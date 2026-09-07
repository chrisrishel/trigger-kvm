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
SETTINGS -- only the absolute path of the file to read them from, which the
watcher cannot work out for itself in session 0 -- and edits take effect when it
next starts. `configure` restarts it for you; `restart` is there for hand-edits.

VERBS, and the same verbs on macOS. You use both computers daily, so the words you
type constantly are where cross-platform muscle memory is worth buying. Flags stay
idiomatic per platform (-AddToPath here, --add-to-path there): forcing the POSIX
spelling into PowerShell means hand-parsing $args and losing parameter binding,
validation and completion, which is a real cost for a cosmetic gain.

WHEN IT STARTS, recorded in the config as install.autostart, and chosen by what you
are willing to grant. There is no flag for it and no name for it in anything a
user reads -- the walkthrough asks, the config records the answer, and the
installer applies what it finds. It was called a "tier" for a while, which told a
reader nothing they could act on:

  install.autostart = boot   Runs at startup, in session 0, as you, still
                           UNELEVATED. ADMIN ONCE, to register the task --
                           prompted for via UAC. Nothing elevated runs on the
                           switch path afterwards. This is what the walkthrough
                           offers first, because it behaves the way people
                           expect. Internally: an S4U task, $EffectiveTier 's4u'.

  install.autostart = login  Runs at logon, in your interactive session,
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
cannot dedupe across them. event-watch.ps1 also takes a mutex covering the whole
computer as defence in depth.

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
    [ValidateSet('install', 'help', 'configure', 'status', 'discover', 'restart', 'logs', 'pause', 'uninstall')]
    [string]$Command = 'install',

    # Put the install directory on the user PATH so `trigger-kvm` works anywhere.
    # Opt-in: editing someone's PATH without asking is rude, and the interactive
    # setup will ask properly once it exists.
    [switch]$AddToPath,

    # `configure -Fresh`: ask everything from scratch instead of pre-filling the
    # answers from the current setup. For when the desk changed enough that the old
    # answers are the wrong starting point -- a new monitor, a rebuilt hub -- and
    # enter-through would carry a stale value forward without you reading it.
    # Everything you hand-wrote is still preserved.
    [switch]$Fresh,

    # Never show a UAC prompt; print what to run instead and exit non-zero. For
    # scripted installs, where a modal dialog on a headless run is a hang, not a
    # prompt.
    [switch]$NoElevate,

    # Set only on the elevated relaunch, to stop an elevation that does not take
    # from looping UAC prompts forever. Not for humans.
    [switch]$Relaunched,

    # WHO THIS INSTALL IS FOR. Set only on the elevated relaunch, and not for
    # humans either.
    #
    # `-Verb RunAs` from a STANDARD account elevates a DIFFERENT user: on a family
    # or corporate PC the person at the keyboard is not an admin, so the child that
    # comes back is somebody else. Left to derive its own answers it would install
    # into the admin's profile and register the task as the admin, and the user's
    # watcher would never start -- with nothing saying so.
    #
    # These are the two facts the parent knows for certain and the child cannot
    # work out: the identity every task principal is registered as, and the
    # LOCALAPPDATA every path is built from. They are two facts, not one -- a
    # redirected LOCALAPPDATA is not derivable from an account name.
    [string]$ForUser = '',
    [string]$ForAppData = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$IsElevated = ([Security.Principal.WindowsPrincipal] `
               [Security.Principal.WindowsIdentity]::GetCurrent()
              ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# WHO THIS INSTALL IS FOR, resolved once. See the -ForUser parameter for why the
# elevated child cannot be left to answer this for itself.
#
# THE ONLY PLACE $env:LOCALAPPDATA AND $env:USERNAME ARE READ. Everything below
# builds on $APPDATA and $FORUSER, so there is one answer to "whose install is
# this?" rather than one per use -- and a check in tests/conventions.tests.ps1
# holds it to that, the way the I2C gate is held to one door.
$ME      = "$env:USERDOMAIN\$env:USERNAME"
$FORUSER = $(if ($ForUser)    { $ForUser }    else { $ME })
$APPDATA = $(if ($ForAppData) { $ForAppData } else { $env:LOCALAPPDATA })

# Installing into somebody else's profile is exactly what elevation is for, and
# without it the copies would fail halfway rather than not at all. Refused rather
# than attempted: a half-written install in the wrong profile is the failure this
# whole parameter pair exists to prevent.
if ($FORUSER -ne $ME -and -not $IsElevated) {
    Write-Host "install: asked to install for $FORUSER, which needs administrator rights."
    exit 1
}

$TASK    = 'trigger-kvm'
$DEST    = Join-Path $APPDATA 'Programs\trigger-kvm'
$LOG     = Join-Path $APPDATA 'trigger-kvm\trigger-kvm.log'
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
$OLD_DEST = Join-Path $APPDATA 'Programs\display-switch'
$OLD_LOG  = Join-Path $APPDATA 'display-switch\displayswitch.log'

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
# Timings, not identities. A default debounce is a reasonable thing to ship; a
# default DEVICE is not -- the pair that used to sit here were this desk's webcam and
# audio interface, and anyone whose config lacked trigger.device would have quietly
# been given them to watch.
$DEFAULT_DEBOUNCE = '3.0'
$DEFAULT_SETTLE   = '0.75'

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
    # $CONFIG, not Get-ConfigPath: the elevated child must read the config of the
    # user it is installing FOR, and Get-ConfigPath answers for whoever is running.
    # Two spellings of one path can disagree; one cannot.
    $c = Read-Config -Path $CONFIG
    if ($c.Contains('install.autostart')) {
        switch ($c['install.autostart']) {
            'boot'  { return 's4u' }
            'login' { return 'user' }
            'no'    { return 'manual' }
        }
    }
    # The old spelling still counts. Unlike the other renamed keys, ignoring this one
    # would not fall back to a harmless default -- it would silently DOWNGRADE a
    # working boot-start install to login-only on the next install, with the loss
    # showing up months later as "switching does nothing at the login screen". The
    # rename warning still fires, and `configure` rewrites the file without it.
    if ($c.Contains('install.start')) {
        switch ($c['install.start']) { 'boot' { return 's4u' } 'login' { return 'user' } }
    }
    if ($c.Contains('install.tier') -and $c['install.tier'] -in @('user', 's4u')) {
        return $c['install.tier']
    }
    # Deliberately NOT the walkthrough's default. The walkthrough offers from-boot
    # first because it can ask for the UAC prompt and get an answer; a headless or
    # scripted install cannot, so it takes the tier that needs no elevation. Nothing
    # ever elevates without someone choosing it.
    return 'user'
}

# --- elevation --------------------------------------------------------------

# $IsElevated is resolved at the top of the file, beside $FORUSER: the two
# together decide whether this process may install for the user it was told to.

# The child is started by handing a STRING to powershell -Command, so its argument
# list has to survive being written out and parsed again. A user name or a profile
# path may contain a space -- "First Last" -- and a plain `-join ' '` does not
# survive one.
#
# Measured 2026-09-01 (docs/measurements.md), because two obvious shapes both look
# right and neither works:
#   & $f @args                    -- array splat binds every element POSITIONALLY:
#                                    "A positional parameter cannot be found that
#                                    accepts argument '-AddToPath'".
#   & $f install -ForUser A B     -- "...accepts argument 'B'".
# Flag names must stay BARE (a quoted '-ForUser' is a positional string, not a
# parameter name) and values must be quoted. So this quotes exactly the elements
# that are not flags.
function Format-ChildArguments {
    param([string[]]$ChildArgs)

    return (@($ChildArgs | ForEach-Object {
        if ($_ -match '^-\w+$') { $_ }
        else { "'" + ($_ -replace "'", "''") + "'" }
    }) -join ' ')
}

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

    # WHO the install is for travels with it, always. The child cannot work this
    # out: on a standard account the elevated process is a different user, and
    # every path and principal it derived for itself would be that admin's.
    $ChildArgs = @($ChildArgs) + @('-ForUser', $FORUSER, '-ForAppData', $APPDATA)

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
        # Quoted, because this line is meant to be pasted and a profile path with a
        # space in it would not survive being retyped bare either.
        Write-Host ("Run this from an elevated PowerShell:  & '{0}' {1}" -f $PSCommandPath, (Format-ChildArguments $ChildArgs))
        return 1
    }

    $transcript = Join-Path ([IO.Path]::GetTempPath()) ("trigger-kvm-elevated-{0}.log" -f [Guid]::NewGuid().ToString('N').Substring(0,8))
    $inner = "& '{0}' {1} -Relaunched *> '{2}'" -f $PSCommandPath, (Format-ChildArguments $ChildArgs), $transcript

    Write-Log 'this needs administrator rights; approving the UAC prompt will continue.'
    try {
        $p = Start-Process powershell.exe -Verb RunAs -Wait -WindowStyle Hidden -PassThru `
             -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $inner)
    } catch {
        # The user declined the prompt, or no admin credentials were available.
        # What happens NEXT is the caller's to say -- an uninstall stops here, an
        # install falls back to the login tier -- so this line no longer claims
        # that nothing was changed.
        Write-Log 'elevation was declined or unavailable.'
        return 1
    }

    if (Test-Path -LiteralPath $transcript) {
        Get-Content -LiteralPath $transcript | ForEach-Object { Write-Host $_ }
        Remove-Item -LiteralPath $transcript -Force -ErrorAction SilentlyContinue
    }
    return $p.ExitCode
}

# The boot tier needs administrator rights ONCE, to register the task. Ask for
# them; if they do not come, say so and install the tier that needs none.
#
# specs/configure.md 8: where elevation cannot be obtained -- a headless install,
# or a prompt that was declined -- the boot tier FALLS BACK TO LOGIN, SAYS SO,
# and the config records login, not what was asked for. Silently keeping `boot`
# is how someone finds out months later that switching does nothing until they
# log in.
#
# This used to exit 1 with the config still saying boot, the OLD watcher still
# running against the OLD trigger devices, and a message claiming nothing had
# been changed -- when the config had been rewritten a moment earlier. macOS has
# done the right thing here since revision 4.
#
# Returns the tier to install. Exits when the elevated child did the whole
# install itself, which is the successful case.
function Invoke-BootTierElevation {
    $rc = Request-Elevation -ChildArgs @('install')
    if ($rc -eq 0) {
        # The PATH is the one thing the child could not do: on a standard account
        # its HKCU is the ADMIN's hive. See Set-InstalledPath.
        Set-InstalledPath
        exit 0
    }
    Write-Log 'falling back to starting at login.'
    Write-Log 'the switch will follow from your logon onward, but not at the login screen.'
    Write-Log 'to try again for the boot tier:  trigger-kvm configure'
    Set-ConfigValue -Path $CONFIG -Key 'install.autostart' -Value 'login'
    return 'user'
}

# --- PATH -------------------------------------------------------------------

