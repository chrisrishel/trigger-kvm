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
    trigger-kvm status             when it starts, what that covers, version
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
idiomatic per platform (-AddToPath here, --add-to-path there): forcing the POSIX
spelling into PowerShell means hand-parsing $args and losing parameter binding,
validation and completion, which is a real cost for a cosmetic gain.

WHEN IT STARTS, recorded in the config as install.start, and chosen by what you
are willing to grant. There is no flag for it and no name for it in anything a
user reads -- the walkthrough asks, the config records the answer, and the
installer applies what it finds. It was called a "tier" for a while, which told a
reader nothing they could act on:

  install.start = boot     Runs at startup, in session 0, as you, still
                           UNELEVATED. ADMIN ONCE, to register the task --
                           prompted for via UAC. Nothing elevated runs on the
                           switch path afterwards. This is what the walkthrough
                           offers first, because it behaves the way people
                           expect. Internally: an S4U task, $EffectiveTier 's4u'.

  install.start = login    Runs at logon, in your interactive session,
                           unelevated. NO ADMIN, at install or at run time.
                           Covers everything from logon onward -- including
                           while the screen is LOCKED, since the session and
                           watcher stay alive. Does not cover: before the first
                           login after a boot, or after a full logoff. What a
                           HEADLESS install falls back to, because it cannot ask
                           for elevation. Internally: 'user'.

The two are mutually exclusive by construction -- they share one task name, so
installing either replaces the other. Two live watchers in different sessions
would both fire on the same arrival, and the debounce is per-process, so it
cannot dedupe across them. event-watch.ps1 also takes a machine-wide mutex as
defence in depth.

This is a property of the HOST, not of the switcher. Nothing in trigger-kvm.ps1
or event-watch.ps1 knows or asks when it was started. If either ever needs to,
the abstraction is wrong -- stop and rethink.

Why starting from boot is possible at all: measured 2026-08-30, NVAPI both enumerates and
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

    # Put the install directory on the user PATH so `trigger-kvm` works anywhere.
    # Opt-in: editing someone's PATH without asking is rude, and the interactive
    # setup will ask properly once it exists.
    [switch]$AddToPath,

    # `configure -Fresh`: ask everything from scratch instead of pre-filling the
    # answers from the current setup. For when the desk changed enough that the old
    # answers are the wrong starting point -- a new monitor, a rebuilt hub -- and
    # enter-through would carry a stale value forward without you reading it.
    # Hand-written config (scenes especially) is still preserved.
    [switch]$Fresh,

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

# --- when it starts ----------------------------------------------------------

