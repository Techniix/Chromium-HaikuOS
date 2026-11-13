# Copyright 2026 The Chromium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Sourced by prepare-tree.sh and build.sh. Finds the tools the build needs on
# this Haiku system and exports their paths. Anything missing is reported
# together at the end, with the HaikuPorts package or command that usually
# provides it. Run it on its own to check a machine:
#     bash scripts/detect-toolchain.sh

_missing=()
_need() { # var description hint candidates...
  local var=$1 desc=$2 hint=$3; shift 3
  local c p
  for c in "$@"; do
    if p=$(command -v "$c" 2>/dev/null); then
      printf -v "$var" '%s' "$p"; export "${var?}"
      printf '  %-20s %s\n' "$desc" "$p"
      return 0
    fi
  done
  _missing+=("$desc ($hint)")
}
_want() { # like _need, but optional
  local var=$1 desc=$2; shift 3
  local c p
  for c in "$@"; do
    if p=$(command -v "$c" 2>/dev/null); then
      printf -v "$var" '%s' "$p"; export "${var?}"
      printf '  %-20s %s\n' "$desc" "$p"
      return 0
    fi
  done
  printf '  %-20s (not found, optional)\n' "$desc"
}

echo "Toolchain:"
_need CLANG        clang        "HaikuPorts llvm*_clang"   clang
_need CLANGXX      clang++      "HaikuPorts llvm*_clang"   clang++
_need LLD          ld.lld       "HaikuPorts llvm*_lld"     ld.lld
_need LLVM_AR      llvm-ar      "HaikuPorts llvm*"         llvm-ar
_need LLVM_STRIP   llvm-strip   "HaikuPorts llvm*"         llvm-strip
_need LLVM_OBJCOPY llvm-objcopy "HaikuPorts llvm*"         llvm-objcopy
_need RUSTC        rustc        "HaikuPorts rust_bin"      rustc
_need RUSTFMT      rustfmt      "HaikuPorts rust_bin"      rustfmt
_need BINDGEN      bindgen      "cargo install bindgen-cli" bindgen
_need PYTHON       python3      "HaikuPorts python3*"      python3
_need NINJA        ninja        "HaikuPorts ninja"         ninja
_need NODE         node         "pkgman install cmd:node"  node
_need GPERF        gperf        "pkgman install cmd:gperf" gperf
_need PKG_CONFIG   pkg-config   "HaikuPorts pkgconfig"     pkg-config pkgconf
_need BISON        bison        "HaikuPorts bison"         bison
_need FLEX         flex         "HaikuPorts flex"          flex
_need GIT          git          "HaikuPorts git"           git
# esbuild is a Go program; on Haiku the WebAssembly build runs under node.
# /boot/system is read-only, so npm's global prefix must point at the
# writable non-packaged hierarchy (already on PATH):
#   npm config set prefix ~/config/non-packaged && npm install -g esbuild-wasm
_need ESBUILD      esbuild      "pkgman install npm; npm config set prefix ~/config/non-packaged; npm install -g esbuild-wasm" esbuild
_want TSGO         tsgo         "" tsgo
# Without tsgo, the JavaScript compiler is used through a wrapper:
#   npm install -g typescript
_want TSC          tsc          "" tsc
_want SYS_CXX      "system C++" "" g++ c++
_want CLANG_FORMAT clang-format "" clang-format

if [ -n "${CLANG:-}" ]; then
  CLANG_RESOURCE_DIR=$("$CLANG" -print-resource-dir)
  CLANG_BIN_DIR=$(dirname "$(readlink -f "$CLANG")")
  CLANG_BASE_PATH=$(dirname "$CLANG_BIN_DIR")
  # Directory whose lib/ holds libclang.so (needed by bindgen).
  LIBCLANG_PREFIX=
  for d in "$CLANG_BASE_PATH" /boot/system /boot/system/develop; do
    if ls "$d"/lib/libclang.so* >/dev/null 2>&1; then LIBCLANG_PREFIX=$d; break; fi
  done
  [ -n "$LIBCLANG_PREFIX" ] || _missing+=("libclang.so (HaikuPorts llvm*_libs / llvm*_clang)")
  export CLANG_RESOURCE_DIR CLANG_BIN_DIR CLANG_BASE_PATH LIBCLANG_PREFIX
  printf '  %-20s %s\n' "clang base path" "$CLANG_BASE_PATH"
  printf '  %-20s %s\n' "libclang prefix" "${LIBCLANG_PREFIX:-?}"
fi
if [ -n "${RUSTC:-}" ]; then
  RUST_SYSROOT=$("$RUSTC" --print sysroot)
  RUSTC_VERSION=$("$RUSTC" -V)
  export RUST_SYSROOT RUSTC_VERSION
  printf '  %-20s %s (%s)\n' "rust sysroot" "$RUST_SYSROOT" "$RUSTC_VERSION"
fi

# Python bindings for libclang, used by V8's metagen (pip install --user clang; the newest
# release works with newer libclang versions too).
if [ -n "${PYTHON:-}" ]; then
  LIBCLANG_BINDINGS_DIR=$("$PYTHON" -c 'import clang, os; print(os.path.dirname(os.path.dirname(clang.__file__)))' 2>/dev/null || true)
  if [ -z "$LIBCLANG_BINDINGS_DIR" ]; then
    _missing+=("python clang bindings (python3 -m pip install --user clang)")
  fi
  export LIBCLANG_BINDINGS_DIR
fi

echo "Libraries (pkg-config):"
for m in wayland-client wayland-cursor wayland-egl xkbcommon glib-2.0 nss nspr expat; do
  if [ -n "${PKG_CONFIG:-}" ] && "$PKG_CONFIG" --exists "$m" 2>/dev/null; then
    printf '  %-20s %s\n' "$m" "$("$PKG_CONFIG" --modversion "$m")"
  else
    case $m in
      wayland-*) pkg=devel:libwayland_client ;;
      xkbcommon) pkg=devel:libxkbcommon ;;
      glib-2.0)  pkg=devel:libglib_2.0 ;;
      nss)       pkg=devel:libnss3 ;;
      nspr)      pkg=devel:libnspr4 ;;
      expat)     pkg=devel:libexpat ;;
      *)         pkg=$m ;;
    esac
    _missing+=("pkg-config module $m (pkgman install $pkg)")
  fi
done

if [ ${#_missing[@]} -gt 0 ]; then
  echo
  echo "Missing:"
  for m in "${_missing[@]}"; do echo "  - $m"; done
  # When sourced, stop the caller; when run directly, just report.
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "Install the missing tools and try again." >&2
    return 1 2>/dev/null || exit 1
  fi
fi
