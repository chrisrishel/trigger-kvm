# The install path's decisions, taken apart where they can be reached.
#
# Registering a task, editing a PATH and deleting a program directory are all
# things a suite must not actually do, so what is testable is the thing DECIDED
# just before: the command the task will carry, the arguments the watcher hands
# the switcher, and whether a directory is ours to remove.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

# config.ps1 is pure definitions, so it is dot-sourced rather than picked at:
# it carries the transport table Get-TransportReport reads.
. (Join-Path $WinDir 'config.ps1')
Import-Subject -Script 'lib\host.ps1'     -Functions @(
    'Get-WatcherCommand', 'Get-PathValueKind', 'Get-UserPath', 'Set-UserPath',
    'Get-InputMapReport', 'Get-TransportReport', 'Get-TriggerReport')
Import-Subject -Script 'lib\menu.ps1'     -Functions @('Join-Names')
Import-Subject -Script 'lib\discover.ps1' -Variables @('GENERIC_NAMES') -Functions @(
    'Get-BestDeviceName', 'Get-DeviceRoles', 'Get-CandidateLabel', 'Get-TriggerCandidates')
Import-Subject -Script 'event-watch.ps1'  -Functions @('Get-SwitcherArguments')
# Get-TriggerReport parses the raw config value itself, through the one parser
# the watcher uses. Real callers get this by dot-sourcing config.ps1.
Import-Subject -Script 'config.ps1'      -Functions @('ConvertFrom-TriggerDevices')

# ---- the task action carries every path, the config included -----------------
#
# An at-startup S4U task can run before the user's profile is loaded, so
# %LOCALAPPDATA% in the watcher is not necessarily the installing user's. A
# watcher that read the wrong config would find no trigger.device, throw into a
# console-less wscript host, and be relaunched every minute by the self-heal
# trigger to do it again.

$cmd = Get-WatcherCommand -Watcher 'C:\p\event-watch.ps1' -Switcher 'C:\p\trigger-kvm.ps1' `
                          -LogFile 'C:\l\trigger-kvm.log' -ConfigFile 'C:\l\config'

Assert-Match $cmd '-File "C:\\p\\event-watch\.ps1"'      'the watcher, by absolute path'
Assert-Match $cmd '-Exec "C:\\p\\trigger-kvm\.ps1"'      'the switcher it runs'
Assert-Match $cmd '-Arg pull'                            'and pull, never another computer'
Assert-Match $cmd '-LogFile "C:\\l\\trigger-kvm\.log"'
Assert-Match $cmd '-Config "C:\\l\\config"'              'and WHICH config, resolved at registration'

# A profile path with a space in it is the common case, not an exotic one.
$cmd = Get-WatcherCommand -Watcher 'C:\Users\First Last\p\event-watch.ps1' `
                          -Switcher 'C:\Users\First Last\p\trigger-kvm.ps1' `
                          -LogFile 'C:\Users\First Last\l\trigger-kvm.log' `
                          -ConfigFile 'C:\Users\First Last\l\config'
Assert-Match $cmd '-Config "C:\\Users\\First Last\\l\\config"' 'every path is quoted'

# ---- and the watcher hands the same answer to the switcher -------------------
#
# The other half of the same defect: the watcher knows which config it was told
# to read, and a child left to re-derive it answers for whoever the child runs
# as.

$a = @(Get-SwitcherArguments -Switcher 'C:\p\trigger-kvm.ps1' -Verb 'pull' `
                             -LogFile 'C:\l\trigger-kvm.log' -ConfigFile 'C:\l\config')
$joined = $a -join ' '

Assert-Match $joined '-File "C:\\p\\trigger-kvm\.ps1" pull' 'the verb follows the file, positionally'
Assert-Match $joined '-Config "C:\\l\\config"'              'and the config is passed down, not re-derived'
Assert-Match $joined '-LogFile "C:\\l\\trigger-kvm\.log"'   'so its lines land beside the watcher''s'

# Run by hand with no log, the switcher must not be handed an empty -LogFile:
# powershell -File would take the next argument as its value.
$a = @(Get-SwitcherArguments -Switcher 'C:\p\trigger-kvm.ps1' -Verb 'pull' `
                             -LogFile '' -ConfigFile 'C:\l\config')
Assert-NoMatch ($a -join ' ') '-LogFile' 'an absent log is absent, not an empty flag'
Assert-Match   ($a -join ' ') '-Config'  'and the config is still handed over'

# ---- a half-copied install says so, rather than throwing ---------------------
#
# install.ps1 dot-sources lib\*.ps1, and under $ErrorActionPreference = 'Stop' a
# missing lib\ is a stack trace about Get-ChildItem. That reads as a broken
# program rather than an incomplete copy -- and an incomplete copy is exactly
# when it happens.
#
# Driven as a child process against a directory holding the two files and no
# lib\, because the guard runs before anything this suite can import.

