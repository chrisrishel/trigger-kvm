# The menu primitives: the cursor, the Done button, separators, and wrapping.
#
# The key-driven half is only reachable because Read-MenuKey exists as a function --
# [Console]::ReadKey is a static and cannot be stubbed, and the alternative was
# shipping the interactive half of the walkthrough unexercised.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

Import-Subject -Script 'lib\menu.ps1' -Functions @(
    'Read-Default','Read-YesNo','Get-MenuWidth','Write-MenuFrame','Clear-ToLineEnd',
    'Split-Detail','Get-ItemWidth','Get-MenuRow',
    'Select-One','Select-Many','Join-Names')

$script:keys = @()
function Read-MenuKey {
    if ($script:keys.Count -eq 0) { throw 'ran out of scripted keys' }
    $k = $script:keys[0]
    $script:keys = @($script:keys | Select-Object -Skip 1)
    return $k
}
# Which half of the menus a case drives. A VARIABLE rather than a second
# definition of the function: PowerShell runs the last one defined, so two of
# them leave a reader unable to say which is live where -- which is exactly what
# conventions.tests.ps1 forbids, and it caught this.
$script:canReadKeys = $true
function Test-CanReadKeys { $script:canReadKeys }
function Set-Keys { param([string[]]$K) $script:keys = @($K) }

# Capture what a menu drew, so layout can be asserted rather than eyeballed.
function Write-Host { param([Parameter(ValueFromPipeline=$true)]$Object, [switch]$NoNewline)
    Add-Printed -Object $Object -NoNewline:$NoNewline
}
function Get-Drawn { return (Get-Printed) }
function Reset-Drawn { Reset-Printed }

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
Assert-Match (Get-Drawn) 'Done\s+1 selected' 'the count sits in the detail column, as every other menu does'
Assert-NoMatch (Get-Drawn) '\[ Done' 'and it is a plain row, like every other menu''s Done'

# ---- a multi-select obeys the SAME layout rules as every other menu ----------
#
# specs/configure.md 3.4, and 3.1 for the rules themselves. This used to
# concatenate the item and its detail. That is fine until the content is long, and
# Bluetooth device names are: reported from a real 80-column terminal, the trigger
# list overflowed, wrapped, and the redraw corrupted -- stale text from the
# previous frame showing at the right edge, and the help block repeating down the
# screen.

# The menu redraws once per keypress and every frame lands in the capture, so the
# assertions below read the LAST frame -- the one a person would be looking at.
function Get-LastFrame {
    param([int]$Rows)
    return @((Get-Drawn) -split "`n" | Select-Object -Last $Rows)
}

# The item column, so the details line up as a column rather than running on.
Reset-Drawn; Set-Keys @('DownArrow','DownArrow','DownArrow','Enter')
$null = Select-Many -Items @('usb:046d:0843','bt:0011223344ff','usb:1235:820a') `
                    -Detail @('USB   Logitech Webcam C930e',
                              'BT    AirPods Pro  (paired, not connected)',
                              'USB   Clarett+ 2Pre') -Checked @(0)
$rows = @((Get-Drawn) -split "`n" | Where-Object { $_ -match '\[[ x]\]' } | Select-Object -Last 3)
Assert-Equal 3 $rows.Count 'three device rows'
$cols = @($rows | ForEach-Object { [Math]::Max($_.IndexOf('USB   '), $_.IndexOf('BT    ')) } | Sort-Object -Unique)
Assert-Equal 1 $cols.Count "every detail starts in the same column, got columns $($cols -join ',')"
Assert-True ($cols[0] -gt 0) 'and that column is a real one'

# Long details WRAP at the ", " between items, on to lines aligned under the item
# column -- and are never truncated.
$long = 'Logitech Inc Wireless Receiver, a very long product description, and more of it, and yet more of it'
Reset-Drawn; Set-Keys @('DownArrow','Enter')
$null = Select-Many -Items @('usb:046d:0843') -Detail @($long) -Checked @(0)
$drawn = (Get-Drawn)
foreach ($piece in ($long -split ', ')) {
    Assert-Match $drawn ([regex]::Escape($piece)) "$piece must survive wrapping, never be cut"
}
Assert-NoMatch $drawn '\.\.\.' 'nothing is truncated'

$tail = @($drawn -split "`n" | Where-Object { $_ -match 'and yet more of it' } | Select-Object -Last 1)[0]
Assert-NoMatch $tail 'usb:046d:0843' 'the detail wrapped rather than running on one line'
Assert-Match $tail '^\s{8,}\S' 'and the continuation is indented under the item column'

# Nothing the menu writes may exceed the width. A longer line wraps; a wrapped
# line's tail is not cleared by the next frame, so the previous frame shows
# through; and a line landing exactly on the fold occupies two rows while a naive
# count says one. Both were reported from a real 80-column terminal.
$w = Get-MenuWidth
foreach ($l in ($drawn -split "`n")) {
    Assert-True ($l.Length -le $w) ("a menu line overran the width ({0} > {1}): {2}" -f $l.Length, $w, $l)
}

