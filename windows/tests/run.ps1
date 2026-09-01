<#
.SYNOPSIS
Run every test in this directory.

.DESCRIPTION
    .\run.ps1                 all of them
    .\run.ps1 menus           only files whose name contains "menus"
    .\run.ps1 -Verbose        show every prompt and answer

Each *.tests.ps1 file runs in its own powershell.exe. That is not tidiness: the
walkthrough tests define stubs with the same names as real functions, and the type
tests deliberately load a stale copy of the switcher into their runspace. Sharing one
process would let those leak into each other.

A file that cannot run on this machine reports SKIPPED, LOUDLY, and is counted
separately -- never as a pass. Two of them need real hardware, and those are the
only tests of the exact packets and of every refusal, so a quiet skip meant a
contributor's green run proved nothing about the part where a mistake is
expensive.

Exit code is the number of files that failed, so CI can just check it. A skip is
not a failure -- it is a fact about the machine -- so it does not raise it.
#>
[CmdletBinding()]
param([string]$Filter = '')

$ErrorActionPreference = 'Stop'
$files = @(Get-ChildItem -Path $PSScriptRoot -Filter '*.tests.ps1' | Sort-Object Name)
if ($Filter) { $files = @($files | Where-Object { $_.Name -like "*$Filter*" }) }
if ($files.Count -eq 0) { Write-Host "no test files match '$Filter'"; exit 1 }

if ($VerbosePreference -eq 'Continue') { $env:TK_TEST_VERBOSE = '1' } else { $env:TK_TEST_VERBOSE = '' }

$failed  = 0
$skipped = @()
foreach ($f in $files) {
    # Continue, and *>&1: a failing child writes a terminating error to stderr, and
    # under Stop with a bare 2>&1 that arrives wrapped in NativeCommandError noise
    # with the actual assertion message truncated -- which is the one thing a test
    # runner exists to show you.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $f.FullName *>&1 |
           ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -eq 0) {
        Write-Host ("  PASS  {0}" -f $f.Name)
        if ($env:TK_TEST_VERBOSE) { $out | ForEach-Object { Write-Host "        $_" } }
    } elseif ($code -eq 2) {
        # Exit-Skipped. Printed with its reason every time, because the whole
        # point is that a skip must be impossible to mistake for a pass.
        $skipped += $f.Name
        Write-Host ("  SKIP  {0}" -f $f.Name)
        $out | Where-Object { $_ -match '^SKIPPED' } | ForEach-Object { Write-Host "        $_" }
    } else {
        $failed++
        Write-Host ("  FAIL  {0}" -f $f.Name)
        $out | ForEach-Object { Write-Host "        $_" }
    }
}

Write-Host ''
$ran = $files.Count - $skipped.Count
if ($failed -eq 0) { Write-Host ("all {0} test files passed" -f $ran) }
else               { Write-Host ("{0} of {1} test files FAILED" -f $failed, $ran) }
if ($skipped.Count -gt 0) {
    Write-Host ("{0} did NOT run on this machine and proved nothing: {1}" -f $skipped.Count, ($skipped -join ', '))
}
exit $failed
