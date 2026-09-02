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

# ---- "is a watcher running" comes from the LOCK ------------------------------
#
# The question status and restart ask. It is answered from the mutex because
# counting processes is structurally blind to a session-0 watcher: an unelevated
# caller reads CommandLine as empty across the session boundary, and status
# printed "watchers : 0" about a live boot-tier watcher that had just fired
# (2026-09-02, docs/measurements.md).
#
# Driven against a name of the suite's own, via -MutexName, because the real
# watcher is usually running while the tests are and would answer every case
# 'running'. That seam reaches the QUERY only -- the assertion that it cannot
# reach the code which takes the lock for real is in conventions.tests.ps1.

function Invoke-IsRunning {
    param([string]$Name)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName  = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -IsRunning -MutexName "{1}"' -f
                     $Watcher, $Name
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $p  = [Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(30000)) { try { $p.Kill() } catch { }; throw '-IsRunning hung' }
    return [pscustomobject]@{ Code = $p.ExitCode; Text = "$($so.Result)`n$($se.Result)" }
}

$probe = 'Local\trigger-kvm-test-' + [Guid]::NewGuid().ToString('N')

# 1. The name does not exist: nothing ever created it.
$r = Invoke-IsRunning $probe
Assert-True ($r.Code -ne 0) 'a lock nobody created must report no watcher'
Assert-Match $r.Text 'none'

# 2. The name exists but NOTHING HOLDS IT -- a watcher that died and left its
#    name behind. Creating a Mutex object does not acquire it, so this is the
#    stale case, and it must NOT be read as a live watcher.
$stale = New-Object System.Threading.Mutex($false, $probe)
try {
    $r = Invoke-IsRunning $probe
    Assert-True ($r.Code -ne 0) 'a lock that exists but is unheld is not a running watcher'
    Assert-Match $r.Text 'none'

    # 3. Held: this is what a live watcher looks like.
    $null = $stale.WaitOne(0)
    try {
        $r = Invoke-IsRunning $probe
        Assert-Equal 0 $r.Code 'a HELD lock is a running watcher'
        Assert-Match $r.Text 'running'
    } finally { $stale.ReleaseMutex() }

    # 4. And releasing it goes back to "none" -- proving the check above did not
    #    simply latch on the name existing.
    $r = Invoke-IsRunning $probe
    Assert-True ($r.Code -ne 0) 'releasing the lock reports no watcher again'
} finally { $stale.Dispose() }

# THE CHECK MUST NOT KEEP WHAT IT TAKES. In the unheld case it acquires the mutex
# to find out nobody had it; holding on would lock the real watcher out of its own
# name at its next start. Proved by taking the lock straight afterwards from here:
# if the child had kept it, this fails.
$after = New-Object System.Threading.Mutex($false, $probe)
try {
    $null = Invoke-IsRunning $probe
    Assert-True ($after.WaitOne(0)) 'the running-check must release any lock it acquired'
    $after.ReleaseMutex()
} finally { $after.Dispose() }

# THE CASE THE WHOLE CHANGE EXISTS FOR: the name exists under a token this one
# cannot OPEN. That is what a session-0 watcher looks like from a desktop session
# -- OpenExisting throws UnauthorizedAccessException rather than finding nothing --
# and reading it as "no watcher" is the bug being fixed (2026-09-02,
# docs/measurements.md).
#
# Built here with a DENY ace for the caller rather than a second logon session,
# which the suite cannot create. The deny is evaluated when the CHILD opens the
# name; the handle made below keeps working, because the check happened when it
# was created.
$denied = 'Local\trigger-kvm-test-' + [Guid]::NewGuid().ToString('N')
$sec = $null
try {
    $sec = New-Object System.Security.AccessControl.MutexSecurity
    $me  = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $sec.AddAccessRule((New-Object System.Security.AccessControl.MutexAccessRule(
        $me, 'FullControl', 'Deny')))
} catch { $sec = $null }

if (-not $sec) {
    Skip-Case 'a lock owned by an unreachable token' 'MutexSecurity is unavailable on this runtime'
} else {
    $new = $false
    $shut = New-Object System.Threading.Mutex($false, $denied, [ref]$new, $sec)
    try {
        Assert-True $new 'the deny-ACL probe must have created the name'
        $r = Invoke-IsRunning $denied
        Assert-Equal 0 $r.Code 'a lock that exists but cannot be OPENED is a running watcher'
        Assert-Match $r.Text 'running'
    } finally { $shut.Dispose() }
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
exit 0
