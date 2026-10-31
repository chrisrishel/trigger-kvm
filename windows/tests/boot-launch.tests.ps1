# Actual host launcher and native token checks; only bounded fixture children.
# No task registration, installation, monitor access or real watcher is used.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $WinDir 'lib\user-launch.ps1')
Initialize-UserLaunch

$facts = New-Object TkUserTokenFacts
$facts.Integrity = 8192
$facts.Privileges = @('SeChangeNotifyPrivilege')
[TkUserLaunch]::RequireOrdinaryToken($facts)
foreach ($unsafe in @('administrator','power-user','high-integrity','privilege')) {
    $facts.Administrator = ($unsafe -eq 'administrator')
    $facts.PowerUser = ($unsafe -eq 'power-user')
    $facts.Integrity = if ($unsafe -eq 'high-integrity') {12288} else {8192}
    $facts.Privileges = if ($unsafe -eq 'privilege') {@('SeChangeNotifyPrivilege','SeDebugPrivilege')} else {@('SeChangeNotifyPrivilege')}
    $refused = $false
    try { [TkUserLaunch]::RequireOrdinaryToken($facts) } catch { $refused = $true }
    Assert-True $refused "unsafe token refused: $unsafe"
}

$root = Join-Path $env:TEMP ("tk-boot-$PID-O'Brien-" + [char]0x00E9 + [char]0x6771)
New-Item -ItemType Directory -Path (Join-Path $root 'lib') -Force | Out-Null
$root = (Get-Item -LiteralPath $root).FullName
$process = $null
try {
    Copy-Item -LiteralPath (Join-Path $WinDir 'lib\user-launch.ps1') -Destination (Join-Path $root 'lib')
    Set-Content -LiteralPath (Join-Path $root 'trigger-kvm.ps1') -Value '# fixture, never executed' -Encoding ASCII
    $watcher = Join-Path $root 'event-watch.ps1'
    @(
        'param($Exec,$Arg,$LogFile,$Config)',
        '$ErrorActionPreference = ''Stop''',
        '. (Join-Path $PSScriptRoot ''lib\user-launch.ps1'')',
        'Initialize-UserLaunch',
        '$token = [TkUserLaunch]::CurrentToken()',
        '[ordered]@{Exec=$Exec;Arg=$Arg;LogFile=$LogFile;Config=$Config;Token=$token} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Config -Encoding UTF8',
        'exit 7'
    ) | Set-Content -LiteralPath $watcher -Encoding ASCII
    $report = Join-Path $root 'received.json'
    $logFile = Join-Path $root 'fixture.log'
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $PSHOME 'powershell.exe'
    $start.Arguments = Get-BootTaskArguments -Watcher $watcher -Switcher (Join-Path $root 'trigger-kvm.ps1') -LogFile $logFile -ConfigFile $report
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    $errors = $process.StandardError.ReadToEndAsync()
    Assert-True ($process.WaitForExit(20000)) 'bounded native boot fixture finished'
    Assert-Equal 7 $process.ExitCode ('launcher preserves the fixture exit code: ' + $errors.Result)
    $result = Get-Content -Raw -LiteralPath $report -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal (Join-Path $root 'trigger-kvm.ps1') $result.Exec 'quoted switcher path survives'
    Assert-Equal 'pull' $result.Arg 'the host launches the detector for pull only'
    Assert-Equal $report $result.Config 'quoted configuration path survives'
    Assert-Equal $logFile $result.LogFile 'quoted log path survives'
    Assert-Equal ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) $result.Token.UserSid 'restriction retains the owner'
    Assert-Equal ([Diagnostics.Process]::GetCurrentProcess().SessionId) $result.Token.Session 'restriction retains the session'
    Assert-Equal $false $result.Token.Administrator 'child has no enabled administrator membership'
    Assert-Equal $false $result.Token.PowerUser 'child has no enabled power-user membership'
    Assert-Equal 8192 $result.Token.Integrity 'child runs at medium integrity'
    Assert-Equal 0 @($result.Token.Privileges | Where-Object {$_ -ne 'SeChangeNotifyPrivilege'}).Count 'no retained administrative privileges, even disabled ones'

    # A launch failure has no path that executes with the original token.
    $refused = $false
    try { [TkUserLaunch]::Run((Join-Path $root 'missing.exe'), '', $root) | Out-Null }
    catch { $refused = $true }
    Assert-True $refused 'a failed restricted launch is refused'

    $UserLaunchSource += "`n// fixture source change"
    $refused = $false
    try { Initialize-UserLaunch } catch { $refused = $_.Exception.Message -match 'already loaded' }
    Assert-True $refused 'native token code cannot silently reuse a different loaded build'
} finally {
    if ($process) {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
    $resolved = (Get-Item -LiteralPath $root).FullName
    if ((Split-Path -Parent $resolved) -ne (Get-Item -LiteralPath $env:TEMP).FullName -or
        -not (Split-Path -Leaf $resolved).StartsWith("tk-boot-$PID-")) { throw 'Cleanup escaped the boot fixture root' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
