<#
.SYNOPSIS
Install the Windows half of trigger-kvm as a Scheduled Task.

.DESCRIPTION
    .\install.ps1              install and start (user tier -- no admin needed)
    .\install.ps1 -Tier s4u    pre-login tier -- NEEDS ADMIN to register
    .\install.ps1 -Status      which tier is installed, and what it can do
    .\install.ps1 -Logs        tail the log
    .\install.ps1 -Uninstall   stop, unregister, remove installed files

Mirrors macos/Makefile. Installs to %LOCALAPPDATA%\Programs\trigger-kvm.

TWO TIERS, and you pick by what you are willing to grant:

  user (default)  Runs at logon, in your interactive session, unelevated.
                  NO ADMIN, at install or at run time.
                  Covers everything from logon onward -- including while the
                  screen is LOCKED, since the session and watcher stay alive.
                  Does not cover: before the first login after a boot, or after
                  a full logoff.

  s4u             Runs at startup, in session 0, as you, still UNELEVATED.
                  ADMIN ONCE, to register the task. Nothing elevated runs on
                  the switch path afterwards.
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
this repo. The LG used to need lg-input-switch.exe, a 16MB GPL-3.0 download; it is
now driven by an aimed NVAPI I2C write from trigger-kvm.ps1, so the download,
its pinned SHA256 check and the install-time network dependency are all gone. A
stale copy left by an older install is removed below.
#>