$noLib = Join-Path $env:TEMP ("tk-nolib-$PID")
Remove-Item -LiteralPath $noLib -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $noLib | Out-Null
Copy-Item -LiteralPath (Join-Path $WinDir 'install.ps1') -Destination $noLib
Copy-Item -LiteralPath (Join-Path $WinDir 'config.ps1')  -Destination $noLib

$said = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass `
              -File (Join-Path $noLib 'install.ps1') status 2>&1 | ForEach-Object { "$_" }) -join "`n"
$code = $LASTEXITCODE
Remove-Item -LiteralPath $noLib -Recurse -Force -ErrorAction SilentlyContinue

Assert-Match   $said 'is missing, so this copy is incomplete' 'it names what is missing'
Assert-Match   $said 'run its install.ps1 again'              'and what to do about it'
Assert-NoMatch $said 'Get-ChildItem'                          'and does not say it as a stack trace'
Assert-Equal   1 $code 'an incomplete copy is a failure, not a quiet no-op'

# ---- the user PATH keeps its %VAR% entries, and its kind ---------------------
#
# [Environment]::GetEnvironmentVariable('Path','User') EXPANDS %VAR% references,
# because that is what reading a REG_EXPAND_SZ value means, and
# SetEnvironmentVariable writes back REG_SZ whatever it is given -- measured
# 2026-09-01. Between them, answering yes to the PATH question rewrote every
# %USERPROFILE%-style entry the user already had as a literal path AND downgraded
# the value's kind, so nothing there would ever follow its variable again.
#
# Against a throwaway key under HKCU\Software. The real PATH is the developer's
# own working setup and a test must not be one edit away from it.

$KeyPath = 'Software\trigger-kvm-tests'
$full    = "HKCU:\$KeyPath"
Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
$k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($KeyPath)
try {
    $k.SetValue('Path', 'C:\a;%USERPROFILE%\b', [Microsoft.Win32.RegistryValueKind]::ExpandString)
} finally { $k.Close() }

Assert-Equal 'C:\a;%USERPROFILE%\b' (Get-UserPath -KeyPath $KeyPath) `
    'the value comes back with its %VAR% references intact'
Assert-True ([Environment]::ExpandEnvironmentVariables('%USERPROFILE%') -ne '%USERPROFILE%') `
    'and that variable really does expand, so the assertion above means something'

# Write it back, as the add/remove helpers do, and the kind survives.
Set-UserPath -Value 'C:\a;%USERPROFILE%\b;C:\new' -KeyPath $KeyPath
$k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($KeyPath, $false)
try {
    Assert-Equal 'ExpandString' ([string]$k.GetValueKind('Path')) 'a REG_EXPAND_SZ PATH stays one'
    Assert-Equal 'C:\a;%USERPROFILE%\b;C:\new' `
        ([string]$k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)) `
        'and the other entries are written back as they were, not as what they point at'
} finally { $k.Close() }

Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue

# The kind decision on its own, since the three cases are what it is for.
Assert-Equal 'ExpandString' (Get-PathValueKind -Value 'C:\a;%FOO%\b' -Current 'String') `
    'a value that needs expansion gets it, whatever the old kind'
Assert-Equal 'ExpandString' (Get-PathValueKind -Value 'C:\a;C:\b'    -Current 'ExpandString') `
    'and a PATH that was already REG_EXPAND_SZ is not downgraded'
Assert-Equal 'String'       (Get-PathValueKind -Value 'C:\a;C:\b'    -Current 'String') `
    'while a plain one is left plain rather than gratuitously changed'

# ---- the input map, and the warning that is the point of it ------------------
#
# specs/status.md 3. The map is an assertion about which socket each computer's
# cable is in, and NOTHING can check it: a panel whose EDID product id is stable
# across its inputs still resolves after a cable moves, so `pull` sends the old
# value and the panel goes black with a success in the log. Detection is barred by
# hard rules 2 and 3, so legibility is the whole remedy -- which makes the warning
# a behaviour with a test, not a comment.

$cfg = @{
    'computer.this'            = 'pc'
    'display.lg.vendor'        = '0x1E6D'
    'display.lg.input.0xd0'    = 'pc'
    'display.lg.input.0xd1'    = 'mac'
    'display.asus.vendor'      = '0x06B3'
    'display.asus.input.0x0f'  = 'mac'
    'display.asus.input.0x11'  = 'pc'
}
$rep = @(Get-InputMapReport -Cfg $cfg -Labels @('lg','asus') -This 'pc' -Computers @('pc','mac'))
$all = $rep -join "`n"

