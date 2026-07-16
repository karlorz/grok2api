#!/usr/bin/env bash
# Fork version tags distinct from upstream official tags.
#
# Scheme:
#   upstream official:  v3.0.2
#   this fork:          v3.0.2-0 , v3.0.2-1 , v3.0.2-2 , ...
#
# When you sync a new upstream release (e.g. v3.1.0), start a new series:
#   ./scripts/fork-tag.sh --base v3.1.0 --write
#   → VERSION=v3.1.0-0
#
# Bump the fork revision on the same upstream base:
#   ./scripts/fork-tag.sh --write
#   → v3.0.2-0 → v3.0.2-1
#
# Create git tag + GitHub Release (after VERSION is committed/pushed):
#   ./scripts/fork-tag.sh --release
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BASE=""
WRITE=0
RELEASE=0
PRINT_ONLY=1

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  echo "Usage: $0 [--base vX.Y.Z] [--write] [--release] [--next]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      BASE="${2:-}"
      shift 2
      ;;
    --write)
      WRITE=1
      PRINT_ONLY=0
      shift
      ;;
    --release)
      RELEASE=1
      PRINT_ONLY=0
      shift
      ;;
    --next)
      # default: print next tag only
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

current_version() {
  if [[ -f VERSION ]]; then
    tr -d '[:space:]' < VERSION
  else
    echo ""
  fi
}

# Parse vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-FORKREV
# Sets: PARSE_MAJOR PARSE_MINOR PARSE_PATCH PARSE_FORK (empty if none)
parse_version() {
  local raw="$1"
  raw="${raw#v}"
  if [[ ! "$raw" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9]+))?$ ]]; then
    return 1
  fi
  PARSE_MAJOR="${BASH_REMATCH[1]}"
  PARSE_MINOR="${BASH_REMATCH[2]}"
  PARSE_PATCH="${BASH_REMATCH[3]}"
  PARSE_FORK="${BASH_REMATCH[5]:-}"
  return 0
}

normalize_base() {
  local raw="$1"
  raw="$(echo "$raw" | tr -d '[:space:]')"
  [[ "$raw" == v* ]] || raw="v${raw}"
  # strip fork rev if user passed v3.0.2-1 as base
  if parse_version "$raw"; then
    echo "v${PARSE_MAJOR}.${PARSE_MINOR}.${PARSE_PATCH}"
  else
    echo ""
  fi
}

CURRENT="$(current_version)"
if [[ -n "$BASE" ]]; then
  UPSTREAM_BASE="$(normalize_base "$BASE")"
  if [[ -z "$UPSTREAM_BASE" ]]; then
    echo "ERROR: invalid --base '$BASE' (want vX.Y.Z)" >&2
    exit 1
  fi
  # New upstream series always starts at -0
  NEXT="${UPSTREAM_BASE}-0"
elif [[ -n "$CURRENT" ]] && parse_version "$CURRENT"; then
  if [[ -n "$PARSE_FORK" ]]; then
    NEXT="v${PARSE_MAJOR}.${PARSE_MINOR}.${PARSE_PATCH}-$((PARSE_FORK + 1))"
  else
    # Official-style VERSION without fork rev → first fork cut
    NEXT="v${PARSE_MAJOR}.${PARSE_MINOR}.${PARSE_PATCH}-0"
  fi
else
  echo "ERROR: no VERSION and no --base; cannot compute next fork tag" >&2
  exit 1
fi

echo "current: ${CURRENT:-"(none)"}"
echo "next:    ${NEXT}"

if [[ "$WRITE" == "1" ]]; then
  printf '%s\n' "$NEXT" > VERSION
  echo "wrote VERSION=${NEXT}"
fi

if [[ "$RELEASE" == "1" ]]; then
  tag="$(tr -d '[:space:]' < VERSION)"
  if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]]; then
    echo "ERROR: VERSION must be fork tag vX.Y.Z-N before --release (got ${tag})" >&2
    exit 1
  fi
  if [[ -n "$(git status --porcelain=v1)" ]]; then
    echo "ERROR: dirty worktree; commit VERSION (and other changes) before --release" >&2
    exit 1
  fi
  # Ensure VERSION on HEAD matches tag we will cut
  if [[ "$(tr -d '[:space:]' < VERSION)" != "$tag" ]]; then
    echo "ERROR: VERSION mismatch" >&2
    exit 1
  fi
  git fetch --tags --force origin 2>/dev/null || true
  if git rev-parse "refs/tags/${tag}" >/dev/null 2>&1; then
    echo "tag ${tag} already exists locally"
  else
    git tag -a "$tag" -m "fork release ${tag}"
    echo "created tag ${tag}"
  fi
  git push origin "refs/tags/${tag}"
  # Trigger Release workflow notes / ensure GitHub Release exists
  if gh release view "$tag" --repo "${GITHUB_REPOSITORY:-karlorz/grok2api}" >/dev/null 2>&1; then
    echo "GitHub Release ${tag} already exists"
  else
    gh release create "$tag" \
      --repo "${GITHUB_REPOSITORY:-karlorz/grok2api}" \
      --title "$tag" \
      --notes "$(cat <<EOF
## ${tag}

Fork release of [karlorz/grok2api](https://github.com/karlorz/grok2api).

- Upstream base: \`v${tag#v}\` → strip fork rev for reference: \`$(echo "$tag" | sed -E 's/-[0-9]+$//')\`
- Fork revision: \`${tag##*-}\` (distinct from upstream official tags)

### Binary deploy (kr01)

\`\`\`bash
git pull --ff-only
make update
\`\`\`

### Container

\`ghcr.io/karlorz/grok2api:${tag}\` (when GHCR workflow succeeds)
EOF
)"
    echo "created GitHub Release ${tag}"
  fi
fi

if [[ "$PRINT_ONLY" == "1" && "$WRITE" != "1" && "$RELEASE" != "1" ]]; then
  # already printed next
  :
fi
