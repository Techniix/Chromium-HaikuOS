# Porting notes

This document explains how the port is put together, which decisions were
made and why, what is known to be missing, and how to move it to a new
Chromium release. The README covers building.

**On the `renga` branch** the platform model, pipeline and most patches are
the same, but Renga's Linux interfaces replace several stock-Haiku
workarounds: patch 0003 is gone, and 0002, 0006, 0007, 0008 and 0012 are
smaller. Where this document describes stock Haiku, [RENGA.md](RENGA.md)
says what differs.

## Contents

- [The platform model](#the-platform-model)
- [Pipeline](#pipeline)
- [What the Haiku patches do](#what-the-haiku-patches-do)
- [Key decisions](#key-decisions)
- [Hand-porting worklist](#hand-porting-worklist)
- [Known limitations](#known-limitations)
- [Updating to a new Chromium release](#updating-to-a-new-chromium-release)
- [Prior work](#prior-work)

## The platform model

Haiku is modelled the way the FreeBSD and OpenBSD ports model their systems:

| Layer | Linux | FreeBSD | Haiku |
| --- | --- | --- | --- |
| GN | `is_linux` | `is_linux && is_bsd && is_freebsd` | `is_linux && is_haiku` |
| C++ | `BUILDFLAG(IS_LINUX)` | `BUILDFLAG(IS_BSD)`, `BUILDFLAG(IS_FREEBSD)` | `BUILDFLAG(IS_HAIKU)` |
| PartitionAlloc | `PA_BUILDFLAG(IS_LINUX)` | `PA_BUILDFLAG(IS_BSD)` | `PA_BUILDFLAG(IS_HAIKU)` |
| V8 | `V8_OS_LINUX` | `V8_OS_FREEBSD`, `V8_OS_BSD` | `V8_OS_HAIKU` |
| Python helpers | `linux` | `freebsd` / `FreeBSD` | `haiku` / `Haiku` |

So GN reuses the desktop-Linux build graph, while C++ sees a distinct
platform that is not Linux. `BUILDFLAG(IS_LINUX)` is 0 on Haiku, exactly as
on the BSDs, so every place that needed a BSD decision also needs a Haiku
decision. `tools/haikuify.py` makes most of those decisions automatically.

## Pipeline

`scripts/prepare-tree.sh` performs these steps on a pristine release tree:

1. **FreeBSD patches** (`patches/freebsd/`, `patch -p0`): 1,696 patches,
   pinned to the FreeBSD ports commit in `scripts/version.sh`. Of these, 1,549
   were verified to apply cleanly to 156.0.8078.79 against the Chromium git
   mirror. The remaining 147 target sub-repositories (V8, Skia, WebRTC,
   ANGLE, ...) that are only present in the release tarball; FreeBSD builds
   from that same tarball.
2. **`tools/haikuify.py`** rewrites
   - `BUILDFLAG(IS_BSD)` → `(BUILDFLAG(IS_BSD) || BUILDFLAG(IS_HAIKU))`, and
     the same for `PA_BUILDFLAG`,
   - `is_bsd` → `(is_bsd || is_haiku)` in GN (never on an assignment target),
   - FreeBSD entries in Python OS tables → an extra Haiku entry.

   In Python, files that already handle Haiku themselves (such as GN's
   `build/gen.py`) are left alone, and a lone call argument is never treated
   as a list item. For example, `startswith('freebsd')` becomes
   `startswith(('freebsd', 'haiku'))`, and other calls are reported instead.

   A guard is left BSD-only when the code it would select for Haiku uses
   BSD-kernel interfaces, or calls a function that is itself defined only
   under such a guard. Negated guards (`!BUILDFLAG(IS_BSD)`) are judged by
   the branch Haiku falls into. The tool is idempotent. On 156 it extends
   2,986 guards and leaves 39 for hand-porting (next section). Its report
   also lists 6 converted sites that use BSD-libc functions whose
   availability on Haiku must be confirmed with `tools/probe-haiku-libc.sh`.

   Guards that the Haiku patches keep BSD-only on purpose carry a
   `haikuify: bsd-only` comment, which the tool always respects. Re-running
   the tool on a prepared tree is therefore a no-op. `--python-only`
   restricts it to Python files.
3. **Haiku patches** (`patches/haiku/`, `patch -p1`), described below.
4. **Toolchain paths**: the FreeBSD patches hard-code FreeBSD's LLVM layout
   (`${LOCALBASE}/llvmNN/...`). Each is replaced with the path detected on
   this machine, and the step fails if any placeholder is left.
5. **Tool links**: system `node`, `rustc`, `gperf`, `esbuild`, `tsgo` and
   `clang-format` are linked to where Chromium expects its Linux prebuilts.

The whole pipeline was run on a pristine 156 tree (the Chromium git mirror
plus V8 at the DEPS revision), and the result was compared file by file with
the reference trees the patches were generated from. The only differences
were the toolchain paths from step 4.

## What the Haiku patches do

### `0001-build-add-haiku-platform`

- `build/build_config.h`: `OS_HAIKU` / `BUILDFLAG(IS_HAIKU)` from
  `__HAIKU__`, which is also POSIX. PartitionAlloc's own `build_config.h`
  gets the same.
- `BUILDCONFIG.gn`: `is_haiku`, `is_linux` true for Haiku, and native-only
  toolchain selection (`//build/toolchain/haiku:clang_$cpu`).
- `build/config/haiku`: feature macros (`_DEFAULT_SOURCE`, `_GNU_SOURCE`)
  plus `libbe` / `libmedia` configs for future native-API code.
- `default_libs`: only `network`. libroot already contains libc, libm,
  libdl and pthreads, and `-lpthread` would fail. Rust's std links
  `network` as well.
- Ozone: Wayland only, no X11. Haiku uses the system `libwayland-client`,
  because that is the copy that loads Haiku's in-process Wayland server.
- WebUI NTP/history defaults match the other desktop platforms.

### `0002-base-haiku-platform-layer`

Native implementations on Haiku's kernel API:

| File | Haiku API |
| --- | --- |
| `process_handle_haiku.cc` | `get_next_image_info()` (executable path), `_kern_process_info()` (parent of another team) |
| `process_iterator_haiku.cc` | `get_next_team_info()` |
| `process_metrics_haiku.cc` | area `ram_size` sums (RSS), `get_team_usage_info()` (CPU time), `get_system_info()` |
| `sys_info_haiku.cc` | `get_system_info()`, `base::CPU` for the model name |
| `platform_thread_haiku.cc` | `rename_thread()`; priorities left at defaults, as on BSD |
| `platform_thread_posix.cc` | `CurrentId()` = `find_thread(NULL)`, the kernel thread id |
| `debugger_posix.cc` | `BeingDebugged()` = `team_info.debugger_nub_thread >= 0` |
| `base_paths_posix.cc` | `FILE_EXE` via the team's `B_APP_IMAGE` |

File watching uses the stub watcher for now. A node-monitor
(`watch_node()`) based watcher is a natural follow-up.

`_kern_process_info()` is a private libroot syscall wrapper. The old
QtWebEngine port used it too. Replace it with `team_info.parent` if the
target Haiku exposes that field.

### `0003-base-message-pump-poll` (stock Haiku only)

Not on the `renga` branch, which uses the native epoll pump.

Chromium's UI and I/O loops use `MessagePumpEpoll`, which also has a poll()
mode (FreeBSD defaults to it). On Haiku, which has neither epoll nor eventfd:

- the pump always takes the poll() path,
- epoll registration becomes a no-op and `epoll_wait()` is unreachable,
- wake-ups use a non-blocking pipe instead of an eventfd,
- epoll's types and constants come from `haiku_epoll_types.h`.

No epoll emulation library is needed. The GLib pump needs no change: the
main-thread check `pid == tid` holds on Haiku, because the main thread's id
equals the team id.

### `0004-sandbox-content-share-bsd`

Haiku has no kernel sandbox mechanism. FreeBSD's `SandboxLinux`
implementation is plain POSIX (no kernel sandbox, optional `RLIMIT_DATA`), and
its GPU pre-sandbox hook is generic `dlopen()` preloading. Haiku reuses both
instead of adding a third copy, without FreeBSD's X11 dependency. Chromium
runs with `--no-sandbox` (`scripts/run-chromium.sh`).

### `0005-services-memory-instrumentation`

`os_metrics_haiku.cc` reports memory through `base::ProcessMetrics`.

### `v8/0001-v8-add-haiku-platform`

- `include/v8config.h`: `V8_OS_HAIKU`, POSIX, `V8_OS_STRING "haiku"`.
- `platform-haiku.cc`: shared libraries via `get_next_image_info()`, stack
  start via `get_thread_info().stack_end`.
- `platform-posix.cc`: no `<sys/syscall.h>`, thread ids via `find_thread()`,
  names via `rename_thread()`, no `MAP_NORESERVE`, and no duplicate
  `ObtainCurrentThreadStackStart()`.
- `sampler.cc`: register state for the CPU profiler on x86_64.
- WebAssembly runs without the trap handler (it is Linux/BSD only), so V8
  uses explicit bounds checks. This is slower but correct.

### `0006` to `0012` and `v8/0002`: fixes from the first full build

These came out of bringing the first full `chrome` build up on Haiku
(November 2026, Haiku hrev60368, Clang 23.1.4) and getting it to run. Each
patch's header lists every change and why it is needed; in short:

| Patch | Contents |
| --- | --- |
| `0006-build-haiku-toolchain-and-compat-headers` | Defines and flags in `build/config/haiku`, Clang's builtin headers ahead of GCC's, stub headers for Linux-only includes (`build/config/haiku/compat`), the `compat/lib` linker search directory and its sources, toolchain fixes |
| `0007-base-haiku-fixes` | Small `base/` fixes (stat times, rlimits, fd directory, process title, ELF names); on Renga, memfd shared memory and `backtrace()` stack traces |
| `0008-net-haiku-socket-and-errno-fixes` | errno cases, the `SO_TIMESTAMP` fallback, `ip_mreqn`, `struct ucred` header |
| `0009-third-party-haiku-fixes` | abseil, ANGLE, crashpad, Dawn (pregenerated Tint, see `docs/TINT.md`), fontconfig, perfetto, pthreadpool and others |
| `0010-ui-wayland-haiku-window-frame-and-input` | Native Haiku window frame through the KDE server-decoration protocol, compatibility with Haiku's older libwayland, evdev key codes |
| `0011-media-haiku-audio-and-decoder-fixes` | Media Kit audio output, the AV1 (`dav1d`) `EAGAIN` fix, capture without V4L2 |
| `0012-content-chrome-services-haiku-fixes` | inotify File System Access watcher on Haiku, sandbox declarations, Blink TLS model, small browser fixes |
| `v8/0002-v8-haiku-tls-signals-and-memory-diagnostics` | TLS model and signal context; temporary diagnostics for the "Check failed: success" renderer crash |

One helper cannot be built by GN and is built by `scripts/build.sh` into
`build/config/haiku/compat/lib/libhaikucompat.a`: the C-ABI shim around the
Media Kit's `BSoundPlayer`, which must be compiled against Haiku's libstdc++
rather than Chromium's libc++. `compat/lib/libm.a` is a linker script that
adds that library, libmedia and libbe to every link; libgnu, which holds
Renga's Linux interfaces, is linked from `build/config/haiku`. (On stock
Haiku, `main` also builds a `__cxa_thread_atexit` helper and pulls libgnu in
through the linker script for `sched_getaffinity()`.)

## Key decisions

- **Target 156.0.8078.79**, the current stable at the start, instead of 134.
  The Kaze project's Chromium 134 patches are unpublished, and FreeBSD's 156
  set is complete and maintained.
- **Reuse FreeBSD through a converter, not a fork of its patches.** A forked
  patch set has to be re-merged every release. The converter just runs again.
- **Ozone/Wayland through Haiku's Wayland layer** first, with no native
  `BWindow` backend. This reuses Chromium's most mature non-X11 backend. A
  native Ozone platform is a later option if the Wayland layer limits
  rendering, input methods or drag and drop.
- **Software rendering first.** Haiku's Wayland layer draws into native
  bitmaps and has no EGL/dma-buf path yet.
- **Clang + libc++ (bundled) + system unwinder.** Chromium no longer builds
  with GCC. The LLVM libunwind build is avoided on Haiku.
- **GLib on**, matching every tested desktop Linux and BSD configuration.
- **Media Kit audio.** ALSA and PulseAudio are off; audio output goes
  through a Media Kit `AudioManager` (patch 0011). Microphone input is a
  silent fake for now.
- **Native window frame.** Haiku's Wayland server draws real Haiku
  decorations through the KDE server-decoration protocol (patch 0010), and
  "Use system title bar and borders" is on by default.

## Hand-porting worklist

`docs/haikuify-report.md` lists every site. Grouped by impact:

**Already handled by the Haiku patches**
`base/BUILD.gn`, `process_iterator.h`, `base_paths_posix.cc`,
`debugger_posix.cc`, `stack_trace_posix.cc`, `platform_thread_posix.cc`,
`content/common/BUILD.gn`, `content/utility/utility_main.cc`,
memory-instrumentation `BUILD.gn`, `third_party/wayland/BUILD.gn` (not used:
system libwayland).

**Correct as is (Haiku takes the generic POSIX path)**
`process_posix.cc` (waitpid instead of kqueue), the PartitionAlloc and
`stack_base_address` / blink `stack_util` stack bounds (via
`pthread_getattr_np`, which `probe-haiku-libc.sh` must confirm),
`message_pump_glib.cc`, the sndio flags in `about_flags.cc`,
`flag_descriptions.h`, `media_switches.cc` and `media/audio/BUILD.gn`.

**Likely needs work during the first build**
- `components/named_mojo_ipc_server/connection_info.h`: peer credentials
  struct. Only matters if a target that uses it is built.
- `content/browser/BUILD.gn`: BSD-only sources around sandbox and zygote
  hosting.

**Not built** (developer tools): `robo_lib/config.py`, `libc-util.py`,
`asan_symbolize.py`, V8's test runner, `platform_thread_unittest.cc`.

## Known limitations

Status on stock Haiku (hrev60368, November 2026): `chrome` builds, runs and
browses with the flags in `scripts/run-chromium.sh`. The table describes
stock Haiku; on Renga, HTTP/3, file watching and crash traces are expected
to work (see [RENGA.md](RENGA.md) for what has been tested).

| Area | Limitation | Notes |
| --- | --- | --- |
| HTTP/3 | QUIC fails: stock Haiku refuses `sendmsg()` with control messages on UDP sockets (`EOPNOTSUPP`) | `--disable-quic`; HTTP/2 over TCP is used. |
| V8 | A renderer occasionally dies with `Check failed: success.` | Not explained yet; `v8/0002` labels every candidate check so the next report names its source. |
| Sandbox | None; every process runs with `--no-sandbox` | No kernel sandbox on Haiku. |
| GPU | Software rendering only (`--disable-gpu`) | Haiku's Wayland layer has no EGL/dma-buf path. |
| File watching | Web apps are not told about file changes | No inotify or kqueue on stock Haiku; the stub watcher reports failure. |
| Media | No microphone input or cameras; no hardware video decoding | Fakes report no devices. |
| Desktop | No D-Bus services: no system notifications, no secret store (`--password-store=basic`) | |
| Crash traces | Release builds print no symbolized stack traces | No `backtrace()` in stock Haiku's libroot. |
| Build | `pkgman` updates of `haiku_devel` during a build make ninja rebuild almost everything | `tools/skip-sysheader-rebuild.sh` undoes that. |

## Target results

`tools/probe-haiku-libc.sh` on Haiku R1~beta6+development hrev60319
(x86_64, 2026-11-02):

| Result | Interfaces | What the port does |
| --- | --- | --- |
| yes | getentropy, MADV_FREE/DONTNEED, posix_madvise, MAP_NORESERVE, MAP_ANONYMOUS, malloc_usable_size, pthread_getattr_np, pthread_attr_getstack, _SC_PHYS_PAGES, _SC_NPROCESSORS_ONLN, pipe2, SOCK_CLOEXEC, MSG_NOSIGNAL, SO_PEERCRED, posix_fallocate, O_DIRECTORY, getdtablesize, getpgid, strlcpy, reallocarray, utimensat, mkostemp | Used as is. The generic stack-bounds paths (`pthread_getattr_np`) work. |
| yes, in libbsd | arc4random_buf, explicit_bzero, ppoll, dl_iterate_phdr | `bsd` is in Haiku's `default_libs` (patch 0001). |
| yes, in libnetwork | accept4 | `network` is in Haiku's `default_libs`. |
| no | getdents | Haiku uses `DirReaderFallback` (patch 0002). |
| no | memfd_create | Not needed. Shared memory uses files in the temp directory, as on BSD. The only converted `memfd_create` user is test code. |
| in libgnu | sched_getaffinity, pthread_getaffinity_np | Used by bundled dav1d and FFmpeg; libgnu is linked through `compat/lib/libm.a`. |
| no | getpeereid | Not used by anything Haiku builds. |
| no | backtrace | Already excluded (glibc/Apple only). Crash logs have no stack traces for now. |
| no | POLLRDHUP | `haiku_epoll_types.h` defines it as 0. |
| no | epoll, eventfd, inotify | Expected. The poll()-based pump and the stub file watcher avoid them. |

## Updating to a new Chromium release

1. Pick the FreeBSD ports commit that updates `www/chromium` to the new
   version. Record it and the tarball SHA-256 (from `www/chromium/distinfo`)
   in `scripts/version.sh`.
2. Replace `patches/freebsd/` with that commit's `www/chromium/files/patch-*`.
3. Rebase `patches/haiku/`: prepare a tree up to and including haikuify, then
   apply each Haiku patch and fix any rejects.
4. Read the new `haikuify-report.md` for new hand-porting sites.

## Prior work

- **HaikuPorts `dev-qt/qtwebengine`**: QtWebEngine 5.15 (Chromium 87) on
  Haiku. It is the source of the "Linux in GN, Haiku in C++" model and of
  the Media Kit audio/video capture code worth porting next.
- **Kaze**: QtWebEngine 6.10.3 (Chromium 134) on Haiku. Its patches had not
  been published when this port started.
- **FreeBSD `www/chromium`**: the base of this port.
- **Haiku's Wayland compatibility layer**: what lets Chromium's Ozone/Wayland
  backend open windows on Haiku.