Assert-Match $all 'asserted, never verified' 'the map must say it cannot be checked'
Assert-Match $all 'switches that panel to a dead input' 'and what goes wrong when it is stale'
Assert-Match $all 'Fix: trigger-kvm configure' 'and the one thing that fixes it'
Assert-Match $all '0xd0 = pc \(this one\)' 'each input names its computer, marking this one'
Assert-Match $all '0xd1 = mac'

# ORDERED BY COMPUTER, NOT BY INPUT VALUE (specs/config-format.md, "Ordering").
# Sorting on the hex puts the same two computers in opposite orders on two panels
# -- asus would read "mac, pc" while lg read "pc, mac" -- purely by which socket
# each happened to be in. This is the assertion that pins it.
$asus = @($rep | Where-Object { $_ -match '\basus\b' })
Assert-Equal 1 $asus.Count 'the asus row is one line'
Assert-Match $asus[0] '0x11 = pc \(this one\).*0x0f = mac' `
    'the computer order decides, so this panel reads pc then mac like the other one'

# A computer the map does not name is not this one, and must not be marked as it.
$rep2 = @(Get-InputMapReport -Cfg $cfg -Labels @('lg') -This 'mac' -Computers @('mac','pc'))
Assert-Match ($rep2 -join "`n") '0xd1 = mac \(this one\)' 'the marking follows computer.this'
Assert-NoMatch ($rep2 -join "`n") '0xd0 = pc \(this one\)' 'and marks only that one'

# Nothing configured: the map asserts nothing, so the warning would be noise.
$none = @(Get-InputMapReport -Cfg @{} -Labels @() -This '' -Computers @())
Assert-Match   ($none -join "`n") 'none configured'
Assert-NoMatch ($none -join "`n") 'asserted, never verified' `
    'with no display configured there is no assertion to warn about'

# A panel carrying no input keys at all says so, rather than printing an empty row
# that reads as "nothing is wrong".
$bare = @(Get-InputMapReport -Cfg @{ 'display.lg.vendor' = '0x1E6D' } -Labels @('lg') `
                             -This 'pc' -Computers @('pc'))
Assert-Match ($bare -join "`n") 'no inputs mapped'

# ---- what a transport takes away, and where status has to say so -------------
#
# specs/status.md 4. The tier line above this block is about the TIER, and it can
# be completely accurate while being untrue of ONE panel: a machine installed
# from boot really does cover the login screen, and a dxva2 panel really will not
# move until somebody logs in. Reporting only the tier is accurate and misleading
# at once, which is the failure this block exists to catch.

$tcfg = @{
    'display.lg.vendor'      = '0x1E6D'
    'display.lg.transport'   = 'nvapi'
    'display.asus.vendor'    = '0x06B3'
    'display.asus.transport' = 'dxva2'
}
$tr = @(Get-TransportReport -Cfg $tcfg -Labels @('lg','asus') -FromBoot) -join "`n"
Assert-Match $tr 'lg\s+nvapi'  'every panel says which transport carries it'
Assert-Match $tr 'asus\s+dxva2'
Assert-Match $tr 'not before somebody logs in' 'and what that costs, on the row'
Assert-Match $tr 'It does not for asus' `
    'the boot tier is contradicted BY NAME for the panel it is untrue of'

# The same config on the login tier says nothing about coverage: the tier never
# claimed the login screen, so there is no promise for the panel to break. A
# warning here would be noise on the tier where dxva2 costs nothing.
$trLogin = @(Get-TransportReport -Cfg $tcfg -Labels @('lg','asus')) -join "`n"
Assert-Match   $trLogin 'asus\s+dxva2' 'the transport is still reported'
Assert-NoMatch $trLogin 'It does not for' `
    'but nothing is contradicted when the tier never promised the login screen'

# An all-nvapi desk on the boot tier: everything is covered, so nothing is said.
$trOk = @(Get-TransportReport -Cfg @{ 'display.lg.transport' = 'nvapi' } -Labels @('lg') -FromBoot) -join "`n"
Assert-NoMatch $trOk 'It does not for' 'a covered desk gets no warning'

# ABSENT MEANS NVAPI -- specs/config-format.md. A config written before the key
# existed must read as the transport it has always used, not as unanswered.
$trOld = @(Get-TransportReport -Cfg @{ 'display.lg.vendor' = '0x1E6D' } -Labels @('lg') -FromBoot) -join "`n"
Assert-Match   $trOld 'lg\s+nvapi' 'a config with no transport key reads as nvapi'
Assert-NoMatch $trOld 'It does not for' 'and is not warned about'

