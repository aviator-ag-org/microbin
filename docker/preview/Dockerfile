# microbin preview image for Aviator Verify (e2b sandboxes).
#
# What this image is for: a pre-warmed machine so a preview boots in seconds
# instead of spending minutes compiling Rust from scratch on every run.
#
# How Aviator uses it at launch:
#   1. boots a sandbox from this image
#   2. finds the repo already in /code, does `git fetch` + checks out the
#      runbook branch (fast path — no fresh clone)
#   3. cleans the tree with `git reset --hard` + `git clean -fd`
#      NOTE: no -x, so GITIGNORED files SURVIVE. That is why baking target/
#      works: it's in .gitignore, so the cleanup leaves it alone.
#   4. runs .aviator/scripts/preview-setup.sh, which rebuilds only what changed
#
# Nothing here runs the app. There is deliberately no CMD/ENTRYPOINT — the
# setup script starts microbin, not Docker.

FROM rust:1-bookworm

ARG DEBIAN_FRONTEND=noninteractive

# e2b's template builder forces its own PATH for RUN steps:
#   /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# The rust base image puts cargo in /usr/local/cargo/bin, which is NOT in that
# list — so a bare `cargo build` dies with `exit status 127` on e2b even though
# it works under plain `docker build`. An `ENV PATH=...` here does NOT fix it;
# e2b overrides PATH regardless (other ENV vars, and the base image's CARGO_HOME
# and RUSTUP_HOME, do come through — PATH is the special case).
#
# So: always invoke Rust tooling by absolute path in this file. Verified against
# e2b's builder — `/usr/local/cargo/bin/cargo --version` returns 1.97.1 there.

# System packages.
#   git/git-lfs     — Aviator checks out the runbook branch here
#   build-essential,
#   perl, pkg-config — required to compile the vendored OpenSSL and bundled
#                      SQLite that microbin's default features pull in
#   nodejs/npm       — NOT for microbin. Aviator appends
#                      `npm install -g @anthropic-ai/claude-code` when it builds
#                      a Dockerfile-sourced template, and the rust base image
#                      ships no Node, so that step would fail without this.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git git-lfs ca-certificates curl \
        build-essential perl pkg-config \
        nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# --- Bake the repo + a warm Rust build cache into /code -----------------------
#
# Clone the fork Aviator is connected to, so /code's origin matches at runtime
# and the launch takes the git-fetch fast path.
#
# --filter=blob:none, NOT --depth 1 / --single-branch: a shallow single-branch
# clone only tracks master, so `git fetch origin <runbook-branch>` would never
# create origin/<branch> and the checkout fails with "invalid reference".
RUN git clone --filter=blob:none \
        https://github.com/aviator-ag-org/microbin.git /code
WORKDIR /code

# Compile once, here, so the preview doesn't have to.
#
# Debug, not --release: the release profile sets `lto = true`, which makes every
# incremental rebuild crawl. A preview only needs the app to run, not to run
# fast — and debug relinks in seconds where LTO takes minutes.
#
# This populates two caches:
#   /code/target        — gitignored, so it survives the launch cleanup
#   /usr/local/cargo    — outside /code, so git never touches it at all
RUN /usr/local/cargo/bin/cargo build

# Data directory the app writes pastes into (microbin_data/* is gitignored).
RUN mkdir -p /code/microbin_data

# Record the commit this image was built from, OUTSIDE /code — a file inside
# /code would be deleted by the launch's `git clean -fd`. preview-setup.sh diffs
# the runbook branch against this to decide whether a rebuild is needed at all.
RUN git -C /code rev-parse HEAD > /preview-image-sha
