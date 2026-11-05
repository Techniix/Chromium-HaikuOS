# haikuify report

- Guards extended to Haiku: 2986 (in 1304 files)
- Guards left BSD-only (need a Haiku implementation): 39

## Hand-porting worklist

Each site below guards code that uses BSD-only interfaces. Haiku currently falls through to the other branch here; add a `BUILDFLAG(IS_HAIKU)` / `is_haiku` implementation or confirm the fallback is correct.


### `base/BUILD.gn`

- L1219: `if (is_bsd) {` — uses epoll-shim
- L2468: `if (is_bsd) {` — uses _bsd.cc

### `base/allocator/partition_allocator/src/partition_alloc/partition_alloc_base/threading/platform_thread_posix.cc`

- L21: `#if PA_BUILDFLAG(IS_LINUX) || PA_BUILDFLAG(IS_CHROMEOS) || PA_BUILDFLAG(IS_BSD)` — uses sys/syscall.h

### `base/allocator/partition_allocator/src/partition_alloc/stack/stack.cc`

- L22: `#if PA_BUILDFLAG(IS_BSD)` — uses pthread_np.h

### `base/base_paths_posix.cc`

- L29: `#if BUILDFLAG(IS_BSD)` — uses sys/sysctl.h

### `base/debug/debugger_posix.cc`

- L38: `#if BUILDFLAG(IS_APPLE) || BUILDFLAG(IS_BSD)` — uses sys/sysctl.h
- L67: `#if BUILDFLAG(IS_APPLE) || BUILDFLAG(IS_BSD)` — uses BeingDebugged() [BSD-only here], CTL_KERN, KERN_PROC, KERN_PROC_PID, VerifyDebugger() [BSD-only here], kinfo_, sysctl

### `base/debug/stack_trace_posix.cc`

