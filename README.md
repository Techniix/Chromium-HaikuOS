# Chromium for Haiku

A port of the [Chromium](https://www.chromium.org/) web browser to
[Haiku](https://www.haiku-os.org/), built natively on Haiku from the official
Chromium release sources.

**Status: pre-alpha.** **Chromium 156.0.8078.79** builds and runs on Haiku
(x86_64, tested on hrev60368): it opens a native Haiku window, browses the
web over HTTP/2, plays video (including AV1) and plays sound through the
Media Kit. It runs without a sandbox, with software rendering and without
HTTP/3; [`docs/PORTING.md`](docs/PORTING.md) lists the known limitations.

A second target, Renga (a Haiku-based operating system that adds the Linux
and BSD interfaces Chromium uses), is developed on the `renga` branch.

## How it works

Haiku is a POSIX desktop OS that is not Linux, which is exactly the situation
the FreeBSD Chromium port already solves, release after release. So instead
of porting 30 million lines from scratch, the port is built in layers:

```
Chromium 156 release tarball
  └─ + FreeBSD port patches (1,696)     patches/freebsd/      "non-Linux desktop Unix"
      └─ + haikuify.py                  tools/haikuify.py     extends ~3,000 BSD guards to Haiku
          └─ + Haiku patches            patches/haiku/        what only Haiku needs
              └─ system toolchain       scripts/              LLVM, Rust, node from HaikuPorts
```

- **FreeBSD patches** teach Chromium to build as a desktop Unix that isn't
  Linux. Both FreeBSD and this port treat the OS as "Linux in GN, its own
  platform in C++".
- **`tools/haikuify.py`** rewrites every `BUILDFLAG(IS_BSD)` / `is_bsd` guard
  to also cover Haiku. It skips any guard whose code depends on BSD-kernel
  interfaces (sysctl, kqueue, `pthread_*_np`, ...) and lists those sites as
  the hand-porting worklist ([`docs/haikuify-report.md`](docs/haikuify-report.md)).
  Because it is a tool rather than a patch, it carries over to each new
  FreeBSD release almost for free.
- **Haiku patches** add the Haiku platform itself: build flags and toolchain,
  native `base/` code on Haiku's kernel API (teams, areas, threads, images),
  a poll()-based message pump, and a V8 platform layer.
- **UI** runs on Chromium's Ozone/Wayland backend through Haiku's built-in
  Wayland compatibility layer, with software rendering to start.

## Building

You need a Haiku x86_64 machine with plenty of resources: roughly 100 GB of
free disk, 16 GB or more of RAM, and many hours of CPU time.

```sh
git clone https://github.com/Techniix/Chromium-HaikuOS.git
cd Chromium-HaikuOS

bash scripts/detect-toolchain.sh        # lists any missing tools/libraries
sh tools/probe-haiku-libc.sh            # records which libc APIs this Haiku has

scripts/fetch-sources.sh                # downloads + verifies the 2 GB tarball into work/
scripts/prepare-tree.sh work/chromium-156.0.8078.79
scripts/build.sh work/chromium-156.0.8078.79
scripts/run-chromium.sh work/chromium-156.0.8078.79/out/Release
```

`detect-toolchain.sh` names the HaikuPorts package for anything missing. The
first successful build used these packages:

```sh
pkgman install llvm23 llvm23_clang llvm23_lld llvm23_libs rust_bin bindgen \
    python3.14 setuptools_python3.14 ninja nasm pkgconfig gperf bison flex \
    git nodejs24 npm gcc haiku_devel wayland wayland_devel wayland_protocols \
    wayland_server libxkbcommon_devel glib2_devel nss_devel nspr_devel \
    dbus_devel expat_devel cairo_devel pango_devel harfbuzz_devel \
    fontconfig_devel freetype_devel
```

`wayland_server` is the in-process Wayland server Chromium's windows go
through; without it Chromium exits with "Failed to connect to Wayland
display". Install packages before starting a build, not during one: an
update of `haiku_devel` changes the system headers' timestamps and makes
ninja rebuild almost everything (`tools/skip-sysheader-rebuild.sh` repairs
that).

`scripts/build.sh` sets `RUSTC_BOOTSTRAP=1` (Chromium's Rust code uses
unstable features) and adds `prebuilt/pkgconfig` to `PKG_CONFIG_PATH`: stub
entries for three libraries Haiku does not have and GN only checks for
(`atspi-2`, `dri`, `gbm`). If you run `ninja` yourself after `build.sh`, set
both in your shell first, since ninja reruns `gn gen` when build files
change.

`/boot/system` is read-only on Haiku, so install npm and pip tools into your
home directory:

```sh
npm config set prefix ~/config/non-packaged   # bin/ is already on PATH
npm install -g esbuild-wasm typescript
python3 -m pip install --user clang   # newest bindings work with newer libclang
```

Please attach the output of `probe-haiku-libc.sh` and the first failing
compile step when reporting a build problem.

## Repository layout

| Path | Contents |
| --- | --- |
| `patches/freebsd/` | FreeBSD `www/chromium` patches, pinned to the commit in `scripts/version.sh` |
| `patches/haiku/chromium/` | Haiku patches for Chromium, applied in order |
| `patches/haiku/v8/` | Haiku patch for V8 |
| `tools/haikuify.py` | Extends FreeBSD's BSD guards to Haiku and writes the worklist |
| `tools/probe-haiku-libc.sh` | Checks which BSD/GNU/Linux libc interfaces this Haiku provides |
| `scripts/` | Fetch, prepare, build and run scripts, plus the GN args template |
| `prebuilt/tint-gen.tar.gz` | Pregenerated Tint sources (their generator needs Go 1.26+), see `docs/TINT.md` |
| `prebuilt/pkgconfig/` | Stub pkg-config entries for libraries GN asks about but Haiku lacks |
| `tools/skip-sysheader-rebuild.sh` | Avoids a full rebuild after a system-header update |
| `docs/PORTING.md` | Design, decisions, current gaps and how to update to a new release |
| `docs/haikuify-report.md` | Hand-porting worklist for 156.0.8078.79 |

## License

Chromium for Haiku is distributed under the same BSD 3-Clause license as
Chromium: see [`LICENSE`](LICENSE), "Copyright 2015 The Chromium Authors".
The new Haiku source files carry Chromium's standard license header, so they
can be contributed upstream unchanged. The V8 patch is under V8's
BSD 3-Clause license.

This repository also redistributes or builds on third-party work under its
own terms:

- `patches/freebsd/`: FreeBSD Ports Collection, BSD 2-Clause.
- HaikuPorts' QtWebEngine patch set, consulted as a reference: MIT.

The full notices are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

Chromium's source code is not included here. The build downloads the official
release tarball, which comes with Chromium's own license and the licenses of
all bundled third-party components (shown at `chrome://credits` in a build).

This is an independent community project. It is not affiliated with or
endorsed by Google, The Chromium Authors, The FreeBSD Project or Haiku, Inc.
"Chrome" and "Google Chrome" are trademarks of Google LLC. Builds from this
project are named Chromium and must not use Google Chrome branding.
