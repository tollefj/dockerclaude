#!/usr/bin/env bash
# Host-side evidence for agent-generated changes (Sikt rules 4 and 9). Usage: agent-verify.sh [base-ref]
set -uo pipefail

cd "$(dirname "$0")/.."
BASE=${1:-main}
status=0

run() {
  local tool=$1 label=$2
  shift 2
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf '[NOT_TESTABLE] %s (%s not installed)\n' "$label" "$tool"
    return
  fi
  if "$@"; then
    printf '[PASS] %s\n' "$label"
  else
    printf '[FAIL] %s\n' "$label"
    status=1
  fi
}

run gitleaks "secret scan, uncommitted changes" gitleaks git --pre-commit --redact --no-banner .
run gitleaks "secret scan, commits since $BASE" gitleaks git --redact --no-banner --log-opts="$BASE..HEAD" .
run semgrep "SAST, new findings since $BASE" semgrep scan --config auto --error --baseline-commit "$BASE" --quiet
run osv-scanner "SCA, dependency vulnerabilities" osv-scanner scan source -r .
exit "$status"
