#!/bin/bash
# Chromium-HaikuOS: fast backup of everything needed to rebuild the progress
# after a fresh Haiku install (a few minutes instead of the full export).
#
# Instead of comparing against a clean copy of the tree, it collects every
# file in the build tree that changed AFTER prepare-tree.sh finished (the
# .haiku-prepared marker): that is all of passes 3-16 plus manual edits.
# The original versions are reconstructed later from the tarball + repo.
#
# Result: ~/haiku-quicksave.tar.gz  (upload it, and copy it off this machine)
set -uo pipefail

REPO=${REPO:-$HOME/Chromium-HaikuOS}
SRC=$REPO/work/chromium-156.0.8078.79
OUT=$HOME/haiku-quicksave
rm -rf "$OUT"; mkdir -p "$OUT"

MARK="$SRC/.haiku-prepared"
if [ ! -e "$MARK" ]; then
    echo "WARN: no .haiku-prepared marker; using haikuify-report.md instead"
    MARK="$SRC/haikuify-report.md"
fi
ls -l --full-time "$MARK" > "$OUT/marker.txt" 2>&1

echo "==> finding files changed since prepare-tree (a few minutes)"
cd "$SRC"
find . -path ./out -prune -o -name __pycache__ -prune -o \
     \( -type f -o -type l \) -newer "$MARK" ! -name '*.pyc' -print \
     | sed 's|^\./||' | sort > "$OUT/changed-files.txt"
echo "    $(wc -l < "$OUT/changed-files.txt") files"

# Keep the list but skip very large files (build products in the tree).
: > "$OUT/skipped-large.txt"
: > "$OUT/to-archive.txt"
while IFS= read -r f; do
    if [ -f "$f" ] && [ ! -L "$f" ] && [ "$(stat -c %s "$f")" -gt 5000000 ]; then
        echo "$f" >> "$OUT/skipped-large.txt"
    else
        echo "$f" >> "$OUT/to-archive.txt"
    fi
done < "$OUT/changed-files.txt"
tar -cf "$OUT/changed-files.tar" -T "$OUT/to-archive.txt" 2>"$OUT/tar-errors.txt"

echo "==> build settings, repo and environment"
cp out/Release/args.gn "$OUT/" 2>/dev/null
git -C "$REPO" log --oneline -3 > "$OUT/repo-log.txt" 2>&1
git -C "$REPO" status --short > "$OUT/repo-status.txt" 2>&1
git -C "$REPO" diff > "$OUT/repo.diff" 2>&1
git -C "$REPO" ls-files --others --exclude-standard 2>/dev/null | grep -v '^work/' \
    | tar -cf "$OUT/repo-untracked.tar" -C "$REPO" -T - 2>/dev/null
cp -r "$HOME/config/non-packaged/lib/pkgconfig" "$OUT/pkgconfig" 2>/dev/null
cp "$HOME/config/settings/fontconfig/fonts.conf" "$OUT/" 2>/dev/null
cp "$HOME"/haiku-fixes-pass*.sh "$HOME"/*.log "$OUT/" 2>/dev/null
pkgman search -i > "$OUT/installed-packages.txt" 2>&1
{
    uname -a; clang --version 2>&1 | head -1; rustc --version 2>&1
    node --version 2>&1; python3 --version 2>&1; go version 2>&1
    python3 -c 'import clang.cindex, sys; print("clang bindings:", clang.cindex.__file__)' 2>&1
    ls -l /boot/system/lib/libclang* 2>&1
} > "$OUT/environment.txt"

tar -czf "$HOME/haiku-quicksave.tar.gz" -C "$HOME" haiku-quicksave
echo
echo "Done: $HOME/haiku-quicksave.tar.gz ($(du -h "$HOME/haiku-quicksave.tar.gz" | cut -f1))"
echo "Upload it here and copy it off this machine before reinstalling."
