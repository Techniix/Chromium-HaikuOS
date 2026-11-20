#!/bin/bash
# Copyright 2026 The Chromium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Continue development in an existing, already built Chromium tree after a
# fresh Renga install, without preparing or building from scratch.
#
# Keep this repository and its work/ directory on a disk that survives
# reinstalling Renga, at the same path. Then, on the new install:
#
#   cd /path/to/Chromium-HaikuOS
#   git pull
#   scripts/resume-dev.sh [--packages DIR] [--from COMMIT] [--accept PATH]...
#   JOBS=10 scripts/build.sh work/chromium-156.0.8078.79
#
# What it does, in order:
#   1. installs the build packages, npm and pip tools (scripts/setup-renga.sh,
#      with --from DIR when --packages DIR is given) and checks them;
#   2. checks that the tree is where it was built (build files hold absolute
#      paths);
#   3. links the reinstalled tools into the tree again (scripts/link-tools.sh;
#      unchanged links are left alone);
#   4. brings the tree's Haiku patches up to this checkout's
#      (tools/update-tree.py), rewriting only the files whose result changes;
#   5. compares the toolchain with the one the last build used
#      (out/Release/.renga-build-env) and, if only Haiku's system headers
#      are newer, marks the outputs that are stale only because of them as
#      current (tools/skip-sysheader-rebuild.sh), so ninja rebuilds what
#      really changed.
#
# Options:
#   --src DIR       the tree (default: work/chromium-156.0.8078.79)
#   --out DIR       build directory inside it (default: out/Release)
#   --packages DIR  saved .hpkg files to install first (setup-renga.sh --save)
#   --from COMMIT   port commit whose patches the tree has, for trees prepared
#                   before prepare-tree.sh recorded it in .haiku-port-commit
#   --accept PATH   passed to tools/update-tree.py: leave PATH as it is
#   --skip-setup    do not install packages (they are installed already)
#   --dry-run       report what step 4 would change, change nothing

set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)

SRC=$HERE/work/chromium-156.0.8078.79
OUT=out/Release
PACKAGES= FROM= SKIP_SETUP= DRY_RUN=
ACCEPT=()
while [ $# -gt 0 ]; do
  case $1 in
    --src)        SRC=$2; shift 2 ;;
    --out)        OUT=$2; shift 2 ;;
    --packages)   PACKAGES=$2; shift 2 ;;
    --from)       FROM=$2; shift 2 ;;
    --accept)     ACCEPT+=(--accept "$2"); shift 2 ;;
    --skip-setup) SKIP_SETUP=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    *) sed -n '2,42p' "$0"; exit 2 ;;
  esac
done

step() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -d "$SRC" ] || die "$SRC does not exist (use --src)"
SRC=$(cd "$SRC" && pwd)
[ -f "$SRC/.haiku-prepared" ] || die "$SRC was never prepared; use prepare-tree.sh"
ENV_FILE=$SRC/$OUT/.renga-build-env

# --- 1. packages ----------------------------------------------------------------
if [ -z "$SKIP_SETUP" ]; then
  step "Installing the build tools"
  if [ -n "$PACKAGES" ]; then
    "$HERE/scripts/setup-renga.sh" --from "$PACKAGES" || die "setup-renga.sh reported missing tools"
  else
    "$HERE/scripts/setup-renga.sh" || die "setup-renga.sh reported missing tools"
  fi
fi
. "$HERE/scripts/detect-toolchain.sh" >/dev/null || die "toolchain incomplete"
# As in build.sh, in case ninja reruns gn below.
export RUSTC_BOOTSTRAP=1
export PKG_CONFIG_PATH="/boot/system/data/renga_wayland/pkgconfig:$HERE/prebuilt/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# --- 2. location ----------------------------------------------------------------
step "Checking the tree"
echo "tree: $SRC ($(cat "$SRC/.haiku-prepared"))"
if [ -f "$ENV_FILE" ]; then
  built_src=$(sed -n 's/^src=//p' "$ENV_FILE")
  if [ -n "$built_src" ] && [ "$built_src" != "$SRC" ]; then
    die "the tree was built at $built_src and is now at $SRC. Build files hold
absolute paths: move it back (or mount the volume at the same place)."
  fi
else
  echo "No $OUT/.renga-build-env (the last build predates it, or never finished);"
  echo "toolchain changes cannot be checked."
fi

# --- 3. tool links ---------------------------------------------------------------
step "Linking tools into the tree"
. "$HERE/scripts/link-tools.sh"

# --- 4. patches ------------------------------------------------------------------
step "Updating the tree's Haiku patches"
if [ -z "$FROM" ] && [ -f "$SRC/.haiku-port-commit" ]; then
  FROM=$(cat "$SRC/.haiku-port-commit")
fi
if [ -z "$FROM" ]; then
  die "the tree does not record which port commit its patches come from.
Pass --from COMMIT: the commit you ran prepare-tree.sh at (git log shows it;
for the first Renga build of 2026-11-18 it is 2191962)."
fi
python3 "$HERE/tools/update-tree.py" "$SRC" --from "$FROM" \
    --clang-resource-dir "$CLANG_RESOURCE_DIR" ${DRY_RUN:+--dry-run} "${ACCEPT[@]}"
case $? in
  0) ;;
  *) die "some files conflict (listed above). Check them; if a file already has
the fix in other words, rerun with --accept PATH for it." ;;
esac
[ -n "$DRY_RUN" ] && { echo; echo "Dry run: nothing changed."; exit 0; }

# --- 5. toolchain ----------------------------------------------------------------
step "Comparing the toolchain with the last build"
if [ -f "$ENV_FILE" ]; then
  pkgver() { ls /boot/system/packages 2>/dev/null | grep -m1 "^$1-" || echo "?"; }
  now_clang=$("$CLANG" --version | head -1)
  now_rustc=$("$RUSTC" --version)
  now_hd=$(pkgver haiku_devel)
  was() { sed -n "s/^$1=//p" "$ENV_FILE"; }
  compiler_changed=
  if [ "$(was clang)" != "$now_clang" ]; then
    echo "clang changed: $(was clang) -> $now_clang"; compiler_changed=1
  fi
  if [ "$(was rustc)" != "$now_rustc" ]; then
    echo "rustc changed: $(was rustc) -> $now_rustc"; compiler_changed=1
  fi
  if [ -n "$compiler_changed" ]; then
    echo "A different compiler is a real change: expect most of the tree to"
    echo "rebuild (Rust code certainly will). To avoid it, install the same"
    echo "versions as before (setup-renga.sh --from with the saved packages)."
  elif [ "$(was haiku_devel)" != "$now_hd" ]; then
    echo "Haiku's system headers changed: $(was haiku_devel) -> $now_hd"
    echo "Marking outputs that are stale only because of them as current."
    built=$(date -d "$(was built)" +%s 2>/dev/null || stat -c %Y "$ENV_FILE")
    SRC=$SRC OUT=$OUT bash "$HERE/tools/skip-sysheader-rebuild.sh" "@$built" ||
      echo "skip-sysheader-rebuild.sh failed; the next build may rebuild more than needed."
  else
    echo "Same compilers and system headers as the last build."
  fi
else
  echo "(no record of the last build; skipped)"
fi

echo
echo "Ready. Continue with:"
echo "  JOBS=10 scripts/build.sh ${SRC#$HERE/}"
