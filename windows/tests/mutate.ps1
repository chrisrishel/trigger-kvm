<#
.SYNOPSIS
Reintroduce each bug the suite is supposed to catch, and check that it does.

.DESCRIPTION
    .\mutate.ps1              every mutation
    .\mutate.ps1 config       only mutations whose name matches
    .\mutate.ps1 -RestoreOnly put back anything an interrupted run left mutated

A passing test proves nothing until it can fail. Each entry below reintroduces
a bug -- most of them bugs this project has actually shipped -- and asserts that
some test goes red. A SURVIVING mutation is a failure of this script: it means
an assertion passes for a reason other than the one it claims.

A mutation is only judged against a suite file that PASSES UNMUTATED. Each suite
is run once, clean, before its first mutation; if it is red already, every
mutation aimed at it is reported UNJUDGED and counted as survived, because "the
suite went red" then proves nothing.

NOT run by run.ps1. It edits files in place, so it is something you run
deliberately. It restores every file it touches, including when a suite wedges
or the run is interrupted -- and it restores leftovers before starting, because
a mutated source left behind silently becomes what the next test run measures.
#>
[CmdletBinding()]
param([string]$Filter = '', [switch]$RestoreOnly)

$ErrorActionPreference = 'Stop'
$WinDir = Split-Path -Parent $PSScriptRoot

$script:Checked  = 0
$script:Survived = 0
$script:Unjudged = 0
$script:Green    = @{}     # suite file -> $true/$false, measured once

# A run killed outright cannot clean up after itself, and a mutated source left
# in the tree is what the next test run then measures. That has cost an hour
# before now, so: restore anything left over first, and say so.
foreach ($bak in @(Get-ChildItem -LiteralPath $WinDir -Filter '*.mutbak' -File -Recurse -ErrorAction SilentlyContinue)) {
    $orig = $bak.FullName -replace '\.mutbak$', ''
    Write-Host ("  restoring {0}, left mutated by an interrupted run" -f (Split-Path -Leaf $orig))
    Move-Item -LiteralPath $bak.FullName -Destination $orig -Force
}
if ($RestoreOnly) { exit 0 }

# One suite file, in its own process, bounded. A mutant can HANG rather than
# fail -- a prompt at EOF that re-asks forever is the shape -- and an unbounded
# run would turn a caught mutation into a wedged terminal.
#
# [Diagnostics.Process] rather than Start-Process, and that is not a style
# choice: `Start-Process -PassThru` WITHOUT -Wait hands back a process object
# whose ExitCode never populates -- measured here, it reads as empty after
# WaitForExit returns true, so every suite looked red and every mutation came
# back UNJUDGED. -Wait would populate it and has no timeout.
function Invoke-Suite {
    param([string]$Suite, [int]$TimeoutSeconds = 300)

    $out = Join-Path $env:TEMP 'trigger-kvm-mutate.out'
    $err = "$out.err"
    foreach ($f in @($out, $err)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName               = 'powershell.exe'
    $psi.Arguments              = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $PSScriptRoot $Suite)
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $p = [Diagnostics.Process]::Start($psi)
    # Read both streams asynchronously. A suite that fills a 4KB pipe buffer
    # while nobody is reading it BLOCKS, which would look exactly like a hang.
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill() } catch { }
        return [pscustomobject]@{ Ok = $false; Why = "timed out after ${TimeoutSeconds}s" }
    }
    $text = "$($so.Result)`n$($se.Result)"
    Set-Content -LiteralPath $out -Value $text -Encoding ASCII

    $why = @($text -split "`r?`n" | Where-Object { $_ -match 'expected |does not match |matches /' }) |
           Select-Object -First 1
    return [pscustomobject]@{ Ok = ($p.ExitCode -eq 0); Why = "$why".Trim() }
}

function Test-SuiteGreen {
    param([string]$Suite)
    if (-not $script:Green.ContainsKey($Suite)) {
        $script:Green[$Suite] = (Invoke-Suite -Suite $Suite).Ok
    }
    return $script:Green[$Suite]
}

# One mutation.
#
# -Find is a LITERAL substring, not a regex and not a patch. A regex would have
# to be escaped twice over -- once for PowerShell, once for the pattern --
# against source that is itself full of $, ` and \, and every version of this
# that took one silently failed to apply somewhere and reported the mutation
# caught. A literal that does not appear is an ERROR here, loudly.
#
# Newlines are normalised to LF on both sides before matching, because the
# working tree carries CRLF for .ps1 while the literals in this file do not.
# The mutant is written back with LF, which PowerShell parses identically; the
# original comes back from the backup either way.
function Invoke-Mutation {
    param([string]$Name, [string]$File, [string]$Suite, [string]$Find, [string]$Replace = '')

    if ($Filter -and $Name -notlike "*$Filter*") { return }

    $target = Join-Path $WinDir $File
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Host ("  ERROR     {0}  ->  no such file: {1}" -f $Name, $File)
        $script:Checked++; $script:Survived++
        return
    }

    if (-not (Test-SuiteGreen -Suite $Suite)) {
        Write-Host ("  UNJUDGED  {0}  ->  {1} is red before any mutation; fix the suite first" -f $Name, $Suite)
        $script:Checked++; $script:Survived++; $script:Unjudged++
        return
    }

    $backup = "$target.mutbak"
    Copy-Item -LiteralPath $target -Destination $backup -Force
    try {
        $src   = (Get-Content -Raw -LiteralPath $target) -replace "`r`n", "`n"
        $Find  = $Find    -replace "`r`n", "`n"
        $Replace = $Replace -replace "`r`n", "`n"
        if (-not $src.Contains($Find)) {
            Write-Host ("  ERROR     {0}  ->  mutation did not apply; '{1}' is not in {2}" -f $Name, $Find, $File)
            $script:Checked++; $script:Survived++
            return
        }
        # -Encoding ASCII, and no BOM: PowerShell 5.1 reads a .ps1 with a BOM
        # differently, and these files are ASCII by convention anyway.
        [IO.File]::WriteAllText($target, $src.Replace($Find, $Replace), [Text.Encoding]::ASCII)

        # A mutant that does not PARSE tests nothing: the suite goes red for the
        # wrong reason and the mutation reads as caught. Only scripts have a
        # parser to fail; some subjects here are markdown.
        $errors = $null
        if ($target -like '*.ps1') {
            [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$null, [ref]$errors) | Out-Null
        }
        if ($errors) {
            Write-Host ("  ERROR     {0}  ->  the mutated source does not parse: {1}" -f $Name, $errors[0].Message)
            $script:Checked++; $script:Survived++
            return
        }

        $script:Checked++
        $r = Invoke-Suite -Suite $Suite
        if ($r.Ok) {
            Write-Host ("  SURVIVED  {0}" -f $Name)
            $script:Survived++
        } else {
            Write-Host ("  caught    {0}  ->  {1}" -f $Name, $r.Why)
        }
    } finally {
        Move-Item -LiteralPath $backup -Destination $target -Force
    }
}

# =============================================================================
# The mutations
# =============================================================================

# --- the instruction-file budget ---------------------------------------------

