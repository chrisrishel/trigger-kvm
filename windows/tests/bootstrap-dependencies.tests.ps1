# Fresh native processes, isolated hostile modules and harmless bounded children.
# No task, real profile/module, persistent environment or installation is changed.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $WinDir 'lib\user-launch.ps1')
$root = Join-Path $env:TEMP ("tk-bootstrap-$PID-O'Brien-" + [char]0x00E9 + [char]0x6771)
New-Item -ItemType Directory -Path $root -Force | Out-Null
$root = (Get-Item -LiteralPath $root).FullName
$process = $null
try {
    $modules = Join-Path $root 'modules'
    $utility = Join-Path $modules 'Microsoft.PowerShell.Utility'
    New-Item -ItemType Directory -Path $utility -Force | Out-Null
    @'
@{RootModule='Microsoft.PowerShell.Utility.psm1';ModuleVersion='99.0.0';FunctionsToExport=@('Add-Type','Write-Error');CmdletsToExport=@();AliasesToExport=@()}
'@ | Set-Content -LiteralPath (Join-Path $utility 'Microsoft.PowerShell.Utility.psd1') -Encoding ASCII
    @'
function Add-Type {
    [CmdletBinding()]param([string]$TypeDefinition)
    [IO.File]::WriteAllText($env:TK_BOOT_MODULE_MARKER, 'substitute Add-Type')
    throw 'fixture module executed before restriction'
}
function Write-Error {
    [CmdletBinding()]param($Message)
    [IO.File]::WriteAllText($env:TK_BOOT_ERROR_MARKER, 'substitute Write-Error')
}
Export-ModuleMember -Function Add-Type,Write-Error
'@ | Set-Content -LiteralPath (Join-Path $utility 'Microsoft.PowerShell.Utility.psm1') -Encoding ASCII
    $watcher = Join-Path $root 'harmless.ps1'
    @'
param($Exec,$Arg,$LogFile,$Config)
[IO.File]::WriteAllText($Config, 'bounded child reached')
exit 7
'@ | Set-Content -LiteralPath $watcher -Encoding ASCII
    # Self-test the adversary in a fresh process; a preloaded trusted module or
    # ineffective search-path setup must not turn this boundary test green.
    $controlMarker = Join-Path $root 'control-module.txt'
    $controlError = Join-Path $root 'control-error.txt'
    $control = New-Object Diagnostics.ProcessStartInfo
    $control.FileName = Join-Path $PSHOME 'powershell.exe'
    $control.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' +
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('try { Add-Type -TypeDefinition ''public class FixtureControl {}'' } catch { Write-Error $_ -ErrorAction Continue }; exit 1'))
    $control.UseShellExecute = $false
    $control.CreateNoWindow = $true
    $control.EnvironmentVariables['PSModulePath'] = $modules + ';' + $env:PSModulePath
    $control.EnvironmentVariables['TK_BOOT_MODULE_MARKER'] = $controlMarker
    $control.EnvironmentVariables['TK_BOOT_ERROR_MARKER'] = $controlError
    $process = [Diagnostics.Process]::Start($control)
    Assert-True ($process.WaitForExit(20000)) 'bounded hostile-module control finished'
    Assert-Equal 1 $process.ExitCode 'hostile-module control exit'
    Assert-True (Test-Path -LiteralPath $controlMarker) 'the substitute Add-Type really resolves in a fresh native process'
    Assert-True (Test-Path -LiteralPath $controlError) 'the substitute Write-Error really resolves too'
    $process.Dispose()
    $process = $null

    # Bait files cannot be selected as compiler, assembly or compression DLL.
    # PowerShell startup itself may create TEMP; boot must leave no build files.
    $bait = Join-Path $root 'bait'
    New-Item -ItemType Directory -Path $bait | Out-Null
    foreach ($file in @('csc.exe','System.dll','clrcompression.dll')) {
        [IO.File]::WriteAllText((Join-Path $bait $file), 'invalid fixture image')
    }
    $savedSource = $UserLaunchSource
    $commandCounts = @()
    foreach ($mode in @('success','restriction-failure','assembly-failure','decompression-failure')) {
        $UserLaunchSource = $savedSource
        if ($mode -eq 'restriction-failure') {
            $UserLaunchSource = $UserLaunchSource.Replace('IntPtr token = CreateOrdinaryToken();',
                'throw new InvalidOperationException("fixture restriction failure"); IntPtr token = CreateOrdinaryToken();')
        }
        $report = Join-Path $root ($mode + '.txt')
        $logFile = Join-Path $root ($mode + '.log')
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = Join-Path $PSHOME 'powershell.exe'
        $start.Arguments = Get-BootTaskArguments -Watcher $watcher -Switcher $watcher -LogFile $logFile -ConfigFile $report
        $encoded = ($start.Arguments -split ' -EncodedCommand ',2)[1]
        $bootstrap = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
        $parseErrors = $null
        $tree = [Management.Automation.Language.Parser]::ParseInput($bootstrap, [ref]$null, [ref]$parseErrors)
        Assert-Equal 0 @($parseErrors).Count 'the protected task script parses'
        $commandCounts += @($tree.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true)).Count
        if ($mode -eq 'assembly-failure') {
            $bootstrap = $bootstrap.Replace('[void][Reflection.Assembly]::Load($assembly.ToArray())',
                '[void][Reflection.Assembly]::Load([byte[]]@(1,2,3))')
            $start.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
        }
        if ($mode -eq 'decompression-failure') {
            $bootstrap = [regex]::Replace($bootstrap, "\[Convert\]::FromBase64String\('[^']+'\)",
                "[Convert]::FromBase64String('AAAAAAAAAAAAAA==')")
            $start.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
        }
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardError = $true
        $start.WorkingDirectory = $bait
        $marker = Join-Path $root ($mode + '-module.txt')
        $errorMarker = Join-Path $root ($mode + '-error-module.txt')
        $start.EnvironmentVariables['PSModulePath'] = $modules + ';' + $env:PSModulePath
        $start.EnvironmentVariables['TK_BOOT_MODULE_MARKER'] = $marker
        $start.EnvironmentVariables['TK_BOOT_ERROR_MARKER'] = $errorMarker
        $start.EnvironmentVariables['PSExecutionPolicyPreference'] = 'Bypass'
        $start.EnvironmentVariables['PATH'] = $bait
        $start.EnvironmentVariables['TEMP'] = Join-Path $root 'missing-temp'
        $start.EnvironmentVariables['TMP'] = Join-Path $root 'missing-temp'
        # The child must be fresh: inspecting Add-Type through Get-Command or
        # pre-importing the real Utility module would conceal the boundary.
        $process = [Diagnostics.Process]::Start($start)
        $errors = $process.StandardError.ReadToEndAsync()
        Assert-True ($process.WaitForExit(20000)) 'bounded dependency fixture finished'
        Assert-True (-not (Test-Path -LiteralPath $marker)) 'bootstrap never executes a user-supplied Add-Type module before restriction'
        Assert-True (-not (Test-Path -LiteralPath $errorMarker)) 'bootstrap error handling never executes a user-supplied module'
        Assert-Equal $(if ($mode -eq 'success') {7} else {1}) $process.ExitCode ('bootstrap exit code: ' + $errors.Result)
        Assert-Equal ($mode -eq 'success') (Test-Path -LiteralPath $report) 'only successful restriction starts the harmless child'
        Assert-True (-not (Test-Path -LiteralPath $logFile)) 'no privileged user-log write'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath (Join-Path $root 'missing-temp') -File -Recurse -ErrorAction SilentlyContinue).Count `
            'boot leaves no compiler scratch files'
        if ($mode -eq 'restriction-failure') { Assert-Match $errors.Result 'fixture restriction failure' 'failure remains observable on stderr' }
        $process.Dispose()
        $process = $null
    }
    Assert-Equal 0 ($commandCounts | Measure-Object -Sum).Sum `
        'pre-restriction startup and failure paths perform no PowerShell command resolution'
    $UserLaunchSource = 'fixture: not valid C#'
    $refused = $false
    try { Get-BootTaskArguments -Watcher $watcher -Switcher $watcher -LogFile $logFile -ConfigFile $report | Out-Null }
    catch { $refused = $_.Exception.Message -like 'Cannot build the boot launcher:*' }
    Assert-True $refused 'a registration-time compiler failure cannot produce a task command'
} finally {
    if ($process) {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
    $resolved = (Get-Item -LiteralPath $root).FullName
    if ((Split-Path -Parent $resolved) -ne (Get-Item -LiteralPath $env:TEMP).FullName -or
        -not (Split-Path -Leaf $resolved).StartsWith("tk-bootstrap-$PID-")) { throw 'Cleanup escaped the dependency fixture root' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
