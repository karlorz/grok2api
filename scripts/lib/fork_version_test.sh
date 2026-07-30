#!/usr/bin/env bash
# Unit tests for scripts/lib/fork_version.sh (shipped helpers).
# Run: bash scripts/lib/fork_version_test.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=fork_version.sh
source "${ROOT_DIR}/scripts/lib/fork_version.sh"

FAILS=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAILS=$((FAILS + 1)); }

assert_eq() {
  local got="$1" want="$2" msg="$3"
  if [[ "$got" == "$want" ]]; then
    pass "$msg"
  else
    fail "$msg (got='$got' want='$want')"
  fi
}

assert_ok() {
  if "$@"; then
    pass "ok: $*"
  else
    fail "expected success: $*"
  fi
}

assert_fail() {
  if "$@"; then
    fail "expected failure: $*"
  else
    pass "fail-as-expected: $*"
  fi
}

echo "==== fv_parse ===="
assert_ok fv_parse "v3.0.11"
assert_eq "${FV_MAJOR}.${FV_MINOR}.${FV_PATCH}" "3.0.11" "parse official"
assert_eq "${FV_FORK}" "" "official has empty fork rev"

assert_ok fv_parse "v3.0.11-0"
assert_eq "${FV_MAJOR}.${FV_MINOR}.${FV_PATCH}-${FV_FORK}" "3.0.11-0" "parse fork"
assert_ok fv_parse "3.0.10-2"
assert_eq "v${FV_MAJOR}.${FV_MINOR}.${FV_PATCH}-${FV_FORK}" "v3.0.10-2" "parse without v prefix"

assert_fail fv_parse "not-a-version"
assert_fail fv_parse "v3.0.8-hotfix.1"

echo "==== fv_upstream_base / fv_fork_series_start ===="
assert_eq "$(fv_upstream_base "v3.0.11-2")" "v3.0.11" "strip fork rev"
assert_eq "$(fv_upstream_base "v3.0.11")" "v3.0.11" "base unchanged"
assert_eq "$(fv_fork_series_start "v3.0.11")" "v3.0.11-0" "series start"
assert_eq "$(fv_fork_series_start "v3.0.11-9")" "v3.0.11-0" "series start from fork ver"

echo "==== fv_compare_base ===="
assert_eq "$(fv_compare_base "v3.0.10-0" "v3.0.11")" "lt" "3.0.10 < 3.0.11"
assert_eq "$(fv_compare_base "v3.0.11-0" "v3.0.11")" "eq" "same base ignores fork rev"
assert_eq "$(fv_compare_base "v3.1.0-0" "v3.0.11")" "gt" "3.1.0 > 3.0.11"
assert_eq "$(fv_compare_base "v3.0.11-5" "v3.0.10")" "gt" "patch compare"

echo "==== fv_fork_covers_upstream ===="
assert_ok fv_fork_covers_upstream "v3.0.11-0" "v3.0.11"
assert_ok fv_fork_covers_upstream "v3.0.11-0" "v3.0.10"
assert_fail fv_fork_covers_upstream "v3.0.10-0" "v3.0.11"
assert_fail fv_fork_covers_upstream "v3.0.10-0" "v3.0.11-0"

echo "==== script files exist (structural) ===="
for f in \
  scripts/sync-upstream-release.sh \
  scripts/upgrade-kr01.sh \
  scripts/fork-tag.sh \
  scripts/update.sh \
  .github/workflows/sync-upstream-release.yml
do
  if [[ -f "${ROOT_DIR}/${f}" ]]; then
    pass "exists ${f}"
  else
    fail "missing ${f}"
  fi
done

# Workflow must declare schedule + workflow_dispatch and invoke the script.
WF="${ROOT_DIR}/.github/workflows/sync-upstream-release.yml"
if grep -q 'schedule:' "$WF" && grep -q 'workflow_dispatch:' "$WF" && grep -q 'sync-upstream-release.sh' "$WF"; then
  pass "workflow has schedule, workflow_dispatch, and invokes sync script"
else
  fail "workflow missing schedule/workflow_dispatch/script invoke"
fi
if grep -q 'contents: write' "$WF"; then
  pass "workflow has contents: write"
else
  fail "workflow missing contents: write"
fi

# upgrade script defaults HOST=kr01 and calls update.sh
UPG="${ROOT_DIR}/scripts/upgrade-kr01.sh"
if grep -q 'HOST="${HOST:-kr01}"' "$UPG" && grep -q './scripts/update.sh' "$UPG"; then
  pass "upgrade-kr01 defaults HOST=kr01 and runs update.sh"
else
  fail "upgrade-kr01 missing HOST default or update.sh call"
fi

echo
if [[ "$FAILS" -eq 0 ]]; then
  echo "All fork_version tests passed."
  exit 0
fi
echo "${FAILS} test(s) failed." >&2
exit 1
