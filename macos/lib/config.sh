# shellcheck shell=bash
# shellcheck disable=SC2034  # a sourced library: its variables are read by its callers

# Shared configuration reader. Sourced by every verb.
#
# The format is a CROSS-PLATFORM CONTRACT -- the same file shape is written and
# read by windows/config.ps1 -- so this parser has to agree with that one. It
# implements exactly this PowerShell regex, and each way the two could have
# differed was checked against it rather than assumed:
#
#     ^\s*([A-Za-z0-9_.\-]+)\s*=\s*(.*?)\s*(?:#.*)?$
#
#   * a key is [A-Za-z0-9_.-]+ and is LOWER-CASED on read
#   * everything after the FIRST '=' is the value, cut at the first '#', then
#     trimmed at both ends. Values keep their case, verbatim -- so a value may
#     contain '=' and it is not a second separator.
#   * a line that does not match is ignored, not an error
#   * on a DUPLICATE key the LAST one wins, because assigning into PowerShell's
#     hashtable does
#
# Deliberately not TOML or JSON: it is read on every device arrival and must not
# depend on a parser being installed.

# The store: normalised "key<TAB>value" lines held in one variable, because
# /bin/bash on macOS is 3.2 and has no associative arrays. A key cannot contain
# a tab (the charset forbids it), so the first tab is unambiguously the
# separator -- which is why every lookup below takes the REMAINDER of the line
# rather than field 2, so a value containing a tab still reads back verbatim.
CONFIG_DATA=""
CONFIG_PATH=""

# Where the config lives. One definition, so no consumer can disagree about
# which file it is talking about. It sits beside the log rather than with the
# program, so uninstalling does not throw away a configuration that represents
# real work.
config_default_path() {
  printf '%s\n' "$HOME/Library/Application Support/trigger-kvm/config"
}

