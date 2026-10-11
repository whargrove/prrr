#!/bin/sh
# Build the Review Buffer fixture repository in DIR, the only argument.
#
# main:  base -- later on main            (base-rev is main's tip)
#           \
#            head = refs/pullreqs/1
#
# head changes, relative to base:
#   README.md          lines 1 and 3 rewritten, a line added (4 lines)
#   data.bin           binary change
#   docs/notes.md      one line added after line 1
#   src/example.el     line 12 and line 30 rewritten (two hunks)
#   src/moved-from.el  renamed to src/moved-to.el, unchanged
#   src/old.el         deleted (50 lines)
# "later on main" adds CHANGELOG, which the PR's diff must not show.
set -eu
dir=$1
mkdir -p "$dir"
cd "$dir"
export GIT_AUTHOR_NAME=example GIT_AUTHOR_EMAIL=example@example.com
export GIT_COMMITTER_NAME=example GIT_COMMITTER_EMAIL=example@example.com
export GIT_AUTHOR_DATE=2026-09-01T00:00:00Z GIT_COMMITTER_DATE=2026-09-01T00:00:00Z
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
git init -q -b main
git config commit.gpgsign false
mkdir -p src docs
seq -f 'line %g' 1 40 > src/example.el
printf 'Title\n\nSome text.\n' > README.md
seq -f 'old %g' 1 50 > src/old.el
printf 'Notes\n' > docs/notes.md
seq -f 'moved %g' 1 10 > src/moved-from.el
printf '\000\001\002' > data.bin
git add -A
git commit -q -m base
git checkout -q -b feature
sed -i.bak -e 's/^line 12$/line twelve/' -e 's/^line 30$/line thirty/' src/example.el
rm src/example.el.bak
printf 'Better title\n\nSome text,\nand more.\n' > README.md
git rm -q src/old.el
printf 'Notes\nA second note.\n' > docs/notes.md
git mv src/moved-from.el src/moved-to.el
printf '\000\001\003' > data.bin
git commit -q -a -m head
git update-ref refs/pullreqs/1 HEAD
git checkout -q main
printf 'Changes\n' > CHANGELOG
git add CHANGELOG
git commit -q -m 'later on main'
