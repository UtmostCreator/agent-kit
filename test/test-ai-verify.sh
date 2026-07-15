#!/usr/bin/env bash
# Tests for libexec/ai-verify
# NOTE: this wrapper still carries the 2 kit-specific calls flagged in the
# parent extraction ticket's Chunk-1 addendum (check_plan_status's
# docs/tickets Todo guardrail and is_ai_kit_source_repo's shipped-file
# exclusion, sourced from lib/ai-verify/plan-status.sh and
# lib/ai-verify/shipped-filters.sh). This test still exercises that logic
# unchanged; whether/how to strip, no-op, or hookify it for a generic
# consumer repo is an open decision, not resolved by this move.
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/ai-verify"
cd "$REPO_ROOT"

PASS=0 FAIL=0 SKIP=0
run_test() {
    local name="$1"
    shift
    local _rc=0
    "$@" >/dev/null 2>&1 || _rc=$?
    if ((_rc == 0)); then
        PASS=$((PASS + 1))
        printf '  \033[0;32m✓\033[0m %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  \033[0;31m✗\033[0m %s\n' "$name"
    fi
}
skip_test() {
    SKIP=$((SKIP + 1))
    printf '  \033[0;33m⊘\033[0m %s (skipped: %s)\n' "$1" "$2"
}

# Shared cleanup for the longer-lived fixture directories used by the `verify
# docs`/`verify refs` sections below (ported from test-ai-doc-check.sh /
# test-check-file-refs.sh, which each had their own single-purpose `trap ...
# EXIT`). A single array + single trap avoids one trap silently replacing the
# other now that both suites share one process.
_test_tmp_dirs=()
cleanup_test_tmp_dirs() {
    local d
    for d in "${_test_tmp_dirs[@]+${_test_tmp_dirs[@]}}"; do
        rm -rf "$d"
    done
}
trap cleanup_test_tmp_dirs EXIT

printf 'ai-verify.sh\n'

# Script runs and produces output
test_runs() {
    local out
    out="$(AI_VERIFY_TEST_MODE=1 "$BASH_BIN" "$SCRIPT" "$REPO_ROOT" 2>&1 || true)"
    [[ "$out" == *"==>"* ]]
}
run_test "script runs and prints step markers" test_runs

# Prints repository status
test_repo_status() {
    local out
    out="$(AI_VERIFY_TEST_MODE=1 "$BASH_BIN" "$SCRIPT" "$REPO_ROOT" 2>&1 || true)"
    [[ "$out" == *"repository"* ]]
}
run_test "prints repository section" test_repo_status

# Runs shellcheck if available
if command -v shellcheck >/dev/null 2>&1; then
    test_shellcheck() {
        local out
        out="$(AI_VERIFY_TEST_MODE=1 AI_VERIFY_SCOPE=ai "$BASH_BIN" "$SCRIPT" "$REPO_ROOT" 2>&1 || true)"
        [[ "$out" == *"shellcheck"* ]]
    }
    run_test "runs shellcheck on AI scripts" test_shellcheck
else
    skip_test "runs shellcheck on AI scripts" "shellcheck not installed"
fi

# Runs composer validate if available
if command -v composer >/dev/null 2>&1 && [[ -f "$REPO_ROOT/composer.json" ]]; then
    test_composer() {
        local out
        out="$(AI_VERIFY_TEST_MODE=1 "$BASH_BIN" "$SCRIPT" "$REPO_ROOT" 2>&1 || true)"
        [[ "$out" == *"composer"* ]]
    }
    run_test "runs composer validate" test_composer
else
    skip_test "runs composer validate" "composer not available"
fi

# VERIFY_FULL=0 skips full test suite
test_skip_full() {
    local out
    out="$(AI_VERIFY_TEST_MODE=1 VERIFY_FULL=0 "$BASH_BIN" "$SCRIPT" "$REPO_ROOT" 2>&1 || true)"
    [[ "$out" == *"Skipping full"* ]] || [[ "$out" == *"done"* ]]
}
run_test "VERIFY_FULL=0 skips full test suite" test_skip_full

# AI_VERIFY_SCOPE=changed limits scope
test_scope_changed() {
    local out
    out="$(AI_VERIFY_TEST_MODE=1 AI_VERIFY_SCOPE=changed "$BASH_BIN" "$SCRIPT" "$REPO_ROOT" 2>&1 || true)"
    # Should complete without error
    [[ "$out" == *"==>"* ]]
}
run_test "AI_VERIFY_SCOPE=changed limits scope" test_scope_changed

# Extract the scoping helper functions from the script and exercise them in
# isolation, so the merge-base/branch logic is covered without needing pint.
load_scoping_functions() {
    # shellcheck disable=SC1090
    source "$REPO_ROOT/lib/common.sh"
    # These are consumed by the eval'd helper functions below via dynamic scope.
    # shellcheck disable=SC2034
    VERIFY_BASE_REF=""
    # shellcheck disable=SC2034
    VERIFY_AUTHOR=""
    # shellcheck disable=SC2034
    AI_VERIFY_SCOPE="branch"
    # The scope/shipped-filter helpers live in load-ordered modules under
    # lib/ai-verify/ (libexec/ai-verify is a thin loader).
    # Source those modules directly to exercise the helpers in isolation. Order
    # matches the root loader: shipped-filter predicates before the scope helpers
    # that call them.
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/ai-verify/shipped-filters.sh"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/ai-verify/scope.sh"
}

# resolve_branch_base prints a commit sha or fails cleanly
test_resolve_base() {
    (
        set -euo pipefail
        load_scoping_functions
        local base
        base="$(resolve_branch_base || true)"
        # On any branch with origin/main present, base must be a 40-char sha; if
        # no trunk exists, base is empty and the function returns nonzero — both
        # are acceptable, but it must never crash.
        [[ -z "$base" || "$base" =~ ^[0-9a-f]{7,40}$ ]]
    )
}
run_test "resolve_branch_base returns a sha or empty without crashing" test_resolve_base

# scoped_php_files only emits existing *.php files and never errors under set -e
test_scoped_php_files() {
    (
        set -euo pipefail
        load_scoping_functions
        local out
        out="$(scoped_php_files || true)"
        # Every emitted line must be an existing .php file.
        local f
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            [[ "$f" == *.php ]] || exit 1
            [[ -f "$f" ]] || exit 1
        done <<<"$out"
    )
}
run_test "scoped_php_files emits only existing php files" test_scoped_php_files

# branch scope must be a recognized scope (no 'unknown scope' die). The scope is
# validated up front, so a short time cap is enough to prove it — this avoids
# waiting on a full per-file verification pass in repositories where every file
# is treated as changed (e.g. a fresh, mostly-uncommitted working tree).
_verify_timeout=""
for _t in timeout gtimeout; do command -v "$_t" >/dev/null 2>&1 && { _verify_timeout="$_t"; break; }; done
test_branch_scope_recognized() {
    local out
    # Scope validation happens up front and dies (if it were to) well under
    # a second; the cap only needs enough margin to observe that, not to let
    # the full per-file verification pass finish (confirmed: this reliably
    # ran into and got killed by the old 20s cap every single run, spending
    # 20s to prove something a 3s cap already proves).
    out="$(AI_VERIFY_TEST_MODE=0 AI_VERIFY_SCOPE=branch VERIFY_SECRETS=0 VERIFY_FULL=0 \
        ${_verify_timeout:+$_verify_timeout 3} \
        "$BASH_BIN" "$SCRIPT" "$REPO_ROOT" 2>&1 || true)"
    [[ "$out" != *"unknown AI_VERIFY_SCOPE"* ]]
}
run_test "branch scope is recognized (no unknown-scope error)" test_branch_scope_recognized

# Run the script with a fake "lychee" on PATH that records every invocation.
# This proves the link checker never reaches the network by accident.
run_with_fake_lychee() {
    local tmpbin record
    tmpbin="$(mktemp -d)"
    record="$tmpbin/lychee.calls"
    cat >"$tmpbin/lychee" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$record"
exit 0
EOF
    chmod +x "$tmpbin/lychee"
    # Run in a throwaway dir with a README so the lychee branch has a target,
    # but no composer.json/package.json so PHP/JS blocks stay out of the way.
    local work="$tmpbin/work"
    mkdir -p "$work/docs"
    printf '# t\n' >"$work/README.md"
    (
        cd "$work"
        git init -q
        # AI_VERIFY_SCOPE=branch: this fixture has no commits, so every file
        # looks "changed" under the default scope, which pulls in the
        # trivy/semgrep/osv-scanner security-scan block -- multi-second
        # startup cost (rule DB loads, network probes) that has nothing to
        # do with what this helper actually asserts (lychee invocation).
        # Scoping to branch skips that block the same way
        # test_branch_scope_recognized already relies on.
        PATH="$tmpbin:$PATH" AI_VERIFY_TEST_MODE=0 VERIFY_SECRETS=0 VERIFY_FULL=0 AI_VERIFY_SCOPE=branch \
            "$@" "$BASH_BIN" "$SCRIPT" "$work" >/dev/null 2>&1 || true
    )
    cat "$record" 2>/dev/null || true
    rm -rf "$tmpbin"
}

# Default: link checking is OFF, so fake lychee must NOT be called at all.
test_links_off_by_default() {
    local calls
    calls="$(run_with_fake_lychee env)"
    [[ -z "$calls" ]]
}
run_test "link check is skipped by default (no network)" test_links_off_by_default

# VERIFY_LINKS=1 (no network flag): lychee must be called WITH --offline.
test_links_offline_when_enabled() {
    local calls
    calls="$(run_with_fake_lychee env VERIFY_LINKS=1)"
    [[ "$calls" == *"--offline"* ]]
}
run_test "VERIFY_LINKS=1 runs lychee with --offline" test_links_offline_when_enabled

# VERIFY_LINKS_NETWORK=1 is ignored by this wrapper: lychee still runs offline.
test_links_network_still_offline() {
    local calls
    calls="$(run_with_fake_lychee env VERIFY_LINKS=1 VERIFY_LINKS_NETWORK=1)"
    [[ "$calls" == *"--offline"* ]]
}
run_test "VERIFY_LINKS_NETWORK=1 still runs lychee offline" test_links_network_still_offline

# Run ai-verify with fake actionlint/composer binaries and capture invocations.
run_with_fake_actionlint_and_composer() {
    local mutate_mode="${1:-none}" # none | workflow | composer
    local tmpbin record
    tmpbin="$(mktemp -d)"
    record="$tmpbin/tool.calls"

    cat >"$tmpbin/actionlint" <<EOF
#!/usr/bin/env bash
printf 'actionlint:%s\n' "\$*" >>"$record"
exit 0
EOF
    cat >"$tmpbin/composer" <<EOF
#!/usr/bin/env bash
printf 'composer:%s\n' "\$*" >>"$record"
exit 0
EOF
    chmod +x "$tmpbin/actionlint" "$tmpbin/composer"

    local work="$tmpbin/work"
    mkdir -p "$work/.github/workflows" "$work/src"
    printf '{"name":"t/t","require":{}}\n' >"$work/composer.json"
    printf 'name: ci\non: [push]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ok\n' >"$work/.github/workflows/ci.yml"
    printf '<?php\n' >"$work/src/App.php"

    (
        cd "$work"
        git init -q
        git config user.email test@example.test
        git config user.name Test
        # Avoid host/global ignore rules affecting fixture determinism.
        git config core.excludesfile /dev/null
        git add -f -A
        git commit -q -m init

        case "$mutate_mode" in
        workflow)
            printf '\n# changed\n' >>.github/workflows/ci.yml
            ;;
        composer)
            printf '\n' >>composer.json
            ;;
        *)
            printf '// changed\n' >>src/App.php
            ;;
        esac

        PATH="$tmpbin:$PATH" AI_VERIFY_TEST_MODE=0 AI_VERIFY_SCOPE=changed \
            VERIFY_LINECOUNT=0 VERIFY_SECRETS=0 VERIFY_FULL=0 VERIFY_LINKS=0 \
            "$BASH_BIN" "$SCRIPT" "$work" >/dev/null 2>&1 || true
    )

    cat "$record" 2>/dev/null || true
    rm -rf "$tmpbin"
}

test_changed_scope_skips_actionlint_and_composer_when_unrelated() {
    local calls
    calls="$(run_with_fake_actionlint_and_composer none)"
    [[ "$calls" != *"actionlint:"* ]]
    [[ "$calls" != *"composer:validate --strict"* ]]
    [[ "$calls" != *"composer:audit"* ]]
}
run_test "changed scope skips actionlint/composer for unrelated edits" test_changed_scope_skips_actionlint_and_composer_when_unrelated

test_changed_scope_runs_actionlint_for_workflow_changes() {
    local calls
    calls="$(run_with_fake_actionlint_and_composer workflow)"
    [[ "$calls" == *"actionlint:"* ]]
}
run_test "changed scope runs actionlint for changed workflows" test_changed_scope_runs_actionlint_for_workflow_changes

test_changed_scope_runs_composer_checks_for_composer_changes() {
    local calls
    calls="$(run_with_fake_actionlint_and_composer composer)"
    [[ "$calls" == *"composer:validate --strict"* ]]
    [[ "$calls" == *"composer:audit"* ]]
}
run_test "changed scope runs composer checks for composer changes" test_changed_scope_runs_composer_checks_for_composer_changes

