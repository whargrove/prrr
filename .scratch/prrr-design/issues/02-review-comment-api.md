# Research: GitHub API for Pending Reviews, comment anchoring, replies, and Ranges

Type: research
Status: open
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
