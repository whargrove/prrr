# Prototype: lazy per-file washing with thread sections in a magit-diff-mode buffer

Type: prototype
Status: resolved
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

## Answer

Resolved 2026-10-10 by the human trying the prototype: "looks great and the
performance is acceptable as a baseline".

Decision: the Review Buffer derives from `magit-diff-mode` and renders
**hybrid lazy**. On open it inserts one collapsed section per changed file
from `git diff --numstat`, then auto-expands from the top until a budget of
about 30 files or 2,000 changed lines (about 100 ms); every other file is
washed on first expand. Threads and File Comments are real child sections
(types `thread` and `file-comment`) inserted by a copy of magit's hunk washer.
Eager washing of everything is ruled out above a few hundred files.

Measured (Emacs 31.1, rails, 118 / 417 / 861 / 2516 files): open with file
list only 31 / 65 / 113 / 355 ms; expand one file 2 to 7 ms (117 to 134 ms for
a 20k-line file); expand-all 269 ms / 1.3 s / 4.4 s / 46 s; refresh with 3
files expanded 25 / 179 / 691 / 3500 ms. Stock `magit-diff-range` on the same
ranges: 213 ms / 7.0 s (417 / 2516). Refresh preserves expanded files, folded
Threads, and Viewed at every size. `RET` visits the blob at the correct line
on refs, including lines after a Thread.

Constraints the spec must carry (from "What fought the design"):
- Deferred section bodies use `magit-insert-section-body`; `magit-git-wash`
  cannot run inside one (its cancel throws to a missing catch), so use
  `magit-git-insert` plus narrowing.
- magit's hunk painting (`magit-section-paint`) and line mapping
  (`magit-diff-hunk-line`) assume hunks have no children: needs a mode-scoped
  `&context` method and one `:around` advice. `magit-diff--hunk-section`
  (internal) takes a file's first child as its first hunk: advised so a
  File Comment can come first.
- Visibility across refresh rides on `magit-section-visibility-cache`;
  restrict `magit-section-cache-visibility` to the file and thread types.
  Viewed lives in prrr's own state, not the visibility cache.
- Resolve the Range's merge base once and diff `BASE..HEAD -- FILE` per file
  (`A...B` per file recomputes the merge base, 45% of expand-all).
- Use `magit-section-inhibit-markers` `'delay` for the file list.

Primary source: branch `prototype/lazy-diff` (throwaway), files
`prototype/prrr-proto-lazy-diff.el`, `prototype/bench.el`,
`prototype/run.sh`, `prototype/RESULTS.md`. Run with `prototype/run.sh`.
