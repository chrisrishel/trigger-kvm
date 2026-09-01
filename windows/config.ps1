# Shared configuration reader. Dot-sourced by trigger-kvm.ps1, event-watch.ps1 and
# install.ps1.
#
# This exists as its own file because three consumers now parse the same format,
# and three copies of a parser is a drift risk with a nasty shape: if one accepts a
# line another rejects, the switcher and the watcher disagree about what is
# configured, silently. Two copies was arguably fine; three is not.
#
# Kept deliberately tiny. It is dot-sourced by a script that runs on EVERY device
# arrival, so it must stay cheap, and the macOS side does the same job in one sed
# expression -- if this grows past what sed can mirror, the format has drifted.

# Flat key = value, "#" starts a comment. Deliberately not TOML or JSON: this is
# read on every switch and must not depend on a parser being installed.
#
#   display.<label>.vendor   EDID manufacturer id, e.g. 0x1E6D
#   display.<label>.product  EDID product id
#   display.<label>.name     human name, for logs
#   display.<label>.method   standard | lg-alt
#   display.<label>.input.<value>  which computer is on that input, e.g.
#                            display.lg.input.0xd1 = mac. This is the WHOLE map:
#                            `pull` looks up computer.this in it, `to mac` looks up
#                            mac, and there is no second table to disagree with it
#   computer.this            what this computer is called in those input maps
#   trigger.device           usb:VVVV:PPPP / VVVV:PPPP / bt:AAAAAAAAAAAA, comma-sep
#   trigger.debounce         seconds
#   trigger.settle           seconds
#   install.autostart        boot | login | no   (install.start, and before it
#                            install.tier = s4u|user, are older spellings that
#                            install.ps1 still reads)
#
# Keys are lower-cased; values are returned verbatim, trimmed. Callers parse and
# VALIDATE their own values with the converters below, which return $null rather
# than guessing, because a misparsed value here is a write aimed at the wrong
# input or the wrong panel.
#
# ORDERED, so keys come back in the order the file lists them, last duplicate
# winning but keeping the position of the first. Nothing in the program depends
# on the order -- every value is resolved before any of them is sent -- but
# specs/config-fixture/expected.tsv is written in file order, and a reader that
# cannot reproduce it cannot be checked against the other platform's.
#
# Get-Content does the rest of specs/config-format.md's line rules for free:
# measured 2026-09-01, it strips a UTF-8 byte-order mark and the CR of a CRLF
# file before this regex ever sees them.
#
# ASK IT `.Contains(key)`, NOT `.ContainsKey(key)`. An OrderedDictionary has only
# the IDictionary spelling; a Hashtable has both. So `.Contains` is the one that
# works whichever a caller is holding, and it is what the [ordered] display maps
# in install.ps1 are already asked.
function Read-Config {
    param([string]$Path)
    $map = [ordered]@{}
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $map }
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^\s*([A-Za-z0-9_.\-]+)\s*=\s*(.*?)\s*(?:#.*)?$') {
            $map[$Matches[1].ToLower()] = $Matches[2]
        }
    }
    return $map
}

# Where the config lives. One definition, so the three consumers cannot disagree
# about which file they are talking about.
#
# THE FALLBACK, not the answer. It reads %LOCALAPPDATA% at run time, which in
# session 0 before a profile is loaded is unset or the Default profile's -- so
# the installed watcher and the switcher it spawns are TOLD their path with
# -Config, and only a hand-run one lands here. See install.ps1's
# Get-WatcherCommand.
function Get-ConfigPath {
    Join-Path $env:LOCALAPPDATA 'trigger-kvm\config'
}

# --- value parsing -----------------------------------------------------------
#
# specs/config-format.md, "Value parsing". Both converters FAIL rather than guess
# or default, and a caller must treat that as "refuse", never as zero. This is
# the one that has already cost this project: a missing value became 0x00 on the
# wire, an input no monitor has, so every switch silently did nothing and said
# nothing -- the null check was present and did not fire. So the property to
# assert in a test is that NOTHING IS SENT.
#
# They live HERE, beside the reader, because they are half of the same contract:
# what a line means and what a value means are one file's worth of format, and
# three consumers each parsing their own would be the drift risk this file exists
# to close. macOS keeps config_to_byte / config_to_word in lib/config.sh for the
# same reason.
#
# NOTHING IS TRIMMED. The reader has already trimmed every value it returns, so
# whitespace reaching here came from somewhere else -- a command line, a menu --
# and " 0x11 " is exactly the kind of near-miss that should be refused rather
# than quietly cleaned up. specs/config-fixture/values.tsv pins it, and the
# macOS converters refuse it too.

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
# debounce of zero fires on every event in a plug's burst and a watcher that
# runs while doing the wrong thing is the worst failure shape available.
function Test-Seconds {
    param([string]$Text)
    return ($Text -match '^[0-9]+(\.[0-9]+)?$')
}
