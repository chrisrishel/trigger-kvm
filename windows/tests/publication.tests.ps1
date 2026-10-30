# Native PowerShell regressions for the publication review. All monitor writes,
# process termination and Task Scheduler operations are fixtures.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $WinDir 'config.ps1')
Import-Subject 'lib\menu.ps1' -Variables @('NAME_RULE','BACK') -Functions @(
    'Read-Default','Read-YesNo','Read-Name','Format-Name','Join-Names',
    'Select-One','Select-Many','Get-MenuWidth','Get-ItemWidth','Get-MenuRow','Split-Detail',
    'Write-MenuFrame','Clear-ToLineEnd')
Import-Subject 'lib\answers.ps1' -Variables @('DIALECTS','MCCS_INPUTS','RENAMED_KEYS') -Functions @(
    'New-PanelAnswer','Set-PanelAnswer','Edit-PanelMaps','Get-AttachedManaged',
    'Get-PassSignature','Get-InputName','Get-InputTable','Format-Byte',
    'Get-TriggerEntries','Get-CarriedKeys','Write-ConfigFile')
Import-Subject 'lib\checks.ps1' -Functions @('Invoke-DisplayTest','Invoke-TestRound',
    'Invoke-TestRoundBody','Test-OneComputer','Invoke-PanelSwing','Get-SwingCandidate',
    'Show-MovePreamble','Move-PanelsAndBack','Invoke-TriggerTest')
Import-Subject 'lib\walkthrough.ps1' -Functions @('Read-Computers','Read-ComputerRemovals',
    'Read-Monitors','Read-InputValue','Test-PullAllowed','Update-PassValidity')
Import-Subject 'lib\host.ps1' -Functions @('Stop-Watchers','Get-WatcherPauseMode',
    'Suspend-Watcher','Resume-Watcher','Get-WatcherState','Request-Elevation','Format-ChildArguments',
    'Get-ChildArguments','Set-ConfigValue','Get-TriggerReport')

$global:DEFAULT_DEBOUNCE = '3.0'
$global:DEFAULT_SETTLE = '0.75'
$global:TASK = 'fixture-task'
$global:DEST = 'C:\Fixture Install'
$global:WATCH = Join-Path $DEST 'event-watch.ps1'
$global:VBS = Join-Path $DEST 'launcher.vbs'
$global:FORUSER = 'fixture\owner'
$global:APPDATA = 'C:\Fixture Data'
$global:IsElevated = $false
$global:Relaunched = $false
$global:NoElevate = $false
$global:INVOKED_WITH = @{}
$script:failures = @()
$script:temp = Join-Path $env:TEMP "tk-publication-$PID"
New-Item -ItemType Directory -Force -Path $script:temp | Out-Null
$global:CONFIG = Join-Path $script:temp 'config'

