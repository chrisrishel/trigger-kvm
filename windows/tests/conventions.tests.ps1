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

# Every shipped script, lib\ included: a duplicate in one of those shadows
# just as silently, and the whole point of splitting install.ps1 was that the
# next reader can see which file a function lives in.
function Get-ShippedScript {
    return @(Get-ChildItem -LiteralPath $WinDir -Filter '*.ps1' -File) +
           @(Get-ChildItem -LiteralPath (Join-Path $WinDir 'lib') -Filter '*.ps1' -File)
}

$scripts = @(Get-ShippedScript) +
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
foreach ($s in (Get-ShippedScript)) {
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
foreach ($s in (Get-ShippedScript)) {
    foreach ($l in (Get-UserVisibleLine $s.FullName)) {
        # -cmatch: "Machine" capitalised at the start of a sentence counts too.
        if ($l.Text -imatch '\bmachines?\b') {
            $saidMachine += ("{0}:{1}: {2}" -f $s.Name, $l.Line, $l.Text.Trim())
        }
    }
}

Assert-Equal 0 $saidMachine.Count ("the user must never be shown ""machine"":`n  " + ($saidMachine -join "`n  "))

# ---- the elevated relaunch forwards what it was given ------------------------
#
# install.ps1 relaunches ITSELF elevated, by name. The argument list used to be
# written out literally at each call site, so nothing checked it against the
# parameters the script declares -- and the failure is invisible from the
# parent: param() is [CmdletBinding()], which THROWS on an unknown named
# argument, and the child runs in a hidden window.
#
# Get-ChildArguments now builds it from $PSBoundParameters, so a flag is
# forwarded by existing and cannot be misspelled. That makes the property
# BEHAVIOURAL rather than structural, and elevation.tests.ps1 asserts it --
# including that -AddToPath is never delegated, because in an elevated child on
# a standard account HKCU is the ADMIN's hive.
#
# What stays here is the one thing a behavioural test cannot see: that no call
# site has gone back to writing a list of its own.

$installer = Join-Path $WinDir 'install.ps1'
$hostLib   = Join-Path $WinDir 'lib\host.ps1'

$literal = @()
foreach ($f in (Get-ShippedScript)) {
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
    if ($errors) { throw ("{0} does not parse: {1}" -f $f.Name, $errors[0].Message) }
    foreach ($c in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        if ($c.GetCommandName() -ne 'Request-Elevation') { continue }
        foreach ($str in $c.FindAll({ $args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) {
            if ($str.Value -match '^-\w') {
                $literal += ("{0}:{1}: {2}" -f $f.Name, $str.Extent.StartLineNumber, $str.Value)
            }
        }
    }
}
Assert-Equal 0 $literal.Count `
    ("a caller is handing the elevated child a flag of its own; it forwards `$PSBoundParameters instead:`
  " +
     ($literal -join "`
  "))

# ---- install.ps1's constants keep their values inside the dispatch -----------
#
# $SWITCH held the path to the switcher, and $switch is PowerShell's own: it
# holds the enumerator of whichever switch statement is running, in the scope
# that runs it. install.ps1's verb dispatch IS a switch statement, so for the
# whole of every verb -- and inside every function it calls -- the constant read
# as the EMPTY STRING, silently.
#
# What that did: `Copy-Item <source> ''` resolves the destination against the
# current directory, so an install run from the source tree tried to copy
# trigger-kvm.ps1 onto itself and died mid-install; uninstall could not remove a
# file whose path was blank; and a task registered on that path would have
# carried an empty -Exec, giving a watcher that could never switch anything.
#
# ASKED BY RUNNING IT, not against a list of names to keep in step. The probe
# gives every name install.ps1 binds at script scope a known value and reads them
# all back from inside the three contexts that bind an automatic variable -- a
# switch, a foreach, and a pipeline. A name PowerShell owns comes back different.
# In a child process, because this session has variables of its own.

function Get-TopLevelAssignment {
    <#
      .SYNOPSIS
      Every plain variable a script assigns at its top level, in order.
    #>
    param([string]$Path)

    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors) { throw ("{0} does not parse: {1}" -f $Path, $errors[0].Message) }

    $out = @()
    foreach ($a in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        if ($a.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        $nested = $false
        for ($p = $a.Parent; $p; $p = $p.Parent) {
            if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
                $p -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $nested = $true; break }
        }
        if ($nested) { continue }
        $n = $a.Left.VariablePath.UserPath
        # env: and other providers are not variables this is about.
        if ($n -match ':') { continue }
        # -cnotcontains: two spellings of one name are the point of the check
        # below, so they must both survive being collected.
        if ($out -cnotcontains $n) { $out += $n }
    }
    return @($out)
}

function Get-ShadowedName {
    <#
      .SYNOPSIS
      Of the given names, the ones PowerShell takes over inside a switch, a
      foreach or a pipeline. Empty means every name is the script's own.
    #>
    param([string[]]$Name)

    $probeDir = Join-Path $env:TEMP ("tk-reserved-$PID")
    New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
    $probe = Join-Path $probeDir 'probe.ps1'

    $body = @('Set-StrictMode -Version Latest', '$tkBad = @()', '$tkNames = @()')
    # A name that ALREADY EXISTS in a clean session is a preference variable or
    # an automatic one PowerShell binds up front -- $ErrorActionPreference is
    # typed and would not even take a test value. Those are not what this looks
    # for: nothing shadows them mid-statement. $switch is not among them,
    # because it exists only while a switch statement runs, which is the whole
    # reason it can be assigned and then quietly taken away.
    foreach ($n in $Name) {
        $body += ('if (-not (Get-Variable -Name ''{0}'' -ErrorAction SilentlyContinue)) {{' -f $n)
        $body += ('    ${0} = ''tk-{0}''; $tkNames += ''{0}''' -f $n)
        $body += '}'
    }
    # One check, run in each of the three contexts.
    # AS TEXT, and forced to a scalar. What a shadowing statement leaves in the
    # name is an ENUMERATOR, and `$enumerator -ne 'x'` filters rather than
    # compares: it answers the empty collection, which is falsy, so a comparison
    # written the obvious way reports that everything is fine.
    $check = @('  foreach ($tkN in $tkNames) {'
               '    $tkV = "" + (Get-Variable -Name $tkN -ValueOnly -ErrorAction SilentlyContinue)'
               '    if ($tkV -ne "tk-$tkN") {'
               '      if ($tkBad -notcontains $tkN) { $tkBad += $tkN }'
               '    }'
               '  }')
    $body += 'switch (1) { default {'
    $body += $check
    $body += '} }'
    $body += 'foreach ($tkI in 1..1) {'
    $body += $check
    $body += '}'
    $body += '1 | ForEach-Object {'
    $body += $check
    $body += '}'
    $body += '$tkBad -join ","'

    $body | Set-Content -LiteralPath $probe -Encoding ASCII
    $said = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probe 2>&1 | ForEach-Object { "$_" }) -join ''
    Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
    return @($said -split ',' | Where-Object { $_ })
}

# Every shipped script, not just install.ps1: lib\ files bind their tables at
# top level and are dot-sourced into the same scope, so a name taken there is
# taken for the whole program.
$bound = @()
foreach ($f in (Get-ShippedScript)) {
    foreach ($n in (Get-TopLevelAssignment $f.FullName)) {
        # -cnotcontains, for the same reason as in the walk: `-notcontains` is
        # case-insensitive and would drop the second spelling of a collision,
        # which is the one thing this list is here to show.
        if ($bound -cnotcontains $n) { $bound += $n }
    }
}
# A count, not a name: naming one would fire before the check below on the very
# rename this exists to catch, and report the sentinel instead of the reason.
Assert-True ($bound.Count -ge 10) `
    ("the AST walk found only {0} script-scope names; it is not reading the files" -f $bound.Count)

# ---- ...and no two of them differ only in case, within one program -----------
#
# VARIABLE NAMES ARE CASE-INSENSITIVE. `$LIBDIR` was the destination lib\ and
# `$libDir` the source one, sixty lines apart in install.ps1 -- ONE variable,
# and the second assignment ran at load time, before any verb. So every install
# copied lib\*.ps1 from the source onto the source and died there with the first
# three files already copied, and `uninstall` would have deleted the working
# tree's lib\ rather than the installed one.
#
# PER PROGRAM, because a scope is a program: install.ps1 dot-sources config.ps1
# and lib\*.ps1 into its own, the switcher and the watcher each dot-source
# config.ps1 into theirs, and nvapi-probe.ps1 stands alone. Tree-wide this reads
# three collisions that are not: `$WATCH` and `$STAMP` in the installer against
# `$watch` and `$stamp` in files it never loads, and `$CONFIG` against the
# switcher's and watcher's `-Config` parameter.
$libFiles = @(Get-ChildItem -LiteralPath (Join-Path $WinDir 'lib') -Filter '*.ps1' -File |
              ForEach-Object { $_.FullName })
$programs = @(
    @{ Name = 'install.ps1'
       Files = @((Join-Path $WinDir 'install.ps1'), (Join-Path $WinDir 'config.ps1')) + $libFiles }
    @{ Name = 'event-watch.ps1'
       Files = @((Join-Path $WinDir 'event-watch.ps1'), (Join-Path $WinDir 'config.ps1')) }
    @{ Name = 'trigger-kvm.ps1'
       Files = @((Join-Path $WinDir 'trigger-kvm.ps1'), (Join-Path $WinDir 'config.ps1')) }
    @{ Name = 'nvapi-probe.ps1'; Files = @((Join-Path $WinDir 'nvapi-probe.ps1')) }
)

# NAMED, not inferred: a new shipped script joins a scope or starts one, and
# that is a decision somebody makes here rather than a file quietly going
# unchecked.
$grouped = @($programs | ForEach-Object { $_.Files } | Sort-Object -Unique)
$shipped = @(Get-ShippedScript | ForEach-Object { $_.FullName } | Sort-Object -Unique)
Assert-Equal ($shipped -join "`n") ($grouped -join "`n") `
    'every shipped script belongs to exactly the scopes named here'

$collisions = @()
foreach ($prog in $programs) {
    $byCase = @{}
    foreach ($f in $prog.Files) {
        foreach ($n in (Get-TopLevelAssignment $f)) {
            $k = $n.ToLowerInvariant()
            if (-not $byCase.ContainsKey($k)) { $byCase[$k] = @() }
            if ($byCase[$k] -cnotcontains $n) { $byCase[$k] += $n }
        }
    }
    foreach ($k in @($byCase.Keys)) {
        if ($byCase[$k].Count -gt 1) {
            $collisions += ("{0}: {1}" -f $prog.Name, ($byCase[$k] -join ' and '))
        }
    }
}
Assert-Equal 0 $collisions.Count `
    ("these are ONE variable, spelled two ways: " + ($collisions -join '; '))

# ...and the walk keeps both spellings, which is the whole trick: a collector
# that de-duplicates case-insensitively silently drops the evidence.
$caseDir = Join-Path $env:TEMP ("tk-case-$PID")
Remove-Item -LiteralPath $caseDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $caseDir | Out-Null
$caseProbe = Join-Path $caseDir 'probe.ps1'
@('$LIBDIR = ''one''', '$libDir = ''two''', '$Other = ''three''') |
    Set-Content -LiteralPath $caseProbe -Encoding ASCII
$caseNames = @(Get-TopLevelAssignment $caseProbe)
Assert-True ($caseNames -ccontains 'LIBDIR' -and $caseNames -ccontains 'libDir') `
    'both spellings must survive the walk, or the check above can never fire'
Assert-Equal 3 $caseNames.Count 'and an ordinary name is collected once, not dropped'
Remove-Item -LiteralPath $caseDir -Recurse -Force -ErrorAction SilentlyContinue

$shadowed = @(Get-ShadowedName -Name $bound)
Assert-Equal 0 $shadowed.Count `
    ("a shipped script binds a name PowerShell owns, so it reads as something else inside a " +
     "switch, foreach or pipeline: " + ($shadowed -join ', '))

# ...and the probe can see one. $switch is the name that bit us.
$canSee = @(Get-ShadowedName -Name @('SWITCH', 'DEST'))
Assert-Equal 'SWITCH' ($canSee -join ',') `
    'the probe must find $SWITCH and must not cry wolf over an ordinary name'

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

# ---- and one door for "which file am I?" -------------------------------------
#
# $PSScriptRoot and $PSCommandPath are per FILE. Inside a function DEFINED in
# lib\ they name that lib file, whichever program dot-sourced it -- measured, and
# not what any of the five uses in lib\host.ps1 meant. Two of them build the
# elevated relaunch, so the child would run a library with no param() block, do
# nothing and exit 0, and the parent would report the install as done.
#
# install.ps1 resolves both once, as $TK_HOME and $TK_SELF, and lib\ reads those.
# The test harness defines them too, which is why a test could not have caught
# this: an imported function would have read tests\lib.ps1's own path.

$perFile = @()
foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $WinDir 'lib') -Filter '*.ps1' -File)) {
    $n = 0
    foreach ($l in (Get-Content -LiteralPath $f.FullName)) {
        $n++
        if ($l -match '^\s*#') { continue }
        if ($l -match '\$PS(ScriptRoot|CommandPath)') {
            $perFile += ("lib\{0}:{1}: {2}" -f $f.Name, $n, $l.Trim())
        }
    }
}
Assert-Equal 0 $perFile.Count `
    ("lib\ reads `$TK_HOME and `$TK_SELF; `$PSScriptRoot and `$PSCommandPath there name the lib file:`n  " +
     ($perFile -join "`n  "))

