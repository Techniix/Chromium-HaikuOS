#!/bin/bash
# Copyright 2026 The Chromium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Launch a Haiku Chromium build with the flags the initial port needs.
# Usage: scripts/run-chromium.sh OUT_DIR [extra chrome flags ...]

set -euo pipefail

OUT=${1:?usage: run-chromium.sh OUT_DIR [flags ...]}
shift
OUT=$(cd "$OUT" && pwd)

# Haiku's runtime loader searches LIBRARY_PATH (not LD_LIBRARY_PATH).
export LIBRARY_PATH="$OUT${LIBRARY_PATH:+:$LIBRARY_PATH}"

# Renga: windows go to Renga's Wayland compositor through its socket,
# $XDG_RUNTIME_DIR/${WAYLAND_DISPLAY:-wayland-0}. Renga sets XDG_RUNTIME_DIR
# at login; the compositor runs while Screen preferences > "Show Wayland
# programs" is on.
: "${XDG_RUNTIME_DIR:=/tmp/xdg-runtime}"
export XDG_RUNTIME_DIR
WL_SOCKET=$XDG_RUNTIME_DIR/${WAYLAND_DISPLAY:-wayland-0}
if [ ! -S "$WL_SOCKET" ]; then
  echo "No Wayland compositor socket at $WL_SOCKET." >&2
  echo "Turn on Screen preferences > \"Show Wayland programs\" (or run" >&2
  echo "'Screen --wayland on') and try again." >&2
  exit 1
fi

PROFILE=$HOME/config/settings/Chromium-dev
FIRST_RUN=()
# Chromium sizes its first window to the screen, but the window frame (tab
# and borders) is drawn outside that size, so the bottom-right corner ends up
# off screen. Renga's compositor now sends xdg_toplevel.configure_bounds,
# but Chromium 156 ignores it (XdgToplevel::OnConfigureBounds is
# NOTIMPLEMENTED), so give a new profile a size that fits; later runs use
# the size Chromium remembers.
[ -f "$PROFILE/Default/Preferences" ] || FIRST_RUN=(--window-size=1280,800 --window-position=40,40)

exec "$OUT/chrome" \
  --no-sandbox \
  --no-zygote \
  --ozone-platform=wayland \
  --disable-gpu \
  --disable-gpu-compositing \
  --disable-features=Vulkan \
  --password-store=basic \
  --user-data-dir="$PROFILE" \
  "${FIRST_RUN[@]}" \
  "$@"

# Why each flag:
#   --no-sandbox            no kernel sandbox yet (Renga phase G); the shared FreeBSD
#                           SandboxLinux is a no-op without this anyway.
#   --ozone-platform=wayland  windows go through Haiku's Wayland layer.
#   --disable-gpu*          that layer has no EGL/dma-buf yet: draw with
#                           Skia in software and hand frames over in wl_shm.
#   --no-zygote             the zygote (fork server) depends on the Linux
#                           sandbox; processes are launched directly.
#   --password-store=basic  no keyring/D-Bus on Haiku.
#   (no --disable-quic)     Renga accepts sendmsg() with control messages
#                           and the ECN/PKTINFO options QUIC uses; pass
#                           --disable-quic yourself to compare with HTTP/2.
#   --user-data-dir         keep the profile in Haiku's settings directory.
