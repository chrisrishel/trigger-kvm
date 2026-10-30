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

# EVERYTHING THE USER CAN SEE, derived rather than listed. It was three files;
# splitting install.ps1 moved every line of the walkthrough into lib\, and a
# hand-written list would have gone on checking three files that no longer held
# any of it -- reporting conformance about wording it could not see. The
# self-test below is what caught that, which is the whole reason it is there.
function Get-ConformanceSources {
    param([string]$Root)
    $Root = (Get-Item -LiteralPath $Root).FullName
    $tests = (Join-Path $Root 'tests') + [IO.Path]::DirectorySeparatorChar
    return @(Get-ChildItem -LiteralPath $Root -Filter '*.ps1' -File -Recurse |
        Where-Object { -not $_.FullName.StartsWith($tests, [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object { $_.FullName } | Sort-Object)
}
$Sources = @(Get-ConformanceSources $WinDir)
Assert-True ($Sources.Count -ge 5) 'the conformance check must have found sources to read'

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
$tmp  = Join-Path $env:TEMP "trigger-kvm-spec-tests-$PID"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$tmp = (Get-Item -LiteralPath $tmp).FullName

# A new directory must join without an edit to this test. Compare elements,
# not a joined string or count that could hide a missing file.
$tree = Join-Path $tmp 'source-tree'
New-Item -ItemType Directory -Force -Path "$tree\lib\nested", "$tree\tests" | Out-Null
foreach ($name in @('entry.ps1','lib\nested\message.ps1','tests\excluded.ps1')) {
    Set-Content -LiteralPath (Join-Path $tree $name) -Value '# fixture' -Encoding ASCII
}
$listed = @(Get-ConformanceSources $tree)
Assert-Equal 2 $listed.Count
Assert-Equal (Join-Path $tree 'entry.ps1') $listed[0]
Assert-Equal (Join-Path $tree 'lib\nested\message.ps1') $listed[1]
# Enumeration expands DOS aliases and dot segments. The exclusion must compare
# canonical paths too, or tests/excluded.ps1 silently joins production sources.
$shortTree = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($tree).ShortPath
foreach ($alias in @("$tree\.", $shortTree)) {
    $aliased = @(Get-ConformanceSources $alias)
    Assert-Equal 2 $aliased.Count 'path aliases must not include the tests directory'
    Assert-Equal $listed[0] $aliased[0]
    Assert-Equal $listed[1] $aliased[1]
}

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

# Comments in both shipped languages cannot supply normative UI wording.
$commentSource = Join-Path $tmp 'comments.ps1'
$realSources = $Sources
$Sources = @($commentSource)
@(
    '# --- nowhere ---',
    'Write-Output "actual text" # --- nowhere ---',
    '<# --- nowhere --- #>',
    ('$Native = @' + "'"),
    'using System;',
    '// --- nowhere ---',
    '/* --- nowhere --- */',
    'public class Fixture { public string Value = "real"; }',
    ("'" + '@')
) | Set-Content -LiteralPath $commentSource -Encoding ASCII
$r = Invoke-Checker $header
Assert-Equal 1 $r.Code 'neither PowerShell nor embedded C# comments count'
Add-Content -LiteralPath $commentSource -Value 'Write-Output "--- nowhere ---"' -Encoding ASCII
$r = Invoke-Checker $header
Assert-Equal 0 $r.Code 'an actual user-visible string counts'
$Sources = $realSources

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

# ---- this implementation conforms -------------------------------------------

# detector.md too, since revision 7. It pins no wording today -- the detector
# talks to a log, not to a person -- so the check passes on it trivially. It is
# in the loop anyway, because the day it grows a normative string is the day
# nobody will think to add it here.
#
# status.md since revision 8.
$CHECKED = @(Get-ChildItem -LiteralPath $Specs -Filter '*.md' -File |
    Where-Object { $_.Name -notin @('README.md','CHANGELOG.md') } | ForEach-Object { $_.BaseName })

# The two files in specs/ that are NOT contracts, and why each is not:
#
#   README.md    its ```normative block is the worked EXAMPLE of the marker
#                format, not an obligation -- checking it would demand those
#                fragments of every implementation
#   CHANGELOG.md the revision ledger, checked below by number instead
#
$NOT_CONTRACTS = @('README.md', 'CHANGELOG.md')

# ---- the list above is COMPLETE ----------------------------------------------
#
# THE HAZARD THIS CLOSES, and it is not hypothetical. A suite that loops over a
# list of spec names it holds itself cannot check a file nobody added to that
# list, and the suite stays GREEN while doing it: specs/README.md records this as
# the conformance check's third blind spot. status.md landed at revision 8 and
# went unchecked on macOS for revisions 8 through 12 -- five revisions reporting
# conformance while six normative fragments were absent. The only thing that
# caught it was revision 8's changelog entry happening to say "add status.md to
# your conformance loop"; an entry that merely described the behaviour would have
# got the revision bumped and the strings skipped for good.
#
# So the list is not trusted, it is CHECKED. A new spec file fails here until
# somebody decides which it is -- a contract to check, or a meta-file to name --
# and that failure is loud, where forgetting was silent.
#
# The alternative is to DERIVE the list by globbing specs/*.md, which macOS does.
# Deriving is not what makes this safe; this assertion is. Kept as a list because
# it is the smaller change and a glob has a quiet failure of its own -- one that
# matches nothing passes vacuously, which is why that case is asserted below.
function Get-UncoveredSpecs {
    param([string[]]$Files, [string[]]$Checked, [string[]]$NotContracts)
    # A glob that matched nothing is not "everything is covered", it is a broken
    # check reporting success -- the exact failure shape this whole section is
    # about, one level up.
    if (@($Files).Count -eq 0) { return @('specs/ has no .md files at all -- the check is broken, not passing') }
    $known = @($Checked | ForEach-Object { "$_.md" }) + @($NotContracts)
    return @($Files | Where-Object { $known -notcontains $_ })
}

# The instrument first, as above: an assertion that cannot fail is decoration.
Assert-Equal 0 (@(Get-UncoveredSpecs -Files @('configure.md','README.md') `
                                     -Checked @('configure') -NotContracts @('README.md')).Count) `
    'a fully covered specs/ is covered'
Assert-Equal 'new.md' (@(Get-UncoveredSpecs -Files @('configure.md','new.md') `
                                            -Checked @('configure') -NotContracts @()) )[0] `
    'a spec file in neither list is NAMED -- this is the whole point'
Assert-Equal 1 (@(Get-UncoveredSpecs -Files @() -Checked @('configure') -NotContracts @()).Count) `
    'and a listing that found nothing FAILS, rather than passing vacuously'

# Now the real one.
$onDisk = @(Get-ChildItem -LiteralPath $Specs -Filter '*.md' -File | ForEach-Object { $_.Name })
$uncovered = @(Get-UncoveredSpecs -Files $onDisk -Checked $CHECKED -NotContracts $NOT_CONTRACTS)
Assert-Equal 0 $uncovered.Count ( @(
    "specs/ holds a .md nobody checks: $($uncovered -join ', ')"
    'Add it to $CHECKED if it is a contract, or to $NOT_CONTRACTS if it is not.'
    'A spec checked by nobody is why this assertion exists -- see the comment above.') -join "`n" )

# EVERY name in the list is a file that exists, or a typo silently checks nothing
# -- the same blind spot wearing the other hat.
foreach ($spec in $CHECKED + $NOT_CONTRACTS) {
    $name = $(if ($spec -like '*.md') { $spec } else { "$spec.md" })
    Assert-True ($onDisk -contains $name) "the list names specs/$name, which does not exist"
}

foreach ($spec in $CHECKED) {
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