# NAMED, NOT CORRECTED. The switcher refuses an unrecognised transport by name
# rather than defaulting, so status must not report a working panel where the
# switch is going to refuse one.
$trBad = @(Get-TransportReport -Cfg @{ 'display.lg.transport' = 'adl' } -Labels @('lg')) -join "`n"
Assert-Match $trBad 'UNRECOGNISED' 'an unknown transport is reported as unknown'
Assert-Match $trBad 'refuse this panel' 'and says what the switch will do about it'

# Nothing configured: no rows, and no header claiming there are.
Assert-Equal 0 @(Get-TransportReport -Cfg @{} -Labels @()).Count `
    'with no display configured there is nothing to report'

# ---- naming a device, when Windows would rather not ---------------------------
#
# Measured on this desk 2026-09-04: three separate rows read `USB Input Device`
# and nothing else -- a Logitech receiver carrying a keyboard AND a mouse, the
# motherboard's RGB controller, and an AIO cooler. Two of those can never travel
# with the switch and the one that IS the peripherals was indistinguishable from
# them. Every name below is a real string one of them reports.
#
# The rule TESTS THE NAME. What it replaced ranked nodes by how specific their
# device CLASS was, as a proxy for how good their name would be, and the proxy is
# inverted: HID nodes are exactly the ones Windows names generically.

Assert-Equal 'G915 X LIGHTSPEED TKL' `
    (Get-BestDeviceName -Names @('USB Input Device', 'USB Receiver', 'G915 X LIGHTSPEED TKL')) `
    'a real product name beats every generic sibling'

# THE CASE THAT WAS ACTUALLY BROKEN: the generic name came FIRST and won on class
# rank. Order must not decide this.
Assert-Equal 'ROG STRIX LC' (Get-BestDeviceName -Names @('USB Input Device', 'ROG STRIX LC'))
Assert-Equal 'AURA LED Controller' `
    (Get-BestDeviceName -Names @('USB Composite Device', 'USB Input Device', 'AURA LED Controller'))

# A NAME BEGINNING "USB " IS DESCRIBING THE BUS, NOT THE DEVICE. `USB Receiver`
# and `USB Audio` are not in any generic list -- they are perfectly good English
# -- and they still name a category rather than a thing. This is the test that
# promotes the manufacturer's own string over them, and it is why there is no
# hand-maintained list of weak names to keep adding to.
Assert-Equal 'Realtek USB Audio' (Get-BestDeviceName -Names @('USB Audio', 'Realtek USB Audio')) `
    'a bus-prefixed name loses to one that is not, even though both are specific'
Assert-Equal 'Realtek USB Audio' (Get-BestDeviceName -Names @('Realtek USB Audio', 'USB Audio')) `
    'and the answer does not depend on which came back first'

# ...but "USB " is a PREFERENCE, not a veto: when it is all there is, say it.
# An empty row is worse than a vague one.
Assert-Equal 'USB Receiver' (Get-BestDeviceName -Names @('USB Input Device', 'USB Receiver')) `
    'a weak name still beats a generic one'
Assert-Equal 'USB Input Device' (Get-BestDeviceName -Names @('USB Input Device')) `
    'and a generic one still beats nothing at all'

Assert-Equal '' (Get-BestDeviceName -Names @())        'nothing in, nothing out'
Assert-Equal '' (Get-BestDeviceName -Names @($null, '', '   ')) 'blanks are not names'

# ---- what a device presents itself AS ----------------------------------------
#
# From the HID children, which the USB pass skips because it matches `USB\` only.
# It is the most useful thing on the row -- and it is how the list shows that one
# receiver carries both a keyboard and a mouse, which is a fact people need: that
# is ONE vendor+product and therefore one row. There is no way to trigger on just
# the mouse.
$pnp = @(
    [PSCustomObject]@{ InstanceId = 'HID\VID_046D&PID_C547&MI_00\a'; Class = 'Keyboard' }
    [PSCustomObject]@{ InstanceId = 'HID\VID_046D&PID_C547&MI_01\b'; Class = 'Mouse' }
    [PSCustomObject]@{ InstanceId = 'HID\VID_046D&PID_C547&MI_01\c'; Class = 'HIDClass' }
    [PSCustomObject]@{ InstanceId = 'HID\VID_0B05&PID_879E\d';       Class = 'HIDClass' }
    [PSCustomObject]@{ InstanceId = 'USB\VID_046D&PID_C547\e';       Class = 'USB' }
)
$r = Get-DeviceRoles -Devices $pnp
Assert-Equal 'keyboard, mouse' (@($r['usb:046d:c547']) -join ', ') `
    'one receiver reports both roles, and they are the roles a person recognises'
Assert-Equal $false ($r.Contains('usb:0b05:879e')) `
    'a bare HIDClass child is not a role -- the cooler speaks HID and is not an input device'

