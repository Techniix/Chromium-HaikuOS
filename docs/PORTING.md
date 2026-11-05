# Porting notes

This document explains how the port is put together, which decisions were
made and why, what is known to be missing, and how to move it to a new
Chromium release. The README covers building.

## Contents

- [The platform model](#the-platform-model)
- [Pipeline](#pipeline)
- [What the Haiku patches do](#what-the-haiku-patches-do)
- [Key decisions](#key-decisions)
- [Hand-porting worklist](#hand-porting-worklist)
- [Known risks for the first build](#known-risks-for-the-first-build)
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

   A guard is left BSD-only when the code it would select for Haiku uses
   BSD-kernel interfaces, or calls a function that is itself defined only
   under such a guard. Negated guards (`!BUILDFLAG(IS_BSD)`) are judged by
   the branch Haiku falls into. The tool is idempotent. On 156 it extends
   2,986 guards and leaves 39 for hand-porting (next section). Its report
   also lists 6 converted sites that use BSD-libc functions whose
   availability on Haiku must be confirmed with `tools/probe-haiku-libc.sh`.
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

### `0003-base-message-pump-poll`

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
- **No audio backend yet.** ALSA and PulseAudio are off. A Media Kit
  `AudioManager` is the next media task; the old HaikuPorts QtWebEngine port
  had one and can serve as a reference.

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

## Known risks for the first build

| Area | Risk | Plan |
| --- | --- | --- |
| Toolchain | LLVM libc++ and lld targeting Haiku at Chromium scale | Try `use_lld=false` if linking fails. |
| libc gaps | `getentropy`, `getdents`, `MADV_FREE`, `memfd_create`, `pthread_getattr_np`, `malloc_usable_size` | Run `tools/probe-haiku-libc.sh` first. Each "no" needs a Haiku branch. |
| Wayland | Haiku's libwayland version may be older than Chromium's minimum, or lack protocols | Check `third_party/wayland/wayland_version.gni` against the system version. Chromium needs xdg-shell and wl_shm. |
| Build tools | esbuild (Go) and tsgo (Go) have no native Haiku builds | Use `esbuild-wasm` under node. Use `use_typescript_go=false`. |
| NSS | Chromium on Linux needs system NSS/NSPR | Use HaikuPorts' NSS, or port it. |
| ffmpeg | `third_party/ffmpeg` (tarball only, not inspected yet) picks a generated config directory by OS name | If GN asks for a `haiku` config directory, map Haiku to the `linux` configs, as FreeBSD does for itself. |
| Shared memory | `base/memory/platform_shared_memory_region_posix.cc` uses `shm_open`/`memfd` paths | Confirm Haiku's `shm_open` works for cross-team sharing. |

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
