# prrr 🐱 — design specification

prrr is an Emacs package for reviewing GitHub pull requests on top of magit
and forge. This document is the approved design: every architectural
question was resolved through the wayfinder map (beads epic `prrr-t9q`;
each decision's full text is in the notes of the child issue it cites) and
the research findings under `docs/research/`. Vocabulary is defined in
`CONTEXT.md` and used here without redefinition.

Status: draft for human review, 2026-10-10.

## 1. Goals and scope

**Goal.** Review GitHub PRs entirely inside Emacs, at least as well as the
GitHub web UI: see the PRs that need you in magit-status, open one, read the
diff with existing Threads inline, leave line, range, and file comments,
reply, look at what changed since you last reviewed, and submit a Verdict.

**Non-negotiable qualities** (map Notes):

1. Diff render performance. A 400-file diff opens in under 100 ms; a
   2,500-file diff in under 400 ms. Files fold, Viewed files fold away,
   jumping between files is one key.
2. Every action has a mnemonic single key and a transient menu that mirrors
   those keys exactly.
3. Default workflow is a server-side Pending Review with batched Submit;
   Immediate Publish is an explicit override per comment.
4. Only forge's public API is used (its EIEIO classes read with `oref`,
   `forge-get-*`, `forge-pull`, `forge-query`, `forge-rest`,
   `magit-add-section-hook`). No `forge--` symbols, no changes to forge's
   database. prrr keeps its own SQLite database.
5. PR Stacks are first-class for authors and reviewers.
6. Agents integrate through a public API in both directions; no agent code
   ships in the package.
7. The project is open source: GPL-3.0-or-later, MELPA-ready headers, no
   personal paths or tokens in the repository.

**Out of scope** (map): any forge other than GitHub; issues and
discussions; a cross-repo Review Queue (current repository only in v1);
AI-assisted review itself; upstreaming into forge; merging PRs
(`forge-merge` exists); reactions; notifications (forge's notification
support stands).

**Supported Emacs and packages.** Emacs 29.1 or later (30 recommended; the
built-in `treesit` is required for syntax highlighting and absent on 28),
magit 4.7 or later, forge 0.5 or later (any 2026 build; forge itself
requires emacsql 4.4, ghub 5.3, transient 0.13, compat 31), emacsql 4.4,
transient 0.13 or later, compat 31. ghub is reached through forge, except that the three mutations whose
answer prrr reads use `ghub-query` with forge's token (section 4).

## 2. Architecture

One package, `prrr`, split into focused files. Each file has one purpose and
depends only on the files above it.

| File                | Purpose                                                                                                                      | Depends on                             |
|---------------------|------------------------------------------------------------------------------------------------------------------------------|----------------------------------------|
| `prrr.el`           | Package entry: `defgroup`, the commands shared by the Review Queue and Review Buffer (`prrr-open-topic`, `prrr-browse`, `prrr-checkout`, `prrr-review`). Loads nothing else; every command is autoloaded. Options that belong to one file are defined in that file. | nothing at load time |
| `prrr-db.el`        | SQLite schema, connection, struct types, CRUD.                                                                               | emacsql                                |
| `prrr-github.el`    | Every GitHub call: GraphQL queries and mutations, REST calls, pagination, rate-limit pauses, response decoding into structs. | forge-query, forge-rest, ghub, prrr-db |
| `prrr-sync.el`      | Freshness rules and the Outbox: pull queue inputs, refetch per PR, every write to GitHub with its order, spacing, retry and reconciliation, Bookmark and ref pinning. | prrr-db, prrr-github, prrr-state, forge, magit-mode |
| `prrr-state.el`     | Pure functions: Review State, Queue Group membership, FIFO ordering, Stack detection, line mapping between Ranges.           | prrr-db structs only                   |
| `prrr-queue.el`     | The Review Queue section in magit-status and its keymap, `prrr-queue-mode` and the `prrr-queue` command.                                                                     | prrr-state, prrr-sync, forge objects   |
| `prrr-diff.el`      | The Review Buffer major mode: lazy file sections, the hunk washer with Thread children, folding, Viewed, refresh.            | magit-diff, magit-section, prrr-state, prrr-thread, prrr-sync (loads prrr-treesit when a Review Buffer starts) |
| `prrr-thread.el`    | Rendering Threads, Review Comments, File Comments, unsent and failed writes and suggestions; the comment capture buffer. | magit-section, magit-diff, prrr-db, prrr-state |
| `prrr-range.el`     | Range commands, switching with point kept, since-review and since-opened starts, fetching a missing start, `prrr-mark-seen`. | prrr-state, prrr-sync, prrr-diff       |
| `prrr-review.el`    | The commands that write: comment, reply, edit, delete, resolve, suggest, Discussion Comment, Immediate Publish, Submit with Verdict, discard, Outbox retry and discard. | prrr-sync, prrr-thread, prrr-diff, prrr-state |
| `prrr-stack.el`     | Stack navigation in the Review Queue and the Review Buffer.                                                                  | prrr-state, prrr-queue, prrr-diff      |
| `prrr-treesit.el`   | Deferred per-file tree-sitter highlighting.                                                                                  | prrr-diff, treesit                     |
| `prrr-api.el`       | The public `prrr-api-*` functions, hooks, JSON export and import.                                                            | prrr-review, prrr-range                |
| `prrr-agent.el`     | `prrr-send-to-agent`, the Markdown payload, the default invoke function.                                                     | prrr-api                               |
| `prrr-transient.el` | All transient prefixes.                                                                                                      | every command file                     |

