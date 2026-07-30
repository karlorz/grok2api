#!/usr/bin/env bash
# Operator entry: upgrade binary deploy on HOST (default kr01) from this fork.
#
# Intended use (from a machine with SSH to kr01 + Go/pnpm toolchains):
#
#   # In an existing checkout:
#   ./scripts/upgrade-kr01.sh
#   make upgrade-kr01
#
#   # One-liner without prior clone (clones to a temp dir, builds, deploys):
#   curl -fsSL https://raw.githubusercontent.com/karlorz/grok2api/main/scripts/upgrade-kr01.sh | bash
#
# Env:
#   HOST          default kr01
#   REPO_URL      default https://github.com/karlorz/grok2api.git
#   GIT_BRANCH    default main
#   FORCE=1       rebuild/redeploy even if deployed SHA matches
#   SKIP_BUILD=1  reuse ./dist (only when already in a prepared checkout)
#   DRY_RUN=1     print steps only
set -euo pipefail

HOST="${HOST:-kr01}"
REPO_URL="${REPO_URL:-https://github.com/karlorz/grok2api.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"
FORCE="${FORCE:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
DRY_RUN="${DRY_RUN:-0}"
CLEANUP_CLONE=0
WORKDIR=""

log() { printf '%s\n' "$*"; }

die() {
  echo "ERROR: $*" >&2
  exit 1
}

is_repo_root() {
  local d="${1:-.}"
  [[ -f "${d}/Makefile" && -f "${d}/scripts/update.sh" && -f "${d}/VERSION" ]]
}

# When piped from curl, BASH_SOURCE is the temp script path, not a checkout.
resolve_workdir() {
  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # Prefer: already inside a checkout (cwd)
  if is_repo_root "."; then
    WORKDIR="$(pwd)"
    return
  fi
  # Prefer: script lives in scripts/ of a checkout
  if is_repo_root "${self_dir}/.."; then
    WORKDIR="$(cd "${self_dir}/.." && pwd)"
    return
  fi
  # Else clone fresh
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/grok2api-upgrade.XXXXXX")"
  CLEANUP_CLONE=1
  log "Cloning ${REPO_URL} (${GIT_BRANCH}) into ${WORKDIR}..."
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN: would git clone --branch ${GIT_BRANCH} --depth 1 ${REPO_URL} ${WORKDIR}"
    return
  fi
  git clone --branch "$GIT_BRANCH" --depth 50 "$REPO_URL" "$WORKDIR"
}

cleanup() {
  if [[ "$CLEANUP_CLONE" == "1" && -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

log "==== upgrade-kr01: HOST=${HOST} branch=${GIT_BRANCH} ===="
resolve_workdir
log "workdir: ${WORKDIR}"

if [[ "$DRY_RUN" == "1" ]]; then
  log "DRY_RUN steps:"
  log "  1. cd ${WORKDIR}"
  log "  2. git fetch origin && git checkout ${GIT_BRANCH} && git pull --ff-only"
  log "  3. HOST=${HOST} FORCE=${FORCE} SKIP_BUILD=${SKIP_BUILD} ./scripts/update.sh"
  log "  4. HOST=${HOST} ./scripts/status.sh"
  exit 0
fi

cd "$WORKDIR"

if [[ "$CLEANUP_CLONE" != "1" ]]; then
  # Existing checkout: fast-forward when clean and behind.
  if [[ -n "$(git status --porcelain=v1 2>/dev/null)" ]]; then
    die "dirty worktree in ${WORKDIR}; commit/stash or run from a clean clone"
  fi
  git fetch --prune origin
  git checkout "$GIT_BRANCH"
  if git rev-parse --verify --quiet "refs/remotes/origin/${GIT_BRANCH}" >/dev/null; then
    git pull --ff-only origin "$GIT_BRANCH"
  fi
fi

log "VERSION=$(tr -d '[:space:]' < VERSION 2>/dev/null || echo unknown)"
log "HEAD=$(git rev-parse HEAD)"

export HOST
export FORCE
export SKIP_BUILD
# update.sh already defaults HOST=kr01 via common.sh
./scripts/update.sh

log "==== Post-upgrade status ===="
./scripts/status.sh

log "==== upgrade-kr01 complete on ${HOST} ===="
