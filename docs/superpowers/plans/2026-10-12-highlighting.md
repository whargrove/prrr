# Milestone 6: Highlighting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Highlight the syntax of a Review Buffer's diff lines with Emacs's built-in tree-sitter, one file section at a time, the first time that section is shown.

**Architecture:** A new file, `prrr-treesit.el`, works out a file's tree-sitter language from its name and borrows that language's ts-mode font-lock rules. It parses the new side (context and `+` lines) and the old side (context and `-` lines) of a file section, each with its own short-lived parser whose included ranges are the line bodies. Token faces go on a property of prrr's own, `prrr-treesit-face`. An `:after` method on magit's hunk paint merges them in front of the line's `font-lock-face` after every paint, because magit's paint resets `font-lock-face` whenever point enters or leaves a hunk. A file is highlighted when one of its hunks is first painted. That happens at once when the user expands it, and on an idle timer when it is painted during a refresh or is larger than `prrr-highlight-max-lines`.

**Tech Stack:** Emacs Lisp; `treesit` (Emacs 29.1+), magit-section/magit-diff, ERT.

**Spec:** `SPEC.md` section 6 "Syntax highlighting", section 12 (the "Expand one file (300 lines, highlighted)" budget of 25 ms), section 9 (`L` is `prrr-toggle-highlight`), section 2 (`prrr-treesit.el` depends on prrr-diff and treesit). Research: `docs/research/treesit-diff-highlighting.md`.

## Global Constraints

- `lexical-binding: t`, the GPL-3.0-or-later header of the other files, a `prrr-` prefix on every symbol, and no personal paths or tokens anywhere.
- Emacs 29.1 or later. `treesit` may be built without tree-sitter (`treesit-available-p` nil); then nothing is highlighted and nothing fails.
- Only forge's public API; this milestone does not touch forge.
- Never call `treesit-font-lock-fontify-region` or set `treesit-range-settings` (SPEC 6).
- Language: from the file name through `auto-mode-alist` and the remapping options (`major-mode-remap-alist`; Emacs 30+ `major-mode-remap` also reads `major-mode-remap-defaults`). Files without an available grammar are left unhighlighted, silently.
- `prrr-highlight` defaults to `t`, `prrr-highlight-max-lines` to `3000`.
- `make compile` (warnings are errors), `make lint` (package-lint + checkdoc) and `make test` must pass before each commit. Commit each task once its tests pass. Do not push.
- Use the terms of `CONTEXT.md` (Review Buffer, Thread, file section…) in docstrings, the UI and the README.
- Tests that need a real grammar use `(skip-unless (treesit-language-available-p 'c))`. The C grammar is installed on the development machine (Emacs 30.2: c, python, rust, go, javascript, bash, lua, json; no elisp).

## Rulings made while planning