Rules:

- Pure logic lives in `prrr-state.el` with no buffer or network access, so
  the Review State, ordering, Stack, and line-mapping rules are unit-tested
  against fixtures.
- Nothing outside `prrr-github.el` builds a query or touches ghub.
- Nothing outside `prrr-db.el` writes SQL.
- Every write to GitHub goes through the Outbox (`prrr-sync-write`): a command
  describes the write, the Outbox sends it.
- Buffers never hold state that the database does not: a Review Buffer is a
  view over database rows plus local git.
- `prrr-thread.el` renders and `prrr-diff.el` places: a Thread's look does
  not depend on the diff, so the capture buffer of milestone 4 takes its
  anchor as an argument.

## 3. Data model and database (prrr-t9q.7)

Plain emacsql tables, `cl-defstruct` rows, one SQLite file for all
repositories at `prrr-database-file` (default `prrr-database.sqlite` under
`user-emacs-directory`). Primary keys are GitHub node ids. Forge's
repository id and the PR number are secondary columns used only to join to
forge objects (forge's own `id` is a composite, not the node id; its
`their-id` slot is the node id).

| Table            | Columns (PK first)                                                                                                                                  | Notes                                                                                                                                                                                                                                                     |
|------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `pullreq-meta`   | pr-id, forge-repo-id, number, head-oid, review-requests, latest-reviews, viewer-latest-review, viewer-latest-review-request, created-at, fetched-at | `review-requests`: list of `(kind name)` with kind `user` or `team`. `latest-reviews`: list of `(login state submitted-at commit-oid on-behalf-of-slugs)`. `viewer-latest-review`: `(state submitted-at commit-oid)` or nil. Everything the Review Queue needs. |
| `thread`         | thread-id, pr-id, path, line, start-line, side, start-side, subject-type, outdated-p, resolved-p, resolvable-p, original-line, original-commit, fetched-at        | `subject-type` is `line` or `file`. `resolvable-p`: GitHub lets the viewer resolve it, or unresolve it when resolved.                                                                                                                                                                                                                       |
| `review-comment` | comment-id, thread-id, pr-id, author, body, created-at, updated-at, reply-to, review-id, state, local-state, agent-p, database-id                                | `state`: `pending` or `submitted` (GitHub's). `local-state`: `sent`, or `proposed` (milestone 7). `database-id`: GitHub's numeric id, which REST replies need.                                                                                                                                                             |
| `pending-review` | pr-id, review-id, commit-oid, body, created-at                                                                                                      | At most one per PR for the viewer.                                                                                                                                                                                                                        |
| `viewed`         | (pr-id, path), state, fetched-at                                                                                                                    | `state`: `viewed`, `unviewed`, `dismissed`. Shown and toggled in every Range.                                                                                                                                                                             |
| `team`           | combined-slug, org, slug, fetched-at                                                                                                                | The viewer's Teams.                                                                                                                                                                                                                                       |
| `pr-bookmark`    | pr-id, last-opened-head-oid, last-opened-at                                                                                                         | Local "since I last looked": the head shown when the Review Buffer was last left, a review submitted, or `prrr-mark-seen` run.                                                                                                                          |
| `outbox`         | id, pr-id, kind, payload, created-at, attempts, last-error                                                                                          | Writes GitHub has not accepted, in id order; `kind` and `payload` as `prrr-state-outbox-kinds` describes. The review tables above hold only what GitHub sent or accepted.                                                                                                                                                                                                                             |
| `schema-version` | version                                                                                                                                             | Before 1.0, a mismatch drops and recreates every table except `outbox`, whose rows are shown to the user first. Version 2 since milestone 4.                                                                                                                                           |

Rows are plain structs (`prrr-thread`, `prrr-comment`, and so on) and are
the values the API returns.

## 4. GitHub access (prrr-t9q.2, prrr-t9q.3, prrr-t9q.4)

All calls go through `forge-query` and `forge-rest` so authentication,
host, and the repository come from forge. Findings with exact fields, costs,
and the unverified items are in `docs/research/`; the spec fixes the choices.

**Identity.** The viewer login is read from the `github.user` git config
(forge's own convention), with `prrr-github-user` as an override.

**Queue inputs: one GraphQL query per repository** (`prrr-pull`), paging
`pullRequests(states: OPEN, first: 100)` and selecting per PR: `id number
headRefOid createdAt isDraft author { login } reviewRequests(first: 50) {
requestedReviewer { ... on User { login } ... on Team { combinedSlug } } }
latestReviews(first: 50) { author { login } state submittedAt commit { oid }
onBehalfOf(first: 10) { nodes { combinedSlug } } } viewerLatestReview { state
submittedAt commit { oid } } viewerLatestReviewRequest { login }`. Stored in
`pullreq-meta`. Draft, author, assignees, base-ref, head-ref, head-rev, and
cross-repo-p come from forge's `forge-pullreq` object (research 04, section
1); forge drops Team requests and forgets satisfied ones, which is why
prrr fetches requests itself.

**Teams.** `viewer { organizations(first: 100) { nodes { login
teams(first: 100, userLogins: [$me]) { nodes { slug combinedSlug } } } } }`
into `team`. Fetched on first use, by `prrr-refresh-teams`, and
automatically when older than a day.

**Per-PR review data** (Review Buffer open and the refetch chord), one query:
`reviewThreads(first: 100)` with `id path line startLine diffSide
startDiffSide originalLine isOutdated isResolved subjectType
viewerCanResolve viewerCanUnresolve comments(first: 100) { id author { login }
body createdAt lastEditedAt replyTo { id } state pullRequestReview { id }
originalCommit { oid } }`, plus `reviews(first: 5, states: [PENDING],
author: $me) { id commit { oid } body createdAt comments(first: 100) {...} }`,
plus `files(first: 100) { path viewerViewedState }`, plus `headRefOid`.
Costs 1 point per page (research 03, section 1). Threads with more than 100
comments page through `node(id:)`.

**Mutations** (GraphQL unless noted):

| Action                                  | Call                                                                                                                                               |
|-----------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------|
| Create Pending Review                   | `addPullRequestReview(pullRequestId, commitOID)` with no event, `commitOID` being the head the user commented on; first query for an existing PENDING review and reuse it                                       |
| Add Thread (line, range, file)          | `addPullRequestReviewThread(pullRequestReviewId, path, body, line, side[, startLine, startSide][, subjectType: FILE])`                             |
| Reply inside Pending Review             | `addPullRequestReviewThreadReply(pullRequestReviewThreadId, pullRequestReviewId, body)`                                                            |
| Immediate Publish of one Review Comment | REST `POST /repos/{o}/{r}/pulls/{n}/comments` with `commit_id` = head, `path`, `line`, `side`, optional `start_line`, `start_side`, `subject_type` |
| Immediate reply                         | REST `POST /repos/{o}/{r}/pulls/{n}/comments/{id}/replies`                                                                                         |
| Discussion Comment                      | `addComment(subjectId: <PR node id>, body)`, selecting `commentEdge.node { id databaseId createdAt }`                                              |
| Edit / delete a comment                 | `updatePullRequestReviewComment` / `deletePullRequestReviewComment`                                                                                |
| Submit                                  | `submitPullRequestReview(pullRequestReviewId, event: APPROVE \| REQUEST_CHANGES \| COMMENT, body)`; without a Pending Review, `addPullRequestReview` with the event                                                 |
| Discard Pending Review                  | `deletePullRequestReview`                                                                                                                          |
| Resolve / unresolve Thread              | `resolveReviewThread` / `unresolveReviewThread`                                                                                                    |
| Viewed                                  | `markFileAsViewed` / `unmarkFileAsViewed` (`pullRequestId, path`)                                                                                  |

**Answers prrr reads.** `forge-mutate` selects only `clientMutationId`,
so creating the Pending Review, a Thread and a reply goes through
`ghub-query` with forge's token, selecting the new ids. GitHub's answer
to Immediate Publish names the comment but not its Thread; the next
refetch does. An HTTP 422 is GitHub refusing a write and is an error,
not `offline`. Whether GitHub accepts Immediate Publish while the
viewer has a Pending Review is unverified.

Line numbers are file line numbers at the review's commit: `RIGHT` is the
new-file number for added and context lines, `LEFT` the old-file number for
deleted lines. Diff positions are never used.

**Limits.** Mutations cost 5 secondary points; prrr serialises mutations
and waits at least one second between them (the Outbox, section 7). Content creation is limited to
80 per minute; the Outbox retry honours that. `first` is capped at 100.

## 5. Review Queue (prrr-t9q.6)

A section inserted into `magit-status-sections-hook` before
`forge-insert-pullreqs` with `magit-add-section-hook`. The section is turned on by the global minor mode `prrr-queue-mode`. `prrr-queue` turns it on when needed. It renders only from
`pullreq-meta`, `team`, and forge's PR objects, never from the network, and
triggers `prrr-pull` in the background when the newest `fetched-at` is older
than `prrr-queue-stale-after` (default 300 seconds). Expanded by default when
non-empty; when both groups are empty it shows collapsed headers with counts.

**Which PRs.** The queue's PRs come from the repository's `pullreq-meta`
rows: each row's `number` is looked up with `forge-get-pullreq`, and only
PRs forge has and lists as `open` are kept. A refresh therefore costs in
proportion to the open PRs, never to the repository's whole history. A PR
forge knows but prrr has not pulled yet appears after the next prrr pull,
at most `prrr-queue-stale-after` later.

**Review State** (first match wins), For Me group: `new-commits` (the
viewer's latest submitted review commit differs from the head oid stored
with it in `pullreq-meta`; forge's head is used only for a PR prrr has
not pulled yet, prrr-knu.3), `requested`
(a review request to me is in the current `reviewRequests`, or
`viewerLatestReviewRequest` is set and I have no submitted review yet;
GitHub keeps the latter after I review), `team-requested` (a Team in
`review-requests` is one of mine and no member has reviewed),
`teammate-reviewed` (a review by someone else whose `on-behalf-of` contains
one of my Teams, or a Team request to one of my Teams that disappeared after
a review by another member), `changes-requested`, `approved`, `commented`
(the viewer's latest review state), `assigned`.

Mine group: `draft`, `awaiting-review`, `changes-requested`, `approved`,
`reviewed`, plus the count of unresolved Threads.

**Membership.** For Me: open, not authored by me, and requested,
team-requested, teammate-reviewed, assigned, or ever reviewed by me. Drafts
are excluded unless directly requested from me or assigned to me; such
drafts are dimmed and stay out of Awaiting me until marked ready. Mine: open
PRs I authored, drafts included. A PR I authored never appears in For Me.

**Ordering (FIFO).** For Me has two partitions. Awaiting me (new-commits,
requested, team-requested, assigned-without-my-review) sorts by PR creation
time, oldest first; a push re-enters a PR at its age position. Served (I
touched it and nothing was pushed since, or teammate-reviewed) sorts by my
last touch, oldest first. Mine sorts by state rank first (changes-requested, then
awaiting-review, approved, reviewed, draft), and by creation time, oldest
first, within a rank, so the PRs needing the author's own action come first.

**Stacks.** Rule: same repository, both open, A's `base-ref` equals B's
`head-ref`, B not `cross-repo-p`; the bottom PR's base is the default branch.
A Stack renders bottom-up as an indented chain under its bottom PR with a
`⟰ k/n` marker. A Stack is listed if any member qualifies; non-qualifying
members are dimmed. A Stack sorts by its highest-ranked member and stays
together.

**Line format.** `#number  state-badge  title  author  stack-marker
unresolved-count  updated-ago`, one face per state, title truncated to the
window width, styled like forge's topic lines. The section value of a row is
the forge `forge-pullreq` object so `forge-pullreq-at-point` keeps working.

## 6. Review Buffer rendering (prrr-t9q.1, prrr-t9q.5)

`prrr-diff-mode` derives from `magit-diff-mode`. The buffer diffs local
refs: forge fetches PR heads to `refs/pullreqs/N`; the merge base is
resolved once per buffer and files are diffed as `BASE..HEAD -- FILE`.

**Hybrid lazy rendering.** On open, insert the header sections, then one
collapsed `file` section per changed file from `git diff --numstat`, with
`magit-section-inhibit-markers` set to `delay` for the list. Then auto-expand
from the top until `prrr-eager-files` (default 30) files or
`prrr-eager-lines` (default 2,000) changed lines have been washed. Every
other file is washed on first expand through the section's deferred body
(`magit-insert-section-body`), using `magit-git-insert` plus narrowing
(`magit-git-wash` cannot run inside a deferred body). Measured baseline:
file list 65 ms at 417 files, 355 ms at 2,516; per-file wash 2 to 7 ms.

**Sections.** `file` > (`file-comment`, `hunk`...) and inside each hunk
`thread` children placed directly after their anchored line. A file's
Threads whose anchor is not in the current Range go into a folded
`not-in-range` section at the end of the file; outdated Threads into a
folded `outdated` section; Threads on files no longer in the diff into a
buffer-level folded `outdated-files` section. The header holds folded
`description` and `discussion` sections (forge's `body` and `posts`, then
the Discussion Comments forge has not pulled yet, sent and unsent) and a
one-line status: PR, Range, "history rewritten" when the Range's start
is not an ancestor of its end, Pending Review count, Outbox count,
refresh state, and "head moved, press g" when applicable.

**Section keymaps.** magit and forge give a section the keymap named after
its type, and a section keymap wins over the mode's. A `discussion`
section's keymap is cleared, since forge's `forge-discussion-section-map`
would otherwise apply. `file` and `hunk` sections get
`prrr-diff-file-section-map` and `prrr-diff-hunk-section-map`, children of
magit's, in which every key a later milestone gives to prrr is `undefined`
(magit's bind `C` to `magit-commit-add-log`).

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

**Refresh.** `g` (`prrr-refresh`) re-runs the open at the PR's current
head; every other redraw keeps the head shown (section 8). Both
preserve expanded files, folded Threads, and Viewed, through
`magit-section-visibility-cache` restricted to the `file`, `thread`,
`file-comment`, `review-comment`, `description`, `discussion`,
`not-in-range`, `outdated` and `outdated-files` types. The cache
records only the user's toggles, so every other section starts as on
open; every open refreshes once its refetch answers, so a type left
out of the list loses its toggle seconds after the user makes it.
Hunks are left out: they start shown and are named by line ranges,
which change with the diff. Viewed is read from the `viewed` table,
never from the visibility cache. `G` (invalidate-and-refetch)
additionally forces the per-PR refetch.

**Magit features that keep working.** `TAB`, `n`/`p`, `M-n`/`M-p`, `^`,
`RET` (visits the blob at the right line, including after a Thread), `j`
jump, `1`-`4` section levels, ediff from a hunk with `E`.

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
chosen from the file name: a file-name regexp of `prrr-highlight-modes`
first, else `auto-mode-alist` (with its case-folded second pass, but not
`interpreter-mode-alist`, which needs the file's content), aliases
resolved (`javascript-mode` is `js-mode`), and the remapping options
(`major-mode-remap-alist`, and `major-mode-remap-defaults` on Emacs 30
and later). When that is not a ts-mode, a major-mode key of
`prrr-highlight-modes` may name one; else FOO-ts-mode stands in for
FOO-mode if it is defined. `prrr-highlight-modes` is seeded with the
built-in ts-modes the rename can't reach (bash, JSON, HTML, TypeScript,
TSX, Go, go.mod, Rust, YAML, TOML, Lua, Dockerfile, CMake); entries
naming an undefined mode are skipped. Running the ts-mode loads its
file, and many ts-mode files add themselves to `auto-mode-alist`,
`interpreter-mode-alist` or `major-mode-remap-defaults` at load; those
are bound around the call, so borrowing rules never changes the mode
the user's own files open in. Messages and warnings from the mode body
are silenced. Files without an available grammar are left
unhighlighted, silently. `prrr-highlight` (default t) turns it on; `L`
toggles it in one buffer, for the buffer's life (`prrr-highlight` is
permanent-local, so reopening keeps it; the idle timer is cancelled
when the mode reruns). Files painted during a refresh, and sections
larger than `prrr-highlight-max-lines` (default 3,000), are highlighted
on an idle timer, so first paint and refresh never wait on it.
Sections over ten times `prrr-highlight-max-lines` are never
highlighted: the idle work on one file can't be split, and would block
for about a second per 30,000 lines.
Measured: 1.3 / 9.7 / 34 ms per 100 / 300 / 1,000-line section.

## 7. Threads, comments, and the Pending Review (prrr-t9q.2, prrr-t9q.7)

**Freshness.** Opening a Review Buffer renders from the database at once,
then refetches Threads, Pending Review, and Viewed in the background and
re-renders affected sections when they arrive, with "refreshing" in the
header. The refetch chord forces it.

**Capture.** Commenting opens a `prrr-comment-mode` buffer (derived from
`text-mode`, markdown helpers if `markdown-mode` is installed) in a side
window, with the anchor (`path:start-end side`, or `path` for a File
Comment) in its header. `C-c C-c` confirms, `C-c C-k` aborts, `C-c C-i`
toggles Immediate Publish for this comment. Confirm writes the row
optimistically and returns point to the anchor.

**Anchors.** A comment on a region spanning lines of one hunk becomes a
range comment with `startLine`/`line` and sides taken from the first and
last line; a region that spans hunks is refused with a message. A comment
with point on a deleted line is `LEFT`; otherwise `RIGHT`. A File Comment
has `subjectType: FILE`.

**Write path (optimistic).** Every new comment, reply, edit, delete,
resolve, Submit, discard and Viewed change is a write handed to the
Outbox (`prrr-sync-write`), stored at once in `outbox`. The Review
Buffer shows the stored rows with the queued writes applied
(`prrr-state-outbox-view`): unsent ones with the `prrr-unsent` face,
failed ones with the `prrr-failed` face and GitHub's message, and the
header counts both. The Outbox sends one mutation at a time, at least a
second apart, at most 80 content creations a minute, each PR's writes in
order; a failed write holds back its PR's later writes and is retried on
the PR's next write or refetch and through `prrr-outbox-retry`, or
dropped with `prrr-outbox-discard`, which also drops the writes that
need it. A rate limit pauses the Outbox until it resets. Success stores
GitHub's rows and renames the write's local ids in the PR's queued
writes, so a reply to a Thread not yet sent goes out once the Thread has
GitHub's id. A success that answers after its write was dropped stores
nothing, since the refetch that follows shows what GitHub made, but
still renames, so a command naming the local id from a buffer drawn
before the drop reaches GitHub's. A Discussion Comment is not in the
review data but in forge's topic, which has it only once forge pulls the
PR: GitHub's answer names the comment, and the Review Buffer shows it,
marked sent, from a session-only list keyed by GitHub's database id
until forge's topic lists a post with that id (forge is asked to pull
the PR at once), so it is never missing and never shown twice. After a
restart forge's next pull shows it. Edit or delete of a comment whose
own write is still queued and not yet sent changes or drops that write.

A write whose send started is *unconfirmed* until GitHub answers: it may
or may not have reached GitHub. The Outbox stores `:sent-at` in the
write's payload before the request goes out (the `outbox` layout is
frozen) and removes it on any answer; a failure answer, even a late one,
counts the attempt and keeps GitHub's message. When GitHub has not
answered after `prrr-sync-timeout` seconds, the send ends: the Outbox
moves on to other PRs' writes, but the unconfirmed write holds back its
PR, shows as unsent, "waiting for GitHub's answer", and is never sent
again blindly, not by a retry and not after a restart. A success answer
that does not name what GitHub made (a null GraphQL payload, a REST
answer without `node_id`) counts as no answer: GitHub may have made it,
so the write stays unconfirmed and the refetch decides. An edit or
delete of what it creates becomes a write of its own that waits for
GitHub's id. The Outbox starts by itself once per session, when prrr
opens its database: it refetches the PRs of unconfirmed writes, then
sends what is queued, without waiting for a Review Buffer.

