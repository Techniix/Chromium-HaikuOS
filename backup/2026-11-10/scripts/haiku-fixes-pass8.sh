#!/bin/bash
# Chromium-HaikuOS: fixes for the failures in build7.log (pass 8).
# Run after passes 3-7. Safe to re-run.
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

# V8 trap handler header: the FreeBSD patch had already added OpenBSD to the
# line pass 7 looked for, so match whatever list is there.
def oob(s):
    if "V8_OS_HAIKU\nconstexpr int kOobSignal = SIGSEGV;" in s: return s
    t, n = re.subn(r"^(#if V8_OS_LINUX \|\| V8_OS_FREEBSD[^\n]*)\n(constexpr int kOobSignal = SIGSEGV;)",
                   r"\1 || V8_OS_HAIKU\n\2", s, count=1, flags=re.M)
    return t if n else None
edit("v8/src/trap-handler/handler-inside-posix.h", oob, "kOobSignal")

# net: Haiku only has struct ip_mreq (no ip_mreqn) and no
# IP_DEFAULT_MULTICAST_TTL. Provide a Linux-layout ip_mreqn: Haiku reads the
# leading ip_mreq part (group + INADDR_ANY interface), so joins use the
# default interface; picking an IPv4 multicast interface by index is ignored.
def mreqn(s):
    if "Haiku has only struct ip_mreq" in s: return s
    m = re.search(r"^namespace ", s, flags=re.M)
    if not m: return None
    block = """#if defined(__HAIKU__)
// Haiku has only struct ip_mreq; this matches Linux's layout, whose leading
// part is ip_mreq (group, interface address).
struct ip_mreqn {
  struct in_addr imr_multiaddr;
  struct in_addr imr_address;
  int imr_ifindex;
};
#ifndef IP_DEFAULT_MULTICAST_TTL
#define IP_DEFAULT_MULTICAST_TTL 1
#endif
#endif  // __HAIKU__

"""
    return s[:m.start()] + block + s[m.start():]
edit("net/socket/udp_socket_posix.cc", mreqn, "ip_mreqn")
PY
echo "==> fixes applied"

if [ ! -f out/Release/gen/src/tint/lang/core/enums.cc ]; then
  cat <<'EOF'

==> Still needed: Tint's generated sources (the remaining Dawn/Tint failure).
    ~/dawn-for-tint-gen.tar.gz was made by pass 5. On any Linux/macOS/WSL
    machine with Go 1.26+ and internet:
        mkdir dawn-gen && cd dawn-gen && tar xzf /path/to/dawn-for-tint-gen.tar.gz
        cd dawn && GO111MODULE=on CGO_ENABLED=0 go run ./tools/src/cmd/gen/sources "$PWD/../out"
        cd .. && tar czf tint-gen.tar.gz -C out src
    Then on Haiku:
        tar xzf tint-gen.tar.gz -C ~/Chromium-HaikuOS/work/chromium-156.0.8078.79/out/Release/gen
EOF
fi

echo "==> Now run:"
echo "  ninja -C out/Release -k 0 chrome 2>&1 | tee ~/build8.log"
