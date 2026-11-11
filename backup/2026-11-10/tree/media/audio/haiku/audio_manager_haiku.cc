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
