#!/bin/bash
# Chromium-HaikuOS: fixes for the failures in build5.log (pass 6).
# Run after passes 3-5. Safe to re-run. Prints WARN for anything it couldn't
# find (send me those lines).
set -euo pipefail

SRC=${SRC:-$HOME/Chromium-HaikuOS/work/chromium-156.0.8078.79}
REPO=${REPO:-$HOME/Chromium-HaikuOS}
cd "$SRC"
say() { printf '==> %s\n' "$*"; }

python3 <<'PY'
import os, re, glob

def edit(path, fn, what=""):
    if not os.path.exists(path):
        print("    WARN missing", path); return
    s = open(path).read()
    t = fn(s)
    if t is None:
        print("    WARN pattern not found:", path, what); return
    if t != s:
        open(path, "w").write(t); print("    patched", path, what)

def rep(old, new, marker=None):
    """Replace first `old` with `new`; skip if `marker` (default new) present."""
    def f(s):
        if (marker or new) in s: return s
        if old not in s: return None
        return s.replace(old, new, 1)
    return f

def insert_before_namespace(block, marker):
    def f(s):
        if marker in s: return s
        m = re.search(r"^namespace ", s, flags=re.M)
        if not m: return None
        return s[:m.start()] + block + "\n" + s[m.start():]
    return f

def guard_errno_cases(s):
    lines, out = s.split("\n"), []
    for i, l in enumerate(lines):
        m = re.match(r"^\s*case (E[A-Z0-9]+):", l)
        if m and not (i and lines[i-1].strip().startswith("#ifdef E")):
            out += ["#ifdef " + m.group(1), l, "#endif"]
        else:
            out.append(l)
    return "\n".join(out)

# ---------------- base ----------------
edit("base/process/process_metrics_posix.cc", rep(
    "#elif BUILDFLAG(IS_AIX)\nstatic const rlim_t kSystemDefaultMaxFds = 8192;\n",
    "#elif BUILDFLAG(IS_AIX)\nstatic const rlim_t kSystemDefaultMaxFds = 8192;\n"
    "#elif BUILDFLAG(IS_HAIKU)\nstatic const rlim_t kSystemDefaultMaxFds = 1024;\n"), "max fds")

edit("base/process/launch_posix.cc", rep(
    '#elif BUILDFLAG(IS_ANDROID)\nstatic const char kFDDir[] = "/proc/self/fd";\n',
    '#elif BUILDFLAG(IS_ANDROID)\nstatic const char kFDDir[] = "/proc/self/fd";\n'
    '#elif BUILDFLAG(IS_HAIKU)\n// No fd directory on Haiku; DirReaderPosix fails and we close every fd.\n'
    'static const char kFDDir[] = "/dev/fd";\n'), "kFDDir")

edit("base/linux_util.cc", rep("#include <memory>\n", "#include <memory>\n#include <sstream>\n",
                               marker="#include <sstream>"), "<sstream>")

edit("base/profiler/module_cache_posix.cc", rep(
    "#include <elf.h>\n",
    "#include <elf.h>\n\n#if !defined(PF_X)  // Haiku's <elf.h> calls it PF_EXECUTE\n#define PF_X 0x1\n#endif\n",
    marker="#define PF_X"), "PF_X")

edit("base/memory/protected_memory_posix.cc", rep(
    "namespace internal {\n",
    "#if !defined(RLIMIT_NPROC)  // Haiku: any rlimit works for the EFAULT probe\n"
    "#define RLIMIT_NPROC RLIMIT_NOFILE\n#endif\n\nnamespace internal {\n",
    marker="define RLIMIT_NPROC"), "RLIMIT_NPROC")

edit("base/posix/can_lower_nice_to.cc", rep(
    "#include <unistd.h>\n",
    "#include <unistd.h>\n\n#if !defined(NZERO)  // Haiku\n#define NZERO 20\n#endif\n",
    marker="#define NZERO"), "NZERO")

edit("base/files/file_posix.cc", rep(
    "int CallFutimes(PlatformFile file, const std::array<struct timeval, 2> times) {\n#ifdef __USE_XOPEN2K8\n",
    "int CallFutimes(PlatformFile file, const std::array<struct timeval, 2> times) {\n"
    "#if defined(__USE_XOPEN2K8) || BUILDFLAG(IS_HAIKU)\n"), "futimens")

