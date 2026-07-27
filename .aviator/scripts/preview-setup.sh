#!/bin/bash
set -euo pipefail

LOG="/tmp/preview-timing.log"
START=$(date +%s)

t() {
  local now
  now=$(date +%s)
  echo "[$((now - START))s] $1" | tee -a "$LOG"
}

t "Starting microbin preview setup"

# e2b runs the script as root. Make git operations trust /code.
git config --global --add safe.directory /code
cd /code

# e2b forces its own PATH and it does NOT contain the rust image's
# /usr/local/cargo/bin, so a bare `cargo` here is `exit status 127`. Other env
# vars from the base image (CARGO_HOME, RUSTUP_HOME) do come through — PATH is
# the special case, and an `ENV PATH=...` in the Dockerfile does not override
# it. Fix it here, and still call cargo by absolute path.
export PATH=/usr/local/cargo/bin:$PATH
CARGO=/usr/local/cargo/bin/cargo
BIN=/code/target/debug/microbin
APP_LOG=/var/log/app/microbin.log

# The image baked /code/target (1.8 GB of compiled deps). The preview launch
# uses a git fetch fast-path and cleans the tree with `git clean -fd` — no -x,
# so gitignored paths survive, which is why target/ and microbin_data/ are
# still here. /preview-image-sha records the commit that cache was built from;
# it lives outside /code so the clean can't delete it.
#
# Unlike other stacks we do NOT gate the build on a path diff against that SHA.
# Cargo has real incrementality: a no-op build against a warm target/ is ~1s
# and it recompiles exactly what changed. Let cargo decide.
if [ -f /preview-image-sha ]; then
  t "  build cache baked at $(cut -c1-12 < /preview-image-sha), branch head is $(git rev-parse --short HEAD)"
fi

# Defensive: normally nothing is running when we get here. On the e2b path
# Aviator either reconnects to an unchanged preview and skips this script
# entirely (preview.py: `if sandbox.reconnected: ... return`), or — when the
# branch head has moved — kills the old preview sandbox and cold boots a fresh
# one. So neither case leaves a live microbin behind.
#
# Keep the kill anyway: it costs nothing, and it makes re-running this script by
# hand (or on a backend that does reuse a live box) safe. If an old instance did
# survive, it would have to die BEFORE the build, not just before the start —
# the linker writes straight to $BIN and Linux returns ETXTBSY ("Text file
# busy") when writing a currently-executing file. It would also let the poll
# below pass against the OLD binary and report a stale preview as ready.
if pgrep -f "$BIN" >/dev/null 2>&1; then
  t "Stopping previous microbin instance..."
  pkill -f "$BIN" || true
  for _ in $(seq 1 10); do
    pgrep -f "$BIN" >/dev/null 2>&1 || break
    sleep 1
  done
  pkill -9 -f "$BIN" 2>/dev/null || true
fi

# Pastes and uploaded files land here. microbin_data/* is gitignored, so
# anything a previous run wrote survives the launch clean.
mkdir -p /code/microbin_data

# askama templates and rust-embed static assets are compiled INTO the binary,
# so a templates/ or static-asset edit needs a genuine rebuild — there is no
# "just reload the page" path on this stack. askama_derive emits include_bytes!
# for each template, so cargo's own change detection does catch those edits.
t "Building microbin (debug)..."
if "$CARGO" build 2>&1 | tee /tmp/cargo-build.log; then
  t "Build OK"
elif [ -x "$BIN" ]; then
  # Degrade rather than abort: a preview of the wrong code still beats no
  # preview, but say so loudly — the run is no longer testing this branch.
  t "  WARN: cargo build FAILED — falling back to the binary baked into the image"
  t "  WARN: this preview does NOT reflect the code changes on this branch"
  tail -40 /tmp/cargo-build.log | tee -a "$LOG" || true
else
  t "ERROR: cargo build failed and there is no prebuilt binary to fall back to:"
  tail -60 /tmp/cargo-build.log | tee -a "$LOG" || true
  exit 1
fi

# PREVIEW_URL is injected by Aviator with the sandbox's public URL. microbin
# builds every paste link, short link, QR target and asset href from
# MICROBIN_PUBLIC_PATH, so without this the page hands the remote browser
# 127.0.0.1 URLs. The PublicUrl parser strips a trailing "/", so passing
# PREVIEW_URL through raw is safe.
export MICROBIN_PUBLIC_PATH="${PREVIEW_URL:-http://127.0.0.1:8080}"
export MICROBIN_PORT=8080
# Listen on all interfaces — the browser driving this preview runs on an
# Aviator worker, not inside the sandbox. 0.0.0.0 is already microbin's
# default; pinned here so a config change upstream can't quietly make it
# loopback-only and break every preview at once.
export MICROBIN_BIND=0.0.0.0
# Must be absolute: microbin resolves --data-dir relative to cwd otherwise.
export MICROBIN_DATA_DIR=/code/microbin_data
# Both of these call out to api.microbin.eu with a reqwest client built with no
# request timeout. Telemetry is a detached background thread (pointless from a
# throwaway sandbox); the update check is awaited INLINE in the GET /admin
# handler, so if sandbox egress is blackholed the admin page hangs until the
# TCP connect gives up. Off for previews.
export MICROBIN_DISABLE_TELEMETRY=true
export MICROBIN_DISABLE_UPDATE_CHECKING=true

t "Starting microbin on 0.0.0.0:8080..."
mkdir -p /var/log/app
setsid "$BIN" < /dev/null > "$APP_LOG" 2>&1 &
disown

# Don't report ready until the port actually accepts connections.
t "Waiting for microbin on port 8080..."
for i in $(seq 1 30); do
  if curl -sf -o /dev/null http://127.0.0.1:8080/; then
    t "microbin is up on port 8080 (public URL: $MICROBIN_PUBLIC_PATH)"
    break
  fi
  # Fail fast on a crash-on-boot instead of burning the full 30s.
  if ! pgrep -f "$BIN" >/dev/null 2>&1; then
    t "ERROR: microbin exited during startup — last log lines:"
    tail -40 "$APP_LOG" | tee -a "$LOG" || true
    exit 1
  fi
  if [ "$i" -eq 30 ]; then
    t "ERROR: microbin did not come up on port 8080 — last log lines:"
    tail -40 "$APP_LOG" | tee -a "$LOG" || true
    exit 1
  fi
  sleep 1
done

t "Preview environment ready."
