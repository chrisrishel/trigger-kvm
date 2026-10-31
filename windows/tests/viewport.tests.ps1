# Synthetic menus only, in a bounded real Windows PowerShell console.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
$root = Join-Path $env:TEMP ('tk-viewport-' + $PID + '-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$process = $null
try {
    $report = Join-Path $root 'console.json'
    $process = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f (Join-Path $PSScriptRoot 'fixtures\menu-viewport-console.ps1')),
        '-Menu',('"{0}"' -f (Join-Path $WinDir 'lib\menu.ps1')),'-Report',('"{0}"' -f $report))
    Assert-True ($process.WaitForExit(90000)) 'native menu fixture must complete within its bound'
    Assert-True (Test-Path -LiteralPath $report) 'native menu fixture must publish its result'
    $result = Get-Content -LiteralPath $report -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True $result.Ok ($result | ConvertTo-Json -Compress -Depth 4)
    Assert-Equal 27 $result.Cases 'all native viewport cases reached their completion guard'
} finally {
    if ($process) {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
    $resolved = (Get-Item -LiteralPath $root).FullName
    if ((Split-Path -Parent $resolved) -ne (Get-Item -LiteralPath $env:TEMP).FullName -or
        -not (Split-Path -Leaf $resolved).StartsWith("tk-viewport-$PID-")) { throw 'Cleanup escaped the viewport fixture directory' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
