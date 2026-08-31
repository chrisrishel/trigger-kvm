<#
.SYNOPSIS
Fire trigger-kvm when something happens that means "this machine owns the desk now".

.DESCRIPTION
The single persistent process on this machine. It watches for events that should
pull the displays here and runs `trigger-kvm.ps1 pull` when one occurs.

    event-watch.ps1 -Exec .	rigger-kvm.ps1 -Arg pull `
                    -Device 046d:0843,1235:820a `
                    [-Debounce 3.0] [-Settle 0.75] [-Verbose]

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
present, because they are wired directly to this PC's motherboard and do not pass
through the USB switch. Matching on vendor id alone would fire constantly. Always
match the full VID+PID pair.

TRAP: this presence model works for USB and NOT for Bluetooth, where a PAIRED
device keeps its PnP node whether or not it is connected. Adding Bluetooth needs a
connection-aware source, not a wider match pattern. See ..\AGENTS.md.

Whatever the source, it runs `pull` -- never a scene. A scene names inputs on
hardware this machine cannot observe, so a stale one must never be reachable from
anything automatic.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Exec,

    [string]$Arg = 'windows',

    # VVVV:PPPP, comma-separated. Keep in sync with ..\displays.toml.
    [Parameter(Mandatory = $true)]
    [string[]]$Device,

    [double]$Debounce = 3.0,
    [double]$Settle   = 0.75,

    # Append to this file as well as writing to the host. The watcher owns its own
    # log rather than relying on shell redirection, so it can be launched with no
    # console attached at all -- see install.ps1.
    [string]$LogFile,

    # Rotate the log at startup once it exceeds this. One generation is kept as
    # .1; the older one is discarded. Output is a few lines per switch, so this is
    # years of normal use -- the point is that it is bounded at all.
    [int]$MaxLogBytes = 1MB
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

# --- parse -Device into WQL prefixes ---------------------------------------

# Split on commas as well as taking a real array: launched via `powershell.exe
# -File` (which is how the Scheduled Task runs it) every argument arrives as one
# literal string, so -Device 046d:0843,1235:820a is a single element there.
$watch = @()
foreach ($d in ($Device -split ',')) {
    if ($d -notmatch '^\s*([0-9A-Fa-f]{4})\s*:\s*([0-9A-Fa-f]{4})\s*$') {
        throw "bad -Device '$d'; expected VVVV:PPPP, e.g. 046d:0843"
    }
    # Not $pid: that is a read-only automatic variable (this process's id).
    $vid  = $Matches[1].ToUpper()
    $prod = $Matches[2].ToUpper()
    $watch += [PSCustomObject]@{
        Key = "$vid`:$prod"
        # Backslash is the WQL LIKE escape character, hence the doubling.
        Wql = "DeviceID LIKE 'USB\\VID_$vid&PID_$prod%'"
    }
}

# Is this specific device attached right now?
function Test-DevicePresent {
    param([string]$Wql)
    # -Verbose:$false so our own -Verbose does not drown the log in CIM's
    # per-query chatter; we want the watcher's decisions, not its WQL.
    $hits = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter $Wql -Property DeviceID `
                              -ErrorAction SilentlyContinue -Verbose:$false)
    return ($hits.Count -gt 0)
}

function Get-PresenceMap {
    $map = @{}
    foreach ($w in $watch) { $map[$w.Key] = (Test-DevicePresent -Wql $w.Wql) }
    return $map
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

if (-not $mutex.WaitOne(0)) {
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
