<#
.SYNOPSIS
Install and manage trigger-kvm on Windows.

.DESCRIPTION
BOOTSTRAP, run from the source tree. This is what installing IS:

    .\install.ps1                  copy files, register the task, start it
    .\install.ps1 -AddToPath       ...and put `trigger-kvm` on PATH

Afterwards it is one command from anywhere:

    trigger-kvm configure          the walkthrough; current settings pre-fill it
    trigger-kvm status             what is installed, running and configured
    trigger-kvm discover           what this computer can see right now
    trigger-kvm restart            make a hand-edited config take effect now
    trigger-kvm logs               follow the log
    trigger-kvm pause              stand the watcher down to run one by hand
    trigger-kvm uninstall

THERE IS NO `install` VERB ON THE CLI, deliberately: installing is what got you
the CLI. Upgrading and repairing both mean "fetch the source and run its
installer", which works because this script installs itself alongside the
program. There is no `apply` step either: everything is read at the point it is
used, so a display edit takes effect on the next switch and a trigger edit when
the watcher next starts.

The verbs are the same on both platforms (specs/README.md). Flags stay idiomatic
per platform -- -AddToPath here, --add-to-path there -- because forcing the
POSIX spelling into PowerShell means hand-parsing $args and losing parameter
binding, validation and completion.

WHEN IT STARTS is recorded in the config as install.autostart and chosen by what
you are willing to grant. There is no flag for it: the walkthrough asks, the
config records the answer, and the installer applies what it finds.

    boot    Runs at startup, in session 0, as you, still UNELEVATED. Admin ONCE,
            to register the task. Nothing elevated runs on the switch path
            afterwards. Internally an S4U task.
    login   Runs at logon, in your interactive session, unelevated. No admin at
            all. Covers everything from logon onward, including while LOCKED.
            Not covered: before the first login after a boot, or after a logoff.
            This is what a headless install falls back to.
    no      Registered with no triggers and started now, for this session only.

The two automatic tiers are mutually exclusive by construction: they share one
task name, so installing either replaces the other. event-watch.ps1 also takes a
mutex covering the whole computer as defence in depth, because two live watchers
in different sessions would both fire on the same arrival and the debounce is
per-process.

This is a property of the HOST, not of the switcher. Nothing in trigger-kvm.ps1
or event-watch.ps1 knows or asks when it was started.

No third-party binary and no network access: both monitors are driven by code in
this repo.

The file map is in README.md; the flow this implements is in ..\specs\.
#>

