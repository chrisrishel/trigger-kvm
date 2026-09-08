# shellcheck shell=bash
# shellcheck disable=SC2034  # a sourced library: its variables are read by its callers
# shellcheck disable=SC2016  # the backticks below are prose in the config's comments

# The walkthrough's answers: the researched tables, the per-panel map, the
# state the menu edits, and how that state is loaded from a config and written
# back as one.

# --- the researched tables ---------------------------------------------------

# Standard MCCS input values, in the channel's own order.
MCCS_NAMES=('DisplayPort 1' 'DisplayPort 2' 'HDMI 1' 'HDMI 2' 'DVI 1' 'DVI 2' 'VGA 1' 'USB-C')
MCCS_VALUES=(0x0F 0x10 0x11 0x12 0x03 0x04 0x01 0x1B)

# What a manufacturer's panels answer to when the standard channel does not.
# Keyed by EDID VENDOR, never by model; values from ../displays.toml, never
# from a probe. Offered, never chosen for anyone (../AGENTS.md hard rule 1b).
DIALECT_VENDORS=(1E6D)
DIALECT_WHAT=(LG)
DIALECT_METHOD=(lg-alt)
DIALECT_INPUTS=('DisplayPort=0xD0,USB-C=0xD1,HDMI 1=0x90,HDMI 2=0x91')

# The dialect index for an EDID vendor, or nothing.
wt_dialect_for() {
  local _i
  _i=0
  while [ "$_i" -lt "${#DIALECT_VENDORS[@]}" ]; do
    [ "${DIALECT_VENDORS[$_i]}" = "$1" ] && { printf '%s\n' "$_i"; return 0; }
    _i=$(( _i + 1 ))
  done
  return 1
}

# --- a panel's map, as a string --------------------------------------------
#
# "mac=0xD1,pc=0xD0", in the order the computers were listed. A string because
# bash 3.2 has no associative arrays and a map has to live inside a record.

map_get() {
  printf '%s' "$1" | tr ',' '\n' |
    awk -F= -v k="$2" '$1 == k { print $2; exit }'
}

map_has() { [ -n "$(map_get "$1" "$2")" ]; }

map_computers() { printf '%s' "$1" | tr ',' '\n' | awk -F= 'NF { print $1 }'; }

map_values() { printf '%s' "$1" | tr ',' '\n' | awk -F= 'NF { print $2 }'; }

map_count() { map_computers "$1" | grep -c . || true; }

# Set, keeping an existing key's position and appending a new one.
map_set() {
  local _m _k _v _out _found _old _e
  _m=$1 _k=$2 _v=$3 _out='' _found=0
  _old=$IFS; IFS=,
  for _e in $_m; do
    IFS=$_old
    [ -n "$_e" ] || { IFS=,; continue; }
    case $_e in
      "$_k="*) _out="$_out,$_k=$_v"; _found=1 ;;
      *)       _out="$_out,$_e" ;;
    esac
    IFS=,
  done
  IFS=$_old
  [ "$_found" = "0" ] && _out="$_out,$_k=$_v"
  printf '%s\n' "${_out#,}"
}

map_del() {
  local _m _k _out _old _e
  _m=$1 _k=$2 _out=''
  _old=$IFS; IFS=,
  for _e in $_m; do
    IFS=$_old
    [ -n "$_e" ] || { IFS=,; continue; }
    case $_e in "$_k="*) ;; *) _out="$_out,$_e" ;; esac
    IFS=,
  done
  IFS=$_old
  printf '%s\n' "${_out#,}"
}

# Which computer holds a value on this panel, or nothing. Compared by value.
map_who_has() {
  printf '%s' "$1" | tr ',' '\n' |
    awk -F= -v v="$2" 'tolower($2) == tolower(v) { print $1; exit }'
}

# Rename a computer throughout a map, keeping its position.
map_rename() {
  printf '%s' "$1" | tr ',' '\n' |
    awk -F= -v o="$2" -v n="$3" 'NF { if ($1 == o) print n "=" $2; else print $0 }' |
    paste -sd, -
}

# --- state -------------------------------------------------------------------

WT_THIS=''
WT_COMPUTERS=()
WT_DEVICES=()
WT_TIER=''
WT_WANTPATH=''
WT_ONPATH=0

# Records are fields joined by the unit separator; wt_found and wt_rec unpack
# one into F_* and R_* variables. A field never carries the separator or a
# newline: wt_record replaces both.
RS=$'\x1f'

