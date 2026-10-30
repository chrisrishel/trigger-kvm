# The host: elevation, PATH, the Scheduled Task, the watcher, and every verb
# that is about this computer rather than about a monitor.
#
# WHEN THE WATCHER STARTS IS A PROPERTY OF THE HOST (../AGENTS.md). Nothing in
# trigger-kvm.ps1 or event-watch.ps1 knows or asks when it was started; if
# either ever needs to, the abstraction is wrong.

function Write-Log { param([string]$m) Write-Host "install: $m" }

# Where the sibling scripts are: beside this one in the source tree, in $DEST
# once installed. ONE answer, because a caller that guesses wrong runs a copy
# nobody meant -- and $PSScriptRoot inside lib\ is lib\, not the program
# directory.
function Get-Sibling {
    param([string]$Name)
    $here = Join-Path $TK_HOME $Name
    if (Test-Path -LiteralPath $here -PathType Leaf) { return $here }
    return (Join-Path $DEST $Name)
}

# Run one of the sibling scripts in a CHILD PROCESS, never in this runspace.
#
# trigger-kvm.ps1 and event-watch.ps1 both Add-Type their P/Invoke bindings, and
# .NET cannot replace a type once a runspace has loaded it -- so calling them
# in-process means inheriting whatever version the window happened to load
# earlier. trigger-kvm.ps1 detects that and refuses, correctly, but the refusal
# then lands mid-walkthrough as a stack trace for a reason that has nothing to
# do with the person's monitors. A fresh process has a fresh runspace.
function Invoke-Sibling {
    param([string]$Script, [string[]]$Arguments)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments
}

# The usage text, built from $VERBS so it cannot describe a verb that is not
# routed or miss one that is.
#
# Shaped to match macOS's usage(): same opening line, same verb-then-options
# layout, same closing notes. README.md claims the verbs are the same on both
# platforms, and a person moving between the desks reads both screens.
#
# The switching verbs come first and are separated from the management ones,
# because they are what the tool is FOR.
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
        '  -Only <label>         pull / to / set: one configured display only'
        '  -WhatIf               pull / to / set: resolve and print the packets, send nothing'
        '  -Config <path>        pull / to / list / set: use this config instead of the default'
        '  -Fresh                configure: pre-fill nothing, ask everything again'
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

# --- when it starts -----------------------------------------------------------

# The config is the only source: a flag would be a second way to say something
# the installer already has to read. Resolved once, so every later decision --
# whether to elevate, which principal to register, what status reports -- reads
# the same answer.
#
# One row per spelling the file may hold, newest first. An older spelling still
# counts: ignoring `install.start` would not fall back to a harmless default, it
# would silently DOWNGRADE a working boot-start install to login-only on the
# next install, and the loss would surface months later as "switching does
# nothing at the login screen".
$AUTOSTART_KEYS = @(
    @{ Key = 'install.autostart'; Values = @{ 'boot' = 's4u'; 'login' = 'user'; 'no' = 'manual' } }
    @{ Key = 'install.start';     Values = @{ 'boot' = 's4u'; 'login' = 'user' } }
    @{ Key = 'install.tier';      Values = @{ 's4u'  = 's4u'; 'user'  = 'user' } }
)

# Returns the INTERNAL names ('s4u' / 'user' / 'manual'), which are what the
# Scheduled Task API calls these principals. Nothing a user reads says either
# word.
#
# $CONFIG, not Get-ConfigPath: the elevated child must read the config of the
# user it is installing FOR, and Get-ConfigPath answers for whoever is running.
function Get-EffectiveTier {
    $c = Read-Config -Path $CONFIG
    foreach ($row in $AUTOSTART_KEYS) {
        if (-not $c.Contains($row.Key)) { continue }
        $v = "$($c[$row.Key])".Trim().ToLower()
        if ($row.Values.Contains($v)) { return $row.Values[$v] }
        # NAMED, never quietly defaulted. A value nothing understands is a hand
        # edit or a newer version's, and reading it as login-start without
        # saying so is how a boot tier disappears unexplained.
        Write-Log ("WARNING: {0} = '{1}' in {2} is not a value this understands." -f `
                   $row.Key, $c[$row.Key], $CONFIG)
        Write-Log '         Starting at login instead. Fix it with:  trigger-kvm configure'
        return 'user'
    }
    # Deliberately NOT the walkthrough's default. The walkthrough offers from
    # boot first because it can ask for the UAC prompt and get an answer; a
    # headless or scripted install cannot, so it takes the tier that needs no
    # elevation. Nothing ever elevates without someone choosing it.
    return 'user'
}

# --- elevation ----------------------------------------------------------------

# The child is started by handing a STRING to powershell -Command, so its
# argument list has to survive being written out and parsed again. A user name
# or a profile path may contain a space, and a plain `-join ' '` does not
# survive one.
#
# Measured (docs/measurements.md), because two obvious shapes both look right
# and neither works: an array splat binds every element POSITIONALLY, and an
# unquoted value is read as a second positional argument. So flag names stay
# BARE -- a quoted '-ForUser' is a positional string, not a parameter name --
# and values are quoted.
function Format-ChildArguments {
    param([string[]]$ChildArgs)

    return (@($ChildArgs | ForEach-Object {
        if ($_ -match '^-\w+$') { $_ }
        else { "'" + ($_ -replace "'", "''") + "'" }
    }) -join ' ')
}

# What to hand the elevated child: the verb, everything this process was
# actually given, and who the install is for.
#
# BUILT FROM $PSBoundParameters rather than a literal list, so a new parameter
# is forwarded by existing. Three names are excluded and each for its own
# reason:
#
#   Command      the verb replaces it
#   AddToPath    ONLY A PROCESS RUNNING AS A USER MAY EDIT THAT USER'S PATH.
#                In an elevated child on a standard account, HKCU is the
#                ADMIN's hive, so a child asked to do it would edit the wrong
#                person's PATH and report success. See Set-InstalledPath.
#   Relaunched   added by the caller, on the command line it builds
#
# ForUser and ForAppData are the two facts the parent knows for certain and the
# child cannot work out: `-Verb RunAs` from a standard account elevates a
# DIFFERENT USER, so every path and principal the child derived for itself would
# be that admin's. They are two facts, not one -- a redirected LOCALAPPDATA is
# not derivable from an account name.
function Get-ChildArguments {
    param([string]$Verb, [System.Collections.IDictionary]$Bound)

    $out = @($Verb)
    foreach ($name in @($Bound.Keys)) {
        if ($name -in @('Command', 'AddToPath', 'Relaunched', 'RemoveTaskOnly', 'ForUser', 'ForAppData')) { continue }
        $v = $Bound[$name]
        if ($v -is [System.Management.Automation.SwitchParameter]) {
            if ($v.IsPresent) { $out += "-$name" }
        } else {
            $out += @("-$name", [string]$v)
        }
    }
    return @($out + @('-ForUser', $FORUSER, '-ForAppData', $APPDATA))
}

# Re-run this script elevated, wait for it, and print what it did.
#
# Worth doing rather than telling the user to open an admin terminal: the s4u
# tier CANNOT be registered without elevation, so the alternative is a dead end
# mid-install -- and the admin-owned task it leaves behind means UNINSTALL needs
# elevation too, so a prompt on the way in without one on the way out would trap
# people in a tier they cannot remove.
#
# The child writes to a temp file and the parent prints it, because -Verb RunAs
# cannot be combined with -RedirectStandardOutput: without this the output lands
# in a window that closes before it can be read.
# Run one elevated child and wait. $null means NO CHILD RAN -- the prompt was
# declined, or the account had no credentials to give -- and that is the only
# thing that means "elevation could not be obtained". Anything else is an exit
# code from a child that did run, and belongs to the install it attempted, not
# to the prompt.
#
# Its own function because that distinction is the whole point and a `try` around
# a `Start-Process` cannot be stubbed; here a test can answer either way.
function Start-ElevatedChild {
    param([string]$Command)
    try {
        $p = Start-Process powershell.exe -Verb RunAs -Wait -WindowStyle Hidden -PassThru `
             -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $Command)
    } catch {
        return $null
    }
    return $p.ExitCode
}