# ---- the row: what it is, and NOT what it is doing right now ------------------
#
# State was moved OUT of the label. Connected-vs-paired is a fact about right
# now, not about what a device IS, and carrying both in one column ran
# `Chris's AirPods Pro - Find My  (paired, not connected)` to 53 characters and
# shoved the vendor+product column out of line for every row beneath it.
Assert-Equal 'G915 X LIGHTSPEED TKL  (mouse, keyboard)' `
    (Get-CandidateLabel ([PSCustomObject]@{ Name = 'G915 X LIGHTSPEED TKL'
                                            Roles = @('mouse','keyboard'); State = ''; Twinned = $false; Ambiguous = $false }))
Assert-Equal 'AirPods' `
    (Get-CandidateLabel ([PSCustomObject]@{ Name = 'AirPods'; Roles = @()
                                            State = 'paired, not connected'; Twinned = $false; Ambiguous = $false })) `
    'the state is placed by the caller, beside the key, not baked into the name'

# ---- status names the triggers too -------------------------------------------
#
# `usb:046d:c547` is the only thing a watcher can match on and it tells a person
# nothing. Same problem as the menu had, same answer: say what it IS beside the
# id, never instead of it.
$cands = @(
    [PSCustomObject]@{ Key = 'usb:046d:c547'; Name = 'G915 X LIGHTSPEED TKL'; Roles = @('mouse','keyboard'); State = ''; Twinned = $false; Ambiguous = $false }
    [PSCustomObject]@{ Key = 'usb:1235:820a'; Name = 'Clarett+ 2Pre'; Roles = @(); State = ''; Twinned = $false; Ambiguous = $false }
)
# THE RAW CONFIG VALUE goes in, exactly as Read-Config returns it -- the spaces
# after the commas included. The report parses it itself, through the one parser
# the watcher uses, because a caller normalising on the way in is the defect this
# whole shape exists to prevent.
$tr = @(Get-TriggerReport -Entries 'usb:046d:c547, usb:1235:820a' -Candidates $cands) -join "`n"
Assert-Match $tr 'triggers : usb:046d:c547\s+G915 X LIGHTSPEED TKL\s+\(mouse, keyboard\)'
Assert-Match $tr 'usb:1235:820a\s+Clarett\+ 2Pre'
Assert-NoMatch $tr 'not attached' 'nothing is missing, so nothing is said about missing'
Assert-NoMatch $tr 'MALFORMED'    'and nothing is wrong with either of them'

# A bare VVVV:PPPP means usb, and a device that moved sockets keeps its marker:
# the spot is not part of an identity.
$bare = @(Get-TriggerReport -Entries '046D:C547@usb-receiver@port-9' -Candidates @(
    [PSCustomObject]@{ Key = 'usb:046d:c547@usb-receiver'; Name = 'G915 X LIGHTSPEED TKL'
                       Roles = @(); State = ''; Twinned = $false; Ambiguous = $false })) -join "`n"
Assert-Match $bare 'G915 X LIGHTSPEED TKL' 'a bare, tokened, spotted entry still resolves'
Assert-Match $bare ([regex]::Escape('046D:C547@usb-receiver@port-9')) `
    'and is shown as WRITTEN, not canonicalised -- it is the string to look for in the file'

# A TRIGGER THAT IS NOT HERE IS THE ORDINARY CASE, not a fault -- the peripherals
# are on the other computer, which is exactly when somebody runs status to ask
# why nothing switched. Say so, or the blank reads as broken.
$gone = @(Get-TriggerReport -Entries 'usb:046d:c547,bt:0011223344ee' -Candidates $cands) -join "`n"
Assert-Match $gone 'bt:0011223344ee\s+-- not attached right now'
Assert-Match $gone 'normal when the switch is on the other computer' `
    'and the absence is explained, once, rather than left to read as a fault'

# ---- a malformed entry is SAID to be malformed --------------------------------
#
# The defect this replaced: `status` deleted all whitespace and lower-cased the
# whole entry before displaying it, so `@has space` showed as the well-formed
# `@hasspace` and `@BadCase` as `@badcase`. The watcher reads the raw value,
# trims only and matches case-sensitively, so it refused both and would not
# start -- while this screen showed a configured trigger that was merely "not
# attached right now", the note explaining that an absent trigger is normal
# included. The screen someone checks when a trigger stops working told them
# nothing was wrong, in characters that were not the ones in their file.
foreach ($bad in 'usb:046d:c547@has space', 'usb:046d:c547@BadCase', 'nonsense',
                 'usb:046d:c547@a@b@c', 'usb:046d:c547@under_score') {
    $r = @(Get-TriggerReport -Entries $bad -Candidates $cands) -join "`n"
    Assert-Match $r 'MALFORMED' "'$bad' is called malformed"
    Assert-Match $r ([regex]::Escape($bad)) `
        "and shown EXACTLY as written, or it cannot be found in the file: '$bad'"
    Assert-Match $r 'watcher will not start' 'and the consequence is stated'
    # THE POINT. Counted as missing, a malformed entry draws the note that says
    # an absent trigger is normal -- the tool reassuring somebody about the one
    # line that is stopping the watcher from starting.
    Assert-NoMatch $r 'not attached right now' `
        "malformed is not a kind of absent: '$bad'"
    Assert-NoMatch $r 'normal when the switch is on the other computer' `
        "and must never draw the reassurance: '$bad'"
}

# Both at once: the good one still resolves, the bad one is still named, and each
# note appears for its own reason.
$mixed = @(Get-TriggerReport -Entries 'usb:046d:c547@BadCase, bt:0011223344ee' -Candidates $cands) -join "`n"
Assert-Match $mixed 'MALFORMED'
Assert-Match $mixed ([regex]::Escape('@BadCase')) 'the case is preserved, not folded to @badcase'
Assert-Match $mixed 'not attached right now'                  'the absent one is still absent'
Assert-Match $mixed 'normal when the switch is on the other'  'and still explained'

