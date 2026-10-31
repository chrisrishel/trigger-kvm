# The two menus every list question is made of (specs/configure.md 3), the
# prompts underneath them, and the name rule both computers and monitors follow.
#
# In both menus ENTER DOES WHAT THE HIGHLIGHTED ROW SAYS, so a multi-select has
# no accept key -- it has a Done row you move to. Both fall back to typed input
# when the host cannot read individual keys (specs/configure.md 3.5), which is
# how the suite drives the whole flow.

# What a question returns when the person pressed esc rather than answering.
#
# THREE outcomes, not two: a panel's questions are a submenu, so "backed out"
# and "no, do not manage this monitor" must stay distinct or esc silently
# unmanages a panel. Read-InputValue validates a typed value as a hex byte and
# every table value is one, so this can never collide with an answer.
$BACK = 'back'

# specs/configure.md 5.1. One name per computer and per monitor: it is a config
# value, an argument you type, and a label in every prompt, so it has to be
# typeable without quoting.
$NAME_RULE = 'Lowercase letters, digits and dashes.'

# --- asking -------------------------------------------------------------------

# Can questions be asked at all? Narrower than Test-CanReadKeys, which only
# decides menu STYLE.
#
# A redirected stdin is a script of answers, not an absence of input --
# specs/configure.md 3.5 exists so a piped answer stream can drive the flow end
# to end. $Relaunched is the elevated child: hidden window, output to a
# transcript, so a prompt there blocks something nobody can see.
function Test-CanPrompt {
    if ($Relaunched) { return $false }
    if ([Console]::IsInputRedirected) { return $true }
    return [Environment]::UserInteractive
}

# THE ONE PLACE A LINE OF ANSWER IS READ, and deliberately not Read-Host:
# Windows PowerShell 5.1's Read-Host reads the CONSOLE, not standard input, so a
# piped answer never reaches it (docs/measurements.md).
#
# [Console]::In.ReadLine() returns $null at end of input -- a third state,
# distinct from an answer and from a blank, which is the distinction
# specs/configure.md 3.5 turns on. Nothing peeks: Peek() blocks on a real
# console.
function Read-Line {
    param([string]$Prompt)

    if (-not [Console]::IsInputRedirected) { return (Read-Host $Prompt) }

    Write-Host ("{0}: " -f $Prompt) -NoNewline
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) {
        Write-Host ''
        Write-Host ''
        Write-Host 'ran out of input. configure needs a terminal, or a complete script of answers.'
        exit 1
    }
    # Echoed, so a scripted run's transcript reads like the session it stands in for.
    Write-Host $line
    return $line
}

# A blank answer keeps the default -- specs/configure.md 5.0, and every prompt
# in this walkthrough behaves that way.
function Read-Default {
    param([string]$Prompt, [string]$Default)
    $shown = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    $answer = Read-Line $shown
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $a = (Read-Line "$Prompt [$hint]").Trim().ToLower()
        if (-not $a) { return $Default }
        if ($a -in @('y', 'yes')) { return $true }
        if ($a -in @('n', 'no'))  { return $false }
    }
}

# --- drawing ------------------------------------------------------------------

function Test-CanReadKeys {
    if ([Console]::IsInputRedirected) { return $false }
    try { $null = [Console]::KeyAvailable } catch { return $false }
    return $true
}

# The one place a key is read. A function because [Console]::ReadKey is a static
# and cannot be stubbed, and the alternative is shipping the interactive half of
# the walkthrough unexercised.
function Read-MenuKey {
    return [Console]::ReadKey($true).Key
}

# Capped at 110 so a menu does not sprawl across a wide window. Clear-ToLineEnd
# depends on this cap; see there.
function Get-MenuWidth {
    $w = 100
    try { if ([Console]::WindowWidth -gt 1) { $w = [Math]::Max(1, [Math]::Min(110, [Console]::WindowWidth - 1)) } } catch { }
    return $w
}

