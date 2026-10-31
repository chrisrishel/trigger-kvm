param([string]$Menu,[string]$Report)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. $Menu
$script:realFrame = ${function:Write-MenuFrame}
$script:realViewport = ${function:Write-MenuViewport}
$script:cases = 0
$script:frames = @(); $script:steps = @(); $script:answers = @()
$script:transcript = ''; $script:prompts = @()
function Require { param([bool]$Condition,[string]$Why) if (-not $Condition) { throw ('expected ' + $Why) } }
function Resize-Console {
    param([int]$Width,[int]$Height,[int]$Buffer = 0)
    if (-not $Buffer) { $Buffer = $Width }
    [Console]::SetWindowSize([Math]::Min($Width,[Console]::WindowWidth),[Math]::Min($Height,[Console]::WindowHeight))
    [Console]::SetBufferSize($Buffer,300)
    [Console]::SetWindowSize($Width,$Height)
}
function Start-Case {
    param([object[]]$Steps=@(),[string[]]$Answers=@(),[int]$Width=80,[int]$Height=12,[int]$Buffer=0)
    Resize-Console $Width $Height $Buffer
    [Console]::Clear()
    $script:steps = @($Steps); $script:answers = @($Answers)
    $script:frames = @(); $script:transcript = ''; $script:prompts = @()
}
function Step {
    param([string]$Key,[string]$Expect,[int]$Width=0,[int]$Height=0,[string[]]$Contains=@())
    [pscustomobject]@{Key=$Key;Expect=$Expect;Width=$Width;Height=$Height;Contains=$Contains}
}
function Finish-Case {
    Require ($script:steps.Count -eq 0 -and $script:answers.Count -eq 0) 'every scripted input consumed'
    $script:cases++
}
function Write-Host {
    param($Object,[switch]$NoNewline)
    $script:transcript += [string]$Object + $(if ($NoNewline) { '' } else { "`n" })
    Microsoft.PowerShell.Utility\Write-Host @PSBoundParameters
}
function Write-MenuFrame {
    param([string[]]$Lines,[int]$Width,[int]$Previous=0)
    Require ($Previous -lt [Console]::WindowHeight) 'redraw never rewinds beyond visible height'
    & $script:realFrame @PSBoundParameters
}
function Write-MenuViewport {
    param($View,$Geometry,$State)
    & $script:realViewport @PSBoundParameters
    Require ($State.Rows -lt [Console]::WindowHeight) 'frame reserves a visible cursor row'
    Require ([Console]::CursorTop - $State.Rows -ge [Console]::WindowTop) 'entire frame inside visible window'
    Require ([Console]::CursorTop -lt [Console]::WindowTop + [Console]::WindowHeight) 'cursor below frame remains visible'
    $rect = New-Object Management.Automation.Host.Rectangle ([Console]::WindowLeft),([Console]::WindowTop),([Console]::WindowLeft+[Console]::WindowWidth-1),([Console]::WindowTop+[Console]::WindowHeight-1)
    $cells = $Host.UI.RawUI.GetBufferContents($rect)
    $lines = @(for ($y=0; $y -lt $cells.GetLength(0); $y++) {
        -join @(for ($x=0; $x -lt $cells.GetLength(1); $x++) {
            if ($cells[$y,$x].BufferCellType -ne [Management.Automation.Host.BufferCellType]::Trailing) { $cells[$y,$x].Character }
        })
    })
    $highlight = @($lines | Where-Object { $_.Contains('  >') })
    Require ($highlight.Count -eq 1) ('exactly one visible highlight, with no stale highlighted row; count='+$highlight.Count+'; screen='+($lines -join '|'))
    $text = $lines -join "`n"
    Require ($text.Contains('up/down move')) 'key hint is visible'
    Require ($text.Contains('pgup/pgdn page')) 'page hint is visible'
    $tail = @($lines | Select-Object -Skip ([Console]::CursorTop - [Console]::WindowTop)) -join ''
    Require ([string]::IsNullOrWhiteSpace($tail)) 'folded/shrinking frame leaves no stale tail'
    $script:frames += [pscustomobject]@{Text=$text;Flat=($lines -join '');Highlight=$highlight[0];Width=[Console]::WindowWidth;Height=[Console]::WindowHeight;Rows=$State.Rows;Top=([Console]::CursorTop-$State.Rows)}
}
function Read-MenuKey {
    Require ($script:steps.Count -gt 0) 'bounded key sequence is not exhausted'
    $step = $script:steps[0]
    $script:steps = @($script:steps | Select-Object -Skip 1)
    $frame = $script:frames[-1]
    Require ($frame.Highlight.Contains($step.Expect)) ('highlight '+$step.Expect+'; saw '+$frame.Highlight)
    foreach ($part in $step.Contains) { Require ($frame.Flat.Contains($part)) ('complete visible text: '+$part) }
    if ($step.Width) { Resize-Console $step.Width $step.Height; $script:resizeTop = [Console]::WindowTop }
    return [ConsoleKey]::$($step.Key)
}
function Read-Line {
    param([string]$Prompt)
    $script:prompts += $Prompt
    Require ($script:answers.Count -gt 0) 'bounded numbered input is not exhausted'
    $answer = $script:answers[0]
    $script:answers = @($script:answers | Select-Object -Skip 1)
    return $answer
}
try {
    $items = @(0..29 | ForEach-Object { 'row{0:d2}' -f $_ })
    Start-Case -Steps @(Step Enter row00 -Contains 'Entries 1-7 of 30')
    Require ((Select-One -Items $items) -eq 0) 'initial row zero returned'
    Finish-Case

    Start-Case -Steps @((Step PageDown row00),(Step PageDown row07),(Step PageUp row14),(Step End row07),
        (Step PageDown row29),(Step DownArrow row29),(Step UpArrow row00),(Step Home row29),(Step PageUp row00),(Step Enter row00))
    Require ((Select-One -Items $items) -eq 0) 'arrows wrap, pages clamp and Home/End reach endpoints'
    Finish-Case

    $shaped = $items.Clone(); $shaped[1]=''; $shaped[8]=''
    Start-Case -Steps @((Step PageDown row02 -Contains ' -- row00'),(Step PageUp row10 -Contains @(' -- row09','Entries 5-11 of 30')),
        (Step Home row03),(Step End row02),(Step Enter row28))
    Require ((Select-One -Items $shaped -Disabled @(0,9,29)) -eq 28) 'pages count separators and skip disabled rows'
    Finish-Case

    Start-Case -Steps @((Step PageDown row00),(Step Spacebar row06),(Step End row06),
        (Step PageUp Done -Contains '2 selected'),(Step Home row24),(Step Spacebar row00),(Step End row00),(Step Enter Done -Contains '1 selected'))
    Require (((Select-Many -Items $items -Checked @(0)) -join ',') -eq '6') 'scrolling and Done preserve checks'
    Finish-Case

    Start-Case -Steps @((Step Enter a -Contains ' -- [x] locked'),(Step DownArrow a),(Step Spacebar b),
        (Step UpArrow b),(Step End a),(Step Enter Done -Contains '3 selected'))
    Require (((Select-Many -Items @('a','','locked','b') -Disabled @(2) -Checked @(2)) -join ',') -eq '0,2,3') 'multi-select skips separator/disabled rows and retains read-only checks'
    Finish-Case

    $details = @(0..29 | ForEach-Object { 'first-{0:d2}-abcdefghijklmnop, second-{0:d2}-abcdefghijklmnop' -f $_ })
    Start-Case -Steps @((Step PageDown row00 -Contains @('first-00-abcdefghijklmnop','second-00-abcdefghijklmnop')),
        (Step PageUp row04 -Contains @('first-04-abcdefghijklmnop','second-04-abcdefghijklmnop')),(Step Enter row00))
    Require ((Select-One -Items $items -Detail $details) -eq 0) 'wrapped physical rows determine page distance'
    Finish-Case

    $identifier = 'ID'+('abcdefgh'*18)+'END'
    foreach ($many in @($false,$true)) {
        Start-Case -Buffer 120 -Steps $(if ($many) { @((Step End row00 -Contains $identifier),(Step Enter Done)) } else { @(Step Enter row00 -Contains $identifier) })
        $answer = if ($many) { Select-Many -Items $items -Detail @($identifier) -Checked @(0) } else { Select-One -Items $items -Detail @($identifier) }
        Require (($answer -join ',') -eq '0') 'unbreakable identifier survives a wider scrollback buffer'
        Finish-Case
    }

    $unicode = 'START'+(('id-'+[char]0x6771+[char]0x00e9)*18)+'FINISH'
    Start-Case -Steps @(Step Enter row00 -Contains 'FINISH')
    Require ((Select-One -Items $items -Detail @($unicode)) -eq 0) 'wide Unicode detail is preserved across physical rows'
    # Native RawUI duplicates wide characters as two Complete cells on 5.1.
    # Check exact characters at Write-Host, and the visible final token in the
    # buffer; frame/selection bounds above still inspect actual console cells.
    Require ($script:transcript.Replace("`n",'').Contains($unicode)) 'all Unicode text elements reach the real host unchanged'
    Finish-Case

    Start-Case -Steps @((Step DownArrow row20 -Width 55 -Height 10),(Step UpArrow row21 -Width 80 -Height 16),(Step Enter row20))
    Require ((Select-One -Items $items -Default 20) -eq 20) 'resizing retains the selection'
    $reflow = @($script:frames | Where-Object { $_.Width -eq 55 })[0]
    Require ($reflow.Highlight.Contains('row20')) 'resize reflows before processing the first key'
    Finish-Case

    Start-Case -Steps @((Step End row00),(Step Home Done -Width 55 -Height 12),(Step Spacebar row00),(Step End row00),(Step Enter Done -Contains '1 selected'))
    Require (((Select-Many -Items $items -Checked @(0,8)) -join ',') -eq '8') 'multi-select resize preserves checks and Done'
    Finish-Case

    Start-Case -Steps @((Step End row00),(Step Enter Done),(Step Spacebar Done -Contains 'Nothing is checked'),
        (Step Home Done),(Step Spacebar row00),(Step End row00),(Step Enter Done -Contains '1 selected'))
    Require (((Select-Many -Items $items) -join ',') -eq '0') 'Done refuses empty state and Space on Done never accepts'
    Finish-Case

    Start-Case -Width 24 -Height 6 -Answers @('')
    Require ((Select-One -Items $items -Detail @($identifier) -Default 5) -eq 5) 'initial numbered fallback retains default'
    Require ($script:transcript.Contains('console is too small') -and $script:transcript.Contains($identifier)) 'fallback explains size and preserves complete text'
    Finish-Case

    Start-Case -Steps @((Step PageDown row00),(Step DownArrow row07 -Width 24 -Height 6)) -Answers @('')
    Require ((Select-One -Items $items) -eq 7) 'fallback keeps the current highlight before an invisible key action'
    Require ($script:prompts[-1].Contains('[8]')) 'numbered default follows the highlighted entry'
    Finish-Case

    Start-Case -Steps @(Step DownArrow row00 -Width 24 -Height 6) -Answers @('q','')
    Require ((Select-One -Items $items -EscapeTo 29) -eq 29) 'fallback q moves to Cancel and still requires Enter'
    Finish-Case

    Start-Case -Steps @(Step DownArrow row00 -Width 24 -Height 6) -Answers @('q')
    Require ((Select-One -Items $items -Escapable) -eq -1) 'fallback submenu q remains Escape'
    Finish-Case

    foreach ($cancel in @($false,$true)) {
        Start-Case -Steps @((Step DownArrow row00),(Step Spacebar row01),(Step DownArrow row01 -Width 24 -Height 6)) -Answers @($(if ($cancel) {'q'} else {''}))
        $checked = @(0)
        $answer = Select-Many -Items $items -Checked $checked -Escapable
        if ($cancel) { Require ($null -eq $answer) 'multi-select fallback q cancels' }
        else { Require (($answer -join ',') -eq '0,1') 'multi-select fallback preserves in-progress checks' }
        Require (($checked -join ',') -eq '0') 'caller selection array is never mutated'
        Finish-Case
    }

    Start-Case -Width 24 -Height 6 -Answers @('2,3','1,4')
    Require (((Select-Many -Items @('a','','locked','b') -Disabled @(2)) -join ',') -eq '0,3') 'numbered fallback cannot select disabled or separator rows'
    Finish-Case

    Start-Case -Steps @((Step End row00),(Step Escape row29))
    Require ((Select-One -Items $items -Escapable) -eq -1) 'interactive Escape preserves its return value after scrolling'
    Finish-Case

    $help = 'HELP'+('h'*90)+'TAIL'
    Start-Case -Steps @((Step PageDown row00 -Contains @('Entries 1-4 of 30','TAIL')),(Step Enter row04))
    Require ((Select-One -Items $items -Help $help) -eq 4) 'wrapped help is reserved before page navigation'
    Finish-Case

    Start-Case -Height 14 -Steps @((Step PageDown row00 -Contains @('Entries 1-5 of 31','TAIL')),(Step End row05),(Step Enter Done))
    Require (((Select-Many -Items $items -Checked @(0) -Help $help) -join ',') -eq '0') 'multi-select reserves wrapped help and Done'
    Finish-Case

    $cluster = 'e'+(([string][char]0x301)*80)
    Start-Case -Answers @('')
    Require ((Select-One -Items $items -Detail @($cluster)) -eq 0) 'an indivisible oversized text element uses the transcript'
    Require ($script:transcript.Contains($cluster)) 'oversized text element remains intact in fallback'
    Finish-Case

    Start-Case -Steps @((Step DownArrow row00 -Width 80 -Height 8),(Step Enter row01))
    Require ((Select-One -Items $items) -eq 1) 'height-only resize is re-queried'
    $shortFrame = @($script:frames | Where-Object { $_.Height -eq 8 })[0]
    Require ($shortFrame.Top -eq $script:resizeTop) 'resize erases and reuses the visible frame instead of appending'
    Finish-Case

    $huge = 'UNBROKEN'+('x'*1000)+'TAIL'
    $oversized = @('')*30; $oversized[29] = $huge
    Start-Case -Answers @('')
    Require ((Select-One -Items $items -Detail $oversized -Default 5) -eq 5) 'an oversized offscreen entry selects numbered fallback before navigation'
    Require ($script:transcript.Contains($huge)) 'oversized offscreen detail remains accessible'
    Finish-Case

    Start-Case -Steps @((Step PageDown row00),(Step End row03),(Step Enter Done))
    Require (((Select-Many -Items $items -Detail $details -Checked @(0)) -join ',') -eq '0') 'multi-select pages count wrapped details'
    Finish-Case

    $longDone = 'Done-'+('D'*90)
    Start-Case -Steps @((Step End row00),(Step Enter Done- -Contains '1 selected'))
    Require (((Select-Many -Items $items -Checked @(0) -DoneLabel $longDone) -join ',') -eq '0') 'wrapped Done stays completely visible and selectable'
    Require ($script:transcript.Replace("`n",'').Contains($longDone)) 'Done text is never truncated'
    Finish-Case

    Start-Case -Steps @(Step Escape row00 -Width 24 -Height 6)
    Require ((Select-One -Items $items -Escapable) -eq -1) 'Escape at the resize boundary still returns to the parent'
    Finish-Case

    Start-Case -Steps @(Step Escape row00 -Width 24 -Height 6) -Answers @('')
    Require ((Select-One -Items $items -EscapeTo 29) -eq 29) 'Escape at the resize boundary moves the numbered default to Cancel'
    Finish-Case

    Start-Case -Steps @((Step Spacebar row00),(Step Escape row00 -Width 24 -Height 6))
    Require ($null -eq (Select-Many -Items $items -Escapable)) 'multi-select Escape at the resize boundary cancels in-progress checks'
    Finish-Case

    @{Ok=$true;Cases=$script:cases} | ConvertTo-Json | Set-Content -LiteralPath $Report -Encoding UTF8
} catch {
    @{Ok=$false;Cases=$script:cases;Error="$_";Frames=$script:frames} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Report -Encoding UTF8
    exit 1
}
