<#
.SYNOPSIS
Reintroduce each bug the suite is supposed to catch, and check that it does.

.DESCRIPTION
    .\mutate.ps1              every mutation
    .\mutate.ps1 config       only mutations whose name matches
    .\mutate.ps1 -RestoreOnly put back anything an interrupted run left mutated

A passing test proves nothing until it can fail. Each entry below reintroduces
a bug -- most of them bugs this project has actually shipped -- and asserts that
some test goes red. A SURVIVING mutation is a failure of this script: it means
an assertion passes for a reason other than the one it claims.

A mutation is only judged against a suite file that PASSES UNMUTATED. Each suite
is run once, clean, before its first mutation; if it is red already, every
mutation aimed at it is reported UNJUDGED and counted as survived, because "the
suite went red" then proves nothing.

NOT run by run.ps1. It edits files in place, so it is something you run
deliberately. It restores every file it touches, including when a suite wedges
or the run is interrupted -- and it restores leftovers before starting, because
a mutated source left behind silently becomes what the next test run measures.
#>
[CmdletBinding()]
param([string]$Filter = '', [switch]$RestoreOnly)

$ErrorActionPreference = 'Stop'
$WinDir = Split-Path -Parent $PSScriptRoot

$script:Checked  = 0
$script:Survived = 0
$script:Unjudged = 0
$script:Green    = @{}     # suite file -> $true/$false, measured once

# A run killed outright cannot clean up after itself, and a mutated source left
# in the tree is what the next test run then measures. That has cost an hour
# before now, so: restore anything left over first, and say so.
foreach ($bak in @(Get-ChildItem -LiteralPath $WinDir -Filter '*.mutbak' -File -Recurse -ErrorAction SilentlyContinue)) {
    $orig = $bak.FullName -replace '\.mutbak$', ''
    Write-Host ("  restoring {0}, left mutated by an interrupted run" -f (Split-Path -Leaf $orig))
    Move-Item -LiteralPath $bak.FullName -Destination $orig -Force
}
if ($RestoreOnly) { exit 0 }

# One suite file, in its own process, bounded. A mutant can HANG rather than
# fail -- a prompt at EOF that re-asks forever is the shape -- and an unbounded
# run would turn a caught mutation into a wedged terminal.
#
# [Diagnostics.Process] rather than Start-Process, and that is not a style
# choice: `Start-Process -PassThru` WITHOUT -Wait hands back a process object
# whose ExitCode never populates -- measured here, it reads as empty after
# WaitForExit returns true, so every suite looked red and every mutation came
# back UNJUDGED. -Wait would populate it and has no timeout.
function Invoke-Suite {
    param([string]$Suite, [int]$TimeoutSeconds = 300)

    $out = Join-Path $env:TEMP 'trigger-kvm-mutate.out'
    $err = "$out.err"
    foreach ($f in @($out, $err)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName               = 'powershell.exe'
    $psi.Arguments              = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $PSScriptRoot $Suite)
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $p = [Diagnostics.Process]::Start($psi)
    # Read both streams asynchronously. A suite that fills a 4KB pipe buffer
    # while nobody is reading it BLOCKS, which would look exactly like a hang.
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill() } catch { }
        return [pscustomobject]@{ Ok = $false; Why = "timed out after ${TimeoutSeconds}s" }
    }
    $text = "$($so.Result)`n$($se.Result)"
    Set-Content -LiteralPath $out -Value $text -Encoding ASCII

    $why = @($text -split "`r?`n" | Where-Object { $_ -match 'expected |does not match |matches /' }) |
           Select-Object -First 1
    return [pscustomobject]@{ Ok = ($p.ExitCode -eq 0); Why = "$why".Trim() }
}

function Test-SuiteGreen {
    param([string]$Suite)
    if (-not $script:Green.ContainsKey($Suite)) {
        $script:Green[$Suite] = (Invoke-Suite -Suite $Suite).Ok
    }
    return $script:Green[$Suite]
}

