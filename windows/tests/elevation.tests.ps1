# Who an install is FOR, and how that survives the trip to the elevated child.
#
# `-Verb RunAs` from a STANDARD account elevates a DIFFERENT user. Everything the
# child would otherwise derive for itself -- $DEST, $LOG, $CONFIG, the task
# principal -- would then be the ADMIN's, so the person who asked for boot start
# gets a watcher installed into somebody else's profile and nothing says so.
#
# The parent therefore hands over two facts it knows for certain, and the child is
# started by handing a STRING to `powershell -Command` -- so the handover is only
# as good as the quoting. A user name or a profile path may contain a space.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

Import-Subject -Script 'install.ps1' -Functions @('Format-ChildArguments', 'Request-Elevation')

# ---- flags stay bare, values get quoted --------------------------------------
#
# Both halves matter, and each has its own way of failing. A quoted '-ForUser' is
# a positional STRING, not a parameter name; an unquoted profile path splits at
# the space. Measured 2026-09-01 -- docs/measurements.md.

Assert-Equal "'install'" (Format-ChildArguments @('install')) 'a plain value is quoted'
Assert-Equal '-AddToPath' (Format-ChildArguments @('-AddToPath')) 'a flag is not'
Assert-Equal "-ForUser 'HOME\First Last'" (Format-ChildArguments @('-ForUser', 'HOME\First Last')) `
    'a space in an account name survives'
Assert-Equal "-ForUser 'HOME\O''Brien'" (Format-ChildArguments @('-ForUser', "HOME\O'Brien")) `
    "an apostrophe is doubled, or it would end the string early"

# ---- and the result actually BINDS -------------------------------------------
#
# The assertions above are about text. This one runs the text, because the whole
# point is what the child's param() does with it -- and the two obvious shapes
# both produce plausible text that does not bind.

$tmp = Join-Path $env:TEMP 'trigger-kvm-elevation'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$child = Join-Path $tmp 'child.ps1'
@'
[CmdletBinding()]
param([Parameter(Position=0)][string]$Command = 'install',
      [switch]$AddToPath, [string]$ForUser = '', [string]$ForAppData = '')
"$Command|$AddToPath|$ForUser|$ForAppData"
'@ | Set-Content -LiteralPath $child -Encoding ASCII

$sample = @('install', '-AddToPath', '-ForUser', "HOME\O'Brien Smith",
          '-ForAppData', 'C:\Users\O''Brien Smith\AppData\Local')
$got = Invoke-Expression ("& '{0}' {1}" -f $child, (Format-ChildArguments $sample))
Assert-Equal "install|True|HOME\O'Brien Smith|C:\Users\O'Brien Smith\AppData\Local" $got `
    'every argument reaches the child as the value the parent held'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

# ---- the identity travels on EVERY relaunch, whatever the caller asked for ----
#
# Not the caller's job to remember. Request-Elevation appends it, so a relaunch
# site added later cannot forget it -- which is how this was wrong to begin with.
#
# -NoElevate is the branch that prints the command instead of running it, so this
# exercises the real function and starts no process.

$global:Relaunched = $false
$global:NoElevate  = $true
$global:FORUSER    = 'HOME\First Last'
$global:APPDATA    = 'C:\Users\First Last\AppData\Local'

Reset-Printed
function Write-Host { param($Object, [switch]$NoNewline) Add-Printed -Object $Object -NoNewline:$NoNewline }
$rc = Request-Elevation -ChildArgs @('install')
$said = Get-Printed

Assert-Equal 1 $rc 'declining to elevate is a failure, not a silent success'
Assert-Match $said "-ForUser 'HOME\\First Last'"                        'the child is told who it is installing for'
Assert-Match $said "-ForAppData 'C:\\Users\\First Last\\AppData\\Local'" 'and where that user keeps their files'
Assert-Match $said "'install'"                                          'and what the caller asked for'

# The printed line is meant to be PASTED, so it has to be runnable as it stands.
Assert-Match $said "(?m)^Run this from an elevated PowerShell:  & '" 'a bare path with a space in it would not be'

exit 0
