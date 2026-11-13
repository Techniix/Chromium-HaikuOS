# Requests to Renga

Requests from the Chromium-HaikuOS port (`renga` branch) to Renga
(Techniix/haiku, branch `ce/main`, roadmap item `F-43`). Renga answers with
dated entries in `docs/partners/CHROMIUM.md` of Techniix/haiku.

Each entry says what the port needs, why, the exact call or behaviour, a
small reproduction where there is one, and how urgent it is. The port does
not work around these: until Renga answers, Chromium takes the fallback it
already has on Linux when the facility is missing, and this file says which.

`tools/renga-probe.c` (run with `scripts/renga-tests.sh probe`) checks every
interface the port uses the way Chromium calls it, and reports the state of
R-1, R-2, R-4 and R-6 on the running system.

Urgency: **high** blocks a phase B item; **medium** costs performance or
noise in normal use; **low** is correctness at the edges or a later phase.

Last updated: 2026-11-13. Port commit: see `git log -- RENGA-REQUESTS.md`.

## Open

### R-3: backtrace_symbols(): which "+0x" offset, and frames outside the first region

- **Urgency:** high (phase B item 7, the V8 crash backtrace).
- **Need:** for a frame in a non-exported function, an offset that
  `addr2line`/`llvm-symbolizer` resolve without knowing Renga's
  internals, and an image name for every frame in an image's code.
- **Why:** almost all of Chromium is hidden-visibility code, so almost every
  frame of a crash prints as `image(+0xoffset)`. `src/libs/gnu/execinfo.cpp`
  computes that offset from `image_info.text` and looks the frame up in
  `[text, text + text_size)`. glibc prints the offset from the image's load
  address (`dli_fbase`, `l_addr`), which is what the tools expect.
  Chromium is linked with lld, whose default layout puts a read-only
  `PT_LOAD` segment (ELF headers, `.rodata`, `.eh_frame`) before the
  executable one. Two questions follow, and I could not answer them
  without running Renga:
  1. Is `image_info.text` the start of the first `PT_LOAD` (the load
     address) or of the executable segment? `tools/symbolize-trace.py`
     defaults to "start of the executable segment" (`--base text`) and
     offers `--base image`; the right default depends on the answer.
  2. If `text`/`text_size` describe only the first region, are frames in the
     executable segment of an lld-linked image found at all, or printed as
     a bare `[0x...]`?
- **Exact behaviour asked for:** as glibc: `image(+0xOFF)` with `OFF =
  address - load address of the image` (the address the image's first
  `PT_LOAD` with `p_vaddr` 0 was mapped at), and the image found for any
  address inside any of its mapped segments. If changing the base is not
  wanted, please document which base is used in `PORTING.md`.
- **Repro:** `scripts/renga-tests.sh probe` compiles `tools/renga-probe.c`
  with `-fuse-ld=lld`, prints a `backtrace_symbols_fd()` trace whose first
  frame is the static function `static_frame()`, and symbolizes it both
  ways. Expected: frame 0 resolves to `static_frame`, frame 1 is named
  `exported_frame+0x...`.

### R-1: a read-only open file description for a memfd

- **Urgency:** medium.
- **Need:** a way to get a second, `O_RDONLY` open file description for
  the file behind a memfd descriptor.