# One mutation.
#
# -Find is a LITERAL substring on ONE line, not a regex or a patch. A regex
# would have to be escaped twice over -- once for PowerShell, once for the
# pattern -- against source that is itself full of $, ` and \, and every version
# of this that took one silently failed to apply somewhere and reported the
# mutation caught. A literal that does not appear is an ERROR here, loudly.
function Invoke-Mutation {
    param([string]$Name, [string]$File, [string]$Suite, [string]$Find, [string]$Replace = '')

    if ($Filter -and $Name -notlike "*$Filter*") { return }

    $target = Join-Path $WinDir $File
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Host ("  ERROR     {0}  ->  no such file: {1}" -f $Name, $File)
        $script:Checked++; $script:Survived++
        return
    }

    if (-not (Test-SuiteGreen -Suite $Suite)) {
        Write-Host ("  UNJUDGED  {0}  ->  {1} is red before any mutation; fix the suite first" -f $Name, $Suite)
        $script:Checked++; $script:Survived++; $script:Unjudged++
        return
    }

    $backup = "$target.mutbak"
    Copy-Item -LiteralPath $target -Destination $backup -Force
    try {
        $src = Get-Content -Raw -LiteralPath $target
        if (-not $src.Contains($Find)) {
            Write-Host ("  ERROR     {0}  ->  mutation did not apply; '{1}' is not in {2}" -f $Name, $Find, $File)
            $script:Checked++; $script:Survived++
            return
        }
        # -Encoding ASCII, and no BOM: PowerShell 5.1 reads a .ps1 with a BOM
        # differently, and these files are ASCII by convention anyway.
        [IO.File]::WriteAllText($target, $src.Replace($Find, $Replace), [Text.Encoding]::ASCII)

        # A mutant that does not PARSE tests nothing: the suite goes red for the
        # wrong reason and the mutation reads as caught. Only scripts have a
        # parser to fail; some subjects here are markdown.
        $errors = $null
        if ($target -like '*.ps1') {
            [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$null, [ref]$errors) | Out-Null
        }
        if ($errors) {
            Write-Host ("  ERROR     {0}  ->  the mutated source does not parse: {1}" -f $Name, $errors[0].Message)
            $script:Checked++; $script:Survived++
            return
        }

        $script:Checked++
        $r = Invoke-Suite -Suite $Suite
        if ($r.Ok) {
            Write-Host ("  SURVIVED  {0}" -f $Name)
            $script:Survived++
        } else {
            Write-Host ("  caught    {0}  ->  {1}" -f $Name, $r.Why)
        }
    } finally {
        Move-Item -LiteralPath $backup -Destination $target -Force
    }
}

# =============================================================================
# The mutations
# =============================================================================

# --- the instruction-file budget ---------------------------------------------

Invoke-Mutation 'docs: windows/AGENTS.md grows past the Codex budget' `
    'AGENTS.md' 'conventions.tests.ps1' `
    '# Windows -- agent instructions' `
    ('# Windows -- agent instructions' + "`n<!-- " + ('x' * 600) + ' -->')
Invoke-Mutation 'docs: a CLAUDE.md becomes a second copy instead of an import' `
    'CLAUDE.md' 'conventions.tests.ps1' `
    '@AGENTS.md' '# Windows -- agent instructions'

# --- which config the watcher reads ------------------------------------------

# Replaced rather than deleted: dropping the last element of the array would
# leave a dangling comma, and a mutant that does not parse tests nothing.
Invoke-Mutation 'launch: the task action does not name the config' `
    'install.ps1' 'install.tests.ps1' `
    "        '-Config', ""``""`$ConfigFile``""""" "        '-Arg', 'pull'"
Invoke-Mutation 'launch: the switcher is left to re-derive the config path' `
    'event-watch.ps1' 'install.tests.ps1' `
    "    if (`$ConfigFile) { `$a += @('-Config',  ""``""`$ConfigFile``"""") }" ''
Invoke-Mutation 'launch: an absent log becomes an empty -LogFile' `
    'event-watch.ps1' 'install.tests.ps1' `
    "    if (`$LogFile)    { `$a += @('-LogFile', ""``""`$LogFile``"""") }" `
    "    `$a += @('-LogFile', ""``""`$LogFile``"""")"

# --- the pre-rename cleanup ---------------------------------------------------

Invoke-Mutation 'legacy: any display-switch directory is deleted' `
    'install.ps1' 'install.tests.ps1' `
    "    if (-not (Test-Path -LiteralPath `$vbs -PathType Leaf)) { return `$false }" `
    "    return `$true"
Invoke-Mutation 'legacy: any task of that name is unregistered' `
    'install.ps1' 'install.tests.ps1' `
    "    if (`$act -match '(usb|event)-watch\.ps1') { return `$true }" `
    "    return `$true"

# --- the monitors list --------------------------------------------------------

Invoke-Mutation 'monitors: the list disables a row it does not own' `
    'install.ps1' 'walkthrough.tests.ps1' `
    '        $pick = Select-One -Items $items -Detail $detail -Default $land -Escapable' `
    '        $pick = Select-One -Items $items -Detail $detail -Default $land -Disabled $off -Escapable'

# =============================================================================

Write-Host ''
if ($script:Survived -eq 0) {
    Write-Host ("all {0} mutations were caught" -f $script:Checked)
} elseif ($script:Survived -eq $script:Unjudged) {
    Write-Host ("{0} of {1} mutations UNJUDGED -- their suite is red unmutated, so nothing was proved" -f
                $script:Unjudged, $script:Checked)
} else {
    Write-Host ("{0} of {1} mutations SURVIVED ({2} unjudged) -- those assertions do not earn their place" -f
                $script:Survived, $script:Checked, $script:Unjudged)
}
exit $script:Survived