# The two names it points at have to be the ones install.ps1 actually resolves,
# or the check above just moves the bug to an undeclared variable.
foreach ($name in 'TK_HOME', 'TK_SELF') {
    Assert-True ([bool](Select-String -LiteralPath $installer -Pattern ('^\${0}\s*=' -f $name))) `
        ("install.ps1 must resolve `$$name at the top, since lib\ may not")
}

# ...and the task is registered as that user, never as whoever is running.
$asWho = @()
foreach ($l in (Select-String -LiteralPath $hostLib -Pattern 'New-ScheduledTaskPrincipal|New-ScheduledTaskTrigger\s+-AtLogOn')) {
    if ($l.Line -notmatch '\$FORUSER') {
        $asWho += ("lib\host.ps1:{0}: {1}" -f $l.LineNumber, $l.Line.Trim())
    }
}
Assert-True ($asWho.Count -ge 0 -and (Select-String -LiteralPath $hostLib -Pattern 'New-ScheduledTaskPrincipal').Count -gt 0) `
    'the principal check must have found the registration to check'
Assert-Equal 0 $asWho.Count ("every task principal and logon trigger names `$FORUSER:`n  " + ($asWho -join "`n  "))

# ---- registering the task is allowed to fail, and must explain itself --------
#
# specs/configure.md 4.4: an interrupted run must leave a working setup
# untouched, and where it cannot, it has to say what is left. The OLD task is
# unregistered before the new one is registered, so a throw between them leaves
# no autostart at all -- and under $ErrorActionPreference = 'Stop' it left no
# message either, just a stack trace after the files had been copied.
#
# Structural because it is straight-line install code: reaching it for real
# means registering a scheduled task, which is machine-wide and outlives
# anything a test can sandbox.

function Test-InsideTry {
    param([string]$Path, [string]$Command)

    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors) { throw ("{0} does not parse: {1}" -f $Path, $errors[0].Message) }

    $calls = @($ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                  $n.GetCommandName() -eq $Command }, $true))
    if ($calls.Count -eq 0) { return $false }   # gone is not the same as guarded

    foreach ($c in $calls) {
        $guarded = $false
        for ($p = $c.Parent; $p; $p = $p.Parent) {
            if ($p -is [System.Management.Automation.Language.TryStatementAst]) { $guarded = $true; break }
        }
        if (-not $guarded) { return $false }
    }
    return $true
}