Invoke-Mutation 'docs: windows/AGENTS.md grows past the Codex budget' `
    'AGENTS.md' 'conventions.tests.ps1' `
    '# Windows -- agent instructions' `
    ('# Windows -- agent instructions' + "`n<!-- " + ('x' * 600) + ' -->')
Invoke-Mutation 'docs: a CLAUDE.md becomes a second copy instead of an import' `
    'CLAUDE.md' 'conventions.tests.ps1' `
    '@AGENTS.md' '# Windows -- agent instructions'

# --- which config the watcher reads ------------------------------------------

# Replaced rather than deleted: dropping the last element of the array would
# leave a dangling comma, and a mutant that does not parse tests nothing.
Invoke-Mutation 'launch: the task action does not name the config' `
    'lib\host.ps1' 'install.tests.ps1' `
    "        '-Config', ""``""`$ConfigFile``""""" "        '-Arg', 'pull'"
Invoke-Mutation 'launch: the switcher is left to re-derive the config path' `
    'event-watch.ps1' 'install.tests.ps1' `
    "    if (`$ConfigFile) { `$a += @('-Config',  ""``""`$ConfigFile``"""") }" ''
Invoke-Mutation 'launch: an absent log becomes an empty -LogFile' `
    'event-watch.ps1' 'install.tests.ps1' `
    "    if (`$LogFile)    { `$a += @('-LogFile', ""``""`$LogFile``"""") }" `
    "    `$a += @('-LogFile', ""``""`$LogFile``"""")"

# --- registering the task ------------------------------------------------------

