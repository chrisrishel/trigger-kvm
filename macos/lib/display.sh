# shellcheck shell=bash
# shellcheck disable=SC2034  # a sourced library: its variables are read by its callers

# Resolving a panel, and the one place this program can move one.
#
# Identity is the EDID vendor:product read off the output on every invocation,
# never an index: m1ddc's numbers shift when a display drops, and index 1
# becoming the other monitor would aim LG service-channel writes at the ASUS.

# 0x1E6D, GSM / LG Electronics: the one vendor that may be sent source 0x50.
DDC_VENDOR_GSM=7789

# 0x50 is LG's service channel. Sweeping it has bricked LG monitors, and what it
# means on another vendor's panel is unknown.
DDC_SOURCE_STANDARD=0x51
DDC_SOURCE_LG=0x50
DDC_VCP_STANDARD=0x60
DDC_VCP_LG=0xF4

# `method` is what is sent; `transport` is how it gets there. This platform has
# one transport, named after the API m1ddc reaches panels through, and a
# config naming another is a config for a different machine.
DDC_TRANSPORT=ioavservice

M1DDC=${M1DDC:-/opt/homebrew/bin/m1ddc}

# DDC is lossy and these writes are idempotent, so each is sent twice. Never a
# read to decide whether to repeat: reads lie on this hardware.
TK_TRIES=${TK_TRIES:-2}

# --- enumeration -------------------------------------------------------------

# Every attached display as "vendor|product|mfg|connector|serial|uuid|name",
# vendor and product in upper-case hex. See display-probe.c.
display_enumerate() {
  if [ ! -x "$TK_PROBE" ]; then
    tk_log "REFUSING: display-probe not found at $TK_PROBE"
    return 1
  fi
  "$TK_PROBE"
}

display_field() { printf '%s\n' "$1" | cut -d'|' -f"$2"; }

# How many attached displays answer to one identity ("VVVV:PPPP"). One
# definition for the list, the walkthrough and `status`.
display_identity_count() {
  printf '%s\n' "$1" | cut -d'|' -f1,2 | tr '|' ':' | grep -cxF "$2" || true
}

display_describe() {
  printf 'edid=0x%s:0x%s connector=%s serial=0x%s' \
    "$(display_field "$1" 1)" "$(display_field "$1" 2)" \
    "$(display_field "$1" 4)" "$(display_field "$1" 5)"
}

# The ONE attached display whose EDID matches, as its row. Zero matches is a
# refusal; so is more than one, because an ambiguous target cannot be aimed at.
display_resolve() {
  local _want_v _want_p _name _all _v _p _match _n _seen _r
  _want_v=$1 _want_p=$2 _name=$3

  _all=$(display_enumerate) || return 1
  _v=$(printf '%04X' "$_want_v"); _p=$(printf '%04X' "$_want_p")
  _match=$(printf '%s\n' "$_all" | awk -F'|' -v v="$_v" -v p="$_p" '$1 == v && $2 == p')

  _n=0
  if [ -n "$_match" ]; then _n=$(printf '%s\n' "$_match" | wc -l | tr -d ' '); fi

  if [ "$_n" = "1" ]; then printf '%s\n' "$_match"; return 0; fi

  if [ "$_n" = "0" ]; then
    _seen="nothing"
    if [ -n "$_all" ]; then
      _seen=$(printf '%s\n' "$_all" | while IFS= read -r _r; do display_describe "$_r"; printf '; '; done)
    fi
    tk_log "REFUSING $_name switch: no display identifies as it (EDID 0x$_v:0x$_p). Attached: $_seen"
  else
    tk_log "REFUSING $_name switch: $_n displays identify as it, so the target is ambiguous"
  fi
  return 1
}

# --- the packet --------------------------------------------------------------

# A DDC/CI SetVCP message: [source, 0x84, 0x03, vcp, 0x00, value, checksum],
# checksum = 0x6E XOR every preceding byte. m1ddc builds this itself; it is
# here so a dry run can show the bytes and a test can pin them to
# ../displays.toml without a monitor.
ddc_packet() {
  local _src _vcp _val _sum
  _src=$(( $1 )) _vcp=$(( $2 )) _val=$(( $3 ))
  _sum=$(( 0x6E ^ _src ^ 0x84 ^ 0x03 ^ _vcp ^ 0x00 ^ _val ))
  printf '%02X %02X %02X %02X %02X %02X %02X\n' \
    "$_src" 132 3 "$_vcp" 0 "$_val" "$_sum"
}