Assert-True (Test-InsideTry -Path $hostLib -Command 'Register-ScheduledTask') `
    'Register-ScheduledTask must be caught: the old task is already gone by then'
Assert-True (Test-InsideTry -Path $hostLib -Command 'Unregister-ScheduledTask') `
    'and so must Unregister, which is where the ownership trap surfaces'

# The check can see an unguarded call, and does not fire on a guarded one.
$probe = Join-Path $env:TEMP "trigger-kvm-try-probe-$PID.ps1"
'Register-ScheduledTask -TaskName x' | Set-Content -LiteralPath $probe -Encoding ASCII
Assert-True (-not (Test-InsideTry -Path $probe -Command 'Register-ScheduledTask')) `
    'an unguarded call must be reported'
@'
try { Register-ScheduledTask -TaskName x } catch { }
'@ | Set-Content -LiteralPath $probe -Encoding ASCII
Assert-True (Test-InsideTry -Path $probe -Command 'Register-ScheduledTask') 'and a guarded one must not'
Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue

# ---- the LG service channel is reachable from exactly one place --------------
#
# ..\..\AGENTS.md hard rule 5. I2C source 0x50 is LG's service/factory channel;
# sweeping it has bricked LG monitors, and what it means on another vendor's
# panel is unknown. The rule is enforced at the TRANSPORT rather than by caller
# discipline: exactly one function may emit that source byte, the byte is not a
# parameter of anything, and that function refuses a target whose EDID
# manufacturer is not GSM.
#
# So the property is structural, and no behavioural test reaches it: a SECOND
# emitter would pass every test in this suite while quietly removing the gate.
# macOS pins the same thing in its own conventions file.

$Switcher = Join-Path $WinDir 'trigger-kvm.ps1'

function Get-TransportLine {
    <#
      .SYNOPSIS
      The embedded C# transport, as lines, with its comments removed.

      .DESCRIPTION
      Comments removed because they TALK about the sidechannel constantly and
      should go on being allowed to. What must be rare is the code.

      ALL the embedded C#, not one transport's worth. There is deliberately one
      Add-Type block holding every transport, because a second block would be
      code this scan cannot see -- and an emitter the scan cannot see is the
      exact failure hard rule 5 exists to prevent. If a second block is ever
      added, this function must grow to cover it or the guard below is a lie.
    #>
    param([string]$Path)

    $ps = Get-Content -Raw -LiteralPath $Path
    $m  = [regex]::Match($ps, '(?s)\$TransportSource = @''\r?\n(.*?)\r?\n''@')
    if (-not $m.Success) { throw "$Path no longer holds a `$TransportSource block; this check is blind" }

    # One block is the invariant, so prove there is not a second one hiding.
    $blocks = @([regex]::Matches($ps, '(?m)^\$\w+Source = @''\s*$'))
    if ($blocks.Count -ne 1) {
        throw ("$Path holds $($blocks.Count) embedded-source blocks; this check reads one, " +
               'so the others are unscanned. Merge them or teach Get-TransportLine about them.')
    }

    $cs = [regex]::Replace($m.Groups[1].Value, '(?s)/\*.*?\*/', '')
    return @($cs -split "`r?`n" | ForEach-Object { $_ -replace '//.*$', '' })
}

function Get-CsMethodLine {
    <#
      .SYNOPSIS
      The line indices of one C# method, signature to closing brace.
    #>
    param([string[]]$Lines, [string]$Name)

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch ('\b' + [regex]::Escape($Name) + '\s*\(')) { continue }
        if ($Lines[$i] -notmatch '^\s*(public|private|internal|static)') { continue }
        $depth = 0; $open = $false; $out = @()
        for ($j = $i; $j -lt $Lines.Count; $j++) {
            $out   += $j
            $depth += ([regex]::Matches($Lines[$j], '\{')).Count
            $depth -= ([regex]::Matches($Lines[$j], '\}')).Count
            if ($Lines[$j] -match '\{') { $open = $true }
            if ($open -and $depth -le 0) { break }
        }
        return $out
    }
    return @()
}

function Get-SourceGateComplaint {
    <#
      .SYNOPSIS
      Everything about this transport that would let source 0x50 out by a second
      door. Empty means the gate holds.
    #>
    param([string]$Path)

    $lines = Get-TransportLine $Path
    $out   = @()

    # The two doors -- the writer and the packet builder -WhatIf prints -- and
    # the gate they both pass through. All three named here, so a FOURTH is a
    # complaint rather than a silently widened allowance.
    $gate    = @(Get-CsMethodLine -Lines $lines -Name 'WriteLgInput')
    $builder = @(Get-CsMethodLine -Lines $lines -Name 'PacketForLgInput')
    $refuse  = @(Get-CsMethodLine -Lines $lines -Name 'RefuseNonGsm')
    if ($gate.Count    -eq 0) { $out += 'WriteLgInput is gone -- there is no writer to check' }
    if ($builder.Count -eq 0) { $out += 'PacketForLgInput is gone' }
    if ($refuse.Count  -eq 0) { $out += 'RefuseNonGsm is gone -- there is no gate to check' }
    $allowed = @($gate) + @($builder) + @($refuse)

    # AND BOTH DOORS MUST GO THROUGH IT. Sharing the gate is only worth anything
    # while both callers still call it: extracting it is exactly the edit that
    # could leave one of them ungated, and -WhatIf printing a packet the writer
    # would refuse is the defect this replaced.
    foreach ($pair in @(@{ N = 'WriteLgInput'; L = $gate }, @{ N = 'PacketForLgInput'; L = $builder })) {
        if ($pair.L.Count -eq 0) { continue }
        $body = ($lines[$pair.L] -join "`n")
        if ($body -notmatch 'RefuseNonGsm\s*\(') {
            $out += ("{0} does not pass the vendor gate" -f $pair.N)
        }
    }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        # The declaration is the one place the literal may appear.
        if ($l -match 'const\s+byte\s+LG_I2C_SOURCE\s*=\s*0x50\s*;') { continue }
        if ($l -match '0x50') {
            $out += ("line {0}: the literal 0x50 outside its one const: {1}" -f ($i + 1), $l.Trim())
        }
        if ($l -match 'LG_I2C_SOURCE' -and $allowed -notcontains $i) {
            $out += ("line {0}: LG_I2C_SOURCE outside WriteLgInput and PacketForLgInput: {1}" -f ($i + 1), $l.Trim())
        }
    }

    # Send is what actually puts bytes on the bus. Public, it would be the
    # generic "write to source N" entry point this rule exists to forbid.
    foreach ($l in @($lines | Where-Object { $_ -match '\bSend\s*\(.*byte\[\]' })) {
        if ($l -match '\bpublic\b') { $out += ("Send must stay private: {0}" -f $l.Trim()) }
    }

    # ...and no public method may take a source or an I2C address at all, which
    # is how the byte would become a caller's choice again.
    foreach ($l in @($lines | Where-Object { $_ -match '^\s*public\s+static\b.*\(' })) {
        $p = [regex]::Match($l, '\((.*)\)')
        if ($p.Success -and $p.Groups[1].Value -match '(?i)\b(source|i2c\w*addr\w*|devaddress)\b') {
            $out += ("a public method takes a source or I2C address: {0}" -f $l.Trim())
        }
    }
    return @($out)
}

$gateComplaints = @(Get-SourceGateComplaint $Switcher)
Assert-Equal 0 $gateComplaints.Count ("source 0x50 has more than one door:`n  " + ($gateComplaints -join "`n  "))

