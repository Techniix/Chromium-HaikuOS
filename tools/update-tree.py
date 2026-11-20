#!/usr/bin/env python3
# Copyright 2026 The Chromium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
"""Bring a prepared Chromium tree from one version of the Haiku patches to
another, touching only the files whose result changes.

prepare-tree.sh applies patches/haiku/{chromium,v8}/*.patch once, to a fresh
tree. When those patches change later (a fix in the port repository), a tree
that has already been built does not need to be prepared again: for every
file the old or new patch series touches differently, this script

  1. takes the file as it is in the tree,
  2. undoes the old series' changes to it (in reverse order),
  3. applies the new series' changes to it (in order), and
  4. writes it back only if the result differs from what is there,

so unchanged files keep their timestamps and ninja rebuilds only what the
patch update really changed.

Files that were edited by hand to match the new patches already (a fix
applied in place before the patches were updated) are recognised and left
alone. Files that match neither are reported as conflicts and not touched.

Usage:
  tools/update-tree.py SRC --from OLD_COMMIT [--to NEW_COMMIT] [--dry-run]
      [--clang-resource-dir DIR] [--accept PATH ...]

  OLD_COMMIT  the port commit whose patches the tree has (prepare-tree.sh and
              this script record it in SRC/.haiku-port-commit)
  NEW_COMMIT  default HEAD
  --clang-resource-dir  value prepare-tree.sh substitutes for
              @CLANG_RESOURCE_DIR@ in patch 0006 (default: from clang)
  --accept PATH  treat PATH (relative to SRC) as already up to date and
              leave it alone: for a file fixed by hand in a way that differs
              in wording from the new patch (reported as a conflict), or
              to skip an update on purpose. May be repeated.

Exit status: 0 when done (or nothing to do), 1 when there were conflicts.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATCH_DIRS = ("patches/haiku/chromium", "patches/haiku/v8")


def git(*args):
    return subprocess.run(["git", "-C", REPO] + list(args), check=True,
                          capture_output=True, text=True).stdout


def patch_series(commit, subst):
    """[(patch name, text)] in application order at a commit."""
    series = []
    for d in PATCH_DIRS:
        names = git("ls-tree", "--name-only", commit, d + "/").split()
        for path in sorted(n for n in names if n.endswith(".patch")):
            text = git("show", f"{commit}:{path}")
            for k, v in subst.items():
                text = text.replace(k, v)
            series.append((path, text))
    return series


DIFF_HEADER = re.compile(r"^diff --git a/(\S+) b/(\S+)$")


def split_by_file(text):
    """{path: chunk} for one patch; each chunk is a complete per-file diff."""
    chunks, cur_path, cur = {}, None, []
    for line in text.splitlines(keepends=True):
        m = DIFF_HEADER.match(line.rstrip("\n"))
        if m:
            if cur_path:
                chunks[cur_path] = "".join(cur)
            cur_path, cur = m.group(2), [line]
        elif cur_path:
            cur.append(line)
    if cur_path:
        chunks[cur_path] = "".join(cur)
    return chunks


def chains(series):
    """{path: [chunk, ...]} in application order across the series."""
    out = {}
    for _, text in series:
        for path, chunk in split_by_file(text).items():
            out.setdefault(path, []).append(chunk)
    return out


def apply_chunk(content, path, chunk, reverse, dry_run=False):
    """Apply one per-file chunk to `content` (None = file absent).
    Returns the new content (None = file deleted) or raises ValueError."""
    creates = "\nnew file mode" in chunk or "\n--- /dev/null" in chunk
    deletes = "\ndeleted file mode" in chunk or "\n+++ /dev/null" in chunk
    if reverse:
        creates, deletes = deletes, creates
    has_hunks = "\n@@ " in chunk
    if not has_hunks:
        # Empty file added or removed (git writes no hunk for it).
        if creates:
            if content not in (None, ""):
                raise ValueError("expected no file")
            return ""
        if deletes:
            if content != "":
                raise ValueError("expected an empty file")
            return None
        return content  # mode change only
    with tempfile.TemporaryDirectory() as tmp:
        target = os.path.join(tmp, path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        if content is not None:
            with open(target, "w", newline="") as f:
                f.write(content)
        elif not creates:
            raise ValueError("file is missing")
        cmd = ["patch", "-p1", "-f", "-s", "--no-backup-if-mismatch",
               "-r", "-", "-d", tmp]
        if reverse:
            cmd.append("-R")
        if dry_run:
            cmd.append("--dry-run")
        r = subprocess.run(cmd, input=chunk, capture_output=True, text=True)
        if r.returncode != 0:
            raise ValueError((r.stdout + r.stderr).strip().splitlines()[-1:]
                             or ["patch failed"])
        if dry_run:
            return content
        if not os.path.exists(target):
            return None
        with open(target, newline="") as f:
            return f.read()


def read(src, path):
    p = os.path.join(src, path)
    if not os.path.lexists(p):
        return None
    with open(p, newline="") as f:
        return f.read()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("src")
    ap.add_argument("--from", dest="old", required=True)
    ap.add_argument("--to", dest="new", default="HEAD")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--clang-resource-dir")
    ap.add_argument("--accept", action="append", default=[])
    args = ap.parse_args()

    src = os.path.abspath(args.src)
    crd = args.clang_resource_dir
    if crd is None:
        try:
            crd = subprocess.run(["clang", "-print-resource-dir"], check=True,
                                 capture_output=True, text=True).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            sys.exit("clang not found; pass --clang-resource-dir")
    subst = {"@CLANG_RESOURCE_DIR@": crd}

    old_c = git("rev-parse", args.old).strip()
    new_c = git("rev-parse", args.new).strip()
    old_chains = chains(patch_series(old_c, subst))
    new_chains = chains(patch_series(new_c, subst))
    paths = sorted(p for p in set(old_chains) | set(new_chains)
                   if old_chains.get(p, []) != new_chains.get(p, []))
    print(f"Haiku patches {old_c[:7]} -> {new_c[:7]}: "
          f"{len(paths)} file(s) patched differently")

    updated, current, conflicts, accepted = [], [], [], []
    for path in paths:
        if path in args.accept:
            accepted.append(path)
            continue
        cur = read(src, path)
        try:
            base = cur
            for chunk in reversed(old_chains.get(path, [])):
                base = apply_chunk(base, path, chunk, reverse=True)
        except ValueError:
            # Not in the old patched state. Already in the new one (edited by
            # hand to match)? Then each new chunk reverses cleanly in order.
            try:
                probe = cur
                for chunk in reversed(new_chains.get(path, [])):
                    probe = apply_chunk(probe, path, chunk, reverse=True)
                current.append(path)
            except ValueError as e:
                conflicts.append((path, f"matches neither patch version ({e})"))
            continue
        try:
            new = base
            for chunk in new_chains.get(path, []):
                new = apply_chunk(new, path, chunk, reverse=False)
        except ValueError as e:
            conflicts.append((path, f"new patch does not apply ({e})"))
            continue
        if new == cur:
            current.append(path)
            continue
        updated.append(path)
        if args.dry_run:
            continue
        target = os.path.join(src, path)
        if new is None:
            os.remove(target)
        else:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            mode = os.stat(target).st_mode if os.path.exists(target) else None
            with open(target + ".update-tree", "w", newline="") as f:
                f.write(new)
            if mode is not None:
                os.chmod(target + ".update-tree", mode)
            os.replace(target + ".update-tree", target)

    verb = "would update" if args.dry_run else "updated"
    for p in updated:
        print(f"  {verb}  {p}")
    for p in current:
        print(f"  current  {p}")
    for p in accepted:
        print(f"  accepted {p} (left as it is, --accept)")
    for p, why in conflicts:
        print(f"  CONFLICT {p}: {why}")
    if not args.dry_run and not conflicts:
        with open(os.path.join(src, ".haiku-port-commit"), "w") as f:
            f.write(new_c + "\n")
        print(f"Recorded {new_c[:7]} in {src}/.haiku-port-commit")
    if conflicts:
        print("Resolve the conflicts by hand (or prepare a fresh tree); the "
              "recorded commit was not changed.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
