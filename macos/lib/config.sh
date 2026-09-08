# shellcheck shell=bash
# shellcheck disable=SC2034  # a sourced library: its variables are read by its callers

# The configuration file: specs/config-format.md, read and written.
#
# The reader is the spec's one regular expression, and every place it could
# differ from windows/config.ps1 is pinned by the shared fixture:
#
#     ^\s*([A-Za-z0-9_.\-]+)\s*=\s*(.*?)\s*(?:#.*)?$

# The store: "key<TAB>value" lines in file order, one variable, because
# /bin/bash on macOS is 3.2 and has no associative arrays. A key cannot contain
# a tab, so every lookup takes the remainder of the line as the value.
CONFIG_DATA=""
CONFIG_PATH=""

config_default_path() {
  printf '%s\n' "$HOME/Library/Application Support/trigger-kvm/config"
}

# A missing file is empty, not an error: "no config yet" is a state every
# caller handles, and `status` runs on exactly that machine.
config_normalize() {
  [ -f "$1" ] || return 0
  awk '
    {
      line = $0
      # \s in the spec covers CR, VT and FF as well as space and tab; awk
      # matches none of them without being told. A BOM hides the first key.
      sub(/\r$/, "", line)
      if (NR == 1 && substr(line, 1, 3) == "\357\273\277") line = substr(line, 4)
      sub(/#.*$/, "", line)
      if (line !~ /^[ \t\v\f]*[A-Za-z0-9_.-]+[ \t\v\f]*=/) next
      eq  = index(line, "=")
      key = substr(line, 1, eq - 1)
      val = substr(line, eq + 1)
      gsub(/^[ \t\v\f]+/, "", key); gsub(/[ \t\v\f]+$/, "", key)
      gsub(/^[ \t\v\f]+/, "", val); gsub(/[ \t\v\f]+$/, "", val)
      print tolower(key) "\t" val
    }
  ' "$1"
}

config_load() {
  CONFIG_PATH=$1
  CONFIG_DATA=$(config_normalize "$1")
}

# The value for a key, or "" when absent. The last definition wins.
config_get() {
  printf '%s\n' "$CONFIG_DATA" |
    awk -F'\t' -v k="$1" '$1 == k { v = substr($0, length($1) + 2) } END { print v }'
}

# Every key under a literal prefix, in file order, once each. A prefix rather
# than a pattern: it carries a display label, and `awk -v` mangles backslashes.
config_keys_under() {
  printf '%s\n' "$CONFIG_DATA" |
    awk -F'\t' -v p="$1" 'index($1, p) == 1 && length($1) > length(p) { print $1 }' | awk '!seen[$0]++'
}

# --- value parsing -----------------------------------------------------------
#
# Both converters FAIL rather than default. A misparsed input value is a write
# aimed at the wrong input; a misparsed EDID id, at the wrong panel. Callers
# treat failure as "refuse", never as zero.

# An input value: 0x11, 0X11 or 17, printed in decimal. 10# because bash reads
# a leading zero as octal and the PowerShell reader does not.
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

# An EDID vendor or product id: a 16-bit word, e.g. 0x1E6D, printed in decimal.
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

# Seconds as the config allows them: digits, or digits.digits.
config_is_seconds() { [[ $1 =~ ^[0-9]+(\.[0-9]+)?$ ]]; }

# --- writing -----------------------------------------------------------------
#
# specs/config-format.md, "A writer must not write what it cannot read back":
# `#` cuts a value, CR and LF end the line, surrounding whitespace is trimmed.
# Each becomes a space and runs of whitespace collapse, byte for byte what
# windows/config.ps1 does, so one panel name is written the same on both.
config_to_value() {
  local _v
  _v=$1
  _v=${_v//[$'#\r\n\t\v\f']/ }
  while [ "$_v" != "${_v//  / }" ]; do _v=${_v//  / }; done
  _v=${_v# }; _v=${_v% }
  printf '%s' "$_v"
}

# The ONE way a `key = value` line is written; tests/conventions.tests.sh scans
# for any other. $3 pads the key so a block lines up.
config_line() {
  printf '%-*s = %s\n' "${3:-0}" "$1" "$(config_to_value "$2")"
}

# --- displays ----------------------------------------------------------------

# Every display label the config declares, sorted, as the Windows reader sorts
# them. `[^.]+`: a label containing a dot is not a label.
config_display_labels() {
  printf '%s\n' "$CONFIG_DATA" | cut -f1 |
    { grep -E '^display\.[^.]+\.vendor$' || true; } |
    sed -e 's/^display\.//' -e 's/\.vendor$//' | sort -u
}

# One display's field, or $3 when the config does not set it.
config_display_field() {
  local _v
  _v=$(config_get "display.$1.$2")
  if [ -n "$_v" ]; then printf '%s\n' "$_v"; else printf '%s\n' "$3"; fi
}

# display.<label>.input.<value> = <computer>, read back as "computer<TAB>value"
# with the value in decimal, in file order. This is the whole map: `pull` looks
# up computer.this in it and `to mac` looks up mac. A value that does not parse
# is dropped, not zeroed; a computer named on two inputs reads as AMBIGUOUS,
# which callers refuse on.
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

config_this_computer() {
  config_get 'computer.this' | tr '[:upper:]' '[:lower:]'
}

# Every computer the config names, in the order it first appears.
config_known_computers() {
  local _l
  for _l in $(config_display_labels); do config_input_map "$_l" | cut -f1; done | awk '!seen[$0]++'
}

# --- triggers ----------------------------------------------------------------
#
# The grammar of specs/config-format.md, in one place: usb:VVVV:PPPP with up to
# two `@` suffixes each [a-z0-9-]+, bt: plus twelve hex digits, or a bare
# VVVV:PPPP meaning usb. The id is case-insensitive; a suffix is checked
# lower-case, never normalised.
CONFIG_ID_RULE='[0-9a-f]{4}:[0-9a-f]{4}'
CONFIG_SUFFIX_RULE='(@[a-z0-9-]+){0,2}'

config_is_trigger_device() {
  local _l
  _l=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [[ $_l =~ ^(usb:)?$CONFIG_ID_RULE$CONFIG_SUFFIX_RULE$ ]] || return 1
  case $1 in
    *@*) [[ ${1#*@} =~ ^[a-z0-9-]+(@[a-z0-9-]+)?$ ]] || return 1 ;;
  esac
  [[ $_l =~ ^bt: ]] && return 1
  return 0
}

# The list split into entries, each trimmed at its ends and otherwise as
# written, so a malformed entry stays malformed and gets named.
config_trigger_entries() {
  config_get 'trigger.device' | tr ',' '\n' |
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | { grep -v '^$' || true; }
}

# The well-formed entries, normalised to the form the watcher's list uses.
config_trigger_devices() {
  local _d _l
  config_trigger_entries |
    while IFS= read -r _d; do
      _l=$(printf '%s' "$_d" | tr '[:upper:]' '[:lower:]')
      if [[ $_l =~ ^bt:[0-9a-f]{12}$ ]]; then printf '%s\n' "$_l"
      elif config_is_trigger_device "$_d"; then
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
