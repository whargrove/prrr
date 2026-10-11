# Commenting and Pending Review Milestone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship milestone 4 of `prrr` (SPEC.md section 15, item 4): comment on a line, a range or a file of the Review Buffer in a capture buffer, reply, edit, delete, resolve, suggest changes, post Discussion Comments, publish one comment at once, and submit the Pending Review with a Verdict or discard it, every write optimistic and kept in an Outbox until GitHub accepts it.

**Architecture:** One deep module, the Outbox in `prrr-sync.el`, is the only write path: a command describes a write (a kind and a payload) and calls `prrr-sync-write`; the Outbox stores it, sends one mutation at a time a second apart, creates or reuses the Pending Review, maps local ids to GitHub's, records failures, pauses on rate limits, and retries. The database tables keep only what GitHub sent or accepted; unsent writes live only in the `outbox` table, and what the user sees is the pure overlay `prrr-state-outbox-view` of the queued writes on the stored rows, so a refetch never loses an unsent comment and a discarded write needs no undo. The capture buffer and the rendering of unsent, failed and suggested changes live in `prrr-thread.el`; anchors come from `prrr-diff.el`; the commands live in a new `prrr-review.el`.

**Tech Stack:** Emacs Lisp (Emacs 29.1+), magit 4.7 (`magit-insert-section`, `magit-section-at`), forge 0.5 (`forge-mutate`, `forge-rest`, `forge-query`, `forge-pull-topic`, `forge-buffer-topic`), ghub (`ghub-query` with forge's token, three mutations only), emacsql 4.4, transient 0.13, markdown-mode (forge's dependency), git, ERT.

**Spec:** `SPEC.md` sections 2, 3, 4 (mutation table and Limits), 7, 9, 11, 15. Glossary: `CONTEXT.md`. Research: `docs/research/review-comment-api.md` and `docs/research/threads-viewed-api.md`. Decisions: `bd show prrr-t9q.7` (data model and write rules) and `bd show prrr-t9q.2` (GitHub API for the review lifecycle). Earlier facts: the "Milestone-3 facts" of `docs/superpowers/plans/2026-10-10-review-buffer.md`.

**Beads:** epic `prrr-qqu`; tasks in order `prrr-qqu.1` to `prrr-qqu.14` (Task N is `prrr-qqu.N`), each depending on the one before. `prrr-8ok` (refetch must keep unsent rows) depends on `prrr-qqu.7`, which resolves it; Task 7 closes it.

## Milestone-4 facts (verified 2026-10-10 against forge 20261006.1249, ghub 20261001.1601, transient 20261001.1359, magit 20261009.1317, markdown-mode 20261009.18, emacsql 20261001.1544, Emacs 30.2)

Every fact below was read in the installed source under `.deps/` or checked in an `emacs -Q --batch` experiment. The code of every task was run in a throwaway copy of the repository before this plan was written: `make compile`, `make lint` and the full ERT suite (389 tests) pass on the end state, and `make bench` reports the Review Buffer within budget (open 417 files 117 ms, 2,516 files 361 ms, expand 2 ms, refresh 133 ms). `make bench` exits non-zero today because the Review Queue measures 28 ms against a 25 ms fail line; that is bead `prrr-opy`, untouched by this milestone.

**ghub and forge**
- `forge-mutate` (forge-client.el:47) sends `(mutation (NAME [(input $input NAMEInput!)] clientMutationId))` built by `ghub--prepare-mutation` (forge-client.el:102). Its selection is fixed to `clientMutationId`, so it cannot return the id of a Thread or comment it created. prrr needs those ids (a reply to a just-created Thread, an edit of a just-sent comment), so the three mutations whose answer prrr reads (`addPullRequestReview`, `addPullRequestReviewThread`, `addPullRequestReviewThreadReply`) are sent with `ghub-query` and `:auth 'forge :host HOST :forge 'github`, exactly the arguments `forge--query` passes (forge-client.el:29). Every other mutation keeps `forge-mutate`.
- `ghub-query` (ghub-graphql.el:68) hoists `(input $input Type!)` into the operation's variable list (ghub-graphql.el:133). Encoded in batch, `(mutation (addPullRequestReviewThread [(input $input AddPullRequestReviewThreadInput!)] (thread id (comments [(first 1)] (nodes id createdAt fullDatabaseId)))))` becomes `mutation ($input: AddPullRequestReviewThreadInput!) { addPullRequestReviewThread (input: $input) { thread { id comments (first: 1) { nodes { id createdAt fullDatabaseId } } } } }`.
- The callback of `ghub-query` receives `(data (FIELD ...))`; `alist-get` skips the leading symbol `data`. A GraphQL error reaches the errorback as `(errors ERROR...)` (ghub-graphql.el:203).
- `forge-rest` (forge-client.el:78) expands its params with `forge--prepare-variables` (forge-client.el:117), which accepts `(and COND (NAME VALUE))` for optional fields. It calls `ghub-request` with `:callback` and `:errorback`; the callback receives `(VALUE HEADERS STATUS REQ)`. With a callback, ghub sets `noerror` (ghub.el:330) and appends the error's JSON body to the error, so an HTTP 422 reaches the errorback as `(error http 422 PAYLOAD)` (ghub.el:564).
- `forge-pull-topic` (forge-commands.el:205) is a transient suffix; the byte compiler rejects a plain call ("is for interactive use only"), so prrr calls it with `funcall-interactively`. For a pull request it runs `forge--pull-topic-1`, whose callback calls `forge-refresh-buffer` in the buffer current when the request was made (forge-github.el:453); that refreshes any `magit-mode` buffer (forge-core.el:408), so a Review Buffer redraws with the new Discussion Comment.
- forge requires markdown-mode 2.8 (forge-pkg.el:12); `forge-post-mode` derives from `gfm-mode` (forge-post.el:119). markdown-mode binds `C-c C-c` (a prefix), `C-c C-k` and `C-c C-i` (markdown-mode.el:5693, 5721, 5785); a derived mode's own bindings of those keys win. `(require 'markdown-mode nil t)` passes package-lint without a `Package-Requires` entry.

**transient**
- `transient-args` (transient.el:4268) returns the active arguments when the current command was invoked from that prefix, and the saved value otherwise; so a command checks `transient-current-command` first. `transient-arg-value` (transient.el:4434) gives a switch's state.

**emacsql and Emacs**
- emacsql stores and reads back any printable Lisp value: a plist payload with strings, symbols and nested plists round-trips unchanged.
- `[:update outbox :set (= last-error $s1) :where (= pr-id $s2)]` with `$s1` bound to nil writes SQL NULL; `[:select * :from outbox :order-by [(asc id)]]` orders by the id column.
- `copy-sequence` copies a `cl-defstruct` record; `(setf (cl-struct-slot-value TYPE SLOT COPY) VALUE)` changes the copy only.
- `prrr-db-insert` is insert-or-replace, which moves a replaced row to the end of rowid order: the Outbox orders by its id, not by rowid.
- The byte compiler measures docstring lines after substituting `\\[command]`; a backslash-newline inside a docstring joins lines, which can make one too wide.
- In batch, `format-mode-line` of a header line with `:eval` returns "" when the buffer has no window; tests call the header function instead.
- A function that calls `pop-to-buffer` leaves the popped buffer current for the rest of the command, so a test that opens a capture buffer continues there.

**GitHub (from the research docs; unverified items are marked)**
- A `PullRequestReviewComment` has no field naming its Thread (threads-viewed-api.md, section 1), and the REST answer to `POST /repos/{o}/{r}/pulls/{n}/comments` is a review comment, so after Immediate Publish of a new comment prrr knows the comment's node id and database id but not its Thread's id until the next refetch.
- REST replies need the database id of the Thread's first comment (`fullDatabaseId`; review-comment-api.md, section 3). Whether GitHub sends `fullDatabaseId` (a `BigInt`) as a string or a number is unverified: prrr formats either as a string.
- Unverified (review-comment-api.md, open items 1 and 2): what REST Immediate Publish does while the viewer has a Pending Review. If GitHub refuses it (an HTTP 422), the comment stays in the Outbox, marked failed with GitHub's message.

## Decisions taken in this plan

- **The Outbox is the one write path, in `prrr-sync.el`.** `prrr-sync-write` takes a kind and a payload (documented once, in `prrr-state-outbox-kinds`) and owns everything after: local ids, storage, order, spacing, the 80-a-minute creation limit, the Pending Review, id renames, failures, rate-limit pauses, retries and the refetch after writing. It stays in `prrr-sync.el`, as SPEC section 2 says, because writes and refetches are one problem: a refetch must not store an answer a write raced, and the Outbox refetches once it has written. Viewed moves onto it, replacing milestone 3's write-then-restore fallback.
- **Unsent writes live only in the `outbox` table; the view is an overlay.** SPEC section 7 says a write "writes a local row with `local-state` `unsent`". Instead the `thread`, `review-comment`, `pending-review` and `viewed` tables hold only what GitHub sent or accepted, and `prrr-state-outbox-view` applies the queued writes to them whenever a buffer draws. A refetch can then replace those tables wholesale (bead `prrr-8ok` is resolved by design), a discarded write needs no undo, and a failed delete leaves the comment in view. A write's success stores GitHub's confirmed rows at once. `local-state` keeps `sent` and, in milestone 7, `proposed`; the overlay marks unsent rows `unsent`. SPEC sections 3 and 7 are corrected in Task 14.
- **Order: per PR, strictly; across PRs, oldest first.** A PR's writes go out in the order they were made, so a reply never overtakes its Thread and Submit never overtakes its comments. A failed write holds back its PR's later writes (other PRs go on) until a retry, which happens on the next write to that PR, on its refetch, or through `O r`. Edit or delete of a comment whose own write is queued and not being sent changes or drops that write (and the writes that need it) instead of calling GitHub.
- **Local ids and renames.** A write that creates something gets `local:` ids. When GitHub accepts it, the Outbox renames those ids in the PR's queued payloads. A write that acts on a local id waits. Immediate Publish of a new comment cannot learn its Thread's id (see facts); a reply queued to such a Thread waits until the refetch after the publish, which maps the local Thread id through the comment id (`prrr-state-thread-renames`).
- **Pending Review.** A Thread or reply of the Pending Review uses the stored Pending Review; without one, the Outbox asks GitHub (`reviews(states: PENDING, author: me)`) and creates one on the head the user commented on (`commitOID`) only when GitHub has none. Submit without a Pending Review creates and submits a review in one `addPullRequestReview` with the event.
- **`ghub-query` for three mutations.** See the facts. SPEC section 1 says "ghub is reached only through forge"; section 2 lists ghub among `prrr-github.el`'s dependencies. This plan calls `ghub-query` (ghub's public API, forge's token) in one private helper, `prrr-github--mutate`, and SPEC section 1 is corrected in Task 14. The alternative, `forge-mutate` followed by a lookup query, needs a second request per comment and cannot tell two identical comments apart.
- **Submit touches the PR; discard does not.** Submit's success records the viewer's latest review in `pullreq-meta`, which moves the PR to Served at once. SPEC section 7 also has discarding touch the PR, but Served is computed from GitHub's latest review and a discarded review leaves none, so a discard leaves the PR where it was. SPEC is corrected in Task 14. A Submit with Request changes or Comment needs a summary or a comment, as GitHub's REST documentation says; Approve may be empty.
- **Resolvable.** The refetch stores whether GitHub lets the viewer resolve or unresolve each Thread (`resolvable-p`, from `viewerCanResolve`/`viewerCanUnresolve`), and `R` refuses up front when GitHub would refuse. Together with the comment's `database-id` this changes two tables, so the schema version becomes 2; before 1.0 a version change drops every table but `outbox`.
- **The capture buffer** derives from `gfm-mode` when markdown-mode is available (it always is with forge) and from `text-mode` otherwise; it receives a label and a confirm function, never `prrr-diff`. `C-c C-c` sends from the buffer the capture started in and returns there; when the confirm function signals, the capture buffer stays so no text is lost.
- **Range rules.** Only the default Range exists until milestone 5, so every diff line is commentable: a removed line on the `left` side at its old number, any other line on the `right` at its new number; a region across hunks is refused.
- **Agents.** No agent features: a comment's `agent-p` shows an `agent` badge in the `prrr-agent` face, and Submit counts agent comments and asks before submitting them, as SPEC section 7 says. Nothing sets `agent-p` until milestone 7.
- **HTTP 422** is GitHub refusing a write ("Validation Failed"): it becomes an `error` failure carrying GitHub's message, not `offline`.

## Global Constraints

- Every `.el` file starts with `;;; NAME.el --- DESCRIPTION  -*- lexical-binding: t -*-`, carries the GPL-3.0-or-later header used by `prrr-db.el`, has `;;; Commentary:` and `;;; Code:` sections and ends with `(provide 'NAME)` and `;;; NAME.el ends here`.
- `prrr.el`'s `Package-Requires` stays exactly `((emacs "29.1") (magit "4.7") (forge "0.5") (emacsql "4.4") (transient "0.13") (compat "31"))`. markdown-mode is required softly (`(require 'markdown-mode nil t)`).
- Every symbol starts with `prrr-`; internals use `prrr-FILE--`. Struct constructors are named explicitly and copiers are disabled.
- No `forge--` symbol anywhere in the repository (SPEC 1, quality 4). forge is used only through `oref` on its classes, `forge-get-*`, `forge-current-pullreq`, `forge-read-pullreq`, `forge-pull`, `forge-pull-topic`, `forge-query`, `forge-mutate`, `forge-rest`, `forge-insert-post`, `forge-buffer-topic`, `forge-visit-topic`, `forge-browse-pullreq`, `forge-checkout-pullreq`, `magit-add-section-hook`.
- `ghub-query` is called in exactly one place, `prrr-github--mutate`; nothing else outside forge touches ghub.
- magit internals: only the two advised functions `magit-diff-hunk-line` and `magit-diff--hunk-section`, plus the `magit-section-paint` method (SPEC section 6). No other `magit--` or `magit-*--` symbol.
- No `with-eval-after-load` / `eval-after-load` in package code (package-lint fails on them).
- `prrr.el` loads nothing at load time; `(require 'prrr)` must keep loading neither forge, magit nor emacsql (`prrr-test-require-prrr-does-not-load-forge`), and every command a key or menu reaches is autoloaded there (`prrr-test-require-prrr-autoloads-every-command`).
- No personal paths, hosts, tokens or logins; tests use `example` names.
- All SQL lives in `prrr-db.el`; all GitHub calls in `prrr-github.el`; `prrr-state.el` has no buffer, network, git or forge access. Every write to GitHub goes through `prrr-sync-write`.
- Timestamps are ISO 8601 UTC strings compared with `string<`; Outbox timing (spacing, creations) uses `float-time`.
- Only Emacs 29.1 APIs: no Emacs 30 `sort` keyword arguments, no `value<`.
- Tests never touch the network: `ghub-query` and `ghub-request` are stubbed (`prrr-test-with-ghub-stub`, `prrr-test-with-ghub-dispatch`, `prrr-test-with-ghub-error-stub`, `prrr-test-with-rest-stub`), and Outbox tests run inside `prrr-test-with-outbox`, which records timers instead of setting them. git is used only on repositories tests create under `temporary-file-directory`.
- `make compile` (warnings are errors), `make lint` (package-lint + checkdoc) and `make test` must pass before every commit. A new source file joins `SRC` and a new test file `TESTS` in the `Makefile` in the task that creates it. `make bench` must report the Review Buffer within budget; its exit status is non-zero until `prrr-opy` is fixed.
- Commit after every task with a conventional message ending with the session's attribution lines. CLAUDE.md permits commits without approval; never push.
- User-visible commands, keys and options reach `README.md` in Task 14, the milestone's last task.

## Review Focus

1. **The network drops mid-review.** Offline, a refused write, or a rate limit: every comment, edit and Viewed change shows at once, a failed one is marked with GitHub's words and the header counts it, nothing is lost or reordered, the next write or refetch or `O r` retries it, and a rate limit pauses the Outbox until it resets and says so. Pinned in Task 6 (`prrr-sync-test-outbox-failure-kept-and-retried`, `prrr-sync-test-outbox-failed-write-holds-back-its-pr-only`, `prrr-sync-test-outbox-rate-limit-pauses`, `prrr-sync-test-outbox-no-answer-then-late-answer`, `prrr-diff-test-toggle-viewed-offline-shows-at-once`), Task 10 (`prrr-diff-test-header-counts-the-outbox`) and Task 12 (`prrr-review-test-comment-offline-shows-failed`).
2. **A refetch that crosses a write.** The buffer's opening refetch, `G`, or the Outbox's own refetch answering around a write's answer: no comment vanishes, none shows twice, an answer that may miss a write is fetched again. Pinned in Task 7 (`prrr-sync-test-refetch-keeps-queued-writes`, `prrr-sync-test-refetch-raced-by-a-write-is-not-stored`, `prrr-sync-test-refetch-while-a-write-is-out-is-not-stored`, `prrr-sync-test-outbox-refetches-once-done`).
3. **Acting on what GitHub has not got yet.** Reply to a Thread still in the Outbox, edit or delete an unsent comment, edit a comment while it is being sent, discard the Pending Review with comments queued, reply to a Thread published at once. Pinned in Task 6 (`prrr-sync-test-outbox-reply-to-an-unsent-thread`, `prrr-sync-test-outbox-discard-takes-dependents`), Task 7 (`prrr-sync-test-refetch-names-a-published-thread`) and Task 8 (`prrr-sync-test-outbox-edit-amends-an-unsent-comment`, `prrr-sync-test-outbox-edit-of-a-comment-being-sent-queues`, `prrr-sync-test-outbox-delete-drops-an-unsent-comment`, `prrr-sync-test-outbox-discard-drops-queued-pending-writes`).
4. **Commenting where point happens to be.** On a removed line, a context line, a region starting on a removed line and ending on an added one, a region ending at the start of a line, a region across hunks, point inside a Thread, on a hunk heading, on a file heading. Pinned in Task 9 (`prrr-state-test-anchor-*`, `prrr-diff-test-anchor-*`, `prrr-diff-test-region-lines-skip-threads`).
5. **The capture buffer's life.** An empty comment, abort, a toggle on a comment that is always published at once, a command that refuses the text, and the Review Buffer killed while the user writes. Pinned in Task 11 (`prrr-thread-test-capture-*`).

---

## File structure

| File | Responsibility | Change |
|------|----------------|--------|
| `prrr-db.el` | Schema 2 (`resolvable-p`, `database-id`); `prrr-db-outbox-rows`, `prrr-db-outbox-clear-errors`, `prrr-db-outbox-done`; `prrr-db-replace-review-data` takes RENAMES. | Modify (Task 1) |
| `prrr-github.el` | Decoding `fullDatabaseId` and resolvability; `prrr-github--mutate`; the Pending Review's writes; REST Immediate Publish; the other mutations; HTTP 422. | Modify (Tasks 2, 3) |
| `prrr-state.el` | The Outbox's pure rules and view; anchors and labels; suggestions; Submit check; write descriptions. | Modify (Tasks 4, 5, 9, 10, 13) |
| `prrr-sync.el` | The Outbox engine (`prrr-sync-write`, `prrr-sync-retry`, `prrr-sync-discard`, `prrr-sync-review-data`, `prrr-sync-outbox-describe`); target-based refetch; `prrr-sync-set-viewed` removed. | Modify (Tasks 6, 7, 8) |
| `prrr-thread.el` | Faces `prrr-unsent`, `prrr-failed`, `prrr-agent`, `prrr-suggestion-heading`; `prrr-thread-insert` with `:with-path :writes :lines`; `prrr-thread-label`; `prrr-thread-insert-unsent-post`; the capture buffer `prrr-comment-mode` and `prrr-comment-capture`. | Modify (Tasks 10, 11) |
| `prrr-diff.el` | Reads `prrr-sync-review-data`; `prrr-diff-pullreq` (renamed), `prrr-diff-head`, `prrr-diff-anchor`, `prrr-diff-file-anchor`, `prrr-diff-region-lines`, `prrr-diff-thread-at-point`, `prrr-diff-comment-at-point`; writes and suggestions in the washer; Outbox in the header; review keys. | Modify (Tasks 6, 9, 10, 12, 13) |
| `prrr-review.el` | The commands that write: comment, file comment, suggest, reply, edit, delete, discussion, resolve, submit, discard, Outbox retry and discard. | Create (Task 12), modify (Task 13) |
| `prrr-transient.el` | `prrr-menu` Comment group with `-i` and Review group; `prrr-submit`, `prrr-outbox`. | Modify (Tasks 12, 13) |
| `prrr.el` | Autoloads of the new commands. | Modify (Tasks 12, 13) |
| `test/prrr-test-helper.el` | `prrr-test-with-outbox`, `prrr-test-run-timers`, `prrr-test-with-rest-stub`; `prrr-test-with-ghub-dispatch` answers failures and records variables. | Modify (Task 6; `prrr-test-with-rest-stub` in Task 3) |
| `test/fixtures/github/` | `review-data.eld` gains `fullDatabaseId`; new `pending-review.eld`, `pending-review-none.eld`, `create-review.eld`, `add-thread.eld`, `add-reply.eld`, `publish-comment.eld`, `publish-reply.eld`. | Modify, create (Tasks 2, 3) |
| `test/prrr-review-test.el` | New ERT suite for the commands. | Create (Task 12) |
| `Makefile` | `prrr-review.el` in `SRC`, `test/prrr-review-test.el` in `TESTS`. | Modify (Task 12) |
| `README.md`, `SPEC.md` | Commenting docs; spec corrections. | Modify (Task 14) |

Running one test file: `make test TESTS=test/prrr-sync-test.el`. One test: `make test SELECTOR='"prrr-sync-test-outbox"'`.

Shared fixture: `test/fixtures/github/review-data.eld` belongs to PR `PR_kwDOexample0000001` (`prrr-sync-test--pr`, `prrr-diff-test--pr`). Its Threads are `PRRT_kwDOexample0000001` (src/example.el line 12 RIGHT, comments `PRRC_…0001` by example-bob and `PRRC_…0002` by example-me), `…0002` (README.md lines 1-3, resolved), `…0003` (src/old.el, outdated), `…0004` (docs/notes.md, File Comment), `…0005` (src/example.el line 30, one PENDING comment `PRRC_…0006` by example-me in the Pending Review `PRR_kwDOexamplePending1`). After Task 2 the six comments carry `fullDatabaseId` "1001" to "1006". In the fixture repository, src/example.el's first hunk is `@@ -9,7 +9,7 @@` with context lines ` line 9` to ` line 11`, `-line 12`, `+line twelve`, ` line 13` to ` line 15`; its second hunk rewrites line 30 the same way.

The viewer in tests is `example-me` (`prrr-test-me`; `prrr-test-with-outbox` binds `prrr-github-user` to it).

---
### Task 1: Schema 2 and the Outbox's storage

**Files:**
- Modify: `prrr-db.el` (schema version, `prrr-thread` and `prrr-comment` structs, `prrr-outbox` docstring, `prrr-db--tables`, `prrr-db-replace-review-data`; new part `;;;; The Outbox` before `(provide 'prrr-db)`)
- Modify: `test/prrr-db-test.el`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `prrr-thread` gains slot `resolvable-p` (after `resolved-p`); `prrr-comment` gains slot `database-id` (last). `prrr-db-schema-version` is 2.
  - `(prrr-db-outbox-rows &optional PR-ID)` → list of `prrr-outbox`, ordered by id.
  - `(prrr-db-outbox-clear-errors &optional PR-ID)` → unspecified.
  - `(prrr-db-outbox-done ID &key insert delete renames)` → nil. DELETE is a list of `(TABLE . PLIST)`; RENAMES an alist from local id to GitHub id.
  - `(prrr-db-replace-review-data PR-ID DATA &optional RENAMES)` → nil; RENAMES applied to PR-ID's queued payloads in the same transaction.
  - Private `prrr-db--rename-outbox-ids`, `prrr-db--rename`.

- [ ] **Step 1: Write the failing tests**

Append to `test/prrr-db-test.el`, before `(provide 'prrr-db-test)` (the helpers `prrr-db-test--pr` and `prrr-db-test--review-data` already exist above):

```elisp
(defun prrr-db-test--write (id pr-id kind payload &optional last-error)
  "A queued write ID of PR-ID with KIND, PAYLOAD and LAST-ERROR."
  (prrr-outbox-create :id id :pr-id pr-id :kind kind :payload payload
                      :created-at "2026-10-10T12:00:00Z" :attempts 0
                      :last-error last-error))

(ert-deftest prrr-db-test-outbox-rows-oldest-first ()
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-db-test--write "2" "PR_1" 'viewed '(:path "b")))
    (prrr-db-insert (prrr-db-test--write "1" "PR_1" 'viewed '(:path "a")))
    (prrr-db-insert (prrr-db-test--write "3" "PR_2" 'viewed '(:path "c")))
    ;; Replacing a row moves it to the end of rowid order, not of the Outbox.
    (prrr-db-insert (prrr-db-test--write "1" "PR_1" 'viewed '(:path "a") "offline"))
    (should (equal '("1" "2" "3") (mapcar #'prrr-outbox-id (prrr-db-outbox-rows))))
    (should (equal '("1" "2") (mapcar #'prrr-outbox-id (prrr-db-outbox-rows "PR_1"))))
    (should (equal '(:path "a") (prrr-outbox-payload (car (prrr-db-outbox-rows)))))))

(ert-deftest prrr-db-test-outbox-clear-errors ()
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-db-test--write "1" "PR_1" 'viewed nil "offline"))
    (prrr-db-insert (prrr-db-test--write "2" "PR_2" 'viewed nil "offline"))
    (prrr-db-outbox-clear-errors "PR_1")
    (should (equal '(nil "offline") (mapcar #'prrr-outbox-last-error (prrr-db-outbox-rows))))
    (prrr-db-outbox-clear-errors)
    (should (equal '(nil nil) (mapcar #'prrr-outbox-last-error (prrr-db-outbox-rows))))))

(ert-deftest prrr-db-test-outbox-done ()
  "The write leaves, its rows arrive, and the PR's other writes learn GitHub's ids."
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-db-test--write "1" "PR_1" 'thread '(:thread "local:T" :comment "local:C")))
    (prrr-db-insert (prrr-db-test--write "2" "PR_1" 'reply '(:thread-id "local:T" :comment "local:R")))
    (prrr-db-insert (prrr-db-test--write "3" "PR_2" 'reply '(:thread-id "local:T")))
    (prrr-db-insert (prrr-test-thread :id "GONE"))
    (prrr-db-outbox-done "1"
                         :insert (list (prrr-test-thread :id "PRRT_1"))
                         :delete '((thread :thread-id "GONE"))
                         :renames '(("local:T" . "PRRT_1")))
    (should (equal '("2" "3") (mapcar #'prrr-outbox-id (prrr-db-outbox-rows))))
    (should (equal '(:thread-id "PRRT_1" :comment "local:R")
                   (prrr-outbox-payload (prrr-db-get 'outbox "2"))))
    (should (equal '(:thread-id "local:T") (prrr-outbox-payload (prrr-db-get 'outbox "3"))))
    (should (equal '("PRRT_1") (mapcar #'prrr-thread-thread-id (prrr-db-select 'thread))))))

(ert-deftest prrr-db-test-review-data-keeps-the-outbox ()
  "Bead prrr-8ok: a refetch replaces GitHub's rows, not the queued writes."
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-db-test--write "1" prrr-db-test--pr 'reply
                                         '(:thread-id "local:T" :comment "local:R")))
    (prrr-db-replace-review-data prrr-db-test--pr (prrr-db-test--review-data)
                                 '(("local:T" . "PRRT_kwDOexample0000005")))
    (should (equal '(:thread-id "PRRT_kwDOexample0000005" :comment "local:R")
                   (prrr-outbox-payload (car (prrr-db-outbox-rows prrr-db-test--pr)))))))

(ert-deftest prrr-db-test-new-columns-round-trip ()
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-thread-create :thread-id "T" :pr-id "PR_1" :resolvable-p t))
    (prrr-db-insert (prrr-comment-create :comment-id "C" :thread-id "T" :pr-id "PR_1"
                                         :database-id "1001"))
    (should (prrr-thread-resolvable-p (prrr-db-get 'thread "T")))
    (should (equal "1001" (prrr-comment-database-id (prrr-db-get 'review-comment "C"))))))
```

Precede them with the line `;;;; The Outbox` and a blank line.

- [ ] **Step 2: Run them to verify they fail**

Run: `make test TESTS=test/prrr-db-test.el`
Expected: FAIL; `prrr-db-outbox-rows` is void and `:resolvable-p` is an unknown keyword.

- [ ] **Step 3: Change the schema**

In `prrr-db.el`:

1. `(defconst prrr-db-schema-version 1` becomes `(defconst prrr-db-schema-version 2`.
2. The `prrr-thread` struct becomes:

```elisp
(cl-defstruct (prrr-thread (:constructor prrr-thread-create) (:copier nil))
  "A Thread (table `thread').
SIDE and START-SIDE are `left' or `right'; SUBJECT-TYPE is `line' or
`file'; OUTDATED-P and RESOLVED-P are booleans.  RESOLVABLE-P is
non-nil when GitHub lets the viewer resolve the Thread, or unresolve
it when it is resolved."
  thread-id pr-id path line start-line side start-side subject-type
  outdated-p resolved-p resolvable-p original-line original-commit fetched-at)
```

3. The `prrr-comment` struct becomes:

```elisp
(cl-defstruct (prrr-comment (:constructor prrr-comment-create) (:copier nil))
  "A Review Comment inside a Thread (table `review-comment').
STATE is `pending' or `submitted' (GitHub's).  LOCAL-STATE is `sent' for
a row GitHub sent or accepted, `unsent' for one the Outbox has not sent
yet (only in `prrr-state-outbox-view', never stored) and `proposed' for
an agent's proposal (milestone 7).  AGENT-P marks comments added through
the API.  DATABASE-ID is GitHub's numeric id as a string, which its
REST endpoints take."
  comment-id thread-id pr-id author body created-at updated-at reply-to
  review-id state local-state agent-p database-id)
```

4. The `prrr-outbox` struct's docstring becomes:

```elisp
  "A write GitHub has not accepted yet (table `outbox').
ID increases with time, so the Outbox sends in id order.  KIND and
PAYLOAD are as `prrr-state-outbox-kinds' describes.  ATTEMPTS counts
the sends that failed; LAST-ERROR is the last failure's message, nil
when the write is waiting to be sent."
```

5. In `prrr-db--tables`, the `thread` column vector becomes

```elisp
     ([(thread-id :primary-key) pr-id path line start-line side start-side
       subject-type outdated-p resolved-p resolvable-p original-line original-commit
       fetched-at]))
```

and the `review-comment` column vector becomes

```elisp
     ([(comment-id :primary-key) thread-id pr-id author body created-at
       updated-at reply-to review-id state local-state agent-p database-id]))
```

- [ ] **Step 4: Store the Outbox's rows**

Replace `prrr-db-replace-review-data` with:

```elisp
(defun prrr-db-replace-review-data (pr-id data &optional renames)
  "Make DATA the only stored review data of PR-ID.
DATA is the plist `prrr-github-decode-review-data' returns, or nil: its
:threads, :comments, :pending-review and :viewed replace every
`thread', `review-comment', `pending-review' and `viewed' row of PR-ID.
These tables hold only what GitHub sent or accepted; the Outbox's
unsent writes live in the `outbox' table, which this leaves alone apart
from RENAMES, an alist from local id to GitHub's applied to the PR's
queued writes.  One transaction."
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
                   (mapcar #'prrr-db--struct-to-row rows))))
      (prrr-db--rename-outbox-ids pr-id renames))
    nil))
