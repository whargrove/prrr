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
- **Viewed**: the per-file flag marking that the user has finished looking at a
  file in the current Range. A Viewed file is folded away. GitHub stores this
  flag and clears it when the file changes.
