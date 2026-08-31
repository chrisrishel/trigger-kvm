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
    'Get-DisplayAnswers','Get-ConfiguredAnswers','Get-PriorDisplay','Read-Monitors',
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
$script:triggerPulled = $null
function Invoke-TriggerTest {
    param([string[]]$Devices, $Answers, [string]$This, [switch]$Pull)
    $script:triggerPulled = [bool]$Pull
    if ($Pull) { return [PSCustomObject]@{ Ok = $true; Text = 'fired, monitors followed' } }
    return [PSCustomObject]@{ Ok = $true; Text = 'arrival seen' }
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
          [string]$Current,[string]$ThisName,[switch]$IsMachine,[int]$Hold = 8,[string]$Config)
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

# The menu is the whole flow, so every case below is: land on the menu, pick a
# section, come back to the menu.
#
#   1 Computers  2 Monitors  3 Triggers  4 Autostart?  5 Add to PATH?
#   (6 blank)  7 Test the monitor inputs  8 Test the triggers  (9 blank)  10 Save  11 Cancel
#
# Monitors are checked BEFORE the triggers: once their values are confirmed, the
# trigger check can pull for real, which is what makes it worth doing last.
#
# The computers list is its own menu: 1..n the computers, then a blank, then Add,
# then Done.

# ---- an empty install starts on the menu, not on a questionnaire --------------

Set-Config $null
Set-Outcomes @()
Set-Answers @(
    '1',            # the cursor is already here: Computers
    'pc',           #   what this computer is called
    '1',            #   how many others
    'mac',          #   and its name
    '5',            #   the list: Done
    '2',            # back at the menu, and it lands on Monitors
    '1',            #   the list: PG42UQ
    'y','',         #     manage? / label
    '3',            #     pc  is on HDMI 1
    '1',            #     mac on HDMI 1 is now DISABLED, so this picks DisplayPort 1
    '2',            #   the list: LG ULTRAGEAR+
    'y','',         #     manage? / label
    '9','0xD0',     #     pc  -- not an MCCS value, so "Type a value..." (row 9)
    '10','0xD1',    #     mac -- 0xD0 is now a row of its own, marked assigned
    '4',            #   the list: Done
    '3',            # menu -> Triggers
    '1,3',
    '7',            # menu -> Test the monitors
    '3','y','y',    #   window: not sure; two rounds
    '8',            # menu -> Test the triggers, which may now pull for real
    '10'            # menu -> Save
)
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE 'an empty install must complete through the menu'
$c = Get-Written
Assert-Equal 'pc'   $c['computer.this']
Assert-Equal 'boot' $c['install.autostart'] 'with nothing configured, the default is from boot'
Assert-Equal 'pc'   $c['display.pg42uq.input.0x11']
Assert-Equal 'mac'  $c['display.pg42uq.input.0x0f']
Assert-Equal 'pc'   $c['display.lg.input.0xd0']
Assert-Equal 'mac'  $c['display.lg.input.0xd1']
Assert-True (-not $c.ContainsKey('display.lg.self')) 'self is gone'
Assert-Equal 'PG42UQ' $c['display.pg42uq.name'] 'the panel names come out of the EDID'

# ---- an assigned input keeps its name, its place, and cannot be taken ---------

# Answering for the second computer used to show "pc  0x11" where "HDMI 1  0x11" had
# been, and the rows moved under you. The monitor's own menu says HDMI 1.
$t = Get-InputTable -Method 'standard' -Map ([ordered]@{ pc = '0x11' })
Assert-Equal 'HDMI 1' @($t.Keys)[2] 'an assigned input keeps its own name'
Assert-Equal (@($MCCS_INPUTS.Keys) -join ',') (@($t.Keys) -join ',') 'and the list keeps its order'

# A value the channel does not list is appended, so it can be shown as assigned
# rather than silently missing.
$t = Get-InputTable -Method 'standard' -Map ([ordered]@{ pc = '0xD0' })
Assert-Equal ($MCCS_INPUTS.Count + 1) $t.Count
Assert-Equal '0xD0' @($t.Keys)[-1] 'a typed value is appended, never inserted'

