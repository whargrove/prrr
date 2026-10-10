# prrr design map

Label: wayfinder:map
Tracker: local markdown (`.scratch/prrr-design/`). Tickets live in `issues/`.

## Destination

An approved `SPEC.md` at the repo root plus an implementation plan, with every
architectural question resolved so subagents can build the package from the
plan without stalling. Nothing is implemented on the way; prototypes are
throwaway.

## Notes

- Domain: an Emacs package, `prrr`, for reviewing GitHub pull requests on top
  of magit and forge. Glossary is `CONTEXT.md` at the repo root; every session
  uses its terms.
- Standing preferences (from the human):
  - Diff render performance is critical. Large diffs must open instantly, with
    per-file folding, a Viewed flag that folds a file away, and easy jumping
    between files.
  - Every action has a mnemonic single key and a transient menu that mirrors
    it exactly (Casual-style discoverability, magit-style speed).
  - Default workflow is a server-side Pending Review with batched Submit;
    Immediate Publish is an explicit override for one comment.
  - Depend only on forge's public API (EIEIO classes, `forge-get-*`,
    `forge-pull`, status-buffer section hooks) and ghub. Never call `forge--`
    privates or extend forge's database. prrr keeps its own SQLite database.
  - The human relies heavily on PR Stacks, both as author and reviewer.
  - Agent integration is bi-directional through a public API: an agent can add
    Pending Review comments as the user (to be read and edited before Submit),
    and the user can hand a PR plus pending comments to an agent from prrr.
    No agent code ships in the package.
  - Tree-sitter syntax highlighting of the diff is wanted if it is not a
    performance drag; off by default otherwise.
- Skills to consult when working tickets: `mattpocock-skills:grilling` and
  `mattpocock-skills:domain-modeling` for grilling tickets;
  `mattpocock-skills:prototype` for prototype tickets;
  `mattpocock-skills:research` for research tickets.
- Prior art the human has not used but suspects has sharp edges: pr-review.el,
  code-review.el. The human's own `~/.emacs.d/lisp/crit-review.el` holds
  reusable UX (region anchoring, capture buffer, next/prev, transient) and the
  agent handoff shape (JSON review file, emacsclient entry point).
- Settled before the map (recorded in `CONTEXT.md` and here, no ticket):
  Review Queue lives in the current repo's magit-status buffer only. Review
  Buffer derives from magit-diff-mode and diffs the local refs forge fetches.
  Threads render as real magit sections under the anchored line; File
  Comments at the top of their file section; outdated Threads in a folded
  section at the end of their file, and a buffer-level folded section for
  files no longer in the diff. The Review Buffer has folded header sections
  for the PR description and discussion, plus a key to forge's topic buffer.
  Non-default Ranges are read-only until research says otherwise. Team
  memberships are fetched once and cached with a refresh command. Nothing
  is merged from prrr.

## Decisions so far

<!-- one line per resolved ticket: [title](issues/NN-slug.md): gist -->

- [Research: GitHub API for Pending Reviews, comment anchoring, replies, and Ranges](issues/02-review-comment-api.md): GraphQL for the whole Pending Review lifecycle (`addPullRequestReview` with no event, `addPullRequestReviewThread` with file line + side, `startLine` for ranges, `subjectType: FILE` for files, `submitPullRequestReview` with the Verdict). Threads anchor to the review's commit; a diff between two arbitrary PR commits cannot take comments, so non-default Ranges stay read-only. Immediate Publish of one Review Comment is REST-only. Limits and deprecations listed in the findings.

## Not yet specified

- Testing strategy for the package: how to test rendering against recorded
  diffs and the API layer against recorded GitHub responses, without a live
  token. Sharpens once the data model and API surface are decided.
- Behaviour when the PR head moves while a review is open (rebases are common
  in Stacks): what happens to the Pending Review, the Viewed flags, and the
  open Review Buffer.
- Editing and deleting one's own comments, resolving and unresolving Threads,
  reactions, and GitHub "suggested changes" blocks: which of these are in v1
  and how they surface. Depends on the API research and the keymap.
- Notifications: whether prrr should tell the user about new activity on PRs
  in the Review Queue, or leave that to forge's notification support.
- Retry and offline behaviour for failed publish calls (the local queue
  mentioned in grilling) and how it interacts with the database.
- Error and conflict handling when the Pending Review on the server differs
  from what the database expects (for example, comments added from the web).

## Out of scope

- GitLab and every forge other than GitHub.
- Reviewing issues or discussions; only pull requests.
- A cross-repo Review Queue (the human chose current-repo only for now).
- AI-assisted review itself; only the extension points ship.
- Contributing any of this upstream into forge.
- Merging the PR from prrr; `forge-merge` exists.
