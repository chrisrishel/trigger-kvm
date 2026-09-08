# Two attached panels answering to ONE EDID identity -- specs/configure.md 6.4
# and specs/status.md 5.
#
# Nobody here owns identical monitors, and both suites are built so they cannot
# move one anyway. What IS testable without twins is every decision made ABOUT
# the count: how it is folded across transports, how a row carrying it is read,
# what the walkthrough refuses on it, and what `status` says. Those are the parts
# that were wrong -- the switcher's refusal itself was already correct and is
# covered by resolve.tests.ps1.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

Import-Subject -Script 'trigger-kvm.ps1' -Functions @('Merge-PanelTally')
Import-Subject -Script 'lib\discover.ps1' -Functions @('ConvertFrom-DisplayRow')
Import-Subject -Script 'lib\host.ps1'     -Functions @('Get-DisplayAmbiguityReport')
Import-Subject -Script 'config.ps1'      -Functions @('ConvertTo-Word')

# ---- folding the count across transports -------------------------------------
#
# THE property, and the one a plausible implementation gets wrong: each transport
# enumerates each panel once, so two transports seeing one panel is one panel.
# Summing would report every ordinary panel on every desk as two, and every desk
# would suddenly refuse to configure anything.

$m = Merge-PanelTally -Into @{ '1E6D:9E9D' = 1 } -From @{ '1E6D:9E9D' = 1 }
Assert-Equal 1 $m['1E6D:9E9D'] 'one panel seen by both transports is ONE panel, not two'

$m = Merge-PanelTally -Into @{ '06B3:42E0' = 2 } -From @{ '06B3:42E0' = 2 }
Assert-Equal 2 $m['06B3:42E0'] 'and two panels seen by both transports are two, not four'

# A transport that sees more panels than the other decides the count: dxva2 sees
# panels on adapters NVAPI cannot (measured 2026-09-01), so the larger reading is
# the true one and must not be lowered by the transport that saw fewer.
$m = Merge-PanelTally -Into @{ 'AAAA:1111' = 1 } -From @{ 'AAAA:1111' = 3 }
Assert-Equal 3 $m['AAAA:1111'] 'a larger count from another transport wins'

$m = Merge-PanelTally -Into @{ 'AAAA:1111' = 3 } -From @{ 'AAAA:1111' = 1 }
Assert-Equal 3 $m['AAAA:1111'] 'and a smaller one does not lower it'

$m = Merge-PanelTally -Into @{} -From @{ 'BBBB:2222' = 2 }
Assert-Equal 2 $m['BBBB:2222'] 'an id only one transport can see is still counted'

$m = Merge-PanelTally -Into @{ 'AAAA:1111' = 1 } -From @{ 'BBBB:2222' = 1 }
Assert-Equal 1 $m['AAAA:1111'] 'and folding leaves the other ids alone'
Assert-Equal 1 $m['BBBB:2222']

# ---- reading a `list -Raw` row -----------------------------------------------
#
# The fields are APPEND-ONLY, and the reason is a real configuration: an
# installer newer than the trigger-kvm.ps1 beside it. Every field added since has
# to default to what the older switcher meant, or an upgrade turns into a
# refusal on a desk that has nothing wrong with it.

$row = ConvertFrom-DisplayRow '1E6D|9E9D|GSM|DisplayPort|00001111|LG ULTRAGEAR+|nvapi,dxva2|1'
Assert-Equal 0x1E6D $row.EdidVendor
Assert-Equal 0x9E9D $row.EdidProduct
Assert-Equal 'LG ULTRAGEAR+' $row.Name
Assert-Equal 1 $row.Panels 'a desk with no twins reports one panel per id'
Assert-Equal 'nvapi,dxva2' ($row.Transports -join ',')

$row = ConvertFrom-DisplayRow '06B3|42E0|AUS|HDMI|01010101|PG42UQ|nvapi|2'
Assert-Equal 2 $row.Panels 'and the count is carried when there IS more than one'

