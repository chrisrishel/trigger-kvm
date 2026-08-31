<#
.SYNOPSIS
Install and manage trigger-kvm on Windows.

.DESCRIPTION
BOOTSTRAP, run from the source tree. This is what installing IS:

    .\install.ps1                  copy files, register the task, start it
                                   no config yet? -> runs `configure` for you

Afterwards it is one command from anywhere (add -AddToPath, or use the full path):

    trigger-kvm configure          interactive; current settings pre-fill the
                                   defaults, and it applies what you changed
    trigger-kvm status             tier, coverage, version, what is configured
    trigger-kvm discover           what is attached, in the form the config wants
    trigger-kvm restart            make a hand-edited config take effect now
    trigger-kvm logs               tail the log
    trigger-kvm pause              stand the watcher down to test one by hand
    trigger-kvm uninstall

THERE IS NO `install` VERB ON THE CLI, deliberately: installing is what got you
the CLI. Upgrading and repairing both mean "fetch the source and run its
installer", which the self-contained install makes coherent -- this script copies
itself, so managing and removing work after the source tree is gone.

AND NO `apply` STEP EITHER. It used to be needed because trigger settings were
baked into the task's command line, so every config edit required re-registering
the task. The watcher now reads the config itself, so the task action carries no
configuration at all and edits take effect when it next starts. `configure`
restarts it for you; `restart` is there for hand-edits.

VERBS, and the same verbs on macOS. You use both machines daily, so the words you
type constantly are where cross-platform muscle memory is worth buying. Flags stay
idiomatic per platform (-Tier here, --tier there): forcing `--tier` into PowerShell
means hand-parsing $args and losing parameter binding, validation and completion,
which is a real cost for a cosmetic gain.

TWO TIERS, recorded in the config as install.tier, and you pick by what you are
willing to grant:

  user (default)  Runs at logon, in your interactive session, unelevated.
                  NO ADMIN, at install or at run time.
                  Covers everything from logon onward -- including while the
                  screen is LOCKED, since the session and watcher stay alive.
                  Does not cover: before the first login after a boot, or after
                  a full logoff.

  s4u             Runs at startup, in session 0, as you, still UNELEVATED.
                  ADMIN ONCE, to register the task -- prompted for via UAC.
                  Nothing elevated runs on the switch path afterwards.
                  Adds: before-first-login and after-logoff.

The tiers are mutually exclusive by construction -- they share one task name, so
installing either replaces the other. Two live watchers in different sessions
would both fire on the same arrival, and the debounce is per-process, so it
cannot dedupe across them. event-watch.ps1 also takes a machine-wide mutex as
defence in depth.

The tier is a property of the HOST, not of the switcher. Nothing in
trigger-kvm.ps1 or event-watch.ps1 knows or asks which tier it runs under. If
either ever needs to, the abstraction is wrong -- stop and rethink.

Why s4u is possible at all: measured 2026-08-30, NVAPI both enumerates and
WRITES from session 0 with no desktop -- an unelevated S4U task moved the LG in
both directions, confirmed visually. The old blocker was dxva2 needing an
HMONITOR, and that path no longer exists. See ..\ARCHITECTURE.md.

No third-party binary and no network access: both monitors are driven by code in
this repo.
#>

[CmdletBinding()]
param(
    # 'install' is the default and is NOT offered on the CLI shim -- it is what
    # running this script from the source tree means.
    [Parameter(Position = 0)]
    [ValidateSet('install', 'configure', 'status', 'discover', 'restart', 'logs', 'pause', 'uninstall')]
    [string]$Command = 'install',

    # Overrides install.tier from the config, for scripted installs. Normally the
    # tier is a configured value like everything else machine-local, so that
    # `configure` can ask about it and the installer just applies what it finds.
    [ValidateSet('user', 's4u')]
    [string]$Tier,

    # Put the install directory on the user PATH so `trigger-kvm` works anywhere.
    # Opt-in: editing someone's PATH without asking is rude, and the interactive
    # setup will ask properly once it exists.
    [switch]$AddToPath,

    # Never show a UAC prompt; print what to run instead and exit non-zero. For
    # scripted installs, where a modal dialog on a headless run is a hang, not a
    # prompt.
    [switch]$NoElevate,

    # Set only on the elevated relaunch, to stop an elevation that does not take
    # from looping UAC prompts forever. Not for humans.
    [switch]$Relaunched
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TASK    = 'trigger-kvm'
$DEST    = Join-Path $env:LOCALAPPDATA 'Programs\trigger-kvm'
$LOG     = Join-Path $env:LOCALAPPDATA 'trigger-kvm\trigger-kvm.log'
$WATCH   = Join-Path $DEST 'event-watch.ps1'
$SWITCH  = Join-Path $DEST 'trigger-kvm.ps1'
$LGEXE   = Join-Path $DEST 'lg-input-switch.exe'   # legacy; removed on install/uninstall
$VBS     = Join-Path $DEST 'launcher.vbs'
$MANAGE  = Join-Path $DEST 'install.ps1'      # this script, installed alongside
# ONLY this directory goes on PATH, and it contains ONLY the shim.
#
# Putting $DEST on PATH would publish every file in it as a command, because PATHEXT
# includes .VBS -- measured: `launcher.vbs` resolves as a bare `launcher`, a generic
# name that starts the watcher. The .ps1 files are safe only by DEFAULT; anyone who
# has added .PS1 to PATHEXT would also get `install` and `config` as global
# commands. A bin directory with one file in it cannot do any of that.
$BINDIR  = Join-Path $DEST 'bin'
$SHIM    = Join-Path $BINDIR 'trigger-kvm.cmd'

# The shim used to live in $DEST, which meant $DEST went on PATH. Both are cleaned
# up on install so an earlier install stops polluting.
$OLD_SHIM = Join-Path $DEST 'trigger-kvm.cmd'
$STAMP   = Join-Path $DEST 'version.txt'
$CFGLIB  = Join-Path $DEST 'config.ps1'        # shared reader, dot-sourced by all three

# Files a previous version of THIS layout installed under names no longer used.
# Remove-LegacyInstall handles the pre-rename DIRECTORY; these are leftovers inside
# the current one, which nothing else would ever clean up.
$STALE = @(
    (Join-Path $DEST 'usb-watch.ps1')         # renamed to event-watch.ps1
)

# This project was called display-switch until 2026-08-30, and was renamed to avoid
# collision with haimgel/display-switch, a well-established project of that exact
# name. An install predating the rename left a task, a program directory and a log
# under the old name, and its watcher holds the OLD mutex -- so leaving it in place
# would mean two watchers both firing on every arrival. Removed on install and on
# uninstall. Delete this block once no machine can plausibly still have one.
$OLD_TASK = 'display-switch'
$OLD_DEST = Join-Path $env:LOCALAPPDATA 'Programs\display-switch'
$OLD_LOG  = Join-Path $env:LOCALAPPDATA 'display-switch\displayswitch.log'

# Machine-local configuration. Generated here, then read by trigger-kvm.ps1 at every
# switch. Lives beside the log rather than in $DEST, so that uninstalling does not
# throw away a configuration you spent time getting right -- same reasoning as
# leaving the log in place.
$CONFIG = Join-Path (Split-Path $LOG) 'config'

# Recorded at install time and shown by `status`. Not an updater -- updating is
# "fetch the new source, run setup" -- but it answers the question that actually
# bites: is what is installed what I think it is?
$VERSION = '0.2.0'

# Seed values, used ONLY when generating a config that does not exist yet. Once the
# file is written it is the source of truth and these are never consulted again --
# so editing the config is how you change things, not editing this.
$SEED_DEVICES  = '046d:0843,1235:820a'
$SEED_DEBOUNCE = '3.0'
$SEED_SETTLE   = '0.75'

function Write-Log { param([string]$m) Write-Host "install: $m" }

# --- the effective tier ------------------------------------------------------

# Config is the source of truth; -Tier overrides it for scripted installs and is
# what `configure` writes back. Resolved once, here, so every later decision --
# whether to elevate, which principal to register, what status reports -- reads the
# same answer.
function Get-EffectiveTier {
    if ($PSBoundParameters.ContainsKey('Tier') -and $Tier) { return $Tier }
    $c = Read-Config -Path (Get-ConfigPath)
    if ($c.ContainsKey('install.tier') -and $c['install.tier'] -in @('user', 's4u')) { return $c['install.tier'] }
    return 'user'
}

# --- elevation --------------------------------------------------------------

$IsElevated = ([Security.Principal.WindowsPrincipal] `
               [Security.Principal.WindowsIdentity]::GetCurrent()
              ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Re-run this script elevated, wait for it, and print what it did.
#
# Two things make this worth doing rather than telling the user to open an admin
# terminal. The s4u tier CANNOT be registered without elevation, so the alternative
# is a dead end mid-install. And the admin-owned task it leaves behind means
# UNINSTALL needs elevation too -- so a prompt on the way in without one on the way
# out would trap people in a tier they cannot remove.
#
# The elevated child writes to a temp file and the parent prints it, because
# -Verb RunAs cannot be combined with -RedirectStandardOutput: without this the
# output would land in a window that closes before it can be read.
function Request-Elevation {
    param([string[]]$ChildArgs)

    if ($Relaunched) {
        # We already asked and came back still unelevated. Something is refusing
        # (policy, or an account with no admin rights available). Do not prompt
        # again -- an elevation loop is far worse than a clear failure.
        Write-Log 'still not elevated after relaunching; not asking again.'
        return 1
    }
    if ($NoElevate) {
        Write-Log 'elevation required, and -NoElevate was given.'
        Write-Host ''
        Write-Host ("Run this from an elevated PowerShell:  {0} {1}" -f $PSCommandPath, ($ChildArgs -join ' '))
        return 1
    }

    $transcript = Join-Path ([IO.Path]::GetTempPath()) ("trigger-kvm-elevated-{0}.log" -f [Guid]::NewGuid().ToString('N').Substring(0,8))
    $inner = "& '{0}' {1} -Relaunched *> '{2}'" -f $PSCommandPath, ($ChildArgs -join ' '), $transcript

    Write-Log 'this needs administrator rights; approving the UAC prompt will continue.'
    try {
        $p = Start-Process powershell.exe -Verb RunAs -Wait -WindowStyle Hidden -PassThru `
             -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $inner)
    } catch {
        # The user declined the prompt, or no admin credentials were available.
        Write-Log 'elevation was declined or unavailable; nothing was changed.'
        return 1
    }

    if (Test-Path -LiteralPath $transcript) {
        Get-Content -LiteralPath $transcript | ForEach-Object { Write-Host $_ }
        Remove-Item -LiteralPath $transcript -Force -ErrorAction SilentlyContinue
    }
    return $p.ExitCode
}

