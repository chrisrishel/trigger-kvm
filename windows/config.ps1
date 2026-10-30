# The shared vocabulary: the configuration format, and the facts more than one
# entry point needs. Dot-sourced by trigger-kvm.ps1, event-watch.ps1 and
# install.ps1.
#
# It exists because three consumers parse the same format, and three copies of a
# parser is a drift risk with a nasty shape: if one accepts a line another
# rejects, the switcher and the watcher disagree about what is configured,
# silently. The verb surface and the transport table are here for the same
# reason -- each was written down in three places and had already drifted.
#
# Kept small. It is dot-sourced by a script that runs on EVERY device arrival,
# so nothing here does work at load time: it is a reader, two converters and
# three tables of constants.

# --- the configuration file ---------------------------------------------------

# Flat key = value, "#" starts a comment -- specs/config-format.md, whose whole
# reader is the one regular expression below. Deliberately not TOML or JSON:
# this is read on every switch and must not depend on a parser being installed.
#
#   display.<label>.vendor   EDID manufacturer id, e.g. 0x1E6D
#   display.<label>.product  EDID product id
#   display.<label>.name     human name, for logs
#   display.<label>.method   WHAT is sent: standard | lg-alt
#   display.<label>.transport HOW it gets there; see $TRANSPORTS below
#   display.<label>.input.<value>  which computer is on that input. This is the
#                            WHOLE map: `pull` looks up computer.this in it and
#                            `to mac` looks up mac, so there is no second table
#                            to disagree with it
#   computer.this            what this computer is called in those input maps
#   trigger.device           usb:VVVV:PPPP[@token[@where]] / VVVV:PPPP /
#                            bt:AAAAAAAAAAAA, comma-separated. specs/detector.md 4.1
#   trigger.debounce         seconds
#   trigger.settle           seconds
#   install.autostart        boot | login | no   (install.start, and before it
#                            install.tier = s4u|user, are older spellings
#                            install.ps1 still reads)
#
# Keys are lower-cased; values come back verbatim, trimmed. Callers parse and
# VALIDATE with the converters below, which return $null rather than guessing:
# a misparsed value here is a write aimed at the wrong input or the wrong panel.
#
# ORDERED, so keys come back in file order, last duplicate winning but keeping
# the position of the first. Nothing in the program depends on the order --
# every value is resolved before any is sent -- but specs/config-fixture is
# written in file order, and a reader that cannot reproduce it cannot be checked
# against the other platform's.
#
# UTF-8 is explicit for BOM-less hand edits; Get-Content also strips a byte-order
# mark and the CR of a CRLF file before this regex sees them.
#
# ASK IT `.Contains(key)`, NOT `.ContainsKey(key)`. An OrderedDictionary has
# only the IDictionary spelling; a Hashtable has both.
function Read-Config {
    param([string]$Path)
    $map = [ordered]@{}
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $map }
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ($line -match '^\s*([A-Za-z0-9_.\-]+)\s*=\s*(.*?)\s*(?:#.*)?$') {
            $map[$Matches[1].ToLower()] = $Matches[2]
        }
    }
    return $map
}

# Where the config lives -- THE FALLBACK, not the answer. It reads
# %LOCALAPPDATA% at run time, which in session 0 before a profile is loaded is
# unset or the Default profile's, so the installed watcher and the switcher it
# spawns are TOLD their path with -Config and only a hand-run one lands here.
function Get-ConfigPath {
    Join-Path $env:LOCALAPPDATA 'trigger-kvm\config'
}

# --- writing ------------------------------------------------------------------

# specs/config-format.md, "A writer must not write what it cannot read back".
#
# Here, beside the reader, because it is the reader's rules read backwards and
# the two must never disagree about what survives a round trip.
#
# Three characters break the trip and all three follow from the regex above: `#`
# cuts the value and has no escape, CR and LF end the line, and surrounding
# whitespace is trimmed. They are REMOVED rather than escaped -- this format has
# no escape, and inventing one is what two readers drift on. `=` needs nothing.
#
# A display's name is written verbatim from what the panel reports, and EDID
# descriptor strings are LF-terminated by the standard, so that is the value
# this bites first.
function ConvertTo-ConfigValue {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace '[#\r\n]', ' ' -replace '\s+', ' ').Trim()
}

# Reduce whatever a platform uses to identify a device INTO the config's token
# class -- specs/config-format.md, `trigger.device`.
#
# `[a-z0-9-]` is not arbitrary: it is the class computer and display names
# already follow, and the only one that survives this list's handling unchanged
# -- no `#` for the reader to cut, no `,` to split, no whitespace or case to
# normalise. Every identifier this program writes passes through a reduction
# like this one, which is why no writer here needs a "cannot represent it"
# refusal.
#
# Here because all three consumers need the same answer: install.ps1 writes
# tokens and event-watch.ps1 matches them, and two spellings of "reduce this
# string" is a watcher that cannot find the device the walkthrough just wrote.
function ConvertTo-DeviceToken {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return (($Text.ToLower() -replace '[^a-z0-9]+', '-').Trim('-'))
}

