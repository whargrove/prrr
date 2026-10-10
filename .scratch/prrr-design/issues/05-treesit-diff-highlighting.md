# Research: tree-sitter syntax highlighting inside a magit diff buffer

Type: research
Status: resolved
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

## Answer

**Go.** On Emacs 31 a hunk's added or removed lines can be parsed in place:
create one `treesit` parser per file section and side
(`treesit-parser-create LANG nil t TAG`) and set its included ranges to the
line bodies (prefix char excluded, newline included) of the context+`+` lines
(new side) or context+`-` lines (old side); tree-sitter treats the ranges as
one continuum, so the parser sees the file fragment and reports buffer
positions. The language's font-lock rules are obtained without enabling the
mode in the diff buffer by running its `*-ts-mode` once in an empty temp
buffer and caching the compiled `treesit-font-lock-settings` (~4 ms warm);
apply them with a small `treesit-query-capture` loop that prepends faces onto
`font-lock-face` (Magit's property; a direct `face` would hide the diff line
face). Do not use `treesit-font-lock-fontify-region` or
`treesit-range-settings`: both require a primary/host parser a diff buffer
does not have (measured: they signal `treesit-parser-p nil`).

Cost (C grammar, measured): parse+fontify 1.3 ms / 9.7 ms / 34 ms for
100 / 300 / 1,000-line file sections, 0 ms while collapsed, 0.1-1.6 ms to
fontify one hunk after its section is parsed. Eager whole-diff highlighting of
a 10k-line diff is ~400 ms, so it must be deferred until the file section is
expanded (and, for huge sections, to the hunk at point or an idle timer).

Also found: Magit 4.6.0+ has `magit-diff-fontify-hunk` (default nil,
"experimental ... synchronous"), which fontifies via a full blob buffer in the
file's major mode: ~234 ms before the first hunk of a 24k-line file. Usable as
a fallback for languages without a grammar; prrr should keep it nil otherwise.
No existing Emacs package highlights diffs with `treesit`.

Findings: [docs/research/treesit-diff-highlighting.md](../../../docs/research/treesit-diff-highlighting.md)