Assert-Match (@(Get-TriggerReport -Entries @() -Candidates $cands) -join "`n") `
    'none configured  <- nothing will ever fire' `
    'no triggers at all is a different statement from a trigger that is elsewhere'
Assert-Match (@(Get-TriggerReport -Entries '   ' -Candidates $cands) -join "`n") `
    'none configured  <- nothing will ever fire' `
    'and so is a value that is nothing but whitespace'

# ---- the pieces above have to be WIRED, not merely each correct ---------------
#
# Every assertion so far tests a helper in isolation, and all of them passed
# while Get-TriggerCandidates quietly stopped calling one -- found by mutation,
# twice. A helper that is right and unused looks exactly like a helper that is
# right and used, from anywhere except here.
#
# So: drive the real assembler over a synthetic desk. The stubs stand in for the
# only two things it cannot have in a suite -- the PnP database and the child
# process that enumerates Bluetooth -- and nothing else is faked.

# Set-StrictMode: a stub must carry every property the real object is read for.
#
# The enumeration is now ASKED OF event-watch.ps1 -- it owns the device-property
# binding because it is what matches a token on every presence sweep, and a
# second copy here could drift. So the stub is that door, not Get-PnpDevice:
# container|vid|pid|token|where|name, one line per candidate name.
#
# The receiver appears TWICE with two different containers, which is the case
# this whole design exists for: two physical devices, one vendor:product pair.
function Invoke-Sibling {
    param([string]$Script, [string[]]$Arguments)
    if ($Arguments -notcontains '-ListUsb') { return @() }
    @(
        # Two receivers. Both report `usb-receiver`; only one reports the G915,
        # which is exactly why a token must be chosen for UNIQUENESS rather than
        # for being the best name.
        'c1|046D|C547|usb-receiver|port-0003-hub-0005|USB Receiver'
        'c1|046D|C547|g915-x-lightspeed-tkl|port-0003-hub-0005|G915 X LIGHTSPEED TKL'
        'c2|046D|C547|usb-receiver|port-0001-hub-0006|USB Receiver'
        'c2|046D|C547|lightspeed-receiver|port-0001-hub-0006|LIGHTSPEED Receiver'
        # Generic at every node: only the device's own report can name it.
        'c3|0B05|879E|rog-strix-lc|port-0004-hub-0004|ROG STRIX LC'
        # Infrastructure, and an unaddressable failed enumeration.
        'c4|8087|0AAA|generic-usb-hub|port-0001-hub-0001|Generic USB Hub'
        # An ASM controller ASSERTS `ASM107x` and its driver calls it a hub.
        # Preferring the device's own name promotes it PAST a filter that
        # only looks at the chosen one -- which is how two hub controllers
        # got back into the list.
        'c7|174C|2074|asm107x|port-0010-hub-0001|ASM107x'
        'c7|174C|2074||port-0010-hub-0001|Generic USB Hub'
        'c5|0000|0000|unknown-usb-device|port-0009-hub-0001|Unknown USB Device'
        'c6|1235|820A|clarett-2pre|port-0004-hub-0006|Clarett+ 2Pre'
        # TWO devices whose ONLY token is shared, at DIFFERENT ports. Neither
        # can be named apart by a token, so the writer falls to the shared token
        # PLUS where -- specs/detector.md 4.1, case 2.
        'c8|1A2B|3C4D|shared-dock|port-0020-hub-0001|Zed Dock'
        'c9|1A2B|3C4D|shared-dock|port-0021-hub-0001|Zed Dock'
    )
}
# Roles still come from the HID children, which the USB listing never sees.
function Get-PnpDevice {
    param([switch]$PresentOnly, $ErrorAction)
    @(
        [PSCustomObject]@{ InstanceId = 'HID\VID_046D&PID_C547&MI_00\a'; Class = 'Keyboard' }
        [PSCustomObject]@{ InstanceId = 'HID\VID_046D&PID_C547&MI_01\b'; Class = 'Mouse' }
        [PSCustomObject]@{ InstanceId = 'HID\VID_0B05&PID_879E\d';       Class = 'HIDClass' }
    )
}

