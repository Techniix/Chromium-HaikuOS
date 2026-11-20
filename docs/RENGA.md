# Chromium on Renga

The `renga` branch builds Chromium 156 for **Renga**, the Haiku-based
operating system in [Techniix/haiku](https://github.com/Techniix/haiku)
(branch `ce/main`). Renga adds the Linux and BSD interfaces Chromium already
uses on those systems, so this branch uses Chromium's own Linux code where
the `main` branch needs Haiku-specific replacements. `main` stays the
stock-Haiku target and is not affected by anything here.

Renga's plan for Chromium is roadmap item `F-43`; the behaviour and limits
of each interface are in `3rdparty/ce/PORTING.md` of Techniix/haiku. What
this port needs from Renga is in [RENGA-REQUESTS.md](../RENGA-REQUESTS.md);
Renga answers in `docs/partners/CHROMIUM.md` there.

## Building and testing

Use the Renga image `renga-2026.11.15-chromium-readiness` (`143b8c30`) from
[Techniix/renga-builds](https://github.com/Techniix/renga-builds), or a later
one that Renga's `docs/partners/CHROMIUM.md` recommends for builds. Renga
checked this image for the build: Node with large heaps and worker threads,
Python, gn, ninja, clang with lld, and `scripts/renga-tests.sh probe`. It
also has the fixes for R-7 (`wl_fixes` 2) and R-8 (lld-linked programs
branded GNU stay native), so the local workarounds used on earlier images
are not needed. Keep Screen preferences > "Show Wayland programs" on (the
default). Then, on Renga:

```sh
git clone https://github.com/Techniix/Chromium-HaikuOS.git
cd Chromium-HaikuOS
git checkout renga
scripts/setup-renga.sh --save /path/to/saved-packages
scripts/fetch-sources.sh
scripts/prepare-tree.sh work/chromium-156.0.8078.79
JOBS=10 scripts/build.sh work/chromium-156.0.8078.79
scripts/renga-tests.sh quic    work/chromium-156.0.8078.79/out/Release
scripts/renga-tests.sh wayland work/chromium-156.0.8078.79/out/Release
scripts/renga-tests.sh v8      work/chromium-156.0.8078.79/out/Release
```

`scripts/setup-renga.sh` installs the build packages, the npm tools
(`esbuild-wasm`, `typescript@6`) and the libclang Python bindings, then
runs `detect-toolchain.sh` and the probe. With `--save DIR` it copies the
installed packages to `DIR`; on the next fresh install, `--from DIR`
installs those first, so little has to be downloaded again. It can be run
again at any time and only installs what is missing.

`scripts/build.sh` stops early on a system without Renga's headers or the
`renga_wayland` package. A tree prepared from `main`, or from this branch
before 2026-11-14, must be prepared again (the patch set differs). For readable V8 backtraces with file and line numbers, build with
`EXTRA_GN_ARGS='symbol_level = 1'` (link time and disk use grow
considerably); function names alone need no change.

`scripts/renga-tests.sh` writes everything to `renga-test-results/`, with a
header recording the date, the Renga revision and whether the run was on a
virtual machine or on real hardware. Results from QEMU are labelled as such
in this file and are never reported as hardware results.

- `probe` builds `tools/renga-probe.c` and checks each interface the way
  Chromium calls it: epoll with an eventfd wake-up from another thread,
  inotify on a directory, a sealed memfd, `backtrace_symbols_fd()` from a
  static and an exported function (then symbolized with
  `tools/symbolize-trace.py`), the QUIC socket options with a `sendmsg()`
  carrying an ECN mark and `recvmmsg()`, affinity and `getpeereid()`. It
  also reports R-1, R-2, R-4 and R-6, which should all say "available" from
  image `2026.11.14-chromium-wayland` on.
- `quic` loads `QUIC_URL` (default `https://cloudflare-quic.com/`) headless
  four times, each with a NetLog: twice in one profile (the first response
  advertises HTTP/3 with Alt-Svc, the second should use it), once with QUIC
  forced on for that origin and once with `--disable-quic`. The summary
  lists QUIC sessions, packets sent and received, and any QUIC errors.
- `wayland` opens a window for 20 seconds and checks with `listimage` that
  the browser loaded `libwayland-client-renga.so.0` and none of HaikuPorts'
  libwayland; check by eye that the window has Renga's frame.
- `v8` starts Chromium with stderr captured, waits for you to reproduce the
  tab crash ("Check failed: success"), and symbolizes the log.

## Continuing development after a fresh install

A built tree can be kept across Renga reinstalls, so a fresh image does not
mean a full rebuild. Keep this repository, with its `work/` directory, on a
disk that survives the reinstall, at the same path, and save the build
packages once with `scripts/setup-renga.sh --save DIR`. On the new install:

```sh
cd /path/to/Chromium-HaikuOS
git pull
scripts/resume-dev.sh --packages /path/to/saved-packages
JOBS=10 scripts/build.sh work/chromium-156.0.8078.79
```

`scripts/resume-dev.sh` installs the tools (from the saved packages
first), checks that the tree has not moved (build files hold absolute
paths), links the reinstalled tools into the tree again, brings the tree's
Haiku patches up to the checked-out port commit, and compares the toolchain
with the one the last build recorded in `out/Release/.renga-build-env`.
If only Haiku's system headers are newer, it runs
`tools/skip-sysheader-rebuild.sh` so that only real changes rebuild; if
clang or rustc changed, it says that most of the tree will rebuild.

The patch update (`tools/update-tree.py`) undoes the old patch version and
applies the new one for each file whose result differs, and rewrites only
those files, so ninja rebuilds only what the patch change affects. It
records the port commit in the tree's `.haiku-port-commit`; trees prepared
before 2026-11-19 do not have it and need `--from COMMIT` once (the first
Renga tree: `--from 2191962`). A file fixed by hand in other words than the
new patch is reported as a conflict; `--accept PATH` leaves it as it is.
`--dry-run` shows what would change. The same script works without a
reinstall, after any `git pull` that changes the patches
(`--skip-setup`).

## Packaging a build

`scripts/package-hpkg.sh OUT_DIR` turns a finished build into a Haiku
package, `packages/chromium_renga-156.0.8078.79-<revision>-x86_64.hpkg`, so
a build that works can be reinstalled on a later Renga image without
rebuilding:

```sh
scripts/package-hpkg.sh work/chromium-156.0.8078.79/out/Release
pkgman install packages/chromium_renga-156.0.8078.79-1-x86_64.hpkg
chromium            # or Deskbar > Applications > Chromium
```

- It installs to `/boot/system/apps/Chromium`, with a `chromium` command
  and a Deskbar entry. The launcher uses the same flags as
  `scripts/run-chromium.sh`, with the profile in
  `~/config/settings/Chromium` (set `CHROMIUM_PROFILE` to use another);
  the profile is not in the package, so back it up separately if it
  matters.
- `apps/Chromium/BUILD-INFO.txt` records the port commit, whether the
  working tree had uncommitted patch or script changes, the Renga revision
  it was built on and the `args.gn`.
- The revision goes up by one with each package of the same Chromium
  version in `packages/` (or set `REVISION`), so `pkgman` treats a newer
  build as an update.
- Binaries are stripped (`STRIP=all`, or `debug`/`none`); the unstripped
  copies go to `packages/<package>-symbols/`. Keep that directory with the
  package: crash traces from the installed build are resolved with
  `tools/symbolize-trace.py --dir packages/<package>-symbols`.
- Requirements are worked out from the libraries the binaries link, by
  asking packagefs which installed package each one comes from, so they
  match the image the build was made on. On a much newer image, `pkgman`
  says if one of them is gone; add packages by hand with `REQUIRES_EXTRA`.
- `packages/` is not tracked by git. Keep the packages on a disk that
  survives reinstalling Renga.

## Test results

### 2026-11-19: first native build, real hardware

Port commit `5f11bae` (plus the two-file fix applied in place, see the
change log), Renga `143b8c30` (`2026.11.15-chromium-readiness`), AMD Ryzen 5
7600X, one 3440x1440 output.

- Build: complete (`chrome` linked). V8's `mksnapshot` and every other build
  tool ran natively after R-8.
- First run: the first window ("Chromium Additional Terms of Service")
  opened on Renga's compositor with server-side decoration and drew; the
  compositor then stopped on pointer motion over it (R-9, fixed in image
  `2026.11.20-batch3`). Expected log
  noise: no D-Bus bus (phase D), and NSS's built-in root module not loaded
  (Chromium uses its own root store).
- HTTP/3 (phase B item 6), `scripts/renga-tests.sh quic`, headless,
  `https://cloudflare-quic.com/`: QUIC handshakes verified and HTTP/3
  responses received in the second Alt-Svc run (5 responses: 200 and 304)
  and with QUIC forced (8 responses, all 200); none with `--disable-quic`.
  Sessions still open at exit close with `ERR_ABORTED`, as when
  `--dump-dom` ends the process on Linux. The summary printed by that run
  listed those closes as errors; `renga-tests.sh` now counts HTTP/3
  responses and leaves shutdown closes out.

### 2026-11-14: probe, real hardware

`scripts/renga-tests.sh probe` at port commit `0498b85`, on Renga
`ea9753b2` (hrev60381+289), real hardware (AMD Ryzen 5 7600X). All 21
checks passed: epoll with an eventfd wake-up, inotify, memfd with sealing,
`backtrace_symbols_fd()`, the QUIC socket options with an ECN-marked
`sendmsg()` and `recvmmsg()` (ECN codepoint and `IP_PKTINFO` received),
affinity and `getpeereid()`.

- R-3: frames in a static function print as `image(+0xOFF)`, and with
  `--base image` (the default) `tools/symbolize-trace.py` resolved every
  frame of the probe to its function and line. `--base text` gives wrong
  functions on this image, as expected.
- R-1 (`/proc/self/fd/N` read-only reopen of a memfd) and R-4
  (`SO_TIMESTAMP`): available.
- R-2 and R-6 were reported missing, but because the probe used
  `access()`, which Renga's `/proc` does not support (it supports `open()`
  only, and Chromium only opens these files). The probe now opens and
  reads them; to be re-run.

Chromium itself has not been built on Renga yet.

## Status

| Item (F-43 phase B) | State |
| --- | --- |
| 1. MessagePumpEpoll with eventfd wake-ups | Done in the patches; not yet run on Renga |
| 2. inotify FilePathWatcher (base and File System Access) | Done in the patches; not yet run on Renga |
| 3. memfd shared memory | Done; writable regions become memfd-backed with R-1 (landed in Renga 2026-11-14, no port change); not yet run on Renga |
| 4. Symbolized crash traces through backtrace() | Done; `tools/symbolize-trace.py` defaults to glibc-style offsets (R-3, landed 2026-11-14); not yet run on Renga |
| 5. Removing emulation | Done; list below |
| 6. HTTP/3 without --disable-quic | Works (2026-11-19, real hardware): HTTP/3 responses after Alt-Svc and with QUIC forced |
| 7. V8 "Check failed: success" backtrace | Tooling ready; capture it on `2026.11.14-chromium-wayland` or later (earlier images can drop frames, R-3) |
| Phase C: Renga's compositor | Built against `renga_wayland`, KDE decoration path removed (2026-11-14); not yet run on Renga |

The patch series applies cleanly to the Chromium 156.0.8078.79 tree and
reproduces this branch's tree exactly (checked by applying every patch to
a freshly prepared tree and comparing the result). A full build on Renga
has not been done yet: this work was done without access to a Renga machine,
and building Chromium inside an emulated (TCG) QEMU is not practical. The
first build and the tests above are the next step.

