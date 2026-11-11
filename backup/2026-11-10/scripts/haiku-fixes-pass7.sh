#!/bin/bash
# Chromium-HaikuOS: fixes for the failures in build6.log (pass 7).
# Run after passes 3-6. Safe to re-run. Prints WARN for anything it couldn't
# find (send me those lines).
set -euo pipefail

SRC=${SRC:-$HOME/Chromium-HaikuOS/work/chromium-156.0.8078.79}
cd "$SRC"

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
    def f(s):
        if (marker or new) in s: return s
        if old not in s: return None
        return s.replace(old, new, 1)
    return f

# ---- Haiku has no struct ucred / getpeereid(); SO_PEERCRED may or may not
# exist depending on the Haiku revision. Use a local {pid,uid,gid} struct and
# let getsockopt() fail cleanly if the option isn't there.
def conn_info(s):
    if "Haiku: no struct ucred" in s: return s
    old = "namespace named_mojo_ipc_server {\n"
    if old not in s: return None
    block = ("#if BUILDFLAG(IS_HAIKU)\n#include <sys/types.h>\n#include <sys/socket.h>\n"
             "#if !defined(SO_PEERCRED)\n#define SO_PEERCRED (-1)  // getsockopt() fails cleanly\n#endif\n#endif\n\n"
             + old +
             "\n#if BUILDFLAG(IS_HAIKU)\n// Haiku: no struct ucred in its headers; same layout as SO_PEERCRED's.\n"
             "struct ucred {\n  pid_t pid;\n  uid_t uid;\n  gid_t gid;\n};\n#endif\n")
    return s.replace(old, block, 1)
edit("components/named_mojo_ipc_server/connection_info.h", conn_info, "ucred")

def uds(s):
    if "Haiku: no getpeereid()" in s: return s
    # undo pass 6 (Haiku in the Linux branch: Credentials has no process_id here)
    s = s.replace("    BUILDFLAG(IS_FUCHSIA) || BUILDFLAG(IS_HAIKU)\n  struct ucred user_cred;",
                  "    BUILDFLAG(IS_FUCHSIA)\n  struct ucred user_cred;", 1)
    old = "#else\n  return getpeereid("
    if old not in s: return None
    new = ("#elif BUILDFLAG(IS_HAIKU)\n  // Haiku: no getpeereid(); use SO_PEERCRED where the kernel has it.\n"
           "#if defined(SO_PEERCRED)\n  struct {\n    pid_t pid;\n    uid_t uid;\n    gid_t gid;\n  } user_cred;\n"
           "  socklen_t len = sizeof(user_cred);\n"
           "  if (getsockopt(socket, SOL_SOCKET, SO_PEERCRED, &user_cred, &len) < 0)\n    return false;\n"
           "  credentials->user_id = user_cred.uid;\n  credentials->group_id = user_cred.gid;\n  return true;\n"
           "#else\n  return false;\n#endif\n" + old)
    return s.replace(old, new, 1)
edit("net/socket/unix_domain_server_socket_posix.cc", uds, "peer credentials")

# ---- base
def stat_times(s):
    if "Haiku: POSIX.1-2008 st_*tim" in s: return s
    old = ("#elif (BUILDFLAG(IS_BSD) || BUILDFLAG(IS_HAIKU))\n"
           "  time_t last_modified_sec = stat_info.st_mtimespec.tv_sec;")
    if old not in s: return None
    new = ("#elif BUILDFLAG(IS_HAIKU)  // Haiku: POSIX.1-2008 st_*tim\n"
           "  time_t last_modified_sec = stat_info.st_mtim.tv_sec;\n"
           "  int64_t last_modified_nsec = stat_info.st_mtim.tv_nsec;\n"
           "  time_t last_accessed_sec = stat_info.st_atim.tv_sec;\n"
           "  int64_t last_accessed_nsec = stat_info.st_atim.tv_nsec;\n"
           "  time_t creation_time_sec = stat_info.st_ctim.tv_sec;\n"
           "  int64_t creation_time_nsec = stat_info.st_ctim.tv_nsec;\n" + old)
    return s.replace(old, new, 1)
edit("base/files/file_posix.cc", stat_times, "st_mtim")

edit("base/linux_util.cc", rep('#include "base/files/scoped_file.h"\n',
     '#include "base/files/scoped_file.h"\n#include "base/logging.h"\n',
     marker='#include "base/logging.h"'), "logging.h")

# ---- net: Haiku has no recvmmsg()/struct mmsghdr.
def mmsg(s):
    g = "#if BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_CHROMEOS) || BUILDFLAG(IS_ANDROID) || (BUILDFLAG(IS_BSD) || BUILDFLAG(IS_HAIKU))\n"
    g2 = "#if BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_CHROMEOS) || BUILDFLAG(IS_ANDROID) || BUILDFLAG(IS_BSD)  // Haiku: no recvmmsg\n"
    if "Haiku: no recvmmsg" in s: return s
    n = 0
    for follow in ("  if (gro_status_ == GroStatus::kEnabled) {\n    return InternalReadMultipleWithGro",
                   "base::expected<DatagramsMetadata, Error> UDPSocketPosix::InternalRecvMmsg("):
        if g + follow in s:
            s = s.replace(g + follow, g2 + follow, 1); n += 1
    return s if n == 2 else None
edit("net/socket/udp_socket_posix.cc", mmsg, "recvmmsg")

# ---- pthreadpool: finish the fpu_state rename (Chromium's jobs.cc too).
for p in (glob.glob("third_party/pthreadpool/**/*.c", recursive=True) +
          glob.glob("third_party/pthreadpool/**/*.cc", recursive=True) +
          glob.glob("third_party/pthreadpool/**/*.h", recursive=True)):
    edit(p, lambda s: re.sub(r"\bfpu_state\b", "pthreadpool_fpu_state", s), "fpu_state")

# ---- V8
edit("v8/src/libsampler/sampler.cc", rep(
    "#elif !V8_OS_OPENBSD\n#include <ucontext.h>\n",
    "#elif !V8_OS_OPENBSD && !V8_OS_HAIKU  // Haiku: ucontext_t is in <signal.h>\n#include <ucontext.h>\n"),
    "ucontext.h")
edit("v8/src/trap-handler/handler-inside-posix.h", rep(
    "#if V8_OS_LINUX || V8_OS_FREEBSD\nconstexpr int kOobSignal = SIGSEGV;",
    "#if V8_OS_LINUX || V8_OS_FREEBSD || V8_OS_HAIKU\nconstexpr int kOobSignal = SIGSEGV;"),
    "kOobSignal (trap handler stays disabled on Haiku)")
PY
echo "==> fixes applied"

if [ ! -f out/Release/gen/src/tint/lang/core/enums.cc ]; then
  echo
  echo "==> Reminder: Tint's generated sources are still missing (the one failure"
  echo "    in Dawn/Tint). See the end of haiku-fixes-pass5.sh for the Go step."
fi

echo "==> Now run:"
echo "  export RUSTC_BOOTSTRAP=1"
echo "  export PKG_CONFIG_PATH=~/config/non-packaged/lib/pkgconfig:\$PKG_CONFIG_PATH"
echo "  ninja -C out/Release -k 0 chrome 2>&1 | tee ~/build7.log"