edit("base/process/set_process_title.cc", rep(
    '#include "build/build_config.h"\n',
    '#include "build/build_config.h"\n\n'
    '#if BUILDFLAG(IS_HAIKU)\n// No setproctitle() on Haiku; the team name comes from argv[0].\n'
    '#define setproctitle(...) ((void)0)\n#endif\n',
    marker="No setproctitle() on Haiku"), "setproctitle")

# ---------------- components / services / sandbox ----------------
edit("components/device_signals/core/common/linux/platform_utils_linux.cc", rep(
    "static_cast<char*>(LLADDR(sdl))", "reinterpret_cast<char*>(LLADDR(sdl))"), "LLADDR")

edit("components/update_client/update_query_params.cc", rep(
    '#elif defined(OS_FREEBSD)\n    "freebsd";\n',
    '#elif defined(OS_FREEBSD)\n    "freebsd";\n#elif BUILDFLAG(IS_HAIKU)\n    "haiku";\n'), "kOs")

def conn_info(s):
    if "IS_HAIKU) // ucred" in s: return s
    s2 = s.replace("#include <sys/ucred.h>\n",
                   "#if !BUILDFLAG(IS_HAIKU)\n#include <sys/ucred.h>\n#endif\n#include <sys/socket.h>\n", 1)
    s2 = s2.replace("#elif BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_OPENBSD)\n",
                    "#elif BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_OPENBSD) || BUILDFLAG(IS_HAIKU) // ucred\n", 1)
    return s2 if s2 != s else None
edit("components/named_mojo_ipc_server/connection_info.h", conn_info, "ucred")

edit("net/socket/unix_domain_server_socket_posix.cc", rep(
    "#if BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_CHROMEOS) || BUILDFLAG(IS_ANDROID) || \\\n    BUILDFLAG(IS_FUCHSIA)\n  struct ucred user_cred;",
    "#if BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_CHROMEOS) || BUILDFLAG(IS_ANDROID) || \\\n    BUILDFLAG(IS_FUCHSIA) || BUILDFLAG(IS_HAIKU)\n  struct ucred user_cred;"), "SO_PEERCRED")

edit("net/base/net_errors_posix.cc", guard_errno_cases, "errno cases")

edit("net/dns/address_sorter_posix.cc",
     lambda s: s.replace("(BUILDFLAG(IS_BSD) || BUILDFLAG(IS_HAIKU))", "BUILDFLAG(IS_BSD)"),
     "no KAME in6_var on Haiku")

NO_TCLASS = """#if defined(__HAIKU__)
// Haiku has no IPv6 traffic class or socket timestamps. Unknown option
// numbers make those setsockopt()s fail cleanly; the cmsg checks never match.
#ifndef IPV6_TCLASS
#define IPV6_TCLASS (-1)
#endif
#ifndef IPV6_RECVTCLASS
#define IPV6_RECVTCLASS (-2)
#endif
#ifndef SO_TIMESTAMP
#define SO_TIMESTAMP (-3)
#endif
#ifndef SCM_TIMESTAMP
#define SCM_TIMESTAMP SO_TIMESTAMP
#endif
#endif  // __HAIKU__
"""
edit("net/socket/udp_socket_posix.cc", insert_before_namespace(NO_TCLASS, "Haiku has no IPv6 traffic class"), "TCLASS")
edit("third_party/webrtc/rtc_base/physical_socket_server.cc", insert_before_namespace(NO_TCLASS, "Haiku has no IPv6 traffic class"), "TCLASS")

def proc_util(s):
    old = "errno == ESTALE && de->d_type == DT_LNK"
    if "IS_HAIKU) // no d_type" in s: return s
    if old not in s: return None
    return s.replace(old, "errno == ESTALE &&\n#if BUILDFLAG(IS_HAIKU) // no d_type\n        false\n#else\n        de->d_type == DT_LNK\n#endif\n        ", 1)
edit("sandbox/linux/services/proc_util.cc", proc_util, "d_type")

edit("services/device/usb/usb_service.cc", rep(
    "#elif (BUILDFLAG(IS_BSD) || BUILDFLAG(IS_HAIKU))\n  return base::WrapUnique(new UsbServiceImpl());",
    "#elif BUILDFLAG(IS_HAIKU)\n  return nullptr;  // No USB backend on Haiku yet.\n"
    "#elif (BUILDFLAG(IS_BSD) || BUILDFLAG(IS_HAIKU))\n  return base::WrapUnique(new UsbServiceImpl());",
    marker="No USB backend on Haiku"), "UsbService")

