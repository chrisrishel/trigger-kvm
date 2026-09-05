# The config reader and its two value converters, against the SHARED fixture.
#
# specs/config-format.md, "The shared fixture". Two readers written independently
# drift in the details, and each platform's own tests only ever mirror what its
# author remembered -- so the adversarial cases live once, in specs/, and both
# suites parse them with their own reader.
#
# Before this, "conforms to config-format.md" passed vacuously here: that spec
# has no normative strings, so the conformance check had nothing to look for,
# and three reader disagreements were found by hand that this would have caught.
#
# This is also the file that makes the switcher's fail-closed rule testable on a
# machine with no monitors attached. resolve.tests.ps1 SKIPS without the two
# reference panels; the converters are pure and skip nowhere.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$WinDir  = Split-Path -Parent $PSScriptRoot
$Specs   = Join-Path (Split-Path -Parent $WinDir) 'specs'
$Fixture = Join-Path $Specs 'config-fixture'

. (Join-Path $WinDir 'config.ps1')
Import-Subject -Script 'install.ps1' -Functions @('Format-Byte')

# ---- the fixture is still the fixture ----------------------------------------
#
# input.conf carries a byte-order mark and CRLF lines ON PURPOSE, and
# .gitattributes marks it -text so no checkout normalises them away. A checkout
# that did would make every assertion below prove less than it says.

$bytes = [IO.File]::ReadAllBytes((Join-Path $Fixture 'input.conf'))
Assert-Equal 'EF-BB-BF' ([BitConverter]::ToString($bytes[0..2])) `
    'the fixture must still start with a UTF-8 byte-order mark'
Assert-True (@($bytes | Where-Object { $_ -eq 13 }).Count -ge 3) `
    'and must still carry CRLF lines'

# ---- the reader reproduces expected.tsv, exactly ------------------------------

$cfg = Read-Config -Path (Join-Path $Fixture 'input.conf')
$got  = @($cfg.Keys | ForEach-Object { "$_`t$($cfg[$_])" }) -join "`n"
$want = @(Get-Content -LiteralPath (Join-Path $Fixture 'expected.tsv')) -join "`n"

# -cne throughout: PowerShell's -ne is CASE-INSENSITIVE, and case is half of what
# this fixture pins. A key is lower-cased on read and a value keeps its case
# verbatim, so a reader that dropped the ToLower passed a case-blind comparison.
# Found by a mutation that survived.
if ($got -cne $want) {
    # Say WHICH line, because a wall of two configs is unreadable.
    $g = @($got -split "`n"); $w = @($want -split "`n")
    for ($i = 0; $i -lt [Math]::Max($g.Count, $w.Count); $i++) {
        $a = $(if ($i -lt $w.Count) { $w[$i] } else { '(nothing)' })
        $b = $(if ($i -lt $g.Count) { $g[$i] } else { '(nothing)' })
        if ($a -cne $b) { throw ("line {0}: expected '{1}', got '{2}' -- this reader disagrees with specs/config-fixture/expected.tsv" -f ($i + 1), $a, $b) }
    }
    throw 'the reader output differs from specs/config-fixture/expected.tsv'
}

# Stated separately, because the diff above would pass a reader that simply
# sorted: the ORDER is file order, first appearance, last duplicate winning.
Assert-Equal 'computer.this' (@($cfg.Keys)[0]) 'the first key in the file is the first key back'
Assert-Equal 'last' $cfg['dup']                'and a duplicate key keeps its position, taking the last value'

# ---- the converters agree with every row of values.tsv -----------------------

$bad = @()
foreach ($row in (Get-Content -LiteralPath (Join-Path $Fixture 'values.tsv'))) {
    if (-not $row) { continue }
    # -1 keeps the EMPTY input field, which is one of the rows.
    $f = $row -split "`t", 3
    if ($f.Count -lt 3) { continue }
    $kind = $f[0]; $input = $f[1]; $want = $f[2]

    $n = $(switch ($kind) { 'byte' { ConvertTo-Byte $input } 'word' { ConvertTo-Word $input } })
    $got = $(if ($null -eq $n) { 'REFUSE' } else { [string][int]$n })
    if ($got -ne $want) { $bad += ("{0} '{1}': expected {2}, got {3}" -f $kind, $input, $want, $got) }
}
Assert-Equal 0 $bad.Count ("converter disagreements with specs/config-fixture/values.tsv:`n  " + ($bad -join "`n  "))