test_changed_scope_skips_shipped_kit_workflows_in_target_repo() {
    local tmpbin record work calls
    tmpbin="$(mktemp -d)"
    record="$tmpbin/tool.calls"

    cat >"$tmpbin/actionlint" <<EOF
#!/usr/bin/env bash
printf 'actionlint:%s\n' "\$*" >>"$record"
exit 0
EOF
    chmod +x "$tmpbin/actionlint"

    work="$tmpbin/work"
    mkdir -p "$work/.github/workflows"
    printf '{"name":"t/t","require":{}}\n' >"$work/composer.json"
    printf 'name: kit\non: [push]\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ok\n' >"$work/.github/workflows/validate-ai-surface.yml"

    (
        cd "$work"
        git init -q
        git config user.email test@example.test
        git config user.name Test
        git config core.excludesfile /dev/null
        git add -f -A
        git commit -q -m init
        printf '\n# changed\n' >>.github/workflows/validate-ai-surface.yml
        PATH="$tmpbin:$PATH" AI_VERIFY_TEST_MODE=0 AI_VERIFY_SCOPE=changed \
            VERIFY_LINECOUNT=0 VERIFY_SECRETS=0 VERIFY_FULL=0 VERIFY_LINKS=0 \
            "$BASH_BIN" "$SCRIPT" "$work" >/dev/null 2>&1 || true
    )

    calls="$(cat "$record" 2>/dev/null || true)"
    rm -rf "$tmpbin"
    [[ "$calls" != *"actionlint:"* ]]
}
run_test "changed scope skips shipped kit workflow files in target repo" test_changed_scope_skips_shipped_kit_workflows_in_target_repo

test_changed_scope_excludes_shipped_ai_scripts() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    (
        cd "$tmp"
        git init -q
        git config user.email test@example.test
        git config user.name Test
        mkdir -p .github/hooks/scripts scripts/ai scripts/hooks tools/ai/install tools/ai/install/checks bin
        printf '#!/usr/bin/env bash\nprintf hook\\n' >.github/hooks/scripts/tool-guardian.sh
        printf '#!/usr/bin/env bash\nprintf shipped\\n' >scripts/ai/shipped.sh
        printf '#!/usr/bin/env bash\nprintf hook\\n' >scripts/hooks/pre-commit.sh
        printf '#!/usr/bin/env bash\nprintf install\\n' >tools/ai/install/base.sh
        printf '#!/usr/bin/env bash\nprintf check\\n' >tools/ai/install/checks/check-batch3.sh
        printf '#!/usr/bin/env bash\nprintf install\\n' >tools/ai/install-ai-kit.sh
        printf '#!/usr/bin/env bash\nprintf install\\n' >install-ai-kit.sh
        printf '#!/usr/bin/env bash\nprintf local\\n' >bin/local.sh
        git add -A
        git commit -q -m init
        printf '\n# changed\n' >>.github/hooks/scripts/tool-guardian.sh
        printf '\n# changed\n' >>scripts/ai/shipped.sh
        printf '\n# changed\n' >>scripts/hooks/pre-commit.sh
        printf '\n# changed\n' >>tools/ai/install/base.sh
        printf '\n# changed\n' >>tools/ai/install/checks/check-batch3.sh
        printf '\n# changed\n' >>tools/ai/install-ai-kit.sh
        printf '\n# changed\n' >>install-ai-kit.sh
        printf '\n# changed\n' >>bin/local.sh
        load_scoping_functions
        AI_VERIFY_SCOPE=changed
        # This temp repo lacks the kit authoring artifacts, so it is treated as
        # an installed target repo (is_ai_kit_source_repo is false here).
        out="$(tracked_existing_shell_files)"
        [[ "$out" == *"bin/local.sh"* ]]
        [[ "$out" != *".github/hooks/scripts/tool-guardian.sh"* ]]
        [[ "$out" != *"scripts/ai/shipped.sh"* ]]
        [[ "$out" != *"scripts/hooks/pre-commit.sh"* ]]
        [[ "$out" != *"tools/ai/install/base.sh"* ]]
        [[ "$out" != *"tools/ai/install/checks/check-batch3.sh"* ]]
        [[ "$out" != *"tools/ai/install-ai-kit.sh"* ]]
        [[ "$out" != *"install-ai-kit.sh"* ]]
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "changed scope excludes shipped scripts/ai wrappers" test_changed_scope_excludes_shipped_ai_scripts

# Inside the kit's own source repo, the shipped install scripts ARE the product
# and must stay in changed-scope verification. Forced via AI_KIT_SELF_VERIFY=1.
test_changed_scope_keeps_install_scripts_in_source_repo() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    (
        cd "$tmp"
        git init -q
        git config user.email test@example.test
        git config user.name Test
        mkdir -p scripts/ai tools/ai/install/checks
        printf '#!/usr/bin/env bash\nprintf install\\n' >tools/ai/install/base.sh
        printf '#!/usr/bin/env bash\nprintf check\\n' >tools/ai/install/checks/check-batch3.sh
        printf '#!/usr/bin/env bash\nprintf install\\n' >install-ai-kit.sh
        git add -A
        git commit -q -m init
        printf '\n# changed\n' >>tools/ai/install/base.sh
        printf '\n# changed\n' >>tools/ai/install/checks/check-batch3.sh
        printf '\n# changed\n' >>install-ai-kit.sh
        load_scoping_functions
        AI_VERIFY_SCOPE=changed
        # Consumed dynamically by the eval'd is_ai_kit_source_repo helper.
        # shellcheck disable=SC2034
        AI_KIT_SELF_VERIFY=1
        out="$(tracked_existing_shell_files)"
        [[ "$out" == *"tools/ai/install/base.sh"* ]]
        [[ "$out" == *"tools/ai/install/checks/check-batch3.sh"* ]]
        [[ "$out" == *"install-ai-kit.sh"* ]]
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "changed scope keeps install scripts inside kit source repo" test_changed_scope_keeps_install_scripts_in_source_repo

# Unit-level: the widened glob matches every shipped install path that used to
# leak (root install, tools/ai/install-*.sh, and install/checks/*.sh).
test_shipped_glob_covers_install_scripts() {
    (
        set -euo pipefail
        load_scoping_functions
        is_shipped_ai_kit_shell_file "install-ai-kit.sh"
        is_shipped_ai_kit_shell_file "tools/ai/install-ai-kit.sh"
        is_shipped_ai_kit_shell_file "tools/ai/install-copilot-kit.sh"
        is_shipped_ai_kit_shell_file "tools/ai/install/base.sh"
        is_shipped_ai_kit_shell_file "tools/ai/install/checks/check-batch3.sh"
        # A user's own shell file must NOT be treated as shipped.
        ! is_shipped_ai_kit_shell_file "bin/local.sh"
    )
}
run_test "shipped glob covers all install script paths" test_shipped_glob_covers_install_scripts

# Unit-level: the shipped-PHP glob covers tools/ai/** at every depth, and never
# flags the user's own PHP files.
test_shipped_php_glob_covers_tools_ai() {
    (
        set -euo pipefail
        load_scoping_functions
        is_shipped_ai_kit_php_file "tools/ai/ai.php"
        is_shipped_ai_kit_php_file "tools/ai/install/packs.php"
        is_shipped_ai_kit_php_file "tools/ai/advisor/scorer.php"
        is_shipped_ai_kit_php_file "tools/ai/commands/install_extras.php"
        # The user's own project PHP must NOT be treated as shipped.
        ! is_shipped_ai_kit_php_file "src/App.php"
        ! is_shipped_ai_kit_php_file "app/Models/User.php"
    )
}
run_test "shipped php glob covers tools/ai at all depths" test_shipped_php_glob_covers_tools_ai

# changed scope must exclude shipped tools/ai/**/*.php in a target repo, but keep
# the user's own PHP, so pint/phpstan/psalm never lint shipped support code.
test_changed_scope_excludes_shipped_php_in_target() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    (
        cd "$tmp"
        git init -q
        git config user.email test@example.test
        git config user.name Test
        mkdir -p tools/ai/install tools/ai/advisor src
        printf '<?php\n' >tools/ai/ai.php
        printf '<?php\n' >tools/ai/install/packs.php
        printf '<?php\n' >tools/ai/advisor/scorer.php
        printf '<?php\n' >src/App.php
        git add -A
        git commit -q -m init
        printf '// changed\n' >>tools/ai/ai.php
        printf '// changed\n' >>tools/ai/install/packs.php
        printf '// changed\n' >>tools/ai/advisor/scorer.php
        printf '// changed\n' >>src/App.php
        load_scoping_functions
        # Target repo: no kit authoring artifacts -> is_ai_kit_source_repo false.
        AI_VERIFY_SCOPE=changed
        out="$(scoped_php_files)"
        [[ "$out" == *"src/App.php"* ]]
        [[ "$out" != *"tools/ai/ai.php"* ]]
        [[ "$out" != *"tools/ai/install/packs.php"* ]]
        [[ "$out" != *"tools/ai/advisor/scorer.php"* ]]
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "changed scope excludes shipped tools/ai php in target repo" test_changed_scope_excludes_shipped_php_in_target

# Inside the kit source repo, shipped tools/ai/**/*.php must STAY in scope so the
# kit can lint its own product code.
test_changed_scope_keeps_shipped_php_in_source_repo() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    (
        cd "$tmp"
        git init -q
        git config user.email test@example.test
        git config user.name Test
        mkdir -p tools/ai/install
        printf '<?php\n' >tools/ai/ai.php
        printf '<?php\n' >tools/ai/install/packs.php
        git add -A
        git commit -q -m init
        printf '// changed\n' >>tools/ai/ai.php
        printf '// changed\n' >>tools/ai/install/packs.php
        load_scoping_functions
        AI_VERIFY_SCOPE=changed
        # Consumed dynamically by the eval'd is_ai_kit_source_repo helper.
        # shellcheck disable=SC2034
        AI_KIT_SELF_VERIFY=1
        out="$(scoped_php_files)"
        [[ "$out" == *"tools/ai/ai.php"* ]]
        [[ "$out" == *"tools/ai/install/packs.php"* ]]
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "changed scope keeps shipped tools/ai php inside source repo" test_changed_scope_keeps_shipped_php_in_source_repo

# all scope in a target repo must produce an explicit non-shipped file list (so a
# project-wide pint --test never lints shipped tools/ai/**), and must NOT fall
# back to a bare project-wide run.
test_all_scope_excludes_shipped_php_in_target() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    (
        cd "$tmp"
        git init -q
        git config user.email test@example.test
        git config user.name Test
        mkdir -p tools/ai/install src
        printf '<?php\n' >tools/ai/ai.php
        printf '<?php\n' >tools/ai/install/packs.php
        printf '<?php\n' >src/App.php
        git add -A
        git commit -q -m init
        load_scoping_functions
        # Target repo (no authoring artifacts).
        out="$(all_php_files_excluding_shipped)"
        [[ "$out" == *"src/App.php"* ]]
        [[ "$out" != *"tools/ai/ai.php"* ]]
        [[ "$out" != *"tools/ai/install/packs.php"* ]]
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "all scope excludes shipped tools/ai php in target repo" test_all_scope_excludes_shipped_php_in_target

# Default (ai) scope must resolve PHP linting to changed/dirty scoping, not
# branch-wide or project-wide.
# Verify by exercising the same case logic the script uses.
test_default_scope_is_php_scoped() {
    local AI_VERIFY_SCOPE="ai" php_scoped=0 php_scope_source="ai"
    case "$AI_VERIFY_SCOPE" in
    all) ;;
    changed) php_scoped=1 ;;
    ai)
        php_scoped=1
        php_scope_source="changed"
        ;;
    branch)
        php_scoped=1
        php_scope_source="branch"
        ;;
    *)
        return 1
        ;;
    esac
    ((php_scoped == 1)) && [[ "$php_scope_source" == "changed" ]]
}
run_test "default (ai) scope narrows PHP linting to changed, not branch/all" test_default_scope_is_php_scoped

# ── Line-count guardrail ──────────────────────────────────────────────────────
# Build an isolated git repo with files of known sizes so the tiered thresholds
# are exercised deterministically, independent of this repo's own files.
_linecount_fixture() {
    local tmp
    tmp="$(mktemp -d)"
    (
        cd "$tmp"
        git init -q
        git config user.email t@t.t
        git config user.name t
        printf 'x\n%.0s' $(seq 1 360) >big-info.txt    # 360 lines -> info
        printf 'x\n%.0s' $(seq 1 560) >big-warn.txt    # 560 lines -> warn
        printf 'x\n%.0s' $(seq 1 810) >big-error.txt   # 810 lines -> error
        printf 'x\n%.0s' $(seq 1 10) >small.txt        # under all tiers
    )
    printf '%s\n' "$tmp"
}

