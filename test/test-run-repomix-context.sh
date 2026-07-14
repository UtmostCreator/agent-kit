#!/usr/bin/env bash
# Tests for libexec/internal/run-repomix-context
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/internal/run-repomix-context"
cd "$REPO_ROOT"
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

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

printf 'run-repomix-context\n'

# --help
test_help() { "$BASH_BIN" "$SCRIPT" --help 2>&1 | grep -q 'Usage'; }
run_test "help flag works" test_help

# --help routes through the uniform sh-introspect --format=help view. It surfaces
# the description, Usage, and a runnable Example parsed from the script header.
test_help_examples() {
    local out
    out="$($BASH_BIN "$SCRIPT" --help 2>&1)"
    [[ "$out" == *"Usage:"* ]]
    [[ "$out" == *"Example:"* ]]
    [[ "$out" == *"run-repomix-context"* ]]
}
run_test "help shows usage and a runnable example" test_help_examples

# Delegates to repomix-context-tree
if command -v scc >/dev/null 2>&1 && command -v repomix >/dev/null 2>&1; then
    test_runs() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" . --top 1 2>&1 || true)"
        [[ -n "$out" ]]
    }
    run_test "delegates to repomix-context-tree" test_runs

    # run-manifest.json content: re-run against a small, clean fixture repo (not
    # this toolkit's own tree) and assert the written manifest's shape/values.
    test_run_manifest_content() {
        local fix manifest
        fix="$(mktemp -d)"
        printf 'package main\nfunc main() {}\n' >"$fix/main.go"
        printf 'echo one\necho two\necho three\necho four\necho five\necho six\necho seven\necho eight\necho nine\necho ten\necho a\necho b\necho c\necho d\necho e\necho f\necho g\necho h\necho i\necho j\necho k\necho l\necho m\necho n\necho o\n' >"$fix/lots.sh"
        ( cd "$fix" && git init -q && git add -A \
            && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1
        "$BASH_BIN" "$SCRIPT" "$fix" --top 0 >/dev/null 2>&1
        manifest="$fix/.repomix-context/tree-context/run-manifest.json"
        [[ -f "$manifest" ]] || return 1
        [[ "$(jq -r '.root' "$manifest")" == "$fix" ]] || return 1
        [[ "$(jq -r '.bundles' "$manifest")" == "$fix/.repomix-context/tree-context/bundles" ]] || return 1
        [[ "$(jq -r '.bundle_count' "$manifest")" -gt 0 ]] || return 1
        [[ -n "$(jq -r '.ts' "$manifest")" ]] || return 1
    }
    run_test "run-manifest.json has root/index/plan/manifest/bundles/bundle_count/ts" test_run_manifest_content
else
    skip_test "delegates to repomix-context-tree" "scc or repomix not installed"
    skip_test "run-manifest.json has root/index/plan/manifest/bundles/bundle_count/ts" "scc or repomix not installed"
fi

# require_bins failure: strip a required binary (scc) from PATH and confirm the
# script dies with require_bins' "required tools not found" message before
# doing anything destructive.
build_path_without() {
    local fakebin="$1"
    shift
    mkdir -p "$fakebin"
    local dir f base skip ex
    local -a dirs=()
    IFS=':' read -ra dirs <<<"$PATH"
    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*; do
            [[ -x "$f" && -f "$f" ]] || continue
            base="$(basename "$f")"
            skip=0
            for ex in "$@"; do
                [[ "$base" == "$ex" ]] && {
                    skip=1
                    break
                }
            done
            ((skip == 1)) && continue
            [[ -e "$fakebin/$base" ]] && continue
            ln -sf "$f" "$fakebin/$base" 2>/dev/null || true
        done
    done
}

test_require_bins_missing_scc() {
    local fakebin out
    fakebin="$(mktemp -d)/fakebin-no-scc"
    build_path_without "$fakebin" scc
    out="$(PATH="$fakebin" "$BASH_BIN" "$SCRIPT" . --top 1 2>&1)"
    local rc=$?
    [[ $rc -ne 0 ]] && [[ "$out" == *"required tools not found"* ]] && [[ "$out" == *"scc"* ]]
}
run_test "require_bins dies with 'required tools not found' when scc is missing" test_require_bins_missing_scc

# secrets-scan failure: a committed fake RSA private key reliably trips
# gitleaks' default private-key rule (a plain AWS-example key in a .env file
# does not, by default rule set — verified empirically).
if command -v gitleaks >/dev/null 2>&1; then
    test_secrets_scan_failure() {
        local secroot out
        secroot="$(mktemp -d)"
        (cd "$secroot" && git init -q) >/dev/null 2>&1
        cat >"$secroot/id_rsa" <<'EOF'
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA1c7+9z5Pad7OejecsQ0bu3aumgIJYowaXlrIrGuFdEwzhpvzB4rF7QNcYAyPFA82OGdlgnfnb4qqOgpm0lZcbGRb3+VBrO0LkVUiB6/HLnu5vXA4mzhqYzHTiJgxVLoyvpXFJvpV5cN/hkbA5PfPMx==
-----END RSA PRIVATE KEY-----
EOF
        (cd "$secroot" && git add -A \
            && git -c user.email=t@t -c user.name=t commit -qm "add key") >/dev/null 2>&1
        out="$("$BASH_BIN" "$SCRIPT" "$secroot" --top 1 2>&1)"
        local rc=$?
        [[ $rc -ne 0 ]] && [[ "$out" == *"secrets detected"* ]]
    }
    run_test "require_clean_secret_scan dies when a committed secret is detected" test_secrets_scan_failure
else
    skip_test "require_clean_secret_scan dies when a committed secret is detected" "gitleaks not installed"
fi

# Missing generated index/plan/manifest/bundles and bundle_count==0 die
# branches: none of these are reachable through the normal command path (a
# "successful" repomix-context-tree run always leaves all four artifacts
# behind, or itself fails first). Copy this script into a throwaway
# libexec/internal-shaped tree next to a real lib/ (via symlink) so SCRIPT_DIR
# resolution still works, and swap in a stub repomix-context-tree that exits 0
# without producing some/all of the expected artifacts, to reach each die
# branch directly.
build_fake_tree_root() {
    local fakeroot="$1"
    mkdir -p "$fakeroot/libexec/internal"
    ln -sfn "$REPO_ROOT/lib" "$fakeroot/lib"
    cp "$SCRIPT" "$fakeroot/libexec/internal/run-repomix-context"
    chmod +x "$fakeroot/libexec/internal/run-repomix-context"
}

test_die_missing_index() {
    local fakeroot cleanroot
    fakeroot="$(mktemp -d)"
    cleanroot="$(mktemp -d)"
    (cd "$cleanroot" && git init -q && printf 'hi\n' >f.txt && git add -A \
        && git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1
    build_fake_tree_root "$fakeroot"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$fakeroot/libexec/internal/repomix-context-tree"
    chmod +x "$fakeroot/libexec/internal/repomix-context-tree"
    local out
    out="$("$BASH_BIN" "$fakeroot/libexec/internal/run-repomix-context" "$cleanroot" --top 1 2>&1)"
    local rc=$?
    [[ $rc -ne 0 ]] && [[ "$out" == *"missing generated index"* ]]
}
run_test "die: missing generated index when the tree script writes nothing" test_die_missing_index

test_die_missing_plan() {
    local fakeroot cleanroot
    fakeroot="$(mktemp -d)"
    cleanroot="$(mktemp -d)"
    (cd "$cleanroot" && git init -q && printf 'hi\n' >f.txt && git add -A \
        && git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1
    build_fake_tree_root "$fakeroot"
    cat >"$fakeroot/libexec/internal/repomix-context-tree" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$2/.repomix-context/tree-context"
printf x >"$2/.repomix-context/tree-context/index.md"
exit 0
EOF
    chmod +x "$fakeroot/libexec/internal/repomix-context-tree"
    local out
    out="$("$BASH_BIN" "$fakeroot/libexec/internal/run-repomix-context" "$cleanroot" --top 1 2>&1)"
    local rc=$?
    [[ $rc -ne 0 ]] && [[ "$out" == *"missing generated plan"* ]]
}
run_test "die: missing generated plan when only the index was written" test_die_missing_plan

test_die_missing_manifest() {
    local fakeroot cleanroot
    fakeroot="$(mktemp -d)"
    cleanroot="$(mktemp -d)"
    (cd "$cleanroot" && git init -q && printf 'hi\n' >f.txt && git add -A \
        && git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1
    build_fake_tree_root "$fakeroot"
    cat >"$fakeroot/libexec/internal/repomix-context-tree" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$2/.repomix-context/tree-context"
printf x >"$2/.repomix-context/tree-context/index.md"
printf '{}' >"$2/.repomix-context/tree-context/tree-plan.json"
exit 0
EOF
    chmod +x "$fakeroot/libexec/internal/repomix-context-tree"
    local out
    out="$("$BASH_BIN" "$fakeroot/libexec/internal/run-repomix-context" "$cleanroot" --top 1 2>&1)"
    local rc=$?
    [[ $rc -ne 0 ]] && [[ "$out" == *"missing generated manifest"* ]]
}
run_test "die: missing generated manifest when index+plan were written" test_die_missing_manifest

test_die_missing_bundles_dir() {
    local fakeroot cleanroot
    fakeroot="$(mktemp -d)"
    cleanroot="$(mktemp -d)"
    (cd "$cleanroot" && git init -q && printf 'hi\n' >f.txt && git add -A \
        && git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1
    build_fake_tree_root "$fakeroot"
    cat >"$fakeroot/libexec/internal/repomix-context-tree" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$2/.repomix-context/tree-context"
printf x >"$2/.repomix-context/tree-context/index.md"
printf '{}' >"$2/.repomix-context/tree-context/tree-plan.json"
printf '{}' >"$2/.repomix-context/tree-context/tree-manifest.json"
exit 0
EOF
    chmod +x "$fakeroot/libexec/internal/repomix-context-tree"
    local out
    out="$("$BASH_BIN" "$fakeroot/libexec/internal/run-repomix-context" "$cleanroot" --top 1 2>&1)"
    local rc=$?
    [[ $rc -ne 0 ]] && [[ "$out" == *"missing generated bundles directory"* ]]
}
run_test "die: missing generated bundles directory when index+plan+manifest were written" test_die_missing_bundles_dir

test_die_bundle_count_zero() {
    local fakeroot cleanroot
    fakeroot="$(mktemp -d)"
    cleanroot="$(mktemp -d)"
    (cd "$cleanroot" && git init -q && printf 'hi\n' >f.txt && git add -A \
        && git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1
    build_fake_tree_root "$fakeroot"
    cat >"$fakeroot/libexec/internal/repomix-context-tree" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$2/.repomix-context/tree-context/bundles"
printf x >"$2/.repomix-context/tree-context/index.md"
printf '{}' >"$2/.repomix-context/tree-context/tree-plan.json"
printf '{}' >"$2/.repomix-context/tree-context/tree-manifest.json"
exit 0
EOF
    chmod +x "$fakeroot/libexec/internal/repomix-context-tree"
    local out
    out="$("$BASH_BIN" "$fakeroot/libexec/internal/run-repomix-context" "$cleanroot" --top 1 2>&1)"
    local rc=$?
    [[ $rc -ne 0 ]] && [[ "$out" == *"no context bundles generated"* ]]
}
run_test "die: bundle_count == 0 when the bundles directory is empty" test_die_bundle_count_zero

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
if ((FAIL == 0)); then
    printf '\033[0;32mPASSED\033[0m\n'
else
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
fi
