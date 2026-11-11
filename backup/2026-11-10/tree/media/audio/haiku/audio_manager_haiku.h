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
