#!/bin/bash
# Chromium-HaikuOS pass 16:
#  1. Sound: a native Haiku audio backend (Media Kit / BSoundPlayer) replaces
#     the silent fake audio manager from pass 13. Output only; microphone
#     input stays a silent fake for now.
#  2. V8 diagnostics: the "Check failed: success." tab crash did not come from
#     the memory calls instrumented in pass 15, so give each remaining
#     CHECK(success) in V8 its own message. The next crash names its source.
# Safe to re-run. Changes BUILD.gn (ninja reruns gn: keep the exports set).
set -euo pipefail

SRC=${SRC:-$HOME/Chromium-HaikuOS/work/chromium-156.0.8078.79}
cd "$SRC"
LIB=build/config/haiku/compat/lib

for h in /boot/system/develop/headers/os/media/SoundPlayer.h \
         /boot/system/develop/headers/os/app/Application.h; do
    [ -f "$h" ] || { echo "ERROR: $h missing (pkgman install haiku_devel)"; exit 1; }
done

# --- 1a. Chromium-side audio manager --------------------------------------
mkdir -p media/audio/haiku
cat > media/audio/haiku/audio_manager_haiku.h <<'EOF'
// Copyright 2026 The Chromium Authors and Chromium-HaikuOS contributors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Chromium-HaikuOS: audio output through Haiku's Media Kit (BSoundPlayer).
//
// The Media Kit classes are C++ built against Haiku's libstdc++, while
// Chromium is built against its own libc++. To keep the two apart, the Media
// Kit calls live in a small C-ABI shim (chromium_haiku_audio_*), built
// outside of GN into build/config/haiku/compat/lib/libhaikucompat.a and
// linked through the compat libm.a linker script. This file only talks to
// that C interface.
//
// Output only for now; capture (microphone) streams are silent fakes.

#ifndef MEDIA_AUDIO_HAIKU_AUDIO_MANAGER_HAIKU_H_
#define MEDIA_AUDIO_HAIKU_AUDIO_MANAGER_HAIKU_H_

#include <memory>
#include <string>
#include <string_view>

#include "media/audio/audio_manager_base.h"

namespace media {

class MEDIA_EXPORT AudioManagerHaiku : public AudioManagerBase {
 public:
  AudioManagerHaiku(std::unique_ptr<AudioThread> audio_thread,
                    AudioLogFactory* audio_log_factory);

  AudioManagerHaiku(const AudioManagerHaiku&) = delete;
  AudioManagerHaiku& operator=(const AudioManagerHaiku&) = delete;

  ~AudioManagerHaiku() override;

  // AudioManager:
  bool HasAudioOutputDevices() override;
  bool HasAudioInputDevices() override;
  const std::string_view GetName() override;

  // AudioManagerBase:
  AudioOutputStream* MakeLinearOutputStream(
      const AudioParameters& params,
      const LogCallback& log_callback) override;
  AudioOutputStream* MakeLowLatencyOutputStream(
      const AudioParameters& params,
      const std::string& device_id,
      const LogCallback& log_callback) override;
  AudioInputStream* MakeLinearInputStream(
      const AudioParameters& params,
      const std::string& device_id,
      const LogCallback& log_callback) override;
  AudioInputStream* MakeLowLatencyInputStream(
      const AudioParameters& params,
      const std::string& device_id,
      const LogCallback& log_callback) override;
  AudioParameters GetInputStreamParameters(
      const std::string& device_id) override;

 protected:
  AudioParameters GetPreferredOutputStreamParameters(
      const std::string& output_device_id,
      const AudioParameters& input_params) override;
};

}  // namespace media

#endif  // MEDIA_AUDIO_HAIKU_AUDIO_MANAGER_HAIKU_H_
EOF
cat > media/audio/haiku/audio_manager_haiku.cc <<'EOF'
// Copyright 2026 The Chromium Authors and Chromium-HaikuOS contributors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Chromium-HaikuOS: see audio_manager_haiku.h for the overall design.

