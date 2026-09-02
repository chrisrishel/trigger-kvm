# Shared scaffolding for the tests.
#
# No test framework. Pester 5 is not in the box on Windows PowerShell 5.1 -- the one
# that ships is 3.4, and requiring `Install-Module` to run the tests would put a
# gallery dependency in front of a project whose whole claim is that it needs nothing
# but stock PowerShell. A test here is a script that throws when something is wrong,
# which is all the framework this needs.
#
# The unit tests pull functions OUT of install.ps1 by name rather than dot-sourcing
# it, because dot-sourcing would run the installer.

# As the scripts under test run. Without this a whole class of failure is invisible
# here and hits the user instead: indexing [0] into an empty match, reading a
# property that was never set, using an undeclared variable. All of those are quiet
# under the default mode and terminating under Latest, which is the mode install.ps1
# sets on its first line.
Set-StrictMode -Version Latest

$script:WinDir = Split-Path -Parent $PSScriptRoot

function Import-Subject {
    <#
      .SYNOPSIS
      Define the named functions and variables from one of the scripts, without
      running it.

      .NOTES
      The regex is non-greedy, so a name defined twice in one file imports the
      FIRST definition -- and PowerShell runs the LAST. That is the opposite end,
      and it is not theoretical: install.ps1 shadowed seven functions, and this
      importer quietly handed the tests the dead copy of Test-DisplayInput, which
      passed while the live one went unexercised.

      conventions.tests.ps1 forbids the duplicate outright, which is the fix.
      Do not make this one pick the last definition instead -- that would make
      the tests agree with PowerShell about which dead code they were running.
    #>
    param([string]$Script, [string[]]$Functions = @(), [string[]]$Variables = @())

    $src = Get-Content -Raw (Join-Path $script:WinDir $Script)
    foreach ($fn in $Functions) {
        $m = [regex]::Match($src, "(?ms)^function\s+$fn\s*\{.*?^\}")
        if (-not $m.Success) { throw "$Script has no function $fn" }
        # Two rewrites before this is evaluated:
        #   global:   Invoke-Expression inside a function defines into THAT function's
        #             scope, so without this every imported function vanishes the
        #             moment Import-Subject returns.
        #   $PSScriptRoot is empty in Invoke-Expression'd code and is read-only, so
        #             the real directory is baked in.
        $def = $m.Value -replace "^function\s+$fn", "function global:$fn"
        Invoke-Expression ($def -replace [regex]::Escape('$PSScriptRoot'), $script:WinDir)
    }
    foreach ($v in $Variables) {
        # Either a block that ends in a brace at column 0, or a one-line assignment.
        $m = [regex]::Match($src, "(?ms)^\`$$v = .*?^\}")
        if (-not $m.Success) { $m = [regex]::Match($src, "(?m)^\`$$v = .*$") }
        if (-not $m.Success) { throw "$Script has no variable $v" }
        Invoke-Expression ($m.Value -replace ('^\$' + $v), ('$global:' + $v))
    }
}

# ---- capturing what was printed ---------------------------------------------

# Every test that asserts on output stubs Write-Host, and the stub HAS TO HONOUR
# -NoNewline, because the real one does and Write-MenuFrame relies on it: a frame
# line is written in three parts -- the text, the erase to the end of the line,
# then the newline. A stub without the switch fails the call outright, and one
# that ignores it turns every frame line into three.
#
# So the accumulator lives here, once, rather than being re-typed per file with a
# subtly different signature each time.
$script:Printed = @()
$script:Partial = ''

function Add-Printed {
    param($Object, [switch]$NoNewline)
    if ($NoNewline) { $script:Partial += "$Object"; return }
    $script:Printed += ($script:Partial + "$Object")
    $script:Partial  = ''
}
function Get-Printed   { return ($script:Printed -join "`n") }
function Reset-Printed { $script:Printed = @(); $script:Partial = '' }

# ---- skipping ---------------------------------------------------------------

# A SKIP IS NOT A PASS, and the exit code has to say so.
#
# Two files need real hardware: resolve.tests.ps1 wants the two reference panels
# attached, and types.tests.ps1 wants an NVIDIA driver to load a type from. Both
# used to `exit 0` when they could not run, and run.ps1 counted that as PASS --
# so on every machine but the reference desk, the only tests of the exact packets
# and of every refusal quietly did not run and the suite reported all green.
#
# Both halves below print a line beginning `SKIPPED:`, which is the string run.ps1
# surfaces WHATEVER the verdict -- so a file that skipped part of itself cannot read
# as one that ran.

# The whole FILE cannot run here. 2 rather than 1, so run.ps1 can tell "did not run"
# from "ran and failed".
function Exit-Skipped {
    param([string]$Why)
    Write-Host "SKIPPED: $Why"
    exit 2
}

