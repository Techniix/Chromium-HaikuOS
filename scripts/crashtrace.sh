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
#        scripts/crashtrace.sh --self-test
#   The trace goes to stderr and to logs/crash-YYYYMMDD-HHMMSS.txt; the
#   symbolized version to logs/crash-YYYYMMDD-HHMMSS-symbolized.txt.
#   --self-test runs a small program that crashes on purpose, to check that
#   preloading and the handler work on this system.
#   CRASHTRACE_ALLOW=1 lets the program install its own crash handlers.

set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
[ $# -gt 0 ] || { sed -n '2,14p' "$0"; exit 2; }

mkdir -p "$HERE/logs"
LIB=$HERE/logs/libcrashtrace.so
if [ ! -f "$LIB" ] || [ "$HERE/tools/crashtrace.c" -nt "$LIB" ]; then
  clang -shared -fPIC -O1 -g -D_GNU_SOURCE -o "$LIB" \
      "$HERE/tools/crashtrace.c" -lgnu || exit 1
fi

if [ "$1" = --self-test ]; then
  cat > "$HERE/logs/crashtest.c" <<'C'
#include <stdio.h>
__attribute__((noinline)) static void crash_here(volatile int* p) { *p = 1; }
__attribute__((noinline)) void crashtest_outer(volatile int* p) { crash_here(p); }
int main(void) { puts("crashtest: about to crash"); crashtest_outer((volatile int*)8); return 0; }
C
  clang -O1 -g -o "$HERE/logs/crashtest" "$HERE/logs/crashtest.c" || exit 1
  set -- "$HERE/logs/crashtest"
  echo "Expected: a trace whose crashing instruction is crash_here (crashtest.c:2)."
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
elif [ "$rc" -eq 127 ]; then
  echo
  echo "The command was not found (exit status 127). Run this from the"
  echo "directory the program is in, or give its full path."
elif ! grep -q 'crashtrace: loaded' "$OUT"; then
  echo
  echo "crashtrace was not loaded into the program (exit status $rc): this"
  echo "system did not honour LD_PRELOAD for it. Log: $OUT"
else
  echo
  echo "crashtrace was loaded but caught no crash (exit status $rc). If the"
  echo "program died anyway, it was killed before its signal handler could"
  echo "run. Log: $OUT"
fi
exit $rc
