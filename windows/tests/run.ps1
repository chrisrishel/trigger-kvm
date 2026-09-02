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

That holds a CASE at a time as well as a file at a time: every line beginning
`SKIPPED:` is printed whatever the verdict, and counted in the summary, because a
file that passed everything it ran is still not a file that ran.

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
$skippedCases = 0

# Every line a file wrote that begins `SKIPPED:`, indented under its verdict.
function Show-Skips { param([string[]]$Out) $Out | Where-Object { $_ -match '^SKIPPED' } | ForEach-Object { Write-Host "        $_" } }

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
    # Skip-Case. Only a file that did NOT exit 2 can have called it -- Exit-Skipped
    # ends the file -- so in that output one `SKIPPED:` line is exactly one skipped
    # case, and there is nothing else to tell it apart from.
    if ($code -ne 2) { $skippedCases += @($out | Where-Object { $_ -match '^SKIPPED' }).Count }

    if ($code -eq 0) {
        Write-Host ("  PASS  {0}" -f $f.Name)
        # A pass is where a skipped case used to disappear: this branch printed
        # nothing unless -Verbose, so the file's own SKIPPED line was swallowed and
        # the run said all green. Not repeated under -Verbose, which dumps it below.
        if ($env:TK_TEST_VERBOSE) { $out | ForEach-Object { Write-Host "        $_" } }
        else                      { Show-Skips $out }
    } elseif ($code -eq 2) {
        # Exit-Skipped. Printed with its reason every time, because the whole
        # point is that a skip must be impossible to mistake for a pass.
        $skipped += $f.Name
        Write-Host ("  SKIP  {0}" -f $f.Name)
        Show-Skips $out
    } else {
        # Everything is printed here already, skipped cases included -- but they
        # still have to reach the summary, which the count above does.
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
if ($skippedCases -gt 0) {
    Write-Host ("{0} case(s) inside the files that did run were skipped -- see SKIPPED above" -f $skippedCases)
}
exit $failed
