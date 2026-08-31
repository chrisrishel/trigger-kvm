# The whole walkthrough, driven with scripted answers.
#
# Parse-checking cannot find what breaks this: a [hashtable] annotation binds fine at
# parse time and throws mid-run, a row number shifts when a list grows, a flag is
# read before the section that sets it. Only executing every branch does.
#
# Row numbers in the review menu count the separators, which are drawn blank and are
# unpickable:
#   1 Computers  2 Monitors  3 Trigger devices  4 Autostart?  5 Add to PATH?  (6 blank)
#   7 Test the trigger  8 Test the monitors  (9 blank)  10 Save  11 Cancel
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

Import-Subject -Script 'install.ps1' -Variables @('DIALECTS','MCCS_INPUTS','COMPUTER_NAME_RULE') -Functions @(
    'Read-Default','Read-YesNo','Get-MenuWidth','Write-MenuFrame','Split-Detail',
    'Select-One','Select-Many','Join-Names','Get-InputName',
    'Get-DefaultComputerName','Get-KnownComputers','Read-Computers',
    'Format-ComputerName','Read-ComputerName',
    'Read-InputValue','Get-InputTable','Get-DisplayMap',
    'Get-DisplayAnswers','Get-ConfiguredAnswers','Get-AllDisplayAnswers',
    'Invoke-DisplayTest','Invoke-TestRound','Invoke-TestRoundBody','Test-OneComputer',
    'Test-DisplayInput','Test-OneValue','Invoke-BlindWalk',
    'Read-Triggers','Read-Tier','Get-CandidateLabel',
    'Invoke-Configure','Write-ConfigFile')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'config.ps1')

# ---- the machine this suite pretends to be sitting at ------------------------

$script:CONFIG = Join-Path $env:TEMP 'trigger-kvm-tests.cfg'
$global:CONFIG = $script:CONFIG
$global:BINDIR = 'C:\fake\bin'
$global:SEED_DEBOUNCE = '3.0'
$global:SEED_SETTLE   = '0.75'
$global:SWITCH = Join-Path (Split-Path -Parent $PSScriptRoot) 'trigger-kvm.ps1'
$global:Relaunched = $false

function Get-UserPath { 'C:\Windows' }
function Add-ToUserPath { param([string]$Dir) }
function Get-TriggerCandidates {
    @(
        [PSCustomObject]@{ Key='usb:046d:0843';  Bus='USB'; Name='Webcam';    Class='Image';     State=''; Rank=0 }
        [PSCustomObject]@{ Key='bt:0011223344ff';Bus='BT';  Name='AirPods';   Class='Bluetooth'; State='paired, not connected'; Rank=1 }
        [PSCustomObject]@{ Key='usb:1235:820a';  Bus='USB'; Name='Clarett';   Class='Audio';     State=''; Rank=1 }
        [PSCustomObject]@{ Key='usb:046d:c547';  Bus='USB'; Name='Input Dev'; Class='HIDClass';  State=''; Rank=2 }
    )
}
function Invoke-TriggerTest {
    param([string[]]$Devices)
    return [PSCustomObject]@{ Ok = $true; Text = 'saw the devices arrive' }
}

# Two panels, as reported by `list -Raw`. Not read from hardware: a test that only
# passes on one desk is not a test.
function Invoke-Sibling {
    param([string]$Script, [string[]]$Arguments)
    if ($Arguments -contains 'list') {
        return @('06B3|42E0|AUS|HDMI|01010101|PG42UQ',
                 '1E6D|9E9D|GSM|DisplayPort|00001111|LG ULTRAGEAR+')
    }
    return @()
}

# 0 = showed the right machine and came back, 1 = showed something else,
# 2 = changed but did not come back, 3 = nothing happened.
$script:outcomes = @()
function Set-Outcomes { param([int[]]$O) $script:outcomes = @($O) }
function Test-DisplayInput {
    param([string]$Label,[string]$Name,[string]$Candidate,[string]$CandidateName,
          [string]$Current,[switch]$IsMachine,[int]$Hold = 8,[string]$Config)
    if ($script:outcomes.Count -eq 0) { return 0 }
    $o = $script:outcomes[0]
    $script:outcomes = @($script:outcomes | Select-Object -Skip 1)
    return $o
}
function Test-OneValue {
    param([string]$Label,[string]$Name,[string]$Value,[string]$Config,[int]$Hold = 6)
    return ($Value -eq '0x12')
}

function Set-Config {
    param([string[]]$Lines)
    if ($Lines) { $Lines | Set-Content -LiteralPath $script:CONFIG -Encoding ASCII }
    else { Remove-Item -LiteralPath $script:CONFIG -Force -ErrorAction SilentlyContinue }
}
function Get-Written {
    if (-not (Test-Path $script:CONFIG)) { return @{} }
    return (Read-Config -Path $script:CONFIG)
}