# Visible dimensions, not scrollback buffer height. Query at every redraw and
# again after a key: a resize while ReadKey waits must precede key handling.
function Get-MenuGeometry {
    $width = Get-MenuWidth
    $columns = $width
    $height = 25
    $buffer = $columns
    $native = $false
    try {
        if ([Console]::WindowWidth -gt 0 -and [Console]::WindowHeight -gt 0) {
            $columns = [Console]::WindowWidth
            $height = [Console]::WindowHeight
            $buffer = [Console]::BufferWidth
            $native = $true
        }
    } catch { }
    return [pscustomobject]@{ Width=$width; Columns=$columns; Height=$height; Buffer=$buffer; Native=$native }
}

function Get-MenuCells {
    param([string]$Text)
    # PowerShell 5.1 can report one cell for a CJK character that conhost draws
    # in two. Bound code units beyond Latin-1 conservatively, then explicitly fold
    # before painting. Each emitted physical line fits even on those hosts.
    $bound = 0
    foreach ($character in $Text.ToCharArray()) { $bound += $(if ([int]$character -gt 255) { 2 } else { 1 }) }
    try { return [Math]::Max($bound, $Host.UI.RawUI.LengthInBufferCells($Text)) } catch { return $bound }
}

# Explicit physical folds also cover a console whose buffer is wider than its
# window. Text elements stay intact, including surrogate pairs/combining marks.
function Split-MenuLine {
    param([string]$Text, [int]$Columns)
    foreach ($part in ($Text -split "`r?`n")) {
        if ((Get-MenuCells $part) -le $Columns) { $part; continue }
        $elements = [Globalization.StringInfo]::GetTextElementEnumerator($part)
        $line = ''; $cells = 0
        while ($elements.MoveNext()) {
            $element = $elements.GetTextElement()
            $size = Get-MenuCells $element
            if ($line -and $cells + $size -gt $Columns) { $line; $line = ''; $cells = 0 }
            $line += $element
            $cells += $size
        }
        if ($line) { $line }
    }
}

function Get-MenuRows {
    param([string[]]$Lines, [int]$Columns)
    $count = 0
    foreach ($line in $Lines) { $count += @(Split-MenuLine -Text $line -Columns $Columns).Count }
    return $count
}

# Entries retain their original positions, including disabled rows/separators.
# Only complete entries fit in the body. Controls and a cursor row are reserved
# before selecting the window; any oversized entry uses the numbered transcript.
function Get-MenuViewport {
    param([object[]]$Entries, [string[]]$Controls, [int]$Selected, [int]$First, $Geometry)
    $heights = @($Entries | ForEach-Object { Get-MenuRows -Lines $_.Lines -Columns $Geometry.Columns })
    $body = $Geometry.Height - 1 - (Get-MenuRows -Lines $Controls -Columns $Geometry.Columns)
    $overflow = ($heights | Measure-Object -Sum).Sum -gt $body
    if ($overflow) {
        $indicator = '  Entries {0}-{0} of {0}' -f $Entries.Count
        $body -= Get-MenuRows -Lines @($indicator) -Columns $Geometry.Columns
    }
    $view = [pscustomobject]@{ Fits=$false; Lines=@(); Heights=$heights; Body=$body; First=0; Last=($Entries.Count-1) }
    if ($Geometry.Columns -lt 2 -or $body -lt 1 -or @($heights | Where-Object { $_ -gt $body }).Count) { return $view }
    # A single text element cannot be split without corrupting its characters.
    # If even that element exceeds the safe width, keep it in the transcript.
    foreach ($line in (@($Entries | ForEach-Object { $_.Lines }) + @($Controls))) {
        foreach ($part in @(Split-MenuLine -Text $line -Columns $Geometry.Columns)) {
            if ((Get-MenuCells $part) -gt $Geometry.Columns) { return $view }
        }
    }
    $start = 0; $end = $Entries.Count - 1
    if ($overflow) {
        $start = [Math]::Max(0, [Math]::Min($First, $Selected))
        $used = 0
        for ($i = $start; $i -le $Selected; $i++) { $used += $heights[$i] }
        while ($used -gt $body) { $used -= $heights[$start]; $start++ }
        $end = $Selected
        while ($end + 1 -lt $Entries.Count -and $used + $heights[$end+1] -le $body) { $end++; $used += $heights[$end] }
        if ($end -eq $Entries.Count - 1) {
            while ($start -gt 0 -and $used + $heights[$start-1] -le $body) { $start--; $used += $heights[$start] }
        }
    }
    $lines = @()
    for ($i = $start; $i -le $end; $i++) { $lines += $Entries[$i].Lines }
    if ($overflow) { $lines += '  Entries {0}-{1} of {2}' -f ($start+1),($end+1),$Entries.Count }
    $view.Fits = $true
    $view.Lines = @($lines) + @($Controls)
    $view.First = $start; $view.Last = $end
    return $view
}