#include "media/audio/haiku/audio_manager_haiku.h"

#include <stddef.h>
#include <string.h>

#include <algorithm>
#include <atomic>
#include <memory>
#include <utility>

#include "base/compiler_specific.h"
#include "base/containers/span.h"
#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/raw_ptr_exclusion.h"
#include "base/synchronization/lock.h"
#include "base/thread_annotations.h"
#include "base/time/time.h"
#include "media/audio/audio_io.h"
#include "media/audio/fake_audio_input_stream.h"
#include "media/base/audio_bus.h"
#include "media/base/audio_glitch_info.h"
#include "media/base/audio_parameters.h"
#include "media/base/audio_pull_fifo.h"
#include "media/base/audio_sample_types.h"
#include "media/base/audio_timestamp_helper.h"
#include "media/base/channel_layout.h"

// C interface of the Media Kit shim (build/config/haiku/compat/lib,
// haiku_media_audio.cpp). All functions are safe to call from any thread.
extern "C" {
typedef void (*chromium_haiku_audio_fill_fn)(void* cookie,
                                             void* buffer,
                                             size_t size);
// Creates a BSoundPlayer producing interleaved float samples. Returns null on
// failure (e.g. media_server not running).
void* chromium_haiku_audio_open(float frame_rate,
                                unsigned int channels,
                                size_t buffer_bytes,
                                chromium_haiku_audio_fill_fn fill,
                                void* cookie);
// Starts playback; |fill| is then called on the Media Kit's thread.
int chromium_haiku_audio_start(void* handle);
// Stops playback. Blocks until |fill| is no longer running.
void chromium_haiku_audio_stop(void* handle);
// Stops (if needed) and destroys the player.
void chromium_haiku_audio_close(void* handle);
// Output latency reported by the Media Kit, in microseconds.
long long chromium_haiku_audio_latency_us(void* handle);
}

namespace media {

namespace {

constexpr int kDefaultSampleRate = 48000;
// ~21 ms at 48 kHz. Chromium's renderer asks for this many frames per
// OnMoreData(); the Media Kit buffer size can differ, AudioPullFifo adapts.
constexpr int kDefaultOutputBufferSize = 1024;
constexpr int kDefaultInputBufferSize = 1024;

class HaikuAudioOutputStream : public AudioOutputStream {
 public:
  HaikuAudioOutputStream(AudioManagerBase* manager,
                         const AudioParameters& params)
      : manager_(manager),
        params_(params),
        fifo_(params.channels(),
              params.frames_per_buffer(),
              base::BindRepeating(&HaikuAudioOutputStream::PullData,
                                  base::Unretained(this))) {}

  HaikuAudioOutputStream(const HaikuAudioOutputStream&) = delete;
  HaikuAudioOutputStream& operator=(const HaikuAudioOutputStream&) = delete;

  ~HaikuAudioOutputStream() override { DCHECK(!handle_); }

  // AudioOutputStream:
  bool Open() override {
    const size_t bytes = static_cast<size_t>(params_.frames_per_buffer()) *
                         params_.channels() * sizeof(float);
    handle_ = chromium_haiku_audio_open(
        static_cast<float>(params_.sample_rate()), params_.channels(), bytes,
        &HaikuAudioOutputStream::FillThunk, this);
    if (!handle_) {
      LOG(ERROR) << "Haiku: could not open a BSoundPlayer (is media_server "
                    "running?)";
      return false;
    }
    return true;
  }

  void Start(AudioSourceCallback* callback) override {
    DCHECK(callback);
    if (!handle_) {
      callback->OnError(AudioSourceCallback::ErrorType::kUnknown);
      return;
    }
    {
      base::AutoLock lock(lock_);
      callback_ = callback;
      fifo_.Clear();
    }
    latency_ = base::Microseconds(chromium_haiku_audio_latency_us(handle_));
    if (chromium_haiku_audio_start(handle_) != 0) {
      {
        base::AutoLock lock(lock_);
        callback_ = nullptr;
      }
      callback->OnError(AudioSourceCallback::ErrorType::kUnknown);
    }
  }

