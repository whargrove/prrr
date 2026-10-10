# GitHub API for the review-comment lifecycle

Research findings for ticket
[02-review-comment-api](../../.scratch/prrr-design/issues/02-review-comment-api.md).
Terms follow `CONTEXT.md` (Pending Review, Thread, Review Comment, File
Comment, Discussion Comment, Immediate Publish, Verdict, Submit, Range).

Sources are GitHub's own reference pages, read on 2026-10-10:

- GQL-PULLS: <https://docs.github.com/en/graphql/reference/pulls>
  (mutations, input objects, objects and enums for pull requests all live on
  this one page; the old `/graphql/reference/mutations` URL is now only an
  index)
- GQL-ISSUES: <https://docs.github.com/en/graphql/reference/issues>
- GQL-LIMITS: <https://docs.github.com/en/graphql/overview/rate-limits-and-node-limits-for-the-graphql-api>
- GQL-BREAKING: <https://docs.github.com/en/graphql/overview/breaking-changes>
- REST-REVIEWS: <https://docs.github.com/en/rest/pulls/reviews>
- REST-COMMENTS: <https://docs.github.com/en/rest/pulls/comments>
- REST-ISSUE-COMMENTS: <https://docs.github.com/en/rest/issues/comments>
- REST-LIMITS: <https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api>
- REST-BEST: <https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api>
- OPENAPI: <https://github.com/github/rest-api-description> (file
  `descriptions/api.github.com/api.github.com.json`; GitHub's own OpenAPI
  description, used only for response-schema field descriptions that the
  rendered docs page omits)
- UD-COMMENTING: <https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/commenting-on-a-pull-request>
- UD-REVIEWING: <https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/reviewing-proposed-changes-in-a-pull-request>

Anything the docs do not state is marked **unverified**. Nothing below was
confirmed by running calls against the API.

## Summary

Use GraphQL for everything in the Pending Review lifecycle; the current,
non-deprecated GraphQL mutations address lines by **file line number at the
commit** plus a `side`, which is exactly what a magit diff buffer can supply.
REST is documented with the same line/side model and is the fallback where
GraphQL is silent (notably Immediate Publish of one Review Comment, which REST
documents explicitly).

| Step | GraphQL | REST |
|---|---|---|
| Create Pending Review | `addPullRequestReview` with no `event` | `POST /repos/{o}/{r}/pulls/{n}/reviews` with no `event` |
| Find the viewer's Pending Review | `pullRequest.reviews(states: [PENDING], author: <login>, first: N)` | `GET /repos/{o}/{r}/pulls/{n}/reviews`, filter `state == "PENDING"` |
| Add a Thread (line, range, or file) | `addPullRequestReviewThread` with `pullRequestReviewId` | REST has no "add comment to pending review"; comments are passed inline on create (see item 2) |
| Reply inside the Pending Review | `addPullRequestReviewThreadReply` with `pullRequestReviewId` | unverified (see item 3) |
| Reply, Immediate Publish | `addPullRequestReviewThreadReply` without `pullRequestReviewId` (unverified) | `POST /repos/{o}/{r}/pulls/{n}/comments/{comment_id}/replies` |
| Immediate Publish of one Review Comment | `addPullRequestReview` with `event: COMMENT` and one `threads` entry (unverified side effects) | `POST /repos/{o}/{r}/pulls/{n}/comments` |
| Immediate Publish of a Discussion Comment | `addComment` with `subjectId` = PR node id | `POST /repos/{o}/{r}/issues/{n}/comments` |
| Edit a pending comment | `updatePullRequestReviewComment` | `PATCH /repos/{o}/{r}/pulls/comments/{comment_id}` |
| Delete a pending comment | `deletePullRequestReviewComment` | `DELETE /repos/{o}/{r}/pulls/comments/{comment_id}` |
| Edit the review body before Submit | `updatePullRequestReview` | `PUT /repos/{o}/{r}/pulls/{n}/reviews/{review_id}` |
| Submit with Verdict | `submitPullRequestReview` with `event: APPROVE \| REQUEST_CHANGES \| COMMENT` | `POST /repos/{o}/{r}/pulls/{n}/reviews/{review_id}/events` with `event` |
| Discard the Pending Review | `deletePullRequestReview` | `DELETE /repos/{o}/{r}/pulls/{n}/reviews/{review_id}` |

