# Checking the monitors, on a desk bigger than the one this was written at.
#
# Two panels never exercise the batching: every round holds one back, so each round
# has a single panel and the "which ones did not?" question can never fire. Four
# panels and two other machines is where the design either pays off or does not.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

Import-Subject -Script 'install.ps1' -Variables @('DIALECTS','MCCS_INPUTS') -Functions @(
    'Read-Default','Read-YesNo','Get-MenuWidth','Write-MenuFrame','Clear-ToLineEnd',
    'Split-Detail','Get-ItemWidth','Get-MenuRow',
    'Select-One','Select-Many','Join-Names','Get-InputName','Get-InputTable',
    'Format-Byte','Read-InputValue','Get-DisplayMap','Invoke-BlindWalk','Test-OneValue',
    'Invoke-DisplayTest','Invoke-TestRound','Invoke-TestRoundBody','Test-OneComputer',
    'Test-DisplayInput','Write-ConfigFile')

$global:DEFAULT_DEBOUNCE = '3.0'
$global:DEFAULT_SETTLE   = '0.75'

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

function Write-Host { param([Parameter(ValueFromPipeline=$true)]$Object, [switch]$NoNewline)
    Add-Printed -Object $Object -NoNewline:$NoNewline
}
function Get-Said { return (Get-Printed) }
function Reset-Said { Reset-Printed }

function New-Panel {
    param([string]$Label, $Map)
    [PSCustomObject]@{
        Label = $Label; Name = $Label.ToUpper(); Method = 'standard'
        Vendor = '0x0001'; Product = '0x0001'; EdidVendor = 1; Mfg = 'XXX'; Key = "k-$Label"
        Map = $Map
    }
}

# Rebuilt for every case: a repair path MUTATES the map it is handed, so cases that
# shared one desk would really be testing each other's leftovers.
function New-Desk {
    @(
        New-Panel 'lg'   ([ordered]@{ pc='0x11'; mac='0x12'; linux='0x0F' })
        New-Panel 'asus' ([ordered]@{ pc='0x11'; mac='0x12' })
        New-Panel 'dell' ([ordered]@{ pc='0x11'; mac='0x12'; linux='0x0F' })
        New-Panel 'big'  ([ordered]@{ pc='0x11'; mac='0x12' })
    )
}
function New-Solo { @( New-Panel 'lg' ([ordered]@{ pc='0x11'; mac='0x12' }) ) }

# ---- the happy path, and the window is scheduled around ----------------------

Reset-Said; Reset-Sent; Set-Outcomes @()
Set-Answers @(
    '1',            # which monitor to check -> All of them
    '','y',         # mac round 1: three panels, one held back
    '','y',         # mac round 2: the held-back one
    '','y'          # the linux round
)
$r = Invoke-DisplayTest -Answers (New-Desk) -This 'pc'
Assert-True $r.Ok 'everything working must read as a pass'
Assert-Equal 'all responded' $r.Text

$said = Get-Said
Assert-Match $said 'Which monitor do you want to check' 'it asks about intent, not about the window'
Assert-NoMatch $said 'Which monitor is this window on' 'that question is gone'
Assert-Match $said 'Sending LG, ASUS and DELL to mac'  'panels batch into one round'
Assert-Match $said 'BIG stays here'                    'and one is always held back'
Assert-Match $said 'If this window is on LG, ASUS and DELL, drag it to BIG first' `
    'every round says what is about to move, so it can be acted on if it applies'
Assert-NoMatch $said 'Which ones did not' 'nothing is asked when nothing went wrong'

# Three claims in one round, then the held-back panel, then the linux pair.
$sent = (Get-Sent) -join ' '
Assert-Match $sent 'lg=0x12 asus=0x12 dell=0x12' 'the batch goes out together'
Assert-Match $sent 'lg=0x11 asus=0x11 dell=0x11' 'and comes back together'
Assert-Match $sent 'big=0x12 big=0x11'           'then the one held back'

# ---- checking ONE monitor leaves the others somewhere to put a window --------

Reset-Said; Reset-Sent; Set-Outcomes @()
Set-Answers @('2', '', 'y', '', 'y')      # just the LG: mac, then linux
$r = Invoke-DisplayTest -Answers (New-Desk) -This 'pc'
Assert-True $r.Ok
$sent = (Get-Sent) -join ' '
Assert-NoMatch $sent 'asus=' 'a panel nobody asked about must not be touched'
Assert-Match (Get-Said) 'ASUS, DELL and BIG stay here' `
    'but it is still somewhere to move a window to'

# ---- one panel in a batch of three is wrong ----------------------------------

Reset-Said; Reset-Sent; Set-Outcomes @(1)      # "changed, but that was not mac"
Set-Answers @(
    '1',            # All of them
    '',             #   enter when ready
    'n',            # mac round 1: not all of them
    '2',            #   which ones did not -> ASUS
    '4',            #   its mac input, re-picked
    'y',            #   retry of ASUS alone
    '','y',         # mac round 2
    '','y'          # linux round
)
$r = Invoke-DisplayTest -Answers (New-Desk) -This 'pc'
Assert-Match (Get-Said) 'Which ones did not' 'a failed batch has to be narrowed'
Assert-Match (Get-Said) 'If this window is on' 'the warning is unconditional now'

