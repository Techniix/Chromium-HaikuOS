#!/bin/bash
# Chromium-HaikuOS: fixes for the failures in build8.log (pass 9).
# Run AFTER the current ninja run has stopped. Run after passes 3-8.
# Safe to re-run. Prints WARN for anything it couldn't find.
set -euo pipefail

SRC=${SRC:-$HOME/Chromium-HaikuOS/work/chromium-156.0.8078.79}
REPO=${REPO:-$HOME/Chromium-HaikuOS}
cd "$SRC"
COMPAT=build/config/haiku/compat
say() { printf '==> %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Linux UAPI bits the Wayland/input code needs (as FreeBSD's evdev-proto
#    provides): key/button codes, plus small shims. Compat dir is searched
#    last, so real Haiku headers always win.
# ---------------------------------------------------------------------------
mkdir -p "$COMPAT/linux" "$COMPAT/sys"
HERE=$(cd "$(dirname "$0")" && pwd)
if [ ! -s "$COMPAT/linux/input-event-codes.h" ] && [ -s "$HERE/input-event-codes.h" ]; then
  cp "$HERE/input-event-codes.h" "$COMPAT/linux/input-event-codes.h"   # Linux v6.12 UAPI
fi
if [ ! -s "$COMPAT/linux/input-event-codes.h" ]; then
  curl -fsSL -o "$COMPAT/linux/input-event-codes.h" \
    https://raw.githubusercontent.com/torvalds/linux/v6.12/include/uapi/linux/input-event-codes.h \
    || { echo "WARN: could not download linux/input-event-codes.h (network?)"; rm -f "$COMPAT/linux/input-event-codes.h"; }
fi
cat > "$COMPAT/linux/haiku_ioc.h" <<'EOF'
// Linux-style _IO/_IOR/_IOW/_IOWR encoding for code that only builds ioctl
// numbers (they're never issued on Haiku).
#ifndef HAIKU_COMPAT_IOC_H
#define HAIKU_COMPAT_IOC_H
#ifndef _IOC
#define _IOC(dir, type, nr, size) \
  ((unsigned long)(((dir) << 30) | ((size) << 16) | ((type) << 8) | (nr)))
#endif
#ifndef _IO
#define _IO(type, nr) _IOC(0U, (type), (nr), 0)
#endif
#ifndef _IOW
#define _IOW(type, nr, t) _IOC(1U, (type), (nr), sizeof(t))
#endif
#ifndef _IOR
#define _IOR(type, nr, t) _IOC(2U, (type), (nr), sizeof(t))
#endif
#ifndef _IOWR
#define _IOWR(type, nr, t) _IOC(3U, (type), (nr), sizeof(t))
#endif
#endif
EOF
cat > "$COMPAT/linux/input.h" <<'EOF'
// Haiku compat <linux/input.h>: only the event/key/button codes.
#ifndef HAIKU_COMPAT_LINUX_INPUT_H
#define HAIKU_COMPAT_LINUX_INPUT_H
#include <linux/input-event-codes.h>
#endif
EOF
cat > "$COMPAT/sys/eventfd.h" <<'EOF'
// Haiku has no eventfd(). Only DRM syncobj code uses it, and that protocol
// is never offered on Haiku; fail cleanly if it's ever called.
#ifndef HAIKU_COMPAT_SYS_EVENTFD_H
#define HAIKU_COMPAT_SYS_EVENTFD_H
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#define EFD_SEMAPHORE 1
#define EFD_CLOEXEC O_CLOEXEC
#define EFD_NONBLOCK O_NONBLOCK
typedef uint64_t eventfd_t;
static inline int eventfd(unsigned int initval, int flags) {
  (void)initval; (void)flags; errno = ENOSYS; return -1;
}
#endif
EOF
# NOTE: haiku_cxx_prelude.h is force-included into every C++ file, so it is
# deliberately NOT touched here (editing it would recompile everything).
say "compat headers"

# ---------------------------------------------------------------------------
# 2. Source fixes.
# ---------------------------------------------------------------------------
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

def guard(old, label):
    def f(s):
        if label in s: return s
        if old not in s: return None
        s = s.replace(old, "#if !BUILDFLAG(IS_HAIKU)  // %s\n%s#endif\n" % (label, old), 1)
        return ensure_build_config(s)
    return f

# --- DMA-BUF ioctl numbers need Linux's _IOW()/_IOWR() (never issued on Haiku).
def dmabuf(s):
    if "linux/haiku_ioc.h" in s: return s
    old = "#include <linux/version.h>\n"
    if old not in s: return None
    return s.replace(old, old + "\n#if defined(__HAIKU__)\n#include <sys/ioctl.h>\n#include <linux/haiku_ioc.h>\n#endif\n", 1)
edit("ui/gfx/linux/dmabuf_uapi.h", dmabuf, "_IOW")

# --- Wayland: Haiku's libwayland (1.21.90) predates wl_fixes (1.24).
NOFIX = "Haiku: libwayland has no wl_fixes"
edit("ui/ozone/platform/wayland/common/wayland_object.h",
     guard("DECLARE_WAYLAND_OBJECT_TRAITS(wl_fixes)\n", NOFIX), "wl_fixes")
edit("ui/ozone/platform/wayland/common/wayland_object.cc",
     guard("IMPLEMENT_WAYLAND_OBJECT_TRAITS(wl_fixes)\n", NOFIX), "wl_fixes")
edit("ui/ozone/platform/wayland/host/wayland_connection.h",
     guard("  wl::Object<wl_fixes> fixes_;\n", NOFIX), "wl_fixes")

def conn(s):
    if NOFIX in s and "No DRM/GBM on Haiku" in s: return s
    blocks = [
        "  if (fixes_ && registry_) {\n    wl_fixes_destroy_registry(fixes_.get(), registry_.get());\n  }\n",
        "  if (self->fixes_ && wl::get_version_of_object(self->fixes_.get()) >=\n"
        "                          WL_FIXES_ACK_GLOBAL_REMOVE_SINCE_VERSION) {\n"
        "    wl_fixes_ack_global_remove(self->fixes_.get(), registry, name);\n  }\n",
    ]
    for b in blocks:
        if b not in s: return None
        s = s.replace(b, "#if !BUILDFLAG(IS_HAIKU)  // %s\n%s#endif\n" % (NOFIX, b), 1)
    # registry bind: drop the `} else if (wl_fixes) {` arm, keep the closing brace.
    m = re.search(r'  \} else if \(!fixes_ && UNSAFE_TODO\(strcmp\(interface, "wl_fixes"\)\) == 0\) \{\n'
                  r'(?:.*\n)*?      return;\n    \}\n', s)
    if not m: return None
    s = s[:m.start()] + "#if !BUILDFLAG(IS_HAIKU)  // %s\n" % NOFIX + m.group(0) + "#endif\n" + s[m.end():]
    s = s.replace("constexpr uint32_t kMaxFixesVersion = 2;\n",
                  "[[maybe_unused]] constexpr uint32_t kMaxFixesVersion = 2;\n", 1)
    # GBM: only used to probe a DRM render node, which Haiku doesn't have.
    inc = '#include "ui/gfx/linux/scoped_gbm_device.h"\n'
    if inc not in s: return None
    s = s.replace(inc, "#if !BUILDFLAG(IS_HAIKU)\n" + inc + "#endif\n", 1)
    old = ("void WaylandConnection::SetRenderNodePath(base::ScopedFD& drm_fd,\n"
           "                                          const char* render_node_path) {\n")
    if old not in s: return None
    i = s.index(old) + len(old)
    j = s.index("\n}\n", i)
    s = (s[:i] + "#if BUILDFLAG(IS_HAIKU)\n  // No DRM/GBM on Haiku.\n#else\n" + s[i:j] +
         "\n#endif" + s[j:])
    return ensure_build_config(s)
edit("ui/ozone/platform/wayland/host/wayland_connection.cc", conn, "wl_fixes + gbm")

# --- Evdev keycodes: the Wayland keyboard needs them on Haiku too.
for p in ("ui/events/keycodes/dom/keycode_converter.h", "ui/events/keycodes/dom/keycode_converter.cc"):
    edit(p, lambda s: s if "IS_FREEBSD) || BUILDFLAG(IS_HAIKU)" in s else
         (s.replace("|| BUILDFLAG(IS_FREEBSD)\n", "|| BUILDFLAG(IS_FREEBSD) || BUILDFLAG(IS_HAIKU)\n")
          if "|| BUILDFLAG(IS_FREEBSD)\n" in s else None), "evdev")

# --- Blink stack bounds: Haiku has pthread_getattr_np(), like Linux.
def stack(s):
    if "IS_FUCHSIA) || BUILDFLAG(IS_HAIKU)" in s: return s
    t = s.replace("BUILDFLAG(IS_FREEBSD) || BUILDFLAG(IS_FUCHSIA)",
                  "BUILDFLAG(IS_FREEBSD) || BUILDFLAG(IS_FUCHSIA) || BUILDFLAG(IS_HAIKU)")
    return t if t != s else None
edit("third_party/blink/renderer/platform/wtf/stack_util.cc", stack, "pthread_getattr_np")

# --- ANGLE: treat Haiku like the BSDs (Linux-style EGL/GL backend).
def angle(s):
    if "ANGLE_PLATFORM_HAIKU" in s: return s
    old = "#elif defined(__FreeBSD__)\n"
    if old not in s: return None
    return s.replace(old, "#elif defined(__HAIKU__)\n#    define ANGLE_PLATFORM_HAIKU 1\n"
                          "#    define ANGLE_PLATFORM_POSIX 1\n#    define ANGLE_PLATFORM_BSD 1\n" + old, 1)
edit("third_party/angle/src/common/platform.h", angle, "ANGLE_PLATFORM_HAIKU")

# ANGLE: the FreeBSD patch uses getprogname() for every "BSD"; Haiku keeps
# the generic path (avoids depending on libbsd's declaration).
def angle_progname(s):
    if "!defined(ANGLE_PLATFORM_HAIKU))" in s: return s
    old = "#if (defined(ANGLE_PLATFORM_ANDROID) && __ANDROID_API__ >= 21) || defined(ANGLE_PLATFORM_BSD)\n"
    if old not in s: return None
    return s.replace(old, "#if (defined(ANGLE_PLATFORM_ANDROID) && __ANDROID_API__ >= 21) || "
                          "(defined(ANGLE_PLATFORM_BSD) && !defined(ANGLE_PLATFORM_HAIKU))\n", 1)
edit("third_party/angle/src/common/system_utils.cpp", angle_progname, "getprogname")

# Link-time insurance: Linux-minded targets add -ldl/-lrt/-lpthread/-lm, which
# live inside Haiku's libroot. Empty stand-in archives (created below, only
# for names Haiku doesn't ship) satisfy those -l flags. ldflags only, so this
# changes link commands, never compile commands (no recompiles).
def ldpath(s):
    if '"compat/lib"' in s: return s
    old = "  cflags_objc = cflags_c\n  cflags_objcc = cflags_cc\n"
    if old not in s: return None
    return s.replace(old, old + '  ldflags = [ "-L" + rebase_path("compat/lib", root_build_dir) ]\n', 1)
edit("build/config/haiku/BUILD.gn", ldpath, "compat/lib")

# --- content: Haiku has no RLIMIT_NPROC (per-user process limit).
def nproc(s):
    if "no RLIMIT_NPROC on Haiku" in s: return s
    t, n = re.subn(r"(size_t GetPlatformProcessLimit\(\) \{\n)#if ",
                   r"\1#if BUILDFLAG(IS_HAIKU)\n  return kUnknownPlatformProcessLimit;  // no RLIMIT_NPROC on Haiku\n#elif ",
                   s, count=1)
    return t if n else None
edit("content/browser/renderer_host/render_process_host_impl.cc", nproc, "RLIMIT_NPROC")

# --- Video capture: no V4L2 on Haiku; no camera backend for now.
for p in ("media/capture/video/create_video_capture_device_factory.cc",
          "media/capture/video/video_capture_buffer_tracker_factory_impl.cc"):
    edit(p, lambda s: s.replace("(BUILDFLAG(IS_BSD) || BUILDFLAG(IS_HAIKU))", "BUILDFLAG(IS_BSD)"), "no V4L2")
edit("media/capture/BUILD.gn", lambda s: s if "!is_haiku) {\n    deps += [ \"video/linux\" ]" in s else
     (s.replace('  if (is_linux || is_chromeos) {\n    deps += [ "video/linux" ]',
                '  if ((is_linux || is_chromeos) && !is_haiku) {\n    deps += [ "video/linux" ]', 1)
      if '  if (is_linux || is_chromeos) {\n    deps += [ "video/linux" ]' in s else None), "no V4L2")
PY
say "source fixes applied"

mkdir -p "$COMPAT/lib"
for l in dl rt pthread m; do
  if ! ls /boot/system/develop/lib/lib$l.so* /boot/system/develop/lib/lib$l.a >/dev/null 2>&1; then
    [ -f "$COMPAT/lib/lib$l.a" ] || printf '!<arch>\n' > "$COMPAT/lib/lib$l.a"
  fi
done

# ---------------------------------------------------------------------------
# 3. libuuid (bundled fontconfig links it).
# ---------------------------------------------------------------------------
if ! ls /boot/system/develop/lib/libuuid.so* /boot/system/non-packaged/develop/lib/libuuid.so* >/dev/null 2>&1; then
  pkgman install -y devel:libuuid >/dev/null 2>&1 || true
fi
if ! ls /boot/system/develop/lib/libuuid.so* /boot/system/non-packaged/develop/lib/libuuid.so* >/dev/null 2>&1; then
  echo "WARN: no libuuid on this system; dropping it from fontconfig's link line."
  python3 - <<'PY'
p = "third_party/fontconfig/BUILD.gn"
s = open(p).read()
s = s.replace('    if (!is_win) {\n      libs = [ "uuid" ]', '    if (!is_win && !is_haiku) {\n      libs = [ "uuid" ]', 1)
open(p, "w").write(s)
PY
fi

# ---------------------------------------------------------------------------
# 4. GN args.
# ---------------------------------------------------------------------------
setarg() { if grep -q "^$2 = " "$1"; then sed -i "s|^$2 = .*|$2 = $3|" "$1"; else echo "$2 = $3" >> "$1"; fi; }
for A in out/Release/args.gn "$REPO/scripts/args.gn.in"; do
  [ -f "$A" ] || continue
  setarg "$A" angle_enable_wgpu false   # ANGLE-on-WebGPU needs libwayland >= 1.23
done
say "args updated"

say "Now run:"
echo "  ninja -C out/Release -k 0 chrome 2>&1 | tee ~/build9.log"
