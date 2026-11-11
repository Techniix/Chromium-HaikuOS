#!/bin/bash
# Chromium-HaikuOS pass 15: problems seen in run2.log (YouTube session).
#
#  1. AV1 video never decodes (dav1d "DecoderStatus::1"). Haiku's errno values
#     are negative, so dav1d returns EAGAIN as-is, but Chromium compares with
#     -EAGAIN (the Linux convention) and treats every "try again" as a fatal
#     error. Use dav1d's own DAV1D_ERR(EAGAIN).
#  2. The video capture service crashed (null pointer) when a page listed
#     cameras: Haiku had no capture factory at all. Give it one that reports
#     no devices.
#  3. A tab died with V8 "Check failed: success." Most likely V8 failed to
#     decommit memory (mmap MAP_FIXED over part of a reservation) or to change
#     page permissions. On Haiku, log the failing call (address, size, errno)
#     and fall back to an mprotect/zero/madvise sequence for decommit.
#     If it still happens, the log line tells us exactly what failed.
# Safe to re-run. Rebuild afterwards (V8 base changes rerun the snapshot step).
set -euo pipefail

SRC=${SRC:-$HOME/Chromium-HaikuOS/work/chromium-156.0.8078.79}
cd "$SRC"

python3 <<'PY'
import os, sys

TAG = "Chromium-HaikuOS"
fails = []

def edit(path, fn, what=""):
    if not os.path.exists(path):
        print("    WARN missing", path); fails.append(path); return
    s = open(path).read()
    t = fn(s)
    if t is None:
        print("    WARN pattern not found:", path, what); fails.append(path); return
    if t != s:
        open(path, "w").write(t); print("    patched", path, what)
    else:
        print("    already done", path, what)

def once(marker, fn):
    return lambda s: s if marker in s else fn(s)

def sub1(s, old, new):
    if s is None or s.count(old) != 1:
        return None
    return s.replace(old, new, 1)

# 1. dav1d EAGAIN ----------------------------------------------------------
def dav1d(s):
    n = s.count("-EAGAIN")
    if n == 0:
        return None
    return s.replace("-EAGAIN", "DAV1D_ERR(EAGAIN)")
edit("media/filters/dav1d_video_decoder.cc",
     lambda s: s if "-EAGAIN" not in s and "DAV1D_ERR(EAGAIN)" in s else dav1d(s),
     "EAGAIN sign")

# 2. Video capture: empty device list on Haiku ------------------------------
edit("media/capture/video/create_video_capture_device_factory.cc",
     once("Chromium-HaikuOS: no camera backend", lambda s: sub1(s,
        "#else\n  NOTIMPLEMENTED();\n  return nullptr;\n#endif\n",
        "#elif BUILDFLAG(IS_HAIKU)\n"
        "  // Chromium-HaikuOS: no camera backend yet; report no devices instead\n"
        "  // of returning null (which crashed the video capture service).\n"
        "  auto result = std::make_unique<FakeVideoCaptureDeviceFactory>();\n"
        "  result->SetToCustomDevicesConfig({});\n"
        "  return result;\n"
        "#else\n  NOTIMPLEMENTED();\n  return nullptr;\n#endif\n")),
     "empty capture factory")

# 3. V8 page decommit / permissions -----------------------------------------
P = "v8/src/base/platform/platform-posix.cc"
def v8posix(s):
    s = sub1(s, "#include <OS.h>  // find_thread, rename_thread\n",
             "#include <OS.h>  // find_thread, rename_thread\n"
             "#include <string.h>  // " + TAG + ": memset, strerror\n"
             "#include <atomic>\n")
    s = sub1(s,
        "  if (V8_UNLIKELY(ret == MAP_FAILED)) {\n"
        "    // Decommitting pages can fail if the limit of VMAs is exceeded.\n"
        "    CHECK_EQ(ENOMEM, errno);\n"
        "    return false;\n"
        "  }\n",
        "  if (V8_UNLIKELY(ret == MAP_FAILED)) {\n"
        "#if V8_OS_HAIKU\n"
        "    // " + TAG + ": replacing part of a reservation with a new mapping\n"
        "    // can fail on Haiku. Log it, then decommit in place instead: the\n"
        "    // caller needs the range inaccessible and zero-filled.\n"
        "    {\n"
        "      const int err = errno;\n"
        "      static std::atomic<int> logged{0};\n"
        "      if (logged.fetch_add(1, std::memory_order_relaxed) < 20) {\n"
        "        fprintf(stderr,\n"
        "                \"[haiku-v8] DecommitPages(%p, %zu): mmap failed: %s (%d)\\n\",\n"
        "                address, size, strerror(err), err);\n"
        "      }\n"
        "      if (mprotect(address, size, PROT_READ | PROT_WRITE) == 0) {\n"
        "        memset(address, 0, size);\n"
        "        madvise(address, size, MADV_DONTNEED);\n"
        "        if (mprotect(address, size, PROT_NONE) == 0) return true;\n"
        "      }\n"
        "      fprintf(stderr, \"[haiku-v8] DecommitPages fallback failed: %s\\n\",\n"
        "              strerror(errno));\n"
        "      return false;\n"
        "    }\n"
        "#endif\n"
        "    // Decommitting pages can fail if the limit of VMAs is exceeded.\n"
        "    CHECK_EQ(ENOMEM, errno);\n"
        "    return false;\n"
        "  }\n")
    s = sub1(s,
        "  if (ret != 0) CHECK_EQ(ENOMEM, errno);\n",
        "#if V8_OS_HAIKU\n"
        "  if (ret != 0) {  // " + TAG + ": say what failed before V8 aborts.\n"
        "    const int err = errno;\n"
        "    fprintf(stderr,\n"
        "            \"[haiku-v8] SetPermissions(%p, %zu, prot=%d) failed: %s (%d)\\n\",\n"
        "            address, size, prot, strerror(err), err);\n"
        "    errno = err;\n"
        "  }\n"
        "#endif\n"
        "  if (ret != 0) CHECK_EQ(ENOMEM, errno);\n")
    return s
edit(P, once("[haiku-v8] DecommitPages", v8posix), "decommit fallback + logging")

if fails:
    print("\n==> Some edits did not apply; send me a screenshot of the WARN lines.")
    sys.exit(1)
PY

echo "==> Now rebuild:"
echo "  ninja -C out/Release -j8 -k 0 chrome 2>&1 | tee ~/build15.log"