function Write-Host { param([Parameter(ValueFromPipeline=$true)]$Object, [switch]$NoNewline)
    Add-Printed $Object -NoNewline:$NoNewline
}
function Test-Case { param([string]$Name, [scriptblock]$Body)
    try { & $Body; Microsoft.PowerShell.Utility\Write-Host "ok: $Name" }
    catch { $script:failures += $Name; Microsoft.PowerShell.Utility\Write-Host "FAIL: $Name -- $_" }
}
function New-TestPanel { param([string]$Label = 'one', $Map = ([ordered]@{ pc='0x11'; mac='0x12' }))
    New-PanelAnswer -Label $Label -Name $Label -Method 'standard' -Transport 'nvapi' `
        -EdidVendor 1 -EdidProduct 2 -Mfg 'TEST' -Map $Map
}
$script:outcomes = @()
function Test-DisplayInput { [CmdletBinding()]param($Name,$CandidateName,$ThisName,[switch]$IsComputer)
    if (-not $script:outcomes.Count) { return 0 }
    $v = $script:outcomes[0]; $script:outcomes = @($script:outcomes | Select-Object -Skip 1); return $v
}
function Get-DisplayAnswers { param($Found,$Existing,$Computers,$This,$Labels)
    New-TestPanel -Label 'edited' -Map ([ordered]@{ pc='0x0F'; mac='0x12' })
}

Test-Case 'declined transport-only check stays untested' {
    $p = New-TestPanel -Map ([ordered]@{pc='0x11'})
    Set-Answers @('n'); Reset-Sent
    $r = Invoke-DisplayTest @($p) 'pc'
    Assert-Equal 0 (Get-Sent).Count
    Assert-True (-not $r.Ok) 'no write or visual confirmation cannot grant a pass'
    Assert-Equal 'not checked' $r.Text
    Assert-True (-not (Test-PullAllowed -Ran $r -Answers @($p)))
}
Test-Case 'selected panel without another computer really gets checked' {
    $p = New-TestPanel -Map ([ordered]@{pc='0x11'})
    $q = New-TestPanel -Label 'two'
    Set-Answers @('2',''); Reset-Sent
    $r = Invoke-DisplayTest @($p,$q) 'pc'
    Assert-Equal 2 (Get-Sent).Count 'scope must be applied before deciding whether a panel needs a transport check'
    Assert-True $r.Ok
    Assert-Equal 'one' ($r.Scope -join ',')
}
Test-Case 'mixed scope checks the panel with only this computer too' {
    $p = New-TestPanel -Map ([ordered]@{pc='0x11'})
    $q = New-TestPanel -Label 'two'
    Set-Answers @('1','','','y'); Reset-Sent
    $r = Invoke-DisplayTest @($p,$q) 'pc'
    Assert-True ((Get-Sent) -match '^one=') 'a pass must include an actual check for every scoped panel'
}
Test-Case 'declined retry cannot authorize pull' {
    $p = New-TestPanel
    Set-Answers @('y','n','n'); Reset-Sent
    $r = Invoke-DisplayTest @($p) 'pc'
    Assert-True (-not $r.Ok)
    Assert-Equal 'not checked' $r.Text
}
Test-Case 'removing an unconfirmed target is not a pass' {
    $p = New-TestPanel
    $script:outcomes = @(1)
    Set-Answers @('y','n','y','10'); Reset-Sent
    $r = Invoke-DisplayTest @($p) 'pc'
    Assert-True (-not $r.Ok)
}
Test-Case 'single-panel repair reports removal as untested' {
    $p = New-TestPanel
    $script:outcomes = @(1)
    Set-Answers @('y','10')
    $result = Test-OneComputer -Answer $p -All @($p) -This pc -Target mac -Config $CONFIG
    Assert-True ($null -eq $result) 'removing a target is neither a confirmed pass nor a panel failure'
}
Test-Case 'repairing the return input invalidates earlier computer checks' {
    $p = New-TestPanel -Map ([ordered]@{pc='0x11';mac='0x12';linux='0x10'})
    $script:outcomes = @(2,0)
    Set-Answers @('y','y','y','n','y','y','1','y')
    $r = Invoke-DisplayTest @($p) 'pc'
    Assert-True (-not $r.Ok) 'mac was checked against an older return input'
    Assert-Equal 'not checked' $r.Text
}
Test-Case 'computer rename then Escape restores maps and pass signature' {
    $p = New-TestPanel; $sig = Get-PassSignature @($p)
    Set-Answers @('2','renamed','q')
    $r = Read-Computers -This pc -Others @('mac') -Existing -Panels @($p)
    Assert-Equal 'pc,mac' ($r.All -join ',')
    Assert-Equal $sig (Get-PassSignature @($p))
    Assert-True (-not $r.Edited)
}
Test-Case 'computer addition then Escape restores names' {
    $p = New-TestPanel
    Set-Answers @('4','linux','q')
    $r = Read-Computers -This pc -Others @('mac') -Existing -Panels @($p)
    Assert-Equal 'pc,mac' ($r.All -join ',')
}
Test-Case 'fresh computer questionnaire then Escape stays unconfigured' {
    Set-Answers @('renamed','1','mac','q')
    $r = Read-Computers -This pc -Others @() -Panels @()
    Assert-Equal 'pc' $r.This
    Assert-Equal 0 $r.All.Count 'Escape must not mark the first-run computer question answered'
    Assert-True (-not $r.Edited)
}
Test-Case 'nested removal then Escape restores map' {
    $p = New-TestPanel -Map ([ordered]@{pc='0x11';mac='0x12';linux='0x0F'})
    $sig = Get-PassSignature @($p)
    Set-Answers @('1','y','q')
    $r = Read-ComputerRemovals -Others @('mac','linux') -Panels @($p)
    Assert-Equal 'mac,linux' ($r.Remaining -join ',')
    Assert-Equal $sig (Get-PassSignature @($p))
    Assert-True (-not $r.Edited)
}
Test-Case 'completed panel edit then Escape restores monitor list' {
    $p = New-TestPanel; $sig = Get-PassSignature @($p)
    $found = @([pscustomobject]@{EdidVendor=1;EdidProduct=2;Name='one';Mfg='TEST';Panels=1})
    Set-Answers @('1','q')
    $r = @(Read-Monitors -Found $found -Answers @($p) -Computers @('pc','mac') -This pc)
    Assert-Equal $sig (Get-PassSignature $r)
}

$script:processes = @()
$script:stopped = @()
function Get-CimInstance { param($ClassName,$Property,[switch]$Verbose) $script:processes }
function Invoke-CimMethod { param($InputObject,$MethodName,$ErrorAction)
    [pscustomobject]@{ReturnValue=0;Domain='fixture';User=$InputObject.Owner}
}
function Stop-Process { param($Id,[switch]$Force,$ErrorAction) $script:stopped += $Id }
Test-Case 'cleanup is limited by script position, full path and owner' {
    $script:processes = @(
        [pscustomobject]@{ProcessId=1;Name='powershell.exe';CommandLine='powershell.exe -File "C:\Fixture Install\event-watch.ps1" -Arg pull';Owner='owner'},
        [pscustomobject]@{ProcessId=2;Name='wscript.exe';CommandLine='wscript.exe "C:\Fixture Install\launcher.vbs"';Owner='owner'},
        [pscustomobject]@{ProcessId=3;Name='powershell.exe';CommandLine='powershell.exe -File C:\OtherTool\event-watch.ps1';Owner='owner'},
        [pscustomobject]@{ProcessId=4;Name='wscript.exe';CommandLine='wscript.exe C:\OtherTool\launcher.vbs';Owner='owner'},
        [pscustomobject]@{ProcessId=5;Name='powershell.exe';CommandLine='powershell.exe -File "C:\Fixture Install\event-watch.ps1"';Owner='visitor'},
        [pscustomobject]@{ProcessId=6;Name='powershell.exe';CommandLine='powershell.exe -File C:\OtherTool\script.ps1 -Text "C:\Fixture Install\event-watch.ps1"';Owner='owner'},
        [pscustomobject]@{ProcessId=7;Name='powershell.exe';CommandLine='powershell.exe -Command "Write-Output ''C:\Fixture Install\event-watch.ps1''"';Owner='owner'}
    )
    $script:stopped = @(); Stop-Watchers
    Assert-Equal '1,2' ($script:stopped -join ',')
}
$script:taskEnabled = $true
$script:running = $true
$script:actions = @()
$script:childMode = 'timeout'
function Get-ScheduledTask { param($TaskName,$ErrorAction)
    [pscustomobject]@{Principal=[pscustomobject]@{LogonType='Interactive'};State=$(if ($script:taskEnabled) {'Ready'} else {'Disabled'});Settings=[pscustomobject]@{Enabled=$script:taskEnabled}}
}
function Test-WatcherRunning { $script:running }
function Disable-ScheduledTask { param($TaskName,$ErrorAction) $script:taskEnabled=$false; $script:actions += 'disable' }
function Stop-ScheduledTask { param($TaskName,$ErrorAction) $script:running=$false; $script:actions += 'stop' }
function Enable-ScheduledTask { param($TaskName,$ErrorAction) $script:taskEnabled=$true; $script:actions += 'enable' }
function Start-ScheduledTask { param($TaskName,$ErrorAction) $script:running=$true; $script:actions += 'start' }
function Invoke-Sibling { param($Script,$Arguments)
    if ($script:childMode -eq 'error') { throw 'fixture child error' }
    if ($script:childMode -eq 'cancel') { throw 'ran out of input. fixture cancellation' }
    $global:LASTEXITCODE = 1
}
foreach ($expectedEnabled in @($true,$false)) {
    foreach ($expectedRunning in @($true,$false)) {
        foreach ($mode in @('timeout','error','cancel')) {
            Test-Case "restore enabled=$expectedEnabled running=$expectedRunning after $mode" {
                $script:taskEnabled=$expectedEnabled; $script:running=$expectedRunning; $script:childMode=$mode
                $script:actions=@(); $script:processes=@()
                try { $null = Invoke-TriggerTest -Devices @('usb:0001:0002') -Answers @() -This pc }
                catch { if ($_ -notmatch 'fixture') { throw } }
                Assert-Equal $expectedEnabled $script:taskEnabled 'prior task enablement'
                Assert-Equal $expectedRunning $script:running 'prior watcher running state'
            }
        }
    }
}
function Start-ElevatedChild { param($Command) $script:inner=$Command; return $null }
Test-Case 'apostrophes in elevated and manual commands parse' {
    $global:TK_SELF = "C:\Users\O'Brien\install.ps1"
    Request-Elevation install | Out-Null
    $errors=$null
    [Management.Automation.Language.Parser]::ParseInput($script:inner,[ref]$null,[ref]$errors) | Out-Null
    Assert-Equal 0 @($errors).Count
    $global:NoElevate=$true; Reset-Printed
    Request-Elevation install | Out-Null
    $manual=((Get-Printed) -split 'elevated PowerShell:')[1].Trim()
    [Management.Automation.Language.Parser]::ParseInput($manual,[ref]$null,[ref]$errors) | Out-Null
    Assert-Equal 0 @($errors).Count
    $global:NoElevate=$false
}
Test-Case 'generated and updated config retains Unicode' {
    $name = 'Panel ' + [char]0x00E9 + [char]0x6771
    $p=New-TestPanel; $p.Name=$name
    Write-ConfigFile -Path $CONFIG -Displays @($p) -Devices @() -This pc -Tier user -Existing @{'custom.note'=$name}
    Assert-Equal $name (Read-Config $CONFIG)['display.one.name']
    Set-ConfigValue $CONFIG 'install.autostart' 'login'
    Set-ConfigValue $CONFIG 'install.autostart' 'boot'
    Assert-Equal $name (Read-Config $CONFIG)['custom.note']
    [IO.File]::WriteAllText($CONFIG, "custom.note = $name", (New-Object Text.UTF8Encoding $false))
    Assert-Equal $name (Read-Config $CONFIG)['custom.note'] 'BOM-less UTF-8 hand edits also survive'
}
Test-Case 'status uses resolver verdict for every saved entry' {
    $r=Get-TriggerReport -Entries @('usb:0001:0002','usb:0001:0002@missing','bt:001122334455') `
        -Candidates @() -Verdicts @{'usb:0001:0002'='present';'usb:0001:0002@missing'='absent';'bt:001122334455'='absent'}
    Assert-Match ($r -join "`n") 'current saved configuration'
    Assert-Match ($r -join "`n") 'trigger-kvm restart'
    Assert-Match ($r -join "`n") 'present'
    Assert-Match ($r -join "`n") 'absent'
}
Test-Case 'empty saved triggers do not describe the running watcher' {
    foreach ($entries in @(@(),@('   '))) {
        $r = (Get-TriggerReport -Entries $entries -Candidates @()) -join "`n"
        Assert-Match $r 'current saved configuration'
        Assert-Match $r 'trigger-kvm restart'
        Assert-Match $r 'running watcher may still hold an older configuration'
        Assert-Match $r 'none configured in the saved configuration'
        Assert-NoMatch $r 'nothing will ever fire'
    }
}
Test-Case 'fractional settle reaches sleep as milliseconds' {
    $src=Get-Content -Raw (Join-Path $WinDir 'event-watch.ps1')
    $ast=[Management.Automation.Language.Parser]::ParseInput($src,[ref]$null,[ref]$null)
    $sleep=@($ast.FindAll({param($a) $a -is [Management.Automation.Language.CommandAst] -and $a.GetCommandName() -eq 'Start-Sleep' -and $a.Extent.Text -match '\$Settle'},$true))
    Assert-Equal 1 $sleep.Count
    foreach ($Settle in @(0.25,0.75,1.125)) {
        $script:delay=0
        function Start-Sleep { param([int]$Seconds,[int]$Milliseconds) $script:delay=1000*$Seconds+$Milliseconds }
        Invoke-Expression $sleep[0].Extent.Text
        Assert-Equal ($Settle*1000) $script:delay
    }
}
Test-Case 'NVAPI shipping and probe loaders restrict DLL search' {
    foreach ($file in @('trigger-kvm.ps1','nvapi-probe.ps1')) {
        $src=Get-Content -Raw (Join-Path $WinDir $file)
        Assert-True ($src -notmatch '\bLoadLibrary\("nvapi64.dll"\)') "$file must not search untrusted directories"
        Assert-True ($src -match 'LoadLibraryEx\(.*Environment.SystemDirectory.*0x00000800') "$file must restrict dependencies too"
    }
}

Test-Case 'overflow retains unbreakable identifiers and erases leftover rows' {
    $id = 'usb:0001:0002@' + ('long-token-' * 8) + '@port-1'
    $rows = @(Get-MenuRow -Item $id -Detail 'first, second' -Marker ' >' -ItemWidth 44 -Width 24)
    Assert-True (($rows -join "`n").Contains($id)) 'the entire identifier survives a narrow terminal'
    Reset-Printed
    $n = Write-MenuFrame -Lines @('short') -Width 40 -Previous 5
    Assert-Equal 1 $n
    Assert-Equal 5 $script:Printed.Count 'the old folded rows are erased, not just the new row'
}

Remove-Item -LiteralPath $script:temp -Recurse -Force
if ($script:failures.Count) { throw "publication regressions: $($script:failures -join '; ')" }