# And the gate still refuses a target that is not GSM, which is the other half:
# one door is no use if it is unlocked.
$gateBody = (Get-TransportLine $Switcher)[(Get-CsMethodLine -Lines (Get-TransportLine $Switcher) -Name 'RefuseNonGsm')] -join "`n"
# The COMPARISON, not merely the name: the name also appears in the refusal
# message, so `if (false)` left the constant present and the gate open. Found by
# a mutation that survived.
Assert-Match $gateBody 'EdidVendor\s*!=\s*EDID_VENDOR_GSM' 'the vendor check lives inside the gate'
Assert-Match $gateBody 'throw new InvalidOperationException' `
    'and it throws rather than returning a code a caller can ignore'

# ---- the second transport cannot become a second door ------------------------
#
# dxva2 was added as a vendor-neutral transport (docs/decisions/003). The reason
# it is safe to add at all is that it CANNOT express an I2C source byte: the
# Windows DDC/CI stack hardcodes 0x51 and SetVCPFeature takes a VCP code, not an
# address. So adding it cannot widen the 0x50 surface -- but only while that
# stays true of the code, which is what this asserts.
#
# Scanned as part of the same $TransportSource block for exactly the reason
# Get-TransportLine documents: a transport the scan cannot see is the failure.

$dxvaLines = @(Get-TransportLine $Switcher)
$dxvaAt    = @(0..($dxvaLines.Count - 1) | Where-Object { $dxvaLines[$_] -match '^\s*public\s+static\s+class\s+Dxva\b' })
Assert-Equal 1 $dxvaAt.Count 'the dxva2 transport class must be found exactly once'

# From that class to the end of the block: everything after it is dxva2's.
$dxvaBody = @($dxvaLines[$dxvaAt[0]..($dxvaLines.Count - 1)])
$joined   = $dxvaBody -join "`n"

Assert-NoMatch $joined '0x50' 'the dxva2 transport must not name the LG service channel at all'
Assert-NoMatch $joined 'LG_I2C_SOURCE' 'nor reach for the constant that spells it'
Assert-NoMatch $joined 'I2CWrite' 'nor call raw I2C, which is the only thing that could carry a source byte'

# ---- and it addresses exactly one panel, and reports honestly ----------------
#
# Two defects in one method, neither reachable from a suite with no monitors, so
# they are held here on the source instead.
#
# ONE HMONITOR CAN CARRY SEVERAL PHYSICAL PANELS -- that is what "Duplicate these
# displays" means -- and identity was read off the first of them, so a write
# aimed at one panel reached every panel behind the handle. Both switchers
# address exactly one display (specs/config-format.md); a handle naming more
# than one cannot be aimed, so it is refused.
#
# AND ZERO ACCEPTED IS NOT SUCCESS. The accepted count was returned raw and the
# PowerShell caller mapped anything non-positive to itself -- so 0, meaning every
# write refused, arrived as 0, which is the success code. The mapping now lives
# in the method, which is the only place that knows what it counted.

$writeStd = @(Get-CsMethodLine -Lines $dxvaBody -Name 'WriteStandardVcp')
Assert-True ($writeStd.Count -gt 0) 'the dxva2 write must be found before it can be checked'
$stdBody = ($dxvaBody[$writeStd] -join "`n")

Assert-Match $stdBody 'GetNumberOfPhysicalMonitorsFromHMONITOR' `
    'it must ask how many panels are behind the handle'
Assert-Match $stdBody '(?m)if\s*\(\s*n\s*!=\s*1\s*\)\s*return\s+-\d' `
    'and refuse anything but exactly one, rather than writing to all of them'
Assert-Match $stdBody 'return\s+ok\s*>\s*0\s*\?\s*0\s*:\s*-\d' `
    'and a write nothing accepted must come back as a failure, not as 0'

# The caller must not put a mapping back on top of that one.
$dxvaCall = (Get-Content -Raw -LiteralPath $Switcher)
Assert-NoMatch $dxvaCall 'Dxva\]::WriteStandardVcp\([^\n]*\n[^\n]*-gt 0' `
    'the success mapping belongs to the method that counted, not to its caller'

foreach ($l in @($dxvaBody | Where-Object { $_ -match '^\s*public\s+static\b.*\(' })) {
    $p = [regex]::Match($l, '\((.*)\)')
    if ($p.Success -and $p.Groups[1].Value -match '(?i)\b(source|i2c\w*addr\w*|devaddress)\b') {
        Assert-True $false ("a dxva2 method takes a source or I2C address: {0}" -f $l.Trim())
    }
}

# ---- and no OTHER file in the tree can reach that bus ------------------------
#
# ..\..\AGENTS.md hard rule 5: each platform's AGENTS.md names EVERY emitter it
# has, and each suite asserts -- self-testedly -- that there are no others.
#
# The scan above reads ONE here-string in ONE file, and that was the whole of
# the proof. It is not enough: event-watch.ps1 carries two Add-Type blocks,
# lib\host.ps1 one, and nvapi-probe.ps1 a whole NVAPI binding, and none of them
# was ever read. An emitter the scan cannot see is precisely the failure the
# rule exists to prevent.

# Comments stripped in BOTH languages -- PowerShell's `#` and <# #>, and the
# `//` and /* */ of the C# these files embed. Otherwise the scan finds the rule
# being DISCUSSED and calls it an emitter: nvapi-probe.ps1's whole point is that
# it does NOT resolve NvAPI_I2CWrite, and it says so four times.
function Get-CodeOnly {
    param([string]$Path)
    $t = Get-Content -Raw -LiteralPath $Path
    $t = [regex]::Replace($t, '(?s)<#.*?#>', '')
    $t = [regex]::Replace($t, '(?s)/\*.*?\*/', '')
    $out = foreach ($l in ($t -split "`r?`n")) {
        if ($l -match '^\s*#') { continue }
        $l -replace '//.*$', ''
    }
    return ($out -join "`n")
}

# Every embedded native-source block in the tree, as file -> text. These are the
# only places PowerShell can gain the ability to touch hardware at all.
function Get-EmbeddedSource {
    param([string]$Path)
    return @([regex]::Matches((Get-CodeOnly $Path), "(?ms)@'\r?\n(.*?)\r?\n'@") |
             ForEach-Object { $_.Groups[1].Value })
}

# Named relative to windows\, so `lib\host.ps1` reads as itself rather than as
# a bare `host.ps1` that could be either.
$blocks = @()
foreach ($f in (Get-ShippedScript)) {
    $rel = $f.FullName.Substring($WinDir.Length + 1)
    foreach ($b in (Get-EmbeddedSource $f.FullName)) {
        $blocks += [pscustomobject]@{ File = $rel; Text = $b }
    }
}

# NAMED, not counted loosely: a new embedded block is a decision somebody has to
# make deliberately, and this is where they are told so.
$expected = 'event-watch.ps1', 'event-watch.ps1', 'lib\host.ps1', 'nvapi-probe.ps1', 'trigger-kvm.ps1'
Assert-Equal ($expected -join ', ') ((@($blocks | ForEach-Object { $_.File }) | Sort-Object) -join ', ') `
    ('the embedded native source in this tree is not what this scan was written against. ' +
     'A new block is a new way to reach hardware: name it here, and in windows\AGENTS.md.')

# NOTHING BUT THE SWITCHER MAY NAME THE BUS. trigger-kvm.ps1's block is scanned
# in full above; every other one must not mention I2C at all.
$reach = @()
foreach ($b in ($blocks | Where-Object { $_.File -ne 'trigger-kvm.ps1' })) {
    foreach ($needle in '0x50', 'LG_I2C_SOURCE', 'I2C') {
        if ($b.Text -match [regex]::Escape($needle)) {
            $reach += ("{0}: embedded source names {1}" -f $b.File, $needle)
        }
    }
}
Assert-Equal 0 $reach.Count ("only the switcher's transport may reach the I2C bus:`n  " + ($reach -join "`n  "))

# ...and the DISPATCH that can actually put bytes on it is resolved in exactly
# one file. nvapi-probe.ps1 deliberately never resolves it, which is what makes
# it an instrument rather than a second emitter (windows\AGENTS.md).
$resolvers = @()
foreach ($f in (Get-ShippedScript)) {
    if ((Get-CodeOnly $f.FullName) -match 'NvAPI_I2CWrite') { $resolvers += $f.Name }
}
Assert-Equal 'trigger-kvm.ps1' ($resolvers -join ', ') `
    'NvAPI_I2CWrite is resolved in exactly one file, and nvapi-probe.ps1 must not be it'

