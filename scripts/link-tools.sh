#!/bin/bash
# Copyright 2026 The Chromium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Link the system's tools into a prepared Chromium tree where Chromium
# expects its own Linux prebuilts (node, rustc, gperf, esbuild, tsc,
# clang-format), and write the tsc wrapper. Part of prepare-tree.sh; run it
# by itself after a fresh Renga install, when the tools are installed again
# (scripts/resume-dev.sh does).
#
# Usage: scripts/link-tools.sh SRC_DIR
#   (or sourced, with SRC and the detect-toolchain.sh variables set)
#
# A link or wrapper is rewritten only when it would change, so an unchanged
# tool keeps its timestamp and ninja does not rerun the steps that use it.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  HERE=$(cd "$(dirname "$0")/.." && pwd)
  SRC=${1:?usage: link-tools.sh SRC_DIR}
  SRC=$(cd "$SRC" && pwd)
  . "$HERE/scripts/detect-toolchain.sh" >/dev/null
fi

link() { # target path-in-tree
  local dst=$SRC/$2
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$1" ]; then
    echo "$2 -> $1 (unchanged)"
    return
  fi
  mkdir -p "$(dirname "$dst")"
  ln -sfn "$1" "$dst"
  echo "$2 -> $1"
}

write_if_changed() { # path content
  if [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; then
    return 1
  fi
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1"
  return 0
}

link "$NODE"   third_party/node/haiku/node-haiku/bin/node
link "$RUSTC"  third_party/rust-toolchain/bin/rustc
link "$GPERF"  third_party/gperf/cipd/bin/gperf
link "$ESBUILD" third_party/devtools-frontend/src/third_party/esbuild/esbuild
if [ -n "${TSGO:-}" ]; then
  link "$TSGO" third_party/typescript/linux-amd64/src/lib/tsc
elif [ -n "${TSC:-}" ]; then
  # No tsgo (a Go program) on Haiku: run the JavaScript TypeScript compiler
  # (npm install -g typescript@6) through a wrapper. Its version differs from
  # the tsgo pinned by Chromium, so type errors are reported but do not stop
  # the build; the emitted JavaScript is what matters.
  w=$SRC/third_party/typescript/linux-amd64/src/lib/tsc
  [ -L "$w" ] && rm -f "$w"
  if write_if_changed "$w" "#!/bin/sh
# Written by scripts/link-tools.sh: tsgo stand-in for Haiku.
\"$TSC\" \"\$@\" --noEmitOnError false
rc=\$?
# 1 and 2 mean type errors (output still emitted with --noEmitOnError false);
# anything else means tsc itself did not run, and the build must stop here
# rather than fail later on missing JavaScript files.
case \$rc in
  0) ;;
  1|2) echo \"tsc wrapper: ignoring type errors (exit \$rc, TypeScript version skew)\" >&2 ;;
  *) echo \"tsc wrapper: $TSC failed with exit \$rc\" >&2; exit \$rc ;;
esac
exit 0"; then
    echo "third_party/typescript/linux-amd64/src/lib/tsc -> wrapper around $TSC"
  else
    echo "third_party/typescript/linux-amd64/src/lib/tsc -> wrapper around $TSC (unchanged)"
  fi
  chmod +x "$w"
fi
# FFmpeg picks its generated configuration by OS name; Haiku uses Linux's,
# as FreeBSD does for itself.
for brand in Chrome Chromium; do
  link linux "third_party/ffmpeg/chromium/config/$brand/haiku"
done
if [ -n "${CLANG_FORMAT:-}" ]; then
  link "$CLANG_FORMAT" buildtools/haiku/clang-format
  link "$CLANG_FORMAT" buildtools/linux64/clang-format
fi
