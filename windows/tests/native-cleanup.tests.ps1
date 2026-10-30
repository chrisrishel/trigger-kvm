# Windows PowerShell 5.1 host parsing and CIM cleanup, using only bounded child
# fixtures. Enumeration is fenced to our recorded PIDs, never the live watcher.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
Import-Subject 'lib\host.ps1' -Functions @('Stop-Watchers','Get-WatcherCommand','Write-WatcherLauncher')
$root = Join-Path $env:TEMP "tk-cleanup-$PID"
New-Item -ItemType Directory -Path $root | Out-Null
$root = (Get-Item -LiteralPath $root).FullName
$global:FORUSER = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$script:fixtureIds = @()
function Get-CimInstance { param($ClassName,$Property,[switch]$Verbose)
    foreach ($fixtureId in $script:fixtureIds) {
        CimCmdlets\Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$fixtureId" -Property $Property
    }
}
function Wait-FixtureReport { param($Path, $Process)
    $limit = (Get-Date).AddSeconds(10)
    while (-not (Test-Path -LiteralPath $Path) -and (Get-Date) -lt $limit -and -not $Process.HasExited) {
        Start-Sleep -Milliseconds 100
    }
    Assert-True (Test-Path -LiteralPath $Path) 'bounded child must execute the fixture script'
    Get-Content -Raw -LiteralPath $Path -Encoding UTF8 | ConvertFrom-Json
}
try {
    $inspect = Join-Path $root 'inspect.ps1'
    @('param($File)',
      '@{Script=$PSCommandPath;File=$File;Version=$PSVersionTable.PSVersion.ToString()} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot ''received.json'') -Encoding UTF8',
      'Start-Sleep -Seconds 20') | Set-Content -LiteralPath $inspect -Encoding ASCII
    $report = Join-Path $root 'received.json'
    # The argument is synthetic data, not a file we execute or create.
    $global:DEST = 'C:\FixtureInstall'
    $global:WATCH = Join-Path $DEST 'event-watch.ps1'
    $global:VBS = Join-Path $DEST 'launcher.vbs'
    $modes = @('-Command','/Command','-c','/c','-co','/co','-comm','', '-File',
        '-EncodedCommand','/EncodedCommand','-ec','-enc')
    foreach ($mode in $modes) {
        Remove-Item -LiteralPath $report -Force -ErrorAction SilentlyContinue
        $command = '.\inspect.ps1 -File C:\FixtureInstall\event-watch.ps1'
        if ($mode -in @('-EncodedCommand','/EncodedCommand','-ec','-enc')) {
            $command = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        }
        $p = Start-Process powershell.exe -WorkingDirectory $root -WindowStyle Hidden -PassThru `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass {0} {1}' -f $mode,$command)
        try {
            $script:fixtureIds = @($p.Id)
            $received = Wait-FixtureReport $report $p
            Assert-Equal $inspect $received.Script "actual executed script for [$mode]"
            Assert-Equal $WATCH $received.File "-File is script data for [$mode]"
            Assert-Match $received.Version '^5\.1\.' 'the child is Windows PowerShell 5.1'
            Stop-Watchers
            Assert-True (-not $p.HasExited) "cleanup must leave unrelated [$mode] fixture alive"
            Write-Host "ok: native cleanup refuses [$mode]; inspect.ps1 received the watcher path as data"
        } finally {
            # A disposable sleep-only child, not a watcher or another application.
            if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit() }
            $p.Dispose()
            $script:fixtureIds = @()
        }
    }

    # Exercise the actual generated WSH + PowerShell launch chain with spaces,
    # an apostrophe and Unicode. The child reports its PID, then sleeps at most
    # 20 seconds; neither fixture has a mutex, event source or monitor code.
    $global:DEST = Join-Path $root ("Fixture Install O'Brien " + [char]0x00E9 + [char]0x6771)
    New-Item -ItemType Directory -Path $DEST | Out-Null
    $global:WATCH = Join-Path $DEST 'event-watch.ps1'
    $global:VBS = Join-Path $DEST 'launcher.vbs'
    @('param($Exec,$Arg,$LogFile,$Config)',
      '@{Script=$PSCommandPath;Id=$PID;Config=$Config} | ConvertTo-Json | Set-Content -LiteralPath $Config -Encoding UTF8',
      'Start-Sleep -Seconds 20') | Set-Content -LiteralPath $WATCH -Encoding ASCII
    Remove-Item -LiteralPath $report -Force
    Write-WatcherLauncher -Path $VBS -Command (Get-WatcherCommand -Watcher $WATCH `
        -Switcher $inspect -LogFile (Join-Path $root 'unused.log') -ConfigFile $report)
    $launcher = Start-Process wscript.exe -WindowStyle Hidden -PassThru -ArgumentList ('"{0}"' -f $VBS)
    $child = $null
    try {
        $received = Wait-FixtureReport $report $launcher
        Assert-Equal $WATCH $received.Script 'generated launcher executes the exact quoted path'
        Assert-Equal $report $received.Config
        $child = Get-Process -Id $received.Id
        $script:fixtureIds = @($launcher.Id,$child.Id)
        Assert-True (-not $launcher.HasExited -and -not $child.HasExited) 'both generated processes are running'
        Stop-Watchers
        Assert-True ($child.WaitForExit(5000)) 'installed watcher launch form remains stoppable'
        Assert-True ($launcher.WaitForExit(5000)) 'quoted installed launcher remains stoppable'
        Write-Host 'ok: native cleanup stops the generated launcher and harmless watcher fixture'
    } finally {
        foreach ($fixture in @($launcher,$child)) {
            if ($null -ne $fixture) {
                if (-not $fixture.HasExited) { $fixture.Kill(); $fixture.WaitForExit() }
                $fixture.Dispose()
            }
        }
        $script:fixtureIds = @()
    }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
