#!/bin/bash
# Chromium-HaikuOS: undo a "rebuild everything" caused only by Haiku's own
# system headers getting a newer timestamp (e.g. a pkgman update of
# haiku_devel). Outputs that are out of date *only* because of /boot/system
# headers (directly, or through other outputs that were out of date for that
# reason) are marked current again. Real changes - edited source files,
# changed flags/args, missing outputs - still rebuild.
#
# Usage: bash haiku-skip-sysheader-rebuild.sh [SINCE]
#   SINCE: source files changed after this time are re-marked as changed at
#          the end so their dependents still rebuild (default: today 12:50,
#          before build8 started; covers pass 9's edits).
set -euo pipefail

SRC=${SRC:-$HOME/Chromium-HaikuOS/work/chromium-156.0.8078.79}
OUT=${OUT:-out/Release}
TARGET=${TARGET:-chrome}
SYSPREFIX=${SYSPREFIX:-/boot/system/}
SINCE=${1:-"$(date +%Y-%m-%d) 12:50"}
cd "$SRC"
export SYSPREFIX

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/touched"

count_steps() { ninja -C "$OUT" -n "$TARGET" 2>/dev/null | grep -c '^\[' || true; }

# Helper: pick outputs whose newest input is a system header or an output we
# already marked current.
cat > "$WORK/pick.py" <<'EOF'
import os, sys
older, touched_p, batch_p = sys.argv[1:4]
sysp = os.environ["SYSPREFIX"]
touched = set(l.rstrip("\n") for l in open(touched_p))
batch = set()
for line in open(older):
    out, inp = line.rstrip("\n").split("\t", 1)
    if out not in touched and (inp.startswith(sysp) or inp in touched):
        batch.add(out)
with open(batch_p, "w") as f:
    for o in sorted(batch):
        f.write(o + "\n")
EOF

# Helper: rewrite the recorded output mtimes in .ninja_deps (format v4) for
# the outputs we marked, so ninja doesn't call their dependency info stale.
cat > "$WORK/fixdeps.py" <<'EOF'
import os, struct, sys
out_dir, touched_p = sys.argv[1], sys.argv[2]
touched = set(l.rstrip("\n") for l in open(touched_p) if l.strip())
p = os.path.join(out_dir, ".ninja_deps")
data = bytearray(open(p, "rb").read())
if not data.startswith(b"# ninjadeps\n"):
    sys.exit("unexpected .ninja_deps header")
(version,) = struct.unpack_from("<i", data, 12)
if version != 4:
    sys.exit("unsupported .ninja_deps version %d (need 4)" % version)
pos, ids, fixed = 16, [], 0
while pos + 4 <= len(data):
    (size,) = struct.unpack_from("<I", data, pos); pos += 4
    is_deps, size = bool(size & 0x80000000), size & 0x7FFFFFFF
    if pos + size > len(data):
        break  # truncated tail; ninja ignores it too
    if is_deps:
        (out_id,) = struct.unpack_from("<i", data, pos)
        if 0 <= out_id < len(ids) and ids[out_id] in touched:
            try:
                mt = os.stat(os.path.join(out_dir, ids[out_id])).st_mtime_ns
                struct.pack_into("<Q", data, pos + 4, mt)
                fixed += 1
            except FileNotFoundError:
                pass
    else:
        ids.append(bytes(data[pos:pos + size - 4]).rstrip(b"\0").decode("utf-8", "surrogateescape"))
    pos += size
if not os.path.exists(p + ".orig"):
    open(p + ".orig", "wb").write(open(p, "rb").read())
open(p, "wb").write(data)
print("    updated %d dependency records" % fixed)
EOF

echo "==> before: $(count_steps) steps"

# 1. Remember which real source files changed recently (pass 9 etc.).
find . -path "./$OUT" -prune -o -path ./.git -prune -o -type f -newermt "$SINCE" -print > "$WORK/changed_src"
echo "==> $(wc -l < "$WORK/changed_src") source files changed since $SINCE (kept as changed)"

# 2. Mark outputs current, round by round, following the dependency chain.
for round in $(seq 1 60); do
  ninja -C "$OUT" -n -d explain "$TARGET" 2>&1 \
    | sed -n 's/^ninja explain: output \(.*\) older than most recent input \(.*\) ([0-9]* vs [0-9]*)$/\1\t\2/p' \
    > "$WORK/older"
  python3 "$WORK/pick.py" "$WORK/older" "$WORK/touched" "$WORK/batch"
  n=$(grep -c . "$WORK/batch" || true)
  echo "    round $round: marking $n outputs current"
  [ "$n" -eq 0 ] && break
  (cd "$OUT" && xargs -d '\n' touch -c < "$WORK/batch")
  cat "$WORK/batch" >> "$WORK/touched"
  # Keep ninja's own records in step so the next round sees the new state.
  ninja -C "$OUT" -t restat >/dev/null
  python3 "$WORK/fixdeps.py" "$OUT" "$WORK/touched" >/dev/null
done

# 3. Re-mark recently edited sources as newest, so their dependents rebuild.
xargs -d '\n' touch -c < "$WORK/changed_src"

echo "==> after: $(count_steps) steps"
echo "==> Now run:"
echo "  ninja -C $OUT -k 0 $TARGET 2>&1 | tee ~/build9.log"
