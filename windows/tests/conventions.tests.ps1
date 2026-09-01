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
      Every '-Something' handed to the elevated child, as name -> line.

      .DESCRIPTION
      Keyed on the DOOR -- what is passed to Request-Elevation's -ChildArgs -- and
      not on the name of a variable. An earlier version of this check looked for
      assignments to $childArgs, and when the call sites were rewritten to pass
      their array inline the check went on passing while guarding nothing: the
      only thing left called $ChildArgs was Request-Elevation's own parameter.
      A check that cannot see the thing it is about is worse than no check.

      A flag computed at run time is out of reach here and is not what this is
      for -- every site writes its arguments literally.
    #>
    param([string]$Path)

    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors) { throw ("{0} does not parse: {1}" -f $Path, ($errors[0].Message)) }

    # The array each caller hands over, plus the append inside Request-Elevation
    # that adds the identity to it. Both end up in the child's argument list.
    $lists = @()
    foreach ($c in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        if ($c.GetCommandName() -ne 'Request-Elevation') { continue }
        $els = @($c.CommandElements)
        for ($i = 0; $i -lt $els.Count - 1; $i++) {
            if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and
                $els[$i].ParameterName -eq 'ChildArgs') { $lists += $els[$i + 1] }
        }
    }
    foreach ($asn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        $left = $asn.Left
        if ($left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        if ($left.VariablePath.UserPath -ne 'ChildArgs') { continue }
        $lists += $asn.Right
    }

    $found = @()
    foreach ($l in $lists) {
        foreach ($s in $l.FindAll({ $args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) {
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

# ---- the relaunch never hands the child the PATH edit ------------------------
#
# Add-ToUserPath and Remove-FromUserPath write the 'User' scope, which is
# HKCU\Environment -- and in an elevated child on a STANDARD account, HKCU is the
# ADMIN's hive. A child asked to do it would edit the wrong person's PATH and
# report success. PATH is per-user and never needed elevation, so the parent keeps
# it: see Set-InstalledPath.

$delegated = @($flags | Where-Object { $_.Flag -eq '-AddToPath' })
Assert-Equal 0 $delegated.Count ("the PATH edit must not be delegated to the elevated child, at line(s) " +
                                 (($delegated | ForEach-Object { $_.Line }) -join ', '))

# ---- one door for "whose install is this?" -----------------------------------
#
# On a standard account the elevated child is a DIFFERENT user, so every path and
# principal it derives from its OWN environment is that admin's. $APPDATA and
# $FORUSER are the answers, resolved once at the top of the file from what the
# parent passed; reading the environment anywhere else re-opens the bug.
#
# Same shape as the I2C source gate: one place may say it, and a check holds it
# there. A comment naming the variable is fine -- the ban is on reading it.

$identity = @()
$lines = @(Get-Content -LiteralPath $installer)
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*#') { continue }
    if ($lines[$i] -match '\$env:(LOCALAPPDATA|USERNAME|USERDOMAIN)') {
        # The two resolution lines, and nothing else.
        if ($lines[$i] -match '^\$(ME|APPDATA)\s*=') { continue }
        $identity += ("install.ps1:{0}: {1}" -f ($i + 1), $lines[$i].Trim())
    }
}
Assert-Equal 0 $identity.Count ("only `$ME and `$APPDATA may read whose account this is:`n  " +
                                ($identity -join "`n  "))

# ...and the task is registered as that user, never as whoever is running.
$asWho = @()
foreach ($l in (Select-String -LiteralPath $installer -Pattern 'New-ScheduledTaskPrincipal|New-ScheduledTaskTrigger\s+-AtLogOn')) {
    if ($l.Line -notmatch '\$FORUSER') {
        $asWho += ("install.ps1:{0}: {1}" -f $l.LineNumber, $l.Line.Trim())
    }
}
Assert-Equal 0 $asWho.Count ("every task principal and logon trigger names `$FORUSER:`n  " + ($asWho -join "`n  "))

# ---- the instruction files fit the tools that load them ----------------------
#
# Codex loads the AGENTS.md chain from the git root down to its working
# directory into ONE budget of project_doc_max_bytes (32768 by default) and
# truncates the rest silently, mid-line. Measured 2026-08-31; see
# docs/decisions/002-instruction-files-for-two-agents.md. This is what turns
# "keep it short" from a hope into a failing test.
#
# macos/tests/conventions.tests.sh runs the same check on both chains, so the
# repo is never unprotected; what this adds is that THIS machine finds out on
# its own run, which is the whole point of a suite per platform.
#
# Raw bytes, not lines, and no normalising: that is what Codex reads, and it is
# what the macOS check measures, so the two agree about the same repo. A .md
# written by Set-Content lands as CRLF and counts more here than it does there
# -- .gitattributes says these files are LF, and a failure that names the size
# is how a stray CRLF gets noticed.

$RootDir       = Split-Path -Parent $WinDir
$CODEX_BUDGET  = 32768
$HEADROOM      = 2048
$ROOT_CAP      = 20480
$PLATFORM_CAP  = 10240

$rootBytes = (Get-Item -LiteralPath (Join-Path $RootDir 'AGENTS.md')).Length
Assert-True ($rootBytes -le $ROOT_CAP) `
    ("AGENTS.md is $rootBytes bytes; the cap is $ROOT_CAP. Move evidence to " +
     'docs/measurements.md or a platform AGENTS.md rather than raising this.')

foreach ($platform in 'macos', 'windows') {
    $platBytes = (Get-Item -LiteralPath (Join-Path $RootDir "$platform\AGENTS.md")).Length
    $chain     = $rootBytes + $platBytes
    Assert-True ($platBytes -le $PLATFORM_CAP) `
        "$platform/AGENTS.md is $platBytes bytes; the cap is $PLATFORM_CAP"
    Assert-True ($chain -le ($CODEX_BUDGET - $HEADROOM)) `
        ("AGENTS.md ($rootBytes) + $platform/AGENTS.md ($platBytes) = $chain bytes; " +
         "Codex loads at most $CODEX_BUDGET and drops the rest without a word")
}

# Claude Code reads CLAUDE.md, not AGENTS.md; the @ import is how it gets the
# same instructions. Anything else at the top of a CLAUDE.md is a second copy
# waiting to drift.
foreach ($rel in 'CLAUDE.md', 'macos\CLAUDE.md', 'windows\CLAUDE.md') {
    $first = @(Get-Content -LiteralPath (Join-Path $RootDir $rel) |
               Where-Object { $_.Trim() }) | Select-Object -First 1
    Assert-Equal '@AGENTS.md' $first "$rel must begin with @AGENTS.md"
}

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
$rc = Request-Elevation -ChildArgs @('install', '-Tier', $EffectiveTier)
exit (Request-Elevation -ChildArgs @('install', '-AddToPath'))
function Request-Elevation {
    param([string[]]$ChildArgs)
    $ChildArgs = @($ChildArgs) + @('-Path', $FORUSER)
}
$other = @('-NotEvenLookedAt')
'@ | Set-Content -LiteralPath $relaunch -Encoding ASCII

$declaredT = @(Get-ScriptParameter $relaunch)
Assert-Equal 'Command,AddToPath,Path' ($declaredT -join ',') 'an alias binds too, so it counts as declared'

$flagsT = @(Get-RelaunchFlag $relaunch)
Assert-Equal '-Tier,-AddToPath,-Path' (($flagsT | ForEach-Object { $_.Flag }) -join ',') `
    'every call site and the identity append are read, and nothing else is'

$badT = @($flagsT | Where-Object { $declaredT -notcontains $_.Flag.TrimStart('-') })
Assert-Equal 1       $badT.Count 'the check must see an undeclared flag'
Assert-Equal '-Tier' $badT[0].Flag

# The mutation that got past the earlier version of this check: a call site that
# hands the child the PATH edit.
Assert-Equal 1 @($flagsT | Where-Object { $_.Flag -eq '-AddToPath' }).Count `
    'a delegated PATH edit must be visible at the call site'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
exit 0