$got = @(Get-TriggerCandidates)
$byKey = @{}
foreach ($g in $got) { $byKey[$g.Key] = $g }

# TWO ROWS for one vendor:product pair, because there are two devices. The row
# count follows the hardware, not the key -- which is the defect this replaced:
# grouping by id pooled both receivers' names and labelled the pair after
# whichever won, so the mouse's receiver was shown as the keyboard.
Assert-Equal 2 @($got | Where-Object { $_.Key -like 'usb:046d:c547*' }).Count `
    'two physical receivers are two rows'

# The token is chosen for UNIQUENESS, not quality. Both carry `usb-receiver`, so
# neither may use it; each takes the one only it has.
Assert-True ($byKey.Contains('usb:046d:c547@g915-x-lightspeed-tkl')) `
    'the keyboard receiver is keyed by the name only it reports'
Assert-True ($byKey.Contains('usb:046d:c547@lightspeed-receiver')) `
    'and the other by the name only it reports -- never the one they share'
Assert-True (-not ($byKey.Keys -match 'usb-receiver')) `
    'a name both of them report cannot identify either'

Assert-Equal 'port-0003-hub-0005' $byKey['usb:046d:c547@g915-x-lightspeed-tkl'].Spot `
    'and each remembers where it was, for breaking a tie later'
Assert-Equal 'keyboard, mouse' ((@($byKey['usb:046d:c547@g915-x-lightspeed-tkl'].Roles) | Sort-Object) -join ', ')

# A device ALONE on its id gets NO token, so every config written before tokens
# existed still means what it meant and nothing migrates.
Assert-True ($byKey.Contains('usb:0b05:879e')) 'a device alone on its id keeps the plain entry'
Assert-Equal 'ROG STRIX LC' $byKey['usb:0b05:879e'].Name `
    'named from its own report, since every node calls it generic'

# NOTHING IS FILTERED BY NAME, hubs included -- specs/configure.md 7.1. The list
# shows what is true and lets the person decide; a hub that never moves is a bad
# trigger and a visible one, and hiding it made this list disagree with what
# `discover` had shown a moment earlier. This assertion is the inverse of the
# one it replaces, and the change is deliberate (revision 14, item 7).
Assert-True ([bool]($byKey.Keys -like 'usb:8087:0aaa*')) 'a hub is offered like anything else'
Assert-True ([bool]($byKey.Keys -like 'usb:174c:2074*')) `
    'and so is one that calls itself ASM107x while its driver calls it a hub'

# The ONE thing withheld is a node that is not a device at all.
Assert-True (-not ($byKey.Keys -like 'usb:0000:0000*')) 'a failed enumeration is not addressable'

# ORDER IS "HOW LIKELY IS THIS TO TRAVEL", the question Rank was always reaching
# for: it used to score how specific a node's CLASS was, so the keyboard and the
# AIO cooler both scored 2 and tied.
Assert-True ($got[0].Key -like 'usb:046d:c547*') `
    'a device presenting a mouse and a keyboard sorts first'
Assert-True ([array]::IndexOf(@($got.Key), 'usb:1235:820a') -lt
             [array]::IndexOf(@($got.Key), 'usb:0b05:879e')) `
    'an audio interface outranks a cooler that merely speaks HID'


# ---- the writer rule, in its three cases -------------------------------------
#
# specs/detector.md 4.1. A writer chooses for UNIQUENESS, not for quality, among
# the devices sharing the id at the time of writing.
#
# The KEY is the identity a saved entry is matched by, with no spot in it, so a
# device that moved sockets is still the same entry. The ENTRY is what the row
# would be written as, and the two differ only in case 2.

$shared = @($got | Where-Object { $_.Key -like 'usb:1a2b:3c4d*' })
Assert-Equal 2 $shared.Count 'two devices on one id are two rows, whatever can be said about them'

# CASE 2: every candidate token is shared, and the devices sit at different
# places, so the shared token PLUS where. `where` is never written without a
# token, and it is what says which row was picked.
foreach ($s in $shared) {
    Assert-Equal 'usb:1a2b:3c4d@shared-dock' $s.Key 'the identity is the shared token, with no spot'
    Assert-True  $s.Shared    'and the row knows the token alone cannot decide'
    Assert-True  (-not $s.Ambiguous) 'so it is NOT a row that cannot be told from its twin'
}
Assert-Equal 'usb:1a2b:3c4d@shared-dock@port-0020-hub-0001' `
    (@($shared | Where-Object { $_.Spot -eq 'port-0020-hub-0001' })[0].Entry) `
    'the entry carries the port, or picking either row would configure the other'
Assert-Equal 2 (@($shared | ForEach-Object { $_.Entry }) | Sort-Object -Unique).Count `
    'and the two rows are written as two DIFFERENT entries'

