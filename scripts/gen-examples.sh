#!/usr/bin/env bash
# Generate docs/examples/ category files and docs/EXAMPLES.md index from each
# command's own `# Example:` block, with captured OUTPUT samples.
#
# MARKER-BASED INJECTION — files are safe to hand-edit.
# ----------------------------------------------------------------------------
# Each generated file interleaves two kinds of region, fenced by invisible HTML
# comment markers:
#
#   GENERATED (owned by this script — rewritten on every run):
#     <!-- restsift:generated:NAME -->  ...auto CLI + captured output...  <!-- /restsift:generated:NAME -->
#
#   HANDWRITTEN (owned by YOU — preserved verbatim across runs):
#     <!-- restsift:handwritten:header -->  ...intro prose...  <!-- /restsift:handwritten:header -->
#     <!-- restsift:notes:NAME -->          ...per-command notes...  <!-- /restsift:notes:NAME -->
#     <!-- restsift:handwritten:footer -->  ...guides, deep dives, to END OF FILE...
#
# The footer is OPEN-ENDED: it has NO closing marker. Everything from the footer
# marker to the end of the file is yours, so anything you append at the bottom —
# the most natural place to add a guide or deep dive — is always preserved.
#
# On rerun the script refreshes only the GENERATED regions; it reads every
# handwritten region back out of the existing file and re-emits it unchanged.
# So you may freely edit the header, the footer, and each command's notes slot,
# and add as much extra prose as you like — it all survives regeneration. The
# per-command CLI blocks and captured output stay auto-synced with the source.
#
# CAVEAT: text you put INSIDE a generated:NAME region is overwritten every run
# (that content is derived from the command's source). Put your prose in the
# notes slot right below it, or in the footer — never inside a generated block.
#
# The command examples themselves live in each libexec/* script header (they
# also drive `--help`), so the generated blocks are always derivable from source
# — edit those in the script, not here.
#
# Each command gets a captured **Output** block: a safe, representative
# invocation run against a deterministic in-repo fixture (counts stable),
# normalized (fixture path → `~/demo`, timings zeroed, capped to readable height).
# Commands whose demo needs an optional tool fall back to a note instead.
#
# Generates (creating handwritten stubs on first run, preserving them after):
#   docs/examples/search.md
#   docs/examples/context.md
#   docs/examples/edit-rollback.md
#   docs/examples/test-verify.md
#   docs/examples/git-repo.md
#   docs/examples/inspect.md
#   docs/examples/session-utilities.md
#   docs/EXAMPLES.md (index)
#
# Usage:
#   bash scripts/gen-examples.sh
#
# Requires: jq, git (optional tools enrich samples but not required)
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
introspect="$repo_root/libexec/sh-introspect"
AK="$repo_root/bin/restsift"
examples_dir="$repo_root/docs/examples"

# Category mappings: command name → category file
declare -A category_map=(
    [ai-s]=search
    [ai-search]=search
    [ai-search-multi]=search
    [ai-search-introspect]=search
    [rg-code]=search
    [fd-files]=search
    [ai-context]=context
    [ai-edit]=edit-rollback
    [ai-rollback]=edit-rollback
    [session-checkpoint]=edit-rollback
    [ai-test]=test-verify
    [ai-verify]=test-verify
    [ai-git]=git-repo
    [ai-repo]=git-repo
    [ai-file-freshness]=git-repo
    [repo-stats]=git-repo
    [repo-tool-inventory]=git-repo
    [ai-inspect]=inspect
    [preview-file]=inspect
    [sh-introspect]=inspect
    [ai-structured]=inspect
    [ai-refactor-scan]=inspect
    [ai-session]=session-utilities
    [watch-loop]=session-utilities
    [ai-doctor]=session-utilities
    [ai-completion]=session-utilities
    [ai-task]=session-utilities
    [all-f-into-one]=session-utilities
)

# Category descriptions
declare -A category_desc=(
    [search]="Repository search commands"
    [context]="Context building and analysis"
    [edit-rollback]="Guarded edits and rollback"
    [test-verify]="Testing and verification"
    [git-repo]="Git and repository inspection"
    [inspect]="Code inspection and analysis"
    [session-utilities]="Session management and utilities"
)