# ---- the widened scan can actually see one ----------------------------------
#
# A scan that cannot fail is decoration, and this one is easy to write so that
# it never fires. Against throwaway copies, never by breaking the real files.
$scanTmp = Join-Path $env:TEMP "trigger-kvm-emitter-scan-$PID"
Remove-Item -LiteralPath $scanTmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $scanTmp | Out-Null

$probe = Join-Path $scanTmp 'probe.ps1'
# Built line by line: a here-string demonstrating a here-string cannot close.
@(
    '$Src = @' + "'"
    'public static class X {'
    '    public static int Write(byte v) { return I2CWrite(0x50, v); }'
    '}'
    "'" + '@'
) | Set-Content -LiteralPath $probe -Encoding ASCII

$got = @(Get-EmbeddedSource $probe)
Assert-Equal 1 $got.Count 'the scan must find an embedded block at all'
Assert-Match $got[0] '0x50'    'and read what is in it'
Assert-Match $got[0] 'I2CWrite'

# The same text in a COMMENT is not an emitter, in either language.
@(
    '# I2CWrite(0x50) is what this file must never do.'
    '$Src = @' + "'"
    '// I2CWrite(0x50) is deliberately not resolved here.'
    'public static class X { }'
    "'" + '@'
) | Set-Content -LiteralPath $probe -Encoding ASCII
$got = @(Get-EmbeddedSource $probe)
Assert-Equal 1 $got.Count 'a block whose body is all comment is still a block'
Assert-NoMatch $got[0] '0x50' 'but talking about the rule is not breaking it'
Assert-NoMatch ((Get-CodeOnly $probe)) 'I2CWrite' 'in either language'

Remove-Item -LiteralPath $scanTmp -Recurse -Force -ErrorAction SilentlyContinue

# ---- one verb surface, in one place ------------------------------------------
#
# "Which verbs exist" was written down THREE times -- the shim's routing table
# and each script's own ValidateSet -- and none could see the others, so they
# drifted and the drift was invisible until somebody typed a wrong verb. What
# they got was a raw PowerShell binding error naming
# "install,configure,status,discover,restart,logs,pause,uninstall": it OMITTED
# pull, to and list, because the shim routes those away before install.ps1 is
# reached, and it OFFERED install, which the shim itself refuses.
#
# There is now ONE table, in config.ps1, which both entry scripts check what
# they were given against. So the copies cannot drift -- and what is left to
# assert is that neither script has grown a second answer.

. (Join-Path $WinDir 'config.ps1')
Import-Subject -Script 'lib\host.ps1' -Functions @('Get-UsageText','Get-ShimLines')

$switchVerbs = @($VERBS | Where-Object { $_.Where -eq 'switch' } | ForEach-Object { $_.Verb })
$manageVerbs = @($VERBS | Where-Object { $_.Where -eq 'manage' } | ForEach-Object { $_.Verb })
Assert-True ($switchVerbs.Count -gt 0) 'the table must name the switching verbs'
Assert-True ($manageVerbs.Count -gt 0) 'and the management ones'

# NEITHER SCRIPT MAY DECLARE ITS OWN SET. A ValidateSet cannot read a variable,
# so one is by construction a second copy of this table.
foreach ($rel in 'install.ps1', 'trigger-kvm.ps1') {
    $src = Get-Content -Raw -LiteralPath (Join-Path $WinDir $rel)
    Assert-NoMatch $src '\[ValidateSet\([^)]*''pull''' `
        ("$rel declares its own verb set; the surface is `$VERBS in config.ps1")
    Assert-NoMatch $src '\[ValidateSet\([^)]*''status''' `
        ("$rel declares its own verb set; the surface is `$VERBS in config.ps1")
    Assert-Match $src 'Get-Verbs -Where' ("$rel must check what it was given against `$VERBS")
}

# The two extras each script accepts without being on the public surface, and
# the reason each is off it.
$manageAccepts = @(Get-Verbs -Where 'manage')
$switchAccepts = @(Get-Verbs -Where 'switch')
foreach ($v in $manageVerbs) { Assert-True ($manageAccepts -contains $v) ("the shim routes '{0}' to install.ps1, which rejects it" -f $v) }
foreach ($v in $switchVerbs) { Assert-True ($switchAccepts -contains $v) ("the shim routes '{0}' to trigger-kvm.ps1, which rejects it" -f $v) }

Assert-True ($manageAccepts -contains 'help') 'install.ps1 must accept the verb the shim calls for usage'
Assert-True ($manageAccepts -contains 'install') 'and the one that running it from the source tree means'
Assert-True (-not ($VERBS.Verb -contains 'install')) `
    'install must NOT be on the usage screen: the shim refuses it, and offering a verb that is refused is how the old error misled'

# `set` IS DELIBERATELY UNROUTED, and this asserts the deliberateness. The
# switcher accepts it for the walkthrough's guided discovery; a general "write
# any value to a monitor" verb on the public surface invites the poking at
# panels hard rule 1 exists to discourage.
Assert-True ($switchAccepts -contains 'set') 'the switcher still has set, for guided discovery'
Assert-True (-not ($VERBS.Verb -contains 'set')) `
    'set must stay off the public verb surface -- see the -Value parameter in trigger-kvm.ps1'

# ---- the shim routes exactly what the usage screen promises -------------------
#
# Generated text that nothing reads back is exactly where a routing table quietly
# stops matching its own help.
$shim  = (Get-ShimLines) -join "`n"
$usage = (Get-UsageText) -join "`n"
foreach ($v in $VERBS) {
    Assert-Match $shim  ('if /i "%~1"=="{0}" goto :{1}' -f $v.Verb, $(if ($v.Where -eq 'switch') { 'switch' } else { 'manage' })) `
        ("'{0}' is on the usage screen and not routed" -f $v.Verb)
    Assert-Match $usage ('(?m)^\s+' + [regex]::Escape($v.Verb) + '\b') `
        ("'{0}' is routed and not on the usage screen" -f $v.Verb)
}

# BARE INVOCATION PRINTS USAGE. It used to `goto :switch`, which with
# trigger-kvm.ps1's $Command defaulting to 'pull' meant the bare command name
# MOVED EVERY CONFIGURED MONITOR -- and that is the likeliest thing somebody
# types to find out what a tool does. Hard rule 4.
Assert-Match   $shim 'if "%~1"=="" goto :usage'
Assert-NoMatch $shim 'if "%~1"=="" goto :switch' 'a bare command must never switch a monitor'

# EVERY usage path exits 2, macOS included -- its usage() ends `exit 2` on every
# route in, `-h` and `--help` among them. Exit 0 for an explicit request is the
# more conventional choice and was written that way first; it was changed on
# purpose, because two implementations of one CLI disagreeing about an exit code
# is the drift this suite exists to prevent, and README.md already claims the
# verbs are the same on both platforms.
Assert-Match   $shim '(?s):usage.*?exit /b %ERRORLEVEL%'
Assert-NoMatch $shim 'exit /b 0' 'no usage path may report success; macOS reports 2'
Assert-Match $shim '(?s):unknown.*?no such verb' `
    'an unknown verb is reported by the shim, which is the only thing that knows the whole surface'
# ...and the fall-through actually REACHES that block. Asserting the block exists
# is not the same claim: a mutation pointing the fall-through back at :manage
# left every line of :unknown in place and unreachable, and passed.
Assert-Match   $shim '(?m)^goto :unknown$'
Assert-NoMatch $shim '(?m)^goto :manage$' `
    'an unrecognised verb must not reach install.ps1, whose ValidateSet names only half the surface'

