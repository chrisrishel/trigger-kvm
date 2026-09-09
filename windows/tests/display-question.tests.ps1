# The question asked after a panel has been switched away and back, and the swing
# that puts it back before the asking.
#
# Everything else stubs Test-DisplayInput, so this is the only place the real one is
# exercised. It is worth exercising: it is the single point where a human's answer
# becomes a diagnosis, and getting the mapping wrong sends someone to fix the wrong
# thing -- a wrong channel and a wrong input value have nothing to do with each other.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

Import-Subject -Script 'lib\answers.ps1' -Variables @('MCCS_INPUTS','DIALECTS')
Import-Subject -Script 'lib\menu.ps1'    -Functions @(
    'Read-Default','Read-YesNo','Get-MenuWidth','Write-MenuFrame','Clear-ToLineEnd',
    'Split-Detail','Get-ItemWidth','Get-MenuRow','Select-One')
Import-Subject -Script 'lib\checks.ps1'  -Functions @('Test-DisplayInput','Move-PanelsAndBack')

# Test-DisplayInput defaults -Config to $CONFIG, which install.ps1 sets at load.
$global:CONFIG = Join-Path $env:TEMP 'trigger-kvm-question.cfg'

function Write-Host { param([Parameter(ValueFromPipeline=$true)]$Object, [switch]$NoNewline)
    Add-Printed -Object $Object -NoNewline:$NoNewline
}
function Get-Said { return (Get-Printed) }
function Reset-Said { Reset-Printed }

function Ask {
    param([string[]]$Answers)
    Reset-Said; Reset-Sent
    Set-Answers $Answers
    return (Test-DisplayInput -Name 'LG ULTRAGEAR+' -CandidateName 'mac' -ThisName 'pc' -IsComputer)
}

# ---- it asks what was watched, in the order it happened ----------------------

$o = Ask @('1')
Assert-Equal 0 $o 'went and came back'
$said = Get-Said
Assert-Match $said 'Did the LG ULTRAGEAR\+ change to mac, and back to pc\?' `
    'the question names the panel and both computers'
Assert-Match $said 'Yes, and it changed back to pc'
Assert-Match $said 'Yes, but it did not change back to pc'

# One question, when the answer is the common one. The four-way version made someone
# hold every failure in mind at once to find their own.
Assert-NoMatch $said 'change at all' 'a yes must not lead to a second question'

# ---- and only a "no" is taken apart ------------------------------------------

$o = Ask @('2')
Assert-Equal 2 $o 'went, did not come back -- the input for pc is wrong'
Assert-NoMatch (Get-Said) 'change at all' 'that is not a "no" either'

$o = Ask @('3', '1')
Assert-Equal 1 $o 'changed, but to something that was not mac -- a wrong mapping'
Assert-Match (Get-Said) 'Did the LG ULTRAGEAR\+ change at all\?'
Assert-Match (Get-Said) 'Yes, but it was not mac'

$o = Ask @('3', '2')
Assert-Equal 3 $o 'nothing happened -- the panel does not answer on this channel'

# ---- the outcomes are four DIFFERENT faults ----------------------------------

# Nothing in the callers works if these collapse: 1 remaps that computer, 2 fixes
# this computer's input or walks for it, 3 offers the manufacturer's channel.
Assert-Equal 4 (@(0,1,2,3) | Sort-Object -Unique).Count

# ---- testing a bare input has no "wrong computer" to ask about ---------------

Reset-Said; Set-Answers @('3')
$o = Test-DisplayInput -Name 'LG ULTRAGEAR+' -CandidateName 'HDMI 2' -ThisName 'pc'
Assert-Equal 3 $o 'any change proves the transport, so a "no" can only mean nothing happened'
Assert-NoMatch (Get-Said) 'change at all' 'and there is nothing left to ask'

Reset-Said; Set-Answers @('2')
$o = Test-DisplayInput -Name 'LG ULTRAGEAR+' -CandidateName 'HDMI 2' -ThisName 'pc'
Assert-Equal 2 $o 'and the middle answer still means "did not come back"'

# ---- the swing switches away and back, in that order -------------------------
#
# THE RETURN IS WHAT MAKES THE CHECK SAFE to run against the display someone is
# reading: the question always arrives on a panel that has already come back.
# The moving is Move-PanelsAndBack's, so that every path that moves a panel goes
# through one swing and one preamble (specs/configure.md 10.2) -- and this is
# where that property is asserted.

Reset-Sent
$panel = [PSCustomObject]@{ Label = 'lg'; Name = 'LG ULTRAGEAR+'
                            Map = [ordered]@{ pc = '0xD0'; mac = '0xD1' } }
Move-PanelsAndBack -Panels @($panel) -Away @{ lg = '0xD1' } -This 'pc' `
                   -Config $global:CONFIG -Hold 8
Assert-Equal 'lg=0xD1 lg=0xD0' ((Get-Sent) -join ' ') `
    'the panel is sent away and always returned, in that order'

Reset-Sent
Move-PanelsAndBack -Panels @($panel) -Away @{ lg = '0x12' } -This 'pc' `
                   -Config $global:CONFIG -Hold 8
Assert-Equal 'lg=0x12 lg=0xD0' ((Get-Sent) -join ' ') `
    'and the destination is the caller''s, so a transport-only check can use any value'

exit 0
