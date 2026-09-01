# Structural conventions -- the things no unit test reaches, because they are
# properties of the FILES rather than of any behaviour.
#
# This exists because of a specific failure. install.ps1 defined seven functions
# twice, and PowerShell takes the LATER definition, so the monitor check ran an
# older version of itself: the two-question flow specs/configure.md 10.4
# describes was present in the file and dead, with a single-question one live
# above it.
#
# Nothing else here could have found that. The conformance check greps for
# strings and both versions' wording was present, so it was green. And the unit
# tests were green too, for a worse reason -- lib.ps1's Import-Subject pulls a
# function out by regex and takes the FIRST match, which is the opposite end
# from the one PowerShell runs. So display-question.tests.ps1 was exercising the
# dead definition and passing, while the live one went untested.
#
# A string check proves a string is PRESENT. This is the half that asks whether
# it is REACHABLE.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$WinDir = Split-Path -Parent $PSScriptRoot

function Get-TopLevelFunction {
    <#
      .SYNOPSIS
      Every function defined at a script's top level, as name -> line numbers.

      .DESCRIPTION
      The AST rather than a regex on '^function', which would miss an indented
      definition and cannot tell a top-level one from a nested one.

      Nested functions are scoped to their parent, so two of the same name in
      two different parents shadow nothing and are not what this is looking for.
      Only definitions whose ancestors contain no other function are counted.
    #>
    param([string]$Path)

    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors) { throw ("{0} does not parse: {1}" -f $Path, ($errors[0].Message)) }

    $found = @{}
    foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $nested = $false
        for ($p = $fn.Parent; $p; $p = $p.Parent) {
            if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $nested = $true; break }
        }
        if ($nested) { continue }
        if (-not $found.ContainsKey($fn.Name)) { $found[$fn.Name] = @() }
        $found[$fn.Name] += $fn.Extent.StartLineNumber
    }
    return $found
}

# ---- no script defines the same function twice ------------------------------

$scripts = @(Get-ChildItem -LiteralPath $WinDir -Filter '*.ps1' -File) +
           @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File)

$complaints = @()
foreach ($s in $scripts) {
    $fns = Get-TopLevelFunction $s.FullName
    foreach ($name in $fns.Keys) {
        if ($fns[$name].Count -gt 1) {
            $complaints += ("{0} defines {1} {2} times, at lines {3} -- PowerShell runs the LAST one" -f
                            $s.Name, $name, $fns[$name].Count, ($fns[$name] -join ', '))
        }
    }
}

Assert-Equal 0 $complaints.Count ("duplicate definitions:`n  " + ($complaints -join "`n  "))

# ---- nothing shadows a built-in cmdlet ---------------------------------------
#
# A function named after a real cmdlet wins inside the script that defines it and
# loses everywhere else, which is the worst of both. This is not hypothetical:
# the computer-removal menu was called Remove-Computer, which is a real cmdlet
# that removes a machine from a DOMAIN. install.ps1 shadowed it, and the moment a
# test called it without importing the function, PowerShell resolved the real one
# and reported "NamedParameterNotFound, RemoveComputerCommand".
#
# The shipped scripts only. Test files shadow Write-Host, Read-Host and
# Start-Sleep deliberately -- that is what stubbing IS -- and the whole harness
# depends on it.

$shadowed = @()
foreach ($s in @(Get-ChildItem -LiteralPath $WinDir -Filter '*.ps1' -File)) {
    foreach ($name in (Get-TopLevelFunction $s.FullName).Keys) {
        $builtin = Get-Command -Name $name -CommandType Cmdlet -ErrorAction SilentlyContinue
        if ($builtin) {
            $shadowed += ("{0} defines {1}, which is a real cmdlet ({2})" -f
                          $s.Name, $name, $builtin.Source)
        }
    }
}

Assert-Equal 0 $shadowed.Count ("functions shadowing cmdlets:`n  " + ($shadowed -join "`n  "))

# ---- "computer", never "machine", in anything the user can see ---------------
#
# specs/configure.md 2. The conformance check cannot ask this: it tests PRESENCE,
# so it can require the right word and never notice the wrong one sitting beside
# it. Absence needs its own check.
#
# Scope is what the user reads -- strings printed at runtime, and the
# comment-based help block Get-Help renders. Source comments are not user-visible
# and are left alone; several of them use "machine" correctly, about the host as
# hardware.

function Get-UserVisibleLine {
    param([string]$Path)

    $lines = @(Get-Content -LiteralPath $Path)
    $out   = @()
    $inHelp = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match '^<#')  { $inHelp = $true;  continue }
        if ($l -match '^#>')  { $inHelp = $false; continue }
        if ($inHelp) { $out += [pscustomobject]@{ Line = $i + 1; Text = $l }; continue }
        # A quoted string reaching the user: Write-Host, Write-Log, or a prompt.
        if ($l -match '^\s*#') { continue }
        if ($l -match 'Write-(Host|Log)|Read-Line|Read-Default|Read-YesNo') {
            $out += [pscustomobject]@{ Line = $i + 1; Text = $l }
        }
    }
    return $out
}

$saidMachine = @()
foreach ($s in @(Get-ChildItem -LiteralPath $WinDir -Filter '*.ps1' -File)) {
    foreach ($l in (Get-UserVisibleLine $s.FullName)) {
        # -cmatch: "Machine" capitalised at the start of a sentence counts too.
        if ($l.Text -imatch '\bmachines?\b') {
            $saidMachine += ("{0}:{1}: {2}" -f $s.Name, $l.Line, $l.Text.Trim())
        }
    }
}

