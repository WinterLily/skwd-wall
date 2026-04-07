#!/bin/sh
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/skwd-wall"
COLORS="$CACHE/niri-primary-color"
[ -f "$COLORS" ] || exit 0

PRIMARY=$(sed -n '1p' "$COLORS" | tr -d '[:space:]')
INACTIVE=$(sed -n '2p' "$COLORS" | tr -d '[:space:]')
[ -z "$PRIMARY" ] && exit 0

NIRI_CFG="$HOME/.config/niri/config.kdl"
[ -f "$NIRI_CFG" ] || exit 0

sed -i "s/active-color \"#[0-9a-fA-F]*\" \/\/ matugen:active-color/active-color \"#${PRIMARY}\" \/\/ matugen:active-color/g" "$NIRI_CFG"

if [ -n "$INACTIVE" ]; then
    sed -i "s/inactive-color \"#[0-9a-fA-F]*\" \/\/ matugen:inactive-color/inactive-color \"#${INACTIVE}\" \/\/ matugen:inactive-color/g" "$NIRI_CFG"
fi

niri msg action load-config-file 2>/dev/null || true
