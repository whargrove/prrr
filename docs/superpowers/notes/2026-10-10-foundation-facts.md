# Verified facts for the Foundation milestone

Collected 2026-10-10 from the installed sources (forge 20260926.1226, ghub
20260925.1500, emacsql 4.4.1, magit 4.7.1) and the Emacs 31.1 on this
machine. Plans and implementers may rely on these without re-checking.

## Environment

- `emacs --batch` is GNU Emacs 31.1; `(sqlite-available-p)` is `t`, so
  emacsql uses the built-in SQLite backend.
- No `eask` or `cask` on PATH. `gh` is available. Dependencies for tests
  must be installed by a script using package.el into a project-local
  directory.
- The user's own packages live under `~/.emacs.d/var/elpa/`; nothing in the
  repository may reference that path. CI installs from MELPA + GNU ELPA.

## emacsql 4.4

- `(emacsql-sqlite-open FILE &optional DEBUG SETUP)`: FILE nil gives an
  in-memory database (use this in tests). Foreign keys are enabled.
- Queries: `(emacsql db [:create-table thread ([(thread-id :primary-key) pr-id path line ...])])`,
  `(emacsql db [:insert-or-replace :into thread :values $v1] (list row1 row2))` (a LIST of row vectors; a single bare row vector also works),
  `(emacsql db [:select * :from thread :where (= pr-id $s1)] id)`,
  `(emacsql db [:delete :from thread :where (= thread-id $s1)] id)`.
  Composite key: `[:create-table viewed ([pr-id path state fetched-at] (:primary-key [pr-id path]))]`.
- Values that are not strings or numbers (lists, symbols, `t`) are stored
  as printed Lisp and read back, so list-valued columns work. `nil` is
  stored as NULL and comes back as `nil`.
- `(emacsql-close db)` closes. Symbols in column names map hyphens to
  underscores internally; use hyphenated symbols in Lisp.

## forge public API used by prrr

- `(forge-query OBJ-OR-HOST QUERY VARIABLES &key callback errorback noerror narrow until)`
  macro (forge-client.el). OBJ-OR-HOST may be a host string such as
  `"api.github.com"`, which is what prrr passes so tests need no forge
  repository object. QUERY is ghub's Lisp GraphQL DSL (below). VARIABLES is
  a list of `(name value)` pairs.
- `(forge-mutate OBJ-OR-HOST MUTATION VARIABLES &key callback errorback noerror)`
  macro: MUTATION is the mutation name symbol (`addPullRequestReview`),
  VARIABLES are the `input` fields as `(name value)` pairs.
- `(forge-rest OBJ-OR-HOST METHOD RESOURCE &optional PARAMS &key callback errorback noerror unpaginate)`.
  With a host string, RESOURCE must be a complete path like
  `/repos/OWNER/NAME/pulls/N/comments`.
- Both macros end in `ghub-query` / `ghub-request` (public ghub functions).
  Tests stub those with `cl-letf` and call the supplied `:callback`
  immediately with fixture data.
- `forge-pullreq` slots (read with `oref`): `id number state author title
  created updated draft-p assignees review-requests base-ref base-rev
  head-ref head-rev head-user cross-repo-p their-id`. `their-id` is the
  GitHub node id. `assignees` and `review-requests` are lists of
  `(ID LOGIN NAME FORGE-ID)` rows; `review-requests` holds users only (Team
  requests are dropped by forge). `forge-repository` slots: `id owner name
  apihost default-branch pullreqs`.
- The viewer login: `(magit-get "github.user")` (forge's own convention);
  prrr adds `prrr-github-user` as an override.

## ghub GraphQL DSL and response shape

Query form (forge-github.el style):

```elisp
(forge-query "api.github.com"
  (repository [(owner $owner String!) (name $name String!)]
     (pullRequests [(:edges t) (states . (OPEN))]
        id number headRefOid createdAt isDraft
        (author login)
        (reviewRequests [(:edges t)]
           (requestedReviewer "__typename ... on User { login } ... on Team { combinedSlug }\n"))
        (latestReviews [(:edges t)]
           (author login) state submittedAt (commit oid)
           (onBehalfOf [(:edges t)] combinedSlug))
        (viewerLatestReview state submittedAt (commit oid))
        (viewerLatestReviewRequest login)))
  ((owner "octo") (name "repo"))
  :callback (lambda (data) ...))
```

- `[(:edges N-or-t) ...]` marks a connection: ghub adds `first`, pages
  automatically (100 per request by default), and replaces the connection
  in the response with a plain list of node alists.
- A string inside a field is emitted verbatim (used for inline fragments
  and `__typename`).
- `(name . (VALUE))` is a literal argument list; `(name ((k v) ...))` an
  object argument.
- Variables are declared inline as `(name $var Type!)` and supplied in the
  VARIABLES list.
- The callback receives the alist `(data (repository ...))`. `let-alist`
  works on it directly (`assq` skips the leading symbol). Objects are
  alists with symbol keys, arrays are lists, JSON `null` and `false` are
  both `nil`, `true` is `t`.
- Fixtures for tests are therefore Emacs Lisp data files (`.eld`) holding
  exactly what the callback receives, printed with `pp`.

## GitHub API facts the foundation needs

From `docs/research/` (full citations there):

- Queue inputs per repository: `pullRequests(states: OPEN)` with `id number
  headRefOid createdAt isDraft author.login reviewRequests(requestedReviewer
  User.login | Team.combinedSlug) latestReviews(author.login state
  submittedAt commit.oid onBehalfOf.combinedSlug) viewerLatestReview
  viewerLatestReviewRequest.login`.
- Teams: `viewer.organizations.nodes.teams(userLogins: [$me]).nodes
  { slug combinedSlug }` with the organization `login`.
- Per-PR review data: `reviewThreads` (fields in research 03 section 1),
  `reviews(states: [PENDING], author: $me)`, `files { path viewerViewedState }`,
  `headRefOid`.
- `PullRequestReviewState` values: `APPROVED CHANGES_REQUESTED COMMENTED
  DISMISSED PENDING`. `FileViewedState`: `VIEWED UNVIEWED DISMISSED`.
  `DiffSide`: `LEFT RIGHT`. `PullRequestReviewThreadSubjectType`: `LINE FILE`.
- Timestamps are ISO 8601 UTC strings (`2026-10-10T12:00:00Z`); they sort
  correctly as strings.

## Decisions fixed by SPEC.md that the foundation implements

- Sections 2 (file layout), 3 (tables), 4 (queries), 5 (Review State,
  membership, FIFO ordering, Stacks), 13 (tests), 14 (packaging).
- Line mapping across Ranges (listed under `prrr-state.el`) belongs to
  milestone 5, not the foundation.
