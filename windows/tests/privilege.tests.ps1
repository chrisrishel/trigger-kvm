# The actual installer flow, with every task/files/PATH operation fenced to
# fixtures. A protected-task retry must not delegate user-tier registration.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $WinDir 'config.ps1')
Import-Subject 'lib\host.ps1' -Functions @('Invoke-Install')
$root = Join-Path $env:TEMP "tk-privilege-$PID"
New-Item -ItemType Directory -Path $root | Out-Null
$global:CONFIG = Join-Path $root 'config'
@('trigger.device = USB\VID_1234&PID_5678\FIXTURE','trigger.debounce = 2','trigger.settle = 0.25') |
    Set-Content -LiteralPath $CONFIG -Encoding ASCII
$global:TASK = 'trigger-kvm-fixture'
$global:FORUSER = 'FIXTURE\User'
$global:ME = $FORUSER
$global:IsElevated = $false
$global:RENAMED_KEYS = @{}
$global:WATCH = Join-Path $root 'event-watch.ps1'
$global:DEST = $root
$global:SWITCHER = Join-Path $root 'trigger-kvm.ps1'
$global:LOG = Join-Path $root 'fixture.log'
$global:VBS = Join-Path $root 'launcher.vbs'
$global:BINDIR = Join-Path $root 'bin'
$global:SHIM = Join-Path $BINDIR 'trigger-kvm.cmd'

