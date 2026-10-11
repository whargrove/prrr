# prrr 🐱

Review GitHub pull requests in Emacs, on top of [magit](https://magit.vc)
and [forge](https://github.com/magit/forge).

prrr puts the pull requests that need you in your magit-status buffer,
oldest first, with Stacks of dependent PRs kept together. Upcoming
milestones add a Review Buffer that shows the diff with existing threads
inline, line and range comments, a pending review submitted in one batch,
and "what changed since my last review".

> **Status:** early development. The Review Queue works. The Review
> Buffer, commenting and submitting are next. See the milestones in
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
| `RET` | `prrr-open-topic` | Open the PR (forge's topic buffer for now)          |
| `o`   | `prrr-open-topic` | Open forge's topic buffer                           |
| `b`   | `prrr-browse`     | Open the PR on GitHub                               |
| `B`   | `prrr-checkout`   | Check out the PR's branch                           |
| `>`   | `prrr-stack-up`   | Move to the PR above in the Stack                   |
| `<`   | `prrr-stack-down` | Move to the PR below in the Stack                   |
| `G`   | `prrr-pull`       | Pull PRs (`forge-pull`) and the queue's data now    |
| `C-o` | `prrr-queue-menu` | Menu with the same keys, plus `-d` drafts, `-s` Served |

forge's own pull request keys, such as `C-c C-c`, also work on a row.

### Commands

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
| `prrr-database-file`     | `prrr-database.sqlite` in `user-emacs-directory` | prrr's own database |

prrr keeps its data in its own SQLite file and never writes to forge's
database.

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
