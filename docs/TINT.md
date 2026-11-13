# Pregenerated Tint sources

Dawn's shader compiler, Tint, has source files that are generated at build
time by a Go program (`third_party/dawn/src/cmd/gen`). That program needs
Go 1.26 or newer, and Haiku's HaikuPorts Go is older (1.18 at the time of
writing). The build therefore uses files generated once on another machine:

- `prebuilt/tint-gen.tar.gz`: 26 generated files under `src/tint/`
  (intrinsic tables, builtin function lists, enums), produced from Dawn
  commit `8114a24a35eed1db88d1d897e8bd193a8c334712`, the revision Chromium
  156.0.8078.79 pins in `DEPS`.
- `scripts/build.sh` unpacks them into `out/Release/gen` before `gn gen`.
- Haiku patch 0009 replaces `third_party/dawn/tools/generate-sources-gn.py`
  with a check that the files are present.

These files are Dawn source (BSD-3-Clause) and only change when Chromium
moves to a new Dawn revision.

## Regenerating them

The pristine `generate-sources-gn.py` runs, from the Dawn checkout:

```sh
GO111MODULE=on CGO_ENABLED=0 go run ./src/cmd/gen/sources <absolute out dir>
```

where `<out dir>` is the build directory's `gen` directory. To refresh the
archive, on any machine with Go 1.26 or newer and git:

```sh
git clone https://dawn.googlesource.com/dawn && cd dawn
git checkout <dawn revision from Chromium's DEPS>
GO111MODULE=on CGO_ENABLED=0 go run ./src/cmd/gen/sources /tmp/tint-gen
tar -czf tint-gen.tar.gz -C /tmp/tint-gen src
```

Check that the archive contains `src/tint/lang/core/enums.cc`, then replace
`prebuilt/tint-gen.tar.gz` and update the commit above. (The generator's
command line can change between Dawn revisions; the pristine script is the
reference.)