# --- deterministic fixture project (stable output across regenerations) -------
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
make_fixture() {
    mkdir -p "$FIXTURE/src" "$FIXTURE/docs"
    cat >"$FIXTURE/README.md" <<'MD'
# Demo project

A tiny fixture used to capture example output.

TODO: wire up the CSV exporter.
TODO: add regression tests for the parser.
MD
    cat >"$FIXTURE/src/app.php" <<'PHP'
<?php
function export_data(array $rows): string {
    // TODO: stream large exports instead of buffering
    return json_encode($rows);
}
PHP
    cat >"$FIXTURE/src/util.js" <<'JS'
export function emitJson(value) {
    return JSON.stringify(value); // TODO: pretty-print on demand
}
JS
    cat >"$FIXTURE/docs/guide.md" <<'MD'
# Guide

See the [app module](../src/app.php) for the exporter.
MD
    cat >"$FIXTURE/package.json" <<'JSON'
{
  "name": "demo",
  "scripts": { "test": "jest", "build": "tsc --noEmit" }
}
JSON
    printf 'id,name\n1,alpha\n2,beta\n3,gamma\n' >"$FIXTURE/data.csv"
    (
        cd "$FIXTURE"
        git init -q
        git config user.email demo@example.com
        git config user.name demo
        git add -A
        git commit -qm "init demo fixture"
    )
}

# mask: strip ANSI colors and neutralize every volatile token (paths, timings,
# hashes, dates, snapshot/backup timestamps + PIDs, byte counts) so the captured
# output is byte-stable across regenerations. Shared by human and JSON blocks.
mask() {
    sed -e $'s/\033\\[[0-9;]*[mGKH]//g' \
        -e "s#${FIXTURE}#~/demo#g" \
        -e "s#${repo_root}#~/restsift#g" \
        -e 's/[0-9][0-9]*\.[0-9][0-9]*s/0.0s/g' \
        -e 's/[0-9]\{8\}-[0-9]\{6\}-[0-9]\{4,\}/<stamp>/g' \
        -e 's/[0-9]\{8\}-[0-9]\{6\}/<stamp>/g' \
        -e 's/-[0-9]\{6\}\.manifest/-<t>.manifest/g' \
        -e 's/"bytes": [0-9][0-9]*/"bytes": 0/g' \
        -e 's/\b[0-9a-f]\{12,40\}\b/<hash>/g' \
        -e 's/^Date:.*/Date:   <date>/' \
        -e 's/[[:space:]][[:space:]]*$//'
}

# normalize: mask + cap human output to a readable height.
normalize() { mask | awk 'NR<=14{print} END{if(NR>14) print "…"}'; }

# capture WORKDIR TIMEOUT ENVSPEC -- cmd...  -> normalized output (never fails)
capture() {
    local workdir="$1" secs="$2" envspec="$3"
    shift 3
    shift # drop the literal --
    local out quoted
    quoted="$(printf '%q ' "$@")"
    out="$(cd "$workdir" && eval "env ${envspec} timeout ${secs} ${quoted}" 2>&1)" || true
    if [[ -z "${out//[[:space:]]/}" ]]; then
        printf '# (no output)\n'
        return 0
    fi
    printf '%s\n' "$out" | normalize
}

# A one-line fallback note when a demo can't run cleanly on this host.
note() { printf '# %s\n' "$1"; }

