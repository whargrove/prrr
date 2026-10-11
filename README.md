# prrr 🐱

Review GitHub pull requests in Emacs, on top of [magit](https://magit.vc)
and [forge](https://github.com/magit/forge).

prrr puts the pull requests that need you in your magit-status buffer,
oldest first, with Stacks of dependent PRs kept together. Press `RET` on
one to open its Review Buffer: the diff from the PR's merge base to its
head, with existing threads inline, files folding away once viewed, and
one key to jump between files and threads. Upcoming milestones add line
and range comments, a pending review submitted in one batch, and "what
changed since my last review".

> **Status:** early development. The Review Queue and a read-only Review
> Buffer work. Commenting and submitting are next. See the milestones in
> [`SPEC.md`](SPEC.md#15-milestones).

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
| `prrr-sync-timeout`      | `60`    | Seconds a pull waits for GitHub before `offline` |
| `prrr-queue-show-drafts` | `t`     | Show draft PRs                                  |
| `prrr-queue-show-served` | `t`     | Show the Served partition                       |
| `prrr-eager-files`       | `30`    | Files expanded when a Review Buffer opens       |
| `prrr-eager-lines`       | `2000`  | Changed lines expanded when it opens            |
| `prrr-database-file`     | `prrr-database.sqlite` in `user-emacs-directory` | prrr's own database |

prrr keeps its data in its own SQLite file and never writes to forge's
database.

## The Review Buffer

`M-x prrr-review` (or `RET` on a queue row) opens a pull request's Review
Buffer. It diffs the PR's head, which forge fetches to `refs/pullreqs/N`,
against its merge base with the base branch. If that ref is missing, prrr
offers to run `forge-pull`. When it stays missing, run
`forge-add-pullreq-refspec` and pull again.

The buffer opens at once from prrr's database and refetches the threads,
your pending review and the Viewed flags in the background. The header
says `refreshing…` meanwhile, and `offline` or `rate limited until 14:05`
when that fails. The header shows the title, the range, your pending
review's comment count, and a warning when GitHub has a newer head than
your local ref. Folded below it are the description and the discussion.

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
viewed`. `g` redraws and keeps what you expanded and folded.

### Keys in the Review Buffer

| Key       | Command                                             | Does                                       |
|-----------|-----------------------------------------------------|--------------------------------------------|
| `]` / `[` | `prrr-next-thread` / `prrr-previous-thread`         | Next or previous thread                    |
| `}` / `{` | `prrr-next-unresolved` / `prrr-previous-unresolved` | Next or previous unresolved thread         |
| `J` / `K` | `prrr-next-file` / `prrr-previous-file`             | Next or previous file                      |
| `j`       | `prrr-jump-to-file`                                 | Jump to a file, with completion            |
| `v`       | `prrr-toggle-viewed`                                | Mark the file Viewed on GitHub and fold it |
| `z` / `Z` | `prrr-collapse-all` / `prrr-expand-all`             | Fold or expand every file                  |
| `o`       | `prrr-open-topic`                                   | forge's topic buffer                       |
| `b`       | `prrr-browse`                                       | Open the PR on GitHub                      |
| `B`       | `prrr-checkout`                                     | Check out the PR's branch                  |
| `g`       | `magit-refresh`                                     | Redraw from the database                   |
| `G`       | `prrr-refetch`                                      | Refetch threads and Viewed flags now       |
| `?`, `C-o`| `prrr-menu`                                         | Menu with the same keys                    |

magit's `TAB`, `n`, `p`, `M-n`, `M-p`, `^`, `RET`, `1`-`4`, `E` (ediff), `h`
and `q` work as in any magit diff. Keys that later milestones use for
commenting and reviewing (`c`, `r`, `e`, `k`, `s`, `S`, …) do nothing yet.

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