Invoke-Mutation 'install: a failed registration is a bare stack trace' `
    'lib\host.ps1' 'conventions.tests.ps1' `
    '    try {
        Register-ScheduledTask @register `
            -Description "trigger-kvm: pull the configured monitors to this computer when the shared peripherals arrive." | Out-Null
    } catch {' `
    '    if ($true) {
        Register-ScheduledTask @register `
            -Description "trigger-kvm: pull the configured monitors to this computer when the shared peripherals arrive." | Out-Null
    } else {'

# --- the user PATH -------------------------------------------------------------

Invoke-Mutation 'path: the read expands other people''s %VAR% entries' `
    'lib\host.ps1' 'install.tests.ps1' `
    "            return [string]`$k.GetValue('Path', '',
                       [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)" `
    "            return [string]`$k.GetValue('Path', '')"
Invoke-Mutation 'path: the write downgrades REG_EXPAND_SZ to REG_SZ' `
    'lib\host.ps1' 'install.tests.ps1' `
    "    if (`$Value -match '%')            { return 'ExpandString' }
    if (`$Current -eq 'ExpandString')  { return 'ExpandString' }" ''

# --- an incomplete copy -------------------------------------------------------

Invoke-Mutation 'install: a half-copied install throws instead of saying so' `
    'install.ps1' 'install.tests.ps1' `
    "if (-not (Test-Path -LiteralPath `$libDir -PathType Container)) {" `
    "if (`$false) {"

# --- the config reader and its converters -------------------------------------

Invoke-Mutation 'config: the value is not cut at the first #' `
    'config.ps1' 'config.tests.ps1' `
    "'^\s*([A-Za-z0-9_.\-]+)\s*=\s*(.*?)\s*(?:#.*)?`$'" `
    "'^\s*([A-Za-z0-9_.\-]+)\s*=\s*(.*?)\s*`$'"
Invoke-Mutation 'config: keys are not lower-cased' `
    'config.ps1' 'config.tests.ps1' `
    '$map[$Matches[1].ToLower()] = $Matches[2]' '$map[$Matches[1]] = $Matches[2]'
Invoke-Mutation 'config: the reader loses file order' `
    'config.ps1' 'config.tests.ps1' `
    '    $map = [ordered]@{}' '    $map = @{}'
Invoke-Mutation 'config: a byte that does not parse becomes zero' `
    'config.ps1' 'config.tests.ps1' `
    '    if ([string]::IsNullOrEmpty($Text)) { return $null }
    try {
        if ($Text -cmatch ''^0[xX][0-9A-Fa-f]{1,2}$'')' `
    '    if ([string]::IsNullOrEmpty($Text)) { return [byte]0 }
    try {
        if ($Text -cmatch ''^0[xX][0-9A-Fa-f]{1,2}$'')'
Invoke-Mutation 'config: a leading zero is read as octal' `
    'config.ps1' 'config.tests.ps1' `
    '        if ($Text -match  ''^[0-9]{1,3}$'')            { return [byte][int]$Text }' `
    '        if ($Text -match  ''^[0-9]{1,3}$'')            { return [byte][Convert]::ToInt32($Text, 8) }'
Invoke-Mutation 'config: a word above 65535 is accepted' `
    'config.ps1' 'config.tests.ps1' `
    '            if ($n -le 65535) { return $n }' '            return $n'
Invoke-Mutation 'config: the converters trim, so " 0x11 " is accepted' `
    'config.ps1' 'config.tests.ps1' `
    '    if ([string]::IsNullOrEmpty($Text)) { return $null }
    try {
        if ($Text -cmatch ''^0[xX][0-9A-Fa-f]{1,2}$'')' `
    '    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $Text = $Text.Trim()
    try {
        if ($Text -cmatch ''^0[xX][0-9A-Fa-f]{1,2}$'')'
Invoke-Mutation 'config: a malformed timing reads as zero rather than being refused' `
    'config.ps1' 'config.tests.ps1' `
    "    return (`$Text -match '^[0-9]+(\.[0-9]+)?`$')" '    return $true'

# --- the walkthrough parses what the switcher parses ---------------------------

Invoke-Mutation 'values: the typed prompt keeps its own regex' `
    'lib\walkthrough.ps1' 'walkthrough.tests.ps1' `
    '            $v = Format-Byte $typed
            if (-not $v) { Write-Host ''  Not a byte.''; continue }' `
    '            if ($typed -notmatch ''^(0[xX])?[0-9A-Fa-f]{1,2}$'') { Write-Host ''  Not a byte.''; continue }
            $v = $typed'
Invoke-Mutation 'values: only a hex input key is read back from the config' `
    'lib\answers.ps1' 'walkthrough.tests.ps1' `
    "            if (`$k -match ('^display\.' + [regex]::Escape(`$Label) + '\.input\.(.+)`$')) {" `
    "            if (`$k -match ('^display\.' + [regex]::Escape(`$Label) + '\.input\.(0x[0-9a-f]{1,2})`$')) {"
Invoke-Mutation 'values: EDID ids are compared as hex text' `
    'lib\answers.ps1' 'walkthrough.tests.ps1' `
    '        $ven = ConvertTo-Word $Existing["display.$l.vendor"]
        $pro = ConvertTo-Word $Existing["display.$l.product"]
        if ($null -eq $ven -or $null -eq $pro) { continue }
        if ((''{0:X4}'' -f $ven) -ne $Key.Split('':'')[0]) { continue }
        if ((''{0:X4}'' -f $pro) -ne $Key.Split('':'')[1]) { continue }' `
    '        if (($Existing["display.$l.vendor"]  -replace ''^0[xX]'','''').ToUpper().PadLeft(4,''0'') -ne $Key.Split('':'')[0]) { continue }
        if (($Existing["display.$l.product"] -replace ''^0[xX]'','''').ToUpper().PadLeft(4,''0'') -ne $Key.Split('':'')[1]) { continue }'

Invoke-Mutation 'values: outcome 2 re-asks without the map, so an input can be taken twice' `
    'lib\checks.ps1' 'monitor-check.tests.ps1' `
    '                -Default $Answer.Map[$This] -Taken $taken -Method $Answer.Method `' `
    '                -Default $Answer.Map[$This] -Method $Answer.Method `'

# --- the typed fallback --------------------------------------------------------

Invoke-Mutation 'menus: q is dead on the top menu in the typed fallback' `
    'lib\menu.ps1' 'menus.tests.ps1' `
    '            if ($EscapeTo -ge 0 -and $pick -eq ''q'' -and $sel -contains $EscapeTo) {
                $Default = $EscapeTo
                continue
            }' ''
Invoke-Mutation 'menus: q on the top menu chooses Cancel outright' `
    'lib\menu.ps1' 'menus.tests.ps1' `
    '                $Default = $EscapeTo
                continue' '                return $EscapeTo'
Invoke-Mutation 'menus: q moves the cursor onto a disabled row' `
    'lib\menu.ps1' 'menus.tests.ps1' `
    "            if (`$EscapeTo -ge 0 -and `$pick -eq 'q' -and `$sel -contains `$EscapeTo) {" `
    "            if (`$EscapeTo -ge 0 -and `$pick -eq 'q') {"

# --- the service channel says what it is --------------------------------------

Invoke-Mutation 'safety: the method chooser does not name the consequence' `
    'lib\walkthrough.ps1' 'walkthrough.tests.ps1' `
    "    Write-Host ('  {0}''s own method talks to a service channel on the monitor. It is' -f `$d.What)" ''
Invoke-Mutation 'safety: typing onto a manufacturer channel is not warned about' `
    'lib\walkthrough.ps1' 'walkthrough.tests.ps1' `
    '            if ($Method -ne ''standard'') {' '            if ($false) {'
Invoke-Mutation 'safety: the warning is shown on the standard channel too' `
    'lib\walkthrough.ps1' 'walkthrough.tests.ps1' `
    '            if ($Method -ne ''standard'') {' '            if ($true) {'

# --- the checks --------------------------------------------------------------

Invoke-Mutation 'checks: backing out of a check reads as a failure' `
    'lib\walkthrough.ps1' 'walkthrough.tests.ps1' `
    '            elseif (-not $ranDisplays.Ok -and -not $ranDisplays.Backed) { 1 }' `
    '            elseif (-not $ranDisplays.Ok) { 1 }'
Invoke-Mutation 'checks: a real failure no longer lands on its setting' `
    'lib\walkthrough.ps1' 'walkthrough.tests.ps1' `
    '            elseif (-not $ranDisplays.Ok -and -not $ranDisplays.Backed) { 1 }' ''

# --- hand edits survive ---------------------------------------------------------

Invoke-Mutation 'config: an unknown key is dropped on Save' `
    'lib\answers.ps1' 'walkthrough.tests.ps1' `
    '    $carried = @(Get-CarriedKeys -Existing $Existing -Displays $Displays)' `
    '    $carried = @()'
Invoke-Mutation 'config: an unmanaged panel''s keys are kept anyway' `
    'lib\answers.ps1' 'walkthrough.tests.ps1' `
    '            if ($managed -notcontains $Matches[1]) { continue }' ''
Invoke-Mutation 'config: a superseded key name is carried beside the new one' `
    'lib\answers.ps1' 'walkthrough.tests.ps1' `
    '        if ($RENAMED_KEYS.Contains($k)) { continue }' ''

# --- names -------------------------------------------------------------------

Invoke-Mutation 'names: two monitors may share one short name' `
    'lib\walkthrough.ps1' 'walkthrough.tests.ps1' `
    "                       -Taken `$Labels -Noun 'monitor'" `
    "                       -Noun 'monitor'"
Invoke-Mutation 'names: a panel clashes with its own short name' `
    'lib\walkthrough.ps1' 'walkthrough.tests.ps1' `
    '        $others = @($out | Where-Object { $_.Key -ne $key } | ForEach-Object { $_.Label })' `
    '        $others = @($out | ForEach-Object { $_.Label })'
Invoke-Mutation 'names: the short name is mangled instead of asked about' `
    'lib\walkthrough.ps1' 'walkthrough.tests.ps1' `
    "    `$label = Read-Name -Prompt 'Short name for it' -Default `$defaultLabel ``
                       -Taken `$Labels -Noun 'monitor'" `
    "    `$label = Read-Default '  Short name for it' `$defaultLabel
    `$label = (`$label -replace '[^A-Za-z0-9_-]', '').ToLower()
    if (-not `$label) { `$label = `$defaultLabel }"
Invoke-Mutation 'names: a duplicate is accepted rather than refused' `
    'lib\menu.ps1' 'walkthrough.tests.ps1' `
    '        if ($Taken -contains $n) {' '        if ($false) {'
Invoke-Mutation 'names: an underscore survives the character rule' `
    'lib\menu.ps1' 'walkthrough.tests.ps1' `
    "    `$n = `$n -replace '[\s._]+', '-'" `
    "    `$n = `$n -replace '[\s.]+', '-'"

# --- the trigger check stands the watcher down --------------------------------

Invoke-Mutation 'trigger check: it runs with no devices chosen' `
    'lib\checks.ps1' 'trigger-check.tests.ps1' `
    '    if (@($Devices).Count -eq 0) {' '    if ($false) {'
Invoke-Mutation 'trigger check: the live watcher fires alongside the one-shot' `
    'lib\checks.ps1' 'trigger-check.tests.ps1' `
    "        'can' {
            Suspend-Watcher" `
    "        'can' {"
Invoke-Mutation 'trigger check: the watcher is left disabled afterwards' `
    'lib\checks.ps1' 'trigger-check.tests.ps1' `
    '        if ($paused) { Resume-Watcher }' ''
Invoke-Mutation 'trigger check: an admin-owned watcher is disabled anyway' `
    'lib\checks.ps1' 'trigger-check.tests.ps1' `
    "        'needs-admin' {
            Write-Host ''
            Write-Host '  The running watcher will also fire, using the saved configuration.'
        }" `
    "        'needs-admin' {
            Suspend-Watcher
            `$paused = `$true
        }"

# --- what the detector refuses before it arms ---------------------------------

Invoke-Mutation 'detector: a malformed debounce is cast, and kills the watcher silently' `
    'event-watch.ps1' 'detector.tests.ps1' `
    "    if (-not (Test-Seconds `$cfg['trigger.debounce'])) {
        Deny-Startup (""trigger.debounce = '{0}' is not a number of seconds (digits, or digits.digits)"" -f `$cfg['trigger.debounce'])
    }" ''
Invoke-Mutation 'detector: a malformed settle is cast' `
    'event-watch.ps1' 'detector.tests.ps1' `
    "    if (-not (Test-Seconds `$cfg['trigger.settle'])) {
        Deny-Startup (""trigger.settle = '{0}' is not a number of seconds (digits, or digits.digits)"" -f `$cfg['trigger.settle'])
    }" ''
Invoke-Mutation 'detector: a bad device entry is thrown, not logged' `
    'event-watch.ps1' 'detector.tests.ps1' `
    "        Deny-Startup (""trigger.device entry '{0}' is not a device; expected usb:VVVV:PPPP[@token[@where]] (or bare VVVV:PPPP) or bt:AAAAAAAAAAAA. A token and a where are lower-case letters, digits and dashes."" -f `$e.Raw)" `
    "        throw ""bad -Device '`$(`$e.Raw)'"""
# The grammar lives in config.ps1 now -- one copy, shared by the watcher that
# matches on it and the UI that displays it. These two prove the WATCHER still
# refuses through it; the config.tests pair below prove the parser itself does.
Invoke-Mutation 'detector: whitespace inside a device entry is accepted' `
    'config.ps1' 'detector.tests.ps1' `
    "        if (`$raw -cmatch '^(?:[Uu][Ss][Bb]:)?([0-9A-Fa-f]{4}):([0-9A-Fa-f]{4})(?:@([a-z0-9-]+))?(?:@([a-z0-9-]+))?`$') {" `
    "        if (`$raw -cmatch '^(?:[Uu][Ss][Bb]:)?([0-9A-Fa-f]{4})\s*:\s*([0-9A-Fa-f]{4})(?:@([a-z0-9-]+))?(?:@([a-z0-9-]+))?`$') {"
Invoke-Mutation 'detector: an entry is stripped of whitespace, not trimmed' `
    'config.ps1' 'detector.tests.ps1' `
    '        $raw = "$entry".Trim()' `
    "        `$raw = ""`$entry"" -replace '\s',''"
Invoke-Mutation 'detector: settle asks whether ANY watched device is present' `
    'event-watch.ps1' 'detector.tests.ps1' `
    '        $stillHere = @($arrived | Where-Object { $present[$_] })' `
    '        $stillHere = @($watch | Where-Object { $present[$_.Key] })'
Invoke-Mutation 'detector: an empty device list arms and watches nothing' `
    'event-watch.ps1' 'detector.tests.ps1' `
    "if (`$watch.Count -eq 0) {
    Deny-Startup 'no devices to watch -- run: trigger-kvm configure'
}" ''

# --- "is a watcher running" comes from the lock -------------------------------

Invoke-Mutation 'running: a lock that exists but is unheld reads as a live watcher' `
    'event-watch.ps1' 'detector.tests.ps1' `
    '            if (-not $m.WaitOne(0)) { return $true }' `
    '            return $true'
Invoke-Mutation 'running: the check keeps the lock it acquired' `
    'event-watch.ps1' 'detector.tests.ps1' `
    "            if (-not `$m.WaitOne(0)) { return `$true }
            # We got it, so nothing held it -- the name outlived its watcher.
            `$m.ReleaseMutex()" `
    '            if (-not $m.WaitOne(0)) { return $true }'
Invoke-Mutation 'running: a name nobody created reads as a live watcher' `
    'event-watch.ps1' 'detector.tests.ps1' `
    '            continue    # the name does not exist: nothing ever created it' `
    '            return $true'
Invoke-Mutation 'running: a lock owned by an unreachable token reads as no watcher' `
    'event-watch.ps1' 'detector.tests.ps1' `
    '            return $true    # exists, owned by a token we cannot open' `
    '            continue'
Invoke-Mutation 'running: install.ps1 goes back to counting processes' `
    'lib\host.ps1' 'conventions.tests.ps1' `
    '    Invoke-Sibling -Script $ew -Arguments @(''-IsRunning'') | Out-Null
    return ($LASTEXITCODE -eq 0)' `
    '    return (@(Get-CimInstance Win32_Process -Property ProcessId,Name,CommandLine -Verbose:$false |
        Where-Object { $_.CommandLine -and $_.CommandLine -match ''(usb|event)-watch\.ps1'' }).Count -ge 1)'