# One record per ATTACHED panel: key vendor product mfg name twins, where twins
# is how many attached panels answer to that identity.
WT_F=()
wt_found() { IFS=$RS read -r F_KEY F_VENDOR F_PRODUCT F_MFG F_NAME F_TWINS <<<"${WT_F[$1]}"; }

# One record per MANAGED panel: key label name method vendor product map
# attached, where attached is the WT_F index or -1 for a configured panel that
# is not attached today.
WT_A=()
wt_rec() { IFS=$RS read -r R_KEY R_LABEL R_NAME R_METHOD R_VENDOR R_PRODUCT R_MAP R_ATTACHED <<<"${WT_A[$1]}"; }

wt_record() {
  local _f _out
  _out=''
  for _f in "$@"; do _out="$_out$RS${_f//[$RS$'\n']/ }"; done
  printf '%s\n' "${_out#"$RS"}"
}

# The index of the answer record for an identity, or nothing. There is at most
# one: records are per configured label, and the walkthrough never manages an
# identity naming two attached panels.
wt_answer_index() {
  local _i
  _i=0
  while [ "$_i" -lt "${#WT_A[@]}" ]; do
    wt_rec "$_i"
    [ "$R_KEY" = "$1" ] && { printf '%s\n' "$_i"; return 0; }
    _i=$(( _i + 1 ))
  done
  return 1
}

wt_answer_add() { WT_A+=("$1"); }

wt_answer_remove() {
  local _keep _i
  _keep=()
  _i=0
  while [ "$_i" -lt "${#WT_A[@]}" ]; do
    wt_rec "$_i"
    [ "$R_KEY" = "$1" ] || _keep+=("${WT_A[$_i]}")
    _i=$(( _i + 1 ))
  done
  WT_A=("${_keep[@]+${_keep[@]}}")
}

# Replace one field of record $1: map or method.
wt_answer_set() {
  wt_rec "$1"
  case $2 in
    map)    R_MAP=$3 ;;
    method) R_METHOD=$3 ;;
  esac
  WT_A[$1]=$(wt_record "$R_KEY" "$R_LABEL" "$R_NAME" "$R_METHOD" "$R_VENDOR" "$R_PRODUCT" "$R_MAP" "$R_ATTACHED")
}

# The managed panels that are attached, as indices.
wt_attached_managed() {
  local _i
  _i=0
  while [ "$_i" -lt "${#WT_A[@]}" ]; do
    wt_rec "$_i"
    [ "$R_ATTACHED" -ge 0 ] && printf '%s\n' "$_i"
    _i=$(( _i + 1 ))
  done
}

# Apply a map edit to every managed panel: wt_maps_edit map_rename old new.
wt_maps_edit() {
  local _fn _i
  _fn=$1; shift
  _i=0
  while [ "$_i" -lt "${#WT_A[@]}" ]; do
    wt_rec "$_i"
    wt_answer_set "$_i" map "$("$_fn" "$R_MAP" "$@")"
    _i=$(( _i + 1 ))
  done
}

# What a monitor-input pass is bound to (specs/configure.md 10.8): for the given
# records, the identity, method and map. The transport is constant here.
wt_pass_signature() {
  local _i _s
  _s=''
  for _i in "$@"; do
    wt_rec "$_i"
    _s="$_s|$R_KEY=$R_METHOD=$R_MAP"
  done
  printf '%s\n' "$_s"
}

wt_answers_signature() {
  local _i _all
  _all=''
  _i=0
  while [ "$_i" -lt "${#WT_A[@]}" ]; do _all="$_all $_i"; _i=$(( _i + 1 )); done
  # shellcheck disable=SC2086  # a list of indices, meant to split
  wt_pass_signature $_all
}

# --- loading -----------------------------------------------------------------

wt_load_found() {
  local _v _p _mfg _conn _ser _uuid _name _all _i
  WT_F=()
  _all=$(display_enumerate)
  # The serial and UUID are read to skip them: the switcher resolves the
  # handle fresh at switch time, and nothing stored here is matched on.
  while IFS='|' read -r _v _p _mfg _conn _ser _uuid _name; do
    [ -n "$_v" ] || continue
    [ -n "$_name" ] || _name="$_mfg panel $_v:$_p"
    WT_F+=("$(wt_record "$_v:$_p" "0x$_v" "0x$_p" "$_mfg" "$_name" \
                        "$(display_identity_count "$_all" "$_v:$_p")")")
  done <<EOF
$_all
EOF
}