  void Stop() override {
    if (handle_) {
      chromium_haiku_audio_stop(handle_);  // Waits for FillThunk to finish.
    }
    base::AutoLock lock(lock_);
    callback_ = nullptr;
  }

  void SetVolume(double volume) override {
    volume_.store(static_cast<float>(std::clamp(volume, 0.0, 1.0)),
                  std::memory_order_relaxed);
  }

  void GetVolume(double* volume) override {
    *volume = volume_.load(std::memory_order_relaxed);
  }

  void Close() override {
    Stop();
    if (handle_) {
      chromium_haiku_audio_close(handle_);
      handle_ = nullptr;
    }
    // Deletes |this|.
    manager_->ReleaseOutputStream(this);
  }

  void Flush() override {}

 private:
  static void FillThunk(void* cookie, void* buffer, size_t size) {
    static_cast<HaikuAudioOutputStream*>(cookie)->Fill(buffer, size);
  }

  // Called on the Media Kit's playback thread.
  void Fill(void* buffer, size_t size) {
    const int channels = params_.channels();
    const int frames =
        static_cast<int>(size / (sizeof(float) * static_cast<size_t>(channels)));
    base::AutoLock lock(lock_);
    if (!callback_ || frames <= 0) {
      UNSAFE_BUFFERS(memset(buffer, 0, size));
      return;
    }
    // The Media Kit keeps its buffer size for the lifetime of the player, so
    // this allocates once.
    if (!output_bus_ || output_bus_->frames() != frames) {
      output_bus_ = AudioBus::Create(channels, frames);
    }
    fifo_.Consume(output_bus_.get(), frames);
    const float volume = volume_.load(std::memory_order_relaxed);
    if (volume != 1.0f) {
      output_bus_->Scale(volume);
    }
    output_bus_->ToInterleaved<Float32SampleTypeTraits>(UNSAFE_BUFFERS(
        base::span<float>(static_cast<float*>(buffer),
                          static_cast<size_t>(frames) * channels)));
  }

  // AudioPullFifo::ReadCB; runs inside Fill() with |lock_| held.
  void PullData(int frame_delay, AudioBus* dest)
      EXCLUSIVE_LOCKS_REQUIRED(lock_) {
    lock_.AssertAcquired();
    const base::TimeDelta delay =
        AudioTimestampHelper::FramesToTime(frame_delay,
                                           params_.sample_rate()) +
        latency_;
    const int filled = callback_->OnMoreData(
        BoundedDelay(delay), base::TimeTicks::Now(), AudioGlitchInfo(), dest);
    if (filled < dest->frames()) {
      dest->ZeroFramesPartial(filled, dest->frames() - filled);
    }
  }

  const raw_ptr<AudioManagerBase> manager_;
  const AudioParameters params_;
  // Opaque shim handle (Stream*), not owned by PartitionAlloc.
  RAW_PTR_EXCLUSION void* handle_ = nullptr;
  base::TimeDelta latency_;
  std::atomic<float> volume_{1.0f};

