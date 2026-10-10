# Research: tree-sitter syntax highlighting inside a magit diff buffer

Ticket: `.scratch/prrr-design/issues/05-treesit-diff-highlighting.md`
Date: 2026-10-10
Environment measured: GNU Emacs 31.1 (`treesit-library-abi-version` 15,
libtree-sitter 0.26), Arch Linux, only the `c` and `lua` grammars installed
system-wide (`/usr/lib/libtree-sitter-c.so`). All numbers below are from the C
grammar in `emacs --batch`.

## Question

Can hunks in a `magit-diff-mode` derived buffer be syntax-highlighted with
Emacs 31's built-in `treesit`, per hunk or per file, at a cost that keeps a
large diff opening instantly?

## Short answer

**Go.** Yes: a parser can be scoped to the added (or removed) lines of a
hunk/file with `treesit-parser-set-included-ranges`; a language's
`treesit-font-lock-settings` can be obtained and applied without turning on
the major mode in the diff buffer; and the cost is small when deferred to
file-section expansion (about 1-2 ms per 100 diff lines on this machine,
measured). Doing it eagerly for a whole large diff costs roughly 35 ms per
1000 diff lines (parse of both sides + fontify), so it must be deferred. Full
details in "Recommendation".

Two things found on the way that change the picture:

1. Magit 4.6.0+ already ships hunk syntax highlighting
   (`magit-diff-fontify-hunk`, default `nil`, "experimental ... synchronous").
   It uses blob buffers in the file's normal major mode plus
   `diff-syntax-fontify-props` from `diff-mode.el`; if the user's
   `major-mode-remap-alist` maps to `*-ts-mode`, it is already tree-sitter
   highlighting, just not scoped to hunks. See "Prior art".
2. No existing Emacs package highlights diffs with `treesit` directly (searches
   below found none); the in-buffer included-ranges design proposed here is
   new ground, but every primitive it needs is documented.

## Sources

Primary (read in full for the parts cited):

- Elisp manual, Emacs 31.1, local info nodes:
  - `(elisp) Using Parser` -- <https://www.gnu.org/software/emacs/manual/html_node/elisp/Using-Parser.html>
  - `(elisp) Multiple Languages` -- <https://www.gnu.org/software/emacs/manual/html_node/elisp/Multiple-Languages.html>
  - `(elisp) Parser-based Font Lock` -- <https://www.gnu.org/software/emacs/manual/html_node/elisp/Parser_002dbased-Font-Lock.html>
  - `(elisp) Tree-sitter Major Modes`, `(elisp) Language Grammar`,
    `(elisp) Special Properties`, `(elisp) Examining Properties`
- `treesit.el` from the installed Emacs 31.1
  (`/usr/share/emacs/31.1/lisp/treesit.el.gz`, 6138 lines). Line numbers
  below refer to that file.
- `c-ts-mode.el` (`/usr/share/emacs/31.1/lisp/progmodes/c-ts-mode.el.gz`).
- `diff-mode.el` (`/usr/share/emacs/31.1/lisp/vc/diff-mode.el.gz`).
- Magit 4.7.1 as installed (`~/.emacs.d/var/elpa/magit-4.7.1/magit-diff.el`,
  `magit-files.el`, `magit.info`, `CHANGELOG`) and magit-section 4.7.1
  (`~/.emacs.d/var/elpa/magit-section-4.7.1/magit-section.el`).
- magit-delta source and README:
  <https://github.com/dandavison/magit-delta> (`magit-delta.el` on `master`).
- diff-ansi README: <https://codeberg.org/ideasman42/emacs-diff-ansi>.
- elta-diff README and `elta-diff.el`:
  <https://codeberg.org/ideasman42/emacs-elta-diff>.
- Measurements: `emacs --batch` scripts (reproduced in the appendix), run on a
  24,310-line concatenation of glibc headers as the "C file".

Secondary / unverified:

- diffs.nvim (Neovim). Its host `git.barrettruth.com` did not resolve from
  here; only a search-engine summary of its README was available. Marked
  unverified where cited.