# The config is the only source: there is no flag, because a flag would have been a
# second way to say something the installer already has to read. Resolved once,
# here, so every later decision -- whether to elevate, which principal to register,
# what status reports -- reads the same answer.
#
# Returns the INTERNAL names ('s4u' / 'user') because they are what the Scheduled
# Task API calls these principals; nothing a user reads says either word.
function Get-EffectiveTier {
    $c = Read-Config -Path (Get-ConfigPath)
    if ($c.ContainsKey('install.start')) {
        if ($c['install.start'] -eq 'boot')  { return 's4u' }
        if ($c['install.start'] -eq 'login') { return 'user' }
    }
    # The old spelling still counts. Unlike the other renamed keys, ignoring this one
    # would not fall back to a harmless default -- it would silently DOWNGRADE a
    # working boot-start install to login-only on the next install, with the loss
    # showing up months later as "switching does nothing at the login screen". The
    # rename warning still fires, and `configure` rewrites the file without it.
    if ($c.ContainsKey('install.tier') -and $c['install.tier'] -in @('user', 's4u')) {
        return $c['install.tier']
    }
    # Deliberately NOT the walkthrough's default. The walkthrough offers from-boot
    # first because it can ask for the UAC prompt and get an answer; a headless or
    # scripted install cannot, so it takes the tier that needs no elevation. Nothing
    # ever elevates without someone choosing it.
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
        '# start: boot (watches before anyone logs in; set up once with admin)'
        '#       s4u  (admin ONCE to register; adds before-first-login and logoff)'
        ''
        'install.start = login'
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
# What a MANUFACTURER's panels answer to when the standard channel does not.
#
# Keyed by EDID vendor alone, never by model. The earlier table was keyed
# vendor:product -- one row per monitor anyone here had met, on a panel whose
# product id is per-INPUT, so the key was nearly per-cable. Nobody else's monitor
# would ever be in it. The transport layer already got this right: WriteLgInput
# gates on the vendor (EDID_VENDOR_GSM) and does not care which LG it is.
#
# A dialect is OFFERED, never probed, and only after standard DDC has been shown
# not to work -- most panels of every make answer 0x60 perfectly well, and reaching
# for a manufacturer channel that is not needed is how monitors get bricked
# (AGENTS.md hard rule 1). Values here come from documentation and measurement,
# never from a search.
$DIALECTS = @{
    '1E6D' = @{                        # GSM -- LG Electronics
        What   = 'LG'
        Method = 'lg-alt'
        # DDC2AB: I2C source 0x50, VCP 0xF4. Measured on a 45GX950A.
        Inputs = [ordered]@{ 'DisplayPort' = '0xD0'; 'USB-C' = '0xD1'; 'HDMI 1' = '0x90'; 'HDMI 2' = '0x91' }
    }
}

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

# --- arrow-key menus ---------------------------------------------------------
#
# Every list question in the walkthrough is one of these two, and in both, ENTER
# DOES WHAT THE HIGHLIGHTED ROW SAYS. That single rule is the whole design: with
# "space toggles, enter accepts" the first thing people did was accept an empty
# list, because enter is what you press. So a multi-select has no accept key --
# it has a row you move to.
#
# Both fall back to a typed number when the host cannot read individual keys: a
# redirected stdin, a non-console host, anything that is not a real terminal. The
# fallback is not a nicety -- it is what makes the whole flow testable end to end,
# and what keeps the installer usable over a session that does not forward keys.

function Test-CanReadKeys {
    if ([Console]::IsInputRedirected) { return $false }
    try { $null = [Console]::KeyAvailable } catch { return $false }
    return $true
}

# The one place a key is read. A function so the key-driven path is reachable by a
# test harness -- [Console]::ReadKey is a static and cannot be stubbed, and the
# alternative was shipping the interactive half of the walkthrough unexercised.
function Read-MenuKey {
    return [Console]::ReadKey($true).Key
}

function Get-MenuWidth {
    $w = 100
    try { $w = [Math]::Max(40, [Math]::Min(110, [Console]::WindowWidth - 1)) } catch { }
    return $w
}

# Repaint a block in place, returning the number of lines drawn -- which the next
# call passes back as -Previous. Counting what was actually drawn is the point:
# every earlier version of this inferred the height from the inputs and was one
# line out the moment a caller changed the block's shape.
function Write-MenuFrame {
    param([string[]]$Lines, [int]$Width, [int]$Previous = 0)

    if ($Previous -gt 0) {
        try { [Console]::SetCursorPosition(0, [Math]::Max(0, [Console]::CursorTop - $Previous)) } catch { }
    }
    foreach ($l in $Lines) {
        $t = "$l"
        # Pad to overwrite the previous frame; truncate so a long name cannot wrap
        # and silently add a line to the block.
        if ($t.Length -gt $Width) { $t = $t.Substring(0, $Width) }
        Write-Host $t.PadRight($Width)
    }
    return $Lines.Count
}

# One choice from a list. Returns the index.
function Select-One {
    param([string[]]$Items, [string[]]$Detail = @(), [int]$Default = 0, [string]$Help,
          # The row that is configured RIGHT NOW, if any. Starting the cursor there
          # is not enough on its own -- the cursor also means "where you are", so a
          # re-run gave no way to tell an unchanged default from a deliberate one.
          [int]$Current = -1)

    # An empty item is a SEPARATOR: drawn as a blank line, skipped by the cursor and
    # unpickable. Grouping a long menu beats renaming its rows to imply grouping.
    $rows = @()
    $sel  = @()
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if (-not $Items[$i]) { $rows += ''; continue }
        $sel += $i
        $d = if ($i -lt $Detail.Count) { "$($Detail[$i])" } else { '' }
        $row = $(if ($d) { '{0,-28} {1}' -f $Items[$i], $d } else { $Items[$i] })
        if ($i -eq $Current) { $row = $row.TrimEnd() + '   (current)' }
        $rows += $row
    }
    if ($sel.Count -eq 0) { throw 'Select-One: nothing selectable' }
    if ($sel -notcontains $Default) { $Default = $sel[0] }

    if (-not (Test-CanReadKeys)) {
        for ($i = 0; $i -lt $rows.Count; $i++) {
            if ($sel -contains $i) { Write-Host ('    {0}) {1}' -f ($i + 1), $rows[$i]) }
            else                   { Write-Host '' }
        }
        if ($Help) { Write-Host ''; Write-Host $Help }
        while ($true) {
            $pick = Read-Default '  Choice' ([string]($Default + 1))
            if ($pick -match '^[0-9]+$' -and $sel -contains ([int]$pick - 1)) { return ([int]$pick - 1) }
            Write-Host '  Pick a number from the list.'
        }
    }

    $width    = Get-MenuWidth
    $helpBody = if ($Help) { @('') + @($Help -split "`r?`n") } else { @() }
    # The cursor moves over the SELECTABLE rows, not over the drawn ones, so a
    # separator can never be landed on or wrapped onto.
    $at    = [Math]::Max(0, $sel.IndexOf($Default))
    $drawn = 0

    while ($true) {
        $lines = @()
        for ($i = 0; $i -lt $rows.Count; $i++) {
            if (-not ($sel -contains $i)) { $lines += ''; continue }
            $lines += '{0} {1}' -f $(if ($i -eq $sel[$at]) { '  >' } else { '   ' }), $rows[$i]
        }
        $lines += $helpBody
        $lines += ''
        $lines += '  up/down move   enter choose'
        $drawn = Write-MenuFrame -Lines $lines -Width $width -Previous $drawn

        switch (Read-MenuKey) {
            'UpArrow'   { $at = ($at - 1 + $sel.Count) % $sel.Count }
            'DownArrow' { $at = ($at + 1) % $sel.Count }
            'Enter'     { Write-Host ''; return $sel[$at] }
        }
    }
}

