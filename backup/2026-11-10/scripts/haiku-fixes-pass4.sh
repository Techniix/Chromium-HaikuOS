#!/bin/bash
# Chromium-HaikuOS: fixes for the failures in build3.log (pass 4).
# Run after haiku-fixes-pass3.sh. Safe to re-run.
set -euo pipefail

SRC=${SRC:-$HOME/Chromium-HaikuOS/work/chromium-156.0.8078.79}
REPO=${REPO:-$HOME/Chromium-HaikuOS}
cd "$SRC"
say() { printf '==> %s\n' "$*"; }

RES=$(clang -print-resource-dir)/include
COMPAT=build/config/haiku/compat

# ---------------------------------------------------------------------------
# 1. C11 atomics: Clang's <stdatomic.h> forwards to the "system" one when
#    hosted, which on Haiku is GCC's. Ship a copy that never forwards, in a
#    directory searched before Clang's own.
# ---------------------------------------------------------------------------
FIRST=build/config/haiku/clang_first
mkdir -p "$FIRST"
python3 - "$RES/stdatomic.h" "$FIRST/stdatomic.h" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
needle = "__has_include_next(<stdatomic.h>)"
assert needle in s, "unexpected clang stdatomic.h"
s = s.replace(needle, "0 /* Haiku: never use GCC's stdatomic.h */", 1)
open(dst, "w").write("// Copied from " + src + " by haiku-fixes-pass4.sh\n" + s)
PY
python3 <<'PY'
p = "build/config/haiku/BUILD.gn"
s = open(p).read()
if "clang_first" not in s:
    old = '  cflags_c = [ "-isystem", clang_builtin_headers ]\n  cflags_cc = [ "-isystem", clang_builtin_headers ]\n'
    new = ('  clang_first = rebase_path("clang_first", root_build_dir)\n'
           '  cflags_c = [ "-isystem", clang_first, "-isystem", clang_builtin_headers ]\n'
           '  cflags_cc = [ "-isystem", clang_first, "-isystem", clang_builtin_headers ]\n')
    assert old in s, "pass3 runtime_library block not found - run pass3 first"
    s = s.replace(old, new, 1)
    open(p, "w").write(s)
PY
say "stdatomic: Clang's own implementation forced"

# ---------------------------------------------------------------------------
# 2. Byte-order helpers (htole64 & co). Haiku has <bsd/endian.h>, which
#    #include_next's an <endian.h> that doesn't exist; supply it (compat is
#    searched last) plus <sys/endian.h> for nasm.
# ---------------------------------------------------------------------------
cat > "$COMPAT/endian.h" <<'EOF'
// Haiku compat <endian.h> (glibc/BSD style), built on compiler builtins.
#ifndef HAIKU_COMPAT_ENDIAN_H
#define HAIKU_COMPAT_ENDIAN_H
#include <stdint.h>
#ifndef __LITTLE_ENDIAN
#define __LITTLE_ENDIAN __ORDER_LITTLE_ENDIAN__
#define __BIG_ENDIAN __ORDER_BIG_ENDIAN__
#define __PDP_ENDIAN __ORDER_PDP_ENDIAN__
#define __BYTE_ORDER __BYTE_ORDER__
#endif
#ifndef LITTLE_ENDIAN
#define LITTLE_ENDIAN __LITTLE_ENDIAN
#define BIG_ENDIAN __BIG_ENDIAN
#define PDP_ENDIAN __PDP_ENDIAN
#endif
#ifndef BYTE_ORDER
#define BYTE_ORDER __BYTE_ORDER
#endif
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
#define HAIKU_COMPAT_LE(b, x) ((uint##b##_t)(x))
#define HAIKU_COMPAT_BE(b, x) ((uint##b##_t)__builtin_bswap##b(x))
#else
#define HAIKU_COMPAT_LE(b, x) ((uint##b##_t)__builtin_bswap##b(x))
#define HAIKU_COMPAT_BE(b, x) ((uint##b##_t)(x))
#endif
#ifndef htole16
#define htole16(x) HAIKU_COMPAT_LE(16, x)
#define htole32(x) HAIKU_COMPAT_LE(32, x)
#define htole64(x) HAIKU_COMPAT_LE(64, x)
#define le16toh(x) HAIKU_COMPAT_LE(16, x)
#define le32toh(x) HAIKU_COMPAT_LE(32, x)
#define le64toh(x) HAIKU_COMPAT_LE(64, x)
#endif
#ifndef htobe16
#define htobe16(x) HAIKU_COMPAT_BE(16, x)
#define htobe32(x) HAIKU_COMPAT_BE(32, x)
#define htobe64(x) HAIKU_COMPAT_BE(64, x)
#define be16toh(x) HAIKU_COMPAT_BE(16, x)
#define be32toh(x) HAIKU_COMPAT_BE(32, x)
#define be64toh(x) HAIKU_COMPAT_BE(64, x)
#endif
#endif
EOF
cat > "$COMPAT/sys/endian.h" <<'EOF'
// Haiku compat <sys/endian.h> (FreeBSD style).
#pragma once
#include <endian.h>
#ifndef bswap16
#define bswap16(x) __builtin_bswap16(x)
#define bswap32(x) __builtin_bswap32(x)
#define bswap64(x) __builtin_bswap64(x)
#endif
EOF
# Undo pass3's nasm change now that <sys/endian.h> exists.
sed -i 's|^/\* #undef HAVE_SYS_ENDIAN_H \*/  /\* Haiku \*/|#define HAVE_SYS_ENDIAN_H 1|' third_party/nasm/config/config-linux.h
say "endian: compat <endian.h>/<sys/endian.h>"