- L329: `#if BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_ANDROID) || BUILDFLAG(IS_CHROMEOS) || BUILDFLAG(IS_BSD)` — uses AlarmSignalHandler() [BSD-only here], SYS_exit_group, syscall(
- L554: `#if BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_ANDROID) || BUILDFLAG(IS_CHROMEOS) || BUILDFLAG(IS_BSD)` — uses SYS_gettid, SYS_rt_tgsigqueueinfo, syscall(

### `base/message_loop/message_pump_glib.cc`

- L10: `#if BUILDFLAG(IS_BSD)` — uses pthread_np.h
- L66: `#if BUILDFLAG(IS_BSD)` — uses pthread_main_np

### `base/process/process_iterator.h`

- L115: `#elif BUILDFLAG(IS_APPLE) || BUILDFLAG(IS_BSD)` — uses kinfo_

### `base/process/process_posix.cc`

- L28: `#if BUILDFLAG(IS_MAC) || BUILDFLAG(IS_BSD)` — uses sys/event.h
- L32: `#if BUILDFLAG(IS_BSD)` — uses sys/sysctl.h
- L112: `#if BUILDFLAG(IS_MAC) || BUILDFLAG(IS_BSD)` — uses EVFILT_, NOTE_EXIT, WaitForSingleNonChildProcess() [BSD-only here], kevent, kqueue
- L377: `#if BUILDFLAG(IS_MAC) || BUILDFLAG(IS_BSD)` — uses WaitForSingleNonChildProcess() [BSD-only here]

### `base/profiler/stack_base_address_posix.cc`

- L22: `#if BUILDFLAG(IS_BSD)` — uses pthread_np.h

### `base/threading/platform_thread_posix.cc`

- L9: `#if BUILDFLAG(IS_BSD)` — uses pthread_np.h

### `base/threading/platform_thread_unittest.cc`

- L70: `#if BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_CHROMEOS) || BUILDFLAG(IS_BSD)` — uses sys/syscall.h
- L659: `#if BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_CHROMEOS) || BUILDFLAG(IS_BSD)` — uses CheckTidCacheCorrectWrapper() [BSD-only here], CreatePthreadToCheckCache() [BSD-only here], IsTidCacheCorrect() [BSD-only here], TestTidCacheCorrect() [BSD-only here], syscall(

### `chrome/browser/about_flags.cc`

- L979: `#if BUILDFLAG(IS_BSD)` — uses sndio

### `chrome/browser/flag_descriptions.h`

- L8876: `#if BUILDFLAG(IS_BSD)` — uses sndio

### `components/named_mojo_ipc_server/connection_info.h`

- L18: `#elif BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_BSD)` — uses sys/ucred.h

### `content/browser/BUILD.gn`

- L2466: `if (is_bsd) {` — uses _bsd.cc

### `content/common/BUILD.gn`

- L376: `if (is_bsd) {` — uses _bsd.cc, _bsd.h

### `content/utility/utility_main.cc`

- L48: `#if BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_CHROMEOS) || BUILDFLAG(IS_BSD)` — uses _bsd.h
- L68: `#if BUILDFLAG(IS_BSD)` — uses _bsd.h

### `media/audio/BUILD.gn`

- L297: `if (is_bsd) {` — uses sndio

### `media/base/media_switches.cc`

- L1495: `#if BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_BSD)` — uses sndio

### `media/ffmpeg/scripts/robo_lib/config.py`

- L228: `elif platform.system() == "FreeBSD":` — uses FreeBSD platform check (Python)
- L229: `self._host_operating_system = "freebsd"` — uses freebsd string (Python), not a list item

### `services/resource_coordinator/public/cpp/memory_instrumentation/BUILD.gn`

- L34: `if (is_bsd) {` — uses _bsd.cc

### `third_party/blink/renderer/platform/wtf/stack_util.cc`

- L25: `#if BUILDFLAG(IS_BSD)` — uses pthread_np.h

### `third_party/rust/chromium_crates_io/vendor/libc-v0_2/etc/libc-util.py`

- L410: `new.attributes = base.attributes | {"freebsd": str(vers)}` — uses freebsd string (Python), not a list item

### `third_party/wayland/BUILD.gn`

- L27: `if (is_bsd) {` — uses epoll-shim

### `tools/valgrind/asan/third_party/asan_symbolize.py`

- L361: `elif system in ['Linux', 'FreeBSD', 'NetBSD', 'SunOS']:` — uses FreeBSD platform check (Python)
- L452: `if self.system not in ['Linux', 'Darwin', 'FreeBSD', 'NetBSD', 'SunOS']:` — uses FreeBSD platform check (Python)

### `v8/tools/testrunner/local/utils.py`

- L80: `elif system == 'FreeBSD':` — uses FreeBSD platform check (Python)
- L81: `return 'freebsd'` — uses freebsd string (Python), not a list item

## Converted, but verify on Haiku

These guards now include Haiku, and the code they select uses BSD-libc functions. Run `tools/probe-haiku-libc.sh` on the Haiku machine; for any symbol it reports missing, add a Haiku branch or a shim (see `patches/haiku/` and `compat/`).


### `base/allocator/partition_allocator/src/partition_alloc/page_allocator_internals_posix.h`

- L321: `#if PA_BUILDFLAG(IS_APPLE) || PA_BUILDFLAG(IS_BSD)` — uses MADV_DONTNEED, MADV_FREE
- L322: `#if PA_BUILDFLAG(IS_BSD)` — uses MADV_FREE

### `base/allocator/partition_allocator/src/partition_alloc/partition_alloc_base/rand_util_posix.cc`

- L93: `#elif PA_BUILDFLAG(IS_BSD)` — uses getentropy

### `base/files/dir_reader_linux.h`

- L71: `#if BUILDFLAG(IS_BSD)` — uses getdents

### `gpu/command_buffer/client/test_shared_image_interface.cc`

- L440: `#if BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_CHROMEOS) || BUILDFLAG(IS_BSD)` — uses memfd_create

### `third_party/ipcz/src/reference_drivers/random.cc`

- L100: `#elif BUILDFLAG(IS_MAC) || BUILDFLAG(IS_BSD)` — uses getentropy
