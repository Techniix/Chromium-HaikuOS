#!/bin/bash
# Chromium-HaikuOS: fixes for the failures in build9.log (pass 10).
# Run AFTER the current ninja run has stopped. Safe to re-run.
# Prints WARN for anything it couldn't find.
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

def ensure_build_config(s):
    if '#include "build/build_config.h"' in s: return s
    m = re.search(r'^#include ".*"\n', s, flags=re.M)
    return s[:m.start()] + '#include "build/build_config.h"\n' + s[m.start():] if m else s

def before_first_namespace(block, marker):
    def f(s):
        if marker in s: return s
        m = re.search(r"^namespace ", s, flags=re.M)
        if not m: return None
        return ensure_build_config(s[:m.start()] + block + "\n" + s[m.start():])
    return f

# 1. DMA-BUF ioctl numbers: define Linux's encoding right here, whatever
#    Haiku's own <sys/ioctl.h> does or doesn't define.
IOC = """#if defined(__HAIKU__)  // HAIKU_DMABUF_IOC_V2
// Linux _IOC encoding, only used to build ioctl numbers (never issued).
#undef _IOC
#undef _IO
#undef _IOR
#undef _IOW
#undef _IOWR
#define _IOC(dir, type, nr, size) \\
  ((unsigned long)(((dir) << 30) | ((size) << 16) | ((type) << 8) | (nr)))
#define _IO(type, nr) _IOC(0U, (type), (nr), 0)
#define _IOW(type, nr, t) _IOC(1U, (type), (nr), sizeof(t))
#define _IOR(type, nr, t) _IOC(2U, (type), (nr), sizeof(t))
#define _IOWR(type, nr, t) _IOC(3U, (type), (nr), sizeof(t))
#endif
"""
def dmabuf(s):
    if "HAIKU_DMABUF_IOC_V2" in s: return s
    # drop pass 9's version if present
    s = s.replace("\n#if defined(__HAIKU__)\n#include <sys/ioctl.h>\n#include <linux/haiku_ioc.h>\n#endif\n", "\n", 1)
    # The FreeBSD patch replaces <linux/version.h> with <sys/types.h>.
    for old in ("#include <sys/types.h>\n", "#include <linux/version.h>\n",
                "#define UI_GFX_LINUX_DMABUF_UAPI_H_\n"):
        if old in s:
            return s.replace(old, old + "\n" + IOC, 1)
    return None
edit("ui/gfx/linux/dmabuf_uapi.h", dmabuf, "_IOW")

# 2. Haiku's libwayland is 1.21.90: no key-repeat state (1.24) and no
#    axis_relative_direction pointer event (1.22).
edit("ui/ozone/platform/wayland/host/wayland_keyboard.cc", before_first_namespace(
    "#if BUILDFLAG(IS_HAIKU) && !defined(WL_KEYBOARD_KEY_STATE_REPEATED)\n"
    "// libwayland < 1.24 has no compositor-side key repeat state; the\n"
    "// compositor never sends it, so any value that isn't 0/1 works.\n"
    "#define WL_KEYBOARD_KEY_STATE_REPEATED 2\n#endif\n",
    "define WL_KEYBOARD_KEY_STATE_REPEATED 2"), "KEY_STATE_REPEATED")

def pointer(s):
    old = "      .axis_relative_direction = &OnAxisRelativeDirection,\n"
    if "libwayland < 1.22" in s: return s
    if old not in s: return None
    s = s.replace(old, "#if !BUILDFLAG(IS_HAIKU)  // libwayland < 1.22\n" + old + "#endif\n", 1)
    return ensure_build_config(s)
edit("ui/ozone/platform/wayland/host/wayland_pointer.cc", pointer, "axis_relative_direction")

# 3. V8: Haiku links executables as shared objects, so V8's default
#    "local-exec" TLS model can't link (mksnapshot). Use local-dynamic, as
#    on Android.
def v8tls(s):
    if "defined(__HAIKU__)" in s: return s
    old = '#elif defined(V8_TARGET_OS_ANDROID)\n#define V8_TLS_MODEL "local-dynamic"\n'
    if old not in s: return None
    return s.replace(old, '#elif defined(V8_TARGET_OS_ANDROID) || defined(__HAIKU__)\n'
                          '#define V8_TLS_MODEL "local-dynamic"\n', 1)
edit("v8/src/common/thread-local-storage.h", v8tls, "TLS model")
PY

# 4. <net/if_arp.h> (Cast/media-router network discovery). Haiku reports
#    link-layer types as IFT_* in sockaddr_dl::sdl_type, the BSD way.
mkdir -p build/config/haiku/compat/net
cat > build/config/haiku/compat/net/if_arp.h <<'EOF'
// Haiku compat <net/if_arp.h>: only the hardware-type constants, mapped to
// the IFT_* values Haiku puts in sockaddr_dl::sdl_type.
#ifndef HAIKU_COMPAT_NET_IF_ARP_H
#define HAIKU_COMPAT_NET_IF_ARP_H
#if __has_include(<net/if_types.h>)
#include <net/if_types.h>
#endif
#ifndef IFT_ETHER
#define IFT_ETHER 0x6
#endif
#ifndef ARPHRD_ETHER
#define ARPHRD_ETHER IFT_ETHER
#endif
#ifndef ARPHRD_IEEE802
#define ARPHRD_IEEE802 IFT_ETHER
#endif
#endif
EOF
echo "    wrote build/config/haiku/compat/net/if_arp.h"

echo "==> Now run:"
echo "  ninja -C out/Release -k 0 chrome 2>&1 | tee ~/build10.log"
