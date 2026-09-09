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

Import-Subject -Script 'lib\host.ps1' -Functions @(
    'Format-ChildArguments', 'Get-ChildArguments', 'Request-Elevation', 'Invoke-BootTierElevation')

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

# ---- what the child is given is built from what this process was given -------
#
# It used to be a literal list at each call site, so nothing checked it against
# the parameters install.ps1 declares -- and one site passed `-Tier`, which has
# never been a parameter, so the documented recovery from an admin-owned task
# died at parameter binding in a hidden window while the parent reported that
# the task had been left exactly as it was.
#
# Built from $PSBoundParameters, a flag is forwarded by EXISTING. Three names
# are excluded, and the middle one is the one that matters.

$global:FORUSER = 'HOME\First Last'
$global:APPDATA = 'C:\Users\First Last\AppData\Local'

$bound = @{ Command = 'configure'; Fresh = [switch]$true; NoElevate = [switch]$false
            AddToPath = [switch]$true; Relaunched = [switch]$true
            ForUser = 'somebody-else'; ForAppData = 'C:\wrong' }
$args1 = @(Get-ChildArguments -Verb 'install' -Bound $bound)

Assert-Equal 'install' $args1[0] 'the verb the caller asked for comes first'
Assert-True ($args1 -contains '-Fresh') 'a switch that was given is forwarded'
Assert-True (-not ($args1 -contains '-NoElevate')) 'one that was not is not'
Assert-True (-not ($args1 -contains '-Command')) 'and the old verb is replaced, not carried'

# ONLY A PROCESS RUNNING AS A USER MAY EDIT THAT USER'S PATH. In an elevated
# child on a standard account HKCU is the ADMIN's hive, so a child asked to do
# it would edit the wrong person's PATH and report success.
Assert-True (-not ($args1 -contains '-AddToPath')) `
    'the PATH edit is never delegated to the elevated child'

# -Relaunched is the caller's to add, on the command line it builds; forwarding
# it here would make the child think it had already tried.
Assert-True (-not ($args1 -contains '-Relaunched')) 'and -Relaunched is not forwarded'

# The identity is recomputed from the parent's answers, never passed through.
$i = [array]::IndexOf($args1, '-ForUser')
Assert-True ($i -ge 0) 'the child is told who it is installing for'
Assert-Equal 'HOME\First Last' $args1[$i + 1] 'and it is the PARENT''s answer, not the caller''s'
Assert-True (-not ($args1 -contains 'somebody-else')) 'a stale value is not carried through'

# Every flag it forwards must be a parameter install.ps1 declares, or the child
# dies at binding in a hidden window.
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
           (Join-Path $WinDir 'install.ps1'), [ref]$null, [ref]$errs)
$declared = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
foreach ($a in $args1) {
    if ($a -notmatch '^-\w') { continue }
    Assert-True ($declared -contains $a.TrimStart('-')) `
        ("{0} is handed to the child and is not a parameter of install.ps1" -f $a)
}

# ---- the identity travels on EVERY relaunch, whatever the caller asked for ----
#
# -NoElevate is the branch that prints the command instead of running it, so
# this exercises the real function and starts no process.

$global:Relaunched   = $false
$global:NoElevate    = $true
$global:INVOKED_WITH = @{ Command = 'install' }

Reset-Printed
function Write-Host { param($Object, [switch]$NoNewline) Add-Printed -Object $Object -NoNewline:$NoNewline }
$rc = Request-Elevation -Verb 'install'
$said = Get-Printed

Assert-Equal 1 $rc 'declining to elevate is a failure, not a silent success'
Assert-Match $said "-ForUser 'HOME\\First Last'"                        'the child is told who it is installing for'
Assert-Match $said "-ForAppData 'C:\\Users\\First Last\\AppData\\Local'" 'and where that user keeps their files'
Assert-Match $said "'install'"                                          'and what the caller asked for'

# The printed line is meant to be PASTED, so it has to be runnable as it stands.
Assert-Match $said "(?m)^Run this from an elevated PowerShell:  & '" 'a bare path with a space in it would not be'

# AND IT NAMES THE PROGRAM. $PSCommandPath inside a function defined in lib\ is
# that lib file, so this line -- and the relaunch built the same way -- would
# hand somebody a library with no param() block: it runs, does nothing, exits 0.
# install.ps1 resolves $TK_SELF once, for both.
Assert-Match $said "[\\/]install\.ps1' " 'and the path it names is install.ps1, not the file the function lives in'

# ---- elevation that does not come falls back, and says so --------------------
#
# specs/configure.md 8. Declining the prompt used to exit 1 with the old watcher
# still running against the OLD trigger devices and a message claiming nothing
# had been changed -- when the config had been rewritten a moment earlier.
# Silently keeping `boot` is how someone finds out months later that switching
# does nothing until they log in.

$script:written = @()
function Set-ConfigValue { param([string]$Path, [string]$Key, [string]$Value)
    $script:written += ('{0}={1}' -f $Key, $Value)
}
function Set-InstalledPath { throw 'the PATH is the parent''s, and only after the child came back clean' }
function Request-Elevation { param([string]$Verb) return $script:elevationResult }
# lib.ps1's Write-Log swallows its argument unless TK_TEST_VERBOSE is set, and
# what this case is about is what the person is TOLD.
function Write-Log { param([string]$m) Add-Printed -Object "install: $m" }

$global:CONFIG = 'C:\fake\config'

Reset-Printed
$script:elevationResult = 1
$tier = Invoke-BootTierElevation

Assert-Equal 'user' $tier 'a refusal installs the tier that needs no elevation'
Assert-Match (Get-Printed) 'falling back to starting at login' 'and says so, in those words'

# THIS ASSERTION IS THE OPPOSITE OF WHAT IT WAS, changed deliberately.
#
# It required this function to write install.autostart = login, and
# specs/configure.md 8 says the other thing: "Record the fallback only once it
# has taken effect. A downgrade written before the install that applies it has
# succeeded leaves the config disagreeing with what is registered." Nothing has
# taken effect here -- this only decides which tier to attempt, and the install
# can still fail at Register-ScheduledTask, which returns 1 with the old boot
# task still registered and the config now saying login.
#
# Invoke-Install writes it after Register-ScheduledTask returns, which is the
# first moment the claim is true. The old assertion pinned the bug.
Assert-Equal '' ($script:written -join ',') `
    'deciding to fall back records nothing; installing the fallback records it'

exit 0