# User PATH only -- never the machine one. This installs per-user and needs no
# admin, and quietly editing a system-wide setting would be a much bigger thing
# than the user agreed to.
#
# READ AND WRITTEN THROUGH THE REGISTRY, NOT THROUGH [Environment]. Measured
# 2026-09-01: SetEnvironmentVariable(...,'User') writes REG_SZ whatever it is
# given, and GetEnvironmentVariable(...,'User') expands %VAR% references, because
# that is what reading a REG_EXPAND_SZ value means. Between them, answering yes to
# the PATH question read every %USERPROFILE%-style entry the user already had as
# a literal path and wrote it back that way -- with the value's KIND downgraded,
# so nothing there would ever follow its variable again.
#
# It does not reproduce on a machine whose Path is already REG_SZ, which is what
# it becomes after the first time. A fresh Windows profile's is REG_EXPAND_SZ.
#
# -KeyPath so the suite can point this at a throwaway key of its own. The real
# PATH is the developer's own working setup, and a test must not be one edit away
# from it.
function Get-UserPath {
    param([string]$KeyPath = 'Environment')
    try {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($KeyPath, $false)
        if (-not $k) { return '' }
        try {
            return [string]$k.GetValue('Path', '',
                       [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        } finally { $k.Close() }
    } catch { return '' }
}

# REG_EXPAND_SZ where the value needs it or already had it; REG_SZ otherwise, so
# a machine whose PATH is plain is not gratuitously changed into something else.
function Get-PathValueKind {
    param([string]$Value, [string]$Current)
    if ($Value -match '%')            { return 'ExpandString' }
    if ($Current -eq 'ExpandString')  { return 'ExpandString' }
    return 'String'
}

function Set-UserPath {
    param([string]$Value, [string]$KeyPath = 'Environment')

    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($KeyPath, $true)
    if (-not $k) { $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($KeyPath) }
    try {
        $was = 'String'
        try { $was = [string]$k.GetValueKind('Path') } catch { }
        $k.SetValue('Path', $Value,
                    [Microsoft.Win32.RegistryValueKind](Get-PathValueKind -Value $Value -Current $was))
    } finally { $k.Close() }

    if ($KeyPath -eq 'Environment') { Send-SettingChange }
}

# Tell everyone the environment changed.
#
# A registry write notifies nobody. Explorer -- and therefore every terminal
# started from it -- re-reads the environment on WM_SETTINGCHANGE, which is what
# [Environment]::SetEnvironmentVariable used to send on our behalf. Without it
# "open a NEW terminal for that to take effect" stops being true and the answer
# becomes "log out".
#
# Guarded by NAME only, with no source stamp -- unlike the transports in
# trigger-kvm.ps1 and event-watch.ps1, which stamp because running a stale copy
# of THEM would mean hand-verifying code that is not on disk. This declares one
# Win32 entry point whose signature has been fixed since 1995 and carries no
# logic to be stale.
function Send-SettingChange {
    if (-not ('TkSettingChange' -as [type])) {
        Add-Type -ErrorAction SilentlyContinue -Name 'TkSettingChange' -Namespace '' -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
                                               string lParam, uint fuFlags, uint uTimeout,
                                               out UIntPtr lpdwResult);
'@
    }
    try {
        $r = [UIntPtr]::Zero
        # HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG, 5s. A hung window
        # must not hold up an install.
        [void][TkSettingChange]::SendMessageTimeout([IntPtr]0xFFFF, 0x1A, [UIntPtr]::Zero,
                                                    'Environment', 0x0002, 5000, [ref]$r)
    } catch {
        # Nothing here is worth failing an install for: the PATH is written
        # either way, and the worst case is that it takes effect at next logon.
        Write-Log 'note: could not announce the PATH change; a new logon will pick it up'
    }
}

function Add-ToUserPath {
    param([string]$Dir)
    $cur = Get-UserPath
    $parts = @(($cur -split ';') | Where-Object { $_ })
    if ($parts -contains $Dir) { Write-Log "already on PATH: $Dir"; return }
    Set-UserPath (@($parts + $Dir) -join ';')
    Write-Log "added to your PATH: $Dir"
    Write-Log 'open a NEW terminal for that to take effect'
}

function Remove-FromUserPath {
    param([string]$Dir)
    $cur = Get-UserPath
    $parts = @(($cur -split ';') | Where-Object { $_ })
    if ($parts -notcontains $Dir) { return }
    Set-UserPath (@($parts | Where-Object { $_ -ne $Dir }) -join ';')
    Write-Log "removed from your PATH: $Dir"
}

# THE USER PATH BELONGS TO THE USER WHOSE PATH IT IS, AND ONLY A PROCESS RUNNING
# AS THEM MAY EDIT IT. Both helpers above go through 'User' scope, which is
# HKCU\Environment -- and in an elevated child on a standard account, HKCU is the
# ADMIN'S hive. A child asked to do this would edit the wrong person's PATH and
# report that it had done what was asked.
#
# So the child never does it, and it never needs to: PATH is per-user and has
# never required elevation. The parent -- which is running as the right user --
# does this itself once the child comes back clean.
# Both verbs, because the rule is about WHO may edit a PATH, not about which way
# the edit goes -- and an uninstall that left the entry behind would be the same
# defect wearing the other hat.
function Set-InstalledPath {
    # An earlier layout put $DEST itself on PATH, which published launcher.vbs as a
    # bare `launcher` command. Undone on every install.
    Remove-FromUserPath -Dir $DEST
    if ($AddToPath) { Add-ToUserPath -Dir $BINDIR }
}

function Clear-InstalledPath {
    Remove-FromUserPath -Dir $BINDIR
    Remove-FromUserPath -Dir $DEST      # an earlier layout put this one on PATH
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

# THE INPUT MAP, AND THE FACT THAT NOTHING CAN CHECK IT -- specs/status.md 3.
#
# The map is an assertion about which physical socket each computer's cable is in.
# If a cable moves to a different input ON THE MONITOR, a panel whose EDID product
# id is stable across its inputs (the ASUS reports 0x42E0 on every one) still
# resolves perfectly, so `pull` sends the old value and the panel switches to an
# input with nothing on it: black screen, silently, with a success in the log. A
# panel with a per-input product id refuses instead, and fails safe.
#
# Detection is BARRED, not merely unimplemented -- reading the value back is
# forbidden (..\AGENTS.md hard rule 2) and answers the wrong question anyway, and a
# success code proves nothing (hard rule 3). See
# ..\ideas\knowing-which-input-you-are-on.md for why no "switch to whoever is
# talking" command exists to sidestep it. So the only move left is making the
# failure legible and cheap to recover, which is all this is.
#
# Returns the lines rather than printing them, so the suite can reach the decision
# without a status run -- same shape as Get-WatcherCommand.
function Get-InputMapReport {
    param($Cfg, [string[]]$Labels, [string]$This, [string[]]$Computers)

    if (-not $Labels) { return @('inputs   : none configured') }

    $out = @('inputs   : (which computer is on which input of each monitor)')
    foreach ($label in $Labels) {
        # In the order the computers were listed, NOT by input value
        # (specs/config-format.md, "Ordering"): sorting on the hex puts the same two
        # computers in opposite orders on two panels, purely by which socket each
        # happened to be in. Ordered this way, this block and `computers` agree.
        $rows = @($Cfg.Keys |
            Where-Object { $_ -match ('^display\.' + [regex]::Escape($label) + '\.input\.(.+)$') } |
            ForEach-Object {
                [pscustomobject]@{ Value = $Matches[1]; Who = "$($Cfg[$_])".Trim().ToLower() }
            })
        $map = @($rows |
            Sort-Object @{ Expression = {
                $i = [array]::IndexOf([string[]]$Computers, $_.Who)
                if ($i -lt 0) { [int]::MaxValue } else { $i } } }, Value |
            ForEach-Object {
                '{0} = {1}{2}' -f $_.Value, $_.Who,
                    $(if ($_.Who -eq $This) { ' (this one)' } else { '' })
            })
        $out += ("           {0,-8} {1}" -f $label,
                 $(if ($map) { $map -join ', ' } else { 'no inputs mapped' }))
    }
    # specs/status.md 3.1. The warning is the point of the block; the map above it
    # is only what the warning is about.
    $out += '           ^ asserted, never verified. If a cable moved to another input on'
    $out += '             the monitor, pull switches that panel to a dead input and it goes'
    $out += '             black, with a success in the log. Fix: trigger-kvm configure'
    return $out
}

# The configured triggers, named wherever this computer can currently see them.
#
# `trigger.device` holds vendor+product pairs, which is the only thing a watcher
# can match on -- and `usb:046d:c547` tells a person nothing. This is the same
# legibility problem the Triggers menu had: the answer is to say what the device
# IS beside the id, not instead of it.
#
# A trigger that is NOT here is the ordinary case, not a fault: the peripherals
# are on the other computer, which is exactly when somebody runs `status` to ask
# why nothing switched. So the absence is stated plainly and the footnote says it
# is normal, rather than leaving a blank that reads as broken.
#
# TAKES THE RAW CONFIG VALUE and parses it here, through the one parser every
# consumer uses. It used to take a pre-normalised list of keys, and the caller
# doing that normalising is what let `status` disagree with the watcher about the
# same line of the same file -- see ConvertFrom-TriggerDevices in config.ps1.
#
# [CmdletBinding()] so a caller left on the old -Devices name THROWS. A simple
# function swallows an undeclared named argument into $args without a word, and
# this one would then report "none configured" for a perfectly good config.
function Get-TriggerReport {
    [CmdletBinding()]
    param([string[]]$Entries, $Candidates)

    $devs = @(ConvertFrom-TriggerDevices $Entries)
    if ($devs.Count -eq 0) { return @('triggers : none configured  <- nothing will ever fire') }

    $by = @{}
    foreach ($c in @($Candidates)) { if ($c) { $by[$c.Key] = $c } }

    $out     = @()
    $missing = 0
    $bad     = 0
    for ($i = 0; $i -lt $devs.Count; $i++) {
        $label = $(if ($i -eq 0) { 'triggers :' } else { '          ' })
        $d = $devs[$i]
        # Malformed FIRST, and it is not a kind of missing. Counted as missing it
        # would draw the "normal when the switch is on the other computer" note,
        # which is the tool reassuring somebody about the exact entry that is
        # stopping the watcher from starting.
        if (-not $d.Ok) {
            $name = 'MALFORMED -- the watcher will refuse to start on this'
            $bad++
        }
        elseif ($by.Contains($d.Identity)) { $name = Get-CandidateLabel $by[$d.Identity] }
        else { $name = '-- not attached right now'; $missing++ }
        # AS WRITTEN, never canonicalised: this is the string to go looking for
        # in the config file, and for a malformed entry it is the only way the
        # screen and the file say the same thing.
        $out += ('{0} {1,-20} {2}' -f $label, $d.Raw, $name)
    }
    # NAMED, not pointed at with a `^`. The absent-device note below already owns
    # that arrow, and when both fire two arrows point up at different rows with
    # nothing to say which is which.
    if ($bad -gt 0) {
        $out += '           a MALFORMED line is not a device: the watcher will not start'
        $out += '           until it is fixed or removed.  Fix:  trigger-kvm configure'
    }
    if ($missing -gt 0) {
        $out += '           ^ normal when the switch is on the other computer: that is'
        $out += '             what these devices arriving here is going to mean.'
    }
    return $out
}

# How the switch reaches each panel, and where that takes away coverage the
# autostart line has already promised -- specs/status.md 4.
#
# The tier statement above is about the TIER, and a transport can make it untrue
# for ONE panel while it stays true for the others: a machine installed from boot
# correctly reports that it covers the login screen and still has a monitor that
# will not move until somebody logs in. Reporting only the tier would be accurate
# and misleading at once.
#
# This is the same fact `configure` names when the transport is chosen. `status`
# is where somebody looks afterwards, having forgotten choosing it or inherited
# the machine.
function Get-TransportReport {
    param($Cfg, [string[]]$Labels, [switch]$FromBoot)

    if (-not $Labels) { return @() }

    $rows     = @()
    $stranded = @()
    foreach ($label in $Labels) {
        $k = "display.$label.transport"
        # Absent means nvapi, so a config written before the key existed reads as
        # the transport it has always used rather than as unanswered.
        $t = $(if ($Cfg.Contains($k)) { "$($Cfg[$k])".Trim().ToLower() } else { 'nvapi' })
        $note = switch ($t) {
            'nvapi' { 'through the graphics card' }
            'dxva2' { 'through Windows; not before somebody logs in' }
            # Named, not corrected. The switcher refuses an unrecognised transport
            # by name rather than defaulting (specs/config-format.md), so status
            # says the same thing instead of quietly reporting a working panel.
            default { 'UNRECOGNISED -- the switch will refuse this panel' }
        }
        $rows += ("           {0,-8} {1,-6} ({2})" -f $label, $t, $note)
        if ($DESKTOP_TRANSPORTS -contains $t) { $stranded += $label }
    }

    $out = @('reaches  : (how the switch reaches each monitor)') + $rows
    if ($FromBoot -and $stranded.Count -gt 0) {
        $out += '           ^ the autostart line above says it covers the login screen.'
        $out += ("             It does not for {0}: nothing moves that panel until" -f (Join-Names $stranded))
        $out += '             somebody has logged in.'
    }
    return $out
}

# One `trigger-kvm list -Raw` line -> the row the walkthrough and `status` both
# read. ONE parser, deliberately: the fields are APPEND-ONLY, so every reader has
# to default the ones an older switcher does not send, and a rule like that only
# stays consistent while it lives in a single place.
#
# Returns $null for a line that is not a row, so a caller filters rather than
# guarding on field counts itself.
function ConvertFrom-DisplayRow {
    param([string]$Line)

    $f = "$Line" -split '\|'
    if ($f.Count -lt 4) { return $null }
    return [PSCustomObject]@{
        EdidVendor  = [Convert]::ToInt32($f[0], 16)
        EdidProduct = [Convert]::ToInt32($f[1], 16)
        Mfg         = $f[2]
        Connector   = $f[3]
        # Field 6, and older copies of trigger-kvm.ps1 do not send it.
        Name        = $(if ($f.Count -ge 6) { $f[5] } else { '' })
        # Field 7, comma-joined: which transports can SEE this panel. Absent means
        # nvapi -- the same default specs/config-format.md gives the key -- so an
        # installer newer than the switcher beside it asks nothing and keeps
        # writing what that switcher understands.
        Transports  = $(if ($f.Count -ge 7 -and $f[6]) {
                            @($f[6] -split ',' | Where-Object { $_ })
                        } else { @('nvapi') })
        # Field 8: how many ATTACHED panels answer to this id. Absent means one,
        # which is what every desk without twins reports anyway -- so an installer
        # newer than the switcher beside it simply never refuses on it.
        # specs/configure.md 6.4.
        Panels      = $(if ($f.Count -ge 8 -and $f[7] -match '^\d+$') {
                            [int]$f[7]
                        } else { 1 })
    }
}

# specs/status.md 5. SILENT unless it has something to say: an id in the config
# that right now answers for more than one attached panel. By the time anyone
# reads `status` the switch has already refused that panel, and the refusal only
# ever reached the log -- which is not where a person looks when a monitor they
# have had for a year quietly stops following.
#
# $Attached maps 'VVVV:PPPP' to how many attached panels answer to it: field 8 of
# `trigger-kvm list -Raw`. A configured id that is merely ABSENT is a different
# state with a different remedy, and is deliberately not reported here.
function Get-DisplayAmbiguityReport {
    param($Cfg, [string[]]$Labels, [hashtable]$Attached)

    if (-not $Labels -or $null -eq $Attached -or $Attached.Count -eq 0) { return @() }

    $rows = @()
    foreach ($label in $Labels) {
        $v = ConvertTo-Word $Cfg["display.$label.vendor"]
        $p = ConvertTo-Word $Cfg["display.$label.product"]
        # An unparseable id matches nothing rather than matching 0x0000 -- the
        # same refusal Get-ConfiguredDisplays makes, for the same reason.
        if ($null -eq $v -or $null -eq $p) { continue }
        $key = '{0:X4}:{1:X4}' -f $v, $p
        # Absent and ambiguous are different states with different remedies, and
        # only the second is this block's (specs/status.md 5.2). The Contains
        # check is redundant TODAY -- a missing key reads as $null and $null -le 1
        # is already true -- and it is kept deliberately, because "a missing value
        # is not zero" is the rule this project follows everywhere else, and
        # leaning on the coercion would make the next edit here a trap. There is
        # no mutation for it in mutate.ps1: the two forms behave identically, so
        # nothing could catch its removal, and a mutation nothing can catch is
        # noise rather than proof.
        if (-not $Attached.Contains($key)) { continue }
        if ($Attached[$key] -le 1) { continue }
        $rows += ("           {0,-8} 0x{1:X4}:0x{2:X4}  {3} of them" -f $label, $v, $p, $Attached[$key])
    }
    if ($rows.Count -eq 0) { return @() }

    # No "run configure" here, deliberately: it cannot fix this and saying so
    # would be a fix this tool does not have (specs/status.md 5.2).
    return @('AMBIGUOUS: more than one attached monitor matches an id in this config') + $rows +
           @('           the switch refuses rather than guessing, so those panels do not',
             '           follow. Unplug one of each pair -- nothing here can tell them apart.')
}

# IS A WATCHER RUNNING? Asked of event-watch.ps1, which owns the single-instance
# lock, for the same reason -ListBluetooth and -TestTrigger are asked of it: a
# second implementation here would be free to disagree with the lock that actually
# decides. See that script for why the lock and not the process table.
#
# This is NOT the question Stop-Watchers asks. That one needs PIDs to kill and runs
# elevated, where CommandLine is readable; this one needs a yes/no from wherever it
# is called. Two questions, two answers, deliberately not merged.
function Test-WatcherRunning {
    $ew = Join-Path $PSScriptRoot 'event-watch.ps1'
    if (-not (Test-Path -LiteralPath $ew -PathType Leaf)) { $ew = $WATCH }
    if (-not (Test-Path -LiteralPath $ew -PathType Leaf)) { return $false }
    Invoke-Sibling -Script $ew -Arguments @('-IsRunning') | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# IS THIS OURS? The rename happened precisely because haimgel/display-switch
# already owns that name, so "anything called display-switch" is exactly the
# wrong test: a user who also has that tool -- or a scheduled task they named
# that themselves -- would lose it on our first run, unasked and unexplained.
#
# The marker is our own GENERATED LAUNCHER: a launcher.vbs that starts one of
# our watchers. Nothing else writes that file, it was written by every install
# of the old layout, and it costs one read to check.
function Test-OurLegacyDir {
    param([string]$Path)
    $vbs = Join-Path $Path 'launcher.vbs'
    if (-not (Test-Path -LiteralPath $vbs -PathType Leaf)) { return $false }
    return ((Get-Content -Raw -LiteralPath $vbs) -match '(usb|event)-watch\.ps1')
}

# The same question about a task: does its action start one of our watchers, or
# point into the directory our old install used? Anything else with that name
# belongs to somebody else.
function Test-OurLegacyTask {
    param($Task, [string]$OldDest)
    $act = @($Task.Actions | ForEach-Object { '{0} {1}' -f $_.Execute, $_.Arguments }) -join ' '
    if ($act -match '(usb|event)-watch\.ps1') { return $true }
    if ($act -match 'launcher\.vbs')          { return $true }
    return ($OldDest -and $act -match [regex]::Escape($OldDest))
}

# STAND THE INSTALLED WATCHER DOWN, and bring it back. One definition, because
# `pause`, `restart` and the trigger check all mean the same thing by it and a
# second spelling would be a second thing to keep right.
#
# Stopping the task is NOT enough, twice over, and both traps have caught people
# (including the docs, which used to give this advice incompletely):
#
#   1. The watcher is a GRANDCHILD of the task -- the task runs wscript.exe,
#      which runs powershell.exe. Stopping the task kills the shim and leaves
#      the watcher holding the single-instance mutex, so a hand-run watcher
#      exits immediately with "another watcher is already running".
#   2. The 1-minute self-heal trigger would start it again within the minute.
#      The task has to be DISABLED, not merely stopped.
function Suspend-Watcher {
    Disable-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue | Out-Null
    Stop-ScheduledTask    -TaskName $TASK -ErrorAction SilentlyContinue
    Stop-Watchers
}

function Resume-Watcher {
    Enable-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue | Out-Null
    Start-ScheduledTask  -TaskName $TASK -ErrorAction SilentlyContinue
}

# Can the installed watcher be stood down here, without a password?
#
# 'none'       nothing is installed, so there is nothing to stand down
# 'can'        it is ours to disable
# 'needs-admin' it is not: the task DEFINITION under System32\Tasks is owned by
#              whoever registered it, and the boot tier requires an administrator
#              to register. Disabling it would prompt, and specs/configure.md 11
#              says a check must not ask for a password -- it says the watcher
#              will fire and lets the person read that before they flip.
#
# Asked of the INSTALLED task rather than of the config, because the walkthrough
# may have changed the answer in memory and not saved it yet. What matters here
# is what is running.
function Get-WatcherPauseMode {
    $t = Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
    if (-not $t) { return 'none' }
    if ($t.Principal.LogonType -eq 'S4U' -and -not $IsElevated) { return 'needs-admin' }
    return 'can'
}

# Remove what a pre-rename install left behind -- OURS ONLY. Stop-Watchers above
# already kills the old watcher process (its regex matches both watcher names),
# which is what releases the old mutex.
function Remove-LegacyInstall {
    $ours = $false

    $t = Get-ScheduledTask -TaskName $OLD_TASK -ErrorAction SilentlyContinue
    if ($t) {
        if (Test-OurLegacyTask -Task $t -OldDest $OLD_DEST) {
            $ours = $true
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
        } else {
            Write-Log ("a scheduled task called '{0}' is registered here but is not one of ours; left alone." -f $OLD_TASK)
        }
    }

    if (Test-Path -LiteralPath $OLD_DEST) {
        if (Test-OurLegacyDir -Path $OLD_DEST) {
            $ours = $true
            Remove-Item -LiteralPath $OLD_DEST -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "removed the pre-rename program directory $OLD_DEST"
        } else {
            Write-Log ("{0} exists but nothing in it was written by this project; left alone." -f $OLD_DEST)
        }
    }

    # The old log is the only record of what happened before the rename, so it is
    # moved rather than deleted -- the same reason uninstall leaves logs alone.
    # Only once something identified the old install as ours: a log file has no
    # marker of its own, and taking somebody else's is the same mistake one step
    # quieter.
    if ($ours -and (Test-Path -LiteralPath $OLD_LOG) -and -not (Test-Path -LiteralPath "$LOG.pre-rename")) {
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
# an untested panel is unknown and sweeping it has bricked monitors. See ..\AGENTS.md
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
# (..\AGENTS.md hard rule 1). Values here come from documentation and measurement,
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
# Can questions be asked AT ALL? Distinct from Test-CanReadKeys, which asks the
# narrower "can individual keystrokes be read", and decides menu style rather than
# whether the walkthrough runs.
#
# A REDIRECTED STDIN IS A SCRIPT OF ANSWERS, NOT AN ABSENCE OF INPUT. This used to
# refuse one, which made specs/configure.md 3.5 unreachable: the menus grew a typed
# fallback precisely so a piped answer stream could drive the whole flow end to end,
# and the one caller that needs it bailed out before reaching it. Running out of
# that stream is a separate condition with its own message -- see Read-Line.
#
# $Relaunched still refuses. That is the elevated child, running hidden with its
# output going to a transcript file, so a prompt there would block a window nobody
# can see.
function Test-CanPrompt {
    if ($Relaunched) { return $false }
    if ([Console]::IsInputRedirected) { return $true }
    return [Environment]::UserInteractive
}

# THE ONE PLACE A LINE OF ANSWER IS READ, and it is deliberately not Read-Host.
#
# WINDOWS POWERSHELL 5.1's Read-Host READS THE CONSOLE, NOT STANDARD INPUT.
# Measured here: `configure` fed "11" on a redirected stdin got '' back from
# Read-Host on the first call, while [Console]::In.Peek() still held the
# unconsumed '1'. They are two different streams. So every answer in a scripted
# run was silently blank -- and since every required prompt re-asks on a blank,
# `configure` spun forever printing "A name is needed here." down the screen with
# nothing driving it.
#
# That is what specs/configure.md 3.5 is about. The typed fallback in the menus is
# only half of it; a fallback that cannot be fed is not a fallback.
#
# [Console]::In is the process's actual stdin, and its ReadLine() returns $null at
# end of input -- a THIRD state, distinct from both an answer and a blank, which is
# the distinction the spec turns on. Nothing peeks: Peek() BLOCKS on a real
# console, which hung the suite for two minutes when this guard was written the
# other way round.
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
    # Echoed, so a scripted run's transcript reads like the session it stands in
    # for. A console echoes what was typed; this is the same courtesy.
    Write-Host $line
    return $line
}

function Read-Default {
    param([string]$Prompt, [string]$Default)
    $shown = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    $answer = Read-Line $shown
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

# What a question returns when the person pressed esc rather than answering.
#
# A panel's questions are a SUBMENU entered from the Monitors list, so esc leaves
# all of them and the list is where it goes -- specs/configure.md 3.3, first row.
# That needs THREE outcomes where there were two, because "backed out" and "no, do
# not manage this monitor" must not be the same thing: conflating them lets esc
# silently unmanage a panel, which is the opposite of changing nothing.
#
# A byte value can never collide with it. Read-InputValue validates a typed value
# as a hex byte and every table value is one, so 'back' is not a value anything
# else can produce.
$BACK = 'back'

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

    # How wide a row really is, which is NOT the menu's width. Get-MenuWidth caps at
    # 110 so a menu does not sprawl across a wide window, and the previous frame is
    # still sitting in every column past that.
    $cols = $Width
    try { $cols = [Console]::BufferWidth } catch { }

    # Callers wrap their own long content (Split-Detail) rather than having it cut
    # here: this used to truncate, which on the review screen hid the very values
    # someone opened it to check. A line that is still over-long wraps in the
    # terminal and is counted, so the frame height stays honest.
    $n = 0
    foreach ($l in $Lines) {
        $t = "$l"
        Write-Host $t -NoNewline
        Clear-ToLineEnd
        Write-Host ''
        # Rows the line occupies. A line of exactly $cols characters occupies ONE:
        # measured here, a full-width write followed by a newline advances the
        # cursor a single row, because conhost delays the wrap until the next
        # character. The old count added 1 to guard against the opposite, and would
        # now over-count every erased line.
        $n += [Math]::Max(1, [Math]::Ceiling($t.Length / [double]$cols))
    }
    return $n
}

# Erase from the cursor to the end of the line it is on.
#
# ERASING, NOT PADDING, and the difference is what specs/configure.md 3.1 asks
# for. PadRight had two faults. It padded to the MENU's width, which is capped at
# 110, so on a 120-column window ten columns of the previous frame survived every
# redraw. And it measured the STRING: .Length counts UTF-16 units, and a line's end
# is a column, which part company on the first surrogate pair or combining mark.
#
# This asks the CONSOLE where the cursor is, so nothing is measured that is not a
# column.
#
# IT STOPS ONE COLUMN SHORT, AND MUST. Writing into the LAST column wraps, which
# costs a row the frame's height count knows nothing about -- and CursorLeft
# CLAMPS at BufferWidth-1, so a line that exactly fills the row is
# indistinguishable from one that stops a column short. Filling to BufferWidth
# therefore wrote one space too many on exactly-full lines: measured, such a line
# reported one row and cost two, the next redraw wound back one row too few, and
# the hint line was left duplicated under the menu. Reported from a real terminal
# at a width where a menu row happened to land exactly on the fold.
#
# The last column is never erased. That is the right trade: `Get-MenuWidth` caps a
# menu at 110 and specs/configure.md 3.1 says nothing a menu writes may exceed the
# width, so only an already-over-long line could have put anything there.
#
# ESC[K would say this more directly and was measured to work in this host, but it
# needs VT processing, which is not on in every console PowerShell 5.1 runs in --
# and where it is off the escape prints as garbage, which is worse than the bug.
# The cursor position is available wherever there is a console at all.
function Clear-ToLineEnd {
    try {
        $left = [Console]::CursorLeft
        $end  = [Console]::BufferWidth - 1
        if ($left -lt $end) { Write-Host (' ' * ($end - $left)) -NoNewline }
    } catch { }
}

# A row's detail, wrapped to the width left for it -- broken at the ", " between
# items wherever possible, so a line never ends mid-identifier.
#
# Nothing in a menu is ever truncated. The review screen exists to let someone
# confirm what is about to be written, and an ellipsis there hides exactly the thing
# they came to check. Growing the menu is the cheaper failure.
function Split-Detail {
    param([string]$Text, [int]$Width)

    if (-not $Text) { return @('') }
    if ($Width -lt 12) { return @($Text) }          # too narrow to wrap usefully

    $out = @()
    $line = ''
    foreach ($part in ($Text -split '(?<=, )')) {
        if ($line -and ($line.Length + $part.Length) -gt $Width) { $out += $line.TrimEnd(); $line = '' }
        # A single item longer than the column: let it overrun rather than cut it.
        $line += $part
    }
    if ($line) { $out += $line.TrimEnd() }
    return @($out)
}

# THE LAYOUT, shared by both menus -- specs/configure.md 3.1, and 3.4 for why the
# multi-select is not exempt.
#
# The item column is 28 unless something does not fit, and then as wide as the
# longest item, capped at 44. Fixed at 28, a long row ran its detail straight on
# with no gap -- "Yes, and it changed back to pc everything works" -- which reads
# as one sentence rather than as a choice and its consequence.
#
# +1 so the longest item still has two spaces before its detail; one reads as a
# word break rather than as a column.
function Get-ItemWidth {
    param([string[]]$Items)
    $w = 28
    foreach ($it in $Items) { if ($it -and ($it.Length + 1) -gt $w) { $w = $it.Length + 1 } }
    return [Math]::Min($w, 44)
}

# One row: the item in its column, its detail wrapped at ", " onto continuation
# lines aligned under that column. Returns one line or several.
#
# SHARED rather than reimplemented per menu. Select-Many concatenated instead, and
# it is the menu where this matters most: device names are long and arrive from the
# system rather than being chosen, so a row overflows, wraps, and the wrapped tail
# is not cleared by the next frame -- which is a corrupted redraw, reported from a
# real 80-column terminal.
#
# The lead comes from the marker, so a caller cannot get the continuation indent
# out of step with the marker it chose. That was two constants before.
function Get-MenuRow {
    param([string]$Item, [string]$Detail, [string]$Marker, [int]$ItemWidth, [int]$Width)

    $lead = $Marker.Length + 1
    if (-not $Detail) { return @(('{0} {1}' -f $Marker, $Item).TrimEnd()) }

    # @(...) around the call, not just inside it: PowerShell unrolls a one-element
    # array on return, and $chunks[0] on a bare string is its first CHARACTER --
    # which renders as a menu of single letters.
    $chunks = @(Split-Detail -Text $Detail -Width ([Math]::Max(12, $Width - $lead - $ItemWidth - 1)))
    $out = @('{0} {1} {2}' -f $Marker, $Item.PadRight($ItemWidth), $chunks[0])
    foreach ($c in @($chunks | Select-Object -Skip 1)) {
        $out += '{0} {1} {2}' -f (' ' * $Marker.Length), (' ' * $ItemWidth), $c
    }
    return @($out)
}

# One choice from a list. Returns the index.
function Select-One {
    param([string[]]$Items, [string[]]$Detail = @(), [int]$Default = 0, [string]$Help,
          # The row that is configured RIGHT NOW, if any. Starting the cursor there
          # is not enough on its own -- the cursor also means "where you are", so a
          # re-run gave no way to tell an unchanged default from a deliberate one.
          [int]$Current = -1,
          # Rows that are shown but cannot be chosen. An input already assigned to
          # another computer is the case this exists for: hiding it would leave a
          # list that changes shape as you answer, and renaming it would lose the
          # only label the monitor's own menu agrees with. So it stays where it was,
          # says who has it, and the cursor passes over it.
          [int[]]$Disabled = @(),
          # Esc returns -1, meaning "back, and change nothing". Opt-in, because it is
          # only unambiguous where backing out has an obvious meaning: a submenu you
          # entered from somewhere. It is deliberately NOT offered on the main menu
          # (which has Cancel, and should not discard a setup on a stray keypress) or
          # on a question that must be answered before the code can continue.
          [switch]$Escapable,
          # Esc MOVES THE CURSOR to this row, and does not activate it. For the top
          # menu, where the way out is a row rather than a return: esc there used to
          # do nothing at all, which reads as a dead key on the one menu people press
          # it on hardest. Moving keeps the property that matters -- a setup still
          # cannot be discarded by a stray keypress, because you have to press enter
          # on a row that says Cancel (discard changes).
          [int]$EscapeTo = -1)

    # An empty item is a SEPARATOR: drawn as a blank line, skipped by the cursor and
    # unpickable. Grouping a long menu beats renaming its rows to imply grouping.
    $sel = @()
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($Items[$i] -and -not ($Disabled -contains $i)) { $sel += $i }
    }
    if ($sel.Count -eq 0) { throw 'Select-One: nothing selectable' }
    if ($sel -notcontains $Default) { $Default = $sel[0] }

    $ITEMW = Get-ItemWidth -Items $Items

    # One row of text, possibly several lines when the detail does not fit.
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
            # The typed analogue of MOVING THE CURSOR -- specs/configure.md 3.3
            # and 3.5. Esc is offered on the top menu (it moves to Cancel), so
            # `q` has to mean the same here, or a scripted or redirected-stdin
            # run cannot express it -- and that run is what each platform's suite
            # drives `configure` with. It makes the way out the DEFAULT, so the
            # next bare enter takes it: still two keystrokes, so a setup still
            # cannot be discarded by one.
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
    # The cursor moves over the SELECTABLE rows, not over the drawn ones, so a
    # separator can never be landed on or wrapped onto -- and a row may now be more
    # than one line tall, which is why nothing here counts lines to find a row.
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
                # Move only. Never activate: that is the whole distinction.
                $to = $sel.IndexOf($EscapeTo)
                if ($to -ge 0) { $at = $to }
            }
        }
    }
}

