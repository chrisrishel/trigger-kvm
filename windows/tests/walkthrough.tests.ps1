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

Import-Subject -Script 'install.ps1' -Variables @('DIALECTS','MCCS_INPUTS','NAME_RULE','BACK','RENAMED_KEYS') -Functions @(
    'Read-Default','Read-YesNo','Get-MenuWidth','Write-MenuFrame','Clear-ToLineEnd',
    'Split-Detail','Get-ItemWidth','Get-MenuRow',
    'Select-One','Select-Many','Join-Names','Get-InputName',
    'Get-DefaultComputerName','Get-KnownComputers','Read-Computers','Read-ComputerRemovals',
    'Edit-PanelMaps','Format-Name','Read-Name',
    'Format-Byte','Read-InputValue','Get-InputTable','Get-DisplayMap','Read-Method',
    'Get-DisplayAnswers','Get-ConfiguredAnswers','Get-PriorDisplay','Read-Monitors',
    'Invoke-DisplayTest','Invoke-TestRound','Invoke-TestRoundBody','Test-OneComputer',
    'Test-DisplayInput','Test-OneValue','Invoke-BlindWalk',
    'Read-Triggers','Read-Tier','Read-PathChoice','Get-CandidateLabel',
    'Invoke-Configure','Get-CarriedKeys','Write-ConfigFile')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'config.ps1')

# ---- the machine this suite pretends to be sitting at ------------------------

$script:CONFIG = Join-Path $env:TEMP 'trigger-kvm-tests.cfg'
$global:CONFIG = $script:CONFIG
$global:BINDIR = 'C:\fake\bin'
$global:DEFAULT_DEBOUNCE = '3.0'
$global:DEFAULT_SETTLE   = '0.75'
$global:SWITCH = Join-Path (Split-Path -Parent $PSScriptRoot) 'trigger-kvm.ps1'
$global:Relaunched = $false

function Add-ToUserPath { param([string]$Dir) }
# Whether this account could elevate at all. The real one reads this process's
# token, so it answers differently depending on who runs the suite; what the
# walkthrough does with each answer is the thing worth pinning.
$script:canElevate = $true
function Test-CanElevate { return $script:canElevate }
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
    # Backed too, like the real one: specs/configure.md 4.2 gives a check THREE
    # outcomes, and reading a property that is not there is a StrictMode throw.
    if ($Pull) { return [PSCustomObject]@{ Ok = $true; Backed = $false; Text = 'fired, monitors followed' } }
    return [PSCustomObject]@{ Ok = $true; Backed = $false; Text = 'arrival seen' }
}

# The panels, as reported by `list -Raw`. Not read from hardware: a test that
# only passes on one desk is not a test. A variable rather than a literal, so a
# case can put a THIRD monitor on the desk -- two never exercise the row
# arithmetic in the Monitors list.
$script:panels = @('06B3|42E0|AUS|HDMI|01010101|PG42UQ',
                   '1E6D|9E9D|GSM|DisplayPort|00001111|LG ULTRAGEAR+')
function Invoke-Sibling {
    param([string]$Script, [string[]]$Arguments)
    if ($Arguments -contains 'list') { return $script:panels }
    return @()
}

