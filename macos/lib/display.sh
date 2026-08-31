# shellcheck shell=bash
# shellcheck disable=SC2034  # a sourced library: its variables are read by its callers

# Resolving a panel, and the one place this program can move one.
#
# IDENTITY COMES FROM THE EDID, NEVER FROM AN INDEX. m1ddc's [1]/[2] numbers
# shift when a display drops, and on Windows the two DISPLAYn numbers were
# observed swapping outright across a reboot with both monitors attached the
# whole time. Index 1 silently becoming the other monitor would send LG
# service-channel writes to the ASUS -- the exact failure this whole approach
# exists to prevent. So every switch resolves afresh, and nothing is cached.
#
# Note that the LG reports a DIFFERENT product id per input -- 0x9E9D on its DP
# input, 0x9E9F on USB-C. Each host sees a stable value for its own cable, so it
# works as a LOCAL key; copying one host's value to another matches nothing.

# 0x1E6D. GSM / LG Electronics -- the one vendor whose panels may be sent the
# service channel. See the gate in ddc_send.
DDC_VENDOR_GSM=7789

# 0x50 is LG's service/factory channel. Sweeping it has bricked LG monitors --
# the ddcutil repo carries an issue titled "Bricked LG Monitor" -- and what it
# means on another vendor's panel is unknown.
DDC_SOURCE_STANDARD=0x51
DDC_SOURCE_LG=0x50
DDC_VCP_STANDARD=0x60
DDC_VCP_LG=0xF4

M1DDC=${M1DDC:-/opt/homebrew/bin/m1ddc}

# DDC is lossy and these writes are idempotent, so a repeat is free. Never a
# READ to decide whether to repeat: reads lie on both panels here.
TK_TRIES=${TK_TRIES:-2}

# --- enumeration -------------------------------------------------------------

# Every attached display, as "vendor|product|mfg|connector|serial|uuid|name"
# with vendor and product in uppercase hex. See display-probe.c.
display_enumerate() {
  if [ ! -x "$TK_PROBE" ]; then
    tk_log "REFUSING: display-probe not found at $TK_PROBE"
    return 1
  fi
  "$TK_PROBE"
}

display_field() { printf '%s\n' "$1" | cut -d'|' -f"$2"; }

# A one-line description of a row, for a refusal message.
display_describe() {
  printf 'edid=0x%s:0x%s connector=%s serial=0x%s' \
    "$(display_field "$1" 1)" "$(display_field "$1" 2)" \
    "$(display_field "$1" 4)" "$(display_field "$1" 5)"
}

# Find the ONE attached display whose EDID matches, printing its row. Prints
# nothing and returns non-zero otherwise.
#
# Fails closed on both sides of "exactly one". Zero is a refusal for the obvious
# reason. More than one is also a refusal: an ambiguous target cannot be aimed
# at, and taking the first would reintroduce exactly the order-dependence the
# EDID matching exists to remove.
display_resolve() {
  local _want_v _want_p _name _all _hex _match _n _seen _r
  _want_v=$1 _want_p=$2 _name=$3

  _all=$(display_enumerate) || return 1
  _hex=$(printf '%04X|%04X' "$_want_v" "$_want_p")
  _match=$(printf '%s\n' "$_all" | grep -F "$_hex|" || true)

  # Written as an `if` rather than `[ ... ] && ...`: under `set -e` a trailing
  # && list that evaluates false is a non-zero return and kills the script.
  _n=0
  if [ -n "$_match" ]; then _n=$(printf '%s\n' "$_match" | wc -l | tr -d ' '); fi

  if [ "$_n" = "1" ]; then printf '%s\n' "$_match"; return 0; fi

  if [ "$_n" = "0" ]; then
    _seen="nothing"
    if [ -n "$_all" ]; then
      _seen=$(printf '%s\n' "$_all" | while IFS= read -r _r; do display_describe "$_r"; printf '; '; done)
    fi
    tk_log "REFUSING $_name switch: no display identifies as it (EDID 0x$(printf '%04X' "$_want_v"):0x$(printf '%04X' "$_want_p")). Attached: $_seen"
  else
    tk_log "REFUSING $_name switch: $_n displays identify as it, so the target is ambiguous"
  fi
  return 1
}

