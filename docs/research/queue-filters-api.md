# Research: GitHub API for queue filters, team membership, and Stack detection

Answers `.scratch/prrr-design/issues/04-queue-filters-api.md`. Terms are those
of `CONTEXT.md` (Review Queue, Queue Filter, Queue Group, Review State, Stack,
Team).

## Sources

- **forge** 20260926.1226, commit `3074fce81303` (`forge-pkg.el:2-17`).
  Files below are relative to `~/.emacs.d/var/elpa/forge-20260926.1226/`.
  Symbols with a `forge--` prefix are private and prrr must not call them;
  they are cited here only to explain what forge stores.
- **forge manual**: `forge.info` in the same directory (node and line given).
- **closql** 20260925.1458 and **ghub** 20260925.1500 (same `elpa/` tree),
  cited only to explain forge's storage behaviour.
- **GitHub GraphQL schema** published by GitHub at
  <https://docs.github.com/public/fpt/schema.docs.graphql> (fetched 2026-10-10;
  line numbers are into that file, 75217 lines). Narrative docs pages cited by
  URL.
- Anything not confirmed from one of these is marked **unverified**.

## Summary

1. forge stores `draft-p`, `author`, `assignees`, `review-requests` (users
   only), `base-ref`, `base-rev`, `base-repo`, `head-ref`, `head-rev`,
   `head-repo`, `head-user`, `cross-repo-p`, `state`, `their-id` on
   `forge-pullreq`; all are read with `oref`. It does **not** store reviews
   (the `reviews` slot exists but is never filled for GitHub; reading it
   signals an error) and it does **not** store Team review requests.
2. Team membership is not in forge's database (the `forge-repository` `teams`
   slot is always nil in this version). prrr must query GitHub:
   `viewer { organizations { nodes { login teams(userLogins: [$me]) { nodes {
   slug combinedSlug } } } } }`. On a PR, `reviewRequests.nodes.requestedReviewer`
   is the union `RequestedReviewer = Bot | EnterpriseTeam | Mannequin | Team |
   User`.
