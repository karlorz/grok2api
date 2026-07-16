#!/usr/bin/env bash
# Fetch GitHub, compare SHAs (local / remote / deployed), pull if behind,
# rebuild from source, and roll out binary + frontend to kr01.
#
# Env:
#   PULL=1              fetch + fast-forward when behind (default)
#   FORCE=0             rebuild even if deployed SHA matches HEAD
#   SKIP_BUILD=0        reuse ./dist; also skips fetch/pull when 1
#   SYNC_UPSTREAM=0     also fetch + merge upstream/$GIT_BRANCH
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
cd "$ROOT_DIR"

PULL="${PULL:-1}"
FORCE="${FORCE:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SYNC_UPSTREAM="${SYNC_UPSTREAM:-0}"

resolve_git_branch

echo "==== Step 0: Git fetch / compare ===="
LOCAL_SHA="$(git rev-parse HEAD)"
LOCAL_SHORT="$(git rev-parse --short HEAD)"
LOCAL_DIRTY=0
if worktree_is_dirty; then
  LOCAL_DIRTY=1
fi

if [[ "$SKIP_BUILD" != "1" ]]; then
  echo "Fetching ${GIT_REMOTE}..."
  git fetch --prune "$GIT_REMOTE"

  if [[ "$SYNC_UPSTREAM" == "1" ]]; then
    if git remote get-url upstream >/dev/null 2>&1; then
      echo "Fetching upstream..."
      git fetch --prune upstream
    else
      echo "WARN: SYNC_UPSTREAM=1 but no 'upstream' remote configured" >&2
    fi
  fi
fi

REMOTE_SHA="$(remote_sha_of "$GIT_REMOTE" "$GIT_BRANCH")"
DEPLOYED_SHA="$(deployed_sha_on_host)"

DIRTY_NOTE=""
[[ "$LOCAL_DIRTY" == "1" ]] && DIRTY_NOTE=" dirty worktree"

echo "  branch:          ${GIT_BRANCH}"
echo "  local  HEAD:     ${LOCAL_SHA} (${LOCAL_SHORT})${DIRTY_NOTE}"
if [[ -n "$REMOTE_SHA" ]]; then
  echo "  ${GIT_REMOTE}/${GIT_BRANCH}: ${REMOTE_SHA} ($(git rev-parse --short "$REMOTE_SHA"))"
else
  echo "  ${GIT_REMOTE}/${GIT_BRANCH}: (not found after fetch)"
fi
if [[ -n "$DEPLOYED_SHA" ]]; then
  echo "  deployed@${HOST}: ${DEPLOYED_SHA} ($(git rev-parse --short "$DEPLOYED_SHA" 2>/dev/null || echo unknown))"
else
  echo "  deployed@${HOST}: (no ${DEPLOY_META_FILE} yet)"
fi
describe_local_vs_remote "$LOCAL_SHA" "$REMOTE_SHA"

if [[ "$SKIP_BUILD" != "1" && "$PULL" == "1" && -n "$REMOTE_SHA" ]]; then
  if [[ "$LOCAL_SHA" != "$REMOTE_SHA" ]]; then
    if git merge-base --is-ancestor "$LOCAL_SHA" "$REMOTE_SHA"; then
      echo "Local is behind ${GIT_REMOTE}/${GIT_BRANCH}; fast-forward pull..."
      require_clean_worktree "commit/stash before pull, or PULL=0"
      git pull --ff-only "$GIT_REMOTE" "$GIT_BRANCH"
      LOCAL_SHA="$(git rev-parse HEAD)"
      LOCAL_SHORT="$(git rev-parse --short HEAD)"
      echo "  updated local HEAD: ${LOCAL_SHA} (${LOCAL_SHORT})"
    elif git merge-base --is-ancestor "$REMOTE_SHA" "$LOCAL_SHA"; then
      echo "Local is ahead of ${GIT_REMOTE}/${GIT_BRANCH}; will build local HEAD (push when ready)."
    else
      echo "ERROR: local and ${GIT_REMOTE}/${GIT_BRANCH} have diverged." >&2
      echo "  Resolve with merge/rebase, or set PULL=0 to build current HEAD only." >&2
      git log --oneline --left-right "HEAD...${GIT_REMOTE}/${GIT_BRANCH}" | head -20 >&2 || true
      exit 1
    fi
  else
    echo "Local already matches ${GIT_REMOTE}/${GIT_BRANCH}."
  fi
fi

if [[ "$SKIP_BUILD" != "1" && "$SYNC_UPSTREAM" == "1" ]] && git remote get-url upstream >/dev/null 2>&1; then
  UPSTREAM_SHA="$(remote_sha_of upstream "$GIT_BRANCH")"
  if [[ -n "$UPSTREAM_SHA" && "$LOCAL_SHA" != "$UPSTREAM_SHA" ]]; then
    if git merge-base --is-ancestor "$UPSTREAM_SHA" "$LOCAL_SHA"; then
      echo "Local already contains upstream/${GIT_BRANCH}."
    else
      echo "Merging upstream/${GIT_BRANCH} into local..."
      require_clean_worktree "commit/stash before upstream merge"
      git merge --no-edit "upstream/${GIT_BRANCH}"
      LOCAL_SHA="$(git rev-parse HEAD)"
      LOCAL_SHORT="$(git rev-parse --short HEAD)"
      echo "  after merge HEAD: ${LOCAL_SHA} (${LOCAL_SHORT})"
    fi
  fi
fi

if [[ "$FORCE" != "1" && -n "$DEPLOYED_SHA" && "$DEPLOYED_SHA" == "$LOCAL_SHA" && "$LOCAL_DIRTY" == "0" ]]; then
  echo "==== Already up to date ===="
  echo "Deployed SHA on ${HOST} matches local HEAD (${LOCAL_SHORT})."
  echo "Nothing to rebuild. Use FORCE=1 to rebuild/redeploy anyway."
  ssh "$HOST" "curl -fsS '${HEALTH_URL}' && echo" || true
  exit 0
fi

if [[ "$SKIP_BUILD" != "1" ]]; then
  echo "==== Step 1: Building ARM64 from source @ ${LOCAL_SHORT} ===="
  make build-arm64
else
  echo "==== Step 1: Skipping build (SKIP_BUILD=1) ===="
  [[ -x ./dist/grok2api ]] || { echo "missing ./dist/grok2api" >&2; exit 1; }
  [[ -d ./dist/frontend/dist ]] || { echo "missing ./dist/frontend/dist" >&2; exit 1; }
  [[ -f ./dist/config.example.yaml ]] || { echo "missing ./dist/config.example.yaml" >&2; exit 1; }
fi

echo "==== Step 2: Stopping service on ${HOST} ===="
ssh "$HOST" "systemctl stop '${SERVICE_NAME}' || true"

echo "==== Step 3: Uploading binary and frontend ===="
upload_release_bundle
write_deploy_meta "$LOCAL_SHA"

echo "==== Step 4: Refreshing systemd unit + restarting ${SERVICE_NAME} ===="
install_systemd_unit
ssh "$HOST" "systemctl restart '${SERVICE_NAME}' && systemctl is-active '${SERVICE_NAME}'"

echo "==== Step 5: Health checks ===="
verify_health warn
echo "==== Update completed on ${HOST} @ ${LOCAL_SHORT} (${LOCAL_SHA}) ===="
