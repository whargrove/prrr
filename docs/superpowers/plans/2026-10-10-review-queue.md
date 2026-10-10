# Review Queue Milestone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship milestone 2 of `prrr` (SPEC.md section 15, item 2): `prrr-pull`, Teams, the Review Queue section in magit-status with FIFO ordering and Stacks, its keymap and transient. Also resolve the seven milestone-1 carry-overs (`prrr-knu.1` to `.7`) and start the `README.md` that each later milestone extends.

**Architecture:** Four new files, each depending only on the files above it. `prrr-sync.el` decides when to pull and records the outcome per repository. `prrr-queue.el` renders the section from the database and forge's objects, never from the network. `prrr-stack.el` holds Stack navigation. `prrr-transient.el` holds the transient menus. `prrr.el` becomes a light entry point: it loads neither forge nor the database, and every command is reached through an autoload. The pure rules stay in `prrr-state.el`, SQL in `prrr-db.el`, GitHub calls in `prrr-github.el`, and each gains the small additions the queue needs.

**Tech Stack:** Emacs Lisp (Emacs 29.1+), emacsql 4.4 with the built-in SQLite backend, forge 0.5 (`forge-query`, `forge-get-repository`, `forge-current-pullreq`, `forge-pull`), magit 4.7 (`magit-insert-section`, `magit-add-section-hook`), transient 0.13, ERT.

**Spec:** `SPEC.md` sections 2, 4, 5, 9, 11, 12, 15. Glossary: `CONTEXT.md`. Verified API facts: `docs/superpowers/notes/2026-10-10-foundation-facts.md`, plus the milestone-2 facts below. Carry-over issues: `bd show prrr-knu.1` through `prrr-knu.7`.

## Milestone-2 facts (verified 2026-10-10 against forge 20261006.1249, magit-section 20260926.1436, ghub 20261001.1601, transient 20261001.1359)

- `magit-insert-section` resolves a section's keymap at creation from `magit-TYPE-section-map` or `forge-TYPE-section-map`. The `keymap` slot has no initarg. To give a row of type `pullreq` prrr's own keymap, bind the section (`(magit-insert-section row (pullreq obj) ...)`) and `(oset row keymap 'prrr-queue-section-map)` inside the body. Text properties are applied when the section finishes, so this works.
- `forge-pullreq-at-point` and `forge-current-pullreq` read `(magit-section-value-if 'pullreq)`. A row whose type is `pullreq` and whose value is the `forge-pullreq` therefore keeps every forge command working.
- `forge-insert-pullreqs` starts with `(forge-db t)` and `(forge-get-repository :tracked?)`. `:tracked?` returns nil, without signalling, for an untracked repository. prrr's section function uses the same guards.
- `(oref repo pullreqs)` returns every `forge-pullreq` of a repository; `(oref pullreq state)` is `open`, `merged` or `rejected`. Other slots: `their-id number title author created updated draft-p head-rev base-ref head-ref cross-repo-p`. `(oref pullreq assignees)` is a list of `(ID LOGIN NAME FORGE-ID)`. That slot has no initarg, so tests cannot construct it; read it through one small function that tests stub.
- `forge-pullreq` and `forge-github-repository` objects can be built offline: `(forge-pullreq :id "x" :number 3 :title "T" :their-id "PR_1")` and `(forge-github-repository :id "rid" :owner "o" :name "n" :apihost "api.github.com")`. `default-branch` has no initarg; set it with `(oset repo default-branch "main")`.
- ghub calls an errorback as `(funcall errorback ERR HEADERS STATUS REQ)`. ERR is `(errors ERROR...)` for GraphQL errors (each ERROR an alist with `type` and `message`), or `(error http CODE)` for HTTP failures. A transport failure has the shape `(error connection-failed ...)`. HEADERS is an alist of `("Header-Name" . "value")` strings, case as sent. `forge-query` passes `:errorback` through to ghub unchanged. Without an errorback, ghub signals.
- A missing token makes `forge-query` signal synchronously, before any request is made.
- `magit-add-section-hook` signals when the hook variable is unbound, so `magit-status-sections-hook` must exist, meaning magit is loaded. `forge.el` itself adds `forge-insert-pullreqs` with `(magit-add-section-hook 'magit-status-sections-hook #'forge-insert-pullreqs nil t)`.
- package-lint warns on every `with-eval-after-load` and `eval-after-load`, and `make lint` fails on warnings. The section is therefore turned on by a global minor mode, `prrr-queue-mode`, which users enable from their own configuration.
- `(transient-get-suffix 'PREFIX "KEY")` returns `(transient-suffix :key "KEY" :description ... :command CMD)` on the installed transient. Older transients return `[LEVEL CLASS PLIST]`. Tests read `:command` from either shape.
- emacsql: `[:select [pr-id (funcall count *)] :from thread :where (isnull resolved-p) :group-by pr-id]` works. nil columns are stored as NULL.

## Decisions taken in this plan

- **prrr-knu.3 (which head new-commits compares against):** the viewer's latest review commit is compared with `prrr-pr-meta-head-oid`, which comes from the same query as the review. forge's `head-rev` is used only when a PR has no meta row yet, and then there is no review to compare. Two snapshots fetched on different cadences can never produce a false `new-commits`. The rule lives in `prrr-state--head-oid` (Task 2) and SPEC section 5.
- **prrr-knu.5 (stack-size versus visible rows):** a row's `⟰ k/n` marker keeps the true Stack position. Indentation comes from the row's depth among the *visible* rows of its Stack, so a For Me Stack that lost my own bottom PR renders `⟰ 2/2` at depth 0, with no gap (Task 7).
- **prrr-knu.7 (Stack tie rule):** when several open PRs have the head branch a PR is based on, the oldest is its parent (creation time, then PR number). The result no longer depends on the input order (Task 1).
- **prrr-knu.6 (startup cost):** `prrr.el` requires nothing from prrr, forge or magit. Commands are reached through autoload cookies. The section is turned on with `prrr-queue-mode` (see the facts above for why).
- **prrr-knu.4 (preserved Outbox):** `prrr-db-take-preserved-outbox` returns the rows and clears the variable in one call. The Review Queue announces them once with `display-warning`. The rows stay in the `outbox` table for milestone 4.
- **prrr-knu.1 / .2 (fetch errors):** every fetch takes an ERRORBACK that receives a classified error `(:kind KIND :message STRING :reset-at TIMESTAMP)`. A null `pullRequest` is a `not-found` error and is never persisted. Fetch failures go to the per-repository sync status shown in the section heading (SPEC section 11). Writes and the Outbox arrive in milestone 4.
- **`G` / `prrr-pull`** runs `forge-pull` as well as prrr's own query, so new PRs reach forge's database and appear. The automatic background pull, when the inputs are stale, runs only prrr's cheap query.
- **`RET` on a queue row** opens forge's topic buffer (`prrr-open-topic`) until the Review Buffer lands in milestone 3, which rebinds it to `prrr-review`.

## Global Constraints

- Every `.el` file starts with `;;; NAME.el --- DESCRIPTION  -*- lexical-binding: t -*-`, carries the GPL-3.0-or-later header used by `prrr-db.el`, has `;;; Commentary:` and `;;; Code:` sections and ends with `(provide 'NAME)` and `;;; NAME.el ends here`.
- `prrr.el`'s `Package-Requires` stays exactly `((emacs "29.1") (magit "4.7") (forge "0.5") (emacsql "4.4") (transient "0.13") (compat "31"))`.
- Every symbol starts with `prrr-`; internals use `prrr-FILE--`. Struct constructors are named explicitly and copiers are disabled.
- No `forge--` symbol anywhere in the repository (SPEC 1, quality 4). Only `oref` on forge's classes, `forge-get-*`, `forge-current-pullreq`, `forge-pull`, `forge-query`, `forge-db`, `forge-visit-topic`, `forge-browse-pullreq`, `forge-checkout-pullreq`, `magit-add-section-hook`.
- No `with-eval-after-load` / `eval-after-load` in package code (package-lint fails on them).
- No personal paths, hosts, tokens or logins; tests use `example` names (`example-org`, `example-me`, `example-alice`).
- All SQL lives in `prrr-db.el`; all GitHub calls in `prrr-github.el`; `prrr-state.el` has no buffer, network or forge access.
- Timestamps are ISO 8601 UTC strings (`2026-10-10T12:00:00Z`), compared with `string<`.
- Only Emacs 29.1 APIs: no Emacs 30 `sort` keyword arguments, no `value<`.
- `make compile` (warnings are errors), `make lint` (package-lint + checkdoc) and `make test` must pass before every commit. Every new source file is added to `SRC` in the `Makefile` and every new test file to `TESTS` in the same task that creates it.
- Commit after every task with a conventional message ending with the session's attribution lines. The repository's CLAUDE.md permits commits without approval; never push.
- Every task that changes user-visible behaviour also updates `README.md` in Task 11's structure once it exists. Tasks before Task 11 leave the README to Task 11.

## Review Focus

1. **A pull that keeps failing** (offline, HTTP 401, rate limit, missing `github.user`): the status buffer refreshes after the failure, and that refresh must not start another pull. Retries happen at most once per `prrr-queue-stale-after`, never before a rate limit's reset. Pinned in Task 6 (`prrr-sync-test-due-p-*`, `prrr-sync-test-pull-failure-*`).
2. **The Review Queue must never break magit-status:** any error while gathering or inserting becomes a one-line `Review Queue (error: ...)` section, and the rest of the buffer renders. Pinned in Task 8 (`prrr-queue-test-hook-error-becomes-a-line`).
3. **A repository never pulled, or with no open PRs:** the section shows `For me (0)` and `Mine (0)` headers, collapsed. A pull starts and nothing signals. Pinned in Task 7 (`prrr-queue-test-empty-queue-collapsed`) and Task 8 (`prrr-queue-test-hook-starts-due-pull`).
4. **forge and prrr out of step:** a forge PR with no meta row yet, and a meta row for a PR forge no longer lists as open. Neither signals; the first renders from forge's data alone and the second is ignored. Pinned in Task 8 (`prrr-queue-test-inputs-tolerate-forge-and-meta-drift`).
5. **Long and wide titles in a narrow window:** a row never exceeds the window width when that width is at least 60 columns, including CJK titles, and never computes a negative title width. Pinned in Task 7 (`prrr-queue-test-line-fits-width`).

---

## File structure

| File | Responsibility | Change |
|------|----------------|--------|
| `prrr.el` | `defgroup prrr`; shared PR commands `prrr-open-topic`, `prrr-browse`, `prrr-checkout`; requires nothing from prrr, forge or magit at load. | Modify (Tasks 6, 9) |
| `prrr-db.el` | Adds `prrr-db-take-preserved-outbox`, `prrr-db-replace-pr-metas`, `prrr-db-replace-teams`, `prrr-db-unresolved-thread-counts`. | Modify (Task 4) |
| `prrr-github.el` | Adds `prrr-github-viewer`, `prrr-github-error`; every fetch takes an ERRORBACK; a null PR is `not-found`. | Modify (Task 5) |
| `prrr-state.el` | Stack tie rule, `stack-id` slot, snapshot head rule, `prrr-state-filter-queue`, `prrr-state-stack-neighbour`. | Modify (Tasks 1-3) |
| `prrr-sync.el` | `prrr-queue-stale-after`, per-repository sync status, `prrr-sync-queue-due-p`, `prrr-sync-pull`, `prrr-sync-pull-teams`, commands `prrr-pull`, `prrr-refresh-teams`. | Create (Task 6) |
| `prrr-queue.el` | Options, faces, keymaps, rendering (`prrr-queue-insert`), the section hook function, `prrr-queue-mode`, `prrr-queue`, row lookup and Stack moves. | Create (Tasks 7, 8, 9) |
| `prrr-stack.el` | `prrr-stack-up`, `prrr-stack-down` (queue context now, Review Buffer in milestone 5). | Create (Task 9) |
| `prrr-transient.el` | `prrr-queue-menu` and its toggles. | Create (Task 9) |
| `test/prrr-test-helper.el` | Gains the shared struct builders, an error-answering ghub stub, and a query-dispatching ghub stub. | Modify (Tasks 1, 5, 6) |
| `test/prrr-sync-test.el`, `test/prrr-queue-test.el`, `test/prrr-test.el` | New ERT suites. | Create |
| `bench/prrr-queue-bench.el` | Review Queue render budget (SPEC section 12). | Create (Task 10) |
| `README.md` | What prrr is, status, install, setup, Review Queue usage and keys, options, development. | Create (Task 11) |

Running one test file while working: `make test TESTS=test/prrr-db-test.el`. Running one test: `make test SELECTOR='"prrr-db-test-insert"'`.

---

### Task 1: Stack tie rule and Stack identity (prrr-knu.7)

**Files:**
- Modify: `prrr-state.el` (`prrr-queue-entry` struct, `prrr-state--parent`, `prrr-state--group`)
- Modify: `test/prrr-test-helper.el` (shared builders moved here)
- Modify: `test/prrr-state-test.el`

**Interfaces:**
- Consumes: `prrr-pr`, `prrr-queue-entry`, `prrr-state-stacks`, `prrr-state-queue` (milestone 1).
- Produces: `prrr-queue-entry-stack-id` (string: the `id` of the Stack's bottom PR, shared by every row of one Stack). Test builders `prrr-test-pr`, `prrr-test-meta` and constants `prrr-test-me`, `prrr-test-teams`, `prrr-test-head`, `prrr-test-old` in `test/prrr-test-helper.el`.

- [ ] **Step 1: Move the struct builders into the test helper**

Rename the shared builders so later test files can use them:

```bash
perl -pi -e 's/prrr-state-test--(pr|meta|me|teams|head|old)(?![a-z-])/prrr-test-$1/g' test/prrr-state-test.el
```

Cut the four `defconst`s and the two `cl-defun`s (`prrr-test-me`, `prrr-test-teams`, `prrr-test-head`, `prrr-test-old`, `prrr-test-pr`, `prrr-test-meta`) from the top of `test/prrr-state-test.el`. Paste them into `test/prrr-test-helper.el`, after `prrr-test-fixture`, unchanged apart from the names. Add `(require 'prrr-state)` next to the helper's existing `(require 'prrr-db)`. Add the new names to the helper's Commentary list.

Run: `make test`
Expected: 93 tests pass (pure rename).

- [ ] **Step 2: Write the failing tests**

Append to the Stacks part of `test/prrr-state-test.el`:

```elisp
(ert-deftest prrr-state-test-stacks-tie-picks-oldest-parent ()
  "Two open PRs share the head branch a third PR is based on (prrr-knu.7)."
  (let* ((old (prrr-test-pr :id "OLD" :number 7 :head-ref "shared"
                            :created-at "2026-09-01T00:00:00Z"))
         (new (prrr-test-pr :id "NEW" :number 3 :head-ref "shared" :base-ref "release"
                            :created-at "2026-09-02T00:00:00Z"))
         (child (prrr-test-pr :id "CHILD" :number 9 :base-ref "shared" :head-ref "child")))
    (dolist (prs (list (list old new child) (list child new old) (list new child old)))
      (should (eq old (prrr-state--parent child prs "main"))))))

(ert-deftest prrr-state-test-stacks-tie-on-created-at-picks-lower-number ()
  (let* ((a (prrr-test-pr :id "A" :number 4 :head-ref "shared"))
         (b (prrr-test-pr :id "B" :number 2 :head-ref "shared"))
         (child (prrr-test-pr :id "CHILD" :number 9 :base-ref "shared" :head-ref "child")))
    (should (eq b (prrr-state--parent child (list a b child) "main")))
    (should (eq b (prrr-state--parent child (list b a child) "main")))))

(ert-deftest prrr-state-test-stacks-tie-missing-created-at-counts-as-newest ()
  (let* ((dated (prrr-test-pr :id "DATED" :number 5 :head-ref "shared"))
         (undated (prrr-test-pr :id "UNDATED" :number 1 :head-ref "shared" :created-at nil))
         (child (prrr-test-pr :id "CHILD" :number 9 :base-ref "shared" :head-ref "child")))
    (should (eq dated (prrr-state--parent child (list undated dated child) "main")))))