## Change log

### 2026-11-14: Renga's compositor, renga_wayland and the landed requests

Renga's 2026-11-14 batch (image `2026.11.14-chromium-wayland`; Techniix/haiku
`docs/partners/CHROMIUM.md`, "landed: R-1 to R-5 and the compositor
completion") landed R-1 to R-6, the rest of its socket Wayland compositor and
`renga_wayland`, its socket-transport libwayland for ports. Renga tested all
of it in QEMU; none of it has been run in the port yet.

**Wayland library (patch 0001, `scripts/build.sh`).** Chromium builds
against `renga_wayland` instead of HaikuPorts' in-process libwayland.
`scripts/build.sh` puts `/boot/system/data/renga_wayland/pkgconfig` first
in `PKG_CONFIG_PATH`, so `wayland-client` and `wayland-server` resolve to
`libwayland-client-renga` and `libwayland-server-renga`, and stops early if
the package is missing. `renga_wayland` has no `libwayland-cursor` or
`libwayland-egl`, and HaikuPorts' copies link HaikuPorts' libwayland, which
must never share a process with Renga's (same symbols). So on Haiku
`third_party/wayland` builds both from Chromium's bundled sources against
the system client library, as the non-system build does; the cursor
library's shared memory uses `memfd_create()` with sealing.
`scripts/detect-toolchain.sh` checks for the `-renga` pkg-config modules.

