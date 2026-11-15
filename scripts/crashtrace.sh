#!/bin/bash
# Copyright 2026 The Chromium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Run a command with tools/crashtrace.c preloaded, so that a crash prints a
# stack trace (and the crashing instruction) instead of just "Segmentation
# violation", then symbolize the trace. Use it when Haiku's Debugger cannot
# catch a crash.
#
# Usage: scripts/crashtrace.sh COMMAND [ARGS...]
#   The trace goes to stderr and to logs/crash-YYYYMMDD-HHMMSS.txt; the
#   symbolized version to logs/crash-YYYYMMDD-HHMMSS-symbolized.txt.

set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
[ $# -gt 0 ] || { sed -n '2,14p' "$0"; exit 2; }

mkdir -p "$HERE/logs"
LIB=$HERE/logs/libcrashtrace.so
if [ ! -f "$LIB" ] || [ "$HERE/tools/crashtrace.c" -nt "$LIB" ]; then
  clang -shared -fPIC -O1 -g -D_GNU_SOURCE -o "$LIB" \
      "$HERE/tools/crashtrace.c" -lgnu || exit 1
fi

STAMP=$(date +%Y%m%d-%H%M%S)
OUT=$HERE/logs/crash-$STAMP.txt
{
  echo "# crashtrace $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# system: $(uname -a)"
  echo "# port: $(git -C "$HERE" rev-parse --abbrev-ref HEAD 2>/dev/null) $(git -C "$HERE" rev-parse --short HEAD 2>/dev/null)"
  echo "# cwd: $PWD"
  echo "# command: $*"
} > "$OUT"

CRASHTRACE_LOG=$OUT LD_PRELOAD=$LIB "$@"
rc=$?
echo "# exit status: $rc" >> "$OUT"

if grep -q '==== crashtrace' "$OUT"; then
  # Images named without a directory are looked up in the command's directory.
  python3 "$HERE/tools/symbolize-trace.py" --dir "$(dirname "$(command -v "$1" || echo "$1")")" \
      --dir "$PWD" "$OUT" > "${OUT%.txt}-symbolized.txt"
  echo
  echo "Crash trace: ${OUT%.txt}-symbolized.txt (raw: $OUT)"
else
  echo
  echo "No crash was caught (exit status $rc). If the program crashed anyway,"
  echo "it handles the signal itself. Log: $OUT"
fi
exit $rc