# Several choices. Enter toggles the highlighted row, and the last row is the way
# out -- so "how do I finish?" is answered by the list itself rather than by a
# hint line nobody reads. Space toggles too, for anyone who reaches for it.
function Select-Many {
    param([string[]]$Items, [string[]]$Detail, [int[]]$Checked = @(), [string]$Help,
          [string]$DoneLabel = 'Done')

    $state = @($Items | ForEach-Object { $false })
    foreach ($i in $Checked) { if ($i -ge 0 -and $i -lt $state.Count) { $state[$i] = $true } }

    if (-not (Test-CanReadKeys)) {
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

    $width    = Get-MenuWidth
    $helpBody = if ($Help) { @('') + @($Help -split "`r?`n") } else { @() }
    $done     = $Items.Count          # the index of the Done row
    $cursor   = 0
    $note     = ''
    $drawn    = 0

    while ($true) {
        $lines = @()
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $lines += '{0} {1} {2}  {3}' -f $(if ($i -eq $cursor) { '  >' } else { '   ' }),
                                            $(if ($state[$i]) { '[x]' } else { '[ ]' }),
                                            $Items[$i], $Detail[$i]
        }
        # Drawn as a button, not as another list row: the last version read as a
        # fourth thing to check, and people did not see that it was the way out.
        # The count is live so the button also answers "what will this use?".
        $n = @($state | Where-Object { $_ }).Count
        $button = $(if ($n -gt 0) { '[ {0} -- use the {1} checked ]' -f $DoneLabel, $n }
                   else           { '[ {0} -- nothing checked yet ]' -f $DoneLabel })
        $lines += ''
        $lines += '{0} {1}' -f $(if ($cursor -eq $done) { '  >' } else { '   ' }), $button
        $lines += $helpBody
        $lines += ''
        $lines += '  up/down move   enter toggles the highlighted row'
        $lines += $note
        $drawn = Write-MenuFrame -Lines $lines -Width $width -Previous $drawn

        $key  = Read-MenuKey
        $note = ''
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
          [string]$Current, [int]$Hold = 8, [string]$Config = $CONFIG)

    $sw = Join-Path $PSScriptRoot 'trigger-kvm.ps1'
    if (-not (Test-Path $sw)) { $sw = $SWITCH }

    Write-Host ''
    Write-Host ("  Switching $Name to $CandidateName for ${Hold}s, then back automatically.")
    Write-Host '  Watch that monitor. It only has to CHANGE -- if nothing is plugged into'
    Write-Host '  that input it will say No Signal, and that still proves the switch worked.'
    & $sw set -Only $Label -Value $Candidate -Config $Config | Out-Null
    Start-Sleep -Seconds $Hold
    if ($Current) { & $sw set -Only $Label -Value $Current -Config $Config | Out-Null; Start-Sleep -Seconds 2 }

    # Three outcomes, three different faults, and the old yes/no could tell only two
    # of them apart: "it did not come back" means the value for THIS PC is wrong,
    # while "nothing happened" means the panel does not answer on this channel at
    # all. Those have nothing to do with each other and were reported identically.
    Write-Host ''
    Write-Host ("  What did the {0} do?" -f $Name)
    return Select-One -Default 0 -Items @(
        'It changed, then came back',
        'It changed, but did not come back',
        'Nothing happened at all'
    ) -Detail @(
        'everything works',
        'the input you gave for THIS PC is wrong',
        'this panel does not answer on this channel'
    )
}

# Send one value and ask whether the panel came back to this PC. The building block
# of blind walking, and the only place a value is sent without knowing what it means.
function Test-OneValue {
    param([string]$Label, [string]$Name, [string]$Value, [string]$Config, [int]$Hold = 6)

    $sw = Join-Path $PSScriptRoot 'trigger-kvm.ps1'
    if (-not (Test-Path $sw)) { $sw = $SWITCH }

    Write-Host ''
    Write-Host ('  Trying {0} ...' -f $Value)
    & $sw set -Only $Label -Value $Value -Config $Config | Out-Null
    Start-Sleep -Seconds $Hold
    return (Read-YesNo ("  Is the {0} showing THIS PC now?" -f $Name) $false)
}

# Last resort: send each standard input value in turn until the panel comes back to
# this PC. Constraint 11 permits exactly this and no more -- standard DDC/CI only,
# MCCS values only, one at a time, and never on a manufacturer sidechannel, where a
# value we have not been told is a value nobody should send.
#
# It is offered, never automatic, and the cost is stated first: every wrong guess
# takes the panel somewhere else, and if none of them is right it stays there.
function Invoke-BlindWalk {
    param($Answer, [string]$Config, [int]$OtherPanels)

    Write-Host ''
    Write-Host '--- try the standard values one at a time ---'
    if ($Answer.Method -ne 'standard') {
        Write-Host '  Only offered on the standard channel. A manufacturer channel takes'
        Write-Host '  values from documentation or from you -- never from us guessing.'
        return $null
    }
    if ($OtherPanels -lt 1) {
        # Hard rule 4. With nothing else on this PC, a wrong guess blacks out the
        # screen this question is printed on.
        Write-Host ('  Not offered: the {0} is the only monitor on this PC, so a wrong' -f $Answer.Name)
        Write-Host '  guess would black out the screen you are reading. Use the monitor''s own'
        Write-Host '  buttons to see which input this PC is on, then enter that value.'
        return $null
    }

    Write-Host ('  I will send each standard input value to the {0} in turn and ask' -f $Answer.Name)
    Write-Host '  whether it came back. Your other monitor stays on this PC throughout,'
    Write-Host '  so you can keep reading this.'
    Write-Host ''
    Write-Host '  COST: every wrong value moves that panel to another input. If none of'
    Write-Host '  them is right it will stay on the last one, and you will need the'
    Write-Host '  monitor''s own buttons to bring it back.'
    if (-not (Read-YesNo '  Go ahead?' $false)) { return $null }

    foreach ($n in $MCCS_INPUTS.Keys) {
        if (Test-OneValue -Label $Answer.Label -Name $Answer.Name -Value $MCCS_INPUTS[$n] -Config $Config) {
            Write-Host ''
            Write-Host ('  Found it: {0} is {1} on this panel.' -f $MCCS_INPUTS[$n], $n)
            return $MCCS_INPUTS[$n]
        }
    }

    Write-Host ''
    Write-Host '  None of the standard values brought it back. Use the monitor''s buttons'
    Write-Host '  to return it to this PC.'
    return $null
}

# Names the user gave inputs on this panel, from a previous run. Stored value-first
# (`display.lg.input.0xd1 = Mac`) so the name survives verbatim -- Read-Config
# lower-cases keys, and "Mac" typed by a person should not come back as "mac".
function Get-NamedInputs {
    param([hashtable]$Existing, [string]$Label)

    $out = [ordered]@{}
    if (-not $Label) { return $out }
    foreach ($k in ($Existing.Keys | Sort-Object)) {
        if ($k -match ('^display\.' + [regex]::Escape($Label) + '\.input\.(0x[0-9a-f]{1,2})$')) {
            $out[$Existing[$k]] = $Matches[1]
        }
    }
    return $out
}

# The inputs to offer for a panel: the channel's own value set, with anything the
# user has named on this desk in front of it. Their "Mac" is a better label than our
# "HDMI 2", and it is the only one that is true about their room.
function Get-InputTable {
    param([string]$Method, $Named)

    $base = $MCCS_INPUTS
    foreach ($d in $DIALECTS.Values) { if ($d.Method -eq $Method) { $base = $d.Inputs } }

    $out = [ordered]@{}
    if ($Named) { foreach ($n in $Named.Keys) { $out[$n] = $Named[$n] } }
    foreach ($n in $base.Keys) {
        # Do not list a value twice under two names; the user's wins.
        if (@($out.Values) -contains $base[$n]) { continue }
        $out[$n] = $base[$n]
    }
    return $out
}