**Window frame and protocol versions (patch 0010).** Removed: the KDE
server-decoration path (protocol target, manager binding, `XdgToplevel`
fallback, `OzonePlatformWayland` checks), the `wl_fixes` guards, the
`WL_KEYBOARD_KEY_STATE_REPEATED` definition and the
`axis_relative_direction` guard. Renga's compositor offers
`zxdg_decoration_manager_v1` (server-side by default), `wl_fixes`,
`wl_seat` 10, `wl_pointer` 9 and `wl_keyboard` 10, and its headers come from
Wayland 1.24's XML, so Chromium's code runs unchanged. Kept: the native
frame as the default for new profiles, no DRM/GBM probing, evdev key codes,
the dma-buf ioctl encodings. Patch 0010 went from 14 files to 5.

**Sockets (patch 0008).** Removed the `SO_TIMESTAMP` stand-in (net and
WebRTC; R-4) and the private `struct ip_mreqn` (R-5). WebRTC needs no
Haiku change any more. `IP_DEFAULT_MULTICAST_TTL`, which Renga's headers do
not define, stays.

**Shared memory and traces.** R-1 needs no port change: writable regions
become memfd-backed because Chromium already reopens `/proc/self/fd/N`.
`tools/symbolize-trace.py` defaults to `--base image` (R-3); `--base text`
remains for traces from older images. R-6 removes the once-per-process
inotify error line. Building the in-process symbolizer again now that
`/proc/self/maps` exists (R-2) is left for later: Renga's `/proc` supports
`open()` only, and the `backtrace()` path covers the need.

