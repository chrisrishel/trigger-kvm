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

Import-Subject -Script 'lib\menu.ps1'    -Functions @('Read-Default','Read-YesNo')
Import-Subject -Script 'lib\answers.ps1' -Variables @('RENAMED_KEYS') -Functions @(
    'Get-TriggerEntries','Get-CarriedKeys','Write-ConfigFile')
Import-Subject -Script 'lib\checks.ps1'  -Functions @('Invoke-TriggerTest')
# Write-ConfigFile sanitises through ConvertTo-ConfigValue, which lives beside
# the reader in config.ps1 -- specs/config-format.md, "A writer must not write
# what it cannot read back".
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'config.ps1')

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

# What the installed watcher does while the check runs. The real ones talk to
# Task Scheduler, which a suite must not.
$script:pauseMode = 'none'
$script:watcher   = @()
function Get-WatcherPauseMode { return $script:pauseMode }
# Returns whether the watcher is actually down, as the real one does -- a stub
# that always said yes would let the caller claim a pause it never got.
$script:suspendWorks = $true
function Suspend-Watcher { $script:watcher += 'suspend'; return $script:suspendWorks }
function Resume-Watcher  { $script:watcher += 'resume' }

function Write-Host { param([Parameter(ValueFromPipeline=$true)]$Object, [switch]$NoNewline)
    Add-Printed -Object $Object -NoNewline:$NoNewline
}

$panels = @(
    [PSCustomObject]@{
        Label='lg'; Name='LG'; Method='lg-alt'; Transport='nvapi'; Vendor='0x1E6D'; Product='0x9E9D'
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

# ---- with nothing chosen, it refuses instead of waiting ----------------------
#
# It used to run the check regardless: -Device '' reached the one-shot, which
# skipped the empty entry and armed an empty watch list, waited the full 90
# seconds, and then told the person their devices might be wrong. macOS refuses
# first, and says which row to go to.

$script:calls = @(); $script:exit = 0; $script:watcher = @(); $script:pauseMode = 'can'
Reset-Printed; Set-Answers @()
$r = Invoke-TriggerTest -Devices @() -Answers $panels -This 'pc'
Assert-Equal $false $r.Ok
Assert-Equal 'no devices chosen' $r.Text 'and the row says which, so the cursor lands on Triggers'
Assert-Equal 0 $script:calls.Count 'nothing is run, so nobody waits 90 seconds for it'
Assert-Match (Get-Printed) 'No trigger devices are chosen yet -- pick some first\.'
Assert-Equal '' ($script:watcher -join ',') 'and the installed watcher is not disturbed for a check that cannot run'

# ---- the installed watcher is stood down for the check -----------------------
#
# specs/configure.md 11. On a re-run the live watcher sees the same flip and
# pulls against the SAVED config -- after the one-shot's pull -- so a correct new
# answer reads as the monitors failing, and the person is sent to fix something
# that is not broken.

$script:calls = @(); $script:exit = 0; $script:watcher = @(); $script:pauseMode = 'can'
Reset-Printed; Set-Answers @()
$null = Invoke-TriggerTest -Devices @('usb:046d:0843') -Answers $panels -This 'pc'
Assert-Equal 'suspend,resume' ($script:watcher -join ',') 'stood down, then put back'
Assert-Match (Get-Printed) 'The running watcher is paused for this check\.'

# Put back on EVERY way out, not just the happy one. Nothing arrived here.
$script:calls = @(); $script:exit = 1; $script:watcher = @(); $script:pauseMode = 'can'
Reset-Printed; Set-Answers @()
$null = Invoke-TriggerTest -Devices @('usb:046d:0843') -Answers $panels -This 'pc'
Assert-Equal 'suspend,resume' ($script:watcher -join ',') `
    'a check that found nothing must still leave the watcher running'

# Where standing it down would need a password, it is left alone and the person
# is TOLD, before they flip -- a check must not raise a prompt of its own.
$script:calls = @(); $script:exit = 0; $script:watcher = @(); $script:pauseMode = 'needs-admin'
Reset-Printed; Set-Answers @()
$null = Invoke-TriggerTest -Devices @('usb:046d:0843') -Answers $panels -This 'pc'
Assert-Equal '' ($script:watcher -join ',') 'nothing is disabled that would need admin to re-enable'
$said = Get-Printed
Assert-Match   $said 'The running watcher will also fire, using the saved configuration\.'
Assert-NoMatch $said 'is paused for this check' 'and it does not claim otherwise'

# Nothing installed: nothing to say and nothing to do.
$script:calls = @(); $script:exit = 0; $script:watcher = @(); $script:pauseMode = 'none'
Reset-Printed; Set-Answers @()
$null = Invoke-TriggerTest -Devices @('usb:046d:0843') -Answers $panels -This 'pc'
Assert-Equal '' ($script:watcher -join ',')
Assert-NoMatch (Get-Printed) 'running watcher' 'a fresh install has no watcher to talk about'

Remove-Item -LiteralPath $global:CONFIG -Force -ErrorAction SilentlyContinue

# ---- the first run on a fresh machine can write its config -------------------
#
# %LOCALAPPDATA%\trigger-kvm\ does not exist until something creates it, and the
# walkthrough writes the config at Save -- before the install path that would
# have made the directory. Set-Content does not create parents, so under
# $ErrorActionPreference = 'Stop' that is a DirectoryNotFoundException with
# every question answered and nothing written. Measured 2026-09-08; the
# reference PC has had the directory since before the rename, so it had never
# been seen live.

$fresh = Join-Path $env:TEMP ("tk-fresh-$PID\trigger-kvm\config")
Remove-Item -LiteralPath (Split-Path -Parent (Split-Path -Parent $fresh)) `
            -Recurse -Force -ErrorAction SilentlyContinue
Assert-True (-not (Test-Path -LiteralPath (Split-Path -Parent $fresh))) `
    'the fixture must start with no directory, or this proves nothing'

Write-ConfigFile -Path $fresh -Displays @() -Devices @('usb:046d:0843') `
                 -Tier 'user' -This 'pc' -Existing @{}
Assert-True (Test-Path -LiteralPath $fresh) 'a first Save creates the directory it writes into'
Assert-Equal 'pc' ([string](Read-Config -Path $fresh)['computer.this']) 'and the file is readable'
Remove-Item -LiteralPath (Split-Path -Parent (Split-Path -Parent $fresh)) `
            -Recurse -Force -ErrorAction SilentlyContinue


# ---- the check does not claim a pause it did not get -------------------------
#
# specs/configure.md 11. 'can' is a reading of the task's principal, and the
# calls under it fail silently when that reading is wrong -- measured on the
# boot tier, where all three failed and `pause` still reported success. Told the
# watcher is paused, somebody flips the switch believing the flip is theirs
# alone; the installed watcher fires too, against the SAVED config, and the
# monitors move somewhere the check did not ask for.

$script:pauseMode = 'can'
$script:suspendWorks = $false
Reset-Printed; $script:watcher = @()
Set-Answers @()
$r = Invoke-TriggerTest -Devices @('usb:046d:0843') -Answers @() -This 'pc'
$said = Get-Printed
Assert-NoMatch $said 'The running watcher is paused' `
    'a pause that did not happen must not be announced'
Assert-Match   $said 'will also fire, using the saved configuration' `
    'and the person is told what will actually happen before they flip'
Assert-True (-not ($script:watcher -contains 'resume')) `
    'and nothing is resumed that was never suspended'
$script:suspendWorks = $true

exit 0