# 0 = showed the right machine and came back, 1 = showed something else,
# 2 = changed but did not come back, 3 = nothing happened.
$script:outcomes = @()
function Set-Outcomes { param([int[]]$O) $script:outcomes = @($O) }
# [CmdletBinding()], like the real one: a SIMPLE stub swallows an undeclared
# named argument into $args, so a caller left on an old parameter name keeps
# passing here while losing the switch. Verified by mutation -- without this the
# -IsMachine -> -IsComputer rename went green with the wrong question being asked.
function Test-DisplayInput {
    [CmdletBinding()]
    param([string]$Label,[string]$Name,[string]$Candidate,[string]$CandidateName,
          [string]$Current,[string]$ThisName,[switch]$IsComputer,[int]$Hold = 8,[string]$Config)
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
    '6',            #   the list: Done (Add is 4, Remove a computer is 5)
    '2',            # back at the menu, and it lands on Monitors
    '1',            #   the list: PG42UQ
    'y','',         #     manage? / label
    '3',            #     pc  is on HDMI 1
    '1',            #     mac on HDMI 1 is now DISABLED, so this picks DisplayPort 1
    '2',            #   the list: LG ULTRAGEAR+
    'y','',         #     manage? / label
    '1',            #     how to talk to it: Standard. Asked because LG has a
                    #     documented alternative; the ASUS above was not asked.
    '9','0xD0',     #     pc  -- not an MCCS value, so "Type a value..." (row 9)
    '10','0xD1',    #     mac -- 0xD0 is now a row of its own, marked assigned
    '4',            #   the list: Done
    '3',            # menu -> Triggers
    '1,3',
    '4','1',        # menu -> Autostart? -- not preset, so it must be answered
    '5','1',        # menu -> Add to PATH? -- likewise
    '7',            # menu -> Test the monitor inputs
    '1',            #   which monitor to check -> All of them
    '','y','','y',  #   two rounds: 'enter when ready', then the answer
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
Assert-True (-not $c.Contains('display.lg.self')) 'self is gone'
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
    '7',            # menu -> Test the monitor inputs
    '1',            #   All of them
    '','y','','y',  #   two rounds
    '5','1',        # menu -> Add to PATH? (never preset)
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
    '6',            #   Done
    '5','1',        # menu -> Add to PATH?
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
# Computers -> Remove a computer -> mac -> confirm -> Done -> Done -> PATH -> Save
Set-Answers @('1', '5', '1', 'y', '5', '5','1', '10')
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
$c = Get-Written
Assert-True (-not $c.Contains('display.lg.input.0xd1')) 'a removed computer leaves no input naming it'
Assert-Equal 'pc' $c['display.lg.input.0xd0']

# ---- the PATH row is drawn even when there is nothing to decide ---------------

# It used to be omitted when bin\ was already on PATH, which moved every row below
# it and left the cursor apparently skipping a step -- with no way to tell whether
# PATH had been handled or forgotten. Reported as "it doesn't advance to add to
# path", and the behaviour was right; the display was not.
$global:TestUserPath = 'C:\Windows;C:\fake\bin'      # already there
Set-Config $CONFIGURED
Set-Outcomes @()
Set-Answers @('10')                                     # Save at once; nothing to answer
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE 'an already-on-PATH install has nothing left to answer'
$asked = (Get-Asked) -join '|'
Assert-NoMatch $asked 'Add .* to your PATH' 'and must not ask about it'

# ---- ...and no row in the Monitors list is unpickable ------------------------
#
# Read-Monitors passed `-Disabled $off`, and $off is not assigned in it: it
# resolved by DYNAMIC SCOPE to Invoke-Configure's, which holds the PATH row's
# index whenever that row is disabled. With THREE monitors and bin\ already on
# PATH, index 4 in the Monitors list is `Done` -- drawn `--`, skipped by the
# cursor, reachable only by esc. Two-monitor desks never saw it, and
# Set-StrictMode does not catch a variable that resolves in a parent scope. So
# it takes all three conditions at once to reproduce.
$global:TestUserPath = 'C:\Windows;C:\fake\bin'          # so the PATH row is disabled
$script:panels = @('06B3|42E0|AUS|HDMI|01010101|PG42UQ',
                   '1E6D|9E9D|GSM|DisplayPort|00001111|LG ULTRAGEAR+',
                   '10AC|A0B1|DEL|HDMI|02020202|DELL U2720Q')
Set-Config $CONFIGURED
Set-Outcomes @()
Set-Answers @(
    '2',            # menu -> Monitors
    '5',            #   the list: PG42UQ(1) LG(2) DELL(3) (4 blank) Done(5)
    '10'            # menu -> Save
)
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE 'Done must be reachable with three monitors and bin\ on PATH'
$c = Get-Written
Assert-Equal 'lg-alt' $c['display.lg.method'] 'and looking at the list changes nothing'
Assert-True (-not $c.Contains('display.dell.vendor')) 'the unmanaged third panel stays unmanaged'

$script:panels = @('06B3|42E0|AUS|HDMI|01010101|PG42UQ',
                   '1E6D|9E9D|GSM|DisplayPort|00001111|LG ULTRAGEAR+')
$global:TestUserPath = 'C:\Windows'                      # back to not-on-PATH

# ---- backing out of a submenu changes nothing ---------------------------------

# Esc in a real terminal; 'q' in the typed fallback these tests drive. Either way it
# means "back, and change nothing" -- not "clear this section".
Set-Config $CONFIGURED
Set-Outcomes @()
Set-Answers @(
    '3',            # menu -> Triggers
    'q',            #   back out without touching the selection
    '1',            # menu -> Computers
    'q',            #   likewise
    '2',            # menu -> Monitors
    'q',
    '4','q',        # menu -> Autostart?, back
    '5','1',        # menu -> Add to PATH? (never preset, so answer it)
    '10'            # menu -> Save
)
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
$c = Get-Written
Assert-Equal 'usb:046d:0843, usb:1235:820a' $c['trigger.device'] 'the triggers are as they were'
Assert-Equal 'pc'     $c['computer.this']
Assert-Equal 'mac'    $c['display.lg.input.0xd1'] 'and so are the monitors'
Assert-Equal 'login'  $c['install.autostart']     'and autostart kept its configured value'

# The main menu is deliberately NOT escapable: it has Cancel, and a setup should not
# be discarded by a stray keypress.
Set-Config $CONFIGURED
Set-Answers @('q', '11')
Invoke-Configure
Assert-Equal 1 $LASTEXITCODE
Assert-Match ((Get-Asked) -join '|') 'Choice' 'q was refused there, and Cancel was needed'

# ---- -Fresh empties the answers, and the menu shows that ----------------------

Set-Config $CONFIGURED
Set-Outcomes @()
Set-Answers @(
    '1','pc','1','mac','6',
    '2','1','y','','3','1','2','y','','1','9','0xD0','10','0xD1','4',
    '3','1,3',
    '4','1', '5','1',           # autostart and PATH must be answered
    '10'                        # Save (the checks are optional)
)
Invoke-Configure -Fresh
Assert-Equal 0 $LASTEXITCODE
Assert-Match ((Get-Asked) -join '|') 'short name for it' '-Fresh must ask again'

# ---- the method is offered UP FRONT, for a vendor that has one ---------------
#
# specs/configure.md 6.2. Offered, never probed -- nothing is sent to find out.
# Before the input questions, because the values on offer depend on the answer.

function Write-Host { param([Parameter(ValueFromPipeline=$true)]$Object, [switch]$NoNewline)
    Add-Printed -Object $Object -NoNewline:$NoNewline
}
function Get-Said { return (Get-Printed) }
function Reset-Said { Reset-Printed }

# A vendor with nothing documented is not asked at all. The question would have one
# real answer, and a menu with one answer is a question that should not be asked.
Reset-Said; Set-Answers @()
Assert-Equal 'standard' (Read-Method -Vendor 0x06B3 -Current 'standard')
Assert-NoMatch (Get-Said) 'how to talk to this monitor' 'no alternative, no question'

Reset-Said; Set-Answers @('1')
Assert-Equal 'standard' (Read-Method -Vendor 0x1E6D -Current 'standard') 'standard is row 1'
$said = Get-Said
Assert-Match $said '--- how to talk to this monitor ---'
Assert-Match $said 'including most LG ones' 'the vendor comes from the table, not from a model'
Assert-Match $said 'the check further down will offer you this again' `
    'and it says the check will ask again, because it will'
Assert-Match $said 'what nearly every monitor takes'
Assert-Match $said "LG's own method"
Assert-Match $said 'Standard\s+what nearly every monitor takes\s+\(current\)' `
    'standard is marked as the current answer, not merely pre-selected'
Assert-Match ((Get-Asked) -join '|') 'Choice \[1\]' `
    'and standard is the default, so the cursor starts there'

# THE CONSEQUENCE, NAMED WHERE THE CHOICE IS MADE -- specs/configure.md 6.2.
# This is the moment a person commits to a service channel, and the rules that
# keep it safe live in AGENTS.md, which a user never opens. Three lines here are
# the only warning they get.
Assert-Match $said "LG's own method talks to a service channel on the monitor\. It is"
Assert-Match $said 'sent only the values written down for it: unknown values on that'
Assert-Match $said 'channel have made monitors unusable\.'
Assert-NoMatch $said '!' 'no exclamation mark: a person about to lose a monitor wants the facts'

Reset-Said; Set-Answers @('2')
Assert-Equal 'lg-alt' (Read-Method -Vendor 0x1E6D -Current 'standard') 'row 2 is the manufacturer one'

# An existing method is a settled answer -- somebody proved it by watching a screen.
Reset-Said; Set-Answers @('2')
Assert-Equal 'lg-alt' (Read-Method -Vendor 0x1E6D -Current 'lg-alt') 'and it survives a re-run'
Assert-Match ((Get-Asked) -join '|') 'Choice \[2\]' 'a configured method keeps the cursor'
Assert-Match (Get-Said) "own method\s+for LG.*\(current\)" 'and is marked, not merely pre-selected'

# ---- esc leaves a panel's questions, and changes nothing ---------------------
#
# specs/configure.md 3.3's first row: a submenu you entered from somewhere returns
# there, changing nothing. A panel's questions are entered from the Monitors list.
#
# This shipped twice wrong. First esc resolved to "keep the current method and
# carry on" -- with the cursor already on the current row that is byte for byte
# what enter does, so esc appeared to ADVANCE the walkthrough. Then esc was taken
# away entirely, which left it dead on the one menu people press it on hardest,
# and would have been inconsistent one keystroke later anyway.

Reset-Said; Set-Answers @('q')
Assert-Equal 'back' (Read-Method -Vendor 0x1E6D -Current 'lg-alt') `
    'esc backs out rather than answering'

# Backing out of the METHOD question abandons the whole panel...
Reset-Said; Set-Answers @('y', 'lg', 'q')
$a = Get-DisplayAnswers -Found ([PSCustomObject]@{
        EdidVendor = 0x1E6D; EdidProduct = 0x9E9D; Name = 'LG ULTRAGEAR+'
        Mfg = 'GSM'; Connector = 'DisplayPort' }) `
     -Existing $null -Computers @('pc','mac') -This 'pc'
Assert-Equal 'back' $a 'and it propagates out of the panel, not just the question'

# ...and so does backing out of an INPUT question, one keystroke later. Esc that
# works on one screen and is dead on the next is worse than either.
Reset-Said; Set-Answers @('y', 'lg', '1', 'q')
$a = Get-DisplayAnswers -Found ([PSCustomObject]@{
        EdidVendor = 0x1E6D; EdidProduct = 0x9E9D; Name = 'LG ULTRAGEAR+'
        Mfg = 'GSM'; Connector = 'DisplayPort' }) `
     -Existing $null -Computers @('pc','mac') -This 'pc'
Assert-Equal 'back' $a 'half a map is not an answer'

# THE ONE THAT MATTERS. "Backed out" and "no, do not manage this monitor" must not
# be the same outcome: Read-Monitors REMOVES a panel on the second, so if esc
# resolved to the same thing it would silently unmanage a working monitor -- the
# exact opposite of "changing nothing".
Set-Config $CONFIGURED
Set-Outcomes @()
Set-Answers @(
    '2',            # menu -> Monitors
    '2',            #   the LG, which is configured
    'y', '', 'q',   #   manage? / label / esc at the method question
    '4',            #   the monitors list: Done
    '5','1',        # menu -> Add to PATH?
    '10'            # Save
)
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
$c = Get-Written
Assert-Equal 'lg-alt' $c['display.lg.method']    'backing out must leave the panel exactly as it was'
Assert-Equal 'pc'     $c['display.lg.input.0xd0']
Assert-Equal 'mac'    $c['display.lg.input.0xd1']
Assert-Equal 'pc'     $c['display.asus.input.0x11'] 'and must not disturb the others'

# Whereas answering "no" still takes it out, which is the outcome esc must not be
# confused with -- but it now says what it is about to forget, and asks again.
#
# specs/configure.md 6. "Manage this monitor?" reads like a flag and the answer is
# destructive: it discards which computer is on which input. Same rule as removing
# a computer, which is the symmetry worth having between the two menus.
Set-Config $CONFIGURED
Set-Outcomes @()
Reset-Printed
Set-Answers @('2', '2', 'n', 'y', '4', '5','1', '10')
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
$c = Get-Written
Assert-True (-not $c.Contains('display.lg.method')) '"no", confirmed, removes the panel'
Assert-Equal 'pc' $c['display.asus.input.0x11']       'and only that panel'
$said = Get-Printed
Assert-Match $said 'Which computer is on which of its inputs is forgotten\. Nothing else'
Assert-MatchCase ((Get-Asked) -join '|') 'Stop managing this monitor\? \[y/N\]' `
    'and the confirm defaults to no'

# Declining the confirm keeps the panel exactly as it was.
Set-Config $CONFIGURED
Set-Outcomes @()
Set-Answers @('2', '2', 'n', 'n', '4', '5','1', '10')
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
$c = Get-Written
Assert-Equal 'lg-alt' $c['display.lg.method']       'declining the confirm changes nothing'
Assert-Equal 'mac'    $c['display.lg.input.0xd1']

# A panel with NOTHING configured has nothing to forget, so it is not asked twice.
# Asked of Get-DisplayAnswers directly: driving this through Invoke-Configure does
# not reach it, because a panel dropped from the working set still has its map in
# the CONFIG until Save, and Read-Monitors falls back to that -- which is right,
# and is exactly why the guard reads $Existing rather than the working set.
$LG = [PSCustomObject]@{ EdidVendor = 0x1E6D; EdidProduct = 0x9E9D
                         Name = 'LG ULTRAGEAR+'; Mfg = 'GSM'; Connector = 'DisplayPort' }

Reset-Printed; Set-Answers @('n')
$a = Get-DisplayAnswers -Found $LG -Existing $null -Computers @('pc','mac') -This 'pc'
Assert-Equal $null $a 'a panel with nothing configured is simply not managed'
Assert-NoMatch ((Get-Asked) -join '|') 'Stop managing this monitor' 'and is not asked twice'

# One that HAS assignments is asked, and declining leaves it alone.
Reset-Printed; Set-Answers @('n', 'n')
$a = Get-DisplayAnswers -Found $LG -Computers @('pc','mac') -This 'pc' `
        -Existing ([PSCustomObject]@{ Label = 'lg'; Method = 'lg-alt'
                                      Map = [ordered]@{ pc = '0xD0'; mac = '0xD1' } })
Assert-Equal 'back' $a 'declining the confirm leaves the panel as it was'
Assert-Match ((Get-Asked) -join '|') 'Stop managing this monitor' 'and it was asked'
Assert-Match (Get-Printed) 'is forgotten\. Nothing else' 'with the loss named first'

# ---- and it lands between the short name and the inputs ----------------------

# The ORDER is the point: after the name, before any input, because the values on
# offer depend on which method is chosen. Asking it afterwards would mean offering
# values from the wrong channel and then discarding the answers.
Reset-Said
Set-Answers @('y', 'lg', '2', '1', '2')   # manage / label / LG's method / two inputs
$a = Get-DisplayAnswers -Found ([PSCustomObject]@{
        EdidVendor = 0x1E6D; EdidProduct = 0x9E9D; Name = 'LG ULTRAGEAR+'
        Mfg = 'GSM'; Connector = 'DisplayPort' }) `
     -Existing $null -Computers @('pc','mac') -This 'pc'
Assert-Equal 'lg-alt' $a.Method
$asked = (Get-Asked) -join '|'
Assert-Match $asked 'Short name for it.*Choice' 'the method question comes after the short name'
$said = Get-Said
Assert-Match $said '(?s)how to talk to this monitor.*which input is'
Assert-Match $said '0xD0' 'and the inputs offered are the chosen channel''s'
Assert-Equal '0xD0' $a.Map['pc'] 'so the values recorded are that channel''s too'

# ---- a dialect is offered when standard does nothing -------------------------

Set-Config @($CONFIGURED | Where-Object { $_ -ne 'display.lg.method = lg-alt' })
Set-Outcomes @(3, 0)        # LG answers nothing, then works on its own channel
Set-Answers @(
    '7','1',
    '','y',         #   round 1: asus fine
    '','n',         #   round 2: the LG did nothing
    '1',            #   try the LG channel? yes (a menu now, not a y/n)
    '1',            #   pc  is on DisplayPort (0xD0)
    '2',            #   mac is on USB-C (0xD1)
    '5','1',
    '10'
)
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
Assert-Equal 'lg-alt' (Get-Written)['display.lg.method'] 'the offered dialect must be recorded'

# ---- a wrong value for this computer gets walked out -------------------------

Set-Config $CONFIGURED
Set-Outcomes @(2, 0)        # the ASUS changes but never comes back
Set-Answers @(
    '7','1',
    '','n',         #   round 1: the ASUS did not come back
    'n',            #   do you know which input it is? no
    'y',            #   walk the standard values (the stub answers each)
    '','y',         #   round 2: the LG is fine
    '5','1',
    '10'
)
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
Assert-Equal 'pc' (Get-Written)['display.asus.input.0x12'] 'the walk must correct the value'

# ---- two computers may not share one input -----------------------------------

Set-Config $null
Set-Outcomes @()
Set-Answers @(
    '1','pc','1','mac','6',
    '2','1',
    'y','',
    '3',            # pc on HDMI 1
    '1',            # HDMI 1 is disabled now, so this lands on DisplayPort 1
    '2','y','','1','9','0xD0','10','0xD1','4',
    '3','1,3',
    '4','1', '5','1',
    '10'
)
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
$c = Get-Written
Assert-Equal 'pc'  $c['display.pg42uq.input.0x11']
Assert-Equal 'mac' $c['display.pg42uq.input.0x0f'] 'the second computer had to move to a free input'

# ---- typing a value onto a manufacturer channel is warned about first --------
#
# specs/configure.md 6.1. 6.2 named what the channel is; a TYPED byte is the one
# thing that reaches it from outside the documented table, and AGENTS.md hard
# rule 1 permits that only because the person typing it is the one who has to
# know where it came from.

Reset-Printed; Set-Answers @('5', '0xD0')     # Type a value... on the LG channel
$v = Read-InputValue -Table (Get-InputTable -Method 'lg-alt' -Map $null) `
                     -Method 'lg-alt' -Prompt 'which input?'
Assert-Equal '0xD0' $v
$said = Get-Printed
Assert-Match $said "This is the manufacturer's service channel\. Type only a value you have"
Assert-Match $said 'from documentation; an unknown value here has made monitors unusable\.'

# ...and NOT on the standard one, where a typed value is ordinary. Saying it
# everywhere would make it read as boilerplate exactly where it is not.
Reset-Printed; Set-Answers @('9', '0x11')
$null = Read-InputValue -Table (Get-InputTable -Method 'standard' -Map $null) `
                        -Method 'standard' -Prompt 'which input?'
Assert-NoMatch (Get-Printed) 'service channel' 'the standard channel is not a service channel'

# Picking a LISTED value on the manufacturer channel is not typing one: those
# values ARE the documented table.
Reset-Printed; Set-Answers @('1')
$null = Read-InputValue -Table (Get-InputTable -Method 'lg-alt' -Map $null) `
                        -Method 'lg-alt' -Prompt 'which input?'
Assert-NoMatch (Get-Printed) 'Type only a value you have' 'the warning is about typing, not about the channel'

# ---- two monitors cannot share one short name --------------------------------
#
# specs/configure.md 6, revision 6 item 3. Two Dell panels both default to
# `dell`; accepting both writes display.dell.* twice, and the reader merges them
# into one panel with a union map -- which the switcher then refuses to act on,
# without saying why. Refused here, where the person can still say what they
# meant.
$script:panels = @('06B3|42E0|AUS|HDMI|01010101|Dell U2720Q',
                   '10AC|A0B1|DEL|DisplayPort|02020202|Dell U2723QE')
Set-Config $null
Set-Outcomes @()
Reset-Printed
Set-Answers @(
    '1','pc','1','mac','6',
    '2','1',            # Monitors -> the first Dell
    'y','',             #   manage / keep the suggested short name `dell`
    '3','1',            #   pc on HDMI 1, mac on DisplayPort 1
    '2',                # Monitors -> the second Dell
    'y',                #   manage
    '',                 #   ...which also suggests `dell`, and is refused
    'dell-2',           #   so a different one is typed
    '3','1',
    '4',                # Monitors -> Done
    '3','1,3', '4','1', '5','1',
    '10'
)
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
Assert-Match (Get-Printed) 'There is already a monitor called dell\.'
$c = Get-Written
Assert-Equal 'pc' $c['display.dell.input.0x11']
Assert-Equal 'pc' $c['display.dell-2.input.0x11'] 'the second panel is its own panel, not a merge'

# Re-opening a panel is not a clash with ITSELF: keeping the name it has must be
# allowed, or a re-run could never leave a monitor alone.
Set-Outcomes @()
Set-Answers @('2', '1', 'y', '', '3', '1', '4', '5','1', '10')
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE 'a panel may keep its own short name'
Assert-Equal 'pc' (Get-Written)['display.dell.input.0x11']

$script:panels = @('06B3|42E0|AUS|HDMI|01010101|PG42UQ',
                   '1E6D|9E9D|GSM|DisplayPort|00001111|LG ULTRAGEAR+')

# ---- the walkthrough and the switcher agree about what a value is ------------
#
# specs/config-format.md "Value parsing", specs/configure.md 6.1. The walkthrough
# carried three regexes of its own and each disagreed with the reader in a
# different direction, so a saved config was not the setup the person had been
# shown. All three sites now go through config.ps1's converters.

# A TYPED value is stored canonically, so `17` and the listed `0x11` are one
# socket rather than two rows that both claim it.
Set-Config $null
Set-Outcomes @()
Set-Answers @(
    '1','pc','1','mac','6',
    '2','1',            # Monitors -> PG42UQ
    'y','',             #   manage / label
    '9','17',           #   pc: Type a value... -> decimal 17
    '1',                #   mac: DisplayPort 1 (HDMI 1 is now taken by pc)
    '2','y','','1',     #   the LG, standard
    '1','2',
    '4',                #   Monitors -> Done
    '3','1,3', '4','1', '5','1',
    '10'
)
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
$c = Get-Written
Assert-Equal 'pc' $c['display.pg42uq.input.0x11'] 'a typed 17 is written as the canonical 0x11'
Assert-True (-not $c.Contains('display.pg42uq.input.17')) 'and never in the spelling it was typed in'
Assert-Equal 'mac' $c['display.pg42uq.input.0x0f'] 'so the next computer had to take a different input'

# A bare hex byte is what the READER drops, so the walkthrough must refuse it
# rather than saving a line that quietly does nothing.
Reset-Printed
Set-Answers @('9', 'd1', '3')       # Type a value... -> refused -> HDMI 1
$v = Read-InputValue -Table (Get-InputTable -Method 'standard' -Map $null) `
                     -Prompt 'which input?'
Assert-Equal '0x11' $v
Assert-Match (Get-Printed) 'Not a byte' 'a bare d1 is not a byte, whatever it looks like'

# ...and a 3-digit decimal IS one, which the old regex refused.
Set-Answers @('9', '200')
Assert-Equal '0xC8' (Read-InputValue -Table (Get-InputTable -Method 'standard' -Map $null) -Prompt 'which input?')

# A HAND-EDITED config in any spelling the reader accepts is VISIBLE here, and
# survives Save. Matched on hex alone it was invisible to the walkthrough and
# gone after the next Save, while the switcher went on acting on it.
Set-Config @(
 'computer.this = pc'
 'display.lg.vendor = 0x1E6D','display.lg.product = 0x9E9D','display.lg.name = LG ULTRAGEAR+'
 'display.lg.method = lg-alt'
 'display.lg.input.0xd0 = pc','display.lg.input.0xd1 = mac'
 'display.asus.vendor = 1715','display.asus.product = 17120'   # 0x06B3 / 0x42E0, in decimal
 'display.asus.name = PG42UQ','display.asus.method = standard'
 'display.asus.input.17 = pc','display.asus.input.15 = mac'    # 0x11 / 0x0F, in decimal
 'trigger.device = 046d:0843','install.autostart = login'
)
Set-Outcomes @()
Set-Answers @('5','1', '10')        # nothing to change: PATH, then Save
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
$c = Get-Written
Assert-Equal 'pc'  $c['display.asus.input.0x11'] 'a decimal input key is read, and rewritten canonically'
Assert-Equal 'mac' $c['display.asus.input.0x0f']
Assert-Equal 'PG42UQ' $c['display.asus.name'] `
    'and a decimal EDID id still matches the panel, so it is not silently unmanaged'

# ---- From boot is drawn for everyone, and disabled where it cannot work ------
#
# specs/configure.md 8. On a STANDARD account `-Verb RunAs` does not raise a
# consent prompt -- it raises a CREDENTIAL prompt for a different account, and
# everything the resulting process installs belongs to that account. So the row
# is drawn, says why in its detail, and the cursor passes over it. Hidden, the
# menu would change shape between machines and the question it raises would go
# unanswered.

Reset-Printed; $script:canElevate = $true
Set-Answers @('1')
Assert-Equal 's4u' (Read-Tier 'user') 'an account that can elevate may choose it'
$said = Get-Printed
Assert-Match $said 'From boot'
Assert-NoMatch $said 'needs an administrator account' 'and is not told it cannot'

Reset-Printed; $script:canElevate = $false
Set-Answers @('1', '2')     # From boot is unpickable, so try again with From login
Assert-Equal 'user' (Read-Tier '')
$said = Get-Printed
Assert-Match $said 'From boot'                     'the row is still drawn'
Assert-Match $said 'needs an administrator account' 'and says why it is not available'
Assert-Match $said '-- From boot'                   'drawn unnumbered, so it cannot be picked'
Assert-Match ((Get-Asked) -join '|') 'Choice \[2\]' 'and the cursor does not start on it'

Reset-Printed; $script:canElevate = $true

# ---- autostart can be answered "no" ------------------------------------------

# Registered but not scheduled: running now, not coming back on its own. The task
# still exists, so `trigger-kvm restart` is what starts it again.
Set-Config $CONFIGURED
Set-Outcomes @()
Set-Answers @('4', '3', '5','1', '10')   # Autostart? -> no -> PATH -> Save
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
Assert-Equal 'no' (Get-Written)['install.autostart'] 'the third answer has to survive the write'

# ---- the trigger check only pulls once the monitors are proven ----------------

# Pulling aims real values at real panels. Before someone has confirmed them by
# looking, that could leave the desk somewhere nobody meant -- so the check reports
# the arrival and stops there.
Set-Config $CONFIGURED
Set-Outcomes @()
Set-Answers @('8', '5','1', '10')           # Test the triggers, PATH, then Save
Invoke-Configure
Assert-Equal $false $script:triggerPulled 'unchecked monitors must not be pulled at'

Set-Config $CONFIGURED
Set-Outcomes @()
Set-Answers @('7','1','','y','','y', '8', '5','1', '10')   # monitors, then triggers
Invoke-Configure
Assert-Equal $true $script:triggerPulled 'once they are proven, the flip back is the real thing'

# ---- backing out of a check is neither a pass nor a failure ------------------
#
# specs/configure.md 4.2. Its row reads `not checked` and the cursor moves ON to
# the next unfinished thing, as if the check had not been opened. Landing on
# Monitors would say "you got the monitors wrong" to someone who only declined to
# move them.
#
# Where the cursor lands is read off the Choice prompt's default. bin\ is on
# PATH for these two, so that row is answered and the checks are what is left --
# otherwise the cursor lands on PATH both times and the case proves nothing.
$global:TestUserPath = 'C:\Windows;C:\fake\bin'
Set-Config $CONFIGURED
Set-Outcomes @()
Set-Answers @(
    '7',            # menu -> Test the monitor inputs
    'q',            #   ...and back out of "which monitor?"
    '11'            # menu -> Cancel, whatever the cursor was on
)
Invoke-Configure
$asked = (Get-Asked) -join '|'
# Row 8 is Test the triggers: the next unfinished thing, NOT row 2 (Monitors).
Assert-Match   $asked 'Choice \[8\]' 'the cursor moves on to the next check'
Assert-NoMatch $asked 'Choice \[2\]' 'and does not blame the monitors for a check nobody ran'

# A check that actually FAILED still sends the cursor to the setting that failed.
# The ASUS answers nothing and has no documented alternative, so that is the end
# of it; the LG round then passes, which is what leaves exactly one failure.
Set-Config $CONFIGURED
Set-Outcomes @(3)
Set-Answers @('7', '1', '', 'n', '', 'y', '11')
Invoke-Configure
Assert-Match ((Get-Asked) -join '|') 'Choice \[2\]' 'a failure does land on Monitors'

$global:TestUserPath = 'C:\Windows'

# ---- a hand-edited key nobody asked about survives Save ----------------------
#
# specs/config-format.md, "Hand edits survive". An unknown key is someone's hand
# edit or a newer version's setting, and dropping it on Save is a silent loss
# with no way to notice. Only trigger.debounce and trigger.settle used to survive.
Set-Config (@($CONFIGURED) + @(
    'trigger.debounce = 5.5'
    'some.future.setting = 42'
    'display.lg.brightness = 80'         # unknown, on a panel that stays managed
    'display.gone.vendor = 0x1234'       # a panel nothing enumerates
    'display.gone.wallpaper = blue'
))
Set-Outcomes @()
Set-Answers @('5','1', '10')
Invoke-Configure
Assert-Equal 0 $LASTEXITCODE
$c = Get-Written
Assert-Equal '42'  $c['some.future.setting']   'an unknown key is carried across'
Assert-Equal '80'  $c['display.lg.brightness'] 'including one under a panel that is still managed'
Assert-Equal '5.5' $c['trigger.debounce']      'and a hand-set timing still survives'
Assert-Equal 'login' $c['install.autostart']   'while a key the walkthrough writes is written, not carried'

# A panel the walkthrough is not managing takes its unknown keys with it:
# unmanaging is the one answer that means "forget", and it forgets the panel.
Assert-True (-not $c.Contains('display.gone.wallpaper')) 'an unmanaged panel is forgotten whole'
Assert-True (-not $c.Contains('display.gone.vendor'))

# A superseded spelling is NOT an unknown key -- it is the same fact under an
# older name, and carrying it would leave two answers to one question in the file.
Set-Config (@($CONFIGURED) + @('install.start = boot', 'trigger.usb.settle = 9'))
Set-Outcomes @()
Set-Answers @('5','1', '10')
Invoke-Configure
$c = Get-Written
Assert-True (-not $c.Contains('install.start'))      'an old key name is rewritten, not kept beside the new one'
Assert-True (-not $c.Contains('trigger.usb.settle'))
Assert-Equal 'login' $c['install.autostart']

# ---- what a computer, OR A MONITOR, may be called ----------------------------

# One name, not a slug plus a display name: it is a config value, a thing you type
# at a prompt, and a label in every message. The rule exists so it survives all three.
# specs/configure.md 6 gives a monitor's short name the SAME rule, by pointing at
# 5.1 rather than restating it -- so there is one function, with two nouns.
Assert-Equal 'mac'         (Format-Name 'Mac')
Assert-Equal 'my-mac'      (Format-Name 'My Mac')        'spaces read as separators'
Assert-Equal 'my-mac'      (Format-Name 'my.mac')        'so do dots'
Assert-Equal 'work-laptop' (Format-Name 'work_laptop')
Assert-Equal 'mac'         (Format-Name '  Mac!  ')      'unusable characters go'
Assert-Equal 'a-b'         (Format-Name 'a---b')         'runs collapse'
Assert-Equal 'mac'         (Format-Name '-mac-')         'and it never starts or ends with a dash'
Assert-Equal ''            (Format-Name '!!!')           'nothing usable is nothing, not a guess'

# It SUGGESTS rather than silently mangling: the old version stripped what it did not
# like, so "My Mac" quietly became "mymac" and left someone hunting for their space.
Set-Answers @('My Mac', 'y')
Assert-Equal 'my-mac' (Read-Name -Prompt 'name?' -Default '')
Assert-Match ((Get-Asked) -join '|') "Use 'my-mac'" 'the change has to be offered, not applied behind their back'

Set-Answers @('My Mac', 'n', 'mac')     # decline the suggestion, type another
Assert-Equal 'mac' (Read-Name -Prompt 'name?' -Default '')

Reset-Printed; Set-Answers @('mac', 'pc')
Assert-Equal 'pc' (Read-Name -Prompt 'name?' -Default '' -Taken @('mac')) 'a name in use is refused'
Assert-Match (Get-Printed) 'There is already a computer called mac\.'

# The same function, the same rule, a different noun -- and a different refusal,
# because both are normative wording.
Reset-Printed; Set-Answers @('lg', 'asus')
Assert-Equal 'asus' (Read-Name -Prompt 'Short name for it' -Default '' -Taken @('lg') -Noun 'monitor')
Assert-Match   (Get-Printed) 'There is already a monitor called lg\.'
Assert-NoMatch (Get-Printed) 'already a computer' 'a monitor is not told it clashes with a computer'

# A BLANK ANSWER KEEPS THE DEFAULT, here as everywhere -- specs 5.0. There is no
# -AllowBlank any more: it existed for a rename prompt whose blank meant REMOVE,
# which revision 5 replaced with a row of its own.
Set-Answers @('')
Assert-Equal 'mac' (Read-Name -Prompt 'name?' -Default 'mac') 'enter keeps what is there'
Assert-True (-not (Get-Command Read-Name).Parameters.ContainsKey('AllowBlank')) `
    'and the parameter that used to make blank destructive is gone'

# ---- the computers list carries every edit into the panels' maps -------------

# specs/configure.md 5.2. The maps are edited AS THE ROW IS CHOSEN, not inferred
# afterwards by lining the old list of computers up against the new one. That
# inference was the bug: a removal shifts every position after it, so the computer
# that slid into the victim's slot was recorded as its NEW NAME and inherited its
# inputs -- and the confirmation the user had just read ("its input on every
# monitor is cleared too") was false.

# The list is: 1 pc, 2 mac, (3 blank), 4 Add another, 5 Remove a computer, 6 Done.

# Rebuilt per case, so one case's edits cannot leak into the next.
function New-TestPanels {
    @([PSCustomObject]@{ Key = 'lg';   Label = 'lg';   Map = [ordered]@{ pc = '0xD0'; mac = '0xD1' } },
      [PSCustomObject]@{ Key = 'asus'; Label = 'asus'; Map = [ordered]@{ pc = '0x11' } })
}
# Keys AND order: a rename must not move a panel's row.
function Format-TestMap { param($Panel) (@($Panel.Map.Keys) | ForEach-Object { '{0}={1}' -f $_, $Panel.Map[$_] }) -join ',' }

Set-Answers @('2', 'macbook', '6')
$p = New-TestPanels
$r = Read-Computers -This 'pc' -Others @('mac') -Existing -Panels $p
Assert-Equal 'pc,macbook' ($r.All -join ',')
Assert-Equal 'pc=0xD0,macbook=0xD1' (Format-TestMap $p[0]) 'a rename is carried into the map, in place'
Assert-Equal 'pc=0x11'              (Format-TestMap $p[1]) 'and leaves a panel it is not on alone'
Assert-Equal $true $r.Edited 'a rename invalidates a monitor-input pass'
Assert-NoMatch ((Get-Asked) -join '|') 'How many OTHER' 'and the count is not re-asked'

# A rename still counts as an edit when no panel happens to have that computer:
# specs/configure.md 5.2 makes the pass invalid on the rename, not on the map.
Set-Answers @('2', 'macbook', '6')
$p = @([PSCustomObject]@{ Key = 'asus'; Label = 'asus'; Map = [ordered]@{ pc = '0x11' } })
$r = Read-Computers -This 'pc' -Others @('mac') -Existing -Panels $p
Assert-Equal $true     $r.Edited
Assert-Equal 'pc=0x11' (Format-TestMap $p[0]) 'and changes nothing it does not name'

# Renaming THIS computer is the same edit. Row 1.
Set-Answers @('1', 'desktop', '6')
$p = New-TestPanels
$r = Read-Computers -This 'pc' -Others @('mac') -Existing -Panels $p
Assert-Equal 'desktop'                   $r.This
Assert-Equal 'desktop=0xD0,mac=0xD1'     (Format-TestMap $p[0])
Assert-Equal 'desktop=0x11'              (Format-TestMap $p[1])

Set-Answers @('4', 'linux', '7')
$p = New-TestPanels
$r = Read-Computers -This 'pc' -Others @('mac') -Existing -Panels $p
Assert-Equal 'pc,mac,linux' ($r.All -join ',')
Assert-Equal $false $r.Edited 'adding a computer edits nothing'
Assert-Equal 'pc=0xD0,mac=0xD1' (Format-TestMap $p[0]) 'and leaves the maps alone'

# ---- ENTER KEEPS THE NAME. It used to remove the computer --------------------
#
# specs/configure.md 5.0. Every other prompt in this walkthrough returns its
# default on a blank answer, so this one doing something DESTRUCTIVE made the most
# innocuous keypress available the dangerous one -- the same failure as accepting
# an empty multi-select, which 3 already exists to prevent.

Reset-Printed; Set-Answers @('2', '', '6')
$p = New-TestPanels
$r = Read-Computers -This 'pc' -Others @('mac') -Existing -Panels $p
Assert-Equal 'pc,mac' ($r.All -join ',') 'enter on the rename prompt keeps the name'
Assert-Equal $false $r.Edited            'and is not even a rename, so a pass still stands'
Assert-Equal 'pc=0xD0,mac=0xD1' (Format-TestMap $p[0]) 'and nothing moved in the maps'
Assert-Match ((Get-Asked) -join '|') "Name for computer 'mac' \[mac\]" `
    'the prompt is pre-filled, so enter visibly means "keep this"'

# ---- removal is a row, and it confirms with the cost named --------------------

# 5 Remove a computer -> 1 mac -> confirm -> (list again) 2 Done -> 6 Done
Reset-Printed; Set-Answers @('5', '1', 'y', '5')   # Remove -> mac -> yes -> Done
# The removal list returns by itself once nothing is left to remove, and the outer
# list has shrunk with it: pc(1), blank(2), Add(3), Remove(4), Done(5).
$p = New-TestPanels
$r = Read-Computers -This 'pc' -Others @('mac') -Existing -Panels $p
Assert-Equal 'pc'  ($r.All -join ',')
Assert-Equal $true $r.Edited
Assert-Equal 'pc=0xD0' (Format-TestMap $p[0]) 'a removal clears that input, as the confirm said it would'
Assert-Equal 'pc=0x11' (Format-TestMap $p[1]) 'and touches nothing else'

$said = Get-Printed
Assert-Match $said '--- remove a computer ---'
Assert-Match $said 'Removing a computer also clears its input on every monitor it is on\.'
Assert-Match $said 'mac\s+on lg' 'the row names the panels it is on, before it is chosen'
Assert-Match $said 'Its input on every monitor is cleared too\. Nothing else changes\.'
Assert-MatchCase ((Get-Asked) -join '|') "Remove 'mac'\? \[y/N\]" 'and the confirm defaults to no'

# Declining the confirm keeps it.
Reset-Printed; Set-Answers @('5', '1', 'n', '3', '6')
$p = New-TestPanels
$r = Read-Computers -This 'pc' -Others @('mac') -Existing -Panels $p
Assert-Equal 'pc,mac' ($r.All -join ',') 'answering no to the confirm removes nothing'
Assert-Equal $false $r.Edited
Assert-Equal 'pc=0xD0,mac=0xD1' (Format-TestMap $p[0]) 'and clears no input either'

# ---- a removal is recorded as a REMOVAL, whoever slides into the slot ---------
#
# The whole point of editing the maps when the row is chosen. Three computers,
# one of them absent from a panel, and the FIRST-LISTED other one removed -- so
# every position after it shifts. Inferring the change from the list positions
# afterwards read this as a RENAME of pc to linux, handed pc's ASUS input to
# linux, and reported nothing removed: `to linux` would then have moved the ASUS
# to the PC's socket.
#
# Outer list: 1 mac, 2 pc, 3 linux, (4 blank), 5 Add, 6 Remove, 7 Done.
# Removal list: 1 pc, 2 linux, (3 blank), 4 Done -- then, with pc gone,
#               1 linux, (2 blank), 3 Done.
Reset-Printed; Set-Answers @('6', '1', 'y', '3', '6')
$p = @([PSCustomObject]@{ Key = 'lg';   Label = 'lg'
                          Map = [ordered]@{ mac = '0xD1'; pc = '0xD0'; linux = '0xD2' } },
       [PSCustomObject]@{ Key = 'asus'; Label = 'asus'
                          Map = [ordered]@{ mac = '0x0F'; pc = '0x11' } })
$r = Read-Computers -This 'mac' -Others @('pc', 'linux') -Existing -Panels $p
Assert-Equal 'mac,linux' ($r.All -join ',')
Assert-Equal 'mac=0xD1,linux=0xD2' (Format-TestMap $p[0]) 'the removed computer goes, and the rest keep their inputs'
Assert-Equal 'mac=0x0F'            (Format-TestMap $p[1]) 'nobody inherits the removed computer''s socket'

# Rename and remove in ONE sitting: the case the positional diff could not
# represent at all, because the removal moves the ground the rename stood on.
# 2 mac -> macbook, then 6 Remove -> 1 macbook -> yes -> 3 Done -> 6 Done.
Reset-Printed; Set-Answers @('2', 'macbook', '6', '1', 'y', '3', '6')
$p = @([PSCustomObject]@{ Key = 'lg';   Label = 'lg'
                          Map = [ordered]@{ pc = '0xD0'; mac = '0xD1'; linux = '0xD2' } },
       [PSCustomObject]@{ Key = 'asus'; Label = 'asus'
                          Map = [ordered]@{ pc = '0x11'; mac = '0x0F' } })
$r = Read-Computers -This 'pc' -Others @('mac', 'linux') -Existing -Panels $p
Assert-Equal 'pc,linux' ($r.All -join ',')
Assert-Equal 'pc=0xD0,linux=0xD2' (Format-TestMap $p[0])
Assert-Equal 'pc=0x11'            (Format-TestMap $p[1]) 'the renamed computer is gone, not relabelled onto linux'

# THIS computer is never offered for removal: its name is what `pull` resolves.
Reset-Printed; Set-Answers @('5', '3', '6')
$r = Read-Computers -This 'pc' -Others @('mac') -Existing
Assert-Equal 'pc,mac' ($r.All -join ',')
$rows = @((Get-Printed) -split "`n" | Where-Object { $_ -match '^\s+\d+\) ' })
Assert-NoMatch (($rows | Select-Object -Last 3) -join "`n") '\bpc\b' `
    'the removal list offers the OTHER computers only'

# ---- autostart and PATH are suggested, never assumed --------------------------

# Both have an obvious answer, and neither is applied without being chosen: one
# decides whether a UAC prompt happens, the other edits your PATH. Showing "from
# boot" for a choice nobody made is the tool answering on someone's behalf.
# Records every row the top menu draws, and then leaves. Cancel, so the
# walkthrough ends whatever state it is in: Save would be refused while a row is
# unanswered, and this stub would then pick it again forever.
#
# ONE definition, reused by resetting $script:rows. It was two nearly identical
# ones for a while, and the second declared a narrower param list -- so a
# -Disabled argument would have been swallowed into $args and silently dropped,
# which is the same class of bug conventions.tests.ps1 exists to catch.
$script:rows = @()
function Select-One {
    param([string[]]$Items, [string[]]$Detail = @(), [int]$Default = 0, [string]$Help,
          [int]$Current = -1, [int[]]$Disabled = @())
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($Items[$i]) { $script:rows += ('{0}|{1}' -f $Items[$i], $(if ($i -lt $Detail.Count) { $Detail[$i] } else { '' })) }
    }
    for ($i = 0; $i -lt $Items.Count; $i++) { if ($Items[$i] -eq 'Cancel (discard changes)') { return $i } }
    return 0
}
Set-Config $null
Set-Answers @()
Invoke-Configure
$seen = ($script:rows -join "`n")
Assert-Match $seen 'Autostart\?\|not set'    'a fresh install has not answered this'
Assert-Match $seen 'Add to PATH\?\|not set'  'nor this'

# ---- the review rows read as one column --------------------------------------

# ", " between items, ": " after a label, "/" for things sharing one label. The
# monitors row used spaces, which meant Split-Detail could not wrap it -- so a desk
# with several panels overran the line rather than wrapping like every other row.
$script:rows = @()
Set-Config $CONFIGURED
Set-Answers @()
Invoke-Configure
$review = @($script:rows | Where-Object { $_ -like 'Computers|*' -or $_ -like 'Monitors|*' -or $_ -like 'Trigger devices|*' })
Assert-Match ($review -join "`n") 'Computers\|pc \(this\), mac'
Assert-Match ($review -join "`n") 'Monitors\|asus: pc/mac, lg: pc/mac' `
    'items separated by ", ", label by ": ", computers on one panel by "/" -- and pc first, as listed'

Remove-Item -LiteralPath $script:CONFIG -Force -ErrorAction SilentlyContinue
exit 0
