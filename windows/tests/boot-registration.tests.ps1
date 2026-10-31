# Actual COM definition construction, with registration/right changes replaced
# by fixtures. No prompt, account policy, scheduled task or installation changes.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $WinDir 'lib\boot-registration.ps1')
Initialize-BootRegistration

$service = Get-BootTaskService
$fixtureOwner = 'FIXTURE\O''Brien-' + [char]0x00E9 + [char]0x6771
$definition = New-BootTaskDefinition -Service $service -User $fixtureOwner -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Arguments '-EncodedCommand fixture'
Assert-Equal $fixtureOwner $definition.Principal.UserId 'COM preserves the intended Unicode owner'
Assert-Equal 2 $definition.Principal.LogonType 'S4U never stores the registration password'
Assert-Equal 0 $definition.Principal.RunLevel 'Limited remains requested alongside actual token restriction'
Assert-Equal 3 $definition.Settings.Compatibility
Assert-Equal $true $definition.Settings.Enabled
Assert-Equal 'PT0S' $definition.Settings.ExecutionTimeLimit
Assert-Equal $false $definition.Settings.DisallowStartIfOnBatteries
Assert-Equal $false $definition.Settings.StopIfGoingOnBatteries
Assert-Equal 2 $definition.Settings.MultipleInstances
Assert-Equal 3 $definition.Settings.RestartCount
Assert-Equal 'PT1M' $definition.Settings.RestartInterval
Assert-Equal 2 $definition.Triggers.Count 'startup plus the shared self-heal'
Assert-Equal 8 $definition.Triggers.Item(1).Type
Assert-Equal 1 $definition.Triggers.Item(2).Type
Assert-Equal 'PT1M' $definition.Triggers.Item(2).Repetition.Interval
Assert-Equal '' $definition.Triggers.Item(2).Repetition.Duration 'self-heal does not expire'
Assert-Equal $false $definition.Triggers.Item(2).Repetition.StopAtDurationEnd
Assert-True ([datetime]$definition.Triggers.Item(2).StartBoundary -gt (Get-Date)) 'self-heal is not an immediate second launch'
Assert-Equal 1 $definition.Actions.Count
Assert-Equal '-EncodedCommand fixture' $definition.Actions.Item(1).Arguments
Assert-Equal 'powershell.exe' (Split-Path -Leaf $definition.Actions.Item(1).Path)

# Use the actual registration helper with a fake COM endpoint. Synthetic secret
# is checked only in memory; no fixture writes it or registers anything.
$script:events = @()
$script:hadRight = $false
$script:failRegister = $false
$script:wrongLogon = $false
$script:fakeFolder = New-Object PSObject
$script:fakeFolder | Add-Member ScriptMethod RegisterTaskDefinition {
    param($name,$taskDefinition,$flags,$owner,$password,$logon)
    $script:events += 'register'
    Assert-Equal 'trigger-kvm-fixture' $name
    Assert-Equal 2 $flags 'create only; never overwrite an unexpected task'
    Assert-Equal $fixtureOwner $owner
    Assert-Equal 2 $logon 'registration explicitly authenticates S4U'
    Assert-Equal 'synthetic-secret' $password 'password is supplied to authenticate the intended account'
    Assert-Equal $fixtureOwner $taskDefinition.Principal.UserId
    if ($script:failRegister) { throw 'fixture registration refused' }
    return [pscustomobject]@{Definition=[pscustomobject]@{Principal=[pscustomobject]@{LogonType=$(if ($script:wrongLogon) {1} else {2})}}}
}
$script:fakeFolder | Add-Member ScriptMethod DeleteTask { param($name,$flags)
    Assert-Equal 'trigger-kvm-fixture' $name
    Assert-Equal 0 $flags
    $script:events += 'delete'
}
$script:fakeService = New-Object PSObject
$script:fakeService | Add-Member ScriptMethod GetFolder { param($path)
    Assert-Equal '\' $path
    return $script:fakeFolder
}
function Get-BootTaskService { $script:fakeService }
function New-BootTaskDefinition { param($Service,$User,$Execute,$Arguments)
    Assert-Equal $script:fakeService $Service
    Assert-Equal 'fixture.exe' $Execute
    Assert-Equal 'fixture-arguments' $Arguments
    return $definition
}
function Set-BootBatchRight { param($User,[bool]$Add)
    Assert-Equal $fixtureOwner $User
    $script:events += "right:$Add"
    return -not $script:hadRight
}
$secret = ConvertTo-SecureString 'synthetic-secret' -AsPlainText -Force
try {
    foreach ($already in @($false,$true)) {
        $script:hadRight = $already
        foreach ($failure in @('none','register','wrong-logon')) {
            $script:failRegister = $failure -eq 'register'
            $script:wrongLogon = $failure -eq 'wrong-logon'
            $script:events = @()
            $threw = $false
            try { Register-CrossUserBootTask -Name 'trigger-kvm-fixture' -User $fixtureOwner -Execute 'fixture.exe' -Arguments 'fixture-arguments' -Password $secret }
            catch { $threw = $true }
            Assert-Equal ($failure -ne 'none') $threw "registration failure propagates: $failure"
            $expected = 'right:True,register'
            if ($failure -eq 'wrong-logon') { $expected += ',delete' }
            if ($failure -ne 'none' -and -not $already) { $expected += ',right:False' }
            Assert-Equal $expected ($script:events -join ',') 'rollback removes only a new grant; never an existing one'
        }
    }
} finally { $secret.Dispose() }

$BootRegistrationSource += "`n// changed fixture source"
$refused = $false
try { Initialize-BootRegistration } catch { $refused = $_.Exception.Message -match 'bindings changed' }
Assert-True $refused 'cannot silently use stale credential/rights bindings'
