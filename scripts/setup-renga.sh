#!/bin/bash
# Copyright 2026 The Chromium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Set up a fresh Renga install for building this branch: install the build
# packages, the npm and pip tools, and check the result. Safe to run again;
# it only installs what is missing.
#
# Usage: scripts/setup-renga.sh [--from DIR] [--save DIR]
#
#   --from DIR   install the .hpkg files in DIR first (saved from an earlier
#                install with --save), so only what is missing is downloaded
#   --save DIR   afterwards, copy the installed packages to DIR, for --from
#                on the next fresh install (keep DIR on a disk that survives
#                reinstalling Renga)
#
# Then: scripts/fetch-sources.sh, scripts/prepare-tree.sh, scripts/build.sh
# (docs/RENGA.md).

set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)

FROM= SAVE=
while [ $# -gt 0 ]; do
  case $1 in
    --from) FROM=${2:?--from needs a directory}; shift 2 ;;
    --save) SAVE=${2:?--save needs a directory}; shift 2 ;;
    *) sed -n '2,20p' "$0"; exit 2 ;;
  esac
done

# HaikuPorts packages this branch builds with. No Wayland packages: Renga's
# own renga_wayland is part of the image and is what the build uses.
PACKAGES=(
  llvm23 llvm23_clang llvm23_lld llvm23_libs rust_bin bindgen
  python3.14 setuptools_python3.14 pip_python3.14
  ninja nasm pkgconfig gperf bison flex git patch nodejs24 npm gcc haiku_devel
  libxkbcommon_devel glib2_devel nss_devel nspr_devel dbus_devel expat_devel
  cairo_devel pango_devel harfbuzz_devel fontconfig_devel freetype_devel
)

step() { printf '\n==> %s\n' "$*"; }

# --- Renga --------------------------------------------------------------------
step "Checking the system"
uname -a
if [ ! -f /boot/system/data/renga_wayland/pkgconfig/wayland-client.pc ]; then
  echo "renga_wayland is missing: this is not a Renga image, or one older than"
  echo "2026.11.14-chromium-wayland. Use 2026.11.15-chromium-readiness or later."
  exit 1
fi

# --- packages -----------------------------------------------------------------
if [ -n "$FROM" ]; then
  step "Installing saved packages from $FROM"
  shopt -s nullglob
  saved=("$FROM"/*.hpkg)
  shopt -u nullglob
  if [ ${#saved[@]} -gt 0 ]; then
    # pkgman skips what is already installed; a saved package that clashes
    # with the image is reported and the rest are still tried below.
    pkgman install -y "${saved[@]}" || echo "Some saved packages were not installed; continuing."
  else
    echo "No .hpkg files in $FROM."
  fi
fi

step "Installing build packages (pkgman)"
if ! pkgman install -y "${PACKAGES[@]}"; then
  echo "pkgman could not install the whole set at once; trying one by one."
  FAILED=()
  for p in "${PACKAGES[@]}"; do
    pkgman install -y "$p" >/dev/null 2>&1 || FAILED+=("$p")
  done
  if [ ${#FAILED[@]} -gt 0 ]; then
    echo "Could not install: ${FAILED[*]}"
    echo "Check the names with 'pkgman search -a <name>' and install by hand."
  fi
fi

# --- npm and pip tools ----------------------------------------------------------
# /boot/system is read-only; these go to ~/config/non-packaged, whose bin/ is
# on PATH. TypeScript 6 is the last JavaScript-based compiler; 7 and later
# are native Go programs without a Haiku build.
step "Installing npm tools (esbuild-wasm, typescript@6)"
npm config set prefix ~/config/non-packaged
npm install -g esbuild-wasm typescript@6 || echo "npm install failed; see above."

step "Installing the libclang Python bindings (pip)"
python3 -m pip install --user clang ||
  python3 -m pip install --user --break-system-packages clang ||
  echo "pip install failed; see above."

# --- check --------------------------------------------------------------------
step "Checking the toolchain"
bash "$HERE/scripts/detect-toolchain.sh"
toolchain=$?

step "Probing Renga's interfaces"
"$HERE/scripts/renga-tests.sh" probe | tail -12

if [ -n "$SAVE" ]; then
  step "Saving installed packages to $SAVE"
  mkdir -p "$SAVE"
  cp -u /boot/system/packages/*.hpkg "$SAVE"/ && ls "$SAVE" | wc -l | xargs echo "packages in $SAVE:"
fi

echo
if [ $toolchain -eq 0 ]; then
  echo "Ready. Next:"
  echo "  scripts/fetch-sources.sh"
  echo "  scripts/prepare-tree.sh work/chromium-156.0.8078.79"
  echo "  JOBS=10 scripts/build.sh work/chromium-156.0.8078.79"
else
  echo "Something is still missing (listed above); install it and run this again."
fi
exit $toolchain