1. **Faces live in `prrr-treesit-face` and are merged into `font-lock-face` after every paint.** SPEC 6 says to prepend faces to `font-lock-face`. magit's `magit-section-paint` for hunks runs `(put-text-property bol (1+ eol) 'font-lock-face line-face)` on every line, each time point enters or leaves a hunk, so faces prepended once would vanish. Cost if wrong: prrr couples to one more detail of magit's paint (it already has a paint method). CI against MELPA magit catches a change.
2. **FOO-ts-mode stands in for FOO-mode** when the mode from `auto-mode-alist` and remapping is not a tree-sitter mode and FOO-ts-mode is defined. Without this, a stock Emacs (where `.py` maps to `python-mode`) would highlight almost nothing. prrr only borrows the rules, so how the user edits files is unchanged. Cost if wrong: a user who deliberately avoids ts-modes sees them used for highlighting; SPEC 6 records the rule.
3. **Parsers are created, used and deleted in one call.** SPEC 6 says "one parser per file section per side". That stays true, but nothing persists, so refresh and collapse need no parser cleanup. Cost if wrong: none measurable. A section is highlighted once per wash, and a refresh rewrites the buffer anyway.
4. **Files painted during a refresh are highlighted on an idle timer**, as larger files are, so first paint and the refresh budget stay as they are. `magit--refreshing-buffer-p` (magit's own deferral flag, bound only inside `magit-refresh-buffer`) tells the two cases apart. Cost if wrong: one frame of uncolored text after each refresh, plus reliance on a magit internal variable, which CI catches.
5. **`prrr-diff-mode` loads `prrr-treesit` from its body** (`(require 'prrr-treesit)`), because every way into a Review Buffer runs that body. `prrr-treesit` requires `prrr-diff` at load time, so the file dependency arrow in SPEC 2 still points one way. Cost if wrong: one runtime require.
6. **`L` toggles highlighting in the current buffer only** (buffer-local `prrr-highlight`) and clears the cache of borrowed rules, so a changed `treesit-font-lock-level` takes effect. Cost if wrong: users wanting a global toggle use `customize`.
7. **`prrr-diff--walk-hunk` becomes public as `prrr-diff-walk-hunk`**, since another file now calls it. Cost if wrong: none.
8. **CI installs tree-sitter-c `v0.21.4` (ABI 14) with `continue-on-error`**, so the grammar-dependent tests run where the install works and skip where it doesn't. Cost if wrong: on a CI Emacs whose tree-sitter library rejects that grammar, those tests are skipped instead of run.

## Review Focus

1. **A hunk that starts inside a block comment or string** should mis-color its first lines at worst and never signal. Pinned by Task 2's `prrr-treesit-test-hunk-inside-comment`.
2. **A file whose mode errors or warns when run** (no grammar, a broken mode) should give no highlighting and no `*Warnings*` buffer; an error is reported once. Pinned by Task 1's `prrr-treesit-test-missing-grammar-is-silent` and `prrr-treesit-test-broken-mode-reported-once`.
3. **A file with no hunks but a highlightable name** (a pure rename `.c` → `.c`) should be shown as before, with nothing highlighted and no error. Pinned by Task 2's `prrr-treesit-test-file-without-hunks`.
4. **A refresh (`g`) while a large file waits on the idle timer** should not highlight the stale section or signal; the new section is queued again. Pinned by Task 3's `prrr-treesit-test-drain-skips-stale-sections`.
5. **Emacs built without tree-sitter** should open Review Buffers exactly as before. Pinned by Task 1's `prrr-treesit-test-no-treesit-no-rules`.

---

### Task 1: Language and rules lookup

**Files:**
- Create: `prrr-treesit.el`
- Create: `test/prrr-treesit-test.el`
- Modify: `Makefile` (append `prrr-treesit.el` to `SRC` after `prrr-stack.el`, and `test/prrr-treesit-test.el` to `TESTS` after `test/prrr-stack-test.el`)

**Interfaces:**
- Produces:
  - `prrr-highlight` (defcustom, boolean, default `t`) and `prrr-highlight-max-lines` (defcustom, natnum, default `3000`), both in group `prrr`.
  - `prrr-treesit--languages`: a hash table from mode symbol to `(LANGUAGE . SETTINGS)` or the symbol `none`.
  - `(prrr-treesit-mode PATH)` returns a tree-sitter major mode symbol or nil.
  - `(prrr-treesit-rules PATH)` returns `(LANGUAGE . SETTINGS)` or nil. SETTINGS is a list of treesit font-lock settings whose positional fields are `(nth 0)` QUERY (compiled), `(nth 1)` ENABLE (`t` when on) and `(nth 3)` OVERRIDE. These positions are the same on Emacs 29, 30 and 31.

- [ ] **Step 1: Write the failing tests**

Create `test/prrr-treesit-test.el` with the header of `test/prrr-stack-test.el` (title `Tests for prrr-treesit`). Commentary: "Tree-sitter highlighting of the Review Buffer, on the C fixture repository. Tests that need the C grammar skip without it. No network." Then:

```elisp
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'prrr-test-helper)
(require 'prrr-treesit)

;;;; Languages

(define-derived-mode prrr-treesit-test-foo-mode fundamental-mode "foo"
  "A mode with a tree-sitter counterpart, for the lookup tests.")

(define-derived-mode prrr-treesit-test-foo-ts-mode fundamental-mode "foo-ts"
  "The tree-sitter counterpart of `prrr-treesit-test-foo-mode'.")

(define-derived-mode prrr-treesit-test-bar-mode fundamental-mode "bar"
  "A mode without a tree-sitter counterpart, for the lookup tests.")

(define-derived-mode prrr-treesit-test-nogrammar-ts-mode fundamental-mode "nogrammar"
  "A tree-sitter mode whose grammar is missing: it only warns, as real ones do."
  (treesit-ready-p 'prrr-no-such-language))

(define-derived-mode prrr-treesit-test-broken-ts-mode fundamental-mode "broken"
  "A tree-sitter mode that fails."
  (error "Broken mode"))

(defvar prrr-treesit-test--hooked nil
  "Set by `prrr-treesit-test-foo-ts-mode-hook' when it runs.")

(defmacro prrr-treesit-test--with-languages (alist &rest body)
  "Run BODY with `auto-mode-alist' ALIST, no remapping and an empty rules cache."
  (declare (indent 1))
  `(let ((auto-mode-alist ,alist)
         (major-mode-remap-alist nil)
         (prrr-treesit--languages (make-hash-table :test #'eq)))
     (cl-letf (((symbol-function 'major-mode-remap)
                (lambda (mode) (or (alist-get mode major-mode-remap-alist) mode))))
       ,@body)))

(ert-deftest prrr-treesit-test-mode-from-auto-mode-alist ()
  (prrr-treesit-test--with-languages '(("\\.foo\\'" . prrr-treesit-test-foo-ts-mode))
    (should (eq 'prrr-treesit-test-foo-ts-mode (prrr-treesit-mode "src/a.foo")))
    (should-not (prrr-treesit-mode "src/a.unknown"))))

(ert-deftest prrr-treesit-test-ts-counterpart-stands-in ()
  "FOO-ts-mode stands in for FOO-mode; a mode without one gives nil."
  (prrr-treesit-test--with-languages '(("\\.foo\\'" . prrr-treesit-test-foo-mode)
                                       ("\\.bar\\'" . prrr-treesit-test-bar-mode))
    (should (eq 'prrr-treesit-test-foo-ts-mode (prrr-treesit-mode "a.foo")))
    (should-not (prrr-treesit-mode "a.bar"))))

(ert-deftest prrr-treesit-test-remap-wins ()
  (prrr-treesit-test--with-languages '(("\\.bar\\'" . prrr-treesit-test-bar-mode))
    (let ((major-mode-remap-alist '((prrr-treesit-test-bar-mode
                                     . prrr-treesit-test-foo-ts-mode))))
      (should (eq 'prrr-treesit-test-foo-ts-mode (prrr-treesit-mode "a.bar"))))))

(ert-deftest prrr-treesit-test-suffix-stripping-entries-pass-over ()
  "An entry asking to strip a suffix and look again names no mode."
  (prrr-treesit-test--with-languages '(("\\.gz\\'" nil jka-compr)
                                       ("\\.foo\\'" . prrr-treesit-test-foo-ts-mode))
    (should-not (prrr-treesit-mode "a.gz"))
    (should (eq 'prrr-treesit-test-foo-ts-mode (prrr-treesit-mode "a.foo")))))

(ert-deftest prrr-treesit-test-c-rules ()
  "C files borrow c-ts-mode's compiled rules, cached per mode."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-languages '(("\\.c\\'" . c-mode))
    (let ((rules (prrr-treesit-rules "src/a.c")))
      (should (eq 'c (car rules)))
      (should (cdr rules))
      (should (seq-some (lambda (setting) (eq t (nth 1 setting))) (cdr rules)))
      (should (eq rules (prrr-treesit-rules "src/b.c"))))))

(ert-deftest prrr-treesit-test-mode-hooks-never-run ()
  "Borrowing rules runs no hook the user put on the mode."
  (prrr-treesit-test--with-languages '(("\\.foo\\'" . prrr-treesit-test-foo-ts-mode))
    (let ((prrr-treesit-test--hooked nil)
          (prrr-treesit-test-foo-ts-mode-hook
           (list (lambda () (setq prrr-treesit-test--hooked t)))))
      (prrr-treesit-rules "a.foo")
      (should-not prrr-treesit-test--hooked))))

(ert-deftest prrr-treesit-test-missing-grammar-is-silent ()
  "A mode without its grammar gives no rules and no warning, and is cached."
  (prrr-treesit-test--with-languages '(("\\.ng\\'" . prrr-treesit-test-nogrammar-ts-mode))
    (when (get-buffer "*Warnings*") (kill-buffer "*Warnings*"))
    (should-not (prrr-treesit-rules "a.ng"))
    (should-not (get-buffer "*Warnings*"))
    (should (eq 'none (gethash 'prrr-treesit-test-nogrammar-ts-mode
                               prrr-treesit--languages)))))

(ert-deftest prrr-treesit-test-broken-mode-reported-once ()
  (prrr-treesit-test--with-languages '(("\\.br\\'" . prrr-treesit-test-broken-ts-mode))
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (push (apply #'format format args) messages))))
        (should-not (prrr-treesit-rules "a.br"))
        (should-not (prrr-treesit-rules "b.br")))
      (should (= 1 (length messages)))
      (should (string-match-p "prrr-treesit-test-broken-ts-mode" (car messages)))
      (should (string-match-p "Broken mode" (car messages))))))

(ert-deftest prrr-treesit-test-no-treesit-no-rules ()
  "Emacs built without tree-sitter highlights nothing and runs no mode."
  (prrr-treesit-test--with-languages '(("\\.br\\'" . prrr-treesit-test-broken-ts-mode))
    (cl-letf (((symbol-function 'treesit-available-p) #'ignore))
      (should-not (prrr-treesit-rules "a.br"))
      (should (zerop (hash-table-count prrr-treesit--languages))))))
```

End the file with `(provide 'prrr-treesit-test)` and `;;; prrr-treesit-test.el ends here`.

- [ ] **Step 2: Run them to see them fail**

Run: `make test SELECTOR='"prrr-treesit-test"'` after adding the file to `TESTS`.
Expected: the load fails with "Cannot open load file ... prrr-treesit".

- [ ] **Step 3: Write `prrr-treesit.el`**

```elisp
;;; prrr-treesit.el --- Syntax highlighting in the Review Buffer  -*- lexical-binding: t -*-

;; (the GPL-3.0-or-later header of prrr-diff.el, verbatim)

;;; Commentary:

;; Deferred per-file tree-sitter highlighting (SPEC section 6).  A
;; file's language is the one visiting it would choose, and its
;; highlighting rules are borrowed from that language's ts-mode, run
;; once in a temporary buffer.  Files without a grammar are left
;; unhighlighted.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'treesit)
(require 'warnings)
(require 'prrr-diff)

(defcustom prrr-highlight t
  "Whether Review Buffers highlight the syntax of their diff lines.
Highlighting needs Emacs built with tree-sitter and the grammar of a
file's language; files without one are left unhighlighted."
  :type 'boolean
  :group 'prrr)

(defcustom prrr-highlight-max-lines 3000
  "Largest file section, in lines, highlighted as soon as it is shown.
A larger one is highlighted when Emacs is next idle."
  :type 'natnum
  :group 'prrr)

;;;; Languages

(defvar prrr-treesit--languages (make-hash-table :test #'eq)
  "Cache from a tree-sitter major mode to (LANGUAGE . SETTINGS), or `none'.
SETTINGS are the mode's compiled `treesit-font-lock-settings', with the
features `treesit-font-lock-level' enables.  `none' when the mode
offers no rules here, for want of a grammar, say.")

(defun prrr-treesit--auto-mode (path)
  "Return the major mode `auto-mode-alist' gives PATH, or nil.
Only entries naming a mode count: one asking to strip a suffix and look
again, as a compressed file's does, is passed over."
  (let ((case-fold-search nil))
    (seq-some (lambda (entry)
                (and (cdr entry) (symbolp (cdr entry))
                     (string-match-p (car entry) path)
                     (cdr entry)))
              auto-mode-alist)))

(defun prrr-treesit--remap (mode)
  "Return the mode MODE is remapped to, else MODE.
On Emacs 30 and later `major-mode-remap' also reads
`major-mode-remap-defaults'; Emacs 29 has only `major-mode-remap-alist'."
  (if (fboundp 'major-mode-remap)
      (major-mode-remap mode)
    (or (alist-get mode major-mode-remap-alist) mode)))

(defun prrr-treesit-mode (path)
  "Return the tree-sitter major mode whose rules highlight PATH, or nil.
The mode is the one visiting PATH would choose, through `auto-mode-alist'
and the remapping options.  When that is FOO-mode, not a tree-sitter
mode, FOO-ts-mode stands in if it is defined: prrr borrows only its
highlighting rules, so how the user edits is unchanged."
  (when-let* ((mode (prrr-treesit--auto-mode path)))
    (let* ((mode (prrr-treesit--remap mode))
           (name (symbol-name mode)))
      (cond ((string-suffix-p "-ts-mode" name) mode)
            ((string-suffix-p "-mode" name)
             (let ((ts (intern-soft (concat (string-remove-suffix "-mode" name) "-ts-mode"))))
               (and ts (fboundp ts) ts)))))))

(defun prrr-treesit--extract (mode)
  "Run MODE in a temporary buffer; return its (LANGUAGE . SETTINGS) or nil.
Its mode hooks are delayed and never run, so nothing the user hooked
on, a language server say, starts.  Warnings are silenced: a missing
grammar means no highlighting, not a message."
  (with-temp-buffer
    (let ((warning-minimum-level :emergency)
          (warning-minimum-log-level :emergency))
      (delay-mode-hooks (funcall mode)))
    (when-let* ((settings treesit-font-lock-settings)
                (language (if-let* ((primary (bound-and-true-p treesit-primary-parser)))
                              (treesit-parser-language primary)
                            (treesit-query-language (nth 0 (car settings))))))
      (cons language settings))))

(defun prrr-treesit-rules (path)
  "Return the (LANGUAGE . SETTINGS) that highlight PATH, or nil.
See `prrr-treesit--languages'.  A mode that fails is reported once
and cached as offering none."
  (when-let* (((treesit-available-p))
              (mode (prrr-treesit-mode path)))
    (let ((rules (gethash mode prrr-treesit--languages)))
      (unless rules
        (setq rules (or (condition-case err
                            (prrr-treesit--extract mode)
                          (error (message "prrr: no highlighting from %s: %s"
                                          mode (error-message-string err))
                                 nil))
                        'none))
        (puthash mode rules prrr-treesit--languages))
      (unless (eq rules 'none) rules))))

(provide 'prrr-treesit)
;;; prrr-treesit.el ends here
```

Notes for the implementer:
- `treesit-query-language` is a C function on Emacs 29 and later. The local Emacs is 30.2. If the byte-compiler warns about `major-mode-remap` on some version, keep the `fboundp` guard; the compiler recognises that pattern.
- If `make compile` warns that `treesit-primary-parser` is a free variable, `bound-and-true-p` already avoids that. Do not add a `defvar`.

- [ ] **Step 4: Run the tests**

Run: `make test SELECTOR='"prrr-treesit-test"'`
Expected: every test passes (or `prrr-treesit-test-c-rules` is SKIPPED without the C grammar).

- [ ] **Step 5: Full gates and commit**

Run `make compile && make lint && make test`. All must pass.

```bash
git add prrr-treesit.el test/prrr-treesit-test.el Makefile
git commit -m "feat(treesit): find a file's tree-sitter language and borrow its rules"
```

---

### Task 2: Highlight a file section on first paint

**Files:**
- Modify: `prrr-treesit.el` (add the highlighting section)
- Modify: `prrr-diff.el` (rename `prrr-diff--walk-hunk` to `prrr-diff-walk-hunk` at its definition, about line 856, and at its two callers, about lines 898 and 1035; add `(require 'prrr-treesit)` at the end of the `prrr-diff-mode` body, after the `quit-window-hook` line, with a comment explaining why)
- Create: `test/fixtures/make-c-repo.sh`
- Modify: `test/prrr-test-helper.el` (`prrr-test-with-repo` reads the script name from a new variable)
- Test: `test/prrr-treesit-test.el`

**Interfaces:**
- Consumes: `prrr-treesit-rules` (Task 1); `prrr-diff-walk-hunk HUNK FUNCTION`, which calls FUNCTION with `(KIND OLD NEW)` and point at the start of each diff line, skipping Threads; `prrr-diff-test--with-buffer SETUP &rest BODY`, `prrr-diff-test--file-section PATH` and `prrr-diff-test--hunks PATH` from `test/prrr-diff-test.el`.
- Produces:
  - `(prrr-treesit-highlight FILE)`, where FILE is a `file` section: it writes `prrr-treesit-face` and merges it into `font-lock-face`.
  - `(prrr-treesit--request FILE)`: highlight once per section. Task 3 changes its body.
  - `(prrr-treesit--highlight-reporting FILE)`: catches errors and messages them.
  - `(prrr-treesit--merge START END)`: idempotent.
  - `prrr-treesit--done`: a buffer-local weak hash table.
  - The text property `prrr-treesit-face`.
  - `prrr-test-repo-script` (defvar in the helper, default `"make-repo.sh"`).

- [ ] **Step 1: The fixture repository**

Create `test/fixtures/make-c-repo.sh` (mode 755) by copying the environment and `git init` lines of `test/fixtures/make-repo.sh`:

```sh
#!/bin/sh
# Build the highlighting fixture repository in DIR, the only argument.
#
# main:  base            (base-rev is main's tip)
#           \
#            head = refs/pullreqs/1
#
# head changes, relative to base:
#   src/sample.c     one hunk: "int answer = 41;" becomes 42, the
#                    "int unused" line is removed, a comment line is
#                    added before "return 0;"
#   src/big.c        new, 40 lines of declarations
#   src/comment.c    line 12, inside a 20-line block comment, rewritten
#   src/moved.c      renamed to src/renamed.c, unchanged (no hunks)
#   notes.txt        one line rewritten (no grammar highlights it)
set -eu
dir=$1
mkdir -p "$dir"
cd "$dir"
export GIT_AUTHOR_NAME=example GIT_AUTHOR_EMAIL=example@example.com
export GIT_COMMITTER_NAME=example GIT_COMMITTER_EMAIL=example@example.com
export GIT_AUTHOR_DATE=2026-09-01T00:00:00Z GIT_COMMITTER_DATE=2026-09-01T00:00:00Z
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
git init -q -b main
git config commit.gpgsign false
mkdir -p src
cat > src/sample.c <<'EOF'
#include <stdio.h>

int answer = 41;

int main(void)
{
  int unused = 0;
  printf("%d\n", answer);
  return 0;
}
EOF
{
  echo '/*'
  i=1
  while [ "$i" -le 20 ]; do echo " * comment line $i"; i=$((i + 1)); done
  echo ' */'
  echo 'int after_comment = 1;'
} > src/comment.c
printf 'int moved = 1;\n' > src/moved.c
printf 'first\nsecond\n' > notes.txt
git add -A
git commit -q -m base
git checkout -q -b feature
cat > src/sample.c <<'EOF'
#include <stdio.h>

int answer = 42;

int main(void)
{
  printf("%d\n", answer);
  /* print the answer */
  return 0;
}
EOF
: > src/big.c
i=1
while [ "$i" -le 40 ]; do printf 'int value_%d = %d;\n' "$i" "$i" >> src/big.c; i=$((i + 1)); done
sed -i.bak -e 's/^ \* comment line 12$/ * comment line twelve/' src/comment.c
rm src/comment.c.bak
git mv src/moved.c src/renamed.c
printf 'first\nsecond, changed\n' > notes.txt
git add -A
git commit -q -m head
git update-ref refs/pullreqs/1 HEAD
git checkout -q main
```

In `test/prrr-test-helper.el`, before `prrr-test-with-repo`, add:

```elisp
(defvar prrr-test-repo-script "make-repo.sh"
  "The script under test/fixtures/ that `prrr-test-with-repo' builds with.")
```

In `prrr-test-with-repo`, replace `"test/fixtures/make-repo.sh"` with `(concat "test/fixtures/" prrr-test-repo-script)`, and in its docstring say the repository is built by `prrr-test-repo-script`, test/fixtures/make-repo.sh by default.

- [ ] **Step 2: Write the failing tests**

Append to `test/prrr-treesit-test.el`. Add `(require 'prrr-diff-test)` next to the other requires.

```elisp
;;;; Highlighting

(defmacro prrr-treesit-test--with-buffer (&rest body)
  "Open the C fixture's Review Buffer, every file collapsed, and run BODY.
Highlighting is on, with C rules from c-ts-mode."
  (declare (indent 0))
  `(let ((prrr-test-repo-script "make-c-repo.sh")
         (prrr-eager-files 0)
         (prrr-highlight t)
         (auto-mode-alist (cons '("\\.c\\'" . c-mode) auto-mode-alist))
         (prrr-treesit--languages (make-hash-table :test #'eq)))
     (prrr-diff-test--with-buffer nil
       ,@body)))

(defun prrr-treesit-test--find (text)
  "Return the position of the first TEXT in the buffer, after its line's prefix."
  (save-excursion
    (goto-char (point-min))
    (search-forward text)
    (match-beginning 0)))

(defun prrr-treesit-test--faces (pos)
  "Return the syntax faces at POS, as a list."
  (ensure-list (get-text-property pos 'prrr-treesit-face)))

(ert-deftest prrr-treesit-test-nothing-before-shown ()
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (should-not (text-property-not-all (point-min) (point-max) 'prrr-treesit-face nil))))

(ert-deftest prrr-treesit-test-expanding-highlights-both-sides ()
  "Added, context and removed lines get their faces; prefixes and headings none."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (magit-section-show (prrr-diff-test--file-section "src/sample.c"))
    (let ((added (prrr-treesit-test--find "int answer = 42"))
          (removed (prrr-treesit-test--find "int answer = 41"))
          (context (prrr-treesit-test--find "\"%d\\n\""))
          (comment (prrr-treesit-test--find "/* print the answer */")))
      (should (memq 'font-lock-type-face (prrr-treesit-test--faces added)))
      (should (memq 'font-lock-type-face (prrr-treesit-test--faces removed)))
      (should (memq 'font-lock-string-face (prrr-treesit-test--faces context)))
      (should (memq 'font-lock-comment-face (prrr-treesit-test--faces comment)))
      (should-not (prrr-treesit-test--faces (1- added)))
      (should-not (prrr-treesit-test--faces (1- removed)))
      (let ((hunk (car (prrr-diff-test--hunks "src/sample.c"))))
        (should-not (text-property-not-all (oref hunk start) (oref hunk content)
                                           'prrr-treesit-face nil))))))

(ert-deftest prrr-treesit-test-line-face-kept-behind-tokens ()
  "The token face comes first in `font-lock-face'; the diff line's face stays."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (magit-section-show (prrr-diff-test--file-section "src/sample.c"))
    (let ((faces (ensure-list (get-text-property (prrr-treesit-test--find "int answer = 42")
                                                 'font-lock-face))))
      (should (eq 'font-lock-type-face (car faces)))
      (should (seq-some (lambda (face) (memq face '(magit-diff-added magit-diff-added-highlight)))
                        faces)))))

(ert-deftest prrr-treesit-test-repaint-keeps-faces ()
  "magit resets `font-lock-face' on every paint; the syntax faces come back."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (let ((hunk (car (prrr-diff-test--hunks "src/sample.c")))
          (pos (prrr-treesit-test--find "int answer = 42")))
      (dolist (highlight '(t nil t))
        (save-excursion
          (goto-char (oref hunk start))
          (magit-section-paint hunk highlight))
        (let ((faces (ensure-list (get-text-property pos 'font-lock-face))))
          (should (eq 'font-lock-type-face (car faces)))
          (should (= 1 (seq-count (lambda (face) (eq face 'font-lock-type-face)) faces)))
          (should (memq (if highlight 'magit-diff-added-highlight 'magit-diff-added) faces)))))))

(ert-deftest prrr-treesit-test-threads-not-colored ()
  "A Thread inside a hunk gets no syntax faces; the lines after it still do."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (prrr-db-insert (prrr-thread-create :thread-id "T_C" :pr-id prrr-diff-test--pr
                                        :path "src/sample.c" :line 3 :side 'right
                                        :subject-type 'line))
    (magit-refresh-buffer)
    (let* ((hunk (car (prrr-diff-test--hunks "src/sample.c")))
           (thread (car (oref hunk children))))
      (should (eq 'thread (oref thread type)))
      (should-not (text-property-not-all (oref thread start) (oref thread end)
                                         'prrr-treesit-face nil))
      (should (memq 'font-lock-type-face
                    (prrr-treesit-test--faces (prrr-treesit-test--find "int main")))))))

(ert-deftest prrr-treesit-test-no-grammar-no-faces ()
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (let ((file (prrr-diff-test--file-section "notes.txt")))
      (magit-section-show file)
      (should-not (text-property-not-all (oref file start) (oref file end)
                                         'prrr-treesit-face nil)))))

(ert-deftest prrr-treesit-test-off-means-no-faces ()
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (setq-local prrr-highlight nil)
    (magit-section-show (prrr-diff-test--file-section "src/sample.c"))
    (should-not (text-property-not-all (point-min) (point-max) 'prrr-treesit-face nil))))

(ert-deftest prrr-treesit-test-highlighted-once ()
  "Showing, hiding, showing and repainting highlight a file once."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (let ((calls 0)
          (highlight (symbol-function 'prrr-treesit-highlight))
          (file (prrr-diff-test--file-section "src/sample.c")))
      (cl-letf (((symbol-function 'prrr-treesit-highlight)
                 (lambda (section) (cl-incf calls) (funcall highlight section))))
        (magit-section-show file)
        (magit-section-hide file)
        (magit-section-show file)
        (let ((hunk (car (prrr-diff-test--hunks "src/sample.c"))))
          (save-excursion (goto-char (oref hunk start)) (magit-section-paint hunk t))))
      (should (= 1 calls)))))

(ert-deftest prrr-treesit-test-failure-reported-not-raised ()
  "A failing highlight is a message; the file still shows."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (let ((messages nil)
          (file (prrr-diff-test--file-section "src/sample.c")))
      (cl-letf (((symbol-function 'prrr-treesit-highlight)
                 (lambda (_section) (error "Parser exploded")))
                ((symbol-function 'message)
                 (lambda (format &rest args) (push (apply #'format format args) messages))))
        (magit-section-show file))
      (should-not (oref file hidden))
      (should (seq-some (lambda (text) (string-match-p "src/sample.c.*Parser exploded" text))
                        messages)))))

(ert-deftest prrr-treesit-test-hunk-inside-comment ()
  "A hunk starting inside a block comment highlights without error."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (magit-section-show (prrr-diff-test--file-section "src/comment.c"))
    (should (text-property-not-all (point-min) (point-max) 'prrr-treesit-face nil))))

(ert-deftest prrr-treesit-test-file-without-hunks ()
  "A renamed file with no hunks shows its note and gets no faces."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (let ((file (prrr-diff-test--file-section "src/renamed.c")))
      (prrr-treesit-highlight file)
      (magit-section-show file)
      (should-not (text-property-not-all (oref file start) (oref file end)
                                         'prrr-treesit-face nil)))))
```

- [ ] **Step 3: Run them to see them fail**

Run: `make test SELECTOR='"prrr-treesit-test"'`
Expected: the new tests fail. `prrr-treesit-test-expanding-highlights-both-sides` reports a nil `memq`, and `prrr-treesit-highlight` is void.

- [ ] **Step 4: Implement**

In `prrr-diff.el`, rename `prrr-diff--walk-hunk` to `prrr-diff-walk-hunk` (definition and both callers). At the end of the `prrr-diff-mode` body add:

```elisp
  ;; Syntax highlighting hooks into hunk painting.  Every way into a
  ;; Review Buffer runs this body, and prrr-treesit requires this file,
  ;; so it is loaded here rather than at the top.
  (require 'prrr-treesit)
```

Append to `prrr-treesit.el`, before `(provide 'prrr-treesit)`:

```elisp
;;;; Highlighting a file section

(defvar prrr-treesit--paint nil
  "While one side of a file is colored: a vector of the (BEG . END) it may color.
In order and not overlapping.")

(defun prrr-treesit--first-range (pos)
  "Return the index of the first range of `prrr-treesit--paint' ending after POS."
  (let ((low 0)
        (high (length prrr-treesit--paint)))
    (while (< low high)
      (let ((middle (/ (+ low high) 2)))
        (if (<= (cdr (aref prrr-treesit--paint middle)) pos)
            (setq low (1+ middle))
          (setq high middle))))
    low))

(defun prrr-treesit--fontify (start end face override &optional bound-start bound-end)
  "Apply FACE from START to END as `treesit-fontify-with-override' does.
OVERRIDE, BOUND-START and BOUND-END are as for that function.  The face
goes on `prrr-treesit-face', not `face', and only within the ranges of
`prrr-treesit--paint': a node spanning several lines also spans the
other side's lines and the Threads between them."
  (when (and bound-start bound-end)
    (setq start (max start bound-start)
          end (min end bound-end)))
  (let ((index (prrr-treesit--first-range start)))
    (while (and (< index (length prrr-treesit--paint))
                (< (car (aref prrr-treesit--paint index)) end))
      (let ((beg (max start (car (aref prrr-treesit--paint index))))
            (stop (min end (cdr (aref prrr-treesit--paint index)))))
        (when (< beg stop)
          (pcase override
            ('nil (unless (text-property-not-all beg stop 'prrr-treesit-face nil)
                    (put-text-property beg stop 'prrr-treesit-face face)))
            ('t (put-text-property beg stop 'prrr-treesit-face face))
            ('append (font-lock-append-text-property beg stop 'prrr-treesit-face face))
            ('prepend (font-lock-prepend-text-property beg stop 'prrr-treesit-face face))
            ('keep (font-lock-fillin-text-property beg stop 'prrr-treesit-face face)))))
      (cl-incf index))))

(defun prrr-treesit--fontify-side (rules parse paint)
  "Parse the ranges PARSE with RULES' language and color those of PAINT.
RULES is (LANGUAGE . SETTINGS) from `prrr-treesit-rules'.  PARSE and
PAINT are lists of (BEG . END) in order, PAINT a subset of PARSE.  The
parser lives only for this call.  Settings whose capture is a function
call `treesit-fontify-with-override' themselves, so that is
`prrr-treesit--fontify' meanwhile."
  (when paint
    (let ((language (car rules))
          (start (car (car parse)))
          (end (cdr (car (last parse))))
          (parser (treesit-parser-create (car rules) nil t)))
      (unwind-protect
          (let ((prrr-treesit--paint (vconcat paint)))
            (treesit-parser-set-included-ranges parser parse)
            (cl-letf (((symbol-function 'treesit-fontify-with-override)
                       #'prrr-treesit--fontify))
              (dolist (setting (cdr rules))
                (let ((query (nth 0 setting))
                      (override (nth 3 setting)))
                  (when (and (eq (nth 1 setting) t)
                             (eq (treesit-query-language query) language))
                    (pcase-dolist (`(,face . ,node)
                                   (treesit-query-capture (treesit-parser-root-node parser)
                                                          query start end))
                      (cond ((facep face)
                             (prrr-treesit--fontify (treesit-node-start node)
                                                    (treesit-node-end node)
                                                    face override))
                            ((functionp face)
                             (funcall face node override start end)))))))))
        (treesit-parser-delete parser)))))

(defun prrr-treesit--lines (file)
  "Return the diff lines of FILE, a `file' section, as (KIND BEG . END).
In order.  KIND is the line's first character, BEG..END its text after
it through the newline.  Threads, \"No newline\" markers and the
hunks of combined diffs are left out."
  (let ((lines nil))
    (dolist (hunk (oref file children))
      (when (and (eq (oref hunk type) 'hunk) (not (oref hunk combined)))
        (prrr-diff-walk-hunk
         hunk (lambda (kind _old _new)
                (when (memq kind '(?\s ?+ ?-))
                  (push (cons kind (cons (1+ (point))
                                         (min (point-max) (1+ (line-end-position)))))
                        lines))))))
    (nreverse lines)))

(defun prrr-treesit-highlight (file)
  "Highlight the syntax of the diff lines of FILE, a Review Buffer `file' section.
The new side (context and added lines) and the old side (context and
removed lines) are parsed apart, each as one text; context lines take
the new side's faces.  Faces go on `prrr-treesit-face' and are merged
into `font-lock-face' (`prrr-treesit--merge').  Does nothing when no
rules highlight the file (`prrr-treesit-rules'), it has no diff lines,
or the buffer is too large for tree-sitter."
  (when-let* ((rules (prrr-treesit-rules (oref file value)))
              ((treesit-ready-p (car rules) t))
              (lines (prrr-treesit--lines file)))
    (let ((new nil) (old nil) (removed nil))
      (pcase-dolist (`(,kind . ,range) lines)
        (unless (eq kind ?-) (push range new))
        (unless (eq kind ?+) (push range old))
        (when (eq kind ?-) (push range removed)))
      (setq new (nreverse new) old (nreverse old) removed (nreverse removed))
      (with-silent-modifications
        (prrr-treesit--fontify-side rules new new)
        (prrr-treesit--fontify-side rules old removed))
      (prrr-treesit--merge (cadr (car lines)) (cddr (car (last lines)))))))

(defun prrr-treesit--merge (start end)
  "Put the faces of `prrr-treesit-face' in front of `font-lock-face', START to END.
magit paints a diff line by setting its `font-lock-face' to the line's
face, so this runs after every paint.  Running it twice changes nothing."
  (with-silent-modifications
    (let ((pos start))
      (while (< pos end)
        (let ((next (next-single-property-change pos 'prrr-treesit-face nil end))
              (tokens (ensure-list (get-text-property pos 'prrr-treesit-face))))
          (when tokens
            (let ((at pos))
              (while (< at next)
                (let ((stop (next-single-property-change at 'font-lock-face nil next))
                      (line (ensure-list (get-text-property at 'font-lock-face))))
                  (put-text-property at stop 'font-lock-face
                                     (append tokens (seq-difference line tokens)))
                  (setq at stop)))))
          (setq pos next))))))

(defvar-local prrr-treesit--done nil
  "Weak table of the `file' sections highlighted, or on their way, here.
Each refresh makes new sections, so it starts them all afresh.")

(defun prrr-treesit--highlight-reporting (file)
  "Run `prrr-treesit-highlight' on FILE; report a failure rather than raise it.
It runs while magit paints, where an error would break the whole redraw."
  (condition-case err
      (prrr-treesit-highlight file)
    (error (message "prrr: highlighting %s failed: %s"
                    (oref file value) (error-message-string err)))))

(defun prrr-treesit--request (file)
  "Highlight FILE, a `file' section, unless it was already or highlighting is off."
  (when (and prrr-highlight (eq (oref file type) 'file))
    (unless prrr-treesit--done
      (setq prrr-treesit--done (make-hash-table :test #'eq :weakness 'key)))
    (unless (gethash file prrr-treesit--done)
      (puthash file t prrr-treesit--done)
      (prrr-treesit--highlight-reporting file))))

(cl-defmethod magit-section-paint :after ((section magit-hunk-section) _highlight
                                          &context (major-mode prrr-diff-mode))
  "Highlight the file of SECTION once, and put its syntax faces back.
magit paints a hunk when it is first shown, and again whenever point
enters or leaves it, each time resetting `font-lock-face'."
  (prrr-treesit--request (oref section parent))
  (prrr-treesit--merge (oref section start) (oref section end)))
```

Notes:
- `treesit-parser-create LANGUAGE nil t`: the third argument is NO-REUSE on Emacs 29, 30 and 31.
- If `make compile` complains about the `_highlight` argument name in a `cl-defmethod` with `&context`, use `highlight` and `(ignore highlight)`.
- `prrr-diff-walk-hunk` asks for `(magit-section-at)` on every line. A hunk washed but hidden still works, because `magit-section-at` reads a text property.

- [ ] **Step 5: Run the tests**

Run: `make test SELECTOR='"prrr-treesit-test"'`, then `make test`.
Expected: all pass. The whole suite includes `prrr-diff-test-later-keys-do-nothing-yet`, which still passes because `L` is unchanged until Task 3.

- [ ] **Step 6: Full gates and commit**

Run `make compile && make lint && make test`.

```bash
git add prrr-treesit.el prrr-diff.el test/fixtures/make-c-repo.sh test/prrr-test-helper.el test/prrr-treesit-test.el
git commit -m "feat(treesit): highlight a file section when its hunks are first painted"
```

---

### Task 3: Defer during refresh and for large files; `L` toggles highlighting

**Files:**
- Modify: `prrr-treesit.el` (queue, idle timer, setup hook, `prrr-toggle-highlight`)
- Modify: `prrr-diff.el` (`prrr-diff--review-keys` gains `("L" . prrr-toggle-highlight)`; `prrr-diff--later-keys` becomes `'("@")`)
- Modify: `prrr.el` (an autoload for `prrr-toggle-highlight`, next to the `prrr-mark-seen` one)
- Modify: `prrr-transient.el` (`(require 'prrr-treesit)`; the `prrr-menu` "View" group gains `("L" "toggle highlighting" prrr-toggle-highlight)` after `Z`)
- Test: `test/prrr-treesit-test.el`; check `test/prrr-test.el` (or wherever the transient's suffixes are asserted) and update it if it lists `prrr-menu`'s keys

**Interfaces:**
- Consumes: Task 2's `prrr-treesit--request`, `prrr-treesit--highlight-reporting`, `prrr-treesit--done` and `prrr-treesit-highlight`.
- Produces:
  - `prrr-treesit--queue` (buffer-local list of file sections) and `prrr-treesit--timer` (buffer-local idle timer or nil).
  - `(prrr-treesit--drain BUFFER)`.
  - `prrr-toggle-highlight` (interactive command).

- [ ] **Step 1: Write the failing tests**

Append to `test/prrr-treesit-test.el`:

```elisp
;;;; Deferral and the toggle

(defvar prrr-treesit-test--idle nil
  "The (BUFFER) arguments of the idle timers set, newest first.")

(defmacro prrr-treesit-test--with-idle-stub (&rest body)
  "Run BODY with `run-with-idle-timer' recording into `prrr-treesit-test--idle'."
  (declare (indent 0))
  `(let ((prrr-treesit-test--idle nil))
     (cl-letf (((symbol-function 'run-with-idle-timer)
                (lambda (_secs _repeat _function &rest args)
                  (push args prrr-treesit-test--idle)
                  'prrr-treesit-test-timer))
               ((symbol-function 'cancel-timer) #'ignore))
       ,@body)))

(defun prrr-treesit-test--colored-p (path)
  "Non-nil when the `file' section of PATH has syntax faces."
  (let ((file (prrr-diff-test--file-section path)))
    (text-property-not-all (oref file start) (oref file end) 'prrr-treesit-face nil)))

(ert-deftest prrr-treesit-test-refresh-defers-to-idle ()
  "Files shown by a refresh wait for the idle timer, so first paint does not."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-idle-stub
    (prrr-treesit-test--with-buffer
      (setq-local prrr-eager-files 10)
      (magit-refresh-buffer)
      (should-not (prrr-treesit-test--colored-p "src/sample.c"))
      (should prrr-treesit-test--idle)
      (prrr-treesit--drain (current-buffer))
      (should (prrr-treesit-test--colored-p "src/sample.c")))))

(ert-deftest prrr-treesit-test-large-file-defers-to-idle ()
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-idle-stub
    (prrr-treesit-test--with-buffer
      (let ((prrr-highlight-max-lines 30))
        (magit-section-show (prrr-diff-test--file-section "src/sample.c"))
        (should (prrr-treesit-test--colored-p "src/sample.c"))
        (magit-section-show (prrr-diff-test--file-section "src/big.c"))
        (should-not (prrr-treesit-test--colored-p "src/big.c"))
        (prrr-treesit--drain (current-buffer))
        (should (prrr-treesit-test--colored-p "src/big.c"))))))

(ert-deftest prrr-treesit-test-drain-skips-stale-sections ()
  "A refresh while a file waits leaves the old section unhighlighted, without error."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-idle-stub
    (prrr-treesit-test--with-buffer
      (let ((prrr-highlight-max-lines 30)
            (highlighted nil)
            (highlight (symbol-function 'prrr-treesit-highlight)))
        (magit-section-show (prrr-diff-test--file-section "src/big.c"))
        (let ((stale (prrr-diff-test--file-section "src/big.c")))
          (magit-refresh-buffer)
          (cl-letf (((symbol-function 'prrr-treesit-highlight)
                     (lambda (section) (push section highlighted) (funcall highlight section))))
            (prrr-treesit--drain (current-buffer)))
          (should-not (memq stale highlighted))
          (should (prrr-treesit-test--colored-p "src/big.c")))))))

(ert-deftest prrr-treesit-test-drain-yields-to-input ()
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-idle-stub
    (prrr-treesit-test--with-buffer
      (let ((prrr-highlight-max-lines 30))
        (magit-section-show (prrr-diff-test--file-section "src/big.c"))
        (setq prrr-treesit-test--idle nil)
        (cl-letf (((symbol-function 'input-pending-p) (lambda (&rest _) t)))
          (prrr-treesit--drain (current-buffer)))
        (should-not (prrr-treesit-test--colored-p "src/big.c"))
        (should prrr-treesit--queue)
        (should prrr-treesit-test--idle)))))

(ert-deftest prrr-treesit-test-kill-cancels-timer ()
  (skip-unless (treesit-language-available-p 'c))
  (let ((buffer nil) (timer nil))
    (prrr-treesit-test--with-buffer
      (let ((prrr-highlight-max-lines 30))
        (magit-section-show (prrr-diff-test--file-section "src/big.c"))
        (setq buffer (current-buffer) timer prrr-treesit--timer)
        (should (memq timer timer-idle-list))))
    (should-not (buffer-live-p buffer))
    (should-not (memq timer timer-idle-list))))

(ert-deftest prrr-treesit-test-toggle ()
  "L turns highlighting off in this buffer only, and back on."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-idle-stub
    (prrr-treesit-test--with-buffer
      (magit-section-show (prrr-diff-test--file-section "src/sample.c"))
      (should (prrr-treesit-test--colored-p "src/sample.c"))
      (prrr-toggle-highlight)
      (should-not prrr-highlight)
      (should (default-value 'prrr-highlight))
      (should (zerop (hash-table-count prrr-treesit--languages)))
      (should-not (text-property-not-all (point-min) (point-max) 'prrr-treesit-face nil))
      (prrr-toggle-highlight)
      (should prrr-highlight)
      (prrr-treesit--drain (current-buffer))
      (should (prrr-treesit-test--colored-p "src/sample.c")))))

(ert-deftest prrr-treesit-test-l-key ()
  (should (eq 'prrr-toggle-highlight (keymap-lookup prrr-diff-mode-map "L")))
  (should (eq 'prrr-toggle-highlight (keymap-lookup prrr-diff-file-section-map "L")))
  (should (eq 'prrr-toggle-highlight (keymap-lookup prrr-diff-hunk-section-map "L"))))
```

`prrr-treesit-test-toggle` relies on the file section's fold surviving the toggle's refresh through the visibility cache (the user expanded it with `magit-section-show`). If the fold does not survive in batch, expand it again after each toggle before checking. Record that in the report.

`prrr-treesit-test--with-buffer` binds `prrr-highlight` with `let`, so `default-value` inside it is `t`. The check `(should (default-value 'prrr-highlight))` proves the toggle was buffer-local.

- [ ] **Step 2: Run them to see them fail**

Run: `make test SELECTOR='"prrr-treesit-test"'`
Expected: the new tests fail (`prrr-treesit--drain` and `prrr-toggle-highlight` are void; files painted by a refresh are colored at once).

- [ ] **Step 3: Implement**

In `prrr-treesit.el`, replace `prrr-treesit--request` with the version below and add the rest after it:

```elisp
(defvar-local prrr-treesit--queue nil
  "The `file' sections waiting for the idle timer, oldest first.")

(defvar-local prrr-treesit--timer nil
  "The idle timer that highlights `prrr-treesit--queue', or nil.")

(defun prrr-treesit--request (file)
  "Highlight FILE, a `file' section, unless it was already or highlighting is off.
A file painted during a refresh, or longer than
`prrr-highlight-max-lines', waits for Emacs to be idle, so neither the
first paint nor a refresh waits on it.  `magit--refreshing-buffer-p' is
magit's own flag for deferring paint work in a refresh."
  (when (and prrr-highlight (eq (oref file type) 'file))
    (unless prrr-treesit--done
      (setq prrr-treesit--done (make-hash-table :test #'eq :weakness 'key)))
    (unless (gethash file prrr-treesit--done)
      (puthash file t prrr-treesit--done)
      (if (or magit--refreshing-buffer-p
              (> (count-lines (oref file content) (oref file end)) prrr-highlight-max-lines))
          (prrr-treesit--enqueue file)
        (prrr-treesit--highlight-reporting file)))))

(defun prrr-treesit--enqueue (file)
  "Queue FILE to be highlighted when Emacs is next idle."
  (setq prrr-treesit--queue (nconc prrr-treesit--queue (list file)))
  (unless prrr-treesit--timer
    (setq prrr-treesit--timer
          (run-with-idle-timer 0 nil #'prrr-treesit--drain (current-buffer)))))

(defun prrr-treesit--live-p (file)
  "Non-nil when FILE is still a section of the current buffer.
A refresh replaces every section."
  (eq file (magit-get-section (magit-section-ident file))))

(defun prrr-treesit--drain (buffer)
  "Highlight the queued files of BUFFER, oldest first, yielding to input.
A file a refresh replaced is dropped: its new section queues itself
when painted.  What is left when input arrives waits for the next idle
time."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq prrr-treesit--timer nil)
      (while (and prrr-treesit--queue (not (input-pending-p)))
        (let ((file (pop prrr-treesit--queue)))
          (when (prrr-treesit--live-p file)
            (prrr-treesit--highlight-reporting file))))
      (when prrr-treesit--queue
        (setq prrr-treesit--timer
              (run-with-idle-timer 0 nil #'prrr-treesit--drain buffer))))))

(defun prrr-treesit--cancel ()
  "Cancel this buffer's idle highlighting; for `kill-buffer-hook'."
  (when prrr-treesit--timer
    (cancel-timer prrr-treesit--timer)
    (setq prrr-treesit--timer nil)))

(defun prrr-treesit--setup ()
  "Make killing this Review Buffer cancel its idle highlighting (SPEC section 11)."
  (add-hook 'kill-buffer-hook #'prrr-treesit--cancel nil t))

(add-hook 'prrr-diff-mode-hook #'prrr-treesit--setup)

;;;###autoload
(defun prrr-toggle-highlight ()
  "Toggle syntax highlighting in this Review Buffer.
Sets `prrr-highlight' in this buffer only, rereads the languages'
highlighting rules, so a changed `treesit-font-lock-level' applies, and
redraws at the head shown."
  (interactive)
  (unless (derived-mode-p 'prrr-diff-mode)
    (user-error "Not in a Review Buffer"))
  (setq-local prrr-highlight (not prrr-highlight))
  (clrhash prrr-treesit--languages)
  (magit-refresh-buffer)
  (message "Syntax highlighting %s" (if prrr-highlight "on" "off")))
```

`prrr-diff-mode-hook` runs after the mode body, so the hook added when the body first loads this file still runs for that first buffer.

In `prrr-diff.el`: add `("L" . prrr-toggle-highlight)` to the end of `prrr-diff--review-keys`; set `prrr-diff--later-keys` to `'("@")`.

In `prrr.el`, after the `prrr-mark-seen` autoload:

```elisp
(autoload 'prrr-toggle-highlight "prrr-treesit" "Toggle syntax highlighting in this Review Buffer." t)
```

In `prrr-transient.el`: `(require 'prrr-treesit)` after `(require 'prrr-range)`; in `prrr-menu`'s "View" group, after `("Z" "expand all" prrr-expand-all)`, add `("L" "toggle highlighting" prrr-toggle-highlight)`.

- [ ] **Step 4: Run the tests**

Run: `make test SELECTOR='"prrr-treesit-test"'`, then `make test`.
Expected: all pass, including `prrr-diff-test-later-keys-do-nothing-yet`, which now finds `L` among the review keys. Task 2's tests still pass because they expand files outside a refresh.

- [ ] **Step 5: Full gates and commit**

Run `make compile && make lint && make test`.

```bash
git add prrr-treesit.el prrr-diff.el prrr.el prrr-transient.el test/
git commit -m "feat(treesit): highlight on idle after a refresh or for large files; L toggles"
```

---

### Task 4: Bench with highlighted C files; README, SPEC and CI

**Files:**
- Modify: `bench/make-diff-repo.sh`, `bench/prrr-diff-bench.el`
- Modify: `README.md`, `SPEC.md`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: everything above. `prrr-treesit-face` tells whether a section was highlighted.

- [ ] **Step 1: The benchmark repository gets five highlighted files**

In `bench/make-diff-repo.sh`, the loop builds `files - 5` text files. After the existing head edits and before `git commit -q -a -m head`, add five new C files of 300 lines in a directory sorting after the others, so they are never eager:

```sh
mkdir -p zz
j=0
while [ "$j" -lt 5 ]; do
  k=1
  : > "zz/expand$j.c"
  while [ "$k" -le 300 ]; do
    printf 'static int value_%d(int x) { return x + %d; /* line %d */ }\n' "$k" "$k" "$k" >> "zz/expand$j.c"
    k=$((k + 1))
  done
  j=$((j + 1))
done
git add zz
```

Change the loop bound from `"$files"` to `"$((files - 5))"`, and the header comment to: "FILES files (argument 2): FILES - 5 300-line text files with three lines changed in each, in directories of 100 files, and five new 300-line C files under zz/ that the expand budget highlights."

- [ ] **Step 2: The expand budget measures highlighting**

In `bench/prrr-diff-bench.el`:
- `(require 'prrr-treesit)` with the other requires.
- In `prrr-diff-bench--measure`, the `expands` list takes the unwashed sections whose path ends in `.c` (`(seq-filter (lambda (file) (string-suffix-p ".c" (oref file value))) (prrr-diff-bench--unwashed))`) instead of the first five unwashed. After each `magit-section-show`, check the file: if `(prrr-treesit-rules "x.c")` is non-nil but the section has no `prrr-treesit-face`, signal `(error "Expanding %s did not highlight it" path)`, so the budget never silently measures nothing.
- In `prrr-diff-bench-run`, before measuring: when `(treesit-language-available-p 'c)` is nil, print `"No C grammar: the expand budget is measured without highlighting"`.
- Replace the commentary sentence "Highlighting arrives in milestone 6; until then the expand budget is measured without it." with: "The expanded files are C, highlighted when the C grammar is installed (`treesit-install-language-grammar`); without it the expand budget is measured unhighlighted and says so."

Run `make bench`. Expected: "expand one 300-line file" stays within its 25 ms budget (fail line 31.25 ms). The open and refresh budgets are unchanged. The Review Queue budget may still fail (bead `prrr-opy`, out of scope). Record every number in the report. If the expand budget fails, report it with the numbers rather than tuning blindly.

- [ ] **Step 3: SPEC section 6**

Replace the "Syntax highlighting" paragraph of SPEC section 6 with:

```markdown
**Syntax highlighting** (`prrr-treesit.el`). Applied when a file section is
first shown, never while collapsed: when a hunk of it is first painted.
One `treesit` parser per side, new (context and `+` lines) and old
(context and `-` lines), with included ranges set to the line bodies
(prefix char excluded); context lines take the new side's faces. The
parsers live only for the call. The rules are the cached
`treesit-font-lock-settings` of the language's ts-mode, run once in a
temporary buffer with its hooks delayed, applied by a small
`treesit-query-capture` loop. Never `treesit-font-lock-fontify-region`
or `treesit-range-settings`. Faces go on the `prrr-treesit-face`
property and are put in front of `font-lock-face` after every paint of
the hunk, since magit resets `font-lock-face` when point enters or
leaves a hunk; the diff line's face stays behind them. Language is
chosen from the file name through `auto-mode-alist` and the remapping
options (`major-mode-remap-alist`, and `major-mode-remap-defaults` on
Emacs 30 and later); when that gives FOO-mode, FOO-ts-mode stands in if
it is defined. Files without an available grammar are left
unhighlighted, silently. `prrr-highlight` (default t) turns it on; `L`
toggles it in one buffer. Files painted during a refresh, and sections
larger than `prrr-highlight-max-lines` (default 3,000), are highlighted
on an idle timer, so first paint and refresh never wait on it.
Measured: 1.3 / 9.7 / 34 ms per 100 / 300 / 1,000-line section.
```

In SPEC section 2's table, change `prrr-diff.el`'s "Depends on" to add "(loads prrr-treesit when a Review Buffer starts)". Change nothing else in that table.

- [ ] **Step 4: README**

In `README.md`:
- In the Status note, replace "Syntax highlighting of the diff is next." with "So does syntax highlighting of the diff. The agent API is next." Also add "syntax highlighting" to the list of things that work, so the note reads naturally.
- In "Requirements", after the Emacs line, add: "Syntax highlighting needs Emacs built with tree-sitter and the grammars of your languages (`M-x treesit-install-language-grammar`); without them the diff shows uncolored."
- In "The Review Buffer", add a "### Syntax highlighting" subsection before "### Keys in the Review Buffer". Write it in the README's voice, covering:
  - A file is colored the first time it is shown, using the tree-sitter rules of its language.
  - The language is the one visiting the file would pick. When that is `foo-mode` and `foo-ts-mode` exists, its rules are used, so no `major-mode-remap-alist` setup is needed.
  - Files without a grammar stay uncolored.
  - Very large files, and files redrawn by a refresh, are colored a moment later.
  - `treesit-font-lock-level` sets how much is colored.
- In the Review Buffer key table, add a row for `L`: "toggle syntax highlighting in this buffer".
- In the Review Buffer's options (add a "### Options" table under the Review Buffer section if there is none, matching the Review Queue's "### Options" format), add `prrr-highlight` (default `t`: highlight diff lines) and `prrr-highlight-max-lines` (default `3000`: larger file sections are highlighted when Emacs is idle).

- [ ] **Step 5: CI installs the C grammar**

In `.github/workflows/ci.yml`, after "Install dependencies from MELPA and GNU ELPA", add:

```yaml
      - name: Install the C tree-sitter grammar (highlighting tests skip without it)
        continue-on-error: true
        run: >-
          emacs -Q --batch --eval '(progn (require (quote treesit))
          (when (treesit-available-p)
          (setq treesit-language-source-alist
          (quote ((c "https://github.com/tree-sitter/tree-sitter-c" "v0.21.4"))))
          (treesit-install-language-grammar (quote c))))'
```

This step is not verifiable locally; say so in the report. Check the YAML parses: `python3 -c 'import yaml,sys; yaml.safe_load(open(".github/workflows/ci.yml"))'`.

- [ ] **Step 6: Full gates and commit**

Run `make compile && make lint && make test`. Also check that `make bench`'s expand line passes.

```bash
git add bench/ README.md SPEC.md .github/workflows/ci.yml
git commit -m "docs, bench, ci: highlighting in the README, SPEC 6, expand budget and CI grammar"
```