# Ask which input a value corresponds to, one panel, one value. Returns a table.
function Read-InputValue {
    param($Table, [string]$Prompt, [string]$Sub, [string]$Default = '')

    $names = @($Table.Keys)
    $rows  = @($names) + @('Type a value...')
    $vals  = @($names | ForEach-Object { $Table[$_] }) + @('')

    # Start on the configured value's row, so a re-run is a review rather than a
    # re-entry. An unlisted value starts on "type a value", which is where it came
    # from.
    $row = 0
    $now = -1
    if ($Default) {
        $row = $rows.Count - 1
        for ($i = 0; $i -lt $names.Count; $i++) { if ($Table[$names[$i]] -ieq $Default) { $row = $i } }
        $now = $row
    }

    Write-Host ''
    Write-Host ('  ' + $Prompt)
    if ($Sub) { Write-Host ('  ' + $Sub) }

    while ($true) {
        $pick = Select-One -Items $rows -Detail $vals -Default $row -Current $now
        if ($pick -lt $names.Count) { return $Table[$names[$pick]] }
        $typed = Read-Default '  Value (e.g. 0x11)' $Default
        if ($typed -match '^(0[xX])?[0-9A-Fa-f]{1,2}$') { return $typed }
        Write-Host '  Not a byte.'
    }
}

# One display: identity is already known from NVAPI; what we need from the human is
# whether to manage it, what to call it, and which input THIS machine is on.
#
# Standard DDC/CI is the answer for everyone here, whatever the make. A manufacturer
# dialect is only reached for later, if the monitor test shows standard does not
# work -- see Invoke-DisplayTest.
function Get-DisplayAnswers {
    # $Existing is a PSCustomObject or $null -- deliberately untyped, because a
    # [hashtable] annotation here silently accepted the call at parse time and threw
    # a transformation error at RUN time, i.e. mid-walkthrough.
    param($Found, $Existing)

    $key  = '{0:X4}:{1:X4}' -f $Found.EdidVendor, $Found.EdidProduct
    # The panel's own name, out of its EDID. No table to be absent from.
    $desc = if ($Found.Name) { $Found.Name } else { ('{0} panel {1}' -f $Found.Mfg, $key) }

    Write-Host ''
    Write-Host ('  {0}   EDID {1}   {2}' -f $desc, $key, $Found.Connector)

    $defaultLabel = if ($Existing) { $Existing.Label } else { ($desc -split ' ')[0].ToLower() }
    if (-not (Read-YesNo '  Manage this monitor?' $true)) { return $null }

    $label = Read-Default '  Short name for it' $defaultLabel
    $label = ($label -replace '[^A-Za-z0-9_-]', '').ToLower()
    if (-not $label) { $label = $defaultLabel }

    # An existing method is a settled answer -- it was proven by someone watching the
    # screen. Do not quietly walk it back to standard on a re-run.
    $method = if ($Existing -and $Existing.Method) { $Existing.Method } else { 'standard' }
    $named  = if ($Existing) { $Existing.Named } else { [ordered]@{} }
    $table  = Get-InputTable -Method $method -Named $named

    $self = Read-InputValue -Table $table -Default $(if ($Existing) { $Existing.Self } else { '' }) `
        -Prompt ('On the {0} itself, which input shows THIS PC?' -f $desc) `
        -Sub    '(the input you would pick on the monitor to see this computer)'

    return [PSCustomObject]@{
        Label = $label; Name = $desc; Method = $method
        Vendor = ('0x{0:X4}' -f $Found.EdidVendor); Product = ('0x{0:X4}' -f $Found.EdidProduct)
        EdidVendor = $Found.EdidVendor; Mfg = $Found.Mfg; Key = $key
        Self = $self; Table = $table; Named = $named
    }
}

# Which devices travel with the switch. Returns the chosen keys.
function Read-Triggers {
    param($Cands, [string[]]$Current)

    Write-Host ''
    Write-Host '--- triggers ---'
    Write-Host 'Which devices move to this machine when you flip the switch?'
    Write-Host 'USB rows are attached right now; Bluetooth rows are everything paired.'
    Write-Host ''

    $checked = @()
    for ($i = 0; $i -lt $Cands.Count; $i++) { if ($Current -contains $Cands[$i].Key) { $checked += $i } }

    $help = '  Keyboards and mice often share a vendor id with something that never' + "`n" +
            '  moves. The full vendor+product is matched, so pick the exact rows.'

    $picked = Select-Many -Checked $checked -Help $help `
        -Items  @($Cands | ForEach-Object { '{0,-20} {1,-4}' -f $_.Key, $_.Bus }) `
        -Detail @($Cands | ForEach-Object { Get-CandidateLabel $_ })

    return @($picked | ForEach-Object { $Cands[$_].Key })
}