# CASE 1 is still preferred over it: a token held by exactly one device is
# written alone, so the device still matches after somebody moves it.
Assert-Equal 'usb:046d:c547@g915-x-lightspeed-tkl' `
    (@($got | Where-Object { $_.Key -like '*g915*' })[0].Entry) `
    'a unique token is written without a spot'

# ---- status says what the WATCHER makes of a qualified entry -----------------
#
# specs/status.md 4.1. The verdict comes from the watcher's own matching code,
# never from a second implementation of the rule here: a second one would be
# free to disagree with the one that decides whether a monitor moves, and this
# screen is where somebody looks when it did not.

$cands = @(
    [PSCustomObject]@{ Key = 'usb:046d:c547@g915-x-lightspeed-tkl'; Name = 'G915'; Roles = @(); Ambiguous = $false }
)
$verdicts = @{
    'usb:046d:c547@g915-x-lightspeed-tkl'                     = 'present'
    'usb:046d:c547@usb-receiver@port-0003-hub-0005'           = 'where'
    'usb:046d:c547@usb-receiver'                              = 'ambiguous'
}
$rep = (Get-TriggerReport -Entries @('usb:046d:c547@g915-x-lightspeed-tkl') `
                          -Candidates $cands -Verdicts $verdicts) -join "`n"
Assert-Match $rep "matched by 'g915-x-lightspeed-tkl'" 'a matched entry says what matched it'

$rep = (Get-TriggerReport -Entries @('usb:046d:c547@usb-receiver@port-0003-hub-0005') `
                          -Candidates @() -Verdicts $verdicts) -join "`n"
Assert-Match $rep "the device at 'port-0003-hub-0005' is the one this matches" `
    'a remembered location that decided a match is SAID, or it is dangerous only while it is silent'
Assert-Match $rep 'if you have moved them' 'and it says what to do if it has gone stale'

$rep = (Get-TriggerReport -Entries @('usb:046d:c547@usb-receiver') `
                          -Candidates @() -Verdicts $verdicts) -join "`n"
Assert-Match $rep 'AMBIGUOUS'    'an ambiguous entry is named as such'
Assert-Match $rep 'will NOT fire' 'and the consequence is stated'
Assert-Match $rep 'is disabled, not absent' `
    'because absent and ambiguous are different states with different remedies'

# An UNQUALIFIED entry gets no verdict line: present and absent are already what
# the row says, and repeating them would be noise on every ordinary desk.
$rep = (Get-TriggerReport -Entries @('usb:046d:0843') -Candidates @() `
                          -Verdicts @{ 'usb:046d:0843' = 'absent' }) -join "`n"
Assert-NoMatch $rep 'matched by' 'an entry with no token has nothing to disambiguate'

# ---- "no" means this session only, and nothing that brings it back -----------
#
# specs/configure.md 8. A task with no triggers is legal and can still be
# started on demand, which is what `restart` does -- so "no" means "nothing
# starts it but you". The SELF-HEAL trigger must not be attached to it, or "no"
# would quietly mean "yes, every minute".
#
# Structural, because reaching it means registering a scheduled task, which is
# machine-wide and outlives anything a suite can sandbox.
$hostText = Get-Content -Raw -LiteralPath (Join-Path $WinDir 'lib\host.ps1')
Assert-Match $hostText "if \(\`$tier -eq 'manual'\) \{[\s\S]*?\`$triggers = @\(\)" `
    'the tier that says it will not come back registers with no triggers'
Assert-Match $hostText "if \(\`$tier -ne 'manual'\) \{ \`$triggers \+= \`$heal \}" `
    'and the self-heal trigger is not attached to it'

# ---- the closing words claim only what was reached ---------------------------
#
# specs/configure.md 12. "trigger-kvm is running" is a claim about the WATCHER,
# and a tier that registered but did not come up has not made it true. Pinned
# structurally: reaching it means registering a scheduled task.
$hostSrc = Get-Content -Raw -LiteralPath (Join-Path $WinDir 'lib\host.ps1')
Assert-Match $hostSrc 'if \(-not \$running\) \{[^}]*NO WATCHER is running' `
    'the closing words must not say it is running when nothing is'

exit 0
