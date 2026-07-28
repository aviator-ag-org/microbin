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
# RUSTUP_HOME and CARGO_HOME are set by the rust base image's own config, and
# e2b does NOT carry that into the sandbox at run time. /usr/local/cargo/bin/cargo
# is a rustup SHIM, so without RUSTUP_HOME it looks in ~/.rustup, finds no
# toolchain, and fails with:
#   "rustup could not choose a version of cargo to run, because one wasn't
#    specified explicitly, and no default is configured"
# That is a silent-wrong-answer bug, not just a slow one: the build fails, the
# script falls back to the binary baked into the image, and the verifier ends up
# testing master instead of the branch. Set them explicitly.
export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo
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
  # Fail fast on a crash-on-boot instead of burning the full 30s — but not
  # before the process has had a chance to exist. `setsid "$BIN" &` forks a
  # subshell that then execs setsid which execs the binary, and until that
  # chain completes pgrep matches nothing. Checking on the first iteration is a
  # race: it passes on a warm machine (where curl succeeds immediately and this
  # branch never runs) and reports a perfectly healthy app as "exited during
  # startup" on a cold sandbox. Give it a few seconds of grace first.
  if [ "$i" -ge 4 ] && ! pgrep -f "$BIN" >/dev/null 2>&1; then
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

# --- Seed a few pastes -------------------------------------------------------
#
# A fresh sandbox starts with an empty database, which is enough to exercise the
# create flow but leaves nothing to look at for a change that touches the list
# view, the paste view, or syntax highlighting. So put a small, predictable
# fixture in place.
#
# Seeded over HTTP rather than by baking a database file into the image on
# purpose: a baked file would need a COPY instruction, and COPY is rejected by
# the Dockerfile parser behind Aviator's "Add Custom Template" screen (there is
# no build context there). Seeding here keeps the image buildable by paste.
#
# expiration=1week is the longest the app accepts under its default
# MICROBIN_MAX_EXPIRY (is_valid_expiration rejects anything further out), and it
# outlives a preview sandbox many times over. Deliberately NOT raising
# MICROBIN_MAX_EXPIRY to allow "never" — the verifier should see the app
# configured the way it actually ships.
SEED_MARKER="/code/microbin_data/.preview-seeded"

seed_paste() {
  # $1 = content, $2 = syntax_highlight, $3 = privacy
  curl -sf -o /dev/null -X POST \
    -F "content=$1" \
    -F "syntax_highlight=$2" \
    -F "privacy=$3" \
    -F "expiration=1week" \
    -F "burn_after=0" \
    -F "file=@/dev/null;filename=" \
    "http://127.0.0.1:8080/upload"
}

if [ -f "$SEED_MARKER" ]; then
  t "Seed data already present — skipping"
else
  t "Seeding example pastes..."
  seeded=0

  seed_paste \
"Welcome to the MicroBin preview.

This paste was created automatically when the preview environment started, so
there is something to look at without having to create one first." \
    "none" "public" && seeded=$((seeded + 1)) || true

  seed_paste \
'fn main() {
    let pastes = vec!["alpha", "beta", "gamma"];
    for (i, p) in pastes.iter().enumerate() {
        println!("{i}: {p}");
    }
}' \
    "rs" "public" && seeded=$((seeded + 1)) || true

  seed_paste \
"This one is unlisted, so it should not appear on /list even though it is
reachable by its own URL." \
    "none" "unlisted" && seeded=$((seeded + 1)) || true

  if [ "$seeded" -gt 0 ]; then
    touch "$SEED_MARKER"
    t "  seeded $seeded paste(s)"
  fi
  # A failed seed is not fatal: the app is up and the create flow still works,
  # so a scenario can make its own data. Say so rather than failing the preview.
  if [ "$seeded" -lt 3 ]; then
    t "  WARN: only $seeded of 3 seed pastes were created"
  fi
fi

t "Preview environment ready."