# demo_for NAME -> the human Output block body (normalized) for the command's
# most representative safe invocation, run against $FIXTURE (or the repo).
demo_for() {
    local name="$1"
    case "$name" in
    ai-completion)
        capture "$repo_root" 10 "" -- bash "$AK" completion bash ;;
    ai-context)
        capture "$FIXTURE" 20 "" -- bash "$AK" context estimate README.md ;;
    ai-doctor)
        capture "$repo_root" 20 "" -- bash "$AK" doctor ;;
    ai-edit)
        capture "$FIXTURE" 20 "" -- bash "$AK" edit sd export_data export_rows . --dry-run ;;
    ai-file-freshness)
        (cd "$FIXTURE" && printf '\nedited\n' >>README.md)
        capture "$FIXTURE" 10 "" -- bash "$AK" file-freshness ;;
    ai-git)
        capture "$FIXTURE" 15 "" -- bash "$AK" git history S TODO README.md ;;
    ai-inspect)
        capture "$FIXTURE" 10 "" -- bash "$AK" inspect file README.md --range 1:6 ;;
    ai-refactor-scan)
        if command -v scc >/dev/null 2>&1; then
            capture "$FIXTURE" 30 "" -- bash "$AK" refactor-scan all . --no-report
        else
            note "requires scc (and lizard for NLOC); run locally to see the ranked table"
        fi ;;
    ai-repo)
        capture "$FIXTURE" 15 "" -- bash "$AK" repo stats ;;
    ai-rollback)
        capture "$FIXTURE" 15 "" -- bash "$AK" rollback list ;;
    ai-s)
        capture "$FIXTURE" 15 "" -- bash "$AK" s export_data ;;
    ai-search)
        capture "$FIXTURE" 15 "" -- bash "$AK" search text export_data . ;;
    ai-search-introspect)
        capture "$repo_root" 15 "" -- bash "$AK" search-introspect ;;
    ai-search-multi)
        capture "$FIXTURE" 15 "" -- bash "$AK" search batch text export_data emitJson . ;;
    ai-session)
        capture "$FIXTURE" 15 "" -- bash "$AK" session checkpoint demo-label ;;
    ai-structured)
        capture "$FIXTURE" 10 "" -- bash "$AK" structured json package.json '.scripts' ;;
    ai-task)
        # Showcase the todos checkbox scanner against a dedicated, self-contained
        # fixture so the progress table is meaningful and stable — kept in its own
        # temp dir so it never perturbs the other commands' shared-fixture samples.
        tdir="$(mktemp -d)"
        mkdir -p "$tdir/docs"
        printf '# Roadmap\n- [x] Draft the spec\n- [x] Review with team\n- [ ] Implement parser\n- [ ] Write tests\n- [-] Ship (blocked upstream)\n' >"$tdir/docs/roadmap.md"
        printf '# Setup\n- [x] Install deps\n- [x] Configure CI\n' >"$tdir/docs/setup.md"
        capture "$tdir" 15 "" -- bash "$AK" task todos docs
        rm -rf "$tdir" ;;
    ai-test)
        capture "$FIXTURE" 15 "" -- bash "$AK" test select changed ;;
    ai-verify)
        capture "$FIXTURE" 30 "VERIFY_SECRETS=0 VERIFY_LINKS=0" -- bash "$AK" verify docs drift README.md ;;
    all-f-into-one)
        capture "$FIXTURE" 15 "" -- bash "$AK" all-f-into-one ;;
    fd-files)
        capture "$FIXTURE" 10 "" -- bash "$AK" fd-files md docs ;;
    preview-file)
        capture "$FIXTURE" 10 "" -- bash "$AK" preview-file README.md --range 1:6 ;;
    repo-stats)
        capture "$FIXTURE" 10 "" -- bash "$AK" repo-stats ;;
    repo-tool-inventory)
        capture "$repo_root" 15 "" -- bash "$AK" repo-tool-inventory ;;
    rg-code)
        capture "$FIXTURE" 15 "" -- bash "$AK" rg-code export_data . ;;
    session-checkpoint)
        capture "$FIXTURE" 15 "" -- bash "$AK" session-checkpoint demo-label ;;
    sh-introspect)
        capture "$repo_root" 10 "" -- bash "$AK" sh-introspect libexec/ai-repo ;;
    watch-loop)
        note "blocks until Ctrl-C (re-runs on change); see 'res watch-loop --help' for the contract" ;;
    *)
        note "run 'res ${name#ai-} --help' to see this command's output" ;;
    esac
}