# One CASE cannot run here. The file goes on to pass or fail on everything else, so
# this is a printed line and nothing more: an exit code would report a file that
# mostly ran as one that did not.
#
# No tally to go with it, unlike macOS. There, `finish` prints a count and run.sh
# reads it, because exit_skipped writes a `SKIPPED:` line too and the two have to be
# told apart. Here there is no per-file end hook to hang a count on -- and none is
# needed: a file that did not exit 2 never calls Exit-Skipped, so in its output one
# `SKIPPED:` line is exactly one skipped case, and run.ps1 counts lines.
function Skip-Case {
    param([string]$Case, [string]$Why)
    Write-Host "SKIPPED: $Case -- $Why"
}

# ---- assertions -------------------------------------------------------------

function Assert-Equal {
    param($Expected, $Actual, [string]$Because)
    if ("$Expected" -ne "$Actual") {
        throw ("expected '{0}', got '{1}'{2}" -f $Expected, $Actual,
               $(if ($Because) { " -- $Because" } else { '' }))
    }
}

function Assert-True {
    param($Condition, [string]$Because)
    if (-not $Condition) { throw ("expected true{0}" -f $(if ($Because) { " -- $Because" } else { '' })) }
}

function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Because)
    if ($Text -notmatch $Pattern) {
        throw ("'{0}' does not match /{1}/{2}" -f $Text, $Pattern,
               $(if ($Because) { " -- $Because" } else { '' }))
    }
}

function Assert-MatchCase {
    <#
      .SYNOPSIS
      Assert-Match, but case-sensitively.

      .DESCRIPTION
      PowerShell's -match is CASE-INSENSITIVE. That is fine for prose and wrong
      for anything where the case IS the meaning -- a yes/no default is spelled
      "[y/N]" or "[Y/n]", and a plain -match for one accepts the other, which is
      the opposite default and the whole point of the assertion.

      Found by a mutation that survived: flipping the removal confirm to default
      YES left the suite green.
    #>
    param([string]$Text, [string]$Pattern, [string]$Because)
    if ($Text -cnotmatch $Pattern) {
        throw ("'{0}' does not match /{1}/ case-sensitively{2}" -f $Text, $Pattern,
               $(if ($Because) { " -- $Because" } else { '' }))
    }
}

function Assert-NoMatch {
    param([string]$Text, [string]$Pattern, [string]$Because)
    if ($Text -match $Pattern) {
        throw ("'{0}' matches /{1}/ and should not{2}" -f $Text, $Pattern,
               $(if ($Because) { " -- $Because" } else { '' }))
    }
}

# ---- a scripted person ------------------------------------------------------

# Every prompt in the walkthrough goes through Read-Line, so one stub drives all of
# them. Running out of answers throws rather than blocking, which is what makes a
# flow change show up as a failed test instead of a hung run.
#
# Read-Line, not Read-Host: the real one reads [Console]::In when stdin is
# redirected, because Windows PowerShell 5.1's Read-Host reads the CONSOLE and
# never sees a piped answer at all. Stubbing Read-Host would leave the function
# that actually decides that untested -- which is stdin.tests.ps1's job.
$script:Answers = @()
$script:Asked   = @()

function Set-Answers { param([string[]]$A) $script:Answers = @($A); $script:Asked = @() }
function Get-Asked   { return $script:Asked }

function Read-Line {
    param([string]$Prompt)
    $script:Asked += $Prompt.Trim()
    if ($script:Answers.Count -eq 0) { throw "ran out of scripted answers at: $($Prompt.Trim())" }
    $a = $script:Answers[0]
    $script:Answers = @($script:Answers | Select-Object -Skip 1)
    if ($env:TK_TEST_VERBOSE) { Write-Host ("    [prompt] {0} -> '{1}'" -f $Prompt.Trim(), $a) }
    return $a
}

# The menus fall back to typed input when the host cannot read individual keys, and a
# test host cannot. Forced rather than inferred so a test never depends on how it was
# launched.
function Test-CanReadKeys { $false }
function Test-CanPrompt   { $true }

# The real holds are 8s + 2s per round. That is the point on hardware and dead weight
# here.
function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }

# ---- nothing may touch a monitor -------------------------------------------

# Send-Input is the single place the installer emits a packet. Stubbing it is what
# keeps the suite from switching the developer's own displays mid-test.
$script:Sent = @()
function Send-Input {
    param([string]$Label, [string]$Value, [string]$Config)
    $script:Sent += ('{0}={1}' -f $Label, $Value)
}
function Reset-Sent { $script:Sent = @() }
function Get-Sent   { return ,@($script:Sent) }   # comma: keep the array, so .Count survives

function Write-Log { param([string]$m) if ($env:TK_TEST_VERBOSE) { Write-Host "install: $m" } }

# The user PATH, as a GLOBAL rather than a redefinable stub. Import-Subject defines
# the code under test with `function global:`, and a test that redefines a helper at
# its own script scope does not reliably reach it -- the redefinition looks like it
# took and quietly did not, which is the least useful kind of test failure.
$global:TestUserPath = 'C:\Windows'
function Get-UserPath { $global:TestUserPath }