# Several choices. Enter toggles the highlighted row, and the last row is the way
# out -- so "how do I finish?" is answered by the list itself rather than by a
# hint line nobody reads. Space toggles too, for anyone who reaches for it.
function Select-Many {
    param([string[]]$Items, [string[]]$Detail, [int[]]$Checked = @(), [string]$Help,
          [string]$DoneLabel = 'Done',
          # Esc returns $null -- distinct from any list of indices, and from the
          # empty list this refuses to return.
          [switch]$Escapable)

    $state = @($Items | ForEach-Object { $false })
    foreach ($i in $Checked) { if ($i -ge 0 -and $i -lt $state.Count) { $state[$i] = $true } }

    # THE SAME LAYOUT AS EVERY OTHER MENU -- specs/configure.md 3.4. This used to
    # concatenate the item and its detail, which is fine until the content is long,
    # and Bluetooth device names are: the row overflowed an 80-column terminal,
    # wrapped, and the wrapped tail was not cleared by the next frame, so the
    # previous frame showed through at the right edge.
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
        # A plain row, aligned with the item text, and the live count sitting in the
        # detail column where every other menu puts a value. It was a bracketed
        # button for a while, to stop it reading as a fourth thing to check -- but
        # the blank line above it and the missing checkbox already say that, and
        # every other menu in this program ends with a bare Done.
        #
        # A marker as wide as "  > [x]" and no wider, so Done lines up with the item
        # text rather than with the checkboxes.
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

# Run one of the sibling scripts in a CHILD PROCESS, never in this runspace.
#
# trigger-kvm.ps1 and event-watch.ps1 both Add-Type their P/Invoke bindings, and .NET
# cannot replace a type once a runspace has loaded it -- so calling them in-process
# means the installer inherits whatever version the window happened to load earlier.
# trigger-kvm.ps1 detects that and refuses (correctly: running stale code while
# appearing to test new code is worse), but the refusal then lands in the middle of
# the walkthrough as a stack trace, for a reason that has nothing to do with the
# person's monitors. A fresh process has a fresh runspace and the question does not
# arise. Costs a process start; none of this is the hot path -- the watcher already
# spawns its own.
function Invoke-Sibling {
    param([string]$Script, [string[]]$Arguments)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments
}

# The one place the installer actually moves a monitor. Everything that switches a
# panel goes through here -- the probe, a batched round, a blind walk -- so there is
# a single line to read when asking "what can send a packet?", and a single thing for
# a test harness to stand in for.
function Send-Input {
    param([string]$Label, [string]$Value, [string]$Config)
    $sw = Join-Path $PSScriptRoot 'trigger-kvm.ps1'
    if (-not (Test-Path $sw)) { $sw = $SWITCH }
    Invoke-Sibling -Script $sw -Arguments @('set', '-Only', $Label, '-Value', $Value, '-Config', $Config) | Out-Null
}

# Switch one display to a candidate input, hold, bring it BACK automatically, and
# only then ask.
#
# The return is what makes this safe to run against the display you are reading:
# the question always arrives on a panel that has already come back, so the
# installer never needs to know which monitor its own window is on, and a wrong
# guess costs a few seconds of black rather than a stranded session. Confirming
# visually is the only verification this hardware permits -- reads lie on both
# panels here (..\AGENTS.md hard rule 2).
#
# Returns 0 correct, 1 changed to the WRONG thing, 2 changed and did not come back,
# 3 nothing happened. Four, because with a computer named the test asserts something
# real -- "did the LG show the Mac?" -- and being shown the wrong computer is a wrong
# MAPPING, which has nothing to do with a wrong channel or a wrong value for this
# one. Testing a bare input value cannot tell 0 from 1, so -IsComputer is what says
# which question is being asked, and it does not offer the distinction without it.
#
# [CmdletBinding()] IS LOAD-BEARING HERE, and it is the one function that has it.
# A SIMPLE function swallows an undeclared named argument into $args without a
# word -- measured -- so a caller left on an old parameter name goes on working
# and quietly loses the switch. That is not hypothetical twice over: it is how
# Test-OneComputer's -ThisName went nowhere while a shadowed definition was live,
# and renaming -IsMachine to -IsComputer reproduced it exactly, with the whole
# suite still green and the walkthrough asking the wrong question.
#
# An advanced function throws "A parameter cannot be found that matches parameter
# name ...". For a switch that decides which question a human is asked about their
# own monitors, loud is the only safe direction. The test stubs of this function
# carry it for the same reason.
function Test-DisplayInput {
    [CmdletBinding()]
    param([string]$Label, [string]$Name, [string]$Candidate, [string]$CandidateName,
          [string]$Current, [string]$ThisName, [switch]$IsComputer,
          [int]$Hold = 8, [string]$Config = $CONFIG)

    Write-Host ''
    Write-Host ("  Switching $Name to $CandidateName for ${Hold}s, then back automatically.")
    if ($IsComputer) {
        Write-Host ("  Watch that monitor -- you should see $CandidateName on it.")
        Write-Host '  If that computer is asleep or off it will say No Signal, which still'
        Write-Host '  proves the switch worked.'
    } else {
        Write-Host '  Watch that monitor. It only has to CHANGE -- if nothing is plugged into'
        Write-Host '  that input it will say No Signal, and that still proves the switch worked.'
    }
    Send-Input -Label $Label -Value $Candidate -Config $Config
    Start-Sleep -Seconds $Hold
    if ($Current) { Send-Input -Label $Label -Value $Current -Config $Config; Start-Sleep -Seconds 2 }

    # Asked as it happened, in the order it happened: did it go, and did it come
    # back. One question with four answers made the reader hold every failure in mind
    # at once to find their own; this asks the thing they just watched, and only the
    # "no" leads anywhere else.
    #
    # Returns 0 correct, 1 changed to the WRONG thing, 2 went and did not come back,
    # 3 nothing happened -- unchanged, so callers keep one set of outcomes.
    $back = if ($ThisName) { $ThisName } else { 'this computer' }

    Write-Host ''
    Write-Host ("  Did the {0} change to {1}, and back to {2}?" -f $Name, $CandidateName, $back)
    $pick = Select-One -Default 0 -Items @(
        ("Yes, and it changed back to $back"),
        ("Yes, but it did not change back to $back"),
        'No'
    ) -Detail @(
        'everything works',
        "the input for $back is wrong",
        ''
    )
    if ($pick -eq 0) { return 0 }
    if ($pick -eq 1) { return 2 }

    # Only a "no" needs taking apart, and only when there was a computer to expect:
    # testing a bare input value, any change at all proves the transport, so there is
    # nothing left to ask.
    if (-not $IsComputer) { return 3 }

    Write-Host ''
    Write-Host ("  Did the {0} change at all?" -f $Name)
    $pick = Select-One -Default 1 -Items @(
        ("Yes, but it was not $CandidateName"),
        'No, nothing happened'
    ) -Detail @(
        "that input is not $CandidateName",
        'this panel does not answer on this channel'
    )
    return $(if ($pick -eq 0) { 1 } else { 3 })
}

# Send one value and ask whether the panel came back to this computer. The building
# block of blind walking, and the only place a value is sent without knowing what it
# means.
function Test-OneValue {
    param([string]$Label, [string]$Name, [string]$Value, [string]$Config, [int]$Hold = 6)

    Write-Host ''
    Write-Host ('  Trying {0} ...' -f $Value)
    Send-Input -Label $Label -Value $Value -Config $Config
    Start-Sleep -Seconds $Hold
    return (Read-YesNo ("  Is the {0} showing THIS computer now?" -f $Name) $false)
}

# Last resort: send each standard input value in turn until the panel comes back to
# this computer. Constraint 11 permits exactly this and no more -- standard DDC/CI
# only, MCCS values only, one at a time, and never on a manufacturer sidechannel,
# where a value we have not been told is a value nobody should send.
#
# Offered, never automatic, and the cost is stated first: every wrong guess takes the
# panel somewhere else, and if none of them is right it stays there.
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
        # Hard rule 4. With nothing else on this computer, a wrong guess blacks out
        # the screen this question is printed on.
        Write-Host ('  Not offered: the {0} is the only monitor on this computer, so a' -f $Answer.Name)
        Write-Host '  wrong guess would black out the screen you are reading. Use the'
        Write-Host '  monitor''s own buttons to see which input this computer is on, then'
        Write-Host '  enter that value.'
        return $null
    }

    Write-Host ('  I will send each standard input value to the {0} in turn and ask' -f $Answer.Name)
    Write-Host '  whether it came back. Your other monitor stays on this computer'
    Write-Host '  throughout, so you can keep reading this.'
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
    Write-Host '  to return it to this computer.'
    return $null
}

# A sensible name for this computer, before anyone has said one. The hostname is
# what people already call it, and it is never typed in anger -- `pull` is the verb.
function Get-DefaultComputerName {
    param([System.Collections.IDictionary]$Seed)
    if ($Seed.Contains('computer.this') -and $Seed['computer.this']) { return "$($Seed['computer.this'])".Trim().ToLower() }
    $n = "$env:COMPUTERNAME".ToLower() -replace '[^a-z0-9_-]', ''
    if ($n) { return $n }
    return 'pc'
}

# Every machine the config already names, in the order it first appears.
function Get-KnownComputers {
    param([System.Collections.IDictionary]$Cfg)
    $out = @()
    foreach ($k in ($Cfg.Keys | Sort-Object)) {
        if ($k -match '^display\.[^.]+\.input\.') {
            $n = "$($Cfg[$k])".Trim().ToLower()
            if ($n -and -not ($out -contains $n)) { $out += $n }
        }
    }
    return $out
}

# What a computer -- OR A MONITOR -- may be called.
#
# ONE name, not a slug plus a friendly name. A computer's name is a value in the
# config, an argument you type (`trigger-kvm to mac`), and a label in every
# prompt; a second "display name" field would be a second thing to keep in step
# for the sake of capital letters. So the one name has to be typeable without
# quoting, which is what the character rule is for.
#
# A monitor's short name follows the SAME rule and is asked the same way --
# specs/configure.md 6, which points at 5.1 rather than restating it. One
# function for both, because "a name someone types, in the character rule,
# unique among its peers" is one idea with two nouns; two functions would be two
# places for the rule to drift.
function Format-Name {
    param([string]$Raw)
    $n = "$Raw".Trim().ToLower()
    $n = $n -replace '[\s._]+', '-'          # spaces, dots and underscores separate
    $n = $n -replace '[^a-z0-9-]', ''        # anything else is simply not usable
    $n = $n -replace '-{2,}', '-'
    return $n.Trim('-')
}

$NAME_RULE = 'Lowercase letters, digits and dashes.'

# Suggests rather than silently mangling. The old version stripped what it did
# not like, so "My Mac" quietly became "mymac" and the person was left wondering
# where their space went.
#
# A blank answer KEEPS the default and never removes anything -- specs 5.0.
# There is no -AllowBlank: it existed for a rename prompt whose blank meant
# REMOVE, which made the most innocuous keypress available the destructive one,
# and removal became a row of its own in revision 5.
function Read-Name {
    param([string]$Prompt, [string]$Default, [string[]]$Taken = @(),
          # 'computer' or 'monitor'. It picks the refusal, which is normative
          # wording in both cases, so the two are written out rather than
          # composed -- the conformance check looks for each as written.
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
            # Say what changed and let them accept or retype, rather than quietly
            # substituting a name they never chose.
            Write-Host ('  Names are what you type at a prompt, so: {0}' -f $NAME_RULE)
            if (-not (Read-YesNo ("  Use '{0}'?" -f $n) $true)) { $Default = $n; continue }
        }
        if ($Taken -contains $n) {
            # Two panels with one label would be WRITTEN as one panel and read
            # back as a merge of both, and the switcher would then refuse without
            # saying why. Two computers with one name is the same shape.
            if ($Noun -eq 'monitor') { Write-Host ('  There is already a monitor called {0}.' -f $n) }
            else                     { Write-Host ('  There is already a computer called {0}.' -f $n) }
            continue
        }
        return $n
    }
}

# Carry a rename or a removal into every panel's map THE MOMENT IT HAPPENS, rather
# than making someone answer the monitors again -- re-asking threw away answers
# nobody asked to change. An empty -Now is a removal.
#
# Applied as it happens, not inferred afterwards. Lining the old list of computers
# up against the new one to work out what changed went wrong the moment one sitting
# held both a rename and a removal: the removal shifted every position after it, so
# the computer that slid into the victim's slot was recorded as its NEW NAME and
# inherited its inputs. Two representations of "computer C is on input V of panel
# D" can disagree; one cannot.
function Edit-PanelMaps {
    param($Panels = @(), [string]$Was, [string]$Now)

    if ($Was -eq $Now) { return }

    foreach ($a in @($Panels | Where-Object { $_ })) {
        if (-not $a.Map.Contains($Was)) { continue }
        # Rebuilt rather than edited in place, because the map's ORDER is the order
        # the panel's inputs were answered in and a rename must not move a row.
        $map = [ordered]@{}
        foreach ($c in @($a.Map.Keys)) {
            if ($c -eq $Was) { if ($Now) { $map[$Now] = $a.Map[$c] } }
            else             { $map[$c]   = $a.Map[$c] }
        }
        $a.Map = $map
    }
}

# The computers plugged into these monitors, this one included.
#
# Asked BEFORE the monitors, so a computer is described once and is then an option on
# every panel. Asking per-monitor meant typing "mac" once per screen, and gave the
# tool no way to know the two answers were about the same computer.
# Which computers to take off the list. Returns the survivors, and whether any
# panel's map changed.
#
# A ROW, NOT A KEYPRESS -- specs/configure.md 5.0. Three reasons that all point
# the same way: it is visible in the list rather than a gesture you have to know;
# it works in the typed fallback, which a keypress does not and which 3.5 makes
# load-bearing, since that fallback is how each platform's suite drives configure;
# and a row has a detail column to state the cost in BEFORE it is chosen.
#
# computer.this is not offered. Its name is what `pull` resolves, so a config
# without it is one the switcher declines to act on.
function Read-ComputerRemovals {
    param([string[]]$Others, $Panels)

    $rest  = @($Others)
    $edits = $false
    while ($true) {
        if ($rest.Count -eq 0) { return [PSCustomObject]@{ Remaining = @(); Edited = $edits } }

        $rows = @()
        $det  = @()
        foreach ($c in $rest) {
            # Which panels lose an input if this one goes. Said here, in the value
            # column, rather than only in the confirmation -- the point of a row is
            # that you can see what it costs without choosing it.
            $on = @($Panels | Where-Object { $_.Map.Contains($c) } | ForEach-Object { $_.Label })
            $rows += $c
            $det  += $(if ($on.Count) { 'on ' + (Join-Names $on) } else { 'not on any monitor' })
        }
        $rows += '';     $det += ''
        $done  = $rows.Count
        $rows += 'Done'; $det += ''

        Write-Host ''
        Write-Host '--- remove a computer ---'
        Write-Host '  Removing a computer also clears its input on every monitor it is on.'
        Write-Host ''
        $pick = Select-One -Items $rows -Detail $det -Default $done -Escapable
        if ($pick -lt 0 -or $pick -eq $done) {
            return [PSCustomObject]@{ Remaining = @($rest); Edited = $edits }
        }

        $victim = $rows[$pick]
        Write-Host ''
        Write-Host '  Its input on every monitor is cleared too. Nothing else changes.'
        # Defaults to NO. This is the destructive half of this menu, and the whole
        # reason removal stopped being a blank answer.
        if (Read-YesNo ("  Remove '{0}'?" -f $victim) $false) {
            # Cleared from the maps HERE, while the name is still known to be the
            # one that was chosen. See Edit-PanelMaps.
            Edit-PanelMaps -Panels $Panels -Was $victim -Now ''
            $rest  = @($rest | Where-Object { $_ -ne $victim })
            $edits = $true
        }
    }
}

function Read-Computers {
    param([string]$This, [string[]]$Others, [switch]$Existing,
          # The display answers as they stand: read, to say which panels a computer
          # is on, and EDITED IN PLACE, because a rename or a removal is carried
          # into every map as it happens rather than reported for the caller to
          # apply afterwards. See Edit-PanelMaps for why.
          $Panels = @())

    Write-Host ''
    Write-Host '--- computers ---'
    Write-Host 'These monitors are shared between this computer and some others.'
    Write-Host 'Each one gets a name, and the name is how you switch to it:'
    Write-Host '    trigger-kvm to mac'
    Write-Host ''

    $me    = $This
    $rest  = @($Others | Where-Object { $_ -and $_ -ne $This })
    # Whether anything happened that a monitor-input pass no longer describes:
    # specs/configure.md 5.2, "a rename or a removal invalidates a pass".
    $edits = $false

    # Nothing configured yet: ask for a count and then that many names. "One per
    # line, blank line when there are no more" made people guess at both how to
    # finish and whether a blank meant cancel.
    if (-not $Existing) {
        $was = $me
        $me  = Read-Name -Prompt 'What should I call THIS computer?' -Default $This
        if ($was -and $me -ne $was) { Edit-PanelMaps -Panels $Panels -Was $was -Now $me; $edits = $true }

        $n = -1
        while ($n -lt 0) {
            $a = Read-Default '  How many OTHER computers are plugged into these monitors?' `
                              ([string]([Math]::Max($rest.Count, 1)))
            if ($a -match '^\d+$' -and [int]$a -le 16) { $n = [int]$a }
            else { Write-Host '  A number, please (16 at most).' }
        }

        $rest = @()
        for ($i = 1; $i -le $n; $i++) {
            $d = ''      # only suggest a leftover name when it is still free
            $rest += Read-Name -Taken (@($me) + $rest) -Default $d `
                        -Prompt $(if ($n -eq 1) { 'What is the other one called?' }
                                  else { "Name for computer $i of ${n}:" })
        }
    }

    # Then, always, a list to correct. Renaming is the common edit -- a name is typed
    # once and lived with -- so it is what selecting a row does.
    while ($true) {
        $rows = @(@($me) + $rest)
        $det  = @(@('this computer') + @($rest | ForEach-Object { '' }))
        $rows += ''; $det += ''
        $add  = $rows.Count
        $rows += 'Add another computer'; $det += ''
        $rows += 'Remove a computer';    $det += ''
        $rows += 'Done';                 $det += ''

        Write-Host ''
        $pick = Select-One -Items $rows -Detail $det -Default ($add + 2) -Escapable `
                           -Help '  Pick a name to change it, or Done.'
        if ($pick -eq $add + 2 -or $pick -lt 0) { break }

        if ($pick -eq $add) {
            $rest += Read-Name -Prompt 'Name for the new computer' -Default '' `
                                       -Taken (@($me) + $rest)
            continue
        }

        if ($pick -eq $add + 1) {
            $r     = Read-ComputerRemovals -Others $rest -Panels $Panels
            $rest  = @($r.Remaining)
            $edits = $edits -or $r.Edited
            continue
        }

        if ($pick -eq 0) {
            $was = $me
            $me  = Read-Name -Prompt 'What should I call THIS computer?' `
                                     -Default $me -Taken $rest
            if ($me -ne $was) { Edit-PanelMaps -Panels $Panels -Was $was -Now $me; $edits = $true }
        } else {
            # PRE-FILLED, and a blank answer KEEPS the name -- like every other
            # prompt here. It used to remove the computer instead, which made the
            # most innocuous keypress available the destructive one. See
            # Read-ComputerRemovals for where removal went and why.
            $i   = $pick - 1
            $was = $rest[$i]
            $rest[$i] = Read-Name -Prompt ("Name for computer '{0}'" -f $was) `
                            -Default $was `
                            -Taken (@($me) + @($rest | Where-Object { $_ -ne $was }))
            if ($rest[$i] -ne $was) {
                Edit-PanelMaps -Panels $Panels -Was $was -Now $rest[$i]
                $edits = $true
            }
        }
    }

    return [PSCustomObject]@{ This = $me; All = @(@($me) + $rest); Edited = $edits }
}

# ONE SPELLING PER INPUT VALUE: the canonical 0xNN, which is how the config is
# written and how the channel's own tables are written.
#
# specs/configure.md 6.1 asks for collision BY VALUE -- `17` and `0x11` are one
# socket -- and the way to get that is not to compare cleverly everywhere. It is
# to CONVERT AT THE TWO BOUNDARIES where a value enters the walkthrough, so that
# from then on every value in every map and every table is already in the same
# form and a plain comparison IS a comparison by value. The boundaries are the
# typed prompt in Read-InputValue and Get-DisplayMap, reading the file.
#
# ConvertTo-Byte comes from config.ps1, which is where the switcher gets it too.
# The walkthrough used to carry three regexes of its own and each disagreed with
# the reader in a different direction: it accepted a bare `d1` the reader then
# dropped, and refused a 3-digit decimal the reader accepts. A saved config was
# not the setup the person had been shown.
#
# Returns $null for anything that is not a byte -- "refuse", never zero.
function Format-Byte {
    param([string]$Text)
    $n = ConvertTo-Byte $Text
    if ($null -eq $n) { return $null }
    return ('0x{0:X2}' -f [int]$n)
}

# Ask which input something is on, for one panel. Returns a value, or $null when
# -AllowNone is given and that machine is not on this panel at all.
#
# Every value it is handed -- the table's, the default's, $Taken's keys -- is
# already canonical, so the comparisons below are plain string ones. What keeps
# that true is the typed branch, which converts before doing anything else.
function Read-InputValue {
    param($Table, [string]$Prompt, [string]$Sub, [string]$Default = '',
          [hashtable]$Taken = @{}, [switch]$AllowNone,
          # Which channel these values are for. Only the typed branch cares: a
          # typed byte is the one thing that reaches a manufacturer channel from
          # outside the documented table (specs/configure.md 6.1).
          [string]$Method = 'standard',
          # Offer esc, returning $BACK. Opt-in, because "back" only means something
          # where the caller arrived from somewhere: configuring a panel came from
          # the Monitors list, but a repair after a failed check is mid-flow and has
          # nowhere to return to.
          [switch]$Escapable)

    $names = @($Table.Keys)
    $rows  = @($names)
    # Two computers cannot share a socket, so an assigned input is not merely
    # discouraged -- it is not an answer. It stays in place, says who has it, and the
    # cursor skips it.
    $off   = @()
    $vals  = @()
    for ($i = 0; $i -lt $names.Count; $i++) {
        $v = $Table[$names[$i]]
        if ($Taken.Contains($v)) { $vals += ('{0}   assigned to {1}' -f $v, $Taken[$v]); $off += $i }
        else                        { $vals += $v }
    }
    $rows += 'Type a value...'; $vals += ''
    if ($AllowNone) { $rows += 'Not on this monitor'; $vals += '' }

    # Start on the configured value's row, so a re-run is a review rather than a
    # re-entry. An unlisted value starts on "type a value", which is where it came
    # from; a machine with no answer yet starts on "not on this monitor".
    $row = 0
    $now = -1
    if ($Default) {
        $row = $names.Count
        for ($i = 0; $i -lt $names.Count; $i++) { if ($Table[$names[$i]] -ieq $Default) { $row = $i } }
        $now = $row
    } elseif ($AllowNone) {
        $row = $rows.Count - 1
    }
    # The cursor cannot start on a row it is not allowed to choose.
    if ($off -contains $row) { $row = $names.Count }

    Write-Host ''
    Write-Host ('  ' + $Prompt)
    if ($Sub) { Write-Host ('  ' + $Sub) }

    while ($true) {
        $v = $null
        $pick = Select-One -Items $rows -Detail $vals -Default $row -Current $now -Disabled $off `
                           -Escapable:$Escapable
        # BEFORE the row tests: esc is -1, and -1 is less than $names.Count.
        if ($pick -lt 0) { return $BACK }
        if ($pick -lt $names.Count) {
            $v = $Table[$names[$pick]]
        } elseif ($AllowNone -and $pick -eq ($rows.Count - 1)) {
            return $null
        } else {
            if ($Method -ne 'standard') {
                # ..\AGENTS.md hard rule 1 permits a typed value on a
                # manufacturer channel only because the person typing it is the
                # one who has to know where it came from. Say so before they do.
                Write-Host ''
                # DOUBLE-quoted, so the apostrophe appears ONCE in the source.
                # This is normative wording, and the conformance check looks for
                # it as the spec writes it -- a PowerShell '' escape makes the
                # line read correctly and match nothing.
                Write-Host "  This is the manufacturer's service channel. Type only a value you have"
                Write-Host '  from documentation; an unknown value here has made monitors unusable.'
            }
            $typed = Read-Default '  Value (e.g. 0x11)' $Default
            # The switcher's own converter, so a value accepted here is one the
            # reader will accept back. Stored canonically, so a typed `17` and a
            # listed `0x11` are one row rather than two.
            $v = Format-Byte $typed
            if (-not $v) { Write-Host '  Not a byte.'; continue }
        }
        # Two machines on one input makes `to` ambiguous, and it refuses rather than
        # guess -- so refuse here instead, where the person can still say which one
        # they meant. Marking it in the list was not enough: it can still be picked,
        # and a typed value never appears in the list at all.
        if ($Taken.Contains($v)) {
            Write-Host ('  {0} is already {1} on this monitor. Two computers cannot share one input.' -f $v, $Taken[$v])
            continue
        }
        return $v
    }
}