(ert-deftest prrr-state-test-queue-entries-carry-stack-id ()
  (let* ((prs (list (prrr-test-pr :id "BOTTOM" :head-ref "step-1")
                    (prrr-test-pr :id "TOP" :base-ref "step-1" :head-ref "step-2")
                    (prrr-test-pr :id "LONE" :head-ref "lone")))
         (metas (mapcar (lambda (id) (prrr-test-meta :pr-id id :review-requests '((user "example-me"))))
                        '("BOTTOM" "TOP" "LONE")))
         (entries (plist-get (prrr-state-test--queue prs metas) :for-me)))
    (should (equal '(("BOTTOM" . "BOTTOM") ("TOP" . "BOTTOM") ("LONE" . "LONE"))
                   (mapcar (lambda (e) (cons (prrr-pr-id (prrr-queue-entry-pr e))
                                             (prrr-queue-entry-stack-id e)))
                           entries)))))
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `make test TESTS=test/prrr-state-test.el SELECTOR='"tie\\|stack-id"'`
Expected: the tie tests FAIL (the parent depends on input order). `queue-entries-carry-stack-id` FAILS with `invalid-function` or `wrong-type-argument` on `prrr-queue-entry-stack-id`.

- [ ] **Step 4: Implement**

In `prrr-state.el`, add the slot and document it. The docstring sentence goes after the STACK-SIZE sentence:

```elisp
(cl-defstruct (prrr-queue-entry (:constructor prrr-queue-entry-create)
                                (:copier nil))
  "One row of the Review Queue.
PR is the `prrr-pr'.  STATE is the Review State (For Me) or Mine state,
nil for a dimmed context row.  GROUP is `for-me' or `mine'.  PARTITION
is `awaiting' or `served' in For Me, nil in Mine.  STACK-POS is the
1-based position of PR in its Stack, bottom first, and STACK-SIZE the
Stack's length (1 for a lone PR).  STACK-ID is the `id' of the Stack's
bottom PR, shared by every row of one Stack.  DIMMED-P marks a row
shown only for context: a non-qualifying Stack member or a draft
requested from me."
  pr state group partition stack-pos stack-size stack-id dimmed-p)
```

Replace `prrr-state--parent` and add `prrr-state--older-p` just above it:

```elisp
(defun prrr-state--older-p (a b)
  "Non-nil when PR A was opened before PR B.
Creation time decides, a PR without one counting as the newest; the
lower PR number breaks a tie."
  (let ((created-a (prrr-pr-created-at a))
        (created-b (prrr-pr-created-at b)))
    (cond ((and created-a created-b (not (equal created-a created-b)))
           (string< created-a created-b))
          ((and created-a (not created-b)) t)
          ((and created-b (not created-a)) nil)
          (t (< (or (prrr-pr-number a) 0) (or (prrr-pr-number b) 0))))))

(defun prrr-state--parent (pr prs default-branch)
  "Return the PR in PRS that PR is stacked on, or nil.
The parent is a PR whose `head-ref' equals PR's `base-ref' and that is
not from a fork.  When several open PRs have that head branch, the
oldest one is the parent (see `prrr-state--older-p'), so the answer
does not depend on the order of PRS.  A PR based on DEFAULT-BRANCH, or
on a branch no open PR has as its head, has no parent."
  (let ((base (prrr-pr-base-ref pr)))
    (and base
         (not (equal base default-branch))
         (car (sort (seq-filter (lambda (candidate)
                                  (and (not (eq candidate pr))
                                       (not (prrr-pr-cross-repo-p candidate))
                                       (equal (prrr-pr-head-ref candidate) base)))
                                prs)
                    #'prrr-state--older-p)))))
```

In `prrr-state--group`, stamp the Stack's identity on every pair before keeping it. Replace the `pairs` binding:

```elisp
             (pairs (delq nil (cl-loop for pr in stack
                                       for pos from 1
                                       collect (funcall make pr pos size))))
```

with:

```elisp
             (pairs (delq nil (cl-loop for pr in stack
                                       for pos from 1
                                       collect (funcall make pr pos size))))
             (_ (dolist (pair pairs)
                  (setf (prrr-queue-entry-stack-id (cdr pair))
                        (prrr-pr-id (car stack)))))
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `make test`
Expected: 97 tests pass.

- [ ] **Step 6: Compile, lint, close the bead, commit**

```bash
make compile lint
bd close prrr-knu.7 --reason="Oldest PR wins a head-branch tie (created-at, then number); documented in prrr-state--parent and pinned by three tests"
git add prrr-state.el test/prrr-state-test.el test/prrr-test-helper.el
git commit -m "feat(state): oldest PR wins a Stack tie; entries carry their Stack id"
```

---

### Task 2: Review State compares against the snapshot head (prrr-knu.3)

**Files:**
- Modify: `prrr-state.el` (`prrr-pr` docstring, new `prrr-state--head-oid`, `prrr-state-review-state`)
- Modify: `test/prrr-state-test.el`
- Modify: `SPEC.md` section 5

**Interfaces:**
- Consumes: `prrr-pr-meta-head-oid`, `prrr-pr-head-oid`.
- Produces: no new public names. `prrr-state-review-state` now judges `new-commits` against META's head when META has one.

- [ ] **Step 1: Write the failing tests**

Append to the Review State part of `test/prrr-state-test.el`:

```elisp
(ert-deftest prrr-state-test-review-state-uses-meta-head-over-forge-head ()
  "forge's head moved but prrr's snapshot still shows my reviewed commit (prrr-knu.3)."
  (should (eq 'approved
              (prrr-state-test--state
               (prrr-test-pr :head-oid prrr-test-head)
               (prrr-test-meta :head-oid prrr-test-old
                               :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z"
                                                           prrr-test-old))))))

(ert-deftest prrr-state-test-review-state-meta-head-moved-is-new-commits ()
  "prrr's snapshot shows a push forge has not seen yet."
  (should (eq 'new-commits
              (prrr-state-test--state
               (prrr-test-pr :head-oid prrr-test-old)
               (prrr-test-meta :head-oid prrr-test-head
                               :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z"
                                                           prrr-test-old))))))

(ert-deftest prrr-state-test-review-state-without-meta-head-falls-back-to-forge ()
  (should (eq 'new-commits
              (prrr-state-test--state
               (prrr-test-pr :head-oid prrr-test-head)
               (prrr-test-meta :head-oid nil
                               :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z"
                                                           prrr-test-old))))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test TESTS=test/prrr-state-test.el SELECTOR='"meta-head\\|forge-head"'`
Expected: the first two FAIL (`new-commits` instead of `approved`, and `approved` instead of `new-commits`). The third passes already.

- [ ] **Step 3: Implement**

In `prrr-state.el`, add above `prrr-state-review-state`:

```elisp
(defun prrr-state--head-oid (pr meta)
  "Return the head commit PR's Review State is judged against.
That is META's head-oid when META has one: it was fetched by the same
query as the viewer's latest review, so the two are one snapshot and
forge's separate fetch cadence cannot fake `new-commits'.  Without it,
PR's head-oid from forge."
  (or (and meta (prrr-pr-meta-head-oid meta))
      (prrr-pr-head-oid pr)))
```

In `prrr-state-review-state` replace `(prrr-pr-head-oid pr)` with `(prrr-state--head-oid pr meta)`.

In the `prrr-pr` docstring, replace the first sentence block's end with this sentence about HEAD-OID:

```
HEAD-OID is forge's head-rev; the Review State prefers the head stored
in the PR's `prrr-pr-meta' (see `prrr-state--head-oid').
```

- [ ] **Step 4: Update SPEC.md section 5**

Replace `` `new-commits` (the viewer's latest submitted review commit differs from head) `` with:

```
`new-commits` (the viewer's latest submitted review commit differs from
the head oid stored with it in `pullreq-meta`; forge's head is used only
for a PR prrr has not pulled yet, prrr-knu.3)
```

- [ ] **Step 5: Run all gates**

Run: `make compile lint test`
Expected: 100 tests pass, no warnings.

- [ ] **Step 6: Record the decision, close the bead, commit**

```bash
bd update prrr-knu.3 --notes="Decision: compare the viewer's latest review commit against prrr-pr-meta-head-oid (same query, same snapshot). forge's head-rev is used only when no meta row exists, in which case there is no review to compare. Implemented in prrr-state--head-oid; SPEC section 5 updated."
bd close prrr-knu.3 --reason="new-commits judged against the meta snapshot head"
git add prrr-state.el test/prrr-state-test.el SPEC.md
git commit -m "feat(state): judge new-commits against the head fetched with the review"
```

---

### Task 3: Display filters and Stack neighbours (prrr-knu.5, pure side)

**Files:**
- Modify: `prrr-state.el` (new section `;;;; Display` after queue assembly)
- Modify: `test/prrr-state-test.el`

**Interfaces:**
- Consumes: `prrr-queue-entry` with `stack-id` (Task 1).
- Produces:
  - `(prrr-state-filter-queue ENTRIES &key (show-drafts t) (show-served t))` → list of `prrr-queue-entry`, order kept.
  - `(prrr-state-stack-neighbour ENTRIES ENTRY DIRECTION)` → `prrr-queue-entry` or nil; DIRECTION is `up` or `down`.

- [ ] **Step 1: Write the failing tests**

Append to `test/prrr-state-test.el`:

```elisp
;;;; Display filters and Stack neighbours

(defun prrr-state-test--entry (id &rest slots)
  "Build a queue entry for a PR with ID; SLOTS are entry keyword arguments."
  (apply #'prrr-queue-entry-create
         :pr (prrr-test-pr :id id :draft-p (plist-get slots :draft))
         (cl-loop for (key value) on slots by #'cddr
                  unless (eq key :draft) append (list key value))))

(ert-deftest prrr-state-test-filter-keeps-everything-by-default ()
  (let ((entries (list (prrr-state-test--entry "A" :state 'requested :partition 'awaiting :stack-id "A")
                       (prrr-state-test--entry "B" :state 'approved :partition 'served :stack-id "B"))))
    (should (equal entries (prrr-state-filter-queue entries)))))

(ert-deftest prrr-state-test-filter-hides-served ()
  (let* ((a (prrr-state-test--entry "A" :state 'requested :partition 'awaiting :stack-id "A"))
         (b (prrr-state-test--entry "B" :state 'approved :partition 'served :stack-id "B")))
    (should (equal (list a) (prrr-state-filter-queue (list a b) :show-served nil)))))

(ert-deftest prrr-state-test-filter-hides-drafts ()
  (let* ((a (prrr-state-test--entry "A" :state 'requested :partition 'awaiting :stack-id "A"))
         (d (prrr-state-test--entry "D" :draft t :state 'requested :partition 'served
                                    :dimmed-p t :stack-id "D")))
    (should (equal (list a) (prrr-state-filter-queue (list a d) :show-drafts nil)))))

(ert-deftest prrr-state-test-filter-drops-stack-left-with-only-context-rows ()
  "Hiding the only qualifying member leaves no reason to show its Stack."
  (let* ((context (prrr-state-test--entry "BOTTOM" :stack-id "BOTTOM" :stack-pos 1 :stack-size 2
                                          :dimmed-p t))
         (served (prrr-state-test--entry "TOP" :state 'approved :partition 'served
                                         :stack-id "BOTTOM" :stack-pos 2 :stack-size 2)))
    (should (null (prrr-state-filter-queue (list context served) :show-served nil)))
    (should (equal (list context served) (prrr-state-filter-queue (list context served))))))

(ert-deftest prrr-state-test-stack-neighbour-up-and-down ()
  (let* ((one (prrr-state-test--entry "ONE" :stack-id "ONE" :stack-pos 1 :stack-size 3))
         (two (prrr-state-test--entry "TWO" :stack-id "ONE" :stack-pos 2 :stack-size 3))
         (three (prrr-state-test--entry "THREE" :stack-id "ONE" :stack-pos 3 :stack-size 3))
         (other (prrr-state-test--entry "OTHER" :stack-id "OTHER" :stack-pos 1 :stack-size 1))
         (entries (list one two three other)))
    (should (eq two (prrr-state-stack-neighbour entries one 'up)))
    (should (eq three (prrr-state-stack-neighbour entries two 'up)))
    (should (null (prrr-state-stack-neighbour entries three 'up)))
    (should (eq two (prrr-state-stack-neighbour entries three 'down)))
    (should (null (prrr-state-stack-neighbour entries one 'down)))
    (should (null (prrr-state-stack-neighbour entries other 'up)))))

(ert-deftest prrr-state-test-stack-neighbour-skips-hidden-rows ()
  "Position 2 is not displayed, so up from 1 lands on 3."
  (let* ((one (prrr-state-test--entry "ONE" :stack-id "ONE" :stack-pos 1 :stack-size 3))
         (three (prrr-state-test--entry "THREE" :stack-id "ONE" :stack-pos 3 :stack-size 3)))
    (should (eq three (prrr-state-stack-neighbour (list one three) one 'up)))
    (should (eq one (prrr-state-stack-neighbour (list one three) three 'down)))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test TESTS=test/prrr-state-test.el SELECTOR='"filter\\|neighbour"'`
Expected: FAIL with `void-function prrr-state-filter-queue` / `prrr-state-stack-neighbour`.

- [ ] **Step 3: Implement**

Append to `prrr-state.el` before `(provide 'prrr-state)`:

```elisp
;;;; Display

(cl-defun prrr-state-filter-queue (entries &key (show-drafts t) (show-served t))
  "Return ENTRIES without the rows the viewer chose to hide.
ENTRIES is one Queue Group from `prrr-state-queue'.  Unless
SHOW-DRAFTS, rows of draft PRs are dropped; unless SHOW-SERVED, rows in
the Served partition are dropped.  A Stack left with only context rows
\(rows without a state) is dropped entirely, so no row is shown without
a reason.  Kept rows keep their order, STACK-POS and STACK-SIZE: a
Stack's visible rows need not be contiguous positions."
  (let* ((kept (seq-remove
                (lambda (entry)
                  (or (and (not show-drafts)
                           (prrr-pr-draft-p (prrr-queue-entry-pr entry)))
                      (and (not show-served)
                           (eq (prrr-queue-entry-partition entry) 'served))))
                entries))
         (live (mapcar #'prrr-queue-entry-stack-id
                       (seq-filter #'prrr-queue-entry-state kept))))
    (seq-filter (lambda (entry) (member (prrr-queue-entry-stack-id entry) live))
                kept)))

(defun prrr-state-stack-neighbour (entries entry direction)
  "Return the row of ENTRIES next to ENTRY in its Stack, or nil.
DIRECTION `up' finds the nearest row above ENTRY (higher STACK-POS),
`down' the nearest below.  ENTRIES are the rows of one displayed Queue
Group, so rows the viewer hid are skipped."
  (let* ((pos (prrr-queue-entry-stack-pos entry))
         (up (eq direction 'up))
         (candidates
          (seq-filter (lambda (other)
                        (and (equal (prrr-queue-entry-stack-id other)
                                    (prrr-queue-entry-stack-id entry))
                             (if up
                                 (> (prrr-queue-entry-stack-pos other) pos)
                               (< (prrr-queue-entry-stack-pos other) pos))))
                      entries)))
    (car (sort candidates
               (lambda (a b)
                 (funcall (if up #'< #'>)
                          (prrr-queue-entry-stack-pos a)
                          (prrr-queue-entry-stack-pos b)))))))
```

Update the Commentary of `prrr-state.el`: add "the display filters, and Stack neighbours" to the list of what the file implements.

- [ ] **Step 4: Run all gates**

Run: `make compile lint test`
Expected: 106 tests pass.

- [ ] **Step 5: Commit**

```bash
git add prrr-state.el test/prrr-state-test.el
git commit -m "feat(state): display filters for drafts and Served; Stack neighbours"
```

---

### Task 4: Database additions for the queue (prrr-knu.4, data side)

**Files:**
- Modify: `prrr-db.el`
- Modify: `test/prrr-db-test.el`

**Interfaces:**
- Consumes: `prrr-db`, `prrr-db-delete`, `prrr-db--struct-to-row`, `prrr-db-preserved-outbox`.
- Produces:
  - `(prrr-db-take-preserved-outbox)` → list of `prrr-outbox`, then nil on the next call.
  - `(prrr-db-replace-pr-metas FORGE-REPO-ID METAS)` → nil.
  - `(prrr-db-replace-teams TEAMS)` → nil.
  - `(prrr-db-unresolved-thread-counts PR-IDS)` → hash table (`equal`) from PR id to integer count, ids without unresolved Threads absent.

- [ ] **Step 1: Write the failing tests**

Append to `test/prrr-db-test.el`:

```elisp
;;;; Queue additions

(ert-deftest prrr-db-test-take-preserved-outbox-returns-once ()
  (let ((prrr-db-preserved-outbox (list (prrr-outbox-create :id "o1" :kind 'comment))))
    (should (equal '("o1") (mapcar #'prrr-outbox-id (prrr-db-take-preserved-outbox))))
    (should (null prrr-db-preserved-outbox))
    (should (null (prrr-db-take-preserved-outbox)))))

(ert-deftest prrr-db-test-replace-pr-metas-replaces-only-that-repository ()
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-pr-meta-create :pr-id "CLOSED" :forge-repo-id "repo-a"))
    (prrr-db-insert (prrr-pr-meta-create :pr-id "OTHER" :forge-repo-id "repo-b"))
    (prrr-db-replace-pr-metas "repo-a"
                              (list (prrr-pr-meta-create :pr-id "OPEN-1" :forge-repo-id "repo-a")
                                    (prrr-pr-meta-create :pr-id "OPEN-2" :forge-repo-id "repo-a")))
    (should (equal '("OPEN-1" "OPEN-2")
                   (mapcar #'prrr-pr-meta-pr-id
                           (prrr-db-select 'pullreq-meta :forge-repo-id "repo-a"))))
    (should (prrr-db-get 'pullreq-meta "OTHER"))))

(ert-deftest prrr-db-test-replace-pr-metas-with-none-empties-the-repository ()
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-pr-meta-create :pr-id "CLOSED" :forge-repo-id "repo-a"))
    (prrr-db-replace-pr-metas "repo-a" nil)
    (should (null (prrr-db-select 'pullreq-meta :forge-repo-id "repo-a")))))

(ert-deftest prrr-db-test-replace-teams ()
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-team-create :combined-slug "example-org/old"))
    (prrr-db-replace-teams (list (prrr-team-create :combined-slug "example-org/new")))
    (should (equal '("example-org/new")
                   (mapcar #'prrr-team-combined-slug (prrr-db-select 'team))))))

(ert-deftest prrr-db-test-unresolved-thread-counts ()
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-thread-create :thread-id "t1" :pr-id "P1" :resolved-p nil))
    (prrr-db-insert (prrr-thread-create :thread-id "t2" :pr-id "P1" :resolved-p nil))
    (prrr-db-insert (prrr-thread-create :thread-id "t3" :pr-id "P1" :resolved-p t))
    (prrr-db-insert (prrr-thread-create :thread-id "t4" :pr-id "P2" :resolved-p t))
    (prrr-db-insert (prrr-thread-create :thread-id "t5" :pr-id "P3" :resolved-p nil))
    (let ((counts (prrr-db-unresolved-thread-counts '("P1" "P2"))))
      (should (= 2 (gethash "P1" counts)))
      (should (null (gethash "P2" counts)))
      (should (null (gethash "P3" counts))))
    (should (zerop (hash-table-count (prrr-db-unresolved-thread-counts nil))))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test TESTS=test/prrr-db-test.el SELECTOR='"take\\|replace\\|unresolved"'`
Expected: FAIL with `void-function`.

- [ ] **Step 3: Implement**

Append to `prrr-db.el` before `(provide 'prrr-db)`:

```elisp
;;;; Queue inputs

(defun prrr-db-take-preserved-outbox ()
  "Return the Outbox rows kept by the last schema reset, and forget them.
Each row is handed out once, so whoever shows them to the user calls
this and nothing is announced twice.  The rows stay in the `outbox'
table."
  (prog1 prrr-db-preserved-outbox
    (setq prrr-db-preserved-outbox nil)))

(defun prrr-db-replace-pr-metas (forge-repo-id metas)
  "Make METAS the only `pullreq-meta' rows of FORGE-REPO-ID.
METAS are the repository's open PRs, so rows of PRs that closed since
the last pull disappear.  One transaction."
  (let ((db (prrr-db)))
    (emacsql-with-transaction db
      (prrr-db-delete 'pullreq-meta :forge-repo-id forge-repo-id)
      (when metas
        (emacsql db [:insert-or-replace :into pullreq-meta :values $v1]
                 (mapcar #'prrr-db--struct-to-row metas))))
    nil))

(defun prrr-db-replace-teams (teams)
  "Make TEAMS, a list of `prrr-team', the viewer's only Teams.  One transaction."
  (let ((db (prrr-db)))
    (emacsql-with-transaction db
      (prrr-db-delete 'team)
      (when teams
        (emacsql db [:insert-or-replace :into team :values $v1]
                 (mapcar #'prrr-db--struct-to-row teams))))
    nil))

(defun prrr-db-unresolved-thread-counts (pr-ids)
  "Return a hash table from each of PR-IDS to its number of unresolved Threads.
A PR with no unresolved Thread, or whose Threads were never fetched, is
absent from the table."
  (let ((counts (make-hash-table :test #'equal)))
    (when pr-ids
      (pcase-dolist (`(,pr-id ,count)
                     (emacsql (prrr-db)
                              [:select [pr-id (funcall count *)] :from thread
                               :where (and (in pr-id $v1) (isnull resolved-p))
                               :group-by pr-id]
                              (vconcat pr-ids)))
        (puthash pr-id count counts)))
    counts))
```

In the docstring of `prrr-db-preserved-outbox`, replace "nothing in this file reads it" with "`prrr-db-take-preserved-outbox' hands the rows out once".

- [ ] **Step 4: Run all gates**

Run: `make compile lint test`
Expected: 111 tests pass.

- [ ] **Step 5: Commit**

```bash
git add prrr-db.el test/prrr-db-test.el
git commit -m "feat(db): replace queue inputs per repository, unresolved counts, take preserved Outbox once"
```

(`prrr-knu.4` closes in Task 8, where the rows are shown.)

---

### Task 5: Fetch errors, null PRs and the viewer login (prrr-knu.1, prrr-knu.2)

**Files:**
- Modify: `prrr-github.el`
- Modify: `test/prrr-test-helper.el` (error stub)
- Modify: `test/prrr-github-test.el`

**Interfaces:**
- Consumes: `prrr-github--query`, the three decoders.
- Produces:
  - `(prrr-github-viewer)` → login string or nil.
  - `(prrr-github-error ERR &optional HEADERS NOW)` → plist `(:kind KIND :message STRING :reset-at TIMESTAMP-OR-NIL)`. KIND is one of `rate-limited auth not-found offline error`.
  - New signatures (ERRORBACK is a function of one classified error plist):
    - `(prrr-github-fetch-queue HOST OWNER NAME CALLBACK ERRORBACK &optional FORGE-REPO-ID)`
    - `(prrr-github-fetch-teams HOST ME CALLBACK ERRORBACK)`
    - `(prrr-github-fetch-review-data HOST OWNER NAME NUMBER ME CALLBACK ERRORBACK)`
  - `prrr-github-decode-review-data` returns nil when the response has no `pullRequest`.
  - Test macro `(prrr-test-with-ghub-error-stub ERR HEADERS &rest BODY)`.

- [ ] **Step 1: Add the error stub to the test helper**

Append to `test/prrr-test-helper.el` after `prrr-test-with-ghub-stub`:

```elisp
(defmacro prrr-test-with-ghub-error-stub (err headers &rest body)
  "Run BODY with `ghub-query' failing every request with ERR and HEADERS.
The errorback runs synchronously, as ghub calls it: with ERR, HEADERS,
a nil status and a nil request.  A request without an errorback fails
the test, because ghub would signal."
  (declare (indent 2) (debug (form form body)))
  `(cl-letf (((symbol-function 'ghub-query)
              (lambda (_query _variables &rest args)
                (let ((errorback (plist-get args :errorback)))
                  (unless errorback
                    (ert-fail "request sent without an errorback"))
                  (funcall errorback ,err ,headers nil nil)))))
     ,@body))
```

Mention the macro in the helper's Commentary.

- [ ] **Step 2: Update the existing fetch tests to the new signatures**

In `test/prrr-github-test.el`, every call to `prrr-github-fetch-queue`, `prrr-github-fetch-teams` and `prrr-github-fetch-review-data` gains an errorback right after its callback: `(lambda (err) (ert-fail (list "unexpected errorback" err)))`. For example:

```elisp
      (prrr-github-fetch-review-data "api.github.com" "example-org" "example-repo" 1
                                     "example-me" (lambda (data) (setq result data))
                                     (lambda (err) (ert-fail (list "unexpected errorback" err))))
```

- [ ] **Step 3: Write the failing tests**

Append to `test/prrr-github-test.el`:

```elisp
;;;; Errors (prrr-knu.1, prrr-knu.2)

(defconst prrr-github-test--now (encode-time '(0 0 12 10 10 2026 nil nil t))
  "2026-10-10T12:00:00Z as a Lisp time.")

(ert-deftest prrr-github-test-error-graphql-rate-limited ()
  (should (equal '(:kind rate-limited :message "API rate limit exceeded"
                   :reset-at "2026-10-10T12:30:00Z")
                 (prrr-github-error
                  '(errors ((type . "RATE_LIMITED") (message . "API rate limit exceeded")))
                  '(("X-RateLimit-Reset" . "1791635400"))
                  prrr-github-test--now))))

(ert-deftest prrr-github-test-error-graphql-not-found ()
  (should (eq 'not-found
              (plist-get (prrr-github-error
                          '(errors ((type . "NOT_FOUND")
                                    (message . "Could not resolve to a PullRequest with the number of 9."))))
                         :kind))))

(ert-deftest prrr-github-test-error-graphql-other-keeps-first-message ()
  (should (equal '(:kind error :message "Something broke" :reset-at nil)
                 (prrr-github-error '(errors ((message . "Something broke")) ((message . "And more")))))))

(ert-deftest prrr-github-test-error-http-401-is-auth ()
  (should (eq 'auth (plist-get (prrr-github-error '(error http 401)) :kind))))

(ert-deftest prrr-github-test-error-http-403-without-limit-headers-is-auth ()
  (should (eq 'auth (plist-get (prrr-github-error '(error http 403) '(("x-ratelimit-remaining" . "12")))
                               :kind))))

(ert-deftest prrr-github-test-error-http-403-secondary-limit-uses-retry-after ()
  (should (equal '(:kind rate-limited :message "GitHub rate limit (HTTP 403)"
                   :reset-at "2026-10-10T12:01:30Z")
                 (prrr-github-error '(error http 403) '(("retry-after" . "90"))
                                    prrr-github-test--now))))

(ert-deftest prrr-github-test-error-rate-limit-without-headers-waits-a-minute ()
  (should (equal "2026-10-10T12:01:00Z"
                 (plist-get (prrr-github-error '(errors ((type . "RATE_LIMITED") (message . "slow down")))
                                               nil prrr-github-test--now)
                            :reset-at))))

(ert-deftest prrr-github-test-error-http-502-is-offline ()
  (should (eq 'offline (plist-get (prrr-github-error '(error http 502)) :kind))))

(ert-deftest prrr-github-test-error-connection-failed-is-offline ()
  (let ((classified (prrr-github-error '(error connection-failed "failed with code 111\n"
                                               :host "api.github.com" :service 443))))
    (should (eq 'offline (plist-get classified :kind)))
    (should (string-match-p "connection-failed" (plist-get classified :message)))))

(ert-deftest prrr-github-test-error-unknown-shape-is-error ()
  (should (eq 'error (plist-get (prrr-github-error 'surprise) :kind))))

(ert-deftest prrr-github-test-fetch-queue-failure-reaches-errorback ()
  (prrr-test-with-ghub-error-stub '(error http 502) nil
    (let (failure)
      (prrr-github-fetch-queue "api.github.com" "example-org" "example-repo"
                               (lambda (_) (ert-fail "callback on failure"))
                               (lambda (err) (setq failure err)))
      (should (eq 'offline (plist-get failure :kind))))))

(ert-deftest prrr-github-test-fetch-teams-failure-reaches-errorback ()
  (prrr-test-with-ghub-error-stub '(error http 401) nil
    (let (failure)
      (prrr-github-fetch-teams "api.github.com" "example-me"
                               (lambda (_) (ert-fail "callback on failure"))
                               (lambda (err) (setq failure err)))
      (should (eq 'auth (plist-get failure :kind))))))

(ert-deftest prrr-github-test-decode-review-data-null-pull-request ()
  (should (null (prrr-github-decode-review-data '(data (repository (pullRequest))) nil))))

(ert-deftest prrr-github-test-fetch-review-data-null-pull-request-is-not-found ()
  "GitHub answered without errors but with a null pullRequest (prrr-knu.2)."
  (prrr-test-with-ghub-stub '(data (repository (pullRequest))) _captured
    (let (failure)
      (prrr-github-fetch-review-data "api.github.com" "example-org" "example-repo" 9 "example-me"
                                     (lambda (_) (ert-fail "null PR reached the callback"))
                                     (lambda (err) (setq failure err)))
      (should (eq 'not-found (plist-get failure :kind)))
      (should (string-match-p "example-org/example-repo#9" (plist-get failure :message))))))

;;;; Viewer

(ert-deftest prrr-github-test-viewer-option-wins ()
  (let ((prrr-github-user "example-me"))
    (cl-letf (((symbol-function 'magit-get) (lambda (&rest _) "example-other")))
      (should (equal "example-me" (prrr-github-viewer))))))

(ert-deftest prrr-github-test-viewer-falls-back-to-git-config ()
  (let ((prrr-github-user nil))
    (cl-letf (((symbol-function 'magit-get)
               (lambda (&rest keys) (and (equal keys '("github.user")) "example-me"))))
      (should (equal "example-me" (prrr-github-viewer))))))
```

The reset epoch `1791635400` is 2026-10-10T12:30:00Z (checked with `date -u -d 2026-10-10T12:30:00Z +%s`).

- [ ] **Step 4: Run the tests to verify they fail**

Run: `make test TESTS=test/prrr-github-test.el`
Expected: the new tests FAIL with `void-function prrr-github-error` / `prrr-github-viewer` or a wrong number of arguments. The updated old fetch tests FAIL with `wrong-number-of-arguments`.

- [ ] **Step 5: Implement**

In `prrr-github.el`, add after the `prrr-github-user` defcustom:

```elisp
(defun prrr-github-viewer ()
  "Return the viewer's GitHub login, or nil when none is configured.
`prrr-github-user' wins; otherwise the `github.user' Git variable of
the current repository, which is where forge reads it."
  (or prrr-github-user (magit-get "github.user")))
```

Add a new section before `;;;; Requests`:

```elisp
;;;; Errors

(defun prrr-github--header (headers name)
  "Return the value of response header NAME in HEADERS, ignoring case."
  (cdr (assoc-string name headers t)))

(defun prrr-github--reset-at (headers now)
  "Return when the rate limit described by HEADERS ends, as a timestamp.
Uses x-ratelimit-reset (epoch seconds) or retry-after (seconds after
NOW, a Lisp time); without either, one minute after NOW."
  (let ((reset (prrr-github--header headers "x-ratelimit-reset"))
        (retry (prrr-github--header headers "retry-after")))
    (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                        (cond (reset (string-to-number reset))
                              (retry (time-add now (string-to-number retry)))
                              (t (time-add now 60)))
                        t)))

(defun prrr-github-error (err &optional headers now)
  "Classify ERR, a failed request, as (:kind KIND :message TEXT :reset-at TIME).
ERR is what ghub hands an errorback: (errors ERROR...) for GraphQL
errors, (error http CODE) for HTTP failures, (error SYMBOL ...) for
transport failures.  HEADERS is the response header alist; NOW, a Lisp
time defaulting to the current time, anchors a retry-after delay.
KIND is one of:
  `rate-limited'  a primary or secondary limit; RESET-AT says when it ends;
  `auth'          the token was rejected;
  `not-found'     the repository or pull request does not exist;
  `offline'       no connection or a server error, worth retrying later;
  `error'         anything else.
RESET-AT is nil unless KIND is `rate-limited'."
  (let ((now (or now (current-time))))
    (pcase err
      (`(errors . ,errors)
       (let ((types (mapcar (lambda (error) (alist-get 'type error)) errors))
             (text (or (alist-get 'message (car errors)) "GitHub GraphQL error")))
         (cond ((member "RATE_LIMITED" types)
                (list :kind 'rate-limited :message text
                      :reset-at (prrr-github--reset-at headers now)))
               ((member "NOT_FOUND" types)
                (list :kind 'not-found :message text :reset-at nil))
               (t (list :kind 'error :message text :reset-at nil)))))
      (`(error http ,code . ,_)
       (cond ((and (memq code '(403 429))
                   (or (equal (prrr-github--header headers "x-ratelimit-remaining") "0")
                       (prrr-github--header headers "retry-after")))
              (list :kind 'rate-limited
                    :message (format "GitHub rate limit (HTTP %d)" code)
                    :reset-at (prrr-github--reset-at headers now)))
             ((memq code '(401 403))
              (list :kind 'auth
                    :message (format "GitHub rejected the token (HTTP %d)" code)
                    :reset-at nil))
             ((eq code 404)
              (list :kind 'not-found :message "GitHub returned HTTP 404" :reset-at nil))
             (t (list :kind 'offline
                      :message (format "GitHub returned HTTP %s" code)
                      :reset-at nil))))
      (`(error . ,data)
       (list :kind 'offline
             :message (format "Cannot reach GitHub: %s"
                              (string-trim (mapconcat (lambda (part) (format "%s" part))
                                                      data " ")))
             :reset-at nil))
      (_ (list :kind 'error :message (format "Unexpected GitHub failure: %S" err)
               :reset-at nil)))))

(defun prrr-github--errorback (errorback)
  "Return a ghub errorback that hands ERRORBACK the classified error."
  (lambda (err headers &rest _)
    (funcall errorback (prrr-github-error err headers))))
```

Make `prrr-github-decode-review-data` return nil for a missing PR: wrap its body as `(let-alist (cdr (assq 'repository data)) (when .pullRequest (let ((decoded ...)) ...)))`. Add to its docstring: "Return nil when DATA has no pull request (deleted, or a wrong number)."

Replace the three request functions:

```elisp
(defun prrr-github-fetch-queue (host owner name callback errorback &optional forge-repo-id)
  "Fetch the Review Queue inputs of OWNER/NAME on HOST.
CALLBACK receives a list of `prrr-pr-meta' stamped with the current
time and FORGE-REPO-ID.  ERRORBACK receives a failure classified by
`prrr-github-error'; exactly one of the two is called."
  (prrr-github--query host prrr-github-queue-query
    ((owner owner) (name name))
    :callback (lambda (data &rest _)
                (funcall callback
                         (prrr-github-decode-queue data forge-repo-id
                                                   (prrr-github--now))))
    :errorback (prrr-github--errorback errorback)))

(defun prrr-github-fetch-teams (host me callback errorback)
  "Fetch the Teams of the viewer ME on HOST.
CALLBACK receives a list of `prrr-team' stamped with the current time.
ERRORBACK receives a failure classified by `prrr-github-error'."
  (prrr-github--query host prrr-github-teams-query
    ((me (vector me)))
    :callback (lambda (data &rest _)
                (funcall callback
                         (prrr-github-decode-teams data (prrr-github--now))))
    :errorback (prrr-github--errorback errorback)))

(defun prrr-github-fetch-review-data (host owner name number me callback errorback)
  "Fetch Threads, Pending Review, Viewed flags and head of OWNER/NAME#NUMBER.
HOST is the API host; ME the viewer's login, used to find the Pending
Review.  CALLBACK receives the plist of `prrr-github-decode-review-data'
with rows stamped with the current time.  ERRORBACK receives a failure
classified by `prrr-github-error'; a response without the pull request
is a `not-found' failure and never reaches CALLBACK."
  (prrr-github--query host prrr-github-review-data-query
    ((owner owner) (name name) (number number) (me me))
    :callback (lambda (data &rest _)
                (let* ((pr-id (alist-get 'id (alist-get 'pullRequest
                                                        (cdr (assq 'repository data)))))
                       (decoded (prrr-github-decode-review-data data pr-id
                                                                (prrr-github--now))))
                  (if decoded
                      (funcall callback decoded)
                    (funcall errorback
                             (list :kind 'not-found
                                   :message (format "Pull request %s/%s#%s not found"
                                                    owner name number)
                                   :reset-at nil)))))
    :errorback (prrr-github--errorback errorback)))
```

In the Commentary, replace "Mutations arrive in milestone 4; this file is read-only until then." with: "Every request takes an ERRORBACK that receives a failure classified by `prrr-github-error'; ghub's own error shapes never leave this file.  Mutations arrive in milestone 4."

- [ ] **Step 6: Run all gates**

Run: `make compile lint test`
Expected: 127 tests pass.

- [ ] **Step 7: Close the beads and commit**

```bash
bd close prrr-knu.1 --reason="Every fetch takes an ERRORBACK receiving a prrr-github-error classification; sync status consumes it (Task 6)"
bd close prrr-knu.2 --reason="decode-review-data returns nil for a null pullRequest; fetch-review-data routes it to the errorback as not-found"
git add prrr-github.el test/prrr-github-test.el test/prrr-test-helper.el
git commit -m "feat(github): classified errorbacks on every fetch; null PR is not-found; viewer login"
```

---

### Task 6: `prrr-sync.el`: when to pull, pulling, and status

**Files:**
- Create: `prrr-sync.el`
- Create: `test/prrr-sync-test.el`
- Modify: `prrr.el` (remove `prrr-queue-stale-after`, which moves here)
- Modify: `test/prrr-test-helper.el` (dispatching stub)
- Modify: `Makefile` (`SRC` gains `prrr-sync.el` after `prrr-state.el`; `TESTS` gains `test/prrr-sync-test.el`)

**Interfaces:**
- Consumes: `prrr-github-viewer`, `prrr-github-fetch-queue`, `prrr-github-fetch-teams` (Task 5); `prrr-db-replace-pr-metas`, `prrr-db-replace-teams`, `prrr-db-select` (Task 4); forge's `forge-get-repository`, `forge-pull`; magit's `magit-refresh-buffer`, `magit-get-mode-buffer`.
- Produces:
  - `prrr-queue-stale-after` (defcustom, seconds, default 300).
  - `(prrr-sync-status REPO-ID)` → plist `(:state STATE :message TEXT :reset-at TIMESTAMP :attempted-at TIMESTAMP)` or nil. STATE is `pulling`, `ok`, or a `prrr-github-error` kind.
  - `(prrr-sync-queue-due-p REPO-ID METAS &optional NOW)` → boolean.
  - `(prrr-sync-pull REPO &optional BUFFER)` → nil. REPO is a `forge-github-repository`; it never signals.
  - `(prrr-sync-current-repository)` → `forge-github-repository` or signals `user-error`.
  - Commands `prrr-pull`, `prrr-refresh-teams` (autoloaded).
  - Test macro `(prrr-test-with-ghub-dispatch ALIST &rest BODY)`: ALIST maps the query's top field (`repository` or `viewer`) to the fixture datum.

- [ ] **Step 1: Add the dispatching stub to the test helper**

Append to `test/prrr-test-helper.el`:

```elisp
(defmacro prrr-test-with-ghub-dispatch (alist &rest body)
  "Run BODY with `ghub-query' answering each request from ALIST.
ALIST maps the query's top-level field (`repository' or `viewer') to
the fixture datum to answer with.  Callbacks run synchronously.  The
variable `prrr-test-requests' collects the top-level field of every
request, oldest first."
  (declare (indent 1) (debug (form body)))
  `(let ((prrr-test-requests nil))
     (cl-letf (((symbol-function 'ghub-query)
                (lambda (query _variables &rest args)
                  (let ((field (car (cadr query))))
                    (setq prrr-test-requests (append prrr-test-requests (list field)))
                    (funcall (plist-get args :callback)
                             (or (alist-get field ,alist)
                                 (ert-fail (list "unexpected request" field))))))))
       ,@body)))

(defvar prrr-test-requests nil
  "Top-level fields of the requests seen by `prrr-test-with-ghub-dispatch'.")
```

Put the `defvar` above the macro.

- [ ] **Step 2: Write the failing tests**

Create `test/prrr-sync-test.el` with the standard header, Commentary "Freshness rules and the background pull, with ghub stubbed and an in-memory database.", and:

```elisp
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'prrr-test-helper)
(require 'prrr-sync)

(defconst prrr-sync-test--now (encode-time '(0 0 12 10 10 2026 nil nil t))
  "2026-10-10T12:00:00Z.")

(defun prrr-sync-test--repo ()
  "Return a GitHub repository object that needs no forge database."
  (let ((repo (forge-github-repository :id "example-repo-id" :owner "example-org"
                                       :name "example-repo" :apihost "api.github.com")))
    (oset repo default-branch "main")
    repo))

(defmacro prrr-sync-test--with-clean-status (&rest body)
  "Run BODY with an empty sync status table and the test viewer."
  (declare (indent 0))
  `(let ((prrr-sync--status (make-hash-table :test #'equal))
         (prrr-sync--teams-fetched-at nil)
         (prrr-github-user "example-me"))
     ,@body))

(defun prrr-sync-test--meta (fetched-at)
  "A meta row of the test repository fetched at FETCHED-AT."
  (prrr-pr-meta-create :pr-id "PR_1" :forge-repo-id "example-repo-id" :fetched-at fetched-at))

;;;; Due

(ert-deftest prrr-sync-test-due-p-never-pulled ()
  (prrr-sync-test--with-clean-status
    (should (prrr-sync-queue-due-p "example-repo-id" nil prrr-sync-test--now))))

(ert-deftest prrr-sync-test-due-p-fresh-rows ()
  (prrr-sync-test--with-clean-status
    (should-not (prrr-sync-queue-due-p "example-repo-id"
                                       (list (prrr-sync-test--meta "2026-10-10T11:58:00Z"))
                                       prrr-sync-test--now))))

(ert-deftest prrr-sync-test-due-p-stale-rows ()
  (prrr-sync-test--with-clean-status
    (should (prrr-sync-queue-due-p "example-repo-id"
                                   (list (prrr-sync-test--meta "2026-10-10T11:50:00Z"))
                                   prrr-sync-test--now))))

(ert-deftest prrr-sync-test-due-p-not-while-pulling ()
  (prrr-sync-test--with-clean-status
    (puthash "example-repo-id" '(:state pulling :attempted-at "2026-10-10T11:00:00Z")
             prrr-sync--status)
    (should-not (prrr-sync-queue-due-p "example-repo-id" nil prrr-sync-test--now))))

(ert-deftest prrr-sync-test-due-p-recent-failed-attempt-waits ()
  "A failure refreshes the buffer; that refresh must not pull again (Review Focus 1)."
  (prrr-sync-test--with-clean-status
    (puthash "example-repo-id" '(:state offline :attempted-at "2026-10-10T11:59:00Z")
             prrr-sync--status)
    (should-not (prrr-sync-queue-due-p "example-repo-id" nil prrr-sync-test--now))))

(ert-deftest prrr-sync-test-due-p-old-failed-attempt-retries ()
  (prrr-sync-test--with-clean-status
    (puthash "example-repo-id" '(:state offline :attempted-at "2026-10-10T11:50:00Z")
             prrr-sync--status)
    (should (prrr-sync-queue-due-p "example-repo-id" nil prrr-sync-test--now))))

(ert-deftest prrr-sync-test-due-p-waits-for-rate-limit-reset ()
  (prrr-sync-test--with-clean-status
    (puthash "example-repo-id" '(:state rate-limited :attempted-at "2026-10-10T11:00:00Z"
                                 :reset-at "2026-10-10T12:30:00Z")
             prrr-sync--status)
    (should-not (prrr-sync-queue-due-p "example-repo-id" nil prrr-sync-test--now))
    (should (prrr-sync-queue-due-p "example-repo-id" nil
                                   (encode-time '(0 31 12 10 10 2026 nil nil t))))))

;;;; Pull

(ert-deftest prrr-sync-test-pull-stores-metas-and-teams ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (prrr-test-with-ghub-dispatch `((viewer . ,(prrr-test-fixture "teams"))
                                      (repository . ,(prrr-test-fixture "queue")))
        (prrr-sync-pull (prrr-sync-test--repo))
        (should (equal '(viewer repository) prrr-test-requests))
        (should (prrr-db-select 'pullreq-meta :forge-repo-id "example-repo-id"))
        (should (prrr-db-select 'team))
        (should (eq 'ok (plist-get (prrr-sync-status "example-repo-id") :state)))
        (should (stringp (plist-get (prrr-sync-status "example-repo-id") :attempted-at)))))))

(ert-deftest prrr-sync-test-pull-skips-fresh-teams ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (prrr-db-replace-teams (list (prrr-team-create :combined-slug "example-org/reviewers"
                                                     :fetched-at (prrr-sync--timestamp))))
      (prrr-test-with-ghub-dispatch `((repository . ,(prrr-test-fixture "queue")))
        (prrr-sync-pull (prrr-sync-test--repo))
        (should (equal '(repository) prrr-test-requests))))))

(ert-deftest prrr-sync-test-pull-no-teams-fetched-this-session-is-not-refetched ()
  "A viewer in no Team has no rows; one fetch per day is enough."
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (setq prrr-sync--teams-fetched-at (prrr-sync--timestamp))
      (prrr-test-with-ghub-dispatch `((repository . ,(prrr-test-fixture "queue")))
        (prrr-sync-pull (prrr-sync-test--repo))
        (should (equal '(repository) prrr-test-requests))))))

(ert-deftest prrr-sync-test-pull-failure-records-status-and-keeps-rows ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (prrr-db-insert (prrr-sync-test--meta "2026-10-01T00:00:00Z"))
      (setq prrr-sync--teams-fetched-at (prrr-sync--timestamp))
      (prrr-test-with-ghub-error-stub '(error http 502) nil
        (prrr-sync-pull (prrr-sync-test--repo)))
      (should (eq 'offline (plist-get (prrr-sync-status "example-repo-id") :state)))
      (should (prrr-db-get 'pullreq-meta "PR_1")))))

(ert-deftest prrr-sync-test-pull-failure-of-teams-stops-the-pull ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (prrr-test-with-ghub-error-stub '(error http 401) nil
        (prrr-sync-pull (prrr-sync-test--repo)))
      (should (eq 'auth (plist-get (prrr-sync-status "example-repo-id") :state))))))

(ert-deftest prrr-sync-test-pull-without-login-records-error-and-sends-nothing ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (let ((prrr-github-user nil))
        (cl-letf (((symbol-function 'magit-get) #'ignore))
          (prrr-test-with-ghub-dispatch nil
            (prrr-sync-pull (prrr-sync-test--repo))
            (should (null prrr-test-requests)))))
      (let ((status (prrr-sync-status "example-repo-id")))
        (should (eq 'error (plist-get status :state)))
        (should (string-match-p "github.user" (plist-get status :message)))))))

(ert-deftest prrr-sync-test-pull-synchronous-signal-becomes-status ()
  "forge signals at once when no token is configured."
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (setq prrr-sync--teams-fetched-at (prrr-sync--timestamp))
      (cl-letf (((symbol-function 'ghub-query)
                 (lambda (&rest _) (error "Required GitHub token does not exist"))))
        (prrr-sync-pull (prrr-sync-test--repo)))
      (should (string-match-p "token" (plist-get (prrr-sync-status "example-repo-id") :message))))))

(ert-deftest prrr-sync-test-pull-ignored-while-pulling ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (puthash "example-repo-id" '(:state pulling) prrr-sync--status)
      (prrr-test-with-ghub-dispatch nil
        (prrr-sync-pull (prrr-sync-test--repo))
        (should (null prrr-test-requests))))))

(ert-deftest prrr-sync-test-pull-refreshes-buffer-later-not-now ()
  "The refresh is deferred so a synchronous answer cannot re-enter a refresh."
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (setq prrr-sync--teams-fetched-at (prrr-sync--timestamp))
      (let ((refreshed nil) (scheduled nil))
        (with-temp-buffer
          (cl-letf (((symbol-function 'magit-refresh-buffer) (lambda (&rest _) (setq refreshed t)))
                    ((symbol-function 'run-at-time)
                     (lambda (_time _repeat fn &rest args) (push (cons fn args) scheduled))))
            (prrr-test-with-ghub-dispatch `((repository . ,(prrr-test-fixture "queue")))
              (prrr-sync-pull (prrr-sync-test--repo) (current-buffer)))
            (should-not refreshed)
            (should (= 1 (length scheduled)))
            (apply (caar scheduled) (cdar scheduled))
            (should refreshed)))))))

(provide 'prrr-sync-test)
;;; prrr-sync-test.el ends here
```

Add `test/prrr-sync-test.el` to `TESTS` in the `Makefile`.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `make test TESTS=test/prrr-sync-test.el`
Expected: FAIL: `Cannot open load file ... prrr-sync`.

- [ ] **Step 4: Implement `prrr-sync.el`**

Create `prrr-sync.el` with the standard header (description: `Freshness rules for prrr`) and:

```elisp
;;; Commentary:

;; When prrr pulls, and what happened the last time it did.  The
;; Review Queue renders only from the database; this file decides when
;; the database is stale, pulls in the background, stores the result
;; and records a per-repository sync status that the queue heading
;; shows (SPEC sections 5 and 11).  A pull never signals: every failure,
;; including a missing login or token, becomes the status.
;;
;; The Outbox retry and per-PR refetch arrive with the Review Buffer
;; (milestones 3 and 4).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'eieio)
(require 'magit-mode)
(require 'forge)
(require 'prrr-db)
(require 'prrr-github)

(defcustom prrr-queue-stale-after 300
  "Seconds after which the Review Queue inputs are pulled again.
This also spaces retries after a failed pull."
  :type 'natnum
  :group 'prrr)

(defconst prrr-sync-teams-max-age (* 24 60 60)
  "Seconds after which the viewer's Teams are fetched again (SPEC section 4).")

(defvar prrr-sync--status (make-hash-table :test #'equal)
  "Sync status of each repository this session, keyed by forge repository id.")

(defvar prrr-sync--teams-fetched-at nil
  "When the viewer's Teams were last fetched this session, or nil.
Remembers a fetch that found no Team, which leaves no row behind.")

(defun prrr-sync--timestamp (&optional time)
  "Return TIME (default now) as a GitHub-style UTC timestamp."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ" time t))

(defun prrr-sync-status (repo-id)
  "Return the sync status of the repository with forge id REPO-ID, or nil.
A plist: :state is `pulling', `ok' or a failure kind of
`prrr-github-error' (`rate-limited', `auth', `not-found', `offline',
`error'); :message describes a failure; :reset-at is when a rate
limit ends; :attempted-at is when the last pull started.  nil means
no pull was attempted this session."
  (gethash repo-id prrr-sync--status))

(defun prrr-sync-queue-due-p (repo-id metas &optional now)
  "Non-nil when the Review Queue inputs of REPO-ID should be pulled.
METAS are the repository's stored `prrr-pr-meta' rows and NOW a Lisp
time, the current time by default.  Due when there are no rows or the
newest is older than `prrr-queue-stale-after', unless a pull is
running, a rate limit has not reset, or the last attempt is more
recent than `prrr-queue-stale-after'.  The last rule makes a failing
pull retry at that pace instead of on every refresh."
  (let* ((now-stamp (prrr-sync--timestamp now))
         (threshold (prrr-sync--timestamp
                     (time-subtract (or now (current-time)) prrr-queue-stale-after)))
         (status (prrr-sync-status repo-id))
         (reset-at (plist-get status :reset-at))
         (attempted-at (plist-get status :attempted-at))
         (newest (car (sort (delq nil (mapcar #'prrr-pr-meta-fetched-at metas))
                            (lambda (a b) (string< b a))))))
    (and (not (eq (plist-get status :state) 'pulling))
         (not (and reset-at (string< now-stamp reset-at)))
         (not (and attempted-at (string< threshold attempted-at)))
         (or (null newest) (string< newest threshold)))))

(defun prrr-sync--teams-due-p ()
  "Non-nil when the viewer's Teams should be fetched before the queue.
Due when no fetch happened this session within `prrr-sync-teams-max-age'
and the stored rows are missing or older than that."
  (let ((threshold (prrr-sync--timestamp
                    (time-subtract (current-time) prrr-sync-teams-max-age))))
    (and (not (and prrr-sync--teams-fetched-at
                   (string< threshold prrr-sync--teams-fetched-at)))
         (let ((teams (prrr-db-select 'team)))
           (or (null teams)
               (seq-some (lambda (team)
                           (string< (or (prrr-team-fetched-at team) "") threshold))
                         teams))))))

(defun prrr-sync--refresh (buffer)
  "Refresh BUFFER if it is still live."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (magit-refresh-buffer))))

(defun prrr-sync--finish (repo-id failure buffer)
  "Record the end of REPO-ID's pull and schedule BUFFER's refresh.
FAILURE is a `prrr-github-error' plist, or nil on success.  The refresh
runs from a timer, so an answer that arrives synchronously never
refreshes a buffer that is still being drawn."
  (puthash repo-id
           (list :state (if failure (plist-get failure :kind) 'ok)
                 :message (plist-get failure :message)
                 :reset-at (plist-get failure :reset-at)
                 :attempted-at (plist-get (prrr-sync-status repo-id) :attempted-at))
           prrr-sync--status)
  (when buffer
    (run-at-time 0 nil #'prrr-sync--refresh buffer)))

(defmacro prrr-sync--guarded (fail &rest body)
  "Run BODY; turn any error into a call of FAIL with an `error' failure."
  (declare (indent 1))
  `(condition-case err
       (progn ,@body)
     (error (funcall ,fail (list :kind 'error :message (error-message-string err)
                                 :reset-at nil)))))

(defun prrr-sync--fetch-teams (host me then fail)
  "Fetch and store the viewer ME's Teams on HOST, then call THEN.
Call FAIL with the classified failure instead when the fetch fails."
  (prrr-github-fetch-teams
   host me
   (lambda (teams)
     (prrr-sync--guarded fail
       (prrr-db-replace-teams teams)
       (setq prrr-sync--teams-fetched-at (prrr-sync--timestamp))
       (funcall then)))
   fail))

(defun prrr-sync-pull (repo &optional buffer)
  "Pull the Review Queue inputs of REPO in the background.
REPO is a `forge-github-repository'.  Fetches the viewer's Teams first
when they are due, then the queue query, and stores both.  Records the
outcome in `prrr-sync-status' and refreshes BUFFER, when live, after
the pull ends either way.  Does nothing while a pull of REPO runs.
Never signals: every failure becomes the status."
  (let ((id (oref repo id)))
    (unless (eq (plist-get (prrr-sync-status id) :state) 'pulling)
      (puthash id (list :state 'pulling :attempted-at (prrr-sync--timestamp))
               prrr-sync--status)
      (let* ((host (oref repo apihost))
             (fail (lambda (failure) (prrr-sync--finish id failure buffer)))
             (fetch-queue
              (lambda ()
                (prrr-github-fetch-queue
                 host (oref repo owner) (oref repo name)
                 (lambda (metas)
                   (prrr-sync--guarded fail
                     (prrr-db-replace-pr-metas id metas)
                     (prrr-sync--finish id nil buffer)))
                 fail id))))
        (prrr-sync--guarded fail
          (let ((me (prrr-github-viewer)))
            (cond ((null me)
                   (funcall fail (list :kind 'error
                                       :message "no GitHub login: set github.user or `prrr-github-user'"
                                       :reset-at nil)))
                  ((prrr-sync--teams-due-p)
                   (prrr-sync--fetch-teams host me fetch-queue fail))
                  (t (funcall fetch-queue)))))))))

;;;; Commands

(defun prrr-sync-current-repository ()
  "Return the current GitHub repository tracked by forge.
Signal a `user-error' when there is none."
  (let ((repo (forge-get-repository :tracked?)))
    (cond ((null repo)
           (user-error "Not in a repository tracked by forge; run `forge-add-repository' first"))
          ((not (cl-typep repo 'forge-github-repository))
           (user-error "Only GitHub repositories can be reviewed with prrr"))
          (t repo))))

;;;###autoload
(defun prrr-pull ()
  "Pull the current repository's pull requests and Review Queue inputs.
Runs `forge-pull', so new pull requests reach forge, and pulls prrr's
own queue inputs.  The magit-status buffer refreshes when each ends."
  (interactive)
  (let ((repo (prrr-sync-current-repository)))
    (forge-pull)
    (prrr-sync-pull repo (magit-get-mode-buffer 'magit-status-mode))
    (message "Pulling the Review Queue of %s/%s..." (oref repo owner) (oref repo name))))

;;;###autoload
(defun prrr-refresh-teams ()
  "Fetch the viewer's Teams again, even if they are fresh."
  (interactive)
  (let ((repo (prrr-sync-current-repository))
        (me (or (prrr-github-viewer)
                (user-error "No GitHub login: set github.user or `prrr-github-user'"))))
    (prrr-sync--fetch-teams
     (oref repo apihost) me
     (lambda () (message "Fetched %d Teams" (length (prrr-db-select 'team))))
     (lambda (failure) (message "Fetching Teams failed: %s" (plist-get failure :message))))))

(provide 'prrr-sync)
;;; prrr-sync.el ends here
```

In `prrr.el` delete the `prrr-queue-stale-after` defcustom and add `(require 'prrr-sync)` next to the other requires (Task 9 removes all of them). Add `prrr-sync.el` to `SRC` in the `Makefile`, after `prrr-state.el`.

- [ ] **Step 5: Run all gates**

Run: `make compile lint test`
Expected: all tests pass (127 + 18 = 145), no warnings. If `magit-get-mode-buffer` warns as unknown, `(require 'magit-mode)` already defines it. Check the spelling.

- [ ] **Step 6: Commit**

```bash
git add prrr-sync.el prrr.el Makefile test/prrr-sync-test.el test/prrr-test-helper.el
git commit -m "feat(sync): background pull of Teams and queue inputs with per-repository status"
```

---

### Task 7: `prrr-queue.el`: rendering (prrr-knu.5, display side)

**Files:**
- Create: `prrr-queue.el`
- Create: `test/prrr-queue-test.el`
- Modify: `Makefile` (`SRC` gains `prrr-queue.el` after `prrr-sync.el`; `TESTS` gains `test/prrr-queue-test.el`)

**Interfaces:**
- Consumes: `prrr-state-queue`, `prrr-state-filter-queue` (Task 3), `prrr-queue-entry-stack-id` (Task 1), `prrr-state-for-me-order`, `prrr-state-mine-order`, `prrr-sync-status` plists (Task 6).
- Produces:
  - Options `prrr-queue-show-drafts`, `prrr-queue-show-served` (booleans, default t).
  - Faces `prrr-queue-state-STATE` for each For Me and Mine state, and `prrr-queue-dimmed`.
  - `(prrr-queue-insert INPUTS)` inserts the section at point. INPUTS is a plist:
    - `:pairs` list of `(FORGE-PULLREQ . PRRR-PR)`, one per open PR;
    - `:metas` list of `prrr-pr-meta`;
    - `:teams` list of combined slugs;
    - `:me` viewer login or nil;
    - `:default-branch` string;
    - `:unresolved` hash table from PR id to count, or nil;
    - `:status` a `prrr-sync-status` plist or nil;
    - `:now` ISO timestamp;
    - `:width` columns.
  - Buffer-local `prrr-queue--rows`: list of `(SECTION . ENTRY)` in display order.
  - Section types: `prrr-queue` (root), `prrr-queue-group` (value `for-me` or `mine`), and `pullreq` rows (value the `forge-pullreq`).
  - `(prrr-queue--ago TIMESTAMP NOW)`, `(prrr-queue--status-text STATUS ME)`, `(prrr-queue--line ENTRY NUMBER-WIDTH DEPTH UNRESOLVED NOW WIDTH)`. These are internal but tested.
  - Keymap variables `prrr-queue-heading-map` and `prrr-queue-section-map` exist as empty keymaps here; Task 9 fills them.

- [ ] **Step 1: Write the failing tests**

Create `test/prrr-queue-test.el` with the standard header, Commentary "Rendering the Review Queue section into a magit-section buffer from constructed inputs; no forge database and no network.", and:

```elisp
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'prrr-test-helper)
(require 'prrr-queue)

(defun prrr-queue-test--pair (&rest args)
  "Return (PULLREQ . PR) for `prrr-test-pr' ARGS with a matching forge object."
  (let ((pr (apply #'prrr-test-pr args)))
    (cons (forge-pullreq :id (format "forge-%s" (prrr-pr-id pr))
                         :number (prrr-pr-number pr)
                         :title (prrr-pr-title pr)
                         :their-id (prrr-pr-id pr))
          pr)))

(cl-defun prrr-queue-test--inputs (pairs metas &key (me prrr-test-me) status unresolved (width 100))
  "INPUTS for `prrr-queue-insert' over PAIRS and METAS."
  (list :pairs pairs :metas metas :teams prrr-test-teams :me me
        :default-branch "main" :unresolved unresolved :status status
        :now "2026-10-10T12:00:00Z" :width width))

(defmacro prrr-queue-test--with-render (inputs &rest body)
  "Render INPUTS into a fresh magit-section buffer and run BODY there."
  (declare (indent 1))
  `(with-temp-buffer
     (magit-section-mode)
     (let ((inhibit-read-only t))
       (magit-insert-section (status)
         (prrr-queue-insert ,inputs)))
     (goto-char (point-min))
     ,@body))

(defun prrr-queue-test--line-of (number)
  "Return the text of the row of PR NUMBER in the current buffer."
  (goto-char (point-min))
  (re-search-forward (format "^#%d " number))
  (buffer-substring-no-properties (line-beginning-position) (line-end-position)))

(defun prrr-queue-test--group (group)
  "Return the section of GROUP (`for-me' or `mine') in the current buffer."
  (seq-find (lambda (section) (eq (oref section value) group))
            (oref (car (oref magit-root-section children)) children)))

;;;; Structure

(ert-deftest prrr-queue-test-heading-and-group-counts ()
  (prrr-queue-test--with-render
      (prrr-queue-test--inputs
       (list (prrr-queue-test--pair :id "A" :number 1)
             (prrr-queue-test--pair :id "M" :number 2 :author "example-me" :head-ref "mine"))
       (list (prrr-test-meta :pr-id "A" :review-requests '((user "example-me")))))
    (should (looking-at "Review Queue\n"))
    (should (search-forward "For me (1)" nil t))
    (should (search-forward "Mine (1)" nil t))))

(ert-deftest prrr-queue-test-row-value-is-the-forge-pullreq ()
  (let ((pair (prrr-queue-test--pair :id "A" :number 7)))
    (prrr-queue-test--with-render
        (prrr-queue-test--inputs (list pair)
                                 (list (prrr-test-meta :pr-id "A" :review-requests '((user "example-me")))))
      (prrr-queue-test--line-of 7)
      (should (eq (car pair) (magit-section-value-if 'pullreq)))
      (should (eq 'prrr-queue-section-map (oref (magit-current-section) keymap)))
      (should (equal "A" (prrr-pr-id (prrr-queue-entry-pr (cdr (car prrr-queue--rows)))))))))

(ert-deftest prrr-queue-test-rows-follow-queue-order ()
  (prrr-queue-test--with-render
      (prrr-queue-test--inputs
       (list (prrr-queue-test--pair :id "NEW" :number 2 :head-ref "n" :created-at "2026-09-05T00:00:00Z")
             (prrr-queue-test--pair :id "OLD" :number 1 :head-ref "o" :created-at "2026-09-01T00:00:00Z"))
       (list (prrr-test-meta :pr-id "NEW" :review-requests '((user "example-me")))
             (prrr-test-meta :pr-id "OLD" :review-requests '((user "example-me")))))
    (should (< (progn (re-search-forward "^#1 ") (point))
               (progn (re-search-forward "^#2 ") (point))))))

(ert-deftest prrr-queue-test-empty-queue-collapsed ()
  "Review Focus 3: nothing pulled yet, no open PRs."
  (prrr-queue-test--with-render (prrr-queue-test--inputs nil nil)
    (should (search-forward "For me (0)" nil t))
    (should (search-forward "Mine (0)" nil t))
    (should (oref (prrr-queue-test--group 'for-me) hidden))
    (should (oref (prrr-queue-test--group 'mine) hidden))))

(ert-deftest prrr-queue-test-non-empty-queue-expanded ()
  (prrr-queue-test--with-render
      (prrr-queue-test--inputs (list (prrr-queue-test--pair :id "A" :number 1))
                               (list (prrr-test-meta :pr-id "A" :review-requests '((user "example-me")))))
    (should-not (oref (prrr-queue-test--group 'for-me) hidden))))

;;;; Stacks (prrr-knu.5)

(ert-deftest prrr-queue-test-stack-missing-bottom-is-not-indented ()
  "My own bottom PR is in Mine, so For Me shows a one-row Stack."
  (prrr-queue-test--with-render
      (prrr-queue-test--inputs
       (list (prrr-queue-test--pair :id "MINE" :number 1 :author "example-me" :head-ref "step-1")
             (prrr-queue-test--pair :id "THEIRS" :number 2 :base-ref "step-1" :head-ref "step-2"))
       (list (prrr-test-meta :pr-id "MINE")
             (prrr-test-meta :pr-id "THEIRS" :review-requests '((user "example-me")))))
    (let ((line (prrr-queue-test--line-of 2)))
      (should (string-prefix-p "#2  requested" line))
      (should (string-match-p "⟰ 2/2" line)))))

(ert-deftest prrr-queue-test-stack-members-indent-by-visible-depth ()
  (prrr-queue-test--with-render
      (prrr-queue-test--inputs
       (list (prrr-queue-test--pair :id "BOTTOM" :number 1 :head-ref "step-1")
             (prrr-queue-test--pair :id "TOP" :number 2 :base-ref "step-1" :head-ref "step-2"))
       (list (prrr-test-meta :pr-id "BOTTOM" :review-requests '((user "example-me")))
             (prrr-test-meta :pr-id "TOP" :review-requests '((user "example-me")))))
    (should (string-prefix-p "#1  requested" (prrr-queue-test--line-of 1)))
    (should (string-prefix-p "#2    requested" (prrr-queue-test--line-of 2)))
    (should (string-match-p "⟰ 1/2" (prrr-queue-test--line-of 1)))))

(ert-deftest prrr-queue-test-lone-pr-has-no-stack-marker ()
  (prrr-queue-test--with-render
      (prrr-queue-test--inputs (list (prrr-queue-test--pair :id "A" :number 1))
                               (list (prrr-test-meta :pr-id "A" :review-requests '((user "example-me")))))
    (should-not (string-match-p "⟰" (prrr-queue-test--line-of 1)))))

;;;; Filters

(ert-deftest prrr-queue-test-hide-served ()
  (let ((prrr-queue-show-served nil))
    (prrr-queue-test--with-render
        (prrr-queue-test--inputs
         (list (prrr-queue-test--pair :id "A" :number 1 :head-ref "a")
               (prrr-queue-test--pair :id "S" :number 2 :head-ref "s"))
         (list (prrr-test-meta :pr-id "A" :review-requests '((user "example-me")))
               (prrr-test-meta :pr-id "S" :viewer-latest-review
                               (list "APPROVED" "2026-09-02T00:00:00Z" prrr-test-head))))
      (should (re-search-forward "^#1 " nil t))
      (goto-char (point-min))
      (should-not (re-search-forward "^#2 " nil t)))))

;;;; Line

(ert-deftest prrr-queue-test-line-shows-author-unresolved-and-age ()
  (let ((unresolved (make-hash-table :test #'equal)))
    (puthash "A" 3 unresolved)
    (prrr-queue-test--with-render
        (prrr-queue-test--inputs
         (list (prrr-queue-test--pair :id "A" :number 1 :title "Fix the parser"
                                      :updated-at "2026-10-08T12:00:00Z"))
         (list (prrr-test-meta :pr-id "A" :review-requests '((user "example-me"))))
         :unresolved unresolved)
      (should (string-match-p
               "^#1  requested +Fix the parser  example-alice  3 unresolved  2d$"
               (prrr-queue-test--line-of 1))))))

(ert-deftest prrr-queue-test-line-fits-width ()
  "Review Focus 5: long and wide titles are truncated to the window."
  (dolist (title (list (make-string 300 ?x) (make-string 150 ?語)))
    (prrr-queue-test--with-render
        (prrr-queue-test--inputs
         (list (prrr-queue-test--pair :id "A" :number 1 :title title))
         (list (prrr-test-meta :pr-id "A" :review-requests '((user "example-me"))))
         :width 60)
      (should (<= (string-width (prrr-queue-test--line-of 1)) 60)))))

(ert-deftest prrr-queue-test-line-dimmed-row-uses-dimmed-face ()
  (let* ((entry (prrr-queue-entry-create :pr (prrr-test-pr :number 4) :state nil
                                         :stack-pos 1 :stack-size 2 :dimmed-p t))
         (line (prrr-queue--line entry 3 0 0 "2026-10-10T12:00:00Z" 80)))
    (should (eq 'prrr-queue-dimmed (get-text-property 0 'font-lock-face line)))))

(ert-deftest prrr-queue-test-ago ()
  (let ((now "2026-10-10T12:00:00Z"))
    (should (equal "now" (prrr-queue--ago "2026-10-10T11:59:30Z" now)))
    (should (equal "5m" (prrr-queue--ago "2026-10-10T11:55:00Z" now)))
    (should (equal "3h" (prrr-queue--ago "2026-10-10T09:00:00Z" now)))
    (should (equal "2d" (prrr-queue--ago "2026-10-08T12:00:00Z" now)))
    (should (equal "2mo" (prrr-queue--ago "2026-08-10T12:00:00Z" now)))
    (should (equal "1y" (prrr-queue--ago "2025-10-01T12:00:00Z" now)))
    (should (equal "" (prrr-queue--ago nil now)))
    (should (equal "now" (prrr-queue--ago "2026-10-10T12:05:00Z" now)))))

;;;; Heading status

(ert-deftest prrr-queue-test-status-text ()
  (should (equal "" (prrr-queue--status-text nil "example-me")))
  (should (equal "" (prrr-queue--status-text '(:state ok) "example-me")))
  (should (string-match-p "pulling" (prrr-queue--status-text '(:state pulling) "example-me")))
  (should (string-match-p "offline" (prrr-queue--status-text '(:state offline) "example-me")))
  (should (string-match-p "rate limited until [0-9][0-9]:[0-9][0-9]"
                          (prrr-queue--status-text '(:state rate-limited :reset-at "2026-10-10T12:30:00Z")
                                                   "example-me")))
  (should (string-match-p "HTTP 401"
                          (prrr-queue--status-text '(:state auth :message "GitHub rejected the token (HTTP 401)")
                                                   "example-me")))
  (should (string-match-p "github.user" (prrr-queue--status-text nil nil))))

(ert-deftest prrr-queue-test-no-login-renders-heading-only ()
  (prrr-queue-test--with-render
      (prrr-queue-test--inputs (list (prrr-queue-test--pair :id "A" :number 1)) nil :me nil)
    (should (looking-at "Review Queue (no GitHub login"))
    (should-not (re-search-forward "^#1 " nil t))))

(provide 'prrr-queue-test)
;;; prrr-queue-test.el ends here
```

Add `test/prrr-queue-test.el` to `TESTS`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test TESTS=test/prrr-queue-test.el`
Expected: FAIL: `Cannot open load file ... prrr-queue`.

- [ ] **Step 3: Implement `prrr-queue.el` (rendering part)**

Create `prrr-queue.el` with the standard header (description: `The Review Queue section in magit-status`) and:

```elisp
;;; Commentary:

;; The Review Queue (SPEC section 5): a section in magit-status listing
;; the open PRs that need the viewer, in two Queue Groups, For Me and
;; Mine, ordered and stacked by `prrr-state'.  It renders only from
;; the database and forge's objects; `prrr-sync' pulls in the
;; background when the inputs are stale.
;;
;; A row is a section of type `pullreq' whose value is forge's
;; `forge-pullreq', so forge's commands work on it, with prrr's own
;; keymap `prrr-queue-section-map'.  `prrr-queue--rows' maps each row
;; section to its `prrr-queue-entry' for Stack navigation.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'parse-time)
(require 'magit)
(require 'forge)
(require 'prrr-db)
(require 'prrr-github)
(require 'prrr-state)
(require 'prrr-sync)

;;;; Options

(defcustom prrr-queue-show-drafts t
  "Whether the Review Queue shows draft pull requests."
  :type 'boolean
  :group 'prrr)

(defcustom prrr-queue-show-served t
  "Whether the Review Queue shows the Served partition of For Me."
  :type 'boolean
  :group 'prrr)

;;;; Faces

(defface prrr-queue-state-new-commits '((t :inherit warning))
  "Review State badge: new commits since my review."
  :group 'prrr)
(defface prrr-queue-state-requested '((t :inherit font-lock-keyword-face :weight bold))
  "Review State badge: my review is requested."
  :group 'prrr)
(defface prrr-queue-state-team-requested '((t :inherit font-lock-function-name-face))
  "Review State badge: one of my Teams is requested."
  :group 'prrr)
(defface prrr-queue-state-teammate-reviewed '((t :inherit shadow))
  "Review State badge: a teammate reviewed in my place."
  :group 'prrr)
(defface prrr-queue-state-changes-requested '((t :inherit error))
  "Review State or Mine state badge: changes requested."
  :group 'prrr)
(defface prrr-queue-state-approved '((t :inherit success))
  "Review State or Mine state badge: approved."
  :group 'prrr)
(defface prrr-queue-state-commented '((t :inherit font-lock-doc-face))
  "Review State badge: I commented."
  :group 'prrr)
(defface prrr-queue-state-assigned '((t :inherit font-lock-type-face))
  "Review State badge: assigned to me."
  :group 'prrr)
(defface prrr-queue-state-awaiting-review '((t :inherit font-lock-keyword-face))
  "Mine state badge: no review yet."
  :group 'prrr)
(defface prrr-queue-state-reviewed '((t :inherit font-lock-doc-face))
  "Mine state badge: reviewed with comments only."
  :group 'prrr)
(defface prrr-queue-state-draft '((t :inherit shadow))
  "Mine state badge: draft."
  :group 'prrr)
(defface prrr-queue-dimmed '((t :inherit magit-dimmed))
  "A row shown only for context: a Stack member that does not qualify, or a draft."
  :group 'prrr)

;;;; Keymaps

(defvar-keymap prrr-queue-heading-map
  :doc "Keys on the Review Queue heading and its group headings.")

(defvar-keymap prrr-queue-section-map
  :doc "Keys on a Review Queue row (SPEC section 9)."
  :parent prrr-queue-heading-map)

;;;; Formatting

(defconst prrr-queue--badge-width
  (apply #'max (mapcar (lambda (state) (length (symbol-name state)))
                       (append prrr-state-for-me-order prrr-state-mine-order)))
  "Width of the state badge column.")

(defun prrr-queue--ago (timestamp now)
  "Return how long before NOW TIMESTAMP was, such as \"5m\" or \"2d\".
The units are \"now\", minutes, hours, days, months (\"mo\", 30 days)
and years.  Both are ISO 8601 strings.  Return \"\" when TIMESTAMP is nil; a
TIMESTAMP after NOW is \"now\"."
  (if (not (and timestamp now))
      ""
    (let ((seconds (max 0 (float-time (time-subtract (parse-iso8601-time-string now)
                                                     (parse-iso8601-time-string timestamp))))))
      (cond ((< seconds 60) "now")
            ((< seconds 3600) (format "%dm" (/ seconds 60)))
            ((< seconds 86400) (format "%dh" (/ seconds 3600)))
            ((< seconds (* 30 86400)) (format "%dd" (/ seconds 86400)))
            ((< seconds (* 365 86400)) (format "%dmo" (/ seconds (* 30 86400))))
            (t (format "%dy" (/ seconds (* 365 86400))))))))

(defun prrr-queue--status-text (status me)
  "Return the heading suffix for sync STATUS and viewer ME.
STATUS is a `prrr-sync-status' plist or nil.  The empty string when
there is nothing to say."
  (let ((text
         (if (null me)
             "no GitHub login: set github.user or `prrr-github-user'"
           (pcase (plist-get status :state)
             ('pulling "pulling…")
             ('offline "offline")
             ('rate-limited
              (format "rate limited until %s"
                      (format-time-string "%H:%M" (parse-iso8601-time-string
                                                   (plist-get status :reset-at)))))
             ((or 'auth 'not-found 'error) (plist-get status :message))))))
    (if text
        (propertize (format " (%s)" text) 'font-lock-face 'magit-dimmed)
      "")))

(defun prrr-queue--line (entry number-width depth unresolved now width)
  "Return the text of ENTRY's row, without a newline.
NUMBER-WIDTH is the width of the PR number column, DEPTH the row's
depth among the visible rows of its Stack, UNRESOLVED its count of
unresolved Threads, NOW the current ISO timestamp and WIDTH the
columns to fit.  The title is truncated so the row fits WIDTH whenever
WIDTH leaves it at least ten columns.  The Stack marker shows the
row's true position, which may skip hidden rows (prrr-knu.5)."
  (let* ((pr (prrr-queue-entry-pr entry))
         (state (prrr-queue-entry-state entry))
         (dimmed (prrr-queue-entry-dimmed-p entry))
         (size (prrr-queue-entry-stack-size entry))
         (ago (prrr-queue--ago (prrr-pr-updated-at pr) now))
         (number (string-pad (format "#%d" (prrr-pr-number pr)) number-width))
         (badge (propertize (string-pad (if state (symbol-name state) "") prrr-queue--badge-width)
                            'font-lock-face (and state (intern (format "prrr-queue-state-%s" state)))))
         (prefix (concat (propertize number 'font-lock-face 'forge-topic-slug-open)
                         "  " (make-string (* 2 depth) ?\s) badge "  "))
         (suffix (concat "  " (propertize (or (prrr-pr-author pr) "") 'font-lock-face 'magit-log-author)
                         (and size (> size 1)
                              (format "  ⟰ %d/%d" (prrr-queue-entry-stack-pos entry) size))
                         (and (> unresolved 0) (format "  %d unresolved" unresolved))
                         (and (not (string-empty-p ago))
                              (concat "  " (propertize ago 'font-lock-face 'magit-log-date)))))
         (title-width (max 10 (- width (string-width prefix) (string-width suffix))))
         (title (truncate-string-to-width (or (prrr-pr-title pr) "") title-width nil nil "…"))
         (line (concat prefix title suffix)))
    (if dimmed
        (propertize line 'font-lock-face 'prrr-queue-dimmed)
      line)))

;;;; Insertion

(defvar-local prrr-queue--rows nil
  "The Review Queue rows of this buffer as (SECTION . ENTRY), in display order.")

(defun prrr-queue--count (entries)
  "Return how many ENTRIES qualify (have a state)."
  (seq-count #'prrr-queue-entry-state entries))

(defun prrr-queue--insert-rows (entries pullreqs inputs number-width)
  "Insert one row section per entry of ENTRIES.
PULLREQS maps PR ids to forge objects; INPUTS and NUMBER-WIDTH are as
in `prrr-queue-insert'."
  (let ((stack-id nil) (depth 0)
        (unresolved (plist-get inputs :unresolved)))
    (dolist (entry entries)
      (if (equal (prrr-queue-entry-stack-id entry) stack-id)
          (cl-incf depth)
        (setq stack-id (prrr-queue-entry-stack-id entry)
              depth 0))
      (let* ((id (prrr-pr-id (prrr-queue-entry-pr entry)))
             (pullreq (gethash id pullreqs)))
        (magit-insert-section row (pullreq pullreq)
          (oset row keymap 'prrr-queue-section-map)
          (insert (prrr-queue--line entry number-width depth
                                    (or (and unresolved (gethash id unresolved)) 0)
                                    (plist-get inputs :now) (plist-get inputs :width))
                  "\n")
          (push (cons row entry) prrr-queue--rows))))))

(defun prrr-queue-insert (inputs)
  "Insert the Review Queue section described by INPUTS at point.
INPUTS is a plist: :pairs, a list of (FORGE-PULLREQ . PRRR-PR) for the
repository's open PRs; :metas, their `prrr-pr-meta' rows; :teams, the
viewer's Team slugs; :me, the viewer's login or nil; :default-branch;
:unresolved, a hash table from PR id to unresolved Thread count, or
nil; :status, a `prrr-sync-status' plist or nil; :now, an ISO
timestamp; :width, the columns rows should fit.  Without a login only
the heading is inserted.  The groups are collapsed when both are
empty.  Sets `prrr-queue--rows'."
  (let* ((me (plist-get inputs :me))
         (pairs (plist-get inputs :pairs))
         (pullreqs (make-hash-table :test #'equal))
         (queue (and me (prrr-state-queue (mapcar #'cdr pairs) (plist-get inputs :metas)
                                          me (plist-get inputs :teams)
                                          (plist-get inputs :default-branch))))
         (groups (mapcar (lambda (group)
                           (list (car group) (cdr group)
                                 (prrr-state-filter-queue
                                  (plist-get queue (if (eq (car group) 'for-me) :for-me :mine))
                                  :show-drafts prrr-queue-show-drafts
                                  :show-served prrr-queue-show-served)))
                         '((for-me . "For me") (mine . "Mine"))))
         (empty (seq-every-p (lambda (group) (null (nth 2 group))) groups))
         (number-width (apply #'max 2 (mapcar (lambda (pair)
                                                (length (format "#%d" (prrr-pr-number (cdr pair)))))
                                              pairs))))
    (dolist (pair pairs)
      (puthash (prrr-pr-id (cdr pair)) (car pair) pullreqs))
    (setq prrr-queue--rows nil)
    (magit-insert-section root (prrr-queue)
      (oset root keymap 'prrr-queue-heading-map)
      (magit-insert-heading
        (propertize "Review Queue" 'font-lock-face 'magit-section-heading)
        (prrr-queue--status-text (plist-get inputs :status) me))
      (when me
        (pcase-dolist (`(,group ,title ,entries) groups)
          (magit-insert-section section (prrr-queue-group group empty)
            (oset section keymap 'prrr-queue-heading-map)
            (magit-insert-heading
              (propertize (format "%s (%d)" title (prrr-queue--count entries))
                          'font-lock-face 'magit-section-secondary-heading))
            (prrr-queue--insert-rows entries pullreqs inputs number-width))))
      (insert "\n"))
    (setq prrr-queue--rows (nreverse prrr-queue--rows))))

(provide 'prrr-queue)
;;; prrr-queue.el ends here
```

Add `prrr-queue.el` to `SRC` after `prrr-sync.el`.

If `prrr-queue-test-stack-members-indent-by-visible-depth` fails on the exact spacing, compare the badge column. The prefix is `#N` padded to NUMBER-WIDTH, two spaces, then `2*depth` spaces, then the badge. With one-digit numbers NUMBER-WIDTH is 2, so depth 1 gives `#2` followed by four spaces before `requested`. Fix the code, not the test.

- [ ] **Step 4: Run all gates**

Run: `make compile lint test`
Expected: all pass (145 + 17 = 162).

- [ ] **Step 5: Commit**

```bash
git add prrr-queue.el Makefile test/prrr-queue-test.el
git commit -m "feat(queue): render the Review Queue section with Stack markers, filters and status"
```

---

### Task 8: The section in magit-status (prrr-knu.4)

**Files:**
- Modify: `prrr-queue.el` (inputs from forge, the hook function, `prrr-queue-mode`, `prrr-queue`, preserved Outbox)
- Modify: `test/prrr-queue-test.el`
- Modify: `SPEC.md` section 5

**Interfaces:**
- Consumes: `prrr-queue-insert` (Task 7), `prrr-sync-queue-due-p`, `prrr-sync-pull`, `prrr-sync-status` (Task 6), `prrr-db-take-preserved-outbox`, `prrr-db-unresolved-thread-counts` (Task 4), `prrr-github-viewer` (Task 5).
- Produces:
  - `(prrr-queue-pr PULLREQ)` → `prrr-pr` built from a `forge-pullreq`.
  - `(prrr-queue-insert-section)`, the `magit-status-sections-hook` function.
  - `prrr-queue-mode`, a global minor mode (autoloaded).
  - `prrr-queue`, a command (autoloaded).
  - Internal `prrr-queue--assignees`, `prrr-queue--open-pullreqs`, `prrr-queue--inputs`, `prrr-queue--announce-preserved-outbox`; tests stub them.

- [ ] **Step 1: Write the failing tests**

Append to `test/prrr-queue-test.el` before `(provide ...)`:

```elisp
;;;; From forge to the section

(defun prrr-queue-test--repo ()
  "A GitHub repository object that needs no forge database."
  (let ((repo (forge-github-repository :id "example-repo-id" :owner "example-org"
                                       :name "example-repo" :apihost "api.github.com")))
    (oset repo default-branch "main")
    repo))

(ert-deftest prrr-queue-test-pr-from-forge ()
  (let ((pullreq (forge-pullreq :id "forge-1" :number 12 :title "Add parser" :state 'open
                                :author "example-alice" :draft-p t :their-id "PR_12"
                                :created "2026-09-01T00:00:00Z" :updated "2026-09-03T00:00:00Z"
                                :head-rev "abc" :base-ref "main" :head-ref "parser"
                                :cross-repo-p nil)))
    (cl-letf (((symbol-function 'prrr-queue--assignees) (lambda (_) '("example-me"))))
      (let ((pr (prrr-queue-pr pullreq)))
        (should (equal "PR_12" (prrr-pr-id pr)))
        (should (= 12 (prrr-pr-number pr)))
        (should (equal "Add parser" (prrr-pr-title pr)))
        (should (equal "example-alice" (prrr-pr-author pr)))
        (should (eq t (prrr-pr-draft-p pr)))
        (should (equal '("example-me") (prrr-pr-assignees pr)))
        (should (equal "2026-09-01T00:00:00Z" (prrr-pr-created-at pr)))
        (should (equal "2026-09-03T00:00:00Z" (prrr-pr-updated-at pr)))
        (should (equal "abc" (prrr-pr-head-oid pr)))
        (should (equal "main" (prrr-pr-base-ref pr)))
        (should (equal "parser" (prrr-pr-head-ref pr)))
        (should (null (prrr-pr-cross-repo-p pr)))))))

(ert-deftest prrr-queue-test-inputs-tolerate-forge-and-meta-drift ()
  "Review Focus 4: forge knows a PR prrr never pulled; prrr has a row forge closed."
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-test-meta :pr-id "CLOSED-IN-FORGE"))
    (let ((pullreq (forge-pullreq :id "forge-5" :number 5 :title "New" :state 'open
                                  :author "example-alice" :their-id "NOT-PULLED-YET"
                                  :base-ref "main" :head-ref "new"))
          (prrr-github-user "example-me"))
      (cl-letf (((symbol-function 'prrr-queue--open-pullreqs) (lambda (_) (list pullreq)))
                ((symbol-function 'prrr-queue--assignees) (lambda (_) '("example-me"))))
        (let ((inputs (prrr-queue--inputs (prrr-queue-test--repo))))
          (should (equal '("CLOSED-IN-FORGE")
                         (mapcar #'prrr-pr-meta-pr-id (plist-get inputs :metas))))
          (prrr-queue-test--with-render inputs
            (should (string-match-p "assigned" (prrr-queue-test--line-of 5)))))))))

(defmacro prrr-queue-test--with-hook-env (repo &rest body)
  "Run BODY with forge's repository lookup answering REPO."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'forge-db) (lambda (&rest _) t))
             ((symbol-function 'forge-get-repository) (lambda (&rest _) ,repo)))
     ,@body))

(defun prrr-queue-test--hook-output ()
  "Run the section hook function in a magit-section buffer; return the text."
  (with-temp-buffer
    (magit-section-mode)
    (let ((inhibit-read-only t))
      (magit-insert-section (status)
        (prrr-queue-insert-section)))
    (buffer-string)))

(ert-deftest prrr-queue-test-hook-inserts-nothing-outside-github ()
  (prrr-queue-test--with-hook-env nil
    (should (equal "" (prrr-queue-test--hook-output)))))

(ert-deftest prrr-queue-test-hook-error-becomes-a-line ()
  "Review Focus 2: the status buffer survives any error in the queue."
  (prrr-queue-test--with-hook-env (prrr-queue-test--repo)
    (cl-letf (((symbol-function 'prrr-queue--inputs)
               (lambda (_) (error "Database is locked"))))
      (let ((text (prrr-queue-test--hook-output)))
        (should (string-match-p "Review Queue (error: Database is locked)" text))))))

(ert-deftest prrr-queue-test-hook-starts-due-pull ()
  (prrr-queue-test--with-hook-env (prrr-queue-test--repo)
    (let ((pulled nil))
      (cl-letf (((symbol-function 'prrr-queue--inputs)
                 (lambda (_) (prrr-queue-test--inputs nil nil)))
                ((symbol-function 'prrr-sync-queue-due-p) (lambda (&rest _) t))
                ((symbol-function 'prrr-sync-pull)
                 (lambda (repo buffer) (setq pulled (list (oref repo id) (bufferp buffer)))))
                ((symbol-function 'prrr-sync-status) (lambda (_) '(:state pulling))))
        (let ((text (prrr-queue-test--hook-output)))
          (should (equal '("example-repo-id" t) pulled))
          (should (string-match-p "Review Queue (pulling" text)))))))

(ert-deftest prrr-queue-test-hook-does-not-pull-when-fresh ()
  (prrr-queue-test--with-hook-env (prrr-queue-test--repo)
    (cl-letf (((symbol-function 'prrr-queue--inputs) (lambda (_) (prrr-queue-test--inputs nil nil)))
              ((symbol-function 'prrr-sync-queue-due-p) (lambda (&rest _) nil))
              ((symbol-function 'prrr-sync-pull) (lambda (&rest _) (ert-fail "pulled"))))
      (prrr-queue-test--hook-output))))

(ert-deftest prrr-queue-test-preserved-outbox-announced-once ()
  "prrr-knu.4: the consumer shows the kept rows and clears them."
  (let ((prrr-db-preserved-outbox (list (prrr-outbox-create :id "o1" :pr-id "PR_1" :kind 'comment)))
        (warnings nil))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (type message &rest _) (push (cons type message) warnings))))
      (prrr-queue--announce-preserved-outbox)
      (prrr-queue--announce-preserved-outbox))
    (should (= 1 (length warnings)))
    (should (eq 'prrr (caar warnings)))
    (should (string-match-p "1 unsent write" (cdar warnings)))
    (should (null prrr-db-preserved-outbox))))

(ert-deftest prrr-queue-test-mode-places-section-before-forge-pullreqs ()
  (let ((magit-status-sections-hook (list #'magit-insert-status-headers #'forge-insert-pullreqs)))
    (unwind-protect
        (progn
          (prrr-queue-mode 1)
          (should (equal (list #'magit-insert-status-headers #'prrr-queue-insert-section
                               #'forge-insert-pullreqs)
                         magit-status-sections-hook))
          (prrr-queue-mode -1)
          (should-not (memq #'prrr-queue-insert-section magit-status-sections-hook)))
      (prrr-queue-mode -1))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test TESTS=test/prrr-queue-test.el`
Expected: the new tests FAIL with `void-function` (`prrr-queue-pr`, `prrr-queue--inputs`, `prrr-queue-insert-section`, ...).

- [ ] **Step 3: Implement**

Append to `prrr-queue.el` before `(provide 'prrr-queue)`:

```elisp
;;;; From forge

(defun prrr-queue--assignees (pullreq)
  "Return the logins assigned to forge's PULLREQ."
  (mapcar #'cadr (oref pullreq assignees)))

(defun prrr-queue-pr (pullreq)
  "Return the `prrr-pr' the Review Queue rules see for forge's PULLREQ.
HEAD-OID is forge's head-rev; the Review State prefers the head stored
with the PR's meta row (`prrr-state--head-oid'), so forge's matters only
for a PR prrr has not pulled yet."
  (prrr-pr-create :id (oref pullreq their-id)
                  :number (oref pullreq number)
                  :title (oref pullreq title)
                  :author (oref pullreq author)
                  :draft-p (and (oref pullreq draft-p) t)
                  :assignees (prrr-queue--assignees pullreq)
                  :created-at (oref pullreq created)
                  :updated-at (oref pullreq updated)
                  :head-oid (oref pullreq head-rev)
                  :base-ref (oref pullreq base-ref)
                  :head-ref (oref pullreq head-ref)
                  :cross-repo-p (and (oref pullreq cross-repo-p) t)))

(defun prrr-queue--open-pullreqs (repo)
  "Return forge's open pull requests of REPO."
  (seq-filter (lambda (pullreq) (eq (oref pullreq state) 'open))
              (oref repo pullreqs)))

(defun prrr-queue--width ()
  "Return the columns rows should fit: the buffer's window, else 80."
  (if-let ((window (get-buffer-window (current-buffer))))
      (window-body-width window)
    80))

(defun prrr-queue--inputs (repo)
  "Gather the `prrr-queue-insert' INPUTS of REPO from forge and the database."
  (let* ((id (oref repo id))
         (pairs (mapcar (lambda (pullreq) (cons pullreq (prrr-queue-pr pullreq)))
                        (prrr-queue--open-pullreqs repo))))
    (list :pairs pairs
          :metas (prrr-db-select 'pullreq-meta :forge-repo-id id)
          :teams (mapcar #'prrr-team-combined-slug (prrr-db-select 'team))
          :me (prrr-github-viewer)
          :default-branch (oref repo default-branch)
          :unresolved (prrr-db-unresolved-thread-counts
                       (mapcar (lambda (pair) (prrr-pr-id (cdr pair))) pairs))
          :status (prrr-sync-status id)
          :now (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t)
          :width (prrr-queue--width))))

;;;; The magit-status section

(defun prrr-queue--announce-preserved-outbox ()
  "Warn once about Outbox rows kept across a database schema reset."
  (when-let ((rows (prrr-db-take-preserved-outbox)))
    (display-warning
     'prrr
     (format "prrr's database was reset for a new layout; %d unsent write(s) are kept in the Outbox: %s"
             (length rows)
             (mapconcat (lambda (row) (format "%s on %s" (prrr-outbox-kind row) (prrr-outbox-pr-id row)))
                        rows ", "))
     :warning)))

(defun prrr-queue--insert-error (err)
  "Insert a Review Queue heading that reports ERR."
  (magit-insert-section (prrr-queue)
    (magit-insert-heading
      (propertize "Review Queue" 'font-lock-face 'magit-section-heading)
      (propertize (format " (error: %s)" (error-message-string err)) 'font-lock-face 'error))
    (insert "\n")))

(defun prrr-queue-insert-section ()
  "Insert the Review Queue into a magit-status buffer.
A `magit-status-sections-hook' function.  Inserts nothing outside a
GitHub repository tracked by forge.  Starts a background pull when the
stored inputs are stale (`prrr-sync-queue-due-p').  Any error becomes a
one-line section, so the rest of the status buffer still renders."
  (when-let* ((_ (forge-db t))
              (repo (forge-get-repository :tracked?))
              (_ (cl-typep repo 'forge-github-repository)))
    (condition-case err
        (let ((inputs (prrr-queue--inputs repo))
              (id (oref repo id)))
          (prrr-queue--announce-preserved-outbox)
          (when (prrr-sync-queue-due-p id (plist-get inputs :metas))
            (prrr-sync-pull repo (current-buffer)))
          (prrr-queue-insert (plist-put inputs :status (prrr-sync-status id))))
      (error
       (message "Review Queue failed: %s" (error-message-string err))
       (prrr-queue--insert-error err)))))

;;;###autoload
(define-minor-mode prrr-queue-mode
  "Show the Review Queue in the magit-status buffer of GitHub repositories.
The section goes right before forge's list of pull requests."
  :global t
  :group 'prrr
  (if prrr-queue-mode
      (magit-add-section-hook 'magit-status-sections-hook #'prrr-queue-insert-section
                              #'forge-insert-pullreqs)
    (remove-hook 'magit-status-sections-hook #'prrr-queue-insert-section)))

;;;###autoload
(defun prrr-queue ()
  "Show the Review Queue of the current repository.
Turns on `prrr-queue-mode' when it is off, opens the repository's
magit-status buffer and moves point to the Review Queue."
  (interactive)
  (unless prrr-queue-mode
    (prrr-queue-mode 1))
  (magit-status-setup-buffer)
  (if-let ((section (magit-get-section '((prrr-queue) (status)))))
      (magit-section-goto section)
    (user-error "No Review Queue here: prrr needs a GitHub repository tracked by forge")))
```

In SPEC.md section 5, after the first paragraph's first sentence, add: "The section is turned on by the global minor mode `prrr-queue-mode`. `prrr-queue` turns it on when needed."

- [ ] **Step 4: Run all gates**

Run: `make compile lint test`
Expected: all pass (162 + 9 = 171).

- [ ] **Step 5: Smoke-test in a real Emacs**

Use the emacsclient skill, or `emacs -Q` with the `.deps` load path, in any GitHub repository tracked by forge:

```elisp
(prrr-queue-mode 1)
(magit-status)
```

Expected: a `Review Queue (pulling…)` heading above forge's `Pull requests` section, replaced within seconds by the groups. Record what you saw in the commit body. If no tracked repository is available, say so in the report instead of claiming the check.

- [ ] **Step 6: Close the bead and commit**

```bash
bd close prrr-knu.4 --reason="prrr-db-take-preserved-outbox hands rows out once; the Review Queue warns about them and the variable is cleared"
git add prrr-queue.el test/prrr-queue-test.el SPEC.md
git commit -m "feat(queue): Review Queue section in magit-status with prrr-queue-mode and background pull"
```

---

### Task 9: Keys, commands, Stack moves, transient, and a light `prrr.el` (prrr-knu.6)

**Files:**
- Modify: `prrr.el`
- Modify: `prrr-queue.el` (fill the keymaps, autoloads for commands defined later, Stack move helper)
- Create: `prrr-stack.el`
- Create: `prrr-transient.el`
- Create: `test/prrr-test.el`
- Modify: `test/prrr-queue-test.el`
- Modify: `test/prrr-test-helper.el` (no longer relies on `prrr` loading the other files)
- Modify: `Makefile` (`SRC` order: `prrr-db.el prrr-github.el prrr-state.el prrr-sync.el prrr-queue.el prrr-stack.el prrr-transient.el prrr.el`; `TESTS` gains `test/prrr-test.el`)
- Modify: `SPEC.md` sections 2 and 9

**Interfaces:**
- Consumes: `prrr-queue--rows`, `prrr-state-stack-neighbour` (Task 3), `prrr-pull` (Task 6).
- Produces:
  - `prrr.el`: `(prrr-current-pullreq)` → `forge-pullreq` or `user-error`; commands `prrr-open-topic`, `prrr-browse`, `prrr-checkout`.
  - `prrr-queue.el`: `(prrr-queue-entry-at-point)` → `prrr-queue-entry` or nil; `(prrr-queue-move-in-stack DIRECTION)` → non-nil when point moved.
  - `prrr-stack.el`: commands `prrr-stack-up`, `prrr-stack-down`.
  - `prrr-transient.el`: prefix `prrr-queue-menu`; suffixes `prrr-queue-toggle-drafts`, `prrr-queue-toggle-served`.

- [ ] **Step 1: Write the failing tests**

Create `test/prrr-test.el` (standard header, Commentary "The package entry point: what loading prrr.el costs, and the shared PR commands."):

```elisp
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'forge)          ; loaded before the stubs below replace its functions
(require 'prrr-test-helper)
(require 'prrr)

(ert-deftest prrr-test-require-prrr-does-not-load-forge ()
  "prrr-knu.6: loading prrr.el loads neither forge, magit nor the database."
  (let ((output
         (with-temp-buffer
           (call-process (expand-file-name invocation-name invocation-directory)
                         nil '(t nil) nil
                         "-Q" "--batch"
                         "--eval" (format "(progn (setq package-user-dir %S) (package-initialize))"
                                          package-user-dir)
                         "-L" prrr-test-root
                         "--eval" "(progn (require 'prrr) (prin1 (list (featurep 'forge) (featurep 'magit) (featurep 'emacsql))))")
           (buffer-string))))
    (should (equal "(nil nil nil)" (string-trim output)))))

(ert-deftest prrr-test-current-pullreq-signals-without-one ()
  (cl-letf (((symbol-function 'forge-current-pullreq) #'ignore))
    (should-error (prrr-current-pullreq) :type 'user-error)))

(ert-deftest prrr-test-shared-commands-act-on-current-pullreq ()
  (let ((pullreq (forge-pullreq :id "forge-1" :number 1))
        (calls nil))
    (cl-letf (((symbol-function 'forge-current-pullreq) (lambda (&rest _) pullreq))
              ((symbol-function 'forge-visit-topic) (lambda (topic) (push (cons 'visit topic) calls)))
              ((symbol-function 'forge-browse-pullreq) (lambda (pr) (push (cons 'browse pr) calls)))
              ((symbol-function 'forge-checkout-pullreq) (lambda (pr) (push (cons 'checkout pr) calls))))
      (prrr-open-topic)
      (prrr-browse)
      (prrr-checkout))
    (should (equal (list (cons 'checkout pullreq) (cons 'browse pullreq) (cons 'visit pullreq))
                   calls))))

(provide 'prrr-test)
;;; prrr-test.el ends here
```

Append to `test/prrr-queue-test.el` before `(provide ...)`:

```elisp
;;;; Keys, Stack moves and the menu

(require 'prrr-stack)
(require 'prrr-transient)

(defun prrr-queue-test--stack-inputs ()
  "Inputs with a three-PR Stack in For Me and a lone PR."
  (prrr-queue-test--inputs
   (list (prrr-queue-test--pair :id "ONE" :number 1 :head-ref "s1")
         (prrr-queue-test--pair :id "TWO" :number 2 :base-ref "s1" :head-ref "s2")
         (prrr-queue-test--pair :id "THREE" :number 3 :base-ref "s2" :head-ref "s3")
         (prrr-queue-test--pair :id "LONE" :number 4 :head-ref "lone"))
   (mapcar (lambda (id) (prrr-test-meta :pr-id id :review-requests '((user "example-me"))))
           '("ONE" "TWO" "THREE" "LONE"))))

(ert-deftest prrr-queue-test-stack-up-and-down-move-between-rows ()
  (prrr-queue-test--with-render (prrr-queue-test--stack-inputs)
    (prrr-queue-test--line-of 1)
    (prrr-stack-up)
    (should (looking-at "#2 "))
    (prrr-stack-up)
    (should (looking-at "#3 "))
    (should-error (prrr-stack-up) :type 'user-error)
    (prrr-stack-down)
    (should (looking-at "#2 "))))

(ert-deftest prrr-queue-test-stack-move-outside-a-row-signals ()
  (prrr-queue-test--with-render (prrr-queue-test--stack-inputs)
    (should-error (prrr-stack-up) :type 'user-error)))

(ert-deftest prrr-queue-test-lone-pr-has-no-stack-neighbour ()
  (prrr-queue-test--with-render (prrr-queue-test--stack-inputs)
    (prrr-queue-test--line-of 4)
    (should-error (prrr-stack-down) :type 'user-error)))

(defun prrr-queue-test--menu-command (key)
  "Return the command bound to KEY in `prrr-queue-menu'."
  (let ((suffix (transient-get-suffix 'prrr-queue-menu key)))
    (plist-get (if (vectorp suffix) (aref suffix 2) (cdr suffix)) :command)))

(ert-deftest prrr-queue-test-menu-mirrors-row-keys ()
  "SPEC section 9: every row key has the same key and command in the menu."
  (dolist (key '("RET" "o" "b" "B" ">" "<" "G"))
    (should (eq (keymap-lookup prrr-queue-section-map key)
                (prrr-queue-test--menu-command key))))
  (should (eq 'prrr-queue-menu (keymap-lookup prrr-queue-section-map "C-o")))
  (should (eq 'prrr-queue-menu (keymap-lookup prrr-queue-heading-map "C-o")))
  (should (eq 'prrr-pull (keymap-lookup prrr-queue-heading-map "G"))))

(ert-deftest prrr-queue-test-menu-toggles ()
  (should (eq 'prrr-queue-toggle-drafts (prrr-queue-test--menu-command "-d")))
  (should (eq 'prrr-queue-toggle-served (prrr-queue-test--menu-command "-s")))
  (let ((prrr-queue-show-served t))
    (cl-letf (((symbol-function 'magit-refresh) #'ignore))
      (call-interactively #'prrr-queue-toggle-served))
    (should-not prrr-queue-show-served)))
```

Add `test/prrr-test.el` to `TESTS`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: the new tests FAIL. The load test prints `(t t t)`, because `prrr.el` still requires the database, GitHub and state files. The other new tests fail with `void-function` or `Cannot open load file ... prrr-stack`.

- [ ] **Step 3: Rewrite `prrr.el`**

Replace everything from `;;; Commentary:` to the end with:

```elisp
;;; Commentary:

;; prrr reviews GitHub pull requests inside Emacs on top of magit and
;; forge: a Review Queue in magit-status, a Review Buffer with Threads
;; inline, and a server-side Pending Review with batched Submit.
;;
;; This file is the entry point.  It holds the customization group and
;; the commands shared by the Review Queue and the Review Buffer, and
;; loads nothing else: every other command is reached through an
;; autoload, so `(require 'prrr)' at startup costs no forge, magit or
;; database load.  Turn the Review Queue on with `prrr-queue-mode'.

;;; Code:

(defgroup prrr nil
  "Review GitHub pull requests with magit and forge."
  :group 'tools
  :prefix "prrr-")

(declare-function forge-current-pullreq "forge-pullreq" (&optional demand))
(declare-function forge-visit-topic "forge-commands" (topic))
(declare-function forge-browse-pullreq "forge-commands" (pull-request))
(declare-function forge-checkout-pullreq "forge-commands" (pullreq))

(defun prrr-current-pullreq ()
  "Return forge's pull request at point or being visited.
Signal a `user-error' when there is none."
  (require 'forge)
  (or (forge-current-pullreq)
      (user-error "No pull request here")))

;;;###autoload
(defun prrr-open-topic ()
  "Show the current pull request in forge's topic buffer."
  (interactive)
  (forge-visit-topic (prrr-current-pullreq)))

;;;###autoload
(defun prrr-browse ()
  "Open the current pull request on GitHub."
  (interactive)
  (forge-browse-pullreq (prrr-current-pullreq)))

;;;###autoload
(defun prrr-checkout ()
  "Check out the current pull request's branch with forge."
  (interactive)
  (forge-checkout-pullreq (prrr-current-pullreq)))

(provide 'prrr)
;;; prrr.el ends here
```

`test/prrr-test-helper.el` already requires `prrr-db` and (since Task 1) `prrr-state`. Each test file requires the file it tests, so nothing else changes. Run `make test TESTS=test/prrr-db-test.el` to confirm.

- [ ] **Step 4: Fill the keymaps and add the Stack helper in `prrr-queue.el`**

Add `(require 'prrr)` after `(require 'prrr-sync)` (it is light, and it defines the shared commands). Replace the two keymap definitions with:

```elisp
(autoload 'prrr-stack-up "prrr-stack" nil t)
(autoload 'prrr-stack-down "prrr-stack" nil t)
(autoload 'prrr-queue-menu "prrr-transient" nil t)

(defvar-keymap prrr-queue-heading-map
  :doc "Keys on the Review Queue heading and its group headings."
  "G" #'prrr-pull
  "C-o" #'prrr-queue-menu)

(defvar-keymap prrr-queue-section-map
  :doc "Keys on a Review Queue row (SPEC section 9).
RET opens forge's topic buffer until the Review Buffer arrives."
  :parent prrr-queue-heading-map
  "RET" #'prrr-open-topic
  "o" #'prrr-open-topic
  "b" #'prrr-browse
  "B" #'prrr-checkout
  ">" #'prrr-stack-up
  "<" #'prrr-stack-down)
```

Append the row helpers before `(provide 'prrr-queue)`:

```elisp
;;;; Rows

(defun prrr-queue-entry-at-point ()
  "Return the `prrr-queue-entry' of the Review Queue row at point, or nil."
  (cdr (assq (magit-current-section) prrr-queue--rows)))

(defun prrr-queue-move-in-stack (direction)
  "Move point to the next row of the current row's Stack in DIRECTION.
DIRECTION is `up' or `down'.  Only the displayed rows of the current
Queue Group are considered.  Return non-nil when point moved; signal a
`user-error' when point is not on a Review Queue row."
  (let* ((entry (or (prrr-queue-entry-at-point)
                    (user-error "Not on a Review Queue row")))
         (group (prrr-queue-entry-group entry))
         (target (prrr-state-stack-neighbour
                  (mapcar #'cdr (seq-filter (lambda (row) (eq (prrr-queue-entry-group (cdr row)) group))
                                            prrr-queue--rows))
                  entry direction)))
    (when target
      (magit-section-goto (car (rassq target prrr-queue--rows)))
      t)))
```

- [ ] **Step 5: Create `prrr-stack.el`**

Standard header (description: `Moving up and down a Stack`), then:

```elisp
;;; Commentary:

;; Stack navigation (SPEC section 8).  In the Review Queue `>' and `<'
;; move point to the next row of the same Stack.  The Review Buffer
;; opens the neighbouring PR instead; that arrives in milestone 5.

;;; Code:

(require 'prrr-queue)

(defun prrr-stack--move (direction)
  "Move to the PR next to the current one in its Stack, in DIRECTION."
  (unless (prrr-queue-move-in-stack direction)
    (user-error (if (eq direction 'up) "Top of the Stack" "Bottom of the Stack"))))

;;;###autoload
(defun prrr-stack-up ()
  "Move to the pull request above the current one in its Stack."
  (interactive)
  (prrr-stack--move 'up))

;;;###autoload
(defun prrr-stack-down ()
  "Move to the pull request below the current one in its Stack."
  (interactive)
  (prrr-stack--move 'down))

(provide 'prrr-stack)
;;; prrr-stack.el ends here
```

- [ ] **Step 6: Create `prrr-transient.el`**

Standard header (description: `Transient menus for prrr`), then:

```elisp
;;; Commentary:

;; Every transient prefix (SPEC section 9).  Each menu mirrors the keys
;; of the buffer or section it belongs to, so a key works the same with
;; and without the menu.  The Review Buffer's `prrr-menu' arrives in
;; milestone 3.

;;; Code:

(require 'transient)
(require 'magit-mode)
(require 'prrr)
(require 'prrr-queue)
(require 'prrr-stack)
(require 'prrr-sync)

(defun prrr-transient--shown (what value)
  "Describe a toggle for WHAT that is on when VALUE is non-nil."
  (concat "show " what " "
          (propertize (if value "[on]" "[off]")
                      'face (if value 'transient-value 'transient-inactive-value))))

(transient-define-suffix prrr-queue-toggle-drafts ()
  "Show or hide draft pull requests in the Review Queue."
  :transient t
  :description (lambda () (prrr-transient--shown "drafts" prrr-queue-show-drafts))
  (interactive)
  (setq prrr-queue-show-drafts (not prrr-queue-show-drafts))
  (magit-refresh))

(transient-define-suffix prrr-queue-toggle-served ()
  "Show or hide the Served partition of the Review Queue."
  :transient t
  :description (lambda () (prrr-transient--shown "Served" prrr-queue-show-served))
  (interactive)
  (setq prrr-queue-show-served (not prrr-queue-show-served))
  (magit-refresh))

;;;###autoload (autoload 'prrr-queue-menu "prrr-transient" nil t)
(transient-define-prefix prrr-queue-menu ()
  "Act on the Review Queue (SPEC section 9)."
  ["Show"
   ("-d" prrr-queue-toggle-drafts)
   ("-s" prrr-queue-toggle-served)]
  [["Pull request"
    ("RET" "open topic" prrr-open-topic)
    ("o" "open topic" prrr-open-topic)
    ("b" "browse on GitHub" prrr-browse)
    ("B" "checkout" prrr-checkout)]
   ["Stack"
    (">" "up" prrr-stack-up)
    ("<" "down" prrr-stack-down)]
   ["Sync"
    ("G" "pull" prrr-pull)]])

(provide 'prrr-transient)
;;; prrr-transient.el ends here
```

Update `SRC` in the `Makefile` to `prrr-db.el prrr-github.el prrr-state.el prrr-sync.el prrr-queue.el prrr-stack.el prrr-transient.el prrr.el`.

- [ ] **Step 7: Update SPEC.md**

- Section 2, `prrr.el` row, Purpose: "Package entry: `defgroup`, the commands shared by the Review Queue and Review Buffer (`prrr-open-topic`, `prrr-browse`, `prrr-checkout`; `prrr-review` arrives with the Review Buffer). Loads nothing else; every command is autoloaded. Options that belong to one file are defined in that file." Depends on: "nothing at load time".
- Section 2, `prrr-queue.el` row: add "`prrr-queue-mode` and the `prrr-queue` command".
- Section 9, Review Queue table, `RET` row: append "(until milestone 3, `prrr-open-topic`)".

- [ ] **Step 8: Run all gates**

Run: `make compile lint test`
Expected: all pass (171 + 8 = 179). If byte-compiling `prrr-queue.el` warns that `prrr-pull` is unknown, check that `(require 'prrr-sync)` precedes the keymap. If checkdoc objects to the `;;;###autoload (autoload ...)` line, keep the cookie exactly as written. Transient's own manual uses that form.

- [ ] **Step 9: Close the bead and commit**

```bash
bd close prrr-knu.5 --reason="Rows indent by visible depth and keep their true k/n marker; Stack moves skip hidden rows (Tasks 3, 7, 9)"
bd close prrr-knu.6 --reason="prrr.el loads nothing; commands are autoloaded; the section is enabled with prrr-queue-mode; a subprocess test pins it"
git add prrr.el prrr-queue.el prrr-stack.el prrr-transient.el Makefile SPEC.md test/prrr-test.el test/prrr-queue-test.el test/prrr-test-helper.el
git commit -m "feat(queue): row keys, Stack moves and prrr-queue-menu; prrr.el loads nothing"
```

---

### Task 10: Review Queue render budget

**Files:**
- Create: `bench/prrr-queue-bench.el`
- Modify: `Makefile` (`bench` target; `compile` and `lint` also cover `bench/*.el`)

**Interfaces:**
- Consumes: `prrr-queue-insert` (Task 7).
- Produces: `make bench` prints `queue render, 200 PRs: X.X ms (budget 20 ms)` and exits non-zero when the median exceeds the budget by more than 25 percent (SPEC sections 12 and 13).

- [ ] **Step 1: Write the benchmark**

Create `bench/prrr-queue-bench.el` (standard header; Commentary: "SPEC section 12: render the Review Queue from the database for 200 PRs within 20 ms. Run with `make bench'."):

```elisp
;;; Code:

(require 'cl-lib)
(require 'prrr-queue)

(defconst prrr-queue-bench-budget-ms 20.0
  "SPEC section 12 budget for rendering 200 PRs.")

(defconst prrr-queue-bench-tolerance 1.25
  "A run fails when the median exceeds the budget by more than this factor.")

(defun prrr-queue-bench--inputs (count)
  "Return `prrr-queue-insert' inputs for COUNT PRs, a fifth of them stacked."
  (let (pairs metas)
    (dotimes (i count)
      (let* ((id (format "PR_%04d" i))
             (stacked (and (> i 0) (zerop (% i 5))))
             (pr (prrr-pr-create
                  :id id :number (1+ i) :title (format "Change number %d of the example" i)
                  :author (if (zerop (% i 7)) "example-me" "example-alice")
                  :draft-p (zerop (% i 11))
                  :created-at (format-time-string "%Y-%m-%dT%H:%M:%SZ" (- 1790000000 (* i 3600)) t)
                  :updated-at "2026-10-09T00:00:00Z"
                  :head-oid "1111111111111111111111111111111111111111"
                  :base-ref (if stacked (format "branch-%d" (1- i)) "main")
                  :head-ref (format "branch-%d" i))))
        (push (cons (forge-pullreq :id (format "forge-%d" i) :number (1+ i) :their-id id) pr) pairs)
        (push (prrr-pr-meta-create
               :pr-id id :head-oid "1111111111111111111111111111111111111111"
               :review-requests (and (zerop (% i 2)) '((user "example-me")))
               :viewer-latest-review (and (zerop (% i 3))
                                          '("APPROVED" "2026-10-01T00:00:00Z"
                                            "0000000000000000000000000000000000000000")))
              metas)))
    (list :pairs (nreverse pairs) :metas metas :teams '("example-org/reviewers")
          :me "example-me" :default-branch "main" :unresolved (make-hash-table :test #'equal)
          :status nil :now "2026-10-10T12:00:00Z" :width 120)))

(defun prrr-queue-bench--render-ms (inputs)
  "Render INPUTS once into a fresh buffer; return the elapsed milliseconds."
  (with-temp-buffer
    (magit-section-mode)
    (let ((inhibit-read-only t)
          (start (float-time)))
      (magit-insert-section (status)
        (prrr-queue-insert inputs))
      (* 1000 (- (float-time) start)))))

(defun prrr-queue-bench-run ()
  "Measure the Review Queue render, print the median, exit 1 over budget."
  (let* ((inputs (prrr-queue-bench--inputs 200))
         (_warmup (dotimes (_ 3) (prrr-queue-bench--render-ms inputs)))
         (runs (sort (cl-loop repeat 21 collect (prrr-queue-bench--render-ms inputs)) #'<))
         (median (nth 10 runs)))
    (message "queue render, 200 PRs: %.1f ms (budget %.0f ms)" median prrr-queue-bench-budget-ms)
    (kill-emacs (if (> median (* prrr-queue-bench-budget-ms prrr-queue-bench-tolerance)) 1 0))))

(provide 'prrr-queue-bench)
;;; prrr-queue-bench.el ends here
```

- [ ] **Step 2: Wire it into the Makefile**

```make
bench:
	$(BATCH) -L bench -l bench/prrr-queue-bench.el -f prrr-queue-bench-run
```

Add `$(wildcard bench/*.el)` next to `$(wildcard test/*.el)` in the `compile` target (and its `rm -f`: add `bench/*.elc`) and in the checkdoc half of `lint`.

- [ ] **Step 3: Run it**

Run: `make bench`
Expected: a line `queue render, 200 PRs: X ms (budget 20 ms)` and exit status 0.
If it fails the budget, profile with `(profiler-start 'cpu)` around `prrr-queue-bench--render-ms`. Likely costs are `truncate-string-to-width` and the per-row `string-width`. Fix the cost in `prrr-queue.el` and re-run the full gates. Do not raise the budget; it is SPEC section 12's. Report the measured number in the commit body.

- [ ] **Step 4: Run all gates and commit**

```bash
make compile lint test bench
git add bench/prrr-queue-bench.el Makefile
git commit -m "bench: Review Queue render budget for 200 PRs"
```

---

### Task 11: README, and the README rule for later milestones

**Files:**
- Create: `README.md`
- Modify: `CLAUDE.md` and `AGENTS.md` (Conventions: the README grows with each milestone)
- Modify: `SPEC.md` section 15, item 8

**Interfaces:**
- Consumes: every user-visible name from Tasks 6-9.
- Produces: `README.md` with the sections below, which later milestones extend in place.

- [ ] **Step 1: Write `README.md`**

```markdown
# prrr 🐱

Review GitHub pull requests in Emacs, on top of [magit](https://magit.vc)
and [forge](https://github.com/magit/forge).

prrr puts the pull requests that need you in your magit-status buffer,
oldest first, with Stacks of dependent PRs kept together. Upcoming
milestones add a Review Buffer that shows the diff with existing threads
inline, line and range comments, a pending review submitted in one batch,
and "what changed since my last review".

> **Status:** early development. The Review Queue works. The Review
> Buffer, commenting and submitting are next. See the milestones in
> [`SPEC.md`](SPEC.md#15-milestones).

## Requirements

- Emacs 29.1 or later
- magit 4.7, forge 0.5, emacsql 4.4, transient 0.13, compat 31
- A GitHub token that forge can use (see forge's manual,
  [Setup for GitHub](https://docs.magit.vc/forge/Setup-for-Githubcom.html))

## Install

prrr is not on MELPA yet. Install from source with `package-vc`:

```elisp
(package-vc-install "https://github.com/whargrove/prrr")
```

Or clone the repository, add it to `load-path`, and `(require 'prrr)`.
Loading prrr loads nothing else; its commands are autoloaded.

## Setup

1. Make sure forge tracks the repository (`M-x forge-add-repository`).
2. Tell prrr who you are. prrr uses forge's convention, the `github.user`
   Git variable:

   ```sh
   git config --global github.user YOUR-LOGIN
   ```

   or set `prrr-github-user`.
3. Turn on the Review Queue section once forge is loaded:

   ```elisp
   (with-eval-after-load 'forge
     (prrr-queue-mode 1))
   ```

   `M-x prrr-queue` also turns it on and jumps to it.

## The Review Queue

The Review Queue sits above forge's pull request list in magit-status. It
has two groups:

- **For me**: PRs by others that want your review, because it was
  requested from you or one of your teams, they are assigned to you, or
  you reviewed them before. **Awaiting me** comes first, oldest PR first.
  **Served** follows: PRs you already handled, by when you last touched
  them.
- **Mine**: your own open PRs, those needing your action first: changes
  requested, then awaiting review, approved, reviewed, draft.

Each row reads `#number  state  title  author  ⟰ k/n  N unresolved  age`.
A Stack (each PR based on the branch of the one below) stays together,
bottom first, with `⟰ k/n` marking each PR's place in it.

The queue renders from a local database. It pulls in the background when
its data is older than `prrr-queue-stale-after` seconds (default 300). The
heading shows `pulling…`, `offline`, `rate limited until 14:05`, or the
error.

### Keys on a queue row

| Key   | Command           | Does                                                |
|-------|-------------------|-----------------------------------------------------|
| `RET` | `prrr-open-topic` | Open the PR (forge's topic buffer for now)          |
| `o`   | `prrr-open-topic` | Open forge's topic buffer                           |
| `b`   | `prrr-browse`     | Open the PR on GitHub                               |
| `B`   | `prrr-checkout`   | Check out the PR's branch                           |
| `>`   | `prrr-stack-up`   | Move to the PR above in the Stack                   |
| `<`   | `prrr-stack-down` | Move to the PR below in the Stack                   |
| `G`   | `prrr-pull`       | Pull PRs (`forge-pull`) and the queue's data now    |
| `C-o` | `prrr-queue-menu` | Menu with the same keys, plus `-d` drafts, `-s` Served |

### Commands

- `prrr-queue`: show the Review Queue of the current repository.
- `prrr-pull`: pull now.
- `prrr-refresh-teams`: fetch your GitHub teams again (done daily anyway).

### Options

| Option                   | Default | Meaning                                         |
|--------------------------|---------|-------------------------------------------------|
| `prrr-github-user`       | `nil`   | Your login; `nil` reads `github.user`           |
| `prrr-queue-stale-after` | `300`   | Seconds before the queue's data is pulled again |
| `prrr-queue-show-drafts` | `t`     | Show draft PRs                                  |
| `prrr-queue-show-served` | `t`     | Show the Served partition                       |
| `prrr-database-file`     | `prrr-database.sqlite` in `user-emacs-directory` | prrr's own database |

prrr keeps its data in its own SQLite file and never writes to forge's
database.

## Development

```sh
make deps     # install dependencies into .deps/
make compile  # byte-compile, warnings are errors
make lint     # package-lint and checkdoc
make test     # ERT suite, no network
make bench    # performance budgets from SPEC.md section 12
```

Read `CONTEXT.md` (the glossary) and `SPEC.md` (the design) first.

## License

GPL-3.0-or-later. See [`LICENSE`](LICENSE).
```

Check every claim against the code before committing:
- every command and option name exists (`grep -n "defun prrr-pull\|defcustom prrr-queue-show" *.el`);
- the key table matches `prrr-queue-section-map`;
- the forge manual link resolves (`curl -sI` it; if it moved, link https://docs.magit.vc/forge/ instead).

- [ ] **Step 2: Record the README rule**

In `CLAUDE.md`, under "Conventions & Patterns", add:

```markdown
- `README.md` grows with every milestone: a milestone's last task adds its
  user-visible commands, keys and options, and updates the Status note.
```

Make the same edit in `AGENTS.md` if it has the same section. The Beads note says the two files are independent and must be mirrored. Then:

```bash
bd remember "README.md is maintained incrementally: each milestone's final task documents its new commands, keys and options and updates the Status note (user request 2026-10-10)."
```

In SPEC.md section 15, item 8, change "README" to "README polish (the README grows with each milestone)".

- [ ] **Step 3: Run all gates and commit**

```bash
make compile lint test
git add README.md CLAUDE.md AGENTS.md SPEC.md
git commit -m "docs: README for the Review Queue milestone; README grows per milestone"
```

- [ ] **Step 4: Close the milestone**

```bash
bd show prrr-knu        # every child closed
bd close prrr-knu --reason="Milestone 2 shipped: prrr-pull, Teams, Review Queue section, FIFO ordering, Stacks, keymap and transient; carry-overs knu.1-7 resolved"
git status
```

Report the measured bench number and the smoke-test observation from Task 8. Also report what was not verified against a live GitHub repository.