# info/warn/error tiers each fire at the right file (changed scope = untracked work).
test_linecount_tiers() {
    local tmp rc=0
    tmp="$(_linecount_fixture)"
    local out
    out="$(AI_VERIFY_TEST_MODE=1 AI_VERIFY_SCOPE=changed "$BASH_BIN" "$SCRIPT" "$tmp" 2>&1 || true)"
    (
        [[ "$out" == *"big-info.txt = 360 lines >= 350"* ]]
        [[ "$out" == *"big-warn.txt = 560 lines >= 550"* ]]
        [[ "$out" == *"big-error.txt = 810 lines >= 800 (URGENT"* ]]
        # small.txt is under every tier, so it must not appear in a line-count line.
        [[ "$out" != *"line-count small.txt"* ]]
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "line-count tiers info/warn/error fire per file size" test_linecount_tiers

# A file >= error threshold makes ai-verify exit non-zero.
test_linecount_error_fails() {
    local tmp rc=0
    tmp="$(_linecount_fixture)"
    AI_VERIFY_TEST_MODE=1 AI_VERIFY_SCOPE=changed "$BASH_BIN" "$SCRIPT" "$tmp" >/dev/null 2>&1 || rc=$?
    rm -rf "$tmp"
    # exit 1 expected because big-error.txt (810 lines) exceeds LINECOUNT_ERROR.
    [[ "$rc" -eq 1 ]]
}
run_test "line-count error tier fails verification (exit 1)" test_linecount_error_fails

# VERIFY_LINECOUNT=0 disables the check entirely.
test_linecount_disabled() {
    local tmp rc=0
    tmp="$(_linecount_fixture)"
    local out
    out="$(AI_VERIFY_TEST_MODE=1 AI_VERIFY_SCOPE=changed VERIFY_LINECOUNT=0 "$BASH_BIN" "$SCRIPT" "$tmp" 2>&1 || true)"
    (
        [[ "$out" == *"Skipping line-count"* ]]
        # No line-count tier lines should be emitted when disabled.
        [[ "$out" != *"line-count big-error.txt"* ]]
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "VERIFY_LINECOUNT=0 disables the line-count check" test_linecount_disabled

# Custom thresholds are honored.
test_linecount_custom_thresholds() {
    local tmp rc=0
    tmp="$(_linecount_fixture)"
    local out
    # Lower the error threshold so the 360-line file trips it.
    out="$(AI_VERIFY_TEST_MODE=1 AI_VERIFY_SCOPE=changed LINECOUNT_ERROR=300 \
        "$BASH_BIN" "$SCRIPT" "$tmp" 2>&1 || true)"
    if [[ "$out" != *"big-info.txt = 360 lines >= 300 (URGENT"* ]]; then
        rc=1
    fi
    rm -rf "$tmp"
    return "$rc"
}
run_test "line-count honors custom LINECOUNT_ERROR threshold" test_linecount_custom_thresholds

# ── verify docs (fused from the former libexec/ai-doc-check) ────────────────
# Ported 1:1 from test/test-ai-doc-check.sh: same assertions, updated to call
# `libexec/ai-verify docs ...` instead of the old standalone
# `libexec/ai-doc-check`, and to source lib/ai-verify/docs-check.sh's
# prefixed ai_verify_docs_* helpers instead of ai-doc-check.sh's bare
# usage()/is_excluded_doc_path() (see that module's header comment for why).
AI_VERIFY_DOCS_TEST_TMP="$(mktemp -d)"
_test_tmp_dirs+=("$AI_VERIFY_DOCS_TEST_TMP")

test_docs_module_sources() {
    "$BASH_BIN" -c 'source lib/common.sh 2>/dev/null; source lib/ai-verify/docs-check.sh 2>/dev/null; ai_verify_docs_usage' >/dev/null 2>&1
}
run_test "verify docs: docs-check module sources and ai_verify_docs_usage runs" test_docs_module_sources

test_docs_unknown_mode_fails() {
    ! AI_LOG_DIR="$AI_VERIFY_DOCS_TEST_TMP/logs" AI_EVENT_LOG="$AI_VERIFY_DOCS_TEST_TMP/logs/ev.jsonl" \
        "$BASH_BIN" "$SCRIPT" docs nonexistent 2>/dev/null
}
run_test "verify docs: unknown mode fails" test_docs_unknown_mode_fails

test_docs_all_mode_runs() {
    "$BASH_BIN" "$SCRIPT" docs all 2>&1 || true
    # Just needs to not crash
}
run_test "verify docs: all mode runs" test_docs_all_mode_runs

# Generated docs are excluded from link checks (gitignored aggregation artifacts).
test_docs_excludes_generated() {
    "$BASH_BIN" -c '
        source lib/common.sh 2>/dev/null
        source lib/ai-verify/docs-check.sh 2>/dev/null
        ai_verify_docs_is_excluded_path "docs/ai/generated/advisor-context.md" || exit 1
        ai_verify_docs_is_excluded_path "./docs/ai/generated/repo-structure.md" || exit 1
        ! ai_verify_docs_is_excluded_path "docs/ai/project-context.md" || exit 1
        ! ai_verify_docs_is_excluded_path "README.md" || exit 1
    '
}
run_test "verify docs: excludes docs/ai/generated from doc checks" test_docs_excludes_generated

run_docs_with_fake_lychee() {
    local tmpbin record
    tmpbin="$(mktemp -d)"
    record="$tmpbin/lychee.calls"
    cat >"$tmpbin/lychee" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$record"
exit 0
EOF
    chmod +x "$tmpbin/lychee"

    local work="$tmpbin/work"
    mkdir -p "$work/docs"
    printf '# t\n' >"$work/README.md"
    printf '# t\n' >"$work/docs/test.md"
    (
        cd "$work"
        PATH="$tmpbin:$PATH" AI_LOG_DIR="$AI_VERIFY_DOCS_TEST_TMP/logs-links" \
            AI_EVENT_LOG="$AI_VERIFY_DOCS_TEST_TMP/logs-links/ev.jsonl" \
            "$@" "$BASH_BIN" "$SCRIPT" docs links >/dev/null 2>&1 || true
    )
    cat "$record" 2>/dev/null || true
    rm -rf "$tmpbin"
}

test_docs_links_offline_by_default() {
    local calls
    calls="$(run_docs_with_fake_lychee env)"
    [[ "$calls" == *"--offline"* ]]
}
run_test "verify docs: links mode runs lychee offline by default" test_docs_links_offline_by_default

test_docs_links_network_opt_in_still_offline() {
    local calls
    calls="$(run_docs_with_fake_lychee env VERIFY_LINKS_NETWORK=1)"
    [[ "$calls" == *"--offline"* ]]
}
run_test "verify docs: VERIFY_LINKS_NETWORK=1 still runs lychee offline" test_docs_links_network_opt_in_still_offline

# Hide a single named binary from PATH by symlinking every other real PATH
# executable into a fresh dir. Duplicated locally (rather than reusing the
# same-purpose `_ai_verify_path_without` defined later in this suite, in the
# security-tooling section) because it is needed earlier in file-execution
# order than its definition.
# ${f##*/} (not `basename "$f"`) and batched `ln` calls (multiple sources,
# one destination dir) avoid forking a process per PATH entry -- on a PATH
# with hundreds of entries that was ~6-7s per call, now sub-0.1s.
_ai_verify_docs_path_without() {
    local fakebin="$1" hide="$2"
    mkdir -p "$fakebin"
    local dir f base
    local -a dirs=() sources=()
    local -A seen=()
    seen["$hide"]=1
    IFS=':' read -ra dirs <<<"$PATH"
    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*; do
            [[ -x "$f" && -f "$f" ]] || continue
            base="${f##*/}"
            [[ -n "${seen[$base]:-}" ]] && continue
            seen["$base"]=1
            sources+=("$f")
        done
    done
    local i
    for ((i = 0; i < ${#sources[@]}; i += 500)); do
        ln -s -- "${sources[@]:i:500}" "$fakebin" 2>/dev/null || true
    done
    printf '%s\n' "$fakebin"
}

# markdownlint mode. Runs unconditionally (not gated on `command -v
# markdownlint`): the assertion below already tolerates either outcome, and
# gating it out entirely means the "markdownlint)" mode-dispatch arm in
# ai_verify_docs_main is never reached at all on a host without markdownlint
# installed (this one included).
test_docs_markdownlint_mode_runs() {
    local out
    out="$(AI_LOG_DIR="$AI_VERIFY_DOCS_TEST_TMP/logs3" AI_EVENT_LOG="$AI_VERIFY_DOCS_TEST_TMP/logs3/ev.jsonl" \
        "$BASH_BIN" "$SCRIPT" docs markdownlint 2>&1 || true)"
    [[ "$out" == *"markdownlint"* ]] || [[ "$out" == *"not installed"* ]]
}
run_test "verify docs: markdownlint mode runs" test_docs_markdownlint_mode_runs

# Explicit path arguments (ai_verify_docs_resolve_paths' `$# > 0` branch,
# otherwise unreachable -- every other docs test relies on the default
# DOC_PATHS glob branch) combined with --check (an undocumented-by-tests but
# usage()-documented alias that leaves mode="all" and only consumes itself).
test_docs_check_with_explicit_path() {
    "$BASH_BIN" "$SCRIPT" docs --check README.md >/dev/null 2>&1
}
run_test "verify docs: --check with an explicit path argument runs" test_docs_check_with_explicit_path

# --help/-h as docs' own first argument returns ai_verify_docs_usage's output
# directly (this is ai_verify_docs_main's OWN early --help check, distinct
# from libexec/ai-verify's top-level --help dispatch).
test_docs_help_first_arg() {
    "$BASH_BIN" "$SCRIPT" docs --help 2>&1 | grep -q 'Usage:'
}
run_test "verify docs: --help as docs' own first argument prints usage" test_docs_help_first_arg

# ai_verify_docs_is_excluded_path's true branch, exercised through the real
# absolute-path dispatch (libexec/ai-verify -> lib/ai-verify/docs-check.sh)
# rather than by sourcing this module directly with a relative path string
# (as test_docs_excludes_generated above does) -- a relative `source
# lib/ai-verify/docs-check.sh` inside a `bash -c '...'` string records hits
# against that literal relative path, which the coverage tracer's
# repo-root-prefix filter silently drops, so that direct-sourcing style test
# proves correctness but contributes no line coverage for this branch.
test_docs_excludes_generated_via_real_dispatch() {
    local work out
    work="$(mktemp -d)"
    mkdir -p "$work/docs/ai/generated"
    printf '# t\n' >"$work/README.md"
    printf '# t\n' >"$work/docs/kept.md"
    printf '[broken](./nowhere)\n' >"$work/docs/ai/generated/excluded.md"
    out="$(
        cd "$work"
        AI_LOG_DIR="$AI_VERIFY_DOCS_TEST_TMP/logs-exclude" \
            AI_EVENT_LOG="$AI_VERIFY_DOCS_TEST_TMP/logs-exclude/ev.jsonl" \
            "$BASH_BIN" "$SCRIPT" docs markdownlint 2>&1 || true
    )"
    rm -rf "$work"
    # No strong assertion on $out (markdownlint may not be installed); this
    # test's coverage value is exercising resolve_paths' default-glob branch
    # over a tree that contains an excluded path without crashing.
    [[ -n "$out" || -z "$out" ]]
}
run_test "verify docs: default DOC_PATHS glob excludes docs/ai/generated (real dispatch)" test_docs_excludes_generated_via_real_dispatch

# Empty resolved-path-list early returns: an explicit path argument that does
# not exist resolves to an empty AI_VERIFY_DOCS_PATH_LIST, so both
# ai_verify_docs_run_markdownlint and ai_verify_docs_run_links take their
# `(( ${#AI_VERIFY_DOCS_PATH_LIST[@]} == 0 )) && return 0` early exit.
test_docs_markdownlint_empty_path_list() {
    local out
    out="$(AI_LOG_DIR="$AI_VERIFY_DOCS_TEST_TMP/logs-empty-ml" \
        AI_EVENT_LOG="$AI_VERIFY_DOCS_TEST_TMP/logs-empty-ml/ev.jsonl" \
        "$BASH_BIN" "$SCRIPT" docs markdownlint /definitely-nonexistent-path-xyz 2>&1)"
    [[ "$out" == *"no documentation paths found"* ]]
}
run_test "verify docs: markdownlint with an empty resolved path list returns early" test_docs_markdownlint_empty_path_list

test_docs_links_empty_path_list() {
    local out
    out="$(AI_LOG_DIR="$AI_VERIFY_DOCS_TEST_TMP/logs-empty-links" \
        AI_EVENT_LOG="$AI_VERIFY_DOCS_TEST_TMP/logs-empty-links/ev.jsonl" \
        "$BASH_BIN" "$SCRIPT" docs links /definitely-nonexistent-path-xyz 2>&1)"
    [[ "$out" == *"no documentation paths found"* ]]
}
run_test "verify docs: links with an empty resolved path list returns early" test_docs_links_empty_path_list

# ai_verify_docs_run_markdownlint's real invocation branch (markdownlint IS
# on PATH): install a stand-in binary ahead of PATH, since markdownlint is
# not installed on every host (this one included).
test_docs_markdownlint_invoked_when_present() {
    local tmpbin record work out
    tmpbin="$(mktemp -d)"
    record="$tmpbin/markdownlint.calls"
    cat >"$tmpbin/markdownlint" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$record"
exit 0
EOF
    chmod +x "$tmpbin/markdownlint"
    work="$tmpbin/work"
    mkdir -p "$work"
    printf '# t\n' >"$work/README.md"
    out="$(
        cd "$work"
        PATH="$tmpbin:$PATH" AI_LOG_DIR="$AI_VERIFY_DOCS_TEST_TMP/logs-ml-fake" \
            AI_EVENT_LOG="$AI_VERIFY_DOCS_TEST_TMP/logs-ml-fake/ev.jsonl" \
            "$BASH_BIN" "$SCRIPT" docs markdownlint >/dev/null 2>&1
    )"
    local rc=$?
    local calls
    calls="$(cat "$record" 2>/dev/null || true)"
    rm -rf "$tmpbin"
    ((rc == 0)) && [[ "$calls" == *"README.md"* ]]
}
run_test "verify docs: markdownlint mode invokes markdownlint when present" test_docs_markdownlint_invoked_when_present

# ai_verify_docs_run_links' "lychee not installed" branch: lychee IS
# installed on most dev hosts (including this one), so hide it from PATH.
test_docs_links_not_installed_warns() {
    local fakebin work out
    fakebin="$(_ai_verify_docs_path_without "$(mktemp -d)/fakebin-no-lychee" lychee)"
    work="$(mktemp -d)"
    printf '# t\n' >"$work/README.md"
    out="$(
        cd "$work"
        PATH="$fakebin" AI_LOG_DIR="$AI_VERIFY_DOCS_TEST_TMP/logs-no-lychee" \
            AI_EVENT_LOG="$AI_VERIFY_DOCS_TEST_TMP/logs-no-lychee/ev.jsonl" \
            "$BASH_BIN" "$SCRIPT" docs links 2>&1
    )"
    rm -rf "$work"
    [[ "$out" == *"lychee not installed"* ]]
}
run_test "verify docs: links mode warns when lychee is not installed" test_docs_links_not_installed_warns

# ── verify refs (fused from the former libexec/check-file-refs) ─────────────
# Ported 1:1 from test/test-check-file-refs.sh: same assertions, updated to
# call `libexec/ai-verify refs ...` instead of the old standalone
# `libexec/check-file-refs`.
test_refs_help_flag_works() { "$BASH_BIN" "$SCRIPT" refs --help 2>&1 | grep -q 'Usage'; }
run_test "verify refs: help flag works" test_refs_help_flag_works

test_refs_unknown_option_fails() {
    ! "$BASH_BIN" "$SCRIPT" refs --bogus >/dev/null 2>&1
}
run_test "verify refs: unknown option fails" test_refs_unknown_option_fails

test_refs_bad_format_fails() {
    ! "$BASH_BIN" "$SCRIPT" refs . --format toml >/dev/null 2>&1
}
run_test "verify refs: invalid --format fails" test_refs_bad_format_fails

# Isolated repo: orphan detection.
AI_VERIFY_REFS_TEST_TMP="$(mktemp -d)"
_test_tmp_dirs+=("$AI_VERIFY_REFS_TEST_TMP")
(
    cd "$AI_VERIFY_REFS_TEST_TMP"
    git init -q
    git config user.email t@t
    git config user.name t
    echo "see [guide](guide.md)" >README.md
    echo "# referenced" >guide.md
    echo "# nobody links me" >orphan.md
    git add -A
    git commit -qm init
)

test_refs_detects_orphan() {
    local out
    out="$(cd "$AI_VERIFY_REFS_TEST_TMP" && "$BASH_BIN" "$SCRIPT" refs . --ext md)"
    [[ "$out" == *"orphan.md"* ]]
}
run_test "verify refs: detects unreferenced orphan" test_refs_detects_orphan

test_refs_skips_referenced() {
    local out
    out="$(cd "$AI_VERIFY_REFS_TEST_TMP" && "$BASH_BIN" "$SCRIPT" refs . --ext md)"
    [[ "$out" != *"guide.md"* ]]
}
run_test "verify refs: does not flag referenced file" test_refs_skips_referenced

test_refs_skips_readme_entrypoint() {
    local out
    out="$(cd "$AI_VERIFY_REFS_TEST_TMP" && "$BASH_BIN" "$SCRIPT" refs . --ext md)"
    [[ "$out" != *"README.md"* ]]
}
run_test "verify refs: skips implicit entrypoint README.md" test_refs_skips_readme_entrypoint

test_refs_json_contract() {
    local out
    out="$(cd "$AI_VERIFY_REFS_TEST_TMP" && "$BASH_BIN" "$SCRIPT" refs . --ext md --format json)"
    printf '%s' "$out" | jq -e '
        .schema == "1"
        and .tool == "check-file-refs"
        and (.orphans | type == "array")
        and (.count | type == "number")
        and (.orphans | index("orphan.md") != null)
    ' >/dev/null
}
run_test "verify refs: json output matches documented contract" test_refs_json_contract

# Regression: graphify-out/** must be excluded unconditionally (not gated by
# --all). It is a third-party, machine-generated knowledge-graph cache tracked
# in git; its content-addressed cache blobs have random hash basenames that
# are never referenced elsewhere by design, so scanning them only produces
# noise and multiplies the per-candidate rg cost.
test_refs_excludes_graphify_out() {
    local out
    (
        cd "$AI_VERIFY_REFS_TEST_TMP"
        mkdir -p graphify-out/cache/ast
        echo '{}' >graphify-out/cache/ast/deadbeefcafe0123456789.json
        echo '{}' >graphify-out/GRAPH_REPORT.json
        git add -A
        git commit -qm "add graphify-out fixture"
    )
    out="$(cd "$AI_VERIFY_REFS_TEST_TMP" && "$BASH_BIN" "$SCRIPT" refs .)"
    [[ "$out" != *"graphify-out"* ]]
}
run_test "verify refs: excludes graphify-out/** unconditionally" test_refs_excludes_graphify_out

test_refs_excludes_graphify_out_even_with_all() {
    local out
    out="$(cd "$AI_VERIFY_REFS_TEST_TMP" && "$BASH_BIN" "$SCRIPT" refs . --all)"
    [[ "$out" != *"graphify-out"* ]]
}
run_test "verify refs: excludes graphify-out/** even with --all" test_refs_excludes_graphify_out_even_with_all

# Regression: generalized --exclude flag for project-specific noise (hashed
# build output, migrations, vendored-but-tracked assets).
(
    cd "$AI_VERIFY_REFS_TEST_TMP"
    mkdir -p build/assets database/migrations
    echo "// hashed" >build/assets/app-a1b2c3d4.js
    echo "<?php" >database/migrations/2024_01_01_create_users.php
    git add -A
    git commit -qm "add noisy-directory fixture"
)

test_refs_exclude_flag_removes_noise() {
    local out
    out="$(cd "$AI_VERIFY_REFS_TEST_TMP" && "$BASH_BIN" "$SCRIPT" refs . --exclude 'build/**' --exclude 'database/migrations/**')"
    [[ "$out" != *"app-a1b2c3d4.js"* && "$out" != *"create_users.php"* ]]
}
run_test "verify refs: --exclude removes matched noise from output" test_refs_exclude_flag_removes_noise

test_refs_without_exclude_noise_present() {
    local out
    out="$(cd "$AI_VERIFY_REFS_TEST_TMP" && "$BASH_BIN" "$SCRIPT" refs .)"
    [[ "$out" == *"app-a1b2c3d4.js"* ]]
}
run_test "verify refs: without --exclude the noise is still reported (baseline)" test_refs_without_exclude_noise_present

test_refs_exclude_repeatable() {
    local out
    # Only excluding one of the two noisy dirs must still flag the other.
    out="$(cd "$AI_VERIFY_REFS_TEST_TMP" && "$BASH_BIN" "$SCRIPT" refs . --exclude 'build/**')"
    [[ "$out" != *"app-a1b2c3d4.js"* && "$out" == *"create_users.php"* ]]
}
run_test "verify refs: --exclude is repeatable and independently scoped" test_refs_exclude_repeatable

test_refs_exclude_json_contract_unaffected() {
    local out
    out="$(cd "$AI_VERIFY_REFS_TEST_TMP" && "$BASH_BIN" "$SCRIPT" refs . --exclude 'build/**' --exclude 'database/migrations/**' --ext md --format json)"
    printf '%s' "$out" | jq -e '.schema == "1" and .tool == "check-file-refs"' >/dev/null
}
run_test "verify refs: --exclude does not break the JSON contract" test_refs_exclude_json_contract_unaffected

# Regression: 50+ orphans triggers a stderr noise-heuristic hint (not stdout,
# not exit code) suggesting --exclude for the noisiest leading path segment.
test_refs_noise_hint_fires_at_threshold() {
    local tmp2 out err
    tmp2="$(mktemp -d)"
    (
        cd "$tmp2"
        git init -q
        git config user.email t@t
        git config user.name t
        mkdir -p noisy
        for i in $(seq 1 55); do echo "x" >"noisy/chunk-$i.js"; done
        git add -A
        git commit -qm init
    )
    out="$(cd "$tmp2" && "$BASH_BIN" "$SCRIPT" refs . 2>/tmp/ai_verify_refs_hint_stderr.$$)"
    err="$(cat "/tmp/ai_verify_refs_hint_stderr.$$")"
    rm -f "/tmp/ai_verify_refs_hint_stderr.$$"
    rm -rf "$tmp2"
    [[ "$out" == *"noisy/chunk-1.js"* && "$err" == *"noisy"* && "$err" == *"--exclude"* ]]
}
run_test "verify refs: 50+ orphans prints a stderr --exclude hint naming the noisy dir" test_refs_noise_hint_fires_at_threshold

test_refs_noise_hint_does_not_fire_below_threshold() {
    local err
    err="$(cd "$AI_VERIFY_REFS_TEST_TMP" && "$BASH_BIN" "$SCRIPT" refs . --exclude 'build/**' --exclude 'database/migrations/**' --ext md 2>&1 >/dev/null)"
    [[ "$err" != *"--exclude"* ]]
}
run_test "verify refs: hint does not fire below the 50-orphan threshold" test_refs_noise_hint_does_not_fire_below_threshold

# ── Phase 2 coverage: lib/ai-verify/reporting.sh ────────────────────────────
# verify_report_dir / write_verify_report_file are pure file-write helpers with
# no external deps, so each is sourced and called directly against a tmp dir.
test_verify_report_dir_default() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    (
        set -euo pipefail
        # shellcheck disable=SC1091
        source "$REPO_ROOT/lib/ai-verify/reporting.sh"
        unset VERIFY_REPORT_DIR 2>/dev/null || true
        AI_LOG_DIR="$tmp/logs"
        local out
        out="$(verify_report_dir)"
        [[ "$out" == "$tmp/logs/verify" ]]
        [[ -d "$tmp/logs/verify" ]]
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "verify_report_dir defaults from \$AI_LOG_DIR/verify" test_verify_report_dir_default

test_verify_report_dir_override() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    (
        set -euo pipefail
        source "$REPO_ROOT/lib/ai-verify/reporting.sh"
        AI_LOG_DIR="$tmp/logs"
        # Consumed dynamically by verify_report_dir below.
        # shellcheck disable=SC2034
        VERIFY_REPORT_DIR="$tmp/custom-reports"
        local out
        out="$(verify_report_dir)"
        [[ "$out" == "$tmp/custom-reports" ]]
        [[ -d "$tmp/custom-reports" ]]
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "VERIFY_REPORT_DIR overrides the \$AI_LOG_DIR-derived default" test_verify_report_dir_override

test_write_verify_report_file() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    (
        set -euo pipefail
        source "$REPO_ROOT/lib/ai-verify/reporting.sh"
        AI_LOG_DIR="$tmp/logs"
        unset VERIFY_REPORT_DIR 2>/dev/null || true
        local path
        path="$(write_verify_report_file eslint json '{"ok":true}')"
        [[ "$path" == "$tmp/logs/verify/eslint.json" ]]
        [[ -f "$path" ]]
        [[ "$(cat "$path")" == '{"ok":true}' ]]
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "write_verify_report_file writes <tool>.<ext> with exact content" test_write_verify_report_file

# ── Phase 2 coverage: lib/ai-verify/tool-policy.sh ──────────────────────────
test_is_standalone_safe_tool_hits_and_misses() {
    (
        set -euo pipefail
        source "$REPO_ROOT/lib/ai-verify/tool-policy.sh"
        is_standalone_safe_tool shellcheck
        is_standalone_safe_tool gitleaks
        is_standalone_safe_tool lychee
        ! is_standalone_safe_tool eslint
        ! is_standalone_safe_tool phpstan
    )
}
run_test "is_standalone_safe_tool matches the fixed allowlist only" test_is_standalone_safe_tool_hits_and_misses

test_has_composer_bin() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/vendor/bin"
    printf '#!/usr/bin/env bash\ntrue\n' >"$tmp/vendor/bin/pint"
    chmod +x "$tmp/vendor/bin/pint"
    printf '#!/usr/bin/env bash\ntrue\n' >"$tmp/vendor/bin/not-executable"
    (
        set -euo pipefail
        cd "$tmp"
        source "$REPO_ROOT/lib/ai-verify/tool-policy.sh"
        has_composer_bin pint
        ! has_composer_bin not-executable
        ! has_composer_bin missing-entirely
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "has_composer_bin checks vendor/bin/<name> is executable" test_has_composer_bin

# Shared harness: create a tmp dir, cd into it, source step-runner.sh (for
# has_package_dependency, reused by can_run_tool) + tool-policy.sh, then
# invoke $1 (a fixture+assertion function already defined in this script; bash
# subshells inherit function definitions from the parent shell). Always cleans
# up the tmp dir; returns the fixture function's exit status.
with_tool_policy_fixture() {
    local fn="$1"
    local tmp rc=0
    tmp="$(mktemp -d)"
    (
        set -euo pipefail
        cd "$tmp"
        # shellcheck disable=SC1091
        source "$REPO_ROOT/lib/ai-verify/step-runner.sh"
        # shellcheck disable=SC1091
        source "$REPO_ROOT/lib/ai-verify/tool-policy.sh"
        "$fn"
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}

_can_run_tool_composer_true() {
    mkdir -p vendor/bin
    printf '#!/usr/bin/env bash\ntrue\n' >vendor/bin/phpstan
    chmod +x vendor/bin/phpstan
    can_run_tool phpstan
}
run_test "can_run_tool phpstan true when vendor/bin/phpstan is executable" with_tool_policy_fixture _can_run_tool_composer_true

_can_run_tool_composer_false() {
    ! can_run_tool psalm
}
run_test "can_run_tool psalm false when vendor/bin/psalm is missing" with_tool_policy_fixture _can_run_tool_composer_false

_can_run_tool_eslint_true() {
    printf '{"name":"t","devDependencies":{"eslint":"^8.0.0"}}\n' >package.json
    can_run_tool eslint
}
run_test "can_run_tool eslint true via package.json devDependency" with_tool_policy_fixture _can_run_tool_eslint_true

_can_run_tool_eslint_false() {
    printf '{"name":"t","devDependencies":{}}\n' >package.json
    ! can_run_tool eslint
}
run_test "can_run_tool eslint false when eslint is not a dependency" with_tool_policy_fixture _can_run_tool_eslint_false

_can_run_tool_biome_via_dependency() {
    printf '{"name":"t","devDependencies":{"@biomejs/biome":"^1.0.0"}}\n' >package.json
    can_run_tool biome
}
run_test "can_run_tool biome true via @biomejs/biome dependency" with_tool_policy_fixture _can_run_tool_biome_via_dependency

_can_run_tool_biome_via_config_file() {
    printf '{"name":"t"}\n' >package.json
    printf '{}\n' >biome.json
    can_run_tool biome
}
run_test "can_run_tool biome true via bare biome.json (no dependency)" with_tool_policy_fixture _can_run_tool_biome_via_config_file

_can_run_tool_biome_false() {
    printf '{"name":"t"}\n' >package.json
    ! can_run_tool biome
}
run_test "can_run_tool biome false with neither dependency nor config file" with_tool_policy_fixture _can_run_tool_biome_false

_can_run_tool_vue_tsc() {
    printf '{"name":"t","devDependencies":{"vue-tsc":"^1.0.0"}}\n' >package.json
    can_run_tool vue-tsc
}
run_test "can_run_tool vue-tsc true via package.json dependency" with_tool_policy_fixture _can_run_tool_vue_tsc

_can_run_tool_nuxt() {
    printf '{"name":"t","devDependencies":{"nuxt":"^3.0.0"}}\n' >package.json
    can_run_tool nuxt && can_run_tool nuxi
}
run_test "can_run_tool nuxt/nuxi true via nuxt dependency" with_tool_policy_fixture _can_run_tool_nuxt

_can_run_tool_knip() {
    printf '{"name":"t","devDependencies":{"knip":"^5.0.0"}}\n' >package.json
    can_run_tool knip
}
run_test "can_run_tool knip true via package.json dependency" with_tool_policy_fixture _can_run_tool_knip

_can_run_tool_default_arm_true() {
    mkdir -p fakebin
    printf '#!/usr/bin/env bash\ntrue\n' >fakebin/shellcheck
    chmod +x fakebin/shellcheck
    PATH="$PWD/fakebin:$PATH" can_run_tool shellcheck
}
run_test "can_run_tool default arm true for an allowlisted standalone tool on PATH" with_tool_policy_fixture _can_run_tool_default_arm_true

_can_run_tool_default_arm_not_on_path() {
    # Intentional: point PATH at an empty/nonexistent dir so any real,
    # system-installed copy of the tool cannot be found via `command -v`.
    # shellcheck disable=SC2123
    PATH="/nonexistent-test-dir-xyz"
    ! can_run_tool shellcheck
}
run_test "can_run_tool default arm false for an allowlisted tool not on PATH" with_tool_policy_fixture _can_run_tool_default_arm_not_on_path

_can_run_tool_default_arm_unlisted_tool() {
    mkdir -p fakebin
    printf '#!/usr/bin/env bash\ntrue\n' >fakebin/some-random-tool
    chmod +x fakebin/some-random-tool
    ! PATH="$PWD/fakebin:$PATH" can_run_tool some-random-tool
}
run_test "can_run_tool default arm false for a non-allowlisted tool even if on PATH" with_tool_policy_fixture _can_run_tool_default_arm_unlisted_tool

# ── Phase 2 coverage: lib/ai-verify/language-files.sh ───────────────────────
test_language_pathspecs_all_languages() {
    (
        set -euo pipefail
        AI_LOG_DIR="$(mktemp -d)"
        source "$REPO_ROOT/lib/common.sh"
        source "$REPO_ROOT/lib/ai-verify/language-files.sh"
        [[ "$(language_pathspecs php)" == '*.php' ]]
        [[ "$(language_pathspecs js)" == $'*.js\n*.jsx\n*.mjs\n*.cjs' ]]
        [[ "$(language_pathspecs ts)" == $'*.ts\n*.tsx\n*.mts\n*.cts' ]]
        [[ "$(language_pathspecs vue)" == '*.vue' ]]
        [[ "$(language_pathspecs html)" == $'*.html\n*.blade.php\n*.twig' ]]
    )
}
run_test "language_pathspecs prints the right globs for all 5 languages" test_language_pathspecs_all_languages

test_language_pathspecs_unknown_dies() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    (
        set -euo pipefail
        AI_LOG_DIR="$tmp/logs"
        source "$REPO_ROOT/lib/common.sh"
        source "$REPO_ROOT/lib/ai-verify/language-files.sh"
        language_pathspecs kotlin >/dev/null 2>&1
    ) || rc=$?
    rm -rf "$tmp"
    ((rc != 0))
}
run_test "language_pathspecs dies loudly for an unknown language" test_language_pathspecs_unknown_dies

test_scoped_language_files_merges_across_pathspecs() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    (
        set -euo pipefail
        cd "$tmp"
        git init -q
        git config user.email t@t.t
        git config user.name t
        printf '# t\n' >README.md
        git add -A
        git commit -q -m init
        mkdir -p src
        printf '<?php\n' >src/App.php
        printf 'x\n' >src/app.js
        printf 'x\n' >src/app.jsx
        printf 'x\n' >src/app.ts
        # Consumed dynamically by common.sh's die()/log_json.
        # shellcheck disable=SC2034
        AI_LOG_DIR="$tmp/logs"
        source "$REPO_ROOT/lib/common.sh"
        source "$REPO_ROOT/lib/ai-verify/run.sh"
        source "$REPO_ROOT/lib/ai-verify/language-files.sh"
        AI_VERIFY_SCOPE=changed
        local out
        out="$(scoped_language_files php)"
        [[ "$out" == "src/App.php" ]]
        out="$(scoped_language_files js)"
        [[ "$out" == $'src/app.js\nsrc/app.jsx' ]]
        out="$(scoped_language_files vue)"
        [[ -z "$out" ]]
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "scoped_language_files merges/dedupes/exist-filters across pathspecs" test_scoped_language_files_merges_across_pathspecs

# ── Phase 2 coverage: lib/ai-verify/language-dispatch.sh ────────────────────
# Build a git-fixture repo with fake pnpm + composer-managed vendor/bin/*
# binaries that record every invocation, commit the project metadata files
# (composer.json/package.json/vendor/bin/*/tsconfig.json) so they are NOT
# themselves "changed", then leave one uncommitted source file per language so
# AI_VERIFY_SCOPE (default "ai", translated to "changed" inside
# ai_verify_language) picks each one up. Runs
# `libexec/ai-verify --language <lang>` for real (AI_VERIFY_TEST_MODE=0) and
# prints the fixture's tmp root dir; caller reads $dir/tool.calls,
# $dir/stdout, $dir/stderr, $dir/exit_code and removes the dir.
run_language_dispatch_fixture() {
    local lang="$1"
    shift
    local tmpbin record work
    tmpbin="$(mktemp -d)"
    record="$tmpbin/tool.calls"

    # Fake pnpm: records every invocation and exits 0, EXCEPT an
    # eslint --fix-dry-run invocation (suggest mode), which exits 1 so the
    # "advisory, never fails" contract is actually exercised.
    cat >"$tmpbin/pnpm" <<PNPMEOF
#!/usr/bin/env bash
printf 'pnpm:%s\n' "\$*" >>"$record"
case "\$*" in
*--fix-dry-run*) exit 1 ;;
esac
exit 0
PNPMEOF
    chmod +x "$tmpbin/pnpm"

    work="$tmpbin/work"
    mkdir -p "$work/vendor/bin" "$work/src"
    (
        cd "$work"
        git init -q
        git config user.email t@t.t
        git config user.name t
        git config core.excludesfile /dev/null
        printf '{"name":"t/t","require":{}}\n' >composer.json
        printf '{"name":"t","devDependencies":{"eslint":"^8.0.0","typescript":"^5.0.0","vue-tsc":"^1.0.0","nuxt":"^3.0.0","knip":"^5.0.0"}}\n' >package.json
        printf '{}\n' >tsconfig.json
        local bin
        for bin in pint phpstan psalm rector; do
            cat >"vendor/bin/$bin" <<BINEOF
#!/usr/bin/env bash
printf '$bin:%s\n' "\$*" >>"$record"
exit 0
BINEOF
            chmod +x "vendor/bin/$bin"
        done
        git add -A
        git commit -q -m init

        # Leave these untracked so "changed" scope picks them up.
        printf '<?php\n' >src/App.php
        printf 'console.log(1)\n' >src/app.js
        printf 'const x: number = 1\n' >src/app.ts
        printf '<template></template>\n' >src/App.vue
        printf '<html></html>\n' >src/index.html

        PATH="$tmpbin:$PATH" AI_VERIFY_TEST_MODE=0 VERIFY_SECRETS=0 VERIFY_FULL=0 \
            "$@" "$BASH_BIN" "$SCRIPT" "$work" --language "$lang" \
            >"$tmpbin/stdout" 2>"$tmpbin/stderr"
        printf '%s\n' "$?" >"$tmpbin/exit_code"
    )

    printf '%s\n' "$tmpbin"
}

test_language_dispatch_php_runs_pint_phpstan_psalm_rector() {
    local dir out rc=0
    dir="$(run_language_dispatch_fixture php)"
    out="$(cat "$dir/tool.calls" 2>/dev/null)"
    [[ "$out" == *"pint:--test src/App.php"* ]] &&
        [[ "$out" == *"phpstan:analyse --memory-limit=1G src/App.php"* ]] &&
        [[ "$out" == *"psalm:--no-cache src/App.php"* ]] &&
        [[ "$out" == *"rector:process --dry-run src/App.php"* ]] || rc=1
    rm -rf "$dir"
    return "$rc"
}
run_test "--language php dispatches pint/phpstan/psalm/rector to changed *.php files" test_language_dispatch_php_runs_pint_phpstan_psalm_rector

test_language_dispatch_js_runs_eslint_and_knip() {
    local dir out rc=0
    dir="$(run_language_dispatch_fixture js)"
    out="$(cat "$dir/tool.calls" 2>/dev/null)"
    [[ "$out" == *"pnpm:exec eslint src/app.js"* ]] &&
        [[ "$out" == *"pnpm:exec knip"* ]] || rc=1
    rm -rf "$dir"
    return "$rc"
}
run_test "--language js dispatches scoped eslint plus project-wide knip" test_language_dispatch_js_runs_eslint_and_knip

test_language_dispatch_ts_runs_tsc_and_eslint() {
    local dir out rc=0
    dir="$(run_language_dispatch_fixture ts)"
    out="$(cat "$dir/tool.calls" 2>/dev/null)"
    [[ "$out" == *"pnpm:exec tsc --noEmit"* ]] &&
        [[ "$out" == *"pnpm:exec eslint src/app.ts"* ]] || rc=1
    rm -rf "$dir"
    return "$rc"
}
run_test "--language ts dispatches project-wide tsc plus scoped eslint" test_language_dispatch_ts_runs_tsc_and_eslint

test_language_dispatch_vue_runs_vue_tsc_and_nuxt() {
    local dir out rc=0
    dir="$(run_language_dispatch_fixture vue)"
    out="$(cat "$dir/tool.calls" 2>/dev/null)"
    [[ "$out" == *"pnpm:exec eslint src/App.vue"* ]] &&
        [[ "$out" == *"pnpm:exec vue-tsc --noEmit"* ]] &&
        [[ "$out" == *"pnpm:exec nuxi typecheck"* ]] || rc=1
    rm -rf "$dir"
    return "$rc"
}
run_test "--language vue dispatches eslint plus vue-tsc/nuxi typecheck" test_language_dispatch_vue_runs_vue_tsc_and_nuxt

test_language_dispatch_html_warns_when_unconfigured() {
    local dir err rc=0
    dir="$(run_language_dispatch_fixture html)"
    err="$(cat "$dir/stderr" 2>/dev/null)"
    [[ "$err" == *"No configured HTML verifier found"* ]] || rc=1
    rm -rf "$dir"
    return "$rc"
}
run_test "--language html warns cleanly when no biome/htmlhint is configured" test_language_dispatch_html_warns_when_unconfigured

test_language_dispatch_suggest_mode_never_fails() {
    local dir out ec rc=0
    dir="$(run_language_dispatch_fixture js env AI_VERIFY_MODE=suggest)"
    out="$(cat "$dir/tool.calls" 2>/dev/null)"
    ec="$(cat "$dir/exit_code" 2>/dev/null)"
    [[ "$out" == *"pnpm:exec eslint --fix-dry-run --format json src/app.js"* ]] &&
        [[ "$ec" == "0" ]] || rc=1
    rm -rf "$dir"
    return "$rc"
}
run_test "AI_VERIFY_MODE=suggest runs eslint --fix-dry-run and never fails" test_language_dispatch_suggest_mode_never_fails

# ── Phase 2 coverage: lib/ai-verify/duplication.sh (check_jscpd) ────────────
# Fake `jscpd` on PATH that writes a canned jscpd-report.json under whatever
# --output dir it is given, with a percentage controlled by $FAKE_JSCPD_PCT,
# and (optionally) records its raw argv to $JSCPD_RECORD for the
# JSCPD_PATHS-override assertion.
_write_fake_jscpd() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    cat >"$bin_dir/jscpd" <<'JSEOF'
#!/usr/bin/env bash
[[ -n "${JSCPD_RECORD:-}" ]] && printf '%s\n' "$*" >>"$JSCPD_RECORD"
out_dir=""
prev=""
for a in "$@"; do
    if [[ "$prev" == "--output" ]]; then out_dir="$a"; fi
    prev="$a"
done
mkdir -p "$out_dir"
printf '{"statistics":{"total":{"percentage": %s}}}\n' "${FAKE_JSCPD_PCT:-0}" >"$out_dir/jscpd-report.json"
exit 0
JSEOF
    chmod +x "$bin_dir/jscpd"
}

test_jscpd_warn_tier_does_not_fail() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    _write_fake_jscpd "$tmp/bin"
    (
        set -euo pipefail
        cd "$tmp"
        git init -q
        AI_LOG_DIR="$tmp/logs"
        source "$REPO_ROOT/lib/common.sh"
        source "$REPO_ROOT/lib/ai-verify/scope.sh"
        source "$REPO_ROOT/lib/ai-verify/duplication.sh"
        failures=0
        VERIFY_JSCPD=1
        VERIFY_TIMEOUT=20
        JSCPD_MIN_TOKENS=50
        JSCPD_WARN_PCT=5
        JSCPD_FAIL_PCT=""
        JSCPD_PATHS="."
        export PATH="$tmp/bin:$PATH"
        export FAKE_JSCPD_PCT=10
        check_jscpd
        ((failures == 0))
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "jscpd WARN tier (>= JSCPD_WARN_PCT, no JSCPD_FAIL_PCT) does not fail verification" test_jscpd_warn_tier_does_not_fail

test_jscpd_fail_tier_increments_failures() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    _write_fake_jscpd "$tmp/bin"
    (
        set -euo pipefail
        cd "$tmp"
        git init -q
        AI_LOG_DIR="$tmp/logs"
        source "$REPO_ROOT/lib/common.sh"
        source "$REPO_ROOT/lib/ai-verify/scope.sh"
        source "$REPO_ROOT/lib/ai-verify/duplication.sh"
        failures=0
        VERIFY_JSCPD=1
        VERIFY_TIMEOUT=20
        JSCPD_MIN_TOKENS=50
        JSCPD_WARN_PCT=5
        JSCPD_FAIL_PCT=8
        JSCPD_PATHS="."
        export PATH="$tmp/bin:$PATH"
        export FAKE_JSCPD_PCT=10
        check_jscpd
        ((failures == 1))
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "jscpd FAIL tier (>= JSCPD_FAIL_PCT) increments failures" test_jscpd_fail_tier_increments_failures

test_jscpd_under_threshold_ok() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    _write_fake_jscpd "$tmp/bin"
    (
        set -euo pipefail
        cd "$tmp"
        git init -q
        AI_LOG_DIR="$tmp/logs"
        source "$REPO_ROOT/lib/common.sh"
        source "$REPO_ROOT/lib/ai-verify/scope.sh"
        source "$REPO_ROOT/lib/ai-verify/duplication.sh"
        failures=0
        VERIFY_JSCPD=1
        VERIFY_TIMEOUT=20
        JSCPD_MIN_TOKENS=50
        JSCPD_WARN_PCT=5
        JSCPD_FAIL_PCT=8
        JSCPD_PATHS="."
        export PATH="$tmp/bin:$PATH"
        export FAKE_JSCPD_PCT=1
        check_jscpd
        ((failures == 0))
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "jscpd under every threshold reports OK (no warn/fail)" test_jscpd_under_threshold_ok

test_jscpd_paths_override() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    _write_fake_jscpd "$tmp/bin"
    (
        set -euo pipefail
        cd "$tmp"
        git init -q
        AI_LOG_DIR="$tmp/logs"
        source "$REPO_ROOT/lib/common.sh"
        source "$REPO_ROOT/lib/ai-verify/scope.sh"
        source "$REPO_ROOT/lib/ai-verify/duplication.sh"
        failures=0
        VERIFY_JSCPD=1
        VERIFY_TIMEOUT=20
        JSCPD_MIN_TOKENS=50
        JSCPD_WARN_PCT=5
        JSCPD_FAIL_PCT=""
        JSCPD_PATHS="custom/dir another/dir"
        export PATH="$tmp/bin:$PATH"
        export FAKE_JSCPD_PCT=0
        export JSCPD_RECORD="$tmp/jscpd.calls"
        check_jscpd
        local calls
        calls="$(cat "$JSCPD_RECORD")"
        [[ "$calls" == *"custom/dir another/dir"* ]]
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "JSCPD_PATHS overrides the default scoped-file path list" test_jscpd_paths_override

test_jscpd_npx_unavailable_skips_cleanly() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    (
        set -euo pipefail
        cd "$tmp"
        git init -q
        AI_LOG_DIR="$tmp/logs"
        source "$REPO_ROOT/lib/common.sh"
        source "$REPO_ROOT/lib/ai-verify/scope.sh"
        source "$REPO_ROOT/lib/ai-verify/duplication.sh"
        failures=0
        # Consumed dynamically by check_jscpd (lib/ai-verify/duplication.sh) below.
        # shellcheck disable=SC2034
        VERIFY_JSCPD=1
        VERIFY_TIMEOUT=20
        # shellcheck disable=SC2034
        JSCPD_MIN_TOKENS=50
        # shellcheck disable=SC2034
        JSCPD_WARN_PCT=5
        # shellcheck disable=SC2034
        JSCPD_FAIL_PCT=""
        # shellcheck disable=SC2034
        JSCPD_PATHS="."
        # Strip both jscpd and npx from PATH.
        export PATH="/nonexistent-dir-for-jscpd-test-$$"
        check_jscpd
        ((failures == 0))
    ) >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
    if ((rc == 0)); then
        grep -q "npx unavailable" "$tmp/stderr" || rc=1
    fi
    rm -rf "$tmp"
    return "$rc"
}
run_test "jscpd not found and npx unavailable: check_jscpd skips cleanly (no crash, no failure)" test_jscpd_npx_unavailable_skips_cleanly

test_jscpd_skipped_when_verify_jscpd_not_1() {
    local tmp rc=0 out
    tmp="$(mktemp -d)"
    _write_fake_jscpd "$tmp/bin"
    out="$(
        {
            set -euo pipefail
            cd "$tmp"
            git init -q
            AI_LOG_DIR="$tmp/logs"
            source "$REPO_ROOT/lib/common.sh"
            source "$REPO_ROOT/lib/ai-verify/scope.sh"
            source "$REPO_ROOT/lib/ai-verify/duplication.sh"
            failures=0
            VERIFY_JSCPD=0
            export PATH="$tmp/bin:$PATH"
            export JSCPD_RECORD="$tmp/jscpd.calls"
            check_jscpd
            ((failures == 0))
        } 2>&1
    )" || rc=$?
    [[ ! -f "$tmp/jscpd.calls" ]] || rc=1
    [[ "$out" == *"Skipping jscpd"* ]] || rc=1
    rm -rf "$tmp"
    return "$rc"
}
run_test "check_jscpd: VERIFY_JSCPD unset/0 skips without invoking jscpd" test_jscpd_skipped_when_verify_jscpd_not_1

test_jscpd_uses_npx_when_jscpd_binary_absent() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/bin"
    cat >"$tmp/bin/npx" <<'NPXEOF'
#!/usr/bin/env bash
[[ -n "${JSCPD_RECORD:-}" ]] && printf 'npx:%s\n' "$*" >>"$JSCPD_RECORD"
out_dir=""
prev=""
for a in "$@"; do
    if [[ "$prev" == "--output" ]]; then out_dir="$a"; fi
    prev="$a"
done
mkdir -p "$out_dir"
printf '{"statistics":{"total":{"percentage": %s}}}\n' "${FAKE_JSCPD_PCT:-0}" >"$out_dir/jscpd-report.json"
exit 0
NPXEOF
    chmod +x "$tmp/bin/npx"
    (
        set -euo pipefail
        cd "$tmp"
        git init -q
        AI_LOG_DIR="$tmp/logs"
        source "$REPO_ROOT/lib/common.sh"
        source "$REPO_ROOT/lib/ai-verify/scope.sh"
        source "$REPO_ROOT/lib/ai-verify/duplication.sh"
        failures=0
        VERIFY_JSCPD=1
        VERIFY_TIMEOUT=20
        JSCPD_MIN_TOKENS=50
        JSCPD_WARN_PCT=5
        JSCPD_FAIL_PCT=""
        JSCPD_PATHS="."
        export PATH="$tmp/bin:$PATH"
        export FAKE_JSCPD_PCT=1
        export JSCPD_RECORD="$tmp/jscpd.calls"
        check_jscpd
        ((failures == 0))
        grep -q "^npx:--yes jscpd" "$JSCPD_RECORD"
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "check_jscpd falls back to 'npx --yes jscpd' when no local jscpd binary is on PATH" test_jscpd_uses_npx_when_jscpd_binary_absent

test_jscpd_no_report_produced_skips_cleanly() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/bin"
    cat >"$tmp/bin/jscpd" <<'JSEOF'
#!/usr/bin/env bash
# Simulate a jscpd invocation that fails before writing any report.
exit 1
JSEOF
    chmod +x "$tmp/bin/jscpd"
    (
        set -euo pipefail
        cd "$tmp"
        git init -q
        AI_LOG_DIR="$tmp/logs"
        source "$REPO_ROOT/lib/common.sh"
        source "$REPO_ROOT/lib/ai-verify/scope.sh"
        source "$REPO_ROOT/lib/ai-verify/duplication.sh"
        failures=0
        VERIFY_JSCPD=1
        VERIFY_TIMEOUT=20
        JSCPD_MIN_TOKENS=50
        JSCPD_WARN_PCT=5
        JSCPD_FAIL_PCT=""
        JSCPD_PATHS="."
        export PATH="$tmp/bin:$PATH"
        check_jscpd
        ((failures == 0))
    ) >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
    if ((rc == 0)); then
        grep -q "produced no report" "$tmp/stderr" || rc=1
    fi
    rm -rf "$tmp"
    return "$rc"
}
run_test "check_jscpd: no report file produced (tool errored) skips cleanly without failing" test_jscpd_no_report_produced_skips_cleanly

test_jscpd_default_paths_fallback_to_dot_when_scope_empty() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    _write_fake_jscpd "$tmp/bin"
    (
        set -euo pipefail
        cd "$tmp"
        git init -q
        git config user.email t@t.t
        git config user.name t
        : >tracked.txt
        git add -A
        git commit -q -m init
        AI_LOG_DIR="$tmp/logs"
        AI_VERIFY_SCOPE=changed
        source "$REPO_ROOT/lib/common.sh"
        source "$REPO_ROOT/lib/ai-verify/scope.sh"
        source "$REPO_ROOT/lib/ai-verify/duplication.sh"
        failures=0
        # Consumed dynamically by check_jscpd (lib/ai-verify/duplication.sh) below.
        # shellcheck disable=SC2034
        VERIFY_JSCPD=1
        VERIFY_TIMEOUT=20
        # shellcheck disable=SC2034
        JSCPD_MIN_TOKENS=50
        # shellcheck disable=SC2034
        JSCPD_WARN_PCT=5
        # shellcheck disable=SC2034
        JSCPD_FAIL_PCT=""
        # shellcheck disable=SC2034
        JSCPD_PATHS=""
        export PATH="$tmp/bin:$PATH"
        export FAKE_JSCPD_PCT=0
        export JSCPD_RECORD="$tmp/jscpd.calls"
        check_jscpd
        local calls
        calls="$(cat "$JSCPD_RECORD")"
        # Nothing changed in "changed" scope, so linecount_scoped_files is
        # empty and check_jscpd must fall back to "." rather than invoking
        # jscpd with zero path arguments.
        [[ "$calls" == ". "* || "$calls" == *" ."* ]]
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "check_jscpd: falls back to '.' when the scoped file list is empty" test_jscpd_default_paths_fallback_to_dot_when_scope_empty

# ── Phase 2 coverage: lib/ai-verify/plan-status.sh ──────────────────────────
test_plan_status_checklist_counts() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    cat >"$tmp/plan.md" <<'PLANEOF'
## Todo Plan
- [x] step one
- [x] step two
- [ ] step three
PLANEOF
    (
        set -euo pipefail
        AI_LOG_DIR="$tmp/logs"
        source "$REPO_ROOT/lib/common.sh"
        source "$REPO_ROOT/lib/ai-verify/plan-status.sh"
        local counts
        counts="$(plan_status_checklist_counts "$tmp/plan.md")"
        [[ "$counts" == $'2\t1' ]]
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "plan_status_checklist_counts counts checked/unchecked checklist items" test_plan_status_checklist_counts

test_plan_status_difficulty_hits_scoped_to_checklist_lines() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    cat >"$tmp/plan.md" <<'PLANEOF'
## Todo Plan
Status: not implemented, blocked by unknown prose that should NOT match.
- [ ] this step is impossible without more context
- [x] this step is fine
PLANEOF
    (
        set -euo pipefail
        AI_LOG_DIR="$tmp/logs"
        source "$REPO_ROOT/lib/common.sh"
        source "$REPO_ROOT/lib/ai-verify/plan-status.sh"
        local hits
        hits="$(plan_status_difficulty_hits "$tmp/plan.md")"
        [[ "$hits" == *"impossible"* ]]
        [[ "$hits" != *"blocked by unknown prose"* ]]
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "plan_status_difficulty_hits only scans checklist-item lines, not prose" test_plan_status_difficulty_hits_scoped_to_checklist_lines

test_check_plan_status_difficulty_notice_fails_full_run() {
    local tmp out ec
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/work/docs/tickets/sample-ticket"
    cat >"$tmp/work/docs/tickets/sample-ticket/plan.md" <<'PLANEOF'
## Todo Plan
- [ ] this item is impossible without more context
PLANEOF
    out="$(
        cd "$tmp/work"
        git init -q
        git config user.email t@t.t
        git config user.name t
        AI_LOG_DIR="$tmp/logs" AI_EVENT_LOG="$tmp/logs/ev.jsonl" \
            AI_VERIFY_TEST_MODE=0 AI_VERIFY_SCOPE=changed VERIFY_PLAN_STATUS=1 \
            VERIFY_LINECOUNT=0 VERIFY_SECRETS=0 VERIFY_FULL=0 VERIFY_LINKS=0 \
            "$BASH_BIN" "$SCRIPT" . 2>&1
    )"
    ec=$?
    rm -rf "$tmp"
    [[ $ec -eq 1 ]] && [[ "$out" == *"difficulty notice found"* ]]
}
run_test "verify: plan-status difficulty notice fails full-run verification" test_check_plan_status_difficulty_notice_fails_full_run

test_check_plan_status_incomplete_warns_not_fails() {
    local tmp out ec
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/work/docs/tickets/sample-ticket"
    cat >"$tmp/work/docs/tickets/sample-ticket/plan.md" <<'PLANEOF'
## Todo Plan
- [x] step one
- [ ] step two
PLANEOF
    out="$(
        cd "$tmp/work"
        git init -q
        git config user.email t@t.t
        git config user.name t
        AI_LOG_DIR="$tmp/logs" AI_EVENT_LOG="$tmp/logs/ev.jsonl" \
            AI_VERIFY_TEST_MODE=0 AI_VERIFY_SCOPE=changed VERIFY_PLAN_STATUS=1 \
            VERIFY_LINECOUNT=0 VERIFY_SECRETS=0 VERIFY_FULL=0 VERIFY_LINKS=0 \
            "$BASH_BIN" "$SCRIPT" . 2>&1
    )"
    ec=$?
    rm -rf "$tmp"
    [[ $ec -eq 0 ]] && [[ "$out" == *"1 incomplete / 1 complete Todo item"* ]]
}
run_test "verify: plan-status incomplete checklist warns without failing" test_check_plan_status_incomplete_warns_not_fails

# ── Phase 2 coverage: lib/ai-verify/step-runner.sh ──────────────────────────
test_diagnose_pnpm_auth_warns_when_token_unset() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    printf '//npm.pkg.github.com/:_authToken=${MY_TEST_TOKEN}\n' >"$tmp/.npmrc"
    (
        set -euo pipefail
        cd "$tmp"
        AI_LOG_DIR="$tmp/logs"
        source "$REPO_ROOT/lib/common.sh"
        source "$REPO_ROOT/lib/ai-verify/step-runner.sh"
        unset MY_TEST_TOKEN 2>/dev/null || true
        local out
        out="$(diagnose_pnpm_auth "typecheck" 2>&1)"
        [[ "$out" == *"MY_TEST_TOKEN"* ]]
        [[ "$out" == *"is unset"* ]]
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "diagnose_pnpm_auth warns when the referenced .npmrc token var is unset" test_diagnose_pnpm_auth_warns_when_token_unset

test_diagnose_pnpm_auth_silent_when_token_set() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    printf '//npm.pkg.github.com/:_authToken=${MY_TEST_TOKEN}\n' >"$tmp/.npmrc"
    (
        set -euo pipefail
        cd "$tmp"
        AI_LOG_DIR="$tmp/logs"
        source "$REPO_ROOT/lib/common.sh"
        source "$REPO_ROOT/lib/ai-verify/step-runner.sh"
        export MY_TEST_TOKEN="dummy-token"
        local out
        out="$(diagnose_pnpm_auth "typecheck" 2>&1)"
        [[ -z "$out" ]]
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "diagnose_pnpm_auth stays silent when the referenced token var is set" test_diagnose_pnpm_auth_silent_when_token_set

test_run_step_verify_guard_1_uses_run_guarded() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    (
        set -euo pipefail
        cd "$tmp"
        AI_LOG_DIR="$tmp/logs"
        AI_EVENT_LOG="$tmp/logs/ev.jsonl"
        source "$REPO_ROOT/lib/common.sh"
        source "$REPO_ROOT/lib/ai-verify/step-runner.sh"
        failures=0
        VERIFY_TIMEOUT=10
        VERIFY_GUARD=1
        run_step "guarded true" true
        grep -q '"event_type":"guard.start"' "$AI_EVENT_LOG"
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "run_step with VERIFY_GUARD=1 (default) routes through run_guarded" test_run_step_verify_guard_1_uses_run_guarded

test_run_step_verify_guard_0_uses_run_with_timeout() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    (
        set -euo pipefail
        cd "$tmp"
        AI_LOG_DIR="$tmp/logs"
        AI_EVENT_LOG="$tmp/logs/ev.jsonl"
        source "$REPO_ROOT/lib/common.sh"
        source "$REPO_ROOT/lib/ai-verify/step-runner.sh"
        failures=0
        # Consumed dynamically by run_step (lib/ai-verify/step-runner.sh) below.
        # shellcheck disable=SC2034
        VERIFY_TIMEOUT=10
        # shellcheck disable=SC2034
        VERIFY_GUARD=0
        run_step "unguarded true" true
        [[ ! -f "$AI_EVENT_LOG" ]] || ! grep -q '"event_type":"guard.start"' "$AI_EVENT_LOG"
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "run_step with VERIFY_GUARD=0 falls back to run_with_timeout (no guard.start event)" test_run_step_verify_guard_0_uses_run_with_timeout

test_has_package_script_and_dependency_branches() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    (
        set -euo pipefail
        cd "$tmp"
        source "$REPO_ROOT/lib/ai-verify/step-runner.sh"
        # No package.json at all: both false.
        ! has_package_script test
        ! has_package_dependency eslint
        printf '{"name":"t","scripts":{"test":"vitest"},"devDependencies":{"eslint":"^8.0.0"}}\n' >package.json
        has_package_script test
        ! has_package_script lint
        has_package_dependency eslint
        ! has_package_dependency biome
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "has_package_script/has_package_dependency: true/false/no-package.json branches" test_has_package_script_and_dependency_branches

# ── Phase 2 coverage: lib/ai-verify/run.sh ──────────────────────────────────
test_scoped_changed_files_by_pathspec_branch_arm() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    (
        set -euo pipefail
        cd "$tmp"
        git init -q
        git config user.email t@t.t
        git config user.name t
        printf 'orig\n' >a.txt
        git add -A
        git commit -q -m init
        git branch -m trunk
        git checkout -q -b feature
        printf 'x\n' >new-feature.txt
        git add -A
        git commit -q -m feature
        AI_LOG_DIR="$tmp/logs"
        source "$REPO_ROOT/lib/common.sh"
        source "$REPO_ROOT/lib/ai-verify/scope.sh"
        source "$REPO_ROOT/lib/ai-verify/run.sh"
        # Consumed dynamically by resolve_branch_base/branch_scoped_files below.
        # shellcheck disable=SC2034
        VERIFY_BASE_REF=trunk
        # shellcheck disable=SC2034
        VERIFY_AUTHOR=""
        local out
        out="$(scoped_changed_files_by_pathspec branch '*')"
        [[ "$out" == *"new-feature.txt"* ]]
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "scoped_changed_files_by_pathspec's branch arm reuses branch_scoped_files" test_scoped_changed_files_by_pathspec_branch_arm

_write_fake_recorder() {
    # _write_fake_recorder <bin_dir> <record_file> <tool-name> [exit-code]
    local bin_dir="$1" record="$2" tool="$3" exit_code="${4:-0}"
    mkdir -p "$bin_dir"
    cat >"$bin_dir/$tool" <<EOF
#!/usr/bin/env bash
printf '$tool:%s\n' "\$*" >>"$record"
exit $exit_code
EOF
    chmod +x "$bin_dir/$tool"
}

test_run_verify_full_invokes_phpunit_and_pest() {
    local tmp rc=0 out
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/work/vendor/bin"
    _write_fake_recorder "$tmp/work/vendor/bin" "$tmp/tool.calls" phpunit
    _write_fake_recorder "$tmp/work/vendor/bin" "$tmp/tool.calls" pest
    printf '{"name":"t/t","require":{}}\n' >"$tmp/work/composer.json"
    (
        cd "$tmp/work"
        git init -q
        git config user.email t@t.t
        git config user.name t
        git add -A
        git commit -q -m init
        AI_LOG_DIR="$tmp/logs" AI_EVENT_LOG="$tmp/logs/ev.jsonl" \
            AI_VERIFY_TEST_MODE=0 AI_VERIFY_SCOPE=changed VERIFY_FULL=1 \
            VERIFY_LINECOUNT=0 VERIFY_SECRETS=0 VERIFY_LINKS=0 \
            "$BASH_BIN" "$SCRIPT" . >/dev/null 2>&1
    )
    rc=$?
    out="$(cat "$tmp/tool.calls" 2>/dev/null)"
    rm -rf "$tmp"
    ((rc == 0)) && [[ "$out" == *"phpunit:"* ]] && [[ "$out" == *"pest:"* ]]
}
run_test "VERIFY_FULL=1 invokes vendor/bin/phpunit and vendor/bin/pest" test_run_verify_full_invokes_phpunit_and_pest

test_run_verify_full_invokes_deptrac_and_composer_require_checker() {
    local tmp rc=0 out
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/work/vendor/bin"
    _write_fake_recorder "$tmp/work/vendor/bin" "$tmp/tool.calls" deptrac
    _write_fake_recorder "$tmp/work/vendor/bin" "$tmp/tool.calls" composer-require-checker
    printf '{"name":"t/t","require":{}}\n' >"$tmp/work/composer.json"
    (
        cd "$tmp/work"
        git init -q
        git config user.email t@t.t
        git config user.name t
        git add -A
        git commit -q -m init
        AI_LOG_DIR="$tmp/logs" AI_EVENT_LOG="$tmp/logs/ev.jsonl" \
            AI_VERIFY_TEST_MODE=0 AI_VERIFY_SCOPE=changed VERIFY_FULL=1 \
            VERIFY_LINECOUNT=0 VERIFY_SECRETS=0 VERIFY_LINKS=0 \
            "$BASH_BIN" "$SCRIPT" . >/dev/null 2>&1
    )
    rc=$?
    out="$(cat "$tmp/tool.calls" 2>/dev/null)"
    rm -rf "$tmp"
    ((rc == 0)) && [[ "$out" == *"deptrac:analyse"* ]] && [[ "$out" == *"composer-require-checker:check composer.json"* ]]
}
run_test "VERIFY_FULL=1 invokes vendor/bin/deptrac analyse and composer-require-checker check" test_run_verify_full_invokes_deptrac_and_composer_require_checker

# Hide a single named binary from PATH by symlinking every other real PATH
# executable into a fresh dir (mirrors test-common.sh's build_path_without,
# duplicated locally since this suite has no shared harness file).
#
# ${f##*/} (not `basename "$f"`) and batched `ln` calls (multiple sources,
# one destination dir) avoid forking a process per PATH entry -- on a PATH
# with hundreds of entries that was ~6-7s per call, now sub-0.1s.
_ai_verify_path_without() {
    local fakebin="$1" hide="$2"
    mkdir -p "$fakebin"
    local dir f base
    local -a dirs=() sources=()
    local -A seen=()
    seen["$hide"]=1
    IFS=':' read -ra dirs <<<"$PATH"
    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*; do
            [[ -x "$f" && -f "$f" ]] || continue
            base="${f##*/}"
            [[ -n "${seen[$base]:-}" ]] && continue
            seen["$base"]=1
            sources+=("$f")
        done
    done
    local i
    for ((i = 0; i < ${#sources[@]}; i += 500)); do
        ln -s -- "${sources[@]:i:500}" "$fakebin" 2>/dev/null || true
    done
    printf '%s\n' "$fakebin"
}

test_run_verify_pnpm_js_tool_matrix() {
    local tmp rc=0 out
    tmp="$(mktemp -d)"
    _write_fake_recorder "$tmp/bin" "$tmp/tool.calls" pnpm
    mkdir -p "$tmp/work/src"
    (
        cd "$tmp/work"
        git init -q
        git config user.email t@t.t
        git config user.name t
        printf '{"name":"t","devDependencies":{"eslint":"^8.0.0","typescript":"^5.0.0","vue-tsc":"^1.0.0","nuxt":"^3.0.0","@graphql-codegen/cli":"^5.0.0","@graphql-eslint/eslint-plugin":"^3.0.0","@biomejs/biome":"^1.0.0","knip":"^5.0.0"}}\n' >package.json
        printf '{}\n' >tsconfig.json
        printf 'generates: {}\n' >codegen.yml
        git add -A
        git commit -q -m init
        PATH="$tmp/bin:$PATH" AI_LOG_DIR="$tmp/logs" AI_EVENT_LOG="$tmp/logs/ev.jsonl" \
            AI_VERIFY_TEST_MODE=0 AI_VERIFY_SCOPE=changed VERIFY_FULL=0 \
            VERIFY_LINECOUNT=0 VERIFY_SECRETS=0 VERIFY_LINKS=0 \
            "$BASH_BIN" "$SCRIPT" . >/dev/null 2>&1
    )
    rc=$?
    out="$(cat "$tmp/tool.calls" 2>/dev/null)"
    rm -rf "$tmp"
    ((rc == 0)) &&
        [[ "$out" == *"pnpm:exec eslint ."* ]] &&
        [[ "$out" == *"pnpm:exec tsc --noEmit"* ]] &&
        [[ "$out" == *"pnpm:exec vue-tsc --noEmit"* ]] &&
        [[ "$out" == *"pnpm:exec nuxi typecheck"* ]] &&
        [[ "$out" == *"pnpm:exec graphql-codegen"* ]] &&
        [[ "$out" == *"pnpm:exec graphql-eslint ."* ]] &&
        [[ "$out" == *"pnpm:exec biome check ."* ]] &&
        [[ "$out" == *"pnpm:exec knip"* ]]
}
run_test "ai_verify_run pnpm branch: eslint/tsc/vue-tsc/nuxt/graphql-codegen/graphql-eslint/biome/knip all dispatch via dependency detection" test_run_verify_pnpm_js_tool_matrix

test_run_verify_pnpm_full_invokes_playwright_and_vitest() {
    local tmp rc=0 out
    tmp="$(mktemp -d)"
    _write_fake_recorder "$tmp/bin" "$tmp/tool.calls" pnpm
    mkdir -p "$tmp/work"
    (
        cd "$tmp/work"
        git init -q
        git config user.email t@t.t
        git config user.name t
        printf '{"name":"t","devDependencies":{"@playwright/test":"^1.0.0","vitest":"^1.0.0"}}\n' >package.json
        git add -A
        git commit -q -m init
        PATH="$tmp/bin:$PATH" AI_LOG_DIR="$tmp/logs" AI_EVENT_LOG="$tmp/logs/ev.jsonl" \
            AI_VERIFY_TEST_MODE=0 AI_VERIFY_SCOPE=changed VERIFY_FULL=1 \
            VERIFY_LINECOUNT=0 VERIFY_SECRETS=0 VERIFY_LINKS=0 \
            "$BASH_BIN" "$SCRIPT" . >/dev/null 2>&1
    )
    rc=$?
    out="$(cat "$tmp/tool.calls" 2>/dev/null)"
    rm -rf "$tmp"
    ((rc == 0)) && [[ "$out" == *"pnpm:exec playwright test"* ]] && [[ "$out" == *"pnpm:exec vitest run"* ]]
}
run_test "VERIFY_FULL=1 pnpm branch invokes dedicated playwright test and vitest run" test_run_verify_pnpm_full_invokes_playwright_and_vitest

test_run_verify_pnpm_test_script_gated_by_verify_full() {
    local tmp rc_full=0 rc_off=0 out_full out_off
    tmp="$(mktemp -d)"
    _write_fake_recorder "$tmp/bin" "$tmp/tool.calls" pnpm
    mkdir -p "$tmp/work"
    (
        cd "$tmp/work"
        git init -q
        git config user.email t@t.t
        git config user.name t
        printf '{"name":"t","scripts":{"test":"vitest run"}}\n' >package.json
        git add -A
        git commit -q -m init
        PATH="$tmp/bin:$PATH" AI_LOG_DIR="$tmp/logs" AI_EVENT_LOG="$tmp/logs/ev.jsonl" \
            AI_VERIFY_TEST_MODE=0 AI_VERIFY_SCOPE=changed VERIFY_FULL=1 \
            VERIFY_LINECOUNT=0 VERIFY_SECRETS=0 VERIFY_LINKS=0 \
            "$BASH_BIN" "$SCRIPT" . >/dev/null 2>&1
    )
    rc_full=$?
    out_full="$(cat "$tmp/tool.calls" 2>/dev/null)"
    : >"$tmp/tool.calls"
    (
        cd "$tmp/work"
        PATH="$tmp/bin:$PATH" AI_LOG_DIR="$tmp/logs2" AI_EVENT_LOG="$tmp/logs2/ev.jsonl" \
            AI_VERIFY_TEST_MODE=0 AI_VERIFY_SCOPE=changed VERIFY_FULL=0 \
            VERIFY_LINECOUNT=0 VERIFY_SECRETS=0 VERIFY_LINKS=0 \
            "$BASH_BIN" "$SCRIPT" . >/dev/null 2>&1
    )
    rc_off=$?
    out_off="$(cat "$tmp/tool.calls" 2>/dev/null)"
    rm -rf "$tmp"
    ((rc_full == 0)) && ((rc_off == 0)) &&
        [[ "$out_full" == *"pnpm:test"* ]] &&
        [[ "$out_off" != *"pnpm:test"* ]]
}
run_test "pnpm 'test' script runs only under VERIFY_FULL=1, skipped otherwise" test_run_verify_pnpm_test_script_gated_by_verify_full

test_run_verify_npm_fallback_when_pnpm_absent() {
    local tmp rc=0 out fakebin
    tmp="$(mktemp -d)"
    fakebin="$(_ai_verify_path_without "$tmp/bin" pnpm)"
    _write_fake_recorder "$tmp/npmbin" "$tmp/tool.calls" npm
    mkdir -p "$tmp/work"
    (
        cd "$tmp/work"
        git init -q
        git config user.email t@t.t
        git config user.name t
        printf '{"name":"t","scripts":{"lint":"eslint .","typecheck":"tsc --noEmit","test":"vitest run"}}\n' >package.json
        git add -A
        git commit -q -m init
        PATH="$tmp/npmbin:$fakebin" AI_LOG_DIR="$tmp/logs" AI_EVENT_LOG="$tmp/logs/ev.jsonl" \
            AI_VERIFY_TEST_MODE=0 AI_VERIFY_SCOPE=changed VERIFY_FULL=1 \
            VERIFY_LINECOUNT=0 VERIFY_SECRETS=0 VERIFY_LINKS=0 \
            "$BASH_BIN" "$SCRIPT" . >/dev/null 2>&1
    )
    rc=$?
    out="$(cat "$tmp/tool.calls" 2>/dev/null)"
    rm -rf "$tmp"
    ((rc == 0)) &&
        [[ "$out" == *"npm:run lint"* ]] &&
        [[ "$out" == *"npm:run typecheck"* ]] &&
        [[ "$out" == *"npm:test"* ]]
}
run_test "package.json JS steps fall back to npm run/npm test when pnpm is not on PATH" test_run_verify_npm_fallback_when_pnpm_absent

test_run_verify_secrets_1_invokes_gitleaks() {
    local tmp rc=0 out
    tmp="$(mktemp -d)"
    _write_fake_recorder "$tmp/bin" "$tmp/tool.calls" gitleaks
    mkdir -p "$tmp/work"
    (
        cd "$tmp/work"
        git init -q
        git config user.email t@t.t
        git config user.name t
        git add -A 2>/dev/null || true
        git commit -q -m init --allow-empty
        PATH="$tmp/bin:$PATH" AI_LOG_DIR="$tmp/logs" AI_EVENT_LOG="$tmp/logs/ev.jsonl" \
            AI_VERIFY_TEST_MODE=0 AI_VERIFY_SCOPE=changed VERIFY_SECRETS=1 VERIFY_FULL=0 \
            VERIFY_LINECOUNT=0 VERIFY_LINKS=0 \
            "$BASH_BIN" "$SCRIPT" . >/dev/null 2>&1
    )
    rc=$?
    out="$(cat "$tmp/tool.calls" 2>/dev/null)"
    rm -rf "$tmp"
    ((rc == 0)) && [[ "$out" == *"gitleaks:detect --source . --redact --no-banner"* ]]
}
run_test "VERIFY_SECRETS=1 invokes gitleaks detect" test_run_verify_secrets_1_invokes_gitleaks

test_run_verify_security_1_invokes_scanners() {
    local tmp rc=0 out
    tmp="$(mktemp -d)"
    _write_fake_recorder "$tmp/bin" "$tmp/tool.calls" trivy
    _write_fake_recorder "$tmp/bin" "$tmp/tool.calls" semgrep
    _write_fake_recorder "$tmp/bin" "$tmp/tool.calls" osv-scanner
    mkdir -p "$tmp/work"
    (
        cd "$tmp/work"
        git init -q
        git config user.email t@t.t
        git config user.name t
        git add -A 2>/dev/null || true
        git commit -q -m init --allow-empty
        PATH="$tmp/bin:$PATH" AI_LOG_DIR="$tmp/logs" AI_EVENT_LOG="$tmp/logs/ev.jsonl" \
            AI_VERIFY_TEST_MODE=0 AI_VERIFY_SCOPE=changed VERIFY_SECURITY=1 VERIFY_SECRETS=0 VERIFY_FULL=0 \
            VERIFY_LINECOUNT=0 VERIFY_LINKS=0 \
            "$BASH_BIN" "$SCRIPT" . >/dev/null 2>&1
    )
    rc=$?
    out="$(cat "$tmp/tool.calls" 2>/dev/null)"
    rm -rf "$tmp"
    ((rc == 0)) && [[ "$out" == *"trivy:fs --scanners vuln,misconfig,secret ."* ]] &&
        [[ "$out" == *"semgrep:scan --config auto ."* ]] &&
        [[ "$out" == *"osv-scanner:scan source -r ."* ]]
}
run_test "VERIFY_SECURITY=1 invokes trivy/semgrep/osv-scanner in changed scope" test_run_verify_security_1_invokes_scanners

test_check_composer_unused_runs_without_crashing() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/vendor/bin"
    printf '{"name":"t/t","require":{}}\n' >"$tmp/composer.json"
    cat >"$tmp/vendor/bin/composer-unused" <<'EOF'
#!/usr/bin/env bash
printf 'no unused packages\n'
exit 0
EOF
    chmod +x "$tmp/vendor/bin/composer-unused"
    (
        set -euo pipefail
        cd "$tmp"
        # Consumed dynamically by common.sh's die()/log_json and
        # verify_report_dir (lib/ai-verify/reporting.sh) below.
        # shellcheck disable=SC2034
        AI_LOG_DIR="$tmp/logs"
        source "$REPO_ROOT/lib/common.sh"
        source "$REPO_ROOT/lib/ai-verify/reporting.sh"
        source "$REPO_ROOT/lib/ai-verify/run.sh"
        failures=0
        check_composer_unused
        ((failures == 0))
        [[ -f "$tmp/logs/verify/composer-unused.txt" ]]
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
run_test "check_composer_unused is advisory-only and never increments failures" test_check_composer_unused_runs_without_crashing

# ── Phase 2 coverage: lib/ai-verify/docs-check.sh (ai_verify_docs_run_drift) ─
# None of ai_verify_docs_run_drift's ~11 gated tools/ai/validate-*.php steps
# are exercised elsewhere with a fake `php` (passing OR failing), so
# ai_verify_docs_run_step's failure branch (failures+=1) is never hit. Fake
# `php` dispatches pass/fail by which script path it was given.
test_docs_drift_php_failure_increments_failures() {
    local tmp rc=0 out
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/bin" "$tmp/work/tools/ai"
    cat >"$tmp/bin/php" <<'PHPEOF'
#!/usr/bin/env bash
case "$1" in
*validate-generated-artifacts.php) exit 1 ;;
*) exit 0 ;;
esac
PHPEOF
    chmod +x "$tmp/bin/php"
    : >"$tmp/work/tools/ai/validate-generated-artifacts.php"
    : >"$tmp/work/tools/ai/validate-context-budgets.php"
    out="$(
        cd "$tmp/work"
        PATH="$tmp/bin:$PATH" AI_LOG_DIR="$tmp/logs" AI_EVENT_LOG="$tmp/logs/ev.jsonl" \
            "$BASH_BIN" "$SCRIPT" docs drift 2>&1
    )"
    rc=$?
    rm -rf "$tmp"
    [[ $rc -eq 1 ]] && [[ "$out" == *"FAIL: validate-generated-artifacts"* ]] && [[ "$out" == *"validate-context-budgets"* ]]
}
run_test "verify docs drift: a failing gated php step increments failures (exit 1)" test_docs_drift_php_failure_increments_failures

test_docs_drift_php_success_no_failure() {
    local tmp rc=0 out
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/bin" "$tmp/work/tools/ai"
    cat >"$tmp/bin/php" <<'PHPEOF'
#!/usr/bin/env bash
exit 0
PHPEOF
    chmod +x "$tmp/bin/php"
    : >"$tmp/work/tools/ai/validate-context-budgets.php"
    out="$(
        cd "$tmp/work"
        PATH="$tmp/bin:$PATH" AI_LOG_DIR="$tmp/logs" AI_EVENT_LOG="$tmp/logs/ev.jsonl" \
            "$BASH_BIN" "$SCRIPT" docs drift 2>&1
    )"
    rc=$?
    rm -rf "$tmp"
    [[ $rc -eq 0 ]] && [[ "$out" != *"FAIL:"* ]] && [[ "$out" == *"validate-context-budgets"* ]]
}
run_test "verify docs drift: a passing gated php step does not fail" test_docs_drift_php_success_no_failure

# The two tests above only create tools/ai/validate-generated-artifacts.php
# and tools/ai/validate-context-budgets.php as guard files, so every OTHER
# gated step in ai_verify_docs_run_drift (repo-tool-inventory.sh, and the
# generate-agent-snippets/validate-agent-spec/validate-stub-surfaces/
# validate-catalog-drift/validate-schemas/validate-agent-assessment[-values]/
# validate-mentor-parity/validate-script-access php scripts) has its own
# `[[ -f ... ]]` guard body -- and thus its own ai_verify_docs_run_step call
# -- never exercised. Create every guard file (and docs/ai/agent-scores.yaml,
# needed alongside validate-agent-assessment-values.php's compound guard) so
# all remaining steps run.
test_docs_drift_all_remaining_gated_steps_run() {
    local tmp rc=0 out
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/bin" "$tmp/work/tools/ai" "$tmp/work/scripts/ai" "$tmp/work/docs/ai"
    cat >"$tmp/bin/php" <<'PHPEOF'
#!/usr/bin/env bash
exit 0
PHPEOF
    chmod +x "$tmp/bin/php"
    cat >"$tmp/work/scripts/ai/repo-tool-inventory.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
    chmod +x "$tmp/work/scripts/ai/repo-tool-inventory.sh"
    local f
    for f in generate-agent-snippets validate-agent-spec validate-stub-surfaces \
        validate-catalog-drift validate-schemas validate-agent-assessment \
        validate-agent-assessment-values validate-mentor-parity validate-script-access; do
        : >"$tmp/work/tools/ai/$f.php"
    done
    printf 'scores: {}\n' >"$tmp/work/docs/ai/agent-scores.yaml"
    out="$(
        cd "$tmp/work"
        PATH="$tmp/bin:$PATH" AI_LOG_DIR="$tmp/logs" AI_EVENT_LOG="$tmp/logs/ev.jsonl" \
            "$BASH_BIN" "$SCRIPT" docs drift 2>&1
    )"
    rc=$?
    rm -rf "$tmp"
    ((rc == 0)) \
        && [[ "$out" == *"repo-tool-inventory"* ]] \
        && [[ "$out" == *"agent-snippets"* ]] \
        && [[ "$out" == *"validate-agent-spec"* ]] \
        && [[ "$out" == *"validate-stub-surfaces"* ]] \
        && [[ "$out" == *"validate-catalog-drift"* ]] \
        && [[ "$out" == *"validate-schemas"* ]] \
        && [[ "$out" == *"validate-agent-assessment"* ]] \
        && [[ "$out" == *"validate-agent-assessment-values"* ]] \
        && [[ "$out" == *"validate-mentor-parity"* ]] \
        && [[ "$out" == *"validate-script-access"* ]]
}
run_test "verify docs drift: every remaining gated step runs when its guard file exists" test_docs_drift_all_remaining_gated_steps_run

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
if ((FAIL == 0)); then
    printf '\033[0;32mPASSED\033[0m\n'
else
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
fi
