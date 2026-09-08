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
    try { $w = [Math]::Max(40, [Math]::Min(110, [Console]::WindowWidth - 1)) } catch { }
    return $w
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
    try { $cols = [Console]::BufferWidth } catch { }

    # Callers wrap their own long content (Split-Detail). Nothing is truncated
    # here -- specs/configure.md 3.1. A still-over-long line wraps in the
    # terminal and is counted, so the frame height stays honest.
    $n = 0
    foreach ($l in $Lines) {
        $t = "$l"
        Write-Host $t -NoNewline
        Clear-ToLineEnd
        Write-Host ''
        $n += [Math]::Max(1, [Math]::Ceiling($t.Length / [double]$cols))
    }
    return $n
}

# Erase from the cursor to the end of its line -- ERASING, NOT PADDING, which is
# what specs/configure.md 3.1 asks for. Padding measures a string where a line's
# end is a column, and pads to the menu's capped width rather than the window's.
#
# IT STOPS ONE COLUMN SHORT, AND MUST. Writing into the last column wraps, which
# costs a row the height count knows nothing about, and [Console]::CursorLeft
# clamps at BufferWidth-1 so an exactly-full line is indistinguishable from one
# a column short (windows/AGENTS.md). Only an already-over-long line could have
# put anything in that last column, and 3.1 forbids one.
#
# Not ESC[K: that needs VT processing, which is not on in every console
# PowerShell 5.1 runs in, and where it is off the escape prints as garbage.
function Clear-ToLineEnd {
    try {
        $left = [Console]::CursorLeft
        $end  = [Console]::BufferWidth - 1
        if ($left -lt $end) { Write-Host (' ' * ($end - $left)) -NoNewline }
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

    if (-not (Test-CanReadKeys)) {
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

    $width    = Get-MenuWidth
    $helpBody = if ($Help) { @('') + @($Help -split "`r?`n") } else { @() }
    # The cursor moves over SELECTABLE rows, not drawn ones, so a separator can
    # never be landed on and a multi-line row is one stop.
    $at    = [Math]::Max(0, $sel.IndexOf($Default))
    $drawn = 0

    while ($true) {
        $lines = @()
        for ($i = 0; $i -lt $Items.Count; $i++) {
            if (-not $Items[$i]) { $lines += ''; continue }
            if ($Disabled -contains $i) { $lines += Build-Row -Index $i -Width $width -Marker '  -'; continue }
            $lines += Build-Row -Index $i -Width $width -Marker $(if ($i -eq $sel[$at]) { '  >' } else { '   ' })
        }
        $lines += $helpBody
        $lines += ''
        $lines += $(if ($Escapable) { '  up/down move   enter choose   esc back' }
                    else            { '  up/down move   enter choose' })
        $drawn = Write-MenuFrame -Lines $lines -Width $width -Previous $drawn

        switch (Read-MenuKey) {
            'UpArrow'   { $at = ($at - 1 + $sel.Count) % $sel.Count }
            'DownArrow' { $at = ($at + 1) % $sel.Count }
            'Enter'     { Write-Host ''; return $sel[$at] }
            'Escape'    {
                if ($Escapable) { Write-Host ''; return -1 }
                $to = $sel.IndexOf($EscapeTo)
                if ($to -ge 0) { $at = $to }
            }
        }
    }
}

# Several choices. Enter toggles the highlighted row and the last row is the way
# out, so "how do I finish?" is answered by the list rather than by a hint line
# nobody reads (specs/configure.md 3.4). Space toggles too.
function Select-Many {
    param([string[]]$Items, [string[]]$Detail, [int[]]$Checked = @(), [string]$Help,
          [string]$DoneLabel = 'Done',
          # Esc returns $null -- distinct from any list of indices, and from the
          # empty list this refuses to return.
          [switch]$Escapable)

    $state = @($Items | ForEach-Object { $false })
    foreach ($i in $Checked) { if ($i -ge 0 -and $i -lt $state.Count) { $state[$i] = $true } }

    # 3.1's layout applies here too, and this is the menu where it matters most:
    # device names arrive from the system rather than being chosen, so a
    # concatenated row overflows, wraps, and the wrapped tail is not cleared.
    $ITEMW = Get-ItemWidth -Items $Items

    if (-not (Test-CanReadKeys)) {
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $mark  = if ($state[$i]) { '*' } else { ' ' }
            $first = $true
            foreach ($l in (Get-MenuRow -Item $Items[$i] -Detail $Detail[$i] -Marker '   [x]' `
                                        -ItemWidth $ITEMW -Width 100)) {
                if ($first) { Write-Host ('  {0}{1,2}) {2}' -f $mark, ($i + 1), $l.Substring(7)) }
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
            $out = @()
            foreach ($n in ($pick -split ',')) {
                $n = $n.Trim()
                if ($n -match '^[0-9]+$' -and [int]$n -ge 1 -and [int]$n -le $Items.Count) { $out += ([int]$n - 1) }
            }
            if ($out.Count -gt 0) { return $out }
            Write-Host $(if ($Escapable) { '  Pick at least one, or q to go back.' }
                         else            { '  Pick at least one.' })
        }
    }

    $width    = Get-MenuWidth
    $helpBody = if ($Help) { @('') + @($Help -split "`r?`n") } else { @() }
    $done     = $Items.Count          # the index of the Done row
    $cursor   = 0
    $note     = ''
    $drawn    = 0

    while ($true) {
        $lines = @()
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $marker = '{0} {1}' -f $(if ($i -eq $cursor) { '  >' } else { '   ' }),
                                   $(if ($state[$i]) { '[x]' } else { '[ ]' })
            $lines += Get-MenuRow -Item $Items[$i] -Detail $Detail[$i] -Marker $marker `
                                  -ItemWidth $ITEMW -Width $width
        }
        # A plain row aligned with the item text, its live count in the detail
        # column where every other menu puts a value. A marker as wide as
        # "  > [x]" and no wider, so Done lines up with the items rather than
        # with the checkboxes.
        $n = @($state | Where-Object { $_ }).Count
        $lines += ''
        $lines += Get-MenuRow -Item $DoneLabel -Marker ('{0}    ' -f $(if ($cursor -eq $done) { '  >' } else { '   ' })) `
                              -Detail $(if ($n -gt 0) { "$n selected" } else { 'nothing selected' }) `
                              -ItemWidth $ITEMW -Width $width
        $lines += $helpBody
        $lines += ''
        $lines += $(if ($Escapable) { '  up/down move   enter toggles the highlighted row   esc back' }
                    else            { '  up/down move   enter toggles the highlighted row' })
        $lines += $note
        $drawn = Write-MenuFrame -Lines $lines -Width $width -Previous $drawn

        $key  = Read-MenuKey
        $note = ''
        if ($key -eq 'Escape' -and $Escapable) { Write-Host ''; return $null }
        switch ($key) {
            'UpArrow'   { $cursor = ($cursor - 1 + $done + 1) % ($done + 1) }
            'DownArrow' { $cursor = ($cursor + 1) % ($done + 1) }
            'Spacebar'  { if ($cursor -ne $done) { $state[$cursor] = -not $state[$cursor] } }
            'Enter'     {
                if ($cursor -ne $done) { $state[$cursor] = -not $state[$cursor]; break }
                $out = @()
                for ($i = 0; $i -lt $state.Count; $i++) { if ($state[$i]) { $out += $i } }
                if ($out.Count -gt 0) { Write-Host ''; return $out }
                $note = '  Nothing is checked -- move to a row and press enter to check it.'
            }
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