function Test-MenuResize {
    param($Previous, $Geometry)
    return ($null -eq $Previous -or $Previous.Columns -ne $Geometry.Columns -or
        $Previous.Height -ne $Geometry.Height -or $Previous.Buffer -ne $Geometry.Buffer)
}

# Erase the owned frame directly rather than rewinding an old height through a
# smaller window. Buffer cells do not scroll; the next frame starts in view.
function Reset-MenuViewport {
    param($State, $Geometry)
    if ($State.Rows -le 0) { return }
    try {
        $oldRows = Get-MenuRows -Lines $State.Lines -Columns $Geometry.Buffer
        $top = [Math]::Max(0, [Math]::Min($State.Top, [Console]::CursorTop - $oldRows))
        $bottom = [Math]::Min([Console]::BufferHeight-1, [Math]::Max($State.Top+$State.Rows-1, [Console]::CursorTop))
        $rect = New-Object Management.Automation.Host.Rectangle 0,$top,([Console]::BufferWidth-1),$bottom
        $cell = New-Object Management.Automation.Host.BufferCell (' ', $Host.UI.RawUI.ForegroundColor,
            $Host.UI.RawUI.BackgroundColor, [Management.Automation.Host.BufferCellType]::Complete)
        $Host.UI.RawUI.SetBufferContents($rect, $cell)
        [Console]::SetCursorPosition(0, [Math]::Max($top, [Console]::WindowTop))
    } catch { }
    $State.Rows = 0
}

function Write-MenuViewport {
    param($View, $Geometry, $State)
    if (Test-MenuResize -Previous $State.Geometry -Geometry $Geometry) { Reset-MenuViewport -State $State -Geometry $Geometry }
    $lines = @($View.Lines)
    if ($Geometry.Native) {
        $lines = @(foreach ($line in $lines) { Split-MenuLine -Text $line -Columns $Geometry.Columns })
        try { [Console]::SetWindowPosition(0, [Console]::WindowTop) } catch { }
    }
    $State.Rows = Write-MenuFrame -Lines $lines -Width $Geometry.Width -Previous $State.Rows
    $State.Lines = $lines
    $State.Geometry = $Geometry
    try {
        $State.Top = [Math]::Max(0, [Console]::CursorTop - $State.Rows)
        if ($State.Top -lt [Console]::WindowTop -or [Console]::CursorTop -ge [Console]::WindowTop + $Geometry.Height) {
            [Console]::SetWindowPosition(0, [Math]::Min($State.Top, [Console]::BufferHeight - $Geometry.Height))
        }
    } catch { }
}

# Page distance is physical rows, including intervening unselectable entries.
# Unlike arrows it clamps at the ends. Return an index into the selectable list.
function Get-MenuPage {
    param([int[]]$Selectable, [int]$At, [int[]]$Heights, [int]$Body, [int]$Direction)
    $start = $Selectable[$At]
    $target = $start; $distance = 0
    for ($i = $start + $Direction; $i -ge 0 -and $i -lt $Heights.Count; $i += $Direction) {
        $distance += $Heights[$(if ($Direction -gt 0) { $i-1 } else { $i })]
        if ($Selectable -contains $i) {
            $target = $i
            if ($distance -ge $Body) { break }
        }
    }
    return [array]::IndexOf($Selectable, $target)
}

