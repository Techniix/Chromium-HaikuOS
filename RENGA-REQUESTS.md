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

Last updated: 2026-11-15. Port commit: see `git log -- RENGA-REQUESTS.md`.

## Open

### R-9: wayland_compositor stops on pointer motion over a Chromium window ("Looper must be locked")

- **Status:** landed 2026-11-20, in image `2026.11.20-batch3` (the
  compositor is part of the system package). Motion without a lock,
  confinement or relative pointer no longer enters the constraints code;
  conversions happen with the view's looper locked; a harness check
  reproduces the original stop. Port: no change. Not yet tested in the port.

- **Urgency:** high (Chromium's first window takes the compositor down
  within seconds; every Wayland program loses its connection).
- **What happens:** native Chromium (port commit `5f11bae`, Renga
  `143b8c30`, real hardware, Ryzen 5 7600X, one 3440x1440 output) opens its
  first window, "Chromium Additional Terms of Service", draws it, and a
  moment later, as the mouse moves over the window, the compositor's
  window thread for that surface calls `debugger("Looper must be locked.")`
  and the compositor dies. Chromium then logs
  `Fatal Wayland communication error: Broken pipe`. Reproduced twice in a
  row (crash reports `app-wayland_compositor-2026-11-19_20-26-07.txt` and
  `…_20-27-08.txt` in `/boot/system/var/log/crash/`).
- **Backtrace (both times identical):**
  ```
  thread "w>Chromium Additional Terms of" (the surface's BWindow looper)
    _kern_debugger
    BView::_CheckOwnerLock() const
    BView::_ConvertToScreen(BPoint*, bool) const
    BView::ConvertToScreen(BPoint) const
    HaikuPointerConstraintsMotion(HaikuSurface*, long, BPoint) + 0x44
    HaikuSeatGlobal::MessageReceived(HaikuSurface*, BMessage*) + 0x42b
    WaylandView::MessageReceived(BMessage*) + 0x200
    BWindow::task_looper()
  ```
  `HaikuPointerConstraintsMotion()` converts a point with a view whose
  looper the calling thread does not hold: most likely a view of another
  surface's window (or of a surface without a window), since the calling
  window's own looper is locked while it dispatches the message.
- **What Chromium had sent:** the client never asked for a pointer lock
  or confinement. It bound `zwp_pointer_constraints_v1` and
  `zwp_relative_pointer_manager_v1` (as it always does) but made no
  `lock_pointer`, `confine_pointer` or `get_relative_pointer` request.
  It has two surfaces: `wl_surface@28`, created at start-up and never
  given a role or a buffer, and `wl_surface@29`, the xdg_toplevel
  (server-side decoration, `wp_viewport` destination 600x508, buffers
  900x762 at fractional scale 180/120). The last requests before the
  disconnect were an ordinary frame: `frame`, `attach`, `damage`,
  `commit`. No protocol error was sent to the client.
- **Exact behaviour asked for:** pointer motion with no active constraint
  must not touch any other view; where a conversion to screen coordinates
  is needed, do it with the view's own looper locked (or from cached
  window coordinates), and do nothing when the client has no lock or
  confinement on that surface.
- **Repro:** run native Chromium (`scripts/run-chromium.sh OUT_DIR`) on a
  new profile and move the mouse over the first window. A smaller client
  that binds `zwp_pointer_constraints_v1`, creates an unused
  `wl_surface` plus an xdg_toplevel with a buffer, then waits for pointer
  motion, is likely to reproduce it, but that is untested. The full
  `WAYLAND_DEBUG=1` client log of the run is available on request.

### R-8: Renguin claims native Haiku executables whose EI_OSABI is GNU

- **Status:** landed 2026-11-15 (`b2484110`), in image
  `2026.11.15-chromium-readiness` (`143b8c30`). Renguin takes `EI_OSABI` 3
  as a Linux brand only for programs without `PT_INTERP` and without
  `DT_NEEDED`; faults of Linux threads now reach an attached debugger and
  are logged. Renga's runtime_loader also applies `R_X86_64_IRELATIVE`
  (IFUNCs within one image; not yet IFUNC symbols referenced from another
  image). Port: no change; the local byte-7 reset is not needed on that
  image. Not yet tested in the port.
