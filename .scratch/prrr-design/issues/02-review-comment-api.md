# Research: GitHub API for Pending Reviews, comment anchoring, replies, and Ranges

Type: research
Status: resolved
Part of: ../map.md

## Question

From GitHub's GraphQL and REST documentation (primary sources only), establish
exactly how prrr must call the API for the review-comment lifecycle:

1. Creating a Pending Review (`addPullRequestReview` with no event, or the
   REST equivalent), discovering an existing pending review for the viewer,
   and what happens if two exist.
2. Adding a Thread to a Pending Review on a single line, a multi-line range
   (`startLine`/`line`, `startSide`/`side`), and a whole file
   (`subjectType: FILE`), including what line numbers mean (file line at the
   commit, not diff position) and which side (LEFT/RIGHT) means what.
3. Replying to an existing Thread, both inside a Pending Review and as an
   Immediate Publish.
4. Immediate Publish of one comment, and of a Discussion Comment.
5. Submitting a Pending Review with each Verdict, editing and deleting pending
   comments before Submit, and discarding a Pending Review.
6. Commenting against a non-default Range: what `commitId` / `commit_id`
   means, whether comments may anchor to an intermediate commit of the PR
   branch, and whether a diff between two arbitrary PR commits can take
   comments at all.
7. Rate limits, pagination limits, and any known pitfalls (for example, the
   REST `position` field being deprecated).

Deliver as a findings file with the exact mutation or endpoint, required
fields, and a short note per item, so the spec can cite it.

## Answer

Findings: [docs/research/review-comment-api.md](../../../docs/research/review-comment-api.md).

Use GraphQL for the Pending Review lifecycle; current mutations address
lines by file line number at the commit plus a `side` (LEFT = deleted line,
old file number; RIGHT = added or context line, new file number), never by
diff position (deprecated in both APIs).

1. Create: `addPullRequestReview {pullRequestId}` with no `event` (REST:
   `POST .../pulls/{n}/reviews` with blank `event`). Discover with
   `pullRequest.reviews(states: [PENDING], author: <login>)`. No doc states
   the one-pending-review rule or the error on a second create: unverified;
   query first, treat a create error as "already exists".
2. Thread: `addPullRequestReviewThread {pullRequestReviewId, path, body,
   line, side}`; range adds `startLine, startSide` (`line`/`side` are the
   end); file comment uses `subjectType: FILE` with no line. No commit field:
   every thread anchors to the review's commit. Batch form
   `addPullRequestReview.threads` is line-only (no `subjectType`).
3. Reply: `addPullRequestReviewThreadReply {pullRequestReviewThreadId, body,
   pullRequestReviewId}`; omit the review id to publish now (unverified in
   docs). REST documented path: `POST .../pulls/{n}/comments/{id}/replies`
   (top-level comment id only, replies to replies unsupported).
4. Immediate Publish of one Review Comment: REST `POST .../pulls/{n}/
   comments {body, commit_id, path, line, side[, start_line, start_side,
   subject_type]}` is the only documented path; GraphQL equivalents are
   unverified. Discussion Comment: `addComment {subjectId, body}` or
   `POST .../issues/{n}/comments`.
5. Submit: `submitPullRequestReview {pullRequestReviewId, event, body}` with
   `APPROVE | REQUEST_CHANGES | COMMENT` (REST `POST .../reviews/{id}/
   events`). Edit/delete pending comments with
   `updatePullRequestReviewComment` / `deletePullRequestReviewComment`;
   discard with `deletePullRequestReview` (REST `DELETE .../reviews/{id}`,
   pending only).
6. `commitId` is the commit the comment applies to; GitHub remaps to head
   (`line`, `commit`) and keeps `originalLine`, `originalCommit`,
   `isOutdated`. The docs allow any SHA, so anchoring to an intermediate PR
   commit is permitted by contract (only via create-review `commitOID` or
   REST `commit_id`; unverified beyond the docs' wording). A diff between two
   arbitrary PR commits cannot take comments: there is no base-commit field,
   and LEFT always means the PR base. Non-default Ranges stay read-only;
   at most RIGHT-side/file comments via REST Immediate Publish could be
   allowed later.
7. 5,000 points/hour primary; secondary: 100 concurrent, 2,000 GraphQL
   points/min (mutation = 5), 80 content-creating requests/min and 500/hour,
   wait 1 s between mutations. `first`/`last` required and capped at 100;
   REST `per_page` max 100. Use `fullDatabaseId` when mixing with REST.
