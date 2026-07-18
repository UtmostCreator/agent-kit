#!/usr/bin/env bash
# Run the full test suite: every per-command implementation test plus the
# cross-cutting behavioral-contract suite (test/test-contract.sh). This is the
# single entry point humans use; CI runs scripts/check.sh, which shellchecks
# first, then runs the same test/test-*.sh set this discovers.
#
#   bash test/run-all.sh                   # every test file
#   CONTRACT_ONLY=1 bash test/run-all.sh   # only the behavioral-contract suite
#
# For CI reproducibility, prefer running from a clean checkout/worktree so
# results never depend on local uncommitted changes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASH_BIN="${BASH_BIN:-$(command -v bash)}"
pass=0 fail=0 failed=()

run_file() {
  local f="$1" name; name="$(basename "$f" .sh)"
  if timeout "${TEST_TIMEOUT:-180}" "$BASH_BIN" "$f" >"/tmp/.run-all.$$.$name.log" 2>&1; then
    printf '  \033[0;32m✓\033[0m %s\n' "$name"; pass=$((pass+1))
  else
    printf '  \033[0;31m✗\033[0m %s (exit=%d)\n' "$name" "$?"; fail=$((fail+1)); failed+=("$name")
    sed 's/^/      /' "/tmp/.run-all.$$.$name.log" | tail -15
  fi
  rm -f "/tmp/.run-all.$$.$name.log"
}

if [[ -n "${CONTRACT_ONLY:-}" ]]; then
  echo "== behavioral-contract suite only =="
  run_file "$SCRIPT_DIR/test-contract.sh"
else
  echo "== full suite (implementation tests + behavioral contract) =="
  for f in "$SCRIPT_DIR"/test-*.sh; do run_file "$f"; done
fi

echo
if [[ $fail -eq 0 ]]; then
  printf '\033[0;32mALL PASS\033[0m (%d files)\n' "$pass"; exit 0
else
  printf '\033[0;31m%d FAILED\033[0m: %s\n' "$fail" "${failed[*]}"; exit 1
fi
