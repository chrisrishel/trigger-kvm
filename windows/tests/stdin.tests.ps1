# configure, driven by a scripted answer stream on stdin -- specs/configure.md 3.5.
#
# The only test here that runs the REAL install.ps1 as a REAL process with REAL
# input. Every other file imports functions and stubs Read-Host, which is faster
# and sharper but cannot see this: whether a piped answer stream reaches the
# walkthrough at all.
#
# It did not. Test-CanPrompt refused a redirected stdin outright, so the typed
# fallback the menus grew specifically for this case was unreachable from the one
# caller that needs it, and "the suite drives configure end to end" was true of a
# stub and false of the program.
#
# Nothing here can move a monitor: configure writes nothing until Save (4.4), and
# these runs never reach Save.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$install = Join-Path (Split-Path -Parent $PSScriptRoot) 'install.ps1'

# install.ps1 has no -Config: the path is derived from LOCALAPPDATA, so that is
# what gets moved. A run must never be able to read or write the real config --
# the developer's own working setup is the thing on the other side of that path.
$tmp = Join-Path $env:TEMP 'trigger-kvm-stdin-tests'
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$cfg = Join-Path $tmp 'trigger-kvm\config'

function Stop-Tree {
    param([int]$Id)
    foreach ($c in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$Id" -Verbose:$false)) {
        Stop-Tree -Id ([int]$c.ProcessId)
    }
    Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue
}

function Invoke-Configure-WithInput {
    <#
      .SYNOPSIS
      Run `install.ps1 configure` with the given lines as stdin, and return what
      it printed.

      .DESCRIPTION
      A .cmd wrapper, because two things have to be true of the CHILD only:
      LOCALAPPDATA points at a throwaway directory (install.ps1 derives the config
      path from it and has no -Config), and stdin is redirected FROM A FILE. A
      PowerShell pipeline cannot do the second at all -- piping into
      powershell.exe makes it read stdin as its COMMAND stream rather than as
      answers.

      BOUNDED, and that is not caution. The defect under test is an INFINITE LOOP:
      a required prompt re-asks on a blank, and every read of an unreadable stream
      is blank. Run unbounded, this file turns "configure spins" from a failing
      test into a hung suite -- which is the one failure a test runner must not
      have. Verified by mutation: putting Read-Host back makes the wait expire.
    #>
    param([string[]]$Answers, [int]$TimeoutSeconds = 60)

    $answerFile = Join-Path $tmp 'answers.txt'
    $outFile    = Join-Path $tmp 'out.txt'
    $runner     = Join-Path $tmp 'run.cmd'
    Set-Content -LiteralPath $answerFile -Value $Answers -Encoding ASCII
    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $runner -Encoding ASCII -Value @(
        '@echo off'
        ('set "LOCALAPPDATA={0}"' -f $tmp)
        ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" configure < "{1}" > "{2}" 2>&1' -f
            $install, $answerFile, $outFile)
    )

    $p = Start-Process cmd.exe -ArgumentList '/c', "`"$runner`"" -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Tree -Id $p.Id
        throw "configure did not finish within ${TimeoutSeconds}s -- it is spinning on input it cannot read"
    }
    if (-not (Test-Path -LiteralPath $outFile)) { return '' }
    return ((Get-Content -LiteralPath $outFile) -join "`n")
}

# ---- a piped answer stream is not an absence of input ------------------------

$out = Invoke-Configure-WithInput @('11')     # 11) Cancel (discard changes)

Assert-NoMatch $out 'configure needs an interactive terminal' `
    'a redirected stdin is a script of answers, and must reach the walkthrough'
Assert-Match $out '--- configuration ---' 'the top menu has to have been drawn'
Assert-Match $out 'Cancel \(discard changes\)' 'and its rows numbered for typing'

# ---- and running out of it stops, rather than spinning -----------------------

# The failure this replaces is not a wrong answer, it is a hang: every required
# prompt re-asks on a blank, and at EOF every read is blank forever.
$out = Invoke-Configure-WithInput @()

Assert-Match $out 'ran out of input\. configure needs a terminal, or a complete script of answers\.' `
    'EOF must be reported as itself'

# Once, not once per re-ask. A guard that says it and loops anyway has not fixed
# anything -- it has only made the spin noisier.
$said = ([regex]::Matches($out, 'ran out of input')).Count
Assert-Equal 1 $said 'the message is said once and the program stops'

# ---- nothing was written, and nothing was installed --------------------------

Assert-True (-not (Test-Path -LiteralPath $cfg)) `
    'configure writes nothing until Save, and neither run reached it'

# `configure` runs the install path afterwards, so a run that fell through to it
# would register a scheduled task -- which is machine-wide and outlives
# LOCALAPPDATA being redirected. Both paths here exit non-zero before that.
Assert-True (-not (Test-Path -LiteralPath (Join-Path $tmp 'Programs\trigger-kvm'))) `
    'neither run may reach the install path'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
exit 0