```

Insert before `(provide 'prrr-db)`:

```elisp
;;;; The Outbox

(defun prrr-db-outbox-rows (&optional pr-id)
  "Return the queued writes of PR-ID, or of every PR when nil, oldest first.
Rows are `prrr-outbox' structs ordered by id, which the Outbox makes
increase with time."
  (mapcar (lambda (row) (prrr-db--row-to-struct 'outbox row))
          (if pr-id
              (emacsql (prrr-db) [:select * :from outbox :where (= pr-id $s1)
                                  :order-by [(asc id)]]
                       pr-id)
            (emacsql (prrr-db) [:select * :from outbox :order-by [(asc id)]]))))

(defun prrr-db-outbox-clear-errors (&optional pr-id)
  "Forget the last error of every queued write of PR-ID, or of every PR when nil.
Their attempts count is kept."
  (if pr-id
      (emacsql (prrr-db) [:update outbox :set (= last-error $s1) :where (= pr-id $s2)]
               nil pr-id)
    (emacsql (prrr-db) [:update outbox :set (= last-error $s1)] nil)))

(defun prrr-db--rename (tree renames)
  "Return a copy of TREE in which each string that is a key of RENAMES is replaced.
RENAMES is an alist from old to new string; TREE is built of conses and atoms."
  (cond ((stringp tree) (or (cdr (assoc tree renames)) tree))
        ((consp tree) (cons (prrr-db--rename (car tree) renames)
                            (prrr-db--rename (cdr tree) renames)))
        (t tree)))

(defun prrr-db--rename-outbox-ids (pr-id renames)
  "Replace the ids in RENAMES in the payloads of PR-ID's queued writes.
RENAMES is an alist from local id to GitHub's id.  Runs inside the
caller's transaction."
  (when renames
    (dolist (row (prrr-db-outbox-rows pr-id))
      (let ((payload (prrr-db--rename (prrr-outbox-payload row) renames)))
        (unless (equal payload (prrr-outbox-payload row))
          (setf (prrr-outbox-payload row) payload)
          (prrr-db-insert row))))))

(cl-defun prrr-db-outbox-done (id &key insert delete renames)
  "Record that GitHub accepted the queued write ID, in one transaction.
The write's row leaves the `outbox' table.  DELETE lists (TABLE . PLIST)
pairs, each deleting the rows `prrr-db-delete' would; then the structs
in INSERT are stored.  RENAMES, an alist from local id to GitHub's id,
is applied to the payloads of the PR's other queued writes, so a write
that needs what this one created now names it as GitHub does."
  (let ((db (prrr-db))
        (row (prrr-db-get 'outbox id)))
    (emacsql-with-transaction db
      (prrr-db-delete 'outbox :id id)
      (pcase-dolist (`(,table . ,plist) delete)
        (apply #'prrr-db-delete table plist))
      (mapc #'prrr-db-insert insert)
      (when row
        (prrr-db--rename-outbox-ids (prrr-outbox-pr-id row) renames)))
    nil))
```

In the Commentary, after the paragraph about schema changes, add:

```
;;
;; The review tables hold only what GitHub sent or accepted.  Writes
;; GitHub has not accepted yet are rows of the `outbox' table, which
;; the Outbox in prrr-sync.el reads and changes through the functions
;; of the part "The Outbox".
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `make test TESTS=test/prrr-db-test.el`
Expected: all pass, `prrr-db-test-struct-slots-match-columns` included.

- [ ] **Step 6: Run all gates and commit**

```bash
make compile lint test
git add prrr-db.el test/prrr-db-test.el
git commit -m "feat(db): schema 2, the Outbox's rows and id renames"
```

---

### Task 2: GitHub: the Pending Review's writes

**Files:**
- Modify: `prrr-github.el` (review-data query and decoders; new part `;;;; Writes` before `(provide 'prrr-github)`; Commentary)
- Modify: `test/fixtures/github/review-data.eld`
- Create: `test/fixtures/github/pending-review.eld`, `pending-review-none.eld`, `create-review.eld`, `add-thread.eld`, `add-reply.eld`
- Modify: `test/prrr-github-test.el`

**Interfaces:**
- Consumes: `prrr-thread-resolvable-p`, `prrr-comment-database-id` (Task 1); `prrr-github--callback`, `prrr-github--errorback`, `prrr-github--query` (milestone 1).
- Produces (each calls exactly one of CALLBACK and ERRORBACK; ERRORBACK receives a `prrr-github-error` plist):
  - `(prrr-github-find-pending-review HOST OWNER NAME NUMBER ME CALLBACK ERRORBACK)`; CALLBACK gets a `prrr-pending-review` or nil.
  - `(prrr-github-create-pending-review HOST PR-ID COMMIT CALLBACK ERRORBACK)`; CALLBACK gets a `prrr-pending-review`.
  - `(prrr-github-add-thread HOST REVIEW-ID ANCHOR BODY CALLBACK ERRORBACK)`; CALLBACK gets `(:thread-id :comment-id :database-id :created-at)`. ANCHOR is the plist of `prrr-state-anchor` (Task 9): `:path :line :side :start-line :start-side :subject-type`.
  - `(prrr-github-add-reply HOST REVIEW-ID THREAD-ID BODY CALLBACK ERRORBACK)`; CALLBACK gets `(:comment-id :database-id :created-at)`.
  - Private: `prrr-github--input`, `prrr-github--side-name`, `prrr-github--database-id`, `prrr-github--mutate`, `prrr-github--pending-review`.
  - Decoded comments carry `:database-id`; decoded Threads carry `:resolvable-p`.

- [ ] **Step 1: Add the fixtures**

In `test/fixtures/github/review-data.eld`, give each of the six comments a database id: after the line `((id . "PRRC_kwDOexample000000N")` add, aligned with it, `(fullDatabaseId . "100N")`, for N from 1 to 6. The first becomes:

```elisp
      ((id . "PRRC_kwDOexample0000001")
       (fullDatabaseId . "1001")
       (author (login . "example-bob"))
```

Create `test/fixtures/github/pending-review.eld`:

```elisp
;; The viewer's Pending Review of example-org/example-repo#1.
(data
 (repository
  (pullRequest
   (id . "PR_kwDOexample0000001")
   (reviews
    ((id . "PRR_kwDOexamplePending1")
     (commit (oid . "1111111111111111111111111111111111111111"))
     (body . "")
     (createdAt . "2026-09-04T09:00:00Z"))))))
```

Create `test/fixtures/github/pending-review-none.eld`:

```elisp
;; example-org/example-repo#1 when the viewer has no Pending Review.
(data
 (repository
  (pullRequest
   (id . "PR_kwDOexample0000001")
   (reviews))))
```

Create `test/fixtures/github/create-review.eld`:

```elisp
;; addPullRequestReview answer without an event: the new Pending Review.
(data
 (addPullRequestReview
  (pullRequestReview
   (id . "PRR_kwDOexampleNew01")
   (commit (oid . "1111111111111111111111111111111111111111"))
   (body . "")
   (createdAt . "2026-10-10T12:00:00Z"))))
```

Create `test/fixtures/github/add-thread.eld`:

```elisp
;; addPullRequestReviewThread answer: the new Thread and its first comment.
(data
 (addPullRequestReviewThread
  (thread
   (id . "PRRT_kwDOexampleNew01")
   (comments
    (nodes
     ((id . "PRRC_kwDOexampleNew01")
      (createdAt . "2026-10-10T12:00:00Z")
      (fullDatabaseId . "2001")))))))
```

Create `test/fixtures/github/add-reply.eld`:

```elisp
;; addPullRequestReviewThreadReply answer: the new reply.
(data
 (addPullRequestReviewThreadReply
  (comment
   (id . "PRRC_kwDOexampleNew02")
   (createdAt . "2026-10-10T12:01:00Z")
   (fullDatabaseId . "2002"))))
```

- [ ] **Step 2: Write the failing tests**

Append to `test/prrr-github-test.el`, before `(provide 'prrr-github-test)`, under a new line `;;;; Writes`:

```elisp
  '(:path "src/example.el" :line 12 :side right :start-line 10 :start-side right :subject-type line)

(ert-deftest prrr-github-test-decode-review-data-database-id-and-resolvable ()
  (let ((data (prrr-github-decode-review-data (prrr-test-fixture "review-data") "PR_1")))
    (should (equal "1001" (prrr-comment-database-id (car (plist-get data :comments)))))
    (should (prrr-thread-resolvable-p (car (plist-get data :threads))))))

(ert-deftest prrr-github-test-find-pending-review ()
  (prrr-test-with-ghub-stub (prrr-test-fixture "pending-review") captured
    (let ((found :none))
      (prrr-github-find-pending-review "api.github.com" "example-org" "example-repo" 1 "example-me"
                                       (lambda (review) (setq found review))
                                       (lambda (f) (ert-fail f)))
      (should (equal "PRR_kwDOexamplePending1" (prrr-pending-review-review-id found)))
      (should (equal "PR_kwDOexample0000001" (prrr-pending-review-pr-id found)))
      (should (equal "example-me" (alist-get 'me (cadr captured)))))))

(ert-deftest prrr-github-test-find-pending-review-none ()
  (prrr-test-with-ghub-stub (prrr-test-fixture "pending-review-none") captured
    (let ((found :none))
      (prrr-github-find-pending-review "api.github.com" "o" "n" 1 "me"
                                       (lambda (review) (setq found review)) #'ert-fail)
      (should (null found))
      (should captured))))

(ert-deftest prrr-github-test-create-pending-review ()
  (prrr-test-with-ghub-stub (prrr-test-fixture "create-review") captured
    (let ((review nil))
      (prrr-github-create-pending-review "api.github.com" "PR_1" "1111" (lambda (r) (setq review r)) #'ert-fail)
      (should (eq 'mutation (car (car captured))))
      (should (equal '((input (pullRequestId . "PR_1") (commitOID . "1111"))) (cadr captured)))
      (should (equal "PRR_kwDOexampleNew01" (prrr-pending-review-review-id review)))
      (should (equal "PR_1" (prrr-pending-review-pr-id review))))))

(ert-deftest prrr-github-test-add-thread-range ()
  (prrr-test-with-ghub-stub (prrr-test-fixture "add-thread") captured
    (let ((result nil))
      (prrr-github-add-thread "api.github.com" "PRR_1" prrr-github-test--anchor "Nit."
                              (lambda (r) (setq result r)) #'ert-fail)
      (should (equal '((input (pullRequestReviewId . "PRR_1") (path . "src/example.el") (body . "Nit.")
                              (line . 12) (side . "RIGHT") (startLine . 10) (startSide . "RIGHT")))
                     (cadr captured)))
      (should (equal '(:thread-id "PRRT_kwDOexampleNew01" :comment-id "PRRC_kwDOexampleNew01"
                       :database-id "2001" :created-at "2026-10-10T12:00:00Z")
                     result)))))

(ert-deftest prrr-github-test-add-thread-file ()
  (prrr-test-with-ghub-stub (prrr-test-fixture "add-thread") captured
    (prrr-github-add-thread "api.github.com" "PRR_1" '(:path "a.el" :subject-type file) "Split."
                            #'ignore #'ert-fail)
    (should (equal '((input (pullRequestReviewId . "PRR_1") (path . "a.el") (body . "Split.")
                            (subjectType . "FILE")))
                   (cadr captured)))))

(ert-deftest prrr-github-test-add-reply ()
  (prrr-test-with-ghub-stub (prrr-test-fixture "add-reply") captured
    (let ((result nil))
      (prrr-github-add-reply "api.github.com" "PRR_1" "PRRT_1" "Agreed." (lambda (r) (setq result r)) #'ert-fail)
      (should (equal '((input (pullRequestReviewThreadId . "PRRT_1") (pullRequestReviewId . "PRR_1") (body . "Agreed.")))
                     (cadr captured)))
      (should (equal "PRRC_kwDOexampleNew02" (plist-get result :comment-id))))))

(ert-deftest prrr-github-test-write-failure-reaches-errorback ()
  (prrr-test-with-ghub-error-stub '(errors ((type . "UNPROCESSABLE") (message . "one pending review"))) nil
    (let ((failure nil))
      (prrr-github-add-reply "api.github.com" "PRR_1" "PRRT_1" "x" #'ert-fail (lambda (f) (setq failure f)))
      (should (equal '(:kind error :message "one pending review" :reset-at nil) failure)))))
```

- [ ] **Step 3: Run them to verify they fail**

Run: `make test TESTS=test/prrr-github-test.el`
Expected: FAIL; `prrr-github-find-pending-review` is void and the decoded comment has no database id.

- [ ] **Step 4: Decode the new fields**

In `prrr-github-review-data-query`, the comment selection line becomes

```elisp
             id (author login) body createdAt lastEditedAt (replyTo id) state fullDatabaseId
```

In `prrr-github--comment`, after `:agent-p nil` add `:database-id (prrr-github--database-id .fullDatabaseId)`, so the constructor call ends:

```elisp
     :local-state 'sent
     :agent-p nil
     :database-id (prrr-github--database-id .fullDatabaseId))))
```

In `prrr-github--thread`, after `:resolved-p (and .isResolved t)` add:

```elisp
           :resolvable-p (and (if .isResolved .viewerCanUnresolve .viewerCanResolve) t)
```

Insert this helper before `prrr-github--comment` (the decoder needs it):

```elisp
(defun prrr-github--database-id (value)
  "Return the database id VALUE as a string, or nil.
GitHub sends a BigInt as a string in GraphQL and a number in REST."
  (and value (format "%s" value)))
```

- [ ] **Step 5: Implement the writes**

Insert before `(provide 'prrr-github)`:

```elisp
;;;; Writes

(defun prrr-github--input (&rest pairs)
  "Return the alist of NAME VALUE PAIRS whose VALUE is non-nil."
  (let ((input nil))
    (while pairs
      (let ((name (pop pairs)) (value (pop pairs)))
        (when value (push (cons name value) input))))
    (nreverse input)))

(defun prrr-github--side-name (side)
  "Return GitHub's DiffSide for SIDE, `left' or `right', or nil."
  (pcase side ('left "LEFT") ('right "RIGHT")))

(defun prrr-github--mutate (host document input decode callback errorback)
  "Send the GraphQL mutation DOCUMENT to HOST with INPUT as its $input.
`forge-mutate' selects only clientMutationId, and these mutations
create things whose ids prrr needs, so DOCUMENT selects them and goes
through `ghub-query' with forge's token, as `forge-query' does.  DECODE
turns the answer's data into what CALLBACK receives; ERRORBACK receives
a failure classified by `prrr-github-error'.  Exactly one is called."
  (ghub-query document `((input . ,input))
    :auth 'forge :host host :forge 'github
    :callback (prrr-github--callback decode callback errorback)
    :errorback (prrr-github--errorback errorback)))

(eval-and-compile
  (defconst prrr-github-pending-review-query
    '(repository [(owner $owner String!) (name $name String!)]
       (pullRequest [(number $number Int!)]
         id
         (reviews [(:edges t) (states . (PENDING)) (author $me String!)]
           id (commit oid) body createdAt)))
    "The viewer's Pending Review of one PR.
Variables: $owner, $name, $number and $me."))

  '(mutation (addPullRequestReview [(input $input AddPullRequestReviewInput!)]
               (pullRequestReview id (commit oid) body createdAt)))

  '(mutation (addPullRequestReviewThread [(input $input AddPullRequestReviewThreadInput!)]
               (thread id (comments [(first 1)] (nodes id createdAt fullDatabaseId)))))

  '(mutation (addPullRequestReviewThreadReply
              [(input $input AddPullRequestReviewThreadReplyInput!)]
              (comment id createdAt fullDatabaseId)))

(defun prrr-github--pending-review (node pr-id)
  "Decode a PullRequestReview NODE of PR-ID into a `prrr-pending-review'."
  (let-alist node
    (prrr-pending-review-create :pr-id pr-id :review-id .id :commit-oid .commit.oid
                                :body .body :created-at .createdAt)))

(defun prrr-github-find-pending-review (host owner name number me callback errorback)
  "Find the Pending Review of ME on OWNER/NAME#NUMBER on HOST.
CALLBACK receives a `prrr-pending-review', or nil when ME has none.
ERRORBACK receives a failure classified by `prrr-github-error'; a
response without the pull request is a `not-found' failure.  Exactly
one of the two is called."
  (prrr-github--query host prrr-github-pending-review-query
    ((owner owner) (name name) (number number) (me me))
    :callback
    (prrr-github--callback
     (lambda (data)
       (let ((pr (alist-get 'pullRequest (cdr (assq 'repository data)))))
         (unless pr
           (signal 'prrr-github-failure
                   (list :kind 'not-found
                         :message (format "Pull request %s/%s#%s not found" owner name number)
                         :reset-at nil)))
         (let ((review (car (alist-get 'reviews pr))))
           (and review (prrr-github--pending-review review (alist-get 'id pr))))))
     callback errorback)
    :errorback (prrr-github--errorback errorback)))

(defun prrr-github-create-pending-review (host pr-id commit callback errorback)
  "Create the viewer's Pending Review on the PR with node id PR-ID on HOST.
The review is on COMMIT, the head the user commented on.  CALLBACK
receives the new `prrr-pending-review'; ERRORBACK a failure classified
by `prrr-github-error'."
  (prrr-github--mutate
   host prrr-github-create-review-mutation
   (prrr-github--input 'pullRequestId pr-id 'commitOID commit)
   (lambda (data)
     (prrr-github--pending-review
      (alist-get 'pullRequestReview (alist-get 'addPullRequestReview data)) pr-id))
   callback errorback))

(defun prrr-github-add-thread (host review-id anchor body callback errorback)
  "On HOST, add a Thread at ANCHOR to the Pending Review REVIEW-ID.
BODY is its first comment.
ANCHOR is a plist as `prrr-state-anchor' returns.  CALLBACK receives
\(:thread-id :comment-id :database-id :created-at) of what GitHub made;
ERRORBACK a failure classified by `prrr-github-error'."
  (prrr-github--mutate
   host prrr-github-add-thread-mutation
   (prrr-github--input 'pullRequestReviewId review-id
                       'path (plist-get anchor :path)
                       'body body
                       'line (plist-get anchor :line)
                       'side (prrr-github--side-name (plist-get anchor :side))
                       'startLine (plist-get anchor :start-line)
                       'startSide (prrr-github--side-name (plist-get anchor :start-side))
                       'subjectType (and (eq (plist-get anchor :subject-type) 'file) "FILE"))
   (lambda (data)
     (let* ((thread (alist-get 'thread (alist-get 'addPullRequestReviewThread data)))
            (comment (car (alist-get 'nodes (alist-get 'comments thread)))))
       (let-alist comment
         (list :thread-id (alist-get 'id thread) :comment-id .id
               :database-id (prrr-github--database-id .fullDatabaseId)
               :created-at .createdAt))))
   callback errorback))

(defun prrr-github-add-reply (host review-id thread-id body callback errorback)
  "On HOST, reply BODY to the Thread THREAD-ID in the Pending Review REVIEW-ID.
CALLBACK receives (:comment-id :database-id :created-at); ERRORBACK a
failure classified by `prrr-github-error'."
  (prrr-github--mutate
   host prrr-github-add-reply-mutation
   (prrr-github--input 'pullRequestReviewThreadId thread-id
                       'pullRequestReviewId review-id 'body body)
   (lambda (data)
     (let-alist (alist-get 'addPullRequestReviewThreadReply data)
       (list :comment-id .comment.id
             :database-id (prrr-github--database-id .comment.fullDatabaseId)
             :created-at .comment.createdAt)))
   callback errorback))
```

In the Commentary, replace "The Viewed mutations are here; the others arrive in milestone 4." with:

```
;; Writes are here too.  Most go through `forge-mutate' or
;; `forge-rest'.  `forge-mutate' selects only clientMutationId, so the
;; three mutations whose answer prrr reads (creating the Pending
;; Review, a Thread, a reply) go through `prrr-github--mutate', which
;; calls `ghub-query' with forge's token as `forge-query' does.
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `make test TESTS=test/prrr-github-test.el`, then `make test`
Expected: all pass. (The database tests read `review-data.eld` too; the new field is decoded and stored.)

- [ ] **Step 7: Run all gates and commit**

```bash
make compile lint test
git add prrr-github.el test/prrr-github-test.el test/fixtures/github/
git commit -m "feat(github): find or create the Pending Review, add Threads and replies"
```

---

### Task 3: GitHub: the other writes

**Files:**
- Modify: `prrr-github.el` (`prrr-github-error` and a new `prrr-github--refusal`; the part `;;;; Writes`)
- Create: `test/fixtures/github/publish-comment.eld`, `publish-reply.eld`
- Modify: `test/prrr-test-helper.el` (`prrr-test-with-rest-stub`; Commentary)
- Modify: `test/prrr-github-test.el`

**Interfaces:**
- Consumes: Task 2's `prrr-github--side-name`, `prrr-github--database-id`.
- Produces (each calls exactly one of CALLBACK and ERRORBACK):
  - `(prrr-github-publish-comment HOST OWNER NAME NUMBER COMMIT ANCHOR BODY CALLBACK ERRORBACK)`; CALLBACK gets `(:comment-id :database-id :created-at)`.
  - `(prrr-github-publish-reply HOST OWNER NAME NUMBER DATABASE-ID BODY CALLBACK ERRORBACK)`; same CALLBACK value.
  - `(prrr-github-add-discussion-comment HOST PR-ID BODY CALLBACK ERRORBACK)`, `(prrr-github-edit-comment HOST COMMENT-ID BODY CALLBACK ERRORBACK)`, `(prrr-github-delete-comment HOST COMMENT-ID CALLBACK ERRORBACK)`, `(prrr-github-set-resolved HOST THREAD-ID RESOLVED CALLBACK ERRORBACK)`, `(prrr-github-submit-review HOST REVIEW-ID PR-ID COMMIT VERDICT BODY CALLBACK ERRORBACK)` (VERDICT `approve`, `request-changes` or `comment`; REVIEW-ID nil creates and submits a review on COMMIT), `(prrr-github-discard-review HOST REVIEW-ID CALLBACK ERRORBACK)`; CALLBACK gets no argument.
  - `prrr-github-error` classifies `(error http 422 PAYLOAD)` as `(:kind error :message "GitHub refused: MESSAGE (DETAIL)" :reset-at nil)`.
  - Test helper `(prrr-test-with-rest-stub ANSWER CAPTURED &rest BODY)`.

- [ ] **Step 1: Add the fixtures and the REST stub**

Create `test/fixtures/github/publish-comment.eld`:

```elisp
;; REST POST /repos/example-org/example-repo/pulls/1/comments answer,
;; decoded by ghub (fields prrr reads, plus a few for context).
((id . 3001)
 (node_id . "PRRC_kwDOexampleNew03")
 (pull_request_review_id . 4001)
 (path . "src/example.el")
 (line . 12)
 (side . "RIGHT")
 (commit_id . "1111111111111111111111111111111111111111")
 (created_at . "2026-10-10T12:02:00Z")
 (body . "Published at once."))
```

Create `test/fixtures/github/publish-reply.eld`:

```elisp
;; REST POST /repos/example-org/example-repo/pulls/1/comments/1001/replies answer.
((id . 3002)
 (node_id . "PRRC_kwDOexampleNew04")
 (in_reply_to_id . 1001)
 (pull_request_review_id . 4002)
 (created_at . "2026-10-10T12:03:00Z")
 (body . "Replied at once."))
```

Append to `test/prrr-test-helper.el`, before `(provide 'prrr-test-helper)`:

```elisp
(defmacro prrr-test-with-rest-stub (answer captured &rest body)
  "Run BODY with `ghub-request' answering every request with ANSWER.
CAPTURED is bound to (METHOD RESOURCE PARAMS) of the last request.
ANSWER is the decoded JSON value handed to the callback, or
\(:error ERR HEADERS) to call the errorback with ERR and HEADERS as
ghub does.  Both run synchronously."
  (declare (indent 2) (debug (form symbolp body)))
  `(let ((,captured nil))
     (cl-letf (((symbol-function 'ghub-request)
                (lambda (method resource params &rest args)
                  (setq ,captured (list method resource params))
                  (let ((answer ,answer))
                    (if (eq (car-safe answer) :error)
                        (funcall (plist-get args :errorback)
                                 (plist-get answer :error) (plist-get answer :headers) nil nil)
                      (funcall (plist-get args :callback) answer nil nil nil))))))
       ,@body)))
```

In the helper's Commentary, after the sentence about `prrr-test-with-ghub-error-stub`, add "`prrr-test-with-rest-stub' does the same for ghub's REST entry point."

- [ ] **Step 2: Write the failing tests**

Append to `test/prrr-github-test.el`, before `(provide 'prrr-github-test)`:

```elisp
(ert-deftest prrr-github-test-error-http-422-is-a-refusal ()
  (should (equal '(:kind error :message "GitHub refused: Validation Failed (line must be part of the diff)" :reset-at nil)
                 (prrr-github-error '(error http 422 ((message . "Validation Failed")
                                                      (errors ((message . "line must be part of the diff")))))))))

(ert-deftest prrr-github-test-publish-comment ()
  (prrr-test-with-rest-stub (prrr-test-fixture "publish-comment") captured
    (let ((result nil))
      (prrr-github-publish-comment "api.github.com" "example-org" "example-repo" 1 "1111"
                                   prrr-github-test--anchor "Now." (lambda (r) (setq result r)) #'ert-fail)
      (should (equal '("POST" "/repos/example-org/example-repo/pulls/1/comments"
                       ((body . "Now.") (commit_id . "1111") (path . "src/example.el") (line . 12)
                        (side . "RIGHT") (start_line . 10) (start_side . "RIGHT") (subject_type . "line")))
                     captured))
      (should (equal '(:comment-id "PRRC_kwDOexampleNew03" :database-id "3001" :created-at "2026-10-10T12:02:00Z")
                     result)))))

(ert-deftest prrr-github-test-publish-file-comment ()
  (prrr-test-with-rest-stub (prrr-test-fixture "publish-comment") captured
    (prrr-github-publish-comment "api.github.com" "o" "n" 1 "1111" '(:path "a.el" :subject-type file) "File."
                                 #'ignore #'ert-fail)
    (should (equal '((body . "File.") (commit_id . "1111") (path . "a.el") (subject_type . "file"))
                   (nth 2 captured)))))

(ert-deftest prrr-github-test-publish-reply ()
  (prrr-test-with-rest-stub (prrr-test-fixture "publish-reply") captured
    (let ((result nil))
      (prrr-github-publish-reply "api.github.com" "o" "n" 1 "1001" "Done." (lambda (r) (setq result r)) #'ert-fail)
      (should (equal '("POST" "/repos/o/n/pulls/1/comments/1001/replies" ((body . "Done."))) captured))
      (should (equal "3002" (plist-get result :database-id))))))

(ert-deftest prrr-github-test-publish-refused ()
  (prrr-test-with-rest-stub '(:error (error http 422 ((message . "Validation Failed")))) captured
    (let ((failure nil))
      (prrr-github-publish-reply "api.github.com" "o" "n" 1 "1001" "x" #'ert-fail (lambda (f) (setq failure f)))
      (should (equal "GitHub refused: Validation Failed" (plist-get failure :message)))
      (should (equal "POST" (car captured))))))

(ert-deftest prrr-github-test-forge-mutations ()
  (pcase-dolist (`(,call ,mutation ,input)
                 `((,(lambda (cb eb) (prrr-github-add-discussion-comment "h" "PR_1" "Hi" cb eb))
                    addComment ((subjectId . "PR_1") (body . "Hi")))
                   (,(lambda (cb eb) (prrr-github-edit-comment "h" "C_1" "New" cb eb))
                    updatePullRequestReviewComment ((pullRequestReviewCommentId . "C_1") (body . "New")))
                   (,(lambda (cb eb) (prrr-github-delete-comment "h" "C_1" cb eb))
                    deletePullRequestReviewComment ((id . "C_1")))
                   (,(lambda (cb eb) (prrr-github-set-resolved "h" "T_1" t cb eb))
                    resolveReviewThread ((threadId . "T_1")))
                   (,(lambda (cb eb) (prrr-github-set-resolved "h" "T_1" nil cb eb))
                    unresolveReviewThread ((threadId . "T_1")))
                   (,(lambda (cb eb) (prrr-github-submit-review "h" "PRR_1" "PR_1" "1111" 'request-changes "Fix." cb eb))
                    submitPullRequestReview ((pullRequestReviewId . "PRR_1") (event . "REQUEST_CHANGES") (body . "Fix.")))
                   (,(lambda (cb eb) (prrr-github-submit-review "h" nil "PR_1" "1111" 'approve "" cb eb))
                    addPullRequestReview ((pullRequestId . "PR_1") (commitOID . "1111") (event . "APPROVE") (body . "")))
                   (,(lambda (cb eb) (prrr-github-discard-review "h" "PRR_1" cb eb))
                    deletePullRequestReview ((pullRequestReviewId . "PRR_1")))))
    (prrr-test-with-ghub-stub `((data (,mutation (clientMutationId)))) captured
      (let ((done nil))
        (funcall call (lambda () (setq done t)) #'ert-fail)
        (should done)
        (should (equal (list mutation (list (cons 'input input)))
                       (list (car (cadr (car captured))) (cadr captured))))))))
```

- [ ] **Step 3: Run them to verify they fail**

Run: `make test TESTS=test/prrr-github-test.el`
Expected: FAIL; the 422 is classified `offline` and `prrr-github-publish-comment` is void.

- [ ] **Step 4: Classify a refusal**

Insert before `prrr-github-error`:

```elisp
(defun prrr-github--refusal (payload)
  "Describe GitHub's refusal of a write, given the PAYLOAD of its HTTP 422."
  (let* ((message (and (consp payload) (alist-get 'message payload)))
         (first (and (consp payload) (car (alist-get 'errors payload))))
         (detail (if (stringp first) first (and (consp first) (alist-get 'message first)))))
    (cond ((and message detail) (format "GitHub refused: %s (%s)" message detail))
          (message (format "GitHub refused: %s" message))
          (t "GitHub refused the request (HTTP 422)"))))
```

In `prrr-github-error`, the HTTP pattern `` (`(error http ,code . ,_) `` becomes `` (`(error http ,code . ,rest) ``, and a clause goes before `((eq code 404)`:

```elisp
             ((eq code 422)
              (list :kind 'error :message (prrr-github--refusal (car (last rest))) :reset-at nil))
```

In the docstring's list of kinds, the `error` line becomes "`error'         anything else, such as GitHub refusing a write (HTTP 422)."

- [ ] **Step 5: Implement the writes**

Append to the part `;;;; Writes`, before `(provide 'prrr-github)`:

```elisp
(defun prrr-github--rest-comment (data)
  "Decode the review comment DATA a REST call answered with.
Return (:comment-id :database-id :created-at)."
  (let-alist data
    (list :comment-id .node_id :database-id (prrr-github--database-id .id)
          :created-at .created_at)))

(defun prrr-github-publish-comment (host owner name number commit anchor body
                                         callback errorback)
  "Publish BODY at ANCHOR of OWNER/NAME#NUMBER on HOST at once.
This is Immediate Publish of a new Thread: GitHub's REST endpoint for
one review comment, on COMMIT, the head the user commented on.  ANCHOR
is a plist as `prrr-state-anchor' returns.  CALLBACK receives
\(:comment-id :database-id :created-at); GitHub's answer does not name
the new Thread.  ERRORBACK receives a failure classified by
`prrr-github-error'."
  (let ((file (eq (plist-get anchor :subject-type) 'file))
        (line (plist-get anchor :line))
        (side (prrr-github--side-name (plist-get anchor :side)))
        (start (plist-get anchor :start-line))
        (start-side (prrr-github--side-name (plist-get anchor :start-side)))
        (path (plist-get anchor :path)))
    (forge-rest host "POST" (format "/repos/%s/%s/pulls/%s/comments" owner name number)
      ((body body) (commit_id commit) (path path)
       (and (not file) (line line))
       (and (not file) (side side))
       (and start (start_line start))
       (and start (start_side start-side))
       (subject_type (if file "file" "line")))
      :callback (prrr-github--callback #'prrr-github--rest-comment callback errorback)
      :errorback (prrr-github--errorback errorback))))

(defun prrr-github-publish-reply (host owner name number database-id body
                                       callback errorback)
  "Publish BODY at once as a reply on OWNER/NAME#NUMBER on HOST.
DATABASE-ID is GitHub's database id of the first comment of the
Thread replied to; GitHub's REST endpoint takes no other.  CALLBACK
receives (:comment-id :database-id :created-at); ERRORBACK a failure
classified by `prrr-github-error'."
  (forge-rest host "POST"
    (format "/repos/%s/%s/pulls/%s/comments/%s/replies" owner name number database-id)
    ((body body))
    :callback (prrr-github--callback #'prrr-github--rest-comment callback errorback)
    :errorback (prrr-github--errorback errorback)))

(defun prrr-github--ignore-answer (callback errorback)
  "Return a ghub callback that calls CALLBACK with no argument.
ERRORBACK receives a failure if CALLBACK's caller signals."
  (prrr-github--callback #'ignore (lambda (_) (funcall callback)) errorback))

(defun prrr-github-add-discussion-comment (host pr-id body callback errorback)
  "Post BODY as a Discussion Comment on the PR with node id PR-ID on HOST.
CALLBACK receives no argument; ERRORBACK a failure classified by
`prrr-github-error'."
  (forge-mutate host addComment ((subjectId pr-id) (body body))
    :callback (prrr-github--ignore-answer callback errorback)
    :errorback (prrr-github--errorback errorback)))

(defun prrr-github-edit-comment (host comment-id body callback errorback)
  "Make BODY the text of the review comment COMMENT-ID on HOST.
CALLBACK receives no argument; ERRORBACK a classified failure."
  (forge-mutate host updatePullRequestReviewComment
    ((pullRequestReviewCommentId comment-id) (body body))
    :callback (prrr-github--ignore-answer callback errorback)
    :errorback (prrr-github--errorback errorback)))

(defun prrr-github-delete-comment (host comment-id callback errorback)
  "Delete the review comment COMMENT-ID on HOST.
CALLBACK receives no argument; ERRORBACK a classified failure."
  (forge-mutate host deletePullRequestReviewComment ((id comment-id))
    :callback (prrr-github--ignore-answer callback errorback)
    :errorback (prrr-github--errorback errorback)))

(defun prrr-github-set-resolved (host thread-id resolved callback errorback)
  "Resolve the Thread THREAD-ID on HOST, or unresolve it when RESOLVED is nil.
CALLBACK receives no argument; ERRORBACK a classified failure."
  (let ((callback (prrr-github--ignore-answer callback errorback))
        (errorback (prrr-github--errorback errorback)))
    (if resolved
        (forge-mutate host resolveReviewThread ((threadId thread-id))
          :callback callback :errorback errorback)
      (forge-mutate host unresolveReviewThread ((threadId thread-id))
        :callback callback :errorback errorback))))

(defun prrr-github--event (verdict)
  "Return GitHub's PullRequestReviewEvent for VERDICT."
  (pcase-exhaustive verdict
    ('approve "APPROVE")
    ('request-changes "REQUEST_CHANGES")
    ('comment "COMMENT")))

(defun prrr-github-submit-review (host review-id pr-id commit verdict body
                                       callback errorback)
  "Submit the viewer's review of the PR with node id PR-ID on HOST.
VERDICT is `approve', `request-changes' or `comment'; BODY the summary.
REVIEW-ID is the Pending Review to submit; when nil, a review with no
comments is created and submitted at once on COMMIT.  CALLBACK receives
no argument; ERRORBACK a classified failure."
  (let ((callback (prrr-github--ignore-answer callback errorback))
        (errorback (prrr-github--errorback errorback))
        (event (prrr-github--event verdict)))
    (if review-id
        (forge-mutate host submitPullRequestReview
          ((pullRequestReviewId review-id) (event event) (body body))
          :callback callback :errorback errorback)
      (forge-mutate host addPullRequestReview
        ((pullRequestId pr-id) (commitOID commit) (event event) (body body))
        :callback callback :errorback errorback))))

(defun prrr-github-discard-review (host review-id callback errorback)
  "Delete the Pending Review REVIEW-ID and its comments on HOST.
CALLBACK receives no argument; ERRORBACK a classified failure."
  (forge-mutate host deletePullRequestReview ((pullRequestReviewId review-id))
    :callback (prrr-github--ignore-answer callback errorback)
    :errorback (prrr-github--errorback errorback)))
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `make test TESTS=test/prrr-github-test.el`
Expected: all pass.

- [ ] **Step 7: Run all gates and commit**

```bash
make compile lint test
git add prrr-github.el test/prrr-github-test.el test/prrr-test-helper.el test/fixtures/github/
git commit -m "feat(github): Immediate Publish, Discussion Comments, edit, delete, resolve, submit, discard"
```

---

### Task 4: Outbox rules (pure)

**Files:**
- Modify: `prrr-state.el` (new part `;;;; The Outbox` before `(provide 'prrr-state)`; Commentary)
- Modify: `test/prrr-state-test.el`

**Interfaces:**
- Consumes: `prrr-outbox`, `prrr-thread`, `prrr-comment` structs (Task 1).
- Produces:
  - `prrr-state-outbox-kinds` (the payload of every kind, documented once), `prrr-state-local-prefix` ("local:"), `prrr-state-creation-kinds`, `prrr-state-creations-per-minute` (80).
  - `(prrr-state-local-id-p ID)`, `(prrr-state-outbox-created-ids ROW)` → local ids ROW creates, `(prrr-state-outbox-references ROW)` → ids ROW acts on, `(prrr-state-outbox-ready-p ROW)`.
  - `(prrr-state-outbox-next ROWS CREATIONS NOW)` → nil or `(ROW . WAIT-SECONDS)`.
  - `(prrr-state-outbox-busy-prs ROWS)` → PR ids whose first write may be sent.
  - `(prrr-state-outbox-dependents ROWS IDS)` → rows needing IDS, transitively.
  - `(prrr-state-thread-renames OLD-COMMENTS NEW-COMMENTS)` → alist local Thread id → GitHub's.
  - `(prrr-state-outbox-created ROW RESULT)` → `(ROWS . RENAMES)`.
  - Private `prrr-state--outbox-heads`, `prrr-state--sendable-p`, `prrr-state--outbox-thread`, `prrr-state--outbox-comment` (Task 5 uses the last two).

- [ ] **Step 1: Write the failing tests**

Append to `test/prrr-state-test.el`, before `(provide 'prrr-state-test)`:

```elisp
;;;; The Outbox

  '(:host "api.github.com" :owner "example-org" :name "example-repo" :number 1
    :pr-id "PR_1" :me "example-me")

(defun prrr-state-test--write (id pr-id kind payload &optional last-error)
  "A queued write ID of PR-ID with KIND, PAYLOAD and LAST-ERROR."
  (prrr-outbox-create :id id :pr-id pr-id :kind kind
                      :payload (append (list :target prrr-state-test--target) payload)
                      :created-at "2026-10-10T12:00:00Z" :attempts 0
                      :last-error last-error))

(ert-deftest prrr-state-test-outbox-next-in-order-per-pr ()
  (let ((a (prrr-state-test--write "1" "PR_1" 'viewed '(:path "a")))
        (b (prrr-state-test--write "2" "PR_1" 'viewed '(:path "b")))
        (c (prrr-state-test--write "3" "PR_2" 'viewed '(:path "c"))))
    (should (equal (cons a 0) (prrr-state-outbox-next (list a b c) nil 100.0)))
    (should (equal '("PR_1" "PR_2") (prrr-state-outbox-busy-prs (list a b c))))
    ;; A failed write holds back its PR, not the others.
    (setf (prrr-outbox-last-error a) "offline")
    (should (equal (cons c 0) (prrr-state-outbox-next (list a b c) nil 100.0)))
    (should (equal '("PR_2") (prrr-state-outbox-busy-prs (list a b c))))
    (should-not (prrr-state-outbox-next (list a b) nil 100.0))))

(ert-deftest prrr-state-test-outbox-next-waits-for-ids ()
  "A write on something GitHub has not named yet waits."
  (let ((reply (prrr-state-test--write "1" "PR_1" 'reply
                                       '(:thread-id "local:T" :comment "local:C"))))
    (should-not (prrr-state-outbox-ready-p reply))
    (should-not (prrr-state-outbox-next (list reply) nil 100.0))
    (should-not (prrr-state-outbox-busy-prs (list reply)))))

(ert-deftest prrr-state-test-outbox-next-creations-per-minute ()
  "SPEC section 4: at most 80 content creations in any minute."
  (let ((thread (prrr-state-test--write "1" "PR_1" 'thread
                                        '(:thread "local:T" :comment "local:C")))
        (viewed (prrr-state-test--write "2" "PR_1" 'viewed '(:path "a")))
        (times (number-sequence 41.0 120.0 1.0)))
    (should (= 80 (length times)))
    ;; The oldest of the 80, sent at 41, leaves the window at 101.
    (should (equal (cons thread 1.0) (prrr-state-outbox-next (list thread) times 100.0)))
    (should (equal (cons thread 0) (prrr-state-outbox-next (list thread) (cdr times) 100.0)))
    (should (equal (cons viewed 0) (prrr-state-outbox-next (list viewed) times 100.0)))))

(ert-deftest prrr-state-test-outbox-dependents ()
  (let* ((thread (prrr-state-test--write "1" "PR_1" 'thread
                                         '(:thread "local:T" :comment "local:C")))
         (reply (prrr-state-test--write "2" "PR_1" 'reply
                                        '(:thread-id "local:T" :comment "local:R")))
         (edit (prrr-state-test--write "3" "PR_1" 'edit '(:comment-id "local:R" :body "x")))
         (other (prrr-state-test--write "4" "PR_1" 'edit '(:comment-id "PRRC_1" :body "y")))
         (rows (list thread reply edit other)))
    (should (equal '("local:T" "local:C") (prrr-state-outbox-created-ids thread)))
    (should (equal (list reply edit)
                   (prrr-state-outbox-dependents rows (prrr-state-outbox-created-ids thread))))
    (should-not (prrr-state-outbox-dependents rows '("local:X")))))

(ert-deftest prrr-state-test-thread-renames ()
  (should (equal '(("local:T" . "PRRT_9"))
                 (prrr-state-thread-renames
                  (list (prrr-comment-create :comment-id "PRRC_1" :thread-id "local:T")
                        (prrr-comment-create :comment-id "PRRC_2" :thread-id "local:T")
                        (prrr-comment-create :comment-id "PRRC_3" :thread-id "PRRT_3"))
                  (list (prrr-comment-create :comment-id "PRRC_1" :thread-id "PRRT_9")
                        (prrr-comment-create :comment-id "PRRC_2" :thread-id "PRRT_9")))))
  (should-not (prrr-state-thread-renames
               (list (prrr-comment-create :comment-id "PRRC_1" :thread-id "local:T"))
               nil)))

(ert-deftest prrr-state-test-outbox-created-thread ()
  (let ((write (prrr-state-test--write
                "1" "PR_1" 'thread
                '(:thread "local:T" :comment "local:C" :body "Nit." :commit "1111"
                  :anchor (:path "a.el" :line 3 :side right :subject-type line)))))
    (pcase-let ((`(,rows . ,renames)
                 (prrr-state-outbox-created write '(:thread-id "PRRT_1" :comment-id "PRRC_1"
                                                    :created-at "2026-10-10T12:00:00Z"
                                                    :database-id "9" :review-id "PRR_1"))))
      (should (equal '(("local:T" . "PRRT_1") ("local:C" . "PRRC_1")) renames))
      (pcase-let ((`(,thread ,comment) rows))
        (should (equal '("PRRT_1" "a.el" 3 right)
                       (list (prrr-thread-thread-id thread) (prrr-thread-path thread)
                             (prrr-thread-line thread) (prrr-thread-side thread))))
        (should (equal '("PRRC_1" "PRRT_1" "example-me" "Nit." pending sent "PRR_1" "9")
                       (list (prrr-comment-comment-id comment) (prrr-comment-thread-id comment)
                             (prrr-comment-author comment) (prrr-comment-body comment)
                             (prrr-comment-state comment) (prrr-comment-local-state comment)
                             (prrr-comment-review-id comment)
                             (prrr-comment-database-id comment))))))))

(ert-deftest prrr-state-test-outbox-created-published-thread-keeps-local-id ()
  "GitHub's answer to Immediate Publish does not name the Thread."
  (let ((write (prrr-state-test--write
                "1" "PR_1" 'publish
                '(:thread "local:T" :comment "local:C" :body "Now."
                  :anchor (:path "a.el" :line 3 :side right)))))
    (pcase-let ((`((,thread ,comment) . ,renames)
                 (prrr-state-outbox-created write '(:comment-id "PRRC_1" :database-id "9"))))
      (should (equal '(("local:C" . "PRRC_1")) renames))
      (should (equal "local:T" (prrr-thread-thread-id thread)))
      (should (eq 'submitted (prrr-comment-state comment))))))

(ert-deftest prrr-state-test-outbox-created-reply ()
  (let ((write (prrr-state-test--write "1" "PR_1" 'reply
                                       '(:thread-id "PRRT_1" :comment "local:R" :body "Yes."))))
    (pcase-let ((`((,comment) . ,renames)
                 (prrr-state-outbox-created write '(:comment-id "PRRC_2" :review-id "PRR_1"))))
      (should (equal '(("local:R" . "PRRC_2")) renames))
      (should (equal "PRRT_1" (prrr-comment-thread-id comment))))))
```

- [ ] **Step 2: Run them to verify they fail**

Run: `make test TESTS=test/prrr-state-test.el`
Expected: FAIL, `prrr-state-outbox-next` is void.

- [ ] **Step 3: Implement**

Insert before `(provide 'prrr-state)`:

```elisp
;;;; The Outbox

  '(thread publish reply publish-reply edit delete resolve viewed discussion
    submit discard)

(defconst prrr-state-local-prefix "local:"
  "Prefix of the ids prrr gives what it created before GitHub names it.")

(defun prrr-state-local-id-p (id)
  "Non-nil when ID is a local id, one GitHub has not given yet."
  (and (stringp id) (string-prefix-p prrr-state-local-prefix id)))

  '(thread publish reply publish-reply discussion submit)

(defconst prrr-state-creations-per-minute 80
  "Most content creations the Outbox sends in any minute.")

(defun prrr-state-outbox-created-ids (row)
  "Return the local ids of what the write ROW creates."
  (let ((payload (prrr-outbox-payload row)))
    (delq nil (list (plist-get payload :thread) (plist-get payload :comment)))))

(defun prrr-state-outbox-references (row)
  "Return the ids of the existing things the write ROW acts on."
  (let ((payload (prrr-outbox-payload row)))
    (pcase (prrr-outbox-kind row)
      ((or 'reply 'publish-reply 'resolve) (list (plist-get payload :thread-id)))
      ((or 'edit 'delete) (list (plist-get payload :comment-id))))))

(defun prrr-state-outbox-ready-p (row)
  "Non-nil when every id the write ROW acts on is GitHub's.
A write that acts on something still known by a local id waits."
  (not (seq-some #'prrr-state-local-id-p (prrr-state-outbox-references row))))

(defun prrr-state--outbox-heads (rows)
  "Return the first row of each PR among ROWS, in the order of ROWS."
  (let ((seen nil) (heads nil))
    (dolist (row rows)
      (unless (member (prrr-outbox-pr-id row) seen)
        (push (prrr-outbox-pr-id row) seen)
        (push row heads)))
    (nreverse heads)))

(defun prrr-state--sendable-p (row)
  "Non-nil when the write ROW, the first of its PR, may be sent."
  (and (null (prrr-outbox-last-error row)) (prrr-state-outbox-ready-p row)))

(defun prrr-state-outbox-busy-prs (rows)
  "Return the ids of the PRs among ROWS whose first write may be sent.
The writes of one PR go out in order, so a failed or waiting first
write holds back the rest of its PR."
  (mapcar #'prrr-outbox-pr-id
          (seq-filter #'prrr-state--sendable-p (prrr-state--outbox-heads rows))))

(defun prrr-state-outbox-next (rows creations now)
  "Choose the write the Outbox sends next.
ROWS are every queued `prrr-outbox' row, oldest first; CREATIONS the
times, as floats, at which content creations were sent; NOW the
current float time.  Each PR's writes go out in order: only its first
write is a candidate, and only when it has not failed and acts on no
local id.  The oldest candidate wins.  Return nil when there is none,
else (ROW . WAIT): send ROW after WAIT seconds, which is 0 unless ROW
creates content and `prrr-state-creations-per-minute' were sent in the
last minute."
  (when-let ((row (seq-find #'prrr-state--sendable-p (prrr-state--outbox-heads rows))))
    (cons row
          (let ((recent (sort (seq-filter (lambda (time) (> time (- now 60))) creations) #'<)))
            (if (or (not (memq (prrr-outbox-kind row) prrr-state-creation-kinds))
                    (< (length recent) prrr-state-creations-per-minute))
                0
              (- (+ (nth (- (length recent) prrr-state-creations-per-minute) recent) 60)
                 now))))))

(defun prrr-state-outbox-dependents (rows ids)
  "Return the rows among ROWS whose write needs one of IDS.
A write needs an id it acts on, or one created by another write that
needs one of IDS.  The rows keep the order of ROWS."
  (let ((needed ids) (found nil) (changed t))
    (while changed
      (setq changed nil)
      (dolist (row rows)
        (when (and (not (memq row found))
                   (seq-some (lambda (id) (member id needed))
                             (prrr-state-outbox-references row)))
          (push row found)
          (setq needed (append (prrr-state-outbox-created-ids row) needed)
                changed t))))
    (seq-filter (lambda (row) (memq row found)) rows)))

(defun prrr-state-thread-renames (old-comments new-comments)
  "Return an alist from local Thread id to GitHub's, learned from a refetch.
OLD-COMMENTS are the stored comments; NEW-COMMENTS those GitHub just
sent.  A comment published at once is stored under GitHub's comment id
but a local Thread id, because GitHub's answer does not name the
Thread; the refetch does."
  (let ((threads (make-hash-table :test #'equal)) (renames nil))
    (dolist (comment new-comments)
      (puthash (prrr-comment-comment-id comment) (prrr-comment-thread-id comment) threads))
    (dolist (comment old-comments)
      (let ((old (prrr-comment-thread-id comment))
            (new (gethash (prrr-comment-comment-id comment) threads)))
        (when (and (prrr-state-local-id-p old) new (not (assoc old renames)))
          (push (cons old new) renames))))
    (nreverse renames)))

(defun prrr-state--outbox-thread (row thread-id)
  "Return the Thread the write ROW creates, under THREAD-ID."
  (let* ((payload (prrr-outbox-payload row))
         (anchor (plist-get payload :anchor)))
    (prrr-thread-create :thread-id thread-id :pr-id (prrr-outbox-pr-id row)
                        :path (plist-get anchor :path) :line (plist-get anchor :line)
                        :start-line (plist-get anchor :start-line)
                        :side (plist-get anchor :side)
                        :start-side (plist-get anchor :start-side)
                        :subject-type (or (plist-get anchor :subject-type) 'line)
                        :outdated-p nil :resolved-p nil :resolvable-p nil
                        :original-line (plist-get anchor :line)
                        :original-commit (plist-get payload :commit))))

(defun prrr-state--outbox-comment (row comment-id thread-id created-at)
  "Return the comment the write ROW creates, under COMMENT-ID in THREAD-ID.
CREATED-AT is its creation time."
  (let ((payload (prrr-outbox-payload row)))
    (prrr-comment-create :comment-id comment-id :thread-id thread-id
                         :pr-id (prrr-outbox-pr-id row)
                         :author (plist-get (plist-get payload :target) :me)
                         :body (plist-get payload :body) :created-at created-at
                         :state (if (memq (prrr-outbox-kind row) '(thread reply))
                                    'pending
                                  'submitted)
                         :local-state 'unsent :agent-p nil)))

(defun prrr-state-outbox-created (row result)
  "Return (ROWS . RENAMES) once GitHub accepted the creating write ROW.
ROW's kind is `thread', `publish', `reply' or `publish-reply'.  RESULT
is GitHub's answer, a plist with :comment-id, :database-id and
:created-at, plus :thread-id and :review-id for a Thread added to the
Pending Review.  ROWS are the `prrr-thread' and `prrr-comment' to
store; RENAMES maps the write's local ids to GitHub's.  A Thread
published at once keeps its local id, since GitHub's answer does not
name it (see `prrr-state-thread-renames')."
  (let* ((payload (prrr-outbox-payload row))
         (local-thread (plist-get payload :thread))
         (thread-id (or (plist-get result :thread-id) local-thread
                        (plist-get payload :thread-id)))
         (comment (prrr-state--outbox-comment row (plist-get result :comment-id) thread-id
                                              (plist-get result :created-at))))
    (setf (prrr-comment-local-state comment) 'sent
          (prrr-comment-review-id comment) (plist-get result :review-id)
          (prrr-comment-database-id comment) (plist-get result :database-id))
    (cons (if local-thread
              (list (prrr-state--outbox-thread row thread-id) comment)
            (list comment))
          (delq nil (list (and local-thread (plist-get result :thread-id)
                               (cons local-thread (plist-get result :thread-id)))
                          (cons (plist-get payload :comment) (plist-get result :comment-id)))))))
```

In the Commentary, after the paragraph about `prrr-state-thread-layout`, add:

```
;;
;; The Outbox's rules are here as well: which queued write goes next,
;; which writes depend on which, and what a write leaves behind once
;; GitHub accepts it.  prrr-sync.el carries them out.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test TESTS=test/prrr-state-test.el`
Expected: all pass.

- [ ] **Step 5: Run all gates and commit**

```bash
make compile lint test
git add prrr-state.el test/prrr-state-test.el
git commit -m "feat(state): the Outbox's rules: order, rate, dependencies, ids"
```

---

### Task 5: What the user sees: the Outbox view (pure)

**Files:**
- Modify: `prrr-state.el` (the part `;;;; The Outbox`)
- Modify: `test/prrr-state-test.el`

**Interfaces:**
- Consumes: Task 4's `prrr-state--outbox-thread`, `prrr-state--outbox-comment`.
- Produces:
  - `(prrr-state-outbox-view DATA ROWS)` → DATA's plist (`:threads :comments :pending-review :viewed`) with ROWS applied, plus `:outbox` ROWS, `:writes` (hash table: comment id, Thread id or Viewed path → newest `prrr-outbox` row touching it), `:discussion` (list of `(ID BODY ROW)`), `:submit` (row or nil).
  - Private `(prrr-state--copy STRUCT &rest CHANGES)`.

- [ ] **Step 1: Write the failing tests**

Append to `test/prrr-state-test.el`, before `(provide 'prrr-state-test)`:

```elisp
;;;; What the user sees

(defun prrr-state-test--data ()
  "Stored review data: one Thread with my pending comment, and a Pending Review."
  (list :threads (list (prrr-test-thread :id "T1"))
        :comments (list (prrr-comment-create :comment-id "C1" :thread-id "T1" :pr-id "PR_1"
                                             :author "example-me" :body "Old."
                                             :state 'pending :local-state 'sent))
        :pending-review (prrr-pending-review-create :pr-id "PR_1" :review-id "PRR_1")
        :viewed nil))

(ert-deftest prrr-state-test-outbox-view-applies-writes ()
  (let* ((data (prrr-state-test--data))
         (rows (list (prrr-state-test--write "1" "PR_1" 'thread
                                             '(:thread "local:T" :comment "local:C" :body "New."
                                               :anchor (:path "b.el" :line 1 :side right)))
                     (prrr-state-test--write "2" "PR_1" 'edit '(:comment-id "C1" :body "Edited.")
                                             "offline")
                     (prrr-state-test--write "3" "PR_1" 'resolve '(:thread-id "T1" :resolved t))
                     (prrr-state-test--write "4" "PR_1" 'viewed '(:path "a.el" :viewed t))
                     (prrr-state-test--write "5" "PR_1" 'discussion
                                             '(:comment "local:D" :body "Thanks!"))
                     (prrr-state-test--write "6" "PR_1" 'submit '(:verdict approve :body ""))))
         (view (prrr-state-outbox-view data rows)))
    (should (equal '("T1" "local:T") (mapcar #'prrr-thread-thread-id (plist-get view :threads))))
    (should (equal '(("Edited." unsent) ("New." unsent))
                   (mapcar (lambda (comment) (list (prrr-comment-body comment)
                                                   (prrr-comment-local-state comment)))
                           (plist-get view :comments))))
    (should (prrr-thread-resolved-p (car (plist-get view :threads))))
    (should (eq 'viewed (prrr-viewed-state (car (plist-get view :viewed)))))
    (should (equal "Thanks!" (nth 1 (car (plist-get view :discussion)))))
    (should (equal "6" (prrr-outbox-id (plist-get view :submit))))
    (should (equal rows (plist-get view :outbox)))
    (let ((writes (plist-get view :writes)))
      (should (equal "offline" (prrr-outbox-last-error (gethash "C1" writes))))
      (should (equal "1" (prrr-outbox-id (gethash "local:C" writes))))
      (should (equal "3" (prrr-outbox-id (gethash "T1" writes))))
      (should (equal "4" (prrr-outbox-id (gethash "a.el" writes)))))
    ;; The stored rows are untouched.
    (should (equal "Old." (prrr-comment-body (car (plist-get data :comments)))))
    (should-not (prrr-thread-resolved-p (car (plist-get data :threads))))))

(ert-deftest prrr-state-test-outbox-view-delete ()
  "Deleting a Thread's last comment hides the Thread; a failed delete hides nothing."
  (let ((data (prrr-state-test--data)))
    (let ((view (prrr-state-outbox-view
                 data (list (prrr-state-test--write "1" "PR_1" 'delete '(:comment-id "C1"))))))
      (should-not (plist-get view :comments))
      (should-not (plist-get view :threads)))
    (let ((view (prrr-state-outbox-view
                 data (list (prrr-state-test--write "1" "PR_1" 'delete '(:comment-id "C1")
                                                    "GitHub returned HTTP 502")))))
      (should (= 1 (length (plist-get view :comments))))
      (should (gethash "C1" (plist-get view :writes))))))

(ert-deftest prrr-state-test-outbox-view-discard ()
  (let ((view (prrr-state-outbox-view (prrr-state-test--data)
                                      (list (prrr-state-test--write "1" "PR_1" 'discard nil)))))
    (should-not (plist-get view :pending-review))
    (should-not (plist-get view :comments))
    (should-not (plist-get view :threads))))

(ert-deftest prrr-state-test-outbox-view-keeps-threads-without-comments ()
  "A stored Thread whose comments are not stored is not the overlay's to hide."
  (let ((view (prrr-state-outbox-view (list :threads (list (prrr-test-thread)) :comments nil)
                                      nil)))
    (should (= 1 (length (plist-get view :threads))))
    (should (zerop (hash-table-count (plist-get view :writes))))))
```

- [ ] **Step 2: Run them to verify they fail**

Run: `make test TESTS=test/prrr-state-test.el`
Expected: FAIL, `prrr-state-outbox-view` is void.

- [ ] **Step 3: Implement**

Append to the part `;;;; The Outbox` of `prrr-state.el`, before `(provide 'prrr-state)`:

```elisp
(defun prrr-state--copy (struct &rest changes)
  "Return a copy of the row STRUCT with CHANGES, :SLOT VALUE pairs, applied."
  (let ((copy (copy-sequence struct)))
    (while changes
      (setf (cl-struct-slot-value (type-of copy) (intern (substring (symbol-name (pop changes)) 1))
                                  copy)
            (pop changes)))
    copy))

(defun prrr-state-outbox-view (data rows)
  "Return review DATA as the user sees it with the queued writes ROWS applied.
DATA is a plist like the one `prrr-db-review-data' returns; ROWS are
the PR's `prrr-outbox' rows, oldest first.  Threads, comments, the
Pending Review and Viewed flags change as each write will change them
on GitHub; created things carry their local ids and a `local-state' of
`unsent'.  A failed delete or discard changes nothing, so what it was
meant to remove stays in view.  The result has DATA's keys plus:
  :outbox      ROWS;
  :writes      a hash table from each comment id, Thread id and Viewed
               path a queued write touches to the newest such row;
  :discussion  the queued Discussion Comments as (ID BODY ROW) lists;
  :submit      the queued Submit row, or nil.
DATA's structs are never changed."
  (let ((threads (plist-get data :threads))
        (comments (plist-get data :comments))
        (pending (plist-get data :pending-review))
        (viewed (plist-get data :viewed))
        (writes (make-hash-table :test #'equal))
        (emptied nil) (discussion nil) (submit nil))
    (dolist (row rows)
      (let* ((payload (prrr-outbox-payload row))
             (failed (prrr-outbox-last-error row))
             (comment-id (plist-get payload :comment-id))
             (thread-id (plist-get payload :thread-id)))
        (pcase (prrr-outbox-kind row)
          ((or 'thread 'publish)
           (let ((thread (plist-get payload :thread))
                 (comment (plist-get payload :comment)))
             (setq threads (append threads (list (prrr-state--outbox-thread row thread)))
                   comments (append comments
                                    (list (prrr-state--outbox-comment
                                           row comment thread (prrr-outbox-created-at row)))))
             (puthash thread row writes)
             (puthash comment row writes)))
          ((or 'reply 'publish-reply)
           (let ((comment (plist-get payload :comment)))
             (setq comments (append comments
                                    (list (prrr-state--outbox-comment
                                           row comment thread-id (prrr-outbox-created-at row)))))
             (puthash comment row writes)))
          ('edit
           (setq comments (mapcar (lambda (comment)
                                    (if (equal (prrr-comment-comment-id comment) comment-id)
                                        (prrr-state--copy comment :body (plist-get payload :body)
                                                          :local-state 'unsent)
                                      comment))
                                  comments))
           (puthash comment-id row writes))
          ('delete
           (if failed
               (puthash comment-id row writes)
             (let ((gone (seq-find (lambda (comment)
                                     (equal (prrr-comment-comment-id comment) comment-id))
                                   comments)))
               (when gone
                 (push (prrr-comment-thread-id gone) emptied)
                 (setq comments (delq gone (copy-sequence comments)))))))
          ('resolve
           (setq threads (mapcar (lambda (thread)
                                   (if (equal (prrr-thread-thread-id thread) thread-id)
                                       (prrr-state--copy thread :resolved-p
                                                         (and (plist-get payload :resolved) t))
                                     thread))
                                 threads))
           (puthash thread-id row writes))
          ('viewed
           (let ((path (plist-get payload :path)))
             (setq viewed (append (seq-remove (lambda (flag) (equal (prrr-viewed-path flag) path))
                                              viewed)
                                  (list (prrr-viewed-create
                                         :pr-id (prrr-outbox-pr-id row) :path path
                                         :state (if (plist-get payload :viewed) 'viewed 'unviewed)))))
             (puthash path row writes)))
          ('discussion
           (push (list (plist-get payload :comment) (plist-get payload :body) row) discussion))
          ('discard
           (unless failed
             (dolist (comment comments)
               (when (eq (prrr-comment-state comment) 'pending)
                 (push (prrr-comment-thread-id comment) emptied)))
             (setq pending nil
                   comments (seq-remove (lambda (comment)
                                          (eq (prrr-comment-state comment) 'pending))
                                        comments))))
          ('submit (setq submit row)))))
    (when emptied
      (let ((live (make-hash-table :test #'equal)))
        (dolist (comment comments)
          (puthash (prrr-comment-thread-id comment) t live))
        (setq threads (seq-remove (lambda (thread)
                                    (let ((id (prrr-thread-thread-id thread)))
                                      (and (member id emptied) (not (gethash id live)))))
                                  threads))))
    (list :threads threads :comments comments :pending-review pending :viewed viewed
          :outbox rows :writes writes :discussion (nreverse discussion) :submit submit)))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test TESTS=test/prrr-state-test.el`
Expected: all pass.

- [ ] **Step 5: Run all gates and commit**

```bash
make compile lint test
git add prrr-state.el test/prrr-state-test.el
git commit -m "feat(state): the review data as the user sees it, queued writes applied"
```

---

### Task 6: The Outbox engine and Viewed through it

**Files:**
- Modify: `prrr-sync.el` (require `prrr-state`; Commentary; `prrr-sync-set-viewed` replaced by a new part `;;;; The Outbox`, placed after `prrr-sync-describe` and before `;;;; Commands`)
- Modify: `prrr-diff.el` (rename `prrr-diff--require-pullreq` to `prrr-diff-pullreq`; buffer state; `prrr-diff-refresh-buffer`; `prrr-diff--viewed-p`; `prrr-toggle-viewed`)
- Modify: `test/prrr-test-helper.el` (`prrr-test-with-ghub-dispatch` rewritten; `prrr-test-variables`, `prrr-test-timers`, `prrr-test-with-outbox`, `prrr-test-run-timers`; Commentary)
- Modify: `test/prrr-sync-test.el` (the three `prrr-sync-test-set-viewed-*` tests and their `;;;; Viewed` heading removed; Outbox tests added)
- Modify: `test/prrr-diff-test.el` (`prrr-diff-test-toggle-viewed` rewritten; an offline variant added)

**Interfaces:**
- Consumes: Tasks 1-5.
- Produces:
  - `(prrr-sync-write REPO PULLREQ KIND PAYLOAD &optional BUFFER)` → the `prrr-outbox` row. PAYLOAD omits `:target` and the local ids (`:thread`, `:comment`), which the Outbox adds. Signals `user-error` without a login.
  - `(prrr-sync-retry &optional PR-ID BUFFER)`, `(prrr-sync-discard ID)` → count dropped, `(prrr-sync-review-data PR-ID)` → `prrr-state-outbox-view` plist, `(prrr-sync-outbox-describe)` → "rate limited until HH:MM" or nil.
  - Private, used by later tasks: `prrr-sync--target` (plist `:host :owner :name :number :pr-id :me`), `prrr-sync--outbox-add`, `prrr-sync--outbox-pump`, `prrr-sync--outbox-run`, `prrr-sync--outbox-outcome`, `prrr-sync--outbox-succeeded`, `prrr-sync--mutate`, `prrr-sync--with-review`, `prrr-sync--sending-id`, `prrr-sync--remember-buffer`, `prrr-sync--outbox-changed`; variables `prrr-sync--mutation-spacing`, `prrr-sync--outbox-sending`, `prrr-sync--outbox-token`, `prrr-sync--outbox-mutated-at`, `prrr-sync--outbox-creations`, `prrr-sync--outbox-paused-until`, `prrr-sync--outbox-scheduled`, `prrr-sync--outbox-buffers`, `prrr-sync--outbox-dirty`.
  - `prrr-diff-pullreq` (public name of the old `prrr-diff--require-pullreq`); buffer-locals `prrr-diff--data` (the view) and `prrr-diff--comments` (comment id → struct).
  - Test helpers `prrr-test-with-outbox`, `prrr-test-run-timers`, `prrr-test-timers`, `prrr-test-variables`; `prrr-test-with-ghub-dispatch` answers `(:error ERR)` and functions.
- Removed: `prrr-sync-set-viewed`.

- [ ] **Step 1: The test helpers**

In `test/prrr-test-helper.el`, replace `prrr-test-with-ghub-dispatch` with the two forms below, and append the next four before `(provide 'prrr-test-helper)`:

```elisp
(defvar prrr-test-variables nil
  "In `prrr-test-with-ghub-dispatch': (FIELD . VARIABLES) of each request.
Newest first.")

(defmacro prrr-test-with-ghub-dispatch (alist &rest body)
  "Run BODY with `ghub-query' answering each request from ALIST.
ALIST maps the request's top-level field (`repository', `viewer', or a
mutation such as `addPullRequestReviewThread') to its answer: a
fixture datum; a function of the query and the variables that returns
one; or (:error ERR), which fails the request as ghub does, with ERR
and no headers.  Answers come synchronously.  The variable
`prrr-test-requests' collects the top-level field of every request,
oldest first, and `prrr-test-variables' their variables."
  (declare (indent 1) (debug (form body)))
  `(let ((prrr-test-requests nil)
         (prrr-test-variables nil))
     (cl-letf (((symbol-function 'ghub-query)
                (lambda (query variables &rest args)
                  (let* ((field (car (cadr query)))
                         (answer (or (alist-get field ,alist)
                                     (ert-fail (list "unexpected request" field))))
                         (answer (if (functionp answer) (funcall answer query variables) answer)))
                    (setq prrr-test-requests (append prrr-test-requests (list field)))
                    (push (cons field variables) prrr-test-variables)
                    (if (eq (car-safe answer) :error)
                        (funcall (plist-get args :errorback) (cadr answer) nil nil nil)
                      (funcall (plist-get args :callback) answer))))))
       ,@body)))
```

```elisp
(defvar prrr-test-timers nil
  "In `prrr-test-with-outbox': (TIME FUNCTION ARGS) of each timer, newest first.")

(defmacro prrr-test-with-outbox (&rest body)
  "Run BODY with an empty Outbox, no spacing between mutations, and no timers.
`run-at-time' records its calls in `prrr-test-timers' instead of
setting timers, so nothing runs later; run one with
`prrr-test-run-timers'.  The viewer is \"example-me\"."
  (declare (indent 0) (debug t))
  `(let ((prrr-sync--outbox-sending nil)
         (prrr-sync--outbox-token 0)
         (prrr-sync--outbox-mutated-at 0.0)
         (prrr-sync--outbox-creations nil)
         (prrr-sync--outbox-paused-until nil)
         (prrr-sync--outbox-scheduled nil)
         (prrr-sync--outbox-buffers (make-hash-table :test #'equal))
         (prrr-sync--outbox-dirty (make-hash-table :test #'equal))
         (prrr-sync--status (make-hash-table :test #'equal))
         (prrr-sync--mutation-spacing 0)
         (prrr-github-user "example-me")
         (prrr-test-timers nil))
     (cl-letf (((symbol-function 'run-at-time)
                (lambda (time _repeat function &rest args)
                  (push (list time function args) prrr-test-timers)
                  nil)))
       ,@body)))

(defun prrr-test-run-timers (function)
  "Run, and forget, the recorded timers that call FUNCTION, oldest first."
  (let ((due (reverse (seq-filter (lambda (timer) (eq (nth 1 timer) function))
                                  prrr-test-timers))))
    (setq prrr-test-timers (seq-difference prrr-test-timers due #'eq))
    (dolist (timer due)
      (apply (nth 1 timer) (nth 2 timer)))))
```

`prrr-test-with-outbox` binds variables of `prrr-sync.el`: every test file that uses it requires `prrr-sync` (directly or through `prrr-diff`), so the bindings are dynamic. In the helper's Commentary add: "`prrr-test-with-outbox' runs BODY with an empty Outbox that sends at once and records timers in `prrr-test-timers'; `prrr-test-run-timers' runs them."

- [ ] **Step 2: Write the failing tests**

In `test/prrr-sync-test.el`, delete `prrr-sync-test-set-viewed-writes-then-sends`, `prrr-sync-test-set-viewed-failure-restores-row`, `prrr-sync-test-set-viewed-failure-removes-new-row` and the `;;;; Viewed` line above them. Append before `(provide 'prrr-sync-test)`:

```elisp
;;;; The Outbox

  '(:path "src/example.el" :line 12 :side right :subject-type line)

(defconst prrr-sync-test--mark-viewed '((data (markFileAsViewed (clientMutationId))))
  "GitHub's answer to markFileAsViewed.")

(defun prrr-sync-test--write (kind payload)
  "Hand the write KIND with PAYLOAD to the fixture PR to the Outbox."
  (prrr-sync-write (prrr-sync-test--repo) (prrr-sync-test--pullreq) kind payload))

(defun prrr-sync-test--queue (kind payload)
  "Queue the write KIND with PAYLOAD for the fixture PR without sending anything."
  (prrr-sync--outbox-add prrr-sync-test--pr kind
                         (append (list :target (prrr-sync--target (prrr-sync-test--repo)
                                                                  (prrr-sync-test--pullreq)))
                                 payload)))

(defun prrr-sync-test--store-pending-review ()
  "Store the viewer's Pending Review of the fixture PR."
  (prrr-db-insert (prrr-pending-review-create :pr-id prrr-sync-test--pr
                                              :review-id "PRR_kwDOexamplePending1"
                                              :commit-oid "1111")))

(defun prrr-sync-test--input (field)
  "Return the input of the last request whose top-level field is FIELD."
  (alist-get 'input (cdr (assq field prrr-test-variables))))

(ert-deftest prrr-sync-test-outbox-shows-at-once-then-confirms ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (let ((callback nil) (sent nil))
        (cl-letf (((symbol-function 'ghub-query)
                   (lambda (_query variables &rest args)
                     (setq sent variables callback (plist-get args :callback)))))
          (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor :body "Nit."
                                               :commit "1111")))
        (should (equal '((input (pullRequestReviewId . "PRR_kwDOexamplePending1")
                                (path . "src/example.el") (body . "Nit.") (line . 12)
                                (side . "RIGHT")))
                       sent))
        (let ((comment (car (last (plist-get (prrr-sync-review-data prrr-sync-test--pr)
                                             :comments)))))
          (should (prrr-state-local-id-p (prrr-comment-comment-id comment)))
          (should (eq 'unsent (prrr-comment-local-state comment))))
        (funcall callback (prrr-test-fixture "add-thread"))
        (should-not (prrr-db-outbox-rows))
        (let ((comment (prrr-db-get 'review-comment "PRRC_kwDOexampleNew01")))
          (should (equal '("PRRT_kwDOexampleNew01" pending sent "PRR_kwDOexamplePending1" "2001")
                         (list (prrr-comment-thread-id comment) (prrr-comment-state comment)
                               (prrr-comment-local-state comment)
                               (prrr-comment-review-id comment)
                               (prrr-comment-database-id comment)))))
        (should (prrr-db-get 'thread "PRRT_kwDOexampleNew01"))))))

(ert-deftest prrr-sync-test-outbox-creates-the-pending-review ()
  "SPEC section 7: the first pending comment creates the Pending Review, after looking."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch
          `((repository . ,(prrr-test-fixture "pending-review-none"))
            (addPullRequestReview . ,(prrr-test-fixture "create-review"))
            (addPullRequestReviewThread . ,(prrr-test-fixture "add-thread")))
        (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor :body "Nit."
                                             :commit "1111"))
        (should (equal '(repository addPullRequestReview addPullRequestReviewThread)
                       prrr-test-requests))
        (should (equal "1111" (alist-get 'commitOID (prrr-sync-test--input
                                                     'addPullRequestReview))))
        (should (equal "PRR_kwDOexampleNew01"
                       (prrr-pending-review-review-id
                        (prrr-db-get 'pending-review prrr-sync-test--pr))))))))

(ert-deftest prrr-sync-test-outbox-reuses-the-pending-review-found ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch
          `((repository . ,(prrr-test-fixture "pending-review"))
            (addPullRequestReviewThread . ,(prrr-test-fixture "add-thread")))
        (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor :body "Nit."
                                             :commit "1111"))
        (should (equal '(repository addPullRequestReviewThread) prrr-test-requests))
        (should (equal "PRR_kwDOexamplePending1"
                       (alist-get 'pullRequestReviewId
                                  (prrr-sync-test--input 'addPullRequestReviewThread))))))))

(ert-deftest prrr-sync-test-outbox-reply-to-an-unsent-thread ()
  "Review Focus 3: a reply waits for its Thread, then goes out under GitHub's id."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (let ((callbacks nil) (fields nil))
        (cl-letf (((symbol-function 'ghub-query)
                   (lambda (query variables &rest args)
                     (push (cons (car (cadr query)) variables) fields)
                     (push (plist-get args :callback) callbacks))))
          (let ((thread (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor
                                                             :body "Nit." :commit "1111"))))
            (prrr-sync-test--write 'reply (list :thread-id (plist-get (prrr-outbox-payload thread)
                                                                      :thread)
                                                :body "And this."))
            (should (= 1 (length fields)))
            (funcall (car callbacks) (prrr-test-fixture "add-thread"))
            (should (equal 'addPullRequestReviewThreadReply (car (car fields))))
            (should (equal "PRRT_kwDOexampleNew01"
                           (alist-get 'pullRequestReviewThreadId
                                      (alist-get 'input (cdr (car fields))))))
            (funcall (car callbacks) (prrr-test-fixture "add-reply"))
            (should-not (prrr-db-outbox-rows))
            (should (equal "PRRT_kwDOexampleNew01"
                           (prrr-comment-thread-id
                            (prrr-db-get 'review-comment "PRRC_kwDOexampleNew02"))))))))))

(ert-deftest prrr-sync-test-outbox-failure-kept-and-retried ()
  "Review Focus 1: a failed write stays, shows, and goes out on retry."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch '((markFileAsViewed . (:error (error http 502))))
        (prrr-sync-test--write 'viewed '(:path "a.el" :viewed t)))
      (let ((row (car (prrr-db-outbox-rows))))
        (should (equal "GitHub returned HTTP 502" (prrr-outbox-last-error row)))
        (should (= 1 (prrr-outbox-attempts row))))
      (should (eq 'viewed (prrr-viewed-state
                           (car (plist-get (prrr-sync-review-data prrr-sync-test--pr) :viewed)))))
      (prrr-test-with-ghub-dispatch `((markFileAsViewed . ,prrr-sync-test--mark-viewed))
        (prrr-sync-retry prrr-sync-test--pr))
      (should-not (prrr-db-outbox-rows))
      (should (eq 'viewed (prrr-viewed-state (prrr-db-get 'viewed prrr-sync-test--pr "a.el")))))))

(ert-deftest prrr-sync-test-outbox-failed-write-holds-back-its-pr-only ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch '((markFileAsViewed . (:error (error http 502))))
        (prrr-sync-test--write 'viewed '(:path "a.el" :viewed t)))
      (prrr-test-with-ghub-dispatch `((markFileAsViewed . ,prrr-sync-test--mark-viewed))
        (prrr-sync-test--queue 'viewed '(:path "b.el" :viewed t))
        (prrr-sync--outbox-add "PR_other" 'viewed
                               '(:target (:host "api.github.com" :pr-id "PR_other" :me "example-me")
                                 :path "c.el" :viewed t))
        (prrr-sync--outbox-pump)
        (should (equal '(markFileAsViewed) prrr-test-requests))
        (should (equal "PR_other" (alist-get 'pullRequestId
                                             (prrr-sync-test--input 'markFileAsViewed)))))
      (should (equal '("a.el" "b.el")
                     (mapcar (lambda (row) (plist-get (prrr-outbox-payload row) :path))
                             (prrr-db-outbox-rows)))))))

(ert-deftest prrr-sync-test-outbox-rate-limit-pauses ()
  "SPEC section 11: a rate limit pauses the Outbox until it resets."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch
          '((markFileAsViewed . (:error (errors ((type . "RATE_LIMITED") (message . "Slow down"))))))
        (prrr-sync-test--write 'viewed '(:path "a.el" :viewed t)))
      (should-not (prrr-outbox-last-error (car (prrr-db-outbox-rows))))
      (should (string-prefix-p "rate limited until" (prrr-sync-outbox-describe)))
      (should prrr-sync--outbox-scheduled)
      (prrr-test-with-ghub-dispatch nil
        (prrr-sync-retry prrr-sync-test--pr)
        (should-not prrr-test-requests)))))

(ert-deftest prrr-sync-test-outbox-spaces-mutations ()
  "SPEC section 4: a second apart."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (let ((prrr-sync--mutation-spacing 1.0))
        (prrr-test-with-ghub-dispatch `((markFileAsViewed . ,prrr-sync-test--mark-viewed))
          (prrr-sync-test--write 'viewed '(:path "a.el" :viewed t))
          (prrr-sync-test--write 'viewed '(:path "b.el" :viewed t))
          (should (= 1 (length prrr-test-requests)))
          (let ((timer (seq-find (lambda (timer) (and (numberp (car timer))
                                                      (< 0 (car timer) 1.01)))
                                 prrr-test-timers)))
            (should timer)
            (funcall (nth 1 timer)))
          (should (= 2 (length prrr-test-requests)))
          (should-not (prrr-db-outbox-rows)))))))

(ert-deftest prrr-sync-test-outbox-no-answer-then-late-answer ()
  "A write without an answer fails as offline; an answer that comes later still counts."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (let ((callback nil))
        (cl-letf (((symbol-function 'ghub-query)
                   (lambda (_query _variables &rest args)
                     (setq callback (plist-get args :callback)))))
          (prrr-sync-test--write 'viewed '(:path "a.el" :viewed t)))
        (let ((watchdog (seq-find (lambda (timer) (eql (car timer) prrr-sync-timeout))
                                  prrr-test-timers)))
          (apply (nth 1 watchdog) (nth 2 watchdog)))
        (should (equal "No answer from GitHub" (prrr-outbox-last-error (car (prrr-db-outbox-rows)))))
        (should-not prrr-sync--outbox-sending)
        (funcall callback prrr-sync-test--mark-viewed)
        (should-not (prrr-db-outbox-rows))
        (should (prrr-db-get 'viewed prrr-sync-test--pr "a.el"))))))

(ert-deftest prrr-sync-test-outbox-sends-after-a-restart ()
  "A queued write carries all it needs: no forge object, no buffer."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--queue 'viewed '(:path "a.el" :viewed t)))
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch `((markFileAsViewed . ,prrr-sync-test--mark-viewed))
        (prrr-sync-retry)
        (should (equal '(markFileAsViewed) prrr-test-requests))
        (should-not (prrr-db-outbox-rows))))))

(ert-deftest prrr-sync-test-outbox-discard-takes-dependents ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (prrr-test-with-ghub-dispatch '((addPullRequestReviewThread . (:error (error http 502))))
        (let ((thread (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor
                                                           :body "Nit." :commit "1111"))))
          (prrr-sync-test--write 'reply (list :thread-id (plist-get (prrr-outbox-payload thread)
                                                                    :thread)
                                              :body "More."))
          (should (= 2 (prrr-sync-discard (prrr-outbox-id thread))))
          (should-not (prrr-db-outbox-rows))
          (should-not (plist-get (prrr-sync-review-data prrr-sync-test--pr) :comments)))))))

(ert-deftest prrr-sync-test-outbox-needs-a-login ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (let ((prrr-github-user nil))
        (cl-letf (((symbol-function 'magit-get) #'ignore))
          (should-error (prrr-sync-test--write 'viewed '(:path "a.el" :viewed t))
                        :type 'user-error)))
      (should-not (prrr-db-outbox-rows)))))
```

In `test/prrr-diff-test.el`, replace `prrr-diff-test-toggle-viewed` with the first form below and add the second after it:

```elisp
(ert-deftest prrr-diff-test-toggle-viewed ()
  "Toggling Viewed writes through the Outbox, shows at once and folds."
  (prrr-diff-test--with-buffer nil
    (prrr-test-with-outbox
      (cl-letf (((symbol-function 'forge-get-repository)
                 (lambda (&rest _) (forge-github-repository :id "r" :owner "example-org"
                                                            :name "example-repo"
                                                            :apihost "api.github.com"))))
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
          (should (equal '(file . "README.md") (prrr-diff-test--at))))))))

(ert-deftest prrr-diff-test-toggle-viewed-offline-shows-at-once ()
  "Review Focus 1: offline, the flag shows and folds, and stays in the Outbox."
  (prrr-diff-test--with-buffer nil
    (prrr-test-with-outbox
      (cl-letf (((symbol-function 'forge-get-repository)
                 (lambda (&rest _) (forge-github-repository :id "r" :owner "example-org"
                                                            :name "example-repo"
                                                            :apihost "api.github.com"))))
        (prrr-test-with-ghub-error-stub '(error http 502) nil
          (prrr-jump-to-file "README.md")
          (prrr-toggle-viewed))
        (should-not (prrr-db-get 'viewed prrr-diff-test--pr "README.md"))
        (should (= 1 (length (prrr-db-outbox-rows prrr-diff-test--pr))))
        (let ((readme (prrr-diff-test--file-section "README.md")))
          (should (oref readme hidden))
          (should (string-match-p "✓ viewed" (prrr-diff-test--text readme))))))))
```

- [ ] **Step 3: Run them to verify they fail**

Run: `make test TESTS="test/prrr-sync-test.el test/prrr-diff-test.el"`
Expected: FAIL; `prrr-sync-write` is void.

- [ ] **Step 4: The Outbox**

In `prrr-sync.el`, add `(require 'prrr-state)` after `(require 'prrr-github)`. Replace the Commentary's last paragraph ("Per-PR refetches of review data live here too.  The Outbox retry arrives in milestone 4.") with:

```
;; Per-PR refetches of review data live here too, and so does the
;; Outbox, the one way prrr writes to GitHub (SPEC section 7): a
;; command hands `prrr-sync-write' a kind of write and its payload;
;; the Outbox stores it, shows it at once through
;; `prrr-sync-review-data', and sends the queued writes one at a time,
;; in order per PR, a second apart, retrying failures on the next
;; write, the next refetch or `prrr-sync-retry'.  Its rules are pure
;; functions in prrr-state.el.
```

Delete `prrr-sync-set-viewed` and put in its place:

```elisp
;;;; The Outbox

(defvar prrr-sync--mutation-spacing 1.0
  "Fewest seconds between one mutation's answer and the next mutation.
GitHub asks for at least a second (SPEC section 4).  Tests set it to 0.")

(defvar prrr-sync--outbox-sending nil
  "The `prrr-outbox' row being sent, or nil.  One write is sent at a time.")

(defvar prrr-sync--outbox-token 0
  "Identifies the latest send.  Counts up.")

(defvar prrr-sync--outbox-mutated-at 0.0
  "When the last mutation answered, as a float time.")

(defvar prrr-sync--outbox-creations nil
  "When each content creation of the last minute was sent, as float times.")

(defvar prrr-sync--outbox-paused-until nil
  "When the rate limit that pauses the Outbox ends, a timestamp, or nil.")

(defvar prrr-sync--outbox-scheduled nil
  "Non-nil while a timer is set to run `prrr-sync--outbox-pump'.")

(defvar prrr-sync--outbox-buffers (make-hash-table :test #'equal)
  "Hash table from PR id to the buffer to refresh when its writes change.")

(defvar prrr-sync--outbox-dirty (make-hash-table :test #'equal)
  "Hash table from PR id to its target, for each PR GitHub changed.
A PR is here from a write's success until a refetch of it starts, so
the Outbox refetches it once it has nothing more to send.")

(defvar prrr-sync--id-counter 0
  "Last counter used by `prrr-sync--new-id'.")

(defun prrr-sync--new-id ()
  "Return a new id, unique and greater than every id returned before."
  (setq prrr-sync--id-counter (% (1+ prrr-sync--id-counter) 10000))
  (format "%s-%04d" (format-time-string "%Y%m%dT%H%M%S.%6N" nil t) prrr-sync--id-counter))

(defun prrr-sync--target (repo pullreq)
  "Return how the Outbox reaches PULLREQ of REPO on GitHub, as a plist.
Keys :host, :owner, :name, :number, :pr-id and :me, the viewer's
login.  Every write stores it, so the Outbox can send the write after a
restart without forge's objects."
  (list :host (oref repo apihost) :owner (oref repo owner) :name (oref repo name)
        :number (oref pullreq number) :pr-id (oref pullreq their-id)
        :me (prrr-github-viewer)))

(defun prrr-sync--remember-buffer (pr-id buffer)
  "Refresh BUFFER, when live, whenever the writes of PR-ID change."
  (when (and pr-id (buffer-live-p buffer))
    (puthash pr-id buffer prrr-sync--outbox-buffers)))

(defun prrr-sync--outbox-changed (pr-id)
  "Refresh the buffer remembered for PR-ID, or every one when PR-ID is nil."
  (if pr-id
      (prrr-sync--schedule-refresh (gethash pr-id prrr-sync--outbox-buffers))
    (maphash (lambda (_pr-id buffer) (prrr-sync--schedule-refresh buffer))
             prrr-sync--outbox-buffers)))

(defun prrr-sync--sending-id ()
  "Return the id of the write being sent, or nil."
  (and prrr-sync--outbox-sending (prrr-outbox-id prrr-sync--outbox-sending)))

(defun prrr-sync--local-id ()
  "Return a new local id."
  (concat prrr-state-local-prefix (prrr-sync--new-id)))

(defun prrr-sync--outbox-payload (kind payload target)
  "Return PAYLOAD of a write KIND completed with TARGET and its local ids."
  (append (list :target target)
          (and (memq kind '(thread publish)) (list :thread (prrr-sync--local-id)))
          (and (memq kind '(thread publish reply publish-reply discussion))
               (list :comment (prrr-sync--local-id)))
          payload))

(defun prrr-sync--outbox-add (pr-id kind payload)
  "Queue the write KIND with PAYLOAD for PR-ID and return its row."
  (prrr-db-insert (prrr-outbox-create :id (prrr-sync--new-id) :pr-id pr-id :kind kind
                                      :payload payload :created-at (prrr-sync--timestamp)
                                      :attempts 0 :last-error nil)))

(defun prrr-sync-write (repo pullreq kind payload &optional buffer)
  "Make the write KIND with PAYLOAD reach PULLREQ of REPO on GitHub.
KIND and PAYLOAD are as `prrr-state-outbox-kinds' describes, without
:target and the local ids, which this adds.  The write is stored in
the Outbox, so `prrr-sync-review-data' shows it at once, and is sent in
the background after the PR's earlier writes, one mutation at a time
\(SPEC section 4).  Every failed write of the PR is tried again too.
BUFFER, when live, refreshes whenever the PR's writes change.  Return
the write's `prrr-outbox' row.  Signal a `user-error' when the
viewer's login is unknown."
  (let* ((target (prrr-sync--target repo pullreq))
         (pr-id (plist-get target :pr-id)))
    (unless (plist-get target :me)
      (user-error "No GitHub login: set github.user or `prrr-github-user'"))
    (prrr-sync--remember-buffer pr-id buffer)
    (prog1 (prrr-sync--outbox-add pr-id kind (prrr-sync--outbox-payload kind payload target))
      (prrr-sync-retry pr-id))))

(defun prrr-sync-retry (&optional pr-id buffer)
  "Send the failed writes of PR-ID again, or those of every PR when nil.
BUFFER, when live, refreshes whenever the PR's writes change."
  (prrr-sync--remember-buffer pr-id buffer)
  (prrr-db-outbox-clear-errors pr-id)
  (prrr-sync--outbox-changed pr-id)
  (prrr-sync--outbox-pump))

(defun prrr-sync-discard (id)
  "Drop the queued write ID and every queued write that needs what it creates.
Return how many writes were dropped.  Signal a `user-error' while ID
is being sent."
  (when-let ((row (prrr-db-get 'outbox id)))
    (when (equal id (prrr-sync--sending-id))
      (user-error "That write is being sent; try again in a moment"))
    (let ((drop (cons row (prrr-state-outbox-dependents
                           (prrr-db-outbox-rows (prrr-outbox-pr-id row))
                           (prrr-state-outbox-created-ids row)))))
      (dolist (dropped drop)
        (prrr-db-delete 'outbox :id (prrr-outbox-id dropped)))
      (prrr-sync--outbox-changed (prrr-outbox-pr-id row))
      (prrr-sync--outbox-pump)
      (length drop))))

(defun prrr-sync-review-data (pr-id)
  "Return the review data of PR-ID as the user should see it.
That is what GitHub sent at the last refetch with the PR's queued
writes applied: see `prrr-state-outbox-view' for the plist."
  (prrr-state-outbox-view (prrr-db-review-data pr-id) (prrr-db-outbox-rows pr-id)))

(defun prrr-sync-outbox-describe ()
  "Return a few words on why the Outbox is not sending, or nil."
  (when (prrr-sync--outbox-paused-p)
    (prrr-sync-describe (list :state 'rate-limited :reset-at prrr-sync--outbox-paused-until))))

(defun prrr-sync--outbox-paused-p ()
  "Non-nil while a rate limit pauses the Outbox."
  (and prrr-sync--outbox-paused-until
       (string< (prrr-sync--timestamp) prrr-sync--outbox-paused-until)))

(defun prrr-sync--outbox-schedule (seconds)
  "Run `prrr-sync--outbox-pump' in SECONDS."
  (setq prrr-sync--outbox-scheduled t)
  (run-at-time (max seconds 0) nil
               (lambda ()
                 (setq prrr-sync--outbox-scheduled nil)
                 (prrr-sync--outbox-pump))))

(defun prrr-sync--outbox-pump ()
  "Send the next write the Outbox may send, or arrange to try later.
Does nothing while a write is being sent or a timer will try later."
  (unless (or prrr-sync--outbox-sending prrr-sync--outbox-scheduled)
    (if (prrr-sync--outbox-paused-p)
        (prrr-sync--outbox-schedule
         (float-time (time-subtract (parse-iso8601-time-string prrr-sync--outbox-paused-until)
                                    nil)))
      (setq prrr-sync--outbox-paused-until nil)
      (pcase (prrr-state-outbox-next (prrr-db-outbox-rows) prrr-sync--outbox-creations
                                     (float-time))
        (`(,row . ,wait)
         (if (> wait 0)
             (prrr-sync--outbox-schedule wait)
           (prrr-sync--outbox-send row)))))))

(defun prrr-sync--outbox-current-p (token)
  "Non-nil when the send identified by TOKEN is still running."
  (and prrr-sync--outbox-sending (eql token prrr-sync--outbox-token)))

(defun prrr-sync--outbox-send (row)
  "Send the write ROW.
It ends as a failure, `offline', when GitHub has not answered after
`prrr-sync-timeout' seconds."
  (let* ((token (cl-incf prrr-sync--outbox-token))
         (now (float-time))
         (done (lambda (&optional result) (prrr-sync--outbox-succeeded row token result)))
         (fail (lambda (failure) (prrr-sync--outbox-failed row token failure))))
    (setq prrr-sync--outbox-sending row)
    (when (memq (prrr-outbox-kind row) prrr-state-creation-kinds)
      (setq prrr-sync--outbox-creations
            (cons now (seq-filter (lambda (time) (> time (- now 60)))
                                  prrr-sync--outbox-creations))))
    (run-at-time prrr-sync-timeout nil fail
                 '(:kind offline :message "No answer from GitHub" :reset-at nil))
    (prrr-sync--guarded fail
      (prrr-sync--outbox-run row done fail))))

(defun prrr-sync--mutate (start then fail)
  "Run a mutation once `prrr-sync--mutation-spacing' allows.
START is called with a callback and an errorback.  THEN receives what
the callback receives, FAIL what the errorback receives."
  (let* ((stamp (lambda () (setq prrr-sync--outbox-mutated-at (float-time))))
         (go (lambda ()
               (prrr-sync--guarded fail
                 (funcall start
                          (lambda (&optional result) (funcall stamp) (funcall then result))
                          (lambda (failure) (funcall stamp) (funcall fail failure))))))
         (wait (- (+ prrr-sync--outbox-mutated-at prrr-sync--mutation-spacing) (float-time))))
    (if (> wait 0)
        (run-at-time wait nil go)
      (funcall go))))

(defun prrr-sync--with-review (target commit create then fail)
  "Call THEN with the id of the viewer's Pending Review of TARGET's PR.
The stored review is used when there is one; otherwise GitHub is asked,
and when it has none and CREATE is non-nil, a review is created on
COMMIT.  THEN receives nil when there is none and CREATE is nil.  FAIL
receives a classified failure."
  (let ((pr-id (plist-get target :pr-id))
        (host (plist-get target :host)))
    (if-let ((stored (prrr-db-get 'pending-review pr-id)))
        (funcall then (prrr-pending-review-review-id stored))
      (prrr-github-find-pending-review
       host (plist-get target :owner) (plist-get target :name) (plist-get target :number)
       (plist-get target :me)
       (lambda (found)
         (cond (found
                (prrr-db-insert found)
                (funcall then (prrr-pending-review-review-id found)))
               ((not create) (funcall then nil))
               (t (prrr-sync--mutate
                   (lambda (callback errorback)
                     (prrr-github-create-pending-review host pr-id commit callback errorback))
                   (lambda (review)
                     (prrr-db-insert review)
                     (funcall then (prrr-pending-review-review-id review)))
                   fail))))
       fail))))

(defun prrr-sync--outbox-run (row done fail)
  "Send the write ROW to GitHub.
DONE receives GitHub's answer, a plist or nil; FAIL a classified failure."
  (let* ((payload (prrr-outbox-payload row))
         (target (plist-get payload :target))
         (host (plist-get target :host))
         (pr-id (plist-get target :pr-id))
         (commit (plist-get payload :commit))
         (body (plist-get payload :body)))
    (pcase (prrr-outbox-kind row)
      ('viewed
       (prrr-sync--mutate (lambda (callback errorback)
                            (prrr-github-set-viewed host pr-id (plist-get payload :path)
                                                    (plist-get payload :viewed)
                                                    callback errorback))
                          done fail))
      ((and kind (or 'thread 'reply))
       (prrr-sync--with-review
        target commit t
        (lambda (review-id)
          (prrr-sync--mutate
           (lambda (callback errorback)
             (if (eq kind 'thread)
                 (prrr-github-add-thread host review-id (plist-get payload :anchor) body
                                         callback errorback)
               (prrr-github-add-reply host review-id (plist-get payload :thread-id) body
                                      callback errorback)))
           (lambda (result) (funcall done (append (list :review-id review-id) result)))
           fail))
        fail))
      (kind (funcall fail (list :kind 'error :message (format "Unknown write %s" kind)
                                :reset-at nil))))))

(defun prrr-sync--outbox-outcome (row result)
  "Return how the database changes once GitHub accepted the write ROW.
RESULT is GitHub's answer.  A plist of `prrr-db-outbox-done''s keys."
  (let ((payload (prrr-outbox-payload row)))
    (pcase (prrr-outbox-kind row)
      ((or 'thread 'publish 'reply 'publish-reply)
       (pcase-let ((`(,rows . ,renames) (prrr-state-outbox-created row result)))
         (list :insert rows :renames renames)))
      ('viewed
       (list :insert (list (prrr-viewed-create :pr-id (prrr-outbox-pr-id row)
                                               :path (plist-get payload :path)
                                               :state (if (plist-get payload :viewed)
                                                          'viewed
                                                        'unviewed)
                                               :fetched-at (prrr-sync--timestamp))))))))

(defun prrr-sync--outbox-succeeded (row token result)
  "Record that GitHub accepted the write ROW, sent as TOKEN, with RESULT.
A late answer, after the send ended as a failure, is still recorded
when the write is queued and not being sent again: it did happen."
  (let ((id (prrr-outbox-id row))
        (pr-id (prrr-outbox-pr-id row)))
    (when (prrr-sync--outbox-current-p token)
      (setq prrr-sync--outbox-sending nil))
    (when (and (prrr-db-get 'outbox id) (not (equal id (prrr-sync--sending-id))))
      (apply #'prrr-db-outbox-done id (prrr-sync--outbox-outcome row result))
      (puthash pr-id (plist-get (prrr-outbox-payload row) :target) prrr-sync--outbox-dirty))
    (prrr-sync--outbox-changed pr-id)
    (prrr-sync--outbox-pump)))

(defun prrr-sync--outbox-failed (row token failure)
  "Record that the write ROW, sent as TOKEN, failed with FAILURE.
A rate limit pauses the Outbox until it ends and leaves ROW as it was;
any other failure stays on ROW, with the attempt counted, until a
retry."
  (when (prrr-sync--outbox-current-p token)
    (setq prrr-sync--outbox-sending nil)
    (if (eq (plist-get failure :kind) 'rate-limited)
        (setq prrr-sync--outbox-paused-until (plist-get failure :reset-at))
      (when-let ((stored (prrr-db-get 'outbox (prrr-outbox-id row))))
        (setf (prrr-outbox-attempts stored) (1+ (or (prrr-outbox-attempts stored) 0))
              (prrr-outbox-last-error stored) (plist-get failure :message))
        (prrr-db-insert stored)))
    (prrr-sync--outbox-changed (prrr-outbox-pr-id row))
    (prrr-sync--outbox-pump)))
```

This task's `prrr-sync--outbox-run` sends Viewed flags, Threads and replies; Task 8 adds the other kinds, and any other kind fails with "Unknown write" until then.

- [ ] **Step 5: The Review Buffer reads the view and writes Viewed through the Outbox**

In `prrr-diff.el`:

1. Rename `prrr-diff--require-pullreq` to `prrr-diff-pullreq` everywhere (`sed -i 's/prrr-diff--require-pullreq/prrr-diff-pullreq/g' prrr-diff.el`); no other file uses it. Commands in `prrr-review.el` call it.
2. After `prrr-diff--file-threads`, add:

```elisp
(defvar-local prrr-diff--data nil
  "The review data shown, from `prrr-sync-review-data'; set by each refresh.")

(defvar-local prrr-diff--comments nil
  "Hash table from comment id to the `prrr-comment' shown; set by each refresh.")
```

3. Replace `prrr-diff-refresh-buffer`, `prrr-diff--viewed-p` and `prrr-toggle-viewed` with:

```elisp
(defun prrr-diff-refresh-buffer ()
  "Insert the Review Buffer of `prrr-diff--pullreq' from git and the database.
The refresh function of `prrr-diff-mode', run by `magit-refresh-buffer'.
The review data is `prrr-sync-review-data''s: what GitHub sent, with
the Outbox's writes applied."
  (let* ((pullreq prrr-diff--pullreq)
         (ref (prrr-diff--head-ref pullreq))
         (head (magit-rev-verify ref))
         (base (and head (prrr-diff--merge-base pullreq head)))
         (data (prrr-sync-review-data (oref pullreq their-id))))
    (setq prrr-diff--base base
          prrr-diff--head head
          prrr-diff--data data
          prrr-diff--comments (make-hash-table :test #'equal)
          magit-buffer-diff-range (and base (concat base ".." head)))
    (dolist (comment (plist-get data :comments))
      (puthash (prrr-comment-comment-id comment) comment prrr-diff--comments))
    ;; magit resets this to nil when the root section finishes; a
    ;; failed refresh must not leave later insertions without markers.
    (setq magit-section-inhibit-markers 'delay)
    (unwind-protect
        (magit-insert-section (diffbuf)
          (prrr-diff--insert-header pullreq base head data)
          (cond ((not head)
                 (prrr-diff--insert-note
                  (format "%s is missing: run `forge-pull', then g" ref)))
                ((not base)
                 (prrr-diff--insert-note
                  (format "The base commit %s is not available locally: run `forge-pull', then g"
                          (or (oref pullreq base-rev) "(unknown)"))))
                (t (let* ((comments (prrr-diff--comments-table (plist-get data :comments)))
                          (elsewhere (prrr-diff--insert-files base head data comments)))
                     (prrr-diff--insert-group 'outdated-files "Threads on files not in this diff"
                                              elsewhere comments)))))
      (setq magit-section-inhibit-markers nil))
    (prrr-diff--content-markers)))

(defun prrr-diff--viewed-p (path)
  "Non-nil when the buffer shows PATH as Viewed."
  (member path (prrr-diff--viewed-paths (plist-get prrr-diff--data :viewed))))

(defun prrr-toggle-viewed ()
  "Mark the file at point Viewed on GitHub and fold it, or unmark it.
Marking moves to the next file, as GitHub does.  The change shows at
once and reaches GitHub through the Outbox."
  (interactive)
  (let* ((pullreq (prrr-diff-pullreq))
         (file (or (prrr-diff--file-at-point) (user-error "No file here")))
         (path (oref file value))
         (viewed (not (prrr-diff--viewed-p path))))
    ;; Folding first records the fold in the visibility cache, so the
    ;; refresh below agrees with the Viewed flag.
    (if viewed (magit-section-hide file) (magit-section-show file))
    (magit-section-goto file)
    (prrr-sync-write (forge-get-repository pullreq) pullreq 'viewed
                     (list :path path :viewed viewed) (current-buffer))
    (magit-refresh-buffer)
    (when-let ((next (and viewed (prrr-diff--file-near-point 1))))
      (magit-section-goto next))))
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `make test`
Expected: all pass. The M3 refetch tests are unchanged and still pass; no test refers to `prrr-sync-set-viewed`.

- [ ] **Step 7: Run all gates and commit**

```bash
make compile lint test
git add prrr-sync.el prrr-diff.el test/prrr-test-helper.el test/prrr-sync-test.el test/prrr-diff-test.el
git commit -m "feat(sync): the Outbox, the one write path; Viewed goes through it"
```

---

### Task 7: Reconciliation: refetch keeps and names queued writes

**Files:**
- Modify: `prrr-sync.el` (`prrr-sync-refetch` moves to the end of the part `;;;; The Outbox` and becomes a wrapper of `prrr-sync--refetch`; `prrr-sync--outbox-pump` replaced; `prrr-sync--outbox-refetch-idle`, `prrr-sync--outbox-races-p` added)
- Modify: `test/prrr-sync-test.el`

**Interfaces:**
- Consumes: Task 6's Outbox; Task 4's `prrr-state-thread-renames`, `prrr-state-outbox-busy-prs`; Task 1's RENAMES argument of `prrr-db-replace-review-data`.
- Produces:
  - `prrr-sync-refetch` keeps its signature `(REPO PULLREQ &optional BUFFER)` and its return value; a successful refetch now retries the PR's failed writes, and an answer a write may have raced is not stored.
  - `(prrr-sync--refetch TARGET BUFFER)`, used by the Outbox from a timer.
- Closes: bead `prrr-8ok`.

- [ ] **Step 1: Write the failing tests**

Append to `test/prrr-sync-test.el`, before `(provide 'prrr-sync-test)`:

```elisp
;;;; Reconciliation

(ert-deftest prrr-sync-test-refetch-keeps-queued-writes ()
  "SPEC 7, bead prrr-8ok: a refetch keeps unsent writes, then retries them."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch `((markFileAsViewed . (:error (error http 502)))
                                      (repository . ,(prrr-test-fixture "review-data")))
        (prrr-sync-test--write 'viewed '(:path "docs/notes.md" :viewed t))
        (should (prrr-sync-refetch (prrr-sync-test--repo) (prrr-sync-test--pullreq)))
        (let ((view (prrr-sync-review-data prrr-sync-test--pr)))
          (should (= 5 (length (plist-get view :threads))))
          (should (eq 'viewed (prrr-viewed-state
                               (seq-find (lambda (flag)
                                           (equal "docs/notes.md" (prrr-viewed-path flag)))
                                         (plist-get view :viewed))))))
        (should (equal '(markFileAsViewed repository markFileAsViewed) prrr-test-requests))))))

(ert-deftest prrr-sync-test-refetch-raced-by-a-write-is-not-stored ()
  "Review Focus 2: an answer that may miss a write is dropped and fetched again."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (let ((callback nil))
        (cl-letf (((symbol-function 'ghub-query)
                   (lambda (_query _variables &rest args)
                     (setq callback (plist-get args :callback)))))
          (prrr-sync-refetch (prrr-sync-test--repo) (prrr-sync-test--pullreq)))
        ;; A write of the PR succeeds while the refetch is out.
        (puthash prrr-sync-test--pr (prrr-sync--target (prrr-sync-test--repo)
                                                       (prrr-sync-test--pullreq))
                 prrr-sync--outbox-dirty)
        (funcall callback (prrr-test-fixture "review-data"))
        (should-not (prrr-db-select 'thread))
        (should (eq 'ok (plist-get (prrr-sync-review-status prrr-sync-test--pr) :state)))
        (prrr-test-with-ghub-dispatch `((repository . ,(prrr-test-fixture "review-data")))
          (prrr-test-run-timers 'prrr-sync--refetch)
          (should (equal '(repository) prrr-test-requests)))
        (should (= 5 (length (prrr-db-select 'thread))))
        (should-not (gethash prrr-sync-test--pr prrr-sync--outbox-dirty))))))

(ert-deftest prrr-sync-test-refetch-while-a-write-is-out-is-not-stored ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch `((repository . ,(prrr-test-fixture "review-data")))
        (setq prrr-sync--outbox-sending
              (prrr-sync-test--queue 'viewed '(:path "a.el" :viewed t)))
        (prrr-sync-refetch (prrr-sync-test--repo) (prrr-sync-test--pullreq))
        (should-not (prrr-db-select 'thread))
        (should (gethash prrr-sync-test--pr prrr-sync--outbox-dirty))))))

(ert-deftest prrr-sync-test-outbox-refetches-once-done ()
  "After its last write of a PR succeeds, the Outbox refetches the PR, from a timer."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch `((markFileAsViewed . ,prrr-sync-test--mark-viewed)
                                      (repository . ,(prrr-test-fixture "review-data")))
        (prrr-sync-test--write 'viewed '(:path "a.el" :viewed t))
        (should (equal '(markFileAsViewed) prrr-test-requests))
        (prrr-test-run-timers 'prrr-sync--refetch)
        (should (equal '(markFileAsViewed repository) prrr-test-requests))))))

(ert-deftest prrr-sync-test-refetch-names-a-published-thread ()
  "A reply to a Thread published at once goes out once a refetch names the Thread."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      ;; What a successful Immediate Publish leaves: GitHub's comment id in a local Thread.
      (prrr-db-insert (prrr-comment-create :comment-id "PRRC_kwDOexample0000006"
                                           :thread-id "local:T" :pr-id prrr-sync-test--pr
                                           :state 'submitted :local-state 'sent))
      (prrr-sync-test--queue 'reply '(:thread-id "local:T" :comment "local:R" :body "More."))
      (prrr-test-with-ghub-dispatch
          `((repository . ,(prrr-test-fixture "review-data"))
            (addPullRequestReviewThreadReply . ,(prrr-test-fixture "add-reply")))
        (prrr-sync-refetch (prrr-sync-test--repo) (prrr-sync-test--pullreq))
        (should (equal '(repository addPullRequestReviewThreadReply) prrr-test-requests))
        (should (equal "PRRT_kwDOexample0000005"
                       (alist-get 'pullRequestReviewThreadId
                                  (prrr-sync-test--input 'addPullRequestReviewThreadReply))))))))
```

- [ ] **Step 2: Run them to verify they fail**

Run: `make test TESTS=test/prrr-sync-test.el SELECTOR='"refetch"'`
Expected: FAIL; the raced answer is stored, no refetch timer is set, and the queued reply keeps its local Thread id.

- [ ] **Step 3: Implement**

In `prrr-sync.el`, delete `prrr-sync-refetch` from the part `;;;; Per-PR refetch`. Replace `prrr-sync--outbox-pump` with the version below, and append the rest at the end of the part `;;;; The Outbox`, before `;;;; Commands` (they read the Outbox's variables, which must be defined first):

```elisp
(defun prrr-sync--outbox-pump ()
  "Send the next write the Outbox may send, or arrange to try later.
Does nothing while a write is being sent or a timer will try later."
  (unless (or prrr-sync--outbox-sending prrr-sync--outbox-scheduled)
    (if (prrr-sync--outbox-paused-p)
        (prrr-sync--outbox-schedule
         (float-time (time-subtract (parse-iso8601-time-string prrr-sync--outbox-paused-until)
                                    nil)))
      (setq prrr-sync--outbox-paused-until nil)
      (let* ((rows (prrr-db-outbox-rows))
             (next (prrr-state-outbox-next rows prrr-sync--outbox-creations (float-time))))
        (prrr-sync--outbox-refetch-idle rows)
        (pcase next
          (`(,row . ,wait)
           (if (> wait 0)
               (prrr-sync--outbox-schedule wait)
             (prrr-sync--outbox-send row))))))))
```

```elisp
(defun prrr-sync--outbox-refetch-idle (rows)
  "Refetch each PR GitHub changed that has no write left to send now.
ROWS are every queued write.  The refetch starts from a timer, never
inside a write's answer."
  (let ((busy (prrr-state-outbox-busy-prs rows))
        (sending (and prrr-sync--outbox-sending (prrr-outbox-pr-id prrr-sync--outbox-sending))))
    (maphash (lambda (pr-id target)
               (unless (or (member pr-id busy) (equal pr-id sending))
                 (run-at-time 0 nil #'prrr-sync--refetch target
                              (gethash pr-id prrr-sync--outbox-buffers))))
             prrr-sync--outbox-dirty)))

(defun prrr-sync-refetch (repo pullreq &optional buffer)
  "Refetch the review data of PULLREQ in the background.
The review data is its Threads, Pending Review and Viewed flags.
REPO is PULLREQ's `forge-github-repository'.  Stores the answer with
`prrr-db-replace-review-data', records the outcome in
`prrr-sync-review-status' and refreshes BUFFER, when live, once the
refetch ends either way.  A successful refetch retries the PR's failed
writes.  Return non-nil when a refetch started; return nil and do
nothing when `prrr-sync-refetch-due-p' says no.  Never signals: every
failure becomes the status."
  (prrr-sync--refetch (prrr-sync--target repo pullreq) buffer))

(defun prrr-sync--outbox-races-p (pr-id)
  "Non-nil when a write may have changed PR-ID on GitHub during a refetch.
That is when a write of PR-ID succeeded since the refetch started, or
one is being sent: the refetch's answer may then miss it."
  (or (gethash pr-id prrr-sync--outbox-dirty)
      (and prrr-sync--outbox-sending
           (equal pr-id (prrr-outbox-pr-id prrr-sync--outbox-sending)))))

(defun prrr-sync--refetch (target buffer)
  "Refetch TARGET's PR and refresh BUFFER, as `prrr-sync-refetch' does.
TARGET is a plist from `prrr-sync--target'.  An answer that a write of
the PR may have raced is not stored: the PR stays changed, and the
Outbox refetches it once it has nothing more to send."
  (let ((pr-id (plist-get target :pr-id)))
    (when (prrr-sync-refetch-due-p pr-id)
      (let* ((key (cons 'review pr-id))
             (token (prrr-sync--start key buffer))
             (fail (lambda (failure) (prrr-sync--finish key token failure buffer))))
        (remhash pr-id prrr-sync--outbox-dirty)
        (prrr-sync--guarded fail
          (let ((me (plist-get target :me)))
            (if (null me)
                (funcall fail (list :kind 'error :message prrr-sync-no-login :reset-at nil))
              (prrr-github-fetch-review-data
               (plist-get target :host) (plist-get target :owner) (plist-get target :name)
               (plist-get target :number) me
               (lambda (data)
                 (when (prrr-sync--current-p key token)
                   (prrr-sync--guarded fail
                     (let ((raced (prrr-sync--outbox-races-p pr-id)))
                       (if raced
                           (puthash pr-id target prrr-sync--outbox-dirty)
                         (prrr-db-replace-review-data
                          pr-id data
                          (prrr-state-thread-renames
                           (prrr-db-select 'review-comment :pr-id pr-id)
                           (plist-get data :comments))))
                       (prrr-sync--finish key token
                                          (list :kind 'ok :head-oid (plist-get data :head-oid))
                                          buffer)
                       (if raced
                           (prrr-sync--outbox-pump)
                         (prrr-sync-retry pr-id buffer))))))
               fail))))
        t))))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: all pass, the milestone-3 refetch tests and `prrr-diff-test-open-shows-refreshing` included.

- [ ] **Step 5: Run all gates, commit, close prrr-8ok**

```bash
make compile lint test
git add prrr-sync.el test/prrr-sync-test.el
git commit -m "feat(sync): refetch keeps and names queued writes, and never stores a raced answer"
bd close prrr-8ok --reason "Resolved by design in M4 Task 7: unsent writes live only in the outbox table; prrr-db-replace-review-data replaces GitHub's rows and renames ids in queued payloads"
```

---

### Task 8: Every kind of write

**Files:**
- Modify: `prrr-sync.el` (`prrr-sync-write`, `prrr-sync--outbox-run`, `prrr-sync--outbox-outcome`, `prrr-sync--outbox-succeeded` replaced; `prrr-sync--outbox-creator`, `prrr-sync--outbox-drop-pending`, `prrr-sync--top-database-id`, `prrr-sync--pull-topic` added)
- Modify: `test/prrr-sync-test.el`

**Interfaces:**
- Consumes: Tasks 3 and 6.
- Produces:
  - `prrr-sync-write` sends every kind of `prrr-state-outbox-kinds`. An `edit` of a comment created by a queued write not being sent changes that write's `:body` and returns it; a `delete` of such a comment drops that write and its dependents and returns nil; a `discard` first drops the queued Threads, replies and writes on pending comments.
  - Submit's success deletes the Pending Review row, marks pending comments `submitted`, and records the viewer's latest review in `pullreq-meta` (`("APPROVED"|"CHANGES_REQUESTED"|"COMMENTED" NOW COMMIT)`), which makes the PR Served.
  - A Discussion Comment's success makes forge pull the PR in its Review Buffer.

- [ ] **Step 1: Write the failing tests**

Append to `test/prrr-sync-test.el`, before `(provide 'prrr-sync-test)`:

```elisp
;;;; Every kind of write

(ert-deftest prrr-sync-test-outbox-publish ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-rest-stub (prrr-test-fixture "publish-comment") captured
        (let ((row (prrr-sync-test--write 'publish (list :anchor prrr-sync-test--anchor
                                                         :body "Now." :commit "1111"))))
          (should (equal "/repos/example-org/example-repo/pulls/1/comments" (cadr captured)))
          (let ((comment (prrr-db-get 'review-comment "PRRC_kwDOexampleNew03")))
            (should (equal (plist-get (prrr-outbox-payload row) :thread)
                           (prrr-comment-thread-id comment)))
            (should (eq 'submitted (prrr-comment-state comment)))
            (should (equal "3001" (prrr-comment-database-id comment)))))))))

(ert-deftest prrr-sync-test-outbox-publish-reply ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-db-replace-review-data
       prrr-sync-test--pr
       (prrr-github-decode-review-data (prrr-test-fixture "review-data") prrr-sync-test--pr))
      (prrr-test-with-rest-stub (prrr-test-fixture "publish-reply") captured
        (prrr-sync-test--write 'publish-reply '(:thread-id "PRRT_kwDOexample0000001"
                                                :body "Done."))
        (should (equal "/repos/example-org/example-repo/pulls/1/comments/1001/replies"
                       (cadr captured)))
        (should (prrr-db-get 'review-comment "PRRC_kwDOexampleNew04"))))))

(ert-deftest prrr-sync-test-outbox-discussion-pulls-the-topic ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (let ((pulled nil))
        (with-temp-buffer
          (setq-local forge-buffer-topic 'example-topic)
          (cl-letf (((symbol-function 'forge-pull-topic)
                     (lambda (topic) (interactive) (setq pulled topic))))
            (prrr-test-with-ghub-dispatch '((addComment . ((data (addComment (clientMutationId))))))
              (prrr-sync-write (prrr-sync-test--repo) (prrr-sync-test--pullreq) 'discussion
                               '(:body "Thanks!") (current-buffer))
              (should (equal prrr-sync-test--pr
                             (alist-get 'subjectId (prrr-sync-test--input 'addComment)))))))
        (should (eq 'example-topic pulled))
        (should-not (prrr-db-outbox-rows))))))

(ert-deftest prrr-sync-test-outbox-edit-amends-an-unsent-comment ()
  "Review Focus 3: editing what GitHub has not got changes the queued write."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (prrr-test-with-ghub-dispatch '((addPullRequestReviewThread . (:error (error http 502))))
        (let* ((thread (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor
                                                            :body "Nit." :commit "1111")))
               (comment (plist-get (prrr-outbox-payload thread) :comment)))
          (should (equal (prrr-outbox-id thread)
                         (prrr-outbox-id (prrr-sync-test--write 'edit (list :comment-id comment
                                                                         :body "Better.")))))
          (should (equal '(thread) (mapcar #'prrr-outbox-kind (prrr-db-outbox-rows))))
          (should (equal "Better." (plist-get (prrr-outbox-payload (car (prrr-db-outbox-rows)))
                                              :body)))
          ;; The edit retried the write.
          (should (equal '(addPullRequestReviewThread addPullRequestReviewThread)
                         prrr-test-requests)))))))

(ert-deftest prrr-sync-test-outbox-edit-of-a-comment-being-sent-queues ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (cl-letf (((symbol-function 'ghub-query) #'ignore))
        (let* ((thread (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor
                                                            :body "Nit." :commit "1111")))
               (comment (plist-get (prrr-outbox-payload thread) :comment)))
          (prrr-sync-test--write 'edit (list :comment-id comment :body "Better."))
          (should (equal '(thread edit) (mapcar #'prrr-outbox-kind (prrr-db-outbox-rows))))
          (should (equal "Better." (prrr-comment-body
                                    (car (last (plist-get (prrr-sync-review-data
                                                           prrr-sync-test--pr)
                                                          :comments)))))))))))

(ert-deftest prrr-sync-test-outbox-delete-drops-an-unsent-comment ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (prrr-test-with-ghub-dispatch '((addPullRequestReviewThread . (:error (error http 502))))
        (let* ((thread (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor
                                                            :body "Nit." :commit "1111")))
               (comment (plist-get (prrr-outbox-payload thread) :comment)))
          (should-not (prrr-sync-test--write 'delete (list :comment-id comment)))
          (should-not (prrr-db-outbox-rows))
          (should-not (plist-get (prrr-sync-review-data prrr-sync-test--pr) :threads)))))))

(ert-deftest prrr-sync-test-outbox-edit-delete-resolve-sent ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-db-replace-review-data
       prrr-sync-test--pr
       (prrr-github-decode-review-data (prrr-test-fixture "review-data") prrr-sync-test--pr))
      (prrr-test-with-ghub-dispatch
          '((updatePullRequestReviewComment . ((data (updatePullRequestReviewComment
                                                      (clientMutationId)))))
            (deletePullRequestReviewComment . ((data (deletePullRequestReviewComment
                                                      (clientMutationId)))))
            (resolveReviewThread . ((data (resolveReviewThread (clientMutationId))))))
        (prrr-sync-test--write 'edit '(:comment-id "PRRC_kwDOexample0000002" :body "Fixed."))
        (prrr-sync-test--write 'resolve '(:thread-id "PRRT_kwDOexample0000001" :resolved t))
        (prrr-sync-test--write 'delete '(:comment-id "PRRC_kwDOexample0000006"))
        (should (equal '(updatePullRequestReviewComment resolveReviewThread
                         deletePullRequestReviewComment)
                       prrr-test-requests)))
      (should (equal "Fixed." (prrr-comment-body
                               (prrr-db-get 'review-comment "PRRC_kwDOexample0000002"))))
      (should (prrr-thread-resolved-p (prrr-db-get 'thread "PRRT_kwDOexample0000001")))
      ;; The deleted comment was its Thread's only one.
      (should-not (prrr-db-get 'review-comment "PRRC_kwDOexample0000006"))
      (should-not (prrr-db-get 'thread "PRRT_kwDOexample0000005")))))

(ert-deftest prrr-sync-test-outbox-submit-touches-the-pr ()
  "SPEC section 7: Submit sends the review and moves the PR to Served."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (prrr-db-insert (prrr-comment-create :comment-id "C1" :thread-id "T1"
                                           :pr-id prrr-sync-test--pr
                                           :state 'pending :local-state 'sent))
      (prrr-db-insert (prrr-pr-meta-create :pr-id prrr-sync-test--pr
                                           :forge-repo-id "example-repo-id" :number 1))
      (prrr-test-with-ghub-dispatch '((submitPullRequestReview
                                       . ((data (submitPullRequestReview (clientMutationId))))))
        (prrr-sync-test--write 'submit '(:verdict approve :body "LGTM" :commit "1111"))
        (should (equal "APPROVE" (alist-get 'event (prrr-sync-test--input
                                                    'submitPullRequestReview)))))
      (should-not (prrr-db-get 'pending-review prrr-sync-test--pr))
      (should (eq 'submitted (prrr-comment-state (prrr-db-get 'review-comment "C1"))))
      (should (equal '("APPROVED" "1111")
                     (let ((review (prrr-pr-meta-viewer-latest-review
                                    (prrr-db-get 'pullreq-meta prrr-sync-test--pr))))
                       (list (nth 0 review) (nth 2 review))))))))

(ert-deftest prrr-sync-test-outbox-submit-without-a-pending-review ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch
          `((repository . ,(prrr-test-fixture "pending-review-none"))
            (addPullRequestReview . ((data (addPullRequestReview (clientMutationId))))))
        (prrr-sync-test--write 'submit '(:verdict approve :body "" :commit "1111"))
        (should (equal '(repository addPullRequestReview) prrr-test-requests))
        (should (equal "APPROVE" (alist-get 'event (prrr-sync-test--input
                                                    'addPullRequestReview))))
        (should-not (prrr-db-outbox-rows))))))

(ert-deftest prrr-sync-test-outbox-discard-drops-queued-pending-writes ()
  "Review Focus 3: discarding takes the queued pending comments with it."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (prrr-db-insert (prrr-comment-create :comment-id "C1" :thread-id "T1"
                                           :pr-id prrr-sync-test--pr
                                           :state 'pending :local-state 'sent))
      (prrr-test-with-ghub-dispatch
          '((addPullRequestReviewThread . (:error (error http 502)))
            (deletePullRequestReview . ((data (deletePullRequestReview (clientMutationId))))))
        (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor :body "Nit."
                                             :commit "1111"))
        (prrr-sync-test--write 'discard nil)
        (should (equal '(addPullRequestReviewThread deletePullRequestReview) prrr-test-requests)))
      (should-not (prrr-db-outbox-rows))
      (should-not (prrr-db-get 'pending-review prrr-sync-test--pr))
      (should-not (prrr-db-get 'review-comment "C1")))))
```

- [ ] **Step 2: Run them to verify they fail**

Run: `make test TESTS=test/prrr-sync-test.el SELECTOR='"prrr-sync-test-outbox"'`
Expected: FAIL; "Unknown write publish" and friends.

- [ ] **Step 3: Implement**

In `prrr-sync.el`, replace `prrr-sync-write`, `prrr-sync--outbox-run`, `prrr-sync--outbox-outcome` and `prrr-sync--outbox-succeeded` with the versions below, and add the four new functions after `prrr-sync-write`:

```elisp
(defun prrr-sync-write (repo pullreq kind payload &optional buffer)
  "Make the write KIND with PAYLOAD reach PULLREQ of REPO on GitHub.
KIND and PAYLOAD are as `prrr-state-outbox-kinds' describes, without
:target and the local ids, which this adds.  The write is stored in
the Outbox, so `prrr-sync-review-data' shows it at once, and is sent in
the background after the PR's earlier writes, one mutation at a time
\(SPEC section 4).  Every failed write of the PR is tried again too.
An edit or delete of a comment whose own write is queued and not being
sent changes or drops that write instead, and a discard drops the
queued writes of the Pending Review first.  BUFFER, when live,
refreshes whenever the PR's writes change.  Return the `prrr-outbox'
row that carries the write, or nil when it dropped queued writes
instead.  Signal a `user-error' when the viewer's login is unknown."
  (let* ((target (prrr-sync--target repo pullreq))
         (pr-id (plist-get target :pr-id))
         (creator (and (memq kind '(edit delete))
                       (prrr-sync--outbox-creator pr-id (plist-get payload :comment-id)))))
    (unless (plist-get target :me)
      (user-error "No GitHub login: set github.user or `prrr-github-user'"))
    (prrr-sync--remember-buffer pr-id buffer)
    (prog1 (cond ((and creator (eq kind 'edit))
                  (setf (prrr-outbox-payload creator)
                        (plist-put (copy-sequence (prrr-outbox-payload creator))
                                   :body (plist-get payload :body)))
                  (prrr-db-insert creator))
                 (creator
                  (prrr-sync-discard (prrr-outbox-id creator))
                  nil)
                 (t
                  (when (eq kind 'discard)
                    (prrr-sync--outbox-drop-pending pr-id))
                  (prrr-sync--outbox-add pr-id kind
                                         (prrr-sync--outbox-payload kind payload target))))
      (prrr-sync-retry pr-id))))

(defun prrr-sync--outbox-creator (pr-id comment-id)
  "Return the queued write of PR-ID creating COMMENT-ID, unless it is being sent."
  (seq-find (lambda (row)
              (and (member comment-id (prrr-state-outbox-created-ids row))
                   (not (equal (prrr-outbox-id row) (prrr-sync--sending-id)))))
            (prrr-db-outbox-rows pr-id)))

(defun prrr-sync--outbox-drop-pending (pr-id)
  "Drop PR-ID's queued writes that a discard of its Pending Review makes moot.
Those are new Threads and replies of the Pending Review, and every
queued write that needs one of them or a stored pending comment,
unless it is being sent."
  (let* ((rows (prrr-db-outbox-rows pr-id))
         (pending (seq-filter (lambda (row) (memq (prrr-outbox-kind row) '(thread reply)))
                              rows))
         (ids (append (mapcar #'prrr-comment-comment-id
                              (prrr-db-select 'review-comment :pr-id pr-id :state 'pending))
                      (mapcan #'prrr-state-outbox-created-ids pending))))
    (dolist (row (append pending (prrr-state-outbox-dependents rows ids)))
      (unless (equal (prrr-outbox-id row) (prrr-sync--sending-id))
        (prrr-db-delete 'outbox :id (prrr-outbox-id row))))))

(defun prrr-sync--top-database-id (thread-id)
  "Return GitHub's database id of the first comment of THREAD-ID, or nil."
  (let ((comments (sort (prrr-db-select 'review-comment :thread-id thread-id)
                        (lambda (a b) (string< (or (prrr-comment-created-at a) "")
                                               (or (prrr-comment-created-at b) ""))))))
    (prrr-comment-database-id (car comments))))

(defun prrr-sync--outbox-run (row done fail)
  "Send the write ROW to GitHub.
DONE receives GitHub's answer, a plist or nil; FAIL a classified failure."
  (let* ((payload (prrr-outbox-payload row))
         (target (plist-get payload :target))
         (host (plist-get target :host))
         (pr-id (plist-get target :pr-id))
         (commit (plist-get payload :commit))
         (body (plist-get payload :body)))
    (pcase (prrr-outbox-kind row)
      ('viewed
       (prrr-sync--mutate (lambda (callback errorback)
                            (prrr-github-set-viewed host pr-id (plist-get payload :path)
                                                    (plist-get payload :viewed)
                                                    callback errorback))
                          done fail))
      ((and kind (or 'thread 'reply))
       (prrr-sync--with-review
        target commit t
        (lambda (review-id)
          (prrr-sync--mutate
           (lambda (callback errorback)
             (if (eq kind 'thread)
                 (prrr-github-add-thread host review-id (plist-get payload :anchor) body
                                         callback errorback)
               (prrr-github-add-reply host review-id (plist-get payload :thread-id) body
                                      callback errorback)))
           (lambda (result) (funcall done (append (list :review-id review-id) result)))
           fail))
        fail))
      ('publish
       (prrr-sync--mutate (lambda (callback errorback)
                            (prrr-github-publish-comment
                             host (plist-get target :owner) (plist-get target :name)
                             (plist-get target :number) commit (plist-get payload :anchor) body
                             callback errorback))
                          done fail))
      ('publish-reply
       (if-let ((top (prrr-sync--top-database-id (plist-get payload :thread-id))))
           (prrr-sync--mutate (lambda (callback errorback)
                                (prrr-github-publish-reply
                                 host (plist-get target :owner) (plist-get target :name)
                                 (plist-get target :number) top body callback errorback))
                              done fail)
         (funcall fail '(:kind error :message "GitHub's id of this Thread is not known yet: press G"
                         :reset-at nil))))
      ('discussion
       (prrr-sync--mutate (lambda (callback errorback)
                            (prrr-github-add-discussion-comment host pr-id body callback errorback))
                          done fail))
      ('edit
       (prrr-sync--mutate (lambda (callback errorback)
                            (prrr-github-edit-comment host (plist-get payload :comment-id) body
                                                      callback errorback))
                          done fail))
      ('delete
       (prrr-sync--mutate (lambda (callback errorback)
                            (prrr-github-delete-comment host (plist-get payload :comment-id)
                                                        callback errorback))
                          done fail))
      ('resolve
       (prrr-sync--mutate (lambda (callback errorback)
                            (prrr-github-set-resolved host (plist-get payload :thread-id)
                                                      (plist-get payload :resolved)
                                                      callback errorback))
                          done fail))
      ('submit
       (prrr-sync--with-review
        target commit nil
        (lambda (review-id)
          (prrr-sync--mutate (lambda (callback errorback)
                               (prrr-github-submit-review host review-id pr-id commit
                                                          (plist-get payload :verdict) body
                                                          callback errorback))
                             done fail))
        fail))
      ('discard
       (prrr-sync--with-review
        target nil nil
        (lambda (review-id)
          (if review-id
              (prrr-sync--mutate (lambda (callback errorback)
                                   (prrr-github-discard-review host review-id callback errorback))
                                 done fail)
            (funcall done)))
        fail))
      (kind (funcall fail (list :kind 'error :message (format "Unknown write %s" kind)
                                :reset-at nil))))))

(defun prrr-sync--outbox-outcome (row result)
  "Return how the database changes once GitHub accepted the write ROW.
RESULT is GitHub's answer.  A plist of `prrr-db-outbox-done''s keys."
  (let* ((payload (prrr-outbox-payload row))
         (pr-id (prrr-outbox-pr-id row))
         (comment-id (plist-get payload :comment-id))
         (thread-id (plist-get payload :thread-id)))
    (pcase (prrr-outbox-kind row)
      ((or 'thread 'publish 'reply 'publish-reply)
       (pcase-let ((`(,rows . ,renames) (prrr-state-outbox-created row result)))
         (list :insert rows :renames renames)))
      ('viewed
       (list :insert (list (prrr-viewed-create :pr-id pr-id :path (plist-get payload :path)
                                               :state (if (plist-get payload :viewed)
                                                          'viewed
                                                        'unviewed)
                                               :fetched-at (prrr-sync--timestamp)))))
      ('edit
       (when-let ((comment (prrr-db-get 'review-comment comment-id)))
         (setf (prrr-comment-body comment) (plist-get payload :body)
               (prrr-comment-updated-at comment) (prrr-sync--timestamp))
         (list :insert (list comment))))
      ('delete
       (let* ((comment (prrr-db-get 'review-comment comment-id))
              (thread (and comment (prrr-comment-thread-id comment))))
         (list :delete (append (list (list 'review-comment :comment-id comment-id))
                               (and thread
                                    (= 1 (length (prrr-db-select 'review-comment
                                                                 :thread-id thread)))
                                    (list (list 'thread :thread-id thread)))))))
      ('resolve
       (when-let ((thread (prrr-db-get 'thread thread-id)))
         (setf (prrr-thread-resolved-p thread) (and (plist-get payload :resolved) t))
         (list :insert (list thread))))
      ('submit
       (list :delete (list (list 'pending-review :pr-id pr-id))
             :insert (append
                      (mapcar (lambda (comment)
                                (setf (prrr-comment-state comment) 'submitted)
                                comment)
                              (prrr-db-select 'review-comment :pr-id pr-id :state 'pending))
                      (when-let ((meta (prrr-db-get 'pullreq-meta pr-id)))
                        (setf (prrr-pr-meta-viewer-latest-review meta)
                              (list (pcase (plist-get payload :verdict)
                                      ('approve "APPROVED")
                                      ('request-changes "CHANGES_REQUESTED")
                                      (_ "COMMENTED"))
                                    (prrr-sync--timestamp)
                                    (plist-get payload :commit)))
                        (list meta)))))
      ('discard
       (let ((pending (prrr-db-select 'review-comment :pr-id pr-id :state 'pending)))
         (list :delete (cons (list 'pending-review :pr-id pr-id)
                             (mapcan (lambda (comment)
                                       (list (list 'review-comment
                                                   :comment-id (prrr-comment-comment-id comment))))
                                     pending))))))))

(defun prrr-sync--outbox-succeeded (row token result)
  "Record that GitHub accepted the write ROW, sent as TOKEN, with RESULT.
A late answer, after the send ended as a failure, is still recorded
when the write is queued and not being sent again: it did happen."
  (let ((id (prrr-outbox-id row))
        (pr-id (prrr-outbox-pr-id row)))
    (when (prrr-sync--outbox-current-p token)
      (setq prrr-sync--outbox-sending nil))
    (when (and (prrr-db-get 'outbox id) (not (equal id (prrr-sync--sending-id))))
      (apply #'prrr-db-outbox-done id (prrr-sync--outbox-outcome row result))
      (puthash pr-id (plist-get (prrr-outbox-payload row) :target) prrr-sync--outbox-dirty)
      (when (eq (prrr-outbox-kind row) 'discussion)
        (prrr-sync--pull-topic pr-id)))
    (prrr-sync--outbox-changed pr-id)
    (prrr-sync--outbox-pump)))

(defun prrr-sync--pull-topic (pr-id)
  "Ask forge to pull the PR of PR-ID, so a new Discussion Comment shows.
Only when the PR's Review Buffer is live, since forge needs it."
  (when-let ((buffer (gethash pr-id prrr-sync--outbox-buffers)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when-let ((topic (bound-and-true-p forge-buffer-topic)))
          (condition-case err
              (funcall-interactively #'forge-pull-topic topic)
            (error (message "prrr: forge could not pull the PR: %s"
                            (error-message-string err)))))))))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: all pass.

- [ ] **Step 5: Run all gates and commit**

```bash
make compile lint test
git add prrr-sync.el test/prrr-sync-test.el
git commit -m "feat(sync): publish, reply, discuss, edit, delete, resolve, submit and discard through the Outbox"
```

---

### Task 9: Anchors: what a comment is on

**Files:**
- Modify: `prrr-state.el` (new part `;;;; Anchors` before `(provide 'prrr-state)`)
- Modify: `prrr-diff.el` (new functions before `;;;; Commands`)
- Modify: `test/prrr-state-test.el`, `test/prrr-diff-test.el`

**Interfaces:**
- Consumes: `prrr-diff--threads`, `prrr-diff--comments`, `prrr-diff--head` (buffer state).
- Produces:
  - `(prrr-state-anchor PATH FIRST LAST)` → anchor plist `(:path P :line L :side S [:start-line SL :start-side SS] :subject-type line)`; FIRST and LAST are `(HUNK KIND OLD NEW)`. Signals `user-error` off a diff line or across hunks.
  - `(prrr-state-file-anchor PATH)` → `(:path P :subject-type file)`.
  - `(prrr-state-anchor-label ANCHOR)` → "src/a.el:3-5 right", "src/a.el:12 left-12 right" or "src/a.el".
  - `(prrr-state-suggestion-body LINES)` → "```suggestion\n…\n```\n"; LINES are `(KIND . TEXT)`; signals `user-error` when a line was removed.
  - `(prrr-diff-head)`, `(prrr-diff-anchor)`, `(prrr-diff-file-anchor)`, `(prrr-diff-region-lines)` → list of `(KIND . TEXT)`, `(prrr-diff-thread-at-point)` → `prrr-thread` or nil, `(prrr-diff-comment-at-point)` → `prrr-comment` or nil.
  - Private `prrr-diff--hunk-of`, `prrr-diff--line-at` → `(HUNK KIND OLD NEW TEXT)` or nil, `prrr-diff--region-ends`, `prrr-diff--section-of`.
  - Test helpers `prrr-diff-test--goto-line`, `prrr-diff-test--with-region`.

- [ ] **Step 1: Write the failing tests**

Append to `test/prrr-state-test.el`, before `(provide 'prrr-state-test)`:

```elisp
;;;; Anchors

(ert-deftest prrr-state-test-anchor-one-line ()
  (should (equal '(:path "a" :line 12 :side right :subject-type line)
                 (prrr-state-anchor "a" '(h ?+ nil 12) '(h ?+ nil 12))))
  (should (equal '(:path "a" :line 13 :side right :subject-type line)
                 (prrr-state-anchor "a" '(h ?\s 13 13) '(h ?\s 13 13))))
  (should (equal '(:path "a" :line 12 :side left :subject-type line)
                 (prrr-state-anchor "a" '(h ?- 12 nil) '(h ?- 12 nil)))))

(ert-deftest prrr-state-test-anchor-range ()
  (should (equal '(:path "a" :line 12 :side right :start-line 9 :start-side right
                   :subject-type line)
                 (prrr-state-anchor "a" '(h ?\s 9 9) '(h ?+ nil 12))))
  (should (equal '(:path "a" :line 12 :side right :start-line 12 :start-side left
                   :subject-type line)
                 (prrr-state-anchor "a" '(h ?- 12 nil) '(h ?+ nil 12)))))

(ert-deftest prrr-state-test-anchor-refused ()
  (should-error (prrr-state-anchor "a" '(h ?+ nil 12) '(g ?+ nil 30)) :type 'user-error)
  (should-error (prrr-state-anchor "a" '(h ?\\ nil nil) '(h ?\\ nil nil)) :type 'user-error))

(ert-deftest prrr-state-test-anchor-label ()
  (should (equal "a:12 right" (prrr-state-anchor-label '(:path "a" :line 12 :side right))))
  (should (equal "a:9-12 right"
                 (prrr-state-anchor-label '(:path "a" :line 12 :side right
                                            :start-line 9 :start-side right))))
  (should (equal "a:12 left-12 right"
                 (prrr-state-anchor-label '(:path "a" :line 12 :side right
                                            :start-line 12 :start-side left))))
  (should (equal "a" (prrr-state-anchor-label (prrr-state-file-anchor "a")))))

(ert-deftest prrr-state-test-suggestion-body ()
  (should (equal "```suggestion\nline twelve\nline 13\n```\n"
                 (prrr-state-suggestion-body '((?+ . "line twelve") (?\s . "line 13")))))
  (should-error (prrr-state-suggestion-body '((?- . "line 12"))) :type 'user-error))
```

Append to `test/prrr-diff-test.el`, before `(provide 'prrr-diff-test)`:

```elisp
;;;; Anchors

(defun prrr-diff-test--goto-line (path text)
  "Move to the diff line of PATH that reads TEXT, expanding PATH."
  (prrr-diff-test--hunks path)
  (goto-char (oref (prrr-diff-test--file-section path) start))
  (re-search-forward (concat "^" (regexp-quote text) "$"))
  (goto-char (line-beginning-position)))

(defmacro prrr-diff-test--with-region (from to &rest body)
  "Run BODY with the region over the lines FROM to TO of src/example.el.
FROM and TO are the texts of the lines."
  (declare (indent 2))
  `(let ((transient-mark-mode t))
     (prrr-diff-test--goto-line "src/example.el" ,from)
     (push-mark (point) t t)
     (prrr-diff-test--goto-line "src/example.el" ,to)
     (goto-char (line-end-position))
     ,@body))

(ert-deftest prrr-diff-test-anchor-added-line ()
  (prrr-diff-test--with-buffer nil
    (prrr-diff-test--goto-line "src/example.el" "+line twelve")
    (should (equal '(:path "src/example.el" :line 12 :side right :subject-type line)
                   (prrr-diff-anchor)))))

(ert-deftest prrr-diff-test-anchor-removed-line-is-left ()
  (prrr-diff-test--with-buffer nil
    (prrr-diff-test--goto-line "src/example.el" "-line 12")
    (should (equal '(:path "src/example.el" :line 12 :side left :subject-type line)
                   (prrr-diff-anchor)))))

(ert-deftest prrr-diff-test-anchor-context-line ()
  (prrr-diff-test--with-buffer nil
    (prrr-diff-test--goto-line "src/example.el" " line 13")
    (should (equal '(:path "src/example.el" :line 13 :side right :subject-type line)
                   (prrr-diff-anchor)))))

(ert-deftest prrr-diff-test-anchor-region-is-a-range ()
  (prrr-diff-test--with-buffer nil
    (prrr-diff-test--with-region " line 10" "+line twelve"
      (should (equal '(:path "src/example.el" :line 12 :side right
                       :start-line 10 :start-side right :subject-type line)
                     (prrr-diff-anchor))))))

(ert-deftest prrr-diff-test-anchor-region-ending-at-a-line-start ()
  "A region that ends where a line starts covers the lines before it."
  (prrr-diff-test--with-buffer nil
    (let ((transient-mark-mode t))
      (prrr-diff-test--goto-line "src/example.el" " line 10")
      (push-mark (point) t t)
      (prrr-diff-test--goto-line "src/example.el" "+line twelve")
      (should (equal '(:path "src/example.el" :line 12 :side left
                       :start-line 10 :start-side right :subject-type line)
                     (prrr-diff-anchor))))))

(ert-deftest prrr-diff-test-anchor-across-hunks-refused ()
  (prrr-diff-test--with-buffer nil
    (prrr-diff-test--with-region "+line twelve" "+line thirty"
      (should-error (prrr-diff-anchor) :type 'user-error))))

(ert-deftest prrr-diff-test-anchor-in-a-thread ()
  "Point in a Thread anchors to the diff line the Thread follows."
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (let ((hunk (car (prrr-diff-test--hunks "src/example.el"))))
      (goto-char (oref (car (oref hunk children)) start))
      (forward-line 1)
      (should (equal '(:path "src/example.el" :line 12 :side right :subject-type line)
                     (prrr-diff-anchor))))))

(ert-deftest prrr-diff-test-anchor-off-diff-lines ()
  (prrr-diff-test--with-buffer nil
    (let ((hunk (car (prrr-diff-test--hunks "src/example.el")))
          (file (prrr-diff-test--file-section "src/example.el")))
      (goto-char (oref hunk start))
      (should-error (prrr-diff-anchor) :type 'user-error)
      (goto-char (oref file start))
      (should-error (prrr-diff-anchor) :type 'user-error)
      (should (equal '(:path "src/example.el" :subject-type file) (prrr-diff-file-anchor))))))

(ert-deftest prrr-diff-test-region-lines-skip-threads ()
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (prrr-diff-test--with-region " line 11" " line 13"
      (should (equal '((?\s . "line 11") (?- . "line 12") (?+ . "line twelve") (?\s . "line 13"))
                     (prrr-diff-region-lines))))))

(ert-deftest prrr-diff-test-thread-and-comment-at-point ()
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (let* ((hunk (car (prrr-diff-test--hunks "src/example.el")))
           (thread (car (oref hunk children))))
      (goto-char (oref thread start))
      (should (equal "PRRT_kwDOexample0000001" (prrr-thread-thread-id (prrr-diff-thread-at-point))))
      (should-not (prrr-diff-comment-at-point))
      (goto-char (oref (cadr (oref thread children)) start))
      (should (equal "PRRC_kwDOexample0000002" (prrr-comment-comment-id (prrr-diff-comment-at-point))))
      (should (equal "PRRT_kwDOexample0000001" (prrr-thread-thread-id (prrr-diff-thread-at-point)))))))
```

`transient-mark-mode` is off in batch; `prrr-diff-test--with-region` binds it so `use-region-p` holds.

- [ ] **Step 2: Run them to verify they fail**

Run: `make test TESTS="test/prrr-state-test.el test/prrr-diff-test.el" SELECTOR='"anchor\\|region\\|at-point\\|suggestion-body"'`
Expected: FAIL, `prrr-state-anchor` is void.

- [ ] **Step 3: Implement the rule**

Insert before `(provide 'prrr-state)`:

```elisp
;;;; Anchors

(defun prrr-state-anchor (path first last)
  "Return the anchor of a comment on the diff lines FIRST to LAST of PATH.
FIRST and LAST describe one diff line each, as (HUNK KIND OLD NEW):
HUNK identifies its hunk (compared with `eq'), KIND is the line's
first character (?+, ?- or ?\\s), OLD and NEW its numbers in the old
and new file, nil on a side the line is not on.  LAST may equal FIRST.
The anchor is a plist (:path :line :side :start-line :start-side
:subject-type line): a removed line is on the `left' side at its old
number, any other line on the `right' side at its new number; LAST
gives :line and :side, and FIRST, when it is another line, :start-line
and :start-side (SPEC section 7).  Signal a `user-error' when either
line is not a diff line or the two are in different hunks."
  (pcase-let ((`(,hunk ,kind ,old ,new) first)
              (`(,last-hunk ,last-kind ,last-old ,last-new) last))
    (unless (and (memq kind '(?+ ?- ?\s)) (memq last-kind '(?+ ?- ?\s)))
      (user-error "Not on a diff line"))
    (unless (eq hunk last-hunk)
      (user-error "A comment can span the lines of one hunk only"))
    (let ((side (if (eq last-kind ?-) 'left 'right))
          (line (if (eq last-kind ?-) last-old last-new))
          (start-side (if (eq kind ?-) 'left 'right))
          (start (if (eq kind ?-) old new)))
      (append (list :path path :line line :side side)
              (unless (and (eq start-side side) (eql start line))
                (list :start-line start :start-side start-side))
              (list :subject-type 'line)))))

(defun prrr-state-file-anchor (path)
  "Return the anchor of a File Comment on PATH."
  (list :path path :subject-type 'file))

(defun prrr-state-anchor-label (anchor)
  "Describe ANCHOR for a header, as \"src/a.el:3-5 right\" or \"src/a.el\"."
  (let ((path (plist-get anchor :path))
        (line (plist-get anchor :line))
        (side (plist-get anchor :side))
        (start (plist-get anchor :start-line))
        (start-side (plist-get anchor :start-side)))
    (cond ((eq (plist-get anchor :subject-type) 'file) path)
          ((null start) (format "%s:%d %s" path line side))
          ((eq start-side side) (format "%s:%d-%d %s" path start line side))
          (t (format "%s:%d %s-%d %s" path start start-side line side)))))

(defun prrr-state-suggestion-body (lines)
  "Return a comment body suggesting a replacement for LINES.
LINES are the commented diff lines as (KIND . TEXT).  Signal a
`user-error' when one was removed, since a suggestion replaces lines of
the new file."
  (when (seq-some (lambda (line) (eq (car line) ?-)) lines)
    (user-error "A suggestion replaces lines of the new file; the region has removed lines"))
  (concat "```suggestion\n" (mapconcat #'cdr lines "\n") "\n```\n"))
```

- [ ] **Step 4: Find the lines at point**

In `prrr-diff.el`, insert before `;;;; Commands`:

```elisp
(defun prrr-diff-head ()
  "Return the oid of the head the current Review Buffer diffs to, or nil."
  prrr-diff--head)

(defun prrr-diff--hunk-of (section)
  "Return the `hunk' section SECTION is in, or nil."
  (while (and section (not (eq (oref section type) 'hunk)))
    (setq section (oref section parent)))
  section)

(defun prrr-diff--line-at (pos)
  "Describe the diff line at POS as (HUNK KIND OLD NEW TEXT), or nil.
HUNK is the line's `hunk' section, KIND its first character, OLD and
NEW its numbers in the old and new file (nil on a side it is not on),
TEXT the line without KIND.  A position in a Thread counts as the diff
line the Thread follows.  nil off a hunk and on a hunk's heading."
  (save-excursion
    (goto-char pos)
    (goto-char (line-beginning-position))
    (let* ((at (magit-section-at))
           (hunk (prrr-diff--hunk-of at)))
      (when hunk
        (unless (eq at hunk)
          (goto-char (oref at start))
          (forward-line -1)
          ;; Several Threads can follow one diff line: step past them.
          (while (and (not (bobp)) (not (eq (magit-section-at) hunk)))
            (forward-line -1)))
        (when (>= (point) (oref hunk content))
          (let ((target (point))
                (old (car (oref hunk from-range)))
                (new (car (oref hunk to-range))))
            (goto-char (oref hunk content))
            (catch 'found
              (while (<= (point) target)
                (when (eq (magit-section-at) hunk)
                  (let ((kind (char-after)))
                    (when (= (point) target)
                      (throw 'found
                             (list hunk kind
                                   (and (memq kind '(?- ?\s)) old)
                                   (and (memq kind '(?+ ?\s)) new)
                                   (buffer-substring-no-properties
                                    (min (1+ (point)) (line-end-position))
                                    (line-end-position)))))
                    (pcase kind
                      (?\s (cl-incf old) (cl-incf new))
                      (?- (cl-incf old))
                      (?+ (cl-incf new)))))
                (forward-line))
              nil)))))))

(defun prrr-diff--region-ends ()
  "Return (BEG . END), the first and last position the comment commands use.
The region's when it is active, else point twice.  A region ending at
the start of a line ends on the line before."
  (if (use-region-p)
      (let ((beg (region-beginning))
            (end (region-end)))
        (cons beg (if (and (> end beg) (save-excursion (goto-char end) (bolp)))
                      (1- end)
                    end)))
    (cons (point) (point))))

(defun prrr-diff-anchor ()
  "Return the anchor of a comment on the line at point or the region's lines.
See `prrr-state-anchor'.  Signal a `user-error' off the diff's lines or
across hunks."
  (prrr-diff-pullreq)
  (pcase-let* ((`(,beg . ,end) (prrr-diff--region-ends))
               (first (or (prrr-diff--line-at beg)
                          (user-error "Not on a diff line; C comments on the file")))
               (last (or (prrr-diff--line-at end)
                         (user-error "The region does not end on a diff line")))
               (file (oref (car first) parent)))
    (prrr-state-anchor (oref file value) (seq-take first 4) (seq-take last 4))))

(defun prrr-diff-file-anchor ()
  "Return the anchor of a File Comment on the file at point."
  (prrr-diff-pullreq)
  (prrr-state-file-anchor
   (oref (or (prrr-diff--file-at-point) (user-error "No file here")) value)))

(defun prrr-diff-region-lines ()
  "Return the diff lines of the line at point or of the region, as (KIND . TEXT).
Lines of Threads in between are left out."
  (pcase-let* ((`(,beg . ,end) (prrr-diff--region-ends))
               (lines nil))
    (save-excursion
      (goto-char beg)
      (goto-char (line-beginning-position))
      (while (<= (point) end)
        (let ((line (and (prrr-diff--hunk-of (magit-section-at))
                         (eq (magit-section-at) (prrr-diff--hunk-of (magit-section-at)))
                         (prrr-diff--line-at (point)))))
          (when line
            (push (cons (nth 1 line) (nth 4 line)) lines)))
        (forward-line)))
    (nreverse lines)))

(defun prrr-diff--section-of (types)
  "Return the section around point whose type is one of TYPES, or nil."
  (let ((section (magit-current-section)))
    (while (and section (not (memq (oref section type) types)))
      (setq section (oref section parent)))
    section))

(defun prrr-diff-thread-at-point ()
  "Return the `prrr-thread' at point, as the buffer shows it, or nil."
  (when-let ((section (prrr-diff--section-of '(thread file-comment))))
    (gethash (oref section value) prrr-diff--threads)))

(defun prrr-diff-comment-at-point ()
  "Return the `prrr-comment' at point, as the buffer shows it, or nil."
  (when-let ((section (prrr-diff--section-of '(review-comment))))
    (gethash (oref section value) prrr-diff--comments)))
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `make test`
Expected: all pass.

- [ ] **Step 6: Run all gates and commit**

```bash
make compile lint test
git add prrr-state.el prrr-diff.el test/prrr-state-test.el test/prrr-diff-test.el
git commit -m "feat(diff): the anchor of a comment on the line at point or the region"
```

---

### Task 10: Rendering unsent and failed writes, agents, suggestions

**Files:**
- Modify: `prrr-state.el` (new part `;;;; Suggestions` before `(provide 'prrr-state)`)
- Modify: `prrr-thread.el` (require `prrr-state`; faces; `prrr-thread-label`; `prrr-thread--row-note`, `prrr-thread--write-note`, `prrr-thread--insert-body`; `prrr-thread--heading`, `prrr-thread--insert-comment` and `prrr-thread-insert` replaced; `prrr-thread-insert-unsent-post`; Commentary)
- Modify: `prrr-diff.el` (`prrr-diff--anchored-lines` added; `prrr-diff--insert-anchored`, `prrr-diff--wash-hunk`, `prrr-diff--insert-group`, `prrr-diff--status-line`, `prrr-diff--insert-header` replaced; `prrr-diff--outbox-status` added; the File Comment loop in `prrr-diff--wash-file`)
- Modify: `test/prrr-state-test.el`, `test/prrr-thread-test.el`, `test/prrr-diff-test.el`

**Interfaces:**
- Consumes: Task 5's `:writes`, `:discussion`, `:submit` and `:outbox` of the view; Task 6's `prrr-diff--data`, `prrr-sync-outbox-describe`.
- Produces:
  - `(prrr-state-split-suggestions BODY)` → list of `(text . STRING)` and `(suggestion . LINES)`; `(prrr-state-suggestion-diff OLD NEW)` → list of `(CHAR . LINE)`.
  - `prrr-thread-insert` becomes `(THREAD COMMENTS &key with-path writes lines)`: WRITES is the view's `:writes`, LINES the anchored lines' text.
  - `(prrr-thread-label THREAD)` → "src/a.el, line 12"; `(prrr-thread-insert-unsent-post BODY ROW)` inserts a section of type `unsent-post`.
  - Faces `prrr-unsent`, `prrr-failed`, `prrr-agent`, `prrr-suggestion-heading`.
  - Header status line: `Pending Review: N comments` (counting unsent pending comments), `Outbox: N unsent, M failed, O to act`, `submitting (VERDICT)…`, the Outbox's rate-limit pause.

- [ ] **Step 1: Write the failing tests**

Append to `test/prrr-state-test.el`, before `(provide 'prrr-state-test)`:

```elisp
;;;; Suggestions

(ert-deftest prrr-state-test-split-suggestions ()
  (should (equal '((text . "Try this:") (suggestion "a" "b") (text . "Thanks."))
                 (prrr-state-split-suggestions "Try this:\n```suggestion\na\nb\n```\nThanks.")))
  (should (equal '((suggestion "a") (suggestion "b"))
                 (prrr-state-split-suggestions "```suggestion\na\n```\n```suggestion\nb\n```")))
  (should (equal '((text . "plain\n\nmore")) (prrr-state-split-suggestions "plain\n\nmore\n")))
  (should-not (prrr-state-split-suggestions "")))

(ert-deftest prrr-state-test-split-suggestions-empty-block ()
  "An empty block deletes the lines; one with an empty line replaces them by it."
  (should (equal '((suggestion)) (prrr-state-split-suggestions "```suggestion\n```")))
  (should (equal '((suggestion "")) (prrr-state-split-suggestions "```suggestion\n\n```"))))

(ert-deftest prrr-state-test-suggestion-diff ()
  (should (equal '((?\s . "a") (?- . "b") (?+ . "B") (?\s . "c"))
                 (prrr-state-suggestion-diff '("a" "b" "c") '("a" "B" "c"))))
  (should (equal '((?- . "x")) (prrr-state-suggestion-diff '("x") nil)))
  (should (equal '((?+ . "y")) (prrr-state-suggestion-diff nil '("y")))))
```

Append to `test/prrr-thread-test.el`, before `(provide 'prrr-thread-test)`:

```elisp
;;;; Unsent writes, agents and suggestions

(defun prrr-thread-test--row (id &optional error)
  "A queued write with ID, failed with ERROR when non-nil."
  (prrr-outbox-create :id id :pr-id "PR_1" :kind 'edit :payload nil
                      :created-at "2026-10-10T12:00:00Z" :attempts (if error 1 0)
                      :last-error error))

(ert-deftest prrr-thread-test-unsent-and-failed ()
  (let ((writes (make-hash-table :test #'equal)))
    (puthash "C_1" (prrr-thread-test--row "1") writes)
    (puthash "C_2" (prrr-thread-test--row "2" "GitHub returned HTTP 502") writes)
    (prrr-thread-test--with-render
        (prrr-thread-insert (prrr-test-thread)
                            (list (prrr-thread-test--comment)
                                  (prrr-thread-test--comment :id "C_2" :author "example-me"))
                            :writes writes)
      (should (eq 'thread (oref section type)))
      (forward-line)
      (should (looking-at "    example-bob  2026-09-02  unsent$"))
      (should (eq 'prrr-unsent (get-text-property (- (line-end-position) 2) 'font-lock-face)))
      (forward-line 2)
      (should (looking-at "    example-me  2026-09-02  failed: GitHub returned HTTP 502$"))
      (should (eq 'prrr-failed (get-text-property (- (line-end-position) 2) 'font-lock-face))))))

(ert-deftest prrr-thread-test-agent-comment ()
  (let ((comment (prrr-thread-test--comment)))
    (setf (prrr-comment-agent-p comment) t)
    (prrr-thread-test--with-render
        (prrr-thread-insert (prrr-test-thread) (list comment))
      (should (eq 'thread (oref section type)))
      (forward-line)
      (should (looking-at "    example-bob  2026-09-02  agent$")))))

(ert-deftest prrr-thread-test-suggestion-as-mini-diff ()
  (prrr-thread-test--with-render
      (prrr-thread-insert (prrr-test-thread)
                          (list (prrr-thread-test--comment
                                 :body "Rename it:\n```suggestion\nline 12\n```\nThanks."))
                          :lines '("line twelve"))
    (should (eq 'thread (oref section type)))
    (should (equal '("    Thread  line 12  1 comment"
                     "    example-bob  2026-09-02"
                     "      Rename it:"
                     "      Suggested change:"
                     "      -line twelve"
                     "      +line 12"
                     "      Thanks.")
                   (prrr-thread-test--lines)))
    (goto-char (point-min))
    (re-search-forward "^      \\+line 12")
    (should (eq 'magit-diff-added (get-text-property (- (point) 2) 'font-lock-face)))))

(ert-deftest prrr-thread-test-unsent-discussion-comment ()
  (prrr-thread-test--with-render
      (prrr-thread-insert-unsent-post "Thanks!" (prrr-thread-test--row "9"))
    (should (eq 'unsent-post (oref section type)))
    (should (equal '("    Your Discussion Comment  unsent" "      Thanks!")
                   (prrr-thread-test--lines)))))
```

In `prrr-thread-test-with-path-and-outdated-line`, the call's last line `nil t)` becomes `nil :with-path t)`.

Append to `test/prrr-diff-test.el`, before `(provide 'prrr-diff-test)`:

```elisp
;;;; Unsent writes and suggestions

(ert-deftest prrr-diff-test-suggestion-against-anchored-lines ()
  "A suggestion on a right-side Thread is a mini diff against its lines."
  (prrr-diff-test--with-buffer
      (progn (prrr-diff-test--store-fixture)
             (prrr-db-insert (prrr-comment-create
                              :comment-id "C_SUGGEST" :thread-id "PRRT_kwDOexample0000001"
                              :pr-id prrr-diff-test--pr :author "example-carol"
                              :body "```suggestion\nline 12\n```"
                              :created-at "2026-09-05T00:00:00Z" :state 'submitted
                              :local-state 'sent)))
    (prrr-diff-test--hunks "src/example.el")
    (goto-char (point-min))
    (re-search-forward "^      Suggested change:\n      -line twelve\n      \\+line 12$")))

(ert-deftest prrr-diff-test-header-counts-the-outbox ()
  "SPEC section 6: the header counts the Outbox; unsent Discussion Comments show."
  (prrr-diff-test--with-buffer
      (progn
        (prrr-diff-test--store-fixture)
        (prrr-db-insert (prrr-outbox-create :id "1" :pr-id prrr-diff-test--pr :kind 'viewed
                                            :payload '(:path "a.el" :viewed t) :attempts 0))
        (prrr-db-insert (prrr-outbox-create :id "2" :pr-id prrr-diff-test--pr :kind 'discussion
                                            :payload '(:comment "local:D" :body "Thanks!")
                                            :attempts 1 :last-error "offline")))
    (let ((status (prrr-diff-test--status-line)))
      (should (string-match-p "Pending Review: 1 comment" status))
      (should (string-match-p "Outbox: 1 unsent, 1 failed, O to act" status)))
    (let ((discussion (magit-get-section '((discussion) (prrr-header) (diffbuf)))))
      (should (string-match-p "Discussion (1)" (prrr-diff-test--text discussion)))
      (should (string-match-p "Your Discussion Comment  failed: offline"
                              (prrr-diff-test--text discussion))))))
```

- [ ] **Step 2: Run them to verify they fail**

Run: `make test TESTS="test/prrr-state-test.el test/prrr-thread-test.el test/prrr-diff-test.el"`
Expected: FAIL; `prrr-state-split-suggestions` is void and `prrr-thread-insert` rejects `:writes`.

- [ ] **Step 3: Suggestions, pure**

Insert before `(provide 'prrr-state)`:

```elisp
;;;; Suggestions

(defun prrr-state-split-suggestions (body)
  "Split BODY into its prose and its suggestion blocks, in order.
Return a list of (text . STRING) and (suggestion . LINES) pairs, LINES
being the suggested lines, nil for a block that deletes the anchored
lines.  A block opens with a line \"```suggestion\" and closes with a
line \"```\"."
  (let ((parts nil) (start 0))
    (while (string-match "^```suggestion[ \t]*\n\\(\\(?:.*\n\\)*?\\)```[ \t]*$" body start)
      (let ((text (substring body start (match-beginning 0)))
            (lines (match-string 1 body)))
        (setq start (match-end 0))
        (unless (string-empty-p (string-trim text))
          (push (cons 'text (string-trim text)) parts))
        (push (cons 'suggestion (and (not (string-empty-p lines))
                                     (split-string (string-remove-suffix "\n" lines) "\n")))
              parts)))
    (let ((rest (string-trim (substring body start))))
      (unless (string-empty-p rest)
        (push (cons 'text rest) parts)))
    (nreverse parts)))

(defun prrr-state-suggestion-diff (old new)
  "Return the mini diff from the lines OLD to the lines NEW.
A list of (CHAR . LINE): ?\\s for a line both keep at the start or the
end, ?- for one only OLD has, ?+ for one only NEW has."
  (let ((head 0) (tail 0))
    (while (and (< head (length old)) (< head (length new))
                (equal (nth head old) (nth head new)))
      (cl-incf head))
    (while (and (< tail (- (length old) head)) (< tail (- (length new) head))
                (equal (nth (- (length old) tail 1) old) (nth (- (length new) tail 1) new)))
      (cl-incf tail))
    (append (mapcar (lambda (line) (cons ?\s line)) (seq-take old head))
            (mapcar (lambda (line) (cons ?- line)) (seq-subseq old head (- (length old) tail)))
            (mapcar (lambda (line) (cons ?+ line)) (seq-subseq new head (- (length new) tail)))
            (mapcar (lambda (line) (cons ?\s line)) (seq-subseq old (- (length old) tail))))))
```

`prrr-state-split-suggestions` reads `match-beginning`, `match-string` and `match-end` before calling anything else: `string-trim` and `split-string` clobber the match data, and a stale `match-end` would loop forever.

- [ ] **Step 4: Rendering**

In `prrr-thread.el`: add `(require 'prrr-state)` after `(require 'prrr-db)`. After the `prrr-comment-pending` face, add:

```elisp
(defface prrr-unsent '((t :inherit shadow :slant italic))
  "Marks a comment or change GitHub has not accepted yet."
  :group 'prrr)

(defface prrr-failed '((t :inherit error))
  "Marks a comment or change GitHub refused or could not be sent."
  :group 'prrr)

(defface prrr-agent '((t :inherit font-lock-builtin-face))
  "Marks a comment an agent wrote through prrr's API."
  :group 'prrr)

(defface prrr-suggestion-heading '((t :inherit magit-diff-hunk-heading))
  "Heading of a suggested change inside a comment."
  :group 'prrr)
```

After `prrr-thread--location`, add:

```elisp
(defun prrr-thread-label (thread)
  "Describe where THREAD is, such as \"src/a.el, line 12\", for a header."
  (concat (prrr-thread-path thread) ", " (prrr-thread--location thread)))

(defun prrr-thread--row-note (row)
  "Return \"  unsent\", or \"  failed: \" and the error, for the queued write ROW."
  (if-let ((error (prrr-outbox-last-error row)))
      (propertize (concat "  failed: " error) 'font-lock-face 'prrr-failed)
    (propertize "  unsent" 'font-lock-face 'prrr-unsent)))

(defun prrr-thread--write-note (id writes)
  "Return the note on the queued write of ID in WRITES, or nil.
WRITES is the :writes table of `prrr-state-outbox-view'; see
`prrr-thread--row-note' for the note."
  (when-let ((row (and writes id (gethash id writes))))
    (prrr-thread--row-note row)))

(defun prrr-thread-insert-unsent-post (body row)
  "Insert the Discussion Comment BODY that the queued write ROW will post.
A section of type `unsent-post' whose value is ROW's id."
  (magit-insert-section (unsent-post (prrr-outbox-id row))
    (magit-insert-heading
      prrr-thread-indent
      (propertize "Your Discussion Comment" 'font-lock-face 'prrr-comment-author)
      (prrr-thread--row-note row)
      "\n")
    (prrr-thread--insert-body body nil)))
```

Replace `prrr-thread--heading`, `prrr-thread--insert-comment` and `prrr-thread-insert` with these, and add `prrr-thread--insert-body` before `prrr-thread--insert-comment`:

```elisp
(defun prrr-thread--heading (thread comments with-path writes)
  "Return the heading line of THREAD, which holds COMMENTS.
WITH-PATH non-nil puts the file before the location; WRITES is as for
`prrr-thread--write-note'."
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
            (prrr-thread--write-note (prrr-thread-thread-id thread) writes)
            "\n")))

(defun prrr-thread--insert-body (body lines)
  "Insert the comment BODY, its suggestions as mini diffs against LINES.
LINES are the text of the lines the Thread is anchored to, or nil."
  (dolist (part (prrr-state-split-suggestions (or body "")))
    (pcase part
      (`(text . ,text)
       (dolist (line (split-string text "\n"))
         (insert prrr-thread-indent "  " line "\n")))
      (`(suggestion . ,new)
       (insert prrr-thread-indent "  "
               (propertize "Suggested change:" 'font-lock-face 'prrr-suggestion-heading) "\n")
       (pcase-dolist (`(,char . ,line) (prrr-state-suggestion-diff lines new))
         (insert prrr-thread-indent "  "
                 (propertize (concat (string char) line)
                             'font-lock-face (pcase char
                                               (?- 'magit-diff-removed)
                                               (?+ 'magit-diff-added)
                                               (_ 'magit-diff-context)))
                 "\n"))))))

(defun prrr-thread--insert-comment (comment writes lines)
  "Insert COMMENT as a section of type `review-comment'.
WRITES is as for `prrr-thread--write-note'; LINES as for
`prrr-thread--insert-body'."
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
      (and (prrr-comment-agent-p comment)
           (propertize "  agent" 'font-lock-face 'prrr-agent))
      (prrr-thread--write-note (prrr-comment-comment-id comment) writes)
      "\n")
    (prrr-thread--insert-body (prrr-comment-body comment) lines)))

(cl-defun prrr-thread-insert (thread comments &key with-path writes lines)
  "Insert THREAD and its COMMENTS, oldest first, as a section.
The section type is `file-comment' for a File Comment and `thread'
otherwise; its value is the Thread id and its children are one
`review-comment' section per comment.  A resolved Thread starts
hidden.  WITH-PATH non-nil names the file in the heading, for a Thread
shown away from its file.  WRITES, the :writes table of
`prrr-state-outbox-view', marks what GitHub has not accepted yet.
LINES, the text of the anchored lines, shows suggestions as mini
diffs against them."
  (magit-insert-section section ((eval (if (eq (prrr-thread-subject-type thread) 'file)
                                           'file-comment
                                         'thread))
                                 (prrr-thread-thread-id thread)
                                 (prrr-thread-resolved-p thread))
    (oset section keymap 'prrr-thread-section-map)
    (magit-insert-heading (prrr-thread--heading thread comments with-path writes))
    (dolist (comment comments)
      (prrr-thread--insert-comment comment writes lines))))
```

Add to the Commentary: "A comment or Thread the Outbox has not sent shows `unsent`, or `failed:` and GitHub's words; a suggestion block shows as a mini diff against the anchored lines."

In `prrr-diff.el`, replace `prrr-diff--insert-anchored`, `prrr-diff--wash-hunk` and `prrr-diff--insert-group` with these, and add `prrr-diff--anchored-lines` before them:

```elisp
(defun prrr-diff--anchored-lines (thread right-lines)
  "Return the text of THREAD's lines that RIGHT-LINES holds, in order.
RIGHT-LINES maps new-file line numbers to their text."
  (let ((line (prrr-thread-line thread)))
    (delq nil (mapcar (lambda (number) (gethash number right-lines))
                      (number-sequence (or (prrr-thread-start-line thread) line) line)))))

(defun prrr-diff--insert-anchored (anchors side line comments right-lines)
  "Insert the Threads ANCHORS holds for LINE of SIDE, and remove them.
COMMENTS maps Thread ids to their Review Comments.  RIGHT-LINES maps
the new-file numbers of the hunk's lines so far to their text, against
which a right-side Thread's suggestions are shown."
  (when line
    (let ((key (cons side line)))
      (dolist (thread (gethash key anchors))
        (prrr-thread-insert thread (gethash (prrr-thread-thread-id thread) comments)
                            :writes (plist-get prrr-diff--data :writes)
                            :lines (and (eq side 'right)
                                        (prrr-diff--anchored-lines thread right-lines))))
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
           (new (car (car (last ranges))))
           (right-lines (and (> (hash-table-count anchors) 0) (make-hash-table))))
      (magit-delete-line)
      (magit-insert-section section (hunk (cons about ranges) nil
                                          :combined combined
                                          :from-range (if combined (butlast ranges) (car ranges))
                                          :to-range (car (last ranges))
                                          :about about)
        (oset section keymap 'prrr-diff-hunk-section-map)
        (magit-insert-heading
          (propertize (concat heading "\n") 'font-lock-face 'magit-diff-hunk-heading))
        (while (not (or (eobp) (looking-at "^[^-+\s\\]")))
          (let ((old-line nil) (new-line nil))
            (pcase (char-after)
              (?\s (setq old-line old new-line new) (cl-incf old) (cl-incf new))
              (?- (setq old-line old) (cl-incf old))
              (?+ (setq new-line new) (cl-incf new)))
            (when (and right-lines new-line)
              (puthash new-line (buffer-substring-no-properties (1+ (point)) (line-end-position))
                       right-lines))
            (forward-line)
            (prrr-diff--insert-anchored anchors 'left old-line comments right-lines)
            (prrr-diff--insert-anchored anchors 'right new-line comments right-lines)))))
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
                            :with-path (eq type 'outdated-files)
                            :writes (plist-get prrr-diff--data :writes))))))
```

The washer keeps the hunk's new-file lines only when the file has Threads, so a file without Threads costs nothing more. In `prrr-diff--wash-file`, the File Comment loop becomes:

```elisp
    (dolist (thread (and threads (prrr-file-threads-file-comments threads)))
      (prrr-thread-insert thread (gethash (prrr-thread-thread-id thread) comments)
                          :writes (plist-get prrr-diff--data :writes)))
```

Replace `prrr-diff--status-line` and `prrr-diff--insert-header` with these, and add `prrr-diff--outbox-status` before them:

```elisp
(defun prrr-diff--outbox-status (data)
  "Describe the Outbox of the review DATA for the header, or return nil."
  (let* ((outbox (plist-get data :outbox))
         (failed (seq-count #'prrr-outbox-last-error outbox))
         (unsent (- (length outbox) failed)))
    (when outbox
      (concat "Outbox: "
              (string-join (delq nil (list (and (> unsent 0) (format "%d unsent" unsent))
                                           (and (> failed 0) (format "%d failed, O to act" failed))))
                           ", ")))))

(defun prrr-diff--status-line (pullreq base head data)
  "Return the header's status line for PULLREQ.
BASE and HEAD are the diffed oids, either may be nil; DATA is the
review data shown.  Names the Range, the Pending Review's comments, the
Outbox, a queued Submit, what the last refetch said, and whether
GitHub's head differs from the local one."
  (let* ((status (prrr-sync-review-status (oref pullreq their-id)))
         (github-head (plist-get status :head-oid))
         (submit (plist-get data :submit))
         (pending (seq-count (lambda (comment) (eq (prrr-comment-state comment) 'pending))
                             (plist-get data :comments))))
    (string-join
     (delq nil
           (list (if base
                     (format "Range: default, %s..%s" (prrr-diff--short base)
                             (prrr-diff--short head))
                   "Range: unavailable")
                 (and (or (plist-get data :pending-review) (> pending 0))
                      (format "Pending Review: %d comment%s" pending (if (= pending 1) "" "s")))
                 (prrr-diff--outbox-status data)
                 (and submit
                      (format "submitting (%s)…"
                              (plist-get (prrr-outbox-payload submit) :verdict)))
                 (prrr-sync-outbox-describe)
                 (prrr-sync-describe status "refreshing…")
                 (and github-head head (not (equal github-head head))
                      (format "GitHub's head is %s: run forge-pull, then g"
                              (prrr-diff--short github-head)))))
     "  ·  ")))

(defun prrr-diff--insert-header (pullreq base head data)
  "Insert the header of PULLREQ's Review Buffer.
The title, a status line (`prrr-diff--status-line' of BASE, HEAD and
DATA), and hidden `description' and `discussion' sections.  The
discussion ends with DATA's unsent Discussion Comments."
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
    (let ((posts (prrr-diff--posts pullreq))
          (unsent (plist-get data :discussion)))
      (magit-insert-section section (discussion nil t)
        ;; Without this, forge's `forge-discussion-section-map' applies.
        (oset section keymap nil)
        (magit-insert-heading (format "Discussion (%d)" (+ (length posts) (length unsent))))
        (dolist (post posts)
          (forge-insert-post post pullreq))
        (pcase-dolist (`(,_id ,body ,row) unsent)
          (prrr-thread-insert-unsent-post body row))))
    (insert "\n")))
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `make test`
Expected: all pass, the milestone-3 rendering and header tests included.

- [ ] **Step 6: Run all gates and commit**

```bash
make compile lint test bench
git add prrr-state.el prrr-thread.el prrr-diff.el test/prrr-state-test.el test/prrr-thread-test.el test/prrr-diff-test.el
git commit -m "feat(thread): unsent and failed marks, agent badge, suggestions as mini diffs; Outbox in the header"
```

`make bench` must report the four Review Buffer lines within budget (about 117, 361, 2 and 133 ms); its exit status is non-zero because of the queue budget (`prrr-opy`).

---

### Task 11: The capture buffer

**Files:**
- Modify: `prrr-thread.el` (new part `;;;; The capture buffer` before `(provide 'prrr-thread)`; Commentary)
- Modify: `test/prrr-thread-test.el`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `(prrr-comment-capture LABEL ON-CONFIRM &key body immediate (immediate-allowed t) allow-empty)` → the capture buffer, shown in a bottom side window. ON-CONFIRM is called with `(TEXT IMMEDIATE)` in the buffer the capture started from.
  - `prrr-comment-mode` (derived from `prrr-comment--parent-mode`, an alias of `gfm-mode` or `text-mode`), `prrr-comment-mode-map`, commands `prrr-comment-confirm` (`C-c C-c`), `prrr-comment-abort` (`C-c C-k`), `prrr-comment-toggle-immediate` (`C-c C-i`).
  - Private `prrr-comment--header` (tests call it).

- [ ] **Step 1: Write the failing tests**

Append to `test/prrr-thread-test.el`, before `(provide 'prrr-thread-test)`:

```elisp
;;;; The capture buffer

(defmacro prrr-thread-test--with-capture (args &rest body)
  "Open a capture buffer from a scratch buffer and run BODY in it.
ARGS follow the label and the confirm function of `prrr-comment-capture'.
`confirmed' collects (TEXT IMMEDIATE BUFFER) of each confirm and
`origin' is the scratch buffer."
  (declare (indent 1))
  `(let ((confirmed nil)
         (origin (generate-new-buffer "prrr-test-origin")))
     (unwind-protect
         (with-current-buffer origin
           (insert "line one\nline two\n")
           (goto-char 10)
           (let ((capture (apply #'prrr-comment-capture "src/a.el:3 right"
                                 (lambda (text immediate)
                                   (push (list text immediate (current-buffer)) confirmed))
                                 (list ,@args))))
             (with-current-buffer capture
               ,@body)))
       (dolist (buffer (buffer-list))
         (when (string-prefix-p "*prrr comment*" (buffer-name buffer))
           (kill-buffer buffer)))
       (kill-buffer origin))))

(ert-deftest prrr-thread-test-capture-confirm ()
  (prrr-thread-test--with-capture ()
    (should (eq 'prrr-comment-mode major-mode))
    (should (derived-mode-p 'text-mode))
    (should (string-match-p "src/a\\.el:3 right" (prrr-comment--header)))
    (should (string-match-p "Pending Review" (prrr-comment--header)))
    (insert "  Looks odd.  \n")
    (let ((capture (current-buffer)))
      (prrr-comment-confirm)
      (should-not (buffer-live-p capture)))
    (should (equal (list (list "Looks odd." nil origin)) confirmed))
    (should (eq (current-buffer) origin))
    (should (= 10 (point)))))

(ert-deftest prrr-thread-test-capture-keys ()
  (prrr-thread-test--with-capture ()
    (should (eq 'prrr-comment-confirm (key-binding (kbd "C-c C-c"))))
    (should (eq 'prrr-comment-abort (key-binding (kbd "C-c C-k"))))
    (should (eq 'prrr-comment-toggle-immediate (key-binding (kbd "C-c C-i"))))))

(ert-deftest prrr-thread-test-capture-empty-refused ()
  "Review Focus 5: an empty comment is refused and the buffer stays."
  (prrr-thread-test--with-capture ()
    (insert "  \n")
    (should-error (prrr-comment-confirm) :type 'user-error)
    (should (eq major-mode 'prrr-comment-mode))
    (should-not confirmed)))

(ert-deftest prrr-thread-test-capture-allow-empty ()
  (prrr-thread-test--with-capture (:allow-empty t)
    (prrr-comment-confirm)
    (should (equal "" (car (car confirmed))))))

(ert-deftest prrr-thread-test-capture-abort ()
  (prrr-thread-test--with-capture (:body "Draft")
    (should (equal "Draft" (buffer-string)))
    (let ((capture (current-buffer)))
      (prrr-comment-abort)
      (should-not (buffer-live-p capture)))
    (should-not confirmed)))

(ert-deftest prrr-thread-test-capture-toggle-immediate ()
  (prrr-thread-test--with-capture (:immediate t)
    (should (string-match-p "publish now" (prrr-comment--header)))
    (prrr-comment-toggle-immediate)
    (insert "Later.")
    (prrr-comment-confirm)
    (should (equal '("Later." nil) (seq-take (car confirmed) 2)))))

(ert-deftest prrr-thread-test-capture-fixed-choice ()
  (prrr-thread-test--with-capture (:immediate t :immediate-allowed nil)
    (should-error (prrr-comment-toggle-immediate) :type 'user-error)
    (should-not (string-match-p "publish now" (prrr-comment--header)))))

(ert-deftest prrr-thread-test-capture-keeps-text-when-sending-fails ()
  "Review Focus 5: when the command refuses the text, nothing is lost."
  (let ((origin (generate-new-buffer "prrr-test-origin")))
    (unwind-protect
        (with-current-buffer origin
          (with-current-buffer (prrr-comment-capture "x" (lambda (_text _now) (user-error "No")))
            (insert "Keep me.")
            (should-error (prrr-comment-confirm) :type 'user-error)
            (should (equal "Keep me." (buffer-string)))
            (kill-buffer)))
      (kill-buffer origin))))

(ert-deftest prrr-thread-test-capture-origin-killed ()
  "Review Focus 5: confirming after the Review Buffer is gone still sends."
  (let ((confirmed nil)
        (origin (generate-new-buffer "prrr-test-origin")))
    (with-current-buffer origin
      (with-current-buffer (prrr-comment-capture "x" (lambda (text _now) (push text confirmed)))
        (kill-buffer origin)
        (insert "Still sent.")
        (prrr-comment-confirm)))
    (should (equal '("Still sent.") confirmed))))
```

- [ ] **Step 2: Run them to verify they fail**

Run: `make test TESTS=test/prrr-thread-test.el`
Expected: FAIL, `prrr-comment-capture` is void.

- [ ] **Step 3: Implement**

Insert before `(provide 'prrr-thread)`:

```elisp
;;;; The capture buffer

  :doc

(defalias 'prrr-comment--parent-mode
  (if (require 'markdown-mode nil t) 'gfm-mode 'text-mode)
  "The mode `prrr-comment-mode' derives from.
GitHub's Markdown mode when markdown-mode is installed, which forge
requires, else `text-mode'.")

(define-derived-mode prrr-comment-mode prrr-comment--parent-mode "prrr-comment"
  "Write a comment for prrr.
\\<prrr-comment-mode-map>\\[prrr-comment-confirm] sends the comment, \\[prrr-comment-abort] drops it.
\\[prrr-comment-toggle-immediate] switches between the Pending Review and
Immediate Publish.

\\{prrr-comment-mode-map}"
  :interactive nil
  :group 'prrr
  (setq-local header-line-format '(:eval (prrr-comment--header))))

(defvar-local prrr-comment--label nil
  "What the comment is about, as the header line says.")

(defvar-local prrr-comment--on-confirm nil
  "Function called with the text and the immediate choice on confirm.")

(defvar-local prrr-comment--immediate nil
  "Non-nil when the comment is published at once.")

(defvar-local prrr-comment--immediate-allowed t
  "Non-nil when the user may change `prrr-comment--immediate'.")

(defvar-local prrr-comment--allow-empty nil
  "Non-nil when an empty text may be confirmed.")

(defvar-local prrr-comment--origin nil
  "Marker where the capture was started.")

(defvar-local prrr-comment--windows nil
  "The window configuration to restore when the capture ends.")

(defun prrr-comment--header ()
  "Return the header line of a capture buffer."
  (concat " " prrr-comment--label
          (and prrr-comment--immediate-allowed
               (if prrr-comment--immediate "  ·  publish now" "  ·  Pending Review"))
          (substitute-command-keys
           (concat "  ·  \\<prrr-comment-mode-map>\\[prrr-comment-confirm] send, "
                   "\\[prrr-comment-abort] cancel"
                   (and prrr-comment--immediate-allowed
                        ", \\[prrr-comment-toggle-immediate] publish now or later")))))

(cl-defun prrr-comment-capture (label on-confirm &key body immediate (immediate-allowed t)
                                      allow-empty)
  "Open a buffer to write a comment about LABEL, and return it.
LABEL says what the comment is about, as `prrr-state-anchor-label' or
`prrr-thread-label' do; the header line shows it.  BODY is the initial
text.  IMMEDIATE is the initial choice between the Pending Review (nil)
and Immediate Publish; IMMEDIATE-ALLOWED nil fixes it.  ALLOW-EMPTY
non-nil lets an empty text be confirmed.

On confirm, ON-CONFIRM is called with the trimmed text and the
immediate choice, in the buffer the capture started from; then the
capture buffer closes and the windows, with point where it was, come
back.  When ON-CONFIRM signals, the capture buffer stays, so no text is
lost."
  (let ((origin (point-marker))
        (windows (current-window-configuration))
        (buffer (generate-new-buffer "*prrr comment*")))
    (with-current-buffer buffer
      (prrr-comment-mode)
      (setq prrr-comment--label label
            prrr-comment--on-confirm on-confirm
            prrr-comment--immediate immediate
            prrr-comment--immediate-allowed immediate-allowed
            prrr-comment--allow-empty allow-empty
            prrr-comment--origin origin
            prrr-comment--windows windows)
      (when body
        (insert body)))
    (pop-to-buffer buffer '((display-buffer-in-side-window) (side . bottom)
                            (window-height . 0.3)))
    buffer))

(defun prrr-comment--close ()
  "Kill the current capture buffer and bring the windows back."
  (let ((windows prrr-comment--windows)
        (origin prrr-comment--origin))
    (kill-buffer (current-buffer))
    (when windows
      (set-window-configuration windows))
    (when (and origin (buffer-live-p (marker-buffer origin)))
      (set-buffer (marker-buffer origin))
      (goto-char origin))))

(defun prrr-comment-confirm ()
  "Send the comment of this buffer and close it."
  (interactive)
  (let ((text (string-trim (buffer-string)))
        (on-confirm prrr-comment--on-confirm)
        (immediate prrr-comment--immediate)
        (origin prrr-comment--origin))
    (when (and (string-empty-p text) (not prrr-comment--allow-empty))
      (user-error (substitute-command-keys
                   "Nothing to send; \\<prrr-comment-mode-map>\\[prrr-comment-abort] cancels")))
    (if (and origin (buffer-live-p (marker-buffer origin)))
        (with-current-buffer (marker-buffer origin)
          (funcall on-confirm text immediate))
      (funcall on-confirm text immediate))
    (prrr-comment--close)))

(defun prrr-comment-abort ()
  "Drop the comment of this buffer and close it."
  (interactive)
  (prrr-comment--close)
  (message "Comment dropped"))

(defun prrr-comment-toggle-immediate ()
  "Switch this comment between the Pending Review and Immediate Publish."
  (interactive)
  (unless prrr-comment--immediate-allowed
    (user-error "This one cannot switch between Pending Review and Immediate Publish"))
  (setq prrr-comment--immediate (not prrr-comment--immediate))
  (force-mode-line-update)
  (message (if prrr-comment--immediate
               "Publish at once"
             "Add to the Pending Review")))
```

The parent is quoted, not `#'`-quoted: `gfm-mode` may be undefined, and `#'` would warn. Add to the Commentary: "The capture buffer, `prrr-comment-mode', is here too: it takes a label and a function to call with the text, so it never needs to know about the diff (SPEC section 2)."

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test TESTS=test/prrr-thread-test.el`
Expected: all pass.

- [ ] **Step 5: Run all gates and commit**

```bash
make compile lint test
git add prrr-thread.el test/prrr-thread-test.el
git commit -m "feat(thread): the comment capture buffer"
```

---

### Task 12: Comment commands and keys

**Files:**
- Create: `prrr-review.el`
- Modify: `prrr-diff.el` (`prrr-diff--later-keys` and `prrr-diff--undefine-later-keys` replaced by `prrr-diff--review-keys`, `prrr-diff--later-keys`, `prrr-diff--bind-review-keys`; the three keymaps call the latter; the docstrings that name the old function)
- Modify: `prrr-transient.el` (require `prrr-review`; `prrr-menu` gets the Comment group)
- Modify: `prrr.el` (autoloads)
- Modify: `Makefile` (`SRC`, `TESTS`)
- Create: `test/prrr-review-test.el`
- Modify: `test/prrr-diff-test.el` (`prrr-diff-test-later-keys-do-nothing-yet` rewritten), `test/prrr-test.el` (autoload list)

**Interfaces:**
- Consumes: `prrr-sync-write` (Tasks 6, 8), `prrr-comment-capture` (Task 11), `prrr-thread-label` (Task 10), `prrr-diff-pullreq`, `prrr-diff-head`, `prrr-diff-anchor`, `prrr-diff-file-anchor`, `prrr-diff-region-lines`, `prrr-diff-thread-at-point`, `prrr-diff-comment-at-point` (Tasks 6, 9), `prrr-state-anchor-label`, `prrr-state-suggestion-body`, `prrr-state-local-id-p`.
- Produces:
  - Commands `prrr-comment` (`c`), `prrr-comment-file` (`C`), `prrr-reply` (`r`), `prrr-edit-comment` (`e`), `prrr-delete-comment` (`k`), `prrr-discussion-comment` (`d`), `prrr-toggle-resolved` (`R`), `prrr-comment-suggest` (`s`). The comment and reply commands take IMMEDIATE (prefix argument or `-i` in `prrr-menu`).
  - Private `prrr-review--immediate-p`, `prrr-review--write`, `prrr-review--comment-on`, `prrr-review--thread`, `prrr-review--own-comment` (Task 13 uses `prrr-review--write`).
  - `prrr-diff--review-keys` (alist key → command), `prrr-diff--later-keys`, `prrr-diff--bind-review-keys`.
  - `prrr-menu` switch `-i` (`--immediate`).

- [ ] **Step 1: Keys in the Review Buffer**

In `prrr-diff.el`, replace `prrr-diff--later-keys` and `prrr-diff--undefine-later-keys` with:

```elisp
(defconst prrr-diff--review-keys
  '(("c" . prrr-comment) ("C" . prrr-comment-file) ("r" . prrr-reply)
    ("e" . prrr-edit-comment) ("k" . prrr-delete-comment)
    ("d" . prrr-discussion-comment) ("R" . prrr-toggle-resolved)
    ("s" . prrr-comment-suggest))
  "The commenting and reviewing keys of a Review Buffer (SPEC section 9).
They are bound in the section keymaps too, which win over the mode's
and in which magit binds several of them.")

(defconst prrr-diff--later-keys
  '("D" "." "m" ">" "<" "S" "O" "@" "L")
  "Keys that later milestones give to prrr in a Review Buffer (SPEC section 9).
They are `undefined' until then, so magit's diff arguments or log never
run from a Review Buffer.")

(defun prrr-diff--bind-review-keys (map)
  "Bind the review keys in MAP and make the later keys `undefined'; return MAP.
They are `prrr-diff--review-keys' and `prrr-diff--later-keys'."
  (pcase-dolist (`(,key . ,command) prrr-diff--review-keys)
    (keymap-set map key command))
  (dolist (key prrr-diff--later-keys)
    (keymap-set map key #'undefined))
  map)
```

Then `sed -i 's/prrr-diff--undefine-later-keys/prrr-diff--bind-review-keys/g' prrr-diff.el` makes the three keymaps use it. The docstring of `prrr-diff-mode-map` becomes "Keys of the Review Buffer (SPEC section 9).\nThe keys of `prrr-diff--review-keys' and `prrr-diff--later-keys' are bound here and in the section keymaps." `prrr-diff-file-section-map`'s docstring ends "binds keys of `prrr-diff--review-keys' such as `C'." The commands are named by symbol in a list, so they need no `declare-function`; `prrr.el` autoloads them.

- [ ] **Step 2: Write the failing tests**

Replace `prrr-diff-test-later-keys-do-nothing-yet` in `test/prrr-diff-test.el` with:

```elisp
(ert-deftest prrr-diff-test-later-keys-do-nothing-yet ()
  "Magit's diff arguments, log and friends never run in a Review Buffer.
Checked by the effective binding on a file heading, a hunk line and a
Thread, where section keymaps apply on top of the mode's."
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (let* ((file (prrr-diff-test--file-section "src/example.el"))
           (hunk (car (prrr-diff-test--hunks "src/example.el")))
           (thread (car (oref hunk children))))
      (pcase-dolist (`(,where . ,position) `((file-heading . ,(oref file start))
                                             (hunk-line . ,(oref hunk content))
                                             (thread . ,(oref thread start))))
        (goto-char position)
        (dolist (key prrr-diff--later-keys)
          (should (equal (list where key 'undefined)
                         (list where key (key-binding (kbd key))))))
        (pcase-dolist (`(,key . ,command) prrr-diff--review-keys)
          (should (equal (list where key command)
                         (list where key (key-binding (kbd key))))))))))
```

In `test/prrr-test.el`, the command list of `prrr-test-require-prrr-autoloads-every-command` gains `prrr-comment prrr-reply`: its third `concat` line becomes `" prrr-stack-up prrr-stack-down prrr-queue-menu"` and a new line `" prrr-comment prrr-reply))"` follows.

Create `test/prrr-review-test.el` with the GPL header of `test/prrr-thread-test.el` (first line `;;; prrr-review-test.el --- ERT tests for commenting and the Pending Review  -*- lexical-binding: t -*-`), then:

```elisp
;;; Commentary:

;; The commenting commands in the fixture PR's Review Buffer, with the
;; Outbox sending synchronously to stubbed GitHub answers.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'prrr-test-helper)
(require 'prrr-diff-test)
(require 'prrr-review)
(require 'prrr-transient)

(defmacro prrr-review-test--with-buffer (answers &rest body)
  "Run BODY in the fixture PR's Review Buffer, its review data stored.
GitHub answers each request from ANSWERS, as for
`prrr-test-with-ghub-dispatch'.  The Outbox sends at once.  A capture
buffer the body opens is confirmed with `prrr-review-test--send'."
  (declare (indent 1))
  `(prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
     (prrr-test-with-outbox
       (cl-letf (((symbol-function 'forge-get-repository)
                  (lambda (&rest _) (forge-github-repository :id "r" :owner "example-org"
                                                             :name "example-repo"
                                                             :apihost "api.github.com"))))
         (prrr-test-with-ghub-dispatch ,answers
           (unwind-protect (progn ,@body)
             (dolist (buffer (buffer-list))
               (when (string-prefix-p "*prrr comment*" (buffer-name buffer))
                 (kill-buffer buffer)))))))))

(defun prrr-review-test--send (text)
  "Type TEXT in the open capture buffer and confirm it."
  (with-current-buffer (seq-find (lambda (buffer)
                                   (string-prefix-p "*prrr comment*" (buffer-name buffer)))
                                 (buffer-list))
    (insert text)
    (prrr-comment-confirm)))

(defun prrr-review-test--capture-header ()
  "Return the header of the open capture buffer."
  (with-current-buffer (seq-find (lambda (buffer)
                                   (string-prefix-p "*prrr comment*" (buffer-name buffer)))
                                 (buffer-list))
    (prrr-comment--header)))

(ert-deftest prrr-review-test-comment-joins-pending-review ()
  (prrr-review-test--with-buffer `((addPullRequestReviewThread . ,(prrr-test-fixture "add-thread")))
    (prrr-diff-test--goto-line "src/example.el" "+line twelve")
    (prrr-comment nil)
    (should (string-match-p "src/example\\.el:12 right" (prrr-review-test--capture-header)))
    (prrr-review-test--send "Nit.")
    (should (equal '(addPullRequestReviewThread) prrr-test-requests))
    (let ((comment (prrr-db-get 'review-comment "PRRC_kwDOexampleNew01")))
      (should (equal "Nit." (prrr-comment-body comment)))
      (should (eq 'pending (prrr-comment-state comment))))
    (should (eq (current-buffer) (get-buffer (prrr-diff--buffer-name (prrr-diff-test--pullreq)))))))

(ert-deftest prrr-review-test-comment-offline-shows-failed ()
  "Review Focus 1: a comment that cannot be sent shows, marked failed."
  (prrr-review-test--with-buffer '((addPullRequestReviewThread . (:error (error http 502))))
    (prrr-diff-test--goto-line "src/example.el" "+line twelve")
    (prrr-comment nil)
    (prrr-review-test--send "Nit.")
    (magit-refresh-buffer)
    (goto-char (point-min))
    (should (re-search-forward "^    example-me  [0-9-]+  pending  failed: GitHub returned HTTP 502$" nil t))
    (should (re-search-forward "^      Nit\\.$" nil t))))

(ert-deftest prrr-review-test-comment-immediate ()
  (prrr-review-test--with-buffer nil
    (prrr-test-with-rest-stub (prrr-test-fixture "publish-comment") captured
      (prrr-diff-test--goto-line "src/example.el" "+line twelve")
      (prrr-comment t)
      (should (string-match-p "publish now" (prrr-review-test--capture-header)))
      (prrr-review-test--send "Now.")
      (should (equal "/repos/example-org/example-repo/pulls/1/comments" (cadr captured)))
      (should (eq 'submitted (prrr-comment-state (prrr-db-get 'review-comment "PRRC_kwDOexampleNew03")))))))

(ert-deftest prrr-review-test-menu-switch-means-immediate ()
  (let ((transient-current-command 'prrr-menu))
    (cl-letf (((symbol-function 'transient-args) (lambda (_) '("--immediate"))))
      (should (prrr-review--immediate-p nil))))
  (should-not (prrr-review--immediate-p nil))
  (should (prrr-review--immediate-p '(4))))

(ert-deftest prrr-review-test-file-comment ()
  (prrr-review-test--with-buffer `((addPullRequestReviewThread . ,(prrr-test-fixture "add-thread")))
    (goto-char (oref (prrr-diff-test--file-section "README.md") start))
    (prrr-comment-file nil)
    (prrr-review-test--send "Split this file.")
    (should (equal "FILE" (alist-get 'subjectType
                                     (alist-get 'input (cdr (assq 'addPullRequestReviewThread prrr-test-variables))))))))

(ert-deftest prrr-review-test-reply-to-thread ()
  (prrr-review-test--with-buffer `((addPullRequestReviewThreadReply . ,(prrr-test-fixture "add-reply")))
    (let ((thread (car (oref (car (prrr-diff-test--hunks "src/example.el")) children))))
      (goto-char (oref thread start))
      (prrr-reply nil)
      (should (string-match-p "Reply on src/example\\.el, line 12" (prrr-review-test--capture-header)))
      (prrr-review-test--send "Agreed.")
      (should (equal "PRRT_kwDOexample0000001"
                     (alist-get 'pullRequestReviewThreadId
                                (alist-get 'input (cdr (assq 'addPullRequestReviewThreadReply
                                                              prrr-test-variables))))))
      (should (equal "PRR_kwDOexamplePending1"
                     (alist-get 'pullRequestReviewId
                                (alist-get 'input (cdr (assq 'addPullRequestReviewThreadReply
                                                              prrr-test-variables)))))))))

(ert-deftest prrr-review-test-reply-immediate-uses-database-id ()
  (prrr-review-test--with-buffer nil
    (prrr-test-with-rest-stub (prrr-test-fixture "publish-reply") captured
      (let ((thread (car (oref (car (prrr-diff-test--hunks "src/example.el")) children))))
        (goto-char (oref thread start))
        (prrr-reply t)
        (prrr-review-test--send "Done.")
        (should (equal "/repos/example-org/example-repo/pulls/1/comments/1001/replies"
                       (cadr captured)))))))

(ert-deftest prrr-review-test-edit-own-comment-only ()
  (prrr-review-test--with-buffer '((updatePullRequestReviewComment
                                    . ((data (updatePullRequestReviewComment (clientMutationId))))))
    (let* ((thread (car (oref (car (prrr-diff-test--hunks "src/example.el")) children)))
           (bob (car (oref thread children)))
           (mine (cadr (oref thread children))))
      (goto-char (oref bob start))
      (should-error (prrr-edit-comment) :type 'user-error)
      (goto-char (oref mine start))
      (prrr-edit-comment)
      (with-current-buffer (seq-find (lambda (buffer)
                                       (string-prefix-p "*prrr comment*" (buffer-name buffer)))
                                     (buffer-list))
        (should (equal "Yes, fixing." (buffer-string)))
        (erase-buffer))
      (prrr-review-test--send "Yes, fixed.")
      (should (equal "Yes, fixed." (prrr-comment-body (prrr-db-get 'review-comment
                                                                   "PRRC_kwDOexample0000002")))))))

(ert-deftest prrr-review-test-delete-own-comment ()
  (prrr-review-test--with-buffer '((deletePullRequestReviewComment
                                    . ((data (deletePullRequestReviewComment (clientMutationId))))))
    (let ((thread (car (oref (car (prrr-diff-test--hunks "src/example.el")) children))))
      (goto-char (oref (cadr (oref thread children)) start))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (prrr-delete-comment))
      (should-not (prrr-db-get 'review-comment "PRRC_kwDOexample0000002"))
      (should (prrr-db-get 'thread "PRRT_kwDOexample0000001")))))

(ert-deftest prrr-review-test-toggle-resolved ()
  (prrr-review-test--with-buffer '((resolveReviewThread . ((data (resolveReviewThread (clientMutationId))))))
    (let ((thread (car (oref (car (prrr-diff-test--hunks "src/example.el")) children))))
      (goto-char (oref thread start))
      (prrr-toggle-resolved)
      (should (equal '(resolveReviewThread) prrr-test-requests))
      (should (prrr-thread-resolved-p (prrr-db-get 'thread "PRRT_kwDOexample0000001"))))))

(ert-deftest prrr-review-test-resolve-refused ()
  (prrr-review-test--with-buffer nil
    (let ((thread (prrr-db-get 'thread "PRRT_kwDOexample0000001")))
      (setf (prrr-thread-resolvable-p thread) nil)
      (prrr-db-insert thread)
      (magit-refresh-buffer)
      (goto-char (oref (car (oref (car (prrr-diff-test--hunks "src/example.el")) children)) start))
      (should-error (prrr-toggle-resolved) :type 'user-error)
      (should-not prrr-test-requests))))

(ert-deftest prrr-review-test-discussion-comment ()
  (prrr-review-test--with-buffer '((addComment . ((data (addComment (clientMutationId))))))
    (let ((pulled nil))
      (cl-letf (((symbol-function 'forge-pull-topic) (lambda (topic) (interactive) (setq pulled topic))))
        (prrr-discussion-comment)
        (should-not (string-match-p "publish now\\|Pending Review" (prrr-review-test--capture-header)))
        (prrr-review-test--send "Thanks!")
        (should (equal '(addComment) prrr-test-requests))
        (should (equal prrr-diff-test--pr
                       (alist-get 'subjectId (alist-get 'input (cdr (assq 'addComment prrr-test-variables))))))
        (should pulled)))))

(ert-deftest prrr-review-test-suggest ()
  (prrr-review-test--with-buffer nil
    (prrr-diff-test--goto-line "src/example.el" "+line twelve")
    (prrr-comment-suggest nil)
    (with-current-buffer (seq-find (lambda (buffer)
                                     (string-prefix-p "*prrr comment*" (buffer-name buffer)))
                                   (buffer-list))
      (should (equal "```suggestion\nline twelve\n```\n" (buffer-string)))
      (prrr-comment-abort))
    (prrr-diff-test--goto-line "src/example.el" "-line 12")
    (should-error (prrr-comment-suggest nil) :type 'user-error)))

(ert-deftest prrr-review-test-keys-and-menus-agree ()
  "SPEC section 9: milestone 4's keys, in the buffer and the menu."
  (pcase-dolist (`(,key . ,command) prrr-diff--review-keys)
    (should (eq command (keymap-lookup prrr-diff-mode-map key)))
    (let ((suffix (transient-get-suffix 'prrr-menu key)))
      (should (eq command (plist-get (if (vectorp suffix) (aref suffix 2) (cdr suffix))
                                     :command)))))
  (let ((switch (transient-get-suffix 'prrr-menu "-i")))
    (should (equal "--immediate" (plist-get (if (vectorp switch) (aref switch 2) (cdr switch))
                                           :argument)))))

(provide 'prrr-review-test)
;;; prrr-review-test.el ends here
```

In the `Makefile`, `SRC` gains `prrr-review.el` after `prrr-diff.el`, and `TESTS` gains `test/prrr-review-test.el` after `test/prrr-thread-test.el`.

- [ ] **Step 3: Run them to verify they fail**

Run: `make test TESTS="test/prrr-review-test.el test/prrr-diff-test.el test/prrr-test.el"`
Expected: FAIL; `prrr-review` cannot be loaded.

- [ ] **Step 4: The commands**

Create `prrr-review.el` with the GPL header of `prrr-db.el` (first line `;;; prrr-review.el --- Commenting and the Pending Review  -*- lexical-binding: t -*-`), then:

```elisp
;;; Commentary:

;; The Review Buffer's commands that write (SPEC sections 7 and 9):
;; comment on a line, a range or a file, reply, edit, delete, resolve,
;; suggest, post a Discussion Comment, submit the Pending Review with
;; a Verdict or discard it, and act on the Outbox.  Each command reads
;; what is at point from `prrr-diff', asks for the text in a capture
;; buffer from `prrr-thread', and hands the write to the Outbox
;; (`prrr-sync-write'), which shows it at once and sends it in the
;; background.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'transient)
(require 'forge)
(require 'prrr-db)
(require 'prrr-state)
(require 'prrr-github)
(require 'prrr-sync)
(require 'prrr-thread)
(require 'prrr-diff)

(defun prrr-review--immediate-p (arg)
  "Non-nil when a comment command should publish at once.
That is when ARG, its prefix argument, is non-nil, or when it was run
from `prrr-menu' with the -i switch on (SPEC section 9)."
  (or (and arg t)
      (and (eq transient-current-command 'prrr-menu)
           (transient-arg-value "--immediate" (transient-args 'prrr-menu)))))

(defun prrr-review--write (pullreq kind payload)
  "Hand the write KIND with PAYLOAD to PULLREQ to the Outbox.
The current buffer refreshes as the write goes out."
  (prrr-sync-write (forge-get-repository pullreq) pullreq kind payload (current-buffer)))

(defun prrr-review--comment-on (anchor immediate body)
  "Capture a comment on ANCHOR and send it as a new Thread.
IMMEDIATE is the initial choice of Immediate Publish; BODY the initial
text."
  (let ((pullreq (prrr-diff-pullreq))
        (head (prrr-diff-head)))
    (prrr-comment-capture
     (prrr-state-anchor-label anchor)
     (lambda (text now)
       (prrr-review--write pullreq (if now 'publish 'thread)
                           (list :anchor anchor :body text :commit head)))
     :body body :immediate immediate)))

;;;###autoload
(defun prrr-comment (immediate)
  "Comment on the diff line at point, or on the region's lines.
The comment joins your Pending Review.  With IMMEDIATE, interactively
a prefix argument or the -i switch of `prrr-menu', it is published at
once; the capture buffer can switch either way."
  (interactive (list (prrr-review--immediate-p current-prefix-arg)))
  (prrr-review--comment-on (prrr-diff-anchor) immediate nil))

;;;###autoload
(defun prrr-comment-file (immediate)
  "Comment on the file at point as a whole: a File Comment.
IMMEDIATE is as for `prrr-comment'."
  (interactive (list (prrr-review--immediate-p current-prefix-arg)))
  (prrr-review--comment-on (prrr-diff-file-anchor) immediate nil))

;;;###autoload
(defun prrr-comment-suggest (immediate)
  "Suggest a change to the line at point, or to the region's lines.
The capture buffer starts with a suggestion block holding the lines,
to edit into what they should be.  IMMEDIATE is as for `prrr-comment'."
  (interactive (list (prrr-review--immediate-p current-prefix-arg)))
  (let ((anchor (prrr-diff-anchor)))
    (prrr-review--comment-on anchor immediate
                             (prrr-state-suggestion-body (prrr-diff-region-lines)))))

(defun prrr-review--thread ()
  "Return the Thread at point, or signal a `user-error'."
  (or (prrr-diff-thread-at-point) (user-error "No Thread here")))

;;;###autoload
(defun prrr-reply (immediate)
  "Reply to the Thread at point.
The reply joins your Pending Review; IMMEDIATE is as for `prrr-comment'."
  (interactive (list (prrr-review--immediate-p current-prefix-arg)))
  (let ((pullreq (prrr-diff-pullreq))
        (thread (prrr-review--thread)))
    (prrr-comment-capture
     (format "Reply on %s" (prrr-thread-label thread))
     (lambda (text now)
       (prrr-review--write pullreq (if now 'publish-reply 'reply)
                           (list :thread-id (prrr-thread-thread-id thread) :body text)))
     :immediate immediate)))

(defun prrr-review--own-comment ()
  "Return your comment at point, or signal a `user-error'."
  (let ((comment (or (prrr-diff-comment-at-point) (user-error "No comment here"))))
    (unless (equal (prrr-comment-author comment) (prrr-github-viewer))
      (user-error "Only your own comments can be changed"))
    comment))

;;;###autoload
(defun prrr-edit-comment ()
  "Edit your comment at point, pending or submitted."
  (interactive)
  (let ((pullreq (prrr-diff-pullreq))
        (comment (prrr-review--own-comment)))
    (prrr-comment-capture
     "Edit your comment"
     (lambda (text _now)
       (prrr-review--write pullreq 'edit (list :comment-id (prrr-comment-comment-id comment)
                                               :body text)))
     :body (prrr-comment-body comment) :immediate-allowed nil)))

;;;###autoload
(defun prrr-delete-comment ()
  "Delete your comment at point, pending or submitted, after confirmation."
  (interactive)
  (let ((pullreq (prrr-diff-pullreq))
        (comment (prrr-review--own-comment)))
    (when (y-or-n-p "Delete this comment? ")
      (prrr-review--write pullreq 'delete
                          (list :comment-id (prrr-comment-comment-id comment))))))

;;;###autoload
(defun prrr-discussion-comment ()
  "Write a Discussion Comment on the pull request; it is published at once."
  (interactive)
  (let ((pullreq (prrr-diff-pullreq)))
    (prrr-comment-capture
     (format "Discussion Comment on #%d" (oref pullreq number))
     (lambda (text _now) (prrr-review--write pullreq 'discussion (list :body text)))
     :immediate t :immediate-allowed nil)))

;;;###autoload
(defun prrr-toggle-resolved ()
  "Resolve the Thread at point, or unresolve it."
  (interactive)
  (let* ((pullreq (prrr-diff-pullreq))
         (thread (prrr-review--thread))
         (resolved (prrr-thread-resolved-p thread)))
    (cond ((prrr-state-local-id-p (prrr-thread-thread-id thread))
           (user-error "This Thread is not on GitHub yet"))
          ((not (prrr-thread-resolvable-p thread))
           (user-error "GitHub does not let you %s this Thread"
                       (if resolved "unresolve" "resolve"))))
    (prrr-review--write pullreq 'resolve (list :thread-id (prrr-thread-thread-id thread)
                                               :resolved (not resolved)))))

(provide 'prrr-review)
;;; prrr-review.el ends here
```


In `prrr.el`, after the `prrr-menu` autoload, add:

```elisp
(autoload 'prrr-comment "prrr-review" "Comment on the diff line at point, or on the region's lines." t)
(autoload 'prrr-comment-file "prrr-review" "Comment on the file at point as a whole." t)
(autoload 'prrr-comment-suggest "prrr-review" "Suggest a change to the line at point or the region's lines." t)
(autoload 'prrr-reply "prrr-review" "Reply to the Thread at point." t)
(autoload 'prrr-edit-comment "prrr-review" "Edit your comment at point." t)
(autoload 'prrr-delete-comment "prrr-review" "Delete your comment at point." t)
(autoload 'prrr-discussion-comment "prrr-review" "Write a Discussion Comment on the pull request." t)
(autoload 'prrr-toggle-resolved "prrr-review" "Resolve the Thread at point, or unresolve it." t)
```

- [ ] **Step 5: The Comment group of the menu**

In `prrr-transient.el`, add `(require 'prrr-review)` after `(require 'prrr-sync)` and replace `prrr-menu` with:

```elisp
;;;###autoload (autoload 'prrr-menu "prrr-transient" nil t)
(transient-define-prefix prrr-menu ()
  "Act on the Review Buffer (SPEC section 9).
Milestones 5 to 7 add the Range, Stack and Agent groups."
  [["Comment"
    ("-i" "publish immediately" "--immediate")
    ("c" "on line or region" prrr-comment)
    ("C" "on file" prrr-comment-file)
    ("r" "reply" prrr-reply)
    ("e" "edit" prrr-edit-comment)
    ("k" "delete" prrr-delete-comment)
    ("d" "discussion" prrr-discussion-comment)
    ("R" "resolve or unresolve" prrr-toggle-resolved)
    ("s" "suggest a change" prrr-comment-suggest)]]
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

- [ ] **Step 6: Run the tests to verify they pass**

Run: `make test`
Expected: all pass, `prrr-diff-test-keys-and-menu-agree` and the autoload tests included.

- [ ] **Step 7: Run all gates and commit**

```bash
make compile lint test
git add prrr-review.el prrr-diff.el prrr-transient.el prrr.el Makefile test/prrr-review-test.el test/prrr-diff-test.el test/prrr-test.el
git commit -m "feat(review): comment, reply, edit, delete, resolve, suggest and discuss from the Review Buffer"
```

---

### Task 13: Submit, discard and the Outbox commands

**Files:**
- Modify: `prrr-state.el` (new part `;;;; Submit` before `(provide 'prrr-state)`)
- Modify: `prrr-review.el` (new part `;;;; Submit and the Outbox` before `(provide 'prrr-review)`)
- Modify: `prrr-transient.el` (`prrr-submit`, `prrr-outbox`; `prrr-menu` gets the Review group)
- Modify: `prrr-diff.el` (`S` and `O` move from `prrr-diff--later-keys` to `prrr-diff--review-keys`)
- Modify: `prrr.el` (autoloads)
- Modify: `test/prrr-state-test.el`, `test/prrr-review-test.el`, `test/prrr-test.el`

**Interfaces:**
- Consumes: Task 12's `prrr-review--write`; Task 8's submit and discard writes; `prrr-sync-retry`, `prrr-sync-discard`, `prrr-sync-review-data`.
- Produces:
  - `(prrr-state-submit-problem VERDICT BODY PENDING)` → nil or a message; `(prrr-state-outbox-describe ROW)` → one line.
  - Commands `prrr-submit-approve`, `prrr-submit-request-changes`, `prrr-submit-comment`, `prrr-discard-pending`, `prrr-outbox-retry`, `prrr-outbox-discard` (ID).
  - Transients `prrr-submit` (`S`: `a r c k`) and `prrr-outbox` (`O`: `r k`).

- [ ] **Step 1: Write the failing tests**

Append to `test/prrr-state-test.el`, before `(provide 'prrr-state-test)`:

```elisp
;;;; Submit

(ert-deftest prrr-state-test-submit-problem ()
  (should-not (prrr-state-submit-problem 'approve "" 0))
  (should-not (prrr-state-submit-problem 'request-changes "" 2))
  (should-not (prrr-state-submit-problem 'comment "Looks fine." 0))
  (should (prrr-state-submit-problem 'request-changes "  " 0))
  (should (prrr-state-submit-problem 'comment "" 0)))

(ert-deftest prrr-state-test-outbox-describe ()
  (should (equal "comment on a.el:3 right: First line (failed: offline)"
                 (prrr-state-outbox-describe
                  (prrr-state-test--write "1" "PR_1" 'thread
                                          '(:body "First line\nsecond"
                                            :anchor (:path "a.el" :line 3 :side right))
                                          "offline"))))
  (should (equal "mark Viewed a.el"
                 (prrr-state-outbox-describe
                  (prrr-state-test--write "1" "PR_1" 'viewed '(:path "a.el" :viewed t))))))
```

In `test/prrr-review-test.el`, add before `prrr-review-test-keys-and-menus-agree` and replace that test with the last form:

```elisp
(ert-deftest prrr-review-test-submit-approve ()
  (prrr-review-test--with-buffer '((submitPullRequestReview . ((data (submitPullRequestReview (clientMutationId))))))
    (prrr-submit-approve)
    (should (string-match-p "Submit, approve: 1 pending comment" (prrr-review-test--capture-header)))
    (prrr-review-test--send "")
    (should (equal "APPROVE" (alist-get 'event (alist-get 'input (cdr (assq 'submitPullRequestReview prrr-test-variables))))))
    (should-not (prrr-db-get 'pending-review prrr-diff-test--pr))))

(ert-deftest prrr-review-test-submit-asks-about-agent-comments ()
  (prrr-review-test--with-buffer '((submitPullRequestReview . ((data (submitPullRequestReview (clientMutationId))))))
    (let ((comment (prrr-db-get 'review-comment "PRRC_kwDOexample0000006")))
      (setf (prrr-comment-agent-p comment) t)
      (prrr-db-insert comment))
    (prrr-submit-comment)
    (should (string-match-p "1 by an agent" (prrr-review-test--capture-header)))
    (cl-letf (((symbol-function 'yes-or-no-p) #'ignore))
      (should-error (prrr-review-test--send "See comments.") :type 'user-error))
    (should-not prrr-test-requests)))

(ert-deftest prrr-review-test-request-changes-needs-text ()
  (prrr-review-test--with-buffer nil
    (prrr-db-delete 'review-comment :comment-id "PRRC_kwDOexample0000006")
    (prrr-submit-request-changes)
    (should-error (prrr-review-test--send "") :type 'user-error)
    (should-not prrr-test-requests)))

(ert-deftest prrr-review-test-discard-pending ()
  (prrr-review-test--with-buffer '((deletePullRequestReview . ((data (deletePullRequestReview (clientMutationId))))))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (prrr-discard-pending))
    (should (equal '(deletePullRequestReview) prrr-test-requests))
    (should-not (prrr-db-get 'pending-review prrr-diff-test--pr))
    (should-not (prrr-db-get 'review-comment "PRRC_kwDOexample0000006"))))

(ert-deftest prrr-review-test-outbox-retry-and-discard ()
  (prrr-review-test--with-buffer '((addPullRequestReviewThread . (:error (error http 502))))
    (prrr-diff-test--goto-line "src/example.el" "+line twelve")
    (prrr-comment nil)
    (prrr-review-test--send "Nit.")
    (prrr-outbox-retry)
    (should (equal '(addPullRequestReviewThread addPullRequestReviewThread) prrr-test-requests))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _) (car (car choices)))))
      (goto-char (point-min))
      (call-interactively #'prrr-outbox-discard))
    (should-not (prrr-db-outbox-rows prrr-diff-test--pr))))

(ert-deftest prrr-review-test-keys-and-menus-agree ()
  "SPEC section 9: milestone 4's keys, in the buffer and the menus."
  (pcase-dolist (`(,key . ,command) prrr-diff--review-keys)
    (should (eq command (keymap-lookup prrr-diff-mode-map key)))
    (let ((suffix (transient-get-suffix 'prrr-menu key)))
      (should (eq command (plist-get (if (vectorp suffix) (aref suffix 2) (cdr suffix))
                                     :command)))))
  (let ((switch (transient-get-suffix 'prrr-menu "-i")))
    (should (equal "--immediate" (plist-get (if (vectorp switch) (aref switch 2) (cdr switch))
                                           :argument))))
  (pcase-dolist (`(,prefix ,key ,command)
                 '((prrr-submit "a" prrr-submit-approve)
                   (prrr-submit "r" prrr-submit-request-changes)
                   (prrr-submit "c" prrr-submit-comment)
                   (prrr-submit "k" prrr-discard-pending)
                   (prrr-outbox "r" prrr-outbox-retry)
                   (prrr-outbox "k" prrr-outbox-discard)))
    (let ((suffix (transient-get-suffix prefix key)))
      (should (eq command (plist-get (if (vectorp suffix) (aref suffix 2) (cdr suffix))
                                     :command))))))
```

In `test/prrr-test.el`, the line `" prrr-comment prrr-reply))"` becomes `" prrr-comment prrr-reply prrr-submit prrr-outbox))"`.

- [ ] **Step 2: Run them to verify they fail**

Run: `make test TESTS="test/prrr-state-test.el test/prrr-review-test.el test/prrr-test.el"`
Expected: FAIL; `prrr-submit-approve` is void and `S` is `undefined`.

- [ ] **Step 3: Implement**

Insert before `(provide 'prrr-state)`:

```elisp
;;;; Submit

(defun prrr-state-submit-problem (verdict body pending)
  "Return why a Submit with VERDICT, summary BODY and PENDING comments is refused.
nil when it may go.  GitHub wants a summary or a comment for a review
that requests changes or only comments."
  (when (and (memq verdict '(request-changes comment))
             (string-empty-p (string-trim body))
             (zerop pending))
    (if (eq verdict 'request-changes)
        "Requesting changes needs a summary or a comment"
      "A comment review needs a summary or a comment")))

(defun prrr-state-outbox-describe (row)
  "Describe the queued write ROW in one line, for choosing it."
  (let* ((payload (prrr-outbox-payload row))
         (body (car (split-string (or (plist-get payload :body) "") "\n")))
         (anchor (plist-get payload :anchor)))
    (concat (pcase (prrr-outbox-kind row)
              ('thread (format "comment on %s" (prrr-state-anchor-label anchor)))
              ('publish (format "comment published on %s" (prrr-state-anchor-label anchor)))
              ((or 'reply 'publish-reply) "reply")
              ('edit "edit")
              ('delete "delete a comment")
              ('resolve (if (plist-get payload :resolved) "resolve a Thread" "unresolve a Thread"))
              ('viewed (format "%s %s" (if (plist-get payload :viewed) "mark Viewed" "unmark Viewed")
                               (plist-get payload :path)))
              ('discussion "Discussion Comment")
              ('submit (format "submit (%s)" (plist-get payload :verdict)))
              ('discard "discard the Pending Review")
              (kind (symbol-name kind)))
            (and (not (string-empty-p body)) (format ": %s" (truncate-string-to-width body 40 nil nil "…")))
            (and (prrr-outbox-last-error row) (format " (failed: %s)" (prrr-outbox-last-error row))))))
```

Insert before `(provide 'prrr-review)`:

```elisp
;;;; Submit and the Outbox

(defun prrr-review--pending (data)
  "Return the pending comments of the review DATA."
  (seq-filter (lambda (comment) (eq (prrr-comment-state comment) 'pending))
              (plist-get data :comments)))

(defun prrr-review--submit (verdict)
  "Capture a summary and submit the Pending Review with VERDICT.
VERDICT is `approve', `request-changes' or `comment'.  The header
counts the pending comments and those an agent wrote; Submit asks
again when there are agent comments (SPEC section 7)."
  (let* ((pullreq (prrr-diff-pullreq))
         (head (prrr-diff-head))
         (pending (prrr-review--pending (prrr-sync-review-data (oref pullreq their-id))))
         (agents (seq-count #'prrr-comment-agent-p pending)))
    (prrr-comment-capture
     (format "Submit, %s: %d pending comment%s%s"
             (pcase verdict
               ('approve "approve")
               ('request-changes "request changes")
               ('comment "comment"))
             (length pending) (if (= (length pending) 1) "" "s")
             (if (> agents 0) (format ", %d by an agent" agents) ""))
     (lambda (text _now)
       (when-let ((problem (prrr-state-submit-problem verdict text (length pending))))
         (user-error "%s" problem))
       (when (and (> agents 0)
                  (not (yes-or-no-p (format "Submit %d comment%s an agent wrote? "
                                            agents (if (= agents 1) "" "s")))))
         (user-error "Not submitted"))
       (prrr-review--write pullreq 'submit (list :verdict verdict :body text :commit head)))
     :immediate-allowed nil :allow-empty t)))

;;;###autoload
(defun prrr-submit-approve ()
  "Submit your Pending Review, approving the pull request."
  (interactive)
  (prrr-review--submit 'approve))

;;;###autoload
(defun prrr-submit-request-changes ()
  "Submit your Pending Review, requesting changes."
  (interactive)
  (prrr-review--submit 'request-changes))

;;;###autoload
(defun prrr-submit-comment ()
  "Submit your Pending Review as comments, without a Verdict for merging."
  (interactive)
  (prrr-review--submit 'comment))

;;;###autoload
(defun prrr-discard-pending ()
  "Discard your Pending Review and its comments, after confirmation."
  (interactive)
  (let* ((pullreq (prrr-diff-pullreq))
         (data (prrr-sync-review-data (oref pullreq their-id)))
         (count (length (prrr-review--pending data))))
    (unless (or (plist-get data :pending-review) (> count 0))
      (user-error "You have no Pending Review on this pull request"))
    (when (yes-or-no-p (format "Discard your Pending Review and its %d comment%s? "
                               count (if (= count 1) "" "s")))
      (prrr-review--write pullreq 'discard nil))))

;;;###autoload
(defun prrr-outbox-retry ()
  "Send this pull request's failed writes again now."
  (interactive)
  (let ((pullreq (prrr-diff-pullreq)))
    (prrr-sync-retry (oref pullreq their-id) (current-buffer))
    (message "Sending the Outbox again")))

(defun prrr-review--read-write (data)
  "Return the id of one of the queued writes of the review DATA.
The write of the comment or Thread at point, else one read with
completion."
  (let* ((writes (plist-get data :writes))
         (at-point (or (let ((comment (prrr-diff-comment-at-point)))
                         (and comment (gethash (prrr-comment-comment-id comment) writes)))
                       (let ((thread (prrr-diff-thread-at-point)))
                         (and thread (gethash (prrr-thread-thread-id thread) writes))))))
    (if at-point
        (prrr-outbox-id at-point)
      (let ((choices (mapcar (lambda (row) (cons (prrr-state-outbox-describe row)
                                                 (prrr-outbox-id row)))
                             (or (plist-get data :outbox)
                                 (user-error "The Outbox of this pull request is empty")))))
        (cdr (assoc (completing-read "Discard write: " choices nil t) choices))))))

;;;###autoload
(defun prrr-outbox-discard (id)
  "Drop the queued write ID of this pull request, after confirmation.
Interactively, the write of the comment or Thread at point, else one
read with completion.  Writes that need what it creates go too."
  (interactive
   (list (prrr-review--read-write
          (prrr-sync-review-data (oref (prrr-diff-pullreq) their-id)))))
  (when (yes-or-no-p "Drop this unsent write? ")
    (let ((count (prrr-sync-discard id)))
      (message "Dropped %d write%s" count (if (eql count 1) "" "s")))))
```


In `prrr-transient.el`, insert before `prrr-menu`:

```elisp
;;;###autoload (autoload 'prrr-submit "prrr-transient" nil t)
(transient-define-prefix prrr-submit ()
  "Submit your Pending Review with a Verdict, or discard it (SPEC section 9)."
  [["Submit"
    ("a" "approve" prrr-submit-approve)
    ("r" "request changes" prrr-submit-request-changes)
    ("c" "comment" prrr-submit-comment)]
   ["Pending Review"
    ("k" "discard" prrr-discard-pending)]])

;;;###autoload (autoload 'prrr-outbox "prrr-transient" nil t)
(transient-define-prefix prrr-outbox ()
  "Act on this pull request's unsent writes (SPEC section 9)."
  ["Outbox"
   ("r" "retry now" prrr-outbox-retry)
   ("k" "discard one" prrr-outbox-discard)])
```

In `prrr-menu`, the first group row becomes `[["Comment" …] ["Review" ("S" "submit or discard…" prrr-submit) ("O" "outbox…" prrr-outbox)]]`, that is:

```elisp
;;;###autoload (autoload 'prrr-menu "prrr-transient" nil t)
(transient-define-prefix prrr-menu ()
  "Act on the Review Buffer (SPEC section 9).
Milestones 5 to 7 add the Range, Stack and Agent groups."
  [["Comment"
    ("-i" "publish immediately" "--immediate")
    ("c" "on line or region" prrr-comment)
    ("C" "on file" prrr-comment-file)
    ("r" "reply" prrr-reply)
    ("e" "edit" prrr-edit-comment)
    ("k" "delete" prrr-delete-comment)
    ("d" "discussion" prrr-discussion-comment)
    ("R" "resolve or unresolve" prrr-toggle-resolved)
    ("s" "suggest a change" prrr-comment-suggest)]
   ["Review"
    ("S" "submit or discard…" prrr-submit)
    ("O" "outbox…" prrr-outbox)]]
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

In `prrr-diff.el`, `prrr-diff--review-keys` gains `("S" . prrr-submit) ("O" . prrr-outbox)` after `("s" . prrr-comment-suggest)`, and `prrr-diff--later-keys` becomes `'("D" "." "m" ">" "<" "@" "L")`.

In `prrr.el`, after the `prrr-toggle-resolved` autoload, add:

```elisp
(autoload 'prrr-submit "prrr-transient" "Submit your Pending Review with a Verdict, or discard it." t)
(autoload 'prrr-outbox "prrr-transient" "Act on this pull request's unsent writes." t)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: all pass.

- [ ] **Step 5: Run all gates and commit**

```bash
make compile lint test
git add prrr-state.el prrr-review.el prrr-transient.el prrr-diff.el prrr.el test/prrr-state-test.el test/prrr-review-test.el test/prrr-test.el
git commit -m "feat(review): submit with a Verdict, discard, and the Outbox menu"
```

---

### Task 14: README, SPEC corrections, and the milestone's close

**Files:**
- Modify: `README.md`
- Modify: `SPEC.md` (sections 1, 2, 3, 4, 7)

**Interfaces:**
- Consumes: every user-visible name from Tasks 6-13.
- Produces: the README sections below; SPEC matches what was built.

- [ ] **Step 1: Update `README.md`**

1. In the second paragraph, replace "Upcoming milestones add line and range comments, a pending review submitted in one batch, and "what changed since my last review"." with:

```markdown
Comment on lines, ranges and files, reply, suggest changes, and submit
your pending review with a verdict; what you write shows at once and is
never lost to a dropped connection. The next milestone adds "what
changed since my last review".
```

2. The Status note becomes:

```markdown
> **Status:** early development. The Review Queue, the Review Buffer,
> commenting and submitting work. Ranges and Stacks inside the Review
> Buffer are next. See the milestones in [`SPEC.md`](SPEC.md#15-milestones).
```

3. In "Keys in the Review Buffer", add these rows after the `v` row:

```markdown
| `c`       | `prrr-comment`                                      | Comment on the line or the region's lines  |
| `C`       | `prrr-comment-file`                                 | Comment on the whole file                  |
| `r`       | `prrr-reply`                                        | Reply to the thread at point               |
| `e` / `k` | `prrr-edit-comment` / `prrr-delete-comment`         | Edit or delete your comment at point       |
| `d`       | `prrr-discussion-comment`                           | Comment on the pull request itself         |
| `R`       | `prrr-toggle-resolved`                              | Resolve or unresolve the thread at point   |
| `s`       | `prrr-comment-suggest`                              | Suggest a change to the line or region     |
| `S`       | `prrr-submit`                                       | Submit your review, or discard it          |
| `O`       | `prrr-outbox`                                       | Retry or drop what has not reached GitHub  |
```

and replace the closing sentence "Keys that later milestones use for commenting and reviewing (`c`, `r`, `e`, `k`, `s`, `S`, …) do nothing yet." with "Keys that later milestones use (`D`, `.`, `m`, `>`, `<`, `@`, `L`) do nothing yet."

4. Insert a new section after the Review Buffer's key table and before "## Development":

```markdown
## Commenting and reviewing

Put point on a line of the diff and press `c`, or mark lines of one hunk
first to comment on all of them. A removed line is commented on as the
old file's line, any other line as the new file's. `C` comments on the
file at point as a whole, `r` replies to the thread at point, and `s`
starts a comment with a GitHub suggestion block holding the lines, to
edit into what they should say. A suggestion shows in the thread as a
small diff against those lines.

Each opens a buffer to write in, at the bottom of the frame. `C-c C-c`
sends, `C-c C-k` cancels, and `C-c C-i` switches between your pending
review and publishing this one comment at once. Comments go to your
pending review, which only you see until you submit it; with `C-u`
before `c`, `C`, `r` or `s`, or the `-i` switch in the `?` menu, the
comment is published at once. `d` writes a comment on the pull request
itself, which is always published at once.

`e` and `k` edit and delete your own comments, pending or published.
`R` resolves or unresolves the thread at point, when GitHub lets you.

`S` opens the submit menu: `a` approve, `r` request changes, `c`
comment, each asking for an optional summary first, or `k` to discard
the pending review and its comments. Requesting changes or commenting
needs a summary or at least one comment. Submitting moves the pull
request to Served in the Review Queue.

Everything you write shows at once, marked `unsent` until GitHub has
it. prrr sends one change at a time, a second apart, in the order you
made them, and never more than 80 new comments a minute, as GitHub
asks. When GitHub cannot be reached or refuses, the change stays,
marked `failed:` with GitHub's reason, and the header counts it. prrr
tries it again with your next change on that pull request, when the
buffer refetches, or when you press `O r`; `O k` drops one, along with
any reply that needs it. Until a failed change goes through, the later
changes to that pull request wait behind it. When GitHub rate-limits
you, the header says until when, and prrr waits. Unsent changes are
kept in prrr's database, so they survive restarting Emacs.

Publishing a single comment at once while you have a pending review
depends on GitHub accepting it; if GitHub refuses, the comment stays
in the Outbox with GitHub's reason, and you can add it to your pending
review instead.
```

5. In "Options", the `prrr-sync-timeout` row's meaning becomes "Seconds a pull, refetch or change waits for GitHub before `offline`".

6. After the Options table, extend "prrr keeps its data in its own SQLite file and never writes to forge's database." with " Upgrading prrr may drop that data, which prrr fetches again; unsent comments are always kept."

- [ ] **Step 2: Correct `SPEC.md`**

1. Section 1, "Supported Emacs and packages": replace "ghub is reached only through forge." with "ghub is reached through forge, except that the three mutations whose answer prrr reads use `ghub-query` with forge's token (section 4)."
2. Section 2, table: the `prrr-sync.el` row's purpose becomes "Freshness rules and the Outbox: pull queue inputs, refetch per PR, every write to GitHub with its order, spacing, retry and reconciliation, Bookmark and ref pinning." and its dependencies "prrr-db, prrr-github, prrr-state, forge, magit-mode". The `prrr-thread.el` row's purpose becomes "Rendering Threads, Review Comments, File Comments, unsent and failed writes and suggestions; the comment capture buffer." and its dependencies "magit-section, magit-diff, prrr-db, prrr-state". The `prrr-review.el` row's purpose becomes "The commands that write: comment, reply, edit, delete, resolve, suggest, Discussion Comment, Immediate Publish, Submit with Verdict, discard, Outbox retry and discard." and its dependencies "prrr-sync, prrr-thread, prrr-diff, prrr-state". Under "Rules", add: "- Every write to GitHub goes through the Outbox (`prrr-sync-write`): a command describes the write, the Outbox sends it."
3. Section 3, table: the `thread` columns gain `resolvable-p` after `resolved-p`, with the note "`resolvable-p`: GitHub lets the viewer resolve it, or unresolve it when resolved."; the `review-comment` columns gain `database-id` at the end, and its note becomes "`state`: `pending` or `submitted` (GitHub's). `local-state`: `sent`, or `proposed` (milestone 7). `database-id`: GitHub's numeric id, which REST replies need." The `outbox` note becomes "Writes GitHub has not accepted, in id order; `kind` and `payload` as `prrr-state-outbox-kinds` describes. The review tables above hold only what GitHub sent or accepted." The `schema-version` note gains "Version 2 since milestone 4."
4. Section 4, the mutation table's "Create Pending Review" call becomes "`addPullRequestReview(pullRequestId, commitOID)` with no event, `commitOID` being the head the user commented on; first query for an existing PENDING review and reuse it", and the "Submit" call gains "; without a Pending Review, `addPullRequestReview` with the event". After the table add:

```markdown
**Answers prrr reads.** `forge-mutate` selects only `clientMutationId`,
so creating the Pending Review, a Thread and a reply goes through
`ghub-query` with forge's token, selecting the new ids. GitHub's answer
to Immediate Publish names the comment but not its Thread; the next
refetch does. An HTTP 422 is GitHub refusing a write and is an error,
not `offline`. Whether GitHub accepts Immediate Publish while the
viewer has a Pending Review is unverified.
```

and in "Limits", after "waits at least one second between them" add "(the Outbox, section 7)".
5. Section 7: replace the paragraphs "Write path (optimistic)" and "Reconciliation" with:

```markdown
**Write path (optimistic).** Every new comment, reply, edit, delete,
resolve, Submit, discard and Viewed change is a write handed to the
Outbox (`prrr-sync-write`), stored at once in `outbox`. The Review
Buffer shows the stored rows with the queued writes applied
(`prrr-state-outbox-view`): unsent ones with the `prrr-unsent` face,
failed ones with the `prrr-failed` face and GitHub's message, and the
header counts both. The Outbox sends one mutation at a time, at least a
second apart, at most 80 content creations a minute, each PR's writes
in order; a failed write holds back its PR's later writes and is
retried on the PR's next write or refetch and through
`prrr-outbox-retry`, or dropped with `prrr-outbox-discard`, which also
drops the writes that need it. A rate limit pauses the Outbox until it
resets. Success stores GitHub's rows and renames the write's local ids
in the PR's queued writes, so a reply to a Thread not yet sent goes
out once the Thread has GitHub's id. Edit or delete of a comment whose
own write is still queued changes or drops that write.

**Reconciliation.** On refetch, GitHub's rows replace every stored
Thread, comment, Pending Review and Viewed flag of the PR; queued
writes, which live only in `outbox`, survive and are re-attempted
against the current pending review id. An answer that a write of the
PR may have raced (one succeeded since the refetch started, or one is
being sent) is not stored; the Outbox refetches the PR once it has
nothing more to send to it. Comments added from the web appear like
any other.
```

In "Pending Review lifecycle", replace "Submitting or discarding touches the PR (moves it to Served)." with "Submitting touches the PR (moves it to Served); discarding does not, since GitHub then records no review."

- [ ] **Step 3: Run all gates and commit**

```bash
make compile lint test
git add README.md SPEC.md
git commit -m "docs: commenting and reviewing in the README; SPEC matches the Outbox as built"
```

- [ ] **Step 4: Close the milestone**

Close the milestone-4 task beads and the epic (`bd close prrr-qqu.1 … prrr-qqu.14`, then `bd close prrr-qqu`), run `bd ready`, and report what remains: `prrr-knu.8`, `prrr-knu.9`, `prrr-knu.10` and `prrr-opy` are not part of this plan.