# The append-only contract, which is the half that breaks silently.
$old = ConvertFrom-DisplayRow '06B3|42E0|AUS|HDMI|01010101|PG42UQ'
Assert-Equal 1       $old.Panels     'a row from a switcher predating field 8 means ONE panel'
Assert-Equal 'nvapi' ($old.Transports -join ',') 'and predating field 7 still means nvapi'

$older = ConvertFrom-DisplayRow '06B3|42E0|AUS|HDMI'
Assert-Equal 1  $older.Panels 'four fields is still a row, and still one panel'
Assert-Equal '' $older.Name

Assert-Equal $null (ConvertFrom-DisplayRow 'not a row at all') 'a non-row is not a row'
Assert-Equal $null (ConvertFrom-DisplayRow '')

# A count that is not a number is not trusted into an [int]: garbage would
# otherwise become 0, and 0 is "fewer than one", which reads as no ambiguity.
$junk = ConvertFrom-DisplayRow '06B3|42E0|AUS|HDMI|01010101|PG42UQ|nvapi|lots'
Assert-Equal 1 $junk.Panels 'an unparseable count falls back to one, never to zero'

# ---- what `status` says about it ---------------------------------------------
#
# specs/status.md 5. The switch has already refused by the time anyone reads
# this, and the refusal only ever reached the log.

$cfg = @{
    'display.lg.vendor'    = '0x1E6D'
    'display.lg.product'   = '0x9E9D'
    'display.asus.vendor'  = '0x06B3'
    'display.asus.product' = '0x42E0'
}

# Nothing ambiguous: the block says NOTHING. A permanent line reading "all fine"
# is noise on every desk in the world, and this is a warning, not a field.
$clean = @(Get-DisplayAmbiguityReport -Cfg $cfg -Labels @('lg','asus') `
                                      -Attached @{ '1E6D:9E9D' = 1; '06B3:42E0' = 1 })
Assert-Equal 0 $clean.Count 'a desk where every id names one panel reads exactly as before'

$none = @(Get-DisplayAmbiguityReport -Cfg $cfg -Labels @('lg','asus') -Attached @{})
Assert-Equal 0 $none.Count 'and so does one where nothing could be enumerated'

# Two panels answering to the ASUS id.
$rep = @(Get-DisplayAmbiguityReport -Cfg $cfg -Labels @('lg','asus') `
                                    -Attached @{ '1E6D:9E9D' = 1; '06B3:42E0' = 2 }) -join "`n"

Assert-Match $rep 'more than one attached monitor matches' 'the normative line, specs/status.md 5.1'
Assert-Match $rep 'the switch refuses rather than guessing' 'and why the panel stopped following'
Assert-Match $rep 'asus'      'the label is named, because that is what the person configured'
Assert-Match $rep '0x06B3'    'with the id, so it can be matched against what is attached'
Assert-Match $rep '2 of them' 'and the count, which the resolver knows'
Assert-NoMatch $rep '(?m)^\s*lg\s' 'the panel that resolves fine is not dragged into the warning'

# specs/status.md 5.2. `configure` cannot fix this -- it refuses the same id --
# so offering it would be a fix this tool does not have. Unlike the input map in
# 3.1, where `configure` is exactly the fix and IS offered.
Assert-NoMatch $rep 'trigger-kvm configure' 'no fix is offered that would not work'

# An id in the config that nothing attached answers to is a DIFFERENT state --
# absent, not ambiguous -- with a different remedy, and is not this block's.
$absent = @(Get-DisplayAmbiguityReport -Cfg $cfg -Labels @('lg','asus') `
                                       -Attached @{ '1E6D:9E9D' = 1 })
Assert-Equal 0 $absent.Count 'a configured panel that is merely unplugged is not reported here'

# An unparseable id must match NOTHING rather than matching vendor 0x0000, the
# same refusal Get-ConfiguredDisplays makes. A cast would turn $null into 0 and
# quietly compare against a real id.
$bad = @(Get-DisplayAmbiguityReport -Cfg @{ 'display.x.vendor' = 'nonsense'
                                            'display.x.product' = '0x0000' } `
                                    -Labels @('x') -Attached @{ '0000:0000' = 2 })