# ---- it will not save half a setup -------------------------------------------

Set-Config $null
Set-Outcomes @()
Set-Answers @(
    '10',           # Save, with nothing set at all
    '11'            # ... so cancel instead
)
Invoke-Configure
Assert-Equal 1 $LASTEXITCODE 'cancelling is a non-zero exit'
Assert-Match ((Get-Asked) -join '|') 'Choice' 'it stayed on the menu rather than writing'

# ---- a configured system opens on the menu with nothing to fill in ------------

Set-Config $CONFIGURED
Set-Outcomes @()
Set-Answers @(
    '7',            # menu -> Test the monitors
    '3',            #   window: not sure
    'y','y',        #   two rounds
    '10'            # menu -> Save
)
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
Assert-NoMatch ((Get-Asked) -join '|') 'short name for it' 'a re-run must not replay the questions'
Assert-Equal 'lg-alt' (Get-Written)['display.lg.method'] 'and must keep what was configured'

# ---- finishing a section returns to the MENU ---------------------------------

# Choosing Done in the computers list used to fall through into the monitors
# questions, on the theory that a rename invalidated their maps. It does not: a
# rename is carried into every panel instead.
Set-Config $CONFIGURED
Set-Outcomes @()
Set-Answers @(
    '1',            # menu -> Computers
    '2',            #   rename row 2 (mac)
    'macbook',
    '5',            #   Done
    '10'            # straight back to the menu, and Save -- no monitor questions
)
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
Assert-NoMatch ((Get-Asked) -join '|') 'Manage this monitor' 'Done must come back to the menu'
$c = Get-Written
Assert-Equal 'macbook' $c['display.lg.input.0xd1']   'and the rename must reach every panel'
Assert-Equal 'macbook' $c['display.asus.input.0x0f']
Assert-Equal 'pc'      $c['display.lg.input.0xd0']   'without disturbing the rest'

# Removing a computer takes it out of the maps rather than leaving a dangling name.
Set-Config $CONFIGURED
Set-Outcomes @()
Set-Answers @('1', '2', '', '4', '10')      # Computers -> row 2 -> remove -> Done -> Save
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
$c = Get-Written
Assert-True (-not $c.ContainsKey('display.lg.input.0xd1')) 'a removed computer leaves no input naming it'
Assert-Equal 'pc' $c['display.lg.input.0xd0']

# ---- -Fresh empties the answers, and the menu shows that ----------------------

Set-Config $CONFIGURED
Set-Outcomes @()
Set-Answers @(
    '1','pc','1','mac','5',
    '2','1','y','','3','1','2','y','','9','0xD0','10','0xD1','4',
    '3','1,3',
    '10'                        # Save (the checks are optional)
)
Invoke-Configure -Fresh
Assert-Equal 0 $LASTEXITCODE
Assert-Match ((Get-Asked) -join '|') 'short name for it' '-Fresh must ask again'

# ---- a dialect is offered when standard does nothing -------------------------

Set-Config @($CONFIGURED | Where-Object { $_ -ne 'display.lg.method = lg-alt' })
Set-Outcomes @(3, 0)        # LG answers nothing, then works on its own channel
Set-Answers @(
    '7','3',
    'y',            #   round 1: asus fine
    'n',            #   round 2: the LG did nothing
    'y',            #   try the LG channel? yes
    '1',            #   pc  is on DisplayPort (0xD0)
    '2',            #   mac is on USB-C (0xD1)
    '10'
)
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
Assert-Equal 'lg-alt' (Get-Written)['display.lg.method'] 'the offered dialect must be recorded'

# ---- a wrong value for this computer gets walked out -------------------------