# Repaint a block in place, returning THE NUMBER OF LINES ACTUALLY DRAWN, which
# the next call passes back as -Previous. Counting what was drawn rather than
# inferring it from the inputs is the whole contract: an inferred height is one
# line out the moment a caller changes the block's shape.
#
# A line of exactly BufferWidth characters occupies ONE row: conhost delays the
# wrap until the next character (measured; windows/AGENTS.md).
function Write-MenuFrame {
    param([string[]]$Lines, [int]$Width, [int]$Previous = 0)

    if ($Previous -gt 0) {
        try { [Console]::SetCursorPosition(0, [Math]::Max(0, [Console]::CursorTop - $Previous)) } catch { }
    }

    # The real row width, which is NOT the menu's: the previous frame is still
    # sitting in every column past Get-MenuWidth's cap.
    $cols = $Width
    try { if ([Console]::BufferWidth -gt 0) { $cols = [Console]::BufferWidth } } catch { }
    $cols = [Math]::Max(1, $cols)

    # Callers wrap their own long content (Split-Detail). Nothing is truncated
    # here -- specs/configure.md 3.1. A still-over-long line wraps in the
    # terminal and is counted, so the frame height stays honest.
    $n = 0
    foreach ($l in $Lines) {
        $t = "$l"
        $cells = $t.Length
        try { $cells = $Host.UI.RawUI.LengthInBufferCells($t) } catch { }
        $rows = [Math]::Max(1, [Math]::Ceiling($cells / [double]$cols))
        # Clear BEFORE writing, including each folded row and its last column.
        # Clearing after a full-width write cannot distinguish the final cell
        # from the clamped cursor position (windows/AGENTS.md).
        Clear-ToLineEnd -Rows $rows
        Write-Host $t -NoNewline
        Write-Host ''
        $n += $rows
    }
    # A shorter replacement must erase the old frame's tail, then leave the
    # cursor just after the new frame, which is what -Previous measures.
    for ($i = $n; $i -lt $Previous; $i++) {
        Clear-ToLineEnd
        Write-Host ''
    }
    if ($Previous -gt $n) {
        try { [Console]::SetCursorPosition(0, [Math]::Max(0, [Console]::CursorTop - ($Previous - $n))) } catch { }
    }
    return $n
}

# Erase from the cursor to the end of its line -- ERASING, NOT PADDING, which is
# what specs/configure.md 3.1 asks for. Padding measures a string where a line's
# end is a column, and pads to the menu's capped width rather than the window's.
#
# RawUI fills cells without moving the cursor or wrapping. This clears the last
# column too, and needs no VT mode on a Windows PowerShell 5.1 console.
function Clear-ToLineEnd {
    param([int]$Rows = 1)
    try {
        $left = [Console]::CursorLeft
        $top = [Console]::CursorTop
        $right = [Console]::BufferWidth - 1
        $bottom = [Math]::Min([Console]::BufferHeight - 1, $top + $Rows - 1)
        $rect = New-Object Management.Automation.Host.Rectangle $left,$top,$right,$bottom
        $cell = New-Object Management.Automation.Host.BufferCell (' ', $Host.UI.RawUI.ForegroundColor,
            $Host.UI.RawUI.BackgroundColor, [Management.Automation.Host.BufferCellType]::Complete)
        $Host.UI.RawUI.SetBufferContents($rect, $cell)
    } catch { }
}

# A row's detail, wrapped to the width left for it, broken at the ", " between
# items so a line never ends mid-identifier -- specs/configure.md 3.1. An
# unbreakable single item overruns rather than being cut: the review screen
# exists to let someone confirm what is about to be written, and an ellipsis
# hides exactly what they came to check.
function Split-Detail {
    param([string]$Text, [int]$Width)

    if (-not $Text) { return @('') }
    if ($Width -lt 12) { return @($Text) }          # too narrow to wrap usefully

    $out = @()
    $line = ''
    foreach ($part in ($Text -split '(?<=, )')) {
        if ($line -and ($line.Length + $part.Length) -gt $Width) { $out += $line.TrimEnd(); $line = '' }
        $line += $part
    }
    if ($line) { $out += $line.TrimEnd() }
    return @($out)
}

# The item column: 28, or the longest item + 1, capped at 44
# (specs/configure.md 3.1). The +1 keeps two spaces before the longest item's
# detail, so it reads as a column rather than a word break.
function Get-ItemWidth {
    param([string[]]$Items)
    $w = 28
    foreach ($it in $Items) { if ($it -and ($it.Length + 1) -gt $w) { $w = $it.Length + 1 } }
    return [Math]::Min($w, 44)
}

