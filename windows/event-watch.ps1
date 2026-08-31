<#
.SYNOPSIS
Fire trigger-kvm when something happens that means "this computer owns the desk now".

.DESCRIPTION
The single persistent process on this computer. It watches for events that should
pull the displays here and runs `trigger-kvm.ps1 pull` when one occurs.

    event-watch.ps1 -Exec ..\trigger-kvm.ps1 -Arg pull [-Verbose]

Device list, debounce and settle come from the CONFIG unless passed explicitly;
the task action carries no configuration at all.

ONE process, N event sources. Today there is one source -- USB device presence --
but the shape is deliberate: every additional persistent listener a user has to run
is another install step and another way for the system to end up half working. A
hotkey, a Bluetooth connection or a dock event belongs HERE, not in a second
background app the user has to set up themselves.

Sources differ in what constitutes a fire, and that is a per-source concern:

  device presence   arrival is an absent -> present EDGE, and needs debounce and
                    settle because a spurious arrival would yank the displays
  hotkey (future)   a keypress is deliberate and discrete; no presence, no settle

So debounce and settle belong to the sources that need them, not to the loop.
What IS shared is the process lifetime, the single-instance lock, and the fire.

Three deliberate safety behaviours on the device source, all there because a
spurious arrival would yank both displays out from under whatever you are doing:

  debounce  ignore any arrival within N seconds of the last fire. Stops two
            watched devices arriving together from firing twice, and stops a
            flapping device from thrashing the displays.
  settle    after an arrival, wait, then confirm the device is STILL present
            before acting. A device that appears and immediately vanishes was a
            glitch, not a switch.
  edge      fire only on a transition from absent to present. Devices already
            plugged in at startup never fire.

Detection uses Win32_DeviceChangeEvent, an extrinsic WMI event: the OS pushes it,
so there is no polling interval. It does not say WHICH device changed, so each
event is followed by a targeted query to establish identity. That combination
gives push latency with exact identity, and needs no elevation.

TRAP: the keyboard and mouse are Logitech too (VID_046D, PID_C547) and are always
present, because they are wired directly to this computer's motherboard and do not
pass through the USB switch. Matching on vendor id alone would fire constantly.
Always match the full VID+PID pair.

TRAP: this presence model works for USB and NOT for Bluetooth, where a PAIRED
device keeps its PnP node whether or not it is connected. Adding Bluetooth needs a
connection-aware source, not a wider match pattern. See ..\AGENTS.md.

Whatever the source, it runs `pull` -- never another computer's name. A name
other than `computer.this` describes inputs on hardware this computer cannot
observe, so a stale one must never be reachable from anything automatic.
#>