  base::Lock lock_;
  raw_ptr<AudioSourceCallback> callback_ GUARDED_BY(lock_) = nullptr;
  AudioPullFifo fifo_ GUARDED_BY(lock_);
  std::unique_ptr<AudioBus> output_bus_ GUARDED_BY(lock_);
};

}  // namespace

AudioManagerHaiku::AudioManagerHaiku(std::unique_ptr<AudioThread> audio_thread,
                                     AudioLogFactory* audio_log_factory)
    : AudioManagerBase(std::move(audio_thread), audio_log_factory) {}

AudioManagerHaiku::~AudioManagerHaiku() = default;

bool AudioManagerHaiku::HasAudioOutputDevices() {
  return true;
}

bool AudioManagerHaiku::HasAudioInputDevices() {
  return false;
}

const std::string_view AudioManagerHaiku::GetName() {
  return "Haiku Media Kit";
}

AudioOutputStream* AudioManagerHaiku::MakeLinearOutputStream(
    const AudioParameters& params,
    const LogCallback& log_callback) {
  return new HaikuAudioOutputStream(this, params);
}

AudioOutputStream* AudioManagerHaiku::MakeLowLatencyOutputStream(
    const AudioParameters& params,
    const std::string& device_id,
    const LogCallback& log_callback) {
  return new HaikuAudioOutputStream(this, params);
}

AudioInputStream* AudioManagerHaiku::MakeLinearInputStream(
    const AudioParameters& params,
    const std::string& device_id,
    const LogCallback& log_callback) {
  return FakeAudioInputStream::MakeFakeStream(this, params);
}

AudioInputStream* AudioManagerHaiku::MakeLowLatencyInputStream(
    const AudioParameters& params,
    const std::string& device_id,
    const LogCallback& log_callback) {
  return FakeAudioInputStream::MakeFakeStream(this, params);
}

AudioParameters AudioManagerHaiku::GetInputStreamParameters(
    const std::string& device_id) {
  return AudioParameters(AudioParameters::AUDIO_PCM_LOW_LATENCY,
                         ChannelLayoutConfig::Stereo(), kDefaultSampleRate,
                         kDefaultInputBufferSize);
}

AudioParameters AudioManagerHaiku::GetPreferredOutputStreamParameters(
    const std::string& output_device_id,
    const AudioParameters& input_params) {
  ChannelLayoutConfig layout = ChannelLayoutConfig::Stereo();
  int sample_rate = kDefaultSampleRate;
  if (input_params.IsValid()) {
    sample_rate = input_params.sample_rate();
    // Haiku's system mixer handles mono and stereo everywhere; keep anything
    // wider as stereo until multichannel output is tested.
    if (input_params.channels() <= 2) {
      layout = input_params.channel_layout_config();
    }
  }
  return AudioParameters(AudioParameters::AUDIO_PCM_LOW_LATENCY, layout,
                         sample_rate, kDefaultOutputBufferSize);
}

// Declared next to its only caller in audio_manager.cc; each platform provides
// one definition.
std::unique_ptr<AudioManager> CreateAudioManager(
    std::unique_ptr<AudioThread> audio_thread,
    AudioLogFactory* audio_log_factory);

std::unique_ptr<AudioManager> CreateAudioManager(
    std::unique_ptr<AudioThread> audio_thread,
    AudioLogFactory* audio_log_factory) {
  return std::make_unique<AudioManagerHaiku>(std::move(audio_thread),
                                             audio_log_factory);
}

}  // namespace media
EOF
echo "    wrote media/audio/haiku/audio_manager_haiku.{h,cc}"

# --- 1b. Media Kit shim, built with the system compiler ---------------------
mkdir -p "$LIB"
cat > "$LIB/haiku_media_audio.cpp" <<'EOF'
/*
 * Chromium-HaikuOS: C-ABI shim around Haiku's Media Kit (BSoundPlayer) for
 * media/audio/haiku/audio_manager_haiku.cc.
 *
 * Built with the system compiler and Haiku's own headers/libstdc++ into
 * libhaikucompat.a (scripts build it, not GN), so Chromium's libc++ never
 * sees Haiku's C++ headers. Linked with libbe and libmedia.
 *
 * The Media Kit needs a BApplication (be_app). Chromium's audio service runs
 * in a utility process that has none, so the first open creates one on its
 * own thread, the same way SDL does for its Haiku audio backend.
 */

#include <Application.h>
#include <OS.h>
#include <SoundPlayer.h>

#include <stddef.h>
#include <stdlib.h>

