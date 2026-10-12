#!/bin/sh
# Build the highlighting fixture repository in DIR, the only argument.
#
# main:  base            (base-rev is main's tip)
#           \
#            head = refs/pullreqs/1
#
# head changes, relative to base:
#   src/sample.c     one hunk: "int answer = 41;" becomes 42, the
#                    "int unused" line is removed, a comment line is
#                    added before "return 0;"
#   src/big.c        new, 40 lines of declarations
#   src/comment.c    line 12, inside a 20-line block comment, rewritten
#   src/moved.c      renamed to src/renamed.c, unchanged (no hunks)
#   notes.txt        one line rewritten (no grammar highlights it)
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
mkdir -p src
cat > src/sample.c <<'EOF'
#include <stdio.h>

int answer = 41;

int main(void)
{
  int unused = 0;
  printf("%d\n", answer);
  return 0;
}
EOF
{
  echo '/*'
  i=1
  while [ "$i" -le 20 ]; do echo " * comment line $i"; i=$((i + 1)); done
  echo ' */'
  echo 'int after_comment = 1;'
} > src/comment.c
printf 'int moved = 1;\n' > src/moved.c
printf 'first\nsecond\n' > notes.txt
git add -A
git commit -q -m base
git checkout -q -b feature
cat > src/sample.c <<'EOF'
#include <stdio.h>

int answer = 42;

int main(void)
{
  printf("%d\n", answer);
  /* print the answer */
  return 0;
}
EOF
: > src/big.c
i=1
while [ "$i" -le 40 ]; do printf 'int value_%d = %d;\n' "$i" "$i" >> src/big.c; i=$((i + 1)); done
sed -i.bak -e 's/^ \* comment line 12$/ * comment line twelve/' src/comment.c
rm src/comment.c.bak
git mv src/moved.c src/renamed.c
printf 'first\nsecond, changed\n' > notes.txt
git add -A
git commit -q -m head
git update-ref refs/pullreqs/1 HEAD
git checkout -q main
