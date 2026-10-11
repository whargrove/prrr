# Review Buffer Milestone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship milestone 3 of `prrr` (SPEC.md section 15, item 3): a read-only Review Buffer, `prrr-diff-mode`, that opens a PR's diff with hybrid lazy rendering, shows Threads and File Comments inline, groups outdated and not-in-range Threads, has a header with the description and discussion, folds Viewed files, keeps folds across refresh, refetches review data in the background, and has jump and fold commands, a transient, and a benchmark harness.

**Architecture:** Two new files. `prrr-thread.el` renders one Thread (or File Comment) and its Review Comments as magit sections. `prrr-diff.el` is the Review Buffer: it lists changed files from one `git diff --raw --numstat`, washes a file's hunks only when the file is first expanded, and inserts Thread sections inside hunks with its own copy of magit's hunk washer. Three magit touch points keep magit's painting, `RET` and section positions correct when hunks have children. The pure rule for where a Thread goes lives in `prrr-state.el`. Review data is stored by `prrr-db.el`, fetched by the existing `prrr-github-fetch-review-data`, and refetched in the background by `prrr-sync.el`, which also sends the one write this milestone has: the Viewed flag.

**Tech Stack:** Emacs Lisp (Emacs 29.1+), magit 4.7 (`magit-diff-mode`, `magit-insert-section`, `magit-insert-section-body`, `magit-setup-buffer`), forge 0.5 (`forge-pullreq`, `forge-insert-post`, `forge-mutate`, `forge-buffer-topic`), emacsql 4.4, transient 0.13, git, ERT.

**Spec:** `SPEC.md` sections 2, 3, 6, 7, 9, 11, 12, 13, 15. Glossary: `CONTEXT.md`. Earlier facts: `docs/superpowers/notes/2026-10-10-foundation-facts.md` and the "Milestone-2 facts" of `docs/superpowers/plans/2026-10-10-review-queue.md`. Rendering decision and prototype numbers: `bd show prrr-t9q.1`.

## Milestone-3 facts (verified 2026-10-10 against magit 20261009.1317, magit-section 20260926.1436, forge 20261006.1249, Emacs 30.2, git 2.56)

Verified by reading the source and by batch experiments, including a working prototype of the Review Buffer core that is the basis of Tasks 7 and 8.