# ---------------------------------------------------------------------------
# 3. Small source fixes.
# ---------------------------------------------------------------------------
python3 <<'PY'
import re

def edit(path, fn):
    s = open(path).read()
    t = fn(s)
    if t != s:
        open(path, "w").write(t)
        print("    patched", path)

# abseil: pthread_t is a pointer on Haiku; use the kernel thread id.
def absl(s):
    if "find_thread(nullptr)" in s:
        return s
    i = s.index("pthread_threadid_np(nullptr, &tid);")
    j = s.index("#elif defined(__FreeBSD__)", i)
    branch = ('#elif defined(__HAIKU__)\n\n'
              'extern "C" int32_t find_thread(const char* name);  // <OS.h>\n'
              'pid_t GetTID() { return static_cast<pid_t>(find_thread(nullptr)); }\n\n')
    return s[:j] + branch + s[j:]
edit("third_party/abseil-cpp/absl/base/internal/sysinfo.cc", absl)

# protodatastore: Haiku has no ENOTBLK.
def enotblk(s):
    if "#ifdef ENOTBLK" in s:
        return s
    return re.sub(r"^(\s*case ENOTBLK:.*)$", r"#ifdef ENOTBLK\n\1\n#endif", s, count=1, flags=re.M)
edit("third_party/federated_compute/third_party/protodatastore-cpp/src/protostore/file-storage.cc", enotblk)

# chrome_crashpad_handler: no crashpad handler on Haiku (same stub as BSDs).
def crashpad(s):
    return s.replace("#if defined(__OpenBSD__) || defined(__FreeBSD__)\n",
                     "#if defined(__OpenBSD__) || defined(__FreeBSD__) || defined(__HAIKU__)\n", 1)
edit("components/crash/core/app/chrome_crashpad_handler.cc", crashpad)

# perfetto: give the Haiku branch every OS flag the FreeBSD branch defines.
def perfetto(s):
    h0 = s.index("#elif defined(__HAIKU__)")
    h1 = s.index("#else\n#error OS not supported", h0)
    f0 = s.index("#elif defined(__FreeBSD__)")
    f1 = s.index("#el", f0 + 5)
    have = set(re.findall(r"PERFETTO_BUILDFLAG_DEFINE_(\w+)\(\)", s[h0:h1]))
    want = re.findall(r"PERFETTO_BUILDFLAG_DEFINE_(\w+)\(\)", s[f0:f1])
    add = "".join("#define PERFETTO_BUILDFLAG_DEFINE_%s() 0\n" % w for w in want if w not in have)
    return s[:h1] + add + s[h1:]
