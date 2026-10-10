# Research: GitHub API for fetching Threads, resolving them, and the Viewed flag

Type: research
Status: resolved
Part of: ../map.md

## Question

From GitHub's GraphQL documentation (primary sources only), establish how prrr
fetches and mutates review state per PR:

1. The `reviewThreads` query: every field prrr needs (path, line, startLine,
   diffSide, isOutdated, isResolved, originalLine, originalCommit,
   subjectType, comments with author/body/createdAt/replyTo/pullRequestReview
   state), pagination, and the cost in GraphQL rate-limit points for a PR with
   hundreds of comments.
2. Fetching the viewer's own Pending Review and its comments in the same or a
   separate query.
3. `resolveReviewThread` / `unresolveReviewThread`.
4. The Viewed flag: `viewerViewedState` on `PullRequest.files`,
   `markFileAsViewed` / `unmarkFileAsViewed`, and when GitHub resets the flag.
5. `reviews` and `latestReviews` / `latestOpinionatedReviews`,
   `reviewDecision`, and timeline events needed to compute "new commits since
   my review".
6. Fetching the PR's Discussion Comments and description (or confirming forge
   already stores these publicly: check `forge-pullreq` slots `body` and
   `posts`).

Deliver as a findings file with queries that can be pasted into GitHub's
explorer, so the spec can cite them.

## Answer

Findings, with paste-ready queries and per-claim citations:
[docs/research/threads-viewed-api.md](../../../docs/research/threads-viewed-api.md).

1. Threads come from `PullRequest.reviewThreads(first: 100)` with nested
   `comments(first: 100)`; the thread carries `path`, `line`, `startLine`,
   `diffSide`, `startDiffSide`, `originalLine`, `isOutdated`, `isResolved`,
   `subjectType` (`LINE`/`FILE`), `viewerCanResolve`; each comment carries
   `author`, `body`, `createdAt`, `state` (`PENDING`/`SUBMITTED`), `replyTo`,
   `commit`, `originalCommit`, `pullRequestReview { state }`. Comments have
   no side field. One page of 100 threads x 100 comments costs 1 point
   (1 + 100 requests, /100, rounded), 10,100 nodes; a PR with hundreds of
   comments is 1-3 points of the 5,000/hour budget. Over-long threads are
   paged via `node(id:) { ... on PullRequestReviewThread { comments } }`.
2. The Pending Review is `reviews(states: [PENDING], author: $login)` with
   its `comments`; `latestReviews` excludes pending by definition. Whether
   pending comments also appear in `reviewThreads` is unverified.
3. `resolveReviewThread` / `unresolveReviewThread` take `threadId` and
   return the updated `thread`; gate on `viewerCanResolve` /
   `viewerCanUnresolve` (author or write access).
4. Viewed: `files { path changeType viewerViewedState }` with
   `VIEWED` / `UNVIEWED` / `DISMISSED` ("new changes since last viewed");
   `markFileAsViewed` / `unmarkFileAsViewed` take `pullRequestId` + `path`.
   GitHub unmarks a file "if the file changes after you view the file"; the
   flag is per (PR, path, viewer) with no commit argument, so it only fits
   the default Range. Finer reset rules are unverified.
5. "New commits since my review": compare the viewer's latest submitted
   review's `commit.oid` with `headRefOid`; list changes with
   `timelineItems(itemTypes: [PULL_REQUEST_COMMIT, HEAD_REF_FORCE_PUSHED_EVENT,
   PULL_REQUEST_REVIEW, REVIEW_REQUESTED_EVENT, REVIEW_DISMISSED_EVENT])`.
   `reviewDecision` is `APPROVED` / `CHANGES_REQUESTED` / `REVIEW_REQUIRED`
   or null. `latestOpinionatedReviews` behaved inconsistently live.
6. forge stores the description in `forge-pullreq` slot `body` and the
   Discussion Comments as `forge-pullreq-post` objects in slot `posts`
   (`author`, `created`, `updated`, `body`); `forge-pullreq-post` has no
   path/line/side/review slots, so Threads need prrr's own store. The
   GitHub node ID for mutations must be fetched (`pullRequest { id }`);
   forge's `id` is its own composite key.
