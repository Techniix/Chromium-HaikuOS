#!/bin/bash
# Copyright 2026 The Chromium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Package a Chromium build from this branch as a Haiku package (.hpkg), so a
# known-good build can be reinstalled on a fresh Renga image without
# rebuilding. Run it on Renga, after scripts/build.sh.
#
# Usage: scripts/package-hpkg.sh OUT_DIR [DEST_DIR]
#
#   OUT_DIR   the build directory (work/chromium-156.0.8078.79/out/Release)
#   DEST_DIR  where the package goes (default: packages/ in this repository)
#
# Environment:
#   REVISION  package revision (an integer). Default: one more than the
#             highest revision already in DEST_DIR, so every package of the
#             same Chromium version sorts after the previous one.
#   STRIP     "all" (default), "debug" or "none": what to strip from the
#             packaged binaries. With "all" or "debug", the unstripped
#             binaries are kept next to the package, in
#             <package>-symbols/, for tools/symbolize-trace.py --dir.
#
# Install the result with:  pkgman install DEST_DIR/chromium_renga-....hpkg
# (or copy it into /boot/system/packages). It installs to
# /boot/system/apps/Chromium, with a `chromium` command and a Deskbar entry
# under Applications. The browser profile lives in
# ~/config/settings/Chromium and is not part of the package.

set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/scripts/version.sh"

OUT=${1:?usage: package-hpkg.sh OUT_DIR [DEST_DIR]}
OUT=$(cd "$OUT" && pwd)
DEST=${2:-$HERE/packages}
mkdir -p "$DEST"
DEST=$(cd "$DEST" && pwd)
STRIP=${STRIP:-all}

NAME=chromium_renga
ARCH=x86_64

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
command -v package >/dev/null || die "Haiku's 'package' tool was not found (run this on Renga)."
[ -x "$OUT/chrome" ] || die "$OUT/chrome not found; build first (scripts/build.sh)."
[ -f /boot/system/data/renga_wayland/pkgconfig/wayland-client.pc ] ||
  die "this is the Renga branch; package it on Renga with renga_wayland installed."

LLVM_STRIP=$(command -v llvm-strip || true)
READELF=$(command -v llvm-readelf || command -v readelf || true)
[ -n "$READELF" ] || die "llvm-readelf not found (needed to work out dependencies)."
if [ "$STRIP" != none ] && [ -z "$LLVM_STRIP" ]; then
  die "llvm-strip not found; install llvm, or set STRIP=none."
fi

# --- revision -------------------------------------------------------------
if [ -z "${REVISION:-}" ]; then
  REVISION=0
  for f in "$DEST/$NAME-$CHROMIUM_VERSION"-*-"$ARCH".hpkg; do
    [ -e "$f" ] || continue
    r=${f##*/$NAME-$CHROMIUM_VERSION-}; r=${r%%-*}
    case $r in *[!0-9]*|'') continue ;; esac
    [ "$r" -gt "$REVISION" ] && REVISION=$r
  done
  REVISION=$((REVISION + 1))
fi
case $REVISION in *[!0-9]*|'') die "REVISION must be an integer" ;; esac
VERSION=$CHROMIUM_VERSION-$REVISION
PKG=$DEST/$NAME-$VERSION-$ARCH.hpkg
[ -e "$PKG" ] && die "$PKG exists; pass another REVISION or remove it."

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/chromium-hpkg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
APP=$STAGE/apps/Chromium
mkdir -p "$APP" "$STAGE/bin" "$STAGE/data/deskbar/menu/Applications"