# --- PATH -------------------------------------------------------------------

# User PATH only -- never the machine one. This installs per-user and needs no
# admin, and quietly editing a system-wide setting would be a much bigger thing
# than the user agreed to.
function Get-UserPath { [Environment]::GetEnvironmentVariable('Path', 'User') }

function Add-ToUserPath {
    param([string]$Dir)
    $cur = Get-UserPath
    $parts = @(($cur -split ';') | Where-Object { $_ })
    if ($parts -contains $Dir) { Write-Log "already on PATH: $Dir"; return }
    [Environment]::SetEnvironmentVariable('Path', (@($parts + $Dir) -join ';'), 'User')
    Write-Log "added to your PATH: $Dir"
    Write-Log 'open a NEW terminal for that to take effect'
}

function Remove-FromUserPath {
    param([string]$Dir)
    $cur = Get-UserPath
    $parts = @(($cur -split ';') | Where-Object { $_ })
    if ($parts -notcontains $Dir) { return }
    [Environment]::SetEnvironmentVariable('Path', (@($parts | Where-Object { $_ -ne $Dir }) -join ';'), 'User')
    Write-Log "removed from your PATH: $Dir"
}

# --- configuration ----------------------------------------------------------

# Shared config reader. Dot-sourced rather than duplicated: three consumers parsing
# the same format independently is a drift risk where the watcher and the switcher
# could silently disagree about what is configured.
. (Join-Path $PSScriptRoot 'config.ps1')

# Update ONE key in place, preserving comments, order and every other line.
#
# Rewriting the whole file from a hashtable would be simpler and would silently
# destroy the comments -- which are most of the file, and are where the traps are
# documented. A config you cannot safely round-trip is one people stop hand-editing.
function Set-ConfigValue {
    param([string]$Path, [string]$Key, [string]$Value)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $lines = @(Get-Content -LiteralPath $Path)
    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $hit = $false
    $out = foreach ($l in $lines) {
        if ($l -match $pattern) { $hit = $true; ('{0} = {1}' -f $Key, $Value) } else { $l }
    }
    if (-not $hit) { $out = @($out) + @('', ('{0} = {1}' -f $Key, $Value)) }
    $out | Set-Content -LiteralPath $Path -Encoding ASCII
}

# Write a starter config, once. Never overwrites: re-running the installer must not
# silently discard hand edits, and re-runnability is the whole point of the file
# living outside $DEST.
#
# The display entries below are this desk's measured values. Interactive discovery
# replaces this seeding -- until then, a different machine must edit the file.
function New-DefaultConfig {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Write-Log "config already present, left untouched: $Path"
        return
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    @(
        '# trigger-kvm configuration'
        '#'
        '# Generated by install.ps1. Safe to edit by hand -- re-running the installer'
        '# will NOT overwrite this file.'
        '#'
        '# Everything here is read at the point it is used, so there is no separate'
        '# apply step: display and scene edits take effect on the next switch, and'
        '# trigger edits when the watcher next starts --  trigger-kvm restart'
        '#'
        '# Displays are identified by the EDID the GPU reads off the output, never by'
        '# index -- \\.\DISPLAYn numbers are not stable and have swapped on this'
        '# machine. Find yours with:  .\nvapi-probe.ps1'
        ''
        '# --- install ----------------------------------------------------------'
        '# tier: user (no admin, from logon onward incl. locked)'
        '#       s4u  (admin ONCE to register; adds before-first-login and logoff)'
        ''
        'install.tier = user'
        ''
        '# --- displays ---------------------------------------------------------'
        '# method: standard (I2C src 0x51, VCP 0x60) | lg-alt (src 0x50, VCP 0xF4)'
        '# self:   the input value where THIS machine is. Required.'
        ''
        'display.lg.vendor  = 0x1E6D'
        'display.lg.product = 0x9E9D'
        'display.lg.name    = LG 45GX950A'
        'display.lg.method  = lg-alt'
        'display.lg.self    = 0xD0'
        ''
        'display.asus.vendor  = 0x06B3'
        'display.asus.product = 0x42E0'
        'display.asus.name    = ASUS PG42UQ'
        'display.asus.method  = standard'
        'display.asus.self    = 0x11'
        ''
        '# --- triggers ---------------------------------------------------------'
        '#'
        '# A trigger is anything that runs:  trigger-kvm.ps1 pull'
        '# The one shipped here watches USB device presence. A hotkey, a Stream Deck'
        '# button or a scheduled task needs no support from this tool -- it just runs'
        '# that command.'
        '#'
        '# Triggers run `pull` and nothing else. Never wire one to a scene: a scene'
        '# names inputs on hardware this machine cannot see, and a stale one would'
        '# then be able to cause an AUTOMATIC switch to a dead input.'
        '#'
        '# device:   comma-separated. Each entry is one of:'
        '#             usb:VVVV:PPPP    a USB vendor+product pair'
        '#             VVVV:PPPP        the same thing; bare means usb'
        '#             bt:AAAAAAAAAAAA  a Bluetooth address, 12 hex digits'
        '#           Match the FULL USB vendor+product -- a vendor-only match fires'
        '#           constantly, because the keyboard and mouse share a vendor id'
        '#           with the webcam and never move.'
        '#           Bluetooth matches on CONNECTED, not paired: a paired device'
        '#           keeps its PnP node for years, so paired-ness never has an edge.'
        '#           Find both with:  .\install.ps1 -Discover'
        '# debounce: applies to every trigger. One window has to cover all of them,'
        '#           since two could not dedupe against each other.'
        ''
        "trigger.device   = $SEED_DEVICES"
        "trigger.debounce = $SEED_DEBOUNCE"
        "trigger.settle   = $SEED_SETTLE"
        ''
        '# --- scenes -----------------------------------------------------------'
        '# Saved arrangements for MANUAL use:  trigger-kvm.ps1 to mac'
        '#'
        '# The trigger never reads these, by any path. That is deliberate: a scene'
        '# names inputs on ANOTHER machine, which this machine cannot observe and'
        '# which go stale the moment someone moves a cable over there. Keeping them'
        '# out of the trigger means a stale scene can only ever spoil a command you'
        '# typed and are watching -- never an automatic switch.'
        ''
        'scene.mac.lg   = 0xD1'
        'scene.mac.asus = 0x0F'
    ) | Set-Content -LiteralPath $Path -Encoding ASCII
    Write-Log "wrote starter config: $Path"
}

# Matches BOTH event-watch.ps1 and the pre-rename usb-watch.ps1 on purpose: a
# surviving old watcher would hold its own debounce clock and fire alongside the new
# one on every arrival. Drop the 'usb' alternative once no machine can still be
# running one.
#
# Stopping the task kills its launcher but NOT the powershell watcher underneath,
# which is a grandchild and outlives it. Left behind, a stale watcher keeps holding
# the single-instance mutex and the newly installed one exits immediately -- so an
# upgrade would silently keep running the old code. Clear them explicitly.
function Stop-Watchers {
    $procs = Get-CimInstance Win32_Process -Property ProcessId,Name,CommandLine -Verbose:$false |
        Where-Object {
            $_.CommandLine -and (
                ($_.Name -eq 'wscript.exe'    -and $_.CommandLine -match 'launcher\.vbs') -or
                ($_.Name -eq 'powershell.exe' -and $_.CommandLine -match '(usb|event)-watch\.ps1')
            )
        }
    foreach ($p in $procs) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Log ("stopped stale {0} (pid {1})" -f $p.Name, $p.ProcessId)
    }
}

