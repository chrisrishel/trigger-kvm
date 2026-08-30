<#
.SYNOPSIS
Fire a command when a watched USB device is plugged in.

.DESCRIPTION
Built for display-switch: when the USB switch hands this PC the shared
peripherals, pull both monitors to this machine. This is the Windows port of
macos/usb-watch.c and deliberately keeps the same semantics.

    usb-watch.ps1 -Exec .\switch-displays.ps1 -Arg windows `
                  -Device 046d:0843,1235:820a `
                  [-Debounce 3.0] [-Settle 0.75] [-Verbose]

Three deliberate safety behaviours, all there because a spurious device arrival
would yank both displays out from under whatever you are doing:

  debounce  ignore any arrival within N seconds of the last fire. Stops two
            watched devices arriving together from firing twice, and stops a
            flapping device from thrashing the displays.
  settle    after an arrival, wait, then confirm the device is STILL present
            before acting. A device that appears and immediately vanishes was a
            glitch, not a switch.
  edge      fire only on a transition from absent to present. Devices already
            plugged in at startup never fire.

Detection uses Win32_DeviceChangeEvent, which is an extrinsic WMI event: the OS
pushes it, so there is no polling interval. It does not say WHICH device changed,
so each event is followed by a targeted query to establish identity. That
combination gives push latency with exact identity, and needs no elevation.

TRAP: the keyboard and mouse are Logitech too (VID_046D, PID_C547) and are always
present, because they are wired directly to this PC's motherboard and do not pass
through the USB switch. Matching on vendor id alone would fire constantly. Always
match the full VID+PID pair.
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
    [double]$Settle   = 0.75
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SOURCE = 'DisplaySwitchDeviceChange'

function Write-Log {
    param([string]$Message)
    Write-Host ('{0} usb-watch: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
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
        $psi = @{
            FilePath     = 'powershell.exe'
            ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Exec, $Arg)
            NoNewWindow  = $true
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

Unregister-Event -SourceIdentifier $SOURCE -ErrorAction SilentlyContinue
Register-CimIndicationEvent -ClassName Win32_DeviceChangeEvent -SourceIdentifier $SOURCE | Out-Null

# Prime: whatever is already plugged in at startup is the baseline and must not
# fire. This is the equivalent of macOS draining the first iterator callback.
$present    = Get-PresenceMap
$alreadyOn  = @($present.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { $_.Key })
$lastFire   = [DateTime]::MinValue

Write-Log ("watching {0} device(s); exec={1} arg={2} debounce={3}s settle={4}s" -f `
           $watch.Count, $Exec, $Arg, $Debounce, $Settle)
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
        $present = $now

        if (-not $arrived) { continue }

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
}
