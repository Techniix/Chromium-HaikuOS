#!/bin/bash
# Chromium-HaikuOS: fixes for the failures in build10.log (pass 11).
# Safe to run while nothing is building; safe to re-run.
set -euo pipefail

SRC=${SRC:-$HOME/Chromium-HaikuOS/work/chromium-156.0.8078.79}
cd "$SRC"

python3 <<'PY'
import os, re

def edit(path, fn, what=""):
    if not os.path.exists(path):
        print("    WARN missing", path); return
    s = open(path).read()
    t = fn(s)
    if t is None:
        print("    WARN pattern not found:", path, what); return
    if t != s:
        open(path, "w").write(t); print("    patched", path, what)

# 1. Sandbox hook headers: the FreeBSD patch picks the BSD sandbox with
#    `defined(__OpenBSD__) || defined(__FreeBSD__)`, which haikuify doesn't
#    extend. utility_main.cc already takes the BSD path on Haiku, so both
#    SandboxLinux classes ended up in one file.
def bsd_sandbox(s):
    old = '#if defined(__OpenBSD__) || defined(__FreeBSD__)\n#include "sandbox/policy/sandbox.h"\n'
    new = '#if defined(__OpenBSD__) || defined(__FreeBSD__) || defined(__HAIKU__)\n#include "sandbox/policy/sandbox.h"\n'
    if new in s: return s
    return s.replace(old, new, 1) if old in s else None
for p in ("services/network/network_sandbox_hook_linux.h",
          "content/services/isolated_xr_device/xr_sandbox_hook_linux.h"):
    edit(p, bsd_sandbox, "BSD sandbox header")

# 2. about:flags "audio-backend" entry: its strings only exist on the BSDs
#    (sndio/pulse/alsa selection); keep it BSD-only.
def audio_flag(s):
    t, n = re.subn(r'#if \(BUILDFLAG\(IS_BSD\) \|\| BUILDFLAG\(IS_HAIKU\)\)\n(    \{"audio-backend",)',
                   r'#if BUILDFLAG(IS_BSD)  // Haiku: no audio-backend flag\n\1', s, count=1)
    if n: return t
    return s if 'Haiku: no audio-backend flag' in s else None
edit("chrome/browser/about_flags.cc", audio_flag, "audio-backend flag")

# 3. Linux desktop notifications: the icon is passed via a sealed memfd.
#    Haiku has no memfd sealing; skip it as OpenBSD does (icons still work
#    through the icon file path).
edit("chrome/browser/notifications/notification_platform_bridge_linux.cc",
     lambda s: s if "!BUILDFLAG(IS_OPENBSD) && !BUILDFLAG(IS_HAIKU)" in s else
     (s.replace("  // XXX\n#if !BUILDFLAG(IS_OPENBSD)\n",
                "  // XXX\n#if !BUILDFLAG(IS_OPENBSD) && !BUILDFLAG(IS_HAIKU)\n", 1)
      if "  // XXX\n#if !BUILDFLAG(IS_OPENBSD)\n" in s else None),
     "memfd")
# 4. Blink heap TLS: Haiku links executables with -shared, so the
#    "local-exec" TLS model fails to link (R_X86_64_TPOFF32 against
#    blink::g_thread_specific_). Use "local-dynamic" as Android does.
edit("third_party/blink/renderer/platform/heap/thread_local.h",
     lambda s: s if "BUILDFLAG(IS_ANDROID) || BUILDFLAG(IS_HAIKU)" in s else
     (s.replace('#elif BUILDFLAG(IS_ANDROID)\n#define BLINK_HEAP_THREAD_LOCAL_MODEL "local-dynamic"\n',
                '#elif BUILDFLAG(IS_ANDROID) || BUILDFLAG(IS_HAIKU)\n#define BLINK_HEAP_THREAD_LOCAL_MODEL "local-dynamic"\n', 1)
      if '#elif BUILDFLAG(IS_ANDROID)\n#define BLINK_HEAP_THREAD_LOCAL_MODEL "local-dynamic"\n' in s else None),
     "TLS model")
PY

echo "==> Now run:"
echo "  ninja -C out/Release -j8 -k 0 chrome 2>&1 | tee ~/build11.log"
