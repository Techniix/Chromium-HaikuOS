#!/bin/bash
# Chromium-HaikuOS: fixes for the failures in build4.log (pass 5).
# Run after pass 3 and pass 4. Safe to re-run.
set -euo pipefail

SRC=${SRC:-$HOME/Chromium-HaikuOS/work/chromium-156.0.8078.79}
cd "$SRC"
say() { printf '==> %s\n' "$*"; }

python3 <<'PY'
import os, re

def edit(path, fn):
    s = open(path).read()
    t = fn(s)
    if t != s:
        open(path, "w").write(t)
        print("    patched", path)

# --- perfetto -------------------------------------------------------------
# Haiku is Linux-like but not Linux. Mark it the way the BSD patches expect:
# OS_LINUX=1 (generic POSIX code), OS_BSD=1 (skips the Linux-only syscalls:
# prctl, eventfd, inotify, sched_setscheduler, gettid ...) and
# LINUX_BUT_NOT_QNX=0 (the remaining Linux-only paths, like on QNX).
def perfetto(s):
    h0 = s.index("#elif defined(__HAIKU__)")
    h1 = s.index("#else\n#error OS not supported", h0)
    block = s[h0:h1]
    for name, val in (("PERFETTO_OS_LINUX", 1), ("PERFETTO_OS_LINUX_BUT_NOT_QNX", 0),
                      ("PERFETTO_OS_BSD", 1), ("PERFETTO_OS_FREEBSD", 0),
                      ("PERFETTO_OS_OPENBSD", 0)):
        pat = r"#define PERFETTO_BUILDFLAG_DEFINE_%s\(\) \d" % name
        rep = "#define PERFETTO_BUILDFLAG_DEFINE_%s() %d" % (name, val)
        if re.search(pat, block):
            block = re.sub(pat, rep, block)
        else:
            block += rep + "\n"
    return s[:h0] + block + s[h1:]
edit("third_party/perfetto/include/perfetto/base/build_config.h", perfetto)

# --- global defines -------------------------------------------------------
# Haiku's CLOCK_MONOTONIC is never slewed (no NTP adjtime on it), so it also
# serves as CLOCK_MONOTONIC_RAW.
def raw(s):
    if "CLOCK_MONOTONIC_RAW" in s:
        return s
    return s.replace('    "CLOCK_BOOTTIME=CLOCK_MONOTONIC",\n',
                     '    "CLOCK_BOOTTIME=CLOCK_MONOTONIC",\n'
                     '    "CLOCK_MONOTONIC_RAW=CLOCK_MONOTONIC",\n', 1)
edit("build/config/haiku/BUILD.gn", raw)

# --- protodatastore: guard every errno case Haiku might lack --------------
def errnos(s):
    lines = s.split("\n")
    out = []
    for i, l in enumerate(lines):
        m = re.match(r"^\s*case (E[A-Z0-9]+):", l)
        guarded = i > 0 and lines[i - 1].strip().startswith("#ifdef E")
        if m and not guarded:
            out += ["#ifdef " + m.group(1), l, "#endif"]
        else:
            out.append(l)
    return "\n".join(out)
edit("third_party/federated_compute/third_party/protodatastore-cpp/src/protostore/file-storage.cc", errnos)