# ---- and a refusal is a refusal, not a zero ----------------------------------
#
# The one that has already cost this project: a missing value became 0x00 on the
# wire, an input no monitor has, so every switch silently did nothing and said
# nothing. The null check was present and did not fire.
foreach ($t in @('', 'zzz', '0x1FF', '256', '-1', ' 0x11 ')) {
    Assert-True ($null -eq (ConvertTo-Byte $t)) "ConvertTo-Byte '$t' must refuse, not return a value"
}
Assert-Equal 0 (ConvertTo-Byte '0')   'and zero itself is still a perfectly good byte'
Assert-Equal 0 (ConvertTo-Byte '0x0') 'however it is spelled'

# ---- seconds ------------------------------------------------------------------
#
# specs/detector.md 4. `three` must be REFUSED, never read as zero: a debounce of
# zero fires on every event in a plug's burst, and a watcher that runs while
# doing the wrong thing is the worst failure shape available.
foreach ($t in @('0', '3', '3.0', '0.75', '10.125')) {
    Assert-True (Test-Seconds $t) "'$t' is a number of seconds"
}
foreach ($t in @('', 'three', '3 s', '-1', '3.', '.5', '1e3', ' 3')) {
    Assert-True (-not (Test-Seconds $t)) "'$t' is not, and must be refused by name"
}

# ---- one spelling per input value ---------------------------------------------
#
# specs/configure.md 6.1: `17` and `0x11` are one socket. The walkthrough gets
# that by converting at the boundary rather than comparing cleverly afterwards,
# so what has to hold is that both spellings land on the same string.
Assert-Equal '0x11' (Format-Byte '17')
Assert-Equal '0x11' (Format-Byte '0x11')
Assert-Equal '0x11' (Format-Byte '0X11')
Assert-Equal '0x0F' (Format-Byte '15')   'two digits, upper case, as the tables are written'
Assert-Equal '0x00' (Format-Byte '0')
Assert-Equal $null  (Format-Byte 'd1')   'a bare hex byte is not a byte -- the reader would drop it'
Assert-Equal $null  (Format-Byte '256')

# ---- a writer must not write what it cannot read back -------------------------
#
# specs/config-format.md. The read rule was pinned to the byte and said nothing
# about writers, so BOTH implementations wrote values straight through and both
# were wrong the same way -- which is what a missing shared rule looks like
# rather than two coincidental bugs.
#
# Measured 2026-09-04: a display's name is written verbatim from what the panel
# reports, so `ACME #1 Display` was written intact and read back as `ACME`.

Assert-Equal 'ACME 1 Display' (ConvertTo-ConfigValue 'ACME #1 Display') `
    'a hash is removed, because the reader cuts the value there and there is no escape'
Assert-Equal 'ACME Display' (ConvertTo-ConfigValue "ACME`nDisplay") `
    'and a newline, which would otherwise end the line mid-value'
Assert-Equal 'ACME Display' (ConvertTo-ConfigValue "ACME`r`nDisplay")
Assert-Equal 'ACME' (ConvertTo-ConfigValue '   ACME   ') 'surrounding space is trimmed, as the reader trims it'
Assert-Equal 'ACME = 42' (ConvertTo-ConfigValue 'ACME = 42') `
    'but `=` is untouched: a value may contain one and it is not a second separator'
Assert-Equal '' (ConvertTo-ConfigValue '') 'and nothing in is nothing out, not an error'

# THE PROPERTY THAT MATTERS, asserted as a round trip rather than as a string:
# whatever a writer emits must read back identically. A test of the sanitiser
# alone would pass while the reader changed underneath it.
$rt = Join-Path $env:TEMP 'tk-writer-roundtrip.cfg'
foreach ($raw in @('ACME #1 Display', "ACME`nDisplay", '   ACME   ', 'ACME = 42',
                   'Logitech USB Camera (Webcam C930e)', 'Clarett+ 2Pre')) {
    $safe = ConvertTo-ConfigValue $raw
    ('display.x.name = {0}' -f $safe) | Set-Content -LiteralPath $rt -Encoding ASCII
    Assert-Equal $safe ([string](Read-Config -Path $rt)['display.x.name']) `
        ("what the writer emits for '{0}' must read back unchanged" -f ($raw -replace "`n",'\n'))
}
Remove-Item -LiteralPath $rt -Force -ErrorAction SilentlyContinue

# An IDENTIFIER is different from a label: a near-miss is stored, looks right and
# matches nothing, so a caller writing one asks first and refuses.
Assert-True  (Test-ConfigValueExact 'g915-x-lightspeed-tkl') 'a token survives, so it may be written'
Assert-True  (-not (Test-ConfigValueExact 'ACME #1')) 'one that would be altered is reported, not quietly stored'
Assert-True  (-not (Test-ConfigValueExact 'trailing ')) 
Assert-True  (Test-ConfigValueExact 'ACME = 42') 'and `=` does not make a value inexact'

exit 0
