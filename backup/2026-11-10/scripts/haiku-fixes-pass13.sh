#!/bin/bash
# Chromium-HaikuOS: fixes for the final `chrome` link failures in build12.log
# (pass 13). Safe to re-run.
#  - media: CreateAudioManager (Haiku gets the fake/silent audio manager for
#    now) and the Linux/BSD feature flags that Haiku code references.
#  - content: FilePathWatcher (same no-op stub Chromium uses on other
#    platforms without inotify/kqueue).
#  - __cxa_thread_atexit: small helper library linked via compat/lib.
# Recompiles 3 files, then relinks chrome. No gn regeneration.
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
    else:
        print("    already done", path, what)

# 1. media/base/media_switches.cc: the Linux/BSD feature block (vaapi,
#    pulseaudio loopback, audio backend) was left BSD-only, but the header
#    declares it for Haiku too. Define it for Haiku, with the FreeBSD default
#    ("auto") for the audio-backend parameter.
def switches(s):
    m = re.search(r'^(#if [^\n]*)\n(?=// Enable vaapi/v4l2 video decoding)', s, re.M)
    if not m:
        return None
    line = m.group(1)
    if "IS_HAIKU" not in line:
        s = s[:m.start(1)] + line + " || BUILDFLAG(IS_HAIKU)" + s[m.end(1):]
    if "kAudioBackendParam" in s and "#else  // FreeBSD, Haiku" not in s:
        s2, n = re.subn(r'#elif BUILDFLAG\(IS_FREEBSD\)(\s*\n\s*AudioBackend::kAuto,)',
                        r'#else  // FreeBSD, Haiku\1', s, count=1)
        if not n:
            print("    WARN audio-backend default not found (send a screenshot)")
        s = s2
    return s
edit("media/base/media_switches.cc", switches, "feature flags")

# 2. media/audio: no Haiku audio backend yet -> FakeAudioManager (silent).
AUDIO = '''
// Chromium-HaikuOS: no native Haiku audio backend yet; audio is silent.
#include "build/build_config.h"
#if BUILDFLAG(IS_HAIKU)
#include <memory>
#include <utility>
namespace media {
std::unique_ptr<AudioManager> CreateAudioManager(
    std::unique_ptr<AudioThread> audio_thread,
    AudioLogFactory* audio_log_factory);
std::unique_ptr<AudioManager> CreateAudioManager(
    std::unique_ptr<AudioThread> audio_thread,
    AudioLogFactory* audio_log_factory) {
  return std::make_unique<FakeAudioManager>(std::move(audio_thread),
                                            audio_log_factory);
}
}  // namespace media
#endif  // BUILDFLAG(IS_HAIKU)
'''
edit("media/audio/fake_audio_manager.cc",
     lambda s: s if "Chromium-HaikuOS: no native Haiku audio" in s else s + AUDIO,
     "CreateAudioManager")

# 3. content FilePathWatcher: same as file_path_watcher_stub.cc.
WATCH = '''
// Chromium-HaikuOS: no file watching backend on Haiku yet. Same behaviour
// as file_path_watcher_stub.cc (Watch() reports failure).
#include "build/build_config.h"
#if BUILDFLAG(IS_HAIKU)
#include <limits>
#include <memory>
#include "base/notimplemented.h"
namespace content {
namespace {
class HaikuFilePathWatcherImpl : public FilePathWatcher::PlatformDelegate {
 public:
  HaikuFilePathWatcherImpl() = default;
  HaikuFilePathWatcherImpl(const HaikuFilePathWatcherImpl&) = delete;
  HaikuFilePathWatcherImpl& operator=(const HaikuFilePathWatcherImpl&) =
      delete;
  ~HaikuFilePathWatcherImpl() override = default;

  bool Watch(const base::FilePath& path,
             Type type,
             const FilePathWatcher::Callback& callback) override {
    NOTIMPLEMENTED_LOG_ONCE();
    return false;
  }
  void Cancel() override { set_cancelled(); }
};
}  // namespace

FilePathWatcher::FilePathWatcher()
    : FilePathWatcher(std::make_unique<HaikuFilePathWatcherImpl>()) {}

// static
size_t FilePathWatcher::GetQuotaLimitImpl() {
  return std::numeric_limits<size_t>::max();
}
}  // namespace content
#endif  // BUILDFLAG(IS_HAIKU)
'''
edit("content/browser/file_system_access/file_path_watcher/file_path_watcher.cc",
     lambda s: s if "Chromium-HaikuOS: no file watching backend" in s else s + WATCH,
     "FilePathWatcher stub")
PY

# 4. __cxa_thread_atexit helper library.
LIB="$SRC/build/config/haiku/compat/lib"
mkdir -p "$LIB"
cat > "$LIB/haiku_cxa_thread_atexit.c" <<'EOF'
/* Chromium-HaikuOS: __cxa_thread_atexit for thread_local objects with
 * destructors. Haiku's libroot does not provide it and Chromium's
 * libc++abi build leaves it out on this target. Destructors registered on
 * a thread run (newest first) when that thread exits, through a pthread
 * key destructor. As with libc++abi's fallback, destructors registered on
 * the main thread are not run at process exit. */
#include <pthread.h>
#include <stdlib.h>

typedef void (*haiku_tls_dtor_fn)(void*);

struct haiku_tls_dtor {
    haiku_tls_dtor_fn fn;
    void* obj;
    struct haiku_tls_dtor* next;
};

static pthread_key_t g_key;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static void run_dtors(void* p)
{
    struct haiku_tls_dtor* n = (struct haiku_tls_dtor*)p;
    while (n != NULL) {
        struct haiku_tls_dtor* next = n->next;
        n->fn(n->obj);
        free(n);
        n = next;
    }
}

static void make_key(void)
{
    pthread_key_create(&g_key, run_dtors);
}

__attribute__((visibility("default")))
int __cxa_thread_atexit(haiku_tls_dtor_fn fn, void* obj, void* dso_symbol)
{
    (void)dso_symbol;
    pthread_once(&g_once, make_key);
    struct haiku_tls_dtor* n = (struct haiku_tls_dtor*)malloc(sizeof(*n));
    if (n == NULL)
        return -1;
    n->fn = fn;
    n->obj = obj;
    n->next = (struct haiku_tls_dtor*)pthread_getspecific(g_key);
    if (pthread_setspecific(g_key, n) != 0) {
        free(n);
        return -1;
    }
    return 0;
}
EOF
AR=$(command -v llvm-ar || command -v ar)
( cd "$LIB" && clang -fPIC -O2 -c haiku_cxa_thread_atexit.c -o haiku_cxa_thread_atexit.o \
    && rm -f libhaikucompat.a && "$AR" rcs libhaikucompat.a haiku_cxa_thread_atexit.o )
echo "==> built $LIB/libhaikucompat.a"

# The build's "-lm" resolves to compat/lib/libm.a (Haiku's libm is part of
# libroot); make it pull in libgnu (pass 12) and the helper library.
cat > "$LIB/libm.a" <<'EOF'
/* Haiku: libm is part of libroot. Pull in libgnu (*_getaffinity) and
   Chromium-HaikuOS helpers (__cxa_thread_atexit). pass 12 + pass 13 */
INPUT(AS_NEEDED(-lgnu) -lhaikucompat)
EOF
echo "==> updated linker script $LIB/libm.a"

echo "==> Now run:"
echo "  ninja -C out/Release -j8 -k 0 chrome 2>&1 | tee ~/build13.log"