[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    # user: logon task, your session, no admin. s4u: at-startup task, session 0,
    # still runs as you and still unelevated, but needs admin ONCE to register.
    [Parameter(ParameterSetName = 'Install')]
    [ValidateSet('user', 's4u')]
    [string]$Tier = 'user',

    [Parameter(ParameterSetName = 'Uninstall')] [switch]$Uninstall,
    [Parameter(ParameterSetName = 'Status')]    [switch]$Status,
    [Parameter(ParameterSetName = 'Logs')]      [switch]$Logs,

    # Show what is attached, in the form the config wants. Changes nothing.
    [Parameter(ParameterSetName = 'Discover')]  [switch]$Discover
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

# Seed values, used ONLY when generating a config that does not exist yet. Once the
# file is written it is the source of truth and these are never consulted again --
# so editing the config is how you change things, not editing this.
$SEED_DEVICES  = '046d:0843,1235:820a'
$SEED_DEBOUNCE = '3.0'
$SEED_SETTLE   = '0.75'

function Write-Log { param([string]$m) Write-Host "install: $m" }

# --- configuration ----------------------------------------------------------

# Same three-line reader as trigger-kvm.ps1. Duplicated rather than shared: a
# dot-sourced module would be a fourth file to keep in step across two install
# locations, and this is smaller than the plumbing that would avoid it.
function Read-Config {
    param([string]$Path)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^\s*([A-Za-z0-9_.\-]+)\s*=\s*(.*?)\s*(?:#.*)?$') {
            $map[$Matches[1].ToLower()] = $Matches[2]
        }
    }
    return $map
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
        '# Displays and scenes take effect on the next switch. Trigger settings are'
        '# baked into the scheduled task, so changing those needs install.ps1 re-run.'
        '#'
        '# Displays are identified by the EDID the GPU reads off the output, never by'
        '# index -- \\.\DISPLAYn numbers are not stable and have swapped on this'
        '# machine. Find yours with:  .\nvapi-probe.ps1'
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
        '# device:   VVVV:PPPP pairs. Match the FULL vendor+product -- a vendor-only'
        '#           match fires constantly, because the keyboard and mouse share a'
        '#           vendor id with the webcam and never move.'
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

# --- discovery ---------------------------------------------------------------

# Candidate trigger devices: USB devices that are attached RIGHT NOW.
#
# "Attached right now" is the filter that does most of the work, and it comes from
# how installing actually happens -- you run this on the machine that currently
# holds the peripherals, so the devices that move are by definition present. That is
# far more discriminating than any heuristic about device class.
#
# The rest is noise removal. Hubs and host controllers never move through a USB
# switch, and one physical device usually enumerates several PnP nodes sharing a
# VID:PID (a webcam appears as a composite parent plus camera and audio children),
# so entries are grouped by VID:PID and the most specific name in each group wins.
function Get-TriggerCandidates {
    $rows = @()
    foreach ($d in (Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)) {
        if ($d.InstanceId -notmatch '^USB\\VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') { continue }
        $key  = ('{0}:{1}' -f $Matches[1], $Matches[2]).ToLower()
        $name = $d.FriendlyName
        if (-not $name) { continue }

        # Infrastructure, not peripherals. These are attached permanently and would
        # only pad the list.
        if ($name -match 'Hub|Host Controller|Root Complex') { continue }

        $rows += [PSCustomObject]@{
            Key   = $key
            Name  = $name
            Class = $d.Class
            # Rank by how specific the class is. 'USB' is the generic fallback node;
            # a real Camera/AudioEndpoint/Image entry names the device far better.
            Rank  = $(switch -Regex ($d.Class) {
                        'Camera|Image'            { 0 }
                        'AudioEndpoint|MEDIA'     { 1 }
                        'HIDClass|Mouse|Keyboard' { 2 }
                        'USB'                     { 4 }
                        default                   { 3 }
                     })
        }
    }

    # One row per VID:PID, keeping the best-named entry.
    return @($rows | Group-Object Key | ForEach-Object {
        $best = $_.Group | Sort-Object Rank | Select-Object -First 1
        [PSCustomObject]@{ Key = $_.Name; Name = $best.Name; Class = $best.Class; Rank = $best.Rank }
    } | Sort-Object Rank, Name)
}

if ($Discover) {
    Write-Host ''
    Write-Host '=== displays on this machine ==='
    & (Join-Path $PSScriptRoot 'trigger-kvm.ps1') list -Config $CONFIG

    Write-Host ''
    Write-Host '=== USB devices attached right now ==='
    Write-Host ''
    Write-Host 'The trigger is whatever MOVES when you flip the switch. Everything below is'
    Write-Host 'attached to this machine at this moment; pick the ones that travel.'
    Write-Host ''

    $cur = @()
    if (Test-Path -LiteralPath $CONFIG) {
        $c = Read-Config -Path $CONFIG
        if ($c.ContainsKey('trigger.device')) { $cur = @(($c['trigger.device'] -replace '\s','') -split ',') }
    }

    foreach ($d in (Get-TriggerCandidates)) {
        $mark = $(if ($cur -contains $d.Key) { ' <- currently a trigger' } else { '' })
        Write-Host ('  {0,-12} {1,-18} {2}{3}' -f $d.Key, $d.Class, $d.Name, $mark)
    }

    Write-Host ''
    Write-Host 'TRAP: match the FULL vendor+product pair. A keyboard and mouse often share a'
    Write-Host 'vendor id with a webcam and are always present, so a vendor-only match fires'
    Write-Host 'constantly. Set trigger.device in the config, then re-run install.ps1.'
    Write-Host ("config: {0}" -f $CONFIG)
    exit 0
}

# --- status / logs / uninstall ---------------------------------------------

if ($Status) {
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
    Write-Host ("config   : {0}{1}" -f $CONFIG, $(if (Test-Path -LiteralPath $CONFIG) { '' } else { '  <- MISSING; run install.ps1' }))

    $c = Read-Config -Path $CONFIG
    $labels = @($c.Keys | Where-Object { $_ -match '^display\.([^.]+)\.vendor$' } | ForEach-Object { $Matches[1] } | Sort-Object -Unique)
    $scenes = @($c.Keys | Where-Object { $_ -match '^scene\.([^.]+)\.' }          | ForEach-Object { $Matches[1] } | Sort-Object -Unique)
    Write-Host ("displays : {0}" -f $(if ($labels) { $labels -join ', ' } else { 'none configured' }))
    Write-Host ("scenes   : {0}" -f $(if ($scenes) { ($scenes -join ', ') + '   (manual only; the trigger never uses these)' } else { 'none' }))
    exit 0
}

if ($Logs) {
    if (-not (Test-Path -LiteralPath $LOG)) { Write-Host "no log yet at $LOG"; exit 1 }
    Get-Content -LiteralPath $LOG -Tail 50 -Wait
    exit 0
}

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask    -TaskName $TASK -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TASK -Confirm:$false
        Write-Log "unregistered task '$TASK'"
    }
    Stop-Watchers
    Remove-LegacyInstall
    # Leave the log in place; it is the only record of what happened.
    foreach ($f in @($WATCH, $SWITCH, $LGEXE, $VBS)) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force; Write-Log "removed $f" }
    }
    Write-Log 'uninstalled.'
    exit 0
}