# ---- the frame's height, which is what stops a redraw stacking ---------------
#
# Write-MenuFrame returns how many ROWS it drew, and the next call winds the cursor
# back by exactly that. One row out and every frame creeps down the screen.
#
# The count changed with the erase, and the reason is not the one first written
# down here. A full-width line costs ONE row only because Clear-ToLineEnd stops a
# column SHORT of the buffer -- writing into the last column wraps. Filling to the
# full width made an exactly-full line report one row and cost two, and the next
# redraw then wound back one row too few and left the hint line duplicated under
# the menu. That shipped, and was reported from a real terminal.
#
# THIS FILE CANNOT SEE THAT. There is no console in the harness, so
# Clear-ToLineEnd is a no-op and $cols falls back to $Width. What it holds down is
# the arithmetic; the console half was settled by sweeping widths 60..120 against
# line lengths around each fold in a real console, reported vs actual.

# ERASED, NOT PADDED. specs/configure.md 3.1. PadRight had two faults: it padded
# to the MENU's width, which is capped at 110, so on a wider window the previous
# frame survived in every column past that; and it measured the STRING, where a
# line's end is a column.
#
# What this file can assert is the visible half -- the text goes to the host
# unpadded, and the fill comes from Clear-ToLineEnd, which is a no-op here because
# there is no console to ask. The other half was settled by measuring the console
# directly rather than by a unit test: a full-width write plus a newline advances
# exactly one row, and Write-Host and [Console]::CursorLeft agree on where the
# cursor is.
Reset-Drawn
$null = Write-MenuFrame -Lines @('short', '') -Width 40
Assert-Equal "short`n" (Get-Drawn) 'the frame must hand the host its text, not its text padded to the width'

Reset-Drawn
Assert-Equal 1 (Write-MenuFrame -Lines @('short') -Width 40) 'a short line is one row'
Reset-Drawn
Assert-Equal 1 (Write-MenuFrame -Lines @('') -Width 40) 'so is a blank one'
Reset-Drawn
Assert-Equal 1 (Write-MenuFrame -Lines @(('x' * 40)) -Width 40) `
    'a line of exactly the width is ONE row -- nothing is written into the last column'
Reset-Drawn
Assert-Equal 2 (Write-MenuFrame -Lines @(('x' * 41)) -Width 40) 'one past it folds'
Reset-Drawn
Assert-Equal 5 (Write-MenuFrame -Lines @('a','b','','d','e') -Width 40) 'and it counts every line'

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

# ---- esc: back where it means something, the way out where it does not -------

# specs/configure.md 3.3. Esc always means "take me to the way out" -- but what the
# way out IS depends on the menu, and it is never "discard everything on one
# keypress".

Set-Keys @('Escape')
Assert-Equal -1 (Select-One -Items @('a','b') -Default 0 -Escapable) `
    'in a submenu, esc returns -1: back, changing nothing'

# The top menu has no -1 to return to. Its way out is a ROW, so esc moves the
# cursor onto it -- and stops there. It used to do nothing at all, which reads as a
# dead key on the one menu people press esc on hardest.
Set-Keys @('Escape','Enter')
Assert-Equal 3 (Select-One -Items @('Computers','Monitors','Save','Cancel') -Default 0 -EscapeTo 3) `
    'esc moves the cursor to Cancel'

# THE MOVE MUST NOT BE A PRESS. This is the whole property: a setup still cannot be
# discarded by a stray keypress, because you have to press enter on the row.
Set-Keys @('Escape','UpArrow','Enter')
Assert-Equal 2 (Select-One -Items @('Computers','Monitors','Save','Cancel') -Default 0 -EscapeTo 3) `
    'esc must not activate the row it moves to -- it can still be moved off'

# Without -EscapeTo, and not escapable, esc is inert rather than an exit.
Set-Keys @('Escape','Enter')
Assert-Equal 0 (Select-One -Items @('a','b') -Default 0) `
    'esc on a question that must be answered does nothing'

# A row the cursor cannot land on is not somewhere to send it.
Set-Keys @('Escape','Enter')
Assert-Equal 0 (Select-One -Items @('a','b','c') -Default 0 -EscapeTo 1 -Disabled @(1)) `
    'esc cannot move the cursor onto a disabled row'

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

# ---- rows that are shown but cannot be chosen --------------------------------

# An input already assigned to another computer. Hiding it would make the list change
# shape as you answer; renaming it would lose the only label the monitor's own menu
# agrees with. So it stays where it was, says who has it, and is skipped.
Reset-Drawn; Set-Keys @('DownArrow','Enter')
$got = Select-One -Items @('HDMI 1','HDMI 2','DisplayPort') `
                  -Detail @('0x11   assigned to pc','0x12','0x0F') -Default 1 -Disabled @(0)
Assert-Equal 2 $got 'the cursor moved from row 2 to row 3'

Reset-Drawn; Set-Keys @('UpArrow','Enter')
$got = Select-One -Items @('HDMI 1','HDMI 2','DisplayPort') `
                  -Detail @('0x11   assigned to pc','0x12','0x0F') -Default 1 -Disabled @(0)
