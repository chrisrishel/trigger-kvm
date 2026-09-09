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
Import-Subject -Script 'event-watch.ps1' -Functions @('Resolve-DeviceMatch','Format-UsbRows')
. (Join-Path $WinDir 'config.ps1')

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

# ---- an entry may say WHICH device, and a malformed one still refuses ---------
#
# specs/detector.md 4.1. Two receivers of one model share a vendor:product pair,
# so `usb:VVVV:PPPP[@token[@where]]` says which. The suffixes are [a-z0-9-]:
# anything else is not the grammar and gets the same refusal as any other
# malformed entry, because an entry that can never match is a watcher that runs
# forever and never fires.
foreach ($bad in 'usb:046d:c547@', 'usb:046d:c547@BAD', 'usb:046d:c547@a b',
                 'usb:046d:c547@ok@', 'usb:046d:c547@a@b@c', 'usb:046d:c547@under_score') {
    $r = Invoke-Watcher @("trigger.device = $bad", 'trigger.debounce = 3.0', 'trigger.settle = 0.75')
    Assert-True ($r.Code -ne 0) "the device entry '$bad' must refuse, not arm"
    Assert-Match $r.Text 'REFUSING to start'
    Assert-Match $r.Text ([regex]::Escape($bad)) "naming the entry as it was written: '$bad'"
}

# The refusal has to TELL you the suffixes exist, or somebody hand-editing a
# config learns the grammar by having it rejected without being shown it.
$r = Invoke-Watcher @('trigger.device = nonsense', 'trigger.debounce = 3.0')
Assert-Match $r.Text ([regex]::Escape('usb:VVVV:PPPP[@token[@where]]')) `
    'the refusal names the whole grammar, suffixes included'

# ---- only what a device says about ITSELF may identify it ---------------------
#
# The rule that makes two identical receivers distinguishable at all. Both
# inherit `LIGHTSPEED Receiver` from one driver; only one ASSERTS `G915 X
# LIGHTSPEED TKL`. Pooling the two sources into the identity search made each
# twin unidentifiable -- so a driver's name may DESCRIBE a device and may never
# IDENTIFY it, and a row carries a token only for the device's own claim.
$devs = @{}
$devs['c1|046D|C547'] = [PSCustomObject]@{
    Names = @('G915 X LIGHTSPEED TKL', 'LIGHTSPEED Receiver', 'USB Input Device')
    Own   = @('G915 X LIGHTSPEED TKL')
    Where = 'port-0003-hub-0005'
}
$rows = @(Format-UsbRows -Devices $devs)
Assert-Equal 3 $rows.Count 'one row per name, so the caller can show any of them'
Assert-True  (@($rows | Where-Object { $_ -like '*|g915-x-lightspeed-tkl|*' }).Count -eq 1) `
    'the name the device asserts carries a token'
foreach ($driverName in 'LIGHTSPEED Receiver', 'USB Input Device') {
    $row = @($rows | Where-Object { $_ -like "*|$driverName" })
    Assert-Equal 1 $row.Count
    Assert-Match $row[0] '\|\|' 'a name the DRIVER gave it carries an empty token, so it can never identify'
}
Assert-True (@($rows | Where-Object { $_ -like '*|port-0003-hub-0005|*' }).Count -eq 3) `
    'and every row carries where the device is, for breaking a tie later'

# ---- which device, when an id names more than one -----------------------------
#
# specs/detector.md 4.1's table, one case each. Against the pure rule rather than
# the lookup, because the lookup needs two identical devices actually plugged in
# -- and mutation proved the point: with the rule buried inside it, the tiebreak
# and the ambiguity branch could both be deleted with every test still green.
function New-Dev { param([string[]]$Tokens, [string]$Spot = '')
    [PSCustomObject]@{ Tokens = @($Tokens); Spot = $Spot }
}
$kbd   = New-Dev @('usb-receiver','g915-x-lightspeed-tkl') 'port-0003-hub-0005'
$mouse = New-Dev @('usb-receiver','lightspeed-receiver')   'port-0001-hub-0006'

$r = Resolve-DeviceMatch -Devices @($kbd,$mouse) -Token 'g915-x-lightspeed-tkl' -Spot ''
Assert-True $r.Present 'a token held by exactly one device matches it'
Assert-Equal 'token' $r.How

# THE PROPERTY THAT MAKES RECORDING A SPOT SAFE: while the token resolves to one
# device the spot is never consulted, so a dongle moved to another socket keeps
# matching. A trigger that silently stops firing after a replug is the failure
# this whole design is arranged to avoid.
$moved = New-Dev @('usb-receiver','g915-x-lightspeed-tkl') 'port-0009-hub-0002'
$r = Resolve-DeviceMatch -Devices @($moved,$mouse) -Token 'g915-x-lightspeed-tkl' -Spot 'port-0003-hub-0005'
Assert-True $r.Present 'a device that moved sockets still matches on its token'
Assert-Equal 'token' $r.How 'and the stale spot is not what decided it'