# THE device-entry grammar, and the only copy of it -- specs/detector.md 4.1.
#
# ONE parse, and every consumer is handed the same verdict: callers that SHOW an
# entry to a person show `Raw`, callers that MATCH use `Key` or `Identity`.
# Nothing re-parses and nothing normalises on the way to a screen, because a
# screen one normalisation looser than the watcher's reader tells somebody their
# entry is fine while the watcher refuses to start on it.
#
# Two case rules, neither cosmetic. The ID half is hex and canonicalises to
# upper (Vid/Prod) for a WQL query and to lower (Key) for a candidate key. The
# SUFFIX half is `[a-z0-9-]` and is CHECKED, never folded: config-format.md
# requires a lower-case token rather than a normalised one, precisely so one
# platform cannot accept what another refuses. Hence -cmatch.
#
# `Spot`, not `Where`: PowerShell gives every object an intrinsic `.Where()`.
function ConvertFrom-TriggerDevices {
    param([string[]]$Text)

    # Split on commas as well as taking a real array: launched via
    # `powershell.exe -File` every argument arrives as one literal string, so a
    # comma-separated -Device is a single element there.
    $out = @()
    foreach ($entry in (@($Text) -split ',')) {
        # TRIMMED, NOT STRIPPED. The whitespace a list has to tolerate is what
        # follows a comma, and that is at an entry's ends; deleting it
        # everywhere turns `@has space` into a valid-looking entry.
        $raw = "$entry".Trim()
        if (-not $raw) { continue }

        $e = [PSCustomObject]@{
            Raw = $raw; Ok = $false; Kind = ''; Vid = ''; Prod = ''
            Token = ''; Spot = ''; Addr = ''; Key = ''; Identity = ''
        }

        # EXACTLY four hex digits, a colon, four more -- no whitespace inside
        # the entry, because `046d : 0843` is accepted by a looser reader and
        # refused by the macOS one, and then one config describes two different
        # sets of watched devices depending on which computer reads it.
        # Both suffixes optional: absent, the entry means what it always meant.
        if ($raw -cmatch '^(?:[Uu][Ss][Bb]:)?([0-9A-Fa-f]{4}):([0-9A-Fa-f]{4})(?:@([a-z0-9-]+))?(?:@([a-z0-9-]+))?$') {
            $e.Ok    = $true
            $e.Kind  = 'usb'
            $e.Vid   = $Matches[1].ToUpper()
            $e.Prod  = $Matches[2].ToUpper()
            $e.Token = $(if ($Matches[3]) { $Matches[3] } else { '' })
            $e.Spot  = $(if ($Matches[4]) { $Matches[4] } else { '' })
            # The spot is NOT part of a device's identity: 4.1 confines it to
            # breaking a tie, so an entry whose device moved sockets is the SAME
            # entry. Everything asking "is this configured?" compares Identity,
            # or a moved device shows as unconfigured and its "currently a
            # trigger" marker vanishes -- which reads as "my setup was lost".
            $e.Identity = ('usb:{0}:{1}' -f $e.Vid, $e.Prod).ToLower() +
                          $(if ($e.Token) { "@$($e.Token)" } else { '' })
            $e.Key      = $e.Identity + $(if ($e.Spot) { "@$($e.Spot)" } else { '' })
        }
        # -match here, -cmatch above: an address is hex either way and is folded
        # down, so there is no lower-case-only class for a case-insensitive
        # match to let through.
        elseif ($raw -match '^[Bb][Tt]:([0-9A-Fa-f]{12})$') {
            $e.Ok       = $true
            $e.Kind     = 'bt'
            $e.Addr     = $Matches[1].ToLower()
            # A Bluetooth address already names one device, so there is nothing
            # to disambiguate and no suffix to carry.
            $e.Identity = "bt:$($e.Addr)"
            $e.Key      = $e.Identity
        }

        $out += $e
    }
    return $out
}

# --- value parsing -----------------------------------------------------------
#
# specs/config-format.md, "Value parsing". Both converters FAIL rather than
# guess, and a caller treats that as "refuse", never as zero. That one has
# already cost this project: a missing value became 0x00 on the wire, an input
# no monitor has, so every switch silently did nothing -- with the null check
# present and not firing. The property a test asserts is that NOTHING IS SENT.
#
# NOTHING IS TRIMMED. The reader has already trimmed every value it returns, so
# whitespace reaching here came from a command line or a menu, and " 0x11 " is
# exactly the near-miss that should be refused rather than quietly cleaned up.