## 1. Creating and discovering a Pending Review

**Create (GraphQL).** `addPullRequestReview(input: AddPullRequestReviewInput!)`
"Adds a review to a Pull Request." Input fields: `pullRequestId: ID!`,
`body: String`, `commitOID: GitObjectID` ("The commit OID the review pertains
to"), `event: PullRequestReviewEvent` ("The event to perform on the pull
request review"), `threads: [DraftPullRequestReviewThread]`, and the
deprecated `comments: [DraftPullRequestReviewComment]` ("comments will be
removed. use the threads argument instead", scheduled 2023-10-01). Returns
`pullRequestReview` and `reviewEdge`. (GQL-PULLS)

The GraphQL page does not say in words that omitting `event` yields a PENDING
review; it is implied by `PullRequestReviewState.PENDING` = "A review that has
not yet been submitted" and by `submitPullRequestReview` = "Submits a pending
pull request review" (GQL-PULLS). The REST page says it outright: "To create
a pending review for a pull request, leave the event parameter blank" and
"By leaving this blank, you set the review action state to PENDING, which
means you will need to submit the pull request review when you are ready"
(REST-REVIEWS). So: call `addPullRequestReview` with `pullRequestId` only (no
`event`, no `body`), keep the returned `pullRequestReview.id`.

**Create (REST).** `POST /repos/{owner}/{repo}/pulls/{pull_number}/reviews`,
body params `commit_id` (optional, "Defaults to the most recent commit in the
pull request when you do not specify a value"), `body` ("Required when using
REQUEST_CHANGES or COMMENT for the event parameter"), `event` (APPROVE,
REQUEST_CHANGES, COMMENT, or blank for PENDING), `comments[]` (`path`
required, `body` required, `position`, `line`, `side`, `start_line`,
`start_side`). "Pull request reviews created in the PENDING state are not
submitted and therefore do not include the submitted_at property in the
response." Status 200; 422 "Validation failed, or the endpoint has been
spammed." (REST-REVIEWS)

**Discover (GraphQL).** `PullRequest.reviews` takes `states:
[PullRequestReviewState!]` ("A list of states to filter the reviews") and
`author: String` ("Filter by author of the review"), plus `first`/`last`
(required, 1-100). Query `reviews(states: [PENDING], author: "<viewer login>",
first: 10) { nodes { id state body commit { oid } comments(first: 100) {...} } }`.
A pending review's comments have `PullRequestReviewComment.state = PENDING`
("A comment that is part of a pending review"). (GQL-PULLS) `PullRequest.
viewerLatestReview` ("The latest review given from the viewer") exists, but
whether it returns a PENDING review is **unverified**; use `reviews(states:
[PENDING])`.

**Discover (REST).** `GET /repos/{owner}/{repo}/pulls/{pull_number}/reviews`
"Lists all reviews for a specified pull request. The list of reviews returns
in chronological order." (REST-REVIEWS). Filter client-side on `state ==
"PENDING"`. Whether other users' pending reviews are visible in this list is
not stated; UD-REVIEWING says pending comments are "only visible to you", so
expect only the viewer's own.

**Two pending reviews.** **Unverified.** No reference page states a
one-pending-review-per-user-per-PR rule or documents the error on a second
`addPullRequestReview`. The user docs describe "a" pending review in the
singular ("To cancel a pending review, including all of its pending
comments... Discard review", UD-REVIEWING). prrr should treat "exactly zero
or one PENDING review for the viewer" as the expected shape, query for it
before creating, and surface a 422/GraphQL error from a second create as
"a pending review already exists" rather than assuming it cannot happen.

## 2. Adding a Thread to a Pending Review

**Mutation.** `addPullRequestReviewThread(input:
AddPullRequestReviewThreadInput!)` "Adds a new thread to a pending Pull
Request Review." Returns `thread: PullRequestReviewThread`. Input fields
(GQL-PULLS):

| Field | Type | Doc text |
|---|---|---|
| `body` | `String!` | "Body of the thread's first comment." |
| `path` | `String` | "Path to the file being commented on." |
| `pullRequestId` | `ID` | "The node ID of the pull request reviewing." |
| `pullRequestReviewId` | `ID` | "The Node ID of the review to modify." |
| `line` | `Int` | "The line of the blob to which the thread refers, required for line-level threads. The end of the line range for multi-line comments." |
| `side` | `DiffSide` | "The side of the diff on which the line resides. For multi-line comments, this is the side for the end of the line range." |
| `startLine` | `Int` | "The first line of the range to which the comment refers." |
| `startSide` | `DiffSide` | "The side of the diff on which the start line resides." |
| `subjectType` | `PullRequestReviewThreadSubjectType` | "The level at which the comments in the corresponding thread are targeted, can be a diff line or a file." Values `LINE`, `FILE`. |

Note there is **no commit argument** on this input; the thread is anchored
against the pending review's commit (see item 6).

**Single line.** `{pullRequestReviewId, path, line, side, body}` (and
optionally `subjectType: LINE`).

**Range.** `{pullRequestReviewId, path, startLine, startSide, line, side,
body}`; `line`/`side` are the **end** of the range, `startLine`/`startSide`
the start (GQL-PULLS, quoted above). The REST equivalent says the same:
"`side` represents whether the last line of the comment range is a deletion
or addition", `start_line` "is the first line in the pull request diff that
your multi-line comment applies to", and `start_line`/`start_side` are
"Required when using multi-line comments unless using in_reply_to"
(REST-COMMENTS).

**Whole file.** `{pullRequestReviewId, path, subjectType: FILE, body}` with
no line. REST confirms `line` is "Required unless using subject_type:file"
(REST-COMMENTS).

**What line numbers mean.** `line` is "The line of the blob", i.e. a file
line number in the file as it exists on the given side, not a diff offset.
GraphQL's deprecation note is explicit: "Use the line and startLine fields
instead, which are file line numbers instead of diff line numbers"
(GQL-BREAKING, change to `PullRequestReviewComment.position` scheduled
2023-10-01). The REST `position` doc describes what the old scheme was: "the
number of lines down from the first "@@" hunk header in the file ... The
line just below the "@@" line is position 1" (REST-COMMENTS); do not use it.

**Which side is which.** `DiffSide`: `LEFT` "The left side of the diff",
`RIGHT` "The right side of the diff" (GQL-PULLS). REST spells out the
mapping: "Use LEFT for deletions that appear in red. Use RIGHT for additions
that appear in green or unchanged lines that appear in white and are shown
for context" (REST-COMMENTS). So in magit terms: a `-` line gets `side:
LEFT` with the line number from the old file; a `+` or context line gets
`side: RIGHT` with the line number from the new file. A range that starts on
a `-` line and ends on a `+` line uses `startSide: LEFT, side: RIGHT`.

**Line must be in the diff.** REST: `line` is "The line of the blob in the
pull request diff that the comment applies to" (REST-COMMENTS). The docs do
not say what error is returned for a line outside any hunk; **unverified**,
expect 422 / a GraphQL error.

**Batch alternative.** `addPullRequestReview.threads:
[DraftPullRequestReviewThread]` lets prrr create the review and several
threads in one mutation. `DraftPullRequestReviewThread` has `body: String!`,
`path`, `line` ("Required if not using positioning"), `side`, `startLine`,
`startSide`; it has **no `subjectType`**, so File Comments cannot be sent
this way (GQL-PULLS). Useful for the agent-API path (hand a batch of comments
to GitHub in one call) but line-only.

**Legacy, do not use.** `addPullRequestReviewComment` and every field of
`AddPullRequestReviewCommentInput` carry "will be removed. use
addPullRequestReviewThread or addPullRequestReviewThreadReply instead",
reason "We are deprecating the addPullRequestReviewComment mutation"
(GQL-PULLS, GQL-BREAKING, scheduled 2023-10-01). They are still present in
the schema as of this reading.

**REST.** REST has no endpoint that appends a comment to an existing pending
review. Comments go in the `comments[]` array of `POST .../reviews` at
creation time (REST-REVIEWS), or are published immediately via `POST
.../pulls/{n}/comments` (item 4). Whether `POST .../pulls/{n}/comments`
silently attaches to an existing pending review is **unverified**; its doc
describes it as creating a comment "on the diff", with no mention of pending
reviews.

## 3. Replying to a Thread

**Inside the Pending Review (GraphQL).** `addPullRequestReviewThreadReply(
input: AddPullRequestReviewThreadReplyInput!)` "Adds a reply to an existing
Pull Request Review Thread." Input: `body: String!` ("The text of the
reply"), `pullRequestReviewThreadId: ID!` ("The Node ID of the thread to
which this reply is being written"), `pullRequestReviewId: ID` ("The Node ID
of the pending review to which the reply will belong"). (GQL-PULLS) Pass the
pending review's id to batch the reply.

**Immediate Publish of a reply (GraphQL).** The same mutation with
`pullRequestReviewId` omitted. The docs do not say what happens then
(**unverified**); the field's description ("the pending review to which the
reply will belong") implies that without it the reply does not belong to a
pending review, i.e. it is published.

**Immediate Publish of a reply (REST, documented).** `POST
/repos/{owner}/{repo}/pulls/{pull_number}/comments/{comment_id}/replies`,
body `{body}`. "For the comment_id, provide the ID of the review comment you
are replying to. This must be the ID of a top-level review comment, not a
reply to that comment. Replies to replies are not supported." Status 201.
Alternatively `POST .../pulls/{n}/comments` with `in_reply_to` ("The ID of
the review comment to reply to ... When specified, all parameters other than
body in the request body are ignored"). (REST-COMMENTS) Both need the
**database id** of the thread's first comment (`PullRequestReviewComment.
fullDatabaseId`; `databaseId` is deprecated for removal 2024-07-01,
GQL-PULLS).

**Inside the Pending Review (REST).** **Unverified**; no REST endpoint
documents attaching a reply to a pending review.

## 4. Immediate Publish

**One Review Comment (REST, documented).** `POST
/repos/{owner}/{repo}/pulls/{pull_number}/comments` "Creates a review comment
on the diff of a specified pull request." Body: `body` (required),
`commit_id` (required, "The SHA of the commit needing a comment. Not using
the latest commit SHA may render your comment outdated if a subsequent
commit modifies the line you specify"), `path` (required), `line`
("Required unless using subject_type:file"), `side` (LEFT/RIGHT),
`start_line`, `start_side`, `subject_type` (`line` | `file`), `in_reply_to`,
and the closing-down `position`. Status 201. "This endpoint triggers
notifications. Creating content too quickly using this endpoint may result
in secondary rate limiting." (REST-COMMENTS)

**One Review Comment (GraphQL).** No mutation is documented as "publish one
line comment now". Two options, both **unverified** as to side effects:
(a) `addPullRequestReview` with `event: COMMENT`, `threads: [{...}]` and no
`body`, which per the REST description of the same operation creates and
submits a COMMENTED review in one call (REST-REVIEWS says `body` is
"Required when using REQUEST_CHANGES or COMMENT", so a body may be needed);
(b) `addPullRequestReviewThread` with `pullRequestId` but no
`pullRequestReviewId`. The GraphQL docs describe (b) only as adding "a new
thread to a pending Pull Request Review", so its behaviour without a pending
review is not documented. Recommend REST `POST .../pulls/{n}/comments` for
Immediate Publish; it is the one path GitHub documents for this, and ghub
exposes REST and GraphQL equally.

**Discussion Comment.** GraphQL `addComment(input: AddCommentInput!)` "Adds
a comment to an Issue or Pull Request", input `subjectId: ID!` (the PR's
node id), `body: String!`; returns `commentEdge`, `subject`, `timelineEdge`
(GQL-ISSUES). REST: `POST /repos/{owner}/{repo}/issues/{issue_number}/
comments` with `{body}`; "Every pull request is an issue, but not every issue
is a pull request" (REST-ISSUE-COMMENTS). Discussion Comments have no pending
state; they always publish immediately.

## 5. Submit, edit, delete, discard

**Submit (GraphQL).** `submitPullRequestReview(input:
SubmitPullRequestReviewInput!)` "Submits a pending pull request review."
Input: `event: PullRequestReviewEvent!` ("The event to send"), `body: String`
("The text field to set on the Pull Request Review"), `pullRequestReviewId:
ID` ("The Pull Request Review ID to submit"), `pullRequestId: ID` ("The Pull
Request ID to submit any pending reviews"). Returns `pullRequestReview`.
(GQL-PULLS) Verdict mapping: approve = `APPROVE` ("Submit feedback and
approve merging these changes"), request changes = `REQUEST_CHANGES` ("Submit
feedback that must be addressed before merging"), comment = `COMMENT`
("Submit general feedback without explicit approval"). The enum also has
`DISMISS` ("Dismiss review so it now longer effects merging"), which is not a
Verdict. (GQL-PULLS) Resulting `PullRequestReview.state` is `APPROVED`,
`CHANGES_REQUESTED`, or `COMMENTED` (GQL-PULLS).

**Submit (REST).** `POST /repos/{owner}/{repo}/pulls/{pull_number}/reviews/
{review_id}/events`, body `event` (required: APPROVE, REQUEST_CHANGES,
COMMENT; "When you leave this blank, the API returns HTTP 422") and optional
`body`. Status 200; 403, 404, 422. (REST-REVIEWS)

**Body required?** REST create says `body` is "Required when using
REQUEST_CHANGES or COMMENT for the event parameter" (REST-REVIEWS). REST
submit lists `body` as optional. GraphQL `submitPullRequestReview.body` is
optional in the schema. Whether GitHub rejects a `REQUEST_CHANGES` submit
with no body and no comments is **unverified**; prrr should allow an empty
summary for APPROVE and prompt for one otherwise.

**Edit a pending comment.** GraphQL `updatePullRequestReviewComment(input:
{pullRequestReviewCommentId: ID!, body: String!})` "Updates a pull request
review comment." REST `PATCH /repos/{owner}/{repo}/pulls/comments/
{comment_id}` with `{body}`, status 200. (GQL-PULLS, REST-COMMENTS) User
docs: "You can edit pending comments anytime before you submit your review"
(UD-REVIEWING).

**Delete a pending comment.** GraphQL `deletePullRequestReviewComment(input:
{id: ID!})` "Deletes a pull request review comment", returns the
`pullRequestReview` it belonged to. REST `DELETE /repos/{owner}/{repo}/pulls/
comments/{comment_id}`, status 204. (GQL-PULLS, REST-COMMENTS) Neither page
says what happens to the review when its last pending comment is deleted;
**unverified**.

**Edit the review summary.** GraphQL `updatePullRequestReview(input:
{pullRequestReviewId: ID!, body: String!})` "Updates the body of a pull
request review." REST `PUT /repos/{owner}/{repo}/pulls/{pull_number}/reviews/
{review_id}` with `{body}`, "Updates the contents of a specified review
summary comment." (GQL-PULLS, REST-REVIEWS) Since Submit takes `body`, prrr
can skip this and pass the summary at Submit time.

**Discard.** GraphQL `deletePullRequestReview(input: {pullRequestReviewId:
ID!})` "Deletes a pull request review." REST `DELETE /repos/{owner}/{repo}/
pulls/{pull_number}/reviews/{review_id}` "Deletes a pull request review that
has not been submitted. Submitted reviews cannot be deleted." Status 200;
404, 422. (GQL-PULLS, REST-REVIEWS) This is the API form of the UI's
"Discard review", which removes "a pending review, including all of its
pending comments" (UD-REVIEWING).

## 6. Non-default Ranges and `commitId`

**What the commit means.** REST review-comment object: `commit_id` = "The
SHA of the commit to which the comment applies", `original_commit_id` = "The
SHA of the original commit to which the comment applies" (OPENAPI). GraphQL
`PullRequestReviewComment.commit` = "Identifies the commit associated with
the comment", `originalCommit` = "Identifies the original commit associated
with the comment", `line`/`startLine` = the line "to which the comment
applies", `originalLine`/`originalStartLine` = the line "to which the
comment applied when it was first created" (GQL-PULLS). On the review:
`PullRequestReview.commit` "Identifies the commit associated with this pull
request review"; REST `commit_id` "A commit SHA for the review"
(GQL-PULLS, OPENAPI). Reading: a comment is anchored to a (commit, path,
line, side); GitHub later re-maps it to the current head (`line`, `commit`),
keeping the original anchor (`originalLine`, `originalCommit`), and flags
`PullRequestReviewThread.isOutdated` "whether this thread was outdated by
newer changes" (GQL-PULLS).

**Where the commit is chosen.** Only at review creation
(`addPullRequestReview.commitOID`, REST `commit_id`) and on REST immediate
comments (`commit_id`, required). `addPullRequestReviewThread` and
`DraftPullRequestReviewThread` have no commit field (GQL-PULLS), so every
Thread added to a Pending Review is anchored to the review's commit. prrr
must therefore pick the commit when it creates the Pending Review, and it
should be the PR head at that moment; REST says the default is "the most
recent commit in the pull request" and warns "Not using the latest commit SHA
may render your review comment outdated if a subsequent commit modifies the
line you specify" (REST-REVIEWS, REST-COMMENTS).

**Can a comment anchor to an intermediate commit?** The reference docs
permit any SHA syntactically: `commit_id` is "The SHA of the commit needing a
comment", with the only caveat being the outdated warning (REST-COMMENTS);
nothing says it must be the head. So anchoring to an intermediate commit of
the PR branch is allowed by the documented contract, with the line number
interpreted against the file **at that commit** and GitHub remapping it to
the head afterwards. Whether GitHub validates that the SHA is on the PR
branch, and what it does when the commented line does not survive to the
head (presumably `isOutdated`), is **unverified**.

**A diff between two arbitrary PR commits.** Not supported as a comment
target. Every anchoring field in both APIs is (one commit, path, line, side):
there is no "base commit" parameter anywhere in `AddPullRequestReviewThread
Input`, `DraftPullRequestReviewThread`, `AddPullRequestReviewInput`, or the
REST create-comment body (GQL-PULLS, REST-COMMENTS). `side: LEFT` means the
deleted line in the **PR's** diff ("deletions that appear in red",
REST-COMMENTS), i.e. the base-branch version, not an arbitrary older PR
commit. A comment on the RIGHT side of a `A..B` diff where `B` is an
intermediate PR commit can be expressed as `commit_id = B, line = <line at
B>, side = RIGHT`; a comment on the LEFT side of such a diff (a line as it
was at `A`, an intermediate commit) has no representation. Consequently a
non-default Range can be writable only for RIGHT-side and FILE comments with
`commit_id` = the Range's end commit, and only via REST Immediate Publish
(the Pending Review has one commit for all its threads). This confirms the
map's "non-default Ranges are read-only" default; lifting it is possible but
partial.

## 7. Limits and pitfalls

**Primary rate limits.** GraphQL: "For users: 5,000 points per hour per
user", query cost = unique connection requests / 100, minimum 1 point per
call; check `x-ratelimit-*` headers or `rateLimit { limit remaining used
resetAt cost }` (GQL-LIMITS). REST: "personal rate limit of 5,000 requests
per hour" (REST-LIMITS).

**Secondary rate limits (shared REST + GraphQL).** "No more than 100
concurrent requests"; "no more than 900 points per minute ... for REST API
endpoints, and no more than 2,000 points per minute ... for the GraphQL API
endpoint" where "GraphQL requests without mutations 1" point and "GraphQL
requests with mutations 5" points; and "no more than 80 content-generating
requests per minute and no more than 500 content-generating requests per
hour ... Some endpoints have lower content creation limits. Content creation
limits include actions taken on the GitHub web interface as well as via the
REST API and GraphQL API." (GQL-LIMITS, REST-LIMITS) Guidance: "pause at
least 1 second between mutative requests and avoid concurrent requests"
(GQL-LIMITS); "wait at least one second between each" POST/PATCH/PUT/DELETE;
on a secondary limit honour `retry-after`, else `x-ratelimit-reset`, else
wait a minute, then back off exponentially; "Continuing to make requests
while you are rate limited may result in the banning of your integration"
(REST-BEST, GQL-LIMITS). Implication for prrr: serialise mutations (one
queue), and when an agent hands over many comments, send them as one
`addPullRequestReview.threads` batch rather than N `addPullRequestReviewThread`
calls where File Comments are not involved.

**Pagination.** GraphQL: "Clients must supply a first or last argument on any
connection", "Values of first and last must be within 1-100", and a call may
not request "more than 500,000 total nodes" (GQL-LIMITS). REST: `per_page`
"The number of results per page (max 100)" on list endpoints (REST-COMMENTS).
`PullRequestReviewThread.comments` additionally accepts `skip: Int`
(GQL-PULLS).

**Deprecated positioning.** GraphQL `PullRequestReviewComment.position` and
`originalPosition` ("We are phasing out diff-relative positioning for PR
comments", removal scheduled 2023-10-01), `AddPullRequestReviewInput.comments`,
and all of `addPullRequestReviewComment` are deprecated (GQL-PULLS,
GQL-BREAKING). REST `position` "is closing down. Use line instead"
(REST-COMMENTS, OPENAPI). All are still served as of 2026-10-10; prrr must
not read or write them.

**Database ids.** GraphQL `databaseId` on reviews and comments is deprecated
("does not support 64-bit signed integer identifiers. Use fullDatabaseId
instead. Removal on 2024-07-01"); REST endpoints key on the numeric id, so
fetch `fullDatabaseId` when mixing APIs (GQL-PULLS).

**Replies to replies.** REST: "Replies to replies are not supported"; reply
to the thread's top-level comment (REST-COMMENTS). GraphQL replies take the
thread id, which sidesteps this.

**Notifications.** Immediate Publish endpoints "trigger notifications"
(REST-COMMENTS, REST-ISSUE-COMMENTS); "Batching your comments avoids sending
multiple notifications" (UD-COMMENTING). This is the user-facing reason the
Pending Review is the default.

**Discovery URL churn.** GitHub has reorganised the GraphQL reference by
category; `/graphql/reference/mutations` and `/input-objects` are now index
pages, and the pull-request material is at `/graphql/reference/pulls`
(observed 2026-10-10). Cite the category pages.

## Open items (unverified, candidates for a prototype ticket)

1. Error returned by a second `addPullRequestReview` while one is PENDING.
2. Behaviour of `addPullRequestReviewThread` / `addPullRequestReviewThreadReply`
   with `pullRequestReviewId` omitted (does it publish, or create a pending
   review?).
3. Whether `viewerLatestReview` includes a PENDING review.
4. Whether a `REQUEST_CHANGES`/`COMMENT` submit with empty body is rejected.
5. Error for a `line` outside any hunk; validation of a `commit_id` that is
   not on the PR branch; how an intermediate-commit comment is remapped.
6. What happens to a pending review whose last comment is deleted.
