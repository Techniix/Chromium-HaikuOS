#!/bin/bash
# Chromium-HaikuOS: capture every local change made to the working tree
# (passes 3-13, manual edits) so they can be turned into proper patches.
#
# 1. Unpacks a second, untouched copy of the Chromium tarball.
# 2. Runs scripts/prepare-tree.sh on it (FreeBSD patches, haikuify, Haiku
#    patches), so it matches what the build tree looked like before the fixes.
# 3. Compares it with the build tree (out/ and caches excluded) and writes
#    unified diffs plus lists of binary files and symlinks.
# 4. Adds `git diff` of the Chromium-HaikuOS repo itself.
# Result: ~/haiku-export.tar.gz  (upload that one file)
#
# Takes a while (unpack + compare); needs ~10 GB free. Touches nothing in
# the build tree.
set -euo pipefail

REPO=${REPO:-$HOME/Chromium-HaikuOS}
. "$REPO/scripts/version.sh"
WORK=$REPO/work
SRC=$WORK/chromium-$CHROMIUM_VERSION
PRISTINE_ROOT=${PRISTINE_ROOT:-$HOME/cr-pristine}
PRISTINE=$PRISTINE_ROOT/chromium-$CHROMIUM_VERSION
OUTDIR=$HOME/haiku-export
TARBALL=$WORK/chromium-$CHROMIUM_VERSION-lite.tar.xz

[ -d "$SRC" ] || { echo "no build tree at $SRC"; exit 1; }
[ -f "$TARBALL" ] || { echo "no tarball at $TARBALL"; exit 1; }

if [ ! -f "$PRISTINE/.haiku-prepared" ]; then
    if [ -d "$PRISTINE" ]; then
        echo "==> removing half-prepared $PRISTINE"
        rm -rf "$PRISTINE"
    fi
    mkdir -p "$PRISTINE_ROOT"
    echo "==> unpacking a clean copy (slow)"
    tar -xJf "$TARBALL" -C "$PRISTINE_ROOT"
    echo "==> preparing it the same way as the build tree"
    "$REPO/scripts/prepare-tree.sh" "$PRISTINE"
fi

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

echo "==> comparing trees (slow)"
set +e
LC_ALL=C diff -rq --no-dereference \
    -x out -x '__pycache__' -x '*.pyc' -x '*.rej' -x '.haiku-prepared' \
    -x 'haikuify-report.md' -x '.ninja_*' \
    "$PRISTINE" "$SRC" > "$OUTDIR/raw-list.txt" 2> "$OUTDIR/diff-errors.txt"
rc=$?
set -e
[ $rc -le 1 ] || echo "    (diff reported problems; see diff-errors.txt)"

python3 - "$PRISTINE" "$SRC" "$OUTDIR" <<'PY'
import os, subprocess, sys
a_root, b_root, out = sys.argv[1:]
lines = open(os.path.join(out, "raw-list.txt"), errors="replace").read().splitlines()

changed, only_a, only_b, links, other = [], [], [], [], []
def rel(p):
    for r in (a_root, b_root):
        if p == r or p.startswith(r + "/"):
            return os.path.relpath(p, r)
    return p
for l in lines:
    if l.startswith("Files ") and l.endswith(" differ"):
        a = l[6:-7].split(" and ")[0]
        changed.append(rel(a))
    elif l.startswith("Only in "):
        d, name = l[8:].split(": ", 1)
        p = os.path.join(d, name)
        (only_a if p.startswith(a_root) else only_b).append(rel(p))
    elif l.startswith("Symbolic links "):
        links.append(l)
    else:
        other.append(l)

def expand(root, paths):
    res = []
    for p in paths:
        full = os.path.join(root, p)
        if os.path.isdir(full) and not os.path.islink(full):
            for dp, dn, fn in os.walk(full):
                dn[:] = [d for d in dn if d != "__pycache__"]
                for f in fn:
                    res.append(os.path.relpath(os.path.join(dp, f), root))
        else:
            res.append(p)
    return res
new_files = expand(b_root, only_b)
gone_files = expand(a_root, only_a)

def is_text(path):
    try:
        with open(path, "rb") as f:
            chunk = f.read(8192)
        return b"\0" not in chunk
    except OSError:
        return False

LIMIT = 2 * 1024 * 1024
diff_out = open(os.path.join(out, "changes.diff"), "w")
binaries, symlinks = [], []
def udiff(rel_a, rel_b):
    pa = os.path.join(a_root, rel_a) if rel_a else "/dev/null"
    pb = os.path.join(b_root, rel_b) if rel_b else "/dev/null"
    r = subprocess.run(["diff", "-u", "--label", "a/" + (rel_a or rel_b),
                        "--label", "b/" + (rel_b or rel_a), pa, pb],
                       capture_output=True, text=True, errors="replace")
    diff_out.write(r.stdout)

for p in sorted(set(changed)):
    pa, pb = os.path.join(a_root, p), os.path.join(b_root, p)
    if is_text(pa) and is_text(pb) and os.path.getsize(pb) < LIMIT:
        udiff(p, p)
    else:
        binaries.append("CHANGED " + p)
for p in sorted(new_files):
    pb = os.path.join(b_root, p)
    if os.path.islink(pb):
        symlinks.append(f"NEW {p} -> {os.readlink(pb)}")
    elif is_text(pb) and os.path.getsize(pb) < LIMIT:
        udiff(None, p)
    else:
        binaries.append(f"NEW {p} ({os.path.getsize(pb)} bytes)")
for p in sorted(gone_files):
    binaries.append("REMOVED " + p)
diff_out.close()

with open(os.path.join(out, "binaries-and-removed.txt"), "w") as f:
    f.write("\n".join(binaries) + "\n")
with open(os.path.join(out, "symlinks.txt"), "w") as f:
    f.write("\n".join(symlinks + links) + "\n")
with open(os.path.join(out, "other.txt"), "w") as f:
    f.write("\n".join(other) + "\n")
print(f"    {len(set(changed))} changed, {len(new_files)} new, "
      f"{len(gone_files)} removed, {len(symlinks) + len(links)} symlink entries")
PY

echo "==> repo state"
git -C "$REPO" log --oneline -3 > "$OUTDIR/repo-log.txt" 2>&1 || true
git -C "$REPO" status --short > "$OUTDIR/repo-status.txt" 2>&1 || true
git -C "$REPO" diff > "$OUTDIR/repo.diff" 2>&1 || true
cp "$SRC/out/Release/args.gn" "$OUTDIR/args.gn" 2>/dev/null || true
for f in $(git -C "$REPO" ls-files --others --exclude-standard 2>/dev/null | grep -v '^work/'); do
    mkdir -p "$OUTDIR/repo-untracked/$(dirname "$f")"
    cp "$REPO/$f" "$OUTDIR/repo-untracked/$f" 2>/dev/null || true
done

echo "==> environment"
{
    uname -a
    clang --version 2>&1 | head -1
    rustc --version 2>&1
    node --version 2>&1
    python3 --version 2>&1
    pkgman search -i -D 2>/dev/null | grep -iE 'wayland|libclang|llvm|nodejs|haiku_devel|^ *haiku ' || true
} > "$OUTDIR/environment.txt" 2>&1

tar -czf "$HOME/haiku-export.tar.gz" -C "$HOME" haiku-export
echo
echo "Done: $HOME/haiku-export.tar.gz ($(du -h "$HOME/haiku-export.tar.gz" | cut -f1))"
echo "Upload that file. ~/cr-pristine can be deleted afterwards."