# The WT_F index of the first attached panel with this identity, or -1.
wt_found_index() {
  local _i
  _i=0
  while [ "$_i" -lt "${#WT_F[@]}" ]; do
    wt_found "$_i"
    [ "$F_KEY" = "$1" ] && { printf '%s\n' "$_i"; return 0; }
    _i=$(( _i + 1 ))
  done
  printf -- '-1\n'
}

# The config label whose identity is "VVVV:PPPP", or nothing.
config_label_for() {
  local _l _vn _pn
  for _l in $(config_display_labels); do
    _vn=$(config_to_word "$(config_get "display.$_l.vendor")") || continue
    _pn=$(config_to_word "$(config_get "display.$_l.product")") || continue
    [ "$(printf '%04X:%04X' "$_vn" "$_pn")" = "$1" ] && { printf '%s\n' "$_l"; return 0; }
  done
  return 1
}

# One answer record from the loaded config for label $1, attached at WT_F
# index $2 (or -1). Its map is in the order the computers were listed.
wt_load_answer() {
  local _l _fi _vn _pn _key _name _map _c _val
  _l=$1 _fi=$2
  _vn=$(config_to_word "$(config_get "display.$_l.vendor")") || return 0
  _pn=$(config_to_word "$(config_get "display.$_l.product")") || return 0
  _key=$(printf '%04X:%04X' "$_vn" "$_pn")
  _name=$(config_display_field "$_l" name '')
  if [ -z "$_name" ] && [ "$_fi" -ge 0 ]; then wt_found "$_fi"; _name=$F_NAME; fi
  [ -n "$_name" ] || _name="panel $_key"
  _map=''
  for _c in ${WT_COMPUTERS[@]+"${WT_COMPUTERS[@]}"}; do
    _val=$(config_input_for "$_l" "$_c")
    [ -n "$_val" ] && [ "$_val" != "AMBIGUOUS" ] && _map=$(map_set "$_map" "$_c" "$(printf '0x%02X' "$_val")")
  done
  wt_answer_add "$(wt_record "$_key" "$_l" "$_name" "$(config_display_field "$_l" method standard)" \
                             "$(printf '0x%04X' "$_vn")" "$(printf '0x%04X' "$_pn")" "$_map" "$_fi")"
}

# The answers, rebuilt from the loaded config: the attached panels in the order
# they are attached, then every configured panel that is not attached today
# (specs/configure.md 6). One record per identity.
wt_load_answers() {
  local _i _l
  WT_A=()
  _i=0
  while [ "$_i" -lt "${#WT_F[@]}" ]; do
    wt_found "$_i"
    if ! wt_answer_index "$F_KEY" >/dev/null && _l=$(config_label_for "$F_KEY"); then
      wt_load_answer "$_l" "$_i"
    fi
    _i=$(( _i + 1 ))
  done
  for _l in $(config_display_labels); do
    wt_labels_except '' | tr ' ' '\n' | grep -qx -- "$_l" && continue
    wt_load_answer "$_l" -1
  done
}

# --- writing -----------------------------------------------------------------