# The two platforms' usage screens must read alike, since a person moving between
# the desks reads both. Not a normative string -- nothing in specs/ pins this --
# but the OPENING LINE is what makes them recognisably the same command.
Assert-Match $usage '(?m)^usage: trigger-kvm <verb> \[options\]$' `
    'the usage screen opens the way the macOS one does'
Assert-Match $usage '(?m)^options:$' 'and carries its options section'
Assert-Match $usage 'There is no `install` verb' 'and says the same thing about install'
foreach ($alias in @('help', '--help', '-h')) {
    Assert-Match $shim ('"%~1"=="{0}" goto :help' -f [regex]::Escape($alias))
}
Assert-Match $shim '"%~1"=="/\?" goto :help'

# ---- the walkthrough cannot offer a pair the switcher refuses ----------------
#
# The two scripts hold DIFFERENT HALVES of one fact on purpose: Switch-Display
# REFUSES a transport it does not know and refuses lg-alt on a transport with no
# source byte -- that is the gate a hand-edited config meets -- while the
# walkthrough simply never OFFERS either. Neither is a copy of the other.
#
# What they must not do is disagree, and the drift is silent and nasty: a
# walkthrough offering a transport the switch rejects writes a config that
# configures nothing, and the person finds out when a monitor does not move.
#
# There is now one table in config.ps1 and both read it, so the assertion is
# that they still do rather than that two lists match.

$swSrc   = (Get-Content -LiteralPath $Switcher) -join "`n"
$walkSrc = (Get-Content -LiteralPath (Join-Path $WinDir 'lib\walkthrough.ps1')) -join "`n"

Assert-True ($TRANSPORT_NAMES.Count -ge 1) 'the transport table must name at least one transport'
Assert-Equal 'dxva2 nvapi' ((@($TRANSPORT_NAMES) | Sort-Object) -join ' ') `
    'and those are the two this platform has'

# The switcher reads the table rather than a list of its own.
Assert-Match   $swSrc 'Transport\s+-notin\s+\$TRANSPORT_NAMES' `
    'the switcher must take its known transports from config.ps1'
Assert-NoMatch $swSrc "Transport\s+-notin\s+@\(" `
    'and must not carry a second copy of the list'

# Every transport the walkthrough can WRITE into a config must be one the
# switcher will accept.
$readT = [regex]::Match($walkSrc, "(?s)function Read-Transport\b.*?\n\}")
Assert-True $readT.Success 'the walkthrough must have exactly one transport question'
$offered = @([regex]::Matches($readT.Value, "'([a-z0-9]+)'") |
             ForEach-Object { $_.Groups[1].Value } |
             Where-Object { $_ -ne 'standard' } | Sort-Object -Unique)
Assert-True ($offered.Count -ge 2) 'and it must name them'
foreach ($t in $offered) {
    Assert-True ($TRANSPORT_NAMES -contains $t) `
        ("the walkthrough offers transport '{0}', which the switcher would refuse" -f $t)
}

# The impossible cell, from both sides -- specs/configure.md 6.3. A transport
# that cannot address an I2C source byte cannot carry a manufacturer dialect, so
# the switcher refuses the pair and the walkthrough never asks a question whose
# answer is already fixed. Both name the same set, and it is the table's.
Assert-Match $swSrc "Method\s+-eq\s+'lg-alt'\s+-and\s+.*Transport\s+-in\s+\`$SOURCELESS_TRANSPORTS" `
    'the switcher refuses the impossible pair, against the shared list'
Assert-Match $walkSrc 'if \(\$Transport -in \$SOURCELESS_TRANSPORTS\) \{ return ''standard'' \}' `
    'and the method question is skipped rather than asked and then refused'
Assert-Equal 'dxva2' (@($SOURCELESS_TRANSPORTS) -join ' ') `
    'and dxva2 is what the table says cannot carry one'

# ---- "is a watcher running" is asked of the lock, not the process table ------
#
# An unelevated caller cannot read CommandLine across the session boundary, so
# counting processes is structurally blind to a session-0 watcher: `status` said
# "watchers : 0" about a live boot-tier one that had just fired (2026-09-02,
# ..\..\docs\measurements.md). The lock is what MAKES a second watcher
# impossible, so it is also the honest answer to whether one runs.
#
# Structural, because no behavioural test in this suite can reach it: the suite
# cannot create a session-0 process, which is the only context where the two
# answers differ. A revert to counting would pass everything else.

$hostSrc = @(Get-Content -LiteralPath $hostLib)

# Stop-Watchers still needs PIDs to kill and runs elevated, so ONE query stays.
# More than one means a "is it running?" caller has gone back to counting.
$procAt = @(0..($hostSrc.Count - 1) |
            Where-Object { $hostSrc[$_] -match 'Get-CimInstance\s+Win32_Process' })
Assert-Equal 1 $procAt.Count `
    ("lib\host.ps1 may enumerate processes in exactly one place (Stop-Watchers, which needs PIDs to kill). " +
     "Whether a watcher RUNS is the lock's question -- see event-watch.ps1 -IsRunning.")

# ...and it is Stop-Watchers': between that definition and the next function.
$stopAt = @(0..($hostSrc.Count - 1) | Where-Object { $hostSrc[$_] -match '^function\s+Stop-Watchers\b' })
Assert-Equal 1 $stopAt.Count 'Stop-Watchers must be defined exactly once'
$nextFn = @(0..($hostSrc.Count - 1) |
            Where-Object { $_ -gt $stopAt[0] -and $hostSrc[$_] -match '^function\s' })
$stopEnd = if ($nextFn.Count) { ($nextFn | Measure-Object -Minimum).Minimum } else { $hostSrc.Count }
Assert-True ($procAt[0] -gt $stopAt[0] -and $procAt[0] -lt $stopEnd) `
    ("the surviving process query must be Stop-Watchers'; it is on line " + ($procAt[0] + 1))

# The -MutexName seam exists so the suite can drive every outcome against a name
# of its own. It is safe ONLY because it cannot reach the code that takes the
# lock for real -- a value there could produce two live watchers, which is the
# single failure the mutex exists to prevent. Pinned, not trusted.
$watchSrc  = @(Get-Content -LiteralPath (Join-Path $WinDir 'event-watch.ps1'))
$seamAt    = @(0..($watchSrc.Count - 1) | Where-Object { $watchSrc[$_] -match '\$MutexName' })
$acquireAt = @(0..($watchSrc.Count - 1) | Where-Object {
                 $watchSrc[$_] -match 'New-Object System\.Threading\.Mutex' })

Assert-True ($seamAt.Count    -gt 0) 'the -MutexName seam check must have found the seam'
Assert-True ($acquireAt.Count -gt 0) 'and the lines that take the lock for real'

$firstAcquire = ($acquireAt | Measure-Object -Minimum).Minimum
$leaked = @($seamAt | Where-Object { $_ -ge $firstAcquire })
Assert-Equal 0 $leaked.Count `
    ("-MutexName must not be readable by the code that TAKES the lock; it appears at line(s) " +
     (($leaked | ForEach-Object { $_ + 1 }) -join ', ') + " at or after the acquisition on line " +
     ($firstAcquire + 1))

# ---- installing clears the watcher it is replacing ---------------------------
#
# Stopping the task does NOT stop the watcher: it is a grandchild (task ->
# wscript -> powershell) and outlives its launcher. Left behind it holds the
# single-instance mutex, the newly installed watcher exits on it, and the upgrade
# goes on running the OLD code while reporting success.
#
# This is not hypothetical -- it bit across the install of 2026-08-31 23:53, where
# no watcher armed at all and the previous day's kept running for 23 hours
# (..\..\docs\measurements.md). Structural, because the suite must not register a
# task or kill a real watcher, so the behaviour itself is out of reach.

