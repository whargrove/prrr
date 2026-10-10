# Agent extension API: bi-directional surface

Type: grilling
Status: open
Blocked by: 07
Part of: ../map.md

## Question

Decide the public API that lets an agent work with a review and lets the
user hand a review to an agent. Inputs: crit-review.el's handoff
(`crit-review-start` via emacsclient, JSON file with comments and anchors,
`crit-review-reply`) and the human's preferences in the map Notes. Decide:
the Elisp functions and their data shapes (list Threads for a PR, read the
Pending Review, add a pending comment on a line/range/file as the user, reply,
read the diff for a Range); how agent-authored pending comments are marked
so the user can review and edit them before Submit; the hooks fired on
comment create, reply, submit; the command that invokes an agent with the PR
and pending comments (agent-shell first, but generic); and whether a JSON
serialization ships in v1 or is deferred. Keep agent code out of the package.
