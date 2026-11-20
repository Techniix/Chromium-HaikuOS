#!/bin/bash
# Copyright 2026 The Chromium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Tests for the renga branch, run on a Renga system (Techniix/haiku ce/main;
# images from Techniix/renga-builds). Results go to renga-test-results/ with
# a header saying whether they came from a virtual machine or real hardware,
# so that QEMU results are never reported as hardware results.
#
# Usage:
#   scripts/renga-tests.sh probe          Renga interfaces, as Chromium calls them
#   scripts/renga-tests.sh quic OUT_DIR   HTTP/3 with and without --disable-quic
#   scripts/renga-tests.sh wayland OUT_DIR  open a window on Renga's compositor
#                                         and check which libwayland is loaded
#   scripts/renga-tests.sh v8 OUT_DIR     run Chromium, capture and symbolize
#                                         the next renderer crash
#   scripts/renga-tests.sh all OUT_DIR    probe, quic, wayland, then v8
#
# Environment:
#   QUIC_URL   page served over HTTP/3 (default https://cloudflare-quic.com/)
#   CRASH_URL  page that reproduces the V8 tab crash (optional; without it the
#              script opens a normal window and waits for you to reproduce it)

set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
RESULTS=${RESULTS:-$PWD/renga-test-results}
mkdir -p "$RESULTS"
STAMP=$(date +%Y%m%d-%H%M%S)

environment() {
  # A best-effort guess, written into every result file. Edit the file if it
  # is wrong; never present a VM run as a hardware run.
  local cpu vm=no
  cpu=$(sysinfo -cpu 2>/dev/null | grep -m1 -i 'cpu #0' || true)
  if sysinfo 2>/dev/null | grep -qiE 'qemu|kvm|virtualbox|vmware|hypervisor' ||
     listdev 2>/dev/null | grep -qiE 'virtio|qemu|red hat|1af4'; then
    vm=yes
  fi
  echo "# date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# system: $(uname -a)"
  echo "# renga: $(cat /boot/system/settings/renga-release 2>/dev/null ||
                   uname -v)"
  echo "# cpu: ${cpu:-unknown}"
  if [ $vm = yes ]; then
    echo "# environment: VIRTUAL MACHINE (QEMU/virtio devices detected)"
  else
    echo "# environment: real hardware (no hypervisor or virtio devices found)"
  fi
  echo "# chromium-haikuos: $(git -C "$HERE" rev-parse --short HEAD 2>/dev/null) ($(git -C "$HERE" rev-parse --abbrev-ref HEAD 2>/dev/null))"
}

find_tool() {
  local t
  for t in "$@"; do command -v "$t" >/dev/null && { command -v "$t"; return; }; done
  return 1
}

cmd_probe() {
  local out=$RESULTS/probe-$STAMP.txt bin=$RESULTS/renga-probe
  local cc
  cc=$(find_tool clang) || { echo "clang not found" >&2; return 1; }
  "$cc" -D_GNU_SOURCE -D_DEFAULT_SOURCE -O0 -g -fuse-ld=lld \
      -o "$bin" "$HERE/tools/renga-probe.c" -lgnu -lbsd -lnetwork || return 1
  { environment; echo; "$bin"; } 2>&1 | tee "$out"
  # R-3: can the frames backtrace_symbols_fd() printed be resolved?
  echo "---- symbolized with tools/symbolize-trace.py (--base image, default)" | tee -a "$out"
  sed -n '/^---- backtrace_symbols_fd/,/^----$/p' "$out" | sed '1d;$d' |
    python3 "$HERE/tools/symbolize-trace.py" --dir "$RESULTS" 2>&1 | tee -a "$out"
  echo "---- symbolized with --base text (images before 2026.11.14-chromium-wayland)" | tee -a "$out"
  sed -n '/^---- backtrace_symbols_fd/,/^----$/p' "$out" | sed '1d;$d' |
    python3 "$HERE/tools/symbolize-trace.py" --dir "$RESULTS" --base text 2>&1 |
    tee -a "$out"
  echo "Expected: frame 0 is static_frame, frame 1 exported_frame, then main."
  echo "Saved $out"
}

