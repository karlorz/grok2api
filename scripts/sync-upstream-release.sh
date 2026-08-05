#!/usr/bin/env bash
# Sync latest upstream GitHub Release into this fork, bump VERSION, optionally
# push main and cut a stable fork tag + GitHub Release.
#
# Reused by:
#   - humans:  ./scripts/sync-upstream-release.sh [--push] [--release]
#   - CI:      .github/workflows/sync-upstream-release.yml (schedule + dispatch)
#
# Env:
#   UPSTREAM_REPO   default chenyme/grok2api
#   FORK_REPO       default karlorz/grok2api (also used by gh)
#   UPSTREAM_REMOTE default upstream
#   ORIGIN_REMOTE   default origin
#   GIT_BRANCH      default main
#   DRY_RUN=1       print plan only (no merge/commit/push/release)
#   GITHUB_TOKEN / GH_TOKEN for gh api + release
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=lib/fork_version.sh
source "${ROOT_DIR}/scripts/lib/fork_version.sh"

UPSTREAM_REPO="${UPSTREAM_REPO:-chenyme/grok2api}"
FORK_REPO="${FORK_REPO:-karlorz/grok2api}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
ORIGIN_REMOTE="${ORIGIN_REMOTE:-origin}"
GIT_BRANCH="${GIT_BRANCH:-main}"
DRY_RUN="${DRY_RUN:-0}"

DO_PUSH=0
DO_RELEASE=0

usage() {
  cat <<'EOF'
Usage: scripts/sync-upstream-release.sh [options]

  Detect latest GitHub Release on UPSTREAM_REPO, merge that tag into GIT_BRANCH
  when newer than fork VERSION, set VERSION to vX.Y.Z-0, commit, optionally
  push and cut a stable fork tag + GitHub Release.

Options:
  --push       push GIT_BRANCH to origin after commit
  --release    after push (or when already current with unpushed tag work),
               run fork-tag.sh --release (requires clean tree + VERSION committed)
  --dry-run    plan only; no merge/commit/push/release
  -h, --help   show this help

Exit codes:
  0  already up to date, or sync (+ optional release) succeeded
  1  error (merge conflict, dirty tree, missing tools, etc.)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push) DO_PUSH=1; shift ;;
    --release) DO_RELEASE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "unknown arg: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

require_cmd git
require_cmd gh

if [[ -n "$(git status --porcelain=v1)" ]]; then
  echo "ERROR: dirty worktree; commit or stash before sync-upstream-release" >&2
  git status --porcelain=v1 | head -20 >&2
  exit 1
fi

current_version() {
  if [[ -f VERSION ]]; then
    tr -d '[:space:]' < VERSION
  else
    echo ""
  fi
}

FORK_VERSION="$(current_version)"
echo "fork VERSION: ${FORK_VERSION:-"(none)"}"
echo "upstream repo: ${UPSTREAM_REPO}"

UPSTREAM_TAG="$(
  gh api "repos/${UPSTREAM_REPO}/releases/latest" --jq '.tagName // .tag_name' 2>/dev/null \
    || gh release view --repo "$UPSTREAM_REPO" --json tagName --jq '.tagName'
)"
UPSTREAM_TAG="$(printf '%s' "$UPSTREAM_TAG" | tr -d '[:space:]')"
if [[ -z "$UPSTREAM_TAG" ]]; then
  echo "ERROR: could not resolve latest release tag for ${UPSTREAM_REPO}" >&2
  exit 1
fi
UPSTREAM_BASE="$(fv_upstream_base "$UPSTREAM_TAG" || true)"
if [[ -z "$UPSTREAM_BASE" ]]; then
  echo "ERROR: upstream tag is not semver-like vX.Y.Z: ${UPSTREAM_TAG}" >&2
  exit 1
fi
echo "upstream latest release: ${UPSTREAM_TAG} (base ${UPSTREAM_BASE})"