$CONFIGURED = @(
 'computer.this = pc'
 'display.lg.vendor = 0x1E6D','display.lg.product = 0x9E9D','display.lg.name = LG ULTRAGEAR+'
 'display.lg.method = lg-alt'
 'display.lg.input.0xd0 = pc','display.lg.input.0xd1 = mac'
 'display.asus.vendor = 0x06B3','display.asus.product = 0x42E0','display.asus.name = PG42UQ'
 'display.asus.method = standard'
 'display.asus.input.0x11 = pc','display.asus.input.0x0f = mac'
 'trigger.device = 046d:0843,1235:820a','trigger.debounce = 3.0','trigger.settle = 0.75'
 'install.autostart = login'
)

# ---- a first run asks everything, computers first ----------------------------

Set-Config $null
Set-Outcomes @()
Set-Answers @(
    'pc',           # what this computer is called
    '1',            # how many others
    'mac',          #   and its name
    '5',            # the list (1 pc, 2 mac, 3 blank, 4 Add, 5 Done)
    'y','',         # PG42UQ: manage? / label
    '3',            #   pc  is on HDMI 1
    '2',            #   mac is on DisplayPort 1 (row 1 is now pc)
    'y','',         # LG: manage? / label
    '9','0xD0',     #   pc  -- not an MCCS value, so "Type a value..."
    '10','0xD1',    #   mac -- row 10 now, since pc was added to the list
    'y',            # check the monitors now?
    '3',            #   which monitor is this window on -> not sure
    'y','y',        #   two rounds, one panel each, both fine
    '1,3',          # triggers
    '',             # when it starts -- the default is FROM BOOT
    'y',            # PATH
    '',             # review -> Test the trigger (the default)
    '10'            # review -> Save
)
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE 'a first run must complete'
$c = Get-Written
Assert-Equal 'pc'   $c['computer.this']
Assert-Equal 'boot' $c['install.autostart'] 'with nothing configured, the default is from boot'
Assert-Equal 'pc'   $c['display.pg42uq.input.0x11']
Assert-Equal 'mac'  $c['display.pg42uq.input.0x0f']
Assert-Equal 'pc'   $c['display.lg.input.0xd0']
Assert-Equal 'mac'  $c['display.lg.input.0xd1']
Assert-True (-not $c.ContainsKey('display.lg.self')) 'self is gone'

# The panel names come out of the EDID, not a table.
Assert-Equal 'PG42UQ' $c['display.pg42uq.name']

# ---- a configured system goes STRAIGHT to the review -------------------------

Set-Config $CONFIGURED
Set-Outcomes @()
Set-Answers @(
    '8',            # review -> Test the monitors
    '3',            #   window: not sure
    'y','y',        #   two rounds
    '10'            # review -> Save
)
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
$asked = @(Get-Asked)
Assert-NoMatch ($asked -join '|') 'short name for it' 'a re-run must not replay the questions'
Assert-Equal 'lg-alt' (Get-Written)['display.lg.method'] 'and must keep what was configured'

# ---- -Fresh asks again, pre-filling nothing ----------------------------------

Set-Config $CONFIGURED
Set-Outcomes @()
Set-Answers @(
    'pc','1','mac','5',
    'y','','3','2',
    'y','','9','0xD0','10','0xD1',
    'n',            # skip the check
    '1,3','','y',
    '','','3','y','y',   # review: test trigger, test monitors (window/2 rounds)
    '10'
)
Invoke-Configure -Fresh
Assert-Equal 0 $LASTEXITCODE
Assert-Match ((Get-Asked) -join '|') 'short name for it' '-Fresh must ask again'

# ---- a dialect is offered when standard does nothing -------------------------

Set-Config @($CONFIGURED | Where-Object { $_ -ne 'display.lg.method = lg-alt' })
Set-Outcomes @(3, 0)        # LG answers nothing, then works on its own channel
Set-Answers @(
    '8',            # review -> Test the monitors
    '3',            #   window: not sure
    'y',            #   round 1: asus fine
    'n',            #   round 2: the LG did nothing
    'y',            #   try the LG channel? yes
    '1',            #   pc  is on DisplayPort (0xD0)
    '2',            #   mac is on USB-C (0xD1)
    '10'            # review -> Save
)
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
Assert-Equal 'lg-alt' (Get-Written)['display.lg.method'] 'the offered dialect must be recorded'

# ---- a wrong value for this computer gets walked out -------------------------

Set-Config $CONFIGURED
Set-Outcomes @(2, 0)        # the ASUS changes but never comes back
Set-Answers @(
    '8','3',
    'n',            #   round 1: the ASUS did not come back
    'n',            #   do you know which input it is? no
    'y',            #   walk the standard values (the stub answers each)
    'y',            #   round 2: the LG is fine
    '10'
)
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
Assert-Equal 'pc' (Get-Written)['display.asus.input.0x12'] 'the walk must correct the value'

# ---- two machines may not share one input ------------------------------------

Set-Config $null
Set-Outcomes @()
Set-Answers @(
    'pc','1','mac','5',
    'y','',
    '3',            # pc on HDMI 1
    '1',            # mac on ... pc's own row: refused
    '2',            # ... so pick DisplayPort 1 instead
    'y','','9','0xD0','10','0xD1',
    'n', '1,3','','y', '','','3','y','y', '10'
)
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
$c = Get-Written
Assert-Equal 'pc'  $c['display.pg42uq.input.0x11']
Assert-Equal 'mac' $c['display.pg42uq.input.0x0f'] 'the second machine had to move to a free input'