$r = Resolve-DeviceMatch -Devices @($kbd,$mouse) -Token 'not-here' -Spot ''
Assert-True (-not $r.Present) 'a token no device carries matches nothing'
Assert-Equal 'none' $r.How

# Both carry `usb-receiver`, so the token alone cannot choose -- THIS is where
# the remembered spot earns its place.
$r = Resolve-DeviceMatch -Devices @($kbd,$mouse) -Token 'usb-receiver' -Spot 'port-0001-hub-0006'
Assert-True $r.Present 'the remembered spot breaks a tie the token cannot'
Assert-Equal 'spot' $r.How 'and the caller is told it was the spot, so it can say so'
Assert-Equal 2 $r.Count

# Ambiguous with no spot recorded, and ambiguous with a spot that no longer
# matches, are the same answer: this ENTRY is disabled, and the caller keeps
# watching everything else.
foreach ($spot in @('', 'port-9999-hub-9999')) {
    $r = Resolve-DeviceMatch -Devices @($kbd,$mouse) -Token 'usb-receiver' -Spot $spot
    Assert-True (-not $r.Present) 'a token both of them carry cannot fire'
    Assert-Equal 'ambiguous' $r.How
    Assert-Equal 2 $r.Count 'and says how many, because the log has to name the problem'
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
Assert-Match $src '\$stillHere = @\(\$arrived \| Where-Object \{ Test-StatePresent \$present\[\$_\] \}\)' `
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

# ---- the listing modes need no config, and refuse nothing --------------------
#
# specs/detector.md 4. They are what `configure` and `discover` are built on, so
# they have to answer on a machine with NO CONFIG AT ALL. They used to sit below
# the settings block, which refuses a missing trigger.device -- so a fresh
# install's walkthrough listed no triggers, and Save then refused for want of
# them (revision 14, item 5). Nothing else on a new machine could get past that.

function Invoke-Listing {
    param([string]$Mode)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName  = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1} -Config "{2}"' -f
                     $Watcher, $Mode, (Join-Path $tmp 'no-such-config')
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $p  = [Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(60000)) {
        try { $p.Kill() } catch { }
        throw "$Mode did not answer -- a listing mode must never wait for anything"
    }
    return [pscustomobject]@{ Code = $p.ExitCode; Text = "$($so.Result)`n$($se.Result)" }
}

Remove-Item -LiteralPath (Join-Path $tmp 'no-such-config') -Force -ErrorAction SilentlyContinue
foreach ($mode in '-ListUsb', '-ListBluetooth') {
    $r = Invoke-Listing $mode
    Assert-Equal 0 $r.Code ("$mode must answer with no config at all")
    Assert-NoMatch $r.Text 'REFUSING to start' ("$mode must refuse nothing")
    Assert-NoMatch $r.Text 'trigger.device'    ("$mode must not even mention what it does not need")
}

# ---- AMBIGUOUS is a state, distinct from absent ------------------------------
#
# specs/detector.md 4.1, and the defect it closes on this platform: read as
# ABSENT, unplugging one of two twins makes the entry resolve, the map flips to
# present, and the loop reads that as an ARRIVAL -- so the monitors move because
# a device LEFT (revision 14, item 2).
Import-Subject -Script 'event-watch.ps1' -Functions @('Test-StatePresent')

Assert-True (Test-StatePresent 'present')            'a resolved device is present'
Assert-True (Test-StatePresent 'where')              'and so is one the remembered spot decided'
Assert-True (-not (Test-StatePresent 'absent'))      'absent is not'
Assert-True (-not (Test-StatePresent 'ambiguous'))   'and neither is ambiguous -- it is a THIRD state'

# The edge itself, pinned at the line that decides it: reaching it needs a real
# WMI device-change event and a real plug, and the whole point of the rule is
# that it is invisible until the day it matters.
$src = Get-Content -Raw -LiteralPath $Watcher
Assert-Match $src '\$arrived\s+= @\(\$watch \| Where-Object \{ \(Test-StatePresent \$now\[\$_\.Key\]\) -and \$present\[\$_\.Key\] -eq ''absent'' \}' `
    'an arrival is ABSENT -> PRESENT: leaving ambiguity re-baselines and never fires'

# ---- every entry ambiguous is a watcher that could never fire ----------------
#
# specs/detector.md 4.1: refusing is the kinder answer, and it is loud under a
# supervisor. Pinned structurally for the same reason -- reproducing it needs
# two physically identical devices at one desk.
Assert-Match $src 'if \(\$ambiguous\.Count -eq \$watch\.Count\) \{' `
    'an all-ambiguous watch list refuses to start'
Assert-Match $src 'every configured trigger is ambiguous' 'and says so in those words'

# ---- a lock that fails for any reason other than "held" refuses --------------
#
# specs/detector.md 1. "Held" is a redundant start and exits 0; anything else is
# a watcher that would otherwise run UNLOCKED, or die as a stack trace inside a
# console-less wscript host with the self-heal relaunching it every minute.
Assert-Match $src 'cannot create the single-instance lock' 'a lock it cannot create is a refusal'
Assert-Match $src 'cannot take the single-instance lock'   'and so is one it cannot take'

exit 0
