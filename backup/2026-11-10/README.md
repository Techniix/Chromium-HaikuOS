# Backup: Haiku build-tree changes, 2026-11-10

This branch preserves the state of a working Chromium 156.0.8078.79 build on
Haiku (x86_64, hrev60368) before a reinstall. It is a **raw backup**, not the
supported way to build: `main` still builds from `patches/`, and these changes
are being converted into a proper patch series there.

Status at the time of the backup: `chrome` builds, links and runs through
Haiku's in-process Wayland server (`wayland_server`), with native Haiku window
decorations, AV1 video, and a Media Kit audio backend that builds and links
(pass 16; audio output not yet tested at the time of this backup).

## Contents

| Path | What it is |
| --- | --- |
| `tree/` | Every file in the build tree that changed after `scripts/prepare-tree.sh` finished (`changed-files.txt`, marker time in `marker.txt`). Full file copies, laid out like the Chromium source tree. Build products and machine-specific links are left out. |
| `scripts/haiku-fixes-pass3.sh` ... `pass16.sh` | The idempotent fix scripts that produced most of `tree/`, in the order they were applied. Each script's header comment explains what it fixes and why. |
| `scripts/haiku-skip-sysheader-rebuild.sh` | Avoids a full rebuild after `pkgman` updates system headers (rewrites ninja's dependency timestamps). |
| `scripts/export-haiku-changes.sh`, `scripts/quick-save-haiku.sh` | The tools used to capture this backup. |
| `tint-gen.tar.gz` | Pregenerated Tint (Dawn) sources. Generating them needs Go 1.26 or newer, which Haiku does not have; they were produced on Linux from Dawn commit `8114a24a35eed1db88d1d897e8bd193a8c334712` and are extracted into `out/Release/gen`. |
| `environment/args.gn` | The GN arguments of the working build. |
| `environment/repo.diff`, `repo-status.txt`, `repo-log.txt` | Uncommitted changes in this repository (to `scripts/args.gn.in` and `scripts/build.sh`) on top of commit `7835a6f`. |
| `environment/pkgconfig/` | Stub `.pc` files (`atspi-2`, `dri`, `gbm`) placed in `~/config/non-packaged/lib/pkgconfig` so `gn gen` resolves those dependencies. |
| `environment/installed-packages.txt`, `environment.txt` | Installed Haiku packages and toolchain versions (clang 23.1.4, rustc 1.94.1, Node 24.21.0, Python 3.14). |
| `logs/build-logs.tar.xz` | Ninja logs from the later build passes, kept for reference when turning the fixes into patches. |

## Restoring onto a fresh tree

1. Install the packages listed in `environment/installed-packages.txt` that the
   build needs (LLVM 23 with clang and lld, `rust_bin`, `nodejs24`, `npm`,
   `python3.14`, `ninja`, `nasm`, the `*_devel` packages, `wayland_server`).
2. Copy `environment/pkgconfig/*.pc` to `~/config/non-packaged/lib/pkgconfig/`.
3. Fetch and prepare the tree as usual (`scripts/fetch-sources.sh`,
   `scripts/prepare-tree.sh`), with `environment/repo.diff` applied to this repo.
4. Copy `tree/` over the prepared tree (`cp -a tree/. <chromium-src>/`).
5. Rebuild the compat helper library: `build/config/haiku/compat/lib/` holds the
   sources; `scripts/haiku-fixes-pass16.sh` shows the exact commands
   (`libhaikucompat.a` from `haiku_cxa_thread_atexit.c` and
   `haiku_media_audio.cpp`; `libm.a` is a linker script, already in `tree/`).
   Also create empty `libdl.a`, `librt.a` and `libpthread.a` there
   (`ar rcs <name>`), as pass 9 does.
6. Extract `tint-gen.tar.gz` into `out/Release/gen`, then build with
   `scripts/build.sh` or `ninja -C out/Release chrome`.

## Licences

Files under `tree/` are modified Chromium (and third-party) sources and keep
their original licences. `tree/build/config/haiku/compat/linux/input-event-codes.h`
is the Linux UAPI header (GPL-2.0 WITH Linux-syscall-note), used only for its
key code definitions.
