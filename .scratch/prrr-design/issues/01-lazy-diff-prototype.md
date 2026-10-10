# Prototype: lazy per-file washing with thread sections in a magit-diff-mode buffer

Type: prototype
Status: open
Part of: ../map.md

## Question

Can a buffer derived from `magit-diff-mode` open a large diff (target: 300+
files, 20k+ changed lines, measured on a real repo) in well under a second by
rendering only the file list first and washing each file's hunks on first
expand, while still inserting Thread sections under specific lines inside
hunks, with TAB folding, `n`/`p` navigation, `magit-section` jump-to-file, and
`RET` to visit the file all working?

Build a throwaway prototype that: diffs two local refs; inserts one section
per file from `git diff --stat` output, collapsed; on expand runs
`git diff <range> -- <file>` and washes it with a copy of magit's hunk washer
modified to insert a fake Thread section after chosen line numbers; folds a
file away when marked Viewed. Record open time, expand time per file, and
whether magit's refresh (`g`) preserves fold state. Note anything in
`magit-section` that fights the design, and whether washing all files up front
is fast enough that laziness is unnecessary.

Resolution is a decision: which rendering strategy the spec commits to, with
numbers.