- **Why:** Chromium's Linux shared memory (`base/memory/
  platform_shared_memory_region_posix.cc`, `CreateAnonymousRegion()`), now
  used on Renga, creates writable regions as a sealed memfd plus a
  read-only descriptor for the same file, so that the region can later be
  shared read-only (`ConvertToReadOnly()`); the receiving side checks with
  `fcntl(F_GETFL)` that the descriptor really is `O_RDONLY`. On Linux the
  second descriptor comes from `open("/proc/self/fd/N", O_RDONLY |
  O_CLOEXEC)`, which opens a new open file description for the same inode.
  Renga has no `/proc`, so that `open()` fails and every writable region
  (most IPC buffers) falls back to an unlinked file in the temporary
  directory: more system calls, a path lookup, and, later, filesystem
  access that sandboxed processes should not need (phase G).
  Unsafe regions, which need no second descriptor, are memfd-backed now.
- **Exact behaviour asked for:** any one of
  - `open("/proc/self/fd/N", O_RDONLY | O_CLOEXEC)` with Linux semantics
    (new open file description, same file, its seals apply; `mmap(PROT_READ,
    MAP_SHARED)` works; `PROT_WRITE` and `mprotect(PROT_WRITE)` on it fail);
  - the same through `/dev/fd/N` (Chromium would then need a one-line
    change, which I would make);
  - `openat(N, "", O_RDONLY | O_EMPTY_PATH)`-style reopening, if Renga
    prefers an explicit call.
- **Repro:** the "R-1" line of `scripts/renga-tests.sh probe`
  (`check_memfd()` in `tools/renga-probe.c`).

### R-2: /proc/self/maps

- **Urgency:** low now, medium for phase G.
- **Need:** `/proc/self/maps` in Linux's format (start-end, perms, offset,
  dev, inode, path), or for the sandbox only, an equivalent the port can
  read without `/proc`.
- **Why:** Chromium's in-process symbolizer (`base/third_party/symbolize`,
  with file and line numbers from DWARF in debug builds) finds the object
  file of each frame there; on Renga the port leaves it out and uses
  `backtrace()` instead (patch 0002), which is enough for now with R-3.
  `base/debug/proc_maps_linux.cc` (memory-infra dumps, the sandbox's
  symbolizer warm-up, PartitionAlloc's address-space statistics) reads it
  too.
- **Repro:** the "R-2" line of `scripts/renga-tests.sh probe`.

### R-4: SO_TIMESTAMP on UDP sockets

- **Urgency:** low.
- **Need:** `setsockopt(SOL_SOCKET, SO_TIMESTAMP)` and an `SCM_TIMESTAMP`
  control message (`struct timeval`, receive time) on `recvmsg()`/
  `recvmmsg()`, as Linux and FreeBSD.
- **Why:** `net/socket/udp_socket_posix.cc` and WebRTC's
  `physical_socket_server.cc` use kernel receive times for QUIC RTT
  samples and WebRTC jitter estimates. Without it the port defines
  `SO_TIMESTAMP` as an invalid option number (the `setsockopt()` fails and
  Chromium stamps packets when it reads them), which is the same fallback
  Chromium takes when the option fails on Linux.

### R-5: struct ip_mreqn for IP_ADD_MEMBERSHIP / IP_DROP_MEMBERSHIP

- **Urgency:** low.
- **Need:** `struct ip_mreqn` in `<netinet/in.h>` (`imr_multiaddr`,
  `imr_address`, `imr_ifindex`), accepted by `IP_ADD_MEMBERSHIP`,
  `IP_DROP_MEMBERSHIP` and `IP_MULTICAST_IF` when `optlen` is its size, as
  Linux and FreeBSD do.
- **Why:** `UDPSocketPosix::JoinGroup()` passes an `ip_mreqn` with the
  interface index chosen by the caller (mDNS, local network discovery,
  WebRTC). The port declares the struct itself (patch 0008). If Renga reads
  only the leading `ip_mreq`, the interface index is ignored and the group
  is joined on the default interface.
- **Exact behaviour asked for:** honour `imr_ifindex` when non-zero (it takes
  precedence over `imr_address`), as Linux.

### R-6: the inotify watch limit

- **Urgency:** low (one error line per process).
- **Need:** `/proc/sys/fs/inotify/max_user_watches`, or a documented
  limit the port may hard-code.
- **Why:** `base/files/file_path_watcher_inotify.cc` reads the limit to
  share it between watchers, and logs `Failed to read
  /proc/sys/fs/inotify/max_user_watches` once per process when it cannot,
  then assumes 8192 (which matches Renga's per-instance limit). Renga's
  limit is per inotify instance, Linux's per user; Chromium uses one
  instance per process, so the numbers are compatible.

## Notes for later phases

These are not requests yet; they are what the port's code and the stock
Haiku bring-up showed, for Renga to take into account when planning.

### Phase C (Wayland layer)

- **Decorations:** the port gets the native Haiku frame through the KDE
  `org_kde_kwin_server_decoration` protocol, because the HaikuPorts server
  offers no `xdg-decoration-unstable-v1` (patch 0010). Please offer
  `zxdg_decoration_manager_v1` (server-side mode); the KDE path can then go.
- **Window size and frame:** Chromium sizes its first window to the output
  and assumes the size it gets is the content size. The Haiku frame (tab and
  borders) is drawn outside it, so the window's bottom-right edge is off
  screen; `scripts/run-chromium.sh` passes `--window-size` for new profiles.
  The output's usable area (`xdg_toplevel.configure_bounds`, version 4) minus
  the frame would fix it properly.
- **Protocol versions** Chromium 156 uses and the HaikuPorts server lacks
  (each compiled out or worked around in patch 0010): `wl_fixes`
  (`wl_registry` destruction), `wl_pointer` version 9
  (`axis_relative_direction`), `wl_keyboard` version 10 (key state
  `repeated`). With them, three Haiku blocks in patch 0010 go away.
- **Also used, in rough order of value:** `wl_data_device` (clipboard,
  drag and drop), `zwp_primary_selection_device_manager_v1`,
  `zwp_text_input_manager_v3` (input methods), `wp_fractional_scale_v1` with
  `wp_viewporter`, `xdg_activation_v1` (focus requests), several `wl_output`s
  with `zxdg_output_manager_v1`, `zwp_pointer_constraints_v1` and
  `zwp_relative_pointer_v1` (pointer lock), `zwp_idle_inhibit_manager_v1`
  (video playback), `xdg_toplevel_icon_v1`, `wp_cursor_shape_v1`.
- **GPU-related (phase F, listed because the Wayland layer carries it):**
  `zwp_linux_dmabuf_v1` (feedback version 4) and `wp_linux_drm_syncobj_v1`
  for explicit sync; Chromium's syncobj code uses `eventfd()`, which Renga
  now has.
- **Clipboard formats:** Chromium offers `text/plain;charset=utf-8`,
  `text/html`, `image/png` and `text/uri-list`; a bridge to the Haiku
  clipboard (`B_MIME_DATA` in `be_clipboard`) should map those.

### Phase D (D-Bus, portals, notifications, Secret Service)

- **D-Bus:** the port is built with `use_dbus = true`; Chromium looks for
  the session bus through `DBUS_SESSION_BUS_ADDRESS` and falls back to
  `$XDG_RUNTIME_DIR/bus`. Setting both for every session process is enough.
  Abstract Unix socket names (`F-52`) are used by default by `dbus-daemon`
  on Linux; a filesystem socket under `XDG_RUNTIME_DIR` works as well.
- **Notifications:** Chromium talks to `org.freedesktop.Notifications`
  (it needs the `body` and `actions` capabilities, and uses `body-markup`,
  `body-images`, `body-hyperlinks`, `persistence` and `inline-reply` when
  offered) or, under a portal, to `org.freedesktop.portal.Notification`.
  For the portal it sends the icon as a sealed memfd (`"file-descriptor"`
  variant; `MFD_ALLOW_SEALING`, `F_SEAL_SHRINK | F_SEAL_GROW |
  F_SEAL_WRITE`) when the portal's version supports it, otherwise as bytes.
  The memfd path, compiled out on stock Haiku, now builds on Renga.
- **Secret Service:** `org.freedesktop.secrets` (collections, items,
  `OpenSession` with `plain` and `dh-ietf1024-sha256-aes128-cbc-pkcs7`).
  Until then the port uses `--password-store=basic`.
- **Portals Chromium uses:** `org.freedesktop.portal.FileChooser`
  (used by default when a portal is running), `Notification`, `Settings` (`org.freedesktop.appearance color-scheme` for the
  dark theme, accent color), `ScreenCast` with PipeWire for screen sharing
  in WebRTC (`rtc_use_pipewire`, now off), `OpenURI`, `Inhibit`.
- **UPower:** Chromium's battery status API and power-save decisions read
  `org.freedesktop.UPower` (`DisplayDevice`, `OnBattery`).

### Phases E-H

- **E (media):** audio output goes through the port's Media Kit shim
  (`BSoundPlayer`, patch 0011); audio and video capture are still stubs on
  the port side and are the next port work there. Chromium's Linux camera
  code is V4L2 (`/dev/video*`, `VIDIOC_*`); with Renga's UVC cameras in the
  Media Kit, the port will add a Media Kit capture backend rather than
  expect V4L2, unless Renga plans a V4L2-compatible interface.
- **G (sandbox):** Chromium's OpenBSD port already has a pledge/unveil
  sandbox (`sandbox/policy/openbsd`), which the shared FreeBSD/OpenBSD
  patches in this tree carry. R-1 matters here: sandboxed renderers cannot
  open files, so writable shared memory must not need the temporary
  directory. The zygote needs `fork()` plus `SCM_RIGHTS` on
  `SOCK_SEQPACKET`, which Renga fixed in `F-58`.
- **`futex()` (F-49):** Chromium uses it for the memfd-based Mojo channel
  (`mojo/core/channel_linux.cc`, Linux only), libc++abi's guard waits and
  PartitionAlloc's `SpinningMutex` (`FUTEX_WAIT`/`FUTEX_WAKE` with
  `FUTEX_PRIVATE_FLAG`). The port keeps
  the generic fallbacks until it ships.
- **H:** WebUSB on Linux uses usbfs (`/dev/bus/usb/BBB/DDD`,
  `USBDEVFS_*` ioctls) with udev for enumeration; WebHID uses `hidraw`;
  Web Serial uses `/dev/tty*` with termios and udev; the Gamepad API uses
  evdev (`/dev/input/event*`) with udev. Each is a separate backend in
  Chromium (`services/device/...`); it helps to know early whether Renga
  plans Linux-compatible device nodes or native APIs for them.

## Answered

None yet.