extern "C" {
typedef void (*chromium_haiku_audio_fill_fn)(void* cookie, void* buffer,
	size_t size);
}

namespace {

int32 sAppStarted = 0;
sem_id sAppReady = -1;

status_t
app_thread(void*)
{
	BApplication* app
		= new BApplication("application/x-vnd.chromium-haiku-audio");
	release_sem(sAppReady);
	app->Run();
	delete app;
	return B_OK;
}

bool
ensure_app()
{
	if (be_app != NULL)
		return true;
	if (atomic_test_and_set(&sAppStarted, 1, 0) == 0) {
		sAppReady = create_sem(0, "chromium audio app ready");
		thread_id thread = spawn_thread(app_thread, "chromium audio app",
			B_NORMAL_PRIORITY, NULL);
		if (thread < 0)
			return false;
		resume_thread(thread);
		acquire_sem_etc(sAppReady, 1, B_RELATIVE_TIMEOUT, 5000000);
	} else {
		for (int i = 0; i < 500 && be_app == NULL; i++)
			snooze(10000);
	}
	return be_app != NULL;
}

struct Stream {
	BSoundPlayer* player;
	chromium_haiku_audio_fill_fn fill;
	void* cookie;
};

void
play_buffer(void* cookie, void* buffer, size_t size,
	const media_raw_audio_format&)
{
	Stream* stream = static_cast<Stream*>(cookie);
	stream->fill(stream->cookie, buffer, size);
}

}	// namespace

extern "C" {

void*
chromium_haiku_audio_open(float frameRate, unsigned int channels,
	size_t bufferBytes, chromium_haiku_audio_fill_fn fill, void* cookie)
{
	if (fill == NULL || !ensure_app())
		return NULL;

	media_raw_audio_format format = media_raw_audio_format::wildcard;
	format.frame_rate = frameRate;
	format.channel_count = channels;
	format.format = media_raw_audio_format::B_AUDIO_FLOAT;
	format.byte_order = B_MEDIA_HOST_ENDIAN;
	format.buffer_size = bufferBytes;

	// Plain malloc/free for our own POD state: this object is compiled
	// against libstdc++ but linked into Chromium, so avoid relying on any
	// particular operator new/delete variant beyond the basic ones the Media
	// Kit classes need.
	Stream* stream = static_cast<Stream*>(malloc(sizeof(Stream)));
	if (stream == NULL)
		return NULL;
	stream->fill = fill;
	stream->cookie = cookie;
	stream->player = new BSoundPlayer(&format, "Chromium", play_buffer, NULL,
		stream);
	if (stream->player->InitCheck() != B_OK) {
		delete stream->player;
		free(stream);
		return NULL;
	}
	return stream;
}

int
chromium_haiku_audio_start(void* handle)
{
	Stream* stream = static_cast<Stream*>(handle);
	if (stream->player->Start() != B_OK)
		return -1;
	stream->player->SetHasData(true);
	return 0;
}

void
chromium_haiku_audio_stop(void* handle)
{
	Stream* stream = static_cast<Stream*>(handle);
	stream->player->SetHasData(false);
	stream->player->Stop(true, true);
}

void
chromium_haiku_audio_close(void* handle)
{
	Stream* stream = static_cast<Stream*>(handle);
	chromium_haiku_audio_stop(handle);
	delete stream->player;
	free(stream);
}

long long
chromium_haiku_audio_latency_us(void* handle)
{
	return static_cast<Stream*>(handle)->player->Latency();
}

}	// extern "C"
EOF
CXX_SYS=$(command -v g++ || command -v c++)
CC_SYS=$(command -v clang || command -v cc)
AR=$(command -v llvm-ar || command -v ar)
(
  cd "$LIB"
  "$CXX_SYS" -fPIC -O2 -fno-exceptions -fno-rtti -fno-sized-deallocation \
      -c haiku_media_audio.cpp -o haiku_media_audio.o
  "$CC_SYS" -fPIC -O2 -c haiku_cxa_thread_atexit.c -o haiku_cxa_thread_atexit.o
  rm -f libhaikucompat.a
  "$AR" rcs libhaikucompat.a haiku_cxa_thread_atexit.o haiku_media_audio.o
)
echo "    rebuilt $LIB/libhaikucompat.a (thread_atexit + Media Kit shim)"