# --- fontconfig: the FreeBSD patch made its config FreeBSD's ---------------
def fontconfig(s):
    def undef(name):
        nonlocal s
        s = re.sub(r"^#define %s( .*)?$" % name, "/* #undef %s */  /* Haiku */" % name, s, flags=re.M)
    def define(name, val="1"):
        nonlocal s
        if re.search(r"^#define %s\b" % name, s, flags=re.M):
            s = re.sub(r"^#define %s\b.*$" % name, "#define %s %s" % (name, val), s, flags=re.M)
        else:
            s = re.sub(r"^/\* #undef %s \*/.*$" % name, "#define %s %s" % (name, val), s, flags=re.M)
    undef("HAVE_GNU_STRERROR_R")      # Haiku's strerror_r is the POSIX (int) one
    undef("HAVE_SYS_MOUNT_H")
    undef("HAVE_SYS_PARAM_H_MOUNT")
    undef("HAVE_STRUCT_STATFS_F_FLAGS")
    undef("HAVE_STRUCT_STATFS_F_FSTYPENAME")
    undef("HAVE_STATFS")
    undef("HAVE_ARC4RANDOM")          # in libbsd on Haiku, not libroot
    define("HAVE_RANDOM")
    s = re.sub(r'^#define FC_DEFAULT_FONTS .*$',
               r'#define FC_DEFAULT_FONTS "\\t<dir>/boot/system/data/fonts</dir>\\n'
               r'\\t<dir>/boot/system/non-packaged/data/fonts</dir>\\n'
               r'\\t<dir>~/config/non-packaged/data/fonts</dir>\\n"',
               s, flags=re.M)
    return s
edit("third_party/fontconfig/include/meson-config.h", fontconfig)

# --- Tint code generation needs Go >= 1.26 (Haiku has 1.18) ---------------
# Replace the generator wrapper: use pre-generated sources if present.
p = "third_party/dawn/tools/generate-sources-gn.py"
s = open(p).read()
if "HAIKU-PREGENERATED" not in s:
    os.replace(p, p + ".orig")
    open(p, "w").write('''#!/usr/bin/env python3
# HAIKU-PREGENERATED: Tint's generator needs Go >= 1.26, which Haiku lacks.
# Generate the sources on another machine (see haiku-fixes-pass5.sh) and
# unpack them into out/Release/gen; this script then just accepts them.
import os, shutil, subprocess, sys
out = os.path.join(os.getcwd(), sys.argv[1])
tint = os.path.join(out, "src", "tint")
if os.path.exists(os.path.join(tint, "lang", "core", "enums.cc")):
    for root, _, files in os.walk(tint):
        for f in files:
            os.utime(os.path.join(root, f))
    sys.exit(0)
if shutil.which("go"):
    orig = os.path.join(os.path.dirname(os.path.abspath(__file__)), "generate-sources-gn.py.orig")
    sys.exit(subprocess.call([sys.executable, orig] + sys.argv[1:]))
sys.stderr.write("Tint sources are missing from %s. Generate them with Go >= 1.26 "
                 "on another machine and unpack them there (see haiku-fixes-pass5.sh).\\n" % tint)
sys.exit(1)
''')
    print("    patched", p)
PY
say "fixes applied"

if [ ! -f out/Release/gen/src/tint/lang/core/enums.cc ]; then
  # Package exactly what the generator needs, for use on another machine.
  tar czf "$HOME/dawn-for-tint-gen.tar.gz" --exclude='.git' -C third_party dawn
  cat <<EOF

==> ONE MANUAL STEP: generate Tint's sources on a machine with Go >= 1.26
    ($HOME/dawn-for-tint-gen.tar.gz has been created for this).

    On Linux/macOS/Windows (WSL) with Go 1.26+ and internet access:
        mkdir dawn-gen && cd dawn-gen
        tar xzf dawn-for-tint-gen.tar.gz
        cd dawn && GO111MODULE=on CGO_ENABLED=0 go run ./tools/src/cmd/gen/sources "\$PWD/../out"
        cd .. && tar czf tint-gen.tar.gz -C out src

    Back on Haiku:
        tar xzf tint-gen.tar.gz -C $SRC/out/Release/gen
        ls $SRC/out/Release/gen/src/tint/lang/core/enums.cc

    The rest of the build doesn't depend on it, so you can start ninja now
    and add the generated files whenever they're ready.
EOF
fi

say "Now run:"
echo "  export RUSTC_BOOTSTRAP=1"
echo "  ninja -C out/Release -k 0 chrome 2>&1 | tee ~/build5.log"