# mojom: haikuify turned the "is_bsd" feature name into "(is_bsd || is_haiku)".
def mojom_gni(s):
    s = s.replace('enabled_features += [ "(is_bsd || is_haiku)" ]', 'enabled_features += [ "is_bsd" ]')
    if "is_haiku\" ]" in s: return s
    old = "    if (is_freebsd) {\n"
    if old not in s: return None
    return s.replace(old, '    if (is_haiku) {\n      enabled_features += [ "is_haiku" ]\n    }\n\n' + old, 1)
edit("mojo/public/tools/bindings/mojom.gni", mojom_gni, "is_haiku feature")
edit("sandbox/policy/mojom/sandbox.mojom", rep(
    "  [EnableIf=is_freebsd]\n  kVideoCapture,\n",
    "  [EnableIf=is_freebsd]\n  kVideoCapture,\n\n  [EnableIf=is_haiku]\n  kVideoCapture,\n"), "kVideoCapture")

# ---------------- third_party ----------------
edit("third_party/crashpad/crashpad/minidump/minidump_misc_info_writer.cc", rep(
    '#elif defined(OS_FREEBSD)\n  static constexpr char kOS[] = "freebsd";\n',
    '#elif defined(OS_FREEBSD)\n  static constexpr char kOS[] = "freebsd";\n'
    '#elif defined(__HAIKU__)\n  static constexpr char kOS[] = "haiku";\n'), "kOS")
def sigio(s):
    if "#if defined(SIGIO)" in s: return s
    if "    SIGIO,\n" not in s: return None
    return s.replace("    SIGIO,\n", "#if defined(SIGIO)\n    SIGIO,\n#endif\n")
edit("third_party/crashpad/crashpad/util/posix/signals.cc", sigio, "SIGIO")

edit("third_party/perfetto/src/base/clock_snapshots.cc", rep(
    "    !PERFETTO_BUILDFLAG(PERFETTO_OS_FREEBSD) && \\\n",
    "    !PERFETTO_BUILDFLAG(PERFETTO_OS_FREEBSD) && \\\n    !PERFETTO_BUILDFLAG(PERFETTO_OS_BSD) && \\\n",
    marker="!PERFETTO_BUILDFLAG(PERFETTO_OS_BSD) && \\\n"), "coarse clocks")

# pthreadpool's struct fpu_state collides with Haiku's <signal.h>.
for p in glob.glob("third_party/pthreadpool/src/src/*.[ch]") + glob.glob("third_party/pthreadpool/src/src/**/*.[ch]", recursive=True):
    edit(p, lambda s: re.sub(r"\bfpu_state\b", "pthreadpool_fpu_state", s), "fpu_state")

def fc(s):
    return re.sub(r"^#define HAVE_STRUCT_DIRENT_D_TYPE\b.*$", "/* #undef HAVE_STRUCT_DIRENT_D_TYPE */  /* Haiku */", s, flags=re.M)
edit("third_party/fontconfig/include/meson-config.h", fc, "d_type")

# ---------------- global defines ----------------
def defines(s):
    if "IFF_RUNNING=IFF_LINK" in s: return s
    old = '    "CLOCK_MONOTONIC_RAW=CLOCK_MONOTONIC",\n'
    if old not in s: return None
    return s.replace(old, old +
        '\n    # Haiku spells "interface has carrier" IFF_LINK.\n    "IFF_RUNNING=IFF_LINK",\n'
        '\n    # No RTLD_NODELETE in Haiku\'s runtime loader.\n    "RTLD_NODELETE=0",\n', 1)
edit("build/config/haiku/BUILD.gn", defines, "global defines")
PY
say "source fixes applied"

setarg() { if grep -q "^$2 = " "$1"; then sed -i "s|^$2 = .*|$2 = $3|" "$1"; else echo "$2 = $3" >> "$1"; fi; }
for A in out/Release/args.gn "$REPO/scripts/args.gn.in"; do
  [ -f "$A" ] || continue
  setarg "$A" use_libpci false                     # no libpci on Haiku
  setarg "$A" v8_use_metagen_instance_types false  # use Torque, skip libclang harvest
done
say "args updated"

say "Now run:"
echo "  export RUSTC_BOOTSTRAP=1"
echo "  ninja -C out/Release -k 0 chrome 2>&1 | tee ~/build6.log"
