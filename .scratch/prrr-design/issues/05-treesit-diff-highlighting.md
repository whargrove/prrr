# Research: tree-sitter syntax highlighting inside a magit diff buffer

Type: research
Status: open
Part of: ../map.md

## Question

Can hunks in a magit-diff-mode derived buffer be syntax-highlighted with
Emacs's built-in `treesit` on Emacs 31, per hunk or per file, at a cost that
keeps a large diff opening instantly?

Investigate primary sources: the Emacs 31 `treesit` manual (parsers on a
buffer region, `treesit-parser-set-included-ranges`, multiple parsers per
buffer, `treesit-font-lock-settings` reuse), and existing packages that
highlight diffs (`magit-delta`, `diff-hl`, `diffview`, Doom's
`magit-diff` highlighting, `treesit` based attempts if any). Determine: whether
a parser can be scoped to one hunk's added and removed lines, whether the
language's font-lock rules can be applied to that region without turning on
the major mode, what it costs, and whether it must be deferred until a file is
expanded. Report the most promising approach and a go / no-go recommendation
with the measured or documented cost.