# ---- one monitor: nothing can be held back -----------------------------------

Reset-Said; Reset-Sent; Set-Outcomes @()
Set-Answers @('y','y')          # ready? / did it come back?
$r = Invoke-DisplayTest -Answers (New-Solo) -This 'pc'
Assert-True $r.Ok

$said = Get-Said
Assert-Match $said 'READ THIS FIRST -- this is your only monitor'
Assert-Match $said 'nothing this tool can do for you' 'it must not pretend it can help'
Assert-Match $said 'choose HDMI 1, value 0x11' `
    'the way back must be in the MONITOR''s words -- its menu has never heard of "pc"'
Assert-NoMatch $said 'choose pc' 'a machine name here would send someone hunting a menu entry that does not exist'

# ---- outcome 3: the other channel is offered, in BOTH directions -------------
#
# specs/configure.md 10.5. Offered, never probed: the values come from the
# documented table and are shown before the question is asked. Since 6.2 lets
# someone choose the manufacturer method UP FRONT, a panel can arrive here already
# on it -- so the offer has to run the other way too, or that person is told "no
# manufacturer values are known here", which is both false and a dead end.

function New-LgPanel {
    param([string]$Method = 'standard')
    [PSCustomObject]@{
        Label = 'lg'; Name = 'LG ULTRAGEAR+'; Method = $Method
        Vendor = '0x1E6D'; Product = '0x9E9D'; EdidVendor = 0x1E6D; Mfg = 'GSM'
        Key = '1E6D:9E9D'; Map = [ordered]@{ pc = '0x11'; mac = '0x12' }
    }
}

# On standard, and this vendor documents an alternative.
Reset-Said; Reset-Sent; Set-Outcomes @(3, 0)
Set-Answers @('','n', '1', '1', '2')     # ready / nothing happened / yes, try LG / two inputs
$panel = New-LgPanel
$r = Invoke-DisplayTest -Answers @($panel) -This 'pc'
$said = Get-Said
Assert-Match $said 'did not answer the standard channel\. It is LG'
Assert-Match $said 'nothing is guessed at on a manufacturer channel'
# ORDER, not mere presence: the values are shown before the question is asked. On
# presence alone this passes with the listing deleted, because the same values
# reappear in the input menus afterwards -- found by a mutation that survived.
Assert-Match $said '(?s)nothing is guessed at.*0xD0.*Yes, try the LG channel' `
    'the documented values are shown BEFORE the question'
Assert-Equal 'lg-alt' $panel.Method 'accepting it switches the method'

# ALREADY on the manufacturer method, and it answers nothing. Standard is what is
# left to try, and this is the direction that did not exist.
Reset-Said; Reset-Sent; Set-Outcomes @(3, 0)
Set-Answers @('','n', '1', '1', '2')
$panel = New-LgPanel -Method 'lg-alt'
$r = Invoke-DisplayTest -Answers @($panel) -This 'pc'
$said = Get-Said
Assert-Match $said "is on LG's own method and did not answer it\. The standard method"
Assert-Match $said 'is the other thing to try'
Assert-Match $said '(?s)these are its values.*0x0F.*Yes, try the standard method' `
    'and the standard values are shown first here too, as the other direction shows its own'
Assert-NoMatch $said 'no manufacturer values' `
    'the dead end must not be reachable from a panel that has somewhere to go'
Assert-Equal 'standard' $panel.Method 'accepting it switches back'

# Declining leaves the panel alone and the rest of the setup standing.
Reset-Said; Reset-Sent; Set-Outcomes @(3)
Set-Answers @('','n', '2')               # no, leave this monitor out
$panel = New-LgPanel -Method 'lg-alt'
$r = Invoke-DisplayTest -Answers @($panel) -This 'pc'
Assert-True (-not $r.Ok) 'a declined escalation is a failed check'
Assert-Equal 'lg-alt' $panel.Method 'and changes nothing'

# On standard with no documented alternative: the dead end, which is still correct.
Reset-Said; Reset-Sent; Set-Outcomes @(3)
Set-Answers @('','n')
$r = Invoke-DisplayTest -Answers (New-Solo) -This 'pc'
Assert-Match (Get-Said) 'did not answer the standard channel, and no manufacturer values'
Assert-True (-not $r.Ok)

# ---- declining is not a pass -------------------------------------------------

Reset-Said; Reset-Sent; Set-Outcomes @()
Set-Answers @('n')
$r = Invoke-DisplayTest -Answers (New-Solo) -This 'pc'
Assert-True (-not $r.Ok)
Assert-Equal 'not checked' $r.Text 'declining must not read as a pass, nor as a fault'
Assert-Equal 0 (Get-Sent).Count 'and nothing may be sent'

exit 0
