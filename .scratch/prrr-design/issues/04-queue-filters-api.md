# Research: GitHub API for queue filters, team membership, and Stack detection

Type: research
Status: open
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