# ---- autostart can be answered "no" ------------------------------------------

# Registered but not scheduled: running now, not coming back on its own. The task
# still exists, so `trigger-kvm restart` is what starts it again.
Set-Config $CONFIGURED
Set-Outcomes @()
Set-Answers @(
    '4',            # review -> Autostart?
    '3',            #   no -- I will start it myself
    '10'            # review -> Save
)
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
Assert-Equal 'no' (Get-Written)['install.autostart'] 'the third answer has to survive the write'

# ---- what a computer may be called -------------------------------------------

# One name, not a slug plus a display name: it is a config value, a thing you type
# at a prompt, and a label in every message. The rule exists so it survives all three.
Assert-Equal 'mac'         (Format-ComputerName 'Mac')
Assert-Equal 'my-mac'      (Format-ComputerName 'My Mac')        'spaces read as separators'
Assert-Equal 'my-mac'      (Format-ComputerName 'my.mac')        'so do dots'
Assert-Equal 'work-laptop' (Format-ComputerName 'work_laptop')
Assert-Equal 'mac'         (Format-ComputerName '  Mac!  ')      'unusable characters go'
Assert-Equal 'a-b'         (Format-ComputerName 'a---b')         'runs collapse'
Assert-Equal 'mac'         (Format-ComputerName '-mac-')         'and it never starts or ends with a dash'
Assert-Equal ''            (Format-ComputerName '!!!')           'nothing usable is nothing, not a guess'

# It SUGGESTS rather than silently mangling: the old version stripped what it did not
# like, so "My Mac" quietly became "mymac" and left someone hunting for their space.
Set-Answers @('My Mac', 'y')
$n = Read-ComputerName -Prompt 'name?' -Default ''
Assert-Equal 'my-mac' $n
Assert-Match ((Get-Asked) -join '|') "Use 'my-mac'" 'the change has to be offered, not applied behind their back'

Set-Answers @('My Mac', 'n', 'mac')     # decline the suggestion, type another
Assert-Equal 'mac' (Read-ComputerName -Prompt 'name?' -Default '')

Set-Answers @('mac', 'pc')
Assert-Equal 'pc' (Read-ComputerName -Prompt 'name?' -Default '' -Taken @('mac')) 'a name in use is refused'

Set-Answers @('')
Assert-Equal '' (Read-ComputerName -Prompt 'name?' -Default '' -AllowBlank) 'blank removes, where blank is allowed'

# ---- the list corrects names without replaying the questions ------------------

Set-Answers @('2', 'macbook', '5')          # rename row 2 (no default now), then Done
$r = Read-Computers -This 'pc' -Others @('mac') -Existing
Assert-Equal 'pc'         $r.This
Assert-Equal 'pc,macbook' ($r.All -join ',') 'a rename must not disturb the rest'
Assert-NoMatch ((Get-Asked) -join '|') 'How many OTHER' 'and must not re-ask the count'

Set-Answers @('4', 'linux', '6')            # Add another; Done is row 6 once the list grows
$r = Read-Computers -This 'pc' -Others @('mac') -Existing
Assert-Equal 'pc,mac,linux' ($r.All -join ',')

Set-Answers @('2', '', '4')                 # nothing typed removes it; then 1 pc, (2), 3 Add, 4 Done
$r = Read-Computers -This 'pc' -Others @('mac') -Existing
Assert-Equal 'pc' ($r.All -join ',') 'entering nothing removes that computer'

# ---- the review rows read as one column --------------------------------------

# ", " between items, ": " after a label, "/" for things sharing one label. The
# monitors row used spaces, which meant Split-Detail could not wrap it -- so a desk
# with several panels overran the line rather than wrapping like every other row.
$script:rows = @()
function Select-One {
    param([string[]]$Items, [string[]]$Detail = @(), [int]$Default = 0, [string]$Help, [int]$Current = -1)
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($Items[$i]) { $script:rows += ('{0}|{1}' -f $Items[$i], $(if ($i -lt $Detail.Count) { $Detail[$i] } else { '' })) }
    }
    # Save, so the walkthrough ends.
    for ($i = 0; $i -lt $Items.Count; $i++) { if ($Items[$i] -eq 'Save configuration and run') { return $i } }
    return 0
}
Set-Config $CONFIGURED
Set-Answers @()
Invoke-Configure
$review = @($script:rows | Where-Object { $_ -like 'Computers|*' -or $_ -like 'Monitors|*' -or $_ -like 'Trigger devices|*' })
Assert-Match ($review -join "`n") 'Computers\|pc \(this\), mac'
Assert-Match ($review -join "`n") 'Monitors\|asus: pc/mac, lg: pc/mac' `
    'items separated by ", ", label by ": ", computers on one panel by "/" -- and pc first, as listed'

Remove-Item -LiteralPath $script:CONFIG -Force -ErrorAction SilentlyContinue
exit 0
