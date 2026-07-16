#!/usr/bin/env bash
# Shared helpers for deploy / update / status. Source only — do not execute.
# shellcheck shell=bash

HOST="${HOST:-kr01}"
TARGET_DIR="${TARGET_DIR:-/opt/grok2api}"
SERVICE_NAME="${SERVICE_NAME:-grok2api}"
DOMAIN="${DOMAIN:-grok2api.karldigi.dev}"
LISTEN="${LISTEN:-127.0.0.1:8000}"
HEALTH_URL="${HEALTH_URL:-http://${LISTEN}/healthz}"
PUBLIC_URL="${PUBLIC_URL:-https://${DOMAIN}/healthz}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
GIT_BRANCH="${GIT_BRANCH:-}"
DEPLOY_META_FILE="${DEPLOY_META_FILE:-.deploy-meta}"

# Resolve repo root from the sourcing script when possible.
if [[ -z "${ROOT_DIR:-}" ]]; then
  if [[ -n "${BASH_SOURCE[1]:-}" ]]; then
    ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd)"
  else
    ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
fi

resolve_git_branch() {
  if [[ -z "$GIT_BRANCH" ]]; then
    GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  fi
}

worktree_is_dirty() {
  [[ -n "$(git status --porcelain=v1 2>/dev/null)" ]]
}

require_clean_worktree() {
  local msg="${1:-commit or stash changes first}"
  if worktree_is_dirty; then
    echo "ERROR: dirty worktree; ${msg}" >&2
    exit 1
  fi
}

remote_sha_of() {
  # $1=remote $2=branch
  git rev-parse --verify --quiet "refs/remotes/$1/$2" 2>/dev/null || true
}

deployed_sha_on_host() {
  ssh "$HOST" "sed -n 's/^git_sha=//p' '${TARGET_DIR}/${DEPLOY_META_FILE}' 2>/dev/null" || true
}

# Build meta file content for a given sha on stdout.
deploy_meta_body() {
  local sha="$1"
  local short_sha subject built_at
  short_sha="$(git rev-parse --short "$sha")"
  subject="$(git log -1 --pretty=%s "$sha")"
  built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat <<EOF
git_sha=${sha}
git_short=${short_sha}
git_subject=${subject}
git_branch=${GIT_BRANCH}
git_remote=${GIT_REMOTE}
built_at=${built_at}
EOF
}

write_deploy_meta() {
  local sha="$1"
  deploy_meta_body "$sha" | ssh "$HOST" "cat > '${TARGET_DIR}/${DEPLOY_META_FILE}' && chmod 644 '${TARGET_DIR}/${DEPLOY_META_FILE}'"
}

# Upload binary + example config + frontend in one stream; optional meta stamp after.
upload_release_bundle() {
  COPYFILE_DISABLE=1 tar -czf - -C ./dist grok2api config.example.yaml frontend \
    | ssh "$HOST" "tar -xzf - -C '${TARGET_DIR}' && chmod 755 '${TARGET_DIR}/grok2api'"
}

verify_health() {
  local mode="${1:-warn}" # warn | strict
  sleep 1
  local ok=0
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ssh "$HOST" "curl -fsS '${HEALTH_URL}'" >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 0.5
  done

  ssh "$HOST" "systemctl --no-pager --full status '${SERVICE_NAME}' | sed -n '1,15p'" || true

  if [[ "$ok" == "1" ]]; then
    ssh "$HOST" "curl -fsS '${HEALTH_URL}' && echo"
  else
    echo "local health: FAIL (${HEALTH_URL})" >&2
    if [[ "$mode" == "strict" ]]; then
      return 1
    fi
  fi

  if curl -fsS -o /dev/null --connect-timeout 10 "$PUBLIC_URL"; then
    echo "public health: OK (${PUBLIC_URL})"
  else
    echo "public health: WARN (could not reach ${PUBLIC_URL})" >&2
    if [[ "$mode" == "strict" ]]; then
      return 1
    fi
  fi
}

describe_local_vs_remote() {
  local local_sha="$1"
  local remote_sha="$2"
  if [[ -z "$remote_sha" ]]; then
    echo "local vs remote: (remote ref missing)"
    return
  fi
  if [[ "$local_sha" == "$remote_sha" ]]; then
    echo "local vs remote: match"
  elif git merge-base --is-ancestor "$local_sha" "$remote_sha"; then
    echo "local vs remote: behind (pull needed)"
  elif git merge-base --is-ancestor "$remote_sha" "$local_sha"; then
    echo "local vs remote: ahead (push pending)"
  else
    echo "local vs remote: diverged"
  fi
}