# The inputs to offer for a panel: the channel's own value set, with anything already
# mapped to a machine in front of it. "mac" is a better label than "HDMI 2", and it
# is the only one that is true about this desk.
# The inputs to offer for a panel: the channel's own value set, in the channel's own
# order, plus any value already assigned that the channel does not list.
#
# It used to put assigned computers' names at the FRONT, replacing the input's name --
# so answering for the second computer showed "pc  0x11" where "HDMI 1  0x11" had
# been, and the rows moved under you. The monitor's own menu says HDMI 1; that is the
# only label worth showing, and it should stay where it was.
function Get-InputTable {
    param([string]$Method, $Map)

    $out = [ordered]@{}
    $base = $MCCS_INPUTS
    foreach ($d in $DIALECTS.Values) { if ($d.Method -eq $Method) { $base = $d.Inputs } }
    foreach ($n in $base.Keys) { $out[$n] = $base[$n] }

    # A value someone typed by hand is not in the channel's list, and would otherwise
    # be invisible -- including to the "already assigned" marking. Compared by VALUE:
    # a hand-edited `display.asus.input.17` is the channel's own 0x11 and must not be
    # appended as a second row for the same socket.
    if ($Map) {
        foreach ($m in $Map.Keys) {
            if (@($out.Values) -contains $Map[$m]) { continue }
            $out[$Map[$m]] = $Map[$m]
        }
    }
    return $out
}

# What the config already says about which computer is on which input of one panel.
#
# Ordered by the CONFIGURED ORDER OF COMPUTERS, not by input value. Reading the file
# sorts by key, which is the hex -- so the same two computers came out "mac, pc" on
# one panel and "pc, mac" on the next, purely because of which socket they happened
# to be plugged into. The order someone listed their computers in is the one they
# will look for.
function Get-DisplayMap {
    param([System.Collections.IDictionary]$Existing, [string]$Label, [string[]]$Computers = @())

    # `.input.(.+)` and then the converter, not a hex-only pattern. The reader
    # accepts every form specs/config-format.md allows, so a spec-legal hand edit
    # -- `display.asus.input.17 = pc` -- has to be VISIBLE here. Matched on hex
    # alone it was invisible to the walkthrough and gone after the next Save,
    # while the switcher went on acting on it.
    $found = @{}
    if ($Label) {
        foreach ($k in ($Existing.Keys | Sort-Object)) {
            if ($k -match ('^display\.' + [regex]::Escape($Label) + '\.input\.(.+)$')) {
                $v = Format-Byte $Matches[1]
                if (-not $v) { continue }     # not a byte: dropped, exactly as the switcher drops it
                $found["$($Existing[$k])".Trim().ToLower()] = $v
            }
        }
    }

    $out = [ordered]@{}
    foreach ($c in $Computers) { if ($found.Contains($c)) { $out[$c] = $found[$c]; $found.Remove($c) } }
    # Anything the config names that the walkthrough does not know about goes last
    # rather than being dropped -- it is somebody's hand edit.
    foreach ($c in ($found.Keys | Sort-Object)) { $out[$c] = $found[$c] }
    return $out
}

# Which transports cannot switch a panel before anyone has logged in.
#
# THE RULE LIVES HERE, ONCE. Three places need it -- the disabled boot row, the
# downgrade of an existing boot tier, and `status` -- and three copies of "dxva2
# needs a desktop" would be three things to keep in step. dxva2 goes through
# user32, and in session 0 user32 reports ONE PHANTOM MONITOR rather than none,
# so it fails by MIS-RESOLVING (AGENTS.md, and windows/AGENTS.md).
$DESKTOP_TRANSPORTS = @('dxva2')

# Which transports cannot express an I2C source byte, and so cannot carry a
# manufacturer dialect at all -- the impossible cell of the 2x2 in
# docs/decisions/003. dxva2 is in both lists today and that is a COINCIDENCE of
# one API, not one property: "needs a desktop" and "cannot address a source byte"
# are the two different axes specs/config-format.md keeps apart, and a future
# transport could easily have one without the other. Two names, each used only
# where its own meaning is what matters.
$SOURCELESS_TRANSPORTS = @('dxva2')

# The managed panels a desktop-only transport would strand before login. Names,
# because the person picking a tier knows their monitors by name and has never
# heard of dxva2.
function Get-LoginOnlyPanels {
    param($Answers)
    return @(@($Answers) |
             Where-Object { $DESKTOP_TRANSPORTS -contains $_.Transport } |
             ForEach-Object { $(if ($_.Name) { $_.Name } else { $_.Label }) })
}

# How the bytes reach one panel -- specs/configure.md 6.3. Returns the transport.
#
# SHOWN ONLY WHERE A CHOICE EXISTS: where this panel enumerated through more than
# one transport. On a one-NVIDIA-card desk both transports see both panels, so the
# question is real here; on a machine with no NVIDIA card only dxva2 enumerates,
# and that panel is told rather than asked.
#
# ENUMERATING IS NOT PROBING. The offer is built from which of THIS COMPUTER'S
# APIs could see the panel, and reading an EDID sends nothing to a monitor.
# AGENTS.md 1b forbids discovering a MONITOR's behaviour by experiment, which is a
# different act -- specs/configure.md 6.3 draws the line because the two could
# otherwise be read as one.
#
# It comes BEFORE the method question, because the transport decides which
# dialects exist at all: dxva2 cannot express an I2C source byte, so offering a
# manufacturer channel first and refusing it second would be asking a question
# whose answer was already fixed.
function Read-Transport {
    param([string[]]$Transports, [string]$Current, [int]$Vendor)

    $t = @($Transports | Where-Object { $_ })
    if ($t.Count -le 1) {
        # Nothing to ask. Store what it enumerated on, so the config records the
        # path that was actually confirmed rather than leaving it to a default.
        if ($t.Count -eq 1) { return $t[0] }
        return $(if ($Current) { $Current } else { 'nvapi' })
    }

    $d = $DIALECTS['{0:X4}' -f $Vendor]

    Write-Host ''
    Write-Host '--- how the switch reaches this monitor ---'
    Write-Host '  Both ways work on this computer. They differ in when they work and'
    Write-Host '  in what they can say.'
    Write-Host ''
    # THE CONSEQUENCE, NAMED WHERE THE CHOICE IS MADE -- specs/configure.md 2 and
    # 6.3. In terms of what the person will experience, not the mechanism: nobody
    # picking a monitor setting wants to be told about session 0.
    Write-Host '  Through Windows, this monitor will not follow the switch until'
    Write-Host '  somebody has logged in. A PC sitting at the login screen keeps'
    Write-Host '  showing whatever it was showing.'
    if ($d) {
        Write-Host ''
        Write-Host ("  It also cannot use {0}'s own method -- there is no way to send that" -f $d.What)
        Write-Host '  down it. Only the standard one.'
    }
    Write-Host ''

    # The graphics card is the default and where the cursor starts: it covers
    # more, and someone with no opinion should land on the answer with fewer
    # consequences (specs/configure.md 6.3).
    $now  = $(if ($Current -eq 'dxva2') { 1 } elseif ($Current -eq 'nvapi') { 0 } else { -1 })
    $pick = Select-One -Default ([Math]::Max(0, $now)) -Current $now -Escapable `
                -Items  @('Through the graphics card', 'Through Windows') `
                -Detail @('works before anyone logs in',
                          $(if ($d) { ('login onward only; cannot use {0}''s own method' -f $d.What) }
                            else    { 'login onward only' }))
    if ($pick -lt 0) { return $BACK }
    return $(if ($pick -eq 1) { 'dxva2' } else { 'nvapi' })
}

# One display: identity is already known -- `list` read it off whichever transports
# could see the panel, and they agree on it. What we need from the human is whether
# to manage it, what to call it, how the bytes get there, and which input each
# machine is on.
#
# Standard DDC/CI is the answer for everyone here, whatever the make. A manufacturer
# dialect is only reached for later, if the test shows standard does not work.
# Which channel to talk to one panel on. Returns the method name.
#
# SHOWN ONLY when this panel's EDID VENDOR has a documented alternative, and keyed
# by vendor alone -- never by model, which would be one row per monitor whoever
# wrote the table happened to own.
#
# OFFERED, NEVER PROBED. Nothing is sent to find out; the choice comes from the
# documented table or not at all, and the transport still refuses a manufacturer
# channel to a panel whose EDID vendor does not match. See ..\AGENTS.md hard rule 1b.
#
# Up front rather than only after a failure, since 2026-08-31. Someone who already
# knows their model needs the alternative should not have to run a check that moves
# a panel and sends packets purely in order to fail -- and someone who watches the
# standard method fail without ever being told the alternative exists may
# reasonably decide the tool does not know about it. Offering here sends fewer
# packets, not more. The check still offers it again, in either direction.
function Read-Method {
    param([int]$Vendor, [string]$Current, [string]$Transport = 'nvapi')

    $d = $DIALECTS['{0:X4}' -f $Vendor]
    if (-not $d) { return $Current }

    # A transport that cannot address an I2C source byte cannot carry a
    # manufacturer channel, so there is no choice left to offer -- and offering
    # one here to refuse it at the transport is exactly the question-whose-answer-
    # is-already-fixed that specs/configure.md 6.3 orders these two to avoid.
    # Read-Transport has already said so on the row where dxva2 was picked.
    #
    # The REFUSAL still lives in trigger-kvm.ps1's Switch-Display, which is where
    # a hand-edited config meets it. This is not a second copy of that rule: one
    # refuses a pair, this one never offers it. conventions.tests.ps1 pins the two
    # to the same transport, so neither can drift into offering what the other
    # rejects.
    if ($Transport -in $SOURCELESS_TRANSPORTS) { return 'standard' }

    Write-Host ''
    Write-Host '--- how to talk to this monitor ---'
    Write-Host ('  Nearly every monitor takes the standard method, including most {0} ones.' -f $d.What)
    Write-Host ('  A few {0} models ignore it and need {0}''s own method instead.' -f $d.What)
    Write-Host ''
    # THE CONSEQUENCE, NAMED WHERE THE CHOICE IS MADE -- specs/configure.md 6.2.
    # This is the moment a person commits to a service channel, and the rules
    # that keep it safe live in ..\AGENTS.md, which a user never opens. Three
    # lines here are the only warning they get: what the channel is, what is sent
    # to it, and what has happened on it. No exclamation mark and no reassurance.
    Write-Host ('  {0}''s own method talks to a service channel on the monitor. It is' -f $d.What)
    Write-Host '  sent only the values written down for it: unknown values on that'
    Write-Host '  channel have made monitors unusable.'
    Write-Host ''
    Write-Host '  If you are not sure, take the standard one. If it turns out not to'
    Write-Host '  work, the check further down will offer you this again.'
    Write-Host ''

    # Standard is the default and where the cursor starts on a fresh panel; an
    # existing choice keeps the cursor, and is marked (current) so an unchanged
    # default is distinguishable from a deliberate one.
    #
    # Esc leaves the panel's questions entirely and returns to the Monitors list --
    # $BACK, propagated by Get-DisplayAnswers, which is where the list is.
    #
    # It shipped once resolving esc to "keep $Current and carry on". With the cursor
    # already on the current row that is byte for byte what enter does, so esc
    # appeared to ADVANCE the walkthrough. The fix is not to take esc away: this is
    # a menu you reached from a list, so "back" is exactly what it should mean.
    $now  = $(if ($Current -eq $d.Method) { 1 } else { 0 })
    $pick = Select-One -Default $now -Current $now -Escapable `
                -Items  @('Standard', ("{0}'s own method" -f $d.What)) `
                -Detail @('what nearly every monitor takes',
                          ('for {0} models that ignore the standard one' -f $d.What))
    if ($pick -lt 0) { return $BACK }
    return $(if ($pick -eq 1) { $d.Method } else { 'standard' })
}

function Get-DisplayAnswers {
    # $Existing is a PSCustomObject or $null -- deliberately untyped, because a
    # [hashtable] annotation here silently accepted the call at parse time and threw
    # a transformation error at RUN time, i.e. mid-walkthrough.
    param($Found, $Existing, [string[]]$Computers, [string]$This,
          # The short names the OTHER managed panels already have. Two panels
          # with one label would be written as one and read back as a merge of
          # both -- specs/configure.md 6.
          [string[]]$Labels = @())

    $key  = '{0:X4}:{1:X4}' -f $Found.EdidVendor, $Found.EdidProduct
    # The panel's own name, out of its EDID. No table to be absent from.
    $desc = if ($Found.Name) { $Found.Name } else { ('{0} panel {1}' -f $Found.Mfg, $key) }

    Write-Host ''
    Write-Host ('  {0}   EDID {1}   {2}' -f $desc, $key, $Found.Connector)

    # Through the character rule, like every other name here: the first word of
    # the panel's own EDID name, else its manufacturer.
    $defaultLabel = if ($Existing) { $Existing.Label } else { Format-Name (($desc -split ' ')[0]) }
    if (-not $defaultLabel) { $defaultLabel = Format-Name $Found.Mfg }
    if (-not (Read-YesNo '  Manage this monitor?' $true)) {
        # "No" is DESTRUCTIVE when there is something to lose: it forgets which
        # computer is on which input. "Manage" reads like a flag, so the loss is
        # named and confirmed -- the same rule as removing a computer
        # (specs/configure.md 5.3), and the symmetry worth having between the two
        # menus. A panel with nothing configured has nothing to lose, so it is not
        # asked twice.
        $had = $(if ($Existing -and $Existing.Map) { @($Existing.Map.Keys).Count } else { 0 })
        if ($had -eq 0) { return $null }

        Write-Host ''
        Write-Host '  Which computer is on which of its inputs is forgotten. Nothing else'
        Write-Host '  changes, and nothing is written until you save.'
        if (Read-YesNo '  Stop managing this monitor?' $false) { return $null }
        return $BACK
    }

    # The same rule, prompt and duplicate check as a computer name --
    # specs/configure.md 6, which points at 5.1 rather than restating it.
    # Suggested and asked, never silently mangled: it used to strip to
    # [^A-Za-z0-9_-] behind the person's back, which also kept underscores the
    # rule turns into dashes.
    $label = Read-Name -Prompt 'Short name for it' -Default $defaultLabel `
                       -Taken $Labels -Noun 'monitor'

    # An existing method is a settled answer -- it was proven by someone watching the
    # screen. Do not quietly walk it back to standard on a re-run.
    $was    = if ($Existing -and $Existing.Method) { $Existing.Method } else { 'standard' }
    $prior  = if ($Existing -and $Existing.Map) { $Existing.Map } else { [ordered]@{} }

    # An existing transport is a settled answer for the same reason an existing
    # method is: somebody watched a panel move over it.
    $wasT = if ($Existing -and $Existing.Transport) { $Existing.Transport } else { '' }

    # BEFORE the method, because the transport decides which dialects exist --
    # specs/configure.md 6.3, which is numbered after 6.2 and asked before it.
    $transport = Read-Transport -Transports $Found.Transports -Current $wasT -Vendor $Found.EdidVendor
    if ($transport -eq $BACK) { return $BACK }

    # Asked here, BEFORE any input question, because the values on offer depend on
    # the answer. Shown only for a vendor with a documented alternative.
    $method = Read-Method -Vendor $Found.EdidVendor -Current $was -Transport $transport
    if ($method -eq $BACK) { return $BACK }

    # A changed method makes every prior value meaningless -- they were addresses on
    # the other channel -- so they stop being defaults rather than being carried
    # across as numbers nobody would recognise. Same reasoning as the escalation in
    # specs/configure.md 10.5, which clears the map for the same reason.
    if ($method -ne $was) { $prior = [ordered]@{} }

    $map   = [ordered]@{}
    $taken = @{}
    foreach ($m in $Computers) {
        $table = Get-InputTable -Method $method -Map $map
        $was   = if ($prior.Contains($m)) { $prior[$m] } else { '' }
        $sub   = if ($m -eq $This) { '(this computer -- the input you would pick to see this screen)' } else { '' }
        $v = Read-InputValue -Table $table -Default $was -Taken $taken -AllowNone:($m -ne $This) `
                             -Prompt ("On the {0}, which input is '{1}' on?" -f $desc, $m) -Sub $sub `
                             -Method $method -Escapable
        # Esc anywhere in a panel's questions abandons the whole panel, not just
        # this one answer. Half a map is not an answer, and the person asked to
        # leave -- so nothing here is kept and the Monitors list gets its old row
        # back untouched.
        if ($v -eq $BACK) { return $BACK }
        if ($null -ne $v) { $map[$m] = $v; $taken[$v] = $m }
    }

    return [PSCustomObject]@{
        Label = $label; Name = $desc; Method = $method; Transport = $transport
        Vendor = ('0x{0:X4}' -f $Found.EdidVendor); Product = ('0x{0:X4}' -f $Found.EdidProduct)
        EdidVendor = $Found.EdidVendor; Mfg = $Found.Mfg; Key = $key
        Map = $map
    }
}

# Which devices travel with the switch. Returns the chosen keys.
function Read-Triggers {
    param($Cands, [string[]]$Current)

    Write-Host ''
    Write-Host '--- triggers ---'
    Write-Host 'Which devices move to this computer when you flip the switch?'
    Write-Host 'USB rows are attached right now; Bluetooth rows are everything paired.'
    Write-Host ''

    $checked = @()
    for ($i = 0; $i -lt $Cands.Count; $i++) { if ($Current -contains $Cands[$i].Key) { $checked += $i } }

    $help = '  Keyboards and mice often share a vendor id with something that never' + "`n" +
            '  moves. The full vendor+product is matched, so pick the exact rows.'

    # THE NAME IS THE ROW; the key is what confirms it. You recognise a device by
    # what it is called, so that is what you pick from -- `usb:046d:c547` names
    # nothing to a person and three of them used to read `USB Input Device`
    # anyway. The vendor+product pair stays visible on the detail line, because
    # the help text above tells you to match the FULL pair and you cannot act on
    # that advice against a name alone.
    $picked = Select-Many -Checked $checked -Help $help -Escapable `
        -Items  @($Cands | ForEach-Object { Get-CandidateLabel $_ }) `
        -Detail @($Cands | ForEach-Object {
                    ('{0,-20} {1}' -f $_.Key, $_.Bus) +
                    $(if ($_.State) { '   ' + $_.State } else { '' }) })

    if ($null -eq $picked) { return @($Current) }
    return @($picked | ForEach-Object { $Cands[$_].Key })
}

# Whether to put bin\ on the user PATH. Returns $true or $false.
#
# A menu rather than a row that flips when you select it. The toggle was fine while
# the row always carried a value, but it cannot express "not answered yet" -- and a
# suggestion belongs on a highlighted row, not in the value column of a menu nobody
# has opened.
function Read-PathChoice {
    param($Current)

    Write-Host ''
    Write-Host '--- PATH ---'
    # Single quotes: in a DOUBLE-quoted PowerShell string a backtick is the escape
    # character, so "`trigger-kvm`" renders as TAB + "rigger-kvm".
    Write-Host ('  Add {0} to your PATH, so `trigger-kvm` works from anywhere?' -f $BINDIR)
    Write-Host '  Only that directory is added, and it holds only the launcher.'
    Write-Host ''
    $now = $(if ($null -eq $Current) { -1 } elseif ($Current) { 0 } else { 1 })
    $pick = Select-One -Default ([Math]::Max(0, $now)) -Current $now -Escapable `
                       -Items @('Yes', 'No') `
                       -Detail @('trigger-kvm works from anywhere', 'call it by its full path')
    if ($pick -lt 0) { return $Current }
    return ($pick -eq 0)
}