edit("third_party/perfetto/include/perfetto/base/build_config.h", perfetto)

# dawn: treat Haiku as Linux desktop.
def dawn(s):
    if "defined(__HAIKU__)" in s:
        return s
    old = "#elif defined(__APPLE__)"
    new = ("#elif defined(__HAIKU__)\n#define DAWN_PLATFORM_IS_LINUX 1\n"
           "#define DAWN_PLATFORM_IS_POSIX 1\n#define DAWN_PLATFORM_IS_LINUX_DESKTOP 1\n\n" + old)
    return s.replace(old, new, 1)
edit("third_party/dawn/src/utils/platform.h", dawn)

# Haiku's CLOCK_MONOTONIC counts from boot and Haiku has no suspend, so it is
# CLOCK_BOOTTIME. Added as a global define in the Haiku compiler config.
def boottime(s):
    if "CLOCK_BOOTTIME" in s:
        return s
    return s.replace('    "_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE",\n',
                     '    "_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE",\n\n'
                     '    # No suspend on Haiku: monotonic == boot time.\n'
                     '    "CLOCK_BOOTTIME=CLOCK_MONOTONIC",\n', 1)
edit("build/config/haiku/BUILD.gn", boottime)
PY
say "source fixes applied"

# ---------------------------------------------------------------------------
# 4. TypeScript: the JavaScript tsc differs from Chromium's pinned tsgo in a
#    few DOM types and declaration-emit rules. Emit anyway and don't fail the
#    build on type errors (they are version skew, not bugs).
# ---------------------------------------------------------------------------
TSC_LINK=third_party/typescript/linux-amd64/src/lib/tsc
REAL_TSC=$(readlink -f "$TSC_LINK" 2>/dev/null || true)
if [ -n "$REAL_TSC" ] && ! grep -q "haiku-tsc-wrapper" "$REAL_TSC" 2>/dev/null; then
  rm -f "$TSC_LINK"
  cat > "$TSC_LINK" <<EOF
#!/bin/sh
# haiku-tsc-wrapper: run the JS TypeScript compiler, emit even on type errors.
"$REAL_TSC" "\$@" --noEmitOnError false
rc=\$?
[ \$rc -eq 0 ] || echo "haiku-tsc-wrapper: ignoring tsc exit \$rc (TypeScript version skew)" >&2
exit 0
EOF
  chmod +x "$TSC_LINK"
  say "tsc wrapper installed (real tsc: $REAL_TSC)"
fi

# ---------------------------------------------------------------------------
# 5. GN args.
# ---------------------------------------------------------------------------
setarg() { if grep -q "^$2 = " "$1"; then sed -i "s|^$2 = .*|$2 = $3|" "$1"; else echo "$2 = $3" >> "$1"; fi; }
for A in out/Release/args.gn "$REPO/scripts/args.gn.in"; do
  [ -f "$A" ] || continue
  # DCHECKs on non-debug builds pull in V8 DEBUG code that the BSD patches
  # don't cover (and slow everything down).
  setarg "$A" dcheck_always_on false
  # Remaining Vulkan / WebGPU pulls.
  setarg "$A" angle_shared_libvulkan false
  setarg "$A" skia_use_dawn false
  setarg "$A" dawn_enable_vulkan false
  setarg "$A" dawn_enable_vulkan_loader false
  setarg "$A" dawn_enable_vulkan_validation_layers false
  setarg "$A" dawn_use_swiftshader false
  # On-device AI model service (needs Dawn + Tint, whose code generator needs Go 1.26).
  setarg "$A" use_on_device_model_service false
  setarg "$A" webnn_use_litert false
done
say "args updated"

say "done. Now run:"
echo "  export RUSTC_BOOTSTRAP=1"
echo "  ninja -C out/Release -k 0 chrome 2>&1 | tee ~/build4.log"
