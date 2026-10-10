# prrr: domain glossary

prrr (🐱) is an Emacs package for reviewing GitHub pull requests on top of
magit and forge. This file is the glossary: the canonical names for the things
the package deals with. No implementation details live here.

## Terms

- **Pull Request (PR)**: a GitHub pull request, as forge models it. prrr never
  creates or merges PRs; it reviews them.
- **Review Queue**: the section in a repository's magit-status buffer listing
  the PRs that need the user's attention, selected by the queue filters.
- **Queue Filter**: one criterion deciding whether a PR is in the Review Queue
  (for example: not a draft, review requested from me, review requested from
  one of my teams, assigned to me).
- **Queue Group**: a named partition of the Review Queue. There are two:
  **For Me** (PRs by others that match a Queue Filter) and **Mine** (PRs the
  user authored). A PR stays in its group after the user reviews it; its
  Review State changes instead.
- **Awaiting me** / **Served**: the two partitions of the For Me group. A PR
  is Awaiting me while it needs the user's review (requested, team-requested,
  new commits since the user's review, or assigned and never reviewed); it is
  Served once the user has touched it and nothing was pushed since, or a
  teammate reviewed in the user's place.
- **Touch**: any comment, review, or Immediate Publish by the user on a PR.
  A touch moves the PR from Awaiting me to Served.
- **Review State**: the user's standing on a PR: awaiting my review, reviewed
  by me (with the Verdict given), reviewed by a teammate in my place, or new
  commits since my review. Shown next to every PR in the Review Queue.
- **Stack**: a chain of PRs where each PR's base branch is the head branch of
  the PR below it. The bottom PR targets the repository's default branch. A
  reviewer moves up and down a Stack without leaving prrr.
- **Team**: a GitHub organization team the user belongs to. Used only to
  evaluate the "review requested from my team" filter.
- **Review Buffer**: the buffer in which one PR is reviewed: its diff, its
  threads, and the controls to comment and submit.
- **Range**: the pair of commits whose diff the Review Buffer is showing. The
  default Range is the PR's merge base to its head.
- **Thread**: a GitHub review conversation anchored to a file, a line, or a
  range of lines in the PR's diff. A Thread is either open or resolved. A
  Thread whose anchor no longer exists in the current diff is **outdated**.
- **Review Comment**: one message inside a Thread.
- **File Comment**: a Thread anchored to a whole file rather than to lines.
- **Discussion Comment**: a top-level comment on the PR that is not anchored
  to code.
- **Pending Review**: the user's batch of Review Comments that have been
  written but not yet submitted. GitHub holds it; only the author can see it.
- **Immediate Publish**: posting a single Review Comment or Discussion Comment
  straight to the PR, bypassing the Pending Review.
- **Verdict**: the choice made when submitting a Pending Review: approve,
  request changes, or comment.
- **Submit**: sending the Pending Review to GitHub with a Verdict and an
  optional summary body.
- **Outbox**: the user's comments and Viewed changes that prrr has written
  locally but GitHub has not yet accepted. Shown distinctly until they are
  sent; can be retried or discarded.
- **Bookmark**: prrr's own record of the last PR head the user opened, used
  to show what is new since the user last looked, independent of GitHub's
  review history.
- **Viewed**: the per-file flag marking that the user has finished looking at a
  file in the current Range. A Viewed file is folded away. GitHub stores this
  flag and clears it when the file changes.