chrome_bin() {
  local out=${1:?OUT_DIR required}
  [ -x "$out/chrome" ] || { echo "$out/chrome not found" >&2; exit 1; }
  export LIBRARY_PATH="$(cd "$out" && pwd)${LIBRARY_PATH:+:$LIBRARY_PATH}"
  CHROME=$(cd "$out" && pwd)/chrome
}

# Loads QUIC_URL twice in one headless profile (the first response carries
# the Alt-Svc header that makes Chromium try HTTP/3 next time), with a NetLog,
# then once with QUIC forced on for that origin. Reports the protocol each
# request used.
cmd_quic() {
  chrome_bin "${1:-}"
  local url=${QUIC_URL:-https://cloudflare-quic.com/}
  local host=${url#https://}; host=${host%%/*}
  local out=$RESULTS/quic-$STAMP
  mkdir -p "$out"
  local common=(--headless=new --no-sandbox --no-zygote --disable-gpu
                --enable-logging=stderr --v=0 --password-store=basic)
  { environment; echo "# url: $url"; } > "$out/summary.txt"

  run() { # name profile extra-flags...
    local name=$1 profile=$2; shift 2
    timeout 120 "$CHROME" "${common[@]}" --user-data-dir="$out/profile-$profile" \
        --log-net-log="$out/$name.netlog.json" --net-log-capture-mode=Default \
        "$@" --dump-dom "$url" > "$out/$name.dom.html" 2> "$out/$name.stderr.txt"
    echo "$name: exit $?" >> "$out/summary.txt"
  }
  run altsvc-1 altsvc            # learns Alt-Svc: h3
  run altsvc-2 altsvc            # same profile: should use HTTP/3
  run forced forced --origin-to-force-quic-on="$host:443"
  run disabled disabled --disable-quic

  python3 - "$out" >> "$out/summary.txt" <<'PY'
import json, os, sys
out = sys.argv[1]
for name in ("altsvc-1", "altsvc-2", "forced", "disabled"):
    path = os.path.join(out, name + ".netlog.json")
    try:
        text = open(path).read()
        if not text.rstrip().endswith("}"):   # NetLog cut off by timeout
            text = text.rstrip().rstrip(",") + "]}"
        log = json.loads(text)
    except Exception as e:
        print(f"{name}: no usable NetLog ({e})")
        continue
    types = {v: k for k, v in log["constants"]["logEventTypes"].items()}
    seen = {}
    errors = []
    for ev in log.get("events", []):
        t = types.get(ev["type"], str(ev["type"]))
        seen[t] = seen.get(t, 0) + 1
        p = ev.get("params") or {}
        if t in ("QUIC_SESSION_CLOSED", "QUIC_SESSION_CONNECTION_CLOSE_FRAME_RECEIVED",
                 "QUIC_SESSION_PACKET_SENT_FAILED") or "net_error" in p and t.startswith("QUIC"):
            errors.append(f"{t} {json.dumps(p)[:300]}")
    protos = set()
    for ev in log.get("events", []):
        p = ev.get("params") or {}
        for k in ("negotiated_protocol", "alpn_protocol", "proto"):
            if k in p:
                protos.add(str(p[k]))
    quic = seen.get("QUIC_SESSION", 0)
    sent = seen.get("QUIC_SESSION_PACKET_SENT", 0)
    recv = seen.get("QUIC_SESSION_PACKET_RECEIVED", 0)
    # HTTP/3 responses: decoded response headers carrying a :status.
    h3 = 0
    for ev in log.get("events", []):
        if types.get(ev["type"]) == "HTTP3_HEADERS_DECODED":
            hdrs = (ev.get("params") or {}).get("headers", [])
            if any(str(h).startswith(":status") for h in hdrs):
                h3 += 1
    verified = seen.get("QUIC_SESSION_CERTIFICATE_VERIFIED", 0)
    print(f"{name}: HTTP/3 responses {h3}; QUIC sessions {quic} "
          f"({verified} handshakes verified), packets sent {sent}, "
          f"received {recv}; other protocols {sorted(protos) or '-'}")
    # Sessions still open when --dump-dom exits are closed with ERR_ABORTED
    # (-3) / QUIC_CONNECTION_CANCELLED (70); that is shutdown, not a failure.
    real = [e for e in errors if '"net_error": -3' not in e
            and '"quic_error": 70' not in e]
    for e in real[:10]:
        print(f"    {e}")
PY
  cat "$out/summary.txt"
  echo "Saved $out (the NetLogs open in https://netlog-viewer.appspot.com/)"
}

# Opens a browser window for 20 seconds through Renga's compositor and checks
# that the browser process loaded Renga's socket libwayland and not
# HaikuPorts' in-process one (the two must never share a process). Asks you
# to confirm the window has Renga's frame (xdg-decoration, no KDE protocol).
cmd_wayland() {
  chrome_bin "${1:-}"
  local out=$RESULTS/wayland-$STAMP
  mkdir -p "$out"
  environment > "$out/summary.txt"
  "$HERE/scripts/run-chromium.sh" "$(dirname "$CHROME")" \
      --enable-logging=stderr --v=0 --user-data-dir="$out/profile" \
      about:blank 2> "$out/chrome.stderr.txt" &
  local team=$!
  sleep 20
  listimage "$team" > "$out/images.txt" 2>&1
  kill "$team" 2>/dev/null; wait "$team" 2>/dev/null
  {
    echo "libwayland images in the browser process:"
    grep -i 'wayland' "$out/images.txt" | sed 's/^/  /' || echo "  (none)"
    if grep -q 'libwayland-client-renga' "$out/images.txt" &&
       ! grep -E 'libwayland-client\.so|wayland_server' "$out/images.txt" >/dev/null; then
      echo "PASS only Renga's socket libwayland is loaded"
    else
      echo "FAIL expected libwayland-client-renga.so.0 and no HaikuPorts libwayland"
    fi
    grep -iE 'wayland|decoration|Failed to' "$out/chrome.stderr.txt" | head -20 |
      sed 's/^/  stderr: /'
  } | tee -a "$out/summary.txt"
  echo "Did the window have Renga's own title tab and borders? Note it in"
  echo "$out/summary.txt. Saved $out"
}

# Starts Chromium with stderr captured, waits until a renderer crashes (or
# the browser exits), then symbolizes the trace.
cmd_v8() {
  chrome_bin "${1:-}"
  local out=$RESULTS/v8-crash-$STAMP
  mkdir -p "$out"
  environment > "$out/environment.txt"
  echo "Starting Chromium; reproduce the tab crash (\"Aw, Snap!\" / Check failed: success)."
  echo "Close Chromium afterwards. Log: $out/chrome.stderr.txt"
  "$HERE/scripts/run-chromium.sh" "$(dirname "$CHROME")" \
      --enable-logging=stderr --v=0 --user-data-dir="$out/profile" \
      ${CRASH_URL:+"$CRASH_URL"} 2> "$out/chrome.stderr.txt"
  python3 "$HERE/tools/symbolize-trace.py" --dir "$(dirname "$CHROME")" \
      "$out/chrome.stderr.txt" > "$out/chrome.symbolized.txt"
  if grep -n -A60 'Check failed\|Received signal\|Fatal error' \
       "$out/chrome.symbolized.txt" > "$out/crash.txt"; then
    echo "Crash found:"; head -80 "$out/crash.txt"
  else
    echo "No crash in the log. If the tab crashed without a trace, Haiku's"
    echo "debug server may have caught the signal first: save its report"
    echo "(Debugger > Save report) into $out."
  fi
  echo "Saved $out"
}

case "${1:-}" in
  probe) cmd_probe ;;
  quic)  cmd_quic "${2:-}" ;;
  wayland) cmd_wayland "${2:-}" ;;
  v8)    cmd_v8 "${2:-}" ;;
  all)   cmd_probe; cmd_quic "${2:-}"; cmd_wayland "${2:-}"; cmd_v8 "${2:-}" ;;
  *) sed -n '2,27p' "$0"; exit 2 ;;
esac
