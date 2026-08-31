#!/bin/bash
#
# Switch both monitors' inputs from this Mac.
#
#   trigger-kvm.sh mac       pull both monitors here   (the normal case)
#   trigger-kvm.sh windows   push both monitors to the PC
#
# Values are documented in ../displays.toml, which is the source of truth. They are
# duplicated here as literals rather than parsed, because this script runs from a
# LaunchAgent on every device arrival and should not depend on a TOML parser.
# If you change displays.toml, change these to match.
#
# Verified 2026-08-30 in both directions on both monitors, including from an
# INACTIVE link (monitor displaying the other machine). That is what makes
# pull-to-self work.
#
# NEVER verify a switch by reading a VCP value back — see displays.toml for why.
# Both monitors switched correctly during testing while reads said they had not.

set -uo pipefail

M1DDC=${M1DDC:-/opt/homebrew/bin/m1ddc}

# Monitor display names as reported by `m1ddc display list`
LG_NAME="LG ULTRAGEAR+"
ASUS_NAME="PG42UQ"

# LG 45GX950A — LG sidechannel (I2C src 0x50, VCP 0xF4); m1ddc `input-alt`.
LG_MAC=209        # 0xD1  USB-C
LG_WIN=208        # 0xD0  DisplayPort

# ASUS PG42UQ — standard DDC/CI VCP 0x60; m1ddc `input`.
ASUS_MAC=15       # 0x0F  DisplayPort
ASUS_WIN=17       # 0x11  HDMI 1

TRIES=${TRIES:-2}   # DDC is lossy and writes are idempotent; a repeat is free

log() { printf '%s trigger-kvm: %s\n' "$(date '+%H:%M:%S')" "$*"; }

if [[ ! -x "$M1DDC" ]]; then
  log "ERROR: m1ddc not found at $M1DDC (override with M1DDC=/path)"
  exit 1
fi

# Resolve a display's UUID by name, on every invocation. Deliberately not hardcoded,
# and deliberately NOT cached.
#
# Display ordering is not stable, and a display dropping is not the only thing that
# reorders it: on Windows the two indices were observed swapping outright -- DISPLAY1
# going from the ASUS to the LG -- across a reboot and hibernate cycle, with both
# monitors attached the whole time. Index 1 silently becoming the other monitor would
# send LG service-channel writes to the ASUS.
#
# Do not "optimize" this into a cached lookup to skip the per-switch call. The cost
# is one m1ddc invocation; a stale mapping is a service-channel write to the wrong
# panel, which is the failure this whole approach exists to prevent.
resolve_uuid() {
  local want=$1
  "$M1DDC" display list 2>/dev/null \
    | grep -F "$want" \
    | sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\)).*/\1/p' \
    | head -1
}

case "${1:-mac}" in
  mac)     lg_val=$LG_MAC; asus_val=$ASUS_MAC; label="this Mac" ;;
  windows) lg_val=$LG_WIN; asus_val=$ASUS_WIN; label="the Windows PC" ;;
  *) echo "usage: ${0##*/} [mac|windows]" >&2; exit 2 ;;
esac

lg_uuid=$(resolve_uuid "$LG_NAME")
asus_uuid=$(resolve_uuid "$ASUS_NAME")

rc=0

if [[ -n "$lg_uuid" ]]; then
  for _ in $(seq "$TRIES"); do
    "$M1DDC" display "$lg_uuid" set input-alt "$lg_val" >/dev/null 2>&1
  done
  log "LG -> $label (input-alt $lg_val)"
else
  log "WARN: '$LG_NAME' not found in display list; skipped"
  rc=1
fi

if [[ -n "$asus_uuid" ]]; then
  for _ in $(seq "$TRIES"); do
    "$M1DDC" display "$asus_uuid" set input "$asus_val" >/dev/null 2>&1
  done
  log "ASUS -> $label (input $asus_val)"
else
  log "WARN: '$ASUS_NAME' not found in display list; skipped"
  rc=1
fi

exit $rc