# The invariant is about STARTING one, not about unregistering: no watcher of
# ours may still be alive when a new one starts, or the new one exits on the
# lock. So Invoke-Install's Start-ScheduledTask must have a Stop-Watchers before
# it, inside the same function.
function Get-FunctionRange {
    param([string[]]$Lines, [string]$Name)
    $at = @(0..($Lines.Count - 1) | Where-Object { $Lines[$_] -match ('^function\s+' + [regex]::Escape($Name) + '\b') })
    if ($at.Count -ne 1) { throw "$Name must be defined exactly once; found $($at.Count)" }
    $next = @(0..($Lines.Count - 1) | Where-Object { $_ -gt $at[0] -and $Lines[$_] -match '^function\s' })
    $end  = if ($next.Count) { ($next | Measure-Object -Minimum).Minimum } else { $Lines.Count }
    return @{ Start = $at[0]; End = $end }
}

$installFn   = Get-FunctionRange -Lines $hostSrc -Name 'Invoke-Install'
$uninstallFn = Get-FunctionRange -Lines $hostSrc -Name 'Invoke-Uninstall'

$stopAt = @(0..($hostSrc.Count - 1) | Where-Object { $hostSrc[$_] -match '^\s*Stop-Watchers\s*$' })

$startAt = @($installFn.Start..($installFn.End - 1) |
             Where-Object { $hostSrc[$_] -match 'Start-ScheduledTask\s+-TaskName\s+\$TASK' })
Assert-True ($startAt.Count -ge 1) 'the install check must have found a Start-ScheduledTask'
$installStart = ($startAt | Measure-Object -Maximum).Maximum

# Anchored to the task-replacement block, not merely to "somewhere earlier":
# Invoke-Uninstall has a Stop-Watchers of its own, and a laxer check passed with
# the install path's call deleted. That mutation is in mutate.ps1.
$replaceAt = @($installFn.Start..($installFn.End - 1) |
               Where-Object { $hostSrc[$_] -match '^\s*if \(Get-ScheduledTask -TaskName \$TASK' })
Assert-True ($replaceAt.Count -ge 1) 'the install check must have found the task-replacement block'
$installReplace = ($replaceAt | Measure-Object -Maximum).Maximum

Assert-True (@($stopAt | Where-Object { $_ -gt $installReplace -and $_ -lt $installStart }).Count -gt 0) `
    ("the install path replaces the task on line " + ($installReplace + 1) + " and starts a watcher on line " +
     ($installStart + 1) + " with no Stop-Watchers between: a surviving watcher holds the lock, " +
     "the new one exits on it, and the upgrade keeps running the old code")

# Uninstall clears them too -- order does not matter there, since nothing is
# started afterwards, only that no watcher outlives the files it runs from.
Assert-True (@($stopAt | Where-Object { $_ -gt $uninstallFn.Start -and $_ -lt $uninstallFn.End }).Count -gt 0) `
    'uninstall must stop the watchers before removing the files they run from'

# And the install says so when nothing came up, because "registered and started"
# is a claim about the TASK -- the two came apart silently for a whole day.
Assert-Match ($hostSrc -join "`n") 'the task is registered but NO WATCHER is running' `
    'a registered task with nothing watching must be stated, not implied'

# ---- the shipped scripts are ASCII, with no BOM and no tabs ------------------
#
# ..\..\AGENTS.md: PowerShell 5.1 reads a .ps1 with no BOM as ANSI, so one
# non-ASCII byte in a comment surfaces as a parse error at an unrelated line.
# That rule had no check, and the bytes in a file are not always the bytes
# somebody typed: a tool that mishandles a backslash escape turns
# %LOCALAPPDATA%\trigger-kvm into %LOCALAPPDATA%<TAB>rigger-kvm, which parses
# fine and says something else. Both have happened here.
#
# Tabs are in the same check rather than a separate one because the question is
# the same: does this file contain a byte the author did not mean to type? The
# tree indents with spaces, so a tab in a .ps1 is always the second thing.

function Get-ByteComplaint {
    param([string]$Path, [string]$Name)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $out   = @()
    if ($bytes.Count -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $out += ("{0}: starts with a UTF-8 BOM" -f $Name)
    }
    $line = 1
    for ($i = 0; $i -lt $bytes.Count; $i++) {
        $b = $bytes[$i]
        if ($b -eq 0x0A) { $line++; continue }
        if ($b -eq 0x0D) { continue }
        if ($b -eq 0x09) { $out += ("{0}:{1}: a literal tab" -f $Name, $line); continue }
        if ($b -lt 0x20 -or $b -gt 0x7E) {
            $out += ("{0}:{1}: byte 0x{2:X2} is not ASCII" -f $Name, $line, $b)
        }
    }
    return @($out)
}

$byteComplaints = @()
foreach ($f in (Get-ShippedScript)) {
    $byteComplaints += @(Get-ByteComplaint -Path $f.FullName -Name $f.Name)
}
Assert-Equal 0 $byteComplaints.Count `
    ("a shipped script holds bytes nobody typed:`n  " + ($byteComplaints -join "`n  "))

# ...and the check can see each of the three.
$byteDir = Join-Path $env:TEMP ("tk-bytes-$PID")
Remove-Item -LiteralPath $byteDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $byteDir | Out-Null

$plain = Join-Path $byteDir 'plain.ps1'
[IO.File]::WriteAllBytes($plain, [Text.Encoding]::ASCII.GetBytes("# fine`r`n"))
Assert-Equal 0 @(Get-ByteComplaint -Path $plain -Name 'plain.ps1').Count 'an ASCII file complains about nothing'