Assert-Equal 0 $bad.Count 'an unparseable id does not match 0x0000'

# ---- what the walkthrough does with it ---------------------------------------
#
# specs/configure.md 6.4. The refusal has to happen BEFORE any question is asked:
# answers here are looked up by the id, so one record would serve both panels and
# the second answer would overwrite the first. That is the macOS defect reported
# in its HANDOFF, and it is the shape this side has to avoid too.

Import-Subject -Script 'lib\walkthrough.ps1' -Functions @('Read-Monitors')

function Write-Host { param([Parameter(ValueFromPipeline=$true)]$Object, [switch]$NoNewline)
    Add-Printed -Object $Object -NoNewline:$NoNewline
}

# If the refusal is missing, Read-Monitors falls through to this -- so a mutation
# that removes it does not merely print less, it reaches a question it must never
# reach, and the test says which.
$script:asked = 0
function Get-DisplayAnswers {
    param($Found, $Existing, [string[]]$Computers, [string]$This, [string[]]$Labels)
    $script:asked++
    return $null
}

$twins = @(ConvertFrom-DisplayRow '06B3|42E0|AUS|HDMI|01010101|PG42UQ|nvapi|2')

# Pick the ambiguous panel, then leave. Row 0 is the panel, row 1 is blank and
# row 2 is Done -- and picking Done is what stops this looping, since a refusal
# returns to the same menu.
$script:picks = @(0, 2)
function Select-One {
    param([string[]]$Items, [string[]]$Detail = @(), [int]$Default = 0, [string]$Help,
          [int]$Current = -1, [int[]]$Disabled = @(), [switch]$Escapable)
    $script:lastDetail = @($Detail)
    if ($script:picks.Count -eq 0) { throw 'Read-Monitors asked for more picks than the test scripted' }
    $p = $script:picks[0]
    $script:picks = @($script:picks | Select-Object -Skip 1)
    return $p
}

Reset-Printed
$script:lastDetail = @()
$kept = @(Read-Monitors -Found $twins -Answers @() -Computers @('pc','mac') -This 'pc')
$said = Get-Printed

Assert-Equal 0 $script:asked 'the walkthrough asks NOTHING about an id it cannot aim at'
Assert-Match $said 'report the same id and cannot be told apart' 'the normative refusal, specs/configure.md 6.4'
Assert-Match $said 'A switch cannot aim at one of them'          'and why it is refused'
Assert-Match $said '2 monitors'                                  'the count, so the reader can check it against the desk'
Assert-Match $said '0x06B3'                                      'and the id'
Assert-Match $said 'Unplug one'                                  'with the one remedy that does work'
Assert-Equal 0 $kept.Count 'and nothing is written for it'

# The row itself says so before it is picked, so the refusal is not a surprise
# sprung on someone who selected it.
Assert-Match ($script:lastDetail -join "`n") 'cannot manage' 'the Monitors row says it up front'

# A config written before the twin arrived is KEPT, not silently dropped: the
# person still has one answer recorded, and unplugging the second panel restores
# it. Dropping it would turn a recoverable state into lost configuration.
$script:asked = 0
$script:picks = @(0, 2)
$prior = @([PSCustomObject]@{ Key = '06B3:42E0'; Label = 'asus'
                              Map = [ordered]@{ 'pc' = '0x11' }; Method = 'standard'
                              Transport = 'nvapi'; Name = 'PG42UQ' })
Reset-Printed
$still = @(Read-Monitors -Found $twins -Answers $prior -Computers @('pc','mac') -This 'pc')
Assert-Equal 1      $still.Count    'an answer that predates the second panel survives the refusal'
Assert-Equal 'asus' $still[0].Label
Assert-Equal 0      $script:asked   'and it still asks nothing'

exit 0