# Normalise a config file to "key<TAB>value" lines on stdout.
#
# A missing file yields nothing and is not an error: "no config yet" is a state
# every caller already handles, and failing here would make `status` and
# `configure` fail on exactly the machine that needs them most.
config_normalize() {
  [ -f "$1" ] || return 0
  awk '
    {
      line = $0
      # The spec regex trims \s, which includes the CR of a CRLF file; awk does
      # not. Left in, the CR rode on every value: `lg-alt<CR>` was an unknown
      # method, the vendor did not parse, and every switch refused with a
      # message that looked fine. A BOM on the first line hid the first key.
      sub(/\r$/, "", line)
      if (NR == 1 && substr(line, 1, 3) == "\357\273\277") line = substr(line, 4)
      sub(/#.*$/, "", line)
      if (line !~ /^[ \t]*[A-Za-z0-9_.-]+[ \t]*=/) next
      eq  = index(line, "=")
      key = substr(line, 1, eq - 1)
      val = substr(line, eq + 1)
      gsub(/^[ \t]+/, "", key); gsub(/[ \t]+$/, "", key)
      gsub(/^[ \t]+/, "", val); gsub(/[ \t]+$/, "", val)
      print tolower(key) "\t" val
    }
  ' "$1"
}

config_load() {
  CONFIG_PATH=$1
  CONFIG_DATA=$(config_normalize "$1")
}

# The value for a key, or "" when absent. Last definition wins.
config_get() {
  printf '%s\n' "$CONFIG_DATA" |
    awk -F'\t' -v k="$1" '$1 == k { v = substr($0, length($1) + 2) } END { print v }'
}

config_has() {
  printf '%s\n' "$CONFIG_DATA" | awk -F'\t' -v k="$1" '$1 == k { f = 1 } END { exit !f }'
}

# Every key that starts with a literal prefix, sorted. A prefix rather than a
# regular expression on purpose: the prefix carries a display LABEL, and passing
# an escaped pattern through `awk -v` mangles the backslashes.
config_keys_under() {
  printf '%s\n' "$CONFIG_DATA" |
    awk -F'\t' -v p="$1" 'index($1, p) == 1 && length($1) > length(p) { print $1 }' | sort -u
}

# --- value parsing -----------------------------------------------------------
#
# Both parsers FAIL rather than guess or default. A misparsed input value is a
# write aimed at the wrong input; a misparsed EDID id is a write aimed at the
# wrong PANEL -- silently, because a wrong id either matches nothing or matches
# something else. Callers must treat failure as "refuse", never as zero.
#
# This is the one that bit hardest on Windows: a missing value became 0x00 on
# the wire, an input no monitor has, so every switch quietly did nothing and
# said nothing. The null check was present and did not fire. So the property to
# assert in a test is that NOTHING IS SENT -- not that a check ran.

# An input value: 0x11, 0X11 or 17. Prints the decimal value; returns non-zero
# and prints nothing when it is not a byte.
#
# 10# on the decimal branch because bash reads a leading zero as octal, so "010"
# would otherwise be 8 here and 10 in the PowerShell reader -- a silent
# cross-platform disagreement about which input to select.
config_to_byte() {
  case $1 in
    0[xX][0-9A-Fa-f]|0[xX][0-9A-Fa-f][0-9A-Fa-f])
      printf '%d\n' $(( 0x${1#0?} )); return 0 ;;
    [0-9]|[0-9][0-9]|[0-9][0-9][0-9])
      [ $(( 10#$1 )) -le 255 ] || return 1
      printf '%d\n' $(( 10#$1 )); return 0 ;;
  esac
  return 1
}

# An EDID vendor or product id: 16-bit, e.g. 0x1E6D. Prints the decimal value.
config_to_word() {
  case $1 in
    0[xX][0-9A-Fa-f]|\
    0[xX][0-9A-Fa-f][0-9A-Fa-f]|\
    0[xX][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]|\
    0[xX][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f])
      printf '%d\n' $(( 0x${1#0?} )); return 0 ;;
    [0-9]|[0-9][0-9]|[0-9][0-9][0-9]|[0-9][0-9][0-9][0-9]|[0-9][0-9][0-9][0-9][0-9])
      [ $(( 10#$1 )) -le 65535 ] || return 1
      printf '%d\n' $(( 10#$1 )); return 0 ;;
  esac
  return 1
}

# A number of seconds as the config allows it: digits, or digits.digits.
config_is_seconds() { [[ $1 =~ ^[0-9]+(\.[0-9]+)?$ ]]; }

# --- writing -----------------------------------------------------------------
#
# specs/config-format.md, "A writer must not write what it cannot read back".
#
# Lives HERE, beside the reader, because it is the reader's rules read backwards
# and the two must never disagree about what survives a round trip -- the same
# reasoning that put the converters in this file rather than in their callers.
#
# THREE characters break the trip, and all three follow from the parser above:
# `#` cuts the value and has NO escape, CR and LF end the line, and surrounding
# whitespace is trimmed. They are REMOVED rather than escaped, because this
# format has no escape and inventing one is exactly the kind of rule two readers
# drift on.  `=` needs nothing: a value may contain it.
#
# NOT hypothetical. A panel's name is written from what the panel reports, and
# EDID descriptor strings are LF-terminated by the standard: `ACME #1 Display`
# used to be written intact and read back as `ACME`, on both platforms.
#
# Each removed character becomes a SPACE and runs of whitespace then collapse,
# matching windows/config.ps1's ConvertTo-ConfigValue byte for byte. Deleting
# outright would glue words together, and two platforms transforming the same
# panel name differently is a disagreement with no upside.
config_to_value() {
  local _v
  _v=$1
  _v=${_v//[$'#\r\n\t\v\f']/ }
  while [ "$_v" != "${_v//  / }" ]; do _v=${_v//  / }; done
  _v=${_v# }; _v=${_v% }
  printf '%s' "$_v"
}

# The ONE way a `key = value` line is written. Sanitising is a property of
# writing a line rather than something each of a dozen printf sites has to
# remember -- which is what let this go wrong: every site wrote its value
# straight through, on both platforms, identically.
#
# $3 pads the key so a block of keys lines up; absent, no padding.
config_line() {
  printf '%-*s = %s\n' "${3:-0}" "$1" "$(config_to_value "$2")"
}

# --- the display map ---------------------------------------------------------

# Every display label the config declares, sorted. `[^.]+` matches the
# PowerShell side: a label containing a dot is not a label.
# `|| true` because grep exits 1 on no match, and under `set -euo pipefail` that
# would make "this config declares no displays" -- an ordinary state on a fresh
# machine -- kill the caller instead of returning an empty list.
config_display_labels() {
  printf '%s\n' "$CONFIG_DATA" | cut -f1 |
    { grep -E '^display\.[^.]+\.vendor$' || true; } |
    sed -e 's/^display\.//' -e 's/\.vendor$//' | sort -u
}

# One display's field, falling back to $3 when the config does not set it.
config_display_field() {
  local _v
  _v=$(config_get "display.$1.$2")
  if [ -n "$_v" ]; then printf '%s\n' "$_v"; else printf '%s\n' "$3"; fi
}

# display.<label>.input.<value> = <computer>, read back as "computer<TAB>value"
# with the value in decimal.
#
# This is the WHOLE map. `pull` looks up computer.this in it and `to mac` looks
# up mac -- the same lookup, the same code path, one name apart, so the two can
# never disagree about where a computer is. There is deliberately no second
# table: Windows had `display.<label>.self` as well as `scene.<name>.<label>`,
# they could drift, and they did.
#
# A value that does not parse as a byte is DROPPED, not zeroed. Two inputs
# naming the same computer on one panel yields AMBIGUOUS, which callers must
# refuse on rather than choose between -- it means the file was edited wrongly,
# and picking one would switch to an input nobody meant on a desk this machine
# cannot see.
config_input_map() {
  local _k _val _who
  config_keys_under "display.$1.input." |
  while IFS= read -r _k; do
    [ -n "$_k" ] || continue
    _val=$(config_to_byte "${_k##*.input.}") || continue
    _who=$(config_get "$_k" | tr '[:upper:]' '[:lower:]')
    [ -n "$_who" ] || continue
    printf '%s\t%s\n' "$_who" "$_val"
  done |
  awk -F'\t' '
    { if ($1 in seen) { seen[$1] = "AMBIGUOUS" } else { seen[$1] = $2; order[++n] = $1 } }
    END { for (i = 1; i <= n; i++) print order[i] "\t" seen[order[i]] }
  '
}

# One computer's input value on one panel, or nothing when it is not on it.
config_input_for() {
  config_input_map "$1" | awk -F'\t' -v who="$2" '$1 == who { print $2 }'
}

# The computer this config calls the machine it is running on, lower-cased.
config_this_computer() {
  config_get 'computer.this' | tr '[:upper:]' '[:lower:]'
}

# Every computer the config names, in the order it first appears.
config_known_computers() {
  local _l
  for _l in $(config_display_labels); do config_input_map "$_l" | cut -f1; done | awk '!seen[$0]++'
}

# The device grammar, in ONE place, because two spellings of it would let an
# entry be good here and bad in the refusal below -- and the entry that is
# neither listed nor named is the one nobody can debug.
#
# specs/config-format.md and specs/detector.md 4: usb:VVVV:PPPP, bt: plus twelve
# hex digits, or a bare VVVV:PPPP, which means usb so configs written before
# Bluetooth existed keep working.
#
# A usb: entry may carry up to TWO optional `@` suffixes -- usb:VVVV:PPPP@token
# or @token@where -- each `[a-z0-9-]+`. The id half is case-insensitive; the
# suffixes are CHECKED lower-case rather than normalised, because a suffix
# silently lower-cased on one platform and refused on another is exactly the
# disagreement this shared corpus exists to prevent. Absent, an entry means what
# it has always meant, so nothing already written needs migrating.
CONFIG_ID_RULE='[0-9a-f]{4}:[0-9a-f]{4}'
CONFIG_SUFFIX_RULE='(@[a-z0-9-]+){0,2}'

# True when an entry is well formed. Takes it EXACTLY as written: the id may be
# any case, the suffixes may not.
config_is_trigger_device() {
  local _l
  _l=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [[ $_l =~ ^(usb:)?$CONFIG_ID_RULE$CONFIG_SUFFIX_RULE$ ]] || return 1
  # The id half only is case-insensitive, so re-check the suffixes as written.
  case $1 in
    *@*) [[ ${1#*@} =~ ^[a-z0-9-]+(@[a-z0-9-]+)?$ ]] || return 1 ;;
  esac
  [[ $_l =~ ^bt: ]] && return 1
  return 0
}

# The list split into entries, each TRIMMED at its ends, as written.
#
# Trimmed, not stripped of all whitespace. `tr -d ' \t'` squashed
# `usb:046d:c547@has space` into `usb:046d:c547@hasspace` -- a malformed entry
# silently becoming a well-formed one that can never match, which is the failure
# shape detector.md 4 refuses by name. The spaces this has to tolerate are the
# ones after a comma, and those are at an entry's ends.
config_trigger_entries() {
  config_get 'trigger.device' | tr ',' '\n' |
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | { grep -v '^$' || true; }
}

# The configured trigger devices, normalised to the form the candidate keys use.
# Anything else is NOT prefixed into a usb: entry that matches nothing -- it is
# left for config_bad_trigger_devices to name, and the launcher refuses.
config_trigger_devices() {
  local _d _l
  config_trigger_entries |
    while IFS= read -r _d; do
      _l=$(printf '%s' "$_d" | tr '[:upper:]' '[:lower:]')
      if [[ $_l =~ ^bt:[0-9a-f]{12}$ ]]; then printf '%s\n' "$_l"
      elif config_is_trigger_device "$_d"; then
        # Only the id half is lower-cased; a suffix that needed lower-casing was
        # already refused above.
        case $_l in usb:*) printf '%s\n' "$_l" ;; *) printf 'usb:%s\n' "$_l" ;; esac
      fi
    done
}

# The entries config_trigger_devices dropped, as written, for a refusal to name.
config_bad_trigger_devices() {
  local _d _l
  config_trigger_entries |
    while IFS= read -r _d; do
      _l=$(printf '%s' "$_d" | tr '[:upper:]' '[:lower:]')
      [[ $_l =~ ^bt:[0-9a-f]{12}$ ]] && continue
      config_is_trigger_device "$_d" && continue
      printf '%s\n' "$_d"
    done
}

# The bare id of an entry, with any suffixes dropped. What "which devices share
# this id" is asked about.
config_trigger_id() { printf '%s\n' "${1%%@*}"; }