# Can this account obtain administrator rights AT ALL?
#
# Not "is this process elevated" -- that is $IsElevated. This is the prior
# question: whether a UAC prompt would be a CONSENT prompt for this person, or a
# CREDENTIAL prompt for somebody else. On a standard account it is the second,
# and everything the resulting process installs belongs to that other account.
#
# Membership of the local Administrators group is the test. A split UAC token
# still LISTS that group -- marked deny-only, but present -- so an admin running
# unelevated answers true here, which is right: they can elevate.
#
# On an error it answers TRUE, i.e. offer the row. Being unable to ask is not
# evidence that the answer is no, and a wrongly hidden option is worse than a
# prompt that turns out to be refused: the prompt at least says so.
function Test-CanElevate {
    if ($IsElevated) { return $true }
    try {
        $admins = New-Object Security.Principal.SecurityIdentifier(
                      [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
        foreach ($g in [Security.Principal.WindowsIdentity]::GetCurrent().Groups) {
            if ($g.Translate([Security.Principal.SecurityIdentifier]) -eq $admins) { return $true }
        }
        return $false
    } catch { return $true }
}

# When the watcher should start running. Returns 's4u' or 'user'.
#
# From boot is offered FIRST and is the default, because it is the answer that
# behaves the way people expect -- a PC sitting at a login screen still follows the
# switch. The cost is one UAC prompt during setup, and asking for it once beats
# discovering months later that switching quietly does nothing until you log in.
# A config that already says otherwise still wins: an existing choice is a choice.
function Read-Tier {
    param([string]$Current, [string[]]$LoginOnly = @())

    Write-Host ''
    Write-Host '--- should it start on its own? ---'
    Write-Host '  It can start as soon as the computer starts, or after you log in for'
    Write-Host '  the first time. Starting before you log in needs administrator'
    Write-Host '  permission to set up -- once, now. Nothing runs elevated afterwards.'
    Write-Host ''
    Write-Host '  Answering no still installs and starts it now; it just will not come'
    Write-Host '  back after a restart until you run:  trigger-kvm restart'
    Write-Host ''
    # DRAWN, and disabled with the reason, for an account that cannot elevate at
    # all -- specs/configure.md 8. Offering it would send the most common kind of
    # account into a prompt for a DIFFERENT account's credentials, and whatever
    # that installs belongs to that other account. The row stays so the menu keeps
    # the shape someone coming from macOS expects, and the question it raises is
    # answered where it is asked.
    #
    # A CONFIGURED TRANSPORT CAN ALSO BE THE REASON, and it is a DIFFERENT fact
    # that must not be merged into one "not available" message: the account case
    # is answered by finding an administrator, the transport case by putting that
    # panel back on the graphics card, and somebody told the wrong one goes
    # hunting for a password that would not have helped. Where both are true,
    # both are said.
    $canElevate = Test-CanElevate
    # @() around it, not the parameter default: an EMPTY result passed explicitly
    # arrives as $null, which the default never replaces, and Set-StrictMode makes
    # $null.Count terminating -- mid-walkthrough, on the common desk where no
    # panel is stranded.
    $stranded = @($LoginOnly | Where-Object { $_ })
    $off = @()
    if (-not $canElevate -or $stranded.Count -gt 0) { $off += 0 }

    $why = @()
    if ($stranded.Count -gt 0) {
        $why += ('{0} cannot switch before login' -f (Join-Names $stranded))
    }
    if (-not $canElevate) { $why += 'needs an administrator account' }
    if ($why.Count -eq 0) { $why += 'one administrator prompt now; nothing runs elevated afterwards' }

    $now = $(switch ($Current) { 's4u' { 0 } 'user' { 1 } 'manual' { 2 } default { -1 } })
    $default = [Math]::Max(0, $now)
    if ($off -contains $default) { $default = 1 }

    $pick = Select-One -Default $default -Current $now -Escapable -Disabled $off -Items @(
        'From boot',
        'From login',
        'No -- I will start it myself') -Detail @(
        ($why -join '; '),
        'covers everything from your logon onward',
        '')
    if ($pick -lt 0) { return $Current }
    return $(switch ($pick) { 1 { 'user' } 2 { 'manual' } default { 's4u' } })
}

# Rebuild the answer objects straight from the config, asking nothing. What the menu
# opens with.
function Get-ConfiguredAnswers {
    param($Found, [System.Collections.IDictionary]$Existing, [string[]]$Computers = @())

    $out = @()
    foreach ($f in $Found) {
        $key   = '{0:X4}:{1:X4}' -f $f.EdidVendor, $f.EdidProduct
        $prior = Get-PriorDisplay -Existing $Existing -Key $key -Computers $Computers
        if (-not $prior) { continue }
        $out += [PSCustomObject]@{
            Label  = $prior.Label
            Name   = $(if ($Existing.Contains("display.$($prior.Label).name")) { $Existing["display.$($prior.Label).name"] } else { $prior.Label })
            Method = $(if ($prior.Method) { $prior.Method } else { 'standard' })
            # Absent means nvapi -- specs/config-format.md. This is where that
            # default is applied for a config written before the key existed, so
            # the menu, the boot row and `status` all read one answered value.
            Transport = $(if ($prior.Transport) { $prior.Transport } else { 'nvapi' })
            Vendor = ('0x{0:X4}' -f $f.EdidVendor); Product = ('0x{0:X4}' -f $f.EdidProduct)
            EdidVendor = $f.EdidVendor; Mfg = $f.Mfg; Key = $key
            Map    = $prior.Map
        }
    }
    return $out
}

# The monitors, as a list you pick from -- the same shape as the computers list, and
# for the same reason. Walking every panel in sequence to change one value meant
# answering for all of them, which is what a menu exists to avoid.
function Read-Monitors {
    param($Found, $Answers, [string[]]$Computers, [string]$This, [System.Collections.IDictionary]$Existing = @{})

    $out = @($Answers)

    while ($true) {
        $items  = @()
        $detail = @()
        foreach ($f in $Found) {
            $key = '{0:X4}:{1:X4}' -f $f.EdidVendor, $f.EdidProduct
            $a   = @($out | Where-Object { $_.Key -eq $key }) | Select-Object -First 1
            $items  += $(if ($f.Name) { $f.Name } else { '{0} panel {1}' -f $f.Mfg, $key })
            # An id that answers for more than one ATTACHED panel cannot be managed
            # at all (specs/configure.md 6.4), so the row says that rather than an
            # answer -- including where a config written before the second panel
            # arrived still holds one. That answer is kept, not quietly dropped.
            $detail += $(if ($f.Panels -gt 1) { '{0} monitors share this id -- cannot manage' -f $f.Panels }
                         elseif ($a) { '{0}: {1}' -f $a.Label, (@($a.Map.Keys) -join '/') }
                         else { 'not managed' })
        }
        $items += ''; $detail += ''
        $done = $items.Count
        $items += 'Done'; $detail += ''

        # The first panel nobody has answered for, else the way out.
        $land = $done
        for ($i = 0; $i -lt $Found.Count; $i++) { if ($detail[$i] -eq 'not managed') { $land = $i; break } }

        Write-Host ''
        Write-Host '--- monitors ---'
        Write-Host 'Which of these should follow the switch, and which input is each'
        Write-Host 'computer on?'
        Write-Host ''
        # No -Disabled: no row in the Monitors list is ever unpickable. It used to
        # pass `-Disabled $off`, and $off is not assigned in this function -- it
        # resolved by DYNAMIC SCOPE to Invoke-Configure's, which holds the row
        # index of the PATH question whenever that row is disabled. With three or
        # more monitors and bin\ already on PATH, index 4 here is `Done`: drawn
        # `--`, skipped by the cursor, and reachable only by esc. Two-monitor
        # desks never saw it, and Set-StrictMode does not catch a variable that
        # resolves in a parent scope.
        $pick = Select-One -Items $items -Detail $detail -Default $land -Escapable
        if ($pick -eq $done -or $pick -lt 0) { return @($out) }

        $f    = $Found[$pick]
        # Refuse BEFORE any question is asked. Answers here are looked up by the
        # id, so one record would serve both panels and the second answer would
        # overwrite the first -- the person configures two monitors and has
        # configured one. specs/configure.md 6.4.
        if ($f.Panels -gt 1) {
            Write-Host ''
            Write-Host ('  {0} monitors report the same id and cannot be told apart (0x{1:X4}:0x{2:X4}).' -f `
                        $f.Panels, $f.EdidVendor, $f.EdidProduct)
            Write-Host  '  A switch cannot aim at one of them, so none of them can be managed.'
            Write-Host  '  Unplug one to manage the other. Anything already configured for'
            Write-Host  '  this id is left exactly as it is.'
            continue
        }
        $key  = '{0:X4}:{1:X4}' -f $f.EdidVendor, $f.EdidProduct
        $was  = @($out | Where-Object { $_.Key -eq $key }) | Select-Object -First 1
        $prior = $was
        if (-not $prior) { $prior = Get-PriorDisplay -Existing $Existing -Key $key -Computers $Computers }

        # Every OTHER managed panel's short name, so this one cannot take a name
        # already in use. This panel's own is excluded: keeping it is not a clash.
        $others = @($out | Where-Object { $_.Key -ne $key } | ForEach-Object { $_.Label })
        $a = Get-DisplayAnswers -Found $f -Existing $prior -Computers $Computers -This $This `
                                -Labels $others
        # $BACK is the only string it can return, and it means CHANGE NOTHING --
        # so the panel keeps whatever row it already had. $null is the different
        # answer "do not manage this monitor", which does remove it.
        if ($a -is [string]) { continue }
        $out = @($out | Where-Object { $_.Key -ne $key })
        if ($a) { $out += $a }
    }
}

# What the config already says about one panel, matched on its EDID rather than on
# whatever label someone gave it.
function Get-PriorDisplay {
    param([System.Collections.IDictionary]$Existing, [string]$Key, [string[]]$Computers = @())

    # Compared by VALUE, not as hex text. The config may spell an EDID id in
    # decimal -- specs/config-format.md allows it and the switcher reads it --
    # and a text comparison then matched nothing, so the panel showed as
    # unmanaged and its answers were silently dropped on the next Save.
    foreach ($k in $Existing.Keys) {
        if ($k -notmatch '^display\.([^.]+)\.vendor$') { continue }
        $l = $Matches[1]
        $ven = ConvertTo-Word $Existing["display.$l.vendor"]
        $pro = ConvertTo-Word $Existing["display.$l.product"]
        if ($null -eq $ven -or $null -eq $pro) { continue }
        if (('{0:X4}' -f $ven) -ne $Key.Split(':')[0]) { continue }
        if (('{0:X4}' -f $pro) -ne $Key.Split(':')[1]) { continue }
        return [PSCustomObject]@{
            Label  = $l
            Method = $(if ($Existing.Contains("display.$l.method")) { $Existing["display.$l.method"] } else { '' })
            # Empty, not 'nvapi', when the key is absent. The DEFAULT is applied
            # where the value is used; here empty means "nobody has answered", so
            # a fresh panel starts the cursor on the recommendation rather than
            # being shown a choice it never made marked (current).
            Transport = $(if ($Existing.Contains("display.$l.transport")) { "$($Existing["display.$l.transport"])".Trim().ToLower() } else { '' })
            Map    = (Get-DisplayMap -Existing $Existing -Label $l -Computers $Computers)
        }
    }
    return $null
}

# The walkthrough. Current settings pre-fill every default, so a re-run is a review
# rather than a replay -- unless -Fresh, which starts from nothing.
#
# Two distinct roles for the old config, and -Fresh separates them: $seed supplies
# DEFAULTS, $existing is what must SURVIVE. Dropping both would silently discard
# anything hand-written, so -Fresh clears the first and never touches the second.
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
    } elseif (-not $isFirst) {
        Write-Host ' Current settings are the defaults -- press enter to keep one.'
    }

    # ---- what is attached ---------------------------------------------------
    $sw = Join-Path $PSScriptRoot 'trigger-kvm.ps1'
    if (-not (Test-Path $sw)) { $sw = $SWITCH }

    # -Raw, not the human table: that one is Write-Host, which never reaches the
    # pipeline, so parsing it would silently find nothing.
    $found = @()
    foreach ($line in (Invoke-Sibling -Script $sw -Arguments @('list', '-Raw', '-Config', $CONFIG) 2>$null)) {
        $row = ConvertFrom-DisplayRow $line
        if ($row) { $found += $row }
    }
    if ($found.Count -eq 0) {
        # Not "on an NVIDIA GPU" any more: dxva2 sees panels on any adapter, so a
        # machine with no NVIDIA card is one this can now configure rather than
        # one it turns away.
        Write-Log 'no displays found by any transport -- nothing to configure.'
        $global:LASTEXITCODE = 2
        return
    }

    Write-Host ''
    Write-Host ('--- monitors found ({0}) ---' -f $found.Count)
    foreach ($f in $found) {
        Write-Host ('  {0,-24} {1}' -f `
                    $(if ($f.Name) { $f.Name } else { '{0} panel' -f $f.Mfg }), $f.Connector)
    }

    # ---- state, from the config or empty ------------------------------------
    #
    # There is no separate first-run questionnaire. A fresh install is this same menu
    # with nothing filled in yet and the cursor on the first thing that needs an
    # answer; a configured one is the same menu with the answers in it. Two flows
    # meant two places for a change to have to be made, and meant that finishing a
    # section on a fresh install dropped you into the NEXT section rather than back
    # to the menu -- which is not what "done" means anywhere else in this program.
    $carry = @{}
    $ranDisplays = $null
    $ranTriggers = $null

    $this      = Get-DefaultComputerName -Seed $seed
    $computers = @(Get-KnownComputers -Cfg $seed)
    if ($computers.Count -gt 0) { $computers = @(@($this) + @($computers | Where-Object { $_ -ne $this })) }
    $answers   = @(Get-ConfiguredAnswers -Found $found -Existing $seed -Computers $computers)
    $carry     = @{}

    $devices = @()
    if ($seed.Contains('trigger.device')) {
        # A malformed entry keeps its RAW text, and that is the whole point: it
        # is what gets shown, and what Write-ConfigFile puts back. Rewriting it
        # into something that parses would edit somebody's file behind them and
        # still not start the watcher.
        $devices = @(ConvertFrom-TriggerDevices $seed['trigger.device'] |
                     ForEach-Object { if ($_.Ok) { $_.Identity } else { $_.Raw } })
    }
    $cands = @(Get-TriggerCandidates)

    # Empty means UNANSWERED, and the row says so. Both of these have a suggestion --
    # from boot, and yes -- but a suggestion belongs on the highlighted row inside the
    # menu, not in the value column of a menu nobody has opened. Showing "from boot"
    # for a choice never made is the tool answering on someone's behalf, and this one
    # raises a UAC prompt.
    $newTier = $(if ($seed.Contains('install.autostart')) {
                     $(switch ($seed['install.autostart']) {
                         'boot' { 's4u' } 'no' { 'manual' } default { 'user' } })
                 } else { '' })

    # (Get-UserPath) -split ';' -- the parentheses are load-bearing. Written as
    # `Get-UserPath -split ';'`, PowerShell reads -split as a PARAMETER of the
    # function rather than as the operator, hands it the unsplit string, and the
    # -contains never matches. That made $onPath permanently false: the walkthrough
    # offered to add a directory that was already there, and `status` reported "not
    # on PATH" about a PATH containing it.
    $onPath   = @((Get-UserPath) -split ';') -contains $BINDIR
    $wantPath = $null

    # ---- the menu ------------------------------------------------------------
    # The settings ARE the rows, and choosing one enters that section and comes
    # straight back here. There is no separate first-run pass: an empty install is
    # this menu with "not set" in it, and the cursor already on the first thing that
    # needs an answer.
    #
    # Three groups, separated by blank rows the cursor skips: what you set, what you
    # can check, and what ends the walkthrough. Flat, they read as equal choices.
    while ($true) {
        # One punctuation rule across every row, because they are read as a column:
        #   ", " separates items      ": " separates a label from its value
        #   "/"  joins things sharing one label
        # Not only tidiness -- Split-Detail wraps at ", ", so the monitors row could
        # not wrap at all while it used spaces, and a busy desk overran the line.
        $items  = @('Computers', 'Monitors', 'Triggers', 'Autostart?')
        $detail = @(
            $(if ($computers.Count -eq 0) { 'not set' } else {
                ($computers | ForEach-Object { if ($_ -eq $this) { "$_ (this)" } else { $_ } }) -join ', ' })
            $(if ($answers.Count -eq 0) { 'not set' } else {
                ($answers | ForEach-Object { '{0}: {1}' -f $_.Label, (@($_.Map.Keys) -join '/') }) -join ', ' })
            # Named, like every other row: Computers shows names and Monitors
            # shows labels, so vendor+product pairs here were the one row that
            # answered "what is set?" with an id nobody can read. $cands is
            # already in hand, so this costs nothing. A device that is not
            # attached right now has no name to show and keeps its key -- the
            # honest answer, and the same one `status` gives.
            $(if ($devices.Count -eq 0) { 'not set' } else {
                (@($devices | ForEach-Object {
                    $d = $_
                    $c = @($cands | Where-Object { $_.Key -eq $d }) | Select-Object -First 1
                    # An entry the reader would refuse is SAID to be refused, here
                    # as in `status`. Without it this row shows a hand-edited
                    # typo as though it were simply a device that is elsewhere.
                    if     ($c) { $c.Name }
                    elseif (-not (ConvertFrom-TriggerDevices $d)[0].Ok) { "$d (malformed)" }
                    else   { $d }
                }) -join ', ') })
            $(switch ($newTier) { 's4u' { 'from boot' } 'manual' { 'no' }
                                  'user' { 'from login' } default { 'not set' } })
        )
        # Always drawn, even when there is nothing to decide. Hiding it moved every
        # row below it and left the cursor apparently skipping a step, with no way to
        # tell whether PATH had been handled or forgotten. Shown and disabled, the
        # menu keeps its shape and answers the question it raises.
        $items  += 'Add to PATH?'
        $pathRow = $items.Count - 1
        $detail += $(if ($onPath) { 'already on PATH' }
                     elseif ($null -eq $wantPath) { 'not set' }
                     elseif ($wantPath) { 'yes' } else { 'no' })
        $off = @()
        if ($onPath) { $off += $pathRow }

        # Monitors first, then the trigger. The trigger check asks someone to flip
        # the switch away and back, and once the monitors are known good the flip
        # back can PULL them for real -- so it stops being a report that an event
        # was seen and becomes the whole thing working, which is the last thing you
        # want to see before saving.
        $items  += ''; $detail += ''
        # "the monitor inputs", not "the monitors": what is under test is the claim
        # that input V of panel P is computer C. A panel that answers perfectly while
        # its inputs are mapped to the wrong computers fails this and is not broken.
        $claims = 0
        foreach ($a in $answers) { $claims += @($a.Map.Keys | Where-Object { $_ -ne $this }).Count }
        $items  += $(if ($claims -eq 1) { 'Test the monitor input' } else { 'Test the monitor inputs' })
        $detail += $(if ($ranDisplays) { $ranDisplays.Text } else { 'untested' })
        $items  += $(if ($devices.Count -eq 1) { 'Test the trigger' } else { 'Test the triggers' })
        $detail += $(if ($ranTriggers) { $ranTriggers.Text } else { 'untested' })

        $items  += ''; $detail += ''
        $save = $items.Count
        $items += 'Save configuration and run'; $detail += ''
        $items += 'Cancel (discard changes)';   $detail += ''

        # Where the cursor lands is the recommendation, and it is just "the next
        # thing that is not done": the unanswered sections in order, then the checks,
        # then save. A FAILED check sends the cursor to the setting that failed
        # rather than onward.
        #
        # BACKING OUT OF A CHECK IS NEITHER -- specs/configure.md 4.2. Its row
        # reads `not checked` and the cursor moves on to the next unfinished
        # thing, as if the check had not been opened. Landing on Monitors would
        # say "you got the monitors wrong" to someone who only declined to move
        # them.
        $land =
            if     ($computers.Count -eq 0) { 0 }
            elseif ($answers.Count   -eq 0) { 1 }
            elseif ($devices.Count   -eq 0) { 2 }
            elseif (-not $newTier)          { 3 }
            elseif (-not $onPath -and $null -eq $wantPath) { $pathRow }
            elseif (-not $ranDisplays)      { $save - 3 }
            elseif (-not $ranDisplays.Ok -and -not $ranDisplays.Backed) { 1 }
            elseif (-not $ranTriggers)      { $save - 2 }
            elseif (-not $ranTriggers.Ok -and -not $ranTriggers.Backed) { 2 }
            else                            { $save }

        Write-Host ''
        Write-Host $(if ($answers.Count -and $devices.Count) { '--- review configuration ---' }
                     else { '--- configuration ---' })
        Write-Host ''
        # Esc moves to Cancel rather than doing nothing, and cannot press it.
        $pick = Select-One -Items $items -Detail $detail -Default $land -EscapeTo ($save + 1)

        if ($pick -eq $save + 1) {
            Write-Log 'cancelled; nothing was changed.'
            $global:LASTEXITCODE = 1
            return
        }
        if ($pick -eq $save) {
            # Saving half a setup would write a config the switcher then refuses to
            # act on, which is a worse way to find out.
            $missing = @()
            if ($computers.Count -eq 0) { $missing += 'Computers' }
            if ($answers.Count   -eq 0) { $missing += 'Monitors' }
            if ($devices.Count   -eq 0) { $missing += 'Triggers' }
            # Both have a suggestion, and neither is applied without being chosen:
            # one decides whether a UAC prompt happens, the other edits your PATH.
            if (-not $newTier)          { $missing += 'Autostart?' }
            if (-not $onPath -and $null -eq $wantPath) { $missing += 'Add to PATH?' }
            if ($missing.Count -eq 0) { break }
            Write-Host ''
            Write-Host ('  Still needed: {0}.' -f (Join-Names $missing))
            continue
        }

        switch ($items[$pick]) {
            'Computers' {
                $m = Read-Computers -This $this -Others @($computers | Where-Object { $_ -ne $this }) `
                                    -Existing:([bool]$computers.Count) -Panels $answers
                $this = $m.This
                $computers = $m.All

                # The maps have already followed the edit -- Read-Computers carried
                # each rename and removal into them as it happened. Adding a computer
                # leaves them alone, and the Monitors row then shows which panels do
                # not know about it yet.
                foreach ($a in $answers) { $carry[$a.Key] = $a }
                # specs/configure.md 5.2: a rename or a removal invalidates a
                # monitor-input pass, because the values that passed are no longer
                # the values configured.
                if ($m.Edited) { $ranDisplays = $null }
            }
            'Monitors' {
                $before  = ($answers | ForEach-Object { '{0}={1}' -f $_.Label, (@($_.Map.Values) -join ',') }) -join '|'
                $answers = @(Read-Monitors -Found $found -Answers $answers -Computers $computers `
                                           -This $this -Existing $seed)
                $after   = ($answers | ForEach-Object { '{0}={1}' -f $_.Label, (@($_.Map.Values) -join ',') }) -join '|'
                # A pass belongs to the values that passed. Carrying it across an edit
                # would show "all responded" beside numbers nothing tried -- but
                # looking at the list and changing nothing is not an edit.
                if ($before -ne $after) { $ranDisplays = $null }

                # specs/configure.md 8: giving a panel a transport that cannot
                # switch before login makes an already-chosen boot tier
                # impossible, so it FALLS BACK TO LOGIN AND SAYS SO -- the same
                # shape as a declined elevation.
                #
                # Said here, attached to the choice that caused it, and only in
                # memory: the Autostart? row now reads "from login", the boot row
                # is drawn disabled with the reason, and nothing is written until
                # Save. That is the difference from the bug TODO.md records
                # against the elevation path, which writes the downgrade into the
                # config BEFORE the install that would apply it has succeeded --
                # here the recording and the applying are the same Save.
                $loginOnly = @(Get-LoginOnlyPanels -Answers $answers)
                if ($newTier -eq 's4u' -and $loginOnly.Count -gt 0) {
                    $newTier = 'user'
                    Write-Host ''
                    Write-Host ('  {0} cannot switch before anyone logs in, so starting from' -f (Join-Names $loginOnly))
                    Write-Host '  boot is no longer possible. Changed to starting from login.'
                }
            }
            'Triggers' {
                $devices = @(Read-Triggers -Cands $cands -Current $devices)
                $ranTriggers = $null
            }
            'Autostart?'      { $newTier = Read-Tier -Current $newTier -LoginOnly (Get-LoginOnlyPanels -Answers $answers) }
            'Add to PATH?'    { $wantPath = Read-PathChoice -Current $wantPath }
            { $_ -like 'Test the trigger*' } {
                # Only pull for real once the monitor values have been confirmed by
                # someone looking at them. Before that, a pull would aim unverified
                # values at panels and could leave the desk somewhere nobody meant.
                $ranTriggers = Invoke-TriggerTest -Devices $devices -Answers $answers -This $this `
                                                  -Pull:([bool]($ranDisplays -and $ranDisplays.Ok))
            }
            { $_ -like 'Test the monitor input*' } {
                $ranDisplays = Invoke-DisplayTest -Answers $answers -This $this
                foreach ($a in $answers) { $carry[$a.Key] = $a }
            }
        }
    }

    Write-ConfigFile -Path $CONFIG -Displays $answers -Devices $devices -Tier $newTier -Candidates $cands `
                     -This $this -Existing $existing
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
    param([string[]]$Devices, $Answers, [string]$This, [switch]$Pull)

    # Nothing to watch for is not a check that fails -- it is a check that cannot
    # be run. It used to go ahead anyway: the one-shot was handed -Device '',
    # skipped the empty entry, armed an empty watch list, waited the full 90
    # seconds and then said the devices might be wrong. Say it now instead.
    if (@($Devices).Count -eq 0) {
        Write-Host ''
        Write-Host '  No trigger devices are chosen yet -- pick some first.'
        return [PSCustomObject]@{ Ok = $false; Backed = $false; Text = 'no devices chosen' }
    }

    $ew = Join-Path $PSScriptRoot 'event-watch.ps1'
    if (-not (Test-Path $ew)) { $ew = $WATCH }

    Write-Host ''
    Write-Host '--- test the trigger ---'
    Write-Host '  Flip your switch AWAY from this computer, then back again. The way'
    Write-Host '  back is what a trigger is: the devices ARRIVING here.'
    if ($Pull) {
        Write-Host ''
        Write-Host '  When they do, the monitors will be pulled here for real, using the'
        Write-Host '  values you just checked. That is the whole thing working end to end.'
    } else {
        Write-Host ''
        Write-Host '  The arrival will be reported but the monitors will NOT be moved:'
        Write-Host '  check them first (the row above) and this becomes the real thing.'
    }

    # THE INSTALLED WATCHER IS STOOD DOWN FOR THIS CHECK -- specs/configure.md 11.
    # On a re-run it would otherwise see the same flip and pull against the SAVED
    # config, after the one-shot's pull, so a correct new answer would read as
    # the monitors failing. Where standing it down would need a password the
    # person is told instead, before they flip, because a check must not raise a
    # prompt of its own.
    $paused = $false
    switch (Get-WatcherPauseMode) {
        'can' {
            Suspend-Watcher
            $paused = $true
            Write-Host ''
            Write-Host '  The running watcher is paused for this check.'
        }
        'needs-admin' {
            Write-Host ''
            Write-Host '  The running watcher will also fire, using the saved configuration.'
        }
    }

    # A throwaway config, for the same reason the monitor check uses one: the answers
    # are not written yet, and pulling against the SAVED config would move the panels
    # to whatever was configured before rather than to what is on screen now.
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('trigger-kvm-trig-{0}.cfg' -f $PID)
    $code = 1
    try {
        Write-ConfigFile -Path $tmp -Displays $Answers -Devices $Devices -Tier 'user' -This $This -Existing @{}

        # Piped to the host, not returned. Invoke-Sibling emits the child's stdout on
        # the success stream, so letting it fall out of this function made the caller
        # receive [those lines..., the result object] -- and $ranTriggers.Text on an
        # array throws under StrictMode, which is exactly how this was reported.
        Invoke-Sibling -Script $ew -Arguments @('-TestTrigger', '-Device', ($Devices -join ','),
                                                '-Config', $tmp) |
            ForEach-Object { Write-Host "$_" }
        $code = $LASTEXITCODE

        if ($code -eq 0 -and $Pull) {
            $sw = Join-Path $PSScriptRoot 'trigger-kvm.ps1'
            if (-not (Test-Path $sw)) { $sw = $SWITCH }
            Write-Host ''
            Write-Host '  Pulling the monitors here...'
            Invoke-Sibling -Script $sw -Arguments @('pull', '-Config', $tmp) |
                ForEach-Object { Write-Host "$_" }
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        # Restored on EVERY way out, including the ones that throw: leaving the
        # task disabled would stop the switch working and say nothing.
        if ($paused) { Resume-Watcher }
    }

    if ($code -ne 0) {
        Write-Host ''
        Write-Host '  Nothing arrived, so these may be the wrong devices -- or they may not'
        Write-Host '  be on the switch at all. Pick Triggers again to change them.'
        return [PSCustomObject]@{ Ok = $false; Backed = $false; Text = 'no arrival seen' }
    }

    if (-not $Pull) { return [PSCustomObject]@{ Ok = $true; Backed = $false; Text = 'arrival seen' } }

    Write-Host ''
    if (Read-YesNo '  Did the monitors come back to this computer?' $true) {
        return [PSCustomObject]@{ Ok = $true; Backed = $false; Text = 'fired, monitors followed' }
    }
    Write-Host ''
    Write-Host '  The trigger fired, so the devices are right. Something about the'
    Write-Host '  monitors is not -- check them again from the row above.'
    return [PSCustomObject]@{ Ok = $false; Backed = $false; Text = 'fired, but the monitors did not follow' }
}

# Prove the display answers BEFORE anything is written, against a throwaway config.
#
# The switcher takes its map from a config file rather than from the command line --
# deliberately, so a panel has one description and not two -- so testing early means
# writing a temp one, not weakening the rule that nothing is written until you save.
#
# BATCHED ACROSS PANELS, NEVER ACROSS MACHINES. Monitors sit side by side, so several
# can be checked in one glance; a sequence of switches over half a minute has to be
# held in memory and reported afterwards, and memory is the weak link. So each round
# sends every panel that claims a machine to that machine at once, and asks straight
# away.
#
# The win is the question, not the wall clock. Asking "did they all show mac?" makes
# the common case -- everything worked -- one keystroke, and the four-way diagnosis
# only appears for the panels someone says went wrong. At two monitors that is two
# menus replaced by one yes/no; at four it is twelve replaced by three.
function Invoke-DisplayTest {
    param($Answers, [string]$This)

    # Every managed panel, kept whole even when only one is being checked.
    $All = @($Answers)
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('trigger-kvm-test-{0}.cfg' -f $PID)
    $bad = @()
    try {
        Write-ConfigFile -Path $tmp -Displays $Answers -Devices @() -Tier 'user' -This $This -Existing @{}

        $others = @()
        foreach ($a in $Answers) {
            foreach ($m in $a.Map.Keys) { if ($m -ne $This -and -not ($others -contains $m)) { $others += $m } }
        }

        # Which monitor to check -- their intent, not the tool's convenience. It used
        # to ask where this window was, so it could schedule that panel last; the
        # same protection comes from saying what is about to move and letting someone
        # act on it, which is one fewer question and one they were not able to answer
        # confidently anyway.
        $Answers = @($Answers)
        if ($Answers.Count -gt 1) {
            Write-Host ''
            Write-Host '  Which monitor do you want to check?'
            $rows = @(@('All of them') + @($Answers | ForEach-Object { $_.Name }))
            $pick = Select-One -Items $rows -Default 0 -Escapable
            if ($pick -lt 0) { return [PSCustomObject]@{ Ok = $false; Backed = $true; Text = 'not checked' } }
            if ($pick -gt 0) { $Answers = @($Answers[$pick - 1]) }
        }

        if ($others.Count -eq 0) {
            # Nothing else is on this desk, so there is no claim to check beyond "the
            # transport reaches each panel".
            foreach ($a in $Answers) {
                if (-not (Test-OneComputer -Answer $a -All $All -This $This -Target '' -Config $tmp)) { $bad += $a.Name }
            }
        }

        foreach ($m in $others) {
            $panels = @($Answers | Where-Object { $_.Map.Contains($m) -and $_.Map.Contains($This) })
            if ($panels.Count -eq 0) { continue }

            # Hard rule 4: one panel always stays on this computer, so the question
            # arrives on a screen you can still read. When every panel being checked
            # claims this computer, that means two rounds -- the second covers the one
            # held back.
            $rounds = @()
            if ($panels.Count -eq @($Answers).Count -and $panels.Count -gt 1) {
                $rounds += ,@($panels[0..($panels.Count - 2)])
                $rounds += ,@($panels[-1])
            } else {
                $rounds += ,@($panels)
            }

            foreach ($r in $rounds) {
                # What stays is measured against EVERY managed panel, not just the
                # ones in this check: a panel nobody asked to check is still on this
                # computer, and still somewhere to put a window.
                $moving = @($r | ForEach-Object { $_.Label })
                $stays  = @($All | Where-Object { -not ($moving -contains $_.Label) })
                foreach ($f in (Invoke-TestRound -Panels $r -Stays $stays -Target $m -All $All `
                                                 -This $This -Config $tmp)) {
                    if (-not ($bad -contains $f)) { $bad += $f }
                }
            }
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    # Declining is not a failure and must not read as a pass either.
    if ($bad -contains '(skipped)') { return [PSCustomObject]@{ Ok = $false; Backed = $true; Text = 'not checked' } }
    if ($bad.Count -gt 0) { return [PSCustomObject]@{ Ok = $false; Backed = $false; Text = ('trouble with ' + ($bad -join ', ')) } }
    return [PSCustomObject]@{ Ok = $true; Backed = $false; Text = 'all responded' }
}