**Scripts.** `scripts/run-chromium.sh` checks for the compositor socket
(`$XDG_RUNTIME_DIR/wayland-0`) and says how to turn the compositor on if it
is missing. `scripts/renga-tests.sh wayland` checks which libwayland the
browser loaded. The first-window size from `scripts/run-chromium.sh` stays:
Chromium 156 ignores `xdg_toplevel.configure_bounds`.

### 2026-11-13: phase B, the port catching up with Renga

Branch `renga` created from `main` at `2ced844`.

**Message loop (item 1).** Patch 0003 (`base-message-pump-poll`) is gone.
Chromium's own `MessagePumpEpoll` is used unchanged: `epoll_create1(0)`, an
`eventfd(0, EFD_NONBLOCK)` as the wake-up descriptor, edge cases as on
Linux. GN already selects it (`use_epoll = is_linux`, and Haiku is a
Linux-like GN target). libgnu, which holds Renga's epoll and eventfd, is
linked into every target from `build/config/haiku:runtime_library` (patch
0006). Renga returns at most 1024 events per `epoll_wait()` and treats
`EPOLLEXCLUSIVE` as a no-op; Chromium asks for 16 events per call and does
not use `EPOLLEXCLUSIVE`.

**File watching (item 2).** `base/files/file_path_watcher_inotify.cc` and
the File System Access watcher
(`content/browser/file_system_access/file_path_watcher/
file_path_watcher_inotify.cc`) replace the stubs (patches 0002 and 0012).
Differences that Chromium can see, from Renga's PORTING.md: `IN_DELETE_SELF`
arrives when the last name is removed rather than at the last close, which
Chromium treats the same way; `IN_UNMOUNT` never comes; `IN_EXCL_UNLINK` has
no effect. Chromium logs once per process that it cannot read the inotify
watch limit from `/proc` (R-6).

**Shared memory (item 3).** `PlatformSharedMemoryRegion` uses Chromium's
Linux memfd code on Renga (patch 0007): `memfd_create()` with
`MFD_CLOEXEC | MFD_ALLOW_SEALING | MFD_NOEXEC_SEAL`, sealed with
`F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_SEAL`. Renga's `memfd_create()` is a
libgnu function, not a system call, so the port calls it directly instead of
`syscall(__NR_memfd_create, ...)`; the seal names are used, never their
numbers (Renga's values differ from Linux's). Unsafe regions, which renderer
and GPU processes now create in-process
(`mojo/core/ipcz_driver/base_shared_memory_service.cc`), are memfd-backed.
Writable regions need a second, read-only descriptor, which Linux obtains by
reopening `/proc/self/fd/N`; on Renga that fails and they use the temporary
file fallback, as on stock Haiku (R-1). Chromium's notification code may now
pass icons as a sealed memfd too (patch 0012).

**Stack traces (item 4).** `base/debug/stack_trace_posix.cc` defines
`HAVE_BACKTRACE` on Haiku (patch 0007). Outside signal handlers, frames come
from `backtrace()` and `backtrace_symbols()` and are demangled. In the crash
signal handler Linux prints bare addresses, because glibc's
`backtrace_symbols_fd()` may allocate; Renga's does not, so the port prints
`image(symbol+0xoffset) [address]` lines there. The `/proc/self/maps`-based
in-process symbolizer (`USE_SYMBOLIZE`), which could never find anything
without `/proc`, is no longer built for Haiku (patch 0002; R-2). V8's own
stack traces use `<execinfo.h>` too (v8 patch 0002).
`tools/symbolize-trace.py` turns `image(+0xoffset)` frames into function
names (and file:line with `symbol_level = 1`) with llvm-symbolizer; which
base Renga's offsets are counted from is R-3.