- **Urgency:** high (stops the Chromium build; will also stop `chrome`).
- **What happens:** V8's `mksnapshot`, a native Haiku executable built by
  this port (`ET_DYN`, linked with `-shared` like every Haiku program, no
  `PT_INTERP`, `PT_DYNAMIC` with `DT_NEEDED` `libroot.so`, `libgnu.so`,
  `libbsd.so`, `libnetwork.so`, `libgcc_s.so.1`), dies with SIGSEGV before
  any of its code runs, even for `./mksnapshot --help` (Renga `ea9753b2`,
  real hardware). Its ELF header has `EI_OSABI` 3 (`ELFOSABI_GNU`/Linux):
  lld brands the output GNU when an input object uses GNU extensions such
  as IFUNC symbols. `renguin_probe()` (`personalities/renguin/loader.cpp`,
  check 2) claims every executable with that byte as a Linux program, so
  Renguin loads this Haiku program with the Linux personality.
- **Evidence:** the SIGSEGV has `si_addr` NULL, `si_errno` `EFAULT`
  (0x80001301) and the team itself as sender; `strace` shows no system
  call before it (native programs show the runtime loader's calls from
  `image_relocated` on); a preloaded library's constructor never runs; the
  graphical Debugger, attached from the start, is never told about a fault
  and only reports that the team terminated (the page-fault path in
  `vm.cpp` sends foreign-ABI threads the signal through
  `foreign_personality_fault_signal()` without notifying the user
  debugger); nothing is logged. `torque`, a smaller V8 tool from the same
  build with `EI_OSABI` 0, runs normally. On stock Haiku, where nothing
  reads `EI_OSABI`, the same `mksnapshot` ran.
- **Exact behaviour asked for:** do not take `EI_OSABI` 3 alone as proof
  of Linux for a dynamically linked executable without a Linux
  interpreter. The comment on check 2 names glibc's *static* programs with
  IFUNCs; restricting it to executables without `PT_DYNAMIC` (or to those
  with a Linux `PT_INTERP`, or excluding any whose `DT_NEEDED` list names
  `libroot.so`) would keep that case and leave Haiku programs alone. Native
  executables with GNU extensions are normal output of lld and GCC on Haiku.
- **Repro:** any Haiku program built with clang and lld that contains an
  IFUNC (for example `__attribute__((ifunc("resolver")))`), or an existing
  executable with byte 7 of its ELF header set to 3:
  `printf '\003' | dd of=prog bs=1 seek=7 conv=notrunc` on a copy of any
  native program, then run it.