wt_write_config() {
  local _path _i _l _c _w _other
  _path=$1
  mkdir -p "$(dirname "$_path")"
  {
    echo '# trigger-kvm configuration'
    echo '#'
    echo '# Written by `trigger-kvm configure`. Safe to edit by hand.'
    echo '#'
    echo '# Everything here is read at the point it is used, so there is no separate'
    echo '# apply step: display edits take effect on the next switch, and trigger edits'
    echo '# when the watcher next starts --  trigger-kvm restart'
    echo '#'
    echo '# Displays are identified by the EDID read off the output, never by an index'
    echo '# -- display numbering is not stable. See what is attached with:'
    echo '#   trigger-kvm list'
    echo ''
    echo '# install ---------------------------------------------------------------'
    config_line 'install.autostart' "${WT_TIER:-login}"
    echo ''
    echo '# computers -------------------------------------------------------------'
    echo '# What this computer is called below. `trigger-kvm pull` means "point every'
    echo '# display at this one"; `trigger-kvm to mac` names any other.'
    echo ''
    config_line 'computer.this' "$WT_THIS"
    echo ''
    echo '# displays --------------------------------------------------------------'
    echo '# method: standard (I2C src 0x51, VCP 0x60) -- what nearly every panel takes'
    echo '#         lg-alt   (src 0x50, VCP 0xF4) -- LG panels whose 0x60 is stubbed'
    echo '# input.<value> = <computer>: which computer is on which input of that panel.'
    echo '#         This is the whole map. pull and to are the same lookup against it,'
    echo '#         differing only in which name they look up, so the two can never'
    echo '#         disagree about where a computer is.'
    echo ''
    _i=0
    while [ "$_i" -lt "${#WT_A[@]}" ]; do
      wt_rec "$_i"
      _l=$R_LABEL
      # Padded to the longest key in the block, `display.<label>.product`.
      _w=$(( 16 + ${#_l} ))
      config_line "display.$_l.vendor"  "$R_VENDOR"  "$_w"
      config_line "display.$_l.product" "$R_PRODUCT" "$_w"
      config_line "display.$_l.name"    "$R_NAME"    "$_w"
      config_line "display.$_l.method"  "$R_METHOD"  "$_w"
      # Stored, never asked: this platform has one transport (specs 6.3).
      config_line "display.$_l.transport" "$DDC_TRANSPORT" "$_w"
      for _c in $(map_computers "$R_MAP"); do
        config_line "display.$_l.input.$(tk_lower "$(map_get "$R_MAP" "$_c")")" "$_c"
      done
      echo ''
      _i=$(( _i + 1 ))
    done
    echo '# triggers --------------------------------------------------------------'
    echo '#'
    echo '# A trigger is anything that runs:  trigger-kvm pull'
    echo '# The one shipped here watches device presence. A hotkey or a Stream Deck'
    echo '# button needs no support from this tool -- it just runs that command.'
    echo '#'
    echo '# Triggers run `pull` and nothing else. Never wire one to another computer:'
    echo '# a name like `pc` describes inputs on hardware this computer cannot observe,'
    echo '# and a stale one would then be able to cause an AUTOMATIC switch to a dead'
    echo '# input. Getting there by hand, watching, is a different risk entirely.'
    echo '#'
    echo '# device: usb:VVVV:PPPP[@token[@where]] (bare VVVV:PPPP means usb) or'
    echo '#         bt:AAAAAAAAAAAA. Bluetooth fires on CONNECTED; every PAIRED device'
    echo '#         is offered.'
    echo ''
    config_line 'trigger.device'   "$(printf '%s' "${WT_DEVICES[*]+${WT_DEVICES[*]}}" | sed 's/ /, /g')" 16
    config_line 'trigger.debounce' "$(wt_keep 'trigger.debounce' '3.0')"  16
    config_line 'trigger.settle'   "$(wt_keep 'trigger.settle' '0.75')"   16
    echo ''
    # Every key the walkthrough did not write is carried across
    # (specs/config-format.md, "Hand edits survive").
    _other=$(wt_other_keys)
    if [ -n "$_other" ]; then
      echo '# --- kept from the previous file (not something configure asks about) --'
      printf '%s\n' "$_other"
      echo ''
    fi
  } > "$_path"
}

# The loaded keys wt_write_config does not itself write, as `key = value`
# lines, last duplicate winning. A display.<label>.* key is kept only while
# that panel is still managed: unmanaging is the one answer that forgets.
wt_other_keys() {
  local _k _v _l _rest _i _managed
  _managed=' '
  _i=0
  while [ "$_i" -lt "${#WT_A[@]}" ]; do wt_rec "$_i"; _managed="$_managed$R_LABEL "; _i=$(( _i + 1 )); done
  printf '%s\n' "$CONFIG_DATA" | awk -F'\t' 'NF { seen[$1] = $0 } END { for (k in seen) print seen[k] }' |
  while IFS=$'\t' read -r _k _v; do
    [ -n "$_k" ] || continue
    case $_k in
      install.autostart|computer.this|trigger.device|trigger.debounce|trigger.settle) continue ;;
      display.*)
        _rest=${_k#display.}; _l=${_rest%%.*}; _rest=${_rest#*.}
        case " $_managed " in *" $_l "*) ;; *) continue ;; esac
        case $_rest in vendor|product|name|method|transport|input.*) continue ;; esac ;;
    esac
    config_line "$_k" "$_v"
  done | sort
}

# A value the walkthrough never asks about, from the loaded config or a default.
wt_keep() {
  local _v
  _v=$(config_get "$1")
  if [ -n "$_v" ]; then printf '%s\n' "$_v"; else printf '%s\n' "$2"; fi
}
