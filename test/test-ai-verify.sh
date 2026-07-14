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
    out="$(AI_VERIFY_TEST_MODE=0 AI_VERIFY_SCOPE=branch VERIFY_SECRETS=0 VERIFY_FULL=0 \
        ${_verify_timeout:+$_verify_timeout 20} \
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
        PATH="$tmpbin:$PATH" AI_VERIFY_TEST_MODE=0 VERIFY_SECRETS=0 VERIFY_FULL=0 \
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

# markdownlint mode
if command -v markdownlint >/dev/null 2>&1; then
    test_docs_markdownlint_mode_runs() {
        local out
        out="$(AI_LOG_DIR="$AI_VERIFY_DOCS_TEST_TMP/logs3" AI_EVENT_LOG="$AI_VERIFY_DOCS_TEST_TMP/logs3/ev.jsonl" \
            "$BASH_BIN" "$SCRIPT" docs markdownlint 2>&1 || true)"
        [[ "$out" == *"markdownlint"* ]] || [[ "$out" == *"not installed"* ]]
    }
    run_test "verify docs: markdownlint mode runs" test_docs_markdownlint_mode_runs
else
    skip_test "verify docs: markdownlint mode runs" "markdownlint not installed"
fi

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

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
if ((FAIL == 0)); then
    printf '\033[0;32mPASSED\033[0m\n'
else
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
fi