# demo_json NAME -> a captured AI_OUTPUT=json envelope for commands that support
# one, pretty-printed and masked; empty for commands without a JSON mode.
demo_json() {
    local name="$1" out=""
    case "$name" in
    ai-doctor) out="$(cd "$repo_root" && AI_OUTPUT=json timeout 20 bash "$AK" doctor 2>/dev/null || true)" ;;
    ai-context) out="$(cd "$FIXTURE" && AI_OUTPUT=json timeout 20 bash "$AK" context estimate README.md 2>/dev/null || true)" ;;
    ai-file-freshness) out="$(cd "$FIXTURE" && AI_OUTPUT=json timeout 10 bash "$AK" file-freshness 2>/dev/null || true)" ;;
    ai-repo | repo-stats) out="$(cd "$FIXTURE" && AI_OUTPUT=json timeout 15 bash "$AK" repo-stats 2>/dev/null || true)" ;;
    ai-rollback) out="$(cd "$FIXTURE" && AI_OUTPUT=json timeout 15 bash "$AK" rollback list 2>/dev/null || true)" ;;
    ai-s) out="$(cd "$FIXTURE" && AI_OUTPUT=json timeout 15 bash "$AK" s export_data 2>/dev/null || true)" ;;
    ai-search) out="$(cd "$FIXTURE" && AI_OUTPUT=json timeout 15 bash "$AK" search text export_data . 2>/dev/null || true)" ;;
    ai-search-introspect) out="$(cd "$repo_root" && AI_OUTPUT=json timeout 15 bash "$AK" search-introspect 2>/dev/null || true)" ;;
    ai-structured) out="$(cd "$FIXTURE" && AI_OUTPUT=json timeout 10 bash "$AK" structured validate-json package.json 2>/dev/null || true)" ;;
    ai-task)
        tdir="$(mktemp -d)"
        mkdir -p "$tdir/docs"
        printf '# Roadmap\n- [x] Draft the spec\n- [x] Review with team\n- [ ] Implement parser\n- [ ] Write tests\n- [-] Ship (blocked upstream)\n' >"$tdir/docs/roadmap.md"
        printf '# Setup\n- [x] Install deps\n- [x] Configure CI\n' >"$tdir/docs/setup.md"
        out="$(cd "$tdir" && timeout 15 bash "$AK" task todos docs --json 2>/dev/null || true)"
        rm -rf "$tdir" ;;
    all-f-into-one) out="$(cd "$FIXTURE" && AI_OUTPUT=json timeout 15 bash "$AK" all-f-into-one 2>/dev/null || true)" ;;
    fd-files) out="$(cd "$FIXTURE" && AI_OUTPUT=json timeout 10 bash "$AK" fd-files md docs 2>/dev/null || true)" ;;
    preview-file) out="$(cd "$FIXTURE" && AI_OUTPUT=json timeout 10 bash "$AK" preview-file README.md --range 1:3 2>/dev/null || true)" ;;
    repo-tool-inventory) out="$(cd "$repo_root" && AI_OUTPUT=json timeout 15 bash "$AK" repo-tool-inventory 2>/dev/null || true)" ;;
    session-checkpoint) out="$(cd "$FIXTURE" && AI_OUTPUT=json timeout 15 bash "$AK" session-checkpoint demo 2>/dev/null || true)" ;;
    sh-introspect) out="$(cd "$repo_root" && timeout 10 bash "$AK" sh-introspect --format=json libexec/ai-repo 2>/dev/null || true)" ;;
    *) return 0 ;;
    esac
    [[ -n "${out//[[:space:]]/}" ]] || return 0
    printf '%s' "$out" | jq -S . 2>/dev/null | mask |
        awk 'NR<=18{print} END{if(NR>18) print "  …"}'
}

make_fixture
mkdir -p "$examples_dir"

# ---------------------------------------------------------------------------
# Marker helpers
# ---------------------------------------------------------------------------
HDR_S='<!-- restsift:handwritten:header -->'
HDR_E='<!-- /restsift:handwritten:header -->'
# The footer is OPEN-ENDED: everything from FTR_S to end-of-file is yours. There
# is deliberately no closing marker, so anything you append at the bottom of the
# file — the most natural place to add a guide or deep dive — is always kept.
# FTR_E is only referenced to strip the legacy closing marker off files written
# by an earlier version of this script.
FTR_S='<!-- restsift:handwritten:footer -->'
FTR_E='<!-- /restsift:handwritten:footer -->'

gen_s()   { printf '<!-- restsift:generated:%s -->' "$1"; }
gen_e()   { printf '<!-- /restsift:generated:%s -->' "$1"; }
notes_s() { printf '<!-- restsift:notes:%s -->' "$1"; }
notes_e() { printf '<!-- /restsift:notes:%s -->' "$1"; }

# extract_region FILE START END -> inner lines (markers excluded), empty if absent.
extract_region() {
    awk -v s="$2" -v e="$3" '
        $0==s { f=1; next }
        $0==e { f=0; next }
        f     { print }
    ' "$1"
}
# extract_to_eof FILE START -> every line after the START marker to end of file
# (START marker excluded). Used for the open-ended footer. Any legacy FTR_E
# closing marker is stripped so migrated files do not keep a dangling marker.
extract_to_eof() {
    awk -v s="$2" '
        f { print }
        $0==s { f=1 }
    ' "$1" | grep -vFx "$FTR_E" || true
}
has_marker() { grep -qF "$2" "$1" 2>/dev/null; }

