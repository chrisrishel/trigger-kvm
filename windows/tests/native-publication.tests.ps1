# Native OS checks with isolated, harmless child programs. No installation,
# task registration, device events, monitor writes or real watcher termination.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $WinDir 'config.ps1')
Import-Subject 'lib\host.ps1' -Functions @('Write-WatcherLauncher','Get-WatcherCommand',
    'Request-Elevation','Get-ChildArguments','Format-ChildArguments','Stop-Watchers','Get-ShimLines',
    'Test-CanElevate','Get-CurrentTokenClaims')

# whoami reports deny-only groups that WindowsIdentity.Groups omits. Compare
# the actual eligibility function with the independent native token view.
$nativeGroups = @(& whoami.exe /groups /fo csv /nh |
    ConvertFrom-Csv -Header 'Group','Kind','Sid','Attributes')
Assert-Equal 0 $LASTEXITCODE 'native token groups can be read'
Assert-True ($nativeGroups.Count -gt 0) 'the native group view is not empty'
$nativeAdmin = [bool]($nativeGroups.Sid -contains 'S-1-5-32-544')
$tokenClaims = @(Get-CurrentTokenClaims)
$claimedAdmin = @($tokenClaims | Where-Object {
    $_.Type -in @([Security.Claims.ClaimTypes]::GroupSid,[Security.Claims.ClaimTypes]::DenyOnlySid) -and
    $_.Value -eq 'S-1-5-32-544'
}).Count -gt 0
Assert-Equal $nativeAdmin $claimedAdmin 'claims preserve native administrator membership after the identity is disposed'
$global:IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
Assert-Equal $nativeAdmin (Test-CanElevate) `
    'boot eligibility includes the native deny-only administrator membership'
$root = Join-Path $env:TEMP ("tk-native-$PID-O'Brien-" + [char]0x00E9 + [char]0x6771)
New-Item -ItemType Directory -Path $root -Force | Out-Null
# TEMP may contain a DOS 8.3 alias. GetTempFileName and enumeration return long
# paths; compare the same path representation without dropping Unicode checks.
$root = (Get-Item -LiteralPath $root).FullName
$global:FORUSER = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$global:APPDATA = $root
$global:INVOKED_WITH = @{}
$global:Relaunched = $false
$global:NoElevate = $false
$script:commands = @()
function Start-ElevatedChild { param($Command) $script:commands += $Command; return $null }

try {
    # Run Request-Elevation's exact command in an unelevated native child. UAC
    # and cross-user installation remain release checks, not unit-test actions.
    $child = Join-Path $root 'child.ps1'
    @('param($Command,[switch]$Relaunched,$ForUser,$ForAppData)',
      'Write-Output ''native child reached''', 'exit 7') | Set-Content $child -Encoding ASCII
    $global:TK_SELF = $child
    $oldTemp = $env:TEMP
    $oldTmp = $env:TMP
    try {
        $shortRoot = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($root).ShortPath
        $env:TEMP = $shortRoot
        $env:TMP = $shortRoot
        Request-Elevation install | Out-Null
    } finally { $env:TEMP = $oldTemp; $env:TMP = $oldTmp }
    $inner = $script:commands[-1]
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($inner,[ref]$null,[ref]$parseErrors)
    Assert-Equal 0 @($parseErrors).Count 'installer AND transcript paths parse'
    $redirect = $ast.Find({param($a) $a -is [Management.Automation.Language.FileRedirectionAst]},$true)
    $transcript = $redirect.Location.SafeGetValue()
    Assert-True ($transcript.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) 'the transcript exercises apostrophes and Unicode too'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    $p = Start-Process powershell.exe -WindowStyle Hidden -Wait -PassThru -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
    Assert-Equal 7 $p.ExitCode 'native child exit code survives the wrapper'
    Assert-Match (Get-Content -Raw -LiteralPath $transcript) 'native child reached'

    # The real WSH reader executes the generated UTF-16 launcher from a Unicode
    # path. Its child only writes its received paths to JSON, then exits.
    $output = Join-Path $root 'received.json'
    $harmless = Join-Path $root 'harmless.ps1'
    @('param($Exec,$Arg,$LogFile,$Config)',
      '@($PSCommandPath,$Exec,$LogFile,$Config) | ConvertTo-Json | Set-Content -LiteralPath $Config -Encoding UTF8') |
        Set-Content -LiteralPath $harmless -Encoding ASCII
    $launcher = Join-Path $root 'launcher.vbs'
    Write-WatcherLauncher -Path $launcher -Command (Get-WatcherCommand -Watcher $harmless `
        -Switcher $child -LogFile (Join-Path $root 'log') -ConfigFile $output)
    & cscript.exe //nologo $launcher | Out-Null
    Assert-Equal 0 $LASTEXITCODE 'Windows Script Host accepted the generated encoding'
    $received = Get-Content -Raw -LiteralPath $output -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal $harmless $received[0]
    Assert-Equal $child $received[1]
    Assert-Equal $output $received[3]

    # The ASCII CMD shim holds relative paths; cmd.exe must preserve Unicode
    # when expanding its own location and forwarding to Windows PowerShell.
    $bin = Join-Path $root 'bin'
    New-Item -ItemType Directory -Path $bin | Out-Null
    $shim = Join-Path $bin 'trigger-kvm.cmd'
    Get-ShimLines | Set-Content -LiteralPath $shim -Encoding ASCII
    @('param($Command)',
      '@($Command,$PSCommandPath) | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot ''shim-result.json'') -Encoding UTF8') |
        Set-Content -LiteralPath (Join-Path $root 'install.ps1') -Encoding ASCII
    & $shim status | Out-Null
    Assert-Equal 0 $LASTEXITCODE 'CMD shim reaches its Unicode parent path'
    $shimResult = Get-Content -Raw -LiteralPath (Join-Path $root 'shim-result.json') -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 'status' $shimResult[0]
    Assert-Equal (Join-Path $root 'install.ps1') $shimResult[1]

    # Uninstall deletes the installed CMD shim while cmd.exe is executing it.
    # Exercise that boundary with a harmless child deleting only these fixtures,
    # and preserve both success and failure exit codes from PowerShell.
    foreach ($uninstallCode in @(0,7)) {
        Get-ShimLines | Set-Content -LiteralPath $shim -Encoding ASCII
        @('param($Command)',
          'if ($Command -ne ''uninstall'') { exit 9 }',
          'Remove-Item -LiteralPath (Join-Path $PSScriptRoot ''bin\trigger-kvm.cmd'') -Force',
          'Remove-Item -LiteralPath $PSCommandPath -Force',
          ('exit {0}' -f $uninstallCode)) |
            Set-Content -LiteralPath (Join-Path $root 'install.ps1') -Encoding ASCII
        $savedPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $uninstallOutput = @(& $shim uninstall 2>&1 | ForEach-Object { "$_" })
            $actualCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $savedPreference }
        Assert-True (-not (Test-Path $shim)) 'the fixture uninstaller removed its own CMD shim'
        Assert-Equal $uninstallCode $actualCode ('self-deleting CMD shim preserves the uninstaller exit code; '+($uninstallOutput -join ' '))
    }

    # A caller using CALL must regain control; closing its command interpreter
    # would hide this error by discarding the caller's remaining work.
    $caller = Join-Path $root 'caller.cmd'
    $continued = Join-Path $root 'caller-continued'
    foreach ($uninstallCode in @(0,7)) {
        Get-ShimLines | Set-Content -LiteralPath $shim -Encoding ASCII
        @('param($Command)',
          'Remove-Item -LiteralPath (Join-Path $PSScriptRoot ''bin\trigger-kvm.cmd'') -Force',
          ('exit {0}' -f $uninstallCode)) |
            Set-Content -LiteralPath (Join-Path $root 'install.ps1') -Encoding ASCII
        @('@echo off','call "%~dp0bin\trigger-kvm.cmd" uninstall',
          'set "result=%errorlevel%"','> "%~dp0caller-continued" echo continued',
          'exit /b %result%') | Set-Content -LiteralPath $caller -Encoding ASCII
        Remove-Item -LiteralPath $continued -ErrorAction SilentlyContinue
        & $caller | Out-Null
        Assert-Equal $uninstallCode $LASTEXITCODE 'uninstall returns its exit code to a calling batch file'
        Assert-True (Test-Path $continued) 'the calling batch file continues after uninstall'
    }

    # Exact path / GetOwner behavior against a native process. This is a
    # harmless fixture named event-watch.ps1, never the installed watcher.
    $global:DEST = Join-Path $root 'install'
    New-Item -ItemType Directory -Path $DEST | Out-Null
    $global:WATCH = Join-Path $DEST 'event-watch.ps1'
    $global:VBS = Join-Path $DEST 'launcher.vbs'
    $ready = Join-Path $root 'ready'
    @('param($Ready)', 'Set-Content -LiteralPath $Ready -Value ready',
      'Start-Sleep -Seconds 25') | Set-Content -LiteralPath $WATCH -Encoding ASCII
    $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $WATCH),'-Ready',('"{0}"' -f $ready))
    try {
        $limit = (Get-Date).AddSeconds(10)
        while (-not (Test-Path $ready) -and (Get-Date) -lt $limit) {
            Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 100
        }
        Assert-True (Test-Path $ready) 'the harmless fixture process started'
        Stop-Watchers
        Assert-True ($p.WaitForExit(5000)) 'the exact installed script and intended owner are stoppable natively'
    } finally {
        # This bounded test child has no lock or event source; it is not a watcher.
        if (-not $p.HasExited) { $p.Kill() }
        $p.Dispose()
    }

    # A real, hidden Windows console; all output inspected from buffer cells.
    # The parent test process has redirected output and cannot measure folds.
    $probe = Join-Path $root 'console.ps1'
    $report = Join-Path $root 'console.json'
    $body = @'