# Remove what a pre-rename install left behind. Stop-Watchers above already kills
# the old watcher process (its regex matches both watcher names),
# which is what releases the old mutex.
function Remove-LegacyInstall {
    if (Get-ScheduledTask -TaskName $OLD_TASK -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $OLD_TASK -ErrorAction SilentlyContinue
        try {
            Unregister-ScheduledTask -TaskName $OLD_TASK -Confirm:$false -ErrorAction Stop
            Write-Log "removed the pre-rename task '$OLD_TASK'"
        } catch {
            # An s4u/system-principal task registered by an admin needs an admin to
            # remove. Say so rather than leaving a second watcher running unexplained.
            Write-Log ("WARNING: could not remove the old task '{0}': {1}" -f $OLD_TASK, $_.Exception.Message)
            Write-Log 'Re-run this elevated, or two watchers may both fire on each arrival.'
        }
    }
    if (Test-Path -LiteralPath $OLD_DEST) {
        Remove-Item -LiteralPath $OLD_DEST -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "removed the pre-rename program directory $OLD_DEST"
    }
    # The old log is the only record of what happened before the rename, so it is
    # moved rather than deleted -- the same reason uninstall leaves logs alone.
    if ((Test-Path -LiteralPath $OLD_LOG) -and -not (Test-Path -LiteralPath "$LOG.pre-rename")) {
        New-Item -ItemType Directory -Force -Path (Split-Path $LOG) | Out-Null
        Move-Item -LiteralPath $OLD_LOG -Destination "$LOG.pre-rename" -Force -ErrorAction SilentlyContinue
        Write-Log "kept the pre-rename log as $LOG.pre-rename"
    }
}

# --- configure ---------------------------------------------------------------

# Researched, cross-machine knowledge: which method a monitor MODEL needs and which
# input values it accepts. Mirrors ..\displays.toml, which is the human-readable
# source of truth -- if you add a model, add it there too and say how it was
# verified.
#
# This is the gate on the manufacturer sidechannel. A panel absent from this table
# is offered STANDARD DDC/CI only, never `lg-alt`, because what source 0x50 means on
# an untested panel is unknown and sweeping it has bricked monitors. See AGENTS.md
# hard rule 1.
$KNOWN_MONITORS = @{
    '1E6D:9E9D' = @{
        Name   = 'LG 45GX950A'
        Method = 'lg-alt'
        # Per-INPUT product id on this panel: 0x9e9d is what a host sees on its own
        # DisplayPort connection. Never copy it between hosts.
        Inputs = [ordered]@{ 'DisplayPort' = '0xD0'; 'USB-C' = '0xD1'; 'HDMI 1' = '0x90'; 'HDMI 2' = '0x91' }
    }
    '06B3:42E0' = @{
        Name   = 'ASUS PG42UQ'
        Method = 'standard'
        Inputs = [ordered]@{ 'HDMI 1' = '0x11'; 'HDMI 2' = '0x12'; 'DisplayPort' = '0x0F' }
    }
}

# Published MCCS values for VCP 0x60, offered for any panel we have no entry for.
# A labelled list the user picks from, one at a time -- NOT a sweep. Trying a
# documented value on the documented input-select code is ordinary operation;
# walking a range to see what happens is what the hard rule forbids.
$MCCS_INPUTS = [ordered]@{
    'DisplayPort 1' = '0x0F'
    'DisplayPort 2' = '0x10'
    'HDMI 1'        = '0x11'
    'HDMI 2'        = '0x12'
    'DVI 1'         = '0x03'
    'DVI 2'         = '0x04'
    'VGA 1'         = '0x01'
    'USB-C'         = '0x1B'
}

# Can we actually hold a conversation? A prompt in a non-interactive context is a
# hang, not a question -- and the elevated relaunch runs in a HIDDEN window, so
# getting this wrong means an install that appears to freeze with no way to see why.
function Test-CanPrompt {
    return ([Environment]::UserInteractive -and -not $Relaunched -and -not [Console]::IsInputRedirected)
}

function Read-Default {
    param([string]$Prompt, [string]$Default)
    $shown = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    $answer = Read-Host $shown
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

# Arrow up/down to move, space to toggle, enter to accept.
#
# Falls back to a typed list when the host cannot read individual keys -- a
# redirected stdin, a non-console host, anything that is not a real terminal. The
# fallback is not a nicety: it is what makes this testable, and what keeps the
# installer usable over a remote session that does not forward key events.
function Select-Many {
    param([string[]]$Items, [string[]]$Detail, [int[]]$Checked = @(), [string]$Help)

    $canKeys = $true
    try { $null = [Console]::KeyAvailable } catch { $canKeys = $false }
    if ([Console]::IsInputRedirected) { $canKeys = $false }

    $state = @($Items | ForEach-Object { $false })
    foreach ($i in $Checked) { if ($i -ge 0 -and $i -lt $state.Count) { $state[$i] = $true } }

    if (-not $canKeys) {
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $mark = if ($state[$i]) { '*' } else { ' ' }
            Write-Host ('  {0}{1,3}) {2}  {3}' -f $mark, ($i + 1), $Items[$i], $Detail[$i])
        }
        if ($Help) { Write-Host ''; Write-Host $Help }
        $pre = @()
        for ($i = 0; $i -lt $state.Count; $i++) { if ($state[$i]) { $pre += ($i + 1) } }
        while ($true) {
            $pick = Read-Default '  Numbers, comma-separated' ($pre -join ',')
            $out = @()
            foreach ($n in ($pick -split ',')) {
                $n = $n.Trim()
                if ($n -match '^[0-9]+$' -and [int]$n -ge 1 -and [int]$n -le $Items.Count) { $out += ([int]$n - 1) }
            }
            if ($out.Count -gt 0) { return $out }
            Write-Host '  Pick at least one.'
        }
    }

    # Every iteration draws exactly this many lines, so the redraw can walk back up
    # by the same count. $Help is a multi-line string, and the note line is always
    # drawn (blank when there is nothing to say) -- both were off-by-N bugs waiting
    # to happen if the height were inferred rather than counted.
    $helpBody  = @($Help -split "`r?`n")
    $helpLines = if ($Help) { 1 + $helpBody.Count } else { 0 }
    $drawn     = $Items.Count + $helpLines + 2

    $width = 100
    try { $width = [Math]::Max(40, [Math]::Min(110, [Console]::WindowWidth - 1)) } catch { }

    $cursor = 0
    $note   = ''
    $first  = $true
    while ($true) {
        if (-not $first) {
            try { [Console]::SetCursorPosition(0, [Math]::Max(0, [Console]::CursorTop - $drawn)) } catch { }
        }
        $first = $false

        for ($i = 0; $i -lt $Items.Count; $i++) {
            $mark = if ($state[$i]) { '[x]' } else { '[ ]' }
            $arrow = if ($i -eq $cursor) { '>' } else { ' ' }
            $line = '{0} {1} {2}  {3}' -f $arrow, $mark, $Items[$i], $Detail[$i]
            # Pad to overwrite the previous frame; truncate so a long name cannot
            # wrap and silently add a line to the block.
            if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }
            Write-Host $line.PadRight($width)
        }
        if ($Help) {
            Write-Host ''
            foreach ($h in $helpBody) { Write-Host $h.PadRight($width) }
        }
        Write-Host '  up/down move   space toggle   enter accept'
        Write-Host $note.PadRight($width)

        $k = [Console]::ReadKey($true)
        $note = ''
        switch ($k.Key) {
            'UpArrow'   { $cursor = ($cursor - 1 + $Items.Count) % $Items.Count }
            'DownArrow' { $cursor = ($cursor + 1) % $Items.Count }
            'Spacebar'  { $state[$cursor] = -not $state[$cursor] }
            'Enter'     {
                $out = @()
                for ($i = 0; $i -lt $state.Count; $i++) { if ($state[$i]) { $out += $i } }
                if ($out.Count -gt 0) { Write-Host ''; return $out }
                $note = '  Pick at least one (space toggles the highlighted row).'
            }
        }
    }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $a = (Read-Host "$Prompt [$hint]").Trim().ToLower()
        if (-not $a) { return $Default }
        if ($a -in @('y', 'yes')) { return $true }
        if ($a -in @('n', 'no'))  { return $false }
    }
}

# Switch one display to a candidate input, hold, bring it BACK automatically, and
# only then ask.
#
# The return is what makes this safe to run against the display you are reading:
# the question always arrives on a panel that has already come back, so the
# installer never needs to know which monitor its own window is on, and a wrong
# guess costs a few seconds of black rather than a stranded session. Confirming
# visually is the only verification this hardware permits -- reads lie on both
# panels here (AGENTS.md hard rule 2).
function Test-DisplayInput {
    param([string]$Label, [string]$Name, [string]$Candidate, [string]$CandidateName,
          [string]$Current, [int]$Hold = 8)

    $sw = Join-Path $PSScriptRoot 'trigger-kvm.ps1'
    if (-not (Test-Path $sw)) { $sw = $SWITCH }

    Write-Host ''
    Write-Host ("  Switching $Name to $CandidateName for ${Hold}s, then back automatically.")
    Write-Host '  Watch that monitor. It only has to CHANGE -- if nothing is plugged into'
    Write-Host '  that input it will say No Signal, and that still proves the switch worked.'
    & $sw set -Only $Label -Value $Candidate -Config $CONFIG | Out-Null
    Start-Sleep -Seconds $Hold
    if ($Current) { & $sw set -Only $Label -Value $Current -Config $CONFIG | Out-Null; Start-Sleep -Seconds 2 }
    Write-Host ''
    return (Read-YesNo "  Did $Name change at all (a picture, or No Signal)?" $true)
}