3. A satisfied Team request is gone from `reviewRequests`. Detect "a
   teammate reviewed in my place" from the PR's reviews
   (`latestReviews { author { login } onBehalfOf { slug } }`) cross-checked
   with the user's Teams, and/or from `timelineItems(itemTypes:
   [REVIEW_REQUESTED_EVENT, REVIEW_REQUEST_REMOVED_EVENT])` whose
   `requestedReviewer` is one of the user's Teams.
4. Stack rule: PR A sits on PR B when both belong to the same
   `forge-repository`, both are `open`, `(oref A base-ref)` is non-nil and
   `equal` to `(oref B head-ref)`, and B is not cross-repository
   (`(oref B cross-repo-p)` nil, equivalently `(oref B head-repo)` equals
   `(oref B base-repo)`). The bottom of a Stack is the PR whose `base-ref`
   equals `(oref repo default-branch)`.
5. forge adds its own sections to `magit-status-sections-hook` with
   `magit-add-section-hook`; third parties are told to do the same with a
   wrapper around `forge-insert-topics`. `forge-add-repository` and
   `forge-add-pullreq-refspec` configure `+refs/pull/*/head:refs/pullreqs/*`
   on the upstream remote, so after a fetch PR number N's head is at
   `refs/pullreqs/N`; `forge-pull` itself only pulls API data and then runs a
   `git fetch` of the remote when a Git worktree is known.

## 1. What forge stores for each queue input, and how to read it

### The `forge-pullreq` class

`forge-pullreq` (`forge-pullreq.el:31-77`) declares these slots (among
others):

| Slot | Set from (GitHub) | Value |
|---|---|---|
| `number` | `.number` (`forge-github.el:622`) | integer |
| `state` | `.state` (`forge-github.el:625-628`) | `'open`, `'merged`, or `'rejected` (`CLOSED` maps to `rejected`) |
| `author` | `.author.login` (`forge-github.el:629`) | login string |
| `draft-p` | `.isDraft` (`forge-github.el:634`) | boolean |
| `cross-repo-p` | `.isCrossRepository` (`forge-github.el:637`) | boolean |
| `base-ref` | `.baseRef.name` (`forge-github.el:638`) | branch name, nil if GitHub returns no `baseRef` |
| `base-rev` | `.baseRefOid` (`forge-github.el:639`) | commit SHA string |
| `base-repo` | `.baseRef.repository.nameWithOwner` (`forge-github.el:640`) | `"owner/name"` |
| `head-ref` | `.headRef.name` (`forge-github.el:641`) | branch name, nil if the head branch was deleted |
| `head-rev` | `.headRefOid` (`forge-github.el:642`) | commit SHA string |
| `head-user` | `.headRef.repository.owner.login` (`forge-github.el:643`) | owner login of the head repository |
| `head-repo` | `.headRef.repository.nameWithOwner` (`forge-github.el:644`) | `"owner/name"` |
| `their-id` | `.id` (`forge-github.el:623`) | GitHub GraphQL node ID (use this for `pullRequestId` in mutations and `node(id:)` queries) |
| `assignees` | `.assignees` ids (`forge-github.el:661`) | join table, see below |
| `review-requests` | `.reviewRequests[].requestedReviewer` ids (`forge-github.el:662-664`) | join table, see below |
| `reviews` | **never set** | slot declared (`forge-pullreq.el:67`), no `oset` of it anywhere in forge (grep `oset .* reviews` over `*.el`: no hits) |

The GraphQL selection that feeds all of this is
`forge--github-repository-query`, `forge-github.el:169-201`. The relevant
fragment:

```
(baseRef name (repository nameWithOwner))        ; forge-github.el:189
baseRefOid                                        ; :190
(headRef name (repository (owner login) nameWithOwner))  ; :191
headRefOid                                        ; :192
(  assignees [(:edges t)] id)                     ; :193
(  reviewRequests [(:edges t)]
   (requestedReviewer "... on User { id }\n"))    ; :194-195
```

Note that forge asks for `baseRef`/`headRef` (nullable `Ref` objects, schema
`44559`, `44777`), not `baseRefName`/`headRefName` (non-null strings that
survive branch deletion, schema `44562-44564`, `44780-44782`). So forge's
`base-ref`/`head-ref` can be nil once the branch is deleted; forge itself
documents "On Github this is simply nil in the same situation"
(`forge-pullreq.el:221-224`).

Single-PR pulls (`forge-pull-topic`) reuse the same selection
(`forge-github.el:405-409` narrows `forge--github-repository-query`), so the
stored fields are identical either way.

### Public accessors

All slots above are read with `oref` on the object (EIEIO public API);
forge's own public code does the same, e.g. `(oref pullreq head-ref)`
(`forge-pullreq.el:220`) and `(oref topic review-requests)`
(`forge-topic.el:1127`).

- **Getting PR objects**: `forge-get-pullreq` is a public generic
  (`forge-core.el:224-225`) with methods for `(repo number)`
  (`forge-pullreq.el:140-144`), a bare `number` (`:146-148`, uses the current
  tracked repository), and an `id` string (`:150-151`).
  `forge-current-pullreq` / `forge-pullreq-at-point` return the PR at point
  (`forge-pullreq.el:169-186`).
- **Listing a repository's PRs**: `(oref repo pullreqs)` -- the slot is
  declared `:closql-class forge-pullreq` on the public `forge-repository`
  class (`forge-repo.el:79`); closql materialises it into a list of
  `forge-pullreq` objects on access (`closql.el:114-125`). There is no public
  `forge-ls-pullreqs`; forge's filtered listing goes through
  `forge--list-topics` with a `forge--topics-spec` (`forge-topic.el:614-716`),
  both private. A public alternative for custom SQL is `forge-sql` /
  `forge-sql-cdr` (`forge-db.el:63-75`).
- **The repository**: `forge-get-repository` (generic documented at
  `forge-core.el:139-216`; `:tracked?` returns the tracked repo or nil).
  Public slots used by prrr: `default-branch` (set from
  `.defaultBranchRef.name`, `forge-github.el:256`; declared
  `forge-repo.el:66`), `owner`, `name`, `remote`, `id`
  (`forge-repo.el:53-57`).
- **`assignees` and `review-requests`** both resolve through the `assignee`
  table. `(oref pr assignees)` runs `select assignee:* ... join
  pullreq-assignee` (`forge-pullreq.el:79-85`); `(oref pr review-requests)`
  runs the same against `pullreq-review-request` (`forge-pullreq.el:95-100`).
  Each element is the `cdr` of an `assignee` row, whose columns are
  `[repository id login name forge-id]` (`forge-db.el:138-143`), i.e. a list
  `(ID LOGIN NAME FORGE-ID)`; forge destructures it as `(_id login name)`
  (`forge-topic.el:1130-1131`). So "review requested from me" is
  `(assoc-string me (mapcar #'cadr (oref pr review-requests)))` style, with
  `cadr` being the login.
- **The user's login** ("me"): forge uses `ghub--username` (a `ghub--`
  private, e.g. `forge-topic.el:1187`), and forge's public docstring for
  `forge-insert-topics` recommends exactly that (`forge-topic.el:1176-1189`).
  It reads the Git variables `github.<host>.user` / `github.user`
  (`ghub.el:783-793`; manual "Setup for Githubcom", `forge.info:154-160`).
  A public equivalent is `(magit-get "github.user")` after the manual's
  setup; prrr should decide whether `ghub--username` counts as off-limits,
  since it is the only forge-sanctioned way to get the login.
- **`reviews`**: do not read it. The slot has no `:closql-*` property
  (`forge-pullreq.el:67`), so `closql-dref` falls through to `slot-unbound`
  (`closql.el:157`), which signals. The schema's `reviews` connection takes
  `author` and `states` filters (schema `45268-45298`); prrr must fetch
  reviews itself (see section 3). forge's public request helpers are the
  macros `forge-query` and `forge-rest` (`forge-client.el:38-45`, `:78-85`),
  which take a repository object as `obj-or-host`.

### Does `review-requests` keep Team requests?

**No.** The selection is `(requestedReviewer "... on User { id }\n")`
(`forge-github.el:195`): only the `User` member of the union is selected, so
a `Team` (or `Bot`, `Mannequin`, `EnterpriseTeam`) reviewer comes back with no
`id`. Storage then drops it:

- `forge--set-connections` maps each element through
  `(forge--object-id rid (alist-get 'id value))` (`forge-core.el:343-357`),
  and `forge--object-id` returns nil when given a nil id
  (`forge-topic.el:312-313`).
- The `pullreq-review-request` table declares `(id :not-null)`
  (`forge-db.el:471-473`), and forge calls `closql-dset` with
  `drop-unknown` = t (`forge-core.el:357`), whose insert is wrapped in
  `ignore-errors` (`closql.el:244-247`). A nil id therefore cannot be stored.
- Consistently, forge's own "request review" command sends `teamIds` as
  always-nil with the comment "TODO Investigate #742, track id, then use it
  here" (`forge-github.el:1204-1214`).

The exact shape ghub hands forge for an empty `requestedReviewer {}` object
is **unverified** (not traced through `ghub-graphql.el`), but every path ends
in the row being dropped.

### Does `review-requests` keep satisfied requests?

forge mirrors GitHub: on every pull, `closql-dset` deletes rows that are no
longer in the fetched list (`closql.el:222-228`) and inserts the new ones, so
the slot always equals GitHub's current `reviewRequests` as of the last
`forge-pull`. GitHub removes a request once that reviewer reviews:
"Requested reviewers are no longer listed in the search results after they
review a pull request" (search docs, see section 3 URL), and the API models
removal as a `ReviewRequestRemovedEvent` (schema `60145-60170`). So after a
pull, a request the user already answered is gone from `review-requests`;
prrr must not treat its absence as "never requested".

### The `teams` slot on `forge-repository`

`forge-repository` declares `teams` (`forge-repo.el:87`) and
`forge--update-repository` sets it from `.owner.teams`
(`forge-github.el:267`), but neither repository query selects `owner` at all
(`forge-github.el:58-199`), so the slot is always nil. Forge issue #742
(<https://github.com/magit/forge/issues/742>) records that fetching teams was
reverted in ghub because it failed for large organizations. prrr must obtain
Teams itself.

## 2. Teams: the query and how a team request appears on a PR

### The `RequestedReviewer` union

```
union RequestedReviewer = Bot | EnterpriseTeam | Mannequin | Team | User
```
(schema `59501`; docs: "Types that can be requested reviewers",
<https://docs.github.com/en/graphql/reference/pulls>, under "Pull requests"
unions.) `ReviewRequest.requestedReviewer: RequestedReviewer` (schema
`60096-60099`); `ReviewRequest` also has `asCodeOwner: Boolean!` ("Whether
this request was created for a code owner", schema `60076-60079`).

Selection that keeps both users and teams:

```graphql
reviewRequests(first: 100) {
  nodes {
    asCodeOwner
    requestedReviewer {
      __typename
      ... on User { login }
      ... on Team { slug combinedSlug }
    }
  }
}
```

`Team.slug` is "The slug corresponding to the team." (schema `66183-66186`)
and `Team.combinedSlug` is "The slug corresponding to the organization and
team." (schema `65878-65881`), e.g. `org/team` -- the same form the search
qualifier `team-review-requested:github/docs` uses (search docs below).

### Listing the viewer's Teams across organizations

`Query.viewer: User!` ("The currently authenticated user.", schema
`48751-48754`); `User.organizations` ("A list of organizations the user
belongs to.", schema `72819-72847`); `Organization.teams` ("A list of teams in
this organization.", schema `37001-37064`) with arguments `userLogins:
[String!]` ("User logins to filter by.", `37061-37063`) and `role: TeamRole`
("If non-null, filters teams according to whether the viewer is an admin or
member on team", `37051-37053`; `TeamRole` = `ADMIN | MEMBER`,
`67580-67590`). Docs page: <https://docs.github.com/en/graphql/reference/orgs>.

```graphql
query MyTeams {
  viewer {
    login
    organizations(first: 100) {
      nodes {
        login
        teams(first: 100, userLogins: [$me]) {   # or role: MEMBER
          nodes { slug combinedSlug }
        }
      }
    }
  }
}
```

`$me` must be the viewer's login (`viewer.login`, schema `72784-72787`).
Paginate both connections (`pageInfo`/`after`) for safety. Which token scope
this needs (`read:org` is the usual answer) is **unverified** here.

prrr's "review requested from one of my Teams" Queue Filter is then: some
`reviewRequests` node is a `Team` whose `combinedSlug` is in the viewer's
Team list. forge cannot answer this from its database (section 1).

Alternative without maintaining a Team list: `Query.search(type: ISSUE,
query: "is:pr is:open repo:OWNER/NAME review-requested:@me")` (schema
`48501-48535`). GitHub's search docs state that `review-requested:USERNAME`
also matches "If the requested person is on a team that is requested for
review", while `user-review-requested:@me` matches only direct requests and
`team-review-requested:TEAMNAME` matches team requests
(<https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests>,
section "Search by pull request review status and reviewer"). The
difference between the two qualifiers is exactly the "my Team" case.

## 3. Detecting that a teammate reviewed in my place

Once a requested reviewer reviews, the request is removed (section 1). For a
Team request GitHub's own "auto assignment" may also replace the Team with
individuals up front: "the team is removed as a reviewer and a specified
subset of team members are assigned in the team's place", except that with a
branch protection rule requiring code owner review the team request stays
(<https://docs.github.com/en/organizations/organizing-members-into-teams/managing-code-review-settings-for-your-team>).
So "request removed" alone does not tell who, if anyone, acted. Two API
signals do:

**(a) Reviews attributed to a Team.** `PullRequestReview.onBehalfOf:
TeamConnection!` -- "A list of teams that this review was made on behalf of."
(schema `46256-46279`; docs page "Pull requests", `PullRequestReview`). Use
`latestReviews` ("A list of latest reviews per user associated with the pull
request that are not also pending review.", schema `44909-44932`) or
`latestOpinionatedReviews` (`44879-44882`):

```graphql
latestReviews(first: 50) {
  nodes {
    author { login }
    state            # PullRequestReviewState: APPROVED | CHANGES_REQUESTED | COMMENTED | DISMISSED | PENDING (schema 46912-46937)
    submittedAt
    commit { oid }   # review was made against this head (schema 46195-46198)
    onBehalfOf(first: 10) { nodes { slug combinedSlug } }
  }
}
```

Rule: the Review State "reviewed by a teammate in my place" holds when some
review has `author.login` not equal to me and `onBehalfOf` contains one of my
Teams. Whether GitHub fills `onBehalfOf` for every review by a member of a
requested Team, or only when the reviewer explicitly picks the team on
submit, is **unverified**; treat it as sufficient, not necessary.

**(b) Timeline reconstruction.** `PullRequest.timelineItems(itemTypes:
[...], since: ...)` (schema `45419-45454`) with item types
`REVIEW_REQUESTED_EVENT` (`47994`), `REVIEW_REQUEST_REMOVED_EVENT` (`47999`)
and `PULL_REQUEST_REVIEW` (`47934`). `ReviewRequestedEvent.requestedReviewer`
("Identifies the reviewer whose review was requested.", `60196-60199`) and
`ReviewRequestRemovedEvent.requestedReviewer` ("Identifies the reviewer whose
review request was removed.", `60166-60169`) are both `RequestedReviewer`, so
`... on Team { combinedSlug }` works. A PR where one of my Teams was
requested (event exists) and is no longer in `reviewRequests`, and a
`PULL_REQUEST_REVIEW` by another member exists after that request, is
"reviewed by a teammate in my place". Membership of "another member" comes
from the Team list in section 2 (or `Team.members`, schema `65968-66011`).

**"New commits since my review"** (the other Review State): compare
`viewerLatestReview { commit { oid } }` ("The latest review given from the
viewer.", schema `45587-45590`) with forge's `(oref pr head-rev)`; or
`PULL_REQUEST_COMMIT` / `HEAD_REF_FORCE_PUSHED_EVENT` timeline items
(`47924`, `47814`) after `viewerLatestReview.submittedAt`.
`viewerLatestReviewRequest` ("The person who has requested the viewer for
review", `45592-45595`) looked like the API's own answer to "am I directly
requested", but live (2026-10-20, seeq12/crab#20848) it resolves to a
`ReviewRequest` for one of the viewer's Teams when only the Team was
requested, and it survives the viewer's review (threads-viewed-api.md). A
direct request is `(user me)` in `reviewRequests`, nothing else (prrr-ah1).

Repository-level `reviewDecision` (`APPROVED | CHANGES_REQUESTED |
REVIEW_REQUIRED`, schema `46852-46867`; field `45210-45213`) is about the PR
as a whole, not the viewer, so it is not a Review State input.

## 4. Stack detection from forge data

Definitions (section 1): `base-ref` = `baseRef.name`, `head-ref` =
`headRef.name`, `base-repo`/`head-repo` = the respective `nameWithOwner`,
`cross-repo-p` = `isCrossRepository` ("The head and base repositories are
different.", schema `44819-44822`).

Rule, in forge slots, for two `forge-pullreq` objects A and B:

```
A is stacked on B  iff
  (equal (oref A repository) (oref B repository))   ; same forge-repository id (forge-pullreq.el:38)
  (eq (oref A state) 'open) (eq (oref B state) 'open)
  (oref A base-ref)                                  ; non-nil
  (equal (oref A base-ref) (oref B head-ref))
  (not (oref B cross-repo-p))                        ; B's head branch lives in the base repository
```

Why the last clause: a PR's base is always a branch of its base repository,
and within one `forge-repository` every PR has the same `base-repo`. A fork
PR (`cross-repo-p` t) has its `head-ref` in the fork (`head-repo` differs,
`head-user` is the fork owner, `forge-github.el:643-644`), so a branch of the
same *name* in the base repository is a different branch; matching on name
alone would produce false Stacks. Equivalently require `(equal (oref B
head-repo) (oref A base-repo))`. A fork PR can itself be the *top* of a Stack
only if its base is another PR's head in the base repo, which the rule
already allows (A may be cross-repo; B may not).

Bottom of a Stack: `(equal (oref A base-ref) (oref repo default-branch))`
(`forge-repo.el:66`, `forge-github.el:256`). PRs whose `head-ref` is nil
(head branch deleted) cannot be a B; PRs whose `base-ref` is nil cannot be an
A. forge exposes the needed fields for cross-repo PRs too (same `oset`s run
for every PR, `forge-github.el:637-644`).

GitHub-side confirmation of the same relation: `Repository.pullRequests`
accepts `baseRefName` and `headRefName` filters ("The base ref name to filter
the pull requests by.", "The head ref name to filter the pull requests by.",
schema `55941-55958`), which is how one would find the PR below/above a given
PR without forge.

## 5. Status-buffer sections and the PR refspec

### How forge adds sections, and how a third party does

forge adds its three sections with

```elisp
(magit-add-section-hook 'magit-status-sections-hook #'forge-insert-pullreqs    nil t)
(magit-add-section-hook 'magit-status-sections-hook #'forge-insert-issues      nil t)
(magit-add-section-hook 'magit-status-sections-hook #'forge-insert-discussions nil t)
```
(`forge.el:88-91`, guarded by `forge-add-default-sections`, `forge.el:82-86`;
manual "Topic sections in Magit status buffers", `forge.info:836-866`). The
manual says the old hard-coded subset sections were removed and "you can use
the new `forge-insert-topics` helper function to define your own section
inserter functions" (`forge.info:858-862`).

`forge-insert-topics (type heading prepare)` is public (`forge-topic.el:1157`).
Its docstring (`forge-topic.el:1158-1198`) says to wrap it in your own
function and add that to the hook, and gives the pattern:

```elisp
(defun my-forge-insert-assigned-issues ()
  (forge-insert-topics 'assigned-issues "Assigned issues"
    (lambda (repo)
      (and-let* ((me (ghub--username repo)))
        (forge--topics-spec :type 'issue :active t :assignee me)))))
(magit-add-section-hook 'magit-status-sections-hook
                        #'my-forge-insert-assigned-issues
                        #'forge-insert-issues)
```

`forge-insert-topics` inserts nothing unless the database is open and the
repository is tracked (`forge-topic.el:1200-1203`). Its `prepare` must return
a `forge--topics-spec` (private class, `forge-topic.el:433`) whose filters are
`author`, `assignee`, `reviewer` (user login whose review was requested,
`forge-topic.el:565-573`), state, labels, etc.; there is no draft or Team
filter. Since prrr's Queue Filters (draft, Team, Review State, Stack) go
beyond what the spec supports, prrr's section should be its own function on
`magit-status-sections-hook` that selects PRs from `(oref repo pullreqs)` (or
`forge-sql`) and renders with `magit-insert-section`, as forge's own
`forge--insert-topics` does (`forge-topic.el:1205-1218`, private; the section
type it uses for a PR row is the symbol `pullreq`, `forge-topic.el:1221`, which
is what `forge-pullreq-at-point` recognises via `magit-section-value-if
'pullreq`, `forge-pullreq.el:183`).

`magit-add-section-hook (hook function &optional at append local)` is
magit-section's public API: FUNCTION is placed before AT (or after it with
APPEND), and `local` makes the change buffer-local (`magit-section.el:2302-
2315`). To put the Review Queue above forge's own list, use
`(magit-add-section-hook 'magit-status-sections-hook #'prrr-insert-review-queue
#'forge-insert-pullreqs)`.

### What `forge-pull` fetches, and the refspec

- The class-allocated slot `pullreq-refspec` is
  `"+refs/pull/*/head:refs/pullreqs/*"` for GitHub (`forge-github.el:48`;
  generic slot `forge-repo.el:50`).
- `forge-add-repository` adds that refspec to `remote.<remote>.fetch` when
  `forge-add-pullreq-refspec` is t (default) or the user says yes to `ask`
  (`forge-commands.el:29-43`, `:1376-1388`; manual "Initial Pull",
  `forge.info:584-587`). `forge-add-pullreq-refspec` does the same on demand
  and then runs `git fetch` (`forge-commands.el:1263-1280`; manual
  `forge.info:1260-1265`).
- `forge-pull` (`forge-commands.el:142-154`; manual "Pulling",
  `forge.info:1064-1073`) calls `forge--pull`, which fetches API data and,
  on completion, calls `forge--maybe-git-fetch` (`forge-github.el:239`),
  which runs `magit-git-fetch` of `(oref repo remote)` with the current
  `magit-fetch-arguments` in the status buffer or the repository's worktree
  (`forge-commands.el:177-189`). That Git fetch is what populates
  `refs/pullreqs/N`; forge itself never fetches individual PR refs.
- forge then expects PR N's head at `refs/pullreqs/N`: `forge--pullreq-ref`
  returns that ref if it verifies (`forge-pullreq.el:239-241`), and
  `forge--pullreq-range` builds `BASE..refs/pullreqs/N`, where BASE is
  `(oref pullreq base-rev)` when the head is already an ancestor of
  `REMOTE/base-ref`, else `REMOTE/base-ref` (`forge-pullreq.el:243-251`).

**Local-ref assumption for the spec**: after `forge-add-repository` with the
default settings and any `git fetch` of the upstream remote, the head commit
of PR N is available locally as `refs/pullreqs/N` and equals
`(oref pr head-rev)` as of that fetch; the base branch is available as
`<remote>/<base-ref>`. If the user disabled `forge-add-pullreq-refspec`,
`refs/pullreqs/N` may be absent, which `forge--pullreq-ref` already treats as
"no ref" (it returns nil); prrr should do the same check with
`magit-rev-verify` and fall back to fetching
`refs/pull/N/head` explicitly. The default Range (merge base to head) is
computable from `refs/pullreqs/N` and `<remote>/<base-ref>` with
`git merge-base`; `base-rev` stored by forge is GitHub's `baseRefOid` at pull
time, not the merge base.
