<#
.SYNOPSIS
Install the Windows half of display-switch as a Scheduled Task at logon.

.DESCRIPTION
    .\install.ps1              install and start
    .\install.ps1 -Status      is the task registered and running?
    .\install.ps1 -Logs        tail the log
    .\install.ps1 -Uninstall   stop, unregister, remove installed files

Mirrors macos/Makefile. Installs to %LOCALAPPDATA%\Programs\display-switch and
registers a Scheduled Task that runs usb-watch.ps1 in the interactive session at
logon.

Post-login by design, matching macOS. A Windows Service runs in session 0, which
has no desktop: GetPhysicalMonitorsFromHMONITOR would have no HMONITOR to work
from. See ..\ARCHITECTURE.md.

lg-input-switch.exe is not vendored into the repo -- it is a 16MB third-party
binary. It is downloaded from a pinned release and checked against a known SHA256.
#>

[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
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
$LGEXE   = Join-Path $DEST 'lg-input-switch.exe'
$VBS     = Join-Path $DEST 'launcher.vbs'

# Watched USB devices -- the peripherals that actually move through the USB
# switch. Keyboard and mouse are wired directly to this PC and never move, so
# they cannot be the trigger. Keep in sync with ..\displays.toml.
$DEVICES  = '046d:0843,1235:820a'
$DEBOUNCE = '3.0'
$SETTLE   = '0.75'

# Pinned third-party dependency: github.com/meer-cha/lg-input-switch
$LG_TAG    = 'v1.2.2'
$LG_URL    = "https://github.com/meer-cha/lg-input-switch/releases/download/$LG_TAG/lg-input-switch-$LG_TAG.zip"
$LG_ZIP_SHA = '7C64B923A4F8B609F7877312599401B76578A6782E50548A7762EA4719663C37'
$LG_EXE_SHA = 'DBC634AA7E711B72380146C8C6EBBE85BB8CF3A8177C32D7F24949424A7338AA'

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
    Write-Host ("task     : {0}" -f $t.State)
    Write-Host ("last run : {0} (result {1})" -f $i.LastRunTime, $i.LastTaskResult)
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

New-Item -ItemType Directory -Force -Path $DEST              | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $LOG)  | Out-Null

Copy-Item (Join-Path $PSScriptRoot 'usb-watch.ps1')       $WATCH  -Force
Copy-Item (Join-Path $PSScriptRoot 'switch-displays.ps1') $SWITCH -Force
Write-Log "installed scripts to $DEST"

# lg-input-switch: fetch the pinned release unless a verified copy is present.
$needFetch = $true
if (Test-Path -LiteralPath $LGEXE) {
    if ((Get-FileHash $LGEXE -Algorithm SHA256).Hash -eq $LG_EXE_SHA) {
        Write-Log "lg-input-switch $LG_TAG already present (sha256 ok)"
        $needFetch = $false
    } else {
        Write-Log 'existing lg-input-switch.exe has an unexpected hash; replacing'
    }
}

if ($needFetch) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "lg-input-switch-$LG_TAG.zip"
    Write-Log "downloading lg-input-switch $LG_TAG"
    Invoke-WebRequest -Uri $LG_URL -OutFile $tmp -UseBasicParsing

    $got = (Get-FileHash $tmp -Algorithm SHA256).Hash
    if ($got -ne $LG_ZIP_SHA) {
        Remove-Item $tmp -Force
        throw "lg-input-switch $LG_TAG sha256 mismatch: expected $LG_ZIP_SHA, got $got"
    }

    $stage = Join-Path ([IO.Path]::GetTempPath()) "lg-input-switch-$LG_TAG"
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $tmp -DestinationPath $stage -Force
    Copy-Item (Join-Path $stage 'lg-input-switch.exe') $LGEXE -Force
    Remove-Item $tmp -Force
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

    $got = (Get-FileHash $LGEXE -Algorithm SHA256).Hash
    if ($got -ne $LG_EXE_SHA) { throw "extracted lg-input-switch.exe sha256 mismatch: got $got" }
    Write-Log "installed lg-input-switch $LG_TAG (sha256 verified)"
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

$triggers = @(
    (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME)
)

# Self-heal. AtLogOn alone means that if the watcher is ever killed -- Task Manager,
# a crash, a stray Stop-Process -- it stays dead until the next logon, and you would
# only find out when the displays silently stopped following the USB switch. This
# second trigger re-runs it every 5 minutes; MultipleInstances IgnoreNew below makes
# that a no-op whenever it is already alive, so the steady-state cost is nothing.
$heal = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 5)
$heal.Repetition.Duration = ''      # empty means indefinitely
$triggers += $heal

# Interactive session, normal user rights: this needs a desktop for HMONITOR and
# deliberately does not need admin.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Limited

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
    -Description 'display-switch: pull both monitors to this PC when the shared USB peripherals arrive.' | Out-Null

Start-ScheduledTask -TaskName $TASK
Write-Log "registered and started task '$TASK'"
Write-Log "log: $LOG"
