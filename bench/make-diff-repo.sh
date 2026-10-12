#!/bin/sh
# Build a repository in DIR (argument 1) whose refs/pullreqs/1 changes
# FILES files (argument 2): FILES - 5 300-line text files with three lines
# changed in each, in directories of 100 files, and five new 300-line C
# files under zz/ that the expand budget highlights.  Deterministic, no
# network.
set -eu
dir=$1
files=$2
mkdir -p "$dir"
cd "$dir"
export GIT_AUTHOR_NAME=example GIT_AUTHOR_EMAIL=example@example.com
export GIT_COMMITTER_NAME=example GIT_COMMITTER_EMAIL=example@example.com
export GIT_AUTHOR_DATE=2026-09-01T00:00:00Z GIT_COMMITTER_DATE=2026-09-01T00:00:00Z
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
git init -q -b main
git config commit.gpgsign false
seq -f 'line %g of the example file' 1 300 > ../template.$$
i=0
while [ "$i" -lt "$((files - 5))" ]; do
  mkdir -p "dir$((i / 100))"
  cp ../template.$$ "dir$((i / 100))/file$i.txt"
  i=$((i + 1))
done
rm ../template.$$
git add -A
git commit -q -m base
git checkout -q -b feature
find . -name '*.txt' -not -path './.git/*' -exec sed -i.bak \
  -e 's/^line 10 of/line ten of/' \
  -e 's/^line 150 of/line 150 changed of/' \
  -e 's/^line 290 of/line 290 changed of/' {} +
find . -name '*.bak' -not -path './.git/*' -exec rm {} +
mkdir -p zz
j=0
while [ "$j" -lt 5 ]; do
  k=1
  : > "zz/expand$j.c"
  while [ "$k" -le 300 ]; do
    printf 'static int value_%d(int x) { return x + %d; /* line %d */ }\n' "$k" "$k" "$k" >> "zz/expand$j.c"
    k=$((k + 1))
  done
  j=$((j + 1))
done
git add zz
git commit -q -a -m head
git update-ref refs/pullreqs/1 HEAD
git checkout -q main
