<#
.SYNOPSIS
Fire trigger-kvm when something happens that means "this computer owns the desk now".

.DESCRIPTION
The single persistent process on this computer. It watches for events that should
pull the displays here and runs `trigger-kvm.ps1 pull` when one occurs.

    event-watch.ps1 -Exec ..\trigger-kvm.ps1 -Arg pull [-Verbose]

Device list, debounce and settle come from the CONFIG unless passed explicitly.
The task action carries no SETTINGS -- only -Config, the absolute path of the
file to read them from, because %LOCALAPPDATA% in session 0 is not necessarily
the installing user's.

ONE process, N event sources. Two today -- USB device presence and Bluetooth
CONNECTION, both in this file -- and the shape is deliberate: every additional
persistent listener a user has to run is another install step and another way for
the system to end up half working. A hotkey or a dock event belongs HERE, not in
a second background app the user has to set up themselves.

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

TRAP: matching on vendor id alone fires constantly -- a desk easily has a webcam
and a receiver from one vendor. Always match the full VID+PID pair.

TRAP: and the full pair is STILL not always one device. The reference desk has
TWO Logitech receivers, one carrying the keyboard and one the mouse, both
reporting 046D:C547. So an entry may carry `@token` to say WHICH -- and a token
comes only from what a device says about ITSELF, never from its driver's name,
because both receivers inherit `LIGHTSPEED Receiver` from one driver while only
one asserts `G915 X LIGHTSPEED TKL`. Presence being per id is what makes this
matter beyond naming: where two devices share an id and only one travels with
the switch, the id never goes absent, the edge never happens, and the trigger
never fires. See specs/detector.md 4.1.

TRAP: the PnP presence model works for USB and NOT for Bluetooth, where a PAIRED
device keeps its node whether or not it is connected -- for years. That is why
Bluetooth is a separate source in this file, matching on CONNECTED through the
classic bthprops.cpl API, rather than a wider PnP match pattern. Do not merge the
two. See .\AGENTS.md.

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
    # on hardware this computer cannot observe, and a stale one would then be able
    # to cause an AUTOMATIC switch to a dead input.
    [Parameter(ParameterSetName = 'Watch')]
    [string]$Arg = 'pull',

    # Comma-separated. usb:VVVV:PPPP, bare VVVV:PPPP (= usb), or bt:AAAAAAAAAAAA.
    # Omitted, it comes from the config -- which is the normal case. Passing it
    # explicitly is for testing a device by hand without editing anything.
    [Parameter(ParameterSetName = 'Watch')]
    [Parameter(ParameterSetName = 'TestTrigger')]
    [Parameter(ParameterSetName = 'Report')]
    [string[]]$Device,

    # Print "address|connected|name" for every paired Bluetooth device and exit.
    # This script owns the Bluetooth binding, so it is the thing that answers
    # questions about Bluetooth -- install.ps1 calls this for -Discover rather than
    # carrying a second copy of the P/Invoke that could drift out of step. Same
    # shape as `trigger-kvm.ps1 list` answering for displays.
    [Parameter(Mandatory = $true, ParameterSetName = 'ListBluetooth')]
    [switch]$ListBluetooth,

    # Every attached USB device as PHYSICAL devices rather than PnP nodes, with
    # what each says it is and where it is plugged. Here for exactly the reason
    # -ListBluetooth is: this script owns the device-property binding, because it
    # is what has to match a token on every presence sweep, and a second copy in
    # install.ps1 could drift -- a drift whose shape is a walkthrough that writes
    # a token the watcher cannot find.
    [Parameter(Mandatory = $true, ParameterSetName = 'ListUsb')]
    [switch]$ListUsb,

    # Watch the configured devices for ONE arrival and exit, reporting what it saw.
    # The installer offers this as "test the trigger", and it lives here for the same
    # reason -ListBluetooth does: this script owns presence, and a second
    # implementation in the installer would be free to disagree with the one that
    # actually fires. Takes no lock and runs nothing -- a real watcher may be running
    # alongside, and this must not disturb it.
    [Parameter(Mandatory = $true, ParameterSetName = 'TestTrigger')]
    [switch]$TestTrigger,

    # HOW EACH CONFIGURED ENTRY RESOLVES RIGHT NOW, as `raw|state`, one state
    # per entry from `present`, `where`, `absent` and `ambiguous`.
    #
    # specs/status.md 4.1: that verdict comes from the watcher's own matching
    # code, never from a second implementation of the rule -- a second one would
    # be free to disagree with the one that decides whether a monitor moves, and
    # `status` is where somebody looks when it did not.
    #
    # Takes no lock and runs nothing, like the other question modes.
    [Parameter(Mandatory = $true, ParameterSetName = 'Report')]
    [switch]$Report,

    # How long to wait for that arrival. Long enough to walk to the switch and back.
    [Parameter(ParameterSetName = 'TestTrigger')]
    [int]$Timeout = 90,

    # Is a watcher running? Print "running" or "none" and exit 0 / 1. Here for the
    # same reason -ListBluetooth and -TestTrigger are: this script owns the
    # single-instance lock, so it owns the question "is one running", and a second
    # implementation in the installer would be free to disagree with the lock that
    # actually decides. Takes the lock only momentarily and never keeps it.
    [Parameter(Mandatory = $true, ParameterSetName = 'IsRunning')]
    [switch]$IsRunning,

    # Which lock to ASK ABOUT. Exists so the suite can drive all four outcomes
    # against a name of its own -- the real watcher is usually running while the
    # tests are, and would answer for every case.
    #
    # SAFE because it is confined to the read-only parameter set: the code that
    # TAKES the lock for real never reads it, so no value here can produce two
    # live watchers. conventions.tests.ps1 asserts that, rather than trusting it.
    [Parameter(ParameterSetName = 'IsRunning')]
    [string[]]$MutexName,

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

    # WHICH file to read at STARTUP for anything not passed explicitly. The task
    # action carries no SETTINGS, deliberately: baking trigger settings into the
    # task command line meant every config edit needed the task re-registered to
    # take effect, which is a coupling nobody could see and the reason an "apply"
    # step had to exist as a separate concept.
    #
    # The PATH is a different thing and is baked in, because it is the one answer
    # this process cannot derive: an at-startup S4U task can run before the
    # user's profile is loaded, and Get-ConfigPath then reads a %LOCALAPPDATA%
    # that is unset or the Default profile's. Falling back to it is right for a
    # hand-run watcher and wrong for the installed one, which is why the
    # installed one is told.
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