# One row: the item in its column, its detail wrapped onto continuation lines
# aligned under that column. Returns one line or several.
#
# SHARED by both menus. The continuation indent comes from the marker, so a
# caller cannot get the two out of step.
function Get-MenuRow {
    param([string]$Item, [string]$Detail, [string]$Marker, [int]$ItemWidth, [int]$Width)

    $lead = $Marker.Length + 1
    if (-not $Detail) { return @(('{0} {1}' -f $Marker, $Item).TrimEnd()) }

    # @(...) around the call, not just inside it: PowerShell unrolls a
    # one-element array on return, and $chunks[0] on a bare string is its first
    # CHARACTER -- which renders as a menu of single letters.
    $chunks = @(Split-Detail -Text $Detail -Width ([Math]::Max(12, $Width - $lead - $ItemWidth - 1)))
    $out = @('{0} {1} {2}' -f $Marker, $Item.PadRight($ItemWidth), $chunks[0])
    foreach ($c in @($chunks | Select-Object -Skip 1)) {
        $out += '{0} {1} {2}' -f (' ' * $Marker.Length), (' ' * $ItemWidth), $c
    }
    return @($out)
}

# One choice from a list. Returns the index, or -1 for esc where it is offered.
function Select-One {
    param([string[]]$Items, [string[]]$Detail = @(), [int]$Default = 0, [string]$Help,
          # The row configured RIGHT NOW. Marked `(current)`, because the cursor
          # already means "where you are" and a re-run needs to distinguish an
          # unchanged default from a deliberate choice (specs/configure.md 3.2).
          [int]$Current = -1,
          # Shown, annotated, skipped by the cursor, unpickable. Hiding would
          # change the list's shape as you answer (specs/configure.md 3.2).
          [int[]]$Disabled = @(),
          # Esc returns -1, "back, and change nothing". Opt-in: it only means
          # something in a submenu you entered from somewhere.
          [switch]$Escapable,
          # Esc MOVES THE CURSOR here and does not activate it -- the top menu,
          # where the way out is a row. A setup cannot be discarded by one
          # keypress (specs/configure.md 3.3).
          [int]$EscapeTo = -1)

    # An empty item is a separator: drawn blank, skipped, unpickable.
    $sel = @()
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($Items[$i] -and -not ($Disabled -contains $i)) { $sel += $i }
    }
    if ($sel.Count -eq 0) { throw 'Select-One: nothing selectable' }
    if ($sel -notcontains $Default) { $Default = $sel[0] }

    $ITEMW = Get-ItemWidth -Items $Items

    function Build-Row {
        param([int]$Index, [int]$Width, [string]$Marker)
        $d = if ($Index -lt $Detail.Count) { "$($Detail[$Index])" } else { '' }
        if ($Index -eq $Current) { $d = ($d + '   (current)').TrimStart() }
        return (Get-MenuRow -Item $Items[$Index] -Detail $d -Marker $Marker `
                            -ItemWidth $ITEMW -Width $Width)
    }

    if (Test-CanReadKeys) {
        $at = [Math]::Max(0, $sel.IndexOf($Default))
        $first = 0; $key = $null
        $frame = [pscustomobject]@{ Rows=0; Top=0; Lines=@(); Geometry=$null }
        $controls = $(if ($Help) { @('') + @($Help -split "`r?`n") } else { @() }) + @('',
            $(if ($Escapable) { '  up/down move   enter choose   esc back' } else { '  up/down move   enter choose' }),
            '  home/end first/last   pgup/pgdn page')
        while ($true) {
            $geometry = Get-MenuGeometry
            $entries = @(for ($i = 0; $i -lt $Items.Count; $i++) {
                $row = if (-not $Items[$i]) { @('') } else {
                    @(Build-Row -Index $i -Width $geometry.Width -Marker $(
                        if ($Disabled -contains $i) { ' --' } elseif ($i -eq $sel[$at]) { '  >' } else { '   ' }))
                }
                [pscustomobject]@{ Lines=@($row) }
            })
            $view = Get-MenuViewport -Entries $entries -Controls $controls -Selected $sel[$at] -First $first -Geometry $geometry
            if (-not $view.Fits) {
                Reset-MenuViewport -State $frame -Geometry $geometry
                Write-Host '  The console is too small for an entry and its controls; using numbered input.'
                $Default = $sel[$at]
                break
            }
            $first = $view.First
            if ($null -eq $key -or (Test-MenuResize -Previous $frame.Geometry -Geometry $geometry)) {
                Write-MenuViewport -View $view -Geometry $geometry -State $frame
            }
            if ($null -eq $key) { $key = Read-MenuKey; continue }
            switch ($key) {
                'UpArrow'   { $at = ($at - 1 + $sel.Count) % $sel.Count }
                'DownArrow' { $at = ($at + 1) % $sel.Count }
                'Home'      { $at = 0 }
                'End'       { $at = $sel.Count - 1 }
                'PageUp'    { $at = Get-MenuPage -Selectable $sel -At $at -Heights $view.Heights -Body $view.Body -Direction -1 }
                'PageDown'  { $at = Get-MenuPage -Selectable $sel -At $at -Heights $view.Heights -Body $view.Body -Direction 1 }
                'Enter'     { Write-Host ''; return $sel[$at] }
                'Escape'    {
                    if ($Escapable) { Write-Host ''; return -1 }
                    $to = $sel.IndexOf($EscapeTo)
                    if ($to -ge 0) { $at = $to }
                }
            }
            $key = $null
        }
    }

    # The same fallback serves redirected input and an oversized viewport.
    # Default is the current highlight, not the menu's original starting row.
    & {
        for ($i = 0; $i -lt $Items.Count; $i++) {
            if (-not $Items[$i]) { Write-Host ''; continue }
            if ($Disabled -contains $i) {
                foreach ($l in (Build-Row -Index $i -Width 100 -Marker '   ')) {
                    Write-Host ('   -- {0}' -f $l.Substring(4))
                }
                continue
            }
            $first = $true
            foreach ($l in (Build-Row -Index $i -Width 100 -Marker '   ')) {
                if ($first) { Write-Host ('  {0,2}) {1}' -f ($i + 1), $l.Substring(4)) }
                else        { Write-Host ('      {0}' -f $l.Substring(4)) }
                $first = $false
            }
        }
        if ($Help) { Write-Host ''; Write-Host $Help }
        while ($true) {
            $pick = Read-Default '  Choice' ([string]($Default + 1))
            if ($Escapable -and $pick -eq 'q') { return -1 }
            # `q` is the typed analogue of MOVING THE CURSOR, not of pressing
            # the row: it makes the way out the default, so the next bare enter
            # takes it. Still two keystrokes.
            if ($EscapeTo -ge 0 -and $pick -eq 'q' -and $sel -contains $EscapeTo) {
                $Default = $EscapeTo
                continue
            }
            if ($pick -match '^[0-9]+$' -and $sel -contains ([int]$pick - 1)) { return ([int]$pick - 1) }
            Write-Host $(if ($Escapable) { '  Pick a number from the list, or q to go back.' }
                         else            { '  Pick a number from the list.' })
        }
    }

}

# Several choices. Enter toggles the highlighted row and the last row is the way
# out, so "how do I finish?" is answered by the list rather than by a hint line
# nobody reads (specs/configure.md 3.4). Space toggles too.
function Select-Many {
    param([string[]]$Items, [string[]]$Detail = @(), [int[]]$Checked = @(), [string]$Help,
          [string]$DoneLabel = 'Done',
          [int[]]$Disabled = @(),
          # Esc returns $null -- distinct from any list of indices, and from the
          # empty list this refuses to return.
          [switch]$Escapable)

    $state = @($Items | ForEach-Object { $false })
    foreach ($i in $Checked) { if ($i -ge 0 -and $i -lt $state.Count -and $Items[$i]) { $state[$i] = $true } }

    # 3.1's layout applies here too, and this is the menu where it matters most:
    # device names arrive from the system rather than being chosen, so a
    # concatenated row overflows, wraps, and the wrapped tail is not cleared.
    $ITEMW = Get-ItemWidth -Items $Items

    $done = $Items.Count
    $sel = @(for ($i = 0; $i -lt $done; $i++) { if ($Items[$i] -and $Disabled -notcontains $i) { $i } }) + @($done)
    if (Test-CanReadKeys) {
        $at = 0; $first = 0; $key = $null; $note = ''
        $frame = [pscustomobject]@{ Rows=0; Top=0; Lines=@(); Geometry=$null }
        $helpBody = if ($Help) { @('') + @($Help -split "`r?`n") } else { @() }
        while ($true) {
            $geometry = Get-MenuGeometry
            $cursor = $sel[$at]
            $entries = @(for ($i = 0; $i -lt $done; $i++) {
                $row = if (-not $Items[$i]) { @('') } else {
                    $marker = '{0} {1}' -f $(if ($Disabled -contains $i) { ' --' } elseif ($cursor -eq $i) { '  >' } else { '   ' }),
                        $(if ($state[$i]) { '[x]' } else { '[ ]' })
                    $detailText = if ($i -lt $Detail.Count) { $Detail[$i] } else { '' }
                    @(Get-MenuRow -Item $Items[$i] -Detail $detailText -Marker $marker -ItemWidth $ITEMW -Width $geometry.Width)
                }
                [pscustomobject]@{ Lines=@($row) }
            })
            $n = @($state | Where-Object { $_ }).Count
            $entries += [pscustomobject]@{ Lines=(@('') + @(Get-MenuRow -Item $DoneLabel -Marker ('{0}    ' -f $(if ($cursor -eq $done) { '  >' } else { '   ' })) `
                -Detail $(if ($n -gt 0) { "$n selected" } else { 'nothing selected' }) -ItemWidth $ITEMW -Width $geometry.Width)) }
            $controls = @($helpBody) + @('',
                $(if ($Escapable) { '  up/down move   enter toggles the highlighted row   esc back' } else { '  up/down move   enter toggles the highlighted row' }),
                '  home/end first/last   pgup/pgdn page', $note)
            $view = Get-MenuViewport -Entries $entries -Controls $controls -Selected $cursor -First $first -Geometry $geometry
            if (-not $view.Fits) {
                Reset-MenuViewport -State $frame -Geometry $geometry
                Write-Host '  The console is too small for an entry and its controls; using numbered input.'
                break
            }
            $first = $view.First
            if ($null -eq $key -or (Test-MenuResize -Previous $frame.Geometry -Geometry $geometry)) {
                Write-MenuViewport -View $view -Geometry $geometry -State $frame
            }
            if ($null -eq $key) { $key = Read-MenuKey; continue }
            $note = ''
            if ($key -eq 'Escape' -and $Escapable) { Write-Host ''; return $null }
            switch ($key) {
                'UpArrow'   { $at = ($at - 1 + $sel.Count) % $sel.Count }
                'DownArrow' { $at = ($at + 1) % $sel.Count }
                'Home'      { $at = 0 }
                'End'       { $at = $sel.Count - 1 }
                'PageUp'    { $at = Get-MenuPage -Selectable $sel -At $at -Heights $view.Heights -Body $view.Body -Direction -1 }
                'PageDown'  { $at = Get-MenuPage -Selectable $sel -At $at -Heights $view.Heights -Body $view.Body -Direction 1 }
                'Spacebar'  { if ($cursor -ne $done) { $state[$cursor] = -not $state[$cursor] } }
                'Enter'     {
                    if ($cursor -ne $done) { $state[$cursor] = -not $state[$cursor]; break }
                    $out = @(for ($i = 0; $i -lt $state.Count; $i++) { if ($state[$i]) { $i } })
                    if ($out.Count -gt 0) { Write-Host ''; return $out }
                    $note = '  Nothing is checked -- move to a row and press enter to check it.'
                }
            }
            $key = $null
        }
    }

    & {
        for ($i = 0; $i -lt $Items.Count; $i++) {
            if (-not $Items[$i]) { Write-Host ''; continue }
            $mark  = if ($state[$i]) { '*' } else { ' ' }
            $first = $true
            $detailText = if ($i -lt $Detail.Count) { $Detail[$i] } else { '' }
            foreach ($l in (Get-MenuRow -Item $Items[$i] -Detail $detailText -Marker '   [x]' `
                                        -ItemWidth $ITEMW -Width 100)) {
                if ($first -and $Disabled -contains $i) { Write-Host ('   -- {0}' -f $l.Substring(7)) }
                elseif ($first) { Write-Host ('  {0}{1,2}) {2}' -f $mark, ($i + 1), $l.Substring(7)) }
                else        { Write-Host ('       {0}' -f $l.Substring(7)) }
                $first = $false
            }
        }
        if ($Help) { Write-Host ''; Write-Host $Help }
        $pre = @()
        for ($i = 0; $i -lt $state.Count; $i++) { if ($state[$i]) { $pre += ($i + 1) } }
        while ($true) {
            $pick = Read-Default '  Numbers, comma-separated' ($pre -join ',')
            if ($Escapable -and $pick -eq 'q') { return $null }
            # Checked disabled rows are read-only state, not selectable inputs.
            $out = @($Disabled | Where-Object { $_ -ge 0 -and $_ -lt $state.Count -and $state[$_] })
            foreach ($n in ($pick -split ',')) {
                $n = $n.Trim()
                if ($n -match '^[0-9]+$' -and $sel -contains ([int]$n - 1) -and [int]$n -le $Items.Count -and $out -notcontains ([int]$n - 1)) { $out += ([int]$n - 1) }
            }
            if ($out.Count -gt 0) { return $out }
            Write-Host $(if ($Escapable) { '  Pick at least one, or q to go back.' }
                         else            { '  Pick at least one.' })
        }
    }

}

# --- names --------------------------------------------------------------------

# What a computer -- OR A MONITOR -- may be called. One function for both,
# because "a name someone types, in the character rule, unique among its peers"
# is one idea with two nouns (specs/configure.md 5.1, and 6 which points at it).
#
# Spaces, dots and underscores become dashes; anything else is dropped.
function Format-Name {
    param([string]$Raw)
    $n = "$Raw".Trim().ToLower()
    $n = $n -replace '[\s._]+', '-'
    $n = $n -replace '[^a-z0-9-]', ''
    $n = $n -replace '-{2,}', '-'
    return $n.Trim('-')
}

# Suggests rather than silently mangling: say what changed and let the person
# accept or retype. A blank answer keeps the default and never removes anything
# (specs/configure.md 5.0); removal is a row of its own.
function Read-Name {
    param([string]$Prompt, [string]$Default, [string[]]$Taken = @(),
          # 'computer' or 'monitor'. It picks the refusal, and both refusals are
          # normative wording, so the two are written out rather than composed.
          [string]$Noun = 'computer')

    while ($true) {
        $raw = Read-Default ('  ' + $Prompt) $Default
        if (-not $raw.Trim()) {
            Write-Host '  A name is needed here.'
            continue
        }
        $n = Format-Name $raw
        if (-not $n) {
            Write-Host ('  Nothing usable in that. {0}' -f $NAME_RULE)
            continue
        }
        if ($n -ne $raw.Trim().ToLower()) {
            Write-Host ('  Names are what you type at a prompt, so: {0}' -f $NAME_RULE)
            if (-not (Read-YesNo ("  Use '{0}'?" -f $n) $true)) { $Default = $n; continue }
        }
        if ($Taken -contains $n) {
            # Two panels with one label would be written as one and read back as
            # a merge of both; two computers with one name is the same shape.
            if ($Noun -eq 'monitor') { Write-Host ('  There is already a monitor called {0}.' -f $n) }
            else                     { Write-Host ('  There is already a computer called {0}.' -f $n) }
            continue
        }
        return $n
    }
}

# "LG, ASUS and DELL" rather than "LG and ASUS and DELL". These lines are read
# under mild pressure -- a monitor is about to go dark -- so they should not
# also be awkward.
function Join-Names {
    param([string[]]$Names)
    if ($Names.Count -le 1) { return ($Names -join '') }
    if ($Names.Count -eq 2) { return ($Names -join ' and ') }
    return (($Names[0..($Names.Count - 2)] -join ', ') + ' and ' + $Names[-1])
}