- Web searches (several phrasings, 2026-10-10) for an Emacs package that
  applies `treesit` to diff buffers: none found. Absence is not proof.

## Findings

### 1. What `treesit` gives us (parsers, ranges, laziness)

- A parser is tied to a buffer and a language: `treesit-parser-create
  LANGUAGE &optional BUFFER NO-REUSE TAG`. TAG "can be any symbol except
  `t`"; "Different parsers can have the same tag"; by default an existing
  parser for the same LANGUAGE+TAG is reused unless NO-REUSE. [`(elisp) Using
  Parser`]
  => prrr can hold several C parsers in one buffer (e.g. tag = `(file . side)`)
  and find them again with `treesit-parser-list BUFFER LANGUAGE TAG`.
- Parsing is lazy: "when a parser is first created, it doesn't parse the
  buffer; it waits until the Lisp program queries for a node for the first
  time." Creating parsers is therefore free until first query. [`(elisp) Using
  Parser`]
- "Every time a change is made to the buffer, Emacs updates parsers in this
  list so they can update their syntax tree incrementally." [`(elisp) Using
  Parser`] Measured: an insert at `point-max` with 306 parsers present cost
  0.0 ms (parsers only mark themselves dirty; nothing reparses until queried).
- Included ranges: `treesit-parser-set-included-ranges PARSER RANGES` makes
  the parser "only read the text of the specified ranges"; ranges are
  `(BEG . END)` conses, "must come in order and must not overlap", else
  `treesit-range-invalid`; `nil` restores whole-buffer parsing. [`(elisp)
  Multiple Languages`]
- Crucially for diffs: "By default, a parser sees its ranges as a continuum,
  rather than treating them as separate independent segments." [`(elisp)
  Multiple Languages`, under `treesit-range-rules`] So if the ranges are
  "every context and `+` line of a file section, minus the leading prefix
  character, including the newline", the parser sees exactly the new-side
  fragment of that file; the old side is a second parser over context and `-`
  lines. Verified in batch: with buffer text `+int main(void) { return 0; }`
  and range `(14 . 43)`, the root is `translation_unit` whose first child is a
  `function_definition` at buffer positions 14-42 with text
  `int main(void) { return 0; }` -- node positions are buffer positions, so
  faces can be applied directly.
- Narrowing is explicitly discouraged as the mechanism: "modes should not use
  narrowing as a means to handle a multi-language buffer; instead, set the
  ranges". [`(elisp) Using Parser`]
- `treesit-ready-p LANGUAGE QUIET` checks build support, grammar presence and
  buffer size (`treesit-max-buffer-size`). [`(elisp) Tree-sitter Major
  Modes`] Grammar lookup order: `treesit-extra-load-path`,
  `user-emacs-directory/tree-sitter`, system library dirs. [`(elisp) Language
  Grammar`] On this machine only `c` and `lua` are installed; prrr must
  degrade to no highlighting when `treesit-ready-p` is nil.
- `treesit-parse-string` exists but the manual says "Do not use this function
  in a loop ... for heavy workload, use a temporary buffer instead" and the
  result cannot be updated. [`(elisp) Using Parser`] Not suitable.
- Only Haskell is known to need line/column tracking
  (`treesit-languages-require-line-column-tracking`); once a buffer starts
  tracking "it never stops". [`(elisp) Using Parser`] A caveat for a Haskell
  hunk in a huge diff buffer; unmeasured.

### 2. Reusing a language's font-lock rules without turning on its major mode

- `treesit-font-lock-settings` is buffer-local; "One should always use
  `treesit-font-lock-rules` to set this variable"; accessors exist for each
  field (`treesit-font-lock-setting-query`, `-feature`, `-enable`,
  `-override`, `-reversed`, `-language`). [`(elisp) Parser-based Font Lock`;
  treesit.el:1474-1530] The internal shape is
  `(QUERY ENABLE FEATURE OVERRIDE REVERSE LANGUAGE)` (treesit.el:1486, marked
  internal).
- Major modes set it in their body, e.g. `c-ts-mode` does
  `(setq-local treesit-font-lock-settings (c-ts-mode--font-lock-settings 'c))`
  then `(treesit-major-mode-setup)` (c-ts-mode.el:1504-1508).
  `treesit-major-mode-setup` copies the list, sets `font-lock-defaults` to
  route `font-lock-fontify-syntactically-function` to
  `treesit-font-lock-fontify-region`, and calls
  `treesit-font-lock-recompute-features`, which sets ENABLE per
  `treesit-font-lock-level`/`treesit-font-lock-feature-list` and compiles the
  queries (treesit.el:4680-4720, 1840-1898).
- Therefore the generic way to get *any* `*-ts-mode`'s compiled, level-aware
  settings is to run the mode once in an empty temp buffer and read
  `treesit-font-lock-settings` out of it. Compiled queries are language
  objects, not buffer objects, so they can be used from another buffer
  (verified: settings compiled in a temp buffer drove queries in the diff
  buffer in the benchmark). Measured cost: `(c-ts-mode)` in an empty temp
  buffer = 17 ms first time (includes loading), 3.6-4.5 ms on later calls.
  Cache per language.
- Can `treesit-font-lock-fontify-region` itself be reused? It does three
  things that bite in a magit buffer (treesit.el:2160-2212):
  1. calls `(treesit-update-ranges start end)`, which iterates
     `treesit-range-settings` with `(list treesit-primary-parser)` as hosts
     (treesit.el:1340-1364) and `treesit--update-range-1` evaluates
     `(treesit-parser-language host-parser)` for every setting
     (treesit.el:1316). Measured: with a function range setting and nil
     `treesit-primary-parser` it signals
     `(wrong-type-argument treesit-parser-p nil)`;
  2. calls `(font-lock-unfontify-region start end)`, which strips the `face`
     property in the region;
  3. computes "fast mode" from `(treesit-parser-root-node
     treesit-primary-parser)` (treesit.el:2185). Measured: with settings
     present but nil `treesit-primary-parser` it signals the same error;
     after `(setq treesit-primary-parser ...)` it works and applied
     `font-lock-type-face` via the `face` property.
  It also only fontifies with `(treesit-parser-list)` + local parsers, i.e.
  every parser in the buffer regardless of file, and applies faces through
  `treesit-fontify-with-override`, which writes the **`face`** text property
  (treesit.el:2019-2045).
- Magit paints hunk lines with the **`font-lock-face`** text property
  (`magit-diff-paint-hunk`, magit-diff.el:3751:
  `(put-text-property bol (1+ eol) 'font-lock-face line-face)`) and
  magit-section sets `font-lock-defaults '(nil t)` precisely to turn off
  syntactic font-lock while keeping `font-lock-face` honoured
  (magit-section.el:496, "Turn off syntactic font locking. See #5420").
  The manual: `font-lock-face` "specifies a value for the `face` property
  that Font Lock mode should apply" [`(elisp) Special Properties`], and
  property aliases are consulted only "If a character does not specify a
  direct value for a property" [`(elisp) Examining Properties`,
  `char-property-alias-alist`]. So a direct `face` text property on a token
  would hide the whole `magit-diff-added` line face (background included).
  Options: (a) write the token face onto `font-lock-face` with
  `font-lock-prepend-text-property` (what the benchmark does; the result is a
  face list `(token-face magit-diff-added)` so the diff background survives),
  or (b) use overlays with `face` as Magit's own implementation does
  (magit-diff.el:3885-3888 `make-overlay` + `overlay-put o 'face face`), since
  overlay faces merge over text-property faces. (a) is cheaper and
  property-only; the measured numbers use (a).
- Conclusion: write a ~25-line fontify loop instead of calling
  `treesit-font-lock-fontify-region`: for each enabled setting of the
  language, `treesit-query-capture ROOT QUERY BEG END`, then prepend the
  captured face on `font-lock-face` clipped to BEG..END. The
  "capture name is a function" case (`(elisp) Parser-based Font Lock`) must
  also be handled (call it with `NODE OVERRIDE START END`); those functions
  call `treesit-fontify-with-override` and thus write `face`; either accept
  that for the few rules that use it, or post-process. c-ts-mode defines
  five such functions (`grep 'defun c-ts-mode--fontify' c-ts-mode.el`, e.g.
  `c-ts-mode--fontify-declarator`); other modes unverified.
- The fontify loop should respect `treesit-font-lock-level` by relying on the
  ENABLE flags that `treesit-font-lock-recompute-features` already set in the
  temp buffer; the user's customisation is honoured for free.

### 3. Several languages in one buffer: `treesit-range-settings` vs direct parsers

The manual node `(elisp) Multiple Languages` documents two layers:

1. The primitive: `treesit-parser-set-included-ranges` /
   `treesit-parser-included-ranges` (quoted above).
2. The automation: `treesit-range-settings` built with
   `treesit-range-rules`, consumed by `treesit-update-ranges`, plus
   `treesit-language-at-point-function` consumed by `treesit-language-at`.
   The model is explicitly host/guest: "there is a 'primary', or 'host'
   language. The parser for this language ... parses the entire buffer.
   Parsers for other languages are 'embedded' or 'guest' parsers ... The
   parse tree of the primary parser is usually used to determine the ranges
   in which the embedded parsers operate." Each `:embed`/`:host` query is run
   "in a host language parser"; `:local t` makes Emacs create and delete a
   dedicated parser per captured range (managed via overlays with
   `treesit-parser-local-p`). A plain function `(START END)` may also be a
   setting and "sets the ranges for parsers in the current buffer".

Fit for a diff buffer:

- There is no host grammar. The structure that decides where C ends and
  Python begins is magit's section tree and the `+`/`-`/` ` prefixes, not a
  parse tree. (A tree-sitter `diff` grammar exists upstream, but Emacs ships
  no mode for it, it is not installed here, and it would still not know the
  per-file language; unverified beyond its existence.)
- The automation layer assumes a non-nil `treesit-primary-parser` even for
  function settings (measured error above) and is driven from
  `treesit-font-lock-fontify-region`/`treesit--pre-redisplay`, i.e. from
  `font-lock-mode` and `jit-lock`, which magit buffers deliberately do not
  use for syntax (`font-lock-defaults '(nil t)`).
- `:local t` parsers would be the closest conceptual match (one parser per
  region, lifecycle managed by Emacs) but they can only be created from a
  host-parser query, not from a function setting (treesit.el:1321-1326 route
  `local` through `treesit--update-ranges-local HOST-PARSER QUERY ...`).
- `treesit-language-at-point-function` only matters to callers of
  `treesit-language-at` (indentation, `treesit-node-at` defaults, etc.);
  prrr's fontifier knows the language from the file section and never needs
  it. If prrr later wants `treesit-node-at`-style commands in the Review
  Buffer it can set it to a function that maps POS -> section -> language.

Recommendation: **create the parsers directly** with `treesit-parser-create
LANG nil t TAG` (one per file section per side, or one per language per side
if sections are merged) and call `treesit-parser-set-included-ranges` with
the ranges computed from magit's hunk sections, exactly the pattern the
manual's own worked example uses before it introduces the automation
("Create parsers ... Set CSS ranges ... `treesit-parser-set-included-ranges`",
`(elisp) Multiple Languages`, subsection "Supporting multiple languages in
major modes"). Multiple languages in one buffer are then just multiple
parsers; the fontify loop filters settings by
`treesit-font-lock-setting-language` and pairs them with parsers of the same
language, the same test `treesit-font-lock-fontify-region` itself uses
(treesit.el:2171-2176 `(eq (treesit-node-language node) language)`).
Delete the parsers (`treesit-parser-delete`) in the refresh path before magit
erases the buffer, and recreate lazily.

Per-file-section parsers (rather than one per language) are preferred
because setting ranges on a parser invalidates its tree; with one parser per
language, expanding a second Python file would force a reparse covering both
files (unverified whether tree-sitter reuses the old tree across a range
change; the manual does not say). Per-section parsers make expansion cost
proportional to that section alone, which is what was measured below.

### 4. Prior art

- **Magit 4.6.0+ built-in** (`magit-diff-fontify-hunk`, magit-diff.el:217-242;
  manual node "Diff Options" in magit.info:3894; CHANGELOG 4.6.0): values
  `nil`/`all`/`t` ("Fontify each hunk once it becomes the current section
  ... only provided for performance reasons"). "This is considered
  experimental and is disabled by default, because the fontification is done
  synchronously, and that can lead to a noticeable delay. The plan is to make
  it asynchronous, probably with the help of the new `futur` package".
  Mechanism (magit-diff.el:3871-3905): for each hunk, both sides,
  `magit-find-file-noselect REV FILE` opens (and caches) a blob buffer in
  the file's normal major mode (`magit--blob-normal-mode` -> `normal-mode`,
  magit-files.el:195-214), then `diff-syntax-fontify-props` from diff-mode.el
  locates the hunk text by line number, runs `font-lock-ensure beg end`, and
  returns per-line `(FROM TO FACE)` triples (diff-mode.el:3496-3562); magit
  applies them as evaporating overlays with `face` (magit-diff.el:3885-3888).
  Toggle: `D T` (`magit-diff-toggle-fontify-hunk`). Implication: with
  `major-mode-remap-alist` -> `c-ts-mode`, this is already tree-sitter
  fontification, at the cost of a full blob checkout + full-file parse per
  file (measured below: 234 ms for the first hunk of a 24k-line file).
  prrr should set `magit-diff-fontify-hunk` to nil in its buffers if it does
  its own highlighting, to avoid double work.
- **diff-mode's `diff-font-lock-syntax`** (diff-mode.el:139-163, since Emacs
  27.1): `t` = file-based via VC backend, `hunk-only` = "based on hunk alone,
  without full source ... the fastest option, but less reliable",
  `hunk-also` = fallback. Same temp-buffer + `set-auto-mode` +
  `font-lock-ensure` design; hunk-only inserts only the hunk text into a temp
  buffer (diff-mode.el:3446-3450). Runs inside diff-mode's font-lock
  keywords, so it is jit-locked (lazy per displayed window). Not usable
  directly by magit (magit-diff-mode is not derived from diff-mode), but it is
  the precedent magit reuses.
- **magit-delta** (`magit-delta.el`): adds
  `magit-delta-call-delta-and-convert-ansi-escape-sequences` to
  `magit-diff-wash-diffs-hook`, pipes the *whole buffer* through the external
  `delta --color-only` with `call-process-region`, then
  `xterm-color-colorize-buffer 'use-overlays`; hides `+`/`-` with a `display`
  property, remaps `magit-diff-added`/`-removed`/`-context-highlight` faces to
  `default`, and forces `magit-diff-refine-hunk` to nil. Whole-buffer,
  synchronous, external process, theme comes from delta/bat not from Emacs
  faces. README documents no performance numbers.
- **diff-ansi** (README): runs delta / diff-so-fancy / ydiff / custom and
  decodes ANSI with `diff-ansi-method` = `immediate` ("may be slow"),
  `progressive` (timer) or `multiprocess` (default; "Converting ANSI escape
  sequences can be slow for large diffs, this is why `multiprocess` support
  is default"), chunked by `diff-ansi-chunks-size` (16384 chars). Magit
  integration is only for revision buffers
  (`diff-ansi-use-magit-revision-diff`). Lesson: ANSI decoding, not
  highlighting, is their bottleneck; the design is chunked and incremental.
- **elta-diff** (README; `elta-diff.el` `elta-diff--frag-buffer-for`,
  `elta-diff--fontify-lines`): Emacs 30.1+ side-by-side pager; "each file's
  major mode runs over the diff, reusing your font-lock and color theme";
  "Highlighting is computed in per-hunk fragment buffers"; runs the mode with
  `(funcall mode)` in a reused space-named buffer (so `font-lock-mode` is a
  no-op and the mode only sets `font-lock-defaults`), then
  `font-lock-flush` + `font-lock-ensure`; folds `font-lock-face` and overlay
  faces into `face`. Comment: "the major-mode setup ... dominates
  fontification for heavy modes", hence buffer reuse. Documented limitation:
  "a hunk beginning inside a multi-line construct may mis-highlight near its
  edges." No treesit-specific code in the part read (first 100k chars).
- **diffs.nvim** (Neovim; unverified, host unreachable, search summary only):
  treesitter highlighting of hunks parsed as fragments, with
  `highlights.context` reading 25 lines from disk around each hunk "for
  parsing context" because "Parsing hunks in isolation can cause errors";
  repaints after `debounce_ms` with an "unavoidable visual flash". Relevant
  as independent confirmation that fragment parsing works and that context
  helps edges.
- No Emacs package applying `treesit` (or the older `tree-sitter.el`) to diff
  hunks was found on GitHub/MELPA via web search.

### 5. Measurements

Script: appendix. "In-buffer" = the recommended mechanism: a unified diff
inserted in a buffer with prefix characters, two C parsers (new side: context
and `+` lines; old side: context and `-` lines), ranges per line excluding the
prefix and including the newline, `c-ts-mode`'s compiled settings applied by
the custom loop onto `font-lock-face`. "magit-style" = full new-side file in a
temp buffer, `(c-ts-mode)`, then `font-lock-ensure` on a 60-line region (what
`magit-diff-fontify-hunk` / `diff-syntax-fontify-props` do, minus git I/O).

Whole-buffer, eager (both parsers over the entire diff):

| source lines | diff lines / hunks / chars | compute ranges | set ranges | first parse (2 parsers) | fontify all | fontify one 9-line hunk (after parse) | ERROR nodes new/old |
|---|---|---|---|---|---|---|---|
| 500 | 215 / 21 / 7 k | 0.1 ms | 0.0 ms | 2.1 ms | 3.7 ms (426 faces) | 0.1 ms | 21 / 21 |
| 2 000 | 883 / 88 / 31 k | 0.9 ms | 0.0 ms | 17.6 ms | 14.0 ms (2 250 faces) | 0.2 ms | 175 / 151 |
| 8 000 | 3 514 / 353 / 122 k | 2.0 ms | 0.0 ms | 57.6 ms | 55.7 ms (7 950 faces) | 0.5 ms | 631 / 505 |
| 24 000 | 10 592 / 1 068 / 382 k | 6.0 ms | 0.1 ms | 224.0 ms | 156.3 ms (24 879 faces) | 1.6 ms | 1 564 / 1 187 |

Per file section, deferred (parsers created and parsed only for one section
inside the 10,592-line diff buffer; includes create + set-ranges + parse +
fontify):

| section size | cost |
|---|---|
| 100 diff lines (79 ranges) | 1.3 ms (172 faces) |
| 300 diff lines (241 ranges) | 9.7 ms (651 faces) |
| 1 000 diff lines (806 ranges) | 34.2 ms (2 544 faces) |

magit-style (full file in `c-ts-mode`):

| source lines | `(c-ts-mode)` | `font-lock-ensure` 60-line hunk incl. first full-file parse | `font-lock-ensure` whole file |
|---|---|---|---|
| 500 | 3.8 ms | 7.4 ms | 4.0 ms |
| 2 000 | 3.6 ms | 25.6 ms | 30.6 ms |
| 8 000 | 3.7 ms | 89.4 ms | 71.7 ms |
| 24 000 | 4.5 ms | 233.8 ms | 377.4 ms |

Other measured facts: settings extraction via `(c-ts-mode)` in an empty temp
buffer 17 ms cold / ~4 ms warm; buffer edit with 306 live parsers 0.0 ms;
`treesit-parser-set-included-ranges` accepts `((1 . 1))` (empty range) and
yields an empty `translation_unit`, so a parser can be parked harmlessly.

Reading the numbers:

- Parsing scales linearly with the amount of ranged text (~0.3 ms per KB per
  parser here; the 24k-line case is 2 x 380 KB). Fragment edges add ERROR
  nodes (about 1-1.5 per hunk) but do not blow up parse time; keywords,
  strings, comments, types still get faces (24,879 faces over 10.6k lines).
- Eager whole-diff highlighting of a 10k-line diff is ~400 ms (ranges +
  parse + fontify): not "instant". Deferred per-section highlighting is
  1-35 ms for sections up to 1,000 diff lines: well under a frame for typical
  files, and only paid when the user expands the file.
- The magit built-in path pays a full-file parse per file (230 ms for a
  24k-line file, plus `git cat-file`), independent of how small the hunk is.
  The in-buffer mechanism pays proportional to hunk text only.
- Fontify-after-parse for one hunk is 0.1-1.6 ms, so a "highlight the
  current hunk only" variant (Magit's `t` style) is essentially free once a
  section is parsed; the parse is the cost to defer.

### 6. Caveats and risks

- Grammar availability per language is the user's responsibility
  (`treesit-ready-p`); prrr needs a language -> ts-mode table (can derive from
  `auto-mode-alist` + `major-mode-remap-alist` + `treesit-language-source-alist`;
  unverified how robust that is across modes that register languages
  differently, e.g. `typescript-ts-mode` with `tsx`).
- Fragment edges: a hunk starting inside a block comment or string will be
  mis-highlighted until the closing delimiter (same limitation elta-diff and
  diffs.nvim document). Mitigation seen in diffs.nvim (unverified): add
  context lines from the blob around each hunk. Not needed for v1.
- `font-lock-face` on tokens must be cleared/recomputed when magit refreshes
  (it rewrites the buffer anyway) and must not be applied to the prefix
  column (ranges already exclude it).
- Function capture names in settings write `face`, not `font-lock-face`; a
  few rules per mode. Acceptable visual glitch for v1, or wrap by let-binding
  `treesit-fontify-with-override` (advice) -- unverified.
- Haskell grammar forces line/column tracking on the whole buffer; cost
  unmeasured.
- `treesit-max-buffer-size` (40 MB on 64-bit, treesit.el:154-157) is per
  buffer, not per range; a diff buffer near that size would disable
  everything.
- Combined ("@@@") merge diffs have two prefix columns; skip them (magit also
  skips `magit--meta-hunk-p` sections).

## Recommendation

**Go**, with the following mechanism:

1. When a file section is expanded (and only then), determine the file's
   tree-sitter language and ts-mode from its name; skip if
   `(treesit-ready-p lang t)` is nil.
2. Obtain and cache that mode's compiled `treesit-font-lock-settings` by
   running the mode once in an empty temp buffer (~4 ms warm, 17 ms cold).
3. Create two parsers with `treesit-parser-create LANG nil t TAG` tagged by
   file section and side; set their included ranges to the line bodies
   (prefix excluded, newline included) of context+`+` lines and context+`-`
   lines respectively, in order, non-overlapping [`(elisp) Multiple
   Languages`].
4. Run a small fontify loop: for each enabled setting whose
   `treesit-font-lock-setting-language` matches, `treesit-query-capture` on
   each parser's root over the section's bounds, and
   `font-lock-prepend-text-property BEG END 'font-lock-face FACE` clipped to
   the section. Do not call `treesit-font-lock-fontify-region`, which requires
   `treesit-primary-parser`, unfontifies `face`, and writes `face`.
5. Delete the section's parsers on refresh/collapse; nothing persists across
   magit's buffer rewrite.

Cost: measured 1.3 ms / 9.7 ms / 34 ms for 100 / 300 / 1,000-line sections
(parse + fontify, C grammar), 0 ms for collapsed sections, ~4 ms per language
for settings extraction. Opening a large diff stays instant because no parser
is queried until a section is expanded. If a section is very large (>2,000
diff lines), either highlight only the hunk under point (0.1-1.6 ms after the
section parse) or run the parse in an idle timer; both fit the design.

Alternative with zero prrr code: set `magit-diff-fontify-hunk` to `t` and let
users map modes to `*-ts-mode`. Rejected as the primary mechanism because it
costs a blob checkout and a full-file parse per file (234 ms for a 24k-line
file before the first hunk shows), is documented by Magit itself as
experimental and synchronous, and highlights via overlays rather than
properties; but it is a reasonable fallback for languages without a
tree-sitter grammar, since `diff-syntax-fontify-props` works with any
font-lock mode.

## Appendix: measurement scripts

Both scripts were run with `emacs --batch -l FILE`. `sample.c` was 64 glibc
headers concatenated (24,310 lines, 871 KB); the "new" version appends
`/* changed */` to every 37th line, inserts a declaration before every 53rd,
and deletes every 71st; `diff -u` produced the unified diffs.

```elisp
;;; bench.el --- measure treesit diff highlighting  -*- lexical-binding: t -*-
(require 'treesit) (require 'c-ts-mode) (require 'font-lock)

(defmacro bench-time (&rest body)
  `(let ((t0 (float-time))) (let ((r (progn ,@body))) (cons r (* 1000 (- (float-time) t0))))))

(defun bench-language-settings (mode)
  "Compiled settings of MODE, obtained by running it in an empty temp buffer."
  (with-temp-buffer (funcall mode)
    (cons treesit-font-lock-settings treesit-font-lock-feature-list)))

(defun bench-side-ranges ()
  "(NEW-RANGES . OLD-RANGES): line bodies without prefix char, newline included."
  (let (new old in-hunk)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((c (char-after)))
          (cond ((looking-at "@@") (setq in-hunk t))
                ((looking-at "\\(diff\\|---\\|\\+\\+\\+\\|index\\) ") (setq in-hunk nil))
                ((and in-hunk (memq c '(?\s ?+ ?-)))
                 (let ((r (cons (1+ (point)) (min (point-max) (1+ (line-end-position))))))
                   (when (memq c '(?\s ?+)) (push r new))
                   (when (memq c '(?\s ?-)) (push r old))))))
        (forward-line 1)))
    (cons (nreverse new) (nreverse old))))

(defun bench-fontify (parsers settings language start end)
  "Apply enabled SETTINGS of LANGUAGE via PARSERS on START..END, onto font-lock-face."
  (let ((n 0))
    (with-silent-modifications
      (dolist (setting settings)
        (when (and (eq (treesit-font-lock-setting-enable setting) t)
                   (eq (treesit-font-lock-setting-language setting) language))
          (let ((query (treesit-font-lock-setting-query setting)))
            (dolist (parser parsers)
              (dolist (capture (treesit-query-capture
                                (treesit-parser-root-node parser) query start end))
                (let ((face (car capture)) (node (cdr capture)))
                  (when (facep face)
                    (setq n (1+ n))
                    (font-lock-prepend-text-property
                     (max start (treesit-node-start node))
                     (min end (treesit-node-end node))
                     'font-lock-face face))))))))
      n)))

;; Per run: insert the diff, (bench-side-ranges), two parsers
;; (treesit-parser-create 'c nil t 'new) / 'old, treesit-parser-set-included-ranges,
;; time (treesit-parser-root-node p) for the parse, then bench-fontify over
;; (point-min)..(point-max) and over one hunk.  magit-style: insert the whole
;; new file, time (c-ts-mode), (font-lock-ensure (point-min) hunk-end) and
;; (font-lock-ensure (point-min) (point-max)).
```

The sanity checks that produced the `treesit-parser-p nil` errors were:

```elisp
(with-temp-buffer
  (insert "int x = 1;\n")
  (setq-local treesit-range-settings (treesit-range-rules (lambda (_b _e) nil)))
  (condition-case e (treesit-update-ranges (point-min) (point-max)) (error e))
  ;; => (wrong-type-argument treesit-parser-p nil)
  (setq-local treesit-range-settings nil)
  (treesit-parser-create 'c)
  (setq-local treesit-font-lock-settings (copy-tree (car (bench-language-settings 'c-ts-mode))))
  (condition-case e (treesit-font-lock-fontify-region (point-min) (point-max)) (error e))
  ;; => (wrong-type-argument treesit-parser-p nil)
  (setq-local treesit-primary-parser (car (treesit-parser-list)))
  (treesit-font-lock-fontify-region (point-min) (point-max))
  (get-text-property 1 'face)) ;; => font-lock-type-face
```