ddc_packet_for() {
  case $1 in
    lg-alt)   ddc_packet "$DDC_SOURCE_LG" "$DDC_VCP_LG" "$2" ;;
    standard) ddc_packet "$DDC_SOURCE_STANDARD" "$DDC_VCP_STANDARD" "$2" ;;
    *)        return 1 ;;
  esac
}

# --- the one place a monitor moves ------------------------------------------

# Send one input-select write to one resolved display, or print it on a dry run.
#
# THE ONLY FUNCTION THAT RUNS m1ddc AND THE ONLY LINE THAT NAMES `input-alt`
# (m1ddc's spelling of source 0x50). The channel is chosen here from the
# method, never passed in, and the vendor gate sits in front of it, so no
# caller can aim the service channel at another vendor's panel: method = lg-alt
# on a non-LG panel makes the write refuse. A dry run passes the gate first.
ddc_send() {
  local _uuid _vendor _method _value _what _dry _sub _ok _i
  _uuid=$1 _vendor=$2 _method=$3 _value=$4 _what=$5 _dry=${6:-0}

  case $_method in
    standard)
      _sub=input
      ;;
    lg-alt)
      if [ "$_vendor" != "$DDC_VENDOR_GSM" ]; then
        tk_log "REFUSING to send the LG service channel (I2C source $DDC_SOURCE_LG, VCP $DDC_VCP_LG) to a non-LG panel: $_what. Only EDID vendor 0x1E6D may receive it."
        return 1
      fi
      _sub=input-alt
      ;;
    *)
      tk_log "REFUSING $_what: unknown method '$_method'. Use 'standard' or 'lg-alt'."
      return 1
      ;;
  esac

  if [ "$_dry" = "1" ]; then
    tk_log "DRY RUN: would send $_what"
    return 0
  fi

  if [ ! -x "$M1DDC" ]; then
    tk_log "REFUSING $_what: m1ddc not found at $M1DDC (override with M1DDC=/path)"
    return 1
  fi

  _ok=0
  _i=0
  while [ "$_i" -lt "$TK_TRIES" ]; do
    if "$M1DDC" display "$_uuid" set "$_sub" "$_value" >/dev/null 2>&1; then
      _ok=$(( _ok + 1 ))
    fi
    _i=$(( _i + 1 ))
  done

  if [ "$_ok" = "0" ]; then
    tk_log "ERROR: $_what -- m1ddc reported failure on every attempt"
    return 1
  fi

  # Sent, not switched: only a person looking at the screen knows the latter.
  tk_log "$_what"
  return 0
}

# One configured display, one input value. Everything is checked before the
# display is resolved, so a config for another machine never reaches hardware.
display_switch() {
  local _label _value _dry _vraw _praw _name _method _transport _vendor _product _row
  local _uuid _packet _chan _what
  _label=$1 _value=$2 _dry=$3

  _vraw=$(config_get "display.$_label.vendor")
  _praw=$(config_get "display.$_label.product")
  _name=$(config_display_field "$_label" name "$_label")
  _method=$(tk_lower "$(config_display_field "$_label" method standard)")

  if ! _vendor=$(config_to_word "$_vraw") || ! _product=$(config_to_word "$_praw"); then
    tk_log "REFUSING $_label: its config has no usable EDID vendor/product. Fix display.$_label.vendor and .product."
    return 1
  fi

  # Refused by name, never defaulted: absent means this transport, a name
  # asserts a machine this is not (specs/config-format.md).
  _transport=$(tk_lower "$(config_display_field "$_label" transport "$DDC_TRANSPORT")")
  if [ "$_transport" != "$DDC_TRANSPORT" ]; then
    tk_log "REFUSING $_label: transport '$_transport' does not exist on this platform. macOS has one, '$DDC_TRANSPORT'. Fix display.$_label.transport, or remove the line to mean this one."
    return 1
  fi

  if ! _packet=$(ddc_packet_for "$_method" "$_value"); then
    tk_log "REFUSING $_label: unknown method '$_method'. Use 'standard' or 'lg-alt'."
    return 1
  fi

  _row=$(display_resolve "$_vendor" "$_product" "$_name") || return 1
  _uuid=$(display_field "$_row" 6)

  case $_method in
    lg-alt)   _chan="src $DDC_SOURCE_LG, VCP $DDC_VCP_LG" ;;
    *)        _chan="src $DDC_SOURCE_STANDARD, VCP $DDC_VCP_STANDARD" ;;
  esac
  _what=$(printf '%s -> %s = 0x%02X on %s [%s]' "$_name" "$_chan" "$_value" "$_uuid" "$_packet")

  ddc_send "$_uuid" "$_vendor" "$_method" "$_value" "$_what" "$_dry"
}
