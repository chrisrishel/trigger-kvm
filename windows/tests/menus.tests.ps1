# The menu primitives: the cursor, the Done button, separators, and wrapping.
#
# The key-driven half is only reachable because Read-MenuKey exists as a function --
# [Console]::ReadKey is a static and cannot be stubbed, and the alternative was
# shipping the interactive half of the walkthrough unexercised.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

Import-Subject -Script 'install.ps1' -Functions @(
    'Read-Default','Read-YesNo','Get-MenuWidth','Write-MenuFrame','Split-Detail',
    'Select-One','Select-Many','Join-Names')

$script:keys = @()
function Read-MenuKey {
    if ($script:keys.Count -eq 0) { throw 'ran out of scripted keys' }
    $k = $script:keys[0]
    $script:keys = @($script:keys | Select-Object -Skip 1)
    return $k
}
function Test-CanReadKeys { $true }     # these tests drive the key path
function Set-Keys { param([string[]]$K) $script:keys = @($K) }

# Capture what a menu drew, so layout can be asserted rather than eyeballed.
$script:drawn = @()
function Write-Host { param([Parameter(ValueFromPipeline=$true)]$Object) $script:drawn += "$Object" }
function Get-Drawn { return ($script:drawn -join "`n") }
function Reset-Drawn { $script:drawn = @() }

# ---- Select-Many: enter toggles, the Done button accepts ---------------------

Reset-Drawn; Set-Keys @('DownArrow','Enter','DownArrow','DownArrow','Enter')
$got = Select-Many -Items @('a','b','c') -Detail @('one','two','three')
Assert-Equal '1' ($got -join ',') 'enter on row 2 checks it, then Done accepts'

Reset-Drawn; Set-Keys @('UpArrow','Enter','DownArrow','Enter','DownArrow','DownArrow','Enter')
$got = Select-Many -Items @('a','b') -Detail @('one','two')
Assert-Equal '0' ($got -join ',') 'Done with nothing checked must refuse, not accept'
Assert-Match (Get-Drawn) 'Nothing is checked' 'and must say why'

Reset-Drawn; Set-Keys @('Spacebar','DownArrow','DownArrow','Enter')
$got = Select-Many -Items @('a','b') -Detail @('one','two') -Checked @(0,1)
Assert-Equal '1' ($got -join ',') 'pre-checked rows survive, and space still toggles'

Reset-Drawn; Set-Keys @('DownArrow','DownArrow','Enter')
$null = Select-Many -Items @('a','b') -Detail @('one','two') -Checked @(0)
Assert-Match (Get-Drawn) '\[ Done -- use the 1 checked \]' 'the button carries a live count'

# ---- Select-One: default, wrap, separators -----------------------------------

Set-Keys @('Enter')
Assert-Equal 2 (Select-One -Items @('a','b','Save','Cancel') -Default 2) 'starts on the default row'

Set-Keys @('UpArrow','Enter')
Assert-Equal 1 (Select-One -Items @('a','b','Save','Cancel') -Default 2) 'up moves one row'

Set-Keys @('DownArrow','DownArrow','Enter')
Assert-Equal 1 (Select-One -Items @('a','b','c') -Default 2) 'down past the end wraps to the top'

Set-Keys @('DownArrow','Enter')
Assert-Equal 0 (Select-One -Items @('a','b','','Save','Cancel') -Default 4) 'wraps PAST a separator'

Set-Keys @('UpArrow','Enter')
Assert-Equal 1 (Select-One -Items @('a','b','','Save','Cancel') -Default 3) 'up skips a separator'

Set-Keys @('Enter')
Assert-Equal 0 (Select-One -Items @('a','','Save') -Default 1) 'a Default on a separator falls to a real row'

# ---- (current) marks what is configured, wherever the cursor is --------------

Reset-Drawn; Set-Keys @('DownArrow','Enter')
$got = Select-One -Items @('DisplayPort','USB-C','HDMI 1') -Detail @('0xD0','0xD1','0x90') -Default 0 -Current 0
Assert-Equal 1 $got
Assert-Match (Get-Drawn) '0xD0\s+\(current\)' 'the configured row is marked, not just pre-selected'

# ---- nothing is ever truncated ----------------------------------------------

# Write-MenuFrame used to cut long lines with Substring, which on the review screen
# hid the very values it exists to let someone check.
$devices = @('usb:046d:0843','usb:1235:820a','usb:046d:c547','bt:0011223344ff',
             'bt:0011223344fc','usb:0b05:1a52')
$chunks = @(Split-Detail -Text ($devices -join ', ') -Width 67)
Assert-True ($chunks.Count -ge 2) 'a long list has to wrap'
foreach ($d in $devices) {
    Assert-Match ($chunks -join '') ([regex]::Escape($d)) "$d must survive wrapping"
}
foreach ($c in $chunks) { Assert-True ($c.Length -le 70) 'each wrapped line stays near the column width' }

Reset-Drawn; Set-Keys @('DownArrow','Enter')
$got = Select-One -Items @('Trigger devices','Save') -Detail @(($devices -join ', '), '') -Default 0
Assert-Equal 1 $got 'a wrapped row is ONE cursor stop, not one per line'

# A single item with no ", " to break at is the case Split-Detail deliberately lets
# overrun -- and therefore the only case where re-adding a Substring in
# Write-MenuFrame would cut something. Wrapping a comma list is not enough on its own
# to notice that regression, which is how it slipped past this file once already.
$huge = 'C:\Users\somebody\AppData\Local\Programs\trigger-kvm\bin\a-very-long-single-path-with-no-commas'
Reset-Drawn; Set-Keys @('Enter')
$null = Select-One -Items @('PATH','Save') -Detail @($huge, '') -Default 0
Assert-Match (Get-Drawn) ([regex]::Escape($huge)) 'an unbreakable item must overrun, never be cut'

# ---- Join-Names --------------------------------------------------------------

Assert-Equal 'LG'                (Join-Names @('LG'))
Assert-Equal 'LG and ASUS'       (Join-Names @('LG','ASUS'))
Assert-Equal 'LG, ASUS and DELL' (Join-Names @('LG','ASUS','DELL')) 'no "and" between every pair'

exit 0
