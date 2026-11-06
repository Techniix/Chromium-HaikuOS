# Chromium for Haiku

A port of the [Chromium](https://www.chromium.org/) web browser to
[Haiku](https://www.haiku-os.org/), built natively on Haiku from the official
Chromium release sources.

**Status: pre-alpha, never built yet.** The patch series and build scripts
are complete for a first build attempt of **Chromium 156.0.8078.79**. They
apply cleanly to that release and have been checked end to end, but nothing
has been compiled on Haiku yet. Expect the first builds to surface compile
errors; [`docs/PORTING.md`](docs/PORTING.md) lists where they are most likely.

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
main requirements are LLVM/Clang with lld, Rust, Python 3, Ninja, Node.js,
gperf, `bindgen` (`cargo install bindgen-cli`), `esbuild`, the Python libclang
bindings, and the development packages for wayland, libxkbcommon, glib, nss
and expat.

`/boot/system` is read-only on Haiku, so install npm and pip tools into your
home directory:

```sh
npm config set prefix ~/config/non-packaged   # bin/ is already on PATH
npm install -g esbuild-wasm
python3 -m pip install --user "clang==$(clang -dumpversion | cut -d. -f1).*"
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