Assert-Equal 0 $saidMachine.Count ("the user must never be shown ""machine"":`n  " + ($saidMachine -join "`n  "))

# ---- the elevated relaunch's arguments bind against this script's param() ----
#
# install.ps1 relaunches ITSELF elevated, by name, with an argument list built as a
# literal. Nothing checks that list against the parameters the script declares, and
# the failure is invisible from the parent: `param()` is [CmdletBinding()], which
# THROWS on an unknown named argument, and the child runs in a hidden window whose
# output the parent only prints if the child got far enough to write any.
#
# That shipped. One of the three relaunch sites passed `-Tier $EffectiveTier`, a
# parameter that has never existed, so the documented recovery from an
# admin-owned task died at parameter binding while the parent reported that the
# task had been left exactly as it was.

function Get-ScriptParameter {
    param([string]$Path)
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors) { throw ("{0} does not parse: {1}" -f $Path, ($errors[0].Message)) }
    if (-not $ast.ParamBlock) { return @() }
    $names = @()
    foreach ($p in $ast.ParamBlock.Parameters) {
        $names += $p.Name.VariablePath.UserPath
        # An alias binds just as well as the parameter's own name.
        foreach ($a in $p.Attributes) {
            if ($a -is [System.Management.Automation.Language.AttributeAst] -and $a.TypeName.Name -eq 'Alias') {
                foreach ($arg in $a.PositionalArguments) {
                    if ($arg -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $names += $arg.Value }
                }
            }
        }
    }
    return $names
}

function Get-RelaunchFlag {
    <#
      .SYNOPSIS
      Every '-Something' written into a $childArgs literal, as name -> line.

      .DESCRIPTION
      Both shapes: the assignment that builds the list, and the `+=` that appends
      to it. A flag computed at run time is out of reach here and is not what this
      is for -- all three sites write theirs literally.
    #>
    param([string]$Path)

    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors) { throw ("{0} does not parse: {1}" -f $Path, ($errors[0].Message)) }

    $found = @()
    foreach ($asn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        $left = $asn.Left
        if ($left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        if ($left.VariablePath.UserPath -ne 'childArgs') { continue }
        foreach ($s in $asn.Right.FindAll({ $args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) {
            if ($s.Value -match '^-\w') {
                $found += [pscustomobject]@{ Flag = $s.Value; Line = $s.Extent.StartLineNumber }
            }
        }
    }
    return $found
}

$installer = Join-Path $WinDir 'install.ps1'
$declared  = @(Get-ScriptParameter $installer)
$flags     = @(Get-RelaunchFlag $installer)

Assert-True ($flags.Count -gt 0) 'the relaunch check must have found some flags to check'

$unbound = @()
foreach ($f in $flags) {
    if ($declared -notcontains $f.Flag.TrimStart('-')) {
        $unbound += ("install.ps1:{0}: {1} is not a parameter of install.ps1" -f $f.Line, $f.Flag)
    }
}
Assert-Equal 0 $unbound.Count ("the elevated relaunch passes what it cannot bind:`n  " + ($unbound -join "`n  "))

# ---- the check can actually see one ------------------------------------------

# A structural check that cannot fail is decoration, and this one is easy to
# write so that it never fires. Prove it against a throwaway file.
$tmp = Join-Path $env:TEMP 'trigger-kvm-conventions'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$dupe = Join-Path $tmp 'dupe.ps1'
@'
function Get-Thing { 'first' }
function Get-Thing { 'second' }
'@ | Set-Content -LiteralPath $dupe -Encoding ASCII

$fns = Get-TopLevelFunction $dupe
Assert-Equal 2 $fns['Get-Thing'].Count 'the duplicate scan must see a plain duplicate'

# ...and does not fire on a nested one, which shadows nothing.
$nested = Join-Path $tmp 'nested.ps1'
@'
function Outer-A { function Helper { 'a' }; Helper }
function Outer-B { function Helper { 'b' }; Helper }
'@ | Set-Content -LiteralPath $nested -Encoding ASCII

$fns = Get-TopLevelFunction $nested
Assert-True (-not $fns.ContainsKey('Helper')) 'a function scoped inside another is not a duplicate'

# ...and the relaunch check sees a flag its own param() does not declare, in both
# the assignment and the append, while leaving a declared one and an alias alone.
$relaunch = Join-Path $tmp 'relaunch.ps1'
@'
[CmdletBinding()]
param(
    [string]$Command = 'install',
    [Alias('Path')]
    [switch]$AddToPath
)
$childArgs = @('install', '-Tier', $EffectiveTier)
if ($AddToPath) { $childArgs += '-AddToPath' }
$childArgs += '-Path'
$other = @('-NotEvenLookedAt')
'@ | Set-Content -LiteralPath $relaunch -Encoding ASCII

$declaredT = @(Get-ScriptParameter $relaunch)
Assert-Equal 'Command,AddToPath,Path' ($declaredT -join ',') 'an alias binds too, so it counts as declared'

$flagsT = @(Get-RelaunchFlag $relaunch)
Assert-Equal '-Tier,-AddToPath,-Path' (($flagsT | ForEach-Object { $_.Flag }) -join ',') `
    'both the assignment and the append are read, and nothing else is'

$badT = @($flagsT | Where-Object { $declaredT -notcontains $_.Flag.TrimStart('-') })
Assert-Equal 1       $badT.Count 'the check must see an undeclared flag'
Assert-Equal '-Tier' $badT[0].Flag

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
exit 0
