# GitHub API for Threads, resolving, the Viewed flag, reviews, and Discussion Comments

Resolves `.scratch/prrr-design/issues/03-threads-viewed-api.md`.
Terms follow `CONTEXT.md` (Thread, Review Comment, File Comment, Discussion
Comment, Pending Review, Verdict, Viewed, Range, Review State).

Researched 2026-10-10 against primary sources only:

- GitHub GraphQL reference, "Pulls" page:
  <https://docs.github.com/en/graphql/reference/pulls> (cited below as
  `pulls#<anchor>`). Note: docs.github.com has reorganised the GraphQL
  reference by product area; the old `/graphql/reference/objects`,
  `/mutations`, `/enums` URLs now redirect to an index.
- "Issues" page: <https://docs.github.com/en/graphql/reference/issues>
  (`issues#<anchor>`).
- "Commits" page: <https://docs.github.com/en/graphql/reference/commits>
  (`commits#<anchor>`).
- Rate limits and node limits:
  <https://docs.github.com/en/graphql/overview/rate-limits-and-node-limits-for-the-graphql-api>
  (`ratelimits#<anchor>`).
- UI docs for the Viewed flag:
  <https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/reviewing-proposed-changes-in-a-pull-request#marking-a-file-as-viewed>
  (`ui-reviewing`).
- UI docs for resolving:
  <https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/commenting-on-a-pull-request#resolving-conversations>
  (`ui-resolving`).
- Live schema introspection and live sample queries run with
  `gh api graphql` on 2026-10-10 against the public PR
  `kubernetes/kubernetes#132761` (54 threads, 121 review comments, 110
  discussion comments). Cited as `live`.
- forge `20260926.1226`, files
  `~/.emacs.d/var/elpa/forge-20260926.1226/forge-pullreq.el` and
  `forge-post.el` (public symbols only). Cited as `forge-pullreq.el:<line>`.

Anything not confirmed by one of these is marked **unverified**.

Every `query` below was run unchanged through `gh api graphql` against the
sample PR on 2026-10-10 and returned no errors; the `mutation`s were not
executed (they would change state on GitHub) and are transcribed from the
mutation and input-object docs. Variables are `$owner`, `$name`, `$number`
(and `$login`, `$cursor`, `$id`, `$pr`, `$path`, `$body` where used). They
paste unchanged into <https://docs.github.com/en/graphql/overview/explorer>.

---

## 1. `reviewThreads`: fields, pagination, cost

### Shape

`PullRequest.reviewThreads(after, before, first, last): PullRequestReviewThreadConnection!`,
"The list of all review threads for this pull request"
(`pulls#object-pullrequest`). The connection has `nodes`, `edges`,
`pageInfo`, `totalCount` (`pulls#object-pullrequestreviewthreadconnection`).

`PullRequestReviewThread` fields (`pulls#object-pullrequestreviewthread`),
all descriptions verbatim:

| Field | Type | Description |
|---|---|---|
| `id` | `ID!` | The Node ID of the PullRequestReviewThread object. (Needed by `resolveReviewThread`.) |
| `path` | `String!` | Identifies the file path of this thread. |
| `line` | `Int` | The line in the file to which this thread refers. |
| `startLine` | `Int` | The start line in the file to which this thread refers (multi-line only). |
| `diffSide` | `DiffSide!` | The side of the diff on which this thread was placed. |
| `startDiffSide` | `DiffSide` | The side of the diff that the first line of the thread starts on (multi-line only). |
| `originalLine` | `Int` | The original line in the file to which this thread refers. |
| `originalStartLine` | `Int` | The original start line in the file to which this thread refers (multi-line only). |
| `isOutdated` | `Boolean!` | Indicates whether this thread was outdated by newer changes. |
| `isResolved` | `Boolean!` | Whether this thread has been resolved. |
| `isCollapsed` | `Boolean!` | Whether or not the thread has been collapsed (resolved). |
| `resolvedBy` | `User` | The user who resolved this thread. |
| `subjectType` | `PullRequestReviewThreadSubjectType!` | The level at which the comments in the corresponding thread are targeted, can be a diff line or a file. |
| `viewerCanReply` | `Boolean!` | Indicates whether the current viewer can reply to this thread. |
| `viewerCanResolve` | `Boolean!` | Whether or not the viewer can resolve this thread. |
| `viewerCanUnresolve` | `Boolean!` | Whether or not the viewer can unresolve this thread. |
| `comments(after, before, first, last, skip)` | `PullRequestReviewCommentConnection!` | A list of pull request comments associated with the thread. |
| `pullRequest`, `repository` | | back-references |