**HTTP/3 (item 6).** `scripts/run-chromium.sh` no longer passes
`--disable-quic`. `recvmmsg()` is used for UDP reads on Haiku as on Linux and
the BSDs (Renga's libnetwork), and the IPv6 traffic-class stubs are gone
(Renga has `IPV6_TCLASS` and `IPV6_RECVTCLASS`). Renga reports the received
TOS byte in BSD form (`IP_RECVTOS`, one byte), which is the form Chromium's
BSD code path, used on Haiku, expects.

**V8 crash (item 7).** With item 4, a renderer that hits a V8 `CHECK` prints
the failed condition, a demangled trace from V8's fatal-error hook
(`gin::V8Platform::GetStackTracePrinter()`, outside the signal handler), and
a second trace from the signal handler. `scripts/renga-tests.sh v8` captures
and symbolizes both. The diagnostic messages of v8 patch 0002 (each
`CHECK(success)` names its call site) are kept for this.

**Other.** `scripts/build.sh` checks for Renga's headers before building,
and builds `libhaikucompat.a` from the Media Kit shim only. Added
`scripts/renga-tests.sh`, `tools/renga-probe.c`, `tools/symbolize-trace.py`,
`RENGA-REQUESTS.md` and this file.

#### Removed (item 5)

Everything below only emulated, or worked around the absence of, something
Renga provides. Removed from the `renga` branch only; `main` keeps it.

| Removed | Was in | Replaced by (Renga) |
| --- | --- | --- |
| Poll-mode `MessagePumpEpoll`: `haiku_epoll_types.h`, pipe wake-up, stub `epoll_ctl()`/`epoll_wait()` | patch 0003 (deleted) | epoll and eventfd in libgnu |
| `file_path_watcher_stub.cc` for base on Haiku | patch 0002 | inotify (libgnu) |
| `HaikuFilePathWatcherImpl`, a no-op File System Access watcher | patch 0012 | inotify |
| `compat/lib/haiku_cxa_thread_atexit.c` (`__cxa_thread_atexit` through a pthread key; no destructors for the main thread) and its build step | patch 0006, `scripts/build.sh` | `__cxa_thread_atexit_impl()` in libroot, called by libc++abi's own `__cxa_thread_atexit()` (`HAVE___CXA_THREAD_ATEXIT_IMPL`) |
| Affinity linker trick: `AS_NEEDED(-lgnu)` in the `compat/lib/libm.a` linker script, which pulled libgnu into every link for `sched_getaffinity()`/`pthread_getaffinity_np()` | patch 0006 | affinity in libroot; libgnu linked explicitly for the Linux interfaces |
| `compat/sys/eventfd.h` (an `eventfd()` that failed with `ENOSYS`) | patch 0006 | `<sys/eventfd.h>` (gnu) |
| `compat/sys/auxv.h` (a `getauxval()` stub returning 0) | patch 0006 | `getauxval()` in libgnu |
| Exclusion of `recvmmsg()` and the GRO read path from Haiku | patch 0008 | `recvmmsg()` in libnetwork |
| `IPV6_TCLASS`/`IPV6_RECVTCLASS` stub option numbers | patch 0008 (net and WebRTC) | the real options |
| `SO_PEERCRED` replacement for `getpeereid()` in `UnixDomainServerSocket` | patch 0008 | `getpeereid()` in libbsd |
| Private `struct ucred` and `SO_PEERCRED` fallback in `named_mojo_ipc_server` | patch 0008 | `struct ucred` in `<sys/socket.h>` |
| Guard that compiled out the notification icon memfd | patch 0012 | `memfd_create()` with sealing |
| `--disable-quic` | `scripts/run-chromium.sh` | UDP `sendmsg()` with control messages, ECN and PKTINFO options |
| Bare-address-only stack traces (no `HAVE_BACKTRACE`, a symbolizer that needed `/proc`) | patches 0002, 0007; v8 0002 | `backtrace()`, `backtrace_symbols()`, `backtrace_symbols_fd()` in libgnu |

Kept, because Renga does not provide the facility (each is a request in
RENGA-REQUESTS.md or not needed): the `SO_TIMESTAMP` fallback (R-4), the
`struct ip_mreqn` declaration (R-5), the file fallback for writable shared
memory (R-1), libc++abi's non-futex guard waits (Renga `F-49`), the Media Kit
audio shim (`libhaikucompat.a`; Chromium has no Media Kit backend of its
own), and the `d_type` workaround in `sandbox/linux/services/proc_util.cc`
(Haiku's `struct dirent` has no `d_type`; that code is not reached
without the Linux sandbox).
