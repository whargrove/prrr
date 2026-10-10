# Research: GitHub API for fetching Threads, resolving them, and the Viewed flag

Type: research
Status: open
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