# --- install ----------------------------------------------------------------

# Constraint: never install a tier that will silently fail. The s4u tier cannot be
# registered without elevation -- measured, S4U registration returns "Access is
# denied" for an ordinary user -- so check up front and say so, rather than letting
# Register-ScheduledTask fail halfway through with the files already copied.
$elevated = ([Security.Principal.WindowsPrincipal] `
             [Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($Tier -eq 's4u' -and -not $elevated) {
    Write-Host ''
    Write-Host 'The s4u tier needs admin to REGISTER the task (it then runs unelevated).'
    Write-Host 'Re-run this from an elevated PowerShell:'
    Write-Host ''
    Write-Host '    .\install.ps1 -Tier s4u'
    Write-Host ''
    Write-Host 'Or install the no-admin tier instead, which covers everything from logon'
    Write-Host 'onward including while locked:'
    Write-Host ''
    Write-Host '    .\install.ps1'
    Write-Host ''
    throw 'elevation required for -Tier s4u'
}

New-DefaultConfig -Path $CONFIG

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
Write-Log "watching: $devices  (debounce ${debounce}s, settle ${settle}s)"

New-Item -ItemType Directory -Force -Path $DEST              | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $LOG)  | Out-Null

Copy-Item (Join-Path $PSScriptRoot 'event-watch.ps1')     $WATCH  -Force
Copy-Item (Join-Path $PSScriptRoot 'trigger-kvm.ps1') $SWITCH -Force
Write-Log "installed scripts to $DEST"

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
    '-Device', $devices,
    '-Debounce', $debounce,
    '-Settle', $settle,
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
if ($Tier -eq 's4u') {
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

if (Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TASK -Confirm:$false
}
Stop-Watchers
Remove-LegacyInstall

Register-ScheduledTask -TaskName $TASK -Action $action -Trigger $triggers `
    -Principal $principal -Settings $settings `
    -Description "trigger-kvm ($Tier tier): pull both monitors to this PC when the shared USB peripherals arrive." | Out-Null

Start-ScheduledTask -TaskName $TASK
Write-Log "registered and started task '$TASK' ($Tier tier)"
Write-Log "log: $LOG"

if ($Tier -eq 's4u') {
    Write-Log ''
    Write-Log 'Installed the pre-login tier. It runs at startup in session 0, as you,'
    Write-Log 'unelevated. Nothing elevated runs on the switch path.'
    Write-Log ''
    Write-Log 'UNVERIFIED until you test it: log out (or reboot) and flip the USB switch'
    Write-Log 'to this PC. The displays should follow with no one logged in. The SWITCHER'
    Write-Log 'is proven in session 0; what that test exercises is whether the WMI device'
    Write-Log 'notification reaches a session-0 watcher.'
} else {
    Write-Log 'Installed the no-admin tier: covers logon onward, including while locked.'
    Write-Log 'For before-first-login and after-logoff, see: .\install.ps1 -Tier s4u'
}