if [[ -n "$FORK_VERSION" ]] && fv_fork_covers_upstream "$FORK_VERSION" "$UPSTREAM_BASE"; then
  echo "==== Already up to date ===="
  echo "Fork VERSION ${FORK_VERSION} already covers upstream ${UPSTREAM_BASE}."
  if [[ "$DO_RELEASE" == "1" ]]; then
    # Still allow cutting a missing release for current VERSION.
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "DRY_RUN: would ensure fork release for ${FORK_VERSION}"
      exit 0
    fi
    if [[ "$FORK_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]]; then
      if gh release view "$FORK_VERSION" --repo "$FORK_REPO" >/dev/null 2>&1; then
        echo "GitHub Release ${FORK_VERSION} already exists; nothing to do."
        exit 0
      fi
      echo "Release missing for current VERSION; running fork-tag --release..."
      GITHUB_REPOSITORY="$FORK_REPO" ./scripts/fork-tag.sh --release
    fi
  fi
  exit 0
fi

NEXT_VERSION="$(fv_fork_series_start "$UPSTREAM_BASE")"
echo "planned fork VERSION: ${NEXT_VERSION}"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY_RUN: would merge ${UPSTREAM_REMOTE} tag/base ${UPSTREAM_BASE}, write VERSION=${NEXT_VERSION}, commit"
  [[ "$DO_PUSH" == "1" ]] && echo "DRY_RUN: would push ${ORIGIN_REMOTE}/${GIT_BRANCH}"
  [[ "$DO_RELEASE" == "1" ]] && echo "DRY_RUN: would run fork-tag.sh --release"
  exit 0
fi

# Ensure remotes
if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  git remote add "$UPSTREAM_REMOTE" "https://github.com/${UPSTREAM_REPO}.git"
fi
if ! git remote get-url "$ORIGIN_REMOTE" >/dev/null 2>&1; then
  echo "ERROR: missing remote ${ORIGIN_REMOTE}" >&2
  exit 1
fi

echo "==== Fetching remotes ===="
git fetch --prune --tags --force "$UPSTREAM_REMOTE"
git fetch --prune --tags --force "$ORIGIN_REMOTE"

# Prefer exact release tag; fall back to remote main if tag missing.
MERGE_REF=""
if git rev-parse --verify --quiet "refs/tags/${UPSTREAM_BASE}" >/dev/null; then
  MERGE_REF="refs/tags/${UPSTREAM_BASE}"
elif git rev-parse --verify --quiet "refs/tags/${UPSTREAM_TAG}" >/dev/null; then
  MERGE_REF="refs/tags/${UPSTREAM_TAG}"
elif git rev-parse --verify --quiet "refs/remotes/${UPSTREAM_REMOTE}/${GIT_BRANCH}" >/dev/null; then
  MERGE_REF="refs/remotes/${UPSTREAM_REMOTE}/${GIT_BRANCH}"
  echo "WARN: tag ${UPSTREAM_BASE} not found after fetch; merging ${MERGE_REF}" >&2
else
  echo "ERROR: cannot resolve merge ref for upstream ${UPSTREAM_TAG}" >&2
  exit 1
fi

MERGE_SHA="$(git rev-parse "$MERGE_REF")"
echo "merge ref: ${MERGE_REF} (${MERGE_SHA})"

MERGE_MSG="chore: sync upstream ${UPSTREAM_BASE} and start fork series ${NEXT_VERSION}

Merge ${UPSTREAM_REPO} ${UPSTREAM_TAG} into ${GIT_BRANCH}."

if git merge-base --is-ancestor "$MERGE_SHA" HEAD; then
  echo "HEAD already contains ${MERGE_REF}; only VERSION bump may be needed."
else
  echo "==== Merging ${MERGE_REF} ===="
  set +e
  git merge --no-edit -m "$MERGE_MSG" "$MERGE_REF"
  merge_rc=$?
  set -e
  if [[ "$merge_rc" -ne 0 ]]; then
    # Only auto-resolve VERSION (fork scheme vs upstream official). Any other
    # conflict aborts cleanly — never force-resolve product files.
    conflicted="$(git diff --name-only --diff-filter=U 2>/dev/null || true)"
    if [[ "$conflicted" == "VERSION" ]]; then
      echo "Resolving sole VERSION conflict → ${NEXT_VERSION}"
      printf '%s\n' "$NEXT_VERSION" > VERSION
      git add VERSION
      git commit -m "$MERGE_MSG"
    elif [[ -z "$conflicted" ]]; then
      echo "ERROR: merge failed without listed conflicts (rc=${merge_rc})" >&2
      git merge --abort 2>/dev/null || true
      exit 1
    else
      echo "ERROR: merge conflict in non-VERSION files; aborting cleanly (no force resolve)." >&2
      printf '%s\n' "$conflicted" | sed 's/^/  /' >&2
      git merge --abort 2>/dev/null || true
      exit 1
    fi
  fi
fi

# Ensure VERSION is the fork series start (merge may have taken upstream vX.Y.Z).
if [[ "$(tr -d '[:space:]' < VERSION)" != "$NEXT_VERSION" ]]; then
  printf '%s\n' "$NEXT_VERSION" > VERSION
  git add VERSION
  git commit -m "chore: set fork VERSION to ${NEXT_VERSION} after upstream ${UPSTREAM_BASE}"
fi

if [[ "$(tr -d '[:space:]' < VERSION)" != "$NEXT_VERSION" ]]; then
  echo "ERROR: VERSION not set to ${NEXT_VERSION}" >&2
  exit 1
fi

echo "HEAD: $(git rev-parse HEAD) VERSION=$(tr -d '[:space:]' < VERSION)"

if [[ "$DO_PUSH" == "1" ]]; then
  echo "==== Pushing ${ORIGIN_REMOTE}/${GIT_BRANCH} ===="
  git push "$ORIGIN_REMOTE" "HEAD:refs/heads/${GIT_BRANCH}"
fi

if [[ "$DO_RELEASE" == "1" ]]; then
  if [[ "$DO_PUSH" != "1" ]]; then
    # Release pushes the tag; branch should already be on origin for clean history.
    echo "WARN: --release without --push; ensure ${GIT_BRANCH} is on origin before tagging." >&2
  fi
  echo "==== Cutting fork release ${NEXT_VERSION} ===="
  GITHUB_REPOSITORY="$FORK_REPO" ./scripts/fork-tag.sh --release
fi

echo "==== Sync complete: ${NEXT_VERSION} ===="