Set-Config $CONFIGURED
Set-Outcomes @(2, 0)        # the ASUS changes but never comes back
Set-Answers @(
    '7','3',
    'n',            #   round 1: the ASUS did not come back
    'n',            #   do you know which input it is? no
    'y',            #   walk the standard values (the stub answers each)
    'y',            #   round 2: the LG is fine
    '10'
)
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
Assert-Equal 'pc' (Get-Written)['display.asus.input.0x12'] 'the walk must correct the value'

# ---- two computers may not share one input -----------------------------------

Set-Config $null
Set-Outcomes @()
Set-Answers @(
    '1','pc','1','mac','5',
    '2','1',
    'y','',
    '3',            # pc on HDMI 1
    '1',            # HDMI 1 is disabled now, so this lands on DisplayPort 1
    '2','y','','9','0xD0','10','0xD1','4',
    '3','1,3',
    '10'
)
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
$c = Get-Written
Assert-Equal 'pc'  $c['display.pg42uq.input.0x11']
Assert-Equal 'mac' $c['display.pg42uq.input.0x0f'] 'the second computer had to move to a free input'

# ---- autostart can be answered "no" ------------------------------------------

# Registered but not scheduled: running now, not coming back on its own. The task
# still exists, so `trigger-kvm restart` is what starts it again.
Set-Config $CONFIGURED
Set-Outcomes @()
Set-Answers @('4', '3', '10')       # Autostart? -> no -- I will start it myself -> Save
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
Assert-Equal 'no' (Get-Written)['install.autostart'] 'the third answer has to survive the write'

# ---- the trigger check only pulls once the monitors are proven ----------------

# Pulling aims real values at real panels. Before someone has confirmed them by
# looking, that could leave the desk somewhere nobody meant -- so the check reports
# the arrival and stops there.
Set-Config $CONFIGURED
Set-Outcomes @()
Set-Answers @('8', '10')                    # Test the triggers, then Save
Invoke-Configure
Assert-Equal $false $script:triggerPulled 'unchecked monitors must not be pulled at'

Set-Config $CONFIGURED
Set-Outcomes @()
Set-Answers @('7','3','y','y', '8', '10')   # check the monitors first, then the triggers
Invoke-Configure
Assert-Equal $true $script:triggerPulled 'once they are proven, the flip back is the real thing'

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
Assert-Equal 'my-mac' (Read-ComputerName -Prompt 'name?' -Default '')
Assert-Match ((Get-Asked) -join '|') "Use 'my-mac'" 'the change has to be offered, not applied behind their back'

Set-Answers @('My Mac', 'n', 'mac')     # decline the suggestion, type another
Assert-Equal 'mac' (Read-ComputerName -Prompt 'name?' -Default '')

Set-Answers @('mac', 'pc')
Assert-Equal 'pc' (Read-ComputerName -Prompt 'name?' -Default '' -Taken @('mac')) 'a name in use is refused'

Set-Answers @('')
Assert-Equal '' (Read-ComputerName -Prompt 'name?' -Default '' -AllowBlank) 'blank removes, where blank is allowed'

# ---- the computers list reports what CHANGED ---------------------------------

Set-Answers @('2', 'macbook', '5')
$r = Read-Computers -This 'pc' -Others @('mac') -Existing
Assert-Equal 'pc,macbook' ($r.All -join ',')
Assert-Equal 'macbook'    $r.Renames['mac'] 'a rename has to be reported, so the panels can follow it'
Assert-Equal 0            @($r.Removed).Count
Assert-NoMatch ((Get-Asked) -join '|') 'How many OTHER' 'and the count is not re-asked'

Set-Answers @('4', 'linux', '6')
$r = Read-Computers -This 'pc' -Others @('mac') -Existing
Assert-Equal 'pc,mac,linux' ($r.All -join ',')
Assert-Equal 0 $r.Renames.Count 'adding renames nothing'

Set-Answers @('2', '', '4')
$r = Read-Computers -This 'pc' -Others @('mac') -Existing
Assert-Equal 'pc'  ($r.All -join ',')
Assert-Equal 'mac' ($r.Removed -join ',') 'a removal has to be reported too'

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
