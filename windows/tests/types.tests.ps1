# The loaded-type guard, and the installer's immunity to it.
#
# trigger-kvm.ps1 Add-Types its NVAPI bindings, and .NET cannot replace a type once a
# runspace has loaded it. Running the SECOND version's script against the FIRST
# version's types would hand-verify code that is not the code on disk -- and
# hand-verification is the only verification this hardware permits, so a false pass is
# the most expensive failure available here. The guard refuses instead.
#
# The installer must not be able to trip it, because there the refusal lands
# mid-walkthrough as a stack trace for a reason that has nothing to do with anyone's
# monitors. It runs its siblings in child processes so the question cannot arise.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$dir = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path $env:TEMP 'trigger-kvm-oldbuild'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# An "older build": the same script with one byte of C# different, so its source hash
# differs. config.ps1 has to come too -- without it the copy dies on its dot-source
# and never loads a type, which would make this whole file assert nothing. That is
# not hypothetical; it is how the first two versions of this test passed while
# proving nothing.
Copy-Item (Join-Path $dir 'config.ps1') $tmp -Force
$old = Join-Path $tmp 'trigger-kvm.ps1'
(Get-Content -Raw (Join-Path $dir 'trigger-kvm.ps1')) -replace
    '// One connected output', '// ONE CONNECTED OUTPUT (an older build)' |
    Set-Content -LiteralPath $old -Encoding UTF8

& $old list *>&1 | Out-Null
if (-not ('NvDdc' -as [type])) {
    Write-Host 'SKIPPED: the old build loaded no types (no NVAPI here?), so there is nothing to guard'
    exit 0
}

# ---- the guard fires for a direct run ---------------------------------------

$fired = $false
try   { & (Join-Path $dir 'trigger-kvm.ps1') list *>&1 | Out-Null }
catch { $fired = "$($_.Exception.Message)" -match 'already loaded' }
Assert-True $fired 'a second version in one session must refuse rather than run stale code'

# ---- the installer is immune ------------------------------------------------

$out = (& (Join-Path $dir 'install.ps1') discover *>&1 | ForEach-Object { "$_" }) -join "`n"
Assert-NoMatch $out 'already loaded' 'the installer must not inherit this session''s types'
Assert-Match   $out 'name \(from the panel\)|no displays found|NVAPI unavailable' `
    'and must still have reached the switcher'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
exit 0
