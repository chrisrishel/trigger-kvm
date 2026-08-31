# Checking the trigger.
#
# The reported failure: "The property 'Text' cannot be found on this object."
# Invoke-Sibling emits the child's stdout on the SUCCESS stream, so letting it fall
# out of Invoke-TriggerTest made the caller receive [those lines..., the result
# object] -- an array, and .Text on an array throws under StrictMode. Every test
# elsewhere stubs Invoke-TriggerTest, so nothing was watching the real one.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest          # as install.ps1 runs
. (Join-Path $PSScriptRoot 'lib.ps1')

Import-Subject -Script 'install.ps1' -Functions @(
    'Read-Default','Read-YesNo','Invoke-TriggerTest','Write-ConfigFile')

$global:CONFIG = Join-Path $env:TEMP 'trigger-kvm-trigcheck.cfg'
$global:SWITCH = Join-Path (Split-Path -Parent $PSScriptRoot) 'trigger-kvm.ps1'
$global:WATCH  = Join-Path (Split-Path -Parent $PSScriptRoot) 'event-watch.ps1'
$global:DEFAULT_DEBOUNCE = '3.0'
$global:DEFAULT_SETTLE   = '0.75'

# The watcher talks while it waits, and the switcher talks while it switches. Both
# go through Invoke-Sibling, which is exactly what made the bug.
$script:calls = @()
$script:exit  = 0
function Invoke-Sibling {
    param([string]$Script, [string[]]$Arguments)
    $script:calls += (Split-Path -Leaf $Script) + ' ' + ($Arguments -join ' ')
    Write-Output '  usb:046d:0843       here now'
    Write-Output '  waiting up to 90s'
    Write-Output '  usb:046d:0843 arrived -- this is what fires the switch.'
    $global:LASTEXITCODE = $script:exit
}

$panels = @(
    [PSCustomObject]@{
        Label='lg'; Name='LG'; Method='lg-alt'; Vendor='0x1E6D'; Product='0x9E9D'
        EdidVendor=0x1E6D; Mfg='GSM'; Key='1E6D:9E9D'
        Map=[ordered]@{ pc='0xD0'; mac='0xD1' }
    }
)

# ---- the result is ONE object, whatever the child printed --------------------

$script:calls = @(); $script:exit = 0
Set-Answers @()
$r = Invoke-TriggerTest -Devices @('usb:046d:0843') -Answers $panels -This 'pc'
Assert-Equal 1 @($r).Count "the child's chatter must not come back as part of the result"
Assert-Equal $true  $r.Ok
Assert-Equal 'arrival seen' $r.Text 'and .Text must be readable under StrictMode'

# ---- without -Pull it watches and stops --------------------------------------

Assert-Equal 1 $script:calls.Count 'no pull was asked for, so none happened'
Assert-Match $script:calls[0] 'event-watch.ps1 -TestTrigger'
Assert-NoMatch ($script:calls -join '|') 'trigger-kvm.ps1 pull'

# ---- with -Pull it fires for real, against a THROWAWAY config ----------------

$script:calls = @(); $script:exit = 0
Set-Answers @('y')                       # did the monitors come back? yes
$r = Invoke-TriggerTest -Devices @('usb:046d:0843') -Answers $panels -This 'pc' -Pull
Assert-Equal 1 @($r).Count
Assert-Equal $true $r.Ok
Assert-Equal 'fired, monitors followed' $r.Text
Assert-Equal 2 $script:calls.Count 'watch, then pull'
Assert-Match $script:calls[1] 'trigger-kvm.ps1 pull'
Assert-NoMatch ($script:calls -join '|') ([regex]::Escape($global:CONFIG)) `
    'the saved config must not be pulled against -- these answers are not written yet'

# ---- the monitors not following is the trigger's PASS and the monitors' FAIL --

$script:calls = @(); $script:exit = 0
Set-Answers @('n')
$r = Invoke-TriggerTest -Devices @('usb:046d:0843') -Answers $panels -This 'pc' -Pull
Assert-Equal $false $r.Ok
Assert-Match $r.Text 'monitors did not follow' 'which is a different fault from no arrival'

# ---- nothing arriving ---------------------------------------------------------

$script:calls = @(); $script:exit = 1
Set-Answers @()
$r = Invoke-TriggerTest -Devices @('usb:046d:0843') -Answers $panels -This 'pc' -Pull
Assert-Equal $false $r.Ok
Assert-Equal 'no arrival seen' $r.Text
Assert-Equal 1 $script:calls.Count 'nothing arrived, so nothing may be pulled'

Remove-Item -LiteralPath $global:CONFIG -Force -ErrorAction SilentlyContinue
exit 0
