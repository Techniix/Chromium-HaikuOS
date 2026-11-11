#!/bin/bash
# Chromium-HaikuOS: fix for the link failures in build11.log (pass 12).
# sched_getaffinity / pthread_getaffinity_np live in Haiku's libgnu, which
# nothing links. Make the build's existing "-lm" also pull in libgnu, via a
# linker script in build/config/haiku/compat/lib. That changes no compile
# or link command, so nothing gets rebuilt; ninja just retries the links.
# Safe to re-run.
set -euo pipefail

SRC=${SRC:-$HOME/Chromium-HaikuOS/work/chromium-156.0.8078.79}
LIB="$SRC/build/config/haiku/compat/lib"

GNU=""
for d in /boot/system/develop/lib /boot/system/lib; do
    [ -e "$d/libgnu.so" ] && { GNU="$d/libgnu.so"; break; }
done
if [ -z "$GNU" ]; then
    echo "ERROR: libgnu.so not found in /boot/system/develop/lib or /boot/system/lib"
    exit 1
fi
echo "==> found $GNU"

NM=$(command -v llvm-nm || command -v nm || true)
if [ -n "$NM" ]; then
    for s in sched_getaffinity pthread_getaffinity_np; do
        if "$NM" -D "$GNU" 2>/dev/null | grep -qw "$s"; then
            echo "    ok: $s is in libgnu"
        else
            echo "    WARN: $s not found in libgnu (send me a screenshot)"
        fi
    done
fi

mkdir -p "$LIB"
SCRIPT='/* Haiku: libm is part of libroot; pull in libgnu for the
   *_getaffinity functions (Chromium-HaikuOS pass 12). */
INPUT(AS_NEEDED(-lgnu))'
if [ -f "$LIB/libm.a" ] && grep -q 'pass 12' "$LIB/libm.a" 2>/dev/null; then
    echo "==> $LIB/libm.a already set up"
else
    [ -f "$LIB/libm.a" ] && mv "$LIB/libm.a" "$LIB/libm.a.orig"
    printf '%s\n' "$SCRIPT" > "$LIB/libm.a"
    echo "==> wrote linker script $LIB/libm.a"
fi

echo "==> Now run:"
echo "  ninja -C out/Release -j8 -k 0 chrome 2>&1 | tee ~/build12.log"
