# What the watcher refuses before it arms -- specs/detector.md 4.
#
# The detector is the one component that acts with nobody watching, so what it
# is TOLD is checked at startup and a bad entry is refused loudly, by name.
# Never defaulted and never silently ignored: a watcher that starts with the
# wrong device list, or with a debounce of zero because `three` parsed as 0,
# runs and never does the right thing.
#
# Run as a real process, because the failure this replaces was a bare cast under
# Set-StrictMode/Stop: the script died at line 300 of itself, before arming, in
# a console-less wscript host, and the 1-minute self-heal relaunched it to die
# again every minute with nothing anywhere saying why. Importing the function
# would not have seen that.
#
# EVERY CASE HERE IS A REFUSAL, deliberately. A run with a valid config ARMS --
# it would take the machine-wide mutex, stand between the installed watcher and
# its arrivals, and sit there until something killed it. So what is proved is
# that each bad entry is refused BY NAME, and that the other checks let a good
# value through, which the cross cases below cover: a valid debounce beside a
# bad device names the device, not the debounce.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$WinDir  = Split-Path -Parent $PSScriptRoot
$Watcher = Join-Path $WinDir 'event-watch.ps1'

$tmp = Join-Path $env:TEMP 'trigger-kvm-detector'
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# -Exec has to exist, and must be something a fire could run harmlessly. None of
# these runs reaches the point of firing anything.
$exec = Join-Path $tmp 'harmless.ps1'
'exit 0' | Set-Content -LiteralPath $exec -Encoding ASCII

function Invoke-Watcher {
    param([string[]]$Config)

    $cfg = Join-Path $tmp 'config'
    $Config | Set-Content -LiteralPath $cfg -Encoding ASCII

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName  = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Exec "{1}" -Config "{2}"' -f
                     $Watcher, $exec, $cfg
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $p  = [Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    # BOUNDED. A regression that armed instead of refusing would otherwise hang
    # the suite AND leave a second watcher holding the lock.
    if (-not $p.WaitForExit(30000)) {
        try { $p.Kill() } catch { }
        throw 'the watcher did not refuse and did not exit -- it armed, which no case here may do'
    }
    return [pscustomobject]@{ Code = $p.ExitCode; Text = "$($so.Result)`n$($se.Result)" }
}

$GOOD_DEVICE = 'trigger.device = usb:046d:0843'

# ---- timings ------------------------------------------------------------------

foreach ($bad in 'three', '3 s', '', '-1', '.5', '3.') {
    $r = Invoke-Watcher @($GOOD_DEVICE, "trigger.debounce = $bad", 'trigger.settle = 0.75')
    Assert-True ($r.Code -ne 0) "a debounce of '$bad' must refuse, not arm"
    Assert-Match $r.Text 'REFUSING to start'  'and say so where a log can see it'
    Assert-Match $r.Text 'trigger.debounce'   "naming the key, for '$bad'"
    Assert-NoMatch $r.Text 'trigger.settle'   'and not the one that was fine'
}

$r = Invoke-Watcher @($GOOD_DEVICE, 'trigger.debounce = 3.0', 'trigger.settle = three')
Assert-True ($r.Code -ne 0) 'and settle is checked too'
Assert-Match $r.Text 'trigger.settle'
Assert-NoMatch $r.Text 'trigger.debounce' 'a valid debounce beside a bad settle is not blamed'

# ---- devices ------------------------------------------------------------------
#
# Anything that is not the grammar is refused BY NAME -- never prefixed into a
# `usb:` entry that can match nothing, which is a watcher that runs forever and
# never fires.
foreach ($bad in 'nonsense', '046d:084', 'usb:046d', 'bt:00112233', 'bt:0011223344fg',
                 '046d : 0843', '0x046d:0x0843') {
    $r = Invoke-Watcher @("trigger.device = $bad", 'trigger.debounce = 3.0', 'trigger.settle = 0.75')
    Assert-True ($r.Code -ne 0) "the device entry '$bad' must refuse, not arm"
    Assert-Match $r.Text 'REFUSING to start'
    Assert-Match $r.Text ([regex]::Escape($bad)) "naming the entry as it was written: '$bad'"
    Assert-NoMatch $r.Text 'trigger.debounce = ' 'and not blaming a timing that was fine'
}

# An empty list is not a watcher with nothing to do; it is a setup nobody
# finished, and the task would otherwise sit there watching for nothing.
$r = Invoke-Watcher @('trigger.device =', 'trigger.debounce = 3.0')
Assert-True ($r.Code -ne 0) 'an empty device list must refuse'
Assert-Match $r.Text 'REFUSING to start'

$r = Invoke-Watcher @('trigger.debounce = 3.0')
Assert-True ($r.Code -ne 0) 'and so must a config with no trigger.device at all'
Assert-Match $r.Text 'trigger-kvm configure' 'saying what to do about it'

# ---- settle tests the ARRIVING device, not any watched one -------------------
#
# specs/detector.md 2. "Appear then vanish" was a glitch, not a switch -- but the
# test has to be on the device that arrived. With two devices that travel
# together, "is anything present?" is always yes and the protection is inert.
# macOS had exactly that; Windows has always filtered $arrived.
#
# Pinned structurally, at the one line that decides it, because reaching it needs
# a real WMI device-change event and a real plug -- and the whole point of the
# rule is that it is invisible until the day it matters.
$src = Get-Content -Raw -LiteralPath $Watcher
Assert-Match $src '\$stillHere = @\(\$arrived \| Where-Object \{ \$present\[\$_\] \}\)' `
    'the settle re-check must filter the devices that ARRIVED, not the whole watch list'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
exit 0