Assert-Equal 2 $got 'and up from row 2 wraps PAST the disabled row, never onto it'
Assert-Match (Get-Drawn) 'HDMI 1' 'a disabled row is still drawn'
Assert-Match (Get-Drawn) 'assigned to pc' 'and still says who has it'

# ---- a long item still gets a gap before its detail --------------------------

# Fixed at 28, "Yes, but it did not change back to pc" ran straight into its detail
# and the row read as one sentence instead of a choice and its consequence.
Reset-Drawn; Set-Keys @('Enter')
$null = Select-One -Default 0 `
    -Items  @('Yes, and it changed back to pc', 'Yes, but it did not change back to pc', 'No') `
    -Detail @('everything works', 'the input for pc is wrong', '')
Assert-Match (Get-Drawn) 'back to pc\s\s+everything works' 'the column widens to the longest item'
Assert-Match (Get-Drawn) 'change back to pc\s\s+the input for pc is wrong' `
    'even the longest item keeps two spaces -- one reads as a word break'

# ---- esc goes back, where back has a meaning ---------------------------------

# Opt-in, because it is only unambiguous in a submenu you entered from somewhere. On
# a menu without it, Escape must do nothing at all rather than fall through to some
# other row.
Set-Keys @('Escape','Enter')
Assert-Equal 0 (Select-One -Items @('a','b') -Default 0) 'Escape is inert without -Escapable'

Set-Keys @('Escape')
Assert-Equal -1 (Select-One -Items @('a','b') -Default 0 -Escapable) 'and returns -1 with it'

Reset-Drawn; Set-Keys @('Escape')
$null = Select-One -Items @('a','b') -Default 0 -Escapable
Assert-Match (Get-Drawn) 'esc back' 'the hint says so, since nothing else would'

Reset-Drawn; Set-Keys @('Enter')
$null = Select-One -Items @('a','b') -Default 0
Assert-NoMatch (Get-Drawn) 'esc back' 'and does not, where it would be a lie'

# Select-Many returns $null, which is distinct both from a list of indices and from
# the empty list it refuses to return.
Set-Keys @('Escape')
$got = Select-Many -Items @('a','b') -Detail @('one','two') -Checked @(0) -Escapable
Assert-True ($null -eq $got) 'Escape backs out of a multi-select without choosing'

Set-Keys @('Escape','DownArrow','DownArrow','Enter')
$got = Select-Many -Items @('a','b') -Detail @('one','two') -Checked @(0)
Assert-Equal '0' ($got -join ',') 'and is inert there too without the switch'

# ---- the typed fallback: `q` is its esc, wherever esc is offered -------------
#
# specs/configure.md 3.5. "`q` is the fallback's esc, and only where esc is
# offered" -- and esc IS offered on the top menu, where it moves the cursor to
# Cancel. Without this a scripted or redirected-stdin run had no way to express
# it, and that run is what each platform's suite drives `configure` with. The
# README claimed it worked; it printed "Pick a number from the list."
#
# Everything above drives the KEY path. From here down, the typed one.
$script:canReadKeys = $false

Reset-Drawn; Set-Answers @('q')
Assert-Equal -1 (Select-One -Items @('a','b') -Default 0 -Escapable) 'q is esc in a submenu'

Reset-Drawn; Set-Answers @('q', '')
Assert-Equal 3 (Select-One -Items @('Computers','Monitors','Save','Cancel') -Default 0 -EscapeTo 3) `
    'on the top menu it makes Cancel the default, and the next bare enter takes it'
Assert-NoMatch (Get-Drawn) 'Pick a number from the list' 'so it is an answer, not a refusal'

# AND IT IS STILL NOT ONE KEYPRESS. The enter is a separate answer, and moving
# off Cancel before pressing it still works -- which is the property that keeps a
# setup from being discarded by a stray key.
Reset-Drawn; Set-Answers @('q', '3')
Assert-Equal 2 (Select-One -Items @('Computers','Monitors','Save','Cancel') -Default 0 -EscapeTo 3) `
    'q moves the default; it does not choose'

# A question that must be answered has no way out at all, so q is refused there.
Reset-Drawn; Set-Answers @('q', '1')
Assert-Equal 0 (Select-One -Items @('a','b') -Default 0)
Assert-Match (Get-Drawn) 'Pick a number from the list\.' 'q means nothing where esc means nothing'

# ...and it does not move the cursor onto a row the cursor cannot land on.
Reset-Drawn; Set-Answers @('q', '1')
Assert-Equal 0 (Select-One -Items @('a','b','c') -Default 0 -EscapeTo 1 -Disabled @(1))
Assert-Match (Get-Drawn) 'Pick a number from the list\.' 'a disabled way out is no way out'

$script:canReadKeys = $true

# ---- Join-Names --------------------------------------------------------------

Assert-Equal 'LG'                (Join-Names @('LG'))
Assert-Equal 'LG and ASUS'       (Join-Names @('LG','ASUS'))
Assert-Equal 'LG, ASUS and DELL' (Join-Names @('LG','ASUS','DELL')) 'no "and" between every pair'

exit 0