$script:tier = 'user'
$script:taskExists = $true
$script:protectedTask = $true
$script:childCode = 0
$script:childRemoves = $true
$script:removeFails = $false
$script:registrations = @()
$script:elevations = @()
$script:events = @()
function Get-EffectiveTier { $script:tier }
function Install-Files { $script:events += 'files' }
function Get-WatcherCommand { param($Watcher,$Switcher,$LogFile,$ConfigFile) 'fixture-command' }
function Get-BootTaskArguments { param($Watcher,$Switcher,$LogFile,$ConfigFile)
    Assert-Equal $WATCH $Watcher
    Assert-Equal $SWITCHER $Switcher
    Assert-Equal $LOG $LogFile
    Assert-Equal $CONFIG $ConfigFile
    '-EncodedCommand fixture-bootstrap'
}
function Write-WatcherLauncher { param($Path,$Command) $script:events += 'launcher' }
function New-ScheduledTaskAction { param($Execute,$Argument)
    $script:lastAction = [pscustomobject]@{Execute=$Execute;Argument=$Argument}
    'fixture-action'
}
function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel)
    [pscustomobject]@{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel}
}
function New-ScheduledTaskTrigger {
    param([switch]$AtStartup,[switch]$AtLogOn,[switch]$Once,$User,$At,$RepetitionInterval)
    [pscustomobject]@{Repetition=[pscustomobject]@{StopAtDurationEnd=$true}}
}
function New-ScheduledTaskSettingsSet {
    param([switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,
          $MultipleInstances,$ExecutionTimeLimit,$RestartCount,$RestartInterval)
    [pscustomobject]@{DisallowStartIfOnBatteries=$true;StopIfGoingOnBatteries=$true}
}
function Get-ScheduledTask { param($TaskName,$ErrorAction)
    if ($script:taskExists) { [pscustomobject]@{TaskName=$TASK} }
}
function Stop-ScheduledTask { param($TaskName,$ErrorAction) $script:events += 'stop-task' }
function Stop-Watchers { $script:events += 'stop-watchers' }
function Unregister-ScheduledTask { param($TaskName,[switch]$Confirm,$ErrorAction)
    $script:events += 'remove-task'
    if ($script:removeFails) { throw 'fixture task removal failed' }
    if ($script:protectedTask -and -not $IsElevated) { throw 'Access is denied' }
    $script:taskExists = $false
}
function Request-Elevation {
    [CmdletBinding()] param([string]$Verb,[switch]$TaskRemovalOnly)
    $script:elevations += [pscustomobject]@{Verb=$Verb;TaskRemovalOnly=[bool]$TaskRemovalOnly}
    if ($script:childCode -eq 0 -and $script:childRemoves) {
        $script:taskExists = $false
        $script:protectedTask = $false
    }
    return $script:childCode
}
function Register-ScheduledTask { param($TaskName,$Action,$Principal,$Settings,$Trigger,$Description)
    $script:registrations += [pscustomobject]@{Elevated=$IsElevated;Principal=$Principal;Triggers=@($Trigger | Where-Object {$null -ne $_}).Count}
    $script:events += 'register-task'
    $script:taskExists = $true
    $script:protectedTask = $IsElevated
}
function Enable-ScheduledTask { param($TaskName,$ErrorAction) $script:events += 'enable-task' }
function Start-ScheduledTask { param($TaskName) $script:events += 'start-task' }
function Test-WatcherRunning { $true }
function Set-ConfigValue { param($Path,$Key,$Value) $script:events += "config:$Value" }
function Set-InstalledPath { $script:events += 'path' }

try {
    foreach ($tier in @('user','manual')) {
        $script:tier = $tier
        $script:taskExists = $true
        $script:protectedTask = $true
        $script:registrations = @()
        $script:elevations = @()
        $script:events = @()
        Assert-Equal 0 (Invoke-Install) 'protected task can be replaced with a user tier'
        Assert-Equal 1 $script:elevations.Count 'only one removal prompt is needed'
        Assert-True $script:elevations[0].TaskRemovalOnly 'elevation removes only the protected task'
        Assert-Equal 1 $script:registrations.Count 'the parent registers the replacement task'
        Assert-Equal $false $script:registrations[0].Elevated 'replacement is registered unelevated'
        Assert-Equal $FORUSER $script:registrations[0].Principal.UserId 'replacement belongs to the intended user'
        Assert-Equal 'Interactive' $script:registrations[0].Principal.LogonType
        Assert-Equal 'Limited' $script:registrations[0].Principal.RunLevel
        Assert-Equal $(if ($tier -eq 'manual') {0} else {2}) $script:registrations[0].Triggers
        Assert-Equal 1 @($script:events | Where-Object {$_ -eq 'path'}).Count 'only the normal parent edits PATH'
        Assert-Equal 0 (Invoke-Install) 'a later user-tier change still works'
        Assert-Equal 1 $script:elevations.Count 'the later user-tier change does not elevate again'
        Assert-Equal 2 $script:registrations.Count
    }
    foreach ($childCode in @(1,3)) {
        $script:childCode = $childCode
        $script:taskExists = $true
        $script:protectedTask = $true
        $script:registrations = @()
        $script:events = @()
        Assert-Equal $childCode (Invoke-Install) 'declined or failed removal is not reported as success'
        Assert-Equal 0 $script:registrations.Count 'no replacement is registered after failed removal'
        Assert-Equal 0 @($script:events | Where-Object {$_ -like 'config:*' -or $_ -eq 'path'}).Count
    }
    $script:childCode = 0
    $script:childRemoves = $false
    $script:taskExists = $true
    $script:protectedTask = $true
    $script:registrations = @()
    Assert-Equal 1 (Invoke-Install) 'a successful child code is insufficient while the old task remains'
    Assert-Equal 0 $script:registrations.Count 'never register over an unremoved protected task'

    Import-Subject 'lib\host.ps1' -Functions @('Remove-ProtectedTask')
    $script:events = @()
    Assert-Equal 1 (Remove-ProtectedTask) 'the removal helper refuses an unelevated caller'
    Assert-Equal 0 $script:events.Count 'refusal changes no task, files, configuration or PATH'
    $global:IsElevated = $true
    $script:taskExists = $true
    Assert-Equal 0 (Remove-ProtectedTask) 'the elevated helper removes the old task'
    Assert-Equal 'stop-task,stop-watchers,remove-task' ($script:events -join ',') `
        'the helper performs only task/watch cleanup, never files, registration, config or PATH'
    Assert-Equal $false $script:taskExists
    $script:events = @()
    Assert-Equal 0 (Remove-ProtectedTask) 'an already absent task needs no work'
    Assert-Equal 0 $script:events.Count
    $script:taskExists = $true
    $script:removeFails = $true
    Assert-Equal 1 (Remove-ProtectedTask) 'an elevated removal failure is not success'
    Assert-Equal 0 $script:registrations.Count 'the helper never registers a replacement'

    $script:taskExists = $false
    $script:tier = 's4u'
    $global:IsElevated = $true
    Assert-Equal 0 (Invoke-Install) 'the boot installation can register its host launcher'
    Assert-Equal 'powershell.exe' (Split-Path -Leaf $script:lastAction.Execute) 'boot uses the token-restricting host launcher'
    Assert-Equal '-EncodedCommand fixture-bootstrap' $script:lastAction.Argument 'boot embeds the token restriction before loading installed scripts'

    # The elevated child belongs to a different administrator. Authenticate the
    # intended owner before replacing anything, and dispose the secret always.
    $global:FORUSER = 'FIXTURE\Standard'
    $script:taskExists = $false
    $script:promptFails = $false
    $script:crossFails = $false
    function Request-BootPassword { param($User)
        Assert-Equal $FORUSER $User
        $script:events += 'password'
        if ($script:promptFails) { throw 'fixture credential entry cancelled' }
        $script:password = ConvertTo-SecureString 'synthetic fixture only' -AsPlainText -Force
        return $script:password
    }
    function Register-CrossUserBootTask { param($Name,$User,$Execute,$Arguments,$Password)
        $script:events += 'cross-register'
        Assert-Equal $TASK $Name
        Assert-Equal $FORUSER $User
        Assert-Equal 'powershell.exe' (Split-Path -Leaf $Execute)
        Assert-Equal '-EncodedCommand fixture-bootstrap' $Arguments
        Assert-True ($Password -is [Security.SecureString]) 'credentials remain a secure value until COM authentication'
        if ($script:crossFails) { throw 'fixture authenticated registration failed' }
    }
    $script:events = @()
    Assert-Equal 0 (Invoke-Install) 'separate-administrator boot uses authenticated S4U registration'
    Assert-Equal 'password,files,launcher,cross-register,enable-task,config:boot,start-task' ($script:events -join ',') 'prompt precedes changes; administrator PATH is never edited'
    $disposed = $false
    # PS 5.1 masks a disposed Length getter as null; Copy reliably throws.
    try { $null = $script:password.Copy() } catch { $disposed = $true }
    Assert-True $disposed 'the installation releases its secure password'
    $script:crossFails = $true
    $script:events = @()
    Assert-Equal 1 (Invoke-Install) 'authenticated registration failure is not success'
    Assert-Equal 'password,files,launcher,cross-register' ($script:events -join ',') 'failed authentication cannot enable or start a task'
    $disposed = $false
    try { $null = $script:password.Copy() } catch { $disposed = $true }
    Assert-True $disposed 'failure also releases its secure password'
    $script:crossFails = $false
    $script:promptFails = $true
    $script:events = @()
    Assert-Equal 1 (Invoke-Install) 'cancelled credential entry is a failed install'
    Assert-Equal 'password' ($script:events -join ',') 'cancellation preserves existing task/files/state'
    $global:FORUSER = $ME

    function Test-TaskApiFailures {
        # Module commands can emit nonterminating errors despite a caller's Stop
        # preference. Exercise that boundary, not a mock which always throws.
        $apiState = @{FailAt='';Events=@();Running=$true}
        $apiModule = New-Module -Name 'TriggerKvmTaskApiFixture' -ArgumentList $apiState -ScriptBlock {
            param($State)
            $script:state = $State
            $ErrorActionPreference = 'Continue'
            function Register-ScheduledTask {
                [CmdletBinding()] param($TaskName,$Action,$Principal,$Settings,$Trigger,$Description)
                $script:state.Events += 'register'
                if ($script:state.FailAt -eq 'register') {
                    $PSCmdlet.WriteError([Management.Automation.ErrorRecord]::new([UnauthorizedAccessException]::new('fixture registration denied'),'FixtureDenied',[Management.Automation.ErrorCategory]::PermissionDenied,$TaskName))
                }
            }
            function Enable-ScheduledTask {
                [CmdletBinding()] param($TaskName)
                $script:state.Events += 'enable'
                if ($script:state.FailAt -eq 'enable') {
                    $PSCmdlet.WriteError([Management.Automation.ErrorRecord]::new([UnauthorizedAccessException]::new('fixture enable denied'),'FixtureDenied',[Management.Automation.ErrorCategory]::PermissionDenied,$TaskName))
                }
            }
            function Start-ScheduledTask {
                [CmdletBinding()] param($TaskName)
                $script:state.Events += 'start'
                if ($script:state.FailAt -eq 'start') {
                    $PSCmdlet.WriteError([Management.Automation.ErrorRecord]::new([UnauthorizedAccessException]::new('fixture start denied'),'FixtureDenied',[Management.Automation.ErrorCategory]::PermissionDenied,$TaskName))
                }
            }
            Export-ModuleMember -Function Register-ScheduledTask,Enable-ScheduledTask,Start-ScheduledTask
        }
        Import-Module $apiModule -Force
        function Start-Sleep { param($Seconds,$Milliseconds) }
        function Test-WatcherRunning { $apiState.Events += 'lock'; return $apiState.Running }
        $script:taskExists = $false
        $script:tier = 'manual'
        foreach ($failure in @('register','enable','start')) {
            $apiState.FailAt = $failure
            $apiState.Events = @()
            $script:events = @()
            $messages = Join-Path $root 'api-messages.txt'
            $errors = Join-Path $root 'api-errors.txt'
            $result = Invoke-Install 6> $messages 2> $errors
            Assert-Equal 1 $result "$failure failure is not a successful installation"
            $expected = switch ($failure) {'register' {'register'} 'enable' {'register,enable'} 'start' {'register,enable,start'}}
            Assert-Equal $expected ($apiState.Events -join ',') 'no later task operation or watcher claim after failure'
            Assert-NoMatch (Get-Content -Raw $messages) 'registered and started|Done\. trigger-kvm is running|Installed, and set up' 'failure output must not claim success'
            if ($failure -eq 'register') {
                Assert-Equal 0 @($script:events | Where-Object {$_ -like 'config:*' -or $_ -eq 'path'}).Count 'failed registration cannot record a fallback or edit PATH'
            }
        }
        $apiState.FailAt = ''
        $apiState.Running = $false
        foreach ($tier in @('manual','user')) {
            $script:tier = $tier
            $apiState.Events = @()
            Assert-Equal 1 (Invoke-Install) 'every tier requires a running watcher before claiming success'
            Assert-Equal 'register,enable,start,lock' ($apiState.Events -join ',') 'manual and automatic tiers both inspect the watcher lock'
        }
        Remove-Module $apiModule
    }
    Test-TaskApiFailures

} finally {
    $resolved = (Get-Item -LiteralPath $root).FullName
    if ((Split-Path -Parent $resolved) -ne (Get-Item -LiteralPath $env:TEMP).FullName -or
        (Split-Path -Leaf $resolved) -ne "tk-privilege-$PID") { throw 'Fixture cleanup escaped its temporary root' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