# --- files ----------------------------------------------------------------
# What Chromium loads from its own directory at run time (the same set
# chrome/installer/linux packages), whichever of these this build produced.
echo "==> Collecting files from $OUT"
copy() { [ -e "$OUT/$1" ] && cp -a "$OUT/$1" "$APP/"; return 0; }
copy chrome
copy chrome_crashpad_handler
for f in "$OUT"/*.pak "$OUT"/*.dat "$OUT"/*.bin "$OUT"/*.so "$OUT"/*.so.* \
         "$OUT"/vk_swiftshader_icd.json; do
  [ -e "$f" ] && cp -a "$f" "$APP/"
done
for d in locales MEIPreload PrivacySandboxAttestationsPreloaded; do
  [ -d "$OUT/$d" ] && cp -a "$OUT/$d" "$APP/"
done
[ -d "$APP/locales" ] || die "$OUT/locales is missing; is the build complete?"
[ -f "$APP/resources.pak" ] || die "$OUT/resources.pak is missing; is the build complete?"

# --- stripping ------------------------------------------------------------
BINARIES=("$APP/chrome")
[ -e "$APP/chrome_crashpad_handler" ] && BINARIES+=("$APP/chrome_crashpad_handler")
for f in "$APP"/*.so "$APP"/*.so.*; do [ -e "$f" ] && BINARIES+=("$f"); done

SYMBOLS=
if [ "$STRIP" != none ]; then
  SYMBOLS=$DEST/$NAME-$VERSION-$ARCH-symbols
  mkdir -p "$SYMBOLS"
  echo "==> Keeping unstripped binaries in $SYMBOLS"
  for b in "${BINARIES[@]}"; do cp -a "$b" "$SYMBOLS/"; done
  case $STRIP in
    all)   flags=--strip-all ;;
    debug) flags=--strip-debug ;;
    *)     die "STRIP must be all, debug or none" ;;
  esac
  for b in "${BINARIES[@]}"; do "$LLVM_STRIP" $flags "$b"; done
fi

# --- launcher -------------------------------------------------------------
cat > "$APP/chromium" <<'LAUNCHER'
#!/bin/bash
# Chromium for Renga (Chromium-HaikuOS, renga branch): installed launcher.
# Same flags as scripts/run-chromium.sh in the source repository; see there
# for why each one is needed.

APP=$(dirname "$(readlink -f "$0")")
export LIBRARY_PATH="$APP${LIBRARY_PATH:+:$LIBRARY_PATH}"

fail() {
  # Started from Deskbar there is no terminal: show the message in an alert.
  if [ -t 2 ]; then echo "$*" >&2; else alert --stop "$*" "OK" >/dev/null; fi
  exit 1
}

: "${XDG_RUNTIME_DIR:=/tmp/xdg-runtime}"
export XDG_RUNTIME_DIR
[ -S "$XDG_RUNTIME_DIR/${WAYLAND_DISPLAY:-wayland-0}" ] ||
  fail "Chromium needs Renga's Wayland compositor. Turn on Screen preferences > \"Show Wayland programs\" (or run 'Screen --wayland on') and start Chromium again."

PROFILE=${CHROMIUM_PROFILE:-$HOME/config/settings/Chromium}
FIRST_RUN=()
# Chromium 156 ignores xdg_toplevel.configure_bounds; give a new profile a
# first window that fits on the screen with its frame.
[ -f "$PROFILE/Default/Preferences" ] ||
  FIRST_RUN=(--window-size=1280,800 --window-position=40,40)

exec "$APP/chrome" \
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
LAUNCHER
chmod 755 "$APP/chromium"
ln -s ../apps/Chromium/chromium "$STAGE/bin/chromium"
ln -s ../../../../apps/Chromium/chromium "$STAGE/data/deskbar/menu/Applications/Chromium"

# --- build record ---------------------------------------------------------
# Enough to know exactly what this package is when it is reinstalled on a
# later Renga image.
{
  echo "Chromium $CHROMIUM_VERSION for Renga, package $NAME $VERSION"
  echo "Packaged: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Port: Techniix/Chromium-HaikuOS $(git -C "$HERE" rev-parse --abbrev-ref HEAD 2>/dev/null) $(git -C "$HERE" rev-parse HEAD 2>/dev/null)"
  if [ -n "$(git -C "$HERE" status --porcelain -- patches scripts 2>/dev/null)" ]; then
    echo "Port working tree: uncommitted changes in patches/ or scripts/"
  fi
  echo "Built on: $(uname -a)"
  echo "Renga: $(cat /boot/system/settings/renga-release 2>/dev/null || uname -v)"
  echo "Stripped: $STRIP"
  echo
  echo "args.gn:"
  sed 's/^/  /' "$OUT/args.gn" 2>/dev/null || echo "  (not found)"
} > "$APP/BUILD-INFO.txt"
cp "$HERE/LICENSE" "$APP/LICENSE"

# --- dependencies ---------------------------------------------------------
# Every library the binaries need that is not in the package itself comes
# from an installed package; packagefs names it in the SYS:PACKAGE attribute
# of the library file. Require those packages by name.
echo "==> Working out dependencies"
declare -A REQUIRES=([haiku]=1)
declare -A SHIPPED=()
for b in "${BINARIES[@]}"; do SHIPPED[$(basename "$b")]=1; done
for b in "${BINARIES[@]}"; do
  while read -r soname; do
    [ -n "${SHIPPED[$soname]:-}" ] && continue
    lib=
    for d in /boot/system/lib /boot/system/lib/x86_64; do
      [ -e "$d/$soname" ] && { lib=$d/$soname; break; }
    done
    if [ -z "$lib" ]; then
      echo "warning: $soname (needed by $(basename "$b")) is not in /boot/system/lib;" >&2
      echo "         add its package to REQUIRES_EXTRA by hand." >&2
      continue
    fi
    owner=$(catattr -d SYS:PACKAGE "$(readlink -f "$lib")" 2>/dev/null || true)
    [ -n "$owner" ] || { echo "warning: no package owns $lib" >&2; continue; }
    REQUIRES[${owner%%-*}]=1      # "nss-3.117-1-x86_64.hpkg" -> "nss"
  done < <("$READELF" -d "$b" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p')
done
for r in ${REQUIRES_EXTRA:-}; do REQUIRES[$r]=1; done
[ -n "${REQUIRES[renga_wayland]:-}" ] ||
  echo "warning: the build does not link renga_wayland; was it built on this branch?" >&2

# --- package info -----------------------------------------------------------
{
  cat <<EOF
name			$NAME
version			$VERSION
architecture		$ARCH
summary			"Chromium web browser for Renga"
description		"Chromium $CHROMIUM_VERSION built from the renga branch of \
Chromium-HaikuOS (Ozone/Wayland on Renga's compositor, software rendering). \
Development build: see /boot/system/apps/Chromium/BUILD-INFO.txt for the \
exact source state."
packager		"Techniix"
vendor			"Techniix"
copyrights		{
	"2015-2026 The Chromium Authors"
}
licenses		{
	"BSD (3-clause)"
}
provides		{
	$NAME = $VERSION
	cmd:chromium = $VERSION
}
requires		{
EOF
  for r in $(printf '%s\n' "${!REQUIRES[@]}" | sort); do printf '\t%s\n' "$r"; done
  echo "}"
} > "$STAGE/.PackageInfo"

echo "==> Creating $PKG"
package create -C "$STAGE" "$PKG"
echo
cat "$STAGE/.PackageInfo"
echo
echo "Package: $PKG ($(du -h "$PKG" | cut -f1))"
[ -n "$SYMBOLS" ] && echo "Symbols: $SYMBOLS (tools/symbolize-trace.py --dir $SYMBOLS)"
echo "Install: pkgman install $PKG"