[CmdletBinding(DefaultParameterSetName = 'Watch')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Watch')]
    [string]$Exec,

    # What to run the switcher with. Always `pull`: a trigger may never name
    # another computer, because a name other than `computer.this` describes inputs
    # on hardware this machine cannot observe.
    [Parameter(ParameterSetName = 'Watch')]
    [string]$Arg = 'pull',

    # Comma-separated. usb:VVVV:PPPP, bare VVVV:PPPP (= usb), or bt:AAAAAAAAAAAA.
    # Omitted, it comes from the config -- which is the normal case. Passing it
    # explicitly is for testing a device by hand without editing anything.
    [Parameter(ParameterSetName = 'Watch')]
    [Parameter(ParameterSetName = 'TestTrigger')]
    [string[]]$Device,

    # Print "address|connected|name" for every paired Bluetooth device and exit.
    # This script owns the Bluetooth binding, so it is the thing that answers
    # questions about Bluetooth -- install.ps1 calls this for -Discover rather than
    # carrying a second copy of the P/Invoke that could drift out of step. Same
    # shape as `trigger-kvm.ps1 list` answering for displays.
    [Parameter(Mandatory = $true, ParameterSetName = 'ListBluetooth')]
    [switch]$ListBluetooth,

    # Watch the configured devices for ONE arrival and exit, reporting what it saw.
    # The installer offers this as "test the trigger", and it lives here for the same
    # reason -ListBluetooth does: this script owns presence, and a second
    # implementation in the installer would be free to disagree with the one that
    # actually fires. Takes no lock and runs nothing -- a real watcher may be running
    # alongside, and this must not disturb it.
    [Parameter(Mandatory = $true, ParameterSetName = 'TestTrigger')]
    [switch]$TestTrigger,

    # How long to wait for that arrival. Long enough to walk to the switch and back.
    [Parameter(ParameterSetName = 'TestTrigger')]
    [int]$Timeout = 90,

    [Parameter(ParameterSetName = 'Watch')]
    [double]$Debounce = 3.0,
    [Parameter(ParameterSetName = 'Watch')]
    [double]$Settle   = 0.75,

    # Append to this file as well as writing to the host. The watcher owns its own
    # log rather than relying on shell redirection, so it can be launched with no
    # console attached at all -- see install.ps1.
    [string]$LogFile,

    # Rotate the log at startup once it exceeds this. One generation is kept as
    # .1; the older one is discarded. Output is a few lines per switch, so this is
    # years of normal use -- the point is that it is bounded at all.
    [int]$MaxLogBytes = 1MB,

    # Read at STARTUP for anything not passed explicitly. The task action carries
    # no configuration at all, deliberately: baking trigger settings into the task
    # command line meant every config edit needed the task re-registered to take
    # effect, which is a coupling nobody could see and the reason an "apply"
    # step had to exist as a separate concept.
    [string]$Config
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared config reader. Dot-sourced rather than duplicated: three consumers parsing
# the same format independently is a drift risk where the watcher and the switcher
# could silently disagree about what is configured.
. (Join-Path $PSScriptRoot 'config.ps1')

if (-not $Config) { $Config = Get-ConfigPath }

$SOURCE = 'TriggerKvmDeviceChange'

# Machine-wide, not per-session. `Local\` is scoped to one session, so a watcher in
# session 1 and one in session 0 would each take their own and BOTH fire on the same
# arrival -- and the debounce is per-process, so it cannot dedupe across them. That
# is exactly the shape the install tiers can produce (a logon watcher in the user's
# session, an at-startup one in session 0), so the name has to be global.
#
# Measured 2026-08-30: an unelevated interactive process can create a `Global\`
# mutex on this machine, and a second process sees it held. SeCreateGlobalPrivilege
# is not universal though, so `Local\` remains a fallback.
#
# Note this file does NOT know which tier it is running under, and must not: the
# tier is a property of the host and lives in install.ps1. This is a question about
# what the OS permits and what is already running, not about who launched us.
$MUTEX_GLOBAL = 'Global\trigger-kvm-usb-watch'
$MUTEX_LOCAL  = 'Local\trigger-kvm-usb-watch'

function Write-Log {
    param([string]$Message)
    $line = '{0} event-watch: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    if ($LogFile) {
        # The switcher appends to the same file, so a write can briefly collide.
        # Logging must never take the watcher down.
        for ($i = 0; $i -lt 3; $i++) {
            try { Add-Content -LiteralPath $LogFile -Value $line -ErrorAction Stop; break }
            catch { Start-Sleep -Milliseconds 50 }
        }
    }
}

# --- Bluetooth presence -----------------------------------------------------
#
# The classic Win32 Bluetooth API, by P/Invoke -- the same idiom the NVAPI transport
# uses. WinRT would be the modern route and is unusable here: PowerShell refuses to
# subscribe to WinRT events, and Add-Type will not reference the .winmd files a C#
# shim would need. See ..\AGENTS.md.
#
# BLUETOOTH_DEVICE_INFO.fConnected is the field that matters, and it is distinct
# from fRemembered. PnP presence cannot substitute: a PAIRED device keeps its PnP
# node for years after it last connected, so an edge would never fire.

$BtSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class BtPresence {
    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEMTIME { public ushort y, m, dow, d, h, min, s, ms; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct BLUETOOTH_DEVICE_INFO {
        public uint dwSize;
        public ulong Address;
        public uint ulClassofDevice;
        [MarshalAs(UnmanagedType.Bool)] public bool fConnected;
        [MarshalAs(UnmanagedType.Bool)] public bool fRemembered;
        [MarshalAs(UnmanagedType.Bool)] public bool fAuthenticated;
        public SYSTEMTIME stLastSeen;
        public SYSTEMTIME stLastUsed;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 248)] public string szName;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct BLUETOOTH_DEVICE_SEARCH_PARAMS {
        public uint dwSize;
        [MarshalAs(UnmanagedType.Bool)] public bool fReturnAuthenticated;
        [MarshalAs(UnmanagedType.Bool)] public bool fReturnRemembered;
        [MarshalAs(UnmanagedType.Bool)] public bool fReturnUnknown;
        [MarshalAs(UnmanagedType.Bool)] public bool fReturnConnected;
        [MarshalAs(UnmanagedType.Bool)] public bool fIssueInquiry;
        public byte cTimeoutMultiplier;
        public IntPtr hRadio;
    }

    [DllImport("bthprops.cpl", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr BluetoothFindFirstDevice(ref BLUETOOTH_DEVICE_SEARCH_PARAMS p, ref BLUETOOTH_DEVICE_INFO i);
    [DllImport("bthprops.cpl", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool BluetoothFindNextDevice(IntPtr h, ref BLUETOOTH_DEVICE_INFO i);
    [DllImport("bthprops.cpl", SetLastError = true)]
    static extern bool BluetoothFindDeviceClose(IntPtr h);

    static BLUETOOTH_DEVICE_SEARCH_PARAMS Params() {
        var p = new BLUETOOTH_DEVICE_SEARCH_PARAMS();
        p.dwSize = (uint)Marshal.SizeOf(typeof(BLUETOOTH_DEVICE_SEARCH_PARAMS));
        p.fReturnAuthenticated = true;
        p.fReturnRemembered    = true;
        p.fReturnUnknown       = false;
        p.fReturnConnected     = true;
        p.fIssueInquiry        = false;   // never scan: slow, and intrusive
        p.cTimeoutMultiplier   = 0;
        p.hRadio               = IntPtr.Zero;
        return p;
    }

    static BLUETOOTH_DEVICE_INFO Info() {
        var i = new BLUETOOTH_DEVICE_INFO();
        i.dwSize = (uint)Marshal.SizeOf(typeof(BLUETOOTH_DEVICE_INFO));
        return i;
    }

    // address (12 lowercase hex) -> is it CONNECTED right now.
    //
    // Walks the whole paired list, so callers must do this ONCE per presence sweep
    // rather than once per watched device: a single USB plug produces ~32 change
    // events and each one triggers a sweep.
    public static Dictionary<string, bool> Connected() {
        var map = new Dictionary<string, bool>();
        var p = Params();
        var info = Info();
        IntPtr h = BluetoothFindFirstDevice(ref p, ref info);
        if (h == IntPtr.Zero) return map;   // no radio, or nothing paired
        try {
            do {
                map[info.Address.ToString("x12")] = info.fConnected;
                info = Info();
            } while (BluetoothFindNextDevice(h, ref info));
        } finally {
            BluetoothFindDeviceClose(h);
        }
        return map;
    }

    // "address|connected|name" rows, for the installer's device list.
    public static List<string> Describe() {
        var rows = new List<string>();
        var p = Params();
        var info = Info();
        IntPtr h = BluetoothFindFirstDevice(ref p, ref info);
        if (h == IntPtr.Zero) return rows;
        try {
            do {
                rows.Add(info.Address.ToString("x12") + "|" + info.fConnected + "|" + info.szName);
                info = Info();
            } while (BluetoothFindNextDevice(h, ref info));
        } finally {
            BluetoothFindDeviceClose(h);
        }
        return rows;
    }
}
'@

# Loaded once per process, stamped with a hash of its own source. .NET cannot
# replace a loaded type, and silently reusing a stale one would mean running code
# that is not the code on disk -- the same guard, for the same reason, as in
# trigger-kvm.ps1.
$btStampKey = 'trigger-kvm:BtPresenceStamp'
$btStamp    = $BtSource.GetHashCode()
if ('BtPresence' -as [type]) {
    if ([AppDomain]::CurrentDomain.GetData($btStampKey) -ne $btStamp) {
        throw ('This PowerShell session already loaded BtPresence from a DIFFERENT ' +
               'version of this script. Open a new PowerShell window and re-run.')
    }
} else {
    Add-Type -ErrorAction Stop -TypeDefinition $BtSource
    [AppDomain]::CurrentDomain.SetData($btStampKey, $btStamp)
}

# --- settings: explicit parameters win, config fills the rest ----------------
#
# $PSBoundParameters rather than checking for empty values: -Debounce has a default,
# so "not supplied" and "supplied as the default" are otherwise indistinguishable,
# and a config value would silently lose to a default nobody chose.
$cfg = Read-Config -Path $Config

if (-not $PSBoundParameters.ContainsKey('Device')) {
    if (-not $cfg.ContainsKey('trigger.device')) {
        throw "no -Device given and no trigger.device in $Config -- run: trigger-kvm configure"
    }
    $Device = @($cfg['trigger.device'])
}
if (-not $PSBoundParameters.ContainsKey('Debounce') -and $cfg.ContainsKey('trigger.debounce')) {
    $Debounce = [double]$cfg['trigger.debounce']
}
if (-not $PSBoundParameters.ContainsKey('Settle') -and $cfg.ContainsKey('trigger.settle')) {
    $Settle = [double]$cfg['trigger.settle']
}

# Answer the Bluetooth question and stop. Placed here, after the binding is loaded
# but before anything else, so listing takes no lock, registers no events, writes no
# log, and cannot disturb a running watcher.
if ($ListBluetooth) {
    try {
        foreach ($row in [BtPresence]::Describe()) { Write-Output $row }
        exit 0
    } catch {
        Write-Error ("Bluetooth enumeration failed: {0}" -f $_.Exception.Message)
        exit 1
    }
}

# --- parse -Device ----------------------------------------------------------

# Accepted forms, one per comma-separated entry:
#
#   usb:VVVV:PPPP    a USB vendor+product pair
#   VVVV:PPPP        the same thing -- bare means usb, so configs written before
#                    Bluetooth existed keep working unchanged
#   bt:AAAAAAAAAAAA  a Bluetooth device address, 12 hex digits
#
# The transport lives in the VALUE rather than in separate keys because the
# installer presents ONE device list: you think "the stuff that moves when I
# switch", not "my USB things and separately my Bluetooth things". The transport is
# metadata the installer detects for you, not a choice to impose.
#
# Split on commas as well as taking a real array: launched via `powershell.exe
# -File` (which is how the Scheduled Task runs it) every argument arrives as one
# literal string, so -Device 046d:0843,1235:820a is a single element there.
$watch = @()
foreach ($d in ($Device -split ',')) {
    $t = $d.Trim()
    if (-not $t) { continue }

    if ($t -match '^(?:[Uu][Ss][Bb]:)?([0-9A-Fa-f]{4})\s*:\s*([0-9A-Fa-f]{4})$') {
        # Not $pid: that is a read-only automatic variable (this process's id).
        $vid  = $Matches[1].ToUpper()
        $prod = $Matches[2].ToUpper()
        $watch += [PSCustomObject]@{
            Kind = 'usb'
            Key  = "usb:$vid`:$prod"
            # Backslash is the WQL LIKE escape character, hence the doubling.
            Wql  = "DeviceID LIKE 'USB\\VID_$vid&PID_$prod%'"
            Addr = $null
        }
    }
    elseif ($t -match '^[Bb][Tt]:([0-9A-Fa-f]{12})$') {
        $addr = $Matches[1].ToLower()
        $watch += [PSCustomObject]@{
            Kind = 'bt'
            Key  = "bt:$addr"
            Wql  = $null
            Addr = $addr
        }
    }
    else {
        throw "bad -Device '$t'; expected usb:VVVV:PPPP (or bare VVVV:PPPP) or bt:AAAAAAAAAAAA"
    }
}

# --- presence ---------------------------------------------------------------

# Is this USB device attached right now?
function Test-UsbPresent {
    param([string]$Wql)
    # -Verbose:$false so our own -Verbose does not drown the log in CIM's
    # per-query chatter; we want the watcher's decisions, not its WQL.
    $hits = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter $Wql -Property DeviceID `
                              -ErrorAction SilentlyContinue -Verbose:$false)
    return ($hits.Count -gt 0)
}

# One sweep across every watched device, whatever its transport.
#
# The Bluetooth list is enumerated ONCE here rather than per device: the API walks
# the whole paired set on every call, and a single USB plug produces ~32 change
# events, each of which triggers a sweep. Skipped entirely when nothing Bluetooth
# is watched, so the common single-transport setup pays nothing for this.
function Get-PresenceMap {
    $map = @{}

    $bt = $null
    if ($watch | Where-Object { $_.Kind -eq 'bt' }) {
        try {
            $bt = [BtPresence]::Connected()
        } catch {
            # A missing or disabled radio must not take the watcher down -- the USB
            # half has to keep working. Treat Bluetooth as "nothing connected",
            # which is an absence, and absences never fire.
            Write-Verbose ("Bluetooth enumeration failed ({0}); treating as none connected" -f $_.Exception.Message)
            $bt = @{}
        }
    }

    foreach ($w in $watch) {
        if ($w.Kind -eq 'bt') {
            # CONNECTED, not paired. A paired-but-disconnected device keeps its PnP
            # node for years, which is exactly why this cannot use the USB path.
            $map[$w.Key] = ($null -ne $bt -and $bt.ContainsKey($w.Addr) -and $bt[$w.Addr])
        } else {
            $map[$w.Key] = Test-UsbPresent -Wql $w.Wql
        }
    }
    return $map
}

# Watch for one arrival and report it. Deliberately after the presence functions and
# before anything that arms or locks: this is a question about the devices, not a
# second watcher.
if ($TestTrigger) {
    $state = Get-PresenceMap
    Write-Host ''
    foreach ($w in $watch) {
        Write-Host ('  {0,-20} {1}' -f $w.Key, $(if ($state[$w.Key]) { 'here now' } else { 'not here' }))
    }
    Write-Host ''
    Write-Host '  Flip your switch AWAY from this computer, then back again.'
    Write-Host ("  Waiting up to {0}s. Ctrl+C to give up." -f $Timeout)
    Write-Host ''

    $deadline = (Get-Date).AddSeconds($Timeout)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 700
        $now = Get-PresenceMap
        foreach ($w in $watch) {
            if ($now[$w.Key] -eq $state[$w.Key]) { continue }
            if ($now[$w.Key]) {
                # An arrival is the event the watcher fires on, so this is the answer.
                Write-Host ('  {0} arrived -- this is what fires the switch.' -f $w.Key)
                exit 0
            }
            Write-Host ('  {0} left.' -f $w.Key)
        }
        $state = $now
    }

    Write-Host '  Nothing arrived.'
    exit 1
}

function Invoke-Exec {
    # Fire and forget, exactly like the macOS posix_spawn: never block the watch
    # loop on the switcher, and never let a switcher failure kill the watcher.
    try {
        $switchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                        '-File', "`"$Exec`"", $Arg)
        # Hand the switcher the same log, so its lines land beside ours.
        if ($LogFile) { $switchArgs += @('-LogFile', "`"$LogFile`"") }

        $psi = @{
            FilePath     = 'powershell.exe'
            ArgumentList = $switchArgs
            WindowStyle  = 'Hidden'
            PassThru     = $true
        }
        $p = Start-Process @psi
        Write-Log ("fired: {0} {1} (pid {2})" -f $Exec, $Arg, $p.Id)
    } catch {
        Write-Log ("ERROR: failed to run {0}: {1}" -f $Exec, $_.Exception.Message)
    }
}

# --- arm --------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Exec -PathType Leaf)) {
    throw "-Exec '$Exec' not found"
}
$Exec = (Resolve-Path -LiteralPath $Exec).Path

# Single instance, enforced here rather than by whoever launches us. Two watchers
# would both see the same arrival and each fire the switcher, and the debounce is
# per-process so it cannot dedupe across them. This also makes the installer's
# 5-minute self-heal trigger free: a redundant start just exits.
$mutex = $null
$scope = 'Global'
try {
    $mutex = New-Object System.Threading.Mutex($false, $MUTEX_GLOBAL)
} catch [System.UnauthorizedAccessException] {
    # The name exists but this token cannot open it, which means something else owns
    # it under a different identity -- in practice a watcher from another tier. Stand
    # down rather than falling back, because falling back to a per-session name here
    # would produce exactly the two-watchers-one-arrival case the global name exists
    # to prevent.
    Write-Log 'a watcher owned by another account already holds the global lock; exiting'
    exit 0
} catch {
    # No SeCreateGlobalPrivilege. Per-session exclusion is still better than none.
    $scope = 'Local'
    $mutex = New-Object System.Threading.Mutex($false, $MUTEX_LOCAL)
}

# An ABANDONED mutex is a normal condition here, not an error. A watcher that is
# force-killed rather than exiting cleanly leaves the lock abandoned -- and
# install.ps1 force-kills it on EVERY install, because stopping the task only kills
# the wscript shim and leaves the watcher running as its grandchild. Task Manager
# and a crash do the same.
#
# .NET throws AbandonedMutexException *after* handing the lock over: it is a
# warning that the previous owner died abnormally, not a failure to acquire. Left
# uncaught it aborts the watcher at startup, so an install would register the task,
# report success, and leave nothing watching.
#
# Nothing is protected by this lock except "only one watcher runs", and no shared
# state can be inconsistent, so taking it over is safe. It is logged rather than
# swallowed: it means something killed the last watcher, which is worth seeing.
#
# Verified semantics, not assumed: the exception is thrown AFTER the handover, and
# a subsequent ReleaseMutex() succeeds -- which only works if we genuinely own it.
# Releasing then consumes the abandonment, so the next start sees a clean lock.
#
# Left uncaught it also strands the lock when run BY HAND, because an aborted script
# does not end an interactive shell: the acquiring thread lives on still owning it,
# and every later watcher reports "another watcher is already running" until that
# window is closed. That is how this bug was found.
$acquired = $false
try {
    $acquired = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $acquired = $true
    Write-Log 'took over an abandoned lock (the previous watcher was killed, not stopped)'
}

if (-not $acquired) {
    Write-Log "another watcher is already running ($scope scope); exiting"
    exit 0
}

# Rotate here, and only here: after the mutex, so the installer's 1-minute
# self-heal tick (which exits immediately while a watcher is alive) never rotates,
# and once per real start rather than per write, so the switcher -- a separate
# process appending to the same file -- can never race a rename mid-switch. The
# watcher is the long-lived owner, so its startup is the one safe moment.
if ($LogFile -and (Test-Path -LiteralPath $LogFile)) {
    try {
        $size = (Get-Item -LiteralPath $LogFile).Length
        if ($size -gt $MaxLogBytes) {
            $old = "$LogFile.1"
            Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath $LogFile -Destination $old -Force
            Write-Log ("rotated log at {0:N0} bytes (previous kept as {1})" -f $size, $old)
        }
    } catch {
        # A log that cannot be rotated is not a reason to stop watching displays.
        Write-Log ("WARN: could not rotate log: {0}" -f $_.Exception.Message)
    }
}

Unregister-Event -SourceIdentifier $SOURCE -ErrorAction SilentlyContinue
Register-CimIndicationEvent -ClassName Win32_DeviceChangeEvent -SourceIdentifier $SOURCE | Out-Null

# Prime: whatever is already plugged in at startup is the baseline and must not
# fire. This is the equivalent of macOS draining the first iterator callback.
$present    = Get-PresenceMap
$alreadyOn  = @($present.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { $_.Key })
$lastFire   = [DateTime]::MinValue

Write-Log ("watching {0} device(s); exec={1} arg={2} debounce={3}s settle={4}s" -f `
           $watch.Count, $Exec, $Arg, $Debounce, $Settle)
Write-Log ("context: user={0} sessionId={1} interactive={2} lock={3}" -f `
           [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
           (Get-Process -Id $PID).SessionId, [Environment]::UserInteractive, $scope)
Write-Log ("armed ({0} already present, not firing){1}" -f `
           $alreadyOn.Count, $(if ($alreadyOn) { ': ' + ($alreadyOn -join ', ') } else { '' }))

try {
    while ($true) {
        # The timeout exists only so the loop stays interruptible; a timeout is
        # not itself a signal and deliberately does nothing.
        $ev = Wait-Event -SourceIdentifier $SOURCE -Timeout 3600
        if (-not $ev) { continue }
        Remove-Event -EventIdentifier $ev.EventIdentifier -ErrorAction SilentlyContinue

        $now     = Get-PresenceMap
        $arrived = @($watch | Where-Object { $now[$_.Key] -and -not $present[$_.Key] } | ForEach-Object { $_.Key })
        $departed = @($watch | Where-Object { $present[$_.Key] -and -not $now[$_.Key] } | ForEach-Object { $_.Key })
        $present = $now

        # Log the rejection rather than dropping it silently. Without this line a
        # quiet log cannot distinguish "no event was delivered" from "an event was
        # delivered and correctly rejected" -- the outcome is the same, the claim is
        # not, and AGENTS.md asks for exactly this before anyone tries to evidence
        # which happened. Verbose rather than logged: the OS delivers these
        # constantly and the steady state is noise, not news.
        if (-not $arrived) {
            $why = if ($departed) { 'departure of ' + ($departed -join ', ') } else { 'no watched device changed state' }
            Write-Verbose ("device-change event yielded no arrival edge ({0}); ignoring" -f $why)
            continue
        }

        $since = ([DateTime]::UtcNow - $lastFire).TotalSeconds
        if ($since -lt $Debounce) {
            Write-Verbose ("arrival {0} within debounce ({1:N1}s); ignoring" -f ($arrived -join ', '), $since)
            continue
        }

        Write-Log ("arrival {0}; settling {1:N2}s" -f ($arrived -join ', '), $Settle)
        Start-Sleep -Seconds $Settle

        # Settle re-check: is any device that just arrived STILL here?
        $present = Get-PresenceMap
        $stillHere = @($arrived | Where-Object { $present[$_] })
        if (-not $stillHere) {
            Write-Log 'device vanished during settle window; ignoring (glitch, not a switch)'
            continue
        }

        $lastFire = [DateTime]::UtcNow
        Invoke-Exec

        # Drop anything that queued up while we slept. Debounce would swallow
        # these anyway; discarding them keeps the loop from replaying stale state.
        Get-Event -SourceIdentifier $SOURCE -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
    }
} finally {
    Unregister-Event -SourceIdentifier $SOURCE -ErrorAction SilentlyContinue
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