# IS A WATCHER RUNNING? Answered from the LOCK, never by counting processes.
#
# Placed here because it needs the mutex names and nothing else -- deliberately
# before anything that reads a config, arms a source or takes the lock for real.
#
# Counting `powershell.exe` processes whose CommandLine matches this script CANNOT
# answer this for the boot tier: an unelevated caller reads CommandLine as EMPTY
# across the session boundary, so every session-0 process is invisible and the
# count is structurally 0 whatever is running. Measured 2026-09-02 -- 183 of 183
# session-0 processes came back blank against 98 of 130 in the caller's own
# session, while `status` printed "watchers : 0" about a live watcher that had
# fired 40 minutes earlier.
#
# The lock is what MAKES a second watcher impossible, so it is also the honest
# answer to whether one is running: a state, not a tally that can disagree with
# itself. Four outcomes, and access-denied is a POSITIVE one -- the name exists
# under a token we cannot open, which is exactly what a session-0 watcher looks
# like from a desktop session.
#
# It must never keep what it takes. Acquiring the mutex here and holding it would
# lock the real watcher out of its own name at its next restart.
function Test-WatcherRunning {
    param([string[]]$Names = @($MUTEX_GLOBAL, $MUTEX_LOCAL))
    foreach ($name in $Names) {
        $m = $null
        try {
            $m = [System.Threading.Mutex]::OpenExisting($name)
        } catch [System.Threading.WaitHandleCannotBeOpenedException] {
            continue    # the name does not exist: nothing ever created it
        } catch [System.UnauthorizedAccessException] {
            return $true    # exists, owned by a token we cannot open
        } catch {
            continue
        }
        try {
            # Held by someone else, so WaitOne(0) fails: a watcher is alive.
            if (-not $m.WaitOne(0)) { return $true }
            # We got it, so nothing held it -- the name outlived its watcher.
            $m.ReleaseMutex()
        } catch [System.Threading.AbandonedMutexException] {
            # A watcher died holding it. WaitOne SUCCEEDED and we own it now, so
            # this is "not running" -- but it has to be handed straight back.
            try { $m.ReleaseMutex() } catch { }
        } catch {
        } finally {
            $m.Dispose()
        }
    }
    return $false
}

