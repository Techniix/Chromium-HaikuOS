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