# One display: identity is already known from NVAPI; what we need from the human is
# whether to manage it, what to call it, and which input THIS machine is on.
function Get-DisplayAnswers {
    # $Existing is a PSCustomObject or $null -- deliberately untyped, because a
    # [hashtable] annotation here silently accepted the call at parse time and threw
    # a transformation error at RUN time, i.e. mid-walkthrough.
    param($Found, $Existing)

    $key   = '{0:X4}:{1:X4}' -f $Found.EdidVendor, $Found.EdidProduct
    $known = $KNOWN_MONITORS[$key]
    $desc  = if ($known) { $known.Name } else { ('{0} panel {1}' -f $Found.Mfg, $key) }

    Write-Host ''
    Write-Host ('  {0}   EDID {1}   {2}' -f $desc, $key, $Found.Connector)
    if (-not $known) {
        Write-Host '  Not in the known-monitor list, so only standard DDC/CI is offered.'
    }

    $default = if ($Existing) { $Existing.Label } else { ($desc -split ' ')[0].ToLower() }
    if (-not (Read-YesNo '  Manage this monitor?' $true)) { return $null }

    $label = Read-Default '  Short name for it' $default
    $label = ($label -replace '[^A-Za-z0-9_-]', '').ToLower()
    if (-not $label) { $label = $default }

    $method = if ($known) { $known.Method } else { 'standard' }
    $table  = if ($known) { $known.Inputs } else { $MCCS_INPUTS }

    Write-Host ''
    Write-Host ('  On the {0} itself, which input shows THIS PC?' -f $desc)
    Write-Host '  (the input you would pick on the monitor to see this computer)'
    $names = @($table.Keys)
    for ($i = 0; $i -lt $names.Count; $i++) {
        Write-Host ('    {0}) {1,-16} {2}' -f ($i + 1), $names[$i], $table[$names[$i]])
    }
    Write-Host '    t) type a value'

    # Pre-fill with the configured value's row, so enter-through keeps it. A
    # re-run should be a review, not a re-entry.
    $defaultPick = ''
    if ($Existing -and $Existing.Self) {
        for ($i = 0; $i -lt $names.Count; $i++) {
            if ($table[$names[$i]] -ieq $Existing.Self) { $defaultPick = [string]($i + 1) }
        }
        if (-not $defaultPick) { $defaultPick = 't' }
    }

    $self = $null
    while (-not $self) {
        $pick = Read-Default '  Choice' $defaultPick
        if ($pick -eq 't') {
            $typed = Read-Default '  Value (e.g. 0x11)' $(if ($Existing) { $Existing.Self } else { '' })
            if ($typed -match '^(0[xX])?[0-9A-Fa-f]{1,2}$') { $self = $typed }
            else { Write-Host '  Not a byte.' }
        }
        elseif ($pick -match '^[0-9]+$' -and [int]$pick -ge 1 -and [int]$pick -le $names.Count) {
            $self = $table[$names[[int]$pick - 1]]
        }
        else { Write-Host '  Pick a number, or t.' }
    }

    return [PSCustomObject]@{
        Label = $label; Name = $desc; Method = $method
        Vendor = ('0x{0:X4}' -f $Found.EdidVendor); Product = ('0x{0:X4}' -f $Found.EdidProduct)
        Self = $self; Table = $table
    }
}

# Which devices travel with the switch. Returns the chosen keys.
function Read-Triggers {
    param($Cands, [string[]]$Current)

    Write-Host ''
    Write-Host '--- triggers ---'
    Write-Host 'Which devices move to this machine when you flip the switch?'
    Write-Host 'Everything below is attached or connected right now.'
    Write-Host ''

    $checked = @()
    for ($i = 0; $i -lt $Cands.Count; $i++) { if ($Current -contains $Cands[$i].Key) { $checked += $i } }

    $help = '  Keyboards and mice often share a vendor id with something that never' + "`n" +
            '  moves. The full vendor+product is matched, so pick the exact rows.'

    $picked = Select-Many -Checked $checked -Help $help `
        -Items  @($Cands | ForEach-Object { '{0,-20} {1,-4}' -f $_.Key, $_.Bus }) `
        -Detail @($Cands | ForEach-Object { $_.Name })

    return @($picked | ForEach-Object { $Cands[$_].Key })
}

# When the watcher should start running. Returns 'user' or 's4u'.
function Read-Tier {
    param([string]$Current)

    Write-Host ''
    Write-Host '--- when should it run? ---'
    Write-Host '  1) from logon onward, INCLUDING while locked        no admin'
    Write-Host '  2) from boot -- adds before-first-login and logoff  admin ONCE (UAC prompt)'
    Write-Host ''
    Write-Host '  Locking does not end your session, so 1 covers most days. 2 is for a'
    Write-Host '  rebooted PC sitting at a login screen you cannot see.'
    $pick = Read-Default '  Choice' $(if ($Current -eq 's4u') { '2' } else { '1' })
    return $(if ($pick -eq '2') { 's4u' } else { 'user' })
}

# Ask about every attached display, pre-filled from whatever the config already
# says about that EDID. A function rather than an inline loop because the review
# menu re-enters it: "the monitors" has to be revisitable as one unit.
function Get-AllDisplayAnswers {
    param($Found, [hashtable]$Existing)

    $out = @()
    foreach ($f in $Found) {
        $key = '{0:X4}:{1:X4}' -f $f.EdidVendor, $f.EdidProduct
        $prior = $null
        foreach ($k in $Existing.Keys) {
            if ($k -match '^display\.([^.]+)\.vendor$') {
                $l = $Matches[1]
                if (($Existing["display.$l.vendor"] -replace '^0[xX]','').ToUpper().PadLeft(4,'0') -eq $key.Split(':')[0] -and
                    ($Existing["display.$l.product"] -replace '^0[xX]','').ToUpper().PadLeft(4,'0') -eq $key.Split(':')[1]) {
                    $prior = [PSCustomObject]@{
                        Label = $l
                        Self  = $(if ($Existing.ContainsKey("display.$l.self")) { $Existing["display.$l.self"] } else { '' })
                    }
                }
            }
        }
        $a = Get-DisplayAnswers -Found $f -Existing $prior
        if ($a) { $out += $a }
    }
    return $out
}