function Request-Elevation {
    param([string]$Verb, [switch]$TaskRemovalOnly)

    # DID A CHILD ACTUALLY RUN? The exit code alone cannot say: 1 is both "the
    # prompt was declined" and "the elevated install ran and failed". Callers
    # need the difference, because only the first is the fallback specs/
    # configure.md 8 describes.
    $script:ELEVATION_REACHED = $false

    $childArgs = Get-ChildArguments -Verb $Verb -Bound $INVOKED_WITH
    if ($TaskRemovalOnly) { $childArgs += '-RemoveTaskOnly' }

    if ($Relaunched) {
        # We already asked and came back still unelevated. Something is refusing
        # (policy, or no admin rights available). Do not prompt again -- an
        # elevation loop is far worse than a clear failure.
        Write-Log 'still not elevated after relaunching; not asking again.'
        return 1
    }
    if ($NoElevate) {
        Write-Log 'elevation required, and -NoElevate was given.'
        Write-Host ''
        # Quoted, because this line is meant to be pasted and a profile path
        # with a space would not survive being retyped bare either.
        Write-Host ("Run this from an elevated PowerShell:  & '{0}' {1}" -f $TK_SELF.Replace("'", "''"), (Format-ChildArguments $childArgs))
        if ($TaskRemovalOnly) { Write-Log 'then rerun the installer from your normal, unelevated shell to register the replacement.' }
        return 1
    }

    $transcript = Join-Path ([IO.Path]::GetTempPath()) ("trigger-kvm-elevated-{0}.log" -f [Guid]::NewGuid().ToString('N').Substring(0,8))

    # THE CATCH IS INSIDE THE REDIRECTION, and the child's own exit code comes
    # back out. `& '<script>' <args> *> '<file>'` looks like it captures
    # everything and does not: a terminating error propagates OUT of the
    # redirected command and is reported after the redirection has ended, so the
    # transcript holds only what was printed before the failure -- in a hidden
    # elevated window, that error text is simply lost, and the caller then says
    # "what it reported is above" about nothing. The same shape also flattens
    # every outcome to 1: a child that exited 7 came back as 1 (measured).
    #
    # Braces are doubled for -f, which would otherwise read them as placeholders.
    $inner = ("& {{ try {{ & '{0}' {1} -Relaunched; `$global:tkRc = `$LASTEXITCODE }} " +
              "catch {{ `$_ | Out-String | Write-Output; `$global:tkRc = 1 }} }} *> '{2}'; " +
              "exit `$global:tkRc") -f $TK_SELF.Replace("'", "''"), (Format-ChildArguments $childArgs), $transcript.Replace("'", "''")

    Write-Log 'this needs administrator rights; approving the UAC prompt will continue.'
    $rc = Start-ElevatedChild -Command $inner
    if ($null -eq $rc) {
        # The user declined the prompt, or no admin credentials were available.
        # What happens NEXT is the caller's to say -- an uninstall stops here, an
        # install falls back to the login tier -- so this line does not claim
        # that nothing was changed.
        Write-Log 'elevation was declined or unavailable.'
        return 1
    }

    $script:ELEVATION_REACHED = $true
    if (Test-Path -LiteralPath $transcript) {
        Get-Content -LiteralPath $transcript | ForEach-Object { Write-Host $_ }
        Remove-Item -LiteralPath $transcript -Force -ErrorAction SilentlyContinue
    }
    return $rc
}

# The boot tier needs administrator rights ONCE, to register the task. Ask; if
# they do not come, say so and install the tier that needs none.
#
# specs/configure.md 8: where elevation cannot be obtained the boot tier FALLS
# BACK TO LOGIN and SAYS SO. Silently keeping `boot` is how someone finds out
# months later that switching does nothing until they log in.
#
# It does not RECORD the fallback. "Record the fallback only once it has taken
# effect", and nothing has taken effect here -- this decides which tier to
# attempt, and the install that applies it can still fail at registration. The
# write belongs to whichever line proves the tier exists, which is the one after
# Register-ScheduledTask returns, in Invoke-Install.
#
# Returns the tier to install. Exits when the elevated child did the whole
# install itself, which is the successful case.
function Invoke-BootTierElevation {
    $rc = Request-Elevation -Verb 'install'
    if ($rc -eq 0) {
        # The PATH is the one thing the child could not do: on a standard
        # account its HKCU is the ADMIN's hive. See Set-InstalledPath.
        Set-InstalledPath
        exit 0
    }
    # THE PROMPT WAS APPROVED AND THE INSTALL FAILED ANYWAY. That is not the
    # fallback: elevation was obtained. Carrying on would install a DIFFERENT
    # tier, unelevated, on top of whatever the elevated run left -- a second
    # install nobody asked for, whose own failure the person then reads as the
    # first one. The child has already said what went wrong, just above.
    if ($ELEVATION_REACHED) {
        Write-Log 'the elevated install did not finish; what it reported is above.'
        Write-Log 'the login tier was NOT installed instead -- nothing else was changed.'
        Write-Log 'fix what it reported and run this again.'
        exit $rc
    }
    Write-Log 'falling back to starting at login.'
    Write-Log 'the switch will follow from your logon onward, but not at the login screen.'
    Write-Log 'to try again for the boot tier:  trigger-kvm configure'
    return 'user'
}

# Materialize claims before disposing the native identity/token handle.
function Get-CurrentTokenClaims {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { return @($identity.Claims) }
    finally { $identity.Dispose() }
}

# Boot-menu eligibility includes split-token administrators and standard users
# allowed to supply a separate administrator credential. Claims retain deny-only
# membership; the read-only UAC policy check identifies explicit standard-user
# denials. Unknown policy/query results leave the prompt available. Windows
# decides whether elevation succeeds; see docs/measurements.md.
function Test-CanElevate {
    if ($IsElevated) { return $true }
    try {
        foreach ($claim in @(Get-CurrentTokenClaims)) {
            if ($claim.Type -in @([Security.Claims.ClaimTypes]::GroupSid,
                                 [Security.Claims.ClaimTypes]::DenyOnlySid) -and
                $claim.Value -eq 'S-1-5-32-544') { return $true }
        }
        $policy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
            -Name EnableLUA,ConsentPromptBehaviorUser -ErrorAction Stop
        return ($policy.EnableLUA -ne 0 -and $policy.ConsentPromptBehaviorUser -ne 0)
    } catch { return $true }
}

# --- PATH ---------------------------------------------------------------------

# USER PATH ONLY, never the machine one: this installs per-user and needs no
# admin, and quietly editing a system-wide setting would be a much bigger thing
# than the user agreed to.
#
# READ AND WRITTEN THROUGH THE REGISTRY, NOT THROUGH [Environment]. Measured:
# SetEnvironmentVariable(...,'User') writes REG_SZ whatever it is given, and
# GetEnvironmentVariable(...,'User') EXPANDS %VAR% references, because that is
# what reading a REG_EXPAND_SZ value means. Between them, answering yes to the
# PATH question read every %USERPROFILE%-style entry as a literal path and wrote
# it back that way, with the value's kind downgraded so nothing there would ever
# follow its variable again. A fresh Windows profile's Path is REG_EXPAND_SZ.
#
# -KeyPath so the suite can point this at a throwaway key of its own: the real
# PATH is the developer's own working setup.
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

# Tell everyone the environment changed. A registry write notifies nobody, and
# Explorer -- so every terminal started from it -- re-reads the environment on
# WM_SETTINGCHANGE. Without this, "open a NEW terminal for that to take effect"
# stops being true and the answer becomes "log out".
#
# Guarded by NAME only, with no source stamp, unlike the transports in
# trigger-kvm.ps1 and event-watch.ps1: this declares one Win32 entry point whose
# signature has been fixed since 1995 and carries no logic to be stale.
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

