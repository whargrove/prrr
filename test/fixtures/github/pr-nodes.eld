;; The batch refresh of PRs already in the queue, as the forge-query
;; callback receives it: nodes(ids:) with the queue fields plus state.
;; PR 1 has a new head since the queue fixture, PR 2 was merged, and
;; the third id named a node GitHub no longer returns.  Re-record with
;; scripts/record-fixtures.el, then replace every real name with an
;; `example' name.
(data
 (nodes
  ((id . "PR_kwDOexample0000001")
   (number . 1)
   (state . "OPEN")
   (headRefOid . "1111111111111111111111111111111111111112")
   (createdAt . "2026-09-01T09:00:00Z")
   (isDraft)
   (author (login . "example-alice"))
   (reviewRequests
    ((requestedReviewer (__typename . "User") (login . "example-me"))))
   (latestReviews
    ((author (login . "example-bob"))
     (state . "APPROVED")
     (submittedAt . "2026-09-02T10:00:00Z")
     (commit (oid . "1111111111111111111111111111111111111111"))
     (onBehalfOf ((combinedSlug . "example-org/reviewers")))))
   (viewerLatestReview)
   (viewerLatestReviewRequest (id . "RR_kwDOexample0000001"))
   (assignees ((login . "example-me"))))
  ((id . "PR_kwDOexample0000002")
   (number . 2)
   (state . "MERGED")
   (headRefOid . "2222222222222222222222222222222222222222")
   (createdAt . "2026-09-03T08:00:00Z")
   (isDraft . t)
   (author (login . "example-bob"))
   (reviewRequests)
   (latestReviews)
   (viewerLatestReview)
   (viewerLatestReviewRequest)
   (assignees))
  nil))
