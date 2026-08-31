<#
.SYNOPSIS
Does this implementation contain every normative string its spec pins down?

.DESCRIPTION
    .\check-conformance.ps1 <spec.md> <source> [source...]

Exits 0 when every fragment is present, 1 otherwise, listing what is missing.

WHAT THIS PROVES, AND WHAT IT DOES NOT. It proves a string is PRESENT in the
sources. It does not prove that string is REACHABLE -- a shadowed function can
still contain it. That gap is real and bit this project once, in install.ps1,
where a duplicate definition left the older wording live and the newer wording
dead in the same file. conventions.tests.ps1 is the structural half.

The marker format is the cross-platform contract, not this script: macOS
implements the same check in bash as specs/check-conformance.sh, the same way
each platform implements its own transport. See ../../specs/README.md.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Spec,
    [Parameter(Mandatory = $true, Position = 1, ValueFromRemainingArguments = $true)][string[]]$Source
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormativeFragment {
    <#
      .SYNOPSIS
      Every literal fragment a spec pins down: each line inside a ```normative
      fence, split on {placeholders}.

      .DESCRIPTION
      The length floor applies only to fragments produced BY SPLITTING. A whole
      line with no placeholder in it was written down deliberately and is
      distinctive enough to pin at any length -- "--- monitors ---" is 16
      characters and could not match by accident. A piece left between two
      placeholders often is not, so those carry an 18-character floor.

      A blanket floor is wrong, and silently so: it drops every section header
      in the spec, so renaming one changes nothing and the check stays green.
      That is a mutation the macOS side found surviving.
    #>
    param([string[]]$Line)

    $inBlock = $false
    foreach ($raw in $Line) {
        if ($raw -match '^```normative[ \t]*$') { $inBlock = $true; continue }
        if ($raw -match '^```')                 { $inBlock = $false; continue }
        if (-not $inBlock) { continue }

        if ($raw -notmatch '\{[^}]*\}') {
            $whole = $raw.Trim()
            if ($whole.Length -ge 6) { $whole }
            continue
        }
        foreach ($piece in [regex]::Split($raw, '\{[^}]*\}')) {
            $t = $piece.Trim()
            if ($t.Length -ge 18) { $t }
        }
    }
}

$sources = (Get-Content -Raw -LiteralPath $Source) -join "`n"
$frags   = @(Get-NormativeFragment -Line (Get-Content -LiteralPath $Spec))

$missing = @($frags | Where-Object { -not $sources.Contains($_) })

foreach ($m in $missing) { Write-Host "  MISSING: $m" }

if ($missing.Count -gt 0) {
    Write-Host ("{0} of {1} normative fragments from {2} are missing" -f
                $missing.Count, $frags.Count, $Spec)
    exit 1
}
Write-Host ("all {0} normative fragments from {1} are present" -f $frags.Count, $Spec)
exit 0