# Both verbs are the PARENT's, because the rule is about WHO may edit a PATH,
# not about which way the edit goes -- see Get-ChildArguments.
#
# ONLY $BINDIR goes on PATH, and it holds only the shim: putting $DEST there
# publishes every file in it as a command, because PATHEXT includes .VBS, so
# `launcher.vbs` resolves as a bare `launcher` that starts the watcher.
function Set-InstalledPath {
    Remove-FromUserPath -Dir $DEST      # an earlier layout put this one on PATH
    if ($AddToPath) { Add-ToUserPath -Dir $BINDIR }
}

function Clear-InstalledPath {
    Remove-FromUserPath -Dir $BINDIR
    Remove-FromUserPath -Dir $DEST
}

# --- the config file, one key at a time ---------------------------------------

# Update ONE key in place, preserving comments, order and every other line.
# Rewriting the whole file from a hashtable would silently destroy the comments,
# which are most of the file; a config you cannot safely round-trip is one
# people stop hand-editing.
function Set-ConfigValue {
    param([string]$Path, [string]$Key, [string]$Value)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $hit = $false
    $out = foreach ($l in $lines) {
        if ($l -match $pattern) { $hit = $true; ('{0} = {1}' -f $Key, $Value) } else { $l }
    }
    if (-not $hit) { $out = @($out) + @('', ('{0} = {1}' -f $Key, $Value)) }
    $out | Set-Content -LiteralPath $Path -Encoding UTF8
}

# --- the watcher --------------------------------------------------------------

# Stopping the task kills its launcher but NOT the powershell watcher
# underneath, which is a grandchild and outlives it. Left behind, a stale
# watcher keeps holding the single-instance mutex and the newly installed one
# exits immediately -- so an upgrade silently goes on running the old code.
#
# Only the target user's scripts in THIS installation belong to us. A script
# name anywhere else in a command line is neither an identity nor ownership.
function Stop-Watchers {
    $procs = Get-CimInstance Win32_Process -Property ProcessId,Name,CommandLine -Verbose:$false
    foreach ($p in $procs) {
        if (-not $p.CommandLine -or $p.Name -notin @('powershell.exe','wscript.exe')) { continue }
        $scriptPath = ''
        if ($p.Name -eq 'powershell.exe') {
            # Recognize only our -File launch grammar (Get-WatcherCommand),
            # with optional generated flags in their generated order. Unknown
            # options, command modes and implicit scripts are not ours to stop.
            # Anchor whole tokens: do not turn quoted fragments into a path.
            $prefix = '(?:-NoProfile\s+)?(?:-ExecutionPolicy\s+Bypass\s+)?(?:-WindowStyle\s+Hidden\s+)?'
            $invocation = '^\s*(?:"[^"]+"|[^\s"]+)\s+' + $prefix +
                '-File\s+(?:"(?<quoted>[^"]+)"|(?<bare>[^\s"]+))(?=\s|$)'
            if ($p.CommandLine -notmatch $invocation) { continue }
            $scriptPath = if ($Matches['quoted']) { $Matches['quoted'] } else { $Matches['bare'] }
            if ($scriptPath -notin @($WATCH, (Join-Path $DEST 'usb-watch.ps1'))) { continue }
        } else {
            $words = @([regex]::Matches($p.CommandLine, '"[^"]*"|[^\s"]+') | ForEach-Object { $_.Value.Trim('"') })
            $scriptPath = @($words | Select-Object -Skip 1 | Where-Object { $_ -notlike '//*' }) | Select-Object -First 1
            if ($scriptPath -ne $VBS) { continue }
        }
        try { $owner = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop }
        catch { continue } # An unreadable owner is not permission to stop it.
        if ($owner.ReturnValue -ne 0 -or ('{0}\{1}' -f $owner.Domain, $owner.User) -ne $FORUSER) { continue }
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Log ("stopped stale {0} (pid {1})" -f $p.Name, $p.ProcessId)
    }
}