**Washing**
- `magit-insert-section-body` stores its body as the section's `washer` when the section is created hidden. `magit-section-show` runs it through `magit-section--opportunistic-wash`, which binds the section as parent, so sections inserted by the body become its children. There is no `catch 'cancel-section` around it.
- `magit-git-wash` and `magit-diff-wash-diffs` cannot be used inside a deferred body. On empty output they throw `cancel-section` to a missing catch. On normal output `magit-diff-wash-diffs` builds a second `file` section inside prrr's own. The working recipe: `magit-git-insert` the per-file diff, narrow to it, delete everything before the first `^@@` line, then `(magit-wash-sequence #'WASH-ONE-HUNK)`. A diff without `@@` (binary, mode-only, pure rename) has to be handled explicitly. Status, rename and binary information come from the file list, not the deleted header.
- magit's `magit-diff-wash-hunk` (magit-diff.el:2982) builds `(hunk (cons about ranges) nil :combined :from-range :to-range :about)` and only skips over body lines. Body faces come later from `magit-section-paint`.
- `magit-section-inhibit-markers` set to `delay` makes `start`, `content` and `end` integers while inserting. When the root finishes, magit converts `start` and `end` to markers **but not `content`**. Once a deferred body inserts text, every later section's `content` is stale: hiding it hides the wrong region, and `magit-diff-hunk-line` miscounts. Fix: after the root section is inserted, `oset` every integer `content` to `(copy-marker content)`.

**Coupling**
- `(cl-defmethod magit-section-paint ((section magit-hunk-section) highlight &context (major-mode prrr-diff-mode)) ...)` is chosen over magit's method in a `prrr-diff-mode` buffer, and `cl-call-next-method` with changed arguments works. magit's method paints from the line after point to the section's `end` and skips the line point is on. Calling it once per run of diff lines, with `end` temporarily set to the next child's start, leaves Thread faces alone. Without it, Thread lines are repainted as diff context.
- `magit-diff-hunk-line (section goto-from)` counts every line from `content` to point, so lines after a Thread child map to the wrong file line. An `:around` advice that counts only lines whose `(magit-section-at)` is the hunk itself, and treats a point inside a child as the diff line that child follows, gives correct numbers. Its only caller is `magit-diff-visit--position` (RET, `C-j`, other-window visits).
- `magit-diff--hunk-section` takes a file's first child as its first hunk. A `file-comment` first child makes RET on the file heading signal `invalid-slot-name from-range`. An `:around` advice that returns the first real hunk fixes it.
- RET on a Thread line signals, because `magit-diff-scope` is nil for type `thread`. Threads need their own RET (`prrr-thread-visit`).
- `magit-diff-fontify-hunk` must be nil in prrr buffers, because the hunk fontifier walks every line. `diff-refine-hunk` still works; a Thread after a removed line only splits that `-`/`+` pairing.

**Sections and keymaps**
- `magit-insert-section` resolves a section's keymap from `magit-TYPE-section-map`, then `forge-TYPE-section-map`. A section of type `discussion` would get `forge-discussion-section-map`. `(oset section keymap ...)` inside the body overrides it, as in milestone 2. `thread`, `file-comment`, `review-comment`, `description`, `not-in-range`, `outdated` and `outdated-files` have no map.
- `(magit-insert-section ((eval FORM) VALUE HIDE) ...)` computes the type at run time.
- `magit-section-forward`/`backward` (`n`/`p`) descend into Thread and comment sections. Levels: file is 1, hunk 2, thread 3, comment 4.

**Visibility**
- With magit's defaults, the only thing that carries visibility across a refresh is `magit-section-visibility-cache`. It is consulted first when a section is created; the hide argument of `magit-insert-section` applies only when the cache has no entry. The cache records only `magit-section-show`/`hide` calls (user toggles), restricted to the types in `magit-section-cache-visibility`. With `(setq-local magit-section-cache-visibility '(file thread file-comment))`, an expanded lazy file and a folded Thread both survive `magit-refresh-buffer`. A cached `show` makes a deferred body run eagerly on refresh.
- A Thread's identity includes its hunk's ranges, `((thread . ID) (hunk nil (9 7) (9 7)) (file . PATH) (diffbuf))`, so a Thread whose hunk changes after a push loses its cached fold.

**Buffer**
- `magit-setup-buffer` with `:buffer NAME` gives one buffer per name. forge's topic buffers do the same. `magit-refresh-buffer` calls `prrr-diff-refresh-buffer`, the name derived from the mode.
- `magit-buffer-diff-type` must be `committed`, because `magit-diff--dwim` uses `pcase-exhaustive` on it. `magit-buffer-diff-range` set to `"BASE-OID..HEAD-OID"` makes RET open the blob at the head oid (`FILE.~OID~`) at the right line. `magit-buffer-revision` must stay nil.
- `C-c C-e` in `magit-diff-section-map` is `magit-diff-edit-hunk-commit`, not ediff. Ediff is `e` (`magit-ediff-dwim`) and `E` (`magit-ediff`) in `magit-mode-map`. prrr takes `e` in milestone 4, so ediff from a hunk stays on `E`. `j` in `magit-diff-mode-map` is `magit-jump-to-diffstat-or-diff`, which prrr overrides.
- `forge-buffer-topic` (forge-topic.el:1356) is a public buffer-local variable. Setting it in the Review Buffer makes `forge-current-pullreq`, and therefore `prrr-open-topic`, `prrr-browse` and `prrr-checkout`, act on the buffer's PR.

**forge**
- forge fetches PR heads with the refspec `+refs/pull/*/head:refs/pullreqs/*` (`forge-add-pullreq-refspec`, default t). There is no base ref. `(oref pullreq base-rev)` is GitHub's `baseRefOid` from the last forge pull, and it is in the local repository after `forge-pull`.
- `forge-pullreq` takes `:base-rev :head-rev :body :author :created :title :their-id :number` as initargs. `forge-pullreq-post` takes `:id :author :created :body`.
- Slots without an `:initform` (`base-rev`, `body`, `title` and others) stay unbound on a constructed object unless passed, and `oref` on them signals. Tests pass every slot the code reads, `nil` included.
- `(forge-insert-post POST TOPIC)` inserts a `post` section with forge's heading and fontified Markdown body, and works on constructed objects in batch. `(forge-insert-post pullreq nil)` renders the PR description.
- `(forge-mutate HOST MUTATION ((NAME FORM)...) :callback :errorback)` is forge's public mutation macro. It sends `(mutation (MUTATION [(input $input MUTATIONInput!)] clientMutationId))` with variables `((input (NAME . VALUE)...))` through `ghub-query`.
- `forge-read-pullreq` returns a topic id string; `(forge-get-pullreq ID)` turns it into the object.

**git**
- `git diff -z -M --raw --numstat BASE HEAD` prints every raw record (`:MODES SHAS STATUS\0PATH\0`, or `\0OLD\0NEW\0` for R and C), then every numstat record in the same order (`ADDED\tDELETED\tPATH\0`, or `ADDED\tDELETED\t\0OLD\0NEW\0`; `-\t-` for binary files).

**Measured with the prototype** (byte-compiled, fresh buffer, generated repositories with three changed lines in each 300-line file): first paint at 417 files 115 ms (SPEC budget 150), at 2,516 files 360 ms (budget 500). Expanding one file 2 to 4 ms. Refresh with three files expanded at 417 files 110 ms (budget 250). At 2,516 files a refresh costs 520 ms, because the previous render's markers are still in the buffer when the new one inserts. SPEC has no refresh budget at that size.

## Decisions taken in this plan

- **Viewed is writable in this milestone.** SPEC lists Viewed under milestone 3, and `v` folds and marks a file. The local row is written first and the mutation runs in the background. On failure the previous row is restored, a message says why, and the buffer refreshes. The Outbox (milestone 4) replaces that fallback. A refetch that lands before the mutation answers can briefly show the old flag; the next refetch corrects it.
- **Dependency direction.** `prrr-thread.el` renders Threads and depends only on `prrr-db` and magit. `prrr-diff.el` requires it. SPEC section 2 lists the reverse and is corrected in Task 13. The capture buffer of milestone 4 receives its anchor as an argument, so it never needs `prrr-diff`.
- **Base and head.** Head is `refs/pullreqs/N`. Base is `git merge-base BASE-REV HEAD`, recomputed on every refresh (one git call), so `g` after a `forge-pull` picks up a new head. A missing head ref makes `prrr-review` offer `forge-pull`. A missing base commit renders a one-line note instead of the files.
- **Eager budget.** Files are washed from the top, skipping Viewed files, while fewer than `prrr-eager-files` files and at most `prrr-eager-lines` changed lines have been taken. The first file that would pass a limit ends the run, so one 20,000-line file at the top never stalls the open.
- **Folds.** The visibility cache decides for a file or Thread the user has toggled. Otherwise a Viewed file starts folded, a resolved Thread starts folded, and the eager budget decides for files. `v` hides or shows the file before refreshing, so the cache and the Viewed flag agree.
- **Section values.** A `thread` or `file-comment` section's value is the Thread id, and a `review-comment` section's value is the comment id. The structs stay in buffer-local tables, so a refetch that changes `fetched-at` keeps the section identity, and with it the fold.
- **Keys from later milestones.** In `prrr-diff-mode-map`, magit keys that SPEC section 9 gives to prrr commands of milestones 4 to 7 (`c C r e k d R s D . m > < S O @ L`) are bound to `undefined` until then, so magit's commit, discard, stage or rebase never run from a Review Buffer.
- **`RET` on a queue row** now runs `prrr-review` (SPEC section 9).
- **Header status.** One line: the Range, the Pending Review's comment count when there is one, the refetch state (`refreshing…`, `offline`, `rate limited until HH:MM`, or the error), and `GitHub's head is abc1234: run forge-pull, then g` when the last refetch saw a head other than the local ref. Milestone 5 adds "head moved, press g" and Ranges.

## Global Constraints

- Every `.el` file starts with `;;; NAME.el --- DESCRIPTION  -*- lexical-binding: t -*-`, carries the GPL-3.0-or-later header used by `prrr-db.el`, has `;;; Commentary:` and `;;; Code:` sections and ends with `(provide 'NAME)` and `;;; NAME.el ends here`.
- `prrr.el`'s `Package-Requires` stays exactly `((emacs "29.1") (magit "4.7") (forge "0.5") (emacsql "4.4") (transient "0.13") (compat "31"))`.
- Every symbol starts with `prrr-`; internals use `prrr-FILE--`. Struct constructors are named explicitly and copiers are disabled.
- No `forge--` symbol anywhere in the repository (SPEC 1, quality 4). forge is used only through `oref` on its classes, `forge-get-*`, `forge-current-pullreq`, `forge-read-pullreq`, `forge-pull`, `forge-query`, `forge-mutate`, `forge-db`, `forge-insert-post`, `forge-buffer-topic`, `forge-visit-topic`, `forge-browse-pullreq`, `forge-checkout-pullreq`, `magit-add-section-hook`.
- magit internals: only the two advised functions `magit-diff-hunk-line` and `magit-diff--hunk-section`, plus the `magit-section-paint` method (SPEC section 6). No other `magit--` or `magit-*--` symbol.
- No `with-eval-after-load` / `eval-after-load` in package code (package-lint fails on them).
- `prrr.el` loads nothing at load time; `(require 'prrr)` must keep loading neither forge, magit nor emacsql (`prrr-test-require-prrr-does-not-load-forge`).
- No personal paths, hosts, tokens or logins; tests use `example` names.
- All SQL lives in `prrr-db.el`; all GitHub calls in `prrr-github.el`; `prrr-state.el` has no buffer, network, git or forge access.
- Timestamps are ISO 8601 UTC strings compared with `string<`.
- Only Emacs 29.1 APIs: no Emacs 30 `sort` keyword arguments, no `value<`.
- Tests never touch the network; git is used only on repositories they create under `temporary-file-directory`.
- `make compile` (warnings are errors), `make lint` (package-lint + checkdoc) and `make test` must pass before every commit. Every new source file joins `SRC` and every new test file `TESTS` in the `Makefile` in the task that creates it.
- Commit after every task with a conventional message ending with the session's attribution lines. CLAUDE.md permits commits without approval; never push.
- User-visible commands, keys and options reach `README.md` in Task 13, the milestone's last task.

## Review Focus

1. **A PR whose local refs are stale or missing.** `refs/pullreqs/N` absent (forge never fetched it, or `forge-add-pullreq-refspec` is off): `prrr-review` offers `forge-pull` and never opens a broken buffer. The base commit absent: the buffer opens with a one-line note and the header. GitHub's head newer than the local ref: Threads anchored to lines that are not in the local diff go to `not-in-range`, never vanish, and the header says to pull. Pinned in Task 7 (`prrr-diff-test-missing-base-note`), Task 8 (`prrr-diff-test-thread-not-in-range`), Task 9 (`prrr-diff-test-header-github-head-differs`) and Task 10 (`prrr-diff-test-review-missing-ref-offers-pull`).
2. **Files that are not plain text edits.** Binary files, pure renames, deletions, new files, and mode-only changes have no `@@` hunks. Each still gets a file section, with a one-line body such as `Binary file, not shown`. No `cancel-section` throw, no empty section, no nested `file` section. Pinned in Task 5 (`prrr-diff-test-parse-changes-*`) and Task 7 (`prrr-diff-test-bodies-without-hunks`).
3. **Expanding a lazy file in the middle of the buffer.** Every section after it must still fold, highlight and map RET correctly (the `content` marker fact). Pinned in Task 7 (`prrr-diff-test-positions-after-lazy-wash`).
4. **Lines after a Thread.** RET on a diff line that follows a Thread visits the right file line, RET on the Thread visits its anchor, and painting keeps Thread faces. Pinned in Task 8 (`prrr-diff-test-ret-after-thread`, `prrr-diff-test-thread-visit`, `prrr-diff-test-paint-keeps-thread-faces`).
5. **Refetch failures while reading.** Offline, rate-limited or token rejected: the buffer keeps rendering from the database, the header says why, and a refresh caused by that failure does not start another refetch. Pinned in Task 4 (`prrr-sync-test-refetch-*`), Task 9 (`prrr-diff-test-header-shows-refetch-status`) and Task 10 (`prrr-diff-test-open-shows-buffer-and-refetches`).

---

## File structure

| File | Responsibility | Change |
|------|----------------|--------|
| `prrr-state.el` | Adds `prrr-file-threads`, `prrr-state-thread-layout`, `prrr-state-thread-anchor`. | Modify (Task 1) |
| `prrr-db.el` | Adds `prrr-db-replace-review-data`, `prrr-db-review-data`. | Modify (Task 2) |
| `prrr-github.el` | Adds `prrr-github-set-viewed`. | Modify (Task 3) |
| `prrr-sync.el` | Jobs keyed per repository or per PR; `prrr-sync-refetch`, `prrr-sync-review-status`, `prrr-sync-refetch-due-p`, `prrr-sync-describe`, `prrr-sync-set-viewed`. | Modify (Tasks 4, 11) |
| `prrr-queue.el` | Heading text through `prrr-sync-describe`; `RET` runs `prrr-review`. | Modify (Tasks 4, 10) |
| `prrr-thread.el` | Faces, `prrr-thread-section-map`, `prrr-thread-insert`, `prrr-thread-visit`. | Create (Task 6) |
| `prrr-diff.el` | Options, `prrr-diff-file`, change parsing, eager budget, mode, refresh, washer, magit coupling, header, `prrr-diff-open`, commands. | Create (Tasks 5, 7-11) |
| `prrr.el` | `prrr-review`; autoloads for the Review Buffer commands. | Modify (Task 10) |
| `prrr-transient.el` | `prrr-menu`; queue menu `RET`. | Modify (Tasks 10, 11) |
| `test/fixtures/make-repo.sh` | Builds the fixture repository. | Create (Task 5) |
| `test/prrr-test-helper.el` | `prrr-test-thread`, `prrr-test-with-repo`, `prrr-test-repo-base`. | Modify (Tasks 1, 5) |
| `test/prrr-thread-test.el`, `test/prrr-diff-test.el` | New ERT suites. | Create (Tasks 5, 6) |
| `bench/make-diff-repo.sh`, `bench/prrr-diff-bench.el` | Review Buffer budgets. | Create (Task 12) |
| `Makefile` | New files in `SRC`, `TESTS`; `bench` runs both benchmarks. | Modify (Tasks 5, 6, 12) |
| `README.md`, `SPEC.md` | Review Buffer docs; spec corrections. | Modify (Task 13) |

Running one test file: `make test TESTS=test/prrr-diff-test.el`. One test: `make test SELECTOR='"prrr-diff-test-eager"'`.

Shared test fixture: the review data fixture `test/fixtures/github/review-data.eld` belongs to PR `PR_kwDOexample0000001`. Its Threads are: `PRRT_kwDOexample0000001` (src/example.el line 12 RIGHT, two comments), `PRRT_kwDOexample0000002` (README.md lines 1-3 RIGHT, resolved), `PRRT_kwDOexample0000003` (src/old.el, outdated, LEFT, original line 40), `PRRT_kwDOexample0000004` (docs/notes.md, File Comment), and `PRRT_kwDOexample0000005` (src/example.el line 30 RIGHT, one pending comment). Its Viewed flags are src/example.el `VIEWED`, README.md `DISMISSED` and docs/notes.md `UNVIEWED`. The repository built by `make-repo.sh` in Task 5 matches these paths and lines.

---
### Task 1: Where a Thread is shown (pure rule)

**Files:**
- Modify: `prrr-state.el` (new part "Threads in the Review Buffer" before `(provide 'prrr-state)`; Commentary mentions it)
- Modify: `test/prrr-test-helper.el` (builder `prrr-test-thread`; Commentary lists it)
- Modify: `test/prrr-state-test.el`

**Interfaces:**
- Consumes: `prrr-thread` struct (milestone 1).
- Produces:
  - `prrr-file-threads` struct with slots `file-comments lines outdated`, constructor `prrr-file-threads-create`.
  - `(prrr-state-thread-layout THREADS PATHS)` → `(TABLE . ELSEWHERE)`; TABLE is an `equal` hash table from path to `prrr-file-threads`; ELSEWHERE a list of `prrr-thread`.
  - `(prrr-state-thread-anchor THREAD)` → `(SIDE . LINE)`, SIDE `left` or `right`.
  - Test builder `(prrr-test-thread &key id path line start-line side subject-type outdated-p resolved-p)`.

- [ ] **Step 1: Add the test builder**

Append to `test/prrr-test-helper.el`, after `prrr-test-meta`:

```elisp
(cl-defun prrr-test-thread (&key (id "T_1") (path "src/example.el") (line 12) start-line
                                 (side 'right) (subject-type 'line) outdated-p resolved-p)
  "Build a `prrr-thread' of PR_1 with sensible defaults.
Keyword arguments: ID, PATH, LINE, START-LINE, SIDE, SUBJECT-TYPE,
OUTDATED-P and RESOLVED-P."
  (prrr-thread-create :thread-id id :pr-id "PR_1" :path path :line line
                      :start-line start-line :side side
                      :start-side (and start-line side)
                      :subject-type subject-type :outdated-p outdated-p
                      :resolved-p resolved-p :original-line line))
```

Add `prrr-test-thread` to the helper's Commentary list of builders.

- [ ] **Step 2: Write the failing tests**

Append to `test/prrr-state-test.el` (a new part `;;;; Threads in the Review Buffer`):

```elisp
(defun prrr-state-test--ids (threads)
  "Return the ids of THREADS."
  (mapcar #'prrr-thread-thread-id threads))

(ert-deftest prrr-state-test-layout-sorts-by-kind ()
  (let* ((layout (prrr-state-thread-layout
                  (list (prrr-test-thread :id "FILE" :subject-type 'file :line nil)
                        (prrr-test-thread :id "LINE")
                        (prrr-test-thread :id "OLD" :outdated-p t)
                        (prrr-test-thread :id "NOLINE" :line nil))
                  '("src/example.el")))
         (entry (gethash "src/example.el" (car layout))))
    (should (equal '("FILE") (prrr-state-test--ids (prrr-file-threads-file-comments entry))))
    (should (equal '("LINE") (prrr-state-test--ids (prrr-file-threads-lines entry))))
    (should (equal '("OLD" "NOLINE") (prrr-state-test--ids (prrr-file-threads-outdated entry))))
    (should (null (cdr layout)))))

(ert-deftest prrr-state-test-layout-keeps-input-order ()
  (let ((entry (gethash "a" (car (prrr-state-thread-layout
                                  (list (prrr-test-thread :id "2" :path "a" :line 30)
                                        (prrr-test-thread :id "1" :path "a" :line 5))
                                  '("a"))))))
    (should (equal '("2" "1") (prrr-state-test--ids (prrr-file-threads-lines entry))))))

(ert-deftest prrr-state-test-layout-files-not-in-diff ()
  "A Thread of any kind on a file outside PATHS goes to ELSEWHERE, in order."
  (let ((layout (prrr-state-thread-layout
                 (list (prrr-test-thread :id "G1" :path "gone.el")
                       (prrr-test-thread :id "IN" :path "a")
                       (prrr-test-thread :id "G2" :path "gone.el" :subject-type 'file :line nil))
                 '("a"))))
    (should (equal '("G1" "G2") (prrr-state-test--ids (cdr layout))))
    (should-not (gethash "gone.el" (car layout)))))

(ert-deftest prrr-state-test-layout-path-without-threads-absent ()
  (should (zerop (hash-table-count (car (prrr-state-thread-layout nil '("a" "b")))))))

(ert-deftest prrr-state-test-anchor ()
  (should (equal '(right . 12) (prrr-state-thread-anchor (prrr-test-thread))))
  (should (equal '(left . 7) (prrr-state-thread-anchor (prrr-test-thread :side 'left :line 7))))
  (should (equal '(right . 3) (prrr-state-thread-anchor (prrr-test-thread :side nil :line 3))))
  (should (equal '(right . 9) (prrr-state-thread-anchor
                               (prrr-test-thread :start-line 4 :line 9)))))
```

- [ ] **Step 3: Run them to verify they fail**

Run: `make test TESTS=test/prrr-state-test.el SELECTOR='"prrr-state-test-\\(layout\\|anchor\\)"'`
Expected: FAIL, `prrr-state-thread-layout` is void.

- [ ] **Step 4: Implement**

Insert before `(provide 'prrr-state)` in `prrr-state.el`:

```elisp
;;;; Threads in the Review Buffer

(cl-defstruct (prrr-file-threads (:constructor prrr-file-threads-create)
                                 (:copier nil))
  "The Threads of one file of a diff, by where the Review Buffer shows them.
FILE-COMMENTS are File Comments, shown first.  LINES are Threads
anchored to lines, shown after their line, or in the file's
`not-in-range' section when that line is not in the diff.  OUTDATED
are the Threads GitHub marks outdated, and line Threads without a line.
Each list keeps the input order."
  file-comments lines outdated)

(defun prrr-state-thread-layout (threads paths)
  "Sort THREADS by where the Review Buffer shows them.
PATHS are the files of the diff.  Return (TABLE . ELSEWHERE): TABLE is
a hash table from each path in PATHS that has Threads to its
`prrr-file-threads'; ELSEWHERE lists, in input order, the Threads whose
file is not in PATHS, which the buffer shows in `outdated-files'."
  (let ((known (make-hash-table :test #'equal))
        (table (make-hash-table :test #'equal))
        (elsewhere nil))
    (dolist (path paths)
      (puthash path t known))
    (dolist (thread threads)
      (let ((path (prrr-thread-path thread)))
        (if (not (gethash path known))
            (push thread elsewhere)
          (let ((entry (or (gethash path table)
                           (puthash path (prrr-file-threads-create) table))))
            (cond ((eq (prrr-thread-subject-type thread) 'file)
                   (push thread (prrr-file-threads-file-comments entry)))
                  ((or (prrr-thread-outdated-p thread) (null (prrr-thread-line thread)))
                   (push thread (prrr-file-threads-outdated entry)))
                  (t (push thread (prrr-file-threads-lines entry))))))))
    (maphash (lambda (_path entry)
               (setf (prrr-file-threads-file-comments entry)
                     (nreverse (prrr-file-threads-file-comments entry))
                     (prrr-file-threads-lines entry)
                     (nreverse (prrr-file-threads-lines entry))
                     (prrr-file-threads-outdated entry)
                     (nreverse (prrr-file-threads-outdated entry))))
             table)
    (cons table (nreverse elsewhere))))

(defun prrr-state-thread-anchor (thread)
  "Return (SIDE . LINE): the Review Buffer shows THREAD after LINE of SIDE.
SIDE is `left' for the old file and `right' for the new one, also when
GitHub sent no side.  A range Thread is shown after its last line."
  (cons (or (prrr-thread-side thread) 'right) (prrr-thread-line thread)))
```

In the Commentary, replace "Line mapping across Ranges is milestone 5 and is not here yet." with:

```
;; Where the Review Buffer shows each Thread is decided here too
;; (`prrr-state-thread-layout').  Line mapping across Ranges is
;; milestone 5 and is not here yet.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `make test TESTS=test/prrr-state-test.el`
Expected: all pass.

- [ ] **Step 6: Run all gates and commit**

```bash
make compile lint test
git add prrr-state.el test/prrr-state-test.el test/prrr-test-helper.el
git commit -m "feat(state): where the Review Buffer shows each Thread"
```

---

### Task 2: Review data in the database

**Files:**
- Modify: `prrr-db.el` (new part `;;;; Review data` before `(provide 'prrr-db)`)
- Modify: `test/prrr-db-test.el`

**Interfaces:**
- Consumes: `prrr-github-decode-review-data`'s plist (milestone 1): `:threads :comments :pending-review :viewed :head-oid`.
- Produces:
  - `(prrr-db-replace-review-data PR-ID DATA)` → nil. Replaces the `thread`, `review-comment`, `pending-review` and `viewed` rows of PR-ID in one transaction.
  - `(prrr-db-review-data PR-ID)` → plist `(:threads LIST :comments LIST :pending-review STRUCT-OR-NIL :viewed LIST)`, comments oldest first.

- [ ] **Step 1: Write the failing tests**

Append to `test/prrr-db-test.el`. Its header already has `(require 'prrr-test-helper)`; add `(require 'prrr-github)` next to it for the decoder.

```elisp
;;;; Review data

(defconst prrr-db-test--pr "PR_kwDOexample0000001"
  "The PR of the review-data fixture.")

(defun prrr-db-test--review-data ()
  "The review-data fixture, decoded."
  (prrr-github-decode-review-data (prrr-test-fixture "review-data") prrr-db-test--pr
                                  "2026-10-10T12:00:00Z"))

(ert-deftest prrr-db-test-review-data-round-trip ()
  (prrr-db-with-test-db
    (prrr-db-replace-review-data prrr-db-test--pr (prrr-db-test--review-data))
    (let ((data (prrr-db-review-data prrr-db-test--pr)))
      (should (equal '("PRRT_kwDOexample0000001" "PRRT_kwDOexample0000002"
                       "PRRT_kwDOexample0000003" "PRRT_kwDOexample0000004"
                       "PRRT_kwDOexample0000005")
                     (mapcar #'prrr-thread-thread-id (plist-get data :threads))))
      (should (equal '("PRRC_kwDOexample0000004" "PRRC_kwDOexample0000001"
                       "PRRC_kwDOexample0000002" "PRRC_kwDOexample0000003"
                       "PRRC_kwDOexample0000005" "PRRC_kwDOexample0000006")
                     (mapcar #'prrr-comment-comment-id (plist-get data :comments))))
      (should (equal "PRR_kwDOexamplePending1"
                     (prrr-pending-review-review-id (plist-get data :pending-review))))
      (should (= 3 (length (plist-get data :viewed)))))))

(ert-deftest prrr-db-test-review-data-replaces-old-rows ()
  "A Thread deleted on GitHub disappears; the Pending Review too once submitted."
  (prrr-db-with-test-db
    (prrr-db-replace-review-data prrr-db-test--pr (prrr-db-test--review-data))
    (let ((data (prrr-db-test--review-data)))
      (prrr-db-replace-review-data
       prrr-db-test--pr
       (list :threads (cdr (plist-get data :threads))
             :comments (seq-remove (lambda (comment)
                                     (equal (prrr-comment-thread-id comment)
                                            "PRRT_kwDOexample0000001"))
                                   (plist-get data :comments))
             :pending-review nil
             :viewed nil)))
    (let ((data (prrr-db-review-data prrr-db-test--pr)))
      (should (= 4 (length (plist-get data :threads))))
      (should (= 4 (length (plist-get data :comments))))
      (should-not (plist-get data :pending-review))
      (should-not (plist-get data :viewed)))))

(ert-deftest prrr-db-test-review-data-other-pr-untouched ()
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-test-thread :id "OTHER"))
    (prrr-db-replace-review-data prrr-db-test--pr (prrr-db-test--review-data))
    (prrr-db-replace-review-data prrr-db-test--pr nil)
    (should (equal '("OTHER") (mapcar #'prrr-thread-thread-id (prrr-db-select 'thread))))))

(ert-deftest prrr-db-test-review-data-never-fetched ()
  (prrr-db-with-test-db
    (should (equal '(:threads nil :comments nil :pending-review nil :viewed nil)
                   (prrr-db-review-data "PR_never")))))
```

The second test needs `seq`; `prrr-db-test.el` gets `(require 'seq)` if it lacks it.

- [ ] **Step 2: Run them to verify they fail**

Run: `make test TESTS=test/prrr-db-test.el`
Expected: FAIL, `prrr-db-replace-review-data` is void.

- [ ] **Step 3: Implement**

Insert before `(provide 'prrr-db)`:

```elisp
;;;; Review data

(defun prrr-db-replace-review-data (pr-id data)
  "Make DATA the only stored review data of PR-ID.
DATA is the plist `prrr-github-decode-review-data' returns, or nil: its
:threads, :comments, :pending-review and :viewed replace every
`thread', `review-comment', `pending-review' and `viewed' row of PR-ID.
One transaction.  The Outbox of milestone 4 keeps unsent rows here."
  (let ((db (prrr-db)))
    (emacsql-with-transaction db
      (dolist (table '(thread review-comment pending-review viewed))
        (prrr-db-delete table :pr-id pr-id))
      (dolist (rows (list (plist-get data :threads)
                          (plist-get data :comments)
                          (delq nil (list (plist-get data :pending-review)))
                          (plist-get data :viewed)))
        (when rows
          (emacsql db (vector :insert-or-replace :into (prrr-db--table-of (car rows))
                              :values '$v1)
                   (mapcar #'prrr-db--struct-to-row rows)))))
    nil))

(defun prrr-db-review-data (pr-id)
  "Return the stored review data of PR-ID.
A plist like the DATA of `prrr-db-replace-review-data': :threads in the
order they were stored, :comments oldest first, :pending-review or nil,
and :viewed.  A PR never fetched has nil for each."
  (list :threads (prrr-db-select 'thread :pr-id pr-id)
        :comments (sort (prrr-db-select 'review-comment :pr-id pr-id)
                        (lambda (a b)
                          (string< (or (prrr-comment-created-at a) "")
                                   (or (prrr-comment-created-at b) ""))))
        :pending-review (prrr-db-get 'pending-review pr-id)
        :viewed (prrr-db-select 'viewed :pr-id pr-id)))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test TESTS=test/prrr-db-test.el`
Expected: all pass.

- [ ] **Step 5: Run all gates and commit**

```bash
make compile lint test
git add prrr-db.el test/prrr-db-test.el
git commit -m "feat(db): store and read a PR's review data"
```

---

### Task 3: The Viewed mutation

**Files:**
- Modify: `prrr-github.el` (new part `;;;; Mutations` before `(provide 'prrr-github)`; the Commentary's "Mutations arrive in milestone 4." becomes "The Viewed mutations are here; the others arrive in milestone 4.")
- Modify: `test/prrr-github-test.el`

**Interfaces:**
- Consumes: `prrr-github--callback`, `prrr-github--errorback`, `prrr-github-error` (milestone 2).
- Produces: `(prrr-github-set-viewed HOST PR-ID PATH VIEWED CALLBACK ERRORBACK)`. CALLBACK takes no argument; ERRORBACK takes a classified failure; exactly one runs.

- [ ] **Step 1: Write the failing tests**

Append to `test/prrr-github-test.el`:

```elisp
;;;; Mutations

(ert-deftest prrr-github-test-set-viewed-sends-mark ()
  (prrr-test-with-ghub-stub '((data (markFileAsViewed (clientMutationId)))) captured
    (let ((done nil))
      (prrr-github-set-viewed "api.github.com" "PR_1" "src/a.el" t
                              (lambda () (setq done t)) (lambda (_) (ert-fail "errorback")))
      (should done)
      (should (eq 'mutation (car (car captured))))
      (should (eq 'markFileAsViewed (car (cadr (car captured)))))
      (should (equal '((input (pullRequestId . "PR_1") (path . "src/a.el")))
                     (cadr captured))))))

(ert-deftest prrr-github-test-set-viewed-sends-unmark ()
  (prrr-test-with-ghub-stub '((data (unmarkFileAsViewed (clientMutationId)))) captured
    (prrr-github-set-viewed "api.github.com" "PR_1" "src/a.el" nil #'ignore #'ignore)
    (should (eq 'unmarkFileAsViewed (car (cadr (car captured)))))))

(ert-deftest prrr-github-test-set-viewed-failure-reaches-errorback ()
  (prrr-test-with-ghub-error-stub '(error http 401) nil
    (let ((failure nil))
      (prrr-github-set-viewed "api.github.com" "PR_1" "src/a.el" t
                              (lambda () (ert-fail "callback"))
                              (lambda (f) (setq failure f)))
      (should (eq 'auth (plist-get failure :kind))))))
```

- [ ] **Step 2: Run them to verify they fail**

Run: `make test TESTS=test/prrr-github-test.el SELECTOR='"set-viewed"'`
Expected: FAIL, `prrr-github-set-viewed` is void.

- [ ] **Step 3: Implement**

Insert before `(provide 'prrr-github)`:

```elisp
;;;; Mutations

(defun prrr-github-set-viewed (host pr-id path viewed callback errorback)
  "Mark PATH of the pull request with node id PR-ID as Viewed on HOST.
With VIEWED nil, unmark it.  CALLBACK receives no argument once GitHub
accepts.  ERRORBACK receives a failure classified by
`prrr-github-error'.  Exactly one of the two is called."
  (let ((callback (prrr-github--callback #'ignore (lambda (_) (funcall callback)) errorback))
        (errorback (prrr-github--errorback errorback)))
    (if viewed
        (forge-mutate host markFileAsViewed ((pullRequestId pr-id) (path path))
          :callback callback :errorback errorback)
      (forge-mutate host unmarkFileAsViewed ((pullRequestId pr-id) (path path))
        :callback callback :errorback errorback))))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test TESTS=test/prrr-github-test.el`
Expected: all pass.

- [ ] **Step 5: Run all gates and commit**

```bash
make compile lint test
git add prrr-github.el test/prrr-github-test.el
git commit -m "feat(github): mark and unmark a file as Viewed"
```

---

### Task 4: Per-PR refetch and one status vocabulary

**Files:**
- Modify: `prrr-sync.el`
- Modify: `prrr-queue.el` (`prrr-queue--status-text`)
- Modify: `test/prrr-sync-test.el`

**Interfaces:**
- Consumes: `prrr-github-fetch-review-data` (milestone 2), `prrr-db-replace-review-data` (Task 2).
- Produces:
  - `prrr-sync--status` keys: a forge repository id for queue pulls, `(review . PR-ID)` for refetches. `prrr-sync--start (KEY BUFFER)` → token; `prrr-sync--current-p (KEY TOKEN)`; `prrr-sync--finish (KEY TOKEN OUTCOME BUFFER)` also stores OUTCOME's `:head-oid`.
  - `(prrr-sync-review-status PR-ID)` → status plist or nil. An `ok` status has `:head-oid`.
  - `(prrr-sync-refetch-due-p PR-ID &optional NOW)` → non-nil unless a refetch runs or a rate limit has not reset.
  - `(prrr-sync-refetch REPO PULLREQ &optional BUFFER)` → non-nil when started.
  - `(prrr-sync-describe STATUS &optional BUSY)` → string or nil.

- [ ] **Step 1: Write the failing tests**

Append to `test/prrr-sync-test.el`:

```elisp
;;;; Refetch

(defconst prrr-sync-test--pr "PR_kwDOexample0000001"
  "The PR of the review-data fixture.")

(defun prrr-sync-test--pullreq ()
  "The fixture's pull request as a forge object, without a database."
  (forge-pullreq :id "forge-1" :number 1 :their-id prrr-sync-test--pr))

(ert-deftest prrr-sync-test-refetch-stores-review-data ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (prrr-test-with-ghub-dispatch `((repository . ,(prrr-test-fixture "review-data")))
        (should (prrr-sync-refetch (prrr-sync-test--repo) (prrr-sync-test--pullreq)))
        (should (= 5 (length (plist-get (prrr-db-review-data prrr-sync-test--pr) :threads))))
        (let ((status (prrr-sync-review-status prrr-sync-test--pr)))
          (should (eq 'ok (plist-get status :state)))
          (should (equal "1111111111111111111111111111111111111111"
                         (plist-get status :head-oid))))))))

(ert-deftest prrr-sync-test-refetch-not-while-running ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (puthash (cons 'review prrr-sync-test--pr)
               (list :state 'pulling :attempted-at (prrr-sync--timestamp))
               prrr-sync--status)
      (prrr-test-with-ghub-dispatch nil
        (should-not (prrr-sync-refetch (prrr-sync-test--repo) (prrr-sync-test--pullreq)))
        (should-not prrr-test-requests)))))

(ert-deftest prrr-sync-test-refetch-waits-for-rate-limit ()
  (prrr-sync-test--with-clean-status
    (puthash (cons 'review prrr-sync-test--pr)
             '(:state rate-limited :attempted-at "2026-10-10T11:00:00Z"
               :reset-at "2026-10-10T12:30:00Z")
             prrr-sync--status)
    (should-not (prrr-sync-refetch-due-p prrr-sync-test--pr prrr-sync-test--now))
    (should (prrr-sync-refetch-due-p prrr-sync-test--pr
                                     (encode-time '(0 31 12 10 10 2026 nil nil t))))))

(ert-deftest prrr-sync-test-refetch-failure-keeps-stored-rows ()
  "Review Focus 5: offline keeps the database copy and says so."
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (prrr-db-insert (prrr-test-thread :id "KEPT"))
      (prrr-test-with-ghub-error-stub '(error http 502) nil
        (prrr-sync-refetch (prrr-sync-test--repo)
                           (forge-pullreq :id "forge-1" :number 1 :their-id "PR_1")))
      (should (eq 'offline (plist-get (prrr-sync-review-status "PR_1") :state)))
      (should (equal '("KEPT") (mapcar #'prrr-thread-thread-id (prrr-db-select 'thread)))))))

(ert-deftest prrr-sync-test-refetch-without-login-is-an-error-status ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (let ((prrr-github-user nil))
        (cl-letf (((symbol-function 'magit-get) #'ignore))
          (prrr-test-with-ghub-dispatch nil
            (prrr-sync-refetch (prrr-sync-test--repo) (prrr-sync-test--pullreq))
            (should-not prrr-test-requests))))
      (should (eq 'error (plist-get (prrr-sync-review-status prrr-sync-test--pr) :state))))))

(ert-deftest prrr-sync-test-refetch-late-answer-ignored ()
  "An answer after the watchdog ended the refetch changes nothing."
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (let ((callback nil))
        (cl-letf (((symbol-function 'ghub-query)
                   (lambda (_query _variables &rest args)
                     (setq callback (plist-get args :callback)))))
          (prrr-sync-refetch (prrr-sync-test--repo) (prrr-sync-test--pullreq)))
        (let ((token (plist-get (prrr-sync-review-status prrr-sync-test--pr) :token)))
          (prrr-sync--finish (cons 'review prrr-sync-test--pr) token
                             '(:kind offline :message "No answer from GitHub" :reset-at nil)
                             nil))
        (funcall callback (prrr-test-fixture "review-data"))
        (should-not (prrr-db-select 'thread))
        (should (eq 'offline (plist-get (prrr-sync-review-status prrr-sync-test--pr) :state)))))))

(ert-deftest prrr-sync-test-refetch-and-pull-keep-separate-status ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (prrr-test-with-ghub-dispatch `((repository . ,(prrr-test-fixture "review-data")))
        (prrr-sync-refetch (prrr-sync-test--repo) (prrr-sync-test--pullreq)))
      (should-not (prrr-sync-status "example-repo-id")))))

;;;; Describe

(ert-deftest prrr-sync-test-describe ()
  (should (equal "pulling…" (prrr-sync-describe '(:state pulling))))
  (should (equal "refreshing…" (prrr-sync-describe '(:state pulling) "refreshing…")))
  (should (equal "offline" (prrr-sync-describe '(:state offline :message "No answer"))))
  (should (equal "GitHub rejected the token (HTTP 401)"
                 (prrr-sync-describe '(:state auth :message "GitHub rejected the token (HTTP 401)"))))
  (should (string-prefix-p "rate limited until "
                           (prrr-sync-describe '(:state rate-limited
                                                 :reset-at "2026-10-10T12:30:00Z"))))
  (should-not (prrr-sync-describe '(:state ok)))
  (should-not (prrr-sync-describe nil)))
```

- [ ] **Step 2: Run them to verify they fail**

Run: `make test TESTS=test/prrr-sync-test.el`
Expected: the new tests FAIL (`prrr-sync-refetch` is void); the existing ones pass.

- [ ] **Step 3: Generalise the job machinery**

In `prrr-sync.el`:

1. Add `(require 'parse-time)` with the other requires.
2. Replace the docstring of `prrr-sync--status` with: `"Sync status of each background job this session.\nKeyed by forge repository id for Review Queue pulls and by\n(review . PR-ID) for per-PR refetches."`
3. Add after `prrr-sync--last-token` (public: the Review Queue uses it too):

```elisp
(defconst prrr-sync-no-login
  "no GitHub login: set github.user or `prrr-github-user'"
  "Failure message when the viewer's login is unknown.")
```

   and use it in `prrr-sync-pull` in place of the literal string.
4. Rename the REPO-ID parameter to KEY in `prrr-sync--current-p` and `prrr-sync--finish`, with docstrings saying "the job KEY" instead of "the pull of REPO-ID". `prrr-sync--finish` stores the outcome's head as well:

```elisp
(defun prrr-sync--finish (key token outcome buffer)
  "End the job KEY identified by TOKEN and refresh BUFFER.
OUTCOME is a `prrr-github-error' plist, or (:kind ok) on success,
optionally with :head-oid.  An answer for a job that already ended, by
its watchdog or because a newer job replaced it, changes nothing."
  (when (prrr-sync--current-p key token)
    (puthash key
             (list :state (plist-get outcome :kind)
                   :message (plist-get outcome :message)
                   :reset-at (plist-get outcome :reset-at)
                   :head-oid (plist-get outcome :head-oid)
                   :attempted-at (plist-get (gethash key prrr-sync--status) :attempted-at)
                   :token token)
             prrr-sync--status)
    (prrr-sync--schedule-refresh buffer)))
```

   `prrr-sync--current-p` reads `(gethash key prrr-sync--status)`.
5. Add before `prrr-sync--fetch-teams`:

```elisp
(defun prrr-sync--start (key buffer)
  "Record a job KEY as running and return its token.
The job ends as `offline' when it has no answer after
`prrr-sync-timeout' seconds; BUFFER is refreshed then."
  (let ((token (cl-incf prrr-sync--last-token)))
    (puthash key (list :state 'pulling :attempted-at (prrr-sync--timestamp) :token token)
             prrr-sync--status)
    (run-at-time prrr-sync-timeout nil #'prrr-sync--finish key token
                 '(:kind offline :message "No answer from GitHub" :reset-at nil)
                 buffer)
    token))
```

6. In `prrr-sync-pull`, replace the `token` binding with `(token (prrr-sync--start id buffer))`, and delete the `puthash` of the `pulling` status and the `run-at-time` that follow. Both are now inside `prrr-sync--start`. The pull's behaviour is unchanged.

Run: `make test TESTS=test/prrr-sync-test.el SELECTOR='"prrr-sync-test-\\(due\\|pull\\)"'`
Expected: the existing pull tests pass.

- [ ] **Step 4: Add the refetch and the shared description**

Append before `;;;; Commands` in `prrr-sync.el`:

```elisp
;;;; Per-PR refetch

(defun prrr-sync-review-status (pr-id)
  "Return the status of the last refetch of the PR with node id PR-ID, or nil.
A plist like `prrr-sync-status'.  An `ok' status also has :head-oid,
the PR's head on GitHub when the refetch answered."
  (gethash (cons 'review pr-id) prrr-sync--status))

(defun prrr-sync-refetch-due-p (pr-id &optional now)
  "Non-nil when a refetch of PR-ID may start at NOW.
Not while one runs (`prrr-sync--running-p') nor before a rate limit
resets.  NOW is a Lisp time, the current time by default."
  (let ((status (prrr-sync-review-status pr-id)))
    (and (not (prrr-sync--running-p status now))
         (let ((reset-at (plist-get status :reset-at)))
           (not (and reset-at (string< (prrr-sync--timestamp now) reset-at)))))))

(defun prrr-sync-refetch (repo pullreq &optional buffer)
  "Refetch the Threads, Pending Review and Viewed flags of PULLREQ in the background.
REPO is PULLREQ's `forge-github-repository'.  Stores the answer with
`prrr-db-replace-review-data', records the outcome in
`prrr-sync-review-status' and refreshes BUFFER, when live, once the
refetch ends either way.  Return non-nil when a refetch started; return
nil and do nothing when `prrr-sync-refetch-due-p' says no.  Never
signals: every failure becomes the status."
  (let ((pr-id (oref pullreq their-id)))
    (when (prrr-sync-refetch-due-p pr-id)
      (let* ((key (cons 'review pr-id))
             (token (prrr-sync--start key buffer))
             (fail (lambda (failure) (prrr-sync--finish key token failure buffer))))
        (prrr-sync--guarded fail
          (let ((me (prrr-github-viewer)))
            (if (null me)
                (funcall fail (list :kind 'error :message prrr-sync-no-login :reset-at nil))
              (prrr-github-fetch-review-data
               (oref repo apihost) (oref repo owner) (oref repo name) (oref pullreq number) me
               (lambda (data)
                 (when (prrr-sync--current-p key token)
                   (prrr-sync--guarded fail
                     (prrr-db-replace-review-data pr-id data)
                     (prrr-sync--finish key token
                                        (list :kind 'ok :head-oid (plist-get data :head-oid))
                                        buffer))))
               fail))))
        t))))

(defun prrr-sync-describe (status &optional busy)
  "Return a few words describing sync STATUS, or nil when all is well.
BUSY describes a job that is running; it defaults to \"pulling…\"."
  (pcase (plist-get status :state)
    ('pulling (or busy "pulling…"))
    ('offline "offline")
    ('rate-limited
     (format "rate limited until %s"
             (format-time-string "%H:%M" (parse-iso8601-time-string
                                          (plist-get status :reset-at)))))
    ((or 'ok 'auth 'not-found 'error) (plist-get status :message))))
```

Update the Commentary's last paragraph to: "Per-PR refetches of review data live here too. The Outbox retry arrives in milestone 4."

- [ ] **Step 5: Use the shared description in the Review Queue**

In `prrr-queue.el`, replace the `pcase` inside `prrr-queue--status-text` so the function reads:

```elisp
(defun prrr-queue--status-text (status me)
  "Return the heading suffix for sync STATUS and viewer ME.
STATUS is a `prrr-sync-status' plist or nil.  The empty string when
there is nothing to say."
  (let ((text (if (null me) prrr-sync-no-login (prrr-sync-describe status))))
    (if text
        (propertize (format " (%s)" text) 'font-lock-face 'magit-dimmed)
      "")))
```

`prrr-sync-no-login` is public because two files use it. `prrr-queue.el` keeps `(require 'parse-time)`, which `prrr-queue--ago` needs.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `make test`
Expected: all pass, including every milestone-2 queue heading test.

- [ ] **Step 7: Run all gates and commit**

```bash
make compile lint test
git add prrr-sync.el prrr-queue.el test/prrr-sync-test.el
git commit -m "feat(sync): background refetch of a PR's review data"
```

---
### Task 5: Fixture repository and the changed files of a diff

**Files:**
- Create: `test/fixtures/make-repo.sh` (executable)
- Modify: `test/prrr-test-helper.el` (`prrr-test-repo-base`, `prrr-test-with-repo`)
- Create: `prrr-diff.el` (header, options, `prrr-diff-file`, parsing, eager budget, merge base)
- Create: `test/prrr-diff-test.el`
- Modify: `Makefile` (`SRC` gains `prrr-diff.el` after `prrr-queue.el`; `TESTS` gains `test/prrr-diff-test.el`)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `test/fixtures/make-repo.sh DIR`: a repository whose `main` has a commit after the PR's base and whose `refs/pullreqs/1` is the PR head (contents below).
  - `(prrr-test-with-repo BODY...)` with `default-directory` in a fresh copy; `prrr-test-repo-base` is `main`'s tip (the PR's `base-rev`).
  - `prrr-eager-files` (30), `prrr-eager-lines` (2000).
  - `prrr-diff-file` struct: `path orig status added deleted binary-p`, constructor `prrr-diff-file-create`.
  - `(prrr-diff-parse-changes OUTPUT)` → list of `prrr-diff-file`.
  - `(prrr-diff--changes BASE HEAD)` → list of `prrr-diff-file` from git.
  - `(prrr-diff--eager-paths FILES VIEWED)` → list of paths.
  - `(prrr-diff--merge-base PULLREQ HEAD)` → oid or nil.

- [ ] **Step 1: Write the fixture script**

Create `test/fixtures/make-repo.sh` and `chmod +x` it:

```sh
#!/bin/sh
# Build the Review Buffer fixture repository in DIR, the only argument.
#
# main:  base -- later on main            (base-rev is main's tip)
#           \
#            head = refs/pullreqs/1
#
# head changes, relative to base:
#   README.md          lines 1 and 3 rewritten, a line added (4 lines)
#   data.bin           binary change
#   docs/notes.md      one line added after line 1
#   src/example.el     line 12 and line 30 rewritten (two hunks)
#   src/moved-from.el  renamed to src/moved-to.el, unchanged
#   src/old.el         deleted (50 lines)
# "later on main" adds CHANGELOG, which the PR's diff must not show.
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
mkdir -p src docs
seq -f 'line %g' 1 40 > src/example.el
printf 'Title\n\nSome text.\n' > README.md
seq -f 'old %g' 1 50 > src/old.el
printf 'Notes\n' > docs/notes.md
seq -f 'moved %g' 1 10 > src/moved-from.el
printf '\000\001\002' > data.bin
git add -A
git commit -q -m base
git checkout -q -b feature
sed -i.bak -e 's/^line 12$/line twelve/' -e 's/^line 30$/line thirty/' src/example.el
rm src/example.el.bak
printf 'Better title\n\nSome text,\nand more.\n' > README.md
git rm -q src/old.el
printf 'Notes\nA second note.\n' > docs/notes.md
git mv src/moved-from.el src/moved-to.el
printf '\000\001\003' > data.bin
git commit -q -a -m head
git update-ref refs/pullreqs/1 HEAD
git checkout -q main
printf 'Changes\n' > CHANGELOG
git add CHANGELOG
git commit -q -m 'later on main'
```

`GIT_CONFIG_GLOBAL` and `GIT_CONFIG_NOSYSTEM` (git 2.32 or later) keep the developer's git configuration (signing, hooks, `diff.context`) out of the fixture. `sed -i.bak` works with both GNU and BSD sed.

Run: `sh test/fixtures/make-repo.sh "$(mktemp -d)/r" && echo ok`
Expected: `ok`.

- [ ] **Step 2: Add the repository helper**

Append to `test/prrr-test-helper.el`:

```elisp
(defvar prrr-test-repo-base nil
  "Inside `prrr-test-with-repo': the oid of main's tip, the PR's base-rev.")

(defmacro prrr-test-with-repo (&rest body)
  "Run BODY in a fresh copy of the Review Buffer fixture repository.
`default-directory' is the repository, built by
test/fixtures/make-repo.sh: refs/pullreqs/1 is the PR's head and
`prrr-test-repo-base' main's tip.  The copy is deleted afterwards."
  (declare (indent 0) (debug t))
  (let ((dir (make-symbol "dir")))
    `(let ((,dir (make-temp-file "prrr-repo" t)))
       (unwind-protect
           (progn
             (unless (zerop (call-process "sh" nil nil nil
                                          (expand-file-name "test/fixtures/make-repo.sh"
                                                            prrr-test-root)
                                          ,dir))
               (error "test/fixtures/make-repo.sh failed"))
             (let* ((default-directory (file-name-as-directory ,dir))
                    ;; The developer's git configuration (diff.context, say)
                    ;; must not change what the tests see.
                    (process-environment (append (list "GIT_CONFIG_GLOBAL=/dev/null"
                                                       "GIT_CONFIG_NOSYSTEM=1")
                                                 process-environment))
                    (prrr-test-repo-base (car (process-lines "git" "rev-parse" "main"))))
               ,@body))
         (delete-directory ,dir t)))))
```

Mention `prrr-test-with-repo` and `prrr-test-repo-base` in the helper's Commentary.

- [ ] **Step 3: Write the failing tests**

Create `test/prrr-diff-test.el` (standard header; Commentary: "The Review Buffer, rendered in batch from the fixture repository of test/fixtures/make-repo.sh and review data stored in a temporary database. No network."):

```elisp
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'prrr-test-helper)
(require 'prrr-diff)

;;;; Changed files

(ert-deftest prrr-diff-test-parse-changes-kinds ()
  "Review Focus 2: every kind of change becomes one file with its status."
  (let ((files (prrr-diff-parse-changes
                (concat ":100644 100644 aaa bbb M\0a.el\0"
                        ":000000 100644 000 ccc A\0new.el\0"
                        ":100644 000000 ddd 000 D\0gone.el\0"
                        ":100644 100644 eee eee R100\0old/name.el\0new/name.el\0"
                        ":100644 100644 fff ggg M\0img.png\0"
                        "3\t1\ta.el\0"
                        "10\t0\tnew.el\0"
                        "0\t5\tgone.el\0"
                        "0\t0\t\0old/name.el\0new/name.el\0"
                        "-\t-\timg.png\0"))))
    (should (equal '("a.el" "new.el" "gone.el" "new/name.el" "img.png")
                   (mapcar #'prrr-diff-file-path files)))
    (should (equal '("modified" "new file" "deleted" "renamed" "modified")
                   (mapcar #'prrr-diff-file-status files)))
    (should (equal '(nil nil nil "old/name.el" nil) (mapcar #'prrr-diff-file-orig files)))
    (should (equal '(3 10 0 0 0) (mapcar #'prrr-diff-file-added files)))
    (should (equal '(1 0 5 0 0) (mapcar #'prrr-diff-file-deleted files)))
    (should (equal '(nil nil nil nil t) (mapcar #'prrr-diff-file-binary-p files)))))

(ert-deftest prrr-diff-test-parse-changes-empty ()
  (should-not (prrr-diff-parse-changes "")))

(ert-deftest prrr-diff-test-parse-changes-tab-in-name ()
  "A path may hold a tab; the count fields never do."
  (let ((file (car (prrr-diff-parse-changes
                    (concat ":100644 100644 aaa bbb M\0odd\tname\0"
                            "1\t0\todd\tname\0")))))
    (should (equal "odd\tname" (prrr-diff-file-path file)))))

(ert-deftest prrr-diff-test-changes-from-git ()
  "The PR's files from its merge base; main's later CHANGELOG is not one."
  (prrr-test-with-repo
    (let* ((head (car (process-lines "git" "rev-parse" "refs/pullreqs/1")))
           (base (car (process-lines "git" "merge-base" "main" head)))
           (files (prrr-diff--changes base head)))
      (should (equal '("README.md" "data.bin" "docs/notes.md" "src/example.el"
                       "src/moved-to.el" "src/old.el")
                     (mapcar #'prrr-diff-file-path files)))
      (should (equal '("modified" "modified" "modified" "modified" "renamed" "deleted")
                     (mapcar #'prrr-diff-file-status files)))
      (should (equal "src/moved-from.el" (prrr-diff-file-orig (nth 4 files))))
      (should (prrr-diff-file-binary-p (nth 1 files))))))

(ert-deftest prrr-diff-test-merge-base ()
  (prrr-test-with-repo
    (let ((head (car (process-lines "git" "rev-parse" "refs/pullreqs/1")))
          (expected (car (process-lines "git" "rev-parse" "main~1"))))
      (should (equal expected
                     (prrr-diff--merge-base
                      (forge-pullreq :id "f" :number 1 :base-rev prrr-test-repo-base) head)))
      (should-not (prrr-diff--merge-base (forge-pullreq :id "f" :number 1 :base-rev nil) head))
      (should-not (prrr-diff--merge-base
                   (forge-pullreq :id "f" :number 1
                                  :base-rev "2222222222222222222222222222222222222222")
                   head)))))

;;;; Eager budget

(defun prrr-diff-test--file (path size)
  "A changed file PATH with SIZE added lines."
  (prrr-diff-file-create :path path :status "modified" :added size :deleted 0))

(ert-deftest prrr-diff-test-eager-stops-at-file-count ()
  (let ((prrr-eager-files 2) (prrr-eager-lines 1000))
    (should (equal '("b" "a")
                   (prrr-diff--eager-paths (list (prrr-diff-test--file "a" 1)
                                                 (prrr-diff-test--file "b" 1)
                                                 (prrr-diff-test--file "c" 1))
                                           nil)))))

(ert-deftest prrr-diff-test-eager-stops-at-first-file-over-lines ()
  "A huge file ends the run, so it never stalls the open."
  (let ((prrr-eager-files 10) (prrr-eager-lines 100))
    (should (equal '("a")
                   (prrr-diff--eager-paths (list (prrr-diff-test--file "a" 60)
                                                 (prrr-diff-test--file "b" 50)
                                                 (prrr-diff-test--file "c" 1))
                                           nil)))
    (should-not (prrr-diff--eager-paths (list (prrr-diff-test--file "huge" 20000)
                                              (prrr-diff-test--file "small" 1))
                                        nil))))

(ert-deftest prrr-diff-test-eager-skips-viewed ()
  (let ((prrr-eager-files 2) (prrr-eager-lines 1000))
    (should (equal '("c" "a")
                   (prrr-diff--eager-paths (list (prrr-diff-test--file "a" 1)
                                                 (prrr-diff-test--file "b" 1)
                                                 (prrr-diff-test--file "c" 1))
                                           '("b"))))))
```

Add `prrr-diff.el` to `SRC` in the `Makefile` after `prrr-queue.el`, and `test/prrr-diff-test.el` to `TESTS`.

- [ ] **Step 4: Run them to verify they fail**

Run: `make test TESTS=test/prrr-diff-test.el`
Expected: FAIL, cannot open `prrr-diff`.

- [ ] **Step 5: Create `prrr-diff.el`**

Standard header with description "The Review Buffer". Commentary:

```
;; The Review Buffer (SPEC section 6): one pull request's diff, from
;; its merge base to its head, with its Threads inline.  It renders
;; from local git and prrr's database, never from the network.
;;
;; Rendering is hybrid lazy.  One `git diff --raw --numstat' lists the
;; changed files, each a collapsed `file' section.  The first files,
;; within `prrr-eager-files' and `prrr-eager-lines', are washed at
;; once; every other file is washed on its first expansion through a
;; deferred section body.
```

Code:

```elisp
;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'magit)
(require 'forge)
(require 'prrr-db)
(require 'prrr-state)

(defcustom prrr-eager-files 30
  "Most files washed when a Review Buffer opens.
The others are washed when first expanded."
  :type 'natnum
  :group 'prrr)

(defcustom prrr-eager-lines 2000
  "Most changed lines washed when a Review Buffer opens.
The first file that would pass this limit, or `prrr-eager-files', and
every file after it, are washed when first expanded."
  :type 'natnum
  :group 'prrr)

;;;; Changed files

(cl-defstruct (prrr-diff-file (:constructor prrr-diff-file-create) (:copier nil))
  "One changed file of a diff.
PATH is the file at head; ORIG the file at base when it was renamed or
copied, else nil.  STATUS is magit's word for the change: \"modified\",
\"new file\", \"deleted\", \"renamed\", \"copied\" or \"typechange\".
ADDED and DELETED count lines; both are 0 for a BINARY-P file."
  path orig status added deleted binary-p)

(defun prrr-diff--status-name (letter)
  "Return magit's word for git's status LETTER."
  (pcase letter
    (?A "new file")
    (?D "deleted")
    (?R "renamed")
    (?C "copied")
    (?T "typechange")
    (_ "modified")))

(defun prrr-diff-parse-changes (output)
  "Parse the OUTPUT of `git diff -z -M --raw --numstat' into `prrr-diff-file's.
Files come in git's order.  Git prints every raw record (status and
names) before the numstat records (line counts), in the same order."
  (let ((tokens (split-string output "\0"))
        (files nil)
        (counts nil))
    (while tokens
      (let ((token (pop tokens)))
        (cond
         ((string-prefix-p ":" token)
          (let* ((letter (aref (car (last (split-string token " "))) 0))
                 (orig (and (memq letter '(?R ?C)) (pop tokens))))
            (push (prrr-diff-file-create :path (pop tokens) :orig orig
                                         :status (prrr-diff--status-name letter))
                  files)))
         ((string-match "\\`\\([0-9]+\\|-\\)\t\\([0-9]+\\|-\\)\t" token)
          (when (= (match-end 0) (length token))
            ;; A rename or copy: its two names follow as tokens.
            (pop tokens)
            (pop tokens))
          (push (cons (match-string 1 token) (match-string 2 token)) counts)))))
    (cl-mapcar (lambda (file count)
                 (let ((binary (equal (car count) "-")))
                   (setf (prrr-diff-file-binary-p file) binary
                         (prrr-diff-file-added file)
                         (if binary 0 (string-to-number (car count)))
                         (prrr-diff-file-deleted file)
                         (if binary 0 (string-to-number (cdr count))))
                   file))
               (nreverse files) (nreverse counts))))

(defun prrr-diff--changes (base head)
  "Return the files changed from BASE to HEAD as `prrr-diff-file's."
  (prrr-diff-parse-changes
   (magit-git-output "diff" "--no-ext-diff" "-z" "-M" "--raw" "--numstat" base head)))

(defun prrr-diff--eager-paths (files viewed)
  "Return the paths among FILES to wash when the buffer opens.
FILES are `prrr-diff-file's in buffer order; the paths in VIEWED are
skipped.  Files are taken from the top until `prrr-eager-files' files
or `prrr-eager-lines' changed lines; the first file that would pass
either limit ends the run."
  (let ((count 0) (lines 0) (paths nil))
    (catch 'done
      (dolist (file files)
        (unless (member (prrr-diff-file-path file) viewed)
          (let ((size (+ (prrr-diff-file-added file) (prrr-diff-file-deleted file))))
            (when (or (>= count prrr-eager-files) (> (+ lines size) prrr-eager-lines))
              (throw 'done nil))
            (cl-incf count)
            (cl-incf lines size)
            (push (prrr-diff-file-path file) paths)))))
    paths))

(defun prrr-diff--merge-base (pullreq head)
  "Return the merge base of PULLREQ's base commit and HEAD, or nil.
nil when forge recorded no base commit or it is not in the repository."
  (when-let ((base-rev (oref pullreq base-rev)))
    (and (magit-rev-verify base-rev)
         (magit-git-string "merge-base" base-rev head))))

(provide 'prrr-diff)
;;; prrr-diff.el ends here
```

`prrr-diff--eager-paths` returns the paths most recent first, which the tests expect. Callers only test membership.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `make test TESTS=test/prrr-diff-test.el`
Expected: all pass.

- [ ] **Step 7: Run all gates and commit**

```bash
make compile lint test
git add test/fixtures/make-repo.sh test/prrr-test-helper.el prrr-diff.el test/prrr-diff-test.el Makefile
git commit -m "feat(diff): changed files of a PR and the eager budget, with a git fixture"
```

---

### Task 6: Rendering a Thread

**Files:**
- Create: `prrr-thread.el`
- Create: `test/prrr-thread-test.el`
- Modify: `Makefile` (`SRC` gains `prrr-thread.el` before `prrr-diff.el`; `TESTS` gains `test/prrr-thread-test.el`)

**Interfaces:**
- Consumes: `prrr-thread`, `prrr-comment` structs.
- Produces:
  - Faces `prrr-thread-heading`, `prrr-thread-resolved`, `prrr-comment-author`, `prrr-comment-date`, `prrr-comment-pending`.
  - `prrr-thread-section-map` (RET → `prrr-thread-visit`).
  - `prrr-thread-indent` (constant string, four spaces).
  - `(prrr-thread-insert THREAD COMMENTS &optional WITH-PATH)`: inserts a section of type `thread` (or `file-comment`), value the Thread id, hidden when resolved, children one `review-comment` section (value the comment id) per comment.
  - `(prrr-thread-visit)` command (exercised in Task 8, where a diff exists).

- [ ] **Step 1: Write the failing tests**

Create `test/prrr-thread-test.el` (standard header; Commentary "Rendering one Thread and its Review Comments into a magit-section buffer."):

```elisp
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'prrr-test-helper)
(require 'prrr-thread)

(cl-defun prrr-thread-test--comment (&key (id "C_1") (thread "T_1") (author "example-bob")
                                          (body "Looks odd.") (state 'submitted) updated-at)
  "A Review Comment of Thread THREAD."
  (prrr-comment-create :comment-id id :thread-id thread :pr-id "PR_1" :author author
                       :body body :created-at "2026-09-02T10:00:00Z" :updated-at updated-at
                       :state state :local-state 'sent))

(defmacro prrr-thread-test--with-render (form &rest body)
  "Evaluate FORM inside a root section of a fresh buffer, then run BODY there.
BODY sees `section', the first child of the root."
  (declare (indent 1))
  `(with-temp-buffer
     (magit-section-mode)
     (let ((inhibit-read-only t))
       (magit-insert-section (root)
         ,form))
     (let ((section (car (oref magit-root-section children))))
       (goto-char (point-min))
       ,@body)))

(defun prrr-thread-test--lines ()
  "The buffer's lines, without properties."
  (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n" t))

(ert-deftest prrr-thread-test-line-thread ()
  (prrr-thread-test--with-render
      (prrr-thread-insert (prrr-test-thread)
                          (list (prrr-thread-test--comment)
                                (prrr-thread-test--comment :id "C_2" :author "example-me"
                                                           :body "Fixed.\nTwice."
                                                           :updated-at "2026-09-03T00:00:00Z")))
    (should (eq 'thread (oref section type)))
    (should (equal "T_1" (oref section value)))
    (should-not (oref section hidden))
    (should (eq 'prrr-thread-section-map (oref section keymap)))
    (should (equal '("    Thread  line 12  2 comments"
                     "    example-bob  2026-09-02"
                     "      Looks odd."
                     "    example-me  2026-09-02  edited"
                     "      Fixed."
                     "      Twice.")
                   (prrr-thread-test--lines)))
    (should (equal '("C_1" "C_2") (mapcar (lambda (child) (oref child value))
                                          (oref section children))))
    (should (equal '(review-comment review-comment)
                   (mapcar (lambda (child) (oref child type)) (oref section children))))))

(ert-deftest prrr-thread-test-resolved-range-thread-is-hidden ()
  (prrr-thread-test--with-render
      (prrr-thread-insert (prrr-test-thread :start-line 1 :line 3 :resolved-p t)
                          (list (prrr-thread-test--comment)))
    (should (oref section hidden))
    (should (looking-at "    Thread  lines 1-3  1 comment  resolved$"))
    (should (eq 'prrr-thread-resolved (get-text-property (+ (point) 4) 'font-lock-face)))))

(ert-deftest prrr-thread-test-left-side-and-pending ()
  (prrr-thread-test--with-render
      (prrr-thread-insert (prrr-test-thread :side 'left :line 7)
                          (list (prrr-thread-test--comment :state 'pending)))
    (should (looking-at "    Thread  line 7, left  1 comment  1 pending$"))
    (forward-line)
    (should (looking-at "    example-bob  2026-09-02  pending$"))))

(ert-deftest prrr-thread-test-file-comment ()
  (prrr-thread-test--with-render
      (prrr-thread-insert (prrr-test-thread :subject-type 'file :line nil)
                          (list (prrr-thread-test--comment)))
    (should (eq 'file-comment (oref section type)))
    (should (looking-at "    File comment  file  1 comment$"))))

(ert-deftest prrr-thread-test-with-path-and-outdated-line ()
  "Away from its file a Thread names the file; an outdated one its original line."
  (prrr-thread-test--with-render
      (prrr-thread-insert (prrr-thread-create :thread-id "T_9" :pr-id "PR_1" :path "src/old.el"
                                              :line nil :original-line 40 :side 'left
                                              :subject-type 'line :outdated-p t)
                          nil t)
    (should (looking-at "    Thread  src/old.el, line 40, left  0 comments$"))))

(ert-deftest prrr-thread-test-ghost-author-and-empty-body ()
  (prrr-thread-test--with-render
      (prrr-thread-insert (prrr-test-thread)
                          (list (prrr-thread-test--comment :author nil :body nil)))
    (forward-line)
    (should (looking-at "    ghost  2026-09-02$"))))
```

Add `prrr-thread.el` to `SRC` before `prrr-diff.el`, and the test file to `TESTS`.

- [ ] **Step 2: Run them to verify they fail**

Run: `make test TESTS=test/prrr-thread-test.el`
Expected: FAIL, cannot open `prrr-thread`.

- [ ] **Step 3: Create `prrr-thread.el`**

Standard header, description "Threads and Review Comments in the Review Buffer". Commentary:

```
;; Renders one Thread, or File Comment, and its Review Comments as
;; magit sections (SPEC section 6).  The Review Buffer decides where a
;; Thread goes; this file decides how it looks.  A Thread section's
;; value is the Thread id and a comment section's value the comment
;; id, so a refetch that changes nothing else keeps their folds.
```

Code:

```elisp
;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'magit-section)
(require 'magit-diff)
(require 'prrr-db)

(defface prrr-thread-heading '((t :inherit magit-diff-hunk-heading :extend t))
  "Heading of an unresolved Thread or File Comment."
  :group 'prrr)

(defface prrr-thread-resolved '((t :inherit (shadow prrr-thread-heading)))
  "Heading of a resolved Thread."
  :group 'prrr)

(defface prrr-comment-author '((t :inherit magit-log-author))
  "Author of a Review Comment."
  :group 'prrr)

(defface prrr-comment-date '((t :inherit magit-log-date))
  "Date of a Review Comment."
  :group 'prrr)

(defface prrr-comment-pending '((t :inherit warning))
  "Marks a Review Comment that belongs to the Pending Review."
  :group 'prrr)

(defvar-keymap prrr-thread-section-map
  :doc "Keys on a Thread, a File Comment and their Review Comments.
RET visits the anchored line: magit's own RET cannot, because a Thread
is not part of the diff."
  "RET" #'prrr-thread-visit)

(defconst prrr-thread-indent "    "
  "Indentation of a Thread's lines, which sets them apart from diff lines.")

(defun prrr-thread--location (thread)
  "Describe where THREAD is anchored, such as \"line 12\" or \"lines 1-3, left\"."
  (let ((line (or (prrr-thread-line thread) (prrr-thread-original-line thread)))
        (start (prrr-thread-start-line thread)))
    (concat (cond ((eq (prrr-thread-subject-type thread) 'file) "file")
                  ((null line) "no line")
                  ((and start (/= start line)) (format "lines %d-%d" start line))
                  (t (format "line %d" line)))
            (and (eq (prrr-thread-side thread) 'left) ", left"))))

(defun prrr-thread--heading (thread comments with-path)
  "Return the heading line of THREAD, which holds COMMENTS.
WITH-PATH non-nil puts the file before the location."
  (let* ((resolved (prrr-thread-resolved-p thread))
         (count (length comments))
         (pending (seq-count (lambda (comment) (eq (prrr-comment-state comment) 'pending))
                             comments)))
    (concat (propertize
             (concat prrr-thread-indent
                     (if (eq (prrr-thread-subject-type thread) 'file) "File comment" "Thread")
                     "  "
                     (and with-path (concat (prrr-thread-path thread) ", "))
                     (prrr-thread--location thread)
                     (format "  %d comment%s" count (if (= count 1) "" "s"))
                     (and resolved "  resolved")
                     (and (> pending 0) (format "  %d pending" pending)))
             'font-lock-face (if resolved 'prrr-thread-resolved 'prrr-thread-heading))
            "\n")))

(defun prrr-thread--date (timestamp)
  "Return the date part of the ISO TIMESTAMP, or \"\"."
  (if (and timestamp (>= (length timestamp) 10)) (substring timestamp 0 10) ""))

(defun prrr-thread--insert-comment (comment)
  "Insert COMMENT as a section of type `review-comment'."
  (magit-insert-section section (review-comment (prrr-comment-comment-id comment))
    (oset section keymap 'prrr-thread-section-map)
    (magit-insert-heading
      prrr-thread-indent
      (propertize (or (prrr-comment-author comment) "ghost") 'font-lock-face 'prrr-comment-author)
      "  "
      (propertize (prrr-thread--date (prrr-comment-created-at comment))
                  'font-lock-face 'prrr-comment-date)
      (and (prrr-comment-updated-at comment) "  edited")
      (and (eq (prrr-comment-state comment) 'pending)
           (propertize "  pending" 'font-lock-face 'prrr-comment-pending))
      "\n")
    (let ((body (string-trim-right (or (prrr-comment-body comment) ""))))
      (unless (string-empty-p body)
        (dolist (line (split-string body "\n"))
          (insert prrr-thread-indent "  " line "\n"))))))

(defun prrr-thread-insert (thread comments &optional with-path)
  "Insert THREAD and its COMMENTS, oldest first, as a section.
The section type is `file-comment' for a File Comment and `thread'
otherwise; its value is the Thread id and its children are one
`review-comment' section per comment.  A resolved Thread starts
hidden.  WITH-PATH non-nil names the file in the heading, for a Thread
shown away from its file."
  (magit-insert-section section ((eval (if (eq (prrr-thread-subject-type thread) 'file)
                                           'file-comment
                                         'thread))
                                 (prrr-thread-thread-id thread)
                                 (prrr-thread-resolved-p thread))
    (oset section keymap 'prrr-thread-section-map)
    (magit-insert-heading (prrr-thread--heading thread comments with-path))
    (mapc #'prrr-thread--insert-comment comments)))

(defun prrr-thread--section-at-point ()
  "Return the `thread' or `file-comment' section around point, or nil."
  (let ((section (magit-current-section)))
    (while (and section (not (memq (oref section type) '(thread file-comment))))
      (setq section (oref section parent)))
    section))

(defun prrr-thread-visit ()
  "Visit the file line the Thread at point is anchored to.
A Thread inside a hunk visits the diff line it follows, through magit's
`magit-diff-visit-file'; any other Thread visits its file."
  (interactive)
  (let* ((section (or (prrr-thread--section-at-point) (user-error "No Thread here")))
         (parent (oref section parent))
         (file parent))
    (while (and file (not (eq (oref file type) 'file)))
      (setq file (oref file parent)))
    (unless file
      (user-error "This Thread's file is not in the diff"))
    (save-excursion
      (if (eq (oref parent type) 'hunk)
          (progn (goto-char (oref section start))
                 (forward-line -1))
        (goto-char (oref file start)))
      (call-interactively #'magit-diff-visit-file))))

(provide 'prrr-thread)
;;; prrr-thread.el ends here
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test TESTS=test/prrr-thread-test.el`
Expected: all pass. If `prrr-thread-test-line-thread` shows an extra blank line, check that `magit-insert-heading` received a string ending in `"\n"` (it adds one only when missing).

- [ ] **Step 5: Run all gates and commit**

```bash
make compile lint test
git add prrr-thread.el test/prrr-thread-test.el Makefile
git commit -m "feat(thread): render a Thread and its Review Comments as sections"
```

---

### Task 7: The Review Buffer: files, lazy hunks, Viewed folding

**Files:**
- Modify: `prrr-diff.el`
- Modify: `test/prrr-diff-test.el`

**Interfaces:**
- Consumes: Tasks 2 and 5; `prrr-thread-indent` (Task 6).
- Produces:
  - Face `prrr-diff-viewed`.
  - Buffer-locals `prrr-diff--pullreq` (the `forge-pullreq`), `prrr-diff--base`, `prrr-diff--head` (oids, nil when unavailable).
  - `prrr-diff-mode` (derived from `magit-diff-mode`), `prrr-diff-mode-map` (parent `magit-diff-mode-map`; filled in Task 11).
  - `prrr-diff-refresh-buffer` (refresh function), `(prrr-diff-setup-buffer PULLREQ)` → buffer, `(prrr-diff--buffer-name PULLREQ)`, `(prrr-diff--head-ref PULLREQ)` → `"refs/pullreqs/N"`.
  - `(prrr-diff--insert-files BASE HEAD DATA)`, `(prrr-diff--wash-file FILE BASE HEAD)` (Task 8 extends both), `(prrr-diff--wash-hunk)`, `(prrr-diff--insert-header PULLREQ BASE HEAD DATA)` (one line here; Task 9 replaces it), `(prrr-diff--insert-note TEXT)`, `(prrr-diff--content-markers)`, `(prrr-diff--viewed-paths VIEWED)`.

- [ ] **Step 1: Write the failing tests**

Append to `test/prrr-diff-test.el`:

```elisp
;;;; Review Buffer

(defconst prrr-diff-test--pr "PR_kwDOexample0000001"
  "The PR of the review-data fixture.")

(defun prrr-diff-test--pullreq ()
  "The fixture repository's pull request, as forge would hold it."
  (forge-pullreq :id "forge-1" :number 1 :title "Example change" :their-id prrr-diff-test--pr
                 :base-rev prrr-test-repo-base :author "example-alice"
                 :created "2026-09-01T00:00:00Z" :body "Why this change."))

(defun prrr-diff-test--store-fixture ()
  "Store the review-data fixture for the fixture PR."
  (prrr-db-replace-review-data
   prrr-diff-test--pr
   (prrr-github-decode-review-data (prrr-test-fixture "review-data") prrr-diff-test--pr
                                   "2026-10-10T12:00:00Z")))

(defmacro prrr-diff-test--with-buffer (setup &rest body)
  "Open the fixture PR's Review Buffer and run BODY in it.
SETUP runs first, inside the fixture repository and a fresh database."
  (declare (indent 1))
  `(prrr-db-with-test-db
     (prrr-test-with-repo
       ,setup
       (let ((buffer (prrr-diff-setup-buffer (prrr-diff-test--pullreq))))
         (unwind-protect
             (with-current-buffer buffer ,@body)
           (kill-buffer buffer))))))

(defun prrr-diff-test--file-section (path)
  "Return the `file' section of PATH in the current Review Buffer."
  (magit-get-section `((file . ,path) (diffbuf))))

(defun prrr-diff-test--files ()
  "Return the paths of the `file' sections, in order."
  (mapcar (lambda (section) (oref section value))
          (seq-filter (lambda (section) (eq (oref section type) 'file))
                      (oref magit-root-section children))))

(defun prrr-diff-test--text (section)
  "Return SECTION's text without properties."
  (buffer-substring-no-properties (oref section start) (oref section end)))

(ert-deftest prrr-diff-test-files-from-merge-base ()
  (prrr-diff-test--with-buffer nil
    (should (eq 'prrr-diff-mode major-mode))
    (should (equal '("README.md" "data.bin" "docs/notes.md" "src/example.el"
                     "src/moved-to.el" "src/old.el")
                   (prrr-diff-test--files)))
    (should (equal (format "%s..%s"
                           (car (process-lines "git" "rev-parse" "main~1"))
                           (car (process-lines "git" "rev-parse" "refs/pullreqs/1")))
                   magit-buffer-diff-range))
    (should (eq 'committed magit-buffer-diff-type))))

(ert-deftest prrr-diff-test-eager-files-washed-others-deferred ()
  (let ((prrr-eager-files 2))
    (prrr-diff-test--with-buffer nil
      (let ((readme (prrr-diff-test--file-section "README.md"))
            (notes (prrr-diff-test--file-section "docs/notes.md")))
        (should-not (oref readme hidden))
        (should (eq 'hunk (oref (car (oref readme children)) type)))
        (should (oref notes hidden))
        (should (oref notes washer))
        (should-not (oref notes children))))))

(ert-deftest prrr-diff-test-lazy-file-washes-on-expand ()
  (let ((prrr-eager-files 0))
    (prrr-diff-test--with-buffer nil
      (let ((notes (prrr-diff-test--file-section "docs/notes.md")))
        (magit-section-show notes)
        (should-not (oref notes washer))
        (should (equal '(hunk) (mapcar (lambda (child) (oref child type))
                                       (oref notes children))))
        (should (string-match-p "^\\+A second note\\.$" (prrr-diff-test--text notes)))))))

(ert-deftest prrr-diff-test-bodies-without-hunks ()
  "Review Focus 2: binary files and pure renames get a one-line body."
  (let ((prrr-eager-files 100))
    (prrr-diff-test--with-buffer nil
      (let ((binary (prrr-diff-test--file-section "data.bin"))
            (moved (prrr-diff-test--file-section "src/moved-to.el"))
            (old (prrr-diff-test--file-section "src/old.el")))
        (should (string-match-p "^    Binary file, not shown$" (prrr-diff-test--text binary)))
        (should (string-match-p "^renamed +src/moved-from\\.el -> src/moved-to\\.el"
                                (prrr-diff-test--text moved)))
        (should (string-match-p "^    No changed lines$" (prrr-diff-test--text moved)))
        (should (string-match-p "^deleted +src/old\\.el" (prrr-diff-test--text old)))
        (should (eq 'hunk (oref (car (oref old children)) type)))
        (dolist (section (list binary moved old))
          (should-not (seq-find (lambda (child) (eq (oref child type) 'file))
                                (oref section children))))))))

(ert-deftest prrr-diff-test-viewed-file-folded-and-marked ()
  (let ((prrr-eager-files 100))
    (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
      (let ((example (prrr-diff-test--file-section "src/example.el"))
            (readme (prrr-diff-test--file-section "README.md")))
        (should (oref example hidden))
        (should (string-match-p "✓ viewed" (prrr-diff-test--text example)))
        ;; DISMISSED means the file changed since it was viewed: not folded.
        (should-not (oref readme hidden))
        (should-not (string-match-p "viewed" (prrr-diff-test--text readme)))))))

(ert-deftest prrr-diff-test-positions-after-lazy-wash ()
  "Review Focus 3: expanding a file keeps every later section's positions right."
  (let ((prrr-eager-files 0))
    (prrr-diff-test--with-buffer nil
      (magit-section-show (prrr-diff-test--file-section "docs/notes.md"))
      (magit-map-sections
       (lambda (section)
         (let ((content (oref section content)))
           (when content
             (should (markerp content))
             (should (<= (oref section start) content (oref section end)))))))
      (let ((old (prrr-diff-test--file-section "src/old.el")))
        (magit-section-show old)
        (magit-section-hide old)
        (goto-char (oref old start))
        (should (looking-at "deleted +src/old\\.el"))
        (should (invisible-p (oref old content)))
        (should-not (invisible-p (oref old start)))))))

(ert-deftest prrr-diff-test-missing-base-note ()
  "Review Focus 1: no base commit renders a note instead of files."
  (prrr-db-with-test-db
    (prrr-test-with-repo
      (let ((buffer (prrr-diff-setup-buffer
                     (forge-pullreq :id "forge-1" :number 1 :title "T" :their-id "PR_1"
                                    :base-rev nil :body nil))))
        (unwind-protect
            (with-current-buffer buffer
              (should-not (prrr-diff-test--files))
              (should (string-match-p "base commit .* not available locally"
                                      (buffer-string))))
          (kill-buffer buffer))))))

(ert-deftest prrr-diff-test-missing-head-note ()
  (prrr-db-with-test-db
    (prrr-test-with-repo
      (call-process "git" nil nil nil "update-ref" "-d" "refs/pullreqs/1")
      (let ((buffer (prrr-diff-setup-buffer (prrr-diff-test--pullreq))))
        (unwind-protect
            (with-current-buffer buffer
              (should (string-match-p "refs/pullreqs/1 is missing" (buffer-string))))
          (kill-buffer buffer))))))

(ert-deftest prrr-diff-test-one-buffer-per-pr ()
  (prrr-diff-test--with-buffer nil
    (should (eq (current-buffer) (prrr-diff-setup-buffer (prrr-diff-test--pullreq))))))

(ert-deftest prrr-diff-test-refresh-keeps-expanded-lazy-file ()
  (let ((prrr-eager-files 0))
    (prrr-diff-test--with-buffer nil
      (magit-section-show (prrr-diff-test--file-section "docs/notes.md"))
      (magit-refresh-buffer)
      (let ((notes (prrr-diff-test--file-section "docs/notes.md")))
        (should-not (oref notes hidden))
        (should (oref notes children))))))
```

Add `(require 'prrr-github)` next to the other requires at the top of `test/prrr-diff-test.el` (for the fixture decoder).

- [ ] **Step 2: Run them to verify they fail**

Run: `make test TESTS=test/prrr-diff-test.el`
Expected: FAIL, `prrr-diff-setup-buffer` is void.

- [ ] **Step 3: Implement the buffer**

In `prrr-diff.el`, add `(require 'prrr-thread)` after `(require 'prrr-state)`. Append to the Commentary:

```
;;
;; A hunk's Threads are child sections of the hunk.  magit assumes
;; hunks have none, so three touch points adapt it: a
;; `magit-section-paint' method scoped to `prrr-diff-mode', and advice
;; on `magit-diff-hunk-line' and `magit-diff--hunk-section'.  CI runs
;; against MELPA magit, so a change there shows up as a failing test.
```

Insert before `(provide 'prrr-diff)`:

```elisp
(defface prrr-diff-viewed '((t :inherit success))
  "The Viewed mark on a file heading."
  :group 'prrr)

;;;; Buffer state

(defvar-local prrr-diff--pullreq nil
  "The `forge-pullreq' this Review Buffer shows.")

(defvar-local prrr-diff--base nil
  "Oid of the merge base the diff starts at, or nil; set by each refresh.")

(defvar-local prrr-diff--head nil
  "Oid of the head the diff ends at, or nil; set by each refresh.")

;;;; Washing

(defun prrr-diff--wash-hunk ()
  "Wash the hunk at point as `magit-diff-wash-hunk' does.
Return non-nil when there was a hunk."
  (when (looking-at "^@\\{2,\\} \\(.+?\\) @\\{2,\\}\\(?: \\(.*\\)\\)?")
    (let* ((heading (match-string 0))
           (ranges (mapcar (lambda (str)
                             (let ((range (mapcar #'string-to-number
                                                  (split-string (substring str 1) ","))))
                               ;; A single line is +1 rather than +1,1.
                               (if (length= range 1) (nconc range (list 1)) range)))
                           (split-string (match-string 1))))
           (about (match-string 2))
           (combined (length= ranges 3)))
      (magit-delete-line)
      (magit-insert-section (hunk (cons about ranges) nil
                                  :combined combined
                                  :from-range (if combined (butlast ranges) (car ranges))
                                  :to-range (car (last ranges))
                                  :about about)
        (magit-insert-heading
          (propertize (concat heading "\n") 'font-lock-face 'magit-diff-hunk-heading))
        (while (not (or (eobp) (looking-at "^[^-+\s\\]")))
          (forward-line))))
    t))

(defun prrr-diff--insert-note (text)
  "Insert TEXT as a dimmed, indented line."
  (insert (propertize (concat prrr-thread-indent text "\n") 'font-lock-face 'magit-dimmed)))

(defun prrr-diff--wash-file (file base head)
  "Insert the hunks of FILE, a `prrr-diff-file', from BASE to HEAD at point.
Runs inside a deferred section body, where `magit-git-wash' cannot be
used, so the diff is inserted, narrowed to, stripped of its header and
washed hunk by hunk.  A diff without hunks becomes a one-line note."
  (let ((beg (point)))
    (apply #'magit-git-insert "diff" "--no-ext-diff" "--no-color" "-p" "-M" base head "--"
           (delq nil (list (prrr-diff-file-orig file) (prrr-diff-file-path file))))
    (save-restriction
      (narrow-to-region beg (point))
      (goto-char beg)
      (if (re-search-forward "^@@" nil t)
          (progn
            (delete-region beg (match-beginning 0))
            (goto-char beg)
            (magit-wash-sequence #'prrr-diff--wash-hunk))
        (delete-region beg (point-max))
        (prrr-diff--insert-note (if (prrr-diff-file-binary-p file)
                                    "Binary file, not shown"
                                  "No changed lines")))
      (goto-char (point-max)))))

(defun prrr-diff--content-markers ()
  "Make every section's content position a marker.
With `magit-section-inhibit-markers' set to `delay', magit turns only
start and end into markers when the root section finishes.  An
integer content goes stale once a deferred body inserts text above it,
and then folding and RET act on the wrong lines."
  (magit-map-sections
   (lambda (section)
     (let ((content (oref section content)))
       (when (integerp content)
         (oset section content (copy-marker content)))))))

;;;; Mode and refresh

(defvar-keymap prrr-diff-mode-map
  :doc "Keys of the Review Buffer (SPEC section 9)."
  :parent magit-diff-mode-map)

(define-derived-mode prrr-diff-mode magit-diff-mode "prrr"
  "Review one pull request: its diff with Threads inline.

\\{prrr-diff-mode-map}"
  :interactive nil
  :group 'prrr
  ;; Folds survive a refresh only through the visibility cache; hunks
  ;; are cheap to rebuild and are left out.
  (setq-local magit-section-cache-visibility '(file thread file-comment))
  ;; magit's hunk fontifier walks every line of a hunk, Threads included.
  (setq-local magit-diff-fontify-hunk nil))

(defun prrr-diff--head-ref (pullreq)
  "Return the ref forge fetches PULLREQ's head to."
  (format "refs/pullreqs/%d" (oref pullreq number)))

(defun prrr-diff--viewed-paths (viewed)
  "Return the paths among VIEWED rows that GitHub marks `viewed'.
A `dismissed' file changed since it was viewed, so it does not count."
  (mapcar #'prrr-viewed-path
          (seq-filter (lambda (row) (eq (prrr-viewed-state row) 'viewed)) viewed)))

(defun prrr-diff--file-heading (file viewed-p)
  "Return the heading of FILE, a `prrr-diff-file', marked when VIEWED-P."
  (concat (magit-format-file 'diff (prrr-diff-file-path file) 'magit-diff-file-heading
                             (prrr-diff-file-status file) (prrr-diff-file-orig file))
          (and viewed-p (propertize "  ✓ viewed" 'font-lock-face 'prrr-diff-viewed))
          "\n"))

(defun prrr-diff--insert-files (base head data)
  "Insert one `file' section per file changed from BASE to HEAD.
DATA is the PR's stored review data (`prrr-db-review-data').  Viewed
files start hidden; the eager budget decides for the others."
  (let* ((files (prrr-diff--changes base head))
         (viewed (prrr-diff--viewed-paths (plist-get data :viewed)))
         (eager (prrr-diff--eager-paths files viewed)))
    (if (null files)
        (prrr-diff--insert-note "No changes")
      (dolist (file files)
        (let ((path (prrr-diff-file-path file)))
          (magit-insert-section (file path (not (member path eager))
                                      :source (prrr-diff-file-orig file)
                                      :binary (prrr-diff-file-binary-p file))
            (magit-insert-heading (prrr-diff--file-heading file (member path viewed)))
            (magit-insert-section-body
              (prrr-diff--wash-file file base head))))))))

(defun prrr-diff--insert-header (pullreq _base _head _data)
  "Insert the header of PULLREQ's Review Buffer."
  (magit-insert-section (prrr-header)
    (magit-insert-heading
      (propertize (format "#%d %s" (oref pullreq number) (oref pullreq title))
                  'font-lock-face 'magit-section-heading))
    (insert "\n")))

(defun prrr-diff-refresh-buffer ()
  "Insert the Review Buffer of `prrr-diff--pullreq' from git and the database.
The refresh function of `prrr-diff-mode', run by `magit-refresh-buffer'."
  (let* ((pullreq prrr-diff--pullreq)
         (ref (prrr-diff--head-ref pullreq))
         (head (magit-rev-verify ref))
         (base (and head (prrr-diff--merge-base pullreq head)))
         (data (prrr-db-review-data (oref pullreq their-id))))
    (setq prrr-diff--base base
          prrr-diff--head head
          magit-buffer-diff-range (and base (concat base ".." head)))
    (setq magit-section-inhibit-markers 'delay)
    (magit-insert-section (diffbuf)
      (prrr-diff--insert-header pullreq base head data)
      (cond ((not head)
             (prrr-diff--insert-note
              (format "%s is missing: run `forge-pull', then g" ref)))
            ((not base)
             (prrr-diff--insert-note
              (format "The base commit %s is not available locally: run `forge-pull', then g"
                      (or (oref pullreq base-rev) "(unknown)"))))
            (t (prrr-diff--insert-files base head data))))
    (prrr-diff--content-markers)))

(defun prrr-diff--buffer-name (pullreq)
  "Return the name of PULLREQ's Review Buffer."
  (format "prrr: %s #%d"
          (file-name-nondirectory (directory-file-name (or (magit-toplevel) default-directory)))
          (oref pullreq number)))

(defun prrr-diff-setup-buffer (pullreq)
  "Show the Review Buffer of PULLREQ, creating it when needed; return it.
There is one buffer per pull request.  `forge-buffer-topic' is set too,
so forge's commands, and `prrr-current-pullreq', act on PULLREQ."
  (magit-setup-buffer #'prrr-diff-mode nil
    :buffer (prrr-diff--buffer-name pullreq)
    (prrr-diff--pullreq pullreq)
    (forge-buffer-topic pullreq)
    (magit-buffer-diff-type 'committed)
    (magit-buffer-diff-range nil)
    (magit-buffer-diff-typearg nil)
    (magit-buffer-diff-args nil)
    (magit-buffer-diff-files nil)
    (magit-buffer-revision nil)))
```

`magit-insert-section` evaluates the `HIDE` argument for every file; `member` on a list of at most `prrr-eager-files` paths keeps that cheap.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test TESTS=test/prrr-diff-test.el`
Expected: all pass. If `prrr-diff-test-positions-after-lazy-wash` fails on `markerp`, `prrr-diff--content-markers` is not running after the root section finished.

- [ ] **Step 5: Run all gates and commit**

```bash
make compile lint test
git add prrr-diff.el test/prrr-diff-test.el
git commit -m "feat(diff): Review Buffer with lazily washed files and Viewed folding"
```

---
### Task 8: Threads inside the diff

**Files:**
- Modify: `prrr-diff.el`
- Modify: `test/prrr-diff-test.el`

**Interfaces:**
- Consumes: `prrr-state-thread-layout`, `prrr-state-thread-anchor` (Task 1), `prrr-thread-insert`, `prrr-thread-visit` (Task 6), Task 7's buffer.
- Produces:
  - Buffer-locals `prrr-diff--threads` (hash table Thread id → `prrr-thread`) and `prrr-diff--file-threads` (hash table path → `prrr-file-threads`), set by each refresh.
  - `(prrr-diff--wash-file FILE THREADS COMMENTS BASE HEAD)` and `(prrr-diff--wash-hunk ANCHORS COMMENTS)` replace Task 7's versions.
  - `(prrr-diff--insert-files BASE HEAD DATA)` now returns the Threads whose file is not in the diff.
  - `(prrr-diff--insert-group TYPE TITLE THREADS COMMENTS)`.
  - Section types `not-in-range`, `outdated` (per file) and `outdated-files` (buffer level), all hidden.
  - The magit coupling: the `magit-section-paint` method, advice `prrr-diff--hunk-line` on `magit-diff-hunk-line`, advice `prrr-diff--hunk-section` on `magit-diff--hunk-section`.

- [ ] **Step 1: Write the failing tests**

Append to `test/prrr-diff-test.el`:

```elisp
;;;; Threads

(defun prrr-diff-test--hunks (path)
  "Return the hunk sections of PATH, expanding the file."
  (let ((file (prrr-diff-test--file-section path)))
    (magit-section-show file)
    (seq-filter (lambda (child) (eq (oref child type) 'hunk)) (oref file children))))

(defun prrr-diff-test--line-before (section)
  "Return the text of the line before SECTION."
  (save-excursion
    (goto-char (oref section start))
    (forward-line -1)
    (buffer-substring-no-properties (line-beginning-position) (line-end-position))))

(defun prrr-diff-test--store-extra-threads ()
  "Store Threads the fixture lacks: not in range, on the left side, on a gone file."
  (dolist (thread (list (prrr-thread-create :thread-id "T_NIR" :pr-id prrr-diff-test--pr
                                            :path "src/example.el" :line 20 :side 'right
                                            :subject-type 'line)
                        (prrr-thread-create :thread-id "T_LEFT" :pr-id prrr-diff-test--pr
                                            :path "src/example.el" :line 30 :side 'left
                                            :subject-type 'line)
                        (prrr-thread-create :thread-id "T_GONE" :pr-id prrr-diff-test--pr
                                            :path "src/gone.el" :line 2 :side 'right
                                            :subject-type 'line)))
    (prrr-db-insert thread)))

(ert-deftest prrr-diff-test-thread-after-its-line ()
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (let* ((hunks (prrr-diff-test--hunks "src/example.el"))
           (first (car (oref (car hunks) children)))
           (pending (car (oref (cadr hunks) children))))
      (should (eq 'thread (oref first type)))
      (should (equal "PRRT_kwDOexample0000001" (oref first value)))
      (should (equal "+line twelve" (prrr-diff-test--line-before first)))
      (should (equal "PRRT_kwDOexample0000005" (oref pending value)))
      (should (equal "+line thirty" (prrr-diff-test--line-before pending))))))

(ert-deftest prrr-diff-test-left-thread-after-removed-line ()
  (prrr-diff-test--with-buffer (progn (prrr-diff-test--store-fixture)
                                      (prrr-diff-test--store-extra-threads))
    (let ((left (seq-find (lambda (child) (equal "T_LEFT" (oref child value)))
                          (oref (cadr (prrr-diff-test--hunks "src/example.el")) children))))
      (should (equal "-line 30" (prrr-diff-test--line-before left))))))

(ert-deftest prrr-diff-test-range-thread-after-last-line-and-folded ()
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (let ((thread (car (oref (car (prrr-diff-test--hunks "README.md")) children))))
      (should (equal "PRRT_kwDOexample0000002" (oref thread value)))
      (should (equal "+Some text," (prrr-diff-test--line-before thread)))
      (should (oref thread hidden)))))

(ert-deftest prrr-diff-test-file-comment-comes-first ()
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (let ((file (prrr-diff-test--file-section "docs/notes.md")))
      (magit-section-show file)
      (should (equal '(file-comment hunk)
                     (mapcar (lambda (child) (oref child type)) (oref file children)))))))

(ert-deftest prrr-diff-test-thread-not-in-range ()
  "Review Focus 1: a Thread whose line is not in the diff is kept, folded away."
  (prrr-diff-test--with-buffer (progn (prrr-diff-test--store-fixture)
                                      (prrr-diff-test--store-extra-threads))
    (let* ((file (prrr-diff-test--file-section "src/example.el"))
           (group (progn (magit-section-show file)
                         (seq-find (lambda (child) (eq (oref child type) 'not-in-range))
                                   (oref file children)))))
      (should group)
      (should (oref group hidden))
      (should (equal '("T_NIR") (mapcar (lambda (child) (oref child value))
                                        (oref group children)))))))

(ert-deftest prrr-diff-test-outdated-thread-grouped ()
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (let* ((file (prrr-diff-test--file-section "src/old.el"))
           (group (progn (magit-section-show file)
                         (seq-find (lambda (child) (eq (oref child type) 'outdated))
                                   (oref file children)))))
      (should (oref group hidden))
      (should (equal '("PRRT_kwDOexample0000003")
                     (mapcar (lambda (child) (oref child value)) (oref group children)))))))

(ert-deftest prrr-diff-test-threads-on-files-not-in-diff ()
  (prrr-diff-test--with-buffer (progn (prrr-diff-test--store-fixture)
                                      (prrr-diff-test--store-extra-threads))
    (let ((group (magit-get-section '((outdated-files) (diffbuf)))))
      (should (oref group hidden))
      (should (equal '("T_GONE") (mapcar (lambda (child) (oref child value))
                                         (oref group children))))
      (should (string-match-p "src/gone\\.el, line 2" (prrr-diff-test--text group))))))

(ert-deftest prrr-diff-test-heading-counts-threads ()
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (should (string-match-p "src/example\\.el  2 threads"
                            (prrr-diff-test--text (prrr-diff-test--file-section "src/example.el"))))))

(ert-deftest prrr-diff-test-ret-after-thread ()
  "Review Focus 4: a diff line after a Thread maps to its own file line."
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (let* ((hunk (car (prrr-diff-test--hunks "src/example.el")))
           (thread (car (oref hunk children))))
      (goto-char (oref thread end))
      (should (looking-at " line 13$"))
      (should (= 13 (magit-diff-hunk-line hunk nil)))
      (goto-char (oref thread start))
      (forward-line 2)
      (should (= 12 (magit-diff-hunk-line hunk nil))))))

(ert-deftest prrr-diff-test-thread-visit ()
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (let ((thread (car (oref (car (prrr-diff-test--hunks "src/example.el")) children))))
      (goto-char (oref thread start))
      (prrr-thread-visit)
      (with-current-buffer (window-buffer)
        (should (string-match-p "example\\.el\\.~" (buffer-name)))
        (should (= 12 (line-number-at-pos)))
        (kill-buffer)))))

(ert-deftest prrr-diff-test-ret-on-file-with-file-comment ()
  "magit's RET on a file heading skips a File Comment to the first hunk."
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (let ((file (prrr-diff-test--file-section "docs/notes.md")))
      (magit-section-show file)
      (goto-char (oref file start))
      (magit-diff-visit-file (magit-file-at-point))
      (with-current-buffer (window-buffer)
        (should (string-match-p "notes\\.md\\.~" (buffer-name)))
        (kill-buffer)))))

(ert-deftest prrr-diff-test-paint-keeps-thread-faces ()
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (let* ((hunk (car (prrr-diff-test--hunks "src/example.el")))
           (thread (car (oref hunk children))))
      (goto-char (oref hunk content))
      (magit-section-update-highlight t)
      (should (eq 'prrr-thread-heading
                  (get-text-property (+ (oref thread start) 4) 'font-lock-face)))
      (should (memq (get-text-property (oref thread end) 'font-lock-face)
                    '(magit-diff-context magit-diff-context-highlight))))))

(ert-deftest prrr-diff-test-refresh-keeps-thread-fold ()
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (magit-section-hide (car (oref (car (prrr-diff-test--hunks "src/example.el")) children)))
    (magit-refresh-buffer)
    (let ((file (prrr-diff-test--file-section "src/example.el")))
      (should-not (oref file hidden))
      (should (oref (car (oref (car (prrr-diff-test--hunks "src/example.el")) children))
                    hidden)))))
```

`src/example.el` is Viewed in the fixture, so it starts hidden; `prrr-diff-test--hunks` expands it.

- [ ] **Step 2: Run them to verify they fail**

Run: `make test TESTS=test/prrr-diff-test.el SELECTOR='"prrr-diff-test-\\(thread\\|left\\|range\\|file-comment\\|outdated\\|heading\\|ret\\|paint\\|refresh-keeps-thread\\)"'`
Expected: FAIL: no Thread sections exist yet.

- [ ] **Step 3: Place Threads while washing**

In `prrr-diff.el`, add after the `prrr-diff--head` defvar:

```elisp
(defvar-local prrr-diff--threads nil
  "Hash table from Thread id to the `prrr-thread' shown; set by each refresh.")

(defvar-local prrr-diff--file-threads nil
  "Hash table from path to its `prrr-file-threads'; set by each refresh.")
```

Replace Task 7's `prrr-diff--wash-hunk` and `prrr-diff--wash-file`, and add two helpers:

```elisp
(defun prrr-diff--insert-anchored (anchors side line comments)
  "Insert the Threads ANCHORS holds for LINE of SIDE, and remove them.
COMMENTS maps Thread ids to their Review Comments."
  (when line
    (let ((key (cons side line)))
      (dolist (thread (gethash key anchors))
        (prrr-thread-insert thread (gethash (prrr-thread-thread-id thread) comments)))
      (remhash key anchors))))

(defun prrr-diff--wash-hunk (anchors comments)
  "Wash the hunk at point as `magit-diff-wash-hunk' does, with its Threads.
After each diff line, the Threads ANCHORS holds for that line are
inserted as children of the hunk (`prrr-diff--insert-anchored').
COMMENTS maps Thread ids to their Review Comments.  Return non-nil when
there was a hunk."
  (when (looking-at "^@\\{2,\\} \\(.+?\\) @\\{2,\\}\\(?: \\(.*\\)\\)?")
    (let* ((heading (match-string 0))
           (ranges (mapcar (lambda (str)
                             (let ((range (mapcar #'string-to-number
                                                  (split-string (substring str 1) ","))))
                               ;; A single line is +1 rather than +1,1.
                               (if (length= range 1) (nconc range (list 1)) range)))
                           (split-string (match-string 1))))
           (about (match-string 2))
           (combined (length= ranges 3))
           (old (car (car ranges)))
           (new (car (car (last ranges)))))
      (magit-delete-line)
      (magit-insert-section (hunk (cons about ranges) nil
                                  :combined combined
                                  :from-range (if combined (butlast ranges) (car ranges))
                                  :to-range (car (last ranges))
                                  :about about)
        (magit-insert-heading
          (propertize (concat heading "\n") 'font-lock-face 'magit-diff-hunk-heading))
        (while (not (or (eobp) (looking-at "^[^-+\s\\]")))
          (let ((old-line nil) (new-line nil))
            (pcase (char-after)
              (?\s (setq old-line old new-line new) (cl-incf old) (cl-incf new))
              (?- (setq old-line old) (cl-incf old))
              (?+ (setq new-line new) (cl-incf new)))
            (forward-line)
            (prrr-diff--insert-anchored anchors 'left old-line comments)
            (prrr-diff--insert-anchored anchors 'right new-line comments)))))
    t))

(defun prrr-diff--insert-group (type title threads comments)
  "Insert THREADS in a hidden section of TYPE headed TITLE, unless there are none.
COMMENTS maps Thread ids to their Review Comments.  A group outside
any file names each Thread's file."
  (when threads
    (magit-insert-section ((eval type) nil t)
      (magit-insert-heading
        (propertize (format "%s%s (%d)\n" prrr-thread-indent title (length threads))
                    'font-lock-face 'magit-section-secondary-heading))
      (dolist (thread threads)
        (prrr-thread-insert thread (gethash (prrr-thread-thread-id thread) comments)
                            (eq type 'outdated-files))))))

(defun prrr-diff--wash-file (file threads comments base head)
  "Insert FILE's diff from BASE to HEAD, with its Threads, at point.
FILE is a `prrr-diff-file'; THREADS its `prrr-file-threads' or nil;
COMMENTS maps Thread ids to their Review Comments.  File Comments come
first, then the hunks with their Threads, then two hidden groups: the
Threads whose line is not in this diff (`not-in-range') and the
outdated ones (`outdated').  Runs inside a deferred section body, where
`magit-git-wash' cannot be used, so the diff is inserted, narrowed to,
stripped of its header and washed hunk by hunk.  A diff without hunks
becomes a one-line note."
  (let ((anchors (make-hash-table :test #'equal))
        (lines (and threads (prrr-file-threads-lines threads))))
    (dolist (thread (and threads (prrr-file-threads-file-comments threads)))
      (prrr-thread-insert thread (gethash (prrr-thread-thread-id thread) comments)))
    (dolist (thread lines)
      (let ((key (prrr-state-thread-anchor thread)))
        (puthash key (append (gethash key anchors) (list thread)) anchors)))
    (let ((beg (point)))
      (apply #'magit-git-insert "diff" "--no-ext-diff" "--no-color" "-p" "-M" base head "--"
             (delq nil (list (prrr-diff-file-orig file) (prrr-diff-file-path file))))
      (save-restriction
        (narrow-to-region beg (point))
        (goto-char beg)
        (if (re-search-forward "^@@" nil t)
            (progn
              (delete-region beg (match-beginning 0))
              (goto-char beg)
              (magit-wash-sequence (lambda () (prrr-diff--wash-hunk anchors comments))))
          (delete-region beg (point-max))
          (prrr-diff--insert-note (if (prrr-diff-file-binary-p file)
                                      "Binary file, not shown"
                                    "No changed lines")))
        (goto-char (point-max))))
    (prrr-diff--insert-group 'not-in-range "Not in this diff"
                             (seq-filter (lambda (thread)
                                           (gethash (prrr-state-thread-anchor thread) anchors))
                                         lines)
                             comments)
    (prrr-diff--insert-group 'outdated "Outdated"
                             (and threads (prrr-file-threads-outdated threads))
                             comments)))
```

A Thread is removed from ANCHORS once inserted, so whatever remains after the last hunk was not in the diff.

Replace `prrr-diff--file-heading` and `prrr-diff--insert-files`, and add the comments table:

```elisp
(defun prrr-diff--comments-table (comments)
  "Return a hash table from Thread id to its COMMENTS, in their order."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (comment (reverse comments))
      (push comment (gethash (prrr-comment-thread-id comment) table)))
    table))

(defun prrr-diff--thread-count (threads)
  "Return how many Threads THREADS, a `prrr-file-threads' or nil, holds."
  (if threads
      (+ (length (prrr-file-threads-file-comments threads))
         (length (prrr-file-threads-lines threads))
         (length (prrr-file-threads-outdated threads)))
    0))

(defun prrr-diff--file-heading (file threads viewed-p)
  "Return the heading of FILE with the count of its THREADS, marked when VIEWED-P."
  (let ((count (prrr-diff--thread-count threads)))
    (concat (magit-format-file 'diff (prrr-diff-file-path file) 'magit-diff-file-heading
                               (prrr-diff-file-status file) (prrr-diff-file-orig file))
            (and (> count 0) (format "  %d thread%s" count (if (= count 1) "" "s")))
            (and viewed-p (propertize "  ✓ viewed" 'font-lock-face 'prrr-diff-viewed))
            "\n")))

(defun prrr-diff--insert-files (base head data)
  "Insert one `file' section per file changed from BASE to HEAD.
DATA is the PR's stored review data (`prrr-db-review-data').  Viewed
files start hidden; the eager budget decides for the others.  Sets
`prrr-diff--threads' and `prrr-diff--file-threads'.  Return the
Threads whose file is not in the diff."
  (let* ((files (prrr-diff--changes base head))
         (layout (prrr-state-thread-layout (plist-get data :threads)
                                           (mapcar #'prrr-diff-file-path files)))
         (comments (prrr-diff--comments-table (plist-get data :comments)))
         (viewed (prrr-diff--viewed-paths (plist-get data :viewed)))
         (eager (prrr-diff--eager-paths files viewed)))
    (setq prrr-diff--file-threads (car layout)
          prrr-diff--threads (make-hash-table :test #'equal))
    (dolist (thread (plist-get data :threads))
      (puthash (prrr-thread-thread-id thread) thread prrr-diff--threads))
    (if (null files)
        (prrr-diff--insert-note "No changes")
      (dolist (file files)
        (let* ((path (prrr-diff-file-path file))
               (threads (gethash path (car layout))))
          (magit-insert-section (file path (not (member path eager))
                                      :source (prrr-diff-file-orig file)
                                      :binary (prrr-diff-file-binary-p file))
            (magit-insert-heading (prrr-diff--file-heading file threads (member path viewed)))
            (magit-insert-section-body
              (prrr-diff--wash-file file threads comments base head))))))
    (cdr layout)))
```

In `prrr-diff-refresh-buffer`, replace the `(t (prrr-diff--insert-files base head data))` clause with:

```elisp
            (t (prrr-diff--insert-group 'outdated-files "Threads on files not in this diff"
                                        (prrr-diff--insert-files base head data)
                                        (prrr-diff--comments-table (plist-get data :comments)))))
```

- [ ] **Step 4: Run the placement tests**

Run: `make test TESTS=test/prrr-diff-test.el`
Expected: the placement tests pass. `prrr-diff-test-ret-after-thread`, `prrr-diff-test-ret-on-file-with-file-comment` and `prrr-diff-test-paint-keeps-thread-faces` still FAIL: magit does not know about children yet.

- [ ] **Step 5: Adapt magit to hunks with children**

Insert after `prrr-diff--content-markers` in `prrr-diff.el` (a new part `;;;; Magit coupling`):

```elisp
;;;; Magit coupling

(cl-defmethod magit-section-paint ((section magit-hunk-section) highlight
                                   &context (major-mode prrr-diff-mode))
  "Paint the diff lines of SECTION, leaving its Thread children alone.
magit's method paints every line after point up to the section's end.
It runs once per run of diff lines, with the end moved to the next
child, starting on the line before the run.  HIGHLIGHT is passed on."
  (let ((children (oref section children)))
    (if (not children)
        (cl-call-next-method)
      (let ((end (oref section end))
            (from (point)))
        (unwind-protect
            (dolist (stop (append (mapcar (lambda (child) (oref child start)) children)
                                  (list end)))
              (save-excursion
                (goto-char from)
                (oset section end stop)
                (cl-call-next-method section highlight))
              (when-let ((child (seq-find (lambda (child) (= (oref child start) stop))
                                          children)))
                ;; magit's method skips the line point is on: the
                ;; child's last line, so painting resumes after it.
                (setq from (save-excursion (goto-char (oref child end))
                                           (forward-line -1)
                                           (point)))))
          (oset section end end))))))

(defun prrr-diff--hunk-line (orig section goto-from)
  "Call ORIG, `magit-diff-hunk-line', counting only SECTION's diff lines.
In a Review Buffer a hunk's Thread children are not diff lines, and a
point inside one counts as the diff line the Thread follows.
GOTO-FROM is as for ORIG."
  (if (not (and (derived-mode-p 'prrr-diff-mode) (oref section children)))
      (funcall orig section goto-from)
    (save-excursion
      (goto-char (line-beginning-position))
      (let ((at (magit-section-at)))
        (unless (eq at section)
          (while (and at (not (eq (oref at parent) section)))
            (setq at (oref at parent)))
          (when at
            (goto-char (oref at start))
            (forward-line -1))))
      (let ((content (oref section content)))
        (when (< (point) content)
          (goto-char content)
          (re-search-forward "^[-+]")
          (goto-char (line-beginning-position)))
        (let ((target (point))
              (offset 0))
          (goto-char content)
          (while (< (point) target)
            (when (and (eq (magit-section-at) section)
                       (not (eq (char-after) (if goto-from ?+ ?-))))
              (cl-incf offset))
            (forward-line))
          (+ (car (if goto-from (oref section from-range) (oref section to-range)))
             offset))))))

(defun prrr-diff--hunk-section (orig)
  "Call ORIG, `magit-diff--hunk-section', skipping a File Comment.
magit takes a file's first child for its first hunk; in a Review
Buffer that child may be a File Comment."
  (let ((section (funcall orig)))
    (if (and section
             (derived-mode-p 'prrr-diff-mode)
             (not (eq (oref section type) 'hunk)))
        (seq-find (lambda (child)
                    (and (eq (oref child type) 'hunk)
                         (not (equal (oref child value) '(chmod)))))
                  (oref (oref section parent) children))
      section)))

(advice-add 'magit-diff-hunk-line :around #'prrr-diff--hunk-line)
(advice-add 'magit-diff--hunk-section :around #'prrr-diff--hunk-section)
```

The advice is installed when `prrr-diff` loads and acts only in `prrr-diff-mode` buffers.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `make test TESTS=test/prrr-diff-test.el`
Expected: all pass. In batch, `magit-diff-visit-file` displays the blob in the selected window. If `prrr-diff-test-thread-visit` finds the Review Buffer in `(window-buffer)`, check that `prrr-thread-visit` calls the command inside `save-excursion` and not `save-window-excursion`.

- [ ] **Step 7: Run all gates and commit**

```bash
make compile lint test
git add prrr-diff.el test/prrr-diff-test.el
git commit -m "feat(diff): Threads inline, with not-in-range and outdated groups"
```

---

### Task 9: The header

**Files:**
- Modify: `prrr-diff.el` (requires `prrr-sync`; replaces `prrr-diff--insert-header`)
- Modify: `test/prrr-diff-test.el`

**Interfaces:**
- Consumes: `prrr-sync-review-status`, `prrr-sync-describe` (Task 4), `forge-insert-post`.
- Produces:
  - `(prrr-diff--posts PULLREQ)` → list of `forge-pullreq-post` (one place for tests to stub).
  - `(prrr-diff--status-line PULLREQ BASE HEAD DATA)` → string.
  - Header sections: `prrr-header` (title heading, status line), with hidden children `description` and `discussion`.

- [ ] **Step 1: Write the failing tests**

In `test/prrr-diff-test.el`, change `prrr-diff-test--with-buffer` so the buffer opens with `prrr-diff--posts` stubbed (tests that need posts bind `prrr-diff-test--posts`):

```elisp
(defvar prrr-diff-test--posts nil
  "The Discussion Comments `prrr-diff--posts' returns in tests.")

(defmacro prrr-diff-test--with-buffer (setup &rest body)
  "Open the fixture PR's Review Buffer and run BODY in it.
SETUP runs first, inside the fixture repository and a fresh database.
`prrr-diff--posts' returns `prrr-diff-test--posts'."
  (declare (indent 1))
  `(prrr-db-with-test-db
     (prrr-test-with-repo
       ,setup
       (cl-letf (((symbol-function 'prrr-diff--posts)
                  (lambda (_pullreq) prrr-diff-test--posts)))
         (let ((buffer (prrr-diff-setup-buffer (prrr-diff-test--pullreq))))
           (unwind-protect
               (with-current-buffer buffer ,@body)
             (kill-buffer buffer)))))))
```

`prrr-diff-test-missing-base-note` and `prrr-diff-test-missing-head-note` open their buffer directly. Wrap their `prrr-diff-setup-buffer` call in the same `cl-letf`.

Append:

```elisp
;;;; Header

(defun prrr-diff-test--status-line ()
  "Return the header's status line."
  (save-excursion
    (goto-char (oref (magit-get-section '((prrr-header) (diffbuf))) content))
    (buffer-substring-no-properties (line-beginning-position) (line-end-position))))

(ert-deftest prrr-diff-test-header-title-and-range ()
  (prrr-diff-test--with-buffer nil
    (goto-char (point-min))
    (should (looking-at "#1 Example change$"))
    (should (string-match-p
             (format "\\`Range: default, %s\\.\\.%s"
                     (substring (car (process-lines "git" "rev-parse" "main~1")) 0 7)
                     (substring (car (process-lines "git" "rev-parse" "refs/pullreqs/1")) 0 7))
             (prrr-diff-test--status-line)))))

(ert-deftest prrr-diff-test-header-pending-review ()
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (should (string-match-p "Pending Review: 1 comment\\b" (prrr-diff-test--status-line)))))

(ert-deftest prrr-diff-test-header-shows-refetch-status ()
  "Review Focus 5: the header says why the data may be old."
  (let ((prrr-sync--status (make-hash-table :test #'equal)))
    (puthash (cons 'review prrr-diff-test--pr)
             (list :state 'pulling :attempted-at (prrr-sync--timestamp)) prrr-sync--status)
    (prrr-diff-test--with-buffer nil
      (should (string-match-p "refreshing…" (prrr-diff-test--status-line)))
      (puthash (cons 'review prrr-diff-test--pr) '(:state offline) prrr-sync--status)
      (magit-refresh-buffer)
      (should (string-match-p "offline" (prrr-diff-test--status-line))))))

(ert-deftest prrr-diff-test-header-github-head-differs ()
  "Review Focus 1: GitHub's head is ahead of the local ref."
  (let ((prrr-sync--status (make-hash-table :test #'equal)))
    (puthash (cons 'review prrr-diff-test--pr)
             '(:state ok :head-oid "2222222222222222222222222222222222222222")
             prrr-sync--status)
    (prrr-diff-test--with-buffer nil
      (should (string-match-p "GitHub's head is 2222222: run forge-pull, then g"
                              (prrr-diff-test--status-line))))))

(ert-deftest prrr-diff-test-header-description-and-discussion ()
  (let ((prrr-diff-test--posts
         (list (forge-pullreq-post :id "post-1" :author "example-bob"
                                   :created "2026-09-03T00:00:00Z" :body "Nice."))))
    (prrr-diff-test--with-buffer nil
      (let ((description (magit-get-section '((description) (prrr-header) (diffbuf))))
            (discussion (magit-get-section '((discussion) (prrr-header) (diffbuf)))))
        (should (oref description hidden))
        (should (string-match-p "Why this change\\." (prrr-diff-test--text description)))
        (should (oref discussion hidden))
        (should (string-match-p "\\`Discussion (1)" (prrr-diff-test--text discussion)))
        (should (string-match-p "Nice\\." (prrr-diff-test--text discussion)))
        (should-not (oref discussion keymap))))))

(ert-deftest prrr-diff-test-header-empty-description ()
  (prrr-db-with-test-db
    (prrr-test-with-repo
      (cl-letf (((symbol-function 'prrr-diff--posts) #'ignore))
        (let ((buffer (prrr-diff-setup-buffer
                       (forge-pullreq :id "forge-1" :number 1 :title "T" :their-id "PR_1"
                                      :base-rev prrr-test-repo-base :author "example-alice"
                                      :created "2026-09-01T00:00:00Z" :body ""))))
          (unwind-protect
              (with-current-buffer buffer
                (should (string-match-p
                         "No description"
                         (prrr-diff-test--text
                          (magit-get-section '((description) (prrr-header) (diffbuf)))))))
            (kill-buffer buffer)))))))
```

- [ ] **Step 2: Run them to verify they fail**

Run: `make test TESTS=test/prrr-diff-test.el SELECTOR='"prrr-diff-test-header"'`
Expected: FAIL, there is no status line.

- [ ] **Step 3: Implement**

In `prrr-diff.el`, add `(require 'prrr-sync)` after `(require 'prrr-thread)`. Replace `prrr-diff--insert-header` with:

```elisp
(defun prrr-diff--posts (pullreq)
  "Return PULLREQ's Discussion Comments, oldest first."
  (oref pullreq posts))

(defun prrr-diff--short (oid)
  "Return the first seven characters of OID."
  (substring oid 0 (min 7 (length oid))))

(defun prrr-diff--status-line (pullreq base head data)
  "Return the header's status line for PULLREQ.
BASE and HEAD are the diffed oids, either may be nil; DATA is the
stored review data.  Names the Range, the Pending Review's comments,
what the last refetch said, and whether GitHub's head differs from the
local one."
  (let* ((status (prrr-sync-review-status (oref pullreq their-id)))
         (github-head (plist-get status :head-oid))
         (pending (seq-count (lambda (comment) (eq (prrr-comment-state comment) 'pending))
                             (plist-get data :comments))))
    (string-join
     (delq nil
           (list (if base
                     (format "Range: default, %s..%s" (prrr-diff--short base)
                             (prrr-diff--short head))
                   "Range: unavailable")
                 (and (plist-get data :pending-review)
                      (format "Pending Review: %d comment%s" pending (if (= pending 1) "" "s")))
                 (prrr-sync-describe status "refreshing…")
                 (and github-head head (not (equal github-head head))
                      (format "GitHub's head is %s: run forge-pull, then g"
                              (prrr-diff--short github-head)))))
     "  ·  ")))

(defun prrr-diff--insert-header (pullreq base head data)
  "Insert the header of PULLREQ's Review Buffer.
The title, a status line (`prrr-diff--status-line' of BASE, HEAD and
DATA), and hidden `description' and `discussion' sections."
  (magit-insert-section (prrr-header)
    (magit-insert-heading
      (propertize (format "#%d %s" (oref pullreq number) (oref pullreq title))
                  'font-lock-face 'magit-section-heading))
    (insert (propertize (prrr-diff--status-line pullreq base head data)
                        'font-lock-face 'magit-dimmed)
            "\n")
    (magit-insert-section (description nil t)
      (magit-insert-heading "Description")
      (if (string-empty-p (string-trim (or (oref pullreq body) "")))
          (prrr-diff--insert-note "No description")
        (forge-insert-post pullreq nil)))
    (let ((posts (prrr-diff--posts pullreq)))
      (magit-insert-section section (discussion nil t)
        ;; Without this, forge's `forge-discussion-section-map' applies.
        (oset section keymap nil)
        (magit-insert-heading (format "Discussion (%d)" (length posts)))
        (dolist (post posts)
          (forge-insert-post post pullreq))))
    (insert "\n")))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test TESTS=test/prrr-diff-test.el`
Expected: all pass.

- [ ] **Step 5: Run all gates and commit**

```bash
make compile lint test
git add prrr-diff.el test/prrr-diff-test.el
git commit -m "feat(diff): header with status line, description and discussion"
```

---

### Task 10: Opening a Review Buffer

**Files:**
- Modify: `prrr-diff.el` (`prrr-diff-open`, `prrr-refetch`)
- Modify: `prrr.el` (`prrr-review`, autoloads)
- Modify: `prrr-queue.el` (`RET` on a row)
- Modify: `prrr-transient.el` (`RET` in `prrr-queue-menu`)
- Modify: `test/prrr-diff-test.el`, `test/prrr-queue-test.el`, `test/prrr-test.el`

**Interfaces:**
- Consumes: `prrr-diff-setup-buffer` (Task 7), `prrr-sync-refetch` (Task 4).
- Produces:
  - `(prrr-diff-open PULLREQ)` → buffer, or `user-error` when the head ref is missing.
  - Command `prrr-review` (`prrr.el`, autoloaded): PR at point, else read with forge's reader; with a prefix argument always read.
  - Command `prrr-refetch` (`prrr-diff.el`, autoloaded from `prrr.el`).
  - `(prrr-diff--require-pullreq)` → the buffer's `forge-pullreq` or `user-error` outside a Review Buffer.

- [ ] **Step 1: Write the failing tests**

Append to `test/prrr-diff-test.el`:

```elisp
;;;; Opening

(defmacro prrr-diff-test--with-open-stubs (&rest body)
  "Run BODY with the network and forge's database stubbed for opening.
`prrr-sync-refetch' records its calls in `refetches'; posts are empty."
  (declare (indent 0))
  `(let ((refetches nil))
     (cl-letf (((symbol-function 'prrr-sync-refetch)
                (lambda (repo pullreq buffer) (push (list repo pullreq buffer) refetches) t))
               ((symbol-function 'forge-get-repository) (lambda (&rest _) 'example-repo))
               ((symbol-function 'prrr-diff--posts) #'ignore))
       ,@body)))

(ert-deftest prrr-diff-test-open-shows-buffer-and-refetches ()
  (prrr-db-with-test-db
    (prrr-test-with-repo
      (prrr-diff-test--with-open-stubs
        (let* ((pullreq (prrr-diff-test--pullreq))
               (buffer (prrr-diff-open pullreq)))
          (unwind-protect
              (progn
                (should (eq 'prrr-diff-mode (buffer-local-value 'major-mode buffer)))
                (should (equal (list (list 'example-repo pullreq buffer)) refetches))
                ;; Review Focus 5: a redraw never refetches.
                (with-current-buffer buffer (magit-refresh-buffer))
                (should (= 1 (length refetches)))
                (with-current-buffer buffer
                  ;; Away from the "#1" in the title, which forge would parse.
                  (goto-char (point-max))
                  (should (eq pullreq (prrr-current-pullreq)))))
            (kill-buffer buffer)))))))

(ert-deftest prrr-diff-test-review-missing-ref-offers-pull ()
  "Review Focus 1: no Review Buffer without the PR's head."
  (prrr-db-with-test-db
    (prrr-test-with-repo
      (call-process "git" nil nil nil "update-ref" "-d" "refs/pullreqs/1")
      (prrr-diff-test--with-open-stubs
        (let ((pulled nil))
          (cl-letf (((symbol-function 'forge-pull) (lambda (&rest _) (interactive) (setq pulled t))))
            (cl-letf (((symbol-function 'y-or-n-p) #'ignore))
              (should-error (prrr-diff-open (prrr-diff-test--pullreq)) :type 'user-error)
              (should-not pulled))
            (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
              (should-error (prrr-diff-open (prrr-diff-test--pullreq)) :type 'user-error)
              (should pulled))
            (should-not refetches)
            (should-not (get-buffer (prrr-diff--buffer-name (prrr-diff-test--pullreq))))))))))

(ert-deftest prrr-diff-test-refetch-command ()
  (prrr-db-with-test-db
    (prrr-test-with-repo
      (prrr-diff-test--with-open-stubs
        (let ((buffer (prrr-diff-open (prrr-diff-test--pullreq))))
          (unwind-protect
              (with-current-buffer buffer
                (setq refetches nil)
                (prrr-refetch)
                (should (= 1 (length refetches))))
            (kill-buffer buffer)))))))

(ert-deftest prrr-diff-test-refetch-outside-review-buffer ()
  (with-temp-buffer
    (should-error (prrr-refetch) :type 'user-error)))
```

In `test/prrr-queue-test.el`, update `prrr-queue-test-row-keeps-forge-keys` and `prrr-queue-test-menu-mirrors-row-keys`, whose `RET` now expects `prrr-review`:

```elisp
  (should (eq 'prrr-review (keymap-lookup prrr-queue-row-map "RET"))))
```

and, in the menu test, the expected command for `"RET"` becomes `prrr-review`.

Append to `test/prrr-test.el`:

```elisp
(ert-deftest prrr-test-review-reads-pullreq-without-one-at-point ()
  (let ((pullreq (forge-pullreq :id "forge-9" :number 9))
        (opened nil))
    (cl-letf (((symbol-function 'forge-current-pullreq) #'ignore)
              ((symbol-function 'forge-read-pullreq) (lambda (&rest _) "forge-9"))
              ((symbol-function 'forge-get-pullreq) (lambda (id) (and (equal id "forge-9") pullreq)))
              ((symbol-function 'prrr-diff-open) (lambda (pr) (setq opened pr))))
      (call-interactively #'prrr-review))
    (should (eq pullreq opened))))

(ert-deftest prrr-test-review-uses-pullreq-at-point ()
  (let ((pullreq (forge-pullreq :id "forge-3" :number 3))
        (opened nil))
    (cl-letf (((symbol-function 'forge-current-pullreq) (lambda (&rest _) pullreq))
              ((symbol-function 'forge-read-pullreq) (lambda (&rest _) (ert-fail "prompted")))
              ((symbol-function 'prrr-diff-open) (lambda (pr) (setq opened pr))))
      (call-interactively #'prrr-review))
    (should (eq pullreq opened))))
```

`prrr-test.el` must `(require 'prrr-diff)` after its other requires, so the stub of `prrr-diff-open` is not undone by the `require` inside `prrr-review`.

- [ ] **Step 2: Run them to verify they fail**

Run: `make test`
Expected: the new tests FAIL (`prrr-diff-open`, `prrr-review` void) and the two updated queue tests FAIL (`RET` is still `prrr-open-topic`).

- [ ] **Step 3: Implement opening in `prrr-diff.el`**

Append a part `;;;; Opening` before `(provide 'prrr-diff)`:

```elisp
;;;; Opening

(defun prrr-diff-open (pullreq)
  "Show the Review Buffer of PULLREQ and refetch its review data in the background.
The buffer renders at once from the database and refreshes when the
refetch ends.  When forge has not fetched the PR's head ref, offer to
run `forge-pull' and signal a `user-error' instead of opening.  Return
the buffer."
  (let ((ref (prrr-diff--head-ref pullreq)))
    (unless (magit-rev-verify ref)
      (when (y-or-n-p (format "%s is missing; run `forge-pull' now? " ref))
        (call-interactively #'forge-pull))
      (user-error (concat "%s is missing: open the pull request again once forge has fetched it"
                          " (if it stays missing, run `forge-add-pullreq-refspec')")
                  ref)))
  (let ((buffer (prrr-diff-setup-buffer pullreq)))
    (prrr-sync-refetch (forge-get-repository pullreq) pullreq buffer)
    buffer))

(defun prrr-diff--require-pullreq ()
  "Return the current Review Buffer's pull request.
Signal a `user-error' outside a Review Buffer."
  (or (and (derived-mode-p 'prrr-diff-mode) prrr-diff--pullreq)
      (user-error "Not in a Review Buffer")))

;;;###autoload
(defun prrr-refetch ()
  "Refetch this pull request's Threads, Pending Review and Viewed flags now.
The buffer shows \"refreshing…\" until the answer arrives, then redraws.
`g' redraws from the database without fetching."
  (interactive)
  (let ((pullreq (prrr-diff--require-pullreq)))
    (if (prrr-sync-refetch (forge-get-repository pullreq) pullreq (current-buffer))
        (magit-refresh-buffer)
      (message "Not refetching: %s"
               (or (prrr-sync-describe (prrr-sync-review-status (oref pullreq their-id))
                                       "a refetch is running")
                   "try again shortly")))))
```

- [ ] **Step 4: Add `prrr-review` to `prrr.el`**

Add to the explicit autoloads:

```elisp
(autoload 'prrr-refetch "prrr-diff" "Refetch this pull request's review data now." t)
```

Add declarations next to the existing ones:

```elisp
(declare-function forge-read-pullreq "forge-pullreq" (prompt))
(declare-function forge-get-pullreq "forge-core" (&rest args))
(declare-function prrr-diff-open "prrr-diff" (pullreq))
```

Add the command after `prrr-checkout`:

```elisp
;;;###autoload
(defun prrr-review (pullreq)
  "Review PULLREQ in its Review Buffer.
Interactively, the pull request at point, else one read with forge's
reader; with a prefix argument, always read one."
  (interactive
   (progn
     (require 'forge)
     (list (or (and (not current-prefix-arg) (forge-current-pullreq))
               (forge-get-pullreq (forge-read-pullreq "Review pull request: "))))))
  (require 'prrr-diff)
  (prrr-diff-open pullreq))
```

In the Commentary, mention `prrr-review` as the way into the Review Buffer.

- [ ] **Step 5: `RET` on a queue row reviews**

In `prrr-queue.el`, `prrr-queue-section-map` binds `"RET" #'prrr-review`, and its `:doc` drops "RET opens forge's topic buffer until the Review Buffer arrives." In `prrr-transient.el`, `prrr-queue-menu`'s first suffix becomes `("RET" "review" prrr-review)`.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `make test`
Expected: all pass, including `prrr-test-require-prrr-does-not-load-forge`.

- [ ] **Step 7: Run all gates and commit**

```bash
make compile lint test
git add prrr.el prrr-diff.el prrr-queue.el prrr-transient.el test/prrr-diff-test.el test/prrr-queue-test.el test/prrr-test.el
git commit -m "feat: prrr-review opens the Review Buffer; RET on a queue row reviews"
```

---
### Task 11: Commands, keys and the `prrr-menu` transient

**Files:**
- Modify: `prrr-sync.el` (`prrr-sync-set-viewed`)
- Modify: `prrr-diff.el` (commands, `prrr-diff-mode-map`)
- Modify: `prrr-transient.el` (`prrr-menu`)
- Modify: `prrr.el` (autoloads)
- Modify: `test/prrr-sync-test.el`, `test/prrr-diff-test.el`

**Interfaces:**
- Consumes: `prrr-github-set-viewed` (Task 3), `prrr-diff--threads`, `prrr-diff--file-threads` (Task 8), `prrr-diff--require-pullreq` (Task 10).
- Produces:
  - `(prrr-sync-set-viewed REPO PR-ID PATH VIEWED &optional BUFFER)`.
  - Commands `prrr-next-file`, `prrr-previous-file`, `prrr-jump-to-file`, `prrr-next-thread`, `prrr-previous-thread`, `prrr-next-unresolved`, `prrr-previous-unresolved`, `prrr-toggle-viewed`, `prrr-collapse-all`, `prrr-expand-all`.
  - `prrr-diff-mode-map` per SPEC section 9 for this milestone's keys.
  - Transient `prrr-menu`.

- [ ] **Step 1: Write the failing sync tests**

Append to `test/prrr-sync-test.el`:

```elisp
;;;; Viewed

(ert-deftest prrr-sync-test-set-viewed-writes-then-sends ()
  (prrr-db-with-test-db
    (prrr-test-with-ghub-stub '((data (markFileAsViewed (clientMutationId)))) captured
      (prrr-sync-set-viewed (prrr-sync-test--repo) "PR_1" "a.el" t)
      (should (eq 'markFileAsViewed (car (cadr (car captured))))))
    (should (eq 'viewed (prrr-viewed-state (prrr-db-get 'viewed "PR_1" "a.el"))))))

(ert-deftest prrr-sync-test-set-viewed-failure-restores-row ()
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-viewed-create :pr-id "PR_1" :path "a.el" :state 'viewed))
    (prrr-test-with-ghub-error-stub '(error http 502) nil
      (prrr-sync-set-viewed (prrr-sync-test--repo) "PR_1" "a.el" nil))
    (should (eq 'viewed (prrr-viewed-state (prrr-db-get 'viewed "PR_1" "a.el"))))))

(ert-deftest prrr-sync-test-set-viewed-failure-removes-new-row ()
  (prrr-db-with-test-db
    (prrr-test-with-ghub-error-stub '(error http 502) nil
      (prrr-sync-set-viewed (prrr-sync-test--repo) "PR_1" "a.el" t))
    (should-not (prrr-db-get 'viewed "PR_1" "a.el"))))
```

- [ ] **Step 2: Implement `prrr-sync-set-viewed`**

Append to the `;;;; Per-PR refetch` part of `prrr-sync.el`:

```elisp
(defun prrr-sync-set-viewed (repo pr-id path viewed &optional buffer)
  "Mark PATH of the PR with node id PR-ID Viewed in REPO, or unmark it.
VIEWED nil unmarks.  The local row is written first, so the Review
Buffer shows the change at once; the mutation runs in the background.
When GitHub refuses, the previous row comes back, a message says why,
and BUFFER, when live, refreshes.  Milestone 4 keeps the failed change
in the Outbox instead."
  (let* ((old (prrr-db-get 'viewed pr-id path))
         (fail (lambda (failure)
                 (if old
                     (prrr-db-insert old)
                   (prrr-db-delete 'viewed :pr-id pr-id :path path))
                 (message "Viewed of %s not changed on GitHub: %s"
                          path (plist-get failure :message))
                 (prrr-sync--schedule-refresh buffer))))
    (prrr-db-insert (prrr-viewed-create :pr-id pr-id :path path
                                        :state (if viewed 'viewed 'unviewed)
                                        :fetched-at (prrr-sync--timestamp)))
    (prrr-sync--guarded fail
      (prrr-github-set-viewed (oref repo apihost) pr-id path viewed #'ignore fail))))
```

Run: `make test TESTS=test/prrr-sync-test.el`
Expected: all pass.

- [ ] **Step 3: Write the failing command tests**

Append to `test/prrr-diff-test.el`:

```elisp
;;;; Commands

(defun prrr-diff-test--at ()
  "Return (TYPE . VALUE) of the section at point."
  (let ((section (magit-current-section)))
    (cons (oref section type) (oref section value))))

(ert-deftest prrr-diff-test-next-and-previous-file ()
  (prrr-diff-test--with-buffer nil
    (goto-char (point-min))
    (prrr-next-file)
    (should (equal '(file . "README.md") (prrr-diff-test--at)))
    (prrr-next-file)
    (should (equal '(file . "data.bin") (prrr-diff-test--at)))
    (prrr-previous-file)
    (should (equal '(file . "README.md") (prrr-diff-test--at)))
    (should-error (prrr-previous-file) :type 'user-error)
    (prrr-jump-to-file "src/old.el")
    (should (equal '(file . "src/old.el") (prrr-diff-test--at)))
    (should-error (prrr-next-file) :type 'user-error)))

(ert-deftest prrr-diff-test-jump-to-file-expands-it ()
  (let ((prrr-eager-files 0))
    (prrr-diff-test--with-buffer nil
      (prrr-jump-to-file "docs/notes.md")
      (should-not (oref (prrr-diff-test--file-section "docs/notes.md") hidden)))))

(ert-deftest prrr-diff-test-next-thread-washes-and-reveals ()
  "] reaches Threads in files not washed yet and inside folded groups."
  (let ((prrr-eager-files 0))
    (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
      (goto-char (point-min))
      (let ((seen nil))
        (dotimes (_ 5)
          (prrr-next-thread)
          (should-not (invisible-p (point)))
          (push (cdr (prrr-diff-test--at)) seen))
        (should (equal '("PRRT_kwDOexample0000002" "PRRT_kwDOexample0000004"
                         "PRRT_kwDOexample0000001" "PRRT_kwDOexample0000005"
                         "PRRT_kwDOexample0000003")
                       (nreverse seen))))
      (should-error (prrr-next-thread) :type 'user-error)
      (prrr-previous-thread)
      (should (equal "PRRT_kwDOexample0000005" (cdr (prrr-diff-test--at)))))))

(ert-deftest prrr-diff-test-next-unresolved-skips-resolved ()
  (let ((prrr-eager-files 0))
    (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
      (goto-char (point-min))
      (prrr-next-unresolved)
      (should (equal "PRRT_kwDOexample0000004" (cdr (prrr-diff-test--at))))
      ;; The only Thread before it, on README.md, is resolved.
      (should-error (prrr-previous-unresolved) :type 'user-error))))

(ert-deftest prrr-diff-test-collapse-and-expand-all ()
  (let ((prrr-eager-files 1))
    (prrr-diff-test--with-buffer nil
      (prrr-expand-all)
      (dolist (path (prrr-diff-test--files))
        (should-not (oref (prrr-diff-test--file-section path) hidden)))
      (prrr-collapse-all)
      (dolist (path (prrr-diff-test--files))
        (should (oref (prrr-diff-test--file-section path) hidden))))))

(ert-deftest prrr-diff-test-toggle-viewed ()
  (prrr-diff-test--with-buffer nil
    (cl-letf (((symbol-function 'forge-get-repository)
               (lambda (&rest _) (forge-github-repository :id "r" :apihost "api.github.com"))))
      (prrr-test-with-ghub-stub '((data (markFileAsViewed (clientMutationId)))) captured
        (prrr-jump-to-file "README.md")
        (prrr-toggle-viewed)
        (should (eq 'markFileAsViewed (car (cadr (car captured)))))
        (should (eq 'viewed (prrr-viewed-state (prrr-db-get 'viewed prrr-diff-test--pr "README.md"))))
        (let ((readme (prrr-diff-test--file-section "README.md")))
          (should (oref readme hidden))
          (should (string-match-p "✓ viewed" (prrr-diff-test--text readme))))
        (should (equal '(file . "data.bin") (prrr-diff-test--at)))
        (prrr-jump-to-file "README.md")
        (prrr-toggle-viewed)
        (should (eq 'unviewed (prrr-viewed-state
                               (prrr-db-get 'viewed prrr-diff-test--pr "README.md"))))
        (should-not (oref (prrr-diff-test--file-section "README.md") hidden))
        (should (equal '(file . "README.md") (prrr-diff-test--at)))))))

(ert-deftest prrr-diff-test-keys-and-menu-agree ()
  "SPEC section 9: every key of this milestone, in the buffer and the menu."
  (pcase-dolist (`(,key . ,command)
                 '(("]" . prrr-next-thread) ("[" . prrr-previous-thread)
                   ("}" . prrr-next-unresolved) ("{" . prrr-previous-unresolved)
                   ("J" . prrr-next-file) ("K" . prrr-previous-file)
                   ("j" . prrr-jump-to-file) ("v" . prrr-toggle-viewed)
                   ("z" . prrr-collapse-all) ("Z" . prrr-expand-all)
                   ("o" . prrr-open-topic) ("b" . prrr-browse) ("B" . prrr-checkout)
                   ("g" . magit-refresh) ("G" . prrr-refetch)))
    (should (eq command (keymap-lookup prrr-diff-mode-map key)))
    (let ((suffix (transient-get-suffix 'prrr-menu key)))
      (should (eq command (plist-get (if (vectorp suffix) (aref suffix 2) (cdr suffix))
                                     :command)))))
  (should (eq 'prrr-menu (keymap-lookup prrr-diff-mode-map "?")))
  (should (eq 'prrr-menu (keymap-lookup prrr-diff-mode-map "C-o")))
  (should (eq 'magit-dispatch (keymap-lookup prrr-diff-mode-map "h"))))

(ert-deftest prrr-diff-test-later-keys-do-nothing-yet ()
  "magit's commit, stage, discard and friends never run in a Review Buffer."
  (dolist (key '("c" "C" "r" "e" "k" "d" "R" "s" "D" "." "m" ">" "<" "S" "O" "@" "L"))
    (should (eq 'undefined (keymap-lookup prrr-diff-mode-map key)))))
```

At the top of `test/prrr-diff-test.el`, add `(require 'prrr-transient)`.

- [ ] **Step 4: Run them to verify they fail**

Run: `make test TESTS=test/prrr-diff-test.el SELECTOR='"prrr-diff-test-\\(next\\|jump\\|collapse\\|toggle\\|keys\\|later\\)"'`
Expected: FAIL, the commands are void.

- [ ] **Step 5: Implement the commands**

Append a part `;;;; Commands` to `prrr-diff.el` before `(provide 'prrr-diff)`:

```elisp
;;;; Commands

(defun prrr-diff--files ()
  "Return the `file' sections of the buffer, in order."
  (seq-filter (lambda (section) (eq (oref section type) 'file))
              (oref magit-root-section children)))

(defun prrr-diff--file-at-point ()
  "Return the `file' section around point, or nil."
  (let ((section (magit-current-section)))
    (while (and section (not (eq (oref section type) 'file)))
      (setq section (oref section parent)))
    section))

(defun prrr-diff--file-near-point (offset)
  "Return the file OFFSET files after the one around point, or nil.
A negative OFFSET counts backwards.  Before the first file, the first
file is one after point; after the last, the last is one before it."
  (let* ((files (prrr-diff--files))
         (current (prrr-diff--file-at-point))
         (index (cond (current (+ (seq-position files current) offset))
                      ((and files (< (point) (oref (car files) start)))
                       (if (> offset 0) (1- offset) -1))
                      (t (if (< offset 0) (+ (length files) offset) (length files))))))
    (and (<= 0 index) (nth index files))))

(defun prrr-next-file ()
  "Move to the next file of the diff."
  (interactive)
  (prrr-diff--require-pullreq)
  (magit-section-goto (or (prrr-diff--file-near-point 1) (user-error "No next file"))))

(defun prrr-previous-file ()
  "Move to the previous file of the diff."
  (interactive)
  (prrr-diff--require-pullreq)
  (magit-section-goto (or (prrr-diff--file-near-point -1) (user-error "No previous file"))))

(defun prrr-jump-to-file (path)
  "Move to the file PATH of the diff and expand it.
Interactively, read PATH with completion over the diff's files."
  (interactive
   (progn (prrr-diff--require-pullreq)
          (list (completing-read "Jump to file: "
                                 (mapcar (lambda (file) (oref file value)) (prrr-diff--files))
                                 nil t))))
  (let ((file (or (seq-find (lambda (file) (equal (oref file value) path)) (prrr-diff--files))
                  (user-error "No file %s in this diff" path))))
    (magit-section-show file)
    (magit-section-goto file)))

(defun prrr-diff--thread-sections (container)
  "Return the `thread' and `file-comment' sections in CONTAINER, in order."
  (let ((sections nil))
    (magit-map-sections (lambda (section)
                          (when (memq (oref section type) '(thread file-comment))
                            (push section sections)))
                        container)
    (nreverse sections)))

(defun prrr-diff--threads-of (path)
  "Return every Thread the buffer shows in the file PATH."
  (when-let ((entry (and prrr-diff--file-threads (gethash path prrr-diff--file-threads))))
    (append (prrr-file-threads-file-comments entry)
            (prrr-file-threads-lines entry)
            (prrr-file-threads-outdated entry))))

(defun prrr-diff--reveal (section)
  "Show SECTION and every section around it."
  (let ((chain nil))
    (while section
      (push section chain)
      (setq section (oref section parent)))
    (dolist (outer chain)
      (when (oref outer hidden)
        (magit-section-show outer)))))

(defun prrr-diff--goto-thread (forward wanted)
  "Move to the next Thread after point, or before it unless FORWARD.
Only Threads whose `prrr-thread' satisfies WANTED count.  A file not
washed yet is expanded when it holds such a Thread, and the target is
revealed wherever it is folded.  Signal a `user-error' when there is
none."
  (prrr-diff--require-pullreq)
  (let* ((here (line-beginning-position))
         (containers (append (prrr-diff--files)
                             (seq-filter (lambda (section)
                                           (eq (oref section type) 'outdated-files))
                                         (oref magit-root-section children))))
         (found
          (catch 'found
            (dolist (container (if forward containers (reverse containers)))
              (when (if forward (> (oref container end) here) (< (oref container start) here))
                (when (and (oref container washer)
                           (seq-some wanted (prrr-diff--threads-of (oref container value))))
                  (magit-section-show container))
                (let ((candidates
                       (seq-filter (lambda (section)
                                     (and (funcall wanted
                                                   (gethash (oref section value) prrr-diff--threads))
                                          (if forward
                                              (> (oref section start) here)
                                            (< (oref section start) here))))
                                   (prrr-diff--thread-sections container))))
                  (when candidates
                    (throw 'found (if forward (car candidates) (car (last candidates))))))))
            nil)))
    (unless found
      (user-error (if forward "No next Thread" "No previous Thread")))
    (prrr-diff--reveal found)
    (magit-section-goto found)))

(defun prrr-diff--unresolved-p (thread)
  "Non-nil when THREAD is not resolved."
  (and thread (not (prrr-thread-resolved-p thread))))

(defun prrr-next-thread ()
  "Move to the next Thread or File Comment."
  (interactive)
  (prrr-diff--goto-thread t #'identity))

(defun prrr-previous-thread ()
  "Move to the previous Thread or File Comment."
  (interactive)
  (prrr-diff--goto-thread nil #'identity))

(defun prrr-next-unresolved ()
  "Move to the next unresolved Thread or File Comment."
  (interactive)
  (prrr-diff--goto-thread t #'prrr-diff--unresolved-p))

(defun prrr-previous-unresolved ()
  "Move to the previous unresolved Thread or File Comment."
  (interactive)
  (prrr-diff--goto-thread nil #'prrr-diff--unresolved-p))

(defun prrr-collapse-all ()
  "Fold every file of the diff."
  (interactive)
  (prrr-diff--require-pullreq)
  (mapc #'magit-section-hide (prrr-diff--files)))

(defconst prrr-diff--expand-all-quietly 100
  "Most files `prrr-expand-all' washes without asking first.")

(defun prrr-expand-all ()
  "Expand every file of the diff, washing the files not washed yet.
Asks first when that means washing more than
`prrr-diff--expand-all-quietly' files, which takes seconds."
  (interactive)
  (prrr-diff--require-pullreq)
  (let* ((files (prrr-diff--files))
         (unwashed (seq-count (lambda (file) (oref file washer)) files)))
    (when (or (<= unwashed prrr-diff--expand-all-quietly)
              (y-or-n-p (format "Wash %d more files? " unwashed)))
      (mapc #'magit-section-show files))))

(defun prrr-diff--viewed-p (pr-id path)
  "Non-nil when PATH of PR-ID is stored as Viewed."
  (let ((row (prrr-db-get 'viewed pr-id path)))
    (and row (eq (prrr-viewed-state row) 'viewed))))

(defun prrr-toggle-viewed ()
  "Mark the file at point Viewed on GitHub and fold it, or unmark it.
Marking moves to the next file, as GitHub does."
  (interactive)
  (let* ((pullreq (prrr-diff--require-pullreq))
         (file (or (prrr-diff--file-at-point) (user-error "No file here")))
         (path (oref file value))
         (pr-id (oref pullreq their-id))
         (viewed (not (prrr-diff--viewed-p pr-id path))))
    ;; Folding first records the fold in the visibility cache, so the
    ;; refresh below agrees with the Viewed flag.
    (if viewed (magit-section-hide file) (magit-section-show file))
    (magit-section-goto file)
    (prrr-sync-set-viewed (forge-get-repository pullreq) pr-id path viewed (current-buffer))
    (magit-refresh-buffer)
    (when-let ((next (and viewed (prrr-diff--file-near-point 1))))
      (magit-section-goto next))))
```

Replace the keymap with:

```elisp
(defvar-keymap prrr-diff-mode-map
  :doc "Keys of the Review Buffer (SPEC section 9).
Keys that later milestones give to prrr are `undefined' until then, so
magit's commit, stage, discard or rebase never run from here."
  :parent magit-diff-mode-map
  "]" #'prrr-next-thread
  "[" #'prrr-previous-thread
  "}" #'prrr-next-unresolved
  "{" #'prrr-previous-unresolved
  "J" #'prrr-next-file
  "K" #'prrr-previous-file
  "j" #'prrr-jump-to-file
  "v" #'prrr-toggle-viewed
  "z" #'prrr-collapse-all
  "Z" #'prrr-expand-all
  "o" #'prrr-open-topic
  "b" #'prrr-browse
  "B" #'prrr-checkout
  "G" #'prrr-refetch
  "?" #'prrr-menu
  "C-o" #'prrr-menu
  "c" #'undefined "C" #'undefined "r" #'undefined "e" #'undefined
  "k" #'undefined "d" #'undefined "R" #'undefined "s" #'undefined
  "D" #'undefined "." #'undefined "m" #'undefined ">" #'undefined
  "<" #'undefined "S" #'undefined "O" #'undefined "@" #'undefined
  "L" #'undefined)
```

`g` stays `magit-refresh` and `h` stays `magit-dispatch`, both inherited. `prrr-diff.el` needs `(require 'prrr)` for `prrr-open-topic` and friends, and `(declare-function prrr-menu "prrr-transient" ())` for the menu.

- [ ] **Step 6: Add the transient**

In `prrr-transient.el`, add `(require 'prrr-diff)` with the other requires and append before `(provide 'prrr-transient)`:

```elisp
;;;###autoload (autoload 'prrr-menu "prrr-transient" nil t)
(transient-define-prefix prrr-menu ()
  "Act on the Review Buffer (SPEC section 9).
Milestones 4 to 7 add the Comment, Range, Stack, Review and Agent groups."
  [["Navigate"
    ("]" "next Thread" prrr-next-thread)
    ("[" "previous Thread" prrr-previous-thread)
    ("}" "next unresolved" prrr-next-unresolved)
    ("{" "previous unresolved" prrr-previous-unresolved)
    ("J" "next file" prrr-next-file)
    ("K" "previous file" prrr-previous-file)
    ("j" "jump to file" prrr-jump-to-file)]
   ["View"
    ("v" "toggle Viewed" prrr-toggle-viewed)
    ("z" "collapse all" prrr-collapse-all)
    ("Z" "expand all" prrr-expand-all)]
   ["Open"
    ("o" "topic" prrr-open-topic)
    ("b" "browse on GitHub" prrr-browse)
    ("B" "checkout" prrr-checkout)]
   ["Sync"
    ("g" "refresh" magit-refresh)
    ("G" "refetch" prrr-refetch)]])
```

Update the file's Commentary: "The Review Buffer's `prrr-menu' arrives in milestone 3." becomes "`prrr-menu' is the Review Buffer's; later milestones add its groups."

In `prrr.el`, add to the explicit autoloads:

```elisp
(autoload 'prrr-menu "prrr-transient" "Show the Review Buffer commands." t)
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `make test`
Expected: all pass. `prrr-diff-test-later-keys-do-nothing-yet` needs `(keymap-lookup prrr-diff-mode-map "c")` to return the symbol `undefined`.

- [ ] **Step 8: Run all gates and commit**

```bash
make compile lint test
git add prrr-sync.el prrr-diff.el prrr-transient.el prrr.el test/prrr-sync-test.el test/prrr-diff-test.el
git commit -m "feat(diff): navigation, folding, Viewed toggle, keys and prrr-menu"
```

---

### Task 12: Review Buffer budgets

**Files:**
- Create: `bench/make-diff-repo.sh` (executable)
- Create: `bench/prrr-diff-bench.el`
- Modify: `Makefile` (`bench` builds and runs both benchmarks)

**Interfaces:**
- Consumes: `prrr-diff-setup-buffer` (Task 7).
- Produces: `make bench` prints the queue line (milestone 2), then four Review Buffer lines, and exits non-zero when any median exceeds its SPEC section 12 budget by more than 25 percent.

- [ ] **Step 1: Write the repository generator**

Create `bench/make-diff-repo.sh` and `chmod +x` it:

```sh
#!/bin/sh
# Build a repository in DIR (argument 1) whose refs/pullreqs/1 changes
# FILES files (argument 2): 300-line files, three lines changed in each,
# in directories of 100 files.  Deterministic, no network.
set -eu
dir=$1
files=$2
mkdir -p "$dir"
cd "$dir"
export GIT_AUTHOR_NAME=example GIT_AUTHOR_EMAIL=example@example.com
export GIT_COMMITTER_NAME=example GIT_COMMITTER_EMAIL=example@example.com
export GIT_AUTHOR_DATE=2026-09-01T00:00:00Z GIT_COMMITTER_DATE=2026-09-01T00:00:00Z
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
git init -q -b main
git config commit.gpgsign false
seq -f 'line %g of the example file' 1 300 > ../template.$$
i=0
while [ "$i" -lt "$files" ]; do
  mkdir -p "dir$((i / 100))"
  cp ../template.$$ "dir$((i / 100))/file$i.txt"
  i=$((i + 1))
done
rm ../template.$$
git add -A
git commit -q -m base
git checkout -q -b feature
find . -name '*.txt' -not -path './.git/*' -exec sed -i.bak \
  -e 's/^line 10 of/line ten of/' \
  -e 's/^line 150 of/line 150 changed of/' \
  -e 's/^line 290 of/line 290 changed of/' {} +
find . -name '*.bak' -not -path './.git/*' -exec rm {} +
git commit -q -a -m head
git update-ref refs/pullreqs/1 HEAD
git checkout -q main
```

Run: `sh bench/make-diff-repo.sh "$(mktemp -d)/r" 5 && echo ok`
Expected: `ok`.

- [ ] **Step 2: Write the benchmark**

Create `bench/prrr-diff-bench.el` (standard header; Commentary: "SPEC section 12: the Review Buffer budgets.  Run with `make bench'.  Generates repositories of 417 and 2,516 changed files with bench/make-diff-repo.sh and measures first paint, expanding one 300-line file, and a refresh with three files expanded, each as the median of several runs in a fresh buffer.  Highlighting arrives in milestone 6; until then the expand budget is measured without it."):

```elisp
;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'prrr-diff)

(defconst prrr-diff-bench-tolerance 1.25
  "A run fails when a median exceeds its budget by more than this factor.")

(defconst prrr-diff-bench--script
  (expand-file-name "make-diff-repo.sh" (file-name-directory (or load-file-name buffer-file-name)))
  "The repository generator next to this file.")

(defun prrr-diff-bench--ms (function)
  "Call FUNCTION; return the elapsed milliseconds."
  (let ((start (float-time)))
    (funcall function)
    (* 1000 (- (float-time) start))))

(defun prrr-diff-bench--median (numbers)
  "Return the median of NUMBERS, an odd-length list."
  (nth (/ (length numbers) 2) (sort (copy-sequence numbers) #'<)))

(defun prrr-diff-bench--pullreq ()
  "The generated repository's pull request."
  (forge-pullreq :id "bench-1" :number 1 :title "Bench" :their-id "PR_bench"
                 :base-rev (car (process-lines "git" "rev-parse" "main"))
                 :author "example-alice" :created "2026-09-01T00:00:00Z" :body ""))

(defun prrr-diff-bench--open (pullreq)
  "Open PULLREQ's Review Buffer in a fresh buffer; return the milliseconds."
  (when-let ((old (get-buffer (prrr-diff--buffer-name pullreq))))
    (kill-buffer old))
  (garbage-collect)
  (prrr-diff-bench--ms (lambda () (prrr-diff-setup-buffer pullreq))))

(defun prrr-diff-bench--buffer (pullreq)
  "Return PULLREQ's Review Buffer."
  (get-buffer (prrr-diff--buffer-name pullreq)))

(defun prrr-diff-bench--unwashed ()
  "Return the current Review Buffer's files not washed yet."
  (seq-filter (lambda (file) (oref file washer)) (prrr-diff--files)))

(defun prrr-diff-bench--measure (files)
  "Measure a repository of FILES changed files; return a plist of medians.
:open is first paint in a fresh buffer, :expand washing one file not
washed yet, :refresh `magit-refresh-buffer' with three more files
expanded."
  (let* ((dir (make-temp-file "prrr-bench" t))
         (repo (expand-file-name "r" dir)))
    (unwind-protect
        (progn
          (unless (zerop (call-process "sh" nil nil nil prrr-diff-bench--script repo
                                       (number-to-string files)))
            (error "make-diff-repo.sh failed"))
          (let* ((default-directory (file-name-as-directory repo))
                 (pullreq (prrr-diff-bench--pullreq))
                 (opens (cl-loop repeat 5 collect (prrr-diff-bench--open pullreq)))
                 (expands (with-current-buffer (prrr-diff-bench--buffer pullreq)
                            (mapcar (lambda (file)
                                      (prrr-diff-bench--ms (lambda () (magit-section-show file))))
                                    (seq-take (prrr-diff-bench--unwashed) 5))))
                 (refreshes (progn
                              (prrr-diff-bench--open pullreq)
                              (with-current-buffer (prrr-diff-bench--buffer pullreq)
                                (mapc #'magit-section-show (seq-take (prrr-diff-bench--unwashed) 3))
                                (cl-loop repeat 5 collect
                                         (prrr-diff-bench--ms #'magit-refresh-buffer))))))
            (kill-buffer (prrr-diff-bench--buffer pullreq))
            (list :open (prrr-diff-bench--median opens)
                  :expand (prrr-diff-bench--median expands)
                  :refresh (prrr-diff-bench--median refreshes))))
      (delete-directory dir t))))

(defun prrr-diff-bench--check (label ms budget)
  "Print LABEL's MS against BUDGET; return non-nil when over the tolerance."
  (message "%s: %.1f ms (budget %.0f ms, fails over %.0f ms)"
           label ms budget (* budget prrr-diff-bench-tolerance))
  (> ms (* budget prrr-diff-bench-tolerance)))

(defun prrr-diff-bench-run ()
  "Measure the Review Buffer budgets of SPEC section 12; exit 1 over budget."
  (let* ((prrr-database-file (make-temp-file "prrr-bench" nil ".sqlite"))
         (small (prrr-diff-bench--measure 417))
         (large (prrr-diff-bench--measure 2516))
         (over (delq nil
                     (list (prrr-diff-bench--check "review open, 417 files"
                                                   (plist-get small :open) 150)
                           (prrr-diff-bench--check "review open, 2516 files"
                                                   (plist-get large :open) 500)
                           (prrr-diff-bench--check "expand one 300-line file"
                                                   (plist-get small :expand) 25)
                           (prrr-diff-bench--check "refresh, 3 expanded, 417 files"
                                                   (plist-get small :refresh) 250)))))
    (prrr-db-close)
    (delete-file prrr-database-file)
    (kill-emacs (if over 1 0))))

(provide 'prrr-diff-bench)
;;; prrr-diff-bench.el ends here
```

The 417-file measurement includes the default eager washing of 30 files, which is what a user's open pays.

- [ ] **Step 3: Wire it into the Makefile**

The `bench` target compiles `$(SRC)` into a temporary directory. Make it compile both bench files, copy the generator, and run both benchmarks, each in its own Emacs:

```make
bench:
	@dir=$$(mktemp -d) && trap 'rm -rf "$$dir"' EXIT && \
	  cp $(SRC) bench/*.el bench/*.sh "$$dir" && \
	  $(BENCH) -L "$$dir" -f batch-byte-compile $(addprefix "$$dir"/,$(SRC)) \
	    "$$dir"/prrr-queue-bench.el "$$dir"/prrr-diff-bench.el && \
	  $(BENCH) -L "$$dir" -l "$$dir"/prrr-queue-bench.elc -f prrr-queue-bench-run && \
	  $(BENCH) -L "$$dir" -l "$$dir"/prrr-diff-bench.elc -f prrr-diff-bench-run
```

- [ ] **Step 4: Run it**

Run: `make bench`
Expected: the queue line, then four lines such as `review open, 417 files: 115.0 ms (budget 150 ms, fails over 188 ms)`, and exit status 0. The prototype measured about 115 ms, 360 ms, 3 ms and 110 ms. If a budget fails, profile with `profiler-start`/`profiler-report` around `prrr-diff-setup-buffer` in this harness. Do not raise a budget; they are SPEC section 12's. Report the measured numbers in the commit body.

- [ ] **Step 5: Run all gates and commit**

```bash
make compile lint test bench
git add bench/make-diff-repo.sh bench/prrr-diff-bench.el Makefile
git commit -m "bench: Review Buffer open, expand and refresh budgets"
```

---

### Task 13: README, SPEC corrections, and the milestone's close

**Files:**
- Modify: `README.md`
- Modify: `SPEC.md` (sections 2, 6, 9)

**Interfaces:**
- Consumes: every user-visible name from Tasks 7-11.
- Produces: the README sections below; SPEC matches what was built.

- [ ] **Step 1: Update `README.md`**

1. Replace the second paragraph (from "prrr puts the pull requests…" up to the Status note) with:

```markdown
prrr puts the pull requests that need you in your magit-status buffer,
oldest first, with Stacks of dependent PRs kept together. Press `RET` on
one to open its Review Buffer: the diff from the PR's merge base to its
head, with existing threads inline, files folding away once viewed, and
one key to jump between files and threads. Upcoming milestones add line
and range comments, a pending review submitted in one batch, and "what
changed since my last review".

> **Status:** early development. The Review Queue and a read-only Review
> Buffer work. Commenting and submitting are next. See the milestones in
> [`SPEC.md`](SPEC.md#15-milestones).
```

2. In "Keys on a queue row", the `RET` row becomes `| `RET` | `prrr-review` | Open the PR's Review Buffer |`.

3. Insert a new section after "The Review Queue" and before "Development":

```markdown
## The Review Buffer

`M-x prrr-review` (or `RET` on a queue row) opens a pull request's Review
Buffer. It diffs the PR's head, which forge fetches to `refs/pullreqs/N`,
against its merge base with the base branch. If that ref is missing, prrr
offers to run `forge-pull`. When it stays missing, run
`forge-add-pullreq-refspec` and pull again.

The buffer opens at once from prrr's database and refetches the threads,
your pending review and the Viewed flags in the background. The header
says `refreshing…` meanwhile, and `offline` or `rate limited until 14:05`
when that fails. The header shows the title, the range, your pending
review's comment count, and a warning when GitHub has a newer head than
your local ref. Folded below it are the description and the discussion.

Large diffs stay fast. The first files, up to `prrr-eager-files` files or
`prrr-eager-lines` changed lines, are shown expanded. Every other file
loads when you first expand it.

Threads sit right after the line they comment on. A thread on a line that
is not in the diff goes to a folded "Not in this diff" group at the end
of its file. Outdated threads go to a folded "Outdated" group. Threads on
files no longer in the diff go to a group at the end of the buffer.
Resolved threads start folded. `RET` on a thread visits the line it is
anchored to.

Files you marked Viewed, here or on GitHub, are folded and marked `✓
viewed`. `g` redraws and keeps what you expanded and folded.

### Keys in the Review Buffer

| Key       | Command                                             | Does                                       |
|-----------|-----------------------------------------------------|--------------------------------------------|
| `]` / `[` | `prrr-next-thread` / `prrr-previous-thread`         | Next or previous thread                    |
| `}` / `{` | `prrr-next-unresolved` / `prrr-previous-unresolved` | Next or previous unresolved thread         |
| `J` / `K` | `prrr-next-file` / `prrr-previous-file`             | Next or previous file                      |
| `j`       | `prrr-jump-to-file`                                 | Jump to a file, with completion            |
| `v`       | `prrr-toggle-viewed`                                | Mark the file Viewed on GitHub and fold it |
| `z` / `Z` | `prrr-collapse-all` / `prrr-expand-all`             | Fold or expand every file                  |
| `o`       | `prrr-open-topic`                                   | forge's topic buffer                       |
| `b`       | `prrr-browse`                                       | Open the PR on GitHub                      |
| `B`       | `prrr-checkout`                                     | Check out the PR's branch                  |
| `g`       | `magit-refresh`                                     | Redraw from the database                   |
| `G`       | `prrr-refetch`                                      | Refetch threads and Viewed flags now       |
| `?`, `C-o`| `prrr-menu`                                         | Menu with the same keys                    |

magit's `TAB`, `n`, `p`, `M-n`, `M-p`, `^`, `RET`, `1`-`4`, `E` (ediff), `h`
and `q` work as in any magit diff. Keys that later milestones use for
commenting and reviewing (`c`, `r`, `e`, `k`, `s`, `S`, …) do nothing yet.
```

4. In "Commands", add `- `prrr-review`: open a pull request's Review Buffer (with `C-u`, always ask which).` as the first item.

5. In "Options", add two rows:

```markdown
| `prrr-eager-files`       | `30`    | Files expanded when a Review Buffer opens       |
| `prrr-eager-lines`       | `2000`  | Changed lines expanded when it opens            |
```

Keep the README's column alignment consistent with the existing tables.

- [ ] **Step 2: Correct `SPEC.md`**

1. Section 2, table: `prrr-thread.el`'s "Depends on" becomes `magit-section, prrr-db`, and `prrr-diff.el`'s becomes `magit-diff, magit-section, prrr-state, prrr-thread, prrr-sync`. Under "Rules" add: "- `prrr-thread.el` renders and `prrr-diff.el` places: a Thread's look does not depend on the diff, so the capture buffer of milestone 4 takes its anchor as an argument."
2. Section 6, "Magit coupling": replace the paragraph with:

```markdown
**Magit coupling.** prrr ships its own copy of `magit-diff-wash-hunk`
(extended to insert `thread` children) and washes deferred files with
`magit-git-insert` plus narrowing, because `magit-git-wash` and
`magit-diff-wash-diffs` cannot run in a deferred body. It defines a
`prrr-diff-mode`-scoped `&context` method for `magit-section-paint`, and
advises `magit-diff-hunk-line` and `magit-diff--hunk-section` to tolerate
child sections. After each render it turns every section's integer
`content` into a marker, because `magit-section-inhibit-markers` `delay`
converts only `start` and `end`. `magit-diff-fontify-hunk` is forced nil in
prrr buffers, and Threads have their own `RET`, because magit's has no
diff scope on them. The package pins `magit >= 4.7` and CI tests against
MELPA magit, so a magit change is found by the test suite, not by users.
```

3. Section 6, "Magit features that keep working": replace `ediff from a hunk` with `ediff from a hunk with E`.
4. Section 9, "Preserved from magit": replace `` `C-c C-e` ediff `` with `` `E` ediff ``.
5. Section 6, "Sections": after the sentence about `outdated-files`, add: "A `discussion` section's keymap is cleared, since forge's `forge-discussion-section-map` would otherwise apply by type name."

- [ ] **Step 3: Run all gates and commit**

```bash
make compile lint test bench
git add README.md SPEC.md
git commit -m "docs: Review Buffer in the README; SPEC matches the built coupling"
```

- [ ] **Step 4: Close the milestone**

Close the milestone-3 beads (`bd close` with their ids), run `bd ready`, and report what remains: the milestone-2 carry-overs `prrr-knu.8`, `prrr-knu.9`, `prrr-knu.10` and `prrr-opy` are not part of this plan.
