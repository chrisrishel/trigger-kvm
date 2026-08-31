<#
.SYNOPSIS
Install the Windows half of display-switch as a Scheduled Task.

.DESCRIPTION
    .\install.ps1              install and start (user tier -- no admin needed)
    .\install.ps1 -Tier s4u    pre-login tier -- NEEDS ADMIN to register
    .\install.ps1 -Status      which tier is installed, and what it can do
    .\install.ps1 -Logs        tail the log
    .\install.ps1 -Uninstall   stop, unregister, remove installed files

Mirrors macos/Makefile. Installs to %LOCALAPPDATA%\Programs\display-switch.

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
cannot dedupe across them. usb-watch.ps1 also takes a machine-wide mutex as
defence in depth.

The tier is a property of the HOST, not of the switcher. Nothing in
switch-displays.ps1 or usb-watch.ps1 knows or asks which tier it runs under. If
either ever needs to, the abstraction is wrong -- stop and rethink.

Why s4u is possible at all: measured 2026-08-30, NVAPI both enumerates and
WRITES from session 0 with no desktop -- an unelevated S4U task moved the LG in
both directions, confirmed visually. The old blocker was dxva2 needing an
HMONITOR, and that path no longer exists. See ..\ARCHITECTURE.md.

No third-party binary and no network access: both monitors are driven by code in
this repo. The LG used to need lg-input-switch.exe, a 16MB GPL-3.0 download; it is
now driven by an aimed NVAPI I2C write from switch-displays.ps1, so the download,
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
    [Parameter(ParameterSetName = 'Logs')]      [switch]$Logs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TASK    = 'display-switch'
$DEST    = Join-Path $env:LOCALAPPDATA 'Programs\display-switch'
$LOG     = Join-Path $env:LOCALAPPDATA 'display-switch\displayswitch.log'
$WATCH   = Join-Path $DEST 'usb-watch.ps1'
$SWITCH  = Join-Path $DEST 'switch-displays.ps1'
$LGEXE   = Join-Path $DEST 'lg-input-switch.exe'   # legacy; removed on install/uninstall
$VBS     = Join-Path $DEST 'launcher.vbs'

# Watched USB devices -- the peripherals that actually move through the USB
# switch. Keyboard and mouse are wired directly to this PC and never move, so
# they cannot be the trigger. Keep in sync with ..\displays.toml.
$DEVICES  = '046d:0843,1235:820a'
$DEBOUNCE = '3.0'
$SETTLE   = '0.75'

function Write-Log { param([string]$m) Write-Host "install: $m" }

# Stopping the task kills its launcher but NOT the powershell watcher underneath,
# which is a grandchild and outlives it. Left behind, a stale watcher keeps holding
# the single-instance mutex and the newly installed one exits immediately -- so an
# upgrade would silently keep running the old code. Clear them explicitly.
function Stop-Watchers {
    $procs = Get-CimInstance Win32_Process -Property ProcessId,Name,CommandLine -Verbose:$false |
        Where-Object {
            $_.CommandLine -and (
                ($_.Name -eq 'wscript.exe'    -and $_.CommandLine -match 'launcher\.vbs') -or
                ($_.Name -eq 'powershell.exe' -and $_.CommandLine -match 'usb-watch\.ps1')
            )
        }
    foreach ($p in $procs) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Log ("stopped stale {0} (pid {1})" -f $p.Name, $p.ProcessId)
    }
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
           Where-Object { $_.CommandLine -and $_.Name -eq 'powershell.exe' -and $_.CommandLine -match 'usb-watch\.ps1' }).Count
    Write-Host ("watchers : {0}{1}" -f $n, $(if ($n -eq 1) { '' } else { '  <- expected exactly 1' }))
    Write-Host ("log      : {0}" -f $LOG)
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

New-Item -ItemType Directory -Force -Path $DEST              | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $LOG)  | Out-Null

Copy-Item (Join-Path $PSScriptRoot 'usb-watch.ps1')       $WATCH  -Force
Copy-Item (Join-Path $PSScriptRoot 'switch-displays.ps1') $SWITCH -Force
Write-Log "installed scripts to $DEST"

# Migration: older installs downloaded lg-input-switch.exe here. The LG is now
# driven by an aimed NVAPI write inside switch-displays.ps1, so the binary is dead
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
    '-Arg', 'windows',
    '-Device', $DEVICES,
    '-Debounce', $DEBOUNCE,
    '-Settle', $SETTLE,
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

Register-ScheduledTask -TaskName $TASK -Action $action -Trigger $triggers `
    -Principal $principal -Settings $settings `
    -Description "display-switch ($Tier tier): pull both monitors to this PC when the shared USB peripherals arrive." | Out-Null

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