# STAND THE INSTALLED WATCHER DOWN, and SAY WHETHER IT WORKED. One definition,
# because `pause`, `restart` and the trigger check all mean the same thing by it.
#
# Stopping the task is NOT enough, twice over: the watcher is a grandchild and
# survives it, and the 1-minute self-heal trigger would start it again within
# the minute. The task has to be DISABLED, not merely stopped.
#
# THE LOCK IS THE AUTHORITY, never the three calls below. On the boot tier from
# an unelevated caller ALL THREE fail silently, measured 2026-09-08: the task
# stayed Enabled, Stop-Watchers matched nothing because
# Win32_Process.CommandLine reads empty across the session boundary, and even
# Stop-Process on the watcher was Access denied. `pause` said "task disabled and
# watcher stopped" and exit 0 while the watcher it named went on running.
#
# The wait is bounded and only runs while the lock is still held: Stop-Process
# returns before the process has finished exiting, and a lock check that raced
# it would report failure on the login tier, where standing it down does work.
function Suspend-Watcher {
    Disable-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue | Out-Null
    Stop-ScheduledTask    -TaskName $TASK -ErrorAction SilentlyContinue
    Stop-Watchers

    for ($i = 0; $i -lt 5; $i++) {
        if (-not (Test-WatcherRunning)) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

# Why standing it down failed, in the person's terms. Asked only after it HAS
# failed, so the answer explains something observed rather than predicting it.
function Get-SuspendFailure {
    if ((Get-WatcherPauseMode) -eq 'needs-admin') {
        return @(
            'the boot tier registers its task as an administrator, so disabling it and'
            'stopping the watcher both need one -- and neither failure is visible from'
            'here, which is why this asks the lock instead of trusting a return code.'
            'To stand it down: run the same command from an elevated PowerShell.'
        )
    }
    return @('nothing here could stop it. Check:  trigger-kvm logs')
}

function Get-WatcherState {
    $t = Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
    return [PSCustomObject]@{
        Installed = [bool]$t
        Enabled = [bool]($t -and $t.Settings.Enabled)
        Running = [bool](Test-WatcherRunning)
    }
}

function Resume-Watcher {
    param($Prior = $null)
    # restart intentionally enables and starts. A temporary check restores the
    # snapshot instead, including after a partially successful suspension.
    if ($null -ne $Prior) {
        if (-not $Prior.Installed) { return }
        $start = $Prior.Running -and -not (Test-WatcherRunning)
        if ($Prior.Enabled -or $start) {
            Enable-ScheduledTask -TaskName $TASK -ErrorAction Stop | Out-Null
        }
        try {
            if ($start) { Start-ScheduledTask -TaskName $TASK -ErrorAction Stop }
        } finally {
            if (-not $Prior.Enabled) { Disable-ScheduledTask -TaskName $TASK -ErrorAction Stop | Out-Null }
        }
        return
    }
    Enable-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue | Out-Null
    Start-ScheduledTask  -TaskName $TASK -ErrorAction SilentlyContinue
}

# Can the installed watcher be stood down here, without a password?
#
#   'none'        nothing is installed, so there is nothing to stand down
#   'can'         it is ours to disable
#   'needs-admin' it is not: the task DEFINITION under System32\Tasks is owned
#                 by whoever registered it, and the boot tier requires an
#                 administrator. Disabling it would prompt, and
#                 specs/configure.md 11 says a check must not ask for a
#                 password -- it says the watcher will fire and lets the person
#                 read that before they flip.
#
# Asked of the INSTALLED task rather than of the config: the walkthrough may
# have changed the answer in memory and not saved it, and what matters here is
# what is running.
function Get-WatcherPauseMode {
    $t = Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
    if (-not $t) { return 'none' }
    if ($t.Principal.LogonType -eq 'S4U' -and -not $IsElevated) { return 'needs-admin' }
    return 'can'
}

# IS A WATCHER RUNNING? Asked of event-watch.ps1, which owns the
# single-instance lock -- specs/status.md 2. An unelevated caller cannot read
# CommandLine across the session boundary, so counting processes is
# structurally blind to a session-0 watcher; the lock is what MAKES a second
# watcher impossible, so it is the authority on both halves of the question.
#
# NOT the question Stop-Watchers asks. That one needs PIDs to kill and runs
# elevated; this one needs a yes/no from wherever it is called.
function Test-WatcherRunning {
    $ew = Get-Sibling 'event-watch.ps1'
    if (-not (Test-Path -LiteralPath $ew -PathType Leaf)) { return $false }
    Invoke-Sibling -Script $ew -Arguments @('-IsRunning') | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# --- what status reports ------------------------------------------------------

# THE INPUT MAP, AND THE FACT THAT NOTHING CAN CHECK IT -- specs/status.md 3.
#
# The map is an assertion about which physical socket each computer's cable is
# in. If a cable moves to a different input ON THE MONITOR, a panel whose EDID
# product id is stable across its inputs still resolves perfectly, so `pull`
# sends the old value and the panel switches to an input with nothing on it:
# black screen, silently, with a success in the log.
#
# Detection is BARRED, not merely unimplemented (../AGENTS.md hard rules 2 and
# 3; ../ideas/knowing-which-input-you-are-on.md). So the only move left is
# making the failure legible and cheap to recover.
#
# Returns lines rather than printing them, so the suite can reach the decision
# without a status run.
function Get-InputMapReport {
    param($Cfg, [string[]]$Labels, [string]$This, [string[]]$Computers)

    if (-not $Labels) { return @('inputs   : none configured') }

    $out = @('inputs   : (which computer is on which input of each monitor)')
    foreach ($label in $Labels) {
        # In the order the computers were listed, NOT by input value
        # (specs/config-format.md, "Ordering"), so this block and the
        # `computers` line agree.
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
    # specs/status.md 3.1. The warning is the point of the block; the map above
    # it is only what the warning is about.
    $out += '           ^ asserted, never verified. If a cable moved to another input on'
    $out += '             the monitor, pull switches that panel to a dead input and it goes'
    $out += '             black, with a success in the log. Fix: trigger-kvm configure'
    return $out
}

# The configured triggers, named wherever this computer can currently see them
# -- specs/status.md 4.1.
#
# A trigger that is NOT here is the ordinary case, not a fault: the peripherals
# are on the other computer, which is exactly when somebody runs `status` to ask
# why nothing switched. So the absence is stated plainly and the footnote says
# it is normal, rather than leaving a blank that reads as broken.
#
# TAKES THE RAW CONFIG VALUE and parses it through the one parser every consumer
# uses. A caller pre-normalising it is what let `status` disagree with the
# watcher about the same line of the same file.
#
# HOW THE SAVED ENTRIES RESOLVE NOW -- specs/status.md 4.1. Asked
# of event-watch.ps1 through -Report, never re-derived here: a second
# implementation of detector.md 4.1 would be free to disagree with the one that
# decides whether a monitor moves, and this screen is where somebody looks when
# it did not.
#
# Returns a map of the entry AS WRITTEN to its verdict, so a caller matches on
# the string in the file rather than on a canonicalisation of it. Empty when
# there is nothing to ask about or no watcher script to ask.
function Get-TriggerVerdicts {
    param([string[]]$Entries)

    $out = @{}
    if (-not $Entries) { return $out }
    $ew = Get-Sibling 'event-watch.ps1'
    if (-not (Test-Path -LiteralPath $ew -PathType Leaf)) { return $out }
    # A malformed entry must not prevent the valid entries being resolved.
    $valid = @(ConvertFrom-TriggerDevices $Entries | Where-Object { $_.Ok } | ForEach-Object { $_.Raw })
    if (-not $valid.Count) { return $out }
    foreach ($line in (Invoke-Sibling -Script $ew -Arguments @('-Report', '-Device', ($valid -join ',')) 2>$null)) {
        $f = "$line" -split '\|', 2
        if ($f.Count -eq 2) { $out[$f[0]] = $f[1] }
    }
    return $out
}

# [CmdletBinding()] so a caller left on an old parameter name THROWS rather than
# reporting "none configured" for a perfectly good config.
function Get-TriggerReport {
    [CmdletBinding()]
    param([string[]]$Entries, $Candidates, [hashtable]$Verdicts = @{})

    $devs = @(ConvertFrom-TriggerDevices $Entries)
    $out = @('triggers : current saved configuration, resolved against devices attached now',
             '           trigger edits require: trigger-kvm restart',
             '           the running watcher may still hold an older configuration')
    if ($devs.Count -eq 0) { return @($out + '           none configured in the saved configuration') }

    $by = @{}
    foreach ($c in @($Candidates)) { if ($c) { $by[$c.Key] = $c } }

    $missing   = 0
    $bad       = 0
    $ambiguous = 0
    for ($i = 0; $i -lt $devs.Count; $i++) {
        $label = '          '
        $d = $devs[$i]
        # Malformed FIRST, and it is not a kind of missing: counted as missing
        # it would draw the "normal when the switch is on the other computer"
        # note, which is the tool reassuring somebody about the exact entry
        # stopping the watcher from starting.
        if (-not $d.Ok) {
            $name = 'MALFORMED -- the watcher will refuse to start on this'
            $bad++
        }
        elseif ($by.Contains($d.Identity)) { $name = Get-CandidateLabel $by[$d.Identity] }
        else { $name = '-- no device name available' }
        # AS WRITTEN, never canonicalised: this is the string to go looking for
        # in the config file.
        $out += ('{0} {1,-20} {2}' -f $label, $d.Raw, $name)

        # Discovery supplies names only. Presence (including Bluetooth
        # connected versus paired) comes exclusively from the watcher resolver.
        if ($d.Ok) {
            $verdict = if ($Verdicts.Contains($d.Raw)) { $Verdicts[$d.Raw] } else { 'unavailable' }
            $said = switch ($verdict) {
                'where'     { "the device at '$($d.Spot)' is the one this matches -- re-run configure if you have moved them" }
                'ambiguous' { 'AMBIGUOUS -- more than one device answers to this and none is at the remembered spot, so it will NOT fire' }
                'present'   { if ($d.Token) { "present, matched by '$($d.Token)'" } else { 'present' } }
                'absent'    { 'absent -- not attached or not connected right now' }
                default    { 'resolution unavailable -- the watcher could not report this entry' }
            }
            if ($said) { $out += ('           ^ {0}' -f $said) }
            if ($verdict -eq 'ambiguous') { $ambiguous++ }
            if ($verdict -eq 'absent') { $missing++ }
        }
    }
    # NAMED, not pointed at with a `^`: the absent-device note below owns that
    # arrow, and when both fire two arrows point up at different rows.
    if ($bad -gt 0) {
        $out += '           a MALFORMED line is not a device: the watcher will not start'
        $out += '           until it is fixed or removed.  Fix:  trigger-kvm configure'
    }
    if ($missing -gt 0) {
        $out += '           ^ normal when the switch is on the other computer: that is'
        $out += '             what these devices arriving here is going to mean.'
    }
    # Not the same fact as "absent", and not the same remedy: unplug one, or
    # re-run configure so a different device is named.
    if ($ambiguous -gt 0) {
        $out += '           an AMBIGUOUS entry is disabled, not absent. Every other trigger'
        $out += '           still works.  Fix:  trigger-kvm configure'
    }
    return $out
}

# How the switch reaches each panel, and where that takes away coverage the
# autostart line has already promised -- specs/status.md 4.
#
# The tier statement is about the TIER, and a transport can make it untrue for
# ONE panel while it stays true for the others: a machine installed from boot
# correctly reports that it covers the login screen and still has a monitor that
# will not move until somebody logs in.
function Get-TransportReport {
    param($Cfg, [string[]]$Labels, [switch]$FromBoot)

    if (-not $Labels) { return @() }

    $rows     = @()
    $stranded = @()
    foreach ($label in $Labels) {
        $k = "display.$label.transport"
        # Absent means nvapi, so a config written before the key existed reads
        # as the transport it has always used rather than as unanswered.
        $t = $(if ($Cfg.Contains($k)) { "$($Cfg[$k])".Trim().ToLower() } else { 'nvapi' })
        $row = @($TRANSPORTS | Where-Object { $_.Name -eq $t }) | Select-Object -First 1
        # Named, not corrected. The switcher refuses an unrecognised transport
        # by name rather than defaulting, so status says the same thing instead
        # of quietly reporting a working panel.
        $note = $(if ($row) { $row.Note } else { 'UNRECOGNISED -- the switch will refuse this panel' })
        $rows += ("           {0,-8} {1,-6} ({2})" -f $label, $t, $note)
        if ($DESKTOP_TRANSPORTS -contains $t) { $stranded += $label }
    }

    $out = @('reaches  : (how the switch reaches each monitor)') + $rows
    if ($FromBoot -and $stranded.Count -gt 0) {
        $out += '           ^ the autostart line above says it covers the login screen.'
        $out += ("             It does not for {0}: nothing moves that panel until" -f (Join-Names $stranded))
        $out += '             a local console session is available; Remote Desktop is not enough.'
    }
    return $out
}

# specs/status.md 5. SILENT unless it has something to say: an id in the config
# that right now answers for more than one attached panel.
#
# By the time anyone reads `status` the switch has already refused that panel,
# and the refusal only ever reached the log -- which is not where a person looks
# when a monitor they have had for a year quietly stops following.
#
# $Attached maps 'VVVV:PPPP' to how many attached panels answer to it. A
# configured id that is merely ABSENT is a different state with a different
# remedy and is deliberately not reported here (specs/status.md 5.2).
function Get-DisplayAmbiguityReport {
    param($Cfg, [string[]]$Labels, [hashtable]$Attached)

    if (-not $Labels -or $null -eq $Attached -or $Attached.Count -eq 0) { return @() }

    $rows = @()
    foreach ($label in $Labels) {
        $v = ConvertTo-Word $Cfg["display.$label.vendor"]
        $p = ConvertTo-Word $Cfg["display.$label.product"]
        # An unparseable id matches nothing rather than matching 0x0000 -- the
        # same refusal the switcher makes, for the same reason.
        if ($null -eq $v -or $null -eq $p) { continue }
        $key = '{0:X4}:{1:X4}' -f $v, $p
        # The Contains check is redundant today -- a missing key reads as $null
        # and $null -le 1 is already true -- and is kept because "a missing
        # value is not zero" is the rule this project follows everywhere else.
        if (-not $Attached.Contains($key)) { continue }
        if ($Attached[$key] -le 1) { continue }
        $rows += ("           {0,-8} 0x{1:X4}:0x{2:X4}  {3} of them" -f $label, $v, $p, $Attached[$key])
    }
    if ($rows.Count -eq 0) { return @() }

    # No "run configure" here, deliberately: it cannot fix this, and saying so
    # would be offering a fix this tool does not have (specs/status.md 5.2).
    return @('AMBIGUOUS: more than one attached monitor matches an id in this config') + $rows +
           @('           the switch refuses rather than guessing, so those panels do not',
             '           follow. Unplug one of each pair -- nothing here can tell them apart.')
}

# --- the management verbs -----------------------------------------------------

# EVERYTHING IT CAN SAY, whether or not a task is registered -- specs/status.md
# 1. The machine with no task is exactly where "what does this think is
# configured?" is the question being asked, so nothing exits early on that.
function Invoke-Status {
    $t = Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
    # Declared before the branch: Set-StrictMode makes an unassigned variable
    # terminating, and the no-task path skips every assignment inside it.
    $fromBoot = $false
    if (-not $t) {
        Write-Host 'autostart: not installed  <- run install.ps1 from the source tree'
        Write-Host '           covers: nothing. No watcher starts on its own.'
    } else {
        $i = Get-ScheduledTaskInfo -TaskName $TASK

        # Say when it runs and what that therefore covers -- never a tier name.
        # What a reader wants to know is whether a locked or logged-out PC still
        # follows the switch. The raw principal stays on the line for diagnosis.
        $logon = $t.Principal.LogonType
        # A task with no triggers is the "no autostart" answer; the principal
        # alone cannot tell you that, because it is Interactive either way.
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

        # 0x800710E0 is "an instance of this task is already running". The
        # 1-minute self-heal trigger produces it on every tick while the watcher
        # is healthy, so it is the expected steady state, not a failure.
        $note = switch ($i.LastTaskResult) {
            0          { '' }
            267009     { '  (running)' }
            2147946720 { '  (self-heal tick found it already running -- expected)' }
            default    { '  <- unexpected' }
        }
        Write-Host ("last run : {0} (result 0x{1:X8}){2}" -f $i.LastRunTime, $i.LastTaskResult, $note)
    }

    # From the LOCK, so this reads the same on both tiers, and "more than one"
    # is not a state the lock permits.
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
    Write-Host ("path     : {0}" -f $(if ($onPath) { "$BINDIR (on PATH)" }
                                      else { "$BINDIR  <- not on PATH; run: trigger-kvm configure  -> Add to PATH?" }))

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
    # `status` and `configure` cannot disagree about how many panels answer to
    # one id. Enumerating is neither sending a packet nor reading a VCP value,
    # so specs/status.md 1 permits it. Skipped entirely with nothing configured.
    $attached = @{}
    if ($labels) {
        foreach ($line in (Invoke-Sibling -Script (Get-Sibling 'trigger-kvm.ps1') `
                                          -Arguments @('list', '-Raw', '-Config', $CONFIG) 2>$null)) {
            $row = ConvertFrom-DisplayRow $line
            if ($row) { $attached[('{0:X4}:{1:X4}' -f $row.EdidVendor, $row.EdidProduct)] = $row.Panels }
        }
    }
    Get-DisplayAmbiguityReport -Cfg $c -Labels $labels -Attached $attached |
        ForEach-Object { Write-Host $_ }

    # What the watcher is actually waiting for. Without this line, "it is
    # running" and "it will fire" looked like the same claim. The RAW value goes
    # in; named through the same door `discover` uses.
    $entries = @(if ($c.Contains('trigger.device')) { $c['trigger.device'] })
    Get-TriggerReport -Entries $entries -Candidates (Get-TriggerCandidates) `
                      -Verdicts (Get-TriggerVerdicts -Entries $entries) |
        ForEach-Object { Write-Host $_ }

    return $(if ($t) { 0 } else { 1 })
}

# For a hand-edited config. The watcher reads its settings at startup, so
# bouncing it is the whole of "make my edit take effect" -- no re-registration,
# because the task action carries no configuration.
function Invoke-Restart {
    $down = Suspend-Watcher
    Resume-Watcher
    Start-Sleep -Seconds 2
    # The lock, not a process count: a boot-tier watcher comes up in session 0,
    # where an unelevated caller cannot read CommandLine.
    $up = Test-WatcherRunning

    # A LOCK THAT WAS NEVER RELEASED CANNOT SAY A WATCHER RESTARTED. It is held
    # by the one we failed to stop, and the one Resume started found it held and
    # exited -- so "restarted" would name a process that has been running since
    # before the command was typed, still holding the configuration it started
    # with. Measured 2026-09-08: it claimed a hand edit had taken effect against
    # a watcher armed three days earlier.
    if (-not $down) {
        Write-Log 'NOT restarted: the running watcher could not be stood down, so it is'
        Write-Log 'still running the configuration it started with, and a hand edit has'
        Write-Log 'NOT taken effect.'
        Get-SuspendFailure | ForEach-Object { Write-Log $_ }
        return 1
    }
    if ($up) { Write-Log 'restarted; the watcher has re-read the config.'; return 0 }
    Write-Log 'restarted, but no watcher came up -- check: trigger-kvm logs'
    return 1
}

function Invoke-Pause {
    if ((Get-WatcherPauseMode) -eq 'none') {
        Write-Log 'nothing is installed here, so there is no watcher to stand down.'
        return 1
    }
    if (-not (Suspend-Watcher)) {
        # SAID, not implied. The whole point of `pause` is running one by hand,
        # and a second watcher against the same devices is the case the lock
        # exists to prevent -- so being told it paused when it did not sends
        # somebody straight into it.
        Write-Log 'COULD NOT PAUSE: a watcher is still running.'
        Get-SuspendFailure | ForEach-Object { Write-Log $_ }
        return 1
    }
    Write-Log 'paused: the task is disabled and no watcher is running'
    Write-Log 'run one by hand now, e.g.:'
    Write-Log '    .\event-watch.ps1 -Exec .\trigger-kvm.ps1 -Arg list -Verbose'
    Write-Log '(it reads the config, so -Device is only needed to try something else)'
    Write-Log 'then restore with:  trigger-kvm restart'
    return 0
}

function Invoke-Logs {
    if (-not (Test-Path -LiteralPath $LOG)) { Write-Host "no log yet at $LOG"; return 1 }
    Get-Content -LiteralPath $LOG -Tail 50 -Wait
    return 0
}

# Remove the program, keeping the config and the log: both live outside $DEST
# because the log is the only record of what happened and a config can
# represent real work.
function Invoke-Uninstall {
    if (Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
        try {
            Unregister-ScheduledTask -TaskName $TASK -Confirm:$false -ErrorAction Stop
            Write-Log "unregistered task '$TASK'"
        } catch {
            # The ownership trap, and the more important half of it: removing
            # the FILES while leaving the task registered would leave a task
            # pointing at scripts that are gone, failing silently at every
            # logon. So elevate, or stop.
            if (-not $IsElevated) {
                Write-Log "'$TASK' was registered by an elevated process."
                $rc = Request-Elevation -Verb 'uninstall'
                # The child cannot reach this user's PATH -- see Set-InstalledPath.
                if ($rc -eq 0) { Clear-InstalledPath }
                else { Write-Log 'nothing removed -- files left in place so the task keeps working.' }
                return $rc
            }
            Write-Log "cannot unregister '$TASK' even elevated: $($_.Exception.Message)"
            Write-Log 'nothing removed -- files left in place so the task keeps working.'
            return 1
        }
    }

    Stop-Watchers
    if ($FORUSER -eq $ME) { Clear-InstalledPath }

    foreach ($f in @($WATCH, $SWITCHER, $VBS, $SHIM, $STAMP, $CFGLIB) + $EARLIER_LAYOUT) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force; Write-Log "removed $f" }
    }
    if (Test-Path -LiteralPath $LIBDIR) {
        Remove-Item -LiteralPath $LIBDIR -Recurse -Force
        Write-Log "removed $LIBDIR"
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
    return 0
}

# --- the Scheduled Task -------------------------------------------------------

# The command the task runs, as one string. A function so the suite can assert
# what a task will carry without registering one.
#
# EVERY PATH IS ABSOLUTE AND BAKED IN HERE, at registration, INCLUDING THE
# CONFIG. An at-startup S4U task can run before the user's profile is loaded,
# and Get-ConfigPath reads %LOCALAPPDATA% at run time: unset, or pointing at the
# Default profile, the watcher reads an empty config, throws "no trigger.device"
# into a console-less wscript host, and the self-heal relaunches it to do the
# same thing forever. Registration is the moment that knows whose install this
# is; the watcher is not.
#
# This is NOT configuration in the task action -- the settings themselves are
# still read from the file at startup, which is why there is no apply step. It
# is only the answer to WHICH FILE, which the watcher cannot derive.
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

# Windows Script Host reads UTF-16LE with a BOM. ASCII source is a repository
# convention; generated launcher paths are user data and may be Unicode.
function Write-WatcherLauncher {
    param([string]$Path, [string]$Command)
    $vbsCmd = $Command -replace '"', '""'
    @(
        "' Generated by install.ps1 -- do not edit; re-run install.ps1 instead."
        "' Runs the watcher with no console allocated and no window to close."
        'Dim sh: Set sh = CreateObject("WScript.Shell")'
        "sh.Run ""$vbsCmd"", 0, True"
    ) | Set-Content -LiteralPath $Path -Encoding Unicode
}

# The `trigger-kvm` on PATH. A .cmd rather than a .ps1 so it runs from cmd.exe,
# PowerShell and the Run dialog alike, with no execution-policy friction.
#
# Two scripts stay behind one command deliberately: trigger-kvm.ps1 runs on
# EVERY device arrival and is kept lean; install.ps1 is large and rarely used.
# Merging them would load installer code on the hot path.
function Get-ShimLines {
@(
    '@echo off'
    'rem Generated by install.ps1 -- do not edit; re-run the installer instead.'
    'rem The routing below is generated from $VERBS; do not hand-add a verb here.'
    'setlocal'
    'rem Scripts live one level up; only this shim is on PATH.'
    'set "TK_DIR=%~dp0..\"'
    # NO ARGUMENTS PRINTS USAGE. It used to reach the switcher, whose $Command
    # defaults to `pull`, so the bare command name MOVED EVERY CONFIGURED
    # MONITOR -- and that is the single likeliest thing somebody types to find
    # out what a tool does. Hard rule 4.
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
    # ANYTHING ELSE IS OURS TO REPORT: the shim is the only thing that knows the
    # whole surface.
    'goto :unknown'
    ':switch'
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TK_DIR%trigger-kvm.ps1" %*'
    'exit /b %ERRORLEVEL%'
    ':manage'
    # Leave this batch context before invoking PowerShell: uninstall removes
    # the shim. The remaining command runs with the already-expanded paths
    # and returns its own code without reading the deleted file or exiting cmd.
    '(goto) 2>nul & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TK_DIR%install.ps1" %*'
    ':noinstall'
    'rem Installing is what produced this command, so re-running it here would only'
    'rem copy the installed files onto themselves. Upgrading and repairing both mean'
    'rem fetching the source and running ITS installer.'
    'echo trigger-kvm: there is no `install` verb here -- installing is what got you'
    'echo                this command. To upgrade or repair, run install.ps1 from the'
    'echo                source tree. To change settings: trigger-kvm configure'
    'exit /b 2'
    # ONE source of usage text, and it is the PowerShell one: generating the
    # whole help screen as `echo` lines would mean escaping <, > and | for cmd
    # on every line of it, forever.
    #
    # help, a bare command and an unknown verb all land on the same target and
    # the same exit code, because macOS's usage() does. The unknown-verb case
    # says WHICH verb first, which is the only part that differs.
    ':unknown'
    'echo trigger-kvm: no such verb "%~1".'
    'echo.'
    ':help'
    ':usage'
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TK_DIR%install.ps1" help'
    'exit /b %ERRORLEVEL%'
)
}

# --- installing ---------------------------------------------------------------

# Put the shipped files where the task will look for them, and stamp what was
# put there. Everything it needs is a path constant from install.ps1.
#
# THE SOURCE CAN BE THE DESTINATION. `trigger-kvm configure` from the installed
# shim re-runs install from $DEST, and then every source below IS its own
# destination -- so this is not "copy, but skip the ones that match": it is one
# fact about where this run started, asked once.
function Install-Files {
    New-Item -ItemType Directory -Force -Path $DEST              | Out-Null
    New-Item -ItemType Directory -Force -Path $BINDIR            | Out-Null
    New-Item -ItemType Directory -Force -Path $LIBDIR            | Out-Null
    New-Item -ItemType Directory -Force -Path (Split-Path $LOG)  | Out-Null

    # Copy-Item refuses a file onto itself -- "Cannot overwrite the item ... with
    # itself", measured -- and $ErrorActionPreference = 'Stop' makes that an
    # abort partway through an install that had already said it was installing.
    $sameCopy = (Resolve-Path $TK_HOME).Path -eq (Resolve-Path $DEST).Path
    if ($sameCopy) {
        Write-Log "running from $DEST -- the scripts there are the ones being installed."
    } else {
        Copy-Item (Join-Path $TK_HOME 'config.ps1')       $CFGLIB -Force
        Copy-Item (Join-Path $TK_HOME 'event-watch.ps1')  $WATCH  -Force
        Copy-Item (Join-Path $TK_HOME 'trigger-kvm.ps1')  $SWITCHER -Force
        # One glob: a new lib file joins the install by existing.
        Copy-Item (Join-Path (Join-Path $TK_HOME 'lib') '*.ps1') $LIBDIR -Force
        # This program too, so status/logs/pause/uninstall keep working after the
        # source tree is deleted. $TK_SELF, not $PSCommandPath: inside lib\ that
        # would be lib\host.ps1.
        Copy-Item $TK_SELF $MANAGE -Force
        Write-Log "installed scripts to $DEST"
    }

    # What an earlier layout of this install left inside $DEST. The PATH half of
    # the old shim is Set-InstalledPath's, at the end, because only a process
    # running as the target user may touch that user's PATH.
    foreach ($f in $EARLIER_LAYOUT) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force; Write-Log "removed $f" }
    }

    Get-ShimLines | Set-Content -LiteralPath $SHIM -Encoding ASCII

    # Reconfiguring the installed files does not change their build identity.
    # The installed directory has no Git metadata or SPEC-REVISION source.
    if ($sameCopy -and (Test-Path -LiteralPath $STAMP)) { return }

    # Version stamp. Records the commit when the source is a git checkout, which
    # is how you tell a released copy from one built off a dirty tree, and the
    # spec revision, which is how you tell a bug from a version gap.
    $commit = ''
    try {
        Push-Location $TK_HOME
        $commit = (& git rev-parse --short HEAD 2>$null)
        if ($LASTEXITCODE -ne 0) { $commit = '' }
        if ($commit -and (& git status --porcelain 2>$null)) { $commit += '+dirty' }
    } catch { } finally { Pop-Location -ErrorAction SilentlyContinue }

    $specRev = ''
    $revFile = Join-Path $TK_HOME 'SPEC-REVISION'
    if (Test-Path -LiteralPath $revFile) {
        $m = [regex]::Match((Get-Content -Raw -LiteralPath $revFile), '(?m)^revision\s*=\s*(\d+)')
        if ($m.Success) { $specRev = $m.Groups[1].Value }
    }

    @(
        "version   = $VERSION"
        "installed = $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "source    = $TK_HOME"
        "commit    = $(if ($commit) { $commit } else { '(not a git checkout)' })"
        "spec      = $(if ($specRev) { $specRev } else { 'unknown' })"
    ) | Set-Content -LiteralPath $STAMP -Encoding UTF8
}

# The elevated half of replacing a protected task with a user tier. No files,
# configuration or PATH are changed here, and no replacement is registered:
# that belongs to the original unelevated parent, including across UAC users.
function Remove-ProtectedTask {
    if (-not $IsElevated) {
        Write-Log 'removing the protected task requires an elevated process.'
        return 1
    }
    try {
        if (Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
            Stop-Watchers
            Unregister-ScheduledTask -TaskName $TASK -Confirm:$false -ErrorAction Stop
        }
        return 0
    } catch {
        Write-Log ("could not remove the protected task '{0}': {1}" -f $TASK, $_.Exception.Message)
        return 1
    }
}

# Copy the files, register the task, start it. This is what installing IS;
# there is no `install` verb on the CLI.
#
# Never install a tier that will silently fail: the s4u tier cannot be
# registered without elevation -- measured, S4U registration returns "Access is
# denied" for an ordinary user -- so ask for it UP FRONT, before copying
# anything, rather than letting Register-ScheduledTask fail halfway through.
function Invoke-Install {
    $tier = Get-EffectiveTier

    if ($tier -eq 's4u' -and -not $IsElevated) {
        # A refusal is not the end of the install: it falls back to the login
        # tier and carries on from here, with the config saying so.
        $tier = Invoke-BootTierElevation
    }

    # No config means nothing to install FROM. Walk the user through it instead,
    # and refuse clearly when we cannot ask.
    if (-not (Test-Path -LiteralPath $CONFIG)) {
        if (Test-CanPrompt) {
            Write-Log 'no configuration yet -- starting the walkthrough.'
            Invoke-Configure
            if ($LASTEXITCODE -ne 0) {
                Write-Log 'the walkthrough did not complete; nothing was installed.'
                return $LASTEXITCODE
            }

            # The check above ran BEFORE there was a config to read, so a
            # walkthrough that asked for boot start would otherwise be silently
            # ignored and the task registered as the login one. This is the
            # common path, since boot start is the default answer.
            $tier = Get-EffectiveTier
            if ($tier -eq 's4u' -and -not $IsElevated) {
                $tier = Invoke-BootTierElevation
            }
        } else {
            Write-Log "no configuration at $CONFIG, and this is not an interactive terminal."
            Write-Host ''
            Write-Host 'Run this from a normal PowerShell window to set it up:'
            Write-Host ("    {0}" -f $TK_SELF)
            return 2
        }
    }

    # The config is the source of truth for what the task watches. Read it back
    # rather than using the walkthrough's answers, so a hand-edited config takes
    # effect on the next install.
    $cfg = Read-Config -Path $CONFIG

    # Falling back to a default on an unrecognised old key would silently revert
    # customised triggers, so say so instead.
    foreach ($old in $RENAMED_KEYS.Keys) {
        if ($cfg.Contains($old)) {
            Write-Log ("WARNING: '{0}' is an old key name; rename it to '{1}' in {2}." -f $old, $RENAMED_KEYS[$old], $CONFIG)
            if ($old -in @('install.tier', 'install.start')) {
                Write-Log '         Still honoured meanwhile; `trigger-kvm configure` rewrites it.'
            } else {
                Write-Log '         Until you do, the built-in default is used instead of your value.'
            }
        }
    }

    # No fallback. A config with no trigger.device is not a config with a
    # default one -- it is a setup nobody finished, and the task would otherwise
    # be registered to watch for something nobody chose.
    if (-not $cfg.Contains('trigger.device') -or -not "$($cfg['trigger.device'])".Trim()) {
        Write-Log "no trigger.device in $CONFIG -- nothing to watch for."
        Write-Log 'run:  trigger-kvm configure'
        return 2
    }
    # VERBATIM. Stripping whitespace here prints a line that does not appear in
    # the file, for a value the watcher is about to refuse.
    $devices  = "$($cfg['trigger.device'])".Trim()
    $debounce = $(if ($cfg.Contains('trigger.debounce')) { $cfg['trigger.debounce'] } else { $DEFAULT_DEBOUNCE })
    $settle   = $(if ($cfg.Contains('trigger.settle'))   { $cfg['trigger.settle'] }   else { $DEFAULT_SETTLE })
    Write-Log "config says: watch $devices  (debounce ${debounce}s, settle ${settle}s)"

    Install-Files

    # --- the task ------------------------------------------------------------
    #
    # Launched through wscript.exe rather than powershell.exe directly:
    # powershell is a console-subsystem binary, so Windows allocates a console
    # before -WindowStyle Hidden can take effect and a logon task flashes a
    # window every time you log in. wscript is GUI-subsystem, so no console is
    # ever created and there is nothing to close by accident.
    #
    # bWaitOnReturn = True keeps the wscript process alive for as long as the
    # watcher runs, so Task Scheduler still reports the task as Running and its
    # restart settings still apply.
    $psCmd  = Get-WatcherCommand -Watcher $WATCH -Switcher $SWITCHER -LogFile $LOG -ConfigFile $CONFIG
    Write-WatcherLauncher -Path $VBS -Command $psCmd

    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$VBS`""

    # The tier differs in exactly two things: when it starts, and as whom.
    # Everything below -- the self-heal trigger, the settings, the action -- is
    # shared, because the tier is not supposed to change what the watcher does.
    #
    # $FORUSER, never this process's own name: boot registration can run as a
    # different administrator supplied at the standard user's UAC prompt.
    if ($tier -eq 'manual') {
        # No triggers at all. A task with none is legal and can still be started
        # on demand, which is what `trigger-kvm restart` does -- so "no" means
        # "nothing starts it but you", including the self-heal below.
        $triggers = @()
        $principal = New-ScheduledTaskPrincipal -UserId $FORUSER `
            -LogonType Interactive -RunLevel Limited
    } elseif ($tier -eq 's4u') {
        # S4U means "run as this user without their password": no stored
        # credential, and RunLevel Limited means ordinary user rights at run
        # time even though registering it needed admin.
        $triggers = @( (New-ScheduledTaskTrigger -AtStartup) )
        $principal = New-ScheduledTaskPrincipal -UserId $FORUSER `
            -LogonType S4U -RunLevel Limited
    } else {
        $triggers = @( (New-ScheduledTaskTrigger -AtLogOn -User $FORUSER) )
        $principal = New-ScheduledTaskPrincipal -UserId $FORUSER `
            -LogonType Interactive -RunLevel Limited
    }

    # Self-heal. Without it a killed watcher stays dead until the next logon,
    # and you would only find out when the displays silently stopped following.
    # The task's own RestartCount / RestartInterval do NOT bring it back:
    # measured, killing the watcher left the task Ready and no restart occurred
    # in 180s, because Task Scheduler treats the ended task as complete rather
    # than failed. So this interval IS the recovery time.
    #
    # One minute, to stay within sight of macOS, where launchd's KeepAlive
    # respawns in about a second. MultipleInstances IgnoreNew makes each tick a
    # no-op while the watcher is alive.
    $heal = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 1)
    # No Duration means repeat indefinitely; be explicit that it must not stop.
    $heal.Repetition.StopAtDurationEnd = $false
    # Not when nothing is meant to start it: a self-heal trigger would quietly
    # make "no" mean "yes, every minute".
    if ($tier -ne 'manual') { $triggers += $heal }

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

    # StopIfGoingOnBatteries defaults on and would silently kill a desktop's
    # watcher on a brief UPS blip.
    $settings.DisallowStartIfOnBatteries = $false
    $settings.StopIfGoingOnBatteries     = $false

    # Replacing the task means deleting it first, and that can be denied even
    # for your own user-tier task: the task FILE under System32\Tasks is owned
    # by whoever registered it, so one elevated run -- or an s4u install, which
    # requires one -- leaves the user with Read only. Raw, it surfaces as
    # "Access is denied" with the scripts already copied, which reads like a
    # broken installer rather than a fixable permission.
    if (Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
        # AND THE WATCHER UNDERNEATH IT, which stopping the task does not touch.
        # Left behind it keeps holding the mutex, the freshly installed watcher
        # exits on it, and the upgrade silently goes on running the OLD code.
        # Here rather than earlier because this branch is the only case that can
        # have a live watcher of ours, and it is elevated on the boot tier, so
        # it can see a watcher in session 0 that pause and restart cannot.
        Stop-Watchers
        try {
            Unregister-ScheduledTask -TaskName $TASK -Confirm:$false -ErrorAction Stop
        } catch {
            # Ask for elevation rather than sending the user to another
            # terminal: being unable to remove a tier you installed is a trap,
            # and it is the same trap on the way out as on the way in.
            if (-not $IsElevated) {
                Write-Log "the existing '$TASK' task was registered by an elevated process."
                # Elevate only the operation this token could not perform.
                # The original parent registers the user-tier replacement so
                # later changes do not inherit an administrator-owned task.
                $rc = Request-Elevation -Verb 'install' -TaskRemovalOnly
                if ($rc -ne 0) {
                    Write-Log 'protected task removal did not finish; no replacement was registered.'
                    Write-Log 'check: trigger-kvm status, then rerun the installer.'
                    return $rc
                }
                if (Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue) {
                    Write-Log 'the protected task is still present; no replacement was registered.'
                    return 1
                }
            } else {
                Write-Log "cannot replace the existing '$TASK' task even elevated: $($_.Exception.Message)"
                Write-Log 'no replacement was registered; check: trigger-kvm status'
                return 1
            }
        }
    }

    # -Trigger will not take an empty array, so the manual task is registered
    # without it.
    $register = @{ TaskName = $TASK; Action = $action; Principal = $principal; Settings = $settings }
    if ($triggers.Count -gt 0) { $register['Trigger'] = $triggers }

    # The OLD task was unregistered a few lines up, so a throw HERE leaves no
    # autostart at all -- and under $ErrorActionPreference = 'Stop' it left no
    # message about it either. specs/configure.md 4.4: where an interrupted run
    # cannot leave a working setup, it has to say what is left and how to
    # recover.
    try {
        Register-ScheduledTask @register `
            -Description "trigger-kvm: pull the configured monitors to this computer when the shared peripherals arrive." | Out-Null
    } catch {
        Write-Log ("could not register the task '{0}': {1}" -f $TASK, $_.Exception.Message)
        Write-Log 'the scripts are installed and the config is intact; what is missing is the autostart entry.'
        Write-Log 'nothing is watching until that is fixed. To try again:'
        Write-Log ("    {0}" -f $TK_SELF)
        Write-Log 'or start one for this session only:  trigger-kvm restart'
        return 1
    }

    # `pause` disables the task; installing again must undo that or the watcher
    # would be registered, reported healthy, and never actually start.
    Enable-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue | Out-Null
    # Persist the tier that was actually installed, so a later bare install --
    # or the elevated relaunch -- keeps it instead of reverting to the default.
    Set-ConfigValue -Path $CONFIG -Key 'install.autostart' `
                    -Value $(switch ($tier) { 's4u' { 'boot' } 'manual' { 'no' } default { 'login' } })

    Start-ScheduledTask -TaskName $TASK
    Write-Log ("registered and started task '{0}' ({1})" -f $TASK, `
               $(switch ($tier) {
                   's4u'    { 'starts at boot' }
                   'manual' { 'no autostart' }
                   default  { 'starts when you log in' } }))

    # DID ONE ACTUALLY COME UP? "Registered and started" is a claim about the
    # TASK, not about the watcher, and the two came apart silently for a whole
    # day: a surviving watcher held the lock and the new one exited on it. A
    # registered task with nothing watching is the failure shape that looks most
    # like success, so it gets its own sentence.
    $running = $true
    if ($tier -ne 'manual') {
        Start-Sleep -Seconds 2
        $running = Test-WatcherRunning
        if ($running) {
            Write-Log 'a watcher is running.'
        } else {
            Write-Log 'WARNING: the task is registered but NO WATCHER is running.'
            Write-Log 'nothing will switch until one starts. Check:  trigger-kvm logs'
            Write-Log 'then try:  trigger-kvm restart'
        }
    }

    # Skipped when this process is the elevated child of a standard account:
    # that user's PATH is not in this process's HKCU, and the parent does it.
    if ($FORUSER -eq $ME) { Set-InstalledPath }

    # What is left to say is short: it is running, when it will run again, how
    # to see that, and the four things you can do to it.
    #
    # AND IT CLAIMS ONLY WHAT WAS REACHED -- specs/configure.md 12. "trigger-kvm
    # is running" is a claim about the watcher, and a tier that registered but
    # did not come up has not made it true; saying it anyway sends somebody away
    # believing their desk is set up.
    $onPath = @((Get-UserPath) -split ';') -contains $BINDIR
    $cmd    = if ($onPath) { 'trigger-kvm' } else { $SHIM }
    Write-Host ''
    if (-not $running) {
        Write-Host '  Installed, and set up to start on its own -- but NO WATCHER is running'
        Write-Host '  yet, so nothing will switch until one does.'
        Write-Host ''
        Write-Host ("    {0} logs        why it did not start" -f $cmd)
        Write-Host ("    {0} restart     try again" -f $cmd)
        Write-Host ''
        return 1
    }
    if ($tier -eq 'manual') {
        Write-Host '  Done. trigger-kvm is running, but will NOT come back after a restart --'
        Write-Host '  start it yourself with:  trigger-kvm restart'
    } else {
        Write-Host ('  Done. trigger-kvm is running, and will start automatically {0}.' -f `
                    $(if ($tier -eq 's4u') { 'each time the computer reboots' }
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
    return 0
}