# An input value: 0x11, 0X11 or 17. A leading zero is DECIMAL, not octal --
# shells read 010 as eight, which would be a silent cross-platform disagreement
# about which input to select.
function ConvertTo-Byte {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    try {
        if ($Text -cmatch '^0[xX][0-9A-Fa-f]{1,2}$') { return [byte][Convert]::ToInt32($Text.Substring(2), 16) }
        if ($Text -match  '^[0-9]{1,3}$')            { return [byte][int]$Text }
    } catch { return $null }
    return $null
}

# An EDID vendor or product id: 16-bit, e.g. 0x1E6D. The <= 65535 check is not
# redundant with the digit count -- 99999 is five digits and is not a word.
function ConvertTo-Word {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    try {
        if ($Text -cmatch '^0[xX][0-9A-Fa-f]{1,4}$') { return [int][Convert]::ToInt32($Text.Substring(2), 16) }
        if ($Text -match  '^[0-9]{1,5}$') {
            $n = [int]$Text
            if ($n -le 65535) { return $n }
        }
    } catch { return $null }
    return $null
}

# A number of seconds as the config allows it: digits, or digits '.' digits.
# specs/detector.md 4 -- `three` is REFUSED, never read as zero, because a
# debounce of zero fires on every event in a plug's burst.
function Test-Seconds {
    param([string]$Text)
    return ($Text -match '^[0-9]+(\.[0-9]+)?$')
}

# --- the transports -----------------------------------------------------------

# HOW THE BYTES GET THERE, one row per transport -- specs/config-format.md,
# "transport and method are different questions".
#
# Here, and only here, because four things need it and they are three different
# scripts: the walkthrough OFFERS a transport, the switcher REFUSES one it does
# not know, `status` REPORTS what each takes away, and the tier question knows
# which ones cannot switch before login. Four copies of that had already drifted
# into a walkthrough that could offer what the switcher would reject.
#
# NeedsDesktop and CanSourceByte are two different axes and dxva2 being in both
# is a coincidence of one API, not one property (docs/decisions/003): "needs a
# desktop" and "cannot address an I2C source byte" could easily come apart in a
# future transport.
#
# dxva2 goes through user32, which reports the wrong monitors rather than none
# when there is no desktop of its own -- one phantom in session 0, and the
# remote display over RDP (docs/measurements.md). Its EDID gate is what stops it
# acting on either.
$TRANSPORTS = @(
    @{ Name = 'nvapi'
       Label  = 'Through the graphics card'
       Detail = 'works before anyone logs in'
       Note   = 'through the graphics card'
       NeedsDesktop = $false; CanSourceByte = $true }
    @{ Name = 'dxva2'
       Label  = 'Through Windows'
       Detail = 'login onward only'
       Note   = 'through Windows; not before somebody logs in'
       NeedsDesktop = $true;  CanSourceByte = $false }
)

# Derived, so a new row in the table above joins all three by existing.
$TRANSPORT_NAMES       = @($TRANSPORTS | ForEach-Object { $_.Name })
$DESKTOP_TRANSPORTS    = @($TRANSPORTS | Where-Object { $_.NeedsDesktop } | ForEach-Object { $_.Name })
$SOURCELESS_TRANSPORTS = @($TRANSPORTS | Where-Object { -not $_.CanSourceByte } | ForEach-Object { $_.Name })

# --- the verb surface ---------------------------------------------------------

# EVERY VERB `trigger-kvm` ACCEPTS, IN ONE PLACE -- specs/README.md, "The verb
# surface". It was in three (the shim's routing, and each script's own accepted
# set), none could see the others, and the drift was invisible until somebody
# typed a wrong verb: the message they got named three verbs that do not work
# and hid three that do.
#
# Here rather than in the installer because BOTH entry scripts check what they
# were given against it, and the shim's routing is generated from it.
#
# `Where` is which script runs it: the switcher is kept lean because it runs on
# every device arrival, and the installer is large and rarely used. That split
# is the reason a shim exists at all.
#
# TWO VERBS ARE DELIBERATELY ABSENT. `install` is what running the installer
# from the source tree means, and the shim refuses it by name; offering a verb
# that is refused is how the old error misled. `set --only <label> --value
# <byte>` exists for the walkthrough's guided discovery, and a general "write
# any value to a monitor" command on the public surface invites exactly the
# poking at panels ../AGENTS.md hard rule 1 discourages.
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

# The verbs one script runs. `install` and `help` reach the installer without
# being on the public surface: the first is what running it from the source tree
# means, the second is what the shim calls to print the usage rather than
# spelling it out in batch echo lines. `set` reaches the switcher the same way.
function Get-Verbs {
    param([ValidateSet('switch', 'manage')][string]$Where)
    $out = @($VERBS | Where-Object { $_.Where -eq $Where } | ForEach-Object { $_.Verb })
    if ($Where -eq 'manage') { return @($out + @('install', 'help')) }
    return @($out + @('set'))
}
