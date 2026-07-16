#!/usr/bin/env bash
# Read-only health probe for the kr01 binary deployment + git SHA compare.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
cd "$ROOT_DIR"

resolve_git_branch
LOCAL_SHA="$(git rev-parse HEAD)"
LOCAL_SHORT="$(git rev-parse --short HEAD)"

echo "==== Git (local checkout) ===="
echo "branch: ${GIT_BRANCH}"
echo "HEAD:   ${LOCAL_SHA} (${LOCAL_SHORT})"
if worktree_is_dirty; then
  echo "worktree: dirty"
fi

REMOTE_SHA=""
if git fetch --quiet --prune "$GIT_REMOTE" 2>/dev/null; then
  REMOTE_SHA="$(remote_sha_of "$GIT_REMOTE" "$GIT_BRANCH")"
  if [[ -n "$REMOTE_SHA" ]]; then
    echo "${GIT_REMOTE}/${GIT_BRANCH}: ${REMOTE_SHA} ($(git rev-parse --short "$REMOTE_SHA"))"
  fi
  describe_local_vs_remote "$LOCAL_SHA" "$REMOTE_SHA"
else
  echo "fetch ${GIT_REMOTE}: skipped/failed"
fi

echo
echo "==== Host ${HOST} ===="
# Single SSH: host facts + meta dump + health; meta ends with git_sha for local parse.
HOST_OUT="$(ssh "$HOST" "
  set +e
  echo \"hostname: \$(hostname) arch: \$(uname -m)\"
  echo \"service: \$(systemctl is-active ${SERVICE_NAME} 2>/dev/null || echo unknown)\"
  echo 'binary:'
  ls -la ${TARGET_DIR}/grok2api 2>/dev/null || echo '  missing'
  echo 'config:'
  ls -la ${TARGET_DIR}/config.yaml 2>/dev/null || echo '  missing'
  echo 'deploy meta:'
  if [ -f ${TARGET_DIR}/${DEPLOY_META_FILE} ]; then
    cat ${TARGET_DIR}/${DEPLOY_META_FILE}
  else
    echo '  (none — run make deploy or make update once to stamp SHA)'
  fi
  echo 'local health:'
  curl -fsS '${HEALTH_URL}' && echo || echo '  failed'
  if [ \"\${VERBOSE:-0}\" = 1 ]; then
    systemctl --no-pager --full status ${SERVICE_NAME} 2>/dev/null | sed -n '1,12p'
  fi
")"
printf '%s\n' "$HOST_OUT"

DEPLOYED_SHA="$(printf '%s\n' "$HOST_OUT" | sed -n 's/^git_sha=//p' | head -1)"

echo
echo "==== SHA compare ===="
if [[ -n "$DEPLOYED_SHA" ]]; then
  echo "deployed: ${DEPLOYED_SHA}"
  if [[ "$DEPLOYED_SHA" == "$LOCAL_SHA" ]]; then
    echo "local vs deployed: match"
  else
    echo "local vs deployed: DIFFERENT (make update to roll out)"
  fi
else
  echo "deployed: unknown (no ${DEPLOY_META_FILE} on host)"
fi

echo
echo "==== Public health ===="
if curl -fsS --connect-timeout 10 "$PUBLIC_URL"; then
  echo
  echo "public: OK (${PUBLIC_URL})"
else
  echo "public: FAIL (${PUBLIC_URL})" >&2
  exit 1
fi