**Reconciliation.** On refetch, GitHub's rows replace every stored
Thread, comment, Pending Review and Viewed flag of the PR; queued
writes, which live only in `outbox`, survive and are re-attempted
against the current pending review id. An answer that a write of the PR
may have raced (one succeeded since the refetch started, or one is being
sent) is not stored; the Outbox refetches the PR once it has nothing
more to send to it. A PR whose last refetch failed is refetched by the
Outbox no sooner than `prrr-sync-min-retry-spacing` after that attempt
and not before a rate limit resets; the Outbox then pumps by itself. A
refetch the Outbox needed (after a success, a send without an answer, or
for an unconfirmed write) that fails or gets no answer is tried again by
the Outbox, no sooner than `prrr-sync-min-retry-spacing` after it
started and not before a rate limit resets, so a reply waiting for the
id of a Thread published at once never needs the user's refetch. A
refetch whose answer is stored decides each unconfirmed write of the PR
from that answer: a new Thread or reply landed when there is a comment
by me with its body, made no earlier than five minutes before the write
was queued, that starts a Thread on its path (or is in its Thread) and
was not stored before the refetch; an edit when the comment has its body
(or is gone); a delete when the comment is gone; a resolve, Viewed
change or discard when the Thread's flag, the file's flag or the absent
Pending Review shows it. A write that landed is recorded as if GitHub
had answered, renames included; one that did not is sent again.
Discussion Comments and Submit are not in the review data, so an
unconfirmed one fails with a message asking the user to check the PR,
then retry or drop it; it stays unconfirmed, so neither a refetch nor
another write sends it again, only the user's `prrr-outbox-retry`. A
retry of a PR with an unconfirmed write refetches it instead of sending.
Comments added from the web appear like any other.

