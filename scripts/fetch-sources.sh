#!/bin/bash
# Copyright 2026 The Chromium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Download and unpack the Chromium release tarball this port is pinned to.
# Usage: scripts/fetch-sources.sh [WORK_DIR]     (default: ./work)
#
# The "-lite" tarball is the one FreeBSD builds from (no test data); it is
# about 2 GB compressed and ~10 GB unpacked.

set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/scripts/version.sh"

WORK=${1:-$HERE/work}
mkdir -p "$WORK"
cd "$WORK"

TARBALL=chromium-${CHROMIUM_VERSION}-lite.tar.xz
URL=https://commondatastorage.googleapis.com/chromium-browser-official/$TARBALL

if [ ! -f "$TARBALL" ]; then
  echo "Downloading $URL"
  curl -fL --retry 3 -C - -o "$TARBALL.part" "$URL"
  mv "$TARBALL.part" "$TARBALL"
fi

echo "Verifying SHA-256"
actual=$(sha256sum "$TARBALL" | cut -d' ' -f1)
if [ "$actual" != "$CHROMIUM_SHA256" ]; then
  echo "Checksum mismatch for $TARBALL" >&2
  echo "  expected $CHROMIUM_SHA256" >&2
  echo "  actual   $actual" >&2
  exit 1
fi

SRC=$WORK/chromium-${CHROMIUM_VERSION}
if [ -d "$SRC" ]; then
  echo "$SRC already exists; not unpacking again."
else
  echo "Unpacking (this takes a while)"
  tar -xJf "$TARBALL"
fi

echo
echo "Sources ready in $SRC"
echo "Next: scripts/prepare-tree.sh $SRC"