# "LG, ASUS and DELL" rather than "LG and ASUS and DELL". These lines are read
# under mild pressure -- a monitor is about to go dark -- so they should not also be
# awkward.
function Join-Names {
    param([string[]]$Names)
    if ($Names.Count -le 1) { return ($Names -join '') }
    if ($Names.Count -eq 2) { return ($Names -join ' and ') }
    return (($Names[0..($Names.Count - 2)] -join ', ') + ' and ' + $Names[-1])
}

# What the monitor's own menu calls an input value, so recovery instructions can say
# "choose HDMI 1" rather than "choose 0x11". Nobody's OSD shows hex.
function Get-InputName {
    param($Answer, [string]$Value)
    # The channel's own table only, never the map: a machine name like "pc" is what
    # THIS tool calls an input, and the monitor's menu has never heard of it.
    $t = $MCCS_INPUTS
    foreach ($d in $DIALECTS.Values) { if ($d.Method -eq $Answer.Method) { $t = $d.Inputs } }
    foreach ($n in $t.Keys) { if ($t[$n] -ieq $Value) { return $n } }
    return ''
}

# One round: send a group of panels to one machine together, bring them all back,
# and ask once. Returns the names of the panels that did not do the right thing.
function Invoke-TestRound {
    param($Panels, $Stays, [string]$Target, $All, [string]$This,
          [string]$Config, [int]$Hold = 8)

    $names = @($Panels | ForEach-Object { $_.Name })
    Write-Host ''
    Write-Host ('  Sending {0} to {1} for {2}s, then back automatically.' -f (Join-Names $names), $Target, $Hold)
    Write-Host ('  If {0} is asleep or off you will see No Signal, which still proves the' -f $Target)
    Write-Host '  switch worked.'

    if ($Stays) {
        $sn = @($Stays | ForEach-Object { $_.Name })
        Write-Host ''
        Write-Host ('  {0} {1} here, so you can read this.' -f (Join-Names $sn),
                    $(if ($sn.Count -eq 1) { 'stays' } else { 'stay' }))
        # Told every round rather than asked once. This cannot see where the window
        # is, and asking made someone answer a question about the tool's scheduling;
        # saying what is about to move lets them act on it only if it applies.
        Write-Host ('  If this window is on {0}, drag it to {1} first: if the switch back' -f `
                    (Join-Names $names), $sn[0])
        Write-Host '  fails, the window goes dark with it and there is no way to answer.'
        # Last, and blocking: it is the thing to act on, so nothing may print after it
        # and be read too late.
        $null = Read-Default '  Enter when ready' ''
        return (Invoke-TestRoundBody -Panels $Panels -Target $Target -All $All -This $This `
                                     -Config $Config -Hold $Hold -Names $names)
    }

    # One monitor and no way to hold anything back: if the switch back fails, this
    # person is looking at a black screen with no way to read a prompt, ask a question
    # or undo anything. That is unavoidable -- but being stranded WITHOUT having been
    # told how to get back is not, and the telling has to happen while there is still
    # a screen to read it on.
    $solo  = @($Panels) | Select-Object -First 1
    $back  = $solo.Map[$This]
    $bname = Get-InputName -Answer $solo -Value $back
    Write-Host ''
    Write-Host '  READ THIS FIRST -- this is your only monitor.'
    Write-Host '  You will not be able to read anything while it is away.'
    Write-Host ''
    Write-Host '  IF IT DOES NOT COME BACK there is nothing this tool can do for you --'
    Write-Host '  it cannot draw on a screen that is showing another computer. The way'
    Write-Host '  back is the monitor itself: press its input (or source) button and'
    Write-Host ('  choose {0}. No software can take that button away from you.' -f `
                $(if ($bname) { '{0}, value {1}' -f $bname, $back } else { "value $back" }))
    Write-Host ''
    if (-not (Read-YesNo '  Ready?' $true)) {
        Write-Host '  Skipped. Nothing was sent.'
        return @('(skipped)')
    }

    return (Invoke-TestRoundBody -Panels $Panels -Target $Target -All $All -This $This `
                                 -Config $Config -Hold $Hold -Names $names)
}

# The half after the explaining: send, wait, send back, and find out what happened.
function Invoke-TestRoundBody {
    param($Panels, [string]$Target, $All, [string]$This, [string]$Config, [int]$Hold, [string[]]$Names)

    foreach ($a in $Panels) { Send-Input -Label $a.Label -Value $a.Map[$Target] -Config $Config }
    Start-Sleep -Seconds $Hold
    foreach ($a in $Panels) { Send-Input -Label $a.Label -Value $a.Map[$This] -Config $Config }
    Start-Sleep -Seconds 2

    Write-Host ''
    $q = if ($Panels.Count -eq 1) { "  Did $($Names[0]) show $Target, then come back?" }
         else                     { "  Did all of them show $Target, then come back?" }
    if (Read-YesNo $q $true) { return @() }

    # Only now does anyone have to think. One panel needs no narrowing question.
    $wrong = $Panels
    if ($Panels.Count -gt 1) {
        Write-Host ''
        Write-Host '  Which ones did not?'
        $picked = Select-Many -Items $Names -Detail @($Panels | ForEach-Object { $_.Label }) `
                              -DoneLabel 'Done'
        $wrong = @($picked | ForEach-Object { $Panels[$_] })
    }

    $bad = @()
    foreach ($a in $wrong) {
        if (-not (Test-OneComputer -Answer $a -All $All -This $This -Target $Target -Config $Config)) { $bad += $a.Name }
    }
    return $bad
}


# One panel, one machine: send it there, bring it back, act on what the human saw.
# Fixes retry in place, because bouncing out to the review menu to change one value
# and come back is a worse way to say "try that again".
function Test-OneComputer {
    param($Answer, $All, [string]$This, [string]$Target, [string]$Config, [int]$Attempt = 1)

    # Write before every attempt: escalating to a dialect changes the method, and the
    # switcher reads the method from the file.
    Write-ConfigFile -Path $Config -Displays $All -Devices @() -Tier 'user' -This $This -Existing @{}

    $here = $Answer.Map[$This]
    if ($Target) {
        $outcome = Test-DisplayInput -Label $Answer.Label -Name $Answer.Name -IsComputer `
                                     -Candidate $Answer.Map[$Target] -CandidateName $Target `
                                     -Current $here -ThisName $This -Config $Config
    } else {
        # Nothing else is on this panel, so there is no claim to check beyond "the
        # transport reaches it". Any other input value will do.
        $table = Get-InputTable -Method $Answer.Method -Map $Answer.Map
        $n = @($table.Keys | Where-Object { $table[$_] -ine $here } | Select-Object -First 1)
        if (-not $n) { return $true }
        $outcome = Test-DisplayInput -Label $Answer.Label -Name $Answer.Name `
                                     -Candidate $table[$n[0]] -CandidateName $n[0] `
                                     -Current $here -ThisName $This -Config $Config
    }

    if ($outcome -eq 0) { return $true }
    if ($Attempt -ge 2) { return $false }   # bounded: one retry per fix

    # 1: the panel obeys and the value for this computer is right -- that input is
    # just not the machine we thought.
    if ($outcome -eq 1 -and $Target) {
        Write-Host ''
        Write-Host ('  So that input is not {0}. Which one is?' -f $Target)
        $taken = @{}
        foreach ($m in $Answer.Map.Keys) { if ($m -ne $Target) { $taken[$Answer.Map[$m]] = $m } }
        $v = Read-InputValue -Table (Get-InputTable -Method $Answer.Method -Map $Answer.Map) `
                             -Default $Answer.Map[$Target] -Taken $taken -AllowNone `
                             -Method $Answer.Method `
                             -Prompt ("On the {0}, which input is '{1}' on?" -f $Answer.Name, $Target)
        if ($null -eq $v) { $Answer.Map.Remove($Target); return $true }
        $Answer.Map[$Target] = $v
        return (Test-OneComputer -Answer $Answer -All $All -This $This -Target $Target -Config $Config -Attempt ($Attempt + 1))
    }

    # 2: the panel obeys, so the channel is right; the value for THIS computer is not.
    if ($outcome -eq 2) {
        Write-Host ''
        Write-Host ('  So {0} responds -- the channel is right. The input for this' -f $Answer.Name)
        Write-Host '  computer is not. Use that monitor''s own buttons to bring it back,'
        Write-Host '  then tell me which input that is.'
        Write-Host ''
        if (Read-YesNo '  Do you know which input it is?' $true) {
            # -Taken, like every other input question. Without it this one repair
            # let someone pick an input another computer already holds, and the
            # writer then emitted the same key twice while the reader kept one --
            # specs/configure.md 6.1, "Two computers cannot share one input".
            $taken = @{}
            foreach ($m in $Answer.Map.Keys) { if ($m -ne $This) { $taken[$Answer.Map[$m]] = $m } }
            $Answer.Map[$This] = Read-InputValue -Table (Get-InputTable -Method $Answer.Method -Map $Answer.Map) `
                -Default $Answer.Map[$This] -Taken $taken -Method $Answer.Method `
                -Prompt ("On the {0}, which input is '{1}' on?" -f $Answer.Name, $This)
        } else {
            $found = Invoke-BlindWalk -Answer $Answer -Config $Config -OtherPanels (@($All).Count - 1)
            if (-not $found) { return $false }
            $Answer.Map[$This] = $found
        }
        return (Test-OneComputer -Answer $Answer -All $All -This $This -Target $Target -Config $Config -Attempt ($Attempt + 1))
    }

    # 3: nothing at all. The channel is wrong, so the other channel is the thing to
    # try -- OFFERED, from documented values, never probed.
    #
    # SYMMETRIC, since 2026-08-31. A panel on the manufacturer method that answers
    # nothing has to be offered STANDARD, because specs/configure.md 6.2 now lets
    # someone choose the manufacturer method up front, so a panel can arrive here
    # already on it. Telling that person "no manufacturer values are known here"
    # would be false and a dead end.
    $d   = $DIALECTS['{0:X4}' -f $Answer.EdidVendor]
    $alt = $null

    if ($d -and $Answer.Method -ne $d.Method) {
        # On standard, and this vendor documents an alternative.
        Write-Host ''
        Write-Host ('  {0} did not answer the standard channel. It is {1}, and some {1}' -f $Answer.Name, $d.What)
        Write-Host '  panels put input switching on a manufacturer channel instead. These'
        Write-Host ('  values are documented for {0}, and are the only ones that will be' -f $d.What)
        Write-Host '  sent -- nothing is guessed at on a manufacturer channel:'
        $alt = @{ Method = $d.Method; Yes = ("Yes, try the {0} channel" -f $d.What); Values = $d.Inputs }
    }
    elseif ($Answer.Method -ne 'standard') {
        # On a manufacturer channel, so standard is what is left. Reached from 6.2's
        # up-front choice, and from a hand-edited config naming a method no table
        # knows -- both land here, and both have the same one thing left to try.
        $what = $(if ($d) { $d.What } else { $Answer.Mfg })
        Write-Host ''
        Write-Host ('  {0} is on {1}''s own method and did not answer it. The standard method' -f $Answer.Name, $what)
        Write-Host '  is the other thing to try. It is what nearly every monitor takes,'
        Write-Host '  and these are its values:'
        $alt = @{ Method = 'standard'; Yes = 'Yes, try the standard method'; Values = $MCCS_INPUTS }
    }

    if ($alt) {
        # The values are shown BEFORE the question is asked, in both directions.
        Write-Host ''
        foreach ($n in $alt.Values.Keys) { Write-Host ('    {0,-14} {1}' -f $n, $alt.Values[$n]) }
        Write-Host ''
        # A menu, like every other decision in the walkthrough. This one used to be
        # the last y/n confirm left, which made the most consequential question in the
        # program look like the least considered.
        $go = Select-One -Default 0 -Escapable `
                  -Items @($alt.Yes, 'No, leave this monitor out') `
                  -Detail @('and say which input each computer is on',
                            'everything else stays configured')
        if ($go -ne 0) { return $false }

        # Every value in the old map was for a channel that does not work, so the
        # map starts again rather than carrying meaningless numbers across.
        $Answer.Method = $alt.Method
        $keep = @($Answer.Map.Keys)
        $Answer.Map = [ordered]@{}
        $taken = @{}
        foreach ($m in $keep) {
            $v = Read-InputValue -Table (Get-InputTable -Method $alt.Method -Map $Answer.Map) `
                                 -Taken $taken -AllowNone:($m -ne $This) -Method $alt.Method `
                                 -Prompt ("On the {0}, which input is '{1}' on?" -f $Answer.Name, $m)
            if ($null -ne $v) { $Answer.Map[$m] = $v; $taken[$v] = $m }
        }
        return (Test-OneComputer -Answer $Answer -All $All -This $This -Target $Target -Config $Config -Attempt ($Attempt + 1))
    }

    # On standard, and nothing else is documented for this vendor.
    Write-Host ''
    Write-Host ('  {0} did not answer the standard channel, and no manufacturer values' -f $Answer.Name)
    Write-Host ('  are known here for {0}. That panel may not support DDC/CI input' -f $Answer.Mfg)
    Write-Host '  switching at all, or may use a channel nobody has documented.'
    Write-Host ''
    Write-Host '  Everything else is still configured; this monitor just will not follow'
    Write-Host '  the switch. Leave it out with Monitors -> "Manage this monitor? no".'
    return $false
}

# Rewrite the config from the answers. There is nothing left to preserve: scenes are
# gone, and every fact the file holds is something the walkthrough asked about.
# Superseded spellings of keys the walkthrough writes. NOT unknown keys: each is
# the same fact under an older name, and carrying one across a Save would leave
# two answers to one question in the file -- which is the drift this project
# deletes tables to avoid. `configure` rewrites the file without them, and the
# install path warns while they are still honoured.
$RENAMED_KEYS = @{
    'trigger.usb.device'      = 'trigger.device'
    'trigger.usb.debounce'    = 'trigger.debounce'
    'trigger.usb.settle'      = 'trigger.settle'
    'trigger.device.usb'      = 'trigger.device'
    'trigger.device.debounce' = 'trigger.debounce'
    'trigger.device.settle'   = 'trigger.settle'
    'install.tier'            = 'install.autostart'
    'install.start'           = 'install.autostart'
}

# Everything in the old file that this walkthrough does not write itself, as
# `key = value` lines -- specs/config-format.md, "Hand edits survive".
#
# An unknown key is somebody's hand edit or a newer version's setting, and
# dropping it on Save is a silent loss with no way to notice. A key the
# walkthrough DOES write is dropped on purpose: that is the answer being applied.
#
# A display.<label>.* key is kept only while that panel is still MANAGED.
# Unmanaging a panel is the one answer that means "forget", and it forgets the
# whole panel -- so an unknown key under a dropped label goes with it.
function Get-CarriedKeys {
    param([System.Collections.IDictionary]$Existing, $Displays)

    $managed = @(@($Displays) | ForEach-Object { $_.Label })
    $out = @()
    foreach ($k in @($Existing.Keys)) {
        if ($k -in @('install.autostart', 'computer.this',
                     'trigger.device', 'trigger.debounce', 'trigger.settle')) { continue }
        if ($RENAMED_KEYS.Contains($k)) { continue }
        if ($k -match '^display\.([^.]+)\.(.+)$') {
            if ($managed -notcontains $Matches[1]) { continue }
            if ($Matches[2] -in @('vendor', 'product', 'name', 'method', 'transport')) { continue }
            if ($Matches[2] -like 'input.*') { continue }
        }
        $out += ('{0} = {1}' -f $k, $Existing[$k])
    }
    return @($out | Sort-Object)
}

