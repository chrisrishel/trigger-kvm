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

function Assert-NoMatch {
    param([string]$Text, [string]$Pattern, [string]$Because)
    if ($Text -match $Pattern) {
        throw ("'{0}' matches /{1}/ and should not{2}" -f $Text, $Pattern,
               $(if ($Because) { " -- $Because" } else { '' }))
    }
}

# ---- a scripted person ------------------------------------------------------

# Every prompt in the walkthrough goes through Read-Host, so one stub drives all of
# them. Running out of answers throws rather than blocking, which is what makes a
# flow change show up as a failed test instead of a hung run.
$script:Answers = @()
$script:Asked   = @()

function Set-Answers { param([string[]]$A) $script:Answers = @($A); $script:Asked = @() }
function Get-Asked   { return $script:Asked }

function Read-Host {
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
