# prrr 🐱

Review GitHub pull requests in Emacs, on top of [magit](https://magit.vc)
and [forge](https://github.com/magit/forge).

prrr puts the pull requests that need you in your magit-status buffer,
oldest first, with Stacks of dependent PRs kept together. Press `RET` on
one to open its Review Buffer: the diff from the PR's merge base to its
head, with existing threads inline, files folding away once viewed, and
one key to jump between files and threads. Comment on lines, ranges and
files, reply, suggest changes, and submit your pending review with a
verdict; what you write shows at once and is never lost to a dropped
connection. Look at what changed since your last review, since you last
opened the PR, or in one commit, and step up and down a Stack without
leaving the Review Buffer. Hand a review to a coding agent with `@`, and
let it read the pull request and add comments to your pending review
through a small Emacs Lisp API.

> **Status:** Milestones 1–7 are done. Release is next. See the
> milestones in [`SPEC.md`](SPEC.md#15-milestones).

## Requirements

- Emacs 29.1 or later
- Syntax highlighting needs Emacs built with tree-sitter and the grammars
  of your languages (`M-x treesit-install-language-grammar`); without
  them the diff shows uncolored.
- magit 4.7, forge 0.5, emacsql 4.4, transient 0.13, compat 31
- A GitHub token that forge can use (see forge's manual,
  [Setup for GitHub](https://docs.magit.vc/forge/Setup-for-Githubcom.html))

## Install

prrr is not on MELPA yet. Install from source with `package-vc`:

```elisp
(package-vc-install "https://github.com/whargrove/prrr")
```

Or clone the repository, add it to `load-path`, and `(require 'prrr)`.
Loading prrr loads nothing else; its commands are autoloaded, with or
without package.el.

## Setup

1. Make sure forge tracks the repository (`M-x forge-add-repository`).
2. Tell prrr who you are. prrr uses forge's convention, the `github.user`
   Git variable:

   ```sh
   git config --global github.user YOUR-LOGIN
   ```

   or set `prrr-github-user`.
3. Turn on the Review Queue section once forge is loaded:

   ```elisp
   (with-eval-after-load 'forge
     (prrr-queue-mode 1))
   ```

   `M-x prrr-queue` also turns it on and jumps to it.

## The Review Queue

The Review Queue sits above forge's pull request list in magit-status. It
has two groups:

- **For me**: PRs by others that want your review, because they are
  assigned to you, it was requested from you or one of your teams, or
  you reviewed them before. Being the assignee (the primary reviewer)
  shows as `assigned` even when your team was requested too. **Awaiting me** comes first, oldest PR first.
  **Served** follows: PRs you already handled, by when you last touched
  them.
- **Mine**: your own open PRs, those needing your action first: changes
  requested, then awaiting review, approved, reviewed, draft.

Each row reads `#number  state  title  author  ⟰ k/n  N unresolved  age`.
A Stack (each PR based on the branch of the one below) stays together,
bottom first, with `⟰ k/n` marking each PR's place in it. Its other PRs
sit one level under its first row; `TAB` on that row folds them away.

A Verdict you submit or a Withdraw shows in the queue at once, before
GitHub has it: the row moves to Served with its new state, or leaves.

`M` on a row mutes the PR: it leaves the queue for good, whatever happens
to it on GitHub. `C-o -m` shows muted rows, dimmed; `M` on one unmutes it.
GitHub is never told.

The queue renders from a local database. It pulls in the background when
its data is older than `prrr-queue-stale-after` seconds (default 300). A
pull first refreshes the PRs already in the queue in one request, so their
rows change at once, and then pages every open PR to find new ones. The
heading shows `pulling…`, `offline`, `rate limited until 14:05`, or the
error. A pull that gets no answer within `prrr-sync-timeout` seconds
(default 60), as when the network is down, ends as `offline` and is retried
later; `G` pulls again at once. If the queue of a large repository over a
slow connection keeps ending as `offline`, raise the timeout; it is never
less than 10 seconds.

A PR joins the queue once prrr has pulled it, so a PR opened since the last
pull can appear in forge's list a few minutes before it appears here. Press
`G` to pull both now.

Teams only refine the `team-requested` and `teammate-reviewed` states. If
prrr cannot list your teams, for example because the token lacks `read:org`
or an organization requires SAML SSO, the queue still fills, prrr uses the
teams it already knows, and the heading says `Teams unavailable: …` until
the teams load. It tries the teams again on the next pull when you were
offline or rate-limited, otherwise the next day, or when you run
`prrr-refresh-teams`.

### Keys on a queue row

| Key   | Command           | Does                                                |
|-------|-------------------|-----------------------------------------------------|
| `RET` | `prrr-review`     | Open the PR's Review Buffer                         |
| `o`   | `prrr-open-topic` | Open forge's topic buffer                           |
| `b`   | `prrr-browse`     | Open the PR on GitHub                               |
| `B`   | `prrr-checkout`   | Check out the PR's branch                           |
| `>`   | `prrr-stack-up`   | Move to the PR above in the Stack                   |
| `<`   | `prrr-stack-down` | Move to the PR below in the Stack                   |
| `x`   | `prrr-withdraw`   | Withdraw: drop your review request and assignment   |
| `M`   | `prrr-mute`       | Mute or unmute: keep the PR out of the queue        |
| `G`   | `prrr-pull`       | Pull PRs (`forge-pull`) and the queue's data now    |
| `C-o` | `prrr-queue-menu` | Menu with the same keys, plus `-d` drafts, `-s` Served, `-m` muted |

forge's own pull request keys, such as `C-c C-c`, also work on a row.

### Commands

- `prrr-review`: open a pull request's Review Buffer (with `C-u`, always ask which).
- `prrr-queue`: show the Review Queue of the current repository.
- `prrr-pull`: pull now.
- `prrr-refresh-teams`: fetch your GitHub teams again (done daily anyway).

### Options

| Option                   | Default | Meaning                                         |
|--------------------------|---------|-------------------------------------------------|
| `prrr-github-user`       | `nil`   | Your login; `nil` reads `github.user`           |
| `prrr-queue-stale-after` | `300`   | Seconds before the queue's data is pulled again |
| `prrr-sync-timeout`      | `60`    | Seconds a pull, refetch or change waits for GitHub before `offline` |
| `prrr-queue-show-drafts` | `t`     | Show draft PRs                                  |
| `prrr-queue-show-served` | `t`     | Show the Served partition                       |
| `prrr-eager-files`       | `30`    | Files expanded when a Review Buffer opens       |
| `prrr-eager-lines`       | `2000`  | Changed lines expanded when it opens            |
| `prrr-database-file`     | `prrr-database.sqlite` in `user-emacs-directory` | prrr's own database |

prrr keeps its data in its own SQLite file and never writes to forge's
database. Upgrading prrr may drop that data, which prrr fetches again;
unsent comments are always kept.

## The Review Buffer

`M-x prrr-review` (or `RET` on a queue row) opens a pull request's Review
Buffer. It diffs the PR's head, which forge fetches to `refs/pullreqs/N`,
against its merge base with the base branch. If that ref is missing, prrr
offers to run `forge-pull`. When it stays missing, run
`forge-add-pullreq-refspec` and pull again.

The buffer opens at once from prrr's database and refetches the threads,
your pending review and the Viewed flags in the background. The header
says `refreshing…` meanwhile, and `offline` or `rate limited until 14:05`
when that fails. The header shows the title, the Range, your pending
review's comment count, and `head moved, press g` when the pull request
moved on. Folded below it are the description and the discussion; a
Discussion Comment you just posted shows there, marked `sent`, until
forge has pulled it.

Large diffs stay fast. The first files, up to `prrr-eager-files` files or
`prrr-eager-lines` changed lines, are shown expanded. Every other file
loads when you first expand it.

Threads sit right after the line they comment on. A thread on a line that
is not in the diff goes to a folded "Not in this diff" group at the end
of its file. Outdated threads go to a folded "Outdated" group. Threads on
files no longer in the diff go to a group at the end of the buffer.
Resolved threads start folded. `RET` on a thread visits the line it is
anchored to.

Files you marked Viewed, here or on GitHub, are folded and marked `✓
viewed`. `g` redraws at the pull request's current head and keeps what
you expanded and folded.

### Syntax highlighting

Diff lines are colored with the tree-sitter rules of the file's
language. The language is the one visiting the file would pick. When
that is `foo-mode` and `foo-ts-mode` exists, its rules are used, without
any `major-mode-remap-alist` setup and without changing the mode your
own files open in. `prrr-highlight-modes` covers the built-in ts-modes
that rule can't find: JavaScript, TypeScript, shell, JSON, HTML, Go,
Rust, YAML, TOML, Lua, Dockerfile and CMake; the rule itself covers C,
C++, C#, Python, Java, Ruby and CSS. Add entries for other languages.
Each language's grammar must be installed
(`treesit-install-language-grammar`); files without one stay uncolored.

A file expanded in an open buffer is colored at once. Files shown when
the buffer opens or refreshes, and very large files, are colored a
moment later, when Emacs is idle. Files over ten times
`prrr-highlight-max-lines` stay uncolored. `treesit-font-lock-level`
sets how much is colored. `L` turns highlighting off and on in one
buffer, for as long as it lives, reopening included, and rereads the
rules, so a changed `treesit-font-lock-level` applies.

### Keys in the Review Buffer

| Key       | Command                                             | Does                                       |
|-----------|-----------------------------------------------------|--------------------------------------------|
| `]` / `[` | `prrr-next-thread` / `prrr-previous-thread`         | Next or previous thread                    |
| `}` / `{` | `prrr-next-unresolved` / `prrr-previous-unresolved` | Next or previous unresolved thread         |
| `J` / `K` | `prrr-next-file` / `prrr-previous-file`             | Next or previous file                      |
| `j`       | `prrr-jump-to-file`                                 | Jump to a file, with completion            |
| `v`       | `prrr-toggle-viewed`                                | Mark the file Viewed on GitHub and fold it |
| `c`       | `prrr-comment`                                      | Comment on the line or the region's lines  |
| `C`       | `prrr-comment-file`                                 | Comment on the whole file                  |
| `r`       | `prrr-reply`                                        | Reply to the thread at point               |
| `e` / `k` | `prrr-edit-comment` / `prrr-delete-comment`         | Edit or delete your comment at point       |
| `d`       | `prrr-discussion-comment`                           | Comment on the pull request itself         |
| `R`       | `prrr-toggle-resolved`                              | Resolve or unresolve the thread at point   |
| `s`       | `prrr-comment-suggest`                              | Suggest a change to the line or region     |
| `S`       | `prrr-submit`                                       | Submit your review, or discard it          |
| `O`       | `prrr-outbox`                                       | Retry or drop what has not reached GitHub  |
| `x`       | `prrr-withdraw`                                     | Drop your review request and assignment    |
| `M`       | `prrr-mute`                                         | Mute or unmute: keep the PR out of the queue |
| `D`       | `prrr-range`                                        | Choose the Range: what the diff shows      |
| `.`       | `prrr-goto-default-range`                           | Back to the default Range, same line       |
| `m`       | `prrr-mark-seen`                                    | Remember this head as seen                 |
| `>` / `<` | `prrr-stack-up` / `prrr-stack-down`                 | Open the PR above or below in the Stack    |
| `z` / `Z` | `prrr-collapse-all` / `prrr-expand-all`             | Fold or expand every file                  |
| `o`       | `prrr-open-topic`                                   | forge's topic buffer                       |
| `b`       | `prrr-browse`                                       | Open the PR on GitHub                      |
| `B`       | `prrr-checkout`                                     | Check out the PR's branch                  |
| `L`       | `prrr-toggle-highlight`                             | Toggle syntax highlighting in this buffer  |
| `@`       | `prrr-send-to-agent`                                | Send the review to an agent                |
| `a`       | `prrr-accept-comment`                               | Accept an agent's proposed comment         |
| `g`       | `prrr-refresh`                                      | Redraw, at the PR's current head           |
| `G`       | `prrr-refetch`                                      | Refetch threads and Viewed flags now       |
| `?`, `C-o`| `prrr-menu`                                         | Menu with the same keys                    |

magit's `TAB`, `n`, `p`, `M-n`, `M-p`, `^`, `RET`, `1`-`4`, `E` (ediff), `h`
and `q` work as in any magit diff.

### Review Buffer options

| Option                     | Default  | Meaning                                                                  |
|----------------------------|----------|--------------------------------------------------------------------------|
| `prrr-highlight`           | `t`      | Highlight diff lines                                                     |
| `prrr-highlight-max-lines` | `3000`   | Larger files are highlighted when Emacs is idle, ten times larger never  |
| `prrr-highlight-modes`     | built-in | ts-mode by file-name regexp or major mode, where `foo-ts-mode` misses    |
| `prrr-hunk-highlight`      | `nil`    | Mark the hunk at point: `nil` not at all, `heading`, or `body` as magit  |

## Commenting and reviewing

Put point on a line of the diff and press `c`, or mark lines of one hunk
first to comment on all of them. A removed line is commented on as the
old file's line, any other line as the new file's. `C` comments on the
file at point as a whole, `r` replies to the thread at point, and `s`
starts a comment with a GitHub suggestion block holding the lines, to
edit into what they should say. A suggestion shows in the thread as a
small diff against those lines.

Each opens a buffer to write in, at the bottom of the frame. `C-c C-c`
sends, `C-c C-k` cancels, and `C-c C-i` switches between your pending
review and publishing this one comment at once. Comments go to your
pending review, which only you see until you submit it; with `C-u`
before `c`, `C`, `r` or `s`, or the `-i` switch in the `?` menu, the
comment is published at once. `d` writes a comment on the pull request
itself, which is always published at once.

`e` and `k` edit and delete your own comments, pending or published.
`R` resolves or unresolves the thread at point, when GitHub lets you.

`S` opens the submit menu: `a` approve, `r` request changes, `c`
comment, each asking for an optional summary first, or `k` to discard
the pending review and its comments. Requesting changes or commenting
needs a summary or at least one comment. Submitting moves the pull
request to Served in the Review Queue.

Everything you write shows at once, marked `unsent` until GitHub has
it. prrr sends one change at a time, a second apart, in the order you
made them, and never more than 80 new comments a minute, as GitHub
asks. When GitHub cannot be reached or refuses, the change stays,
marked `failed:` with GitHub's reason, and the header counts it. prrr
tries it again with your next change on that pull request, when the
buffer refetches, or when you press `O r`; `O k` drops one, along with
any reply that needs it. Until a failed change goes through, the later
changes to that pull request wait behind it. When GitHub rate-limits
you, the header says until when, and prrr waits. Unsent changes are
kept in prrr's database, so they survive restarting Emacs, and prrr
sends them once it starts again.

When GitHub does not answer within `prrr-sync-timeout` seconds, or
answers without naming what it made, the
change may or may not have reached GitHub. It shows as unsent, `waiting
for GitHub's answer`, and is never sent twice blindly: prrr refetches
the pull request, records the change if GitHub has it and sends it
again if not. `O r` checks again. A Discussion Comment or a submitted
review cannot be checked that way, so it ends as failed, asking you to
look at the pull request on GitHub, then retry or drop it; prrr sends
it again only when you press `O r`.

Publishing a single comment at once while you have a pending review
depends on GitHub accepting it; if GitHub refuses, the comment stays
in the Outbox with GitHub's reason. To put it in your pending review
instead, drop it with `O k` and write the comment again without `C-u`.

## Ranges and Stacks

The Review Buffer shows a Range: the two commits it diffs. It opens at
the default Range, the PR's merge base to its head, and the header
names the Range shown. `D` opens a menu to choose another; the keys
below belong to that menu only (in the buffer itself `r`, `c` and
`d` mean other things):

| Key | Command                   | Range                                                  |
|-----|---------------------------|--------------------------------------------------------|
| `d` | `prrr-goto-default-range` | The merge base to the head                             |
| `r` | `prrr-show-since-review`  | The commit of your latest submitted review to the head |
| `o` | `prrr-show-since-opened`  | The head you last saw to the head                      |
| `c` | `prrr-show-commit`        | One commit of the PR, against its parent               |
| `b` | `prrr-show-between`       | From one commit (or the merge base) to a later one     |

Switching keeps point on the same file and line when the new Range
shows that line. Viewed flags are GitHub's, one per file, and work in
every Range.

GitHub numbers comment lines at the PR's head, so a Range that ends at
the head (default, since review, since opened) takes comments on its
new side. Its old side, and both sides of one commit or of two commits,
are read-only: `.` shows the same line in the default Range, where it
takes a comment. Threads show inline where the Range numbers lines as
GitHub does, and in the file's "Not in this diff" group otherwise.  The
same group takes every line Thread, on both sides, while the review
data was fetched at another head than the one shown, until the head
shown is the one the refetch saw (`g`, after `forge-pull` when the
header asks for it).

"Since opened" starts at the head you saw when you last left the
Review Buffer, by `q`, by killing it, by stepping to another PR of
its Stack with `>` or `<`, or by opening it again once forge fetched a
newer head; or last submitted a review, or last pressed `m`. Opening a
PR does not count otherwise, so it means "since my previous visit".

When the author force-pushes, a Range from an older commit compares the
two trees directly, and the header says `history rewritten`. prrr keeps
the commits these Ranges start at under `refs/prrr/`, so neither the
push nor git's garbage collection loses them. `prrr-pull` removes the
pins of pull requests that are no longer open, except those with an open
Review Buffer. A start commit you do not
have is fetched from the PR's remote; when that fails, prrr shows the
default Range and says so.

The diff never changes under you. When forge fetches a new head while
the buffer is open, the header says `head moved, press g`; when only
GitHub has it, `head moved to 1234567 on GitHub: run forge-pull, then
g`. Your pending review stays on the commit it was started on, as
GitHub keeps it. A new comment can join it only while the buffer shows
that commit: on a newer head, submit or discard the pending review
first, or publish the comment at once.

`>` and `<` open the pull request above or below in its Stack, in the
same window, at its own default Range: each PR shows its diff against
its own base.

## Agents

prrr lets a coding agent read a pull request's review and write to it,
as you, through plain Emacs Lisp functions. An agent outside Emacs calls
them with `emacsclient -e`; nothing needs a Review Buffer open, only
`(require 'prrr)` and a repository forge tracks. Each function takes the
pull request as `("OWNER/NAME" . NUMBER)` for a repository on github.com,
as a `forge-repository` and a number, or as forge's pull request object.

### Send a review to an agent

`@` in the Review Buffer asks for your instructions, then hands the agent
a Markdown summary: the pull request, the Range shown and its diff, the
threads, your pending review with any agent comments, and the
`emacsclient -e` calls to answer with. A diff longer than
`prrr-agent-max-diff-lines` is cut, with the changed files listed for
the agent to read one at a time.

When [agent-shell](https://github.com/xenodium/agent-shell) is loaded
and has a buffer open, the summary goes to the one running in the
repository, or to any when none does; prrr asks when several fit. It is
queued as the next prompt while the agent is busy and sent at once
otherwise. Without agent-shell, or without one of its buffers, the
summary goes to the kill ring, to paste into any agent.
To hand it to another agent, set `prrr-agent-invoke-function`.

### The API

| Function                          | Does                                                         |
|-----------------------------------|--------------------------------------------------------------|
| `prrr-api-pullreq`                | The PR's summary: title, commits, Review State, counts       |
| `prrr-api-threads`                | Its threads with their comments, optionally of a Range only  |
| `prrr-api-diff`                   | Its diff, for a Range and optionally one file                |
| `prrr-api-pending`                | Your pending review and its comments                         |
| `prrr-api-add-comment`            | A new thread on a line, lines or a file                      |
| `prrr-api-reply`                  | A reply to a thread                                          |
| `prrr-api-delete-pending-comment` | Delete an agent comment or proposal of your pending review   |
| `prrr-api-submit`                 | Submit your pending review, after asking you                 |
| `prrr-api-export`                 | Write the review as JSON                                     |
| `prrr-api-import`                 | Add the new comments and replies of a JSON file              |

Reads return alists whose keys are the JSON keys `prrr-api-export`
writes. A Range is `nil` for the default, or `(since-review)`,
`(since-opened)`, `(commit OID)` or `(between FROM TO)`. The API never
fetches: a Range whose commits you do not have asks you to show it in
the Review Buffer once.

```sh
emacsclient -e '(prrr-api-pullreq (quote ("example-org/example-repo" . 42)))'
emacsclient -e '(prrr-api-threads (quote ("example-org/example-repo" . 42)) (quote (since-review)))'
emacsclient -e '(prrr-api-diff (quote ("example-org/example-repo" . 42)) nil "src/main.el")'
emacsclient -e '(prrr-api-pending (quote ("example-org/example-repo" . 42)))'
emacsclient -e '(prrr-api-add-comment (quote ("example-org/example-repo" . 42)) "src/main.el" 12 "Guard against nil." :start-line 10)'
emacsclient -e '(prrr-api-add-comment (quote ("example-org/example-repo" . 42)) "src/main.el" nil "Split this file." :file t)'
emacsclient -e '(prrr-api-reply (quote ("example-org/example-repo" . 42)) "PRRT_kwDOexample" "Agreed.")'
emacsclient -e '(prrr-api-delete-pending-comment (quote ("example-org/example-repo" . 42)) "PRRC_kwDOexample")'
emacsclient -e '(prrr-api-submit (quote ("example-org/example-repo" . 42)) (quote comment) "Two nits.")'
emacsclient -e '(prrr-api-export (quote ("example-org/example-repo" . 42)))'
emacsclient -e '(prrr-api-import (quote ("example-org/example-repo" . 42)) "/tmp/review.json")'
```

A new comment must sit on lines of the pull request's diff, on the new
side unless it passes `:side "old"`; anything else is refused at once,
with the line ranges the diff has, before it is queued, as is any
comment while the pull request's base commit is not in your repository.
Writes go through the same queue as yours and never wait on the network.
An agent can delete only its own comments and proposals; yours are
yours to delete.

### Agent comments

Everything is posted under your account. Comments an agent adds show
with an `agent` badge, and `prrr-agent-comment-prefix` goes before their
text. They are in your pending review, to edit or delete like your own,
and submitting asks once more when an agent wrote some of them.
`prrr-api-submit` asks you too, with the counts and the body (its first
200 characters), unless `prrr-api-confirm-submit` is nil.

With `prrr-agent-comment-mode` set to `proposed`, an agent's comments
stay in Emacs, marked `proposed`, until you decide: `a` (or `e`) opens
one to edit and accept into your pending review, `k` rejects it.
Proposals are not part of the pending review: its counts and Submit
leave them out, and the header shows `N proposed, a to accept`. A reply
to a proposed thread, yours or an agent's, is refused until you accept
the thread, unless the reply is a proposal itself. A proposed thread
written at another commit than your pending review's is refused too,
as your own would be.

### Export and import

`prrr-api-export` writes the review as JSON, by default to
`prrr/review-N.json` inside the repository's git directory, out of the
worktree. The shape is crit-review's handoff extended with GitHub's ids,
so a tool that reads crit-review's file can read this one.
`prrr-api-import` reads the same shape and adds, as agent comments, each
entry without a `comment_id` as a new thread and each reply without one
as a reply to its entry's existing thread; entries of type `review` are
skipped. A reply under a new thread has no thread to go to yet, and is
refused. It checks every entry first: one it cannot add adds nothing.

### Hooks

| Hook                              | Runs with                                                 |
|-----------------------------------|-----------------------------------------------------------|
| `prrr-comment-created-hook`       | The new thread's first comment, once GitHub has it        |
| `prrr-reply-created-hook`         | The reply, once GitHub has it                             |
| `prrr-review-submitted-hook`      | A plist `(:pr-id :verdict :body :commit)` once submitted  |
| `prrr-review-buffer-opened-hook`  | forge's pull request, in the Review Buffer just opened    |

A hook function that signals shows the error, with its name, as a
message and stops nothing: the hook's other functions still run.

### Agent options

| Option                        | Default                     | Meaning                                                       |
|-------------------------------|-----------------------------|---------------------------------------------------------------|
| `prrr-agent-comment-mode`     | `pending`                   | `pending`: to your pending review; `proposed`: wait for you   |
| `prrr-agent-comment-prefix`   | `""`                        | Text put before every agent comment                           |
| `prrr-api-confirm-submit`     | `t`                         | `prrr-api-submit` asks you first                              |
| `prrr-agent-invoke-function`  | `prrr-agent-invoke-default` | Hands the `@` summary to an agent                             |
| `prrr-agent-max-diff-lines`   | `2000`                      | Longest diff `@` sends                                        |

## Development

```sh
make deps     # install dependencies into .deps/
make compile  # byte-compile, warnings are errors
make lint     # package-lint and checkdoc
make test     # ERT suite, no network
make bench    # performance budgets from SPEC.md section 12
```

Read `CONTEXT.md` (the glossary) and `SPEC.md` (the design) first.

## License

GPL-3.0-or-later. See [`LICENSE`](LICENSE).