[CmdletBinding()]
param(
    # Checked against $VERBS below rather than by a ValidateSet, so the verb
    # surface is written down once (config.ps1) and an unknown verb gets this
    # program's own message rather than a binding error naming half of it.
    [Parameter(Position = 0)]
    [string]$Command = 'install',

    # Put the install directory on the user PATH so `trigger-kvm` works
    # anywhere. Opt-in: editing someone's PATH without asking is rude, and the
    # walkthrough asks properly once it exists.
    [switch]$AddToPath,

    # `configure -Fresh`: ask everything from scratch instead of pre-filling
    # from the current setup. For when the desk changed enough that the old
    # answers are the wrong starting point. Hand edits are still preserved.
    [switch]$Fresh,

    # Never show a UAC prompt; print what to run instead and exit non-zero. For
    # scripted installs, where a modal dialog is a hang, not a prompt.
    [switch]$NoElevate,

    # Set only on the elevated relaunch, to stop an elevation that does not take
    # from looping UAC prompts forever. Not for humans.
    [switch]$Relaunched,

    # WHO THIS INSTALL IS FOR. Set only on the elevated relaunch, and not for
    # humans either. See Get-ChildArguments in lib\host.ps1 for why the child
    # cannot answer this for itself.
    [string]$ForUser = '',
    [string]$ForAppData = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# What this process was actually given, so the elevated relaunch forwards it
# without a second list to keep in step.
$INVOKED_WITH = $PSBoundParameters

$IsElevated = ([Security.Principal.WindowsPrincipal] `
               [Security.Principal.WindowsIdentity]::GetCurrent()
              ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# WHO THIS INSTALL IS FOR, resolved once. THE ONLY PLACE $env:LOCALAPPDATA AND
# $env:USERNAME ARE READ: everything else builds on $APPDATA and $FORUSER, so
# there is one answer to "whose install is this?" rather than one per use, and
# tests\conventions.tests.ps1 holds it here the way the I2C gate is held to one
# door.
$ME      = "$env:USERDOMAIN\$env:USERNAME"
$FORUSER = $(if ($ForUser)    { $ForUser }    else { $ME })
$APPDATA = $(if ($ForAppData) { $ForAppData } else { $env:LOCALAPPDATA })

# --- where everything lives ---------------------------------------------------

# The source tree, or the installed copy this is running from. $PSScriptRoot
# inside lib\ is lib\, so this is the one answer every file reads.
$TK_HOME = $PSScriptRoot

# THIS PROGRAM, as a path to paste or to hand a child process. $PSCommandPath is
# per FILE, not per program: inside a function defined in lib\ it is that lib
# file (measured), which has no param() block -- so an elevated relaunch built
# from it runs a library, does nothing and exits 0, and the parent reports the
# install as done. tests\conventions.tests.ps1 keeps both names out of lib\.
$TK_SELF = $PSCommandPath

$TASK    = 'trigger-kvm'
$DEST    = Join-Path $APPDATA 'Programs\trigger-kvm'
$LIBDIR  = Join-Path $DEST 'lib'
$LOG     = Join-Path $APPDATA 'trigger-kvm\trigger-kvm.log'
$WATCH   = Join-Path $DEST 'event-watch.ps1'
# SWITCHER, not SWITCH: $switch is PowerShell's own, holding the enumerator of
# whichever switch statement is running -- and the verb dispatch at the bottom of
# this file IS one, so inside it, and inside everything it calls, the constant
# read as EMPTY. tests\conventions.tests.ps1 keeps every name here off that list.
$SWITCHER = Join-Path $DEST 'trigger-kvm.ps1'
$CFGLIB  = Join-Path $DEST 'config.ps1'
$VBS     = Join-Path $DEST 'launcher.vbs'
$MANAGE  = Join-Path $DEST 'install.ps1'      # this script, installed alongside
$STAMP   = Join-Path $DEST 'version.txt'

# ONLY this directory goes on PATH, and it holds ONLY the shim. Putting $DEST
# there publishes every file in it as a command, because PATHEXT includes .VBS
# -- measured: `launcher.vbs` resolves as a bare `launcher`, a generic name that
# starts the watcher.
$BINDIR  = Join-Path $DEST 'bin'
$SHIM    = Join-Path $BINDIR 'trigger-kvm.cmd'

# Files an earlier layout of THIS install left inside $DEST, which nothing else
# would ever clean up. Removed on install and on uninstall. Delete this list
# once no machine can still have one.
$EARLIER_LAYOUT = @(
    (Join-Path $DEST 'trigger-kvm.cmd')       # the shim, before it moved to bin\
    (Join-Path $DEST 'usb-watch.ps1')         # renamed to event-watch.ps1
    (Join-Path $DEST 'lg-input-switch.exe')   # a 16MB GPL binary the LG used to need
)

# Machine-local configuration, beside the log rather than in $DEST, so that
# uninstalling does not throw away a configuration that represents real work.
$CONFIG = Join-Path (Split-Path $LOG) 'config'

# Recorded at install time and shown by `status`. Not an updater -- updating is
# "fetch the new source and run it" -- but it answers the question that bites:
# is what is installed what I think it is?
$VERSION = '0.2.0'

# Used ONLY when generating a config that does not exist yet. Timings, not
# identities: a default debounce is a reasonable thing to ship, a default DEVICE
# is not -- the pair that used to sit here were one desk's webcam and audio
# interface, and anyone whose config lacked trigger.device would quietly have
# been given them to watch.
$DEFAULT_DEBOUNCE = '3.0'
$DEFAULT_SETTLE   = '0.75'

# --- the program --------------------------------------------------------------
#
# config.ps1 is the shared vocabulary, dot-sourced by all three entry scripts.
# lib\ is this one's: the menus, the walkthrough, the checks, discovery and the
# host verbs. A new file there joins by existing.
. (Join-Path $TK_HOME 'config.ps1')

# Said rather than thrown. Under $ErrorActionPreference = 'Stop' a missing lib\
# is a stack trace about Get-ChildItem, which reads as a broken program rather
# than as a half-copied one -- and a half-copied install is exactly when this
# happens.
$libDir = Join-Path $TK_HOME 'lib'
if (-not (Test-Path -LiteralPath $libDir -PathType Container)) {
    Write-Host "install: $libDir is missing, so this copy is incomplete."
    Write-Host 'install: fetch the source and run its install.ps1 again.'
    exit 1
}
foreach ($f in (Get-ChildItem -LiteralPath $libDir -Filter '*.ps1' -File | Sort-Object Name)) {
    . $f.FullName
}

# Installing into somebody else's profile is what elevation is for, and without
# it the copies would fail halfway rather than not at all. Refused rather than
# attempted: a half-written install in the wrong profile is the failure the
# -ForUser pair exists to prevent.
if ($FORUSER -ne $ME -and -not $IsElevated) {
    Write-Log "asked to install for $FORUSER, which needs administrator rights."
    exit 1
}

# --- the verb -----------------------------------------------------------------

if ($Command -notin (Get-Verbs -Where 'manage')) {
    Write-Host ("trigger-kvm: no such verb ""{0}""." -f $Command)
    Write-Host ''
    Get-UsageText | ForEach-Object { Write-Host $_ }
    exit 2
}

# EXIT 2 FOR EVERY USAGE PATH, an explicit `help` included, because macOS's
# usage() does. Exit 0 for an explicit request is the more conventional choice
# and was written that way first; it was changed on purpose, because two
# implementations of one CLI disagreeing about an exit code is the drift this
# repo spends a conformance check preventing.
if ($Command -eq 'help') {
    Get-UsageText | ForEach-Object { Write-Host $_ }
    exit 2
}

if ($Command -eq 'configure') {
    Invoke-Configure -Fresh:$Fresh
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    # Applying is a CONSEQUENCE of configuring, not a thing to invoke -- which
    # is why there is no apply verb. Re-running the install path covers both
    # cases: a tier change needs the task re-registered, and anything else needs
    # the watcher restarted, which registering does anyway.
    Write-Log ''
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath install
    exit $LASTEXITCODE
}

# Each verb returns its exit code and prints through Write-Host, which does not
# reach the pipeline -- so a stray value from any of them would show up here as
# an array and fail loudly rather than becoming the exit code silently.
$code = switch ($Command) {
    'discover'  { Invoke-Discover; 0 }
    'status'    { Invoke-Status }
    'restart'   { Invoke-Restart }
    'pause'     { Invoke-Pause }
    'logs'      { Invoke-Logs }
    'uninstall' { Invoke-Uninstall }
    default     { Invoke-Install }
}
exit $code