# --- installing clears the watcher it replaces --------------------------------

Invoke-Mutation 'install: the watcher under the task survives the upgrade' `
    'lib\host.ps1' 'conventions.tests.ps1' `
    "        Stop-Watchers
        try {
            Unregister-ScheduledTask -TaskName `$TASK -Confirm:`$false -ErrorAction Stop" `
    "        try {
            Unregister-ScheduledTask -TaskName `$TASK -Confirm:`$false -ErrorAction Stop"
Invoke-Mutation 'install: a registered task with nothing watching reads as success' `
    'lib\host.ps1' 'conventions.tests.ps1' `
    "        Write-Log 'WARNING: the task is registered but NO WATCHER is running.'" `
    "        Write-Log 'installed.'"

# --- the input map says it cannot be verified ---------------------------------

Invoke-Mutation 'inputs: the map is shown without saying nothing can check it' `
    'lib\host.ps1' 'install.tests.ps1' `
    "    `$out += '           ^ asserted, never verified. If a cable moved to another input on'
    `$out += '             the monitor, pull switches that panel to a dead input and it goes'
    `$out += '             black, with a success in the log. Fix: trigger-kvm configure'" ''
Invoke-Mutation 'inputs: the warning drops what actually goes wrong' `
    'lib\host.ps1' 'install.tests.ps1' `
    "    `$out += '             the monitor, pull switches that panel to a dead input and it goes'" `
    "    `$out += '             the monitor this will not work.'"
Invoke-Mutation 'inputs: the warning stops saying how to fix it' `
    'lib\host.ps1' 'install.tests.ps1' `
    "    `$out += '             black, with a success in the log. Fix: trigger-kvm configure'" `
    "    `$out += '             black, with a success in the log.'"
Invoke-Mutation 'inputs: the map sorts by input value, so two panels disagree' `
    'lib\host.ps1' 'install.tests.ps1' `
    "        `$map = @(`$rows |
            Sort-Object @{ Expression = {
                `$i = [array]::IndexOf([string[]]`$Computers, `$_.Who)
                if (`$i -lt 0) { [int]::MaxValue } else { `$i } } }, Value |" `
    "        `$map = @(`$rows |
            Sort-Object Value |"
Invoke-Mutation 'inputs: this computer is not marked, so the map reads as somebody else''s' `
    'lib\host.ps1' 'install.tests.ps1' `
    "                    `$(if (`$_.Who -eq `$This) { ' (this one)' } else { '' })" `
    "                    ''"
Invoke-Mutation 'inputs: a panel with no inputs mapped prints an empty row' `
    'lib\host.ps1' 'install.tests.ps1' `
    "                 `$(if (`$map) { `$map -join ', ' } else { 'no inputs mapped' }))" `
    "                 (`$map -join ', '))"
Invoke-Mutation 'inputs: the whole block is dropped from status' `
    'lib\host.ps1' 'spec.tests.ps1' `
    "    `$out += '           ^ asserted, never verified. If a cable moved to another input on'" ''

Invoke-Mutation 'running: the test-only mutex name reaches the real lock' `
    'event-watch.ps1' 'conventions.tests.ps1' `
    '    $mutex = New-Object System.Threading.Mutex($false, $MUTEX_GLOBAL)' `
    '    $mutex = New-Object System.Threading.Mutex($false, $(if ($MutexName) { $MutexName[0] } else { $MUTEX_GLOBAL }))'

# --- transport is a second axis, and cannot become a second door --------------

Invoke-Mutation 'transport: dxva2 quietly carries lg-alt instead of refusing' `
    'trigger-kvm.ps1' 'resolve.tests.ps1' `
    "    if (`$Display.Method -eq 'lg-alt' -and `$Display.Transport -in `$SOURCELESS_TRANSPORTS) {" `
    "    if (`$false) {"
Invoke-Mutation 'transport: an unknown transport falls back instead of refusing' `
    'trigger-kvm.ps1' 'resolve.tests.ps1' `
    "    if (`$Display.Transport -notin `$TRANSPORT_NAMES) {" `
    "    if (`$false) { `$Display.Transport = 'nvapi' }
    if (`$false) {"
Invoke-Mutation 'transport: an absent transport key stops meaning nvapi' `
    'trigger-kvm.ps1' 'resolve.tests.ps1' `
    "else { 'nvapi' })" `
    "else { 'dxva2' })"
Invoke-Mutation 'transport: dxva2 gains an I2C source parameter' `
    'trigger-kvm.ps1' 'conventions.tests.ps1' `
    '    public static int WriteStandardVcp(DxvaDisplay target, byte code, byte value) {' `
    '    public static int WriteStandardVcp(DxvaDisplay target, byte source, byte code, byte value) {'
Invoke-Mutation 'transport: a second embedded-source block goes unscanned' `
    'trigger-kvm.ps1' 'conventions.tests.ps1' `
    '$TransportSource = @''' `
    "\$SecondSource = @'`nusing System;`n'@`n`n\$TransportSource = @'"

# --- the walkthrough must configure a transport, and say what it costs --------
#
# The switcher's half of this is above. These are the installer's: what it asks,
# what it writes, and the two places a transport takes away coverage the rest of
# the program has already promised.

Invoke-Mutation 'transport: the question is asked even with one transport' `
    'lib\walkthrough.ps1' 'walkthrough.tests.ps1' `
    '    if ($t.Count -le 1) {' `
    '    if ($false) {'
Invoke-Mutation 'transport: dxva2 becomes the default instead of the covering one' `
    'lib\walkthrough.ps1' 'walkthrough.tests.ps1' `
    "    `$now  = `$(if (`$Current -eq 'dxva2') { 1 } elseif (`$Current -eq 'nvapi') { 0 } else { -1 })" `
    "    `$now  = `$(if (`$Current -eq 'dxva2') { 1 } elseif (`$Current -eq 'nvapi') { 0 } else { 1 })"
Invoke-Mutation 'transport: the dialect question is asked and then refused' `
    'lib\walkthrough.ps1' 'walkthrough.tests.ps1' `
    "    if (`$Transport -in `$SOURCELESS_TRANSPORTS) { return 'standard' }" `
    '    if ($false) { }'
Invoke-Mutation 'transport: the method question stops being told which transport' `
    'lib\walkthrough.ps1' 'walkthrough.tests.ps1' `
    '    $method = Read-Method -Vendor $Found.EdidVendor -Current $was -Transport $transport' `
    '    $method = Read-Method -Vendor $Found.EdidVendor -Current $was'
Invoke-Mutation 'transport: the choice is never written to the config' `
    'lib\answers.ps1' 'walkthrough.tests.ps1' `
    '            ("display.{0}.transport = {1}" -f $d.Label, $(if ($d.Transport) { $d.Transport } else { ''nvapi'' }))' `
    ''
Invoke-Mutation 'transport: a configured one is walked back to the default on a re-run' `
    'lib\answers.ps1' 'walkthrough.tests.ps1' `
    '            -Transport $(if ($prior.Transport) { $prior.Transport } else { ''nvapi'' }) `' `
    '            -Transport ''nvapi'' `'
Invoke-Mutation 'transport: the boot row stays pickable with a panel that cannot reach it' `
    'lib\walkthrough.ps1' 'walkthrough.tests.ps1' `
    '    if (-not $canElevate -or $stranded.Count -gt 0) { $off += 0 }' `
    '    if (-not $canElevate) { $off += 0 }'
Invoke-Mutation 'transport: the two disabled reasons are merged into one' `
    'lib\walkthrough.ps1' 'walkthrough.tests.ps1' `
    "        `$why += ('{0} cannot switch before login' -f (Join-Names `$stranded))" `
    "        `$why += 'needs an administrator account'"
Invoke-Mutation 'transport: an impossible boot tier is kept rather than downgraded' `
    'lib\walkthrough.ps1' 'walkthrough.tests.ps1' `
    "                if (`$newTier -eq 's4u' -and `$loginOnly.Count -gt 0) {" `
    '                if ($false) {'
Invoke-Mutation 'transport: status reports the tier and hides what it costs' `
    'lib\host.ps1' 'install.tests.ps1' `
    '    if ($FromBoot -and $stranded.Count -gt 0) {' `
    '    if ($false) {'
Invoke-Mutation 'transport: status defaults an unrecognised transport instead of naming it' `
    'lib\host.ps1' 'install.tests.ps1' `
    "        `$note = `$(if (`$row) { `$row.Note } else { 'UNRECOGNISED -- the switch will refuse this panel' })" `
    "        `$note = `$(if (`$row) { `$row.Note } else { 'through the graphics card' })"
Invoke-Mutation 'transport: the walkthrough may offer one the switcher refuses' `
    'lib\walkthrough.ps1' 'conventions.tests.ps1' `
    "    return `$(if (`$pick -eq 1) { 'dxva2' } else { 'nvapi' })" `
    "    return `$(if (`$pick -eq 1) { 'adl' } else { 'nvapi' })"

# --- a vendor:product pair can name more than one device ----------------------
#
# Two receivers on the reference desk share 046D:C547. These hold down the fact
# that each is separately selectable, and that a token identifies exactly one.

Invoke-Mutation 'token: the best name is taken rather than a unique one' `
    'lib\discover.ps1' 'install.tests.ps1' `
    '                    (@($mine | Where-Object { $_.Tokens -contains $t }).Count -eq 1)' `
    '                    $true'
Invoke-Mutation 'token: two devices on one id collapse back into one row' `
    'lib\discover.ps1' 'install.tests.ps1' `
    "        `$id = '{0}|{1}' -f `$f[0], `$key" `
    "        `$id = `$key"
Invoke-Mutation 'token: a device alone on its id is given one anyway' `
    'lib\discover.ps1' 'install.tests.ps1' `
    '        $alone = ($mine.Count -eq 1)' `
    '        $alone = $false'
Invoke-Mutation 'token: hubs come back, because the chosen name is filtered' `
    'lib\discover.ps1' 'install.tests.ps1' `
    "            if (@(`$d.Names | Where-Object { `$_ -match 'Hub|Host Controller|Root Complex' })) { continue }" `
    "            if (`$name -match 'Hub|Host Controller|Root Complex') { continue }"
Invoke-Mutation 'token: the remembered spot is consulted before the token resolves' `
    'event-watch.ps1' 'detector.tests.ps1' `
    "        return [PSCustomObject]@{ Present = `$true;  How = 'token';     Count = 1 }" `
    "        if (`$Spot) { return [PSCustomObject]@{ Present = `$false; How = 'none'; Count = 1 } }
        return [PSCustomObject]@{ Present = `$true;  How = 'token';     Count = 1 }"
Invoke-Mutation 'token: an ambiguous entry fires anyway' `
    'event-watch.ps1' 'detector.tests.ps1' `
    "    return [PSCustomObject]@{ Present = `$false; How = 'ambiguous'; Count = `$matched.Count }" `
    "    return [PSCustomObject]@{ Present = `$true; How = 'ambiguous'; Count = `$matched.Count }"
Invoke-Mutation 'token: a tie is broken without saying so' `
    'event-watch.ps1' 'detector.tests.ps1' `
    "            return [PSCustomObject]@{ Present = `$true; How = 'spot'; Count = `$matched.Count }" `
    "            return [PSCustomObject]@{ Present = `$true; How = 'token'; Count = `$matched.Count }"

# --- a writer must not write what it cannot read back -------------------------
#
# The read rule was pinned to the byte and said nothing about writers, so both
# implementations wrote values straight through and both truncated a display name
# containing a hash. These hold the fix down on this side.

Invoke-Mutation 'writer: a hash is written through and truncates on read' `
    'config.ps1' 'config.tests.ps1' `
    "    return (`$Text -replace '[#\r\n]', ' ' -replace '\s+', ' ').Trim()" `
    "    return (`$Text -replace '[\r\n]', ' ' -replace '\s+', ' ').Trim()"
Invoke-Mutation 'writer: a newline is written through and breaks the line' `
    'config.ps1' 'config.tests.ps1' `
    "    return (`$Text -replace '[#\r\n]', ' ' -replace '\s+', ' ').Trim()" `
    "    return (`$Text -replace '[#]', ' ' -replace '[ \t]+', ' ').Trim()"
Invoke-Mutation 'writer: an equals sign is stripped, though a value may hold one' `
    'config.ps1' 'config.tests.ps1' `
    "    return (`$Text -replace '[#\r\n]', ' ' -replace '\s+', ' ').Trim()" `
    "    return (`$Text -replace '[#=\r\n]', ' ' -replace '\s+', ' ').Trim()"
Invoke-Mutation 'writer: a device token keeps characters the format would eat' `
    'config.ps1' 'config.tests.ps1' `
    "    return ((`$Text.ToLower() -replace '[^a-z0-9]+', '-').Trim('-'))" `
    '    return $Text.ToLower()'

# ---- the device-entry grammar, and the normalising that shipped ---------------
#
# The defect these hold down: install.ps1 deleted ALL whitespace and lower-cased
# the WHOLE entry before showing it, so `@has space` displayed as the well-formed
# `@hasspace` and `@BadCase` as `@badcase` -- both refused by the watcher, which
# reads the raw value. `status` then called a malformed entry a configured device
# that was merely "not attached right now".

Invoke-Mutation 'grammar: an entry is stripped of whitespace, so @has space looks valid' `
    'config.ps1' 'config.tests.ps1' `
    '        $raw = "$entry".Trim()' `
    "        `$raw = ""`$entry"" -replace '\s',''"
Invoke-Mutation 'grammar: the suffix is matched case-insensitively, so @BadCase is accepted' `
    'config.ps1' 'config.tests.ps1' `
    "        if (`$raw -cmatch '^(?:[Uu][Ss][Bb]:)?([0-9A-Fa-f]{4}):([0-9A-Fa-f]{4})(?:@([a-z0-9-]+))?(?:@([a-z0-9-]+))?`$') {" `
    "        if (`$raw -match '^(?:[Uu][Ss][Bb]:)?([0-9A-Fa-f]{4}):([0-9A-Fa-f]{4})(?:@([a-z0-9-]+))?(?:@([a-z0-9-]+))?`$') {"
Invoke-Mutation 'grammar: a malformed entry keeps a canonicalised Raw, not what was written' `
    'config.ps1' 'config.tests.ps1' `
    '            Raw = $raw; Ok = $false; Kind = ''''; Vid = ''''; Prod = ''''' `
    '            Raw = $raw.ToLower(); Ok = $false; Kind = ''''; Vid = ''''; Prod = '''''
Invoke-Mutation 'grammar: the spot is part of an identity, so a moved device reads as unconfigured' `
    'config.ps1' 'config.tests.ps1' `
    "            `$e.Key      = `$e.Identity + `$(if (`$e.Spot) { ""@`$(`$e.Spot)"" } else { '' })" `
    "            `$e.Identity = `$e.Identity + `$(if (`$e.Spot) { ""@`$(`$e.Spot)"" } else { '' }); `$e.Key = `$e.Identity"

# ---- status tells the truth about a malformed entry ---------------------------

Invoke-Mutation 'status: a malformed trigger is counted as merely absent' `
    'lib\host.ps1' 'install.tests.ps1' `
    '            $bad++' `
    '            $missing++'
Invoke-Mutation 'status: a trigger row is canonicalised, so it is not the string in the file' `
    'lib\host.ps1' 'install.tests.ps1' `
    "        `$out += ('{0} {1,-20} {2}' -f `$label, `$d.Raw, `$name)" `
    "        `$out += ('{0} {1,-20} {2}' -f `$label, `$d.Key, `$name)"
Invoke-Mutation 'status: a malformed trigger is reported as a device that is elsewhere' `
    'lib\host.ps1' 'install.tests.ps1' `
    '        if (-not $d.Ok) {' `
    '        if ($false) {'

# ---- the conformance loop knows when a spec file is checked by nobody ---------
#
# A suite that loops over a list of spec names it holds itself cannot check a
# file nobody added to that list, and it stays GREEN while doing it -- status.md
# went unchecked on macOS for five revisions that way.
Invoke-Mutation 'spec: a listing that finds nothing passes vacuously' `
    'tests\spec.tests.ps1' 'spec.tests.ps1' `
    "    if (@(`$Files).Count -eq 0) { return @('specs/ has no .md files at all -- the check is broken, not passing') }" `
    '    if (@($Files).Count -eq 0) { return @() }'
Invoke-Mutation 'spec: a spec file in neither list goes unnoticed' `
    'tests\spec.tests.ps1' 'spec.tests.ps1' `
    '    return @($Files | Where-Object { $known -notcontains $_ })' `
    '    return @()'
Invoke-Mutation 'writer: the display name goes to the file unsanitised' `
    'lib\answers.ps1' 'walkthrough.tests.ps1' `
    '            ("display.{0}.name      = {1}" -f $d.Label, (ConvertTo-ConfigValue $d.Name))' `
    '            ("display.{0}.name      = {1}" -f $d.Label, $d.Name)'

# --- naming a device, when Windows would rather not ---------------------------
#
# Three rows read `USB Input Device` on the reference desk, and two of them could
# never travel. These are the assertions that stop it going back.

Invoke-Mutation 'naming: a generic name wins again' `
    'lib\discover.ps1' 'install.tests.ps1' `
    '    $named = @($all | Where-Object { $_ -notmatch $GENERIC_NAMES -and $_ -notmatch ''^USB '' })' `
    '    $named = @($all)'
Invoke-Mutation 'naming: a bus-prefixed name stops losing to a real one' `
    'lib\discover.ps1' 'install.tests.ps1' `
    '    $named = @($all | Where-Object { $_ -notmatch $GENERIC_NAMES -and $_ -notmatch ''^USB '' })' `
    '    $named = @($all | Where-Object { $_ -notmatch $GENERIC_NAMES })'
Invoke-Mutation 'naming: "USB " becomes a veto rather than a preference' `
    'lib\discover.ps1' 'install.tests.ps1' `
    '    $good = @($all | Where-Object { $_ -notmatch $GENERIC_NAMES })
    if ($good.Count -gt 0) { return $good[0] }' `
    ''
Invoke-Mutation 'naming: a driver name is allowed to identify a device' `
    'event-watch.ps1' 'detector.tests.ps1' `
    "            `$tok = `$(if (`$Devices[`$k].Own -contains `$n) { ConvertTo-DeviceToken `$n } else { '' })" `
    "            `$tok = ConvertTo-DeviceToken `$n"
Invoke-Mutation 'naming: a bare HIDClass child counts as an input role' `
    'lib\discover.ps1' 'install.tests.ps1' `
    "        if (`$d.Class -notin @('Mouse', 'Keyboard')) { continue }" `
    "        if (-not `$d.Class) { continue }"
Invoke-Mutation 'naming: roles stop reaching the row' `
    'lib\discover.ps1' 'install.tests.ps1' `
    '    if ($Candidate.Roles) { $s += (''  ({0})'' -f (@($Candidate.Roles) -join '', '')) }' `
    ''
Invoke-Mutation 'naming: the state goes back into the name and breaks the columns' `
    'lib\discover.ps1' 'install.tests.ps1' `
    '    if ($Candidate.Roles) { $s += (''  ({0})'' -f (@($Candidate.Roles) -join '', '')) }' `
    '    if ($Candidate.Roles) { $s += (''  ({0})'' -f (@($Candidate.Roles) -join '', '')) }
    if ($Candidate.State) { $s += ("  ({0})" -f $Candidate.State) }'
Invoke-Mutation 'naming: the menu goes back to picking by vendor:product' `
    'lib\walkthrough.ps1' 'walkthrough.tests.ps1' `
    '        -Items  @($Cands | ForEach-Object { Get-CandidateLabel $_ }) `' `
    '        -Items  @($Cands | ForEach-Object { ''{0,-20} {1,-4}'' -f $_.Key, $_.Bus }) `'
Invoke-Mutation 'naming: a device presenting a keyboard stops sorting first' `
    'lib\discover.ps1' 'install.tests.ps1' `
    '                Rank  = $(if ($roles[$d.Key]) { 0 }' `
    '                Rank  = $(if ($false) { 0 }'
Invoke-Mutation 'naming: the review menu goes back to listing ids' `
    'lib\walkthrough.ps1' 'walkthrough.tests.ps1' `
    '                    if     ($c) { $c.Name }' `
    '                    if     ($false) { $c.Name }'
Invoke-Mutation 'naming: the review menu shows a malformed entry as an ordinary device' `
    'lib\walkthrough.ps1' 'walkthrough.tests.ps1' `
    '                    elseif (-not (ConvertFrom-TriggerDevices $d)[0].Ok) { "$d (malformed)" }' `
    '                    elseif ($false) { "$d (malformed)" }'
Invoke-Mutation 'naming: status reports the trigger keys with no names' `
    'lib\host.ps1' 'install.tests.ps1' `
    '        elseif ($by.Contains($d.Identity)) { $name = Get-CandidateLabel $by[$d.Identity] }' `
    "        elseif (`$by.Contains(`$d.Identity)) { `$name = '' }"
Invoke-Mutation 'naming: an absent trigger is left reading as a fault' `
    'lib\host.ps1' 'install.tests.ps1' `
    '    if ($missing -gt 0) {' `
    '    if ($false) {'

# --- one verb surface, in one place -------------------------------------------
#
# The drift these catch is the one that shipped: three lists of verbs that could
# not see each other, and an error message that named a verb which did not work
# while hiding three that did.

Invoke-Mutation 'verbs: a bare command switches the monitors again' `
    'lib\host.ps1' 'conventions.tests.ps1' `
    '    ''if "%~1"=="" goto :usage''' `
    '    ''if "%~1"=="" goto :switch'''
Invoke-Mutation 'verbs: a usage path diverges from macOS by reporting success' `
    'lib\host.ps1' 'conventions.tests.ps1' `
    "    'exit /b %ERRORLEVEL%'" `
    "    'exit /b 0'"
Invoke-Mutation 'verbs: the usage screen stops reading like the macOS one' `
    'lib\host.ps1' 'conventions.tests.ps1' `
    "        'usage: trigger-kvm <verb> [options]'" `
    "        'trigger-kvm -- two computers, two monitors, one switch'"
Invoke-Mutation 'verbs: an unknown one falls through to the binding error again' `
    'lib\host.ps1' 'conventions.tests.ps1' `
    "    'goto :unknown'" `
    "    'goto :manage'"
Invoke-Mutation 'verbs: a switching verb stops being routed' `
    'lib\host.ps1' 'conventions.tests.ps1' `
    "    foreach (`$v in (`$VERBS | Where-Object { `$_.Where -eq 'switch' })) {" `
    "    foreach (`$v in (`$VERBS | Where-Object { `$_.Where -eq 'switch' -and `$_.Verb -ne 'list' })) {"
Invoke-Mutation 'verbs: install is offered on the usage screen' `
    'config.ps1' 'conventions.tests.ps1' `
    "    @{ Verb = 'pull';      Where = 'switch'; Arg = ''" `
    "    @{ Verb = 'install';   Where = 'manage'; Arg = ''
       Help = 'install it' }
    @{ Verb = 'pull';      Where = 'switch'; Arg = ''"
Invoke-Mutation 'verbs: set reaches the public surface' `
    'config.ps1' 'conventions.tests.ps1' `
    "    @{ Verb = 'list';      Where = 'switch'; Arg = ''" `
    "    @{ Verb = 'set';       Where = 'switch'; Arg = '<value>'
       Help = 'write a value' }
    @{ Verb = 'list';      Where = 'switch'; Arg = ''"

# --- the LG service channel has one door --------------------------------------
#
# The self-test inside conventions.tests.ps1 already proves the CHECK bites, on
# throwaway copies. These prove the check is wired to the real file.

Invoke-Mutation 'gate: a second emitter of source 0x50' `
    'trigger-kvm.ps1' 'conventions.tests.ps1' `
    '    public static int WriteStandardVcp(NvDisplay target, byte vcp, byte value) {
        if (target == null) throw new ArgumentNullException("target");
        return Send(target, BuildSetVcp(STD_I2C_SOURCE, vcp, value));' `
    '    public static int WriteStandardVcp(NvDisplay target, byte vcp, byte value) {
        if (target == null) throw new ArgumentNullException("target");
        return Send(target, BuildSetVcp(LG_I2C_SOURCE, vcp, value));'
Invoke-Mutation 'gate: the vendor check leaves the gate' `
    'trigger-kvm.ps1' 'conventions.tests.ps1' `
    '        if (target.EdidVendor != EDID_VENDOR_GSM)' `
    '        if (false)'

# --- the boot tier ------------------------------------------------------------

Invoke-Mutation 'tier: a declined prompt leaves the config claiming boot' `
    'lib\host.ps1' 'elevation.tests.ps1' `
    "    Write-Log 'falling back to starting at login.'" `
    "    Write-Log 'nothing was changed.'; return 's4u'"
Invoke-Mutation 'tier: the fallback does not record what was installed' `
    'lib\host.ps1' 'elevation.tests.ps1' `
    "    Set-ConfigValue -Path `$CONFIG -Key 'install.autostart' -Value 'login'" ''
Invoke-Mutation 'tier: the From boot row is offered to an account that cannot elevate' `
    'lib\walkthrough.ps1' 'walkthrough.tests.ps1' `
    '    if (-not $canElevate -or $stranded.Count -gt 0) { $off += 0 }' `
    '    if ($stranded.Count -gt 0) { $off += 0 }'
Invoke-Mutation 'tier: the row is hidden instead of disabled' `
    'lib\walkthrough.ps1' 'walkthrough.tests.ps1' `
    "    if (-not `$canElevate) { `$why += 'needs an administrator account' }"  `
    "    if (-not `$canElevate) { `$why += 'not available here' }"

# --- the monitors list --------------------------------------------------------

Invoke-Mutation 'monitors: the list disables a row it does not own' `
    'lib\walkthrough.ps1' 'walkthrough.tests.ps1' `
    '        $pick = Select-One -Items $items -Detail $detail -Default $land -Escapable' `
    '        $pick = Select-One -Items $items -Detail $detail -Default $land -Disabled $off -Escapable'

# --- a skip is never a pass ---------------------------------------------------
#
# The harness itself is the subject here. conventions.tests.ps1 copies run.ps1
# and lib.ps1 into a temp directory and runs probe files through them, so a
# mutation to the real run.ps1 travels into that copy -- which is the point: the
# bug these catch was in the rendering, not in Skip-Case.

Invoke-Mutation 'skips: a skipped case is swallowed by the file that passed' `
    'tests\run.ps1' 'conventions.tests.ps1' `
    '
        else                      { Show-Skips $out }' `
    ''

Invoke-Mutation 'skips: the summary does not count them' `
    'tests\run.ps1' 'conventions.tests.ps1' `
    @'
if ($skippedCases -gt 0) {
    Write-Host ("{0} case(s) inside the files that did run were skipped -- see SKIPPED above" -f $skippedCases)
}
'@ `
    ''

# --- two attached panels sharing one identity ---------------------------------
#
# specs/configure.md 6.4, specs/status.md 5. Nobody here owns twins, so every one
# of these is aimed at the decisions made ABOUT the count rather than at the
# hardware case -- which is exactly what identity.tests.ps1 can reach.

Invoke-Mutation 'identity: the panel count is summed across transports, not maxed' `
    'trigger-kvm.ps1' 'identity.tests.ps1' `
    '        if (-not $Into.Contains($k) -or $Into[$k] -lt $From[$k]) { $Into[$k] = $From[$k] }' `
    '        $Into[$k] = $(if ($Into.Contains($k)) { $Into[$k] } else { 0 }) + $From[$k]'

Invoke-Mutation 'identity: a smaller count from one transport lowers the other' `
    'trigger-kvm.ps1' 'identity.tests.ps1' `
    '        if (-not $Into.Contains($k) -or $Into[$k] -lt $From[$k]) { $Into[$k] = $From[$k] }' `
    '        $Into[$k] = $From[$k]'

# An older switcher sends no field 8. Defaulting it to 0 rather than 1 makes
# every upgraded desk read as "fewer than one panel", which is not a state.
Invoke-Mutation 'identity: a row with no panel count defaults to zero' `
    'lib\discover.ps1' 'identity.tests.ps1' `
    '                            [int]$f[7]
                        } else { 1 }' `
    '                            [int]$f[7]
                        } else { 0 }'

Invoke-Mutation 'identity: an unparseable panel count is cast anyway' `
    'lib\discover.ps1' 'identity.tests.ps1' `
    '$(if ($f.Count -ge 8 -and $f[7] -match ''^\d+$'') {' `
    '$(if ($f.Count -ge 8) {'

# The refusal is the whole point: without it the walkthrough asks about an id it
# cannot aim at, and the second answer overwrites the first.
Invoke-Mutation 'identity: the walkthrough takes an answer for an ambiguous id' `
    'lib\walkthrough.ps1' 'identity.tests.ps1' `
    '        if ($f.Panels -gt 1) {
            Write-Host ''''' `
    '        if ($false) {
            Write-Host '''''

Invoke-Mutation 'identity: the Monitors row does not say the id is unmanageable' `
    'lib\walkthrough.ps1' 'identity.tests.ps1' `
    '$detail += $(if ($f.Panels -gt 1) { ''{0} monitors share this id -- cannot manage'' -f $f.Panels }' `
    '$detail += $(if ($false) { ''{0} monitors share this id -- cannot manage'' -f $f.Panels }'

# specs/status.md 5.2: absent and ambiguous are different states. The guard that
# separates them has NO mutation here on purpose -- dropping the Contains check
# behaves identically, because a missing key reads as $null and $null -le 1 is
# already true. It stays in the source for explicitness; a mutation nothing can
# catch would report a surviving bug that is not one. The threshold below IS
# mutable, and is what actually decides.
Invoke-Mutation 'identity: status reports on a single attached panel' `
    'lib\host.ps1' 'identity.tests.ps1' `
    '        if ($Attached[$key] -le 1) { continue }' `
    '        if ($Attached[$key] -le 0) { continue }'

Invoke-Mutation 'identity: status offers configure as the fix it does not have' `
    'lib\host.ps1' 'identity.tests.ps1' `
    '           follow. Unplug one of each pair -- nothing here can tell them apart.' `
    '           follow. Fix: trigger-kvm configure'

# =============================================================================

Write-Host ''
if ($script:Survived -eq 0) {
    Write-Host ("all {0} mutations were caught" -f $script:Checked)
} elseif ($script:Survived -eq $script:Unjudged) {
    Write-Host ("{0} of {1} mutations UNJUDGED -- their suite is red unmutated, so nothing was proved" -f
                $script:Unjudged, $script:Checked)
} else {
    Write-Host ("{0} of {1} mutations SURVIVED ({2} unjudged) -- those assertions do not earn their place" -f
                $script:Survived, $script:Checked, $script:Unjudged)
}
exit $script:Survived
