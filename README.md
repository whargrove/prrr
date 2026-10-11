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
leaving the Review Buffer.

> **Status:** early development. The Review Queue, the Review Buffer,
> commenting and submitting, Ranges and Stacks work. Syntax highlighting
> of the diff is next. See the milestones in [`SPEC.md`](SPEC.md#15-milestones).

## Requirements

- Emacs 29.1 or later
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

- **For me**: PRs by others that want your review, because it was
  requested from you or one of your teams, they are assigned to you, or
  you reviewed them before. **Awaiting me** comes first, oldest PR first.
  **Served** follows: PRs you already handled, by when you last touched
  them.
- **Mine**: your own open PRs, those needing your action first: changes
  requested, then awaiting review, approved, reviewed, draft.

Each row reads `#number  state  title  author  ⟰ k/n  N unresolved  age`.
A Stack (each PR based on the branch of the one below) stays together,
bottom first, with `⟰ k/n` marking each PR's place in it.

The queue renders from a local database. It pulls in the background when
its data is older than `prrr-queue-stale-after` seconds (default 300). The
heading shows `pulling…`, `offline`, `rate limited until 14:05`, or the
error. A pull that gets no answer within `prrr-sync-timeout` seconds
(default 60), as when the network is down, ends as `offline` and is retried
later; `G` pulls again at once.

A PR joins the queue once prrr has pulled it, so a PR opened since the last
pull can appear in forge's list a few minutes before it appears here. Press
`G` to pull both now.

Teams only refine the `team-requested` and `teammate-reviewed` states. If
prrr cannot list your teams, for example because the token lacks `read:org`
or an organization requires SAML SSO, the queue still fills, prrr uses the
teams it already knows, and the heading says `Teams unavailable: …`. It
tries the teams again the next day, or when you run `prrr-refresh-teams`.

### Keys on a queue row

| Key   | Command           | Does                                                |
|-------|-------------------|-----------------------------------------------------|
| `RET` | `prrr-review`     | Open the PR's Review Buffer                         |
| `o`   | `prrr-open-topic` | Open forge's topic buffer                           |
| `b`   | `prrr-browse`     | Open the PR on GitHub                               |
| `B`   | `prrr-checkout`   | Check out the PR's branch                           |
| `>`   | `prrr-stack-up`   | Move to the PR above in the Stack                   |
| `<`   | `prrr-stack-down` | Move to the PR below in the Stack                   |
| `G`   | `prrr-pull`       | Pull PRs (`forge-pull`) and the queue's data now    |
| `C-o` | `prrr-queue-menu` | Menu with the same keys, plus `-d` drafts, `-s` Served |

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
moved on. Folded below it are the description and the discussion.

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
viewed`. `g` redraws at the pull request's current head and keeps what you expanded and folded.

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
| `D`       | `prrr-range`                                        | Choose the Range: what the diff shows      |
| `.`       | `prrr-goto-default-range`                           | Back to the default Range, same line       |
| `m`       | `prrr-mark-seen`                                    | Remember this head as seen                 |
| `>` / `<` | `prrr-stack-up` / `prrr-stack-down`                 | Open the PR above or below in the Stack    |
| `z` / `Z` | `prrr-collapse-all` / `prrr-expand-all`             | Fold or expand every file                  |
| `o`       | `prrr-open-topic`                                   | forge's topic buffer                       |
| `b`       | `prrr-browse`                                       | Open the PR on GitHub                      |
| `B`       | `prrr-checkout`                                     | Check out the PR's branch                  |
| `g`       | `prrr-refresh`                                      | Redraw, at the PR's current head           |
| `G`       | `prrr-refetch`                                      | Refetch threads and Viewed flags now       |
| `?`, `C-o`| `prrr-menu`                                         | Menu with the same keys                    |

magit's `TAB`, `n`, `p`, `M-n`, `M-p`, `^`, `RET`, `1`-`4`, `E` (ediff), `h`
and `q` work as in any magit diff. Keys that later milestones use
(`@`, `L`) do nothing yet.

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
kept in prrr's database, so they survive restarting Emacs.

Publishing a single comment at once while you have a pending review
depends on GitHub accepting it; if GitHub refuses, the comment stays
in the Outbox with GitHub's reason. To put it in your pending review
instead, drop it with `O k` and write the comment again without `C-u`.

## Ranges and Stacks

The Review Buffer shows a Range: the two commits it diffs. It opens at
the default Range, the PR's merge base to its head, and the header
names the Range shown. `D` chooses another:

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
GitHub does, and in the file's "Not in this diff" group otherwise.

"Since opened" starts at the head you saw when you last left the
Review Buffer, by `q`, by killing it or by stepping to another PR of
its Stack with `>` or `<`, or last submitted a review, or last pressed
`m`. Opening a PR does not count, so it means "since my previous
visit".

When the author force-pushes, a Range from an older commit compares the
two trees directly, and the header says `history rewritten`. prrr keeps
the commits these Ranges start at under `refs/prrr/`, so neither the
push nor git's garbage collection loses them. A start commit you do not
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