param($Menu,$Report)
$ErrorActionPreference='Stop'
try {
    . $Menu
    $results=@()
    foreach ($width in @(24,60,80,120)) {
        [Console]::SetWindowSize([Math]::Min($width,[Console]::WindowWidth),10)
        [Console]::SetBufferSize($width,300)
        foreach ($length in @(($width-1),$width,($width+1),(2*$width),(2*$width+1))) {
            $dirty=New-Object Management.Automation.Host.Rectangle 0,2,($width-1),12
            $fill=New-Object Management.Automation.Host.BufferCell ('Z',[ConsoleColor]::Gray,[ConsoleColor]::Black,[Management.Automation.Host.BufferCellType]::Complete)
            $Host.UI.RawUI.SetBufferContents($dirty,$fill)
            [Console]::SetCursorPosition(0,2)
            $text='X'*$length
            $n=Write-MenuFrame -Lines @($text,'old tail') -Width ($width-1)
            $actual=[Console]::CursorTop-2
            if ($n -ne $actual) { throw "width=$width length=$length reported=$n actual=$actual" }
            $used=New-Object Management.Automation.Host.Rectangle 0,2,($width-1),(2+$n-1)
            $painted=-join @($Host.UI.RawUI.GetBufferContents($used) | ForEach-Object { $_.Character })
            if ($painted.Contains('Z')) { throw 'a folded line left stale cells behind' }
            $next=Write-MenuFrame -Lines @('short') -Width ($width-1) -Previous $n
            if ($next -ne 1 -or [Console]::CursorTop -ne 3) { throw 'redraw cursor drifted' }
            $rect=New-Object Management.Automation.Host.Rectangle 0,2,($width-1),(2+$n-1)
            $cells=$Host.UI.RawUI.GetBufferContents($rect)
            $seen=-join @($cells | ForEach-Object { $_.Character })
            if ($seen.Trim() -ne 'short') { throw "leftover folded/last-column/tail cells: $seen" }
            $results += "width=$width length=$length"
        }
    }
    @{Ok=$true;Cases=$results.Count} | ConvertTo-Json | Set-Content -LiteralPath $Report -Encoding UTF8
} catch {
    @{Ok=$false;Error="$_"} | ConvertTo-Json | Set-Content -LiteralPath $Report -Encoding UTF8
    exit 1
}
'@
    Set-Content -LiteralPath $probe -Value $body -Encoding ASCII
    $p = Start-Process powershell.exe -WindowStyle Hidden -Wait -PassThru -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $probe),
        '-Menu',('"{0}"' -f (Join-Path $WinDir 'lib\menu.ps1')),'-Report',('"{0}"' -f $report))
    $result = Get-Content -Raw -LiteralPath $report -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 0 $p.ExitCode ($result | ConvertTo-Json -Compress)
    Assert-True $result.Ok
    Assert-Equal 20 $result.Cases 'real console fold and shrinking-frame cases'

    # Compile the actual two embedded bindings. Init resolves functions but
    # never writes. Then exercise absence with a harmless Windows DLL sitting
    # in the current directory under the missing library's name.
    foreach ($file in @('trigger-kvm.ps1','nvapi-probe.ps1')) {
        $source = Get-Content -Raw -LiteralPath (Join-Path $WinDir $file)
        $cs = [regex]::Match($source, "(?ms)@'\r?\n(using System;.*?)\r?\n'@").Groups[1].Value
        Assert-True ($cs.Length -gt 0)
        Add-Type -TypeDefinition $cs
        $typeName = if ($file -eq 'trigger-kvm.ps1') { 'NvDdc' } else { 'NvProbe' }
        $type = $typeName -as [type]
        $init = $type.GetMethod('Init').Invoke($null,@())
        if ($init -like 'FAIL:*') {
            Skip-Case "$typeName real driver" $init
        } else {
            $loaded = @([Diagnostics.Process]::GetCurrentProcess().Modules | Where-Object { $_.ModuleName -ieq 'nvapi64.dll' })
            Assert-Equal 1 $loaded.Count
            Assert-True ([string]::Equals((Join-Path ([Environment]::SystemDirectory) 'nvapi64.dll'),
                $loaded[0].FileName, [StringComparison]::OrdinalIgnoreCase)) 'the native module path is the system DLL (Windows path comparison)'
        }
        $missingName = "tk-no-nvapi-$PID.dll"
        Copy-Item -LiteralPath (Join-Path ([Environment]::SystemDirectory) 'version.dll') -Destination (Join-Path $root $missingName) -Force
        $namespace = "Missing$typeName"
        Add-Type -TypeDefinition ("namespace $namespace {`n" + $cs.Replace('"nvapi64.dll"', ('"{0}"' -f $missingName)) + "`n}")
        $missingType = "$namespace.$typeName" -as [type]
        $oldDirectory = [Environment]::CurrentDirectory
        try {
            [Environment]::CurrentDirectory = $root
            $absent = $missingType.GetMethod('Init').Invoke($null,@())
            Assert-Match $absent 'not found \(no NVIDIA driver\?\)' 'absence must not search the current directory'
        } finally { [Environment]::CurrentDirectory = $oldDirectory }
    }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