# default_notes NAME -> a stub comment shown until you write real notes.
default_notes() {
    printf '<!-- Add hand-written notes for `res %s` here — caveats, gotchas, or\n' "${1#ai-}"
    printf '     real-world recipes. Everything between the notes markers is kept\n'
    printf '     verbatim when scripts/gen-examples.sh reruns. -->'
}

# build_gen_block NAME JSON DESC -> the auto-generated body for one command.
build_gen_block() {
    local name="$1" json="$2" desc="$3" human jsonout
    printf '### `res %s`\n' "${name#ai-}"
    [[ -n "$desc" ]] && printf '%s\n' "$desc"
    printf '\n```bash\n'
    printf '%s' "$json" | jq -r '.examples[]?' | sed -E 's/\brestsift /res /g'
    printf '```\n'
    human="$(demo_for "$name")"
    if [[ -n "${human//[[:space:]]/}" ]]; then
        printf '\n_Output:_\n\n```\n%s\n```\n' "$human"
    fi
    jsonout="$(demo_json "$name")"
    if [[ -n "${jsonout//[[:space:]]/}" ]]; then
        printf '\n_Machine-readable (`AI_OUTPUT=json`):_\n\n```json\n%s\n```\n' "$jsonout"
    fi
}

# ---------------------------------------------------------------------------
# Collect fresh generated blocks per command, grouped by category (sorted).
# ---------------------------------------------------------------------------
declare -A gen_block
declare -A category_cmds

while IFS= read -r f; do
    name=$(basename "$f")
    json=$(bash "$introspect" --format=json "$f" 2>/dev/null || true)
    [[ -n "$json" ]] || continue
    category="${category_map[$name]:-}"
    [[ -n "$category" ]] || continue
    desc=$(printf '%s' "$json" | jq -r '.description // ""')
    gen_block[$name]="$(build_gen_block "$name" "$json" "$desc")"
    category_cmds[$category]+="$name "
done < <(find "$repo_root/libexec" -maxdepth 1 -type f | sort)

# ---------------------------------------------------------------------------
# Render each category file, preserving handwritten header/footer/notes.
# ---------------------------------------------------------------------------
for category in search context edit-rollback test-verify git-repo inspect session-utilities; do
    [[ -n "${category_cmds[$category]:-}" ]] || continue
    file="$examples_dir/${category}.md"
    read -r -a cmds <<<"${category_cmds[$category]}"

    cmd_list=$(printf '%s\n' "${cmds[@]}" | sed 's/^ai-//; s/^/`res /; s/$/`/' | paste -sd ',' - | sed 's/,/, /g')

    # Preserve handwritten header/footer if the file already carries markers,
    # otherwise seed an editable stub (also migrates old marker-less files).
    if [[ -f "$file" ]] && has_marker "$file" "$HDR_S"; then
        header_body="$(extract_region "$file" "$HDR_S" "$HDR_E")"
    else
        header_body="$(printf '\n> Hand-written intro for this category. Edit anything between the header\n> markers (add prose, links, a diagram); it survives `bash scripts/gen-examples.sh`.')"
    fi
    if [[ -f "$file" ]] && has_marker "$file" "$FTR_S"; then
        footer_body="$(extract_to_eof "$file" "$FTR_S")"
    else
        footer_body="$(printf '\n<!-- Everything from this marker to the end of the file is yours. Add\n     guides, advanced usage, or deep dives below — no closing marker, so\n     anything you append at the bottom always survives regeneration. -->')"
    fi

    tmp="$(mktemp)"
    {
        # Always-fresh title + command list.
        printf '%s\n' "$(gen_s _title)"
        printf '# %s\n\n' "${category_desc[$category]}"
        printf 'Commands: %s\n' "$cmd_list"
        printf '%s\n\n' "$(gen_e _title)"

        # Preserved handwritten header.
        printf '%s\n%s\n%s\n\n' "$HDR_S" "$header_body" "$HDR_E"

        # Per command: fresh generated block + preserved notes slot.
        for name in "${cmds[@]}"; do
            printf '%s\n%s\n%s\n\n' "$(gen_s "$name")" "${gen_block[$name]}" "$(gen_e "$name")"

            if [[ -f "$file" ]] && has_marker "$file" "$(notes_s "$name")"; then
                notes_body="$(extract_region "$file" "$(notes_s "$name")" "$(notes_e "$name")")"
            else
                notes_body="$(default_notes "$name")"
            fi
            printf '%s\n%s\n%s\n\n' "$(notes_s "$name")" "$notes_body" "$(notes_e "$name")"
        done

        # Preserved handwritten footer (open-ended: FTR_S to end of file).
        printf '%s\n%s\n' "$FTR_S" "$footer_body"
    } >"$tmp"
    mv "$tmp" "$file"