# --- the packet --------------------------------------------------------------

# A DDC/CI SetVCP message: [source, 0x84, 0x03, vcp, 0x00, value, checksum],
# checksum = 0x6E XOR every preceding byte. These are the bytes documented in
# ../displays.toml, and `pull --dry-run` prints them rather than sending.
#
# m1ddc builds this packet itself; this is here so a dry run can show exactly
# what is about to go on the wire, and so a test can assert the bytes against
# displays.toml without a monitor being present.
ddc_packet() {
  local _src _vcp _val _sum
  _src=$(( $1 )) _vcp=$(( $2 )) _val=$(( $3 ))
  _sum=$(( 0x6E ^ _src ^ 0x84 ^ 0x03 ^ _vcp ^ 0x00 ^ _val ))
  printf '%02X %02X %02X %02X %02X %02X %02X\n' \
    "$_src" 132 3 "$_vcp" 0 "$_val" "$_sum"
}

# The packet a given method and value produce, for logging and dry runs.
ddc_packet_for() {
  case $1 in
    lg-alt)   ddc_packet "$DDC_SOURCE_LG" "$DDC_VCP_LG" "$2" ;;
    standard) ddc_packet "$DDC_SOURCE_STANDARD" "$DDC_VCP_STANDARD" "$2" ;;
    *)        return 1 ;;
  esac
}

# --- the one place a monitor moves ------------------------------------------

# Send one input-select write to ONE resolved display.
#
# THIS IS THE ONLY FUNCTION IN THIS PROGRAM THAT RUNS m1ddc, and the only place
# the string `input-alt` appears. Both facts are deliberate, and they are the
# same fact: the vendor gate sits in the same function as the sidechannel, so
# there is no path to source 0x50 that skips the check. There is no generic
# "write value V on channel C" entry point for a caller to reach around it, and
# the channel is chosen here from the method rather than handed in as a source
# byte -- which is the shape AGENTS.md hard rule 5 asks for, a gate a caller
# cannot pass around rather than a check a caller is asked to perform.
#
# Setting method = lg-alt on a non-LG panel therefore makes the write REFUSE. It
# does not make the write happen.
#
# It is also the single thing the test harness stands in for, which is what
# keeps the suite from moving a developer's own monitors.
ddc_send() {
  local _uuid _vendor _method _value _what _sub _ok _i
  _uuid=$1 _vendor=$2 _method=$3 _value=$4 _what=$5

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

  # A success here means the write was SENT, not that the monitor switched.
  # There is no way to learn the latter from software on this hardware: reads
  # lie on both of these panels. Confirm by looking at the screen.
  tk_log "$_what"
  return 0
}

# One configured display, one input value. The method decides which channel is
# used and that is the ONLY thing it changes -- resolution, aiming, retry and
# logging are identical either way.
display_switch() {
  local _label _value _dry _vraw _praw _name _method _vendor _product _row
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

  _row=$(display_resolve "$_vendor" "$_product" "$_name") || return 1
  _uuid=$(display_field "$_row" 6)

  if ! _packet=$(ddc_packet_for "$_method" "$_value"); then
    tk_log "REFUSING $_label: unknown method '$_method'. Use 'standard' or 'lg-alt'."
    return 1
  fi

  case $_method in
    lg-alt)   _chan="src $DDC_SOURCE_LG, VCP $DDC_VCP_LG" ;;
    *)        _chan="src $DDC_SOURCE_STANDARD, VCP $DDC_VCP_STANDARD" ;;
  esac
  _what=$(printf '%s -> %s = 0x%02X on %s [%s]' "$_name" "$_chan" "$_value" "$_uuid" "$_packet")

  if [ "$_dry" = "1" ]; then
    tk_log "DRY RUN: would send $_what"
    return 0
  fi

  ddc_send "$_uuid" "$_vendor" "$_method" "$_value" "$_what"
}
