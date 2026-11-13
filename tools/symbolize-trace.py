#!/usr/bin/env python3
# Copyright 2026 The Chromium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
"""Resolve the stack frames Chromium prints on Renga to functions and lines.

On Renga, Chromium's stack traces come from backtrace_symbols() and
backtrace_symbols_fd() (libgnu), which print glibc-style frames:

    /path/to/image(symbol+0x1f) [0x7f...]    exported function + offset
    /path/to/image(+0x1234) [0x7f...]        non-exported function

Most of Chromium is hidden-visibility code, so most frames are of the second
kind. This script reads a log (stderr of chrome, or a file), resolves every
such frame with llvm-symbolizer and prints the trace with function names (and
file:line if the build has debug info, i.e. symbol_level >= 1).

Usage:
    tools/symbolize-trace.py [--dir OUT_DIR] [--symbolizer PATH] [LOG]

  --dir        where to look for images whose path in the log does not exist
               on this machine (for example out/Release); may be repeated
  --base       how "+0x" offsets are counted: "text" (from the start of the
               image's first executable PT_LOAD segment) or "image" (from the
               load address, as glibc does). Default "text", matching Renga's
               execinfo.cpp, which counts from image_info.text. See
               RENGA-REQUESTS.md R-3.

Lines that are not frames are printed unchanged, so the whole log can be
piped through it.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys

FRAME = re.compile(
    r"(?P<image>[^\s()\[\]]+)\((?P<sym>[^()+\s]*)\+0x(?P<off>[0-9a-fA-F]+)\)"
    r"(?:\s*\[(?P<addr>0x[0-9a-fA-F]+)\])?")


def find_tool(name, override):
    if override:
        return override
    for candidate in (name, name + "-23", name + "-22", name + "-21",
                      name + "-20", name + "-19", name + "-18"):
        path = shutil.which(candidate)
        if path:
            return path
    sys.exit(f"{name} not found; pass --symbolizer or put it in PATH")


class Image:
    def __init__(self, path, tools):
        self.path = path
        self.tools = tools
        self._symbols = None
        self._text_vaddr = None

    def text_vaddr(self):
        """Virtual address of the first executable PT_LOAD segment."""
        if self._text_vaddr is None:
            self._text_vaddr = 0
            out = subprocess.run([self.tools["readelf"], "-lW", self.path],
                                 capture_output=True, text=True).stdout
            for line in out.splitlines():
                f = line.split()
                if f and f[0] == "LOAD" and "E" in "".join(f[6:-1]):
                    self._text_vaddr = int(f[2], 16)
                    break
        return self._text_vaddr

    def symbol_vaddr(self, name):
        if self._symbols is None:
            self._symbols = {}
            out = subprocess.run(
                [self.tools["nm"], "--defined-only", "-D", self.path],
                capture_output=True, text=True).stdout
            for line in out.splitlines():
                f = line.split()
                if len(f) >= 3:
                    # Drop symbol versions (name@@VERSION).
                    self._symbols[f[2].split("@")[0]] = int(f[0], 16)
        return self._symbols.get(name)


def resolve_image(path, dirs, cache, tools):
    if path in cache:
        return cache[path]
    found = path if os.path.isfile(path) else None
    if not found:
        base = os.path.basename(path)
        for d in dirs:
            if os.path.isfile(os.path.join(d, base)):
                found = os.path.join(d, base)
                break
    cache[path] = Image(found, tools) if found else None
    return cache[path]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("log", nargs="?", help="log file (default: stdin)")
    ap.add_argument("--dir", action="append", default=[])
    ap.add_argument("--symbolizer")
    ap.add_argument("--base", choices=("text", "image"), default="text")
    args = ap.parse_args()

    symbolizer = find_tool("llvm-symbolizer", args.symbolizer)
    tools = {
        "readelf": find_tool("llvm-readelf", None),
        "nm": find_tool("llvm-nm", None),
    }
    cache = {}
    src = open(args.log, errors="replace") if args.log else sys.stdin

    for line in src:
        line = line.rstrip("\n")
        m = FRAME.search(line)
        image = m and resolve_image(m.group("image"), args.dir, cache, tools)
        if not image:
            print(line)
            continue
        off = int(m.group("off"), 16)
        if m.group("sym"):
            start = image.symbol_vaddr(m.group("sym"))
            if start is None:
                print(line)
                continue
            vaddr = start + off
        else:
            vaddr = off + (image.text_vaddr() if args.base == "text" else 0)
        # Return addresses point after the call; look up the call itself.
        out = subprocess.run(
            [symbolizer, "--obj=" + image.path, "--demangle", "--inlines",
             "--relativenames", hex(vaddr - 1)],
            capture_output=True, text=True).stdout.strip().splitlines()
        frames = [out[i] + " " + out[i + 1]
                  for i in range(0, len(out) - 1, 2)] or ["??"]
        prefix = line[:m.start()]
        print(f"{prefix}{os.path.basename(image.path)}+{vaddr:#x}  "
              + "\n    inlined into ".join(frames))


if __name__ == "__main__":
    main()
