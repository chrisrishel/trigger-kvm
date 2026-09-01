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
    'install.ps1' 'install.tests.ps1' `
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
    'install.ps1' 'conventions.tests.ps1' `
    'try {
    Register-ScheduledTask @register `
        -Description "trigger-kvm: pull the configured monitors to this computer when the shared peripherals arrive." | Out-Null
} catch {' `
    'if ($true) {
    Register-ScheduledTask @register `
        -Description "trigger-kvm: pull the configured monitors to this computer when the shared peripherals arrive." | Out-Null
} else {'

# --- the user PATH -------------------------------------------------------------

Invoke-Mutation 'path: the read expands other people''s %VAR% entries' `
    'install.ps1' 'install.tests.ps1' `
    "            return [string]`$k.GetValue('Path', '',
                       [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)" `
    "            return [string]`$k.GetValue('Path', '')"
Invoke-Mutation 'path: the write downgrades REG_EXPAND_SZ to REG_SZ' `
    'install.ps1' 'install.tests.ps1' `
    "    if (`$Value -match '%')            { return 'ExpandString' }
    if (`$Current -eq 'ExpandString')  { return 'ExpandString' }" ''

# --- the pre-rename cleanup ---------------------------------------------------

Invoke-Mutation 'legacy: any display-switch directory is deleted' `
    'install.ps1' 'install.tests.ps1' `
    "    if (-not (Test-Path -LiteralPath `$vbs -PathType Leaf)) { return `$false }" `
    "    return `$true"
Invoke-Mutation 'legacy: any task of that name is unregistered' `
    'install.ps1' 'install.tests.ps1' `
    "    if (`$act -match '(usb|event)-watch\.ps1') { return `$true }" `
    "    return `$true"

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
    'install.ps1' 'walkthrough.tests.ps1' `
    '            $v = Format-Byte $typed
            if (-not $v) { Write-Host ''  Not a byte.''; continue }' `
    '            if ($typed -notmatch ''^(0[xX])?[0-9A-Fa-f]{1,2}$'') { Write-Host ''  Not a byte.''; continue }
            $v = $typed'
Invoke-Mutation 'values: only a hex input key is read back from the config' `
    'install.ps1' 'walkthrough.tests.ps1' `
    "            if (`$k -match ('^display\.' + [regex]::Escape(`$Label) + '\.input\.(.+)`$')) {" `
    "            if (`$k -match ('^display\.' + [regex]::Escape(`$Label) + '\.input\.(0x[0-9a-f]{1,2})`$')) {"
Invoke-Mutation 'values: EDID ids are compared as hex text' `
    'install.ps1' 'walkthrough.tests.ps1' `
    '        $ven = ConvertTo-Word $Existing["display.$l.vendor"]
        $pro = ConvertTo-Word $Existing["display.$l.product"]
        if ($null -eq $ven -or $null -eq $pro) { continue }
        if ((''{0:X4}'' -f $ven) -ne $Key.Split('':'')[0]) { continue }
        if ((''{0:X4}'' -f $pro) -ne $Key.Split('':'')[1]) { continue }' `
    '        if (($Existing["display.$l.vendor"]  -replace ''^0[xX]'','''').ToUpper().PadLeft(4,''0'') -ne $Key.Split('':'')[0]) { continue }
        if (($Existing["display.$l.product"] -replace ''^0[xX]'','''').ToUpper().PadLeft(4,''0'') -ne $Key.Split('':'')[1]) { continue }'

Invoke-Mutation 'values: outcome 2 re-asks without the map, so an input can be taken twice' `
    'install.ps1' 'monitor-check.tests.ps1' `
    '                -Default $Answer.Map[$This] -Taken $taken -Method $Answer.Method `' `
    '                -Default $Answer.Map[$This] -Method $Answer.Method `'

# --- the typed fallback --------------------------------------------------------

Invoke-Mutation 'menus: q is dead on the top menu in the typed fallback' `
    'install.ps1' 'menus.tests.ps1' `
    '            if ($EscapeTo -ge 0 -and $pick -eq ''q'' -and $sel -contains $EscapeTo) {
                $Default = $EscapeTo
                continue
            }' ''
Invoke-Mutation 'menus: q on the top menu chooses Cancel outright' `
    'install.ps1' 'menus.tests.ps1' `
    '                $Default = $EscapeTo
                continue' '                return $EscapeTo'
Invoke-Mutation 'menus: q moves the cursor onto a disabled row' `
    'install.ps1' 'menus.tests.ps1' `
    "            if (`$EscapeTo -ge 0 -and `$pick -eq 'q' -and `$sel -contains `$EscapeTo) {" `
    "            if (`$EscapeTo -ge 0 -and `$pick -eq 'q') {"

# --- the service channel says what it is --------------------------------------

Invoke-Mutation 'safety: the method chooser does not name the consequence' `
    'install.ps1' 'walkthrough.tests.ps1' `
    "    Write-Host ('  {0}''s own method talks to a service channel on the monitor. It is' -f `$d.What)" ''
Invoke-Mutation 'safety: typing onto a manufacturer channel is not warned about' `
    'install.ps1' 'walkthrough.tests.ps1' `
    '            if ($Method -ne ''standard'') {' '            if ($false) {'
Invoke-Mutation 'safety: the warning is shown on the standard channel too' `
    'install.ps1' 'walkthrough.tests.ps1' `
    '            if ($Method -ne ''standard'') {' '            if ($true) {'

# --- the checks --------------------------------------------------------------

Invoke-Mutation 'checks: backing out of a check reads as a failure' `
    'install.ps1' 'walkthrough.tests.ps1' `
    '            elseif (-not $ranDisplays.Ok -and -not $ranDisplays.Backed) { 1 }' `
    '            elseif (-not $ranDisplays.Ok) { 1 }'
Invoke-Mutation 'checks: a real failure no longer lands on its setting' `
    'install.ps1' 'walkthrough.tests.ps1' `
    '            elseif (-not $ranDisplays.Ok -and -not $ranDisplays.Backed) { 1 }' ''

# --- hand edits survive ---------------------------------------------------------

Invoke-Mutation 'config: an unknown key is dropped on Save' `
    'install.ps1' 'walkthrough.tests.ps1' `
    '    $carried = @(Get-CarriedKeys -Existing $Existing -Displays $Displays)' `
    '    $carried = @()'
Invoke-Mutation 'config: an unmanaged panel''s keys are kept anyway' `
    'install.ps1' 'walkthrough.tests.ps1' `
    '            if ($managed -notcontains $Matches[1]) { continue }' ''
Invoke-Mutation 'config: a superseded key name is carried beside the new one' `
    'install.ps1' 'walkthrough.tests.ps1' `
    '        if ($RENAMED_KEYS.Contains($k)) { continue }' ''

# --- names -------------------------------------------------------------------

Invoke-Mutation 'names: two monitors may share one short name' `
    'install.ps1' 'walkthrough.tests.ps1' `
    "                       -Taken `$Labels -Noun 'monitor'" `
    "                       -Noun 'monitor'"
Invoke-Mutation 'names: a panel clashes with its own short name' `
    'install.ps1' 'walkthrough.tests.ps1' `
    '        $others = @($out | Where-Object { $_.Key -ne $key } | ForEach-Object { $_.Label })' `
    '        $others = @($out | ForEach-Object { $_.Label })'
Invoke-Mutation 'names: the short name is mangled instead of asked about' `
    'install.ps1' 'walkthrough.tests.ps1' `
    "    `$label = Read-Name -Prompt 'Short name for it' -Default `$defaultLabel ``
                       -Taken `$Labels -Noun 'monitor'" `
    "    `$label = Read-Default '  Short name for it' `$defaultLabel
    `$label = (`$label -replace '[^A-Za-z0-9_-]', '').ToLower()
    if (-not `$label) { `$label = `$defaultLabel }"
Invoke-Mutation 'names: a duplicate is accepted rather than refused' `
    'install.ps1' 'walkthrough.tests.ps1' `
    '        if ($Taken -contains $n) {' '        if ($false) {'
Invoke-Mutation 'names: an underscore survives the character rule' `
    'install.ps1' 'walkthrough.tests.ps1' `
    "    `$n = `$n -replace '[\s._]+', '-'          # spaces, dots and underscores separate" `
    "    `$n = `$n -replace '[\s.]+', '-'"

# --- the trigger check stands the watcher down --------------------------------

Invoke-Mutation 'trigger check: it runs with no devices chosen' `
    'install.ps1' 'trigger-check.tests.ps1' `
    '    if (@($Devices).Count -eq 0) {' '    if ($false) {'
Invoke-Mutation 'trigger check: the live watcher fires alongside the one-shot' `
    'install.ps1' 'trigger-check.tests.ps1' `
    "        'can' {
            Suspend-Watcher" `
    "        'can' {"
Invoke-Mutation 'trigger check: the watcher is left disabled afterwards' `
    'install.ps1' 'trigger-check.tests.ps1' `
    '        if ($paused) { Resume-Watcher }' ''
Invoke-Mutation 'trigger check: an admin-owned watcher is disabled anyway' `
    'install.ps1' 'trigger-check.tests.ps1' `
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
    "        Deny-Startup (""trigger.device entry '{0}' is not a device; expected usb:VVVV:PPPP (or bare VVVV:PPPP) or bt:AAAAAAAAAAAA"" -f `$t)" `
    "        throw ""bad -Device '`$t'"""
Invoke-Mutation 'detector: whitespace inside a device entry is accepted' `
    'event-watch.ps1' 'detector.tests.ps1' `
    "    if (`$t -match '^(?:[Uu][Ss][Bb]:)?([0-9A-Fa-f]{4}):([0-9A-Fa-f]{4})`$') {" `
    "    if (`$t -match '^(?:[Uu][Ss][Bb]:)?([0-9A-Fa-f]{4})\s*:\s*([0-9A-Fa-f]{4})`$') {"
Invoke-Mutation 'detector: settle asks whether ANY watched device is present' `
    'event-watch.ps1' 'detector.tests.ps1' `
    '        $stillHere = @($arrived | Where-Object { $present[$_] })' `
    '        $stillHere = @($watch | Where-Object { $present[$_.Key] })'
Invoke-Mutation 'detector: an empty device list arms and watches nothing' `
    'event-watch.ps1' 'detector.tests.ps1' `
    "if (`$watch.Count -eq 0) {
    Deny-Startup 'no devices to watch -- run: trigger-kvm configure'
}" ''

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
    'install.ps1' 'elevation.tests.ps1' `
    "    Write-Log 'falling back to starting at login.'" `
    "    Write-Log 'nothing was changed.'; return 's4u'"
Invoke-Mutation 'tier: the fallback does not record what was installed' `
    'install.ps1' 'elevation.tests.ps1' `
    "    Set-ConfigValue -Path `$CONFIG -Key 'install.autostart' -Value 'login'" ''
Invoke-Mutation 'tier: the From boot row is offered to an account that cannot elevate' `
    'install.ps1' 'walkthrough.tests.ps1' `
    '    if (-not $canElevate) { $off += 0 }' ''
Invoke-Mutation 'tier: the row is hidden instead of disabled' `
    'install.ps1' 'walkthrough.tests.ps1' `
    "          else             { 'needs an administrator account' }),"  `
    "          else             { 'not available here' }),"

# --- the monitors list --------------------------------------------------------

Invoke-Mutation 'monitors: the list disables a row it does not own' `
    'install.ps1' 'walkthrough.tests.ps1' `
    '        $pick = Select-One -Items $items -Detail $detail -Default $land -Escapable' `
    '        $pick = Select-One -Items $items -Detail $detail -Default $land -Disabled $off -Escapable'

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