# The walkthrough. Current settings pre-fill every default, so a re-run is a review
# rather than a replay.
#
# Nothing is written until every answer is in: an interrupted run must leave a
# working setup untouched, not a half-written config plus a task pointing at it.
function Invoke-Configure {
    if (-not (Test-CanPrompt)) {
        Write-Log 'configure needs an interactive terminal.'
        Write-Host ''
        Write-Host ("Edit the config directly instead:  {0}" -f $CONFIG)
        Write-Host 'Then:  trigger-kvm restart'
        $global:LASTEXITCODE = 2
        return
    }

    $existing = Read-Config -Path $CONFIG
    $isFirst  = -not (Test-Path -LiteralPath $CONFIG)

    Write-Host ''
    Write-Host '=============================================================='
    Write-Host $(if ($isFirst) { ' trigger-kvm setup' } else { ' trigger-kvm reconfigure' })
    Write-Host '=============================================================='
    if (-not $isFirst) {
        Write-Host ' Current settings are the defaults -- press enter to keep one.'
    }

    # ---- displays ----------------------------------------------------------
    $sw = Join-Path $PSScriptRoot 'trigger-kvm.ps1'
    if (-not (Test-Path $sw)) { $sw = $SWITCH }

    # -Raw, not the human table: that one is Write-Host, which never reaches the
    # pipeline, so parsing it would silently find nothing.
    $found = @()
    foreach ($line in (& $sw list -Raw -Config $CONFIG 2>$null)) {
        $f = "$line" -split '\|'
        if ($f.Count -ge 4) {
            $found += [PSCustomObject]@{
                EdidVendor  = [Convert]::ToInt32($f[0], 16)
                EdidProduct = [Convert]::ToInt32($f[1], 16)
                Mfg         = $f[2]
                Connector   = $f[3]
            }
        }
    }
    if ($found.Count -eq 0) {
        Write-Log 'no displays found on an NVIDIA GPU -- nothing to configure.'
        $global:LASTEXITCODE = 2
        return
    }

    Write-Host ''
    Write-Host ('--- displays ({0} connected) ---' -f $found.Count)

    $answers = @(Get-AllDisplayAnswers -Found $found -Existing $existing)

    if ($answers.Count -eq 0) {
        Write-Log 'no monitors selected -- nothing to do.'
        $global:LASTEXITCODE = 2
        return
    }

    # ---- triggers ----------------------------------------------------------
    $cands = @(Get-TriggerCandidates)
    $cur = @()
    if ($existing.ContainsKey('trigger.device')) {
        $cur = @(($existing['trigger.device'] -replace '\s','') -split ',' | Where-Object { $_ } | ForEach-Object {
            if ($_ -match '^(usb:|bt:)') { $_.ToLower() } else { 'usb:' + $_.ToLower() } })
    }
    $devices = @(Read-Triggers -Cands $cands -Current $cur)

    # ---- tier --------------------------------------------------------------
    $newTier = Read-Tier $(if ($existing.ContainsKey('install.tier')) { $existing['install.tier'] } else { 'user' })

    # ---- PATH --------------------------------------------------------------
    $onPath = @((Get-UserPath -split ';')) -contains $BINDIR
    $wantPath = $false
    if (-not $onPath) {
        Write-Host ''
        Write-Host '--- PATH ---'
        # Single quotes: in a DOUBLE-quoted PowerShell string a backtick is the escape
        # character, so "`trigger-kvm`" renders as TAB + "rigger-kvm".
        Write-Host ('  Add {0} to your PATH, so `trigger-kvm` works from anywhere?' -f $BINDIR)
        Write-Host '  Only that directory is added, and it holds only the launcher.'
        $wantPath = Read-YesNo '  Add it?' $true
    }

    # ---- review, then write ------------------------------------------------
    # A menu rather than a linear "go back one step": the answer you got wrong is
    # rarely the last one you gave, and unwinding four sections to fix the first is
    # worse than re-entering the one section that is wrong.
    while ($true) {
        Write-Host ''
        Write-Host '--- review ---'
        foreach ($a in $answers) {
            Write-Host ('    {0,-8} {1,-22} this PC is on {2}' -f $a.Label, $a.Name, $a.Self)
        }
        Write-Host ('    triggers {0}' -f ($devices -join ', '))
        Write-Host ('    starts   {0}' -f $(if ($newTier -eq 's4u') { 'at boot, before login' } else { 'when you log in' }))
        if (-not $onPath) { Write-Host ('    PATH     {0}' -f $(if ($wantPath) { 'add it' } else { 'leave it alone' })) }
        Write-Host ''
        $menu = '    w) write it   1) monitors   2) triggers   3) when it starts'
        if (-not $onPath) { $menu += '   p) PATH' }
        Write-Host ($menu + '   q) cancel')
        $go = (Read-Default '  Choice' 'w').ToLower()

        if ($go -eq 'w') { break }
        if ($go -eq 'q') {
            Write-Log 'cancelled; nothing was changed.'
            $global:LASTEXITCODE = 1
            return
        }
        switch ($go) {
            '1' {
                $again = @(Get-AllDisplayAnswers -Found $found -Existing $existing)
                if ($again.Count -gt 0) { $answers = $again }
                else { Write-Host '  No monitors selected -- keeping the previous answers.' }
            }
            '2' {
                $devices = @(Read-Triggers -Cands $cands -Current $devices)
            }
            '3' {
                $newTier = Read-Tier $newTier
            }
            'p' {
                if (-not $onPath) { $wantPath = Read-YesNo ('  Add {0} to your PATH?' -f $BINDIR) $wantPath }
            }
        }
    }

    Write-ConfigFile -Path $CONFIG -Displays $answers -Devices $devices -Tier $newTier -Existing $existing
    Write-Log "wrote $CONFIG"

    # ---- prove it, one display at a time -----------------------------------
    Write-Host ''
    if (Read-YesNo '  Test each monitor now? (each one leaves and comes straight back)' $true) {
        foreach ($a in $answers) {
            # Any input but this machine's will do -- the test is only that the panel
            # CHANGES, so there is nothing to pick cleverly. Named, so the prompt can
            # say where it is going instead of showing a bare hex value.
            $otherName = $null; $other = $null
            foreach ($n in @($a.Table.Keys)) {
                if ($a.Table[$n] -ine $a.Self) { $otherName = $n; $other = $a.Table[$n]; break }
            }
            if (-not $other) { continue }
            $ok = Test-DisplayInput -Label $a.Label -Name $a.Name -Candidate $other `
                                    -CandidateName $otherName -Current $a.Self
            if (-not $ok) {
                Write-Host ''
                Write-Host ('  {0} did not respond as expected.' -f $a.Name)
                Write-Host '  Its input value may be wrong, or this panel may need a method'
                Write-Host '  this tool does not have. Re-run `trigger-kvm configure` to try'
                Write-Host '  another value; the config is written either way.'
            }
        }
    }

    if ($wantPath) { Add-ToUserPath -Dir $BINDIR }

    Write-Host ''
    Write-Log 'configured. Applying...'
    $global:LASTEXITCODE = 0
}

# Rewrite the config, preserving every comment block and any key the walkthrough
# does not own (scenes, in particular, which are hand-made and must survive).
function Write-ConfigFile {
    param([string]$Path, $Displays, [string[]]$Devices, [string]$Tier, [hashtable]$Existing)

    $lines = @(
        '# trigger-kvm configuration'
        '#'
        '# Written by `trigger-kvm configure`. Safe to edit by hand.'
        '#'
        '# Everything here is read at the point it is used, so there is no separate'
        '# apply step: display and scene edits take effect on the next switch, and'
        '# trigger edits when the watcher next starts --  trigger-kvm restart'
        '#'
        '# Displays are identified by the EDID the GPU reads off the output, never by'
        '# index -- \\.\DISPLAYn numbers are not stable and have swapped on this'
        '# machine. See what is attached with:  trigger-kvm list'
        ''
        '# --- install ----------------------------------------------------------'
        ("install.tier = {0}" -f $Tier)
        ''
        '# --- displays ---------------------------------------------------------'
        '# method: standard (I2C src 0x51, VCP 0x60) | lg-alt (src 0x50, VCP 0xF4)'
        '# self:   the input value where THIS machine is. Required.'
        ''
    )
    foreach ($d in $Displays) {
        $lines += @(
            ("display.{0}.vendor  = {1}" -f $d.Label, $d.Vendor)
            ("display.{0}.product = {1}" -f $d.Label, $d.Product)
            ("display.{0}.name    = {1}" -f $d.Label, $d.Name)
            ("display.{0}.method  = {1}" -f $d.Label, $d.Method)
            ("display.{0}.self    = {1}" -f $d.Label, $d.Self)
            ''
        )
    }
    $lines += @(
        '# --- triggers ---------------------------------------------------------'
        '#'
        '# A trigger is anything that runs:  trigger-kvm pull'
        '# The one shipped here watches device presence. A hotkey or a Stream Deck'
        '# button needs no support from this tool -- it just runs that command.'
        '#'
        '# Triggers run `pull` and nothing else. Never wire one to a scene: a scene'
        '# names inputs on hardware this machine cannot see, and a stale one would'
        '# then be able to cause an AUTOMATIC switch to a dead input.'
        '#'
        '# device: usb:VVVV:PPPP (bare VVVV:PPPP means usb) or bt:AAAAAAAAAAAA.'
        '#         Bluetooth matches on CONNECTED, not paired.'
        ''
        ("trigger.device   = {0}" -f ($Devices -join ', '))
        ("trigger.debounce = {0}" -f $(if ($Existing.ContainsKey('trigger.debounce')) { $Existing['trigger.debounce'] } else { $SEED_DEBOUNCE }))
        ("trigger.settle   = {0}" -f $(if ($Existing.ContainsKey('trigger.settle'))   { $Existing['trigger.settle'] }   else { $SEED_SETTLE }))
        ''
        '# --- scenes -----------------------------------------------------------'
        '# Saved arrangements for MANUAL use:  trigger-kvm to mac'
        '#'
        '# The trigger never reads these. A scene names inputs on ANOTHER machine,'
        '# which this machine cannot observe and which go stale the moment someone'
        '# moves a cable over there. Keeping them out of the trigger means a stale'
        '# scene can only spoil a command you typed and are watching.'
        ''
    )
    # Scenes are hand-made and the walkthrough does not ask about them, so carry
    # them across verbatim rather than silently dropping someone's work.
    $sceneKeys = @($Existing.Keys | Where-Object { $_ -match '^scene\.' } | Sort-Object)
    foreach ($k in $sceneKeys) { $lines += ("{0} = {1}" -f $k, $Existing[$k]) }

    $lines | Set-Content -LiteralPath $Path -Encoding ASCII
}

# --- discovery ---------------------------------------------------------------

# Candidate trigger devices: things attached or connected RIGHT NOW.
#
# "Right now" is the filter doing most of the work, and it comes from how installing
# actually happens -- you run this on the machine currently holding the peripherals,
# so whatever moves is by definition present. Far more discriminating than any
# heuristic about device class.
#
# ONE list across transports, with a column saying which. You think "the stuff that
# moves when I switch", not "my USB things and separately my Bluetooth things", so
# the transport is metadata detected for you rather than a question to answer.
function Get-TriggerCandidates {
    $rows = @()

    # --- USB: present PnP nodes, minus infrastructure -----------------------
    foreach ($d in (Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)) {
        if ($d.InstanceId -notmatch '^USB\\VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') { continue }
        $key  = ('usb:{0}:{1}' -f $Matches[1], $Matches[2]).ToLower()
        $name = $d.FriendlyName
        if (-not $name) { continue }

        # Hubs and controllers are attached permanently and never move.
        if ($name -match 'Hub|Host Controller|Root Complex') { continue }

        $rows += [PSCustomObject]@{
            Key   = $key
            Bus   = 'USB'
            Name  = $name
            Class = $d.Class
            # Rank by how specific the class is: 'USB' is the generic fallback node,
            # while a Camera/AudioEndpoint/Image entry names the device far better.
            Rank  = $(switch -Regex ($d.Class) {
                        'Camera|Image'            { 0 }
                        'AudioEndpoint|MEDIA'     { 1 }
                        'HIDClass|Mouse|Keyboard' { 2 }
                        'USB'                     { 4 }
                        default                   { 3 }
                     })
        }
    }

    # One row per VID:PID -- a single physical device enumerates several PnP nodes
    # sharing one id (a webcam appears as a composite parent plus camera and audio
    # children), so keep the best-named entry of each group.
    $usb = @($rows | Group-Object Key | ForEach-Object {
        $best = $_.Group | Sort-Object Rank | Select-Object -First 1
        [PSCustomObject]@{ Key = $_.Name; Bus = 'USB'; Name = $best.Name; Class = $best.Class; Rank = $best.Rank }
    })

    # --- Bluetooth: CONNECTED, not merely paired ----------------------------
    #
    # PnP cannot answer this. A paired device keeps its node for years after it last
    # connected, so listing paired devices would offer triggers that can never fire.
    # Only currently-connected ones are candidates, for the same reason USB lists
    # only attached ones.
    # event-watch.ps1 owns the Bluetooth binding, so ask it rather than keeping a
    # second copy of the P/Invoke here. Two copies would drift, and a drifted struct
    # layout is a marshalling bug that presents as WRONG DATA rather than an error.
    # Same shape as asking trigger-kvm.ps1 for the display list.
    $bt = @()
    try {
        $rows = & (Join-Path $PSScriptRoot 'event-watch.ps1') -ListBluetooth 2>$null
        foreach ($row in $rows) {
            $parts = "$row" -split '\|', 3
            if ($parts.Count -lt 3) { continue }
            if ($parts[1] -ne 'True') { continue }   # paired but not connected
            $bt += [PSCustomObject]@{
                Key = 'bt:' + $parts[0]; Bus = 'BT'; Name = $parts[2]; Class = 'Bluetooth'; Rank = 1
            }
        }
    } catch {
        # No radio, or the API is unavailable. Not a reason to fail discovery.
        Write-Log "note: Bluetooth enumeration unavailable ($($_.Exception.Message))"
    }

    return @(@($usb) + @($bt) | Sort-Object Rank, Name)
}

if ($Command -eq 'discover') {
    Write-Host ''
    Write-Host '=== displays on this machine ==='
    & (Join-Path $PSScriptRoot 'trigger-kvm.ps1') list -Config $CONFIG

    Write-Host ''
    Write-Host '=== USB devices attached right now ==='
    Write-Host ''
    Write-Host 'The trigger is whatever MOVES when you flip the switch. Everything below is'
    Write-Host 'attached or connected to this machine at this moment; pick the ones that travel.'
    Write-Host ''

    $cur = @()
    if (Test-Path -LiteralPath $CONFIG) {
        $c = Read-Config -Path $CONFIG
        if ($c.ContainsKey('trigger.device')) {
            # Normalise to the same form the candidate keys use. A config entry may
            # be bare (VVVV:PPPP), which means usb -- without this the "currently a
            # trigger" markers silently stop appearing for every pre-Bluetooth
            # config, which reads as "none of these are configured" and is worse
            # than no marker at all.
            $cur = @(($c['trigger.device'] -replace '\s','') -split ',' | Where-Object { $_ } | ForEach-Object {
                if ($_ -match '^(usb:|bt:)') { $_.ToLower() } else { 'usb:' + $_.ToLower() }
            })
        }
    }

    foreach ($d in (Get-TriggerCandidates)) {
        $mark = $(if ($cur -contains $d.Key) { ' <- currently a trigger' } else { '' })
        Write-Host ('  {0,-20} {1,-4} {2,-18} {3}{4}' -f $d.Key, $d.Bus, $d.Class, $d.Name, $mark)
    }

    Write-Host ''
    Write-Host 'Bluetooth entries list only devices CONNECTED right now, not merely paired --'
    Write-Host 'a paired-but-disconnected device would never produce an arrival to fire on.'

    Write-Host ''
    Write-Host 'TRAP: match the FULL vendor+product pair. A keyboard and mouse often share a'
    Write-Host 'vendor id with a webcam and are always present, so a vendor-only match fires'
    Write-Host 'constantly. Set trigger.device in the config, then re-run install.ps1.'
    Write-Host ("config: {0}" -f $CONFIG)
    exit 0
}

# --- status / logs / uninstall ---------------------------------------------

if ($Command -eq 'configure') {
    # The interactive walkthrough. Current settings pre-fill every default, so a
    # re-run is a review rather than a replay.
    Invoke-Configure
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    # Applying is a CONSEQUENCE of configuring, not a thing to invoke -- which is
    # why there is no apply verb. Re-running the install path covers both cases:
    # a tier change needs the task re-registered, and anything else just needs the
    # watcher restarted, which registering does anyway.
    Write-Log ''
    $self = $PSCommandPath
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $self install
    exit $LASTEXITCODE
}

if ($Command -eq 'restart') {
    # For a hand-edited config. The watcher reads its settings at startup, so
    # bouncing it is the whole of "make my edit take effect" -- no re-registration,
    # because the task action carries no configuration.
    Enable-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue | Out-Null
    Stop-ScheduledTask   -TaskName $TASK -ErrorAction SilentlyContinue
    Stop-Watchers
    Start-ScheduledTask  -TaskName $TASK -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $n = @(Get-CimInstance Win32_Process -Property ProcessId,Name,CommandLine -Verbose:$false |
           Where-Object { $_.CommandLine -and $_.Name -eq 'powershell.exe' -and $_.CommandLine -match '(usb|event)-watch\.ps1' }).Count
    if ($n -ge 1) { Write-Log 'restarted; the watcher has re-read the config.' }
    else { Write-Log 'restarted, but no watcher came up -- check: trigger-kvm logs' }
    exit $(if ($n -ge 1) { 0 } else { 1 })
}

if ($Command -eq 'pause') {
    # Stopping the task is NOT enough, twice over, and both traps have caught
    # people (including the docs, which used to give this advice incompletely):
    #
    #   1. The watcher is a GRANDCHILD of the task -- the task runs wscript.exe,
    #      which runs powershell.exe. Stopping the task kills the shim and leaves
    #      the watcher holding the single-instance mutex, so a hand-run watcher
    #      exits immediately with "another watcher is already running".
    #   2. The 1-minute self-heal trigger would start it again within the minute.
    #      The task has to be DISABLED, not merely stopped.
    Disable-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue | Out-Null
    Stop-ScheduledTask    -TaskName $TASK -ErrorAction SilentlyContinue
    Stop-Watchers
    Write-Log "paused: task disabled and watcher stopped"
    Write-Log 'run one by hand now, e.g.:'
    Write-Log '    .\event-watch.ps1 -Exec .\nvapi-probe.ps1 -Arg TEST -Verbose'
    Write-Log '(it reads the config, so -Device is only needed to try something else)'
    Write-Log 'then restore with:  trigger-kvm restart'
    exit 0
}

if ($Command -eq 'status') {
    $t = Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
    if (-not $t) { Write-Host 'not installed'; exit 1 }
    $i = Get-ScheduledTaskInfo -TaskName $TASK

    # Report the tier AND what it therefore covers. A tier name alone invites the
    # reader to guess the capability, and the whole point of having tiers is that
    # they differ in exactly that.
    $logon = $t.Principal.LogonType
    $tier  = if ($logon -eq 'S4U') { 's4u' } elseif ($logon -eq 'Interactive') { 'user' } else { "unknown ($logon)" }
    Write-Host ("tier     : {0}  (principal={1} logon={2} runlevel={3})" -f `
                $tier, $t.Principal.UserId, $logon, $t.Principal.RunLevel)

    switch ($tier) {
        'user' {
            Write-Host '           covers: from logon onward, including while LOCKED'
            Write-Host '           NOT covered: before the first login after a boot; after a logoff'
        }
        's4u' {
            Write-Host '           covers: from boot onward -- before first login, while locked, after logoff'
        }
        default {
            Write-Host '           <- unrecognised principal; capability unknown'
        }
    }
    Write-Host ("task     : {0}" -f $t.State)

    # 0x800710E0 is "an instance of this task is already running". The 5-minute
    # self-heal trigger produces it on every tick while the watcher is healthy, so
    # it is the expected steady state, not a failure.
    $note = switch ($i.LastTaskResult) {
        0          { '' }
        267009     { '  (running)' }
        2147946720 { '  (self-heal tick found it already running -- expected)' }
        default    { '  <- unexpected' }
    }
    Write-Host ("last run : {0} (result 0x{1:X8}){2}" -f $i.LastRunTime, $i.LastTaskResult, $note)

    $n = @(Get-CimInstance Win32_Process -Property ProcessId,Name,CommandLine -Verbose:$false |
           Where-Object { $_.CommandLine -and $_.Name -eq 'powershell.exe' -and $_.CommandLine -match '(usb|event)-watch\.ps1' }).Count
    Write-Host ("watchers : {0}{1}" -f $n, $(if ($n -eq 1) { '' } else { '  <- expected exactly 1' }))
    Write-Host ("log      : {0}" -f $LOG)
    Write-Host ("config   : {0}{1}" -f $CONFIG, $(if (Test-Path -LiteralPath $CONFIG) { '' } else { '  <- MISSING; run: trigger-kvm configure' }))

    if (Test-Path -LiteralPath $STAMP) {
        $v = Read-Config -Path $STAMP
        Write-Host ("version  : {0}  (installed {1}, commit {2})" -f `
                    $v['version'], $v['installed'], $v['commit'])
    } else {
        Write-Host 'version  : unknown  <- installed before version stamping'
    }

    $onPath = @((Get-UserPath -split ';')) -contains $BINDIR
    Write-Host ("path     : {0}" -f $(if ($onPath) { "$BINDIR (on PATH)" } else { "$BINDIR  <- not on PATH; re-run the installer with -AddToPath" }))

    $c = Read-Config -Path $CONFIG
    $labels = @($c.Keys | Where-Object { $_ -match '^display\.([^.]+)\.vendor$' } | ForEach-Object { $Matches[1] } | Sort-Object -Unique)
    $scenes = @($c.Keys | Where-Object { $_ -match '^scene\.([^.]+)\.' }          | ForEach-Object { $Matches[1] } | Sort-Object -Unique)
    Write-Host ("displays : {0}" -f $(if ($labels) { $labels -join ', ' } else { 'none configured' }))
    Write-Host ("scenes   : {0}" -f $(if ($scenes) { ($scenes -join ', ') + '   (manual only; the trigger never uses these)' } else { 'none' }))
    exit 0
}

if ($Command -eq 'logs') {
    if (-not (Test-Path -LiteralPath $LOG)) { Write-Host "no log yet at $LOG"; exit 1 }
    Get-Content -LiteralPath $LOG -Tail 50 -Wait
    exit 0
}

if ($Command -eq 'uninstall') {
    if (Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
        try {
            Unregister-ScheduledTask -TaskName $TASK -Confirm:$false -ErrorAction Stop
            Write-Log "unregistered task '$TASK'"
        } catch {
            # Same ownership trap as setup, and the more important of the two:
            # removing the FILES while leaving the task registered would be the
            # worst outcome -- a task pointing at scripts that are gone, failing
            # silently at every logon. So elevate, or stop.
            if (-not $IsElevated) {
                Write-Log "'$TASK' was registered by an elevated process."
                $rc = Request-Elevation -ChildArgs @('uninstall')
                if ($rc -ne 0) { Write-Log 'nothing removed -- files left in place so the task keeps working.' }
                exit $rc
            }
            Write-Log "cannot unregister '$TASK' even elevated: $($_.Exception.Message)"
            Write-Log 'nothing removed -- files left in place so the task keeps working.'
            exit 1
        }
    }

    Stop-Watchers
    Remove-LegacyInstall
    Remove-FromUserPath -Dir $BINDIR
    Remove-FromUserPath -Dir $DEST      # an earlier layout put this one on PATH

    # Leave the log AND the config in place. The log is the only record of what
    # happened, and a config can represent real work -- reinstalling should not
    # make you redo it. Both live outside $DEST for exactly this reason.
    foreach ($f in @($WATCH, $SWITCH, $LGEXE, $VBS, $SHIM, $OLD_SHIM, $STAMP, $CFGLIB) + $STALE) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force; Write-Log "removed $f" }
    }

    # This script last: it is running from here when invoked as `trigger-kvm
    # uninstall`, and PowerShell has already read it, so deleting it now is safe.
    if (Test-Path -LiteralPath $MANAGE) { Remove-Item -LiteralPath $MANAGE -Force; Write-Log "removed $MANAGE" }
    if ((Test-Path -LiteralPath $BINDIR) -and -not (Get-ChildItem -LiteralPath $BINDIR -Force)) {
        Remove-Item -LiteralPath $BINDIR -Force
    }
    if ((Test-Path -LiteralPath $DEST) -and -not (Get-ChildItem -LiteralPath $DEST -Force)) {
        Remove-Item -LiteralPath $DEST -Force
        Write-Log "removed empty $DEST"
    }

    Write-Log 'uninstalled.'
    Write-Log "config and log kept: $CONFIG"
    exit 0
}

# --- install ----------------------------------------------------------------

# Constraint: never install a tier that will silently fail. The s4u tier cannot be
# registered without elevation -- measured, S4U registration returns "Access is
# denied" for an ordinary user -- so ask for it UP FRONT, before copying anything,
# rather than letting Register-ScheduledTask fail halfway through.
$EffectiveTier = Get-EffectiveTier

if ($EffectiveTier -eq 's4u' -and -not $IsElevated) {
    $childArgs = @('install', '-Tier', 's4u')
    if ($AddToPath) { $childArgs += '-AddToPath' }
    exit (Request-Elevation -ChildArgs $childArgs)
}

# No config means nothing to install FROM: the seed values describe one specific
# desk and would be wrong for anyone else. Walk the user through it instead, and
# refuse clearly when we cannot ask.
if (-not (Test-Path -LiteralPath $CONFIG)) {
    if (Test-CanPrompt) {
        Write-Log 'no configuration yet -- starting setup.'
        Invoke-Configure
        if ($LASTEXITCODE -ne 0) {
            Write-Log 'setup did not complete; nothing was installed.'
            exit $LASTEXITCODE
        }
    } else {
        Write-Log "no configuration at $CONFIG, and this is not an interactive terminal."
        Write-Host ''
        Write-Host 'Run this from a normal PowerShell window to set it up:'
        Write-Host ("    {0}" -f $PSCommandPath)
        exit 2
    }
}

# The config is the source of truth for what the task watches. Read it back rather
# than using the seed values, so that a hand-edited config actually takes effect on
# the next install -- otherwise editing trigger.device would silently do nothing.
$cfg      = Read-Config -Path $CONFIG

# These keys were briefly trigger.usb.* and then trigger.device.*, before settling
# back to the original flat names. The reasoning for the detour was future-proofing
# against a second transport -- which is the same speculative generality this project
# refuses elsewhere (there is no trigger framework, and the name commits to neither
# USB nor DDC for the same reason). A malformed device id already throws loudly with
# an explicit "expected VVVV:PPPP", so nothing was failing silently for the extra
# nesting to prevent.
#
# The timings sit at trigger.* rather than under any transport on purpose: one
# debounce must cover every trigger, since two independent windows could not dedupe
# against each other -- the failure that forced the single-instance mutex to go
# machine-wide. At this level that holds by construction.
#
# Falling back to seed values on an unrecognised old key would silently revert
# customised triggers, so say so instead. Drop this once no config can still use one.
$renamed = @{
    'trigger.usb.device'      = 'trigger.device'
    'trigger.usb.debounce'    = 'trigger.debounce'
    'trigger.usb.settle'      = 'trigger.settle'
    'trigger.device.usb'      = 'trigger.device'
    'trigger.device.debounce' = 'trigger.debounce'
    'trigger.device.settle'   = 'trigger.settle'
}
foreach ($old in $renamed.Keys) {
    if ($cfg.ContainsKey($old)) {
        Write-Log ("WARNING: '{0}' is an old key name; rename it to '{1}' in {2}." -f $old, $renamed[$old], $CONFIG)
        Write-Log '         Until you do, the seed defaults are used instead of your value.'
    }
}

$devices  = $(if ($cfg.ContainsKey('trigger.device'))   { $cfg['trigger.device'] -replace '\s', '' } else { $SEED_DEVICES })
$debounce = $(if ($cfg.ContainsKey('trigger.debounce')) { $cfg['trigger.debounce'] }                 else { $SEED_DEBOUNCE })
$settle   = $(if ($cfg.ContainsKey('trigger.settle'))   { $cfg['trigger.settle'] }                   else { $SEED_SETTLE })
Write-Log "config says: watch $devices  (debounce ${debounce}s, settle ${settle}s)"

New-Item -ItemType Directory -Force -Path $DEST              | Out-Null
New-Item -ItemType Directory -Force -Path $BINDIR            | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $LOG)  | Out-Null

Copy-Item (Join-Path $PSScriptRoot 'config.ps1')       $CFGLIB -Force
Copy-Item (Join-Path $PSScriptRoot 'event-watch.ps1')  $WATCH  -Force
Copy-Item (Join-Path $PSScriptRoot 'trigger-kvm.ps1')  $SWITCH -Force

# Install THIS script too, so status/logs/pause/uninstall keep working after the
# source tree is deleted. Skipped when already running from $DEST -- copying a file
# onto itself throws, and `trigger-kvm setup` re-run in place does exactly that.
if ((Resolve-Path $PSScriptRoot).Path -ne (Resolve-Path $DEST).Path) {
    Copy-Item $PSCommandPath $MANAGE -Force
}
Write-Log "installed scripts to $DEST"

# An earlier layout put the shim in $DEST and therefore $DEST on PATH, which
# published launcher.vbs as a bare `launcher` command. Undo both.
if (Test-Path -LiteralPath $OLD_SHIM) {
    Remove-Item -LiteralPath $OLD_SHIM -Force
    Write-Log "removed the old shim from $DEST (it required putting the whole directory on PATH)"
}
Remove-FromUserPath -Dir $DEST

# Leftovers from earlier layouts inside this same directory.
foreach ($f in $STALE) {
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force; Write-Log "removed stale $f" }
}

# The `trigger-kvm` on PATH. A .cmd rather than a .ps1 so it runs from cmd.exe,
# PowerShell and the Run dialog alike, with no execution-policy friction: it calls
# powershell with -ExecutionPolicy Bypass itself.
#
# Two scripts stay behind one command deliberately. trigger-kvm.ps1 runs on EVERY
# device arrival and is kept lean; install.ps1 is large and rarely used. Merging
# them would load installer code on the hot path.
@(
    '@echo off'
    'rem Generated by install.ps1 -- do not edit; re-run the installer instead.'
    'setlocal'
    'rem Scripts live one level up; only this shim is on PATH.'
    'set "TK_DIR=%~dp0..\\"'
    'if "%~1"=="" goto :switch'
    'if /i "%~1"=="pull" goto :switch'
    'if /i "%~1"=="to"   goto :switch'
    'if /i "%~1"=="list" goto :switch'
    'if /i "%~1"=="install" goto :noinstall'
    'goto :manage'
    ':switch'
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TK_DIR%trigger-kvm.ps1" %*'
    'exit /b %ERRORLEVEL%'
    ':manage'
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TK_DIR%install.ps1" %*'
    'exit /b %ERRORLEVEL%'
    ':noinstall'
    'rem Installing is what produced this command, so re-running it here would only'
    'rem copy the installed files onto themselves. Upgrading and repairing both mean'
    'rem fetching the source and running ITS installer.'
    'echo trigger-kvm: there is no `install` verb here -- installing is what got you'
    'echo                this command. To upgrade or repair, run install.ps1 from the'
    'echo                source tree. To change settings: trigger-kvm configure'
    'exit /b 2'
) | Set-Content -LiteralPath $SHIM -Encoding ASCII

# Version stamp. Records the commit too when the source is a git checkout, which is
# how you tell a released copy from one built off a dirty tree.
$commit = ''
try {
    Push-Location $PSScriptRoot
    $commit = (& git rev-parse --short HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) { $commit = '' }
    if ($commit -and (& git status --porcelain 2>$null)) { $commit += '+dirty' }
} catch { } finally { Pop-Location -ErrorAction SilentlyContinue }

@(
    "version   = $VERSION"
    "installed = $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    "source    = $PSScriptRoot"
    "commit    = $(if ($commit) { $commit } else { '(not a git checkout)' })"
) | Set-Content -LiteralPath $STAMP -Encoding ASCII

# Migration: older installs downloaded lg-input-switch.exe here. The LG is now
# driven by an aimed NVAPI write inside trigger-kvm.ps1, so the binary is dead
# weight -- and leaving a 16MB GPL-3.0 executable lying around after it stopped
# being used would be its own small surprise.
if (Test-Path -LiteralPath $LGEXE) {
    Remove-Item -LiteralPath $LGEXE -Force
    Write-Log "removed lg-input-switch.exe (no longer used; the LG path is now native)"
}

# --- the Scheduled Task -----------------------------------------------------

# powershell.exe -File passes every argument as a literal string, which is why
# -Device takes one comma-separated value here rather than an array.
$psCmd = @(
    'powershell.exe',
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', "`"$WATCH`"",
    '-Exec', "`"$SWITCH`"",
    '-Arg', 'pull',
    '-LogFile', "`"$LOG`""
) -join ' '

# Launch through wscript.exe rather than running powershell.exe directly.
#
# powershell.exe is a console-subsystem binary: Windows allocates a console for it
# before -WindowStyle Hidden can take effect, so starting it from a logon task can
# flash a console window every time you log in, and leaves something closeable.
# wscript.exe is GUI-subsystem, so routing through it means no console is ever
# created and there is no window to close by accident.
#
# bWaitOnReturn = True keeps the wscript process alive for as long as the watcher
# runs, so Task Scheduler still reports the task as Running and its restart-on-
# failure settings still apply. Generated rather than committed, the same way the
# macOS Makefile generates the LaunchAgent plist.
$vbsCmd = $psCmd -replace '"', '""'
@(
    "' Generated by install.ps1 -- do not edit; re-run install.ps1 instead."
    "' Runs the watcher with no console allocated and no window to close."
    'Dim sh: Set sh = CreateObject("WScript.Shell")'
    "sh.Run ""$vbsCmd"", 0, True"
) | Set-Content -LiteralPath $VBS -Encoding ASCII

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$VBS`""

# The tier differs in exactly two things: when it starts, and as whom. Everything
# below this point -- the self-heal trigger, the settings, the action -- is shared,
# because the tier is not supposed to change what the watcher does.
if ($EffectiveTier -eq 's4u') {
    # At startup, so it is running before anyone logs in. S4U means "run as this
    # user without their password": no stored credential (which is rejected
    # outright), and RunLevel Limited means ordinary user rights at run time even
    # though registering it needed admin.
    $triggers = @( (New-ScheduledTaskTrigger -AtStartup) )
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType S4U -RunLevel Limited
} else {
    # Interactive session, normal user rights, and deliberately no admin anywhere.
    $triggers = @( (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME) )
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive -RunLevel Limited
}

# Self-heal. AtLogOn alone means that if the watcher is ever killed -- Task Manager,
# a crash, a stray Stop-Process -- it stays dead until the next logon, and you would
# only find out when the displays silently stopped following the USB switch.
#
# This trigger is the ONLY thing that brings it back. The task's RestartCount /
# RestartInterval settings do not: measured 2026-08-30, killing the watcher left the
# task Ready and no restart occurred in 180s, because Task Scheduler treats the
# ended task as complete rather than failed. So this interval IS the recovery time.
#
# One minute, to stay within sight of the macOS side, where launchd's KeepAlive
# respawns in about a second. MultipleInstances IgnoreNew makes each tick a no-op
# while the watcher is alive, so the steady-state cost of the tighter interval is a
# process launch that exits immediately.
$heal = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 1)
# No Duration means repeat indefinitely; be explicit that it must not stop.
$heal.Repetition.StopAtDurationEnd = $false
$triggers += $heal

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

# StopIfGoingOnBatteries defaults on and would silently kill a desktop's watcher
# on a brief UPS blip.
$settings.DisallowStartIfOnBatteries = $false
$settings.StopIfGoingOnBatteries     = $false

# Replacing the task means deleting it first, and that can be denied even though
# this is your own user-tier task: the task FILE under System32\Tasks is owned by
# whoever registered it. Register once from an elevated shell -- or install the s4u
# tier, which requires elevation -- and the file becomes Administrators-owned, with
# the user left holding Read only. Every later unelevated setup then fails here.
#
# That is not exotic. Installing s4u and later going back to the user tier hits it
# every time, and so does running setup once from an admin window by habit. Left
# raw it surfaces as "Access is denied" with the scripts already copied, which reads
# like a broken installer rather than a fixable permission.
if (Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
    try {
        Unregister-ScheduledTask -TaskName $TASK -Confirm:$false -ErrorAction Stop
    } catch {
        # Denied because the task DEFINITION is owned by whoever registered it.
        # One earlier run from an admin shell -- or an s4u install, which requires
        # one -- leaves an ordinary user with Read only on their own user-tier task.
        #
        # Ask for elevation rather than sending the user away to another terminal.
        # Being unable to remove a tier you installed is a trap, and it is the same
        # trap on the way out as on the way in.
        if (-not $IsElevated) {
            Write-Log "the existing '$TASK' task was registered by an elevated process."
            $childArgs = @('install', '-Tier', $EffectiveTier)
            if ($AddToPath) { $childArgs += '-AddToPath' }
            $rc = Request-Elevation -ChildArgs $childArgs
            if ($rc -eq 0) {
                Write-Log 'done (elevated).'
            } else {
                Write-Log 'the task was left exactly as it was, so what was running still is.'
            }
            exit $rc
        }

        # Already elevated and STILL denied: not an ownership problem.
        Write-Log "cannot replace the existing '$TASK' task even elevated: $($_.Exception.Message)"
        Write-Log 'the task was left as it was; nothing is broken, but nothing changed either.'
        exit 1
    }
}

Register-ScheduledTask -TaskName $TASK -Action $action -Trigger $triggers `
    -Principal $principal -Settings $settings `
    -Description "trigger-kvm ($EffectiveTier tier): pull both monitors to this PC when the shared USB peripherals arrive." | Out-Null

# -Pause disables the task; installing again must undo that or the watcher would
# be registered, reported healthy, and never actually start.
Enable-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue | Out-Null
# Persist the tier that was actually installed, so a later bare `install` -- or the
# elevated relaunch -- keeps it instead of silently reverting to the default.
Set-ConfigValue -Path $CONFIG -Key 'install.tier' -Value $EffectiveTier

Start-ScheduledTask -TaskName $TASK
Write-Log "registered and started task '$TASK' ($EffectiveTier tier)"

if ($AddToPath) { Add-ToUserPath -Dir $BINDIR }

# What is left to say is short: it works, here is how to see that, here are the
# four things you can do to it. Everything else -- tiers, sessions, the transport --
# is in the docs for the day someone needs it, and is noise on the day they don't.
#
# Two different questions, and printing the wrong one sends people to a "not
# recognized" error: the User PATH says whether `trigger-kvm` will resolve in a NEW
# terminal, $env:PATH whether it resolves in THIS one. A PATH entry added a moment
# ago -- here, or by the walkthrough that invoked this -- satisfies the first and
# not the second.
$onPath      = @((Get-UserPath -split ';')) -contains $BINDIR
$inThisShell = @(($env:PATH -split ';')) -contains $BINDIR
$cmd = if ($onPath) { 'trigger-kvm' } else { $SHIM }

Write-Host ''
Write-Host '  Done. trigger-kvm is running.'
Write-Host ''
Write-Host '  Flip your switch to this PC -- the monitors should follow.'
Write-Host ''
Write-Host ("    {0} status      is it running?" -f $cmd)
Write-Host ("    {0} pull        bring the displays here now" -f $cmd)
Write-Host ("    {0} logs        what has it been doing" -f $cmd)
Write-Host ("    {0} configure   change any of this" -f $cmd)
Write-Host ''

if (-not $onPath) {
    Write-Host ('  (Re-run with -AddToPath to put {0} on your PATH and shorten that.)' -f $BINDIR)
    Write-Host ''
} elseif (-not $inThisShell) {
    Write-Host '  (Open a new terminal first -- this one has not picked up the PATH change.)'
    Write-Host ''
}

if ($EffectiveTier -eq 's4u') {
    Write-Host '  It starts at boot, before anyone logs in -- but that part is UNVERIFIED'
    Write-Host '  on this machine until you try it: log out, flip the switch, and see'
    Write-Host '  whether the monitors follow with nobody logged in.'
    Write-Host ''
}