cat > "$LIB/libm.a" <<'EOF'
/* Haiku: libm is part of libroot. Pull in libgnu (*_getaffinity), the
   Chromium-HaikuOS helpers (__cxa_thread_atexit, Media Kit audio shim) and
   the Haiku kits the shim uses. pass 12 + 13 + 16 */
INPUT(AS_NEEDED(-lgnu) -lhaikucompat AS_NEEDED(-lmedia -lbe))
EOF
echo "    updated linker script $LIB/libm.a"

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

def sub1(s, old, new):
    if s is None or s.count(old) != 1:
        return None
    return s.replace(old, new, 1)

# --- 1c. GN: build the Haiku audio manager ---------------------------------
def gn(s):
    if "haiku/audio_manager_haiku.cc" in s:
        return s
    return sub1(s,
        '  if (is_bsd) {\n    sources += [ "sndio/audio_manager_sndio.cc" ]\n  }\n',
        '  if (is_bsd) {\n    sources += [ "sndio/audio_manager_sndio.cc" ]\n  }\n'
        '\n  # ' + TAG + ': Media Kit output (see haiku/audio_manager_haiku.h).\n'
        '  if (is_haiku) {\n    sources += [\n'
        '      "haiku/audio_manager_haiku.cc",\n'
        '      "haiku/audio_manager_haiku.h",\n    ]\n  }\n')
edit("media/audio/BUILD.gn", gn, "Haiku audio sources")

# --- 1d. Drop the pass-13 silent CreateAudioManager --------------------------
PASS13 = '''
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
     lambda s: s.replace(PASS13, "") if PASS13 in s else
               (s if "no native Haiku audio backend" not in s else None),
     "remove silent fallback")

# --- 2. V8: distinct messages for every CHECK(success) ----------------------
def msg(old_ctx, new_msg):
    def f(s):
        if new_msg in s:
            return s
        return sub1(s, old_ctx, old_ctx.replace(
            "CHECK(success);", 'CHECK_WITH_MSG(success, "' + new_msg + '");'))
    return f
edit("v8/src/compiler/pipeline.cc",
     msg("        &linkage, turboshaft_pipeline, &pipeline, data.osr_helper_ptr());\n    CHECK(success);",
         "Haiku: wasm wrapper code generation failed (pipeline.cc)"),
     "wrapper codegen check")
edit("v8/src/base/bounded-page-allocator.cc",
     msg("    success = page_allocator_->DecommitPages(raw_address, size);\n"
         "    // Since we require zero-initialized pages, we must fail here if we cannot\n"
         "    // decomitt the range.\n    CHECK(success);",
         "Haiku: BoundedPageAllocator::FreePages decommit failed"),
     "FreePages check")
edit("v8/src/sandbox/segmented-table.cc",
     msg("      PagePermissions::kReadWrite);\n  CHECK(success);",
         "Haiku: SegmentedTable unseal (kReadWrite) failed"),
     "unseal check")
edit("v8/src/sandbox/segmented-table.cc",
     msg("this->vas_->base(), read_only_reservation_size_, PagePermissions::kRead);\n  CHECK(success);",
         "Haiku: SegmentedTable seal (kRead) failed"),
     "seal check")

if fails:
    print("\n==> Some edits did not apply; send me a screenshot of the WARN lines.")
    sys.exit(1)
PY

echo "==> Now rebuild:"
echo "  ninja -C out/Release -j8 -k 0 chrome 2>&1 | tee ~/build16.log"
