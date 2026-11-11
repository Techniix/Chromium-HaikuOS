#!/bin/bash
# Chromium-HaikuOS: fixes for the failures in build2.log (pass 3).
# Run once from anywhere; safe to re-run (each step checks before editing).
set -euo pipefail

SRC=${SRC:-$HOME/Chromium-HaikuOS/work/chromium-156.0.8078.79}
REPO=${REPO:-$HOME/Chromium-HaikuOS}
cd "$SRC"

say() { printf '==> %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 0. Clang's own headers must exist; they will be put ahead of GCC's.
# ---------------------------------------------------------------------------
RES=$(clang -print-resource-dir)
if [ ! -f "$RES/include/xmmintrin.h" ] || [ ! -f "$RES/include/stdatomic.h" ]; then
  echo "ERROR: Clang's builtin headers are missing from $RES/include."
  echo "Install the package that provides them (pkgman search llvm23) and re-run."
  exit 1
fi
say "clang resource headers: $RES/include"

# ---------------------------------------------------------------------------
# 1. Compat headers for Linux-only <sys/...> headers Haiku doesn't have.
#    Added with -idirafter, so a real system header always wins.
# ---------------------------------------------------------------------------
COMPAT=build/config/haiku/compat
mkdir -p "$COMPAT/sys"
cat > "$COMPAT/sys/syscall.h" <<'EOF'
// Haiku has no <sys/syscall.h>; Linux-only code that uses syscall(__NR_*)
// must still be guarded. This stub only satisfies the #include.
#pragma once
EOF
cat > "$COMPAT/sys/auxv.h" <<'EOF'
// Haiku has no <sys/auxv.h>/getauxval(). Stub for unconditional includes.
#pragma once
EOF
cat > "$COMPAT/sys/sysmacros.h" <<'EOF'
// Haiku dev_t has no major/minor split; these only make DRM-related code
// compile (it is never used on Haiku).
#pragma once
#include <sys/types.h>
#ifndef major
#define major(d) ((unsigned int)(((d) >> 8) & 0xfff))
#define minor(d) ((unsigned int)((d) & 0xff))
#define makedev(ma, mi) ((dev_t)(((ma) << 8) | (mi)))
#endif
EOF
# Haiku's <ctype.h> defines isdigit() etc. as macros even in C++, which breaks
# every `std::isdigit(...)`. Include it first, then drop the macros.
cat > "$COMPAT/haiku_cxx_prelude.h" <<'EOF'
// Force-included into every C++ file on Haiku (see build/config/haiku).
#pragma once
#include <ctype.h>
#undef isalnum
#undef isalpha
#undef isblank
#undef iscntrl
#undef isdigit
#undef isgraph
#undef islower
#undef isprint
#undef ispunct
#undef isspace
#undef isupper
#undef isxdigit
#undef tolower
#undef toupper
#undef isascii
#undef toascii
EOF
say "compat headers written to $COMPAT"

# ---------------------------------------------------------------------------
# 2. build/config/haiku/BUILD.gn: libc++ rune table, compat dir, C++ prelude,
#    and Clang's headers ahead of /boot/system/develop/headers/gcc/include.
# ---------------------------------------------------------------------------
python3 - "$RES/include" <<'PY'
import sys, re
res = sys.argv[1]
p = "build/config/haiku/BUILD.gn"
s = open(p).read()
if "_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE" not in s:
    old = '''    "_GNU_SOURCE",
  ]'''
    new = '''    "_GNU_SOURCE",

    # libc++ has no Haiku ctype/rune table; use its built-in classic table.
    "_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE",
  ]'''
    assert old in s, "compiler defines block not found"
    s = s.replace(old, new, 1)
    old = '''    "-Wno-unused-command-line-argument",
  ]'''
    new = '''    "-Wno-unused-command-line-argument",

    # Stubs for Linux-only <sys/...> headers (build/config/haiku/compat).
    "-idirafter",
    rebase_path("compat", root_build_dir),
  ]
  cflags_cc = [
    "-include",
    rebase_path("compat/haiku_cxx_prelude.h", root_build_dir),
  ]'''
    assert old in s, "compiler cflags block not found"
    s = s.replace(old, new, 1)
if "clang_builtin_headers" not in s:
    old = '''config("runtime_library") {'''
    new = '''config("runtime_library") {
  # The Haiku Clang driver searches /boot/system/develop/headers/gcc/include
  # (GCC's intrinsics and <stdatomic.h>) ahead of Clang's own builtin headers,
  # which Clang can't compile. Put Clang's first. This config is applied after
  # libc++'s, so libc++'s -isystem dirs still come before it.
  clang_builtin_headers = "%s"
  cflags_c = [ "-isystem", clang_builtin_headers ]
  cflags_cc = [ "-isystem", clang_builtin_headers ]
  cflags_objc = cflags_c
  cflags_objcc = cflags_cc
''' % res
    assert old in s, "runtime_library config not found"
    s = s.replace(old, new, 1)
open(p, "w").write(s)
PY
say "updated build/config/haiku/BUILD.gn"

# ---------------------------------------------------------------------------
# 3. libc++abi: Haiku has no futex; use the pthread guard implementation.
# ---------------------------------------------------------------------------
f=buildtools/third_party/libc++abi/BUILD.gn
grep -q '!is_freebsd && !is_haiku' "$f" || \
  sed -i 's/(is_linux || is_android) && !is_freebsd)/(is_linux || is_android) \&\& !is_freebsd \&\& !is_haiku)/' "$f"
grep -q '!is_haiku' "$f" && say "libc++abi: futex disabled on Haiku"

# ---------------------------------------------------------------------------
# 4. nasm: the FreeBSD patch claims <sys/endian.h>/<machine/endian.h>; Haiku
#    has neither. nasm falls back to the compiler's __BYTE_ORDER__.
# ---------------------------------------------------------------------------
f=third_party/nasm/config/config-linux.h
sed -i 's|^#define HAVE_SYS_ENDIAN_H 1|/* #undef HAVE_SYS_ENDIAN_H */  /* Haiku */|; s|^#define HAVE_MACHINE_ENDIAN_H 1|/* #undef HAVE_MACHINE_ENDIAN_H */  /* Haiku */|' "$f"
say "nasm: endian headers off"

# ---------------------------------------------------------------------------
# 5. perfetto: add a Haiku branch (copy of the Linux one) to build_config.h.
# ---------------------------------------------------------------------------
python3 <<'PY'
p = "third_party/perfetto/include/perfetto/base/build_config.h"
s = open(p).read()
if "defined(__HAIKU__)" not in s:
    start = s.index("#elif defined(__linux__)")
    end = s.index("#elif", start + 5)
    block = s[start:end].replace("#elif defined(__linux__)", "#elif defined(__HAIKU__)", 1)
    marker = "#else\n#error OS not supported"
    assert marker in s, "perfetto #error marker not found"
    s = s.replace(marker, block + marker, 1)
    open(p, "w").write(s)
PY
say "perfetto: Haiku treated as Linux"

# ---------------------------------------------------------------------------
# 6. libsync relied on Linux headers pulling in <stdint.h>.
# ---------------------------------------------------------------------------
f=third_party/libsync/src/sync.c
grep -q '^#include <stdint.h> /\* Haiku \*/' "$f" || sed -i '1i #include <stdint.h> /* Haiku */' "$f"

# ---------------------------------------------------------------------------
# 7. GN args: no Vulkan/Dawn/SwiftShader/OpenXR for the first bring-up.
#    (Removes ~600 failures in vulkan-*, spirv-tools, swiftshader, dawn.)
# ---------------------------------------------------------------------------
setarg() {  # setarg FILE KEY VALUE
  if grep -q "^$2 = " "$1"; then sed -i "s|^$2 = .*|$2 = $3|" "$1"; else echo "$2 = $3" >> "$1"; fi
}
for A in out/Release/args.gn "$REPO/scripts/args.gn.in"; do
  [ -f "$A" ] || continue
  grep -q "Haiku first bring-up" "$A" || printf '\n# --- Haiku first bring-up: no Vulkan/WebGPU/SwiftShader/XR ---\n' >> "$A"
  setarg "$A" enable_vulkan false
  setarg "$A" enable_swiftshader_vulkan false
  setarg "$A" enable_swiftshader false
  setarg "$A" angle_enable_vulkan false
  setarg "$A" use_dawn false
  setarg "$A" build_dawn_tests false
  setarg "$A" enable_openxr false
  sed -i '/^use_atk = /d; /^use_typescript_go = /d' "$A"
done
say "args updated (out/Release/args.gn and scripts/args.gn.in)"

say "done. Now run:"
echo "  export RUSTC_BOOTSTRAP=1"
echo "  ninja -C out/Release -k 0 chrome 2>&1 | tee ~/build3.log"