function Write-ConfigFile {
    # $Candidates only supplies the remembered spot for a tokened device, so it
    # is optional: every caller that writes no devices, and every older caller,
    # still writes a correct file without it.
    param([string]$Path, $Displays, [string[]]$Devices, [string]$Tier,
          [string]$This, [System.Collections.IDictionary]$Existing, $Candidates = @())

    $lines = @(
        '# trigger-kvm configuration'
        '#'
        '# Written by `trigger-kvm configure`. Safe to edit by hand.'
        '#'
        '# Everything here is read at the point it is used, so there is no separate'
        '# apply step: display edits take effect on the next switch, and trigger edits'
        '# when the watcher next starts --  trigger-kvm restart'
        '#'
        '# Displays are identified by the EDID the GPU reads off the output, never by'
        '# index -- \\.\DISPLAYn numbers are not stable and have swapped on this'
        '# computer. See what is attached with:  trigger-kvm list'
        ''
        '# --- install ----------------------------------------------------------'
        ("install.autostart = {0}" -f $(switch ($Tier) { 's4u' { 'boot' } 'manual' { 'no' } default { 'login' } }))
        ''
        '# --- computers --------------------------------------------------------'
        '# What this computer is called below. `trigger-kvm pull` means "point every'
        '# display at this one"; `trigger-kvm to mac` names any other.'
        ''
        ("computer.this = {0}" -f $This)
        ''
        '# --- displays ---------------------------------------------------------'
        '# method:    WHAT is sent.'
        '#         standard (I2C src 0x51, VCP 0x60) -- what nearly every panel takes'
        '#         lg-alt   (src 0x50, VCP 0xF4) -- LG panels whose 0x60 is stubbed'
        '# transport: HOW it gets there.'
        '#         nvapi -- aimed raw I2C at one GPU output. NVIDIA only, works with'
        '#                  no desktop, and the only one that can carry lg-alt.'
        '#         dxva2 -- Windows'' own DDC/CI stack. Any adapter, but it needs a'
        '#                  desktop, so a panel on it does not follow the switch'
        '#                  until somebody has logged in.'
        '#         Omit it and it means nvapi. Never a fallback: nothing tries one'
        '#         and falls through to the other.'
        '# input.<value> = <computer>: which computer is on which input of that panel.'
        '#         This is the whole map. pull and to are the same lookup against it,'
        '#         differing only in which name they look up, so the two can never'
        '#         disagree about where a computer is.'
        ''
    )
    foreach ($d in $Displays) {
        $lines += @(
            ("display.{0}.vendor    = {1}" -f $d.Label, $d.Vendor)
            ("display.{0}.product   = {1}" -f $d.Label, $d.Product)
            # THE ONE FREE-TEXT VALUE HERE, and it comes from the panel rather
            # than from anybody who could be asked to change it -- so it is the
            # one that has to be made storable. specs/config-format.md, "A writer
            # must not write what it cannot read back": `ACME #1 Display` used to
            # be written intact and read back as `ACME`, and EDID descriptor
            # strings are LF-terminated by the standard.
            #
            # Every other value on this page is already safe by construction:
            # labels and computer names are name-ruled to [a-z0-9-], vendor and
            # product are 0xNNNN, transport and method are enumerated, inputs are
            # hex, and the timings are decimals.
            ("display.{0}.name      = {1}" -f $d.Label, (ConvertTo-ConfigValue $d.Name))
            ("display.{0}.transport = {1}" -f $d.Label, $(if ($d.Transport) { $d.Transport } else { 'nvapi' }))
            ("display.{0}.method    = {1}" -f $d.Label, $d.Method)
        )
        foreach ($m in $d.Map.Keys) {
            $lines += ("display.{0}.input.{1} = {2}" -f $d.Label, ([string]$d.Map[$m]).ToLower(), $m)
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
        '# Triggers run `pull` and nothing else. Never wire one to another computer: a'
        '# name like `mac` describes inputs on hardware this computer cannot observe,'
        '# and a stale one would then be able to cause an AUTOMATIC switch to a dead'
        '# input. Getting there by hand, watching, is a different risk entirely.'
        '#'
        '# device: usb:VVVV:PPPP (bare VVVV:PPPP means usb) or bt:AAAAAAAAAAAA.'
        '#         Bluetooth fires on CONNECTED, and every PAIRED device is offered.'
        ''
        # The remembered spot is appended HERE rather than carried in the key,
        # because it is not part of a device's identity: an entry whose device
        # moved sockets is still the same entry. specs/detector.md 4.1 confines
        # `where` to breaking a tie, and only a tokened entry can have one --
        # there is nothing to break a tie between otherwise.
        ("trigger.device   = {0}" -f (@($Devices | ForEach-Object {
            $d = $_
            $c = @($Candidates | Where-Object { $_.Key -eq $d }) | Select-Object -First 1
            if ($c -and $d -like '*@*' -and $c.Spot) { '{0}@{1}' -f $d, $c.Spot } else { $d }
        }) -join ', '))
        ("trigger.debounce = {0}" -f $(if ($Existing.Contains('trigger.debounce')) { $Existing['trigger.debounce'] } else { $DEFAULT_DEBOUNCE }))
        ("trigger.settle   = {0}" -f $(if ($Existing.Contains('trigger.settle'))   { $Existing['trigger.settle'] }   else { $DEFAULT_SETTLE }))
        ''
    )

    $carried = @(Get-CarriedKeys -Existing $Existing -Displays $Displays)
    if ($carried.Count -gt 0) {
        $lines += @(
            '# --- kept from the previous file (not something configure asks about) --'
            ''
        ) + $carried + @('')
    }

    $lines | Set-Content -LiteralPath $Path -Encoding ASCII
}

# --- the verb surface ---------------------------------------------------------

# EVERY VERB `trigger-kvm` ACCEPTS, IN ONE PLACE, because it was in three and they
# had already drifted. The shim's routing table, this script's ValidateSet and
# trigger-kvm.ps1's ValidateSet each held a partial answer, and none could see the
# others -- so an unknown verb produced a raw PowerShell binding error naming
# "install,configure,status,discover,restart,logs,pause,uninstall": it OMITTED
# pull, to and list, which the shim routes away before this script ever sees them,
# and it OFFERED install, which the shim refuses at :noinstall. The one message a
# lost user got named a verb that does not work and hid three that do.
#
# So both the usage text and the shim's routing are generated from here, and
# conventions.tests.ps1 asserts the two ValidateSets still agree with it.
#
# `Where` is which script runs it: the switcher is kept lean because it runs on
# every device arrival, and the installer is large and rarely used. That split is
# the reason a shim exists at all.
#
# `set` IS DELIBERATELY ABSENT. trigger-kvm.ps1 accepts it for the installer's
# guided input discovery, and the shim has never routed it: a general "write any
# value to a monitor" command invites exactly the poking at panels that hard rule
# 1 exists to discourage. Do not "fix" the omission.
$VERBS = @(
    @{ Verb = 'pull';      Where = 'switch'; Arg = ''
       Help = 'point every configured monitor at this computer' }
    @{ Verb = 'to';        Where = 'switch'; Arg = '<computer>'
       Help = 'point them at another computer, by name. Manual only' }
    @{ Verb = 'list';      Where = 'switch'; Arg = ''
       Help = 'what displays are attached, and how the switch can reach them' }
    @{ Verb = 'configure'; Where = 'manage'; Arg = ''
       Help = 'set up monitors, computers and triggers' }
    @{ Verb = 'status';    Where = 'manage'; Arg = ''
       Help = 'what is installed, running and configured' }
    @{ Verb = 'discover';  Where = 'manage'; Arg = ''
       Help = 'what this computer can see right now' }
    @{ Verb = 'restart';   Where = 'manage'; Arg = ''
       Help = 'start the watcher, or restart it after a pause' }
    @{ Verb = 'pause';     Where = 'manage'; Arg = ''
       Help = 'stand the watcher down until the next restart' }
    @{ Verb = 'logs';      Where = 'manage'; Arg = ''
       Help = 'follow the log' }
    @{ Verb = 'uninstall'; Where = 'manage'; Arg = ''
       Help = 'remove it, keeping the config and the log' }
)

# The usage text, built from the table so it cannot describe a verb that is not
# routed or miss one that is.
#
# SHAPED TO MATCH macOS's `usage()`, which had all of this right before Windows
# did -- same opening line, same verb-then-options layout, same closing notes.
# This side was simply not conforming: `trigger-kvm` bare PULLED here and printed
# usage there, and the root README already claims the verbs are the same on both
# platforms. Keep them reading alike; the flags differ only where each platform's
# convention does (-Only / --only, -WhatIf / --dry-run).
#
# The switching verbs come first and are separated from the management ones,
# because they are what the tool is FOR -- the rest is setup and diagnosis you
# touch once. `pull` is named first for the same reason it is what a trigger runs.
function Get-UsageText {
    $out = @(
        'usage: trigger-kvm <verb> [options]'
        ''
    )
    $w = 0
    foreach ($v in $VERBS) {
        $n = ($v.Verb + $(if ($v.Arg) { ' ' + $v.Arg } else { '' })).Length
        if ($n -gt $w) { $w = $n }
    }
    $last = ''
    foreach ($v in $VERBS) {
        if ($last -and $v.Where -ne $last) { $out += '' }
        $out += ('  {0,-' + $w + '}   {1}') -f `
                ($v.Verb + $(if ($v.Arg) { ' ' + $v.Arg } else { '' })), $v.Help
        $last = $v.Where
    }
    $out += @(
        ''
        'options:'
        '  -Only <label>         one configured display only'
        '  -WhatIf               resolve and print the packets, send nothing'
        '  -Fresh                configure: pre-fill nothing, ask everything again'
        '  -Config <path>        use this config instead of the default'
        ''
        'Only pull is ever automatic. A trigger runs pull and nothing else: another'
        'computer''s name describes hardware this one cannot observe, so a stale one'
        'could switch a monitor to a dead input with nobody watching.'
        ''
        'There is no `install` verb, deliberately: installing is what produced this'
        'command. Upgrading and repairing both mean "fetch the source and run its'
        'installer".'
        ''
        'There is no `apply` step either. Everything is read at the point it is used:'
        'display edits take effect on the next switch, trigger edits when the watcher'
        'next starts -- and `restart` does that.'
    )
    return $out
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

# The device's own name for itself is read by event-watch.ps1 and asked for
# through -ListUsb, NOT read here. That script owns the binding because it is
# what matches a token on every presence sweep, and two copies of a P/Invoke
# drift -- with the nasty shape that the walkthrough writes a token the watcher
# cannot find. Same rule as -ListBluetooth. See Get-TriggerCandidates.

# Names Windows hands out when it has nothing specific to say. Matching one of
# these identifies a CLASS of device, not a device.
$GENERIC_NAMES = '^(USB Input Device|USB Composite Device|USB Device|' +
                 'HID-compliant [a-z ]+|Generic USB [A-Za-z]+|' +
                 'USB Attached SCSI \(UAS\) Mass Storage Device)$'

# The best of the names one device reports about itself.
#
# A FUNCTION over a list of names, not a regex buried in the enumeration loop,
# because this is the thing most likely to need another case later and it must be
# testable without any hardware attached.
#
# "Best" TESTS THE NAME, which is the whole correction here. The rule it replaces
# ranked by how specific a node's device CLASS was, as a proxy for how good its
# name would be -- and the proxy is inverted, because HID nodes are exactly the
# ones Windows names generically. On this desk that made the keyboard's row read
# `USB Input Device` while a sibling node already said `G915 X LIGHTSPEED TKL`.
#
# A NAME BEGINNING "USB " IS DESCRIBING THE BUS, NOT THE DEVICE. That is true of
# every generic name measured here -- `USB Input Device`, `USB Receiver`,
# `USB Audio`, `USB Composite Device` -- and of none of the manufacturers' own
# strings. Preferring against it is what promotes `Realtek USB Audio` over
# `USB Audio`, and it beats keeping a list of weak names, which would drift and
# would only ever describe the desks somebody happened to own.
function Get-BestDeviceName {
    param([string[]]$Names)

    $all = @($Names | Where-Object { $_ } | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if ($all.Count -eq 0) { return '' }

    $named = @($all | Where-Object { $_ -notmatch $GENERIC_NAMES -and $_ -notmatch '^USB ' })
    if ($named.Count -gt 0) { return $named[0] }
    $good = @($all | Where-Object { $_ -notmatch $GENERIC_NAMES })
    if ($good.Count -gt 0) { return $good[0] }
    # Everything it reports is generic. Say the generic thing rather than nothing
    # -- an empty row is worse than a vague one.
    return $all[0]
}

# What each VID:PID actually presents to the user, from its HID children.
#
# These are the `HID\VID_...` nodes, which the USB pass skips because it matches
# `USB\` only -- so this costs nothing but a second walk of a list already in
# hand. It is the most useful thing on the row: `mouse, keyboard` says what the
# device IS in the terms somebody chose it in.
#
# It also shows when one dongle carries both, which is a fact people need: a
# Logitech receiver serving a keyboard and a mouse is ONE vendor+product and
# therefore ONE row. There is no way to trigger on just the mouse.
function Get-DeviceRoles {
    param($Devices)

    $roles = @{}
    foreach ($d in @($Devices)) {
        if ("$($d.InstanceId)" -notmatch '^HID\\VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') { continue }
        $key = ('usb:{0}:{1}' -f $Matches[1], $Matches[2]).ToLower()
        # Mouse and Keyboard only. Every such device also presents a bare
        # HIDClass node, which says nothing a person can use.
        if ($d.Class -notin @('Mouse', 'Keyboard')) { continue }
        $r = "$($d.Class)".ToLower()
        if (-not $roles.Contains($key)) { $roles[$key] = @() }
        if ($roles[$key] -notcontains $r) { $roles[$key] += $r }
    }
    return $roles
}

# WHAT THE DEVICE IS: its name, and what it presents itself as. Built once
# because both places that show candidates want exactly this and it is the half
# with a rule behind it.
#
# The STATE is deliberately NOT in here, and that is a change. Connected-vs-paired
# is not part of what a device IS -- it is a fact about right now -- and putting
# it here made a single column carry both, so `Chris's AirPods Pro - Find My
# (paired, not connected)` ran 53 characters and shoved the vendor+product column
# out of alignment for every row beneath it. Both callers now place it after the
# key, in the same relative position, which is one `$_.State` each rather than a
# second formatting rule.
function Get-CandidateLabel {
    param($Candidate)
    $s = "$($Candidate.Name)"
    if ($Candidate.Roles) { $s += ('  ({0})' -f (@($Candidate.Roles) -join ', ')) }
    # A device that cannot be told from its twin is not a device you can pick,
    # and the row says so rather than looking like a choice. specs/detector.md
    # 4.1: where no name is held by exactly one of them, no token is written.
    if ($Candidate.Ambiguous) { $s += '  [cannot be told from its twin]' }
    return $s
}

function Get-TriggerCandidates {
    # ONE ROW PER PHYSICAL DEVICE, and the enumeration is ASKED OF THE WATCHER
    # rather than done here -- specs/detector.md 4.1. event-watch.ps1 owns the
    # device-property binding because it is what matches a token on every
    # presence sweep, and a second copy here could drift; the shape of that drift
    # is a walkthrough writing a token the watcher cannot find. Same reasoning as
    # -ListBluetooth, and as asking trigger-kvm.ps1 for the display list.
    #
    # Fields: container|vid|pid|token|where|name, one line per candidate name.
    $devices = @{}
    $ew = Join-Path $PSScriptRoot 'event-watch.ps1'
    if (-not (Test-Path -LiteralPath $ew -PathType Leaf)) { $ew = $WATCH }
    foreach ($line in (Invoke-Sibling -Script $ew -Arguments @('-ListUsb') 2>$null)) {
        $f = "$line" -split '\|', 6
        if ($f.Count -lt 6) { continue }
        $key = ('usb:{0}:{1}' -f $f[1], $f[2]).ToLower()
        # A failed enumeration is not addressable at all.
        if ($key -like 'usb:0000:*') { continue }
        $id = '{0}|{1}' -f $f[0], $key
        if (-not $devices.Contains($id)) {
            $devices[$id] = [PSCustomObject]@{
                Key = $key; Tokens = @(); Names = @(); Where = $f[4]
            }
        }
        if ($f[3] -and $devices[$id].Tokens -notcontains $f[3]) { $devices[$id].Tokens += $f[3] }
        if ($f[5] -and $devices[$id].Names  -notcontains $f[5]) { $devices[$id].Names  += $f[5] }
    }

    # Roles come from the HID children, which are `HID\` nodes the USB listing
    # never sees. Cheap, and the most recognisable thing on a row.
    $roles = Get-DeviceRoles -Devices @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)

    # A VENDOR:PRODUCT PAIR CAN NAME MORE THAN ONE DEVICE, so the token that
    # distinguishes them is chosen HERE, per id, where the other candidates are
    # visible. Choosing the "best" name per device in isolation is not enough:
    # measured on this desk both receivers report `usb-receiver`, and only one
    # reports `g915-x-lightspeed-tkl`.
    $usb = @()
    foreach ($grp in ($devices.Values | Group-Object Key)) {
        $mine  = @($grp.Group)
        $alone = ($mine.Count -eq 1)
        foreach ($d in $mine) {
            $token = ''
            if (-not $alone) {
                # Held by exactly one device in this group. Where none is, the
                # device cannot be named apart from its twin and the row says so
                # rather than writing a token that matches both.
                $token = @($d.Tokens | Where-Object {
                    $t = $_
                    (@($mine | Where-Object { $_.Tokens -contains $t }).Count -eq 1)
                } | Select-Object -First 1)
                if ($token -isnot [string]) { $token = [string]$token }
            }
            $name = Get-BestDeviceName -Names $d.Names
            if (-not $name) { continue }
            # Hubs and controllers are attached permanently and never move.
            #
            # Tested against EVERY name the device reports, not the chosen one.
            # Choosing the best name defeats a filter aimed at the worst: an ASM
            # hub controller calls itself `ASM107x` while its driver calls it
            # `Generic USB Hub`, so preferring the device's own name promoted it
            # past the filter and put two hub controllers back in the list.
            if (@($d.Names | Where-Object { $_ -match 'Hub|Host Controller|Root Complex' })) { continue }

            $usb += [PSCustomObject]@{
                # IDENTITY, without the remembered spot: a device that moved
                # sockets is still the same entry, so the "currently a trigger"
                # marker and the config round trip both keep working.
                Key   = $d.Key + $(if ($token) { "@$token" } else { '' })
                Bus   = 'USB'
                Name  = $name
                Roles = @($roles[$d.Key] | Where-Object { $_ })
                Class = ''
                Spot  = $d.Where
                # More than one device on this id and nothing to tell them apart.
                Twinned = (-not $alone)
                Ambiguous = ((-not $alone) -and (-not $token))
                State = ''
                # Rank answers only HOW LIKELY THIS IS TO TRAVEL. It used to pick
                # the row's NAME as well, from a single number scoring how
                # specific a node's device class was -- an inverted proxy, since
                # HID nodes are exactly the ones Windows names generically.
                Rank  = $(if ($roles[$d.Key]) { 0 }
                          elseif ($name -match 'Audio|Camera|Webcam') { 1 }
                          else { 3 })
            }
        }
    }

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
        $rows = Invoke-Sibling -Script (Join-Path $PSScriptRoot 'event-watch.ps1') `
                               -Arguments @('-ListBluetooth') 2>$null
        foreach ($row in $rows) {
            $parts = "$row" -split '\|', 3
            if ($parts.Count -lt 3) { continue }
            $bt += [PSCustomObject]@{
                Key = 'bt:' + $parts[0]; Bus = 'BT'; Name = $parts[2]; Class = 'Bluetooth'
                # Bluetooth reports no HID roles here -- the classic API gives a
                # name and a connected flag, not a usage page. An empty array
                # rather than an absent property: Set-StrictMode makes reading a
                # property that is not there terminating, and every consumer of a
                # candidate reads this one.
                Roles = @()
                # A Bluetooth address already names one device, so none of the
                # disambiguation applies. Present and empty rather than absent:
                # Set-StrictMode makes reading a property that is not there
                # terminating, and every consumer of a candidate reads these.
                Spot = ''; Twinned = $false; Ambiguous = $false
                State = $(if ($parts[1] -eq 'True') { 'connected now' } else { 'paired, not connected' })
                # Ranked with the audio and camera devices: a paired peripheral is
                # a likely trigger, but nothing here says it is an input device the
                # way a HID mouse child does.
                Rank = 1
            }
        }
    } catch {
        # No radio, or the API is unavailable. Not a reason to fail discovery.
        Write-Log "note: Bluetooth enumeration unavailable ($($_.Exception.Message))"
    }

    return @(@($usb) + @($bt) | Sort-Object Rank, Name)
}

if ($Command -eq 'help') {
    Get-UsageText | ForEach-Object { Write-Host $_ }
    # EXIT 2, INCLUDING for an explicit `help`, because macOS's usage() does --
    # every path into it there ends `exit 2`, `-h` and `--help` included.
    #
    # Exit 0 for an explicit request would be the more conventional choice and it
    # was written that way first. It was changed on purpose: two implementations
    # of one CLI disagreeing about an exit code is precisely the kind of drift
    # this repo spends a conformance check preventing, and "the verbs are the
    # same on both platforms" is a claim README.md already makes. Making them
    # agree needs no spec change; diverging would need one FIRST.
    exit 2
}

if ($Command -eq 'discover') {
    Write-Host ''
    Write-Host '=== displays on this computer ==='
    Invoke-Sibling -Script (Join-Path $PSScriptRoot 'trigger-kvm.ps1') `
                   -Arguments @('list', '-Config', $CONFIG)

    Write-Host ''
    Write-Host '=== devices that could be a trigger ==='
    Write-Host ''
    Write-Host 'The trigger is whatever MOVES when you flip the switch. Pick the ones that'
    Write-Host 'travel; USB rows are what is attached right now, Bluetooth rows what is paired.'
    Write-Host ''

    $cur = @()
    if (Test-Path -LiteralPath $CONFIG) {
        $c = Read-Config -Path $CONFIG
        if ($c.Contains('trigger.device')) {
            # Canonicalise to the same form the candidate keys use. A config entry
            # may be bare (VVVV:PPPP), which means usb -- without this the
            # "currently a trigger" markers silently stop appearing for every
            # pre-Bluetooth config, which reads as "none of these are configured"
            # and is worse than no marker at all.
            #
            # ONLY a well-formed entry earns a marker. A malformed one matches
            # nothing here, which is correct: the watcher will not start on it, so
            # marking a row as configured because of it would be a third screen
            # disagreeing with the file.
            $cur = @(ConvertFrom-TriggerDevices $c['trigger.device'] |
                     Where-Object { $_.Ok } | ForEach-Object { $_.Identity })
        }
    }

    foreach ($d in (Get-TriggerCandidates)) {
        $mark = $(if ($cur -contains $d.Key) { ' <- currently a trigger' } else { '' })
        # Same order as the Triggers menu, for the same reason: what it is, then
        # what identifies it. The Class column went -- it was the internal reason
        # a row used to be named badly, and now that names are chosen by testing
        # names it tells a reader nothing they can act on.
        Write-Host ('  {0,-40} {1,-36} {2,-4}{3}{4}' -f (Get-CandidateLabel $d), $d.Key, $d.Bus,
                    $(if ($d.State) { '  ' + $d.State } else { '' }), $mark)
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
    Suspend-Watcher
    Resume-Watcher
    Start-Sleep -Seconds 2
    # The lock, not a process count: a boot-tier watcher comes up in session 0,
    # where an unelevated caller cannot read CommandLine, so counting reported
    # "no watcher came up" about one that had.
    $up = Test-WatcherRunning
    if ($up) { Write-Log 'restarted; the watcher has re-read the config.' }
    else { Write-Log 'restarted, but no watcher came up -- check: trigger-kvm logs' }
    exit $(if ($up) { 0 } else { 1 })
}

if ($Command -eq 'pause') {
    Suspend-Watcher
    Write-Log "paused: task disabled and watcher stopped"
    Write-Log 'run one by hand now, e.g.:'
    Write-Log '    .\event-watch.ps1 -Exec .\trigger-kvm.ps1 -Arg list -Verbose'
    Write-Log '(it reads the config, so -Device is only needed to try something else)'
    Write-Log 'then restore with:  trigger-kvm restart'
    exit 0
}

if ($Command -eq 'status') {
    # EVERYTHING IT CAN SAY, whether or not a task is registered. It used to
    # print "not installed" and exit before the config block, which is exactly
    # backwards: the machine that has no task is the one where "what does this
    # think is configured?" is the question being asked.
    $t = Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
    # Declared before the branch: Set-StrictMode makes an unassigned variable
    # terminating, and the no-task path below skips every assignment inside it.
    $fromBoot = $false
    if (-not $t) {
        Write-Host 'autostart: not installed  <- run install.ps1 from the source tree'
        Write-Host '           covers: nothing. No watcher starts on its own.'
    } else {
    $i = Get-ScheduledTaskInfo -TaskName $TASK

    # Say when it runs and what that therefore covers -- never a tier name. The
    # name was the internal label for the distinction and told a reader nothing they
    # could act on; what they want to know is whether a locked or logged-out PC still
    # follows the switch. The raw principal stays on the same line for diagnosis.
    $logon = $t.Principal.LogonType
    # A task with no triggers is the "no autostart" answer; the principal alone
    # cannot tell you that, because it is Interactive either way.
    $auto = @($t.Triggers).Count -gt 0
    $fromBoot = ($auto -and $logon -eq 'S4U')
    Write-Host ("autostart: {0}  (principal={1} logon={2} runlevel={3})" -f `
                $(if (-not $auto) { 'no -- start it with: trigger-kvm restart' }
                  else { switch ($logon) {
                    'S4U'         { 'at boot' }
                    'Interactive' { 'when you log in' }
                    default       { "unknown ($logon)" } } }),
                $t.Principal.UserId, $logon, $t.Principal.RunLevel)

    if (-not $auto) {
        Write-Host '           covers: this session only, until something stops it'
    } else {
    switch ($logon) {
        'Interactive' {
            Write-Host '           covers: from logon onward, including while LOCKED'
            Write-Host '           NOT covered: before the first login after a boot; after a logoff'
            # Say how to get the other tier, rather than only what this one is
            # not. macOS says the same thing at the same moment.
            Write-Host '           to cover the login screen too:  trigger-kvm configure  -> Autostart?'
        }
        'S4U' {
            Write-Host '           covers: from boot onward -- before first login, while locked, after logoff'
        }
        default {
            Write-Host '           <- unrecognised principal; capability unknown'
        }
    }
    }
    Write-Host ("task     : {0}" -f $t.State)

    # 0x800710E0 is "an instance of this task is already running". The 1-minute
    # self-heal trigger produces it on every tick while the watcher is healthy, so
    # it is the expected steady state, not a failure.
    $note = switch ($i.LastTaskResult) {
        0          { '' }
        267009     { '  (running)' }
        2147946720 { '  (self-heal tick found it already running -- expected)' }
        default    { '  <- unexpected' }
    }
    Write-Host ("last run : {0} (result 0x{1:X8}){2}" -f $i.LastRunTime, $i.LastTaskResult, $note)
    }

    # From the LOCK, so this reads the same on both tiers. Counting processes was
    # structurally blind to a session-0 watcher and printed "0  <- expected exactly
    # 1" about a healthy boot tier, which invites fixing a system that works.
    # "More than one" is not a state the lock permits, so this is yes or no.
    Write-Host ("watcher  : {0}" -f $(if (Test-WatcherRunning) { 'running' }
                                      else { 'NOT running  <- run: trigger-kvm restart' }))
    Write-Host ("log      : {0}" -f $LOG)
    Write-Host ("config   : {0}{1}" -f $CONFIG, $(if (Test-Path -LiteralPath $CONFIG) { '' } else { '  <- MISSING; run: trigger-kvm configure' }))

    if (Test-Path -LiteralPath $STAMP) {
        $v = Read-Config -Path $STAMP
        # The spec revision too: with two implementations of one flow, "which
        # revision is this one built to?" is the question that says whether a
        # difference between the two desks is a bug or a version gap.
        Write-Host ("version  : {0}  (installed {1}, commit {2}, spec revision {3})" -f `
                    $v['version'], $v['installed'], $v['commit'],
                    $(if ($v.Contains('spec')) { $v['spec'] } else { 'unrecorded' }))
    } else {
        Write-Host 'version  : unknown  <- installed before version stamping'
    }

    $onPath = @((Get-UserPath) -split ';') -contains $BINDIR
    Write-Host ("path     : {0}" -f $(if ($onPath) { "$BINDIR (on PATH)" } else { "$BINDIR  <- not on PATH; re-run the installer with -AddToPath" }))

    $c = Read-Config -Path $CONFIG
    $labels = @($c.Keys | Where-Object { $_ -match '^display\.([^.]+)\.vendor$' } | ForEach-Object { $Matches[1] } | Sort-Object -Unique)
    $this = $(if ($c.Contains('computer.this')) { "$($c['computer.this'])".Trim().ToLower() } else { '' })
    $computers = @(Get-KnownComputers -Cfg $c)
    Write-Host ("displays : {0}" -f $(if ($labels) { $labels -join ', ' } else { 'none configured' }))
    Write-Host ("computers: {0}" -f $(if ($computers) {
        (@($computers | ForEach-Object { if ($_ -eq $this) { "$_ (this one)" } else { $_ } }) -join ', ') +
        '   (trigger-kvm to <name>; only pull is automatic)'
    } else { 'none' }))
    Get-InputMapReport -Cfg $c -Labels $labels -This $this -Computers $computers |
        ForEach-Object { Write-Host $_ }
    Get-TransportReport -Cfg $c -Labels $labels -FromBoot:$fromBoot |
        ForEach-Object { Write-Host $_ }

    # What is attached RIGHT NOW, through the same door the walkthrough uses, so
    # `status` and `configure` can never disagree about how many panels answer to
    # one id. Enumerating is neither sending a packet nor reading a VCP value, so
    # specs/status.md 1 permits it. Skipped entirely with nothing configured:
    # there is no claim to check, and this is the one line here that costs a
    # child process.
    $attached = @{}
    if ($labels) {
        $sw = Join-Path $PSScriptRoot 'trigger-kvm.ps1'
        if (-not (Test-Path $sw)) { $sw = $SWITCH }
        foreach ($line in (Invoke-Sibling -Script $sw -Arguments @('list', '-Raw', '-Config', $CONFIG) 2>$null)) {
            $row = ConvertFrom-DisplayRow $line
            if ($row) { $attached[('{0:X4}:{1:X4}' -f $row.EdidVendor, $row.EdidProduct)] = $row.Panels }
        }
    }
    Get-DisplayAmbiguityReport -Cfg $c -Labels $labels -Attached $attached |
        ForEach-Object { Write-Host $_ }

    # What the watcher is actually waiting for. Without this line, "it is running"
    # and "it will fire" looked like the same claim.
    #
    # The RAW value goes in. Parsing it here, one normalisation looser than the
    # watcher's, is what used to make this screen call a malformed entry a
    # configured device that was merely somewhere else.
    #
    # Named through the same door the walkthrough uses, so `status` and
    # `discover` can never disagree about what a device is called.
    $entries = @(if ($c.Contains('trigger.device')) { $c['trigger.device'] })
    Get-TriggerReport -Entries $entries -Candidates (Get-TriggerCandidates) |
        ForEach-Object { Write-Host $_ }

    exit $(if ($t) { 0 } else { 1 })
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
                # The child cannot reach this user's PATH -- see Set-InstalledPath.
                if ($rc -eq 0) { Clear-InstalledPath }
                else { Write-Log 'nothing removed -- files left in place so the task keeps working.' }
                exit $rc
            }
            Write-Log "cannot unregister '$TASK' even elevated: $($_.Exception.Message)"
            Write-Log 'nothing removed -- files left in place so the task keeps working.'
            exit 1
        }
    }

    Stop-Watchers
    Remove-LegacyInstall
    if ($FORUSER -eq $ME) { Clear-InstalledPath }

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
    # -AddToPath is deliberately NOT handed over. See Set-InstalledPath.
    # A refusal is not the end of the install: it falls back to the login tier
    # and carries on from here, with the config saying so.
    $EffectiveTier = Invoke-BootTierElevation
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
            $EffectiveTier = Invoke-BootTierElevation
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
foreach ($old in $RENAMED_KEYS.Keys) {
    if ($cfg.Contains($old)) {
        Write-Log ("WARNING: '{0}' is an old key name; rename it to '{1}' in {2}." -f $old, $RENAMED_KEYS[$old], $CONFIG)
        if ($old -eq 'install.tier') {
            Write-Log "         The values changed too: 's4u' is now 'boot', 'user' is now 'login'."
            Write-Log '         This one is still honoured meanwhile, and `trigger-kvm configure`'
            Write-Log '         rewrites the file without it.'
        } elseif ($old -eq 'install.start') {
            Write-Log '         Still honoured meanwhile; `trigger-kvm configure` rewrites it.'
        } else {
            Write-Log '         Until you do, the built-in default is used instead of your value.'
        }
    }
}

# No fallback. A config with no trigger.device is not a config with a default one --
# it is a setup nobody finished, and the task would otherwise be registered to watch
# for something nobody chose.
if (-not $cfg.Contains('trigger.device') -or -not "$($cfg['trigger.device'])".Trim()) {
    Write-Log "no trigger.device in $CONFIG -- nothing to watch for."
    Write-Log 'run:  trigger-kvm configure'
    exit 2
}
# VERBATIM. Stripping whitespace here printed a line that did not appear in the
# file, for a value the watcher was about to refuse -- so install said one thing,
# the config said another, and the watcher would not start on either.
$devices  = "$($cfg['trigger.device'])".Trim()
$debounce = $(if ($cfg.Contains('trigger.debounce')) { $cfg['trigger.debounce'] }                 else { $DEFAULT_DEBOUNCE })
$settle   = $(if ($cfg.Contains('trigger.settle'))   { $cfg['trigger.settle'] }                   else { $DEFAULT_SETTLE })
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

# An earlier layout put the shim in $DEST and therefore $DEST on PATH. The file is
# removed here; the PATH half of it is Set-InstalledPath's, at the end, because
# only a process running as the target user may touch that user's PATH.
if (Test-Path -LiteralPath $OLD_SHIM) {
    Remove-Item -LiteralPath $OLD_SHIM -Force
    Write-Log "removed the old shim from $DEST (it required putting the whole directory on PATH)"
}

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
function Get-ShimLines {
@(
    '@echo off'
    'rem Generated by install.ps1 -- do not edit; re-run the installer instead.'
    'rem The routing below is generated from $VERBS; do not hand-add a verb here.'
    'setlocal'
    'rem Scripts live one level up; only this shim is on PATH.'
    'set "TK_DIR=%~dp0..\"'
    # NO ARGUMENTS PRINTS USAGE; it used to `pull`. That fell out of two defaults
    # meeting -- this line said `goto :switch` and trigger-kvm.ps1's $Command
    # defaults to 'pull' -- rather than out of a decision, and what it produced is
    # a bare command name that MOVES EVERY CONFIGURED MONITOR. That is the single
    # likeliest thing somebody types to find out what a tool does, and hard rule 4
    # is that we never leave a person without a working display. `trigger-kvm pull`
    # is what every doc and config comment already says.
    'if "%~1"=="" goto :usage'
    'if /i "%~1"=="help" goto :help'
    'if /i "%~1"=="--help" goto :help'
    'if /i "%~1"=="-h" goto :help'
    'if "%~1"=="/?" goto :help'
) + @(
    # Generated, so a verb cannot exist in the usage text and not be routed.
    foreach ($v in ($VERBS | Where-Object { $_.Where -eq 'switch' })) {
        'if /i "%~1"=="{0}" goto :switch' -f $v.Verb
    }
    foreach ($v in ($VERBS | Where-Object { $_.Where -eq 'manage' })) {
        'if /i "%~1"=="{0}" goto :manage' -f $v.Verb
    }
) + @(
    'if /i "%~1"=="install" goto :noinstall'
    # ANYTHING ELSE IS OURS TO REPORT. It used to fall through to install.ps1 and
    # die on its ValidateSet, which named the manage verbs only -- omitting pull,
    # to and list, and offering install, which :noinstall refuses.
    'goto :unknown'
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
    # ONE source of usage text, and it is the PowerShell one. Generating the whole
    # help screen as `echo` lines would mean escaping <, > and | for cmd on every
    # line of it, forever -- so the shim asks install.ps1 to print it instead. It
    # costs a process start on a path nobody is timing.
    #
    # help, a bare command and an unknown verb all land on the same target and
    # the same exit code, because macOS's usage() does: every path into it there
    # ends `exit 2`. The unknown-verb case says WHICH verb first, which is the
    # only part that differs, and is what the old PowerShell binding error could
    # not do without naming half the surface wrongly.
    ':unknown'
    'echo trigger-kvm: no such verb "%~1".'
    'echo.'
    ':help'
    ':usage'
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TK_DIR%install.ps1" help'
    'exit /b %ERRORLEVEL%'
)
}

Get-ShimLines | Set-Content -LiteralPath $SHIM -Encoding ASCII

# Version stamp. Records the commit too when the source is a git checkout, which is
# how you tell a released copy from one built off a dirty tree.
$commit = ''
try {
    Push-Location $PSScriptRoot
    $commit = (& git rev-parse --short HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) { $commit = '' }
    if ($commit -and (& git status --porcelain 2>$null)) { $commit += '+dirty' }
} catch { } finally { Pop-Location -ErrorAction SilentlyContinue }

# The specs/ revision this copy was built to. With two implementations of one
# flow, "which revision is this one?" is the question that says whether a
# difference between the two desks is a bug or a version gap -- and the source
# tree it came from may be long gone by the time anyone asks.
$specRev = ''
$revFile = Join-Path $PSScriptRoot 'SPEC-REVISION'
if (Test-Path -LiteralPath $revFile) {
    $m = [regex]::Match((Get-Content -Raw -LiteralPath $revFile), '(?m)^revision\s*=\s*(\d+)')
    if ($m.Success) { $specRev = $m.Groups[1].Value }
}

@(
    "version   = $VERSION"
    "installed = $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    "source    = $PSScriptRoot"
    "commit    = $(if ($commit) { $commit } else { '(not a git checkout)' })"
    "spec      = $(if ($specRev) { $specRev } else { 'unknown' })"
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

# The command the task runs, as one string.
#
# A FUNCTION so the suite can assert what a task will carry without registering
# one -- the same reason Read-MenuKey and Send-Input are functions.
#
# EVERY PATH IS ABSOLUTE AND BAKED IN HERE, at registration, and that includes
# the CONFIG. An at-startup S4U task can run before the user's profile is
# loaded, and Get-ConfigPath reads %LOCALAPPDATA% at run time: unset, or
# pointing at the Default profile, the watcher reads an empty config, throws
# "no trigger.device" into a console-less wscript host, and the 1-minute
# self-heal relaunches it to do the same thing forever. Registration is the
# moment that knows whose install this is; the watcher is not.
#
# This is NOT configuration in the task action -- the settings themselves are
# still read from the file at startup, which is why there is no apply step.
# It is only the ANSWER TO "WHICH FILE", which the watcher cannot derive.
function Get-WatcherCommand {
    param([string]$Watcher, [string]$Switcher, [string]$LogFile, [string]$ConfigFile)

    # powershell.exe -File passes every argument as a literal string, which is
    # why -Device (when given at all) takes one comma-separated value rather
    # than an array.
    return (@(
        'powershell.exe',
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', "`"$Watcher`"",
        '-Exec', "`"$Switcher`"",
        '-Arg', 'pull',
        '-LogFile', "`"$LogFile`"",
        '-Config', "`"$ConfigFile`""
    ) -join ' ')
}

$psCmd = Get-WatcherCommand -Watcher $WATCH -Switcher $SWITCH -LogFile $LOG -ConfigFile $CONFIG

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
if ($EffectiveTier -eq 'manual') {
    # No triggers at all. A task with none is perfectly legal and can still be
    # started on demand, which is what `trigger-kvm restart` does -- so "no" means
    # "nothing starts it but you", including the self-heal below.
    $triggers = @()
    $principal = New-ScheduledTaskPrincipal -UserId $FORUSER `
        -LogonType Interactive -RunLevel Limited
} elseif ($EffectiveTier -eq 's4u') {
    # At startup, so it is running before anyone logs in. S4U means "run as this
    # user without their password": no stored credential (which is rejected
    # outright), and RunLevel Limited means ordinary user rights at run time even
    # though registering it needed admin.
    $triggers = @( (New-ScheduledTaskTrigger -AtStartup) )
    $principal = New-ScheduledTaskPrincipal -UserId $FORUSER `
        -LogonType S4U -RunLevel Limited
} else {
    # Interactive session, normal user rights, and deliberately no admin anywhere.
    # $FORUSER, not this process's own name: the ownership-denial path relaunches
    # elevated even for THIS tier, and on a standard account that is somebody else.
    $triggers = @( (New-ScheduledTaskTrigger -AtLogOn -User $FORUSER) )
    $principal = New-ScheduledTaskPrincipal -UserId $FORUSER `
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
# Not when nothing is meant to start it: a self-heal trigger would quietly make "no"
# mean "yes, every minute".
if ($EffectiveTier -ne 'manual') { $triggers += $heal }

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
    # AND THE WATCHER UNDERNEATH IT, which stopping the task does not touch: it is a
    # grandchild (task -> wscript -> powershell) and outlives its launcher. Left
    # behind it keeps holding the single-instance mutex, so the freshly installed
    # watcher starts, finds the lock held, logs "another watcher is already running"
    # and exits -- and the upgrade silently goes on running the OLD code, which is
    # exactly what Stop-Watchers says it exists to prevent.
    #
    # It was missing here, and it bit: across the install of 2026-08-31 23:53 no
    # watcher armed at all (the log records every arm), and the one from the day
    # before kept running for another 23 hours. See docs/measurements.md.
    #
    # Here rather than earlier because this branch is where a task already exists,
    # which is the only case that can have a live watcher of ours. Elevated on the
    # boot tier -- the install path asks for elevation -- so this can see and kill a
    # watcher in session 0, which pause and restart cannot (TODO.md).
    Stop-Watchers
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
            # No tier is passed. There is no -Tier parameter -- this script's param()
            # is [CmdletBinding()], which THROWS on an unknown named argument, so the
            # child died at parameter binding in a hidden window while the parent
            # reported that nothing had changed. The tier is not the parent's to hand
            # over anyway: the child re-derives it from the config with
            # Get-EffectiveTier, exactly as the other two relaunch sites do.
            $rc = Request-Elevation -ChildArgs @('install')
            if ($rc -eq 0) {
                Set-InstalledPath
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

# -Trigger will not take an empty array, so the manual task is registered without it.
$register = @{ TaskName = $TASK; Action = $action; Principal = $principal; Settings = $settings }
if ($triggers.Count -gt 0) { $register['Trigger'] = $triggers }

# The OLD task was unregistered a few lines up, so a throw HERE leaves no
# autostart at all -- and under $ErrorActionPreference = 'Stop' it left no
# message about it either, just a stack trace after the files had already been
# copied. specs/configure.md 4.4: an interrupted run must leave a working setup
# untouched, and where it cannot, it has to say what is left and how to recover.
try {
    Register-ScheduledTask @register `
        -Description "trigger-kvm: pull the configured monitors to this computer when the shared peripherals arrive." | Out-Null
} catch {
    Write-Log ("could not register the task '{0}': {1}" -f $TASK, $_.Exception.Message)
    Write-Log 'the scripts are installed and the config is intact; what is missing is the autostart entry.'
    Write-Log 'nothing is watching until that is fixed. To try again:'
    Write-Log ("    {0}" -f $PSCommandPath)
    Write-Log 'or start one for this session only:  trigger-kvm restart'
    exit 1
}

# -Pause disables the task; installing again must undo that or the watcher would
# be registered, reported healthy, and never actually start.
Enable-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue | Out-Null
# Persist the tier that was actually installed, so a later bare `install` -- or the
# elevated relaunch -- keeps it instead of silently reverting to the default.
Set-ConfigValue -Path $CONFIG -Key 'install.autostart' `
                -Value $(switch ($EffectiveTier) { 's4u' { 'boot' } 'manual' { 'no' } default { 'login' } })

Start-ScheduledTask -TaskName $TASK
Write-Log ("registered and started task '{0}' ({1})" -f $TASK, `
           $(switch ($EffectiveTier) {
               's4u'    { 'starts at boot' }
               'manual' { 'no autostart' }
               default  { 'starts when you log in' } }))

# DID ONE ACTUALLY COME UP? "Registered and started" is a claim about the task, not
# about the watcher, and the two came apart silently for a whole day: a surviving
# watcher held the lock, the new one exited on it, and this line still said what it
# says above. A registered task with nothing watching is the failure shape that
# looks most like success, so it gets its own sentence.
#
# Not for the manual tier, which has no autostart and is not expected to be running.
if ($EffectiveTier -ne 'manual') {
    Start-Sleep -Seconds 2
    if (Test-WatcherRunning) {
        Write-Log 'a watcher is running.'
    } else {
        Write-Log 'WARNING: the task is registered but NO WATCHER is running.'
        Write-Log 'nothing will switch until one starts. Check:  trigger-kvm logs'
        Write-Log 'then try:  trigger-kvm restart'
    }
}

# Skipped when this process is the elevated child of a standard account: that
# user's PATH is not in this process's HKCU, and the parent does it instead.
if ($FORUSER -eq $ME) { Set-InstalledPath }

# What is left to say is short: it is running, when it will run again, how to see
# that, and the four things you can do to it. Everything else -- tiers, sessions,
# the transport -- is in the docs for the day someone needs it, and is noise on the
# day they do not.
$onPath = @((Get-UserPath) -split ';') -contains $BINDIR
$cmd    = if ($onPath) { 'trigger-kvm' } else { $SHIM }
Write-Host ''
if ($EffectiveTier -eq 'manual') {
    Write-Host '  Done. trigger-kvm is running, but will NOT come back after a restart --'
    Write-Host '  start it yourself with:  trigger-kvm restart'
} else {
    Write-Host ('  Done. trigger-kvm is running, and will start automatically {0}.' -f `
                $(if ($EffectiveTier -eq 's4u') { 'each time the computer reboots' }
                  else { 'each time you log in' }))
}
Write-Host ''
Write-Host '  Flip your switch to this computer -- the monitors should follow.'
Write-Host ''
Write-Host ("    {0} status      is it running?" -f $cmd)
Write-Host ("    {0} pull        bring the displays here now" -f $cmd)
Write-Host ("    {0} logs        what has it been doing" -f $cmd)
Write-Host ("    {0} configure   change any of this" -f $cmd)
Write-Host ''