There is **no `originalCommit` on the thread**; it lives on each comment (see
below). The ticket's "originalCommit" is satisfied via the thread's first
comment.

Enums (`pulls#enum-diffside`, `pulls#enum-pullrequestreviewthreadsubjecttype`):

- `DiffSide`: `LEFT` "The left side of the diff.", `RIGHT` "The right side of the diff."
- `PullRequestReviewThreadSubjectType`: `FILE` "A comment that has been made
  against the file of a pull request." (a File Comment), `LINE` "A comment
  that has been made against the line of a pull request."

`PullRequestReviewComment` fields prrr needs
(`pulls#object-pullrequestreviewcomment`):

| Field | Type | Description |
|---|---|---|
| `id` | `ID!` | Node ID (needed for replies, edits, deletes; ticket 02). |
| `author` | `Actor` | The actor who authored the comment. |
| `body` | `String!` | The comment body of this review comment. (`bodyText`, `bodyHTML` also exist.) |
| `createdAt` | `DateTime!` | Identifies when the comment was created. |
| `publishedAt` | `DateTime` | Identifies when the comment was published at. |
| `draftedAt` | `DateTime!` | Identifies when the comment was created in a draft state. |
| `lastEditedAt` | `DateTime` | The moment the editor made the last edit. |
| `replyTo` | `PullRequestReviewComment` | The comment this is a reply to. |
| `pullRequestReview` | `PullRequestReview` | The pull request review associated with this review comment. (`state` on it gives the review's Verdict / `PENDING`.) |
| `state` | `PullRequestReviewCommentState!` | Identifies the state of the comment. `PENDING` "A comment that is part of a pending review." / `SUBMITTED` "A comment that is part of a submitted review." (`pulls#enum-pullrequestreviewcommentstate`) |
| `commit` | `Commit` | Identifies the commit associated with the comment. |
| `originalCommit` | `Commit` | Identifies the original commit associated with the comment. |
| `path` | `String!` | The path to which the comment applies. |
| `line` / `startLine` | `Int` | The end / start line number on the file to which the comment applies. |
| `originalLine` / `originalStartLine` | `Int` | ... to which the comment applied when it was first created. |
| `outdated` | `Boolean!` | Identifies when the comment body is outdated. |
| `diffHunk` | `String!` | The diff hunk to which the comment applies. |
| `subjectType` | `PullRequestReviewThreadSubjectType!` | as on the thread |
| `isMinimized`, `minimizedReason` | | hidden-comment state |
| `viewerDidAuthor`, `viewerCanUpdate`, `viewerCanDelete` | `Boolean!` | permissions |
| `url` | `URI!` | permalink |

Deprecated, do not use: `position`, `originalPosition` ("We are phasing out
diff-relative positioning for PR comments ... Use the line and startLine
fields instead"), `databaseId` (use `fullDatabaseId`).

**A comment has no side field.** Live introspection of
`PullRequestReviewComment` lists only `line, originalLine, originalStartLine,
startLine` among line/side fields (`live`). `diffSide` / `startDiffSide` exist
only on the thread, so prrr must take the side from the thread and never from
a comment fetched via `PullRequestReview.comments` (relevant to section 2).

### Paste-ready query

```graphql
query Threads($owner: String!, $name: String!, $number: Int!, $cursor: String) {
  rateLimit { cost nodeCount remaining resetAt }
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id
      headRefOid
      baseRefOid
      reviewThreads(first: 100, after: $cursor) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          path
          line
          startLine
          diffSide
          startDiffSide
          originalLine
          originalStartLine
          isOutdated
          isResolved
          resolvedBy { login }
          subjectType
          viewerCanReply
          viewerCanResolve
          viewerCanUnresolve
          comments(first: 100) {
            totalCount
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              author { login }
              body
              createdAt
              publishedAt
              lastEditedAt
              state
              outdated
              diffHunk
              commit { oid }
              originalCommit { oid }
              replyTo { id }
              pullRequestReview { id state }
              viewerDidAuthor
              viewerCanUpdate
              viewerCanDelete
              url
            }
          }
        }
      }
    }
  }
}
```

### Pagination

- "Clients must supply a first or last argument on any connection." "Values
  of first and last must be within 1-100." "Individual calls cannot request
  more than 500,000 total nodes." (`ratelimits#node-limit`)
- Outer page: loop on `reviewThreads.pageInfo.hasNextPage` / `endCursor`.
- Inner page: a thread with more than 100 comments needs a follow-up on the
  thread node. `Query.node(id)` and `Query.nodes(ids)` exist (`live`
  introspection; the category docs no longer list the `Query` root fields
  under a stable anchor):

```graphql
query ThreadComments($id: ID!, $cursor: String) {
  node(id: $id) {
    ... on PullRequestReviewThread {
      comments(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes { id author { login } body createdAt state replyTo { id } pullRequestReview { id state } }
      }
    }
  }
}
```

  `comments` also accepts `skip (Int)` "Skips the first n elements in the
  list." (`pulls#object-pullrequestreviewthread`).

### Cost

Primary rate limit: "For users: 5,000 points per hour per user."
(`ratelimits#primary-rate-limit`). Point formula
(`ratelimits#predicting-the-point-value-of-a-query`):

> Add up the number of requests needed to fulfill each unique connection in
> the call. Assume every request will reach the first or last argument
> limits. Divide the number by 100 and round the result to the nearest whole
> number to get the final aggregate point value. ... The minimum point value
> of a call to the GraphQL API is 1.

Applied to `Threads` above: 1 request for `reviewThreads` + 100 (one
`comments` request per potential thread) = 101 → round(1.01) = **1 point per
page of 100 threads**, node count 100 + 100×100 = 10,100 (limit 500,000).

Verified live: the query above on `kubernetes/kubernetes#132761` returned
`rateLimit.cost = 1`, `nodeCount = 10100`, 54 threads / 121 comments in one
page (`live`).

So a PR with "hundreds of comments" costs ⌈threads/100⌉ points, i.e. 1–3
points out of 5,000/hour. Cost is driven by `first:` values, not by actual
data; shrinking `comments(first: 20)` does not change the rounded result.

Secondary limits that matter for a client that polls
(`ratelimits#secondary-rate-limits`,
`ratelimits#calculating-points-for-the-secondary-rate-limit`,
`ratelimits#staying-under-the-rate-limit`):

- "No more than 100 concurrent requests are allowed."
- "no more than 2,000 points per minute are allowed for the GraphQL API
  endpoint", where for this limit "GraphQL requests without mutations" count
  1 and "GraphQL requests with mutations" count 5.
- "no more than 80 content-generating requests per minute and no more than
  500 content-generating requests per hour".
- "you should pause at least 1 second between mutative requests and avoid
  concurrent requests."
- Timeouts: requests over 10 seconds are terminated with 502/504, and "If a
  timeout occurs ... additional points will be deducted from your primary
  rate limit for the next hour" (`ratelimits#timeouts`). Keep nested
  `first:` values moderate for huge PRs.

Response headers `x-ratelimit-limit`, `-remaining`, `-used`, `-reset` are
preferred over querying `rateLimit`
(`ratelimits#checking-the-status-of-your-primary-rate-limit`).

---

## 2. Fetching the viewer's Pending Review and its comments

`PullRequest.reviews(after, before, first, last, states: [PullRequestReviewState!], author: String)`,
with `author` "Filter by author of the review." (`pulls#object-pullrequest`;
arguments confirmed by `live` introspection). `PullRequestReviewState`
(`pulls#enum-pullrequestreviewstate`): `APPROVED` "A review allowing the pull
request to merge.", `CHANGES_REQUESTED` "A review blocking the pull request
from merging.", `COMMENTED` "An informational review.", `DISMISSED` "A review
that has been dismissed.", `PENDING` "A review that has not yet been
submitted."

`PullRequestReview` fields (`pulls#object-pullrequestreview`): `id`, `author`,
`body` "Identifies the pull request review body.", `state`, `submittedAt`
"Identifies when the Pull Request Review was submitted.", `createdAt`,
`commit` "Identifies the commit associated with this pull request review.",
`comments(after, before, first, last)`, `onBehalfOf` (teams), `viewerDidAuthor`,
`url`.

Same-query fetch (add to `Threads`, or run alone):

```graphql
query PendingReview($owner: String!, $name: String!, $number: Int!, $login: String!) {
  viewer { login }
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id
      reviews(first: 5, states: [PENDING], author: $login) {
        totalCount
        nodes {
          id
          state
          body
          createdAt
          commit { oid }
          comments(first: 100) {
            totalCount
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              body
              path
              line
              startLine
              subjectType
              state
              draftedAt
              replyTo { id }
              diffHunk
              commit { oid }
            }
          }
        }
      }
    }
  }
}
```

Notes:

- Get `$login` from `viewer { login }` first (or omit `author:` and filter on
  `viewerDidAuthor`).
- `latestReviews` explicitly excludes pending reviews ("that are not also
  pending review", `pulls#object-pullrequest`), so it cannot be used to find
  the Pending Review.
- `viewerLatestReview` is "The latest review given from the viewer."
  Whether it can return a `PENDING` review is **unverified**.
- Whether the viewer's pending comments also appear inside `reviewThreads`
  (as comments with `state: PENDING` and `pullRequestReview.state: PENDING`)
  is **unverified** from the docs. The schema allows it (`state`,
  `draftedAt`, `publishedAt` on comments). If prrr fetches both, dedupe on
  comment `id`, and remember that a comment fetched through
  `PullRequestReview.comments` carries **no side**; a brand-new pending
  thread's side must come from prrr's own record of what it posted
  (ticket 02) or from `reviewThreads` if it appears there.
- Whether other users' pending reviews are hidden from the API is
  **unverified** from the docs; the live query with `states: [PENDING]` and no
  `author` returned `totalCount: 0` on a PR with 54 threads (`live`), which
  is consistent with the UI rule but not proof.
- Cost: `reviews(first: 5)` + `comments(first: 100)` = 1 + 5 = 6 requests →
  1 point.

---

## 3. `resolveReviewThread` / `unresolveReviewThread`

`pulls#mutation-resolvereviewthread`: "Marks a review thread as resolved."
Input `ResolveReviewThreadInput!` (`pulls#input-object-resolvereviewthreadinput`):

- `threadId (ID!)` "The ID of the thread to resolve."
- `resolutionReason (PullRequestReviewThreadResolutionReason)` "The reason a
  Copilot code review thread was resolved." Values `ADDRESSED`, `INVALID`,
  `WONT_FIX` (`pulls#enum-pullrequestreviewthreadresolutionreason`). Optional;
  only meaningful for Copilot threads.
- `clientMutationId (String)`.

Returns `thread (PullRequestReviewThread)` "The thread to resolve." and
`clientMutationId`.

`pulls#mutation-unresolvereviewthread`: "Marks a review thread as
unresolved." Input `UnresolveReviewThreadInput!` with `threadId (ID!)` "The
ID of the thread to unresolve." (`pulls#input-object-unresolvereviewthreadinput`).
Returns `thread`.

```graphql
mutation Resolve($id: ID!) {
  resolveReviewThread(input: { threadId: $id }) {
    thread { id isResolved isCollapsed resolvedBy { login } viewerCanUnresolve }
  }
}

mutation Unresolve($id: ID!) {
  unresolveReviewThread(input: { threadId: $id }) {
    thread { id isResolved isCollapsed viewerCanResolve }
  }
}
```

Who may resolve (`ui-resolving`): "You can resolve a conversation in a pull
request if you opened the pull request or if you have write access to the
repository where the pull request was opened." The API exposes this per
thread as `viewerCanResolve` / `viewerCanUnresolve`
(`pulls#object-pullrequestreviewthread`); on the live sample (viewer without
write access, not the author) both were `false` (`live`). prrr should gate
its resolve command on these flags rather than guess from permissions.

Resolving does not need a refetch: the returned `thread` carries the new
`isResolved`. Mutations count 5 secondary-limit points and should be spaced
≥ 1 s apart (section 1).

---

## 4. The Viewed flag

### Reading

`PullRequest.files(after, before, first, last): PullRequestChangedFileConnection`
"Lists the files changed within this pull request." (`pulls#object-pullrequest`).
`PullRequestChangedFile` (`pulls#object-pullrequestchangedfile`):

| Field | Type | Description |
|---|---|---|
| `path` | `String!` | The path of the file. |
| `changeType` | `PatchStatus!` | How the file was changed in this PullRequest. |
| `additions` / `deletions` | `Int!` | The number of additions / deletions to the file. |
| `viewerViewedState` | `FileViewedState!` | The state of the file for the viewer. |

`FileViewedState` (`pulls#enum-fileviewedstate`), verbatim:

- `VIEWED` "The file has been marked as viewed."
- `UNVIEWED` "The file has not been marked as viewed."
- `DISMISSED` "The file has new changes since last viewed."

`PatchStatus` (`pulls#enum-patchstatus`): `ADDED` (git `A`), `CHANGED`
("The file's type was changed", `T`), `COPIED` (`C`), `DELETED` (`D`),
`MODIFIED` (`M`), `RENAMED` (`R`). Note there is no old-path field on
`PullRequestChangedFile`; for renames the API gives only the new `path`.

```graphql
query ViewedFiles($owner: String!, $name: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id
      changedFiles
      files(first: 100, after: $cursor) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes { path changeType additions deletions viewerViewedState }
      }
    }
  }
}
```

Cost: 1 request → 1 point per 100 files. (`changedFiles (Int!)` "The number
of changed files in this pull request." gives the total without paging.)

### Writing

`pulls#mutation-markfileasviewed` "Mark a pull request file as viewed." and
`pulls#mutation-unmarkfileasviewed` "Unmark a pull request file as viewed."
Inputs (`pulls#input-object-markfileasviewedinput`,
`pulls#input-object-unmarkfileasviewedinput`): `pullRequestId (ID!)` "The
Node ID of the pull request.", `path (String!)` "The path of the file to mark
as viewed." / "... as unviewed.", `clientMutationId`. Both return
`pullRequest (PullRequest)` "The updated pull request."

```graphql
mutation MarkViewed($pr: ID!, $path: String!) {
  markFileAsViewed(input: { pullRequestId: $pr, path: $path }) {
    pullRequest { id }
  }
}

mutation UnmarkViewed($pr: ID!, $path: String!) {
  unmarkFileAsViewed(input: { pullRequestId: $pr, path: $path }) {
    pullRequest { id }
  }
}
```

No field selection on the returned `pullRequest` yields the single file's
new state directly; `files(first: 100)` on the returned object re-reads all
of them if confirmation is wanted (cheap: 1 point).

### Reset rules

Documented (`ui-reviewing`): "After you finish reviewing a file, you can mark
the file as viewed. The file will collapse. If the file changes after you
view the file, it will be unmarked as viewed." The API represents that
unmarking as `DISMISSED` ("The file has new changes since last viewed"),
distinct from `UNVIEWED`.

**Unverified** (not stated in any primary source found): whether a
force-push that leaves a file's content identical resets it; whether merging
the base branch into the head resets files the merge touched; whether
"changes" is computed per file path against the head at the time of
marking. prrr should treat `VIEWED` as the only folded state and
`DISMISSED` as "unfolded, but show that it was viewed before".

Scope: the flag is keyed by (pull request, path, viewer) only. The mutation
takes no commit or range argument, so GitHub's Viewed flag is meaningful for
the default Range (merge base → head) only. For a non-default Range (ticket
09) prrr must keep its own per-Range viewed state locally; GitHub cannot
store it.

---

## 5. Reviews, review decision, and "new commits since my review"

### Reviews

- `reviews(...)`: "A list of reviews associated with the pull request."
  Filterable by `states` and `author` (section 2).
- `latestReviews(first..)`: "A list of latest reviews per user associated
  with the pull request that are not also pending review."
- `latestOpinionatedReviews(first.., writersOnly: Boolean = false)`: "A list
  of latest reviews per user associated with the pull request."
  `writersOnly`: "Only return reviews from user who have write access to the
  repository." What "opinionated" excludes (presumably `COMMENTED`) is
  **unverified**; the docs do not define it. Live runs were inconsistent:
  on the same PR, one run with `writersOnly: false` returned one `APPROVED`
  review and a later run without the argument returned none (`live`). Do
  not build Review State on this field without further testing.
- `viewerLatestReview (PullRequestReview)`: "The latest review given from the
  viewer."
- `viewerLatestReviewRequest (ReviewRequest)`: "The person who has requested
  the viewer for review on this pull request." (non-null means a review is
  currently requested from the viewer; ticket 04 covers queue filters).
- `reviewDecision (PullRequestReviewDecision)`: "The current status of this
  pull request with respect to code review." Values
  (`pulls#enum-pullrequestreviewdecision`): `APPROVED` "The pull request has
  received an approving review.", `CHANGES_REQUESTED` "Changes have been
  requested on the pull request.", `REVIEW_REQUIRED` "A review is required
  before the pull request can be merged." The field is nullable; the live
  sample returned `null` (`live`). The docs do not say when it is null
  (**unverified**; plausibly when the base branch has no review requirement).

All from `pulls#object-pullrequest`.

### Computing "new commits since my review" (Review State)

Signals available:

1. `PullRequestReview.commit` "Identifies the commit associated with this
   pull request review." (`pulls#object-pullrequestreview`) versus
   `PullRequest.headRefOid` "Identifies the oid of the head ref associated
   with the pull request, even if the ref has been deleted."
   (`pulls#object-pullrequest`). If the viewer's latest submitted review has
   `commit.oid != headRefOid`, the head moved after the review. This is the
   cheapest and does not depend on timestamps. Live sample reviews carried
   `commit { oid }` (`live`).
2. `timelineItems(first, after, itemTypes: [PullRequestTimelineItemsItemType!], since: DateTime, skip)`:
   "A list of events, comments, commits, etc. associated with the pull
   request." `itemTypes` "Filter timeline items by type.", `since` "Filter
   timeline items by a since timestamp." (`pulls#object-pullrequest`).
   Relevant item types (`pulls#enum-pullrequesttimelineitemsitemtype`):
   - `PULL_REQUEST_COMMIT` "Represents a Git commit part of a pull request."
     → `PullRequestCommit { commit { oid committedDate pushedDate messageHeadline } }`
     (`pulls#object-pullrequestcommit`, `commits#object-commit`: `pushedDate`
     "The datetime when this commit was pushed.", nullable).
   - `HEAD_REF_FORCE_PUSHED_EVENT` → `HeadRefForcePushedEvent { createdAt beforeCommit { oid } afterCommit { oid } }`
     (`pulls#object-headrefforcepushedevent`).
   - `PULL_REQUEST_REVIEW` → `PullRequestReview` (as above).
   - `REVIEW_REQUESTED_EVENT` → `ReviewRequestedEvent { createdAt requestedReviewer }`
     (`pulls#object-reviewrequestedevent`), and `REVIEW_REQUEST_REMOVED_EVENT`.
   - `REVIEW_DISMISSED_EVENT` → `ReviewDismissedEvent { previousReviewState pullRequestCommit { commit { oid } } review { id } }`
     where `pullRequestCommit` "Identifies the commit which caused the review
     to become stale." (`pulls#object-reviewdismissedevent`).
   - `PULL_REQUEST_REVISION_MARKER` → `PullRequestRevisionMarker { lastSeenCommit { oid } }`
     "Represents the latest point in the pull request timeline for which the
     viewer has seen the pull request's commits."
     (`pulls#object-pullrequestrevisionmarker`). This is GitHub's own
     "new commits since you last looked" marker (seen, not reviewed).

   Which timestamp `since` compares for `PULL_REQUEST_COMMIT` items
   (`committedDate` vs `pushedDate` vs insertion time) is **unverified**;
   prefer signal 1 for the boolean and use the timeline only to list what
   changed.
3. `PullRequest.commits(first..)` "A list of commits present in this pull
   request's head branch not present in the base branch." gives the current
   commit list for diffing against a stored list.

Paste-ready query combining them:

```graphql
query ReviewState($owner: String!, $name: String!, $number: Int!, $login: String!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id
      headRefOid
      baseRefOid
      reviewDecision
      viewerDidAuthor
      viewerLatestReviewRequest { id }
      viewerLatestReview { id state submittedAt commit { oid } }
      myReviews: reviews(last: 1, author: $login,
                         states: [APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED]) {
        nodes { id state submittedAt commit { oid } }
      }
      latestReviews(first: 100) {
        nodes { author { login } state submittedAt commit { oid } }
      }
      latestOpinionatedReviews(first: 100) {
        nodes { author { login } state submittedAt }
      }
      timelineItems(first: 100,
                    itemTypes: [PULL_REQUEST_COMMIT, HEAD_REF_FORCE_PUSHED_EVENT,
                                PULL_REQUEST_REVIEW, REVIEW_REQUESTED_EVENT,
                                REVIEW_REQUEST_REMOVED_EVENT, REVIEW_DISMISSED_EVENT]) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes {
          __typename
          ... on PullRequestCommit { commit { oid committedDate pushedDate messageHeadline } }
          ... on HeadRefForcePushedEvent { createdAt beforeCommit { oid } afterCommit { oid } }
          ... on PullRequestReview { id author { login } state submittedAt commit { oid } }
          ... on ReviewRequestedEvent { createdAt requestedReviewer { __typename ... on User { login } ... on Team { slug } } }
          ... on ReviewRequestRemovedEvent { createdAt }
          ... on ReviewDismissedEvent { createdAt previousReviewState pullRequestCommit { commit { oid } } review { id } }
        }
      }
    }
  }
}
```

Cost: five independent connections, each 1 request → 5 → 1 point. A variant
of this query ran live with `cost: 1`, `nodeCount: 660` (`live`). The
ordering of `reviews` (so that `last: 1` is the newest) is **unverified**
from the docs; the timeline order is chronological in the live sample
(`live`), so `timelineItems` with `PULL_REQUEST_REVIEW` is the safer source
if ordering matters.

Also from the UI docs (`ui-reviewing`, "Submitting your review"): "If both
required reviews and stale review dismissal are enabled and a code-modifying
commit is pushed to the branch of an approved pull request, the approval is
dismissed." That dismissal surfaces as `REVIEW_DISMISSED_EVENT` with
`pullRequestCommit`.

---

## 6. Description and Discussion Comments; what forge already stores

### API

- Description: `PullRequest.body (String!)` "The body as Markdown.",
  `bodyText` "The body rendered to text.", `bodyHTML`, `lastEditedAt`
  (`pulls#object-pullrequest`).
- Discussion Comments: `PullRequest.comments(after, before, first, last, orderBy: IssueCommentOrder): IssueCommentConnection!`
  "A list of comments associated with the pull request."
  (`pulls#object-pullrequest`). Node type `IssueComment`
  (`issues#object-issuecomment`) with `id`, `author`, `body`, `bodyText`,
  `createdAt`, `updatedAt`, `lastEditedAt`, `isMinimized`, `minimizedReason`,
  `url`, `viewerDidAuthor`, `viewerCanUpdate`, `viewerCanDelete`,
  `reactionGroups`. Live sample: 110 comments, fetched in one page (`live`).
  `PullRequest.totalCommentsCount` ("Returns a count of how many comments
  this pull request has received.") returned 236 on the same PR, so it is
  not the Discussion Comment count; use `comments.totalCount`.
- Posting one (Immediate Publish of a Discussion Comment):
  `addComment(input: { subjectId: <PullRequest id>, body })` "Adds a comment
  to an Issue or Pull Request." (`issues#mutation-addcomment`,
  `issues#input-object-addcommentinput`), returning `commentEdge { node { ... } }`.

```graphql
query Discussion($owner: String!, $name: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id
      title
      body
      lastEditedAt
      totalCommentsCount
      comments(first: 100, after: $cursor) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes {
          id author { login } body createdAt updatedAt lastEditedAt
          isMinimized minimizedReason viewerDidAuthor viewerCanUpdate url
        }
      }
    }
  }
}

mutation AddDiscussionComment($pr: ID!, $body: String!) {
  addComment(input: { subjectId: $pr, body: $body }) {
    commentEdge { node { id createdAt url } }
  }
}
```

### forge

`forge-pullreq` (`forge-pullreq.el:31-78`) is a closql class with, among
others, these slots: `id`, `repository`, `number`, `state`, `author`,
`title`, `created`, `updated`, `closed`, `merged`, `status`, `draft-p`,
`base-ref`, `base-repo`, `head-ref`, `head-user`, `head-repo`, `base-rev`,
`head-rev`, **`body`** (`:initarg :body`), **`posts`**
(`:closql-class forge-pullreq-post`), `review-requests`, `reviews`,
`timeline`, `commits`, `their-id`, `note`.

`forge-pullreq-post` (`forge-pullreq.el:111-125`) slots: `id`, `pullreq`,
`number`, `author`, `created`, `updated`, `body`, `edits`, `reactions`.

Conclusions:

- The PR description is stored: `(oref pullreq body)`.
- Discussion Comments are stored as `forge-pullreq-post` objects reachable
  through `(oref pullreq posts)`, each with `author`, `created`, `updated`,
  `body`. Public accessors (`forge-pullreq.el:131-199`, `forge-post.el:73-105`):
  `forge-get-pullreq` (methods on `forge-pullreq`, `(repo number)`,
  `integer`, `string` id, `forge-pullreq-post`, `(:branch &optional branch)`),
  `forge-current-pullreq`, `forge-pullreq-at-point`, `forge-read-pullreq`,
  `forge-get-topic`, `forge-get-repository`, `forge-post-at-point`,
  `forge-comment-at-point` (returns a `forge-pullreq-post` or
  `forge-issue-post` at point).
- `forge-pullreq-post` has **no** `path`, `line`, side, thread, review or
  state slot, so forge cannot represent Threads, Review Comments, File
  Comments or the Pending Review with their anchors. prrr needs its own store
  for section 1-2 data (ticket 07).
- Whether forge's GitHub fetcher also folds review comments into `posts`, and
  what the `reviews`, `timeline`, `commits` slots (no `:initarg`) contain, is
  **unverified** from `forge-pullreq.el` / `forge-post.el`; the ticket scope
  excluded forge's fetch code.
- `(oref pullreq id)` is forge's own composite id
  (`forge--object-id` in `forge-topic.el`), not GitHub's node ID, so it
  cannot be passed as `pullRequestId` / `subjectId`. Whether `their-id`
  holds the GitHub node ID is **unverified** from these files; if not, prrr
  must fetch `pullRequest(number:) { id }` once (section 5 query already
  returns it).

---

## Summary of unverified items

1. Whether `viewerLatestReview` can be `PENDING`.
2. Whether the viewer's pending comments appear inside `reviewThreads`.
3. Whether other users' pending reviews are hidden from the API (live
   evidence consistent, no doc statement).
4. Precise Viewed reset triggers beyond "if the file changes".
5. Semantics of `latestOpinionatedReviews` ("opinionated") and of a `null`
   `reviewDecision`.
6. Which timestamp `timelineItems(since:)` uses for commits; default ordering
   of `reviews`.
7. forge: contents of `reviews`/`timeline`/`commits` slots, whether `posts`
   includes review comments, and whether `their-id` is the GitHub node ID.