[IO.File]::WriteAllBytes($plain, [byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::ASCII.GetBytes("# fine`r`n"))
Assert-Match (@(Get-ByteComplaint -Path $plain -Name 'p.ps1') -join ' ') 'BOM' 'a BOM is found'

[IO.File]::WriteAllBytes($plain, [Text.Encoding]::ASCII.GetBytes("# a`r`n# b`tc`r`n"))
Assert-Match (@(Get-ByteComplaint -Path $plain -Name 'p.ps1') -join ' ') 'p\.ps1:2: a literal tab' `
    'a tab is found, on its own line'

# The em dash the rule was written for, as the three UTF-8 bytes 5.1 would read
# as ANSI. Written as bytes because this file is itself ASCII-only.
[IO.File]::WriteAllBytes($plain,
    [Text.Encoding]::ASCII.GetBytes('# a dash: ') + [byte[]](0xE2, 0x80, 0x94) +
    [Text.Encoding]::ASCII.GetBytes("`r`n"))
Assert-Match (@(Get-ByteComplaint -Path $plain -Name 'p.ps1') -join ' ') 'byte 0xE2 is not ASCII' `
    'and the em dash the rule was written for'

Remove-Item -LiteralPath $byteDir -Recurse -Force -ErrorAction SilentlyContinue

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
$tmp = Join-Path $env:TEMP "trigger-kvm-conventions-$PID"
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

# ...and Import-Subject reads a variable's WHOLE definition and stops at its
# end. The rule it replaced looked for the next closing brace at column 0, which
# is right for a `@{...}` block and wrong for a one-line assignment: that
# matched from its own line through the end of whatever function came next, and
# imported that function too. It worked by accident.
$vars = Join-Path $tmp 'vars.ps1'
@'
$ONE_LINE = 'just this'

# A comment in between.
function Not-Imported { 'this must not come along' }

$A_BLOCK = @{
    'k' = 'v'
}

$A_LIST = @(
    @{ Name = 'first' }
    @{ Name = 'second' }
)
'@ | Set-Content -LiteralPath $vars -Encoding ASCII

Copy-Item -LiteralPath $vars -Destination (Join-Path $WinDir 'tk-import-probe.ps1')
try {
    Import-Subject -Script 'tk-import-probe.ps1' -Variables @('ONE_LINE', 'A_BLOCK', 'A_LIST')
    Assert-Equal 'just this' $ONE_LINE 'a one-line assignment imports as itself'
    Assert-Equal 'v'         $A_BLOCK['k'] 'a hashtable block imports whole'
    Assert-Equal 2           @($A_LIST).Count 'and so does an array of them'
    Assert-True (-not (Get-Command -Name 'Not-Imported' -ErrorAction SilentlyContinue)) `
        'a one-line variable must not drag the next function in with it'
} finally {
    Remove-Item -LiteralPath (Join-Path $WinDir 'tk-import-probe.ps1') -Force -ErrorAction SilentlyContinue
}

# ...and the source-gate check sees a second door, in each of the three shapes
# it exists to forbid. Against a THROWAWAY COPY, not by breaking the real one:
# a check that cannot fail is decoration, and this one is easy to write so that
# it never fires.
$copy = Join-Path $tmp 'switcher.ps1'

function New-TransportCopy {
    param([string]$Find, [string]$Replace)
    $s = Get-Content -Raw -LiteralPath (Join-Path $WinDir 'trigger-kvm.ps1')
    if (-not $s.Contains($Find)) { throw "the self-test fixture no longer matches the source: $Find" }
    Set-Content -LiteralPath $copy -Value ($s.Replace($Find, $Replace)) -Encoding ASCII
}

# 1. A second emitter, which is the failure the whole rule exists to prevent.
New-TransportCopy '    public static string PacketForStandardVcp(byte vcp, byte value) {' @'
    public static int WriteAnything(NvDisplay target, byte vcp, byte value) {
        return Send(target, BuildSetVcp(LG_I2C_SOURCE, vcp, value));
    }

    public static string PacketForStandardVcp(byte vcp, byte value) {
'@
$c = @(Get-SourceGateComplaint $copy)
Assert-True ($c.Count -ge 1) 'a second emitter of LG_I2C_SOURCE must be reported'
Assert-Match ($c -join "`n") 'LG_I2C_SOURCE outside WriteLgInput'

# 2. The raw literal, sidestepping the constant.
New-TransportCopy '        return Send(target, BuildSetVcp(STD_I2C_SOURCE, vcp, value));' `
                  '        return Send(target, BuildSetVcp(0x50, vcp, value));'
$c = @(Get-SourceGateComplaint $copy)
Assert-True ($c.Count -ge 1) 'the raw literal must be reported too, or the constant is only a convention'
Assert-Match ($c -join "`n") 'the literal 0x50 outside its one const'

# 3. A generic "write to source N", which puts the byte back in a caller's hands.
New-TransportCopy '    public static int WriteStandardVcp(NvDisplay target, byte vcp, byte value) {' `
                  '    public static int WriteStandardVcp(NvDisplay target, byte source, byte vcp, byte value) {'
$c = @(Get-SourceGateComplaint $copy)
Assert-Match ($c -join "`n") 'takes a source or I2C address'

# ...and it does NOT fire on the file as it stands, which the assertion above
# already showed -- restated here so the three cases above are read as a
# comparison rather than as three ways of saying yes.
Assert-Equal 0 @(Get-SourceGateComplaint (Join-Path $WinDir 'trigger-kvm.ps1')).Count

# ---- a test that did not run is never reported as one that passed -------------
#
# run.ps1 prints a passing file's output only under -Verbose, so a skip written
# inside a file that then passed was SWALLOWED and the run said all green. The
# file-level half of that was closed in 5febeec; the case-level half survived it,
# because the `^SKIPPED` filter ran in the exit-2 branch only.
#
# Driven end to end against throwaway probes in a COPY of the harness: the bug is
# in the RENDERING, so asserting Skip-Case and Exit-Skipped alone would not have
# caught it. The copy is also why no probe file is ever left in the real tests
# directory, where the next run would pick it up.
$probeDir = Join-Path $tmp 'harness'
New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'run.ps1') -Destination $probeDir
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'lib.ps1') -Destination $probeDir

function New-Probe {
    param([string]$Name, [string]$Body)
    ". (Join-Path `$PSScriptRoot 'lib.ps1')`n$Body" |
        Set-Content -LiteralPath (Join-Path $probeDir $Name) -Encoding ASCII
}
New-Probe 'pass.tests.ps1'      "Assert-Equal a a`nexit 0"
New-Probe 'filelevel.tests.ps1' "Exit-Skipped 'PROBE-WHOLE-FILE'"
New-Probe 'caselevel.tests.ps1' "Assert-Equal a a`nSkip-Case 'one that cannot' 'PROBE-ONE-CASE'`nexit 0"

function Invoke-Probes {
    param([string]$Filter = '')
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                          -File (Join-Path $probeDir 'run.ps1') $Filter *>&1 |
         ForEach-Object { "$_" }
    return [pscustomobject]@{ Out = ($o -join "`n"); Code = $LASTEXITCODE }
}

$probeRun = Invoke-Probes

# A file that could not run reports SKIP, with its reason, and never PASS.
Assert-Match   $probeRun.Out 'SKIP  filelevel\.tests\.ps1'
Assert-Match   $probeRun.Out 'PROBE-WHOLE-FILE' 'the reason must be printed every time'
Assert-NoMatch $probeRun.Out 'PASS  filelevel\.tests\.ps1'
Assert-Match   $probeRun.Out 'did NOT run on this machine and proved nothing'

# The swallowing bug in one line: this file exits 0, so its output was hidden.
Assert-Match $probeRun.Out 'PASS  caselevel\.tests\.ps1' 'a file that skipped one case still ran the rest'
Assert-Match $probeRun.Out 'PROBE-ONE-CASE'              'and its skip must be surfaced under that PASS'
Assert-Match $probeRun.Out '1 case\(s\) inside the files that did run were skipped'

# A skip is a fact about the machine, not a failure, so it does not raise the code
# -- and the count of files that passed excludes the one that did not run. Three
# probes, one skipped: "all 3 passed" is the false claim.
Assert-Equal 0 $probeRun.Code
Assert-Match $probeRun.Out 'all 2 test files passed'

# A skipped case reaches the summary from a file that FAILED too, where the whole
# output is dumped anyway -- the count is what carries it.
New-Probe 'red.tests.ps1' "Skip-Case 'one that cannot' 'PROBE-RED-SKIP'`nAssert-Equal a b"
$probeRed = Invoke-Probes 'red'
Assert-Match $probeRed.Out 'FAIL  red\.tests\.ps1'
Assert-Equal 1 $probeRed.Code 'the probe harness can still go red, so the assertions above are not vacuous'
Assert-Match $probeRed.Out '1 case\(s\) inside the files that did run were skipped'

# ...and with nothing skipped, neither summary line appears at all.
$probeClean = Invoke-Probes 'pass'
Assert-NoMatch $probeClean.Out 'case\(s\) inside the files'
Assert-NoMatch $probeClean.Out 'proved nothing'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

# Fixture roots must distinguish concurrent processes. A child can inherit a
# parent's isolated root, but no test may introduce a fixed name under TEMP.
function Get-FixtureRootComplaint {
    param([string]$Text)
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text,[ref]$null,[ref]$null)
    foreach ($command in $ast.FindAll({param($a)
        $a -is [Management.Automation.Language.CommandAst] -and $a.GetCommandName() -eq 'Join-Path'
    },$true)) {
        if ($command.Extent.Text -match '\$env:(TEMP|TMP)\b' -and $command.Extent.Text -notmatch '\$PID\b') {
            $command.Extent.Text
        }
    }
}
Assert-Equal 1 @(Get-FixtureRootComplaint 'Join-Path $env:TEMP ''shared.cfg''').Count
Assert-Equal 0 @(Get-FixtureRootComplaint 'Join-Path $env:TEMP "fixture-$PID.cfg"').Count
foreach ($testFile in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File -Recurse) {
    $complaints = @(Get-FixtureRootComplaint (Get-Content -Raw -LiteralPath $testFile.FullName))
    Assert-Equal 0 $complaints.Count ("$($testFile.Name) has a shared fixture root: $($complaints -join ', ')")
}
exit 0
