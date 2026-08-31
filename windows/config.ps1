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
#   display.<label>.self     input value where THIS machine is
#   display.<label>.input.<value>  your name for that input, e.g.
#                            display.lg.input.0xd1 = Mac. Value-first so the name
#                            survives verbatim: keys are lower-cased, values are not
#   scene.<name>.<label>     input value for that display in that scene
#   trigger.device           usb:VVVV:PPPP / VVVV:PPPP / bt:AAAAAAAAAAAA, comma-sep
#   trigger.debounce         seconds
#   trigger.settle           seconds
#   install.start            boot | login  (install.tier = s4u|user is the old
#                            spelling, still read by install.ps1)
#
# Keys are lower-cased; values are returned verbatim, trimmed. Callers parse and
# VALIDATE their own values -- see the converters in trigger-kvm.ps1, which return
# $null rather than guessing, because a misparsed value here is a write aimed at the
# wrong input or the wrong panel.
function Read-Config {
    param([string]$Path)
    $map = @{}
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
function Get-ConfigPath {
    Join-Path $env:LOCALAPPDATA 'trigger-kvm\config'
}