- **Port meanwhile:** nothing is committed. To keep a local build going,
  byte 7 of the affected executables in `out/Release` can be reset to 0
  (Haiku's runtime_loader does not read it); this has to be repeated after
  each relink.

### R-7: wl_fixes version 2 in renga_wayland's core protocol

- **Status:** landed 2026-11-14 (`c855b4b3`; package `renga_wayland`
  `r1~beta6_hrev60381_305-1` in RengaPorts, `pkgman refresh && pkgman
  update renga_wayland`, no system update needed). Headers and interface
  tables have `wl_fixes` 2; the compositor offers version 2 from the next
  image. Port: drop the local `#ifdef` once the package is installed; not
  yet tested. The compositor side (advertising version 2) is in image
  `2026.11.15-chromium-readiness` (`143b8c30`).
- **Urgency:** high (stops the Chromium build).
- **Need:** `renga_wayland`'s core protocol, both the generated
  `wayland-client-protocol.h` and the `wl_fixes_interface` table compiled
  into `libwayland-client-renga`, at `wl_fixes` version 2, which adds the
  request `ack_global_remove(registry: object wl_registry, name: uint)`
  (opcode 2, since 2) and the `invalid_ack_remove` error.
- **Why:** Chromium 156 builds against the system libwayland's headers.
  `ui/ozone/platform/wayland/host/wayland_connection.cc` binds `wl_fixes` up
  to version 2 and, in its `wl_registry.global_remove` handler, calls
  `wl_fixes_ack_global_remove()` when the bound version is at least
  `WL_FIXES_ACK_GLOBAL_REMOVE_SINCE_VERSION`. Renga's headers are generated
  from Wayland 1.24's `wayland.xml`, where `wl_fixes` is version 1, so
  neither name exists and the file does not compile:
  `error: use of undeclared identifier 'WL_FIXES_ACK_GLOBAL_REMOVE_SINCE_VERSION'`
  (first Renga build, `ea9753b2`, real hardware).
- **Exact behaviour asked for:** generate the headers and the interface
  tables from a `wayland.xml` with `wl_fixes` version 2 (the one bundled in
  Chromium 156, `third_party/wayland/src/protocol/wayland.xml`, has it).
  The compositor may keep advertising version 1: Chromium sends the request
  only when it bound version 2. If the compositor offers version 2, it must
  accept the acknowledgement of a removed global, and it may then destroy
  the global for good once every client bound to `wl_fixes` 2 has
  acknowledged it.
- **Only this is used:** comparing Chromium's bundled `wayland.xml` with
  Renga's, Chromium's protocol is newer in several places (`wl_compositor`
  7, `wl_surface` 7, `wl_seat` 11, `wl_data_device_manager` 4, new
  `wl_shm` formats), but Chromium 156 binds `wl_compositor` up to 4,
  `wl_seat` up to 10 and `wl_data_device_manager` up to 3 and uses none of
  the newer names; `wl_fixes` 2 is the only one it needs.
- **Port meanwhile:** nothing is committed. To keep a local build going,
  wrap that one call in
  `#ifdef WL_FIXES_ACK_GLOBAL_REMOVE_SINCE_VERSION` in the source tree; it
  then compiles the call again by itself once Renga's headers have it.

## Landed in Renga, not yet tested in the port

Renga accepted R-1 to R-6 on 2026-11-14 and landed them the same day in
image `2026.11.14-chromium-wayland` (`CHROMIUM.md`, "landed: R-1 to R-5 and
the compositor completion"; QEMU tested on Renga's side). The port changes
listed under each entry are on the `renga` branch since 2026-11-14 (see
`docs/RENGA.md`). Entries move to "Answered" once the port has been built
and run on that image.

### R-3: backtrace_symbols(): which "+0x" offset, and frames outside the first region

- **Status:** landed 2026-11-14 (`c595cafe`): frames are found in any
  segment and printed as `image(+0xOFF)`, `OFF` = address - load bias (the
  ELF virtual address). Port: `--base image` is the default now.
  Accepted earlier the same day: Renga confirmed that frames in the
  executable segment of an lld-linked image can print as a bare `[0x...]`
  today. It will find the image for an address in any of its mapped
  segments (through `dladdr()`) and print `image(+0xOFF)` with `OFF` counted
  from the image's load address, as glibc, and document it in `PORTING.md`.
  **Port, when it lands:** make `--base image` the default of
  `tools/symbolize-trace.py`; capture the V8 crash (phase B item 7) again,
  since traces from earlier images may be missing frames.
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

- **Status:** landed 2026-11-14 (`da0ac1d9`; `open()` only, no `stat()`,
  `readlink()` or listing; a socket descriptor gives `ENXIO`). Accepted as
  a small native `/proc` for Renga
  programs: `open("/proc/self/fd/N", O_RDONLY)` creates a new open file
  description with Linux semantics; `/dev/fd/N` behaves the same.
  **Port, when it lands:** nothing to change; writable regions become
  memfd-backed because the code already tries `/proc/self/fd/N`. Confirm with
  the "R-1" line of `scripts/renga-tests.sh probe`.
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

- **Status:** landed 2026-11-14 (`da0ac1d9`; `start - offset` = load
  base). Accepted as (`/proc/self/maps` in Linux's format,
  part of the same `/proc`).
  **Port, when it lands:** consider building Chromium's in-process
  symbolizer (`USE_SYMBOLIZE`) again on Renga, for file:line in traces
  without the offline tool; it also needs R-3's behaviour to agree with it.
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

- **Status:** landed 2026-11-14 (`976dcccc`); port fallback removed.
  Accepted as (`SO_TIMESTAMP` with `SCM_TIMESTAMP` on
  `recvmsg()`/`recvmmsg()`).
  **Port, when it lands:** remove the `SO_TIMESTAMP` fallback from patch 0008
  (net and WebRTC).
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

- **Status:** landed 2026-11-14 (`976dcccc`); port declaration removed.
  Accepted as (`struct ip_mreqn` in `<netinet/in.h>`,
  honoured by `IP_ADD_MEMBERSHIP`, `IP_DROP_MEMBERSHIP` and
  `IP_MULTICAST_IF`, `imr_ifindex` first).
  **Port, when it lands:** remove the `ip_mreqn` declaration from patch 0008.
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

- **Status:** landed 2026-11-14 (`da0ac1d9`). Accepted as
  (`/proc/sys/fs/inotify/max_user_watches`,
  8192, per instance).
  **Port, when it lands:** nothing to change; the error line goes away.
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

Status (2026-11-14, evening): landed. Renga's compositor now has
everything below except `linux-dmabuf`, `linux-drm-syncobj` and
`libwayland-egl` (GPU stage), and `renga_wayland` is packaged. The port
builds against it and has dropped the KDE decoration path and the
version-compatibility blocks of patch 0010 (`docs/RENGA.md`). One item is
now on the port's side: Chromium 156 ignores `configure_bounds`
(`XdgToplevel::OnConfigureBounds` is `NOTIMPLEMENTED`), so using it for the
first window's size needs a port change.

Earlier the same day: Renga runs a socket Wayland compositor
(`$XDG_RUNTIME_DIR/wayland-0`) with xdg-shell, `wl_shm` from memfd,
subsurfaces, viewporter, xdg-activation, text-input-v3, KDE
server-decoration, one output and the clipboard (QEMU tested). Renga
accepted the remaining items below for the same batch as R-1 to R-6, except
`linux-dmabuf` and `linux-drm-syncobj`, which come with the GPU stage. Renga
will also package its socket libwayland (client, server, headers, `.pc`
files) for ports; until that entry names the package, the port keeps
HaikuPorts' in-process libwayland. When both land, the port moves to the
packaged libwayland and drops the KDE decoration path and the
version-compatibility blocks in patch 0010.

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

Status (2026-11-20): Renga runs a D-Bus session bus at login
(`DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/xdg-runtime/bus`) with
`org.freedesktop.Notifications`, `org.freedesktop.UPower`,
`org.freedesktop.portal.Desktop` (Settings, OpenURI) and
`org.freedesktop.secrets` (asking the user once per program). Not yet:
FileChooser, Screenshot and ScreenCast portals, and a system bus. The port
is already built with `use_dbus = true` against HaikuPorts' libdbus, so
notifications, battery status and the dark-theme setting should work on an
image with the bus without a port change; `--password-store=basic` stays
until the libsecret path has been tried. The notes below were written
before this landed.

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
- **H (gamepads):** Renga exposes pads as evdev devices
  (`/dev/input/event<N>`) and game controllers as `/dev/hidraw<N>`, without
  udev (`CHROMIUM.md`, 2026-11-13). Chromium's Linux gamepad and HID code
  enumerates and watches devices through udev (`device/udev_linux`), so phase
  H needs either a udev-compatible enumeration interface from Renga or a
  small port-side enumerator over `/dev/input` with inotify. To be decided
  with Renga before phase H starts.
- **H:** WebUSB on Linux uses usbfs (`/dev/bus/usb/BBB/DDD`,
  `USBDEVFS_*` ioctls) with udev for enumeration; WebHID uses `hidraw`;
  Web Serial uses `/dev/tty*` with termios and udev; the Gamepad API uses
  evdev (`/dev/input/event*`) with udev. Each is a separate backend in
  Chromium (`services/device/...`); it helps to know early whether Renga
  plans Linux-compatible device nodes or native APIs for them.

## Answered

None closed yet; R-1 to R-6 are accepted and waiting to land (above).