done

# ---------------------------------------------------------------------------
# Render the index (docs/EXAMPLES.md), preserving its handwritten intro/footer.
# ---------------------------------------------------------------------------
index_file="$repo_root/docs/EXAMPLES.md"
index_order=(search context edit-rollback test-verify git-repo inspect session-utilities)
declare -A index_title=(
    [search]="Repository Search"
    [context]="Context Building"
    [edit-rollback]="Guarded Edits & Rollback"
    [test-verify]="Testing & Verification"
    [git-repo]="Git & Repository"
    [inspect]="Code Inspection"
    [session-utilities]="Session & Utilities"
)
declare -A index_blurb=(
    [search]='`search`, `rg-code`, `fd-files`, and text search variants'
    [context]='Bundle and pack repository context'
    [edit-rollback]='Safe edits with snapshots and rollback'
    [test-verify]='Test selection and project verification'
    [git-repo]='Git history, PR context, repository metadata'
    [inspect]='Analyze files, scripts, and refactor candidates'
    [session-utilities]='Session checkpoints, watchers, and tools'
)

if [[ -f "$index_file" ]] && has_marker "$index_file" "$HDR_S"; then
    index_header="$(extract_region "$index_file" "$HDR_S" "$HDR_E")"
else
    index_header="$(cat <<'EOF'

# Examples

One runnable example per command — generated from each command's own
`# Example:` block — plus a **captured output** sample so you can see what each
command actually prints before you run it.

These snippets use the short **`res`** alias, which every installer creates
alongside the canonical `restsift`. They work verbatim after any install — no
setup needed. For the everyday search case, `res s QUERY` is even shorter: it
defaults to text mode and auto-detects the repo root, so `res s TODO` replaces
`res search text TODO .`.

The canonical command is `restsift` — the two are interchangeable, so replace
`res` with `restsift` anywhere you prefer the long form (e.g. in scripts). The
authoritative contract for any command is always `restsift <command> --help`
(and `--introspect` for JSON).

**About the output blocks:** each was captured by running the command against a
small fixture project (paths shown as `~/demo`, timings zeroed for stability).
Every command whose contract supports it also honors `AI_OUTPUT=json` (or
`--json`) for a stable `ai.<tool>/v1` envelope; the human output above stays
byte-identical. Samples that need an optional tool (e.g. `scc`, `lizard`,
security scanners) show a note when it is not installed.

> Regenerate these files with: `bash scripts/gen-examples.sh` — your
> hand-written intros, footers, and per-command notes are preserved.
EOF
)"
fi

if [[ -f "$index_file" ]] && has_marker "$index_file" "$FTR_S"; then
    index_footer="$(extract_to_eof "$index_file" "$FTR_S")"
else
    index_footer="$(printf '\nFor a complete list of all commands and their capabilities, see [COMMANDS.md](COMMANDS.md) or run `restsift --list`.')"
fi

tmp="$(mktemp)"
{
    printf '%s\n%s\n%s\n\n' "$HDR_S" "$index_header" "$HDR_E"
    printf '%s\n' "$(gen_s index)"
    printf '## Examples by category\n\n'
    for c in "${index_order[@]}"; do
        printf -- '- [%s](examples/%s.md) — %s\n' "${index_title[$c]}" "$c" "${index_blurb[$c]}"
    done
    printf '%s\n\n' "$(gen_e index)"
    # Open-ended footer: FTR_S to end of file, no closing marker.
    printf '%s\n%s\n' "$FTR_S" "$index_footer"
} >"$tmp"
mv "$tmp" "$index_file"

echo "[✓] Generated docs/EXAMPLES.md and category files in docs/examples/ (handwritten regions preserved)" >&2
