# scripts/lib/cov-lines.awk
#
# Prints the line numbers of a Bash source file that Bash's DEBUG trap can
# actually fire on ("executable" lines), so coverage.sh can compute a
# meaningful denominator. Excludes: blank lines, comment-only lines,
# structural-only lines (bare `{`, `}`, `fi`, `done`, `esac`, `else`, `then`,
# `do`, `;;`), and heredoc body/terminator lines (data, not code).
BEGIN { in_heredoc = 0; delim = "" }
{
    line = $0

    if (in_heredoc) {
        term = line
        gsub(/^[ \t]+/, "", term)
        if (term == delim) in_heredoc = 0
        next
    }

    trimmed = line
    gsub(/^[ \t]+|[ \t]+$/, "", trimmed)

    executable = 1
    if (trimmed == "") executable = 0
    else if (trimmed ~ /^#/) executable = 0
    else if (trimmed ~ /^(\{|\}|fi|done|esac|else|then|do|;;|\(|\))$/) executable = 0

    if (executable) print NR

    # Detect a heredoc start (`<<DELIM`, `<<-DELIM`, `<<'DELIM'`, `<<"DELIM"`)
    # while excluding here-strings (`<<<DELIM`).
    scan = line
    gsub(/<<</, "\x01", scan)
    if (match(scan, /<<-?[ \t]*['"]?[A-Za-z_][A-Za-z0-9_]*['"]?/)) {
        tok = substr(scan, RSTART, RLENGTH)
        gsub(/^<<-?[ \t]*/, "", tok)
        gsub(/['"]/, "", tok)
        delim = tok
        in_heredoc = 1
    }
}