if ($IsRunning) {
    $names = if ($MutexName) { $MutexName } else { @($MUTEX_GLOBAL, $MUTEX_LOCAL) }
    if (Test-WatcherRunning -Names $names) { Write-Host 'running'; exit 0 }
    Write-Host 'none'
    exit 1
}

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
# Device properties, for telling apart two devices that share a vendor:product
# pair -- specs/detector.md 4.1.
#
# cfgmgr32 DIRECTLY, never Get-PnpDeviceProperty: measured 2026-09-04, the cmdlet
# costs ~200 ms PER CALL against 0.14 ms here, and this runs inside a presence
# sweep, of which one physical plug produces dozens. Through the cmdlet a single
# plug would cost over a minute. See windows/AGENTS.md.
#
# Loaded lazily and guarded, like the Bluetooth bindings below: .NET cannot
# replace a type once a runspace has it, and this script is run by hand as well
# as by the task.
$DevNameSource = @'
using System;
using System.Runtime.InteropServices;

public static class DevName {
    [StructLayout(LayoutKind.Sequential)]
    public struct KEY { public Guid fmtid; public uint pid; }

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Locate_DevNodeW(out uint pdnDevInst, string pDeviceID, uint ulFlags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Get_DevNode_PropertyW(uint dnDevInst, ref KEY PropertyKey,
        out uint PropertyType, IntPtr PropertyBuffer, ref uint PropertyBufferSize, uint ulFlags);

    // DEVPKEY_Device_BusReportedDeviceDesc -- what the DEVICE says it is, as
    // opposed to the generic name its driver gives it.
    static KEY BUS = new KEY { fmtid = new Guid("540b947e-8b40-45bc-a8a2-6a0b894cbda2"), pid = 4 };
    // DEVPKEY_Device_ContainerId -- one value per PHYSICAL device, which is how
    // a receiver's twenty-odd nodes collapse into one thing to match.
    static KEY CON = new KEY { fmtid = new Guid("8c7ed206-3f8a-4827-b3ab-ae9e1faefc6c"), pid = 2 };
    // DEVPKEY_Device_LocationInfo -- "Port_#0003.Hub_#0005".
    static KEY LOC = new KEY { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 15 };

    // null for "nothing to say", never a guess and never a throw: an absent
    // property is ordinary, and a presence sweep must not fail over one.
    static string Get(string instanceId, ref KEY k) {
        uint dev;
        if (CM_Locate_DevNodeW(out dev, instanceId, 0) != 0) return null;
        uint type = 0, size = 0;
        CM_Get_DevNode_PropertyW(dev, ref k, out type, IntPtr.Zero, ref size, 0);
        if (size == 0) return null;
        IntPtr buf = Marshal.AllocHGlobal((int)size);
        try {
            if (CM_Get_DevNode_PropertyW(dev, ref k, out type, buf, ref size, 0) != 0) return null;
            if (type == 13) {   // DEVPROP_TYPE_GUID
                byte[] g = new byte[16]; Marshal.Copy(buf, g, 0, 16);
                return new Guid(g).ToString();
            }
            return Marshal.PtrToStringUni(buf);
        } finally { Marshal.FreeHGlobal(buf); }
    }

    public static string BusName(string id)   { return Get(id, ref BUS); }
    public static string Container(string id) { return Get(id, ref CON); }
    public static string Location(string id)  { return Get(id, ref LOC); }
}
'@

function Initialize-DevName {
    if ('DevName' -as [type]) { return $true }
    try { Add-Type -ErrorAction Stop -TypeDefinition $DevNameSource; return $true }
    catch {
        # A token cannot be matched without it. Say so once and treat every
        # tokened entry as unresolvable rather than silently matching the whole
        # id, which would be the fall-back specs/detector.md 4.1 forbids.
        Write-Log ("cannot load device-property bindings ({0}); entries naming a specific device cannot be matched" -f $_.Exception.Message)
        return $false
    }
}


# --- Bluetooth presence -----------------------------------------------------
#
# The classic Win32 Bluetooth API, by P/Invoke -- the same idiom the NVAPI transport
# uses. WinRT would be the modern route and is unusable here: PowerShell refuses to
# subscribe to WinRT events, and Add-Type will not reference the .winmd files a C#
# shim would need. See .\AGENTS.md.
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

# --- the listing modes -------------------------------------------------------
#
# THEY NEED NO CONFIG AND REFUSE NOTHING -- specs/detector.md 4. They are what
# `configure` and `discover` are built on, so they have to answer on a machine
# with no config at all: below this point the settings block refuses a missing
# trigger.device, which on a fresh install left the walkthrough with no triggers
# to list and Save then refusing for want of them.
#
# Here rather than lower down for the other half of the same reason -- listing
# takes no lock, registers no events, writes no log, and cannot disturb a
# running watcher.

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

# The emitted rows, as a pure function over already-gathered devices.
#
# Separated from the gathering because the gathering needs real hardware and a
# P/Invoke, so a rule living inside it can only be checked on a desk that happens
# to own two identical devices -- and mutation found exactly that: the rule below
# could be deleted with the whole suite still green.
#
# ONE ROW PER NAME, and `token` is filled ONLY where the name is the device's own
# claim. A driver's name may describe a device and may never identify it: both
# receivers inherit `LIGHTSPEED Receiver` from one driver, while only one asserts
# `G915 X LIGHTSPEED TKL`, so pooling the two made each twin unidentifiable.
function Format-UsbRows {
    param($Devices)
    $out = @()
    foreach ($k in ($Devices.Keys | Sort-Object)) {
        $p = $k -split '\|'
        foreach ($n in $Devices[$k].Names) {
            $tok = $(if ($Devices[$k].Own -contains $n) { ConvertTo-DeviceToken $n } else { '' })
            $out += ('{0}|{1}|{2}|{3}|{4}|{5}' -f `
                     $p[0], $p[1], $p[2], $tok, $Devices[$k].Where, $n)
        }
    }
    return $out
}

# Answer the USB question and stop, for the same reason and with the same
# properties: no lock, no events, no log, no disturbance to a running watcher.
#
# ONE ROW PER PHYSICAL DEVICE, not per PnP node. A wireless receiver enumerates
# twenty-odd nodes and a person thinks of it as one thing, so the grouping is
# ContainerId -- and grouping here rather than in the caller is the point of
# having one owner: the walkthrough's idea of "a device" and the watcher's have
# to be the same idea, or a token written by one will not match in the other.
#
# Fields: container|vid|pid|token|where|name . `token` and `where` are already
# reduced to the config's [a-z0-9-] class, so the caller never has to know how
# that reduction is done; `name` is the unreduced text, for showing a person.
if ($ListUsb) {
    if (-not (Initialize-DevName)) { exit 1 }
    $devices = @{}
    foreach ($e in @(Get-CimInstance -ClassName Win32_PnPEntity -Property DeviceID, Name `
                                     -Filter "DeviceID LIKE 'USB\\VID_%'" `
                                     -ErrorAction SilentlyContinue -Verbose:$false)) {
        if ($e.DeviceID -notmatch '^USB\\VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') { continue }
        $vid = $Matches[1].ToUpper(); $prod = $Matches[2].ToUpper()
        $c = [DevName]::Container($e.DeviceID)
        if (-not $c) { continue }
        $k = "$c|$vid|$prod"
        if (-not $devices.Contains($k)) {
            $devices[$k] = [PSCustomObject]@{ Names = @(); Own = @(); Where = '' }
        }
        # BOTH SOURCES, because either can be the good one: the driver names a
        # webcam well and the device names a cooler well. Emitting only the
        # device's own name lost that -- and lost the hub filter with it, since
        # an ASM controller calls itself `ASM107x` while its driver calls it
        # `Generic USB Hub`.
        # Kept apart, because they answer different questions. The BUS name is
        # what the device asserts about ITSELF, so it is the only one that may
        # IDENTIFY it; a driver's name is inherited and generic, and pooling the
        # two into the identity search made a receiver undistinguishable from its
        # twin -- both inherit `LIGHTSPEED Receiver` from the same driver, while
        # only one ASSERTS `G915 X LIGHTSPEED TKL`.
        $bus = [DevName]::BusName($e.DeviceID)
        if ($bus -and $devices[$k].Own -notcontains $bus) { $devices[$k].Own += $bus }
        foreach ($n in @($bus, $e.Name)) {
            if ($n -and $devices[$k].Names -notcontains $n) { $devices[$k].Names += $n }
        }
        if (-not $devices[$k].Where) {
            $devices[$k].Where = ConvertTo-DeviceToken ([DevName]::Location($e.DeviceID))
        }
    }
    Format-UsbRows -Devices $devices | ForEach-Object { Write-Output $_ }
    exit 0
}


# --- settings: explicit parameters win, config fills the rest ----------------
#
# $PSBoundParameters rather than checking for empty values: -Debounce has a default,
# so "not supplied" and "supplied as the default" are otherwise indistinguishable,
# and a config value would silently lose to a default nobody chose.
$cfg = Read-Config -Path $Config

# WHAT THIS WATCHER WAS TOLD, CHECKED BEFORE IT ARMS -- specs/detector.md 4.
#
# A bad input is REFUSED, loudly, NAMING THE ENTRY. Never defaulted, never
# silently ignored: a watcher that starts with the wrong device list, or with a
# debounce of zero because `three` parsed as 0, runs and never does the right
# thing, which is the worst failure shape available here.
#
# Refusing under a supervisor means being restarted and refusing again. That is
# the point -- it is loud in the log. What it must not be is SILENT, and it was:
# the timings were a bare [double] cast under Set-StrictMode/Stop, so one bad
# hand edit killed this process before it armed, inside a console-less wscript
# host, with the 1-minute self-heal relaunching it to die again every minute and
# nothing anywhere saying why.
function Deny-Startup {
    param([string]$Message, [string]$Fix = '')
    Write-Log "REFUSING to start: $Message"
    Write-Log $(if ($Fix) { $Fix } else { "fix it in $Config, then:  trigger-kvm restart" })
    exit 2
}

if (-not $PSBoundParameters.ContainsKey('Device')) {
    if (-not $cfg.Contains('trigger.device')) {
        Deny-Startup "no -Device given and no trigger.device in the config -- run: trigger-kvm configure"
    }
    $Device = @($cfg['trigger.device'])
}
if (-not $PSBoundParameters.ContainsKey('Debounce') -and $cfg.Contains('trigger.debounce')) {
    if (-not (Test-Seconds $cfg['trigger.debounce'])) {
        Deny-Startup ("trigger.debounce = '{0}' is not a number of seconds (digits, or digits.digits)" -f $cfg['trigger.debounce'])
    }
    $Debounce = [double]$cfg['trigger.debounce']
}
if (-not $PSBoundParameters.ContainsKey('Settle') -and $cfg.Contains('trigger.settle')) {
    if (-not (Test-Seconds $cfg['trigger.settle'])) {
        Deny-Startup ("trigger.settle = '{0}' is not a number of seconds (digits, or digits.digits)" -f $cfg['trigger.settle'])
    }
    $Settle = [double]$cfg['trigger.settle']
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
# The grammar itself is ConvertFrom-TriggerDevices in config.ps1 -- one copy,
# because install.ps1 shows these entries to a person while this file matches on
# them, and a UI that accepts what this reader refuses is a screen that calls a
# trigger fine while the watcher will not start on it. That shipped once; the
# history is at that function.
$watch = @()
foreach ($e in (ConvertFrom-TriggerDevices $Device)) {
    if (-not $e.Ok) {
        # NAMED, and never prefixed into a `usb:` entry that can match nothing.
        # NAMES THE WHOLE GRAMMAR, suffixes included: somebody hand-editing a
        # config should not have to learn that `@token` exists by having an entry
        # rejected without being shown it. AS IT WAS WRITTEN, so it can be found
        # in the file -- the parser trims and never rewrites for this reason.
        Deny-Startup ("trigger.device entry '{0}' is not a device; expected usb:VVVV:PPPP[@token[@where]] (or bare VVVV:PPPP) or bt:AAAAAAAAAAAA. A token and a where are lower-case letters, digits and dashes." -f $e.Raw)
    }

    if ($e.Kind -eq 'usb') {
        $watch += [PSCustomObject]@{
            Kind = 'usb'
            # AS WRITTEN, so -Report can hand a verdict back against the line in
            # the file rather than against a canonicalisation of it.
            Raw  = $e.Raw
            # UPPER hex here, lower in $e.Key. This one is the watcher's own
            # label, printed beside the WQL it was built with; the candidate
            # keys install.ps1 matches against are the lower-case ones. Do not
            # converge them -- they are read in different places.
            Key  = "usb:$($e.Vid)`:$($e.Prod)" + $(if ($e.Token) { "@$($e.Token)" } else { '' }) +
                                                 $(if ($e.Spot)  { "@$($e.Spot)"  } else { '' })
            # Backslash is the WQL LIKE escape character, hence the doubling.
            # STILL THE WHOLE ID: the query finds every candidate, and the token
            # narrows them afterwards. Putting a token in the WQL would need it
            # to appear in a DeviceID, which is exactly what it does not do.
            Wql  = "DeviceID LIKE 'USB\\VID_$($e.Vid)&PID_$($e.Prod)%'"
            # WHICH device among those sharing the id, and where it was when it
            # was configured. Spot is a TIEBREAK ONLY -- consulted when and only
            # when Token still matches more than one present device, so that
            # moving a dongle to another socket cannot stop a trigger firing.
            Token = $e.Token
            Spot  = $e.Spot
            Addr  = $null
        }
    }
    else {
        $watch += [PSCustomObject]@{
            Kind = 'bt'
            Raw  = $e.Raw
            Key  = $e.Key
            Wql  = $null
            # A Bluetooth address already names one device, so there is nothing
            # to disambiguate. Present and empty rather than absent, because
            # Set-StrictMode makes reading a property that is not there
            # terminating, and every consumer of a watch entry reads these.
            Token = ''
            Spot  = ''
            Addr  = $e.Addr
        }
    }
}

if ($watch.Count -eq 0) {
    Deny-Startup 'no devices to watch -- run: trigger-kvm configure'
}

# --- presence ---------------------------------------------------------------

# Is this USB device attached right now?

function Get-UsbState {
    param([string]$Wql, [string]$Token = '', [string]$Spot = '', [string]$Key = '')

    # -Verbose:$false so our own -Verbose does not drown the log in CIM's
    # per-query chatter; we want the watcher's decisions, not its WQL.
    $hits = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter $Wql -Property DeviceID `
                              -ErrorAction SilentlyContinue -Verbose:$false)

    # NO TOKEN IS THE WHOLE OF THE OLD BEHAVIOUR, and it is the common case: the
    # id is present if anything matching it is. Returning here also means a
    # config written before tokens existed costs exactly nothing -- measured, the
    # branch below adds ~1.4 ms per sweep and this one adds none.
    if (-not $Token) { return $(if ($hits.Count -gt 0) { 'present' } else { 'absent' }) }
    if (-not (Initialize-DevName)) { return 'absent' }

    # specs/detector.md 4.1. Group the matched nodes into PHYSICAL DEVICES and
    # ask which of them carries the token. A vendor:product pair can name more
    # than one device -- two receivers of the same model do -- and presence being
    # per id is what makes that dangerous: if one of them never travels, the id
    # is permanently present, the absent->present edge never happens, and the
    # trigger never fires with nothing in the log to say why.
    $byDevice = @{}
    foreach ($h in $hits) {
        $c = [DevName]::Container($h.DeviceID)
        if (-not $c) { continue }
        if (-not $byDevice.Contains($c)) {
            $byDevice[$c] = [PSCustomObject]@{ Tokens = @(); Spot = '' }
        }
        $slug = ConvertTo-DeviceToken ([DevName]::BusName($h.DeviceID))
        if ($slug -and $byDevice[$c].Tokens -notcontains $slug) { $byDevice[$c].Tokens += $slug }
        if (-not $byDevice[$c].Spot) {
            $byDevice[$c].Spot = ConvertTo-DeviceToken ([DevName]::Location($h.DeviceID))
        }
    }

    $verdict = Resolve-DeviceMatch -Devices @($byDevice.Values) -Token $Token -Spot $Spot

    if ($verdict.How -eq 'spot') {
        # SAID, not silent. A remembered location that has gone stale is
        # dangerous only while nobody can see it was used -- two
        # indistinguishable devices swapped between sockets resolve to the wrong
        # one, and this line is the whole defence against that.
        Write-Log ("{0}: {1} devices share this id and carry '{2}'; the one at '{3}' decided it. Re-run configure if you have moved them." -f `
                   $Key, $verdict.Count, $Token, $Spot)
    }
    if ($verdict.How -eq 'ambiguous' -and -not $script:AmbiguousSaid.Contains($Key)) {
        $script:AmbiguousSaid[$Key] = $true
        Write-Log ("{0}: DISABLED -- {1} devices share this id and carry '{2}', and none is at the remembered spot. Every other trigger still works. Re-run configure to pick." -f `
                   $Key, $verdict.Count, $Token)
    }

    # THE VERDICT, not a bool -- specs/detector.md 4.1. AMBIGUOUS is a state
    # DISTINCT FROM ABSENT, and the difference is what stops a monitor moving
    # because a device LEFT: read as absent, unplugging one of two twins makes
    # the entry resolve, the map flips false -> true, and the loop reads that as
    # an arrival.
    switch ($verdict.How) {
        'token'     { return 'present' }
        'spot'      { return 'where' }
        'ambiguous' { return 'ambiguous' }
        default     { return 'absent' }
    }
}

# The four verdicts, and the two that mean the device is here. `where` is
# present and says the remembered spot is what decided it, which `status` shows
# and the log says at the moment it happens.
function Test-StatePresent {
    param([string]$State)
    return ($State -eq 'present' -or $State -eq 'where')
}

# THE MATCHING RULE, as a pure function over already-gathered devices --
# specs/detector.md 4.1's table, one branch each.
#
# Separated from the lookup deliberately. The lookup needs real hardware and a
# P/Invoke, so a rule living inside it can only be checked on a desk that happens
# to have two identical devices -- and mutation found exactly that: the tiebreak
# and the ambiguity branch could both be deleted with every test still green.
# The rule is the part that decides whether a monitor moves; it is the part that
# has to be testable on any machine.
#
# Returns Present (fire or not), How (which branch decided) and Count, because
# the caller has something to SAY in two of the four cases and cannot re-derive
# which one it was.
function Resolve-DeviceMatch {
    param($Devices, [string]$Token, [string]$Spot)

    $matched = @(@($Devices) | Where-Object { $_.Tokens -contains $Token })

    if ($matched.Count -eq 1) {
        # THE SPOT IS NOT CONSULTED HERE, and that is the whole reason it is safe
        # to record one: a device that moved sockets still matches, so a trigger
        # cannot silently stop firing after a replug.
        return [PSCustomObject]@{ Present = $true;  How = 'token';     Count = 1 }
    }
    if ($matched.Count -eq 0) {
        return [PSCustomObject]@{ Present = $false; How = 'none';      Count = 0 }
    }
    if ($Spot) {
        $here = @($matched | Where-Object { $_.Spot -eq $Spot })
        if ($here.Count -eq 1) {
            return [PSCustomObject]@{ Present = $true; How = 'spot'; Count = $matched.Count }
        }
    }
    # THIS ENTRY is disabled, not the watcher -- a malformed entry can never
    # match, so a watcher carrying one runs and never fires, while this one has
    # its devices present and only "which" unresolved. Refusing to start over
    # that turns a cosmetic uncertainty into total non-operation, met as "it just
    # stopped working" with no visible cause.
    return [PSCustomObject]@{ Present = $false; How = 'ambiguous'; Count = $matched.Count }
}

# Said once per entry, not once per sweep: one plug is dozens of sweeps, and a
# line repeated 32 times per plug would bury the log it is trying to explain.
$script:AmbiguousSaid = @{}

# One sweep across every watched device, whatever its transport. Returns a map
# of key -> state, one of `present`, `where`, `absent` or `ambiguous`.
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
            $map[$w.Key] = $(if ($null -ne $bt -and $bt.ContainsKey($w.Addr) -and $bt[$w.Addr]) { 'present' } else { 'absent' })
        } else {
            $map[$w.Key] = Get-UsbState -Wql $w.Wql -Token $w.Token -Spot $w.Spot -Key $w.Key
        }
    }
    return $map
}

# How each entry resolves now. Deliberately here, after the presence functions
# and before anything that arms or locks: it is a question about the devices,
# not a second watcher, so a real one may be running alongside it.
if ($Report) {
    $state = Get-PresenceMap
    foreach ($w in $watch) { Write-Output ('{0}|{1}' -f $w.Raw, $state[$w.Key]) }
    exit 0
}

# Watch for one arrival and report it. Deliberately after the presence functions and
# before anything that arms or locks: this is a question about the devices, not a
# second watcher.
if ($TestTrigger) {
    $state = Get-PresenceMap
    Write-Host ''
    foreach ($w in $watch) {
        Write-Host ('  {0,-20} {1}' -f $w.Key, $(switch ($state[$w.Key]) {
            'present'   { 'here now' }
            'where'     { 'here now (the remembered spot decided which)' }
            'ambiguous' { 'cannot tell which device this is -- it will not fire' }
            default     { 'not here' } }))
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
            # The same edge the watch loop fires on: ABSENT -> PRESENT and
            # nothing else. Leaving ambiguity is not an arrival, so this must
            # not report one either, or the check would say the trigger works
            # when the watcher would not have fired.
            if ((Test-StatePresent $now[$w.Key]) -and $state[$w.Key] -eq 'absent') {
                Write-Host ('  {0} arrived -- this is what fires the switch.' -f $w.Key)
                exit 0
            }
            if (Test-StatePresent $state[$w.Key]) { Write-Host ('  {0} left.' -f $w.Key) }
        }
        $state = $now
    }

    Write-Host '  Nothing arrived.'
    exit 1
}

# What the switcher is started with. A function so the suite can assert what it
# is handed without spawning one.
#
# -Config is passed on for the same reason the task action bakes it in: this
# process was TOLD which file to read, and a child left to re-derive it from
# %LOCALAPPDATA% answers for whoever the child runs as -- which, in session 0
# before a profile is loaded, is not the installing user. One answer to "which
# config?", handed down, rather than one derived per process.
function Get-SwitcherArguments {
    param([string]$Switcher, [string]$Verb, [string]$LogFile, [string]$ConfigFile)

    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
           '-File', "`"$Switcher`"", $Verb)
    # Hand the switcher the same log, so its lines land beside ours.
    if ($LogFile)    { $a += @('-LogFile', "`"$LogFile`"") }
    if ($ConfigFile) { $a += @('-Config',  "`"$ConfigFile`"") }
    return $a
}

function Invoke-Exec {
    # Fire and forget, exactly like the macOS posix_spawn: never block the watch
    # loop on the switcher, and never let a switcher failure kill the watcher.
    try {
        $switchArgs = Get-SwitcherArguments -Switcher $Exec -Verb $Arg `
                                            -LogFile $LogFile -ConfigFile $Config

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
    try {
        $mutex = New-Object System.Threading.Mutex($false, $MUTEX_LOCAL)
    } catch {
        # NOT "held", so this is not a redundant start -- specs/detector.md 1: a
        # watcher that cannot establish its lock REFUSES, and never runs
        # unlocked. Said rather than thrown, because unhandled it died as a
        # stack trace inside a console-less wscript host and the self-heal
        # relaunched it to do the same thing every minute.
        Deny-Startup ("cannot create the single-instance lock: {0}" -f $_.Exception.Message) `
                     'nothing is watching until that is fixed.'
    }
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
} catch {
    # Anything else is not "held" either, and the same rule applies.
    Deny-Startup ("cannot take the single-instance lock: {0}" -f $_.Exception.Message) `
                 'nothing is watching until that is fixed.'
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
$alreadyOn  = @($present.GetEnumerator() | Where-Object { Test-StatePresent $_.Value } | ForEach-Object { $_.Key })
$lastFire   = [DateTime]::MinValue

# EVERY ENTRY AMBIGUOUS IS A WATCHER THAT WOULD RUN AND NEVER FIRE --
# specs/detector.md 4.1. Refusing is the kinder answer, and it is loud under a
# supervisor. An entry that is merely ABSENT is usable and does not count
# against this: absent is what every trigger looks like while the switch is on
# the other computer.
$ambiguous = @($present.GetEnumerator() | Where-Object { $_.Value -eq 'ambiguous' } | ForEach-Object { $_.Key })
if ($ambiguous.Count -eq $watch.Count) {
    Deny-Startup ("every configured trigger is ambiguous ({0}) -- more than one device answers to each id and none is at its remembered spot, so nothing could ever fire. Re-run: trigger-kvm configure" -f ($ambiguous -join ', '))
}

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

        # AN ARRIVAL IS ABSENT -> PRESENT, and nothing else -- specs/detector.md
        # 2 and 4.1. An entry that was AMBIGUOUS and is now resolved has not
        # arrived: its devices were here all along and only "which" changed, so
        # the baseline moves and nothing fires.
        $now      = Get-PresenceMap
        $arrived  = @($watch | Where-Object { (Test-StatePresent $now[$_.Key]) -and $present[$_.Key] -eq 'absent' } | ForEach-Object { $_.Key })
        $departed = @($watch | Where-Object { (Test-StatePresent $present[$_.Key]) -and -not (Test-StatePresent $now[$_.Key]) } | ForEach-Object { $_.Key })
        $present  = $now

        # Log the rejection rather than dropping it silently. Without this line a
        # quiet log cannot distinguish "no event was delivered" from "an event was
        # delivered and correctly rejected" -- the outcome is the same, the claim is
        # not, and .\AGENTS.md asks for exactly this before anyone tries to evidence
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
        # Windows PowerShell 5.1 binds -Seconds as Int32; preserve fractions.
        Start-Sleep -Milliseconds ([int][Math]::Ceiling($Settle * 1000))

        # Settle re-check: is any device that just arrived STILL here?
        $present = Get-PresenceMap
        $stillHere = @($arrived | Where-Object { Test-StatePresent $present[$_] })
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
