# Research: GitHub API for queue filters, team membership, and Stack detection

Type: research
Status: resolved
Part of: ../map.md

## Question

From GitHub's GraphQL documentation and forge's public API (read the forge
sources in `~/.emacs.d/var/elpa/forge-*/`, public symbols only), establish:

1. Which of the queue inputs forge already stores on `forge-pullreq` and
   `forge-repository` (draft-p, review-requests including Team requests,
   assignees, author, base-ref, head-ref, head-rev, reviews) and how each is
   read with public accessors. Note whether forge's `review-requests` keeps a
   requested Team or only users, and whether it keeps requests that GitHub
   has already satisfied.
2. The GraphQL query to list the viewer's Teams across organizations, and how
   a team review request is represented on a PR (`requestedReviewer` union).
3. How to detect that a teammate reviewed in the user's place (a Team request
   satisfied by another member) when the request itself has been removed.
4. Stack detection from forge data: a PR whose `base-ref` equals another open
   PR's `head-ref` in the same repository. Confirm forge exposes both for
   cross-repo (fork) PRs too and what the fields hold.
5. Whether forge exposes a public hook or section function to add a custom
   section to magit-status (`forge-insert-*` functions and
   `magit-status-sections-hook` conventions), and what `forge-pull` fetches
   (`refs/pull/*/head` refspec) so the spec can state the local-ref assumption.

Deliver as a findings file so the spec can cite the queries and accessors.

## Answer

Findings: [docs/research/queue-filters-api.md](../../../docs/research/queue-filters-api.md)
(forge 20260926.1226, GitHub GraphQL schema fetched 2026-10-10; every claim
cites file:line or URL).

1. forge stores `draft-p`, `author`, `assignees`, `review-requests`,
   `base-ref`/`base-rev`/`base-repo`, `head-ref`/`head-rev`/`head-repo`/
   `head-user`, `cross-repo-p`, `state`, `their-id` on `forge-pullreq`; read
   with `oref`. `assignees`/`review-requests` are lists of
   `(ID LOGIN NAME FORGE-ID)`. forge's query selects only `... on User { id }`
   for `requestedReviewer`, so Team requests are dropped; the slot mirrors
   GitHub's current `reviewRequests` at pull time, so satisfied requests are
   gone. The `reviews` slot is never filled (reading it signals). The
   `forge-repository` `teams` slot is always nil in this version.
2. Teams: `viewer { organizations { nodes { login teams(userLogins:[$me]) {
   nodes { slug combinedSlug } } } } }`; on a PR `requestedReviewer` is
   `Bot | EnterpriseTeam | Mannequin | Team | User`.
3. Teammate-in-my-place: `latestReviews { author { login } onBehalfOf { slug } }`
   against my Team list, and/or `timelineItems(itemTypes:
   [REVIEW_REQUESTED_EVENT, REVIEW_REQUEST_REMOVED_EVENT, PULL_REQUEST_REVIEW])`
   with `requestedReviewer { ... on Team { combinedSlug } }`.
4. Stack: same `repository`, both `open`, `(oref A base-ref)` non-nil and
   `equal` to `(oref B head-ref)`, and `(oref B cross-repo-p)` nil. Bottom
   PR: `base-ref` equals `(oref repo default-branch)`.
5. forge adds `forge-insert-pullreqs` etc. to `magit-status-sections-hook`
   via `magit-add-section-hook`; third parties do the same (public
   `forge-insert-topics` needs the private `forge--topics-spec`, so prrr
   should write its own inserter over `(oref repo pullreqs)`). Refspec:
   `+refs/pull/*/head:refs/pullreqs/*` added by `forge-add-repository` /
   `forge-add-pullreq-refspec`; `forge-pull` pulls API data then runs
   `git fetch <remote>`, so PR N's head is at `refs/pullreqs/N`.
