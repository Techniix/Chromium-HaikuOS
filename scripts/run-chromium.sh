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

PROFILE=$HOME/config/settings/Chromium-dev
FIRST_RUN=()
# Chromium sizes its first window to the screen, but the Haiku window frame
# (tab and borders) is drawn outside that size, so the bottom-right corner
# ends up off screen. Give a new profile a size that fits; later runs use
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
  --disable-quic \
  --user-data-dir="$PROFILE" \
  "${FIRST_RUN[@]}" \
  "$@"

# Why each flag:
#   --no-sandbox            Haiku has no kernel sandbox; the shared FreeBSD
#                           SandboxLinux is a no-op without this anyway.
#   --ozone-platform=wayland  windows go through Haiku's Wayland layer.
#   --disable-gpu*          that layer has no EGL/dma-buf yet: draw with
#                           Skia in software and hand frames over in wl_shm.
#   --no-zygote             the zygote (fork server) depends on the Linux
#                           sandbox; processes are launched directly.
#   --password-store=basic  no keyring/D-Bus on Haiku.
#   --disable-quic          stock Haiku refuses sendmsg() with control
#                           messages on UDP sockets (EOPNOTSUPP), so QUIC
#                           requests fail; HTTP/2 over TCP is used instead.
#   --user-data-dir         keep the profile in Haiku's settings directory.
