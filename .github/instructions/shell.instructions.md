---
applyTo: "**/*.sh,bin/**,libexec/**,hooks/**"
---

Use Bash 4.4+ conventions unless the file declares another shell. Quote expansions, use arrays for argument lists, validate untrusted input, use `--` before positional paths where supported, and avoid `eval`. Use secure temporary directories and cleanup traps. Preserve stdout/stderr and exit-code contracts. Put reusable logic in `lib/` and keep command entry points thin. Add or update shell tests for every behavior change.
