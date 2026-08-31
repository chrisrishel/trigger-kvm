# Checking the monitors, on a desk bigger than the one this was written at.
#
# Two panels never exercise the batching: every round holds one back, so each round
# has a single panel and the "which ones did not?" question can never fire. Four
# panels and two other machines is where the design either pays off or does not.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

Import-Subject -Script 'install.ps1' -Variables @('DIALECTS','MCCS_INPUTS') -Functions @(
    'Read-Default','Read-YesNo','Get-MenuWidth','Write-MenuFrame','Split-Detail',
    'Select-One','Select-Many','Join-Names','Get-InputName','Get-InputTable',
    'Read-InputValue','Get-DisplayMap','Invoke-BlindWalk','Test-OneValue',
    'Invoke-DisplayTest','Invoke-TestRound','Invoke-TestRoundBody','Test-OneMachine',
    'Test-DisplayInput','Write-ConfigFile')

$global:SEED_DEBOUNCE = '3.0'
$global:SEED_SETTLE   = '0.75'

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

$script:said = @()
function Write-Host { param([Parameter(ValueFromPipeline=$true)]$Object) $script:said += "$Object" }
function Get-Said { return ($script:said -join "`n") }
function Reset-Said { $script:said = @() }

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
    '1',            # this window is on the LG
    'y',            # mac round 1: asus, dell, big -- the LG is held back
    '',             #   mac round 2 moves the LG: window dragged first
    'y',
    '',             #   the linux round moves the LG too
    'y'
)
$r = Invoke-DisplayTest -Answers (New-Desk) -This 'pc'
Assert-True $r.Ok 'everything working must read as a pass'
Assert-Equal 'all responded' $r.Text

$said = Get-Said
Assert-Match $said 'Sending ASUS, DELL and BIG to mac' 'panels batch into one round'
Assert-Match $said 'LG stays here'                     'and one is always held back'
Assert-Match $said 'THIS WINDOW is on LG'              'the window is warned about before it moves'
Assert-Match $said 'Drag it to ASUS first'
Assert-NoMatch $said 'Which ones did not' 'nothing is asked when nothing went wrong'

# Three claims in one round, then the held-back panel, then the linux pair. The LG
# is last in every group because that is where the window is.
$sent = (Get-Sent) -join ' '
Assert-Match $sent 'asus=0x12 dell=0x12 big=0x12' 'the batch goes out together'
Assert-Match $sent 'asus=0x11 dell=0x11 big=0x11' 'and comes back together'
Assert-Match $sent 'lg=0x12 lg=0x11'              'the window''s panel moves alone, and last'

# ---- one panel in a batch of three is wrong ----------------------------------

Reset-Said; Reset-Sent; Set-Outcomes @(1)      # "changed, but that was not mac"
Set-Answers @(
    '5',            # window: not sure -- no scheduling, no drag prompt
    'n',            # mac round 1: not all of them
    '2',            #   which ones did not -> ASUS
    '4',            #   its mac input, re-picked
    'y',            #   retry of ASUS alone
    'y',            # mac round 2 (big)
    'y'             # linux round
)
$r = Invoke-DisplayTest -Answers (New-Desk) -This 'pc'
Assert-Match (Get-Said) 'Which ones did not' 'a failed batch has to be narrowed'
Assert-NoMatch (Get-Said) 'THIS WINDOW is on' '"not sure" means no scheduling claims'

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

# ---- declining is not a pass -------------------------------------------------

Reset-Said; Reset-Sent; Set-Outcomes @()
Set-Answers @('n')
$r = Invoke-DisplayTest -Answers (New-Solo) -This 'pc'
Assert-True (-not $r.Ok)
Assert-Equal 'not checked' $r.Text 'declining must not read as a pass, nor as a fault'
Assert-Equal 0 (Get-Sent).Count 'and nothing may be sent'

exit 0
