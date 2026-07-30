#!/usr/bin/env bash
# Pure version helpers for fork scheme vMAJOR.MINOR.PATCH-FORKREV.
# Source only — do not execute.
# shellcheck shell=bash

# Parse vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-FORKREV.
# Sets: FV_MAJOR FV_MINOR FV_PATCH FV_FORK (empty if none)
# Returns 0 on success, 1 on invalid.
fv_parse() {
  local raw="${1:-}"
  raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
  raw="${raw#v}"
  if [[ ! "$raw" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9]+))?$ ]]; then
    FV_MAJOR="" FV_MINOR="" FV_PATCH="" FV_FORK=""
    return 1
  fi
  FV_MAJOR="${BASH_REMATCH[1]}"
  FV_MINOR="${BASH_REMATCH[2]}"
  FV_PATCH="${BASH_REMATCH[3]}"
  FV_FORK="${BASH_REMATCH[5]:-}"
  return 0
}

# Normalize to upstream base vX.Y.Z (strip fork rev if present). Empty on invalid.
fv_upstream_base() {
  local raw="${1:-}"
  if ! fv_parse "$raw"; then
    echo ""
    return 1
  fi
  echo "v${FV_MAJOR}.${FV_MINOR}.${FV_PATCH}"
}

# First fork cut for an upstream base: vX.Y.Z-0
fv_fork_series_start() {
  local base
  base="$(fv_upstream_base "${1:-}")" || true
  if [[ -z "$base" ]]; then
    echo ""
    return 1
  fi
  echo "${base}-0"
}

# Compare two version strings by (major, minor, patch) only; fork rev ignored.
# Prints: lt | eq | gt | invalid
fv_compare_base() {
  local a="${1:-}" b="${2:-}"
  if ! fv_parse "$a"; then
    echo "invalid"
    return 1
  fi
  local a_maj="$FV_MAJOR" a_min="$FV_MINOR" a_pat="$FV_PATCH"
  if ! fv_parse "$b"; then
    echo "invalid"
    return 1
  fi
  local b_maj="$FV_MAJOR" b_min="$FV_MINOR" b_pat="$FV_PATCH"

  if (( a_maj < b_maj )); then echo "lt"; return 0; fi
  if (( a_maj > b_maj )); then echo "gt"; return 0; fi
  if (( a_min < b_min )); then echo "lt"; return 0; fi
  if (( a_min > b_min )); then echo "gt"; return 0; fi
  if (( a_pat < b_pat )); then echo "lt"; return 0; fi
  if (( a_pat > b_pat )); then echo "gt"; return 0; fi
  echo "eq"
}

# True (exit 0) when fork VERSION base is already >= upstream release tag base.
fv_fork_covers_upstream() {
  local fork_ver="${1:-}" upstream_tag="${2:-}"
  local cmp
  cmp="$(fv_compare_base "$fork_ver" "$upstream_tag")" || return 1
  [[ "$cmp" == "eq" || "$cmp" == "gt" ]]
}