# When the watcher should start running. Returns 's4u' or 'user'.
#
# From boot is offered FIRST and is the default, because it is the answer that
# behaves the way people expect -- a PC sitting at a login screen still follows the
# switch. The cost is one UAC prompt during setup, and asking for it once beats
# discovering months later that switching quietly does nothing until you log in.
# A config that already says otherwise still wins: an existing choice is a choice.
function Read-Tier {
    param([string]$Current)

    Write-Host ''
    Write-Host '--- when should it start watching? ---'
    Write-Host '  It can start as soon as the computer starts, or after you log in for'
    Write-Host '  the first time. Starting before you log in needs administrator'
    Write-Host '  permission to set up -- once, now. Nothing runs elevated afterwards.'
    Write-Host ''
    $now = $(if ($Current -eq 'user') { 1 } elseif ($Current -eq 's4u') { 0 } else { -1 })
    $pick = Select-One -Default ([Math]::Max(0, $now)) -Current $now `
                       -Items @('From boot (requires admin)', 'After you log in')
    return $(if ($pick -eq 1) { 'user' } else { 's4u' })
}

# Ask about every attached display, pre-filled from whatever the config already
# says about that EDID. A function rather than an inline loop because the review
# menu re-enters it: "the monitors" has to be revisitable as one unit.
function Get-AllDisplayAnswers {
    # $Carry is names given during THIS walkthrough, keyed by EDID. They are not in
    # the config yet -- nothing is written until you save -- so without this,
    # re-entering the monitors section to change one value would silently throw away
    # everything the user just told us about their own inputs. Keyed by EDID rather
    # than by label because the label is one of the things they might be changing.
    param($Found, [hashtable]$Existing, [hashtable]$Carry = @{})

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
                        Label  = $l
                        Self   = $(if ($Existing.ContainsKey("display.$l.self"))   { $Existing["display.$l.self"] }   else { '' })
                        Method = $(if ($Existing.ContainsKey("display.$l.method")) { $Existing["display.$l.method"] } else { '' })
                        Named  = (Get-NamedInputs -Existing $Existing -Label $l)
                    }
                }
            }
        }
        if ($Carry.ContainsKey($key)) {
            if (-not $prior) { $prior = [PSCustomObject]@{ Label = ''; Self = ''; Method = ''; Named = [ordered]@{} } }
            $prior.Named = $Carry[$key]
        }
        $a = Get-DisplayAnswers -Found $f -Existing $prior
        if ($a) { $out += $a }
    }
    return $out
}

# The walkthrough. Current settings pre-fill every default, so a re-run is a review
# rather than a replay -- unless -Fresh, which starts from nothing.
#
# Two distinct roles for the old config, and -Fresh separates them: $seed supplies
# DEFAULTS, $existing is what must SURVIVE. Dropping both would silently discard
# hand-written scenes, so -Fresh clears the first and never touches the second.
#
# Nothing is written until every answer is in: an interrupted run must leave a
# working setup untouched, not a half-written config plus a task pointing at it.
function Invoke-Configure {
    param([switch]$Fresh)

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
    $seed     = if ($Fresh) { @{} } else { $existing }

    Write-Host ''
    Write-Host '=============================================================='
    Write-Host $(if ($isFirst) { ' trigger-kvm setup' } else { ' trigger-kvm reconfigure' })
    Write-Host '=============================================================='
    if ($Fresh -and -not $isFirst) {
        Write-Host ' Starting fresh -- nothing is pre-filled from the current setup.'
        Write-Host ' Scenes and anything else you hand-wrote are still kept.'
    } elseif (-not $isFirst) {
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
                # Field 6, and older copies of trigger-kvm.ps1 do not send it.
                Name        = $(if ($f.Count -ge 6) { $f[5] } else { '' })
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

    # Names collected during this run, surviving a trip back into the monitors
    # section. Merged into the config on save.
    $carry = @{}
    $answers = @(Get-AllDisplayAnswers -Found $found -Existing $seed -Carry $carry)

    if ($answers.Count -eq 0) {
        Write-Log 'no monitors selected -- nothing to do.'
        $global:LASTEXITCODE = 2
        return
    }

    # ---- triggers ----------------------------------------------------------
    $cands = @(Get-TriggerCandidates)
    $cur = @()
    if ($seed.ContainsKey('trigger.device')) {
        $cur = @(($seed['trigger.device'] -replace '\s','') -split ',' | Where-Object { $_ } | ForEach-Object {
            if ($_ -match '^(usb:|bt:)') { $_.ToLower() } else { 'usb:' + $_.ToLower() } })
    }
    $devices = @(Read-Triggers -Cands $cands -Current $cur)

    # ---- tier --------------------------------------------------------------
    # Empty, not 'user', when nothing is configured: Read-Tier reads that as "no
    # existing choice" and offers from-boot as the default. Passing 'user' here would
    # have quietly made the old default win under a menu that says otherwise.
    $newTier = Read-Tier $(if ($seed.ContainsKey('install.start')) {
                               $(if ($seed['install.start'] -eq 'boot') { 's4u' } else { 'user' })
                           } else { '' })

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
    # The same menu as everywhere else, so the review is not a new thing to learn:
    # the settings ARE the rows, and choosing one re-enters that section. Above the
    # save row so they read as "what you have already done"; cancel below it.
    #
    # A menu rather than a linear "go back one step" because the answer you got
    # wrong is rarely the last one you gave, and unwinding three sections to fix
    # the first is worse than re-entering the one that is wrong.
    # Three groups, separated by blank rows: what you set, what you can check, and
    # what ends the walkthrough. Seven flat rows read as seven equal choices; the
    # groups say which are edits, which are checks, and which are the way out.
    $ranDisplays = $null
    $ranTriggers = $null
    while ($true) {
        Write-Host ''
        Write-Host '--- review configuration ---'
        Write-Host ''

        $items  = @('Monitors', 'Trigger devices', 'When it starts')
        $detail = @(
            (($answers | ForEach-Object { '{0} on {1}' -f $_.Label, $_.Self }) -join ', ')
            ($devices -join ', ')
            $(if ($newTier -eq 's4u') { 'from boot' } else { 'after you log in' })
        )
        if (-not $onPath) {
            $items  += 'PATH'
            $detail += $(if ($wantPath) { "add $BINDIR" } else { 'leave it alone' })
        }

        $items  += ''; $detail += ''
        $items  += 'Test the trigger'
        $detail += $(if ($ranTriggers) { $ranTriggers.Text } else { 'untested' })
        $items  += 'Test the monitors'
        $detail += $(if ($ranDisplays) { $ranDisplays.Text } else { 'untested' })

        $items  += ''; $detail += ''
        $save = $items.Count
        $items += 'Save configuration and run'; $detail += ''
        $items += 'Cancel (discard changes)';   $detail += ''

        # Where the cursor lands is the recommendation, and it walks you through the
        # checks in order: trigger, then monitors, then save. A failure sends you to
        # the setting that failed rather than onward.
        $land =
            if     (-not $ranTriggers)  { $save - 3 }
            elseif (-not $ranTriggers.Ok) { 1 }
            elseif (-not $ranDisplays)  { $save - 2 }
            elseif (-not $ranDisplays.Ok) { 0 }
            else                        { $save }

        $pick = Select-One -Items $items -Detail $detail -Default $land
        if ($pick -eq $save) { break }
        if ($pick -eq $save + 1) {
            Write-Log 'cancelled; nothing was changed.'
            $global:LASTEXITCODE = 1
            return
        }
        switch ($items[$pick]) {
            'Monitors' {
                $again = @(Get-AllDisplayAnswers -Found $found -Existing $seed -Carry $carry)
                if ($again.Count -gt 0) { $answers = $again }
                else { Write-Host '  No monitors selected -- keeping the previous answers.' }
                # A pass belongs to the values that passed. Carrying it across an edit
                # would show "every monitor responded" beside numbers nothing tried.
                $ranDisplays = $null
            }
            'Trigger devices' {
                $devices = @(Read-Triggers -Cands $cands -Current $devices)
                $ranTriggers = $null
            }
            'When it starts'  { $newTier = Read-Tier $newTier }
            # Binary, so the row is the control: selecting it flips it. A yes/no
            # prompt for something already shown as "add it"/"leave it alone"
            # would just be a second way to say the same thing.
            'PATH'            { $wantPath = -not $wantPath }
            'Test the trigger'  { $ranTriggers = Invoke-TriggerTest -Devices $devices }
            'Test the monitors' {
                $ranDisplays = Invoke-DisplayTest -Answers $answers
                foreach ($a in $answers) { $carry[$a.Key] = $a.Named }
            }
        }
    }

    Write-ConfigFile -Path $CONFIG -Displays $answers -Devices $devices -Tier $newTier -Existing $existing
    Write-Log "wrote $CONFIG"

    if ($wantPath) { Add-ToUserPath -Dir $BINDIR }

    Write-Host ''
    Write-Log 'configured. Applying...'
    $global:LASTEXITCODE = 0
}

# Watch for one real arrival of the chosen devices. Asks event-watch.ps1 rather than
# re-deriving presence here: it owns that question, and a second implementation in
# the installer would be free to disagree with the one that actually fires -- which
# is the worst possible place for a disagreement, since this test exists to tell you
# the trigger works.
function Invoke-TriggerTest {
    param([string[]]$Devices)

    $ew = Join-Path $PSScriptRoot 'event-watch.ps1'
    if (-not (Test-Path $ew)) { $ew = $WATCH }

    Write-Host ''
    Write-Host '--- test the trigger ---'
    Write-Host '  This watches for the devices you picked to ARRIVE -- which is the'
    Write-Host '  event that switches your monitors.'
    if (Test-Path -LiteralPath $CONFIG) {
        Write-Host '  If trigger-kvm is already running, the flip will also switch your'
        Write-Host '  displays for real. That is fine, and is the thing working.'
    }

    & $ew -TestTrigger -Device ($Devices -join ',') -Config $CONFIG
    $code = $LASTEXITCODE

    if ($code -eq 0) { return [PSCustomObject]@{ Ok = $true; Text = 'saw the devices arrive' } }

    Write-Host ''
    Write-Host '  Nothing arrived, so these may be the wrong devices -- or they may not'
    Write-Host '  be on the switch at all. Pick Trigger devices again to change them.'
    return [PSCustomObject]@{ Ok = $false; Text = 'no arrival seen' }
}

# Prove the display answers BEFORE anything is written, against a throwaway config.
#
# The switcher takes its method and identity from a config file rather than from the
# command line -- deliberately, so there is one description of a panel and not two --
# so testing early means writing a temp one, not weakening the rule that nothing is
# written until you save. Returns what the review row should say.
#
# This is also where an unfamiliar panel gets sorted out, because it is the only
# place anyone is actually looking at the screen. Standard DDC/CI is what every
# panel was set up with; if it does nothing, the manufacturer's documented dialect
# is OFFERED here, and only here.
function Invoke-DisplayTest {
    param($Answers)

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('trigger-kvm-test-{0}.cfg' -f $PID)
    $bad = @()
    try {
        foreach ($a in $Answers) {
            # Re-written per panel: escalating to a dialect changes the method, and
            # the switcher reads the method from the file.
            Write-ConfigFile -Path $tmp -Displays $Answers -Devices @() -Tier 'user' -Existing @{}

            $verdict = Test-OnePanel -Answer $a -All $Answers -Config $tmp
            if (-not $verdict) { $bad += $a.Name }
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    if ($bad.Count -gt 0) { return [PSCustomObject]@{ Ok = $false; Text = ('no response from ' + ($bad -join ', ')) } }
    return [PSCustomObject]@{ Ok = $true; Text = 'all responded' }
}

# One panel: switch it away and back, then act on what the human saw. Retries after
# a fix, because bouncing out to the review menu to change one value and come back
# is a worse way to say "try that again".
function Test-OnePanel {
    param($Answer, $All, [string]$Config, [int]$Attempt = 1)

    # Any input but this machine's will do -- the test is only that the panel
    # CHANGES, so there is nothing to pick cleverly. Named, so the prompt can say
    # where it is going instead of showing a bare hex value.
    $otherName = $null; $other = $null
    foreach ($n in @($Answer.Table.Keys)) {
        if ($Answer.Table[$n] -ine $Answer.Self) { $otherName = $n; $other = $Answer.Table[$n]; break }
    }
    if (-not $other) { return $true }

    $outcome = Test-DisplayInput -Label $Answer.Label -Name $Answer.Name -Candidate $other `
                                 -CandidateName $otherName -Current $Answer.Self -Config $Config

    # 0: it worked. Offer to name what was on the other input while they are still
    # looking at it -- a name from their own desk beats anything we could ship, and
    # this is the one moment they know the answer.
    if ($outcome -eq 0) {
        $named = Read-Default ("  What is on the {0} input? (enter to skip)" -f $otherName) ''
        if ($named) {
            $Answer.Named[$named] = $other
            $Answer.Table = Get-InputTable -Method $Answer.Method -Named $Answer.Named
        }
        return $true
    }

    # 1: the panel obeys, so the channel is right; the value for THIS PC is not.
    if ($outcome -eq 1) {
        Write-Host ''
        Write-Host ('  So {0} responds -- the channel is right. The value for THIS PC is' -f $Answer.Name)
        Write-Host '  not. Use that monitor''s own buttons to bring it back to this PC, then'
        Write-Host '  tell me which input that is.'
        Write-Host ''
        if (Read-YesNo '  Do you know which input it is?' $true) {
            $Answer.Self = Read-InputValue -Table $Answer.Table -Default $Answer.Self `
                -Prompt ('Which input on the {0} shows THIS PC?' -f $Answer.Name)
        } else {
            $found = Invoke-BlindWalk -Answer $Answer -Config $Config -OtherPanels (@($All).Count - 1)
            if (-not $found) { return $false }
            $Answer.Self = $found
        }
        if ($Attempt -ge 2) { return $true }   # bounded: one retry, then take the answer
        Write-ConfigFile -Path $Config -Displays $All -Devices @() -Tier 'user' -Existing @{}
        return (Test-OnePanel -Answer $Answer -All $All -Config $Config -Attempt ($Attempt + 1))
    }

    # 2: nothing at all. The channel is wrong. This is where a manufacturer dialect
    # is offered -- offered, from documented values, never probed.
    $d = $DIALECTS['{0:X4}' -f $Answer.EdidVendor]
    if ($d -and $Answer.Method -ne $d.Method) {
        Write-Host ''
        Write-Host ('  {0} did not answer the standard channel. It is {1}, and some {1}' -f $Answer.Name, $d.What)
        Write-Host '  panels put input switching on a manufacturer channel instead. These'
        Write-Host ('  values are documented for {0}:' -f $d.What)
        Write-Host ''
        foreach ($n in $d.Inputs.Keys) { Write-Host ('    {0,-14} {1}' -f $n, $d.Inputs[$n]) }
        Write-Host ''
        if (Read-YesNo '  Try that channel instead?' $true) {
            $Answer.Method = $d.Method
            $Answer.Table  = Get-InputTable -Method $d.Method -Named $Answer.Named
            $Answer.Self   = Read-InputValue -Table $Answer.Table -Default '' `
                -Prompt ('Which input on the {0} shows THIS PC?' -f $Answer.Name)
            if ($Attempt -ge 2) { return $true }
            Write-ConfigFile -Path $Config -Displays $All -Devices @() -Tier 'user' -Existing @{}
            return (Test-OnePanel -Answer $Answer -All $All -Config $Config -Attempt ($Attempt + 1))
        }
        return $false
    }

    Write-Host ''
    Write-Host ('  {0} did not answer the standard channel, and no manufacturer values' -f $Answer.Name)
    Write-Host ('  are known here for {0}. That panel may not support DDC/CI input' -f $Answer.Mfg)
    Write-Host '  switching at all, or may use a channel nobody has documented.'
    Write-Host ''
    Write-Host '  Everything else is still configured; this monitor just will not follow'
    Write-Host '  the switch. Leave it out with Monitors -> "Manage this monitor? no".'
    return $false
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
        ("install.start = {0}" -f $(if ($Tier -eq 's4u') { 'boot' } else { 'login' }))
        ''
        '# --- displays ---------------------------------------------------------'
        '# method: standard (I2C src 0x51, VCP 0x60) -- what nearly every panel takes'
        '#         lg-alt   (src 0x50, VCP 0xF4) -- LG panels whose 0x60 is stubbed'
        '# self:   the input value where THIS machine is. Required.'
        '# input.<value>: your name for that input on that panel. Optional, and'
        '#         yours -- the walkthrough offers these before the standard names.'
        ''
    )
    foreach ($d in $Displays) {
        $lines += @(
            ("display.{0}.vendor  = {1}" -f $d.Label, $d.Vendor)
            ("display.{0}.product = {1}" -f $d.Label, $d.Product)
            ("display.{0}.name    = {1}" -f $d.Label, $d.Name)
            ("display.{0}.method  = {1}" -f $d.Label, $d.Method)
            ("display.{0}.self    = {1}" -f $d.Label, $d.Self)
        )
        # Value-first, so a name the user typed comes back exactly as they typed it:
        # Read-Config lower-cases keys and returns values verbatim.
        if ($d.PSObject.Properties['Named'] -and $d.Named) {
            foreach ($n in $d.Named.Keys) {
                $lines += ("display.{0}.input.{1} = {2}" -f $d.Label, ([string]$d.Named[$n]).ToLower(), $n)
            }
        }
        $lines += ''
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
# Connected-vs-paired belongs beside the name in both places that show candidates,
# so it is built once here rather than formatted twice.
function Get-CandidateLabel {
    param($Candidate)
    if ($Candidate.State) { return ('{0}  ({1})' -f $Candidate.Name, $Candidate.State) }
    return $Candidate.Name
}

function Get-TriggerCandidates {
    $rows = @()

    # --- USB: present PnP nodes, minus infrastructure -----------------------
    foreach ($d in (Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)) {
        if ($d.InstanceId -notmatch '^USB\\VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') { continue }
        $key  = ('usb:{0}:{1}' -f $Matches[1], $Matches[2]).ToLower()
        $name = $d.FriendlyName
        if (-not $name) { continue }

        # Hubs, controllers and the Bluetooth radio itself are attached permanently
        # and never move. A failed enumeration (vid 0000) is not addressable at all.
        if ($name -match 'Hub|Host Controller|Root Complex') { continue }
        if ($d.Class -eq 'Bluetooth') { continue }
        if ($key -like 'usb:0000:*') { continue }

        $rows += [PSCustomObject]@{
            Key   = $key
            Bus   = 'USB'
            Name  = $name
            Class = $d.Class
            State = ''
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
        [PSCustomObject]@{ Key = $_.Name; Bus = 'USB'; Name = $best.Name; Class = $best.Class
                           State = ''; Rank = $best.Rank }
    })

    # --- Bluetooth: every PAIRED device, connected or not --------------------
    #
    # Filtering to connected-only was wrong, and backwards. A trigger fires on
    # ARRIVAL, so the device that is disconnected right now is precisely the one
    # that will produce one: the headphones on the Mac connect to this PC when you
    # flip the switch. Hiding them meant the choice a user most wants was the one
    # they could not see. Connected/not is still shown -- it is useful context, but
    # it is not a filter.
    #
    # PnP cannot answer connected-vs-paired at all: a paired device keeps its node
    # for years after it last connected. event-watch.ps1 owns the Bluetooth binding,
    # so ask it rather than keeping a second copy of the P/Invoke here. Two copies
    # would drift, and a drifted struct layout is a marshalling bug that presents as
    # WRONG DATA rather than an error. Same shape as asking trigger-kvm.ps1 for the
    # display list.
    $bt = @()
    try {
        $rows = & (Join-Path $PSScriptRoot 'event-watch.ps1') -ListBluetooth 2>$null
        foreach ($row in $rows) {
            $parts = "$row" -split '\|', 3
            if ($parts.Count -lt 3) { continue }
            $bt += [PSCustomObject]@{
                Key = 'bt:' + $parts[0]; Bus = 'BT'; Name = $parts[2]; Class = 'Bluetooth'
                State = $(if ($parts[1] -eq 'True') { 'connected now' } else { 'paired, not connected' })
                Rank = 1
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
    Write-Host '=== devices that could be a trigger ==='
    Write-Host ''
    Write-Host 'The trigger is whatever MOVES when you flip the switch. Pick the ones that'
    Write-Host 'travel; USB rows are what is attached right now, Bluetooth rows what is paired.'
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
        Write-Host ('  {0,-20} {1,-4} {2,-18} {3}{4}' -f $d.Key, $d.Bus, $d.Class, (Get-CandidateLabel $d), $mark)
    }

    Write-Host ''
    Write-Host 'Bluetooth entries are every PAIRED device. One that is not connected right now'
    Write-Host 'is still a fine trigger -- better, even: a trigger fires on ARRIVAL, and that is'
    Write-Host 'what connecting is. USB rows are only devices attached at this moment, because'
    Write-Host 'PnP cannot tell you about a USB device that is somewhere else.'

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
    # re-run is a review rather than a replay; -Fresh starts from nothing instead.
    Invoke-Configure -Fresh:$Fresh
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

    # Say when it runs and what that therefore covers -- never a tier name. The
    # name was the internal label for the distinction and told a reader nothing they
    # could act on; what they want to know is whether a locked or logged-out PC still
    # follows the switch. The raw principal stays on the same line for diagnosis.
    $logon = $t.Principal.LogonType
    Write-Host ("starts   : {0}  (principal={1} logon={2} runlevel={3})" -f `
                $(switch ($logon) {
                    'S4U'         { 'at boot' }
                    'Interactive' { 'when you log in' }
                    default       { "unknown ($logon)" }
                  }), $t.Principal.UserId, $logon, $t.Principal.RunLevel)

    switch ($logon) {
        'Interactive' {
            Write-Host '           covers: from logon onward, including while LOCKED'
            Write-Host '           NOT covered: before the first login after a boot; after a logoff'
        }
        'S4U' {
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
    $childArgs = @('install')
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

        # The check above ran BEFORE there was a config to read, so a walkthrough
        # that asked for boot start would otherwise be silently ignored and the task
        # registered as the login one. Re-derive and elevate here instead. This is
        # the common path now that boot start is the default answer.
        $EffectiveTier = Get-EffectiveTier
        if ($EffectiveTier -eq 's4u' -and -not $IsElevated) {
            $childArgs = @('install')
            if ($AddToPath) { $childArgs += '-AddToPath' }
            exit (Request-Elevation -ChildArgs $childArgs)
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
    'install.tier'            = 'install.start'
}
foreach ($old in $renamed.Keys) {
    if ($cfg.ContainsKey($old)) {
        Write-Log ("WARNING: '{0}' is an old key name; rename it to '{1}' in {2}." -f $old, $renamed[$old], $CONFIG)
        if ($old -eq 'install.tier') {
            Write-Log "         The values changed too: 's4u' is now 'boot', 'user' is now 'login'."
            Write-Log '         This one is still honoured meanwhile, and `trigger-kvm configure`'
            Write-Log '         rewrites the file without it.'
        } else {
            Write-Log '         Until you do, the seed defaults are used instead of your value.'
        }
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
Set-ConfigValue -Path $CONFIG -Key 'install.start' -Value $(if ($EffectiveTier -eq 's4u') { 'boot' } else { 'login' })

Start-ScheduledTask -TaskName $TASK
Write-Log ("registered and started task '{0}' (starts {1})" -f $TASK, `
           $(if ($EffectiveTier -eq 's4u') { 'at boot' } else { 'when you log in' }))

if ($AddToPath) { Add-ToUserPath -Dir $BINDIR }

# What is left to say is short: it is running, when it will run again, how to see
# that, and the four things you can do to it. Everything else -- tiers, sessions,
# the transport -- is in the docs for the day someone needs it, and is noise on the
# day they do not.
$onPath = @((Get-UserPath -split ';')) -contains $BINDIR
$cmd    = if ($onPath) { 'trigger-kvm' } else { $SHIM }
$when   = if ($EffectiveTier -eq 's4u') { 'each time the computer reboots' }
          else                          { 'each time you log in' }

Write-Host ''
Write-Host ('  Done. trigger-kvm is running, and will start automatically {0}.' -f $when)
Write-Host ''
Write-Host '  Flip your switch to this PC -- the monitors should follow.'
Write-Host ''
Write-Host ("    {0} status      is it running?" -f $cmd)
Write-Host ("    {0} pull        bring the displays here now" -f $cmd)
Write-Host ("    {0} logs        what has it been doing" -f $cmd)
Write-Host ("    {0} configure   change any of this" -f $cmd)
Write-Host ''
