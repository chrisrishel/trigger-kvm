# Conformance: does this implementation contain every normative string the specs
# pin down, and is it level with the spec revision?
#
# ../../specs is what this is built FROM. When the specs and the code disagree,
# the code is wrong -- so a spec edit fails here until this platform catches up,
# which is what makes "spec first" a rule rather than a hope.
#
# See ../../specs/README.md for the marker format and for what the string check
# does NOT prove: it proves a string is PRESENT, not that it is REACHABLE. The
# structural half is conventions.tests.ps1.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$WinDir = Split-Path -Parent $PSScriptRoot
$Specs  = Join-Path (Split-Path -Parent $WinDir) 'specs'
$Check  = Join-Path $PSScriptRoot 'check-conformance.ps1'

# Everything the user can see comes out of these three.
$Sources = @(
    (Join-Path $WinDir 'install.ps1')
    (Join-Path $WinDir 'trigger-kvm.ps1')
    (Join-Path $WinDir 'event-watch.ps1')
)

# A child process, not a dot-source: the checker exits with its verdict, and an
# exit in this runspace would end the test file at the first spec.
function Invoke-Checker {
    param([string]$SpecFile)
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Check $SpecFile @Sources *>&1 |
           ForEach-Object { "$_" }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
}

Assert-True (Test-Path -LiteralPath $Check) "the checker is missing: $Check"

# ---- the checker actually bites ---------------------------------------------
#
# The instrument is proved before it is trusted, and that ordering is load
# bearing: a broken checker passes everything, so putting the real conformance
# assertion first would let a checker that never fails look like a clean bill of
# health, and the mutation that broke it would have nothing to fail.

# A conformance check that cannot fail is decoration. Prove it against a
# throwaway spec rather than by breaking a real one.
$tmp  = Join-Path $env:TEMP 'trigger-kvm-spec-tests'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$fake = Join-Path $tmp 'fake-spec.md'
@'
# A spec nothing implements

```normative
this exact sentence appears in no source file anywhere
```
'@ | Set-Content -LiteralPath $fake -Encoding ASCII

$r = Invoke-Checker $fake
Assert-Equal 1 $r.Code 'a missing fragment must fail'
Assert-Match $r.Text 'this exact sentence appears in no source file'

# ---- and does not bite on things too short to pin anything down -------------

$short = Join-Path $tmp 'short-spec.md'
@'
```normative
{a} zqxjv {b}
```
'@ | Set-Content -LiteralPath $short -Encoding ASCII

# The fragment has to be one that is genuinely ABSENT, or the case proves nothing:
# with "ok" here, dropping the floor altogether still passed, because "ok" turns up
# in the sources anyway. Found by a mutation that survived.
$r = Invoke-Checker $short
Assert-Equal 0 $r.Code 'a fragment left between two placeholders, under the floor, is not normative'

# ---- a whole line is pinned at any length, a split piece is not -------------

# The subtlety a blanket floor gets wrong. "--- monitors ---" is 16 characters
# and was written down deliberately; with one floor for both cases every section
# header in the spec is silently dropped and renaming one changes nothing.
$header = Join-Path $tmp 'header-spec.md'
@'
```normative
--- nowhere ---
```
'@ | Set-Content -LiteralPath $header -Encoding ASCII

# 15 characters: BELOW the 18-character floor a split piece carries, and above the
# 6 a whole line carries. A fixture on the wrong side of that proves nothing --
# with a 22-character one here, collapsing the two floors into one still passed.
$r = Invoke-Checker $header
Assert-Equal 1 $r.Code 'a whole line under 18 characters must still be checked'
Assert-Match $r.Text 'nowhere'

# ---- placeholders are split on, not matched literally -----------------------

$ph = Join-Path $tmp 'ph-spec.md'
@'
```normative
{some placeholder} here, so you can read this. {another}
```
'@ | Set-Content -LiteralPath $ph -Encoding ASCII

$r = Invoke-Checker $ph
Assert-Equal 0 $r.Code 'the literal between placeholders is what is checked'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

# ---- this implementation conforms -------------------------------------------

# detector.md too, since revision 7. It pins no wording today -- the detector
# talks to a log, not to a person -- so the check passes on it trivially. It is
# in the loop anyway, because the day it grows a normative string is the day
# nobody will think to add it here.
foreach ($spec in 'configure', 'config-format', 'detector') {
    $r = Invoke-Checker (Join-Path $Specs "$spec.md")
    Assert-Equal 0 $r.Code "windows does not conform to specs/$spec.md:`n$($r.Text)"
}

# =============================================================================
# The spec revision this implementation claims to implement
# =============================================================================
#
# The string check above is blind to two kinds of spec change: a behavioural one
# with no new wording to grep for, and a REMOVED string, since it only tests
# presence. The revision closes both -- and it is how this platform finds out it
# is behind without anyone having to tell it, which is what makes a third
# implementation cost nothing.

function Get-SpecRevision {
    param([string]$Path)
    $m = [regex]::Match((Get-Content -Raw -LiteralPath $Path), '(?m)^revision\s*=\s*(\d+)')
    if (-not $m.Success) { return $null }
    return [int]$m.Groups[1].Value
}

$changelog = Get-Content -Raw -LiteralPath (Join-Path $Specs 'CHANGELOG.md')
$revisions = @([regex]::Matches($changelog, '(?m)^## Revision (\d+)') |
                ForEach-Object { [int]$_.Groups[1].Value })

Assert-True ($revisions.Count -gt 0) "specs/CHANGELOG.md must carry '## Revision N' entries"
$head = ($revisions | Measure-Object -Maximum).Maximum

$mine = Get-SpecRevision (Join-Path $WinDir 'SPEC-REVISION')
Assert-True ($null -ne $mine) "windows/SPEC-REVISION must carry 'revision = N'"

# When this fails, read the changelog entries between the two numbers: they are
# what this platform owes. Bump SPEC-REVISION in the commit that lands them.
if ($mine -lt $head) {
    $owed = ($revisions | Where-Object { $_ -gt $mine } | Sort-Object | ForEach-Object { "rev $_" }) -join ', '
    throw ("windows implements spec revision {0}; specs/CHANGELOG.md is at {1}. Outstanding: {2}" -f
           $mine, $head, $owed)
}

# Ahead means someone implemented a change without writing it down, which is the
# spec-first rule broken in the direction that leaves no trace.
Assert-True ($mine -le $head) `
    "windows/SPEC-REVISION is $mine but the changelog only reaches $head"

exit 0