**Pending Review lifecycle.** The first pending comment on a PR creates the
Pending Review (after checking for an existing one). Edit and delete of my
own comments work for pending and submitted comments. `prrr-submit` opens a
capture buffer for the summary body with the Verdict chosen from the
transient (approve, request changes, comment); it shows the counts of
pending and agent-authored comments and asks for confirmation when any
agent comments exist. `prrr-discard-pending` deletes the Pending Review after
confirmation. Submitting touches the PR (moves it to Served); discarding does not, since GitHub then records no review.

GitHub anchors every Thread of a Pending Review at the review's commit,
so a new Thread joins the Pending Review only when the review is on the
head the buffer shows; otherwise the comment is refused before it is
queued, its text kept, and the user submits or discards the review
first, or publishes the comment at once. The Outbox makes the same check
when it sends (bead prrr-836).

**Immediate Publish.** A prefix argument (`C-u`) on any comment or reply
command, or the capture-buffer toggle, publishes that one comment now
through the REST path, bypassing the Pending Review. Discussion Comments
always publish immediately.

**Suggestions.** A ```` ```suggestion ```` block in a comment body renders
inline as a mini diff against the anchored lines. `prrr-comment-suggest`
pre-fills the capture buffer with a suggestion block containing the region.

## 8. Ranges (prrr-t9q.9)

Kinds: `default` (merge base to head), `since-review` (my latest submitted
review commit to head), `since-opened` (Bookmark head to head), `commit`
(one PR commit against its parent), `between` (two PR commits, chosen with
completing-read over the PR's commits; the first may also be the merge
base). The header names the Range. Switching preserves point on the
same file and line when the new Range shows it: the line number is
mapped from its commit to the new Range's commits through `git diff -U0`
(`prrr-state-map-line`), tried on the right side, then the left, then
the file's heading.

**Commenting.** `RIGHT`-side lines of any Range that ends at head are
commentable as default-Range comments (their numbers are head line
numbers). `LEFT`-side lines of `since-review`/`since-opened`, and both
sides of `commit`/`between`, are read-only; `.` jumps to the same file
and line in the default Range. File Comments need a Range that ends at
head. Threads render inline only on the sides a Range numbers as
GitHub does (right when it ends at head, left only in `default`); the
others go to the file's `not-in-range` section. Both sides also need
the review data fetched at the head shown: while the last refetch saw
another head (until the head shown is the one the refetch saw: `g`,
after `forge-pull` when the header asks), every line Thread folds into
`not-in-range`, the left side too, because a rebase may have moved the
merge base GitHub numbers it against and no stored field names that
commit. At the head shown, prrr takes GitHub's merge base to be the
local one (of forge's base commit and the head); they differ only if
forge's base commit is stale in a way that changes the merge base, a
limit prrr accepts.

**Viewed** is GitHub's flag only, shown and toggled on every Range.

**Bookmark** updates when the Review Buffer is killed or its window
quit (`q`), when `>` or `<` steps to another PR of its Stack, when
opening the PR again moves its open buffer to a newer head, on Submit,
and through `prrr-mark-seen`; never otherwise on open. It records the
head the buffer shows (before the move, when opening moves it).

**Force-push and moving heads.** prrr pins each commit it may need later as
`refs/prrr/<number>/<oid>` when it records a Bookmark (Submit records
one), opens a PR whose latest review by the viewer it knows, and shows
a `since-review` or `since-opened` Range. Pins are not written on every
Review Queue pull (that would cost one git process per PR); they are
removed on it: after the queue pull stored its rows, `prrr-pull` deletes
the pins of every PR the pull did not return as open, with one
`git for-each-ref` and one `git update-ref --stdin` (about 10 ms for
500 pins, so synchronous), except the pins of a PR with a live Review
Buffer. Bookmarks are kept. Pins are keyed by PR number only, so two
forge repositories sharing one worktree (a fork and its upstream)
prune each other's pins; a start that is missing then is fetched by
sha. If a Range's start is not an
ancestor of head, prrr diffs the two trees directly and shows "history
rewritten" in the header. If the start commit is missing locally it is
fetched by sha from the PR's remote (forge's `remote` of the
repository); if that fails the Range falls back to `default` with a
message. A Review Buffer keeps the head it shows: only opening it and
`g` (`prrr-refresh`) move it to the head forge fetched. When forge
fetched a newer head, the header shows "head moved, press g"; when
only the last refetch saw one, "head moved to <oid> on GitHub: run
forge-pull, then g". Nothing re-renders underneath the user.

**Stack navigation.** `>` and `<` open the PR above or below at its own
default Range in the same window. Each PR diffs against its own base.

## 9. Keymap and transient menus

Every command has one key in the buffer and the same key in the transient.
`?` opens the main prrr transient in prrr buffers; `h` stays
`magit-dispatch`. `C-o` is an alias for `?` in prrr buffers and the only
menu key inside the magit-status section, where `?` belongs to magit.

**Review Buffer** (`prrr-diff-mode-map`, parent `magit-diff-mode-map`):

| Key         | Command                                             | Note                                                                                  |
|-------------|-----------------------------------------------------|---------------------------------------------------------------------------------------|
| `c`         | `prrr-comment`                                      | line or region; `C-u` publishes immediately                                           |
| `C`         | `prrr-comment-file`                                 | File Comment                                                                          |
| `r`         | `prrr-reply`                                        | Thread at point; `C-u` immediate                                                      |
| `e`         | `prrr-edit-comment`                                 | own comment at point                                                                  |
| `k`         | `prrr-delete-comment`                               | own comment at point                                                                  |
| `d`         | `prrr-discussion-comment`                           | always immediate                                                                      |
| `R`         | `prrr-toggle-resolved`                              | Thread at point                                                                       |
| `s`         | `prrr-comment-suggest`                              | suggestion block from region                                                          |
| `]` / `[`   | `prrr-next-thread` / `prrr-previous-thread`         |                                                                                       |
| `}` / `{`   | `prrr-next-unresolved` / `prrr-previous-unresolved` |                                                                                       |
| `J` / `K`   | `prrr-next-file` / `prrr-previous-file`             | `M-n`/`M-p` stay magit's sibling motion                                               |
| `j`         | `prrr-jump-to-file`                                 | completing-read over files                                                            |
| `v`         | `prrr-toggle-viewed`                                | folds and marks ✓                                                                     |
| `z` / `Z`   | `prrr-collapse-all` / `prrr-expand-all`             |                                                                                       |
| `D`         | `prrr-range`                                        | Range transient                                                                       |
| `.`         | `prrr-goto-default-range`                           | same file and line                                                                    |
| `m`         | `prrr-mark-seen`                                    | update Bookmark                                                                       |
| `>` / `<`   | `prrr-stack-up` / `prrr-stack-down`                 |                                                                                       |
| `o`         | `prrr-open-topic`                                   | forge topic buffer                                                                    |
| `b`         | `prrr-browse`                                       | on GitHub                                                                             |
| `B`         | `prrr-checkout`                                     | forge's checkout                                                                      |
| `g` / `G`   | `prrr-refresh` / `prrr-refetch`                     | refresh at the current head / invalidate-and-refetch                                  |
| `S`         | `prrr-submit`                                       | Verdict transient: `a` approve, `r` request changes, `c` comment, `k` discard pending |
| `O`         | `prrr-outbox`                                       | transient: `r` retry, `k` discard                                                     |
| `@`         | `prrr-send-to-agent`                                |                                                                                       |
| `L`         | `prrr-toggle-highlight`                             |                                                                                       |
| `?` / `C-o` | `prrr-menu`                                         | main transient                                                                        |

Preserved from magit: `TAB`, `S-TAB`, `n`, `p`, `M-n`, `M-p`, `^`, `RET`,
`q`, `1`-`4`, `E` ediff, `h`. Overridden magit keys (`c`, `d`, `e`,
`k`, `s`, `z`, `D`, `b`, `B`, `o`, `v`, `L`, `S`, `O`, `G`) are commit, diff,
ediff, delete, stage, stash, diff args, branch, bisect, submodule, revert,
log, and refresh-all, none of which belong in a review buffer.

**Main transient** `prrr-menu`, groups: Comment (`c C r e k d R s`),
Navigate (`] [ } { J K j`), View (`v z Z L`), Range (`D . m`), Stack
(`> <`), Review (`S O`), Open (`o b B`), Sync (`g G`), Agent (`@`). The
transient has one switch, `-i` immediate, equivalent to `C-u`.

**Review Queue section** (`prrr-queue-section-map`, active on a queue row):

| Key       | Command                                                             |
|-----------|---------------------------------------------------------------------|
| `RET`     | `prrr-review` (open Review Buffer at default Range)                 |
| `o`       | `prrr-open-topic`                                                   |
| `b`       | `prrr-browse`                                                       |
| `B`       | `prrr-checkout`                                                     |
| `>` / `<` | `prrr-stack-up` / `prrr-stack-down`                                 |
| `G`       | `prrr-pull`                                                         |
| `C-o`     | `prrr-queue-menu` (adds toggles `-d` show drafts, `-s` show Served) |

**Capture buffer** (`prrr-comment-mode-map`): `C-c C-c` confirm, `C-c C-k`
abort, `C-c C-i` toggle immediate.

**Global commands.** `prrr-review` (prompt for a PR with forge's reader),
`prrr-queue` (jump to the section in magit-status), `prrr-pull`,
`prrr-refresh-teams`.

## 10. Agent API (prrr-t9q.8)

Public functions in `prrr-api.el`, each taking a PR designator (`(REPO .
NUMBER)` or a forge `forge-pullreq`) and returning structs or alists, never
buffers:

`prrr-api-pullreq`, `prrr-api-threads` (optional Range), `prrr-api-diff`
(Range, optional file), `prrr-api-pending`, `prrr-api-add-comment` (path,
line, optional start-line, side, body, `:file t` for a File Comment),
`prrr-api-reply`, `prrr-api-delete-pending-comment`, `prrr-api-submit`
(Verdict, body), `prrr-api-export` (JSON file, crit-review's handoff shape
extended with GitHub ids), `prrr-api-import` (file of comments). All work
through `emacsclient -e` without buffer context and in-process alike.

**Agent comments.** `prrr-agent-comment-mode` is `pending` (default): a
comment added through the API goes straight to the Pending Review with the
user's token, flagged `agent-p`, rendered with the `prrr-agent` face and an
"agent" badge, editable and deletable like any pending comment, and
counted in the Submit confirmation. The alternative `proposed` keeps such
comments local with `local-state` `proposed` until the user accepts (`e`
then `C-c C-c`, or `prrr-accept-comment`) or rejects (`k`) each one.

**Hooks.** `prrr-comment-created-hook`, `prrr-reply-created-hook`,
`prrr-review-submitted-hook`, `prrr-review-buffer-opened-hook`, each run
with the relevant struct. `prrr-agent-invoke-function` is the single
agent-specific seam.

**Send to agent.** `prrr-send-to-agent` collects the PR summary, current
Range, diff, Threads, Pending Review (agent comments included), and the
user's instructions from a capture buffer into a Markdown payload and calls
`prrr-agent-invoke-function`. The default implementation submits the payload
to an `agent-shell` buffer for the repository when agent-shell is loaded
(queue request, else insert and submit), otherwise copies it to the kill
ring.

**Attribution.** Everything is posted under the user's account.
`prrr-agent-comment-prefix` (default "") is prepended to agent-authored
bodies; nothing else is added.

## 11. Errors, auth, and offline

- Authentication failures (HTTP 401, or 403 without rate-limit headers)
  show prrr's classified message, "GitHub rejected the token (HTTP N)",
  and leave the buffer usable for reading local diffs. A missing token that
  forge reports before sending shows forge's own message.
- Rate-limit responses (primary or secondary) pause the Outbox and the
  background refetch until the reset time and say so in the header. An HTTP
  403 with quota left is GitHub's secondary limit and waits one minute.
- A pull that gets no answer within `prrr-sync-timeout` (default 60
  seconds), as when the connection fails, ends as offline; a later answer
  is ignored.
- A failed Teams fetch does not stop the queue pull: the stored Teams stay,
  Teams are not retried before their daily cadence, and the header says
  "Teams unavailable: ...".
- Network failures on refetch keep the database copy and show "offline" in
  the header; writes go to the Outbox.
- A missing PR ref (`refs/pullreqs/N` absent) prompts to run `forge-pull`.
- Every background job is cancellable by killing the buffer; callbacks check
  that the buffer is live and the PR and head oid unchanged before touching
  it.

## 12. Performance budgets

Measured on Emacs 31.1 with the prototype; the implementation must stay
within these on the test fixtures in CI:

| Operation                                | Budget                                           |
|------------------------------------------|--------------------------------------------------|
| Review Queue render (database only)      | 20 ms for 200 PRs                                |
| Review Buffer open, 417 files            | 150 ms to first paint                            |
| Review Buffer open, 2,516 files          | 500 ms to first paint                            |
| Expand one file (300 lines, highlighted) | 25 ms                                            |
| Refresh with 3 files expanded, 417 files | 250 ms                                           |
| Per-PR refetch                           | 1 GraphQL point, 1 request for up to 100 Threads |

The Review Queue budget covers what a magit-status refresh pays: gathering
the inputs from forge's and prrr's databases plus inserting the section,
measured on a repository with 3000 PRs of which 200 are open.

## 13. Testing

- ERT suite under `test/`, run by `make test` and GitHub Actions on Emacs
  29.4, 30.1, and 31.1 with MELPA magit, forge, emacsql, and transient.
- `prrr-state.el` tested exhaustively with constructed structs: every Review
  State, both partitions and their ordering, Stack detection including fork
  and deleted-branch cases, line mapping across Ranges.
- `prrr-github.el` tested against recorded JSON responses under
  `test/fixtures/github/` by stubbing `forge-query` and `forge-rest`; no
  network in CI. A separate `make test-live` runs the queries against a
  public PR when a token is present.
- Rendering tested in batch against a git fixture repository generated by a
  script (`test/fixtures/make-repo.sh`) with known hunks, Threads injected
  from fixtures: section tree shape, Thread placement, Viewed folding, refresh
  preservation, and `RET` line mapping.
- `bench/` keeps the prototype's benchmark harness; `make bench` reports the
  numbers in section 12 and fails on a budget regression over 25 percent.
- `package-lint`, `checkdoc`, and byte-compilation with warnings as errors
  run in CI.

## 14. Packaging

GPL-3.0-or-later with `LICENSE` and per-file headers; `Package-Requires`
listing section 1's versions; `prrr-pkg.el`; a `README.md` with screenshots,
install, and the key table; `CHANGELOG.md`; `Makefile` with `test`, `lint`,
`bench`, `compile`. No personal paths, hosts, or logins anywhere in the
repository; sample data in tests uses `example` names.

## 15. Milestones

Each milestone is shippable on its own and is the unit of the
implementation plan.

1. **Foundation.** Package skeleton, `prrr-db.el` schema and structs,
   `prrr-github.el` queries and decoding with fixtures, `prrr-state.el` with
   full unit tests, CI.
2. **Review Queue.** `prrr-pull`, Teams, the magit-status section, FIFO
   ordering, Stacks, keymap and transient.
3. **Review Buffer, read-only.** `prrr-diff-mode` with hybrid lazy
   rendering, Thread and File Comment sections, outdated and not-in-range
   sections, header, Viewed, refresh preservation, jump and fold commands,
   benchmark harness.
4. **Commenting and Pending Review.** Capture buffer, anchors, optimistic
   writes, Outbox, reply, edit, delete, resolve, Immediate Publish,
   Discussion Comments, Submit with Verdict, discard, suggestions.
5. **Ranges and Stacks in the buffer.** All five Range kinds, since-review
   and since-opened, ref pinning, force-push handling, head-moved notice,
   Stack navigation, Bookmark.
6. **Highlighting.** `prrr-treesit.el`.
7. **Agent API.** `prrr-api.el`, hooks, JSON export and import,
   `prrr-agent.el` with the agent-shell default.
8. **Release.** README polish (the README grows with each milestone), screenshots, CHANGELOG, MELPA recipe.
