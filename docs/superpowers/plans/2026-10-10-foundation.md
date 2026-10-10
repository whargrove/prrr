# Foundation Milestone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship milestone 1 of `prrr` (SPEC.md section 15, item 1): the package skeleton, `prrr-db.el` schema and structs, `prrr-github.el` read-only queries and decoders tested against fixtures, `prrr-state.el` with exhaustive unit tests, and CI.

**Architecture:** Four source files that depend only on the files above them: `prrr-db.el` (every SQL statement; one `cl-defstruct` per table whose slot names equal the column names, so CRUD is generic), `prrr-github.el` (GraphQL queries in ghub's Lisp DSL sent through `forge-query`, plus pure decoders from the callback data into `prrr-db` structs), `prrr-state.el` (pure Review State, membership, ordering and Stack rules over `prrr-pr` and `prrr-pr-meta` structs), `prrr.el` (group and user options). Tests never touch the network: `ghub-query` is stubbed with `cl-letf` and answered from `.eld` fixtures; the database is in-memory.

**Tech Stack:** Emacs Lisp (Emacs 29.1+), emacsql 4.4 with the built-in SQLite backend, forge 0.5 (`forge-query`), magit 4.7, ERT, package.el for dependencies, GitHub Actions with `purcell/setup-emacs`.

**Spec:** `SPEC.md` (sections 1, 2, 3, 4, 5, 11, 12, 13, 14, 15). Glossary: `CONTEXT.md`. Verified API facts the plan relies on without re-checking: `docs/superpowers/notes/2026-10-10-foundation-facts.md`.

## Global Constraints

- Every `.el` file starts with `;;; NAME.el --- DESCRIPTION  -*- lexical-binding: t -*-`, carries the GPL-3.0-or-later header shown in Task 1, has `;;; Commentary:` and `;;; Code:` sections and ends with `(provide 'NAME)` and `;;; NAME.el ends here`.
- `prrr.el` declares `;; Package-Requires: ((emacs "29.1") (magit "4.7") (forge "0.5") (emacsql "4.4") (transient "0.13") (compat "31"))` exactly.
- Every symbol the package defines starts with `prrr-`; internals use `prrr-FILE--`. Struct constructors are named explicitly (`prrr-thread-create`) and copiers are disabled, so no `make-`/`copy-` symbols exist.
- No `forge--` symbol appears anywhere in the repository (SPEC 1, quality 4). forge is used through `forge-query` only; ghub is never called directly by package code (tests stub `ghub-query`).
- No personal paths, hosts, tokens or logins anywhere; fixtures and tests use `example` names (`example-org`, `example-repo`, `example-me`, `example-alice`, ...). Nothing references `~/.emacs.d`.
- `make compile` byte-compiles with `byte-compile-error-on-warn` set; `make lint` runs `package-lint` and `checkdoc`; both must be clean before every commit. Never commit with failing tests.
- Only Emacs 29.1 APIs: no Emacs 30 `sort` keyword arguments, no `value<`.
- All SQL lives in `prrr-db.el`; all GitHub calls live in `prrr-github.el`; `prrr-state.el` has no buffer, network or forge-object access.
- Timestamps are ISO 8601 UTC strings as GitHub sends them (`2026-10-10T12:00:00Z`) and are compared with `string<`.
- Commit after every task with a conventional message (`feat(db): ...`, `test(state): ...`, `chore: ...`). The repository's CLAUDE.md permits commits without approval; never push.

## Review Focus

1. The viewer's own Pending Review surfacing as `viewerLatestReview` with state `PENDING`: it must not count as a touch (no `commented` state, no move to Served); the PR keeps the state it would have without it. Pinned in Task 8.
2. A review whose author was deleted (`author` is `null`, so the login is nil): decoders and state functions must not signal, and the review counts as someone else's. Pinned in Task 4 (fixture) and Task 9.
3. A Stack cycle (two open PRs each based on the other's head), a PR whose parent's head branch was deleted (`head-ref` nil), and a cross-repo parent: `prrr-state-stacks` must terminate and list every PR exactly once. Pinned in Task 10.
4. Opening the database when its directory does not exist, or when the stored schema version differs while unsent Outbox rows exist: the directory is created; the Outbox rows survive and are handed to the caller in `prrr-db-preserved-outbox`. Pinned in Task 2.
5. A `viewerLatestReview` or `latestReviews` entry whose `commit` is `null` (GitHub nulls it when the commit is gone): decoding yields a nil oid and `new-commits` must not fire on a nil oid. Pinned in Task 4 (fixture) and Task 8.

---

## File structure

| File | Responsibility |
|------|----------------|
| `prrr.el` | Package headers, `defgroup prrr`, user options `prrr-database-file`, `prrr-github-user`, `prrr-queue-stale-after`; requires the three files below. |
| `prrr-db.el` | `prrr-db--tables`, the eight row structs, connection (`prrr-db`), schema version check, `prrr-db-reset`, generic `prrr-db-insert`/`-get`/`-select`/`-delete`. |
| `prrr-github.el` | Query constants, `prrr-github--query` macro over `forge-query`, request functions `prrr-github-fetch-queue`/`-teams`/`-review-data`, pure decoders. |
| `prrr-state.el` | `prrr-pr`, `prrr-queue-entry`; Review State, Mine state, membership, partition, Stacks, queue assembly. |
| `Makefile` | `deps compile lint test bench`. |
| `scripts/install-deps.el` | package.el install of forge, magit, emacsql, compat, transient, package-lint into `.deps/`. |
| `scripts/record-fixtures.el` | Re-records raw GraphQL responses from a real repository (never in CI). |
| `.github/workflows/ci.yml` | Emacs 29.4 / 30.1 / 31.1 matrix running `make deps compile lint test`. |
| `test/prrr-test-helper.el` | `prrr-test-root`, `prrr-test-fixture`, `prrr-db-with-test-db`, `prrr-test-with-ghub-stub`. |
| `test/prrr-db-test.el`, `test/prrr-github-test.el`, `test/prrr-state-test.el` | ERT suites. |
| `test/fixtures/github/queue.eld`, `teams.eld`, `review-data.eld` | Exactly what the `forge-query` callback receives, as printed Lisp data. |

Running a single test file while working: `make test TESTS=test/prrr-db-test.el`; a single test: `make test SELECTOR='"prrr-db-test-insert"'` (the Makefile defines both variables).

---

### Task 1: Package skeleton and toolchain

**Files:**
- Create: `LICENSE`, `prrr.el`, `Makefile`, `scripts/install-deps.el`, `test/prrr-test-helper.el`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `prrr-database-file`, `prrr-github-user`, `prrr-queue-stale-after` (defcustoms, used by Task 2); `prrr-test-root` (directory string) and `(prrr-test-fixture NAME) -> Lisp data` (used by Tasks 4-6); the `make` targets every later task runs.

- [ ] **Step 1: Fetch the license and extend `.gitignore`**

```bash
cd ~/Projects/prrr
curl -fsSL https://www.gnu.org/licenses/gpl-3.0.txt -o LICENSE
head -3 LICENSE   # expect "GNU GENERAL PUBLIC LICENSE" / "Version 3, 29 June 2007"
cat >> .gitignore <<'EOF'

# prrr build artefacts
.deps/
*.elc
test/fixtures/github/recorded/
EOF
```

- [ ] **Step 2: Write `prrr.el`**

```elisp
;;; prrr.el --- Review GitHub pull requests with magit and forge  -*- lexical-binding: t -*-

;; Copyright (C) 2026  Wesley Hargrove

;; Author: Wesley Hargrove <wesleyhargrove@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (magit "4.7") (forge "0.5") (emacsql "4.4") (transient "0.13") (compat "31"))
;; Keywords: vc, tools

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; prrr reviews GitHub pull requests inside Emacs on top of magit and
;; forge: a Review Queue in magit-status, a Review Buffer with Threads
;; inline, and a server-side Pending Review with batched Submit.
;;
;; This file holds the customization group and the user options.  The
;; database lives in `prrr-db', GitHub access in `prrr-github', and the
;; pure Review Queue rules in `prrr-state'.

;;; Code:

(defgroup prrr nil
  "Review GitHub pull requests with magit and forge."
  :group 'tools
  :prefix "prrr-")

(defcustom prrr-database-file
  (expand-file-name "prrr-database.sqlite" user-emacs-directory)
  "File holding prrr's SQLite database.
One database serves every repository.  Created on first use."
  :type 'file)

(defcustom prrr-github-user nil
  "GitHub login of the viewer.
When nil, the `github.user' Git variable is used, as forge does."
  :type '(choice (const :tag "Use the github.user Git variable" nil)
                 (string :tag "Login")))

(defcustom prrr-queue-stale-after 300
  "Seconds after which the Review Queue inputs are pulled again."
  :type 'natnum)

(provide 'prrr)
;;; prrr.el ends here
```

Every later `.el` file copies the same copyright block and license text, changing only the first line's name and description.

- [ ] **Step 3: Write `scripts/install-deps.el`**

```elisp
;;; install-deps.el --- Install prrr's dependencies into .deps/  -*- lexical-binding: t -*-

;; Copyright (C) 2026  Wesley Hargrove

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Run by `make deps' with `package-user-dir' already pointing at the
;; project-local .deps/ directory.  Installs the newest archive version
;; of each dependency, replacing built-in copies (transient on Emacs 29)
;; when the archive is newer.

;;; Code:

(require 'package)

(setq package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                         ("melpa" . "https://melpa.org/packages/"))
      package-install-upgrade-built-in t)

(package-initialize)
(package-refresh-contents)

(defun install-deps--newest (name)
  "Return the newest archive description of package NAME."
  (car (sort (copy-sequence (cdr (assq name package-archive-contents)))
             (lambda (a b)
               (version-list-< (package-desc-version b)
                               (package-desc-version a))))))

(dolist (name '(compat transient emacsql magit forge package-lint))
  (let ((desc (install-deps--newest name)))
    (unless desc
      (error "install-deps: %s is not in any configured archive" name))
    (if (package-installed-p name (package-desc-version desc))
        (message "install-deps: %s %s already installed"
                 name (package-version-join (package-desc-version desc)))
      (message "install-deps: installing %s %s"
               name (package-version-join (package-desc-version desc)))
      (package-install desc))))

;;; install-deps.el ends here
```

- [ ] **Step 4: Write the `Makefile`**

```make
EMACS    ?= emacs
DEPS_DIR := $(CURDIR)/.deps
SRC      := prrr-db.el prrr-github.el prrr-state.el prrr.el
TESTS    ?= test/prrr-db-test.el test/prrr-github-test.el test/prrr-state-test.el
SELECTOR ?= t

BATCH := $(EMACS) -Q --batch \
  --eval '(setq package-user-dir "$(DEPS_DIR)")' \
  --eval '(package-initialize)' \
  -L . -L test

.PHONY: deps compile lint test bench clean

deps:
	$(EMACS) -Q --batch --eval '(setq package-user-dir "$(DEPS_DIR)")' \
	  -l scripts/install-deps.el

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(wildcard $(SRC)) $(wildcard test/*.el)
	rm -f *.elc test/*.elc

lint:
	$(BATCH) -l package-lint \
	  --eval '(setq package-lint-main-file "prrr.el")' \
	  -f package-lint-batch-and-exit $(wildcard $(SRC))
	$(BATCH) --eval '(progn (require (quote checkdoc)) (defvar prrr-checkdoc-failed nil) (setq checkdoc-create-error-function (lambda (text start _end &optional _unfixable) (setq prrr-checkdoc-failed t) (message "%s:%d: %s" (buffer-file-name) (line-number-at-pos start) text) nil)) (dolist (file command-line-args-left) (checkdoc-file file)) (kill-emacs (if prrr-checkdoc-failed 1 0)))' \
	  $(wildcard $(SRC)) $(wildcard test/*.el)

test:
	$(BATCH) -l test/prrr-test-helper.el $(addprefix -l ,$(wildcard $(TESTS))) \
	  --eval '(ert-run-tests-batch-and-exit (quote $(SELECTOR)))'

bench:
	@echo "no benchmarks yet"

clean:
	rm -f *.elc test/*.elc
```

`$(wildcard ...)` lets `make compile` and `make test` work while later tasks' files do not exist yet. Recipe lines are indented with a TAB.

- [ ] **Step 5: Write `test/prrr-test-helper.el`**

```elisp
;;; prrr-test-helper.el --- Shared helpers for prrr's ERT suite  -*- lexical-binding: t -*-

;; Copyright (C) 2026  Wesley Hargrove

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Loaded by `make test' before every test file.  Fixture access only
;; in this task; Task 2 adds `prrr-db-with-test-db' and Task 4 adds
;; `prrr-test-with-ghub-stub'.

;;; Code:

(require 'ert)
(require 'prrr)

(defconst prrr-test-root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Root directory of the prrr checkout.")

(defun prrr-test-fixture (name)
  "Return the Lisp datum stored in test/fixtures/github/NAME.eld."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name (format "test/fixtures/github/%s.eld" name)
                       prrr-test-root))
    (read (current-buffer))))

(provide 'prrr-test-helper)
;;; prrr-test-helper.el ends here
```

- [ ] **Step 6: Install dependencies and run the toolchain**

Run: `make deps && make compile lint test`
Expected: `deps` prints one `installing ...` line per package; `compile` finishes with no warnings; `lint` prints nothing from package-lint or checkdoc and exits 0; `test` prints `Ran 0 tests` and exits 0.

If `package-lint` reports `Package-Requires` entries it cannot find, the archive contents were not refreshed: rerun `make deps`.

- [ ] **Step 7: Commit**

```bash
git add LICENSE .gitignore prrr.el Makefile scripts/install-deps.el test/prrr-test-helper.el
git commit -m "chore: package skeleton, Makefile and dependency installer"
```

---

### Task 2: `prrr-db.el` structs, schema, connection and version check

**Files:**
- Create: `prrr-db.el`, `test/prrr-db-test.el`
- Modify: `test/prrr-test-helper.el` (add `prrr-db-with-test-db`), `prrr.el` (add `(require 'prrr-db)`)

**Interfaces:**
- Consumes: `prrr-database-file` from Task 1.
- Produces: structs `prrr-pr-meta`, `prrr-thread`, `prrr-comment`, `prrr-pending-review`, `prrr-viewed`, `prrr-team`, `prrr-bookmark`, `prrr-outbox` with constructors `prrr-NAME-create` (keyword arguments named after the slots) and predicates `prrr-NAME-p`; `prrr-db--tables` (list of `(TABLE STRUCT SCHEMA)`); `prrr-db-schema-version`; `(prrr-db) -> connection`; `(prrr-db--init DB) -> DB`; `(prrr-db-reset &optional DB) -> DB`; `(prrr-db-close)`; variable `prrr-db-preserved-outbox`; `(prrr-db--columns TABLE) -> list of symbols`; `(prrr-db--primary-key TABLE) -> list of symbols`; `(prrr-db--slot-names STRUCT) -> list of symbols`; `(prrr-db--row-to-struct TABLE ROW) -> struct`.

- [ ] **Step 1: Write the failing tests**

`test/prrr-db-test.el` (header as in Task 1, first line `;;; prrr-db-test.el --- Tests for prrr-db  -*- lexical-binding: t -*-`):

```elisp
;;; Commentary:

;; Schema, structs, connection lifecycle and CRUD of `prrr-db', run
;; against an in-memory SQLite database.

;;; Code:

(require 'ert)
(require 'prrr-test-helper)
(require 'prrr-db)

(ert-deftest prrr-db-test-struct-slots-match-columns ()
  "Every table's struct has exactly the table's columns, in order."
  (dolist (entry prrr-db--tables)
    (should (equal (prrr-db--slot-names (nth 1 entry))
                   (prrr-db--columns (nth 0 entry))))))

(ert-deftest prrr-db-test-fresh-database-stores-version ()
  (prrr-db-with-test-db
    (should (equal (emacsql (prrr-db) [:select version :from schema-version])
                   (list (list prrr-db-schema-version))))))

(ert-deftest prrr-db-test-fresh-database-has-every-table ()
  (prrr-db-with-test-db
    (dolist (entry prrr-db--tables)
      (should (null (emacsql (prrr-db)
                             (vector :select '* :from (nth 0 entry))))))))

(ert-deftest prrr-db-test-version-mismatch-resets-but-keeps-outbox ()
  "Review Focus 4: a schema change drops data tables, keeps the Outbox."
  (prrr-db-with-test-db
    (let ((db (prrr-db))
          (prrr-db-preserved-outbox nil))
      (emacsql db [:insert :into team :values $v1]
               (list (vector "example-org/reviewers" "example-org"
                               "reviewers" "2026-10-10T12:00:00Z")))
      (emacsql db [:insert :into outbox :values $v1]
               (list (vector 1 "PR_1" 'comment "payload"
                               "2026-10-10T12:00:00Z" 0 nil)))
      (emacsql db [:delete :from schema-version])
      (emacsql db [:insert :into schema-version :values $v1]
               (list (vector 0)))
      (prrr-db--init db)
      (should (null (emacsql db [:select * :from team])))
      (should (= 1 (length (emacsql db [:select * :from outbox]))))
      (should (equal (emacsql db [:select version :from schema-version])
                     (list (list prrr-db-schema-version))))
      (should (= 1 (length prrr-db-preserved-outbox)))
      (should (prrr-outbox-p (car prrr-db-preserved-outbox)))
      (should (equal (prrr-outbox-pr-id (car prrr-db-preserved-outbox))
                     "PR_1")))))

(ert-deftest prrr-db-test-matching-version-keeps-data ()
  (prrr-db-with-test-db
    (let ((db (prrr-db)))
      (emacsql db [:insert :into team :values $v1]
               (list (vector "example-org/reviewers" "example-org"
                               "reviewers" nil)))
      (prrr-db--init db)
      (should (= 1 (length (emacsql db [:select * :from team])))))))

(ert-deftest prrr-db-test-reset-recreates-tables ()
  (prrr-db-with-test-db
    (let ((db (prrr-db)))
      (emacsql db [:insert :into pr-bookmark :values $v1]
               (list (vector "PR_1" "abc" "2026-10-10T12:00:00Z")))
      (prrr-db-reset db)
      (should (null (emacsql db [:select * :from pr-bookmark])))
      (should (null (emacsql db [:select * :from outbox]))))))

(ert-deftest prrr-db-test-open-creates-directory ()
  "Review Focus 4: `prrr-db' creates the database's directory."
  (let* ((dir (make-temp-file "prrr-db-test-" t))
         (prrr-database-file (expand-file-name "nested/dir/prrr.sqlite" dir))
         (prrr-db--connection nil))
    (unwind-protect
        (progn
          (should (emacsql-live-p (prrr-db)))
          (should (file-exists-p prrr-database-file))
          (should (eq (prrr-db) prrr-db--connection))
          (prrr-db-close)
          (should (null prrr-db--connection)))
      (prrr-db-close)
      (delete-directory dir t))))

(provide 'prrr-db-test)
;;; prrr-db-test.el ends here
```

Add to `test/prrr-test-helper.el`, after `(require 'prrr)`:

```elisp
(require 'prrr-db)

(defmacro prrr-db-with-test-db (&rest body)
  "Run BODY with `prrr-db' returning a fresh in-memory database."
  (declare (indent 0) (debug t))
  `(let ((prrr-db--connection (emacsql-sqlite-open nil)))
     (unwind-protect
         (progn (prrr-db--init prrr-db--connection) ,@body)
       (emacsql-close prrr-db--connection))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test TESTS=test/prrr-db-test.el`
Expected: load error `Cannot open load file: prrr-db` (the helper requires it).

- [ ] **Step 3: Write `prrr-db.el`**

First line `;;; prrr-db.el --- SQLite schema, structs and CRUD for prrr  -*- lexical-binding: t -*-`, then the license block from Task 1, then:

```elisp
;;; Commentary:

;; Every SQL statement prrr runs lives in this file.  Each table has a
;; `cl-defstruct' whose slot names equal the table's column names in
;; order, so `prrr-db-insert', `prrr-db-get', `prrr-db-select' and
;; `prrr-db-delete' convert rows and structs generically.
;;
;; Primary keys are GitHub node ids.  Forge's repository id and the PR
;; number are secondary columns used only to join to forge objects.
;; Before 1.0 a schema change bumps `prrr-db-schema-version'; a
;; database with another version is dropped and recreated except for
;; the `outbox' table, whose rows are kept and also exposed through
;; `prrr-db-preserved-outbox' so the UI can show them first.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'emacsql)
(require 'emacsql-sqlite)

(defvar prrr-database-file)             ; defined in prrr.el

(defconst prrr-db-schema-version 1
  "Version of the table layout in `prrr-db--tables'.
Bump it whenever a table changes.  A stored version that differs makes
`prrr-db--init' call `prrr-db-reset'.")

;;;; Row structs

(cl-defstruct (prrr-pr-meta (:constructor prrr-pr-meta-create) (:copier nil))
  "Review Queue inputs of one Pull Request (table `pullreq-meta').
REVIEW-REQUESTS is a list of (user LOGIN) and (team COMBINED-SLUG).
LATEST-REVIEWS is a list of (LOGIN STATE SUBMITTED-AT COMMIT-OID
ON-BEHALF-OF-SLUGS), one per reviewer, pending reviews excluded.
VIEWER-LATEST-REVIEW is (STATE SUBMITTED-AT COMMIT-OID) or nil.
VIEWER-LATEST-REVIEW-REQUEST is the login of whoever requested the
viewer's review, or nil.  STATE values are GitHub's strings."
  pr-id forge-repo-id number head-oid review-requests latest-reviews
  viewer-latest-review viewer-latest-review-request created-at fetched-at)

(cl-defstruct (prrr-thread (:constructor prrr-thread-create) (:copier nil))
  "A Thread (table `thread').
SIDE and START-SIDE are `left' or `right'; SUBJECT-TYPE is `line' or
`file'; OUTDATED-P and RESOLVED-P are booleans."
  thread-id pr-id path line start-line side start-side subject-type
  outdated-p resolved-p original-line original-commit fetched-at)

(cl-defstruct (prrr-comment (:constructor prrr-comment-create) (:copier nil))
  "A Review Comment inside a Thread (table `review-comment').
STATE is `pending' or `submitted' (GitHub's); LOCAL-STATE is `sent',
`unsent' or `proposed'; AGENT-P marks comments added through the API."
  comment-id thread-id pr-id author body created-at updated-at reply-to
  review-id state local-state agent-p)

(cl-defstruct (prrr-pending-review (:constructor prrr-pending-review-create)
                                   (:copier nil))
  "The viewer's Pending Review on one PR (table `pending-review')."
  pr-id review-id commit-oid body created-at)

(cl-defstruct (prrr-viewed (:constructor prrr-viewed-create) (:copier nil))
  "GitHub's Viewed flag for one file of one PR (table `viewed').
STATE is `viewed', `unviewed' or `dismissed'."
  pr-id path state fetched-at)

(cl-defstruct (prrr-team (:constructor prrr-team-create) (:copier nil))
  "A Team the viewer belongs to (table `team')."
  combined-slug org slug fetched-at)

(cl-defstruct (prrr-bookmark (:constructor prrr-bookmark-create) (:copier nil))
  "The last PR head the viewer opened (table `pr-bookmark')."
  pr-id last-opened-head-oid last-opened-at)

(cl-defstruct (prrr-outbox (:constructor prrr-outbox-create) (:copier nil))
  "A write GitHub has not accepted yet (table `outbox')."
  id pr-id kind payload created-at attempts last-error)

;;;; Schema

(defconst prrr-db--tables
  '((pullreq-meta prrr-pr-meta
     ([(pr-id :primary-key) forge-repo-id number head-oid review-requests
       latest-reviews viewer-latest-review viewer-latest-review-request
       created-at fetched-at]))
    (thread prrr-thread
     ([(thread-id :primary-key) pr-id path line start-line side start-side
       subject-type outdated-p resolved-p original-line original-commit
       fetched-at]))
    (review-comment prrr-comment
     ([(comment-id :primary-key) thread-id pr-id author body created-at
       updated-at reply-to review-id state local-state agent-p]))
    (pending-review prrr-pending-review
     ([(pr-id :primary-key) review-id commit-oid body created-at]))
    (viewed prrr-viewed
     ([pr-id path state fetched-at] (:primary-key [pr-id path])))
    (team prrr-team
     ([(combined-slug :primary-key) org slug fetched-at]))
    (pr-bookmark prrr-bookmark
     ([(pr-id :primary-key) last-opened-head-oid last-opened-at]))
    (outbox prrr-outbox
     ([(id :primary-key) pr-id kind payload created-at attempts last-error])))
  "Tables as (TABLE STRUCT SCHEMA).
SCHEMA is the emacsql `:create-table' schema: the column vector followed
by table constraints.  The struct's slots equal the columns in order.")

(defun prrr-db--table-entry (table)
  "Return the `prrr-db--tables' entry of TABLE, or signal an error."
  (or (assq table prrr-db--tables)
      (error "prrr-db: unknown table %s" table)))

(defun prrr-db--struct (table)
  "Return the struct type whose instances are rows of TABLE."
  (nth 1 (prrr-db--table-entry table)))

(defun prrr-db--schema (table)
  "Return the emacsql schema of TABLE."
  (nth 2 (prrr-db--table-entry table)))

(defun prrr-db--columns (table)
  "Return the column names of TABLE as a list of symbols, in order."
  (mapcar (lambda (column) (if (consp column) (car column) column))
          (append (car (prrr-db--schema table)) nil)))

(defun prrr-db--primary-key (table)
  "Return the primary key columns of TABLE as a list of symbols."
  (let ((schema (prrr-db--schema table)))
    (or (append (cadr (assq :primary-key (cdr schema))) nil)
        (cl-loop for column across (car schema)
                 when (and (consp column) (memq :primary-key column))
                 collect (car column)))))

(defun prrr-db--slot-names (struct)
  "Return the slot names of struct type STRUCT, in order."
  (mapcar #'car (cdr (cl-struct-slot-info struct))))

(defun prrr-db--row-to-struct (table row)
  "Build TABLE's struct from ROW, a list of column values."
  (let ((struct (prrr-db--struct table)))
    (apply (intern (format "%s-create" struct))
           (cl-loop for slot in (prrr-db--slot-names struct)
                    for value in row
                    append (list (intern (format ":%s" slot)) value)))))

;;;; Connection and lifecycle

(defvar prrr-db--connection nil
  "The open emacsql connection, or nil.")

(defvar prrr-db-preserved-outbox nil
  "Outbox rows found when the database was last reset for a schema change.
A list of `prrr-outbox' structs.  The UI shows them to the user before
anything else; `prrr-db--init' sets it, nothing in this file reads it.")

(defun prrr-db--table-exists-p (db table)
  "Non-nil when TABLE exists in DB."
  (condition-case nil
      (progn (emacsql db (vector :select '* :from table :limit 0)) t)
    (emacsql-error nil)))

(defun prrr-db--stored-version (db)
  "Return the schema version stored in DB, or nil when there is none."
  (and (prrr-db--table-exists-p db 'schema-version)
       (caar (emacsql db [:select version :from schema-version]))))

(defun prrr-db--create-tables (db)
  "Create every missing table in DB and record `prrr-db-schema-version'."
  (dolist (entry prrr-db--tables)
    (unless (prrr-db--table-exists-p db (nth 0 entry))
      (emacsql db (vector :create-table (nth 0 entry) (nth 2 entry)))))
  (unless (prrr-db--table-exists-p db 'schema-version)
    (emacsql db [:create-table schema-version ([version])]))
  (emacsql db [:delete :from schema-version])
  (emacsql db [:insert :into schema-version :values $v1]
           (list (vector prrr-db-schema-version))))

(defun prrr-db--drop-table (db table)
  "Drop TABLE from DB if it exists."
  (when (prrr-db--table-exists-p db table)
    (emacsql db (vector :drop-table table))))

(defun prrr-db-reset (&optional db)
  "Drop and recreate every table except `outbox' in DB.
DB defaults to the open connection.  The stored schema version becomes
`prrr-db-schema-version'.  Return DB."
  (let ((db (or db (prrr-db))))
    (dolist (entry prrr-db--tables)
      (unless (eq (nth 0 entry) 'outbox)
        (prrr-db--drop-table db (nth 0 entry))))
    (prrr-db--create-tables db)
    db))

(defun prrr-db--init (db)
  "Create the tables in DB or reset them on a schema version mismatch.
On a mismatch the `outbox' rows are collected into
`prrr-db-preserved-outbox' before `prrr-db-reset' runs.  Return DB."
  (let ((version (prrr-db--stored-version db)))
    (cond
     ((null version)
      (prrr-db--create-tables db))
     ((/= version prrr-db-schema-version)
      (setq prrr-db-preserved-outbox
            (and (prrr-db--table-exists-p db 'outbox)
                 (mapcar (lambda (row) (prrr-db--row-to-struct 'outbox row))
                         (emacsql db [:select * :from outbox]))))
      (prrr-db-reset db))))
  db)

(defun prrr-db ()
  "Return the open connection to `prrr-database-file', opening it if needed.
The file's directory is created when missing."
  (unless (and prrr-db--connection (emacsql-live-p prrr-db--connection))
    (require 'prrr)                     ; defines `prrr-database-file'
    (let ((file (expand-file-name prrr-database-file)))
      (make-directory (file-name-directory file) t)
      (setq prrr-db--connection (emacsql-sqlite-open file))
      (prrr-db--init prrr-db--connection)))
  prrr-db--connection)

(defun prrr-db-close ()
  "Close the database connection, if open."
  (when (and prrr-db--connection (emacsql-live-p prrr-db--connection))
    (emacsql-close prrr-db--connection))
  (setq prrr-db--connection nil))

(provide 'prrr-db)
;;; prrr-db.el ends here
```

The lazy `(require 'prrr)` inside `prrr-db` is deliberate: `prrr.el` requires `prrr-db` at load time, so the option can only be reached at call time without a load cycle; tests never hit this path because `prrr-db-with-test-db` binds the connection.

Add `(require 'prrr-db)` to `prrr.el` directly under `;;; Code:`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make compile lint && make test TESTS=test/prrr-db-test.el`
Expected: `Ran 7 tests, 7 results as expected`, no compile or lint output.

If `prrr-db-test-fresh-database-has-every-table` fails on `viewed` with a syntax error, the composite key form must be exactly `([pr-id path state fetched-at] (:primary-key [pr-id path]))` (facts note, emacsql section).

- [ ] **Step 5: Commit**

```bash
git add prrr-db.el prrr.el test/prrr-db-test.el test/prrr-test-helper.el
git commit -m "feat(db): row structs, schema, connection and version check"
```

---

### Task 3: `prrr-db.el` generic CRUD

**Files:**
- Modify: `prrr-db.el` (insert before `(provide 'prrr-db)`), `test/prrr-db-test.el`

**Interfaces:**
- Consumes: structs, `prrr-db--tables`, `prrr-db--row-to-struct`, `prrr-db--primary-key`, `(prrr-db)` from Task 2.
- Produces: `(prrr-db-insert STRUCT) -> STRUCT`, `(prrr-db-get TABLE &rest KEY) -> struct or nil`, `(prrr-db-select TABLE &rest PLIST) -> list of structs`, `(prrr-db-delete TABLE &rest PLIST)`. PLIST is `:column value` pairs, all of which must match; no pairs means every row.

- [ ] **Step 1: Write the failing tests**

Insert before `(provide 'prrr-db-test)`:

```elisp
(ert-deftest prrr-db-test-insert-and-get-round-trip ()
  "Lists, symbols, booleans and nil survive a round trip."
  (prrr-db-with-test-db
    (let ((meta (prrr-pr-meta-create
                 :pr-id "PR_1" :forge-repo-id "example-repo-id" :number 7
                 :head-oid "1111111111111111111111111111111111111111"
                 :review-requests '((user "example-me")
                                    (team "example-org/reviewers"))
                 :latest-reviews '(("example-bob" "APPROVED"
                                    "2026-09-02T10:00:00Z"
                                    "1111111111111111111111111111111111111111"
                                    ("example-org/reviewers")))
                 :viewer-latest-review nil
                 :viewer-latest-review-request "example-alice"
                 :created-at "2026-09-01T09:00:00Z"
                 :fetched-at "2026-10-10T12:00:00Z")))
      (should (eq meta (prrr-db-insert meta)))
      (should (equal meta (prrr-db-get 'pullreq-meta "PR_1")))
      (should (null (prrr-db-get 'pullreq-meta "PR_404"))))))

(ert-deftest prrr-db-test-insert-replaces-existing-row ()
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-bookmark-create :pr-id "PR_1" :last-opened-head-oid "a"
                                          :last-opened-at "2026-10-01T00:00:00Z"))
    (prrr-db-insert (prrr-bookmark-create :pr-id "PR_1" :last-opened-head-oid "b"
                                          :last-opened-at "2026-10-02T00:00:00Z"))
    (should (= 1 (length (prrr-db-select 'pr-bookmark))))
    (should (equal "b" (prrr-bookmark-last-opened-head-oid
                        (prrr-db-get 'pr-bookmark "PR_1"))))))

(ert-deftest prrr-db-test-get-with-composite-key ()
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-viewed-create :pr-id "PR_1" :path "src/a.el"
                                        :state 'viewed :fetched-at nil))
    (prrr-db-insert (prrr-viewed-create :pr-id "PR_1" :path "src/b.el"
                                        :state 'dismissed :fetched-at nil))
    (should (eq 'dismissed
                (prrr-viewed-state (prrr-db-get 'viewed "PR_1" "src/b.el"))))
    (should (null (prrr-db-get 'viewed "PR_2" "src/b.el")))
    (should-error (prrr-db-get 'viewed "PR_1"))))

(ert-deftest prrr-db-test-select-filters-by-columns ()
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-thread-create :thread-id "T_1" :pr-id "PR_1" :path "a"
                                        :side 'right :subject-type 'line
                                        :resolved-p t))
    (prrr-db-insert (prrr-thread-create :thread-id "T_2" :pr-id "PR_1" :path "b"
                                        :side 'right :subject-type 'line
                                        :resolved-p nil))
    (prrr-db-insert (prrr-thread-create :thread-id "T_3" :pr-id "PR_2" :path "a"
                                        :side 'left :subject-type 'file
                                        :resolved-p t))
    (should (= 3 (length (prrr-db-select 'thread))))
    (should (equal '("T_1" "T_2")
                   (mapcar #'prrr-thread-thread-id
                           (prrr-db-select 'thread :pr-id "PR_1"))))
    (should (equal '("T_1")
                   (mapcar #'prrr-thread-thread-id
                           (prrr-db-select 'thread :pr-id "PR_1" :resolved-p t))))
    (should (eq t (prrr-thread-resolved-p (prrr-db-get 'thread "T_1"))))
    (should (eq 'file (prrr-thread-subject-type (prrr-db-get 'thread "T_3"))))))

(ert-deftest prrr-db-test-delete-by-columns-and-all ()
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-team-create :combined-slug "example-org/a" :org "example-org" :slug "a"))
    (prrr-db-insert (prrr-team-create :combined-slug "example-org/b" :org "example-org" :slug "b"))
    (prrr-db-insert (prrr-team-create :combined-slug "other/c" :org "other" :slug "c"))
    (prrr-db-delete 'team :org "example-org")
    (should (equal '("other/c")
                   (mapcar #'prrr-team-combined-slug (prrr-db-select 'team))))
    (prrr-db-delete 'team)
    (should (null (prrr-db-select 'team)))))

(ert-deftest prrr-db-test-insert-rejects-foreign-value ()
  (prrr-db-with-test-db
    (should-error (prrr-db-insert (list 'not 'a 'struct)))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test TESTS=test/prrr-db-test.el SELECTOR='"prrr-db-test-insert\\|select\\|get\\|delete"'`
Expected: the six new tests fail with `void-function prrr-db-insert` and friends.

- [ ] **Step 3: Implement the CRUD functions**

Insert before `(provide 'prrr-db)`:

```elisp
;;;; Generic CRUD

(defun prrr-db--table-of (struct)
  "Return the table whose rows are instances of STRUCT's type."
  (let ((type (type-of struct)))
    (or (and (recordp struct)
             (car (seq-find (lambda (entry) (eq (nth 1 entry) type))
                            prrr-db--tables)))
        (error "prrr-db: %S is not a prrr row struct" struct))))

(defun prrr-db--struct-to-row (struct)
  "Return STRUCT's slot values as a vector in column order."
  (let ((type (type-of struct)))
    (apply #'vector
           (mapcar (lambda (slot) (cl-struct-slot-value type slot struct))
                   (prrr-db--slot-names type)))))

(defun prrr-db--where (plist)
  "Translate PLIST of :column value pairs into (WHERE-FORM . VALUES).
WHERE-FORM is nil when PLIST is empty.  Column values are bound to
$s1, $s2, ... in order.  A nil value never matches (SQL NULL)."
  (let ((clauses nil) (values nil) (n 0))
    (while plist
      (let* ((column (intern (substring (symbol-name (pop plist)) 1)))
             (value (pop plist)))
        (setq n (1+ n))
        (push (list '= column (intern (format "$s%d" n))) clauses)
        (push value values)))
    (setq clauses (nreverse clauses))
    (cons (pcase clauses
            ('nil nil)
            (`(,one) one)
            (_ (cons 'and clauses)))
          (nreverse values))))

(defun prrr-db-insert (struct)
  "Insert STRUCT into its table, replacing a row with the same key.
Return STRUCT."
  (emacsql (prrr-db)
           (vector :insert-or-replace :into (prrr-db--table-of struct)
                   :values '$v1)
           (list (prrr-db--struct-to-row struct)))
  struct)

(defun prrr-db-select (table &rest plist)
  "Return the rows of TABLE matching PLIST as structs.
PLIST is :column value pairs that must all match; with no pairs every
row is returned.  Rows come back in insertion order."
  (pcase-let ((`(,where . ,values) (prrr-db--where plist)))
    (mapcar (lambda (row) (prrr-db--row-to-struct table row))
            (apply #'emacsql (prrr-db)
                   (if where
                       (vector :select '* :from table :where where)
                     (vector :select '* :from table))
                   values))))

(defun prrr-db-get (table &rest key)
  "Return the row of TABLE whose primary key is KEY, or nil.
KEY has one value per primary key column, so a composite key such as
`viewed' takes two: (prrr-db-get \\='viewed PR-ID PATH)."
  (let ((columns (prrr-db--primary-key table)))
    (unless (= (length columns) (length key))
      (error "prrr-db: %s needs %d key values, got %d"
             table (length columns) (length key)))
    (car (apply #'prrr-db-select table
                (cl-loop for column in columns
                         for value in key
                         append (list (intern (format ":%s" column)) value))))))

(defun prrr-db-delete (table &rest plist)
  "Delete the rows of TABLE matching PLIST (:column value pairs).
With no pairs every row of TABLE is deleted."
  (pcase-let ((`(,where . ,values) (prrr-db--where plist)))
    (apply #'emacsql (prrr-db)
           (if where
               (vector :delete :from table :where where)
             (vector :delete :from table))
           values)))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make compile lint && make test TESTS=test/prrr-db-test.el`
Expected: `Ran 13 tests, 13 results as expected`.

- [ ] **Step 5: Commit**

```bash
git add prrr-db.el test/prrr-db-test.el
git commit -m "feat(db): generic insert, get, select and delete over row structs"
```

---

### Task 4: `prrr-github.el` queue query, decoder and request function

**Files:**
- Create: `prrr-github.el`, `test/prrr-github-test.el`, `test/fixtures/github/queue.eld`
- Modify: `test/prrr-test-helper.el` (add `prrr-test-with-ghub-stub`), `prrr.el` (add `(require 'prrr-github)`)

**Interfaces:**
- Consumes: `prrr-pr-meta-create` from Task 2; `prrr-test-fixture` from Task 1.
- Produces: `prrr-github-queue-query` (ghub DSL list); `(prrr-github--query HOST QUERY-SYMBOL VARIABLES &rest KEYS)` macro; `(prrr-github--now) -> string`; `(prrr-github-decode-queue DATA FORGE-REPO-ID &optional FETCHED-AT) -> list of prrr-pr-meta`; `(prrr-github-fetch-queue HOST OWNER NAME CALLBACK &optional FORGE-REPO-ID)`; test macro `(prrr-test-with-ghub-stub FIXTURE CAPTURED &rest BODY)` where CAPTURED is bound to `(QUERY VARIABLES)` after the call.

- [ ] **Step 1: Write the queue fixture**

`test/fixtures/github/queue.eld` holds exactly what the `forge-query` callback receives (facts note: the leading `data` symbol is skipped by `assq`, connections marked `(:edges t)` arrive as plain lists of node alists, JSON `null` and `false` are both nil). Three PRs: #1 by `example-alice` with a direct request for `example-me`, a Team request, and a review by `example-bob` on behalf of the Team; #2 a draft by `example-bob` that `example-me` commented on at an older commit; #3 by `example-me` with a `CHANGES_REQUESTED` review and a `DISMISSED` review by a deleted user whose commit is also gone.

```elisp
;; Queue inputs for example-org/example-repo as the forge-query callback
;; receives them.  Re-record with scripts/record-fixtures.el, then
;; replace every real name with an `example' name.
(data
 (repository
  (pullRequests
   ((id . "PR_kwDOexample0000001")
    (number . 1)
    (headRefOid . "1111111111111111111111111111111111111111")
    (createdAt . "2026-09-01T09:00:00Z")
    (isDraft)
    (author (login . "example-alice"))
    (reviewRequests
     ((requestedReviewer (__typename . "User") (login . "example-me")))
     ((requestedReviewer (__typename . "Team")
                         (combinedSlug . "example-org/reviewers")))
     ((requestedReviewer (__typename . "Bot"))))
    (latestReviews
     ((author (login . "example-bob"))
      (state . "APPROVED")
      (submittedAt . "2026-09-02T10:00:00Z")
      (commit (oid . "1111111111111111111111111111111111111111"))
      (onBehalfOf ((combinedSlug . "example-org/reviewers")))))
    (viewerLatestReview)
    (viewerLatestReviewRequest (login . "example-alice")))
   ((id . "PR_kwDOexample0000002")
    (number . 2)
    (headRefOid . "2222222222222222222222222222222222222222")
    (createdAt . "2026-09-03T08:00:00Z")
    (isDraft . t)
    (author (login . "example-bob"))
    (reviewRequests)
    (latestReviews
     ((author (login . "example-me"))
      (state . "COMMENTED")
      (submittedAt . "2026-09-04T08:00:00Z")
      (commit (oid . "2222222222222222222222222222222222222200"))
      (onBehalfOf)))
    (viewerLatestReview
     (state . "COMMENTED")
     (submittedAt . "2026-09-04T08:00:00Z")
     (commit (oid . "2222222222222222222222222222222222222200")))
    (viewerLatestReviewRequest))
   ((id . "PR_kwDOexample0000003")
    (number . 3)
    (headRefOid . "3333333333333333333333333333333333333333")
    (createdAt . "2026-09-05T07:00:00Z")
    (isDraft)
    (author (login . "example-me"))
    (reviewRequests)
    (latestReviews
     ((author (login . "example-carol"))
      (state . "CHANGES_REQUESTED")
      (submittedAt . "2026-09-06T07:00:00Z")
      (commit (oid . "3333333333333333333333333333333333333333"))
      (onBehalfOf))
     ((author)
      (state . "DISMISSED")
      (submittedAt . "2026-09-05T12:00:00Z")
      (commit)
      (onBehalfOf)))
    (viewerLatestReview)
    (viewerLatestReviewRequest)))))
```

- [ ] **Step 2: Write the failing tests**

`test/prrr-github-test.el` (header as in Task 1, first line `;;; prrr-github-test.el --- Tests for prrr-github  -*- lexical-binding: t -*-`):

```elisp
;;; Commentary:

;; Decoders run against the recorded fixtures under
;; test/fixtures/github/; request functions run with `ghub-query'
;; stubbed, so nothing here touches the network.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'prrr-test-helper)
(require 'prrr-github)

(ert-deftest prrr-github-test-decode-queue-one-meta-per-pr ()
  (let ((metas (prrr-github-decode-queue (prrr-test-fixture "queue")
                                         "example-repo-id" "2026-10-10T12:00:00Z")))
    (should (= 3 (length metas)))
    (should (cl-every #'prrr-pr-meta-p metas))
    (should (equal '("PR_kwDOexample0000001" "PR_kwDOexample0000002"
                     "PR_kwDOexample0000003")
                   (mapcar #'prrr-pr-meta-pr-id metas)))
    (should (equal '(1 2 3) (mapcar #'prrr-pr-meta-number metas)))
    (should (cl-every (lambda (m) (equal "example-repo-id" (prrr-pr-meta-forge-repo-id m)))
                      metas))
    (should (cl-every (lambda (m) (equal "2026-10-10T12:00:00Z" (prrr-pr-meta-fetched-at m)))
                      metas))))

(ert-deftest prrr-github-test-decode-queue-scalars ()
  (let ((meta (car (prrr-github-decode-queue (prrr-test-fixture "queue") nil))))
    (should (equal "1111111111111111111111111111111111111111" (prrr-pr-meta-head-oid meta)))
    (should (equal "2026-09-01T09:00:00Z" (prrr-pr-meta-created-at meta)))
    (should (null (prrr-pr-meta-fetched-at meta)))))

(ert-deftest prrr-github-test-decode-queue-review-requests-by-typename ()
  "Users become (user LOGIN), Teams (team COMBINED-SLUG); other kinds are dropped."
  (let ((meta (car (prrr-github-decode-queue (prrr-test-fixture "queue") nil))))
    (should (equal '((user "example-me") (team "example-org/reviewers"))
                   (prrr-pr-meta-review-requests meta)))))

(ert-deftest prrr-github-test-decode-queue-latest-reviews ()
  (let ((metas (prrr-github-decode-queue (prrr-test-fixture "queue") nil)))
    (should (equal '(("example-bob" "APPROVED" "2026-09-02T10:00:00Z"
                      "1111111111111111111111111111111111111111"
                      ("example-org/reviewers")))
                   (prrr-pr-meta-latest-reviews (nth 0 metas))))
    ;; Review Focus 2 and 5: a deleted author and a missing commit decode to nil.
    (should (equal '(("example-carol" "CHANGES_REQUESTED" "2026-09-06T07:00:00Z"
                      "3333333333333333333333333333333333333333" nil)
                     (nil "DISMISSED" "2026-09-05T12:00:00Z" nil nil))
                   (prrr-pr-meta-latest-reviews (nth 2 metas))))))

(ert-deftest prrr-github-test-decode-queue-viewer-fields ()
  (let ((metas (prrr-github-decode-queue (prrr-test-fixture "queue") nil)))
    (should (null (prrr-pr-meta-viewer-latest-review (nth 0 metas))))
    (should (equal "example-alice" (prrr-pr-meta-viewer-latest-review-request (nth 0 metas))))
    (should (equal '("COMMENTED" "2026-09-04T08:00:00Z"
                     "2222222222222222222222222222222222222200")
                   (prrr-pr-meta-viewer-latest-review (nth 1 metas))))
    (should (null (prrr-pr-meta-viewer-latest-review-request (nth 1 metas))))))

(ert-deftest prrr-github-test-decode-queue-empty-repository ()
  (should (null (prrr-github-decode-queue '(data (repository (pullRequests))) nil))))

(ert-deftest prrr-github-test-fetch-queue-sends-query-and-decodes ()
  (prrr-test-with-ghub-stub (prrr-test-fixture "queue") captured
    (let (result)
      (prrr-github-fetch-queue "api.github.com" "example-org" "example-repo"
                               (lambda (metas) (setq result metas))
                               "example-repo-id")
      (should (equal `(query ,prrr-github-queue-query) (nth 0 captured)))
      (should (equal '((owner . "example-org") (name . "example-repo")) (nth 1 captured)))
      (should (= 3 (length result)))
      (should (equal "example-repo-id" (prrr-pr-meta-forge-repo-id (car result))))
      (should (stringp (prrr-pr-meta-fetched-at (car result)))))))

(ert-deftest prrr-github-test-queue-query-shape ()
  "The query pages open PRs and selects both reviewer kinds."
  (should (eq 'repository (car prrr-github-queue-query)))
  (let ((prs (assq 'pullRequests (cddr prrr-github-queue-query))))
    (should (member '(:edges t) (append (cadr prs) nil)))
    (should (member '(states . (OPEN)) (append (cadr prs) nil)))
    (should (string-match-p "__typename.*on User { login }.*on Team { combinedSlug }"
                            (format "%S" prs)))))

(provide 'prrr-github-test)
;;; prrr-github-test.el ends here
```

Add to `test/prrr-test-helper.el`, after the `prrr-db-with-test-db` macro:

```elisp
(defmacro prrr-test-with-ghub-stub (fixture captured &rest body)
  "Run BODY with `ghub-query' answering every request with FIXTURE.
CAPTURED is bound to (QUERY VARIABLES) of the last request, so BODY can
inspect what `forge-query' sent.  The callback runs synchronously."
  (declare (indent 2) (debug (form symbolp body)))
  `(let ((,captured nil))
     (cl-letf (((symbol-function 'ghub-query)
                (lambda (query variables &rest args)
                  (setq ,captured (list query variables))
                  (funcall (plist-get args :callback) ,fixture))))
       ,@body)))
```

and add `(require 'cl-lib)` next to `(require 'ert)` at the top of the helper.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `make test TESTS=test/prrr-github-test.el`
Expected: `Cannot open load file: prrr-github`.

- [ ] **Step 4: Confirm how `forge-query` takes its query**

Run:

```bash
emacs -Q --batch --eval '(setq package-user-dir (expand-file-name ".deps"))' \
  --eval '(package-initialize)' -l forge \
  --eval '(pp (macroexpand-1 (quote (forge-query "api.github.com" (viewer login) nil :callback (function ignore)))))'
```

Expected: the expansion contains the query as quoted data (`'(viewer login)` or `(quote (viewer login))`), confirming that `forge-query` is a macro that takes the DSL literally (facts note; forge's own calls write the query inline). This is why `prrr-github--query` below splices the constant in at macro-expansion time. If the expansion instead passed `(viewer login)` through unquoted for evaluation, the macro body becomes `` `(forge-query ,host ,query-symbol ,variables ,@keys) `` and nothing else in this task changes.

- [ ] **Step 5: Write `prrr-github.el`**

First line `;;; prrr-github.el --- GitHub GraphQL access for prrr  -*- lexical-binding: t -*-`, license block, then:

```elisp
;;; Commentary:

;; Every GitHub call prrr makes lives here.  Queries are written in
;; ghub's Lisp GraphQL DSL and sent through `forge-query', so the host,
;; the token and pagination come from forge.  The decoders are pure
;; functions from the callback data to `prrr-db' structs and are tested
;; against the fixtures under test/fixtures/github/.
;;
;; Response shape (facts note): the callback receives
;; (data (repository ...)); `let-alist' works on it directly.  A
;; connection written as [(:edges t)] arrives as a plain list of node
;; alists.  JSON null and false both arrive as nil.
;;
;; Mutations arrive in milestone 4; this file is read-only until then.

;;; Code:

(require 'cl-lib)
(require 'let-alist)
(require 'forge)
(require 'prrr-db)

;;;; Queries

(eval-and-compile
  (defconst prrr-github-queue-query
    '(repository [(owner $owner String!) (name $name String!)]
       (pullRequests [(:edges t) (states . (OPEN))]
         id number headRefOid createdAt isDraft
         (author login)
         (reviewRequests [(:edges t)]
           (requestedReviewer "__typename ... on User { login } ... on Team { combinedSlug }\n"))
         (latestReviews [(:edges t)]
           (author login) state submittedAt (commit oid)
           (onBehalfOf [(:edges t)] combinedSlug))
         (viewerLatestReview state submittedAt (commit oid))
         (viewerLatestReviewRequest login)))
    "Review Queue inputs of one repository (SPEC section 4).
Variables: $owner and $name.  Pages every open PR."))

(defmacro prrr-github--query (host query-symbol variables &rest keys)
  "Send the query stored in QUERY-SYMBOL to HOST through `forge-query'.
VARIABLES is a list of (NAME VALUE) pairs; KEYS are `forge-query'
keyword arguments such as :callback.  `forge-query' takes its query
literally, so the constant named by QUERY-SYMBOL is spliced into the
call at macro-expansion time."
  (declare (indent 2))
  `(forge-query ,host ,(symbol-value query-symbol) ,variables ,@keys))

(defun prrr-github--now ()
  "Return the current UTC time as GitHub formats timestamps."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))

;;;; Decoding the queue

(defun prrr-github--review-requests (nodes)
  "Decode reviewRequests NODES into (user LOGIN) and (team SLUG) pairs.
Requested reviewers of other kinds (bots, mannequins) are dropped."
  (delq nil
        (mapcar (lambda (node)
                  (let-alist node
                    (pcase .requestedReviewer.__typename
                      ("User" (list 'user .requestedReviewer.login))
                      ("Team" (list 'team .requestedReviewer.combinedSlug)))))
                nodes)))

(defun prrr-github--latest-reviews (nodes)
  "Decode latestReviews NODES.
Each result is (LOGIN STATE SUBMITTED-AT COMMIT-OID ON-BEHALF-OF-SLUGS)."
  (mapcar (lambda (node)
            (let-alist node
              (list .author.login .state .submittedAt .commit.oid
                    (mapcar (lambda (team) (alist-get 'combinedSlug team))
                            .onBehalfOf))))
          nodes))

(defun prrr-github--viewer-review (node)
  "Decode a viewerLatestReview NODE into (STATE SUBMITTED-AT COMMIT-OID)."
  (and node (let-alist node (list .state .submittedAt .commit.oid))))

(defun prrr-github-decode-queue (data forge-repo-id &optional fetched-at)
  "Decode queue query DATA into a list of `prrr-pr-meta'.
FORGE-REPO-ID is stored in every row; FETCHED-AT is the timestamp to
record, nil when the caller stamps rows itself."
  (let-alist data
    (mapcar (lambda (pr)
              (let-alist pr
                (prrr-pr-meta-create
                 :pr-id .id
                 :forge-repo-id forge-repo-id
                 :number .number
                 :head-oid .headRefOid
                 :review-requests (prrr-github--review-requests .reviewRequests)
                 :latest-reviews (prrr-github--latest-reviews .latestReviews)
                 :viewer-latest-review (prrr-github--viewer-review .viewerLatestReview)
                 :viewer-latest-review-request .viewerLatestReviewRequest.login
                 :created-at .createdAt
                 :fetched-at fetched-at)))
            .repository.pullRequests)))

;;;; Requests

(defun prrr-github-fetch-queue (host owner name callback &optional forge-repo-id)
  "Fetch the Review Queue inputs of OWNER/NAME on HOST.
CALLBACK receives a list of `prrr-pr-meta' stamped with the current
time and FORGE-REPO-ID."
  (prrr-github--query host prrr-github-queue-query
    ((owner owner) (name name))
    :callback (lambda (data &rest _)
                (funcall callback
                         (prrr-github-decode-queue data forge-repo-id
                                                   (prrr-github--now))))))

(provide 'prrr-github)
;;; prrr-github.el ends here
```

Add `(require 'prrr-github)` to `prrr.el` after `(require 'prrr-db)`.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `make compile lint && make test TESTS=test/prrr-github-test.el`
Expected: `Ran 8 tests, 8 results as expected`.

If `prrr-github-test-fetch-queue-sends-query-and-decodes` fails with a wrong-number-of-arguments error raised inside forge, forge wrapped the callback and calls it with more arguments: change the stub's `funcall` to `(apply (plist-get args :callback) ,fixture (make-list 3 nil))` (data, headers, status) in the helper and keep everything else.

- [ ] **Step 7: Commit**

```bash
git add prrr-github.el prrr.el test/prrr-github-test.el test/prrr-test-helper.el test/fixtures/github/queue.eld
git commit -m "feat(github): queue query, decoder and fetch with recorded fixture"
```

---

### Task 5: `prrr-github.el` viewer teams

**Files:**
- Modify: `prrr-github.el`, `test/prrr-github-test.el`
- Create: `test/fixtures/github/teams.eld`

**Interfaces:**
- Consumes: `prrr-github--query`, `prrr-github--now`, `prrr-team-create`.
- Produces: `prrr-github-teams-query`; `(prrr-github-decode-teams DATA &optional FETCHED-AT) -> list of prrr-team`; `(prrr-github-fetch-teams HOST ME CALLBACK)`.

- [ ] **Step 1: Write the teams fixture**

`test/fixtures/github/teams.eld`:

```elisp
;; The viewer's Teams across organizations, as the forge-query callback
;; receives them.  `teams' is an edges connection, so it arrives flat.
(data
 (viewer
  (login . "example-me")
  (organizations
   ((login . "example-org")
    (teams
     ((slug . "reviewers") (combinedSlug . "example-org/reviewers"))
     ((slug . "platform") (combinedSlug . "example-org/platform"))))
   ((login . "example-other-org")
    (teams)))))
```

- [ ] **Step 2: Write the failing tests**

Insert before `(provide 'prrr-github-test)`:

```elisp
(ert-deftest prrr-github-test-decode-teams ()
  (let ((teams (prrr-github-decode-teams (prrr-test-fixture "teams")
                                         "2026-10-10T12:00:00Z")))
    (should (= 2 (length teams)))
    (should (cl-every #'prrr-team-p teams))
    (should (equal '("example-org/reviewers" "example-org/platform")
                   (mapcar #'prrr-team-combined-slug teams)))
    (should (equal '("reviewers" "platform") (mapcar #'prrr-team-slug teams)))
    (should (equal '("example-org" "example-org") (mapcar #'prrr-team-org teams)))
    (should (equal "2026-10-10T12:00:00Z" (prrr-team-fetched-at (car teams))))))

(ert-deftest prrr-github-test-decode-teams-no-organizations ()
  (should (null (prrr-github-decode-teams
                 '(data (viewer (login . "example-me") (organizations)))))))

(ert-deftest prrr-github-test-fetch-teams-sends-login-and-decodes ()
  (prrr-test-with-ghub-stub (prrr-test-fixture "teams") captured
    (let (result)
      (prrr-github-fetch-teams "api.github.com" "example-me"
                               (lambda (teams) (setq result teams)))
      (should (equal prrr-github-teams-query (nth 0 captured)))
      (should (equal '((me ("example-me"))) (nth 1 captured)))
      (should (= 2 (length result)))
      (should (stringp (prrr-team-fetched-at (car result)))))))
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `make test TESTS=test/prrr-github-test.el SELECTOR='"teams"'`
Expected: 3 failures, `void-function prrr-github-decode-teams`.

- [ ] **Step 4: Check how ghub encodes a list-typed variable**

The Teams query filters with `teams(userLogins: [$me])` (SPEC section 4), which needs `$me` declared as `[String!]`. Confirm ghub's encoder (`gsexp-encode`, in gsexp.el shipped with ghub) prints that declaration:

```bash
emacs -Q --batch --eval '(setq package-user-dir (expand-file-name ".deps"))' \
  --eval '(package-initialize)' -l ghub-graphql \
  --eval '(princ (gsexp-encode (quote (query (viewer login (organizations [(first 100)] login (teams [(first 100) (userLogins $me [String!])] slug combinedSlug)))))))'
```

Expected output contains `$me:[String!]` in the declaration list and `userLogins:$me` in the field. If it does, use form A below. If the type is printed differently (or the encoder rejects a vector), use form B, which asks for the teams the viewer is a member of without a variable; ME is then unused by the query. The decoder and fixture are the same for both.

- [ ] **Step 5: Implement the query, decoder and request**

Add after the queue query's `eval-and-compile` block. Form A:

```elisp
(eval-and-compile
  (defconst prrr-github-teams-query
    '(viewer login
       (organizations [(:edges t)]
         login
         (teams [(:edges t) (userLogins $me [String!])] slug combinedSlug)))
    "The viewer's Teams in every organization (SPEC section 4).
Variable: $me, a one-element list holding the viewer's login."))
```

Form B (only if Step 4 showed the declaration is not encoded):

```elisp
(eval-and-compile
  (defconst prrr-github-teams-query
    '(viewer login
       (organizations [(:edges t)]
         login
         (teams [(:edges t) (role . MEMBER)] slug combinedSlug)))
    "The viewer's Teams in every organization (SPEC section 4).
No variables: `role: MEMBER' restricts the list to the viewer's Teams."))
```

With form B, `prrr-github-fetch-teams` passes `nil` as VARIABLES (ME stays in the signature for the caller's sake) and the test's variables assertion becomes `(should (null (nth 1 captured)))`.

Add after `prrr-github-decode-queue`:

```elisp
;;;; Decoding teams

(defun prrr-github-decode-teams (data &optional fetched-at)
  "Decode viewer teams DATA into a list of `prrr-team' stamped FETCHED-AT."
  (let-alist data
    (cl-mapcan (lambda (org)
                 (let ((org-login (alist-get 'login org)))
                   (mapcar (lambda (team)
                             (let-alist team
                               (prrr-team-create :combined-slug .combinedSlug
                                                 :org org-login
                                                 :slug .slug
                                                 :fetched-at fetched-at)))
                           (alist-get 'teams org))))
               .viewer.organizations)))
```

Add after `prrr-github-fetch-queue`:

```elisp
(defun prrr-github-fetch-teams (host me callback)
  "Fetch the Teams of the viewer ME on HOST.
CALLBACK receives a list of `prrr-team' stamped with the current time."
  (prrr-github--query host prrr-github-teams-query
    ((me (vector me)))
    :callback (lambda (data &rest _)
                (funcall callback
                         (prrr-github-decode-teams data (prrr-github--now))))))
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `make compile lint && make test TESTS=test/prrr-github-test.el`
Expected: `Ran 11 tests, 11 results as expected`.

- [ ] **Step 7: Commit**

```bash
git add prrr-github.el test/prrr-github-test.el test/fixtures/github/teams.eld
git commit -m "feat(github): viewer teams query, decoder and fetch"
```

---

### Task 6: `prrr-github.el` per-PR review data

**Files:**
- Modify: `prrr-github.el`, `test/prrr-github-test.el`
- Create: `test/fixtures/github/review-data.eld`

**Interfaces:**
- Consumes: `prrr-github--query`, `prrr-github--now`, `prrr-thread-create`, `prrr-comment-create`, `prrr-pending-review-create`, `prrr-viewed-create`.
- Produces: `prrr-github-review-data-query`; `(prrr-github-decode-review-data DATA PR-ID &optional FETCHED-AT) -> plist (:threads :comments :pending-review :viewed :head-oid)`; `(prrr-github-fetch-review-data HOST OWNER NAME NUMBER ME CALLBACK)`.

- [ ] **Step 1: Write the review-data fixture**

`test/fixtures/github/review-data.eld`. PR #1 with five Threads: an open line Thread with a reply, a resolved range Thread, an outdated Thread, a file-level Thread, and the viewer's pending Thread; one pending review by the viewer; three files, one per Viewed state.

```elisp
;; Review data of example-org/example-repo#1 as the forge-query callback
;; receives it: reviewThreads, the viewer's PENDING review, files with
;; viewerViewedState, and the head oid.
(data
 (repository
  (pullRequest
   (id . "PR_kwDOexample0000001")
   (headRefOid . "1111111111111111111111111111111111111111")
   (reviewThreads
    ((id . "PRRT_kwDOexample0000001")
     (path . "src/example.el")
     (line . 12)
     (startLine)
     (diffSide . "RIGHT")
     (startDiffSide)
     (originalLine . 12)
     (isOutdated)
     (isResolved)
     (subjectType . "LINE")
     (viewerCanResolve . t)
     (viewerCanUnresolve . t)
     (comments
      ((id . "PRRC_kwDOexample0000001")
       (author (login . "example-bob"))
       (body . "Should this be a `when'?")
       (createdAt . "2026-09-02T10:00:00Z")
       (lastEditedAt)
       (replyTo)
       (state . "SUBMITTED")
       (pullRequestReview (id . "PRR_kwDOexample0000001"))
       (originalCommit (oid . "1111111111111111111111111111111111111111")))
      ((id . "PRRC_kwDOexample0000002")
       (author (login . "example-me"))
       (body . "Yes, fixing.")
       (createdAt . "2026-09-02T11:00:00Z")
       (lastEditedAt . "2026-09-02T11:05:00Z")
       (replyTo (id . "PRRC_kwDOexample0000001"))
       (state . "SUBMITTED")
       (pullRequestReview (id . "PRR_kwDOexample0000002"))
       (originalCommit (oid . "1111111111111111111111111111111111111111")))))
    ((id . "PRRT_kwDOexample0000002")
     (path . "README.md")
     (line . 3)
     (startLine . 1)
     (diffSide . "RIGHT")
     (startDiffSide . "RIGHT")
     (originalLine . 3)
     (isOutdated)
     (isResolved . t)
     (subjectType . "LINE")
     (viewerCanResolve . t)
     (viewerCanUnresolve . t)
     (comments
      ((id . "PRRC_kwDOexample0000003")
       (author (login . "example-carol"))
       (body . "Typo in the title.")
       (createdAt . "2026-09-02T12:00:00Z")
       (lastEditedAt)
       (replyTo)
       (state . "SUBMITTED")
       (pullRequestReview (id . "PRR_kwDOexample0000003"))
       (originalCommit (oid . "1111111111111111111111111111111111111111")))))
    ((id . "PRRT_kwDOexample0000003")
     (path . "src/old.el")
     (line)
     (startLine)
     (diffSide . "LEFT")
     (startDiffSide)
     (originalLine . 40)
     (isOutdated . t)
     (isResolved)
     (subjectType . "LINE")
     (viewerCanResolve . t)
     (viewerCanUnresolve . t)
     (comments
      ((id . "PRRC_kwDOexample0000004")
       (author (login . "example-bob"))
       (body . "This branch is dead.")
       (createdAt . "2026-08-30T09:00:00Z")
       (lastEditedAt)
       (replyTo)
       (state . "SUBMITTED")
       (pullRequestReview (id . "PRR_kwDOexample0000001"))
       (originalCommit (oid . "0000000000000000000000000000000000000001")))))
    ((id . "PRRT_kwDOexample0000004")
     (path . "docs/notes.md")
     (line)
     (startLine)
     (diffSide . "RIGHT")
     (startDiffSide)
     (originalLine)
     (isOutdated)
     (isResolved)
     (subjectType . "FILE")
     (viewerCanResolve . t)
     (viewerCanUnresolve . t)
     (comments
      ((id . "PRRC_kwDOexample0000005")
       (author (login . "example-carol"))
       (body . "Please split this file.")
       (createdAt . "2026-09-03T08:00:00Z")
       (lastEditedAt)
       (replyTo)
       (state . "SUBMITTED")
       (pullRequestReview (id . "PRR_kwDOexample0000003"))
       (originalCommit (oid . "1111111111111111111111111111111111111111")))))
    ((id . "PRRT_kwDOexample0000005")
     (path . "src/example.el")
     (line . 30)
     (startLine)
     (diffSide . "RIGHT")
     (startDiffSide)
     (originalLine . 30)
     (isOutdated)
     (isResolved)
     (subjectType . "LINE")
     (viewerCanResolve . t)
     (viewerCanUnresolve . t)
     (comments
      ((id . "PRRC_kwDOexample0000006")
       (author (login . "example-me"))
       (body . "Draft: rename this.")
       (createdAt . "2026-09-04T09:00:00Z")
       (lastEditedAt)
       (replyTo)
       (state . "PENDING")
       (pullRequestReview (id . "PRR_kwDOexamplePending1"))
       (originalCommit (oid . "1111111111111111111111111111111111111111"))))))
   (reviews
    ((id . "PRR_kwDOexamplePending1")
     (commit (oid . "1111111111111111111111111111111111111111"))
     (body . "")
     (createdAt . "2026-09-04T09:00:00Z")))
   (files
    ((path . "src/example.el") (viewerViewedState . "VIEWED"))
    ((path . "README.md") (viewerViewedState . "DISMISSED"))
    ((path . "docs/notes.md") (viewerViewedState . "UNVIEWED"))))))
```

- [ ] **Step 2: Write the failing tests**

Insert before `(provide 'prrr-github-test)`:

```elisp
(defun prrr-github-test--review-data ()
  "Decode the review-data fixture for PR_kwDOexample0000001."
  (prrr-github-decode-review-data (prrr-test-fixture "review-data")
                                  "PR_kwDOexample0000001"
                                  "2026-10-10T12:00:00Z"))

(ert-deftest prrr-github-test-decode-review-data-threads ()
  (let ((threads (plist-get (prrr-github-test--review-data) :threads)))
    (should (= 5 (length threads)))
    (should (cl-every #'prrr-thread-p threads))
    (should (cl-every (lambda (th) (equal "PR_kwDOexample0000001" (prrr-thread-pr-id th)))
                      threads))
    (let ((open (nth 0 threads)))
      (should (equal "PRRT_kwDOexample0000001" (prrr-thread-thread-id open)))
      (should (equal "src/example.el" (prrr-thread-path open)))
      (should (= 12 (prrr-thread-line open)))
      (should (null (prrr-thread-start-line open)))
      (should (eq 'right (prrr-thread-side open)))
      (should (null (prrr-thread-start-side open)))
      (should (eq 'line (prrr-thread-subject-type open)))
      (should (null (prrr-thread-outdated-p open)))
      (should (null (prrr-thread-resolved-p open)))
      (should (= 12 (prrr-thread-original-line open)))
      (should (equal "1111111111111111111111111111111111111111"
                     (prrr-thread-original-commit open)))
      (should (equal "2026-10-10T12:00:00Z" (prrr-thread-fetched-at open))))))

(ert-deftest prrr-github-test-decode-review-data-resolved-range-thread ()
  (let ((th (nth 1 (plist-get (prrr-github-test--review-data) :threads))))
    (should (eq t (prrr-thread-resolved-p th)))
    (should (= 1 (prrr-thread-start-line th)))
    (should (eq 'right (prrr-thread-start-side th)))))

(ert-deftest prrr-github-test-decode-review-data-outdated-thread ()
  (let ((th (nth 2 (plist-get (prrr-github-test--review-data) :threads))))
    (should (eq t (prrr-thread-outdated-p th)))
    (should (null (prrr-thread-line th)))
    (should (= 40 (prrr-thread-original-line th)))
    (should (eq 'left (prrr-thread-side th)))
    (should (equal "0000000000000000000000000000000000000001"
                   (prrr-thread-original-commit th)))))

(ert-deftest prrr-github-test-decode-review-data-file-thread ()
  (let ((th (nth 3 (plist-get (prrr-github-test--review-data) :threads))))
    (should (eq 'file (prrr-thread-subject-type th)))
    (should (null (prrr-thread-line th)))
    (should (equal "docs/notes.md" (prrr-thread-path th)))))

(ert-deftest prrr-github-test-decode-review-data-comments ()
  (let ((comments (plist-get (prrr-github-test--review-data) :comments)))
    (should (= 6 (length comments)))
    (should (cl-every #'prrr-comment-p comments))
    (let ((first (nth 0 comments)) (reply (nth 1 comments)) (pending (nth 5 comments)))
      (should (equal "PRRC_kwDOexample0000001" (prrr-comment-comment-id first)))
      (should (equal "PRRT_kwDOexample0000001" (prrr-comment-thread-id first)))
      (should (equal "PR_kwDOexample0000001" (prrr-comment-pr-id first)))
      (should (equal "example-bob" (prrr-comment-author first)))
      (should (equal "Should this be a `when'?" (prrr-comment-body first)))
      (should (equal "2026-09-02T10:00:00Z" (prrr-comment-created-at first)))
      (should (null (prrr-comment-updated-at first)))
      (should (null (prrr-comment-reply-to first)))
      (should (equal "PRR_kwDOexample0000001" (prrr-comment-review-id first)))
      (should (eq 'submitted (prrr-comment-state first)))
      (should (eq 'sent (prrr-comment-local-state first)))
      (should (null (prrr-comment-agent-p first)))
      (should (equal "PRRC_kwDOexample0000001" (prrr-comment-reply-to reply)))
      (should (equal "2026-09-02T11:05:00Z" (prrr-comment-updated-at reply)))
      (should (eq 'pending (prrr-comment-state pending)))
      (should (equal "PRR_kwDOexamplePending1" (prrr-comment-review-id pending))))))

(ert-deftest prrr-github-test-decode-review-data-pending-review ()
  (let ((pending (plist-get (prrr-github-test--review-data) :pending-review)))
    (should (prrr-pending-review-p pending))
    (should (equal "PR_kwDOexample0000001" (prrr-pending-review-pr-id pending)))
    (should (equal "PRR_kwDOexamplePending1" (prrr-pending-review-review-id pending)))
    (should (equal "1111111111111111111111111111111111111111"
                   (prrr-pending-review-commit-oid pending)))
    (should (equal "" (prrr-pending-review-body pending)))
    (should (equal "2026-09-04T09:00:00Z" (prrr-pending-review-created-at pending)))))

(ert-deftest prrr-github-test-decode-review-data-viewed ()
  (let ((viewed (plist-get (prrr-github-test--review-data) :viewed)))
    (should (equal '(("src/example.el" . viewed) ("README.md" . dismissed)
                     ("docs/notes.md" . unviewed))
                   (mapcar (lambda (v) (cons (prrr-viewed-path v) (prrr-viewed-state v)))
                           viewed)))
    (should (cl-every (lambda (v) (equal "PR_kwDOexample0000001" (prrr-viewed-pr-id v)))
                      viewed))
    (should (equal "2026-10-10T12:00:00Z" (prrr-viewed-fetched-at (car viewed))))))

(ert-deftest prrr-github-test-decode-review-data-head-oid ()
  (should (equal "1111111111111111111111111111111111111111"
                 (plist-get (prrr-github-test--review-data) :head-oid))))

(ert-deftest prrr-github-test-decode-review-data-without-pending-review ()
  (let ((result (prrr-github-decode-review-data
                 '(data (repository (pullRequest (id . "PR_1") (headRefOid . "abc")
                                                 (reviewThreads) (reviews) (files))))
                 "PR_1")))
    (should (null (plist-get result :threads)))
    (should (null (plist-get result :comments)))
    (should (null (plist-get result :pending-review)))
    (should (null (plist-get result :viewed)))
    (should (equal "abc" (plist-get result :head-oid)))))

(ert-deftest prrr-github-test-fetch-review-data-sends-variables-and-decodes ()
  (prrr-test-with-ghub-stub (prrr-test-fixture "review-data") captured
    (let (result)
      (prrr-github-fetch-review-data "api.github.com" "example-org" "example-repo" 1
                                     "example-me" (lambda (data) (setq result data)))
      (should (equal `(query ,prrr-github-review-data-query) (nth 0 captured)))
      (should (equal '((owner . "example-org") (name . "example-repo") (number . 1) (me . "example-me"))
                     (nth 1 captured)))
      (should (= 5 (length (plist-get result :threads))))
      (should (equal "PR_kwDOexample0000001"
                     (prrr-thread-pr-id (car (plist-get result :threads)))))
      (should (stringp (prrr-thread-fetched-at (car (plist-get result :threads))))))))
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `make test TESTS=test/prrr-github-test.el SELECTOR='"review-data"'`
Expected: 10 failures, `void-function prrr-github-decode-review-data`.

- [ ] **Step 4: Implement the query, decoder and request**

Add the query after the teams query's `eval-and-compile` block:

```elisp
(eval-and-compile
  (defconst prrr-github-review-data-query
    '(repository [(owner $owner String!) (name $name String!)]
       (pullRequest [(number $number Int!)]
         id headRefOid
         (reviewThreads [(:edges t)]
           id path line startLine diffSide startDiffSide originalLine
           isOutdated isResolved subjectType viewerCanResolve viewerCanUnresolve
           (comments [(:edges t)]
             id (author login) body createdAt lastEditedAt (replyTo id) state
             (pullRequestReview id) (originalCommit oid)))
         (reviews [(:edges t) (states . (PENDING)) (author $me String!)]
           id (commit oid) body createdAt)
         (files [(:edges t)] path viewerViewedState)))
    "Threads, the viewer's Pending Review, Viewed flags and head of one PR.
Variables: $owner, $name, $number and $me (the viewer's login).
The pending review's own comments are not selected: pending comments
appear in reviewThreads with state PENDING, which is where their side
comes from (research 03, section 2)."))
```

Add the decoder after `prrr-github-decode-teams`:

```elisp
;;;; Decoding per-PR review data

(defun prrr-github--side (side)
  "Translate a DiffSide string SIDE into `left', `right' or nil."
  (pcase side ("LEFT" 'left) ("RIGHT" 'right)))

(defun prrr-github--comment (node thread-id pr-id)
  "Decode a review comment NODE of THREAD-ID on PR-ID into a `prrr-comment'."
  (let-alist node
    (prrr-comment-create
     :comment-id .id
     :thread-id thread-id
     :pr-id pr-id
     :author .author.login
     :body .body
     :created-at .createdAt
     :updated-at .lastEditedAt
     :reply-to .replyTo.id
     :review-id .pullRequestReview.id
     :state (if (equal .state "PENDING") 'pending 'submitted)
     :local-state 'sent
     :agent-p nil)))

(defun prrr-github--thread (node pr-id fetched-at)
  "Decode a reviewThreads NODE of PR-ID into (THREAD . COMMENTS).
FETCHED-AT is stamped on the Thread."
  (let-alist node
    (cons (prrr-thread-create
           :thread-id .id
           :pr-id pr-id
           :path .path
           :line .line
           :start-line .startLine
           :side (prrr-github--side .diffSide)
           :start-side (prrr-github--side .startDiffSide)
           :subject-type (if (equal .subjectType "FILE") 'file 'line)
           :outdated-p (and .isOutdated t)
           :resolved-p (and .isResolved t)
           :original-line .originalLine
           :original-commit (let-alist (car .comments) .originalCommit.oid)
           :fetched-at fetched-at)
          (mapcar (lambda (comment) (prrr-github--comment comment .id pr-id))
                  .comments))))

(defun prrr-github--viewed-state (state)
  "Translate a FileViewedState string STATE into a `prrr-viewed' state."
  (pcase state
    ("VIEWED" 'viewed)
    ("DISMISSED" 'dismissed)
    (_ 'unviewed)))

(defun prrr-github-decode-review-data (data pr-id &optional fetched-at)
  "Decode per-PR review DATA of PR-ID into a plist.
Keys: :threads (list of `prrr-thread'), :comments (list of
`prrr-comment' in Thread order), :pending-review (`prrr-pending-review'
or nil), :viewed (list of `prrr-viewed'), :head-oid.  FETCHED-AT is
stamped on Threads and Viewed rows."
  (let-alist (cdr (assq 'repository data))
    (let ((decoded (mapcar (lambda (node) (prrr-github--thread node pr-id fetched-at))
                           (alist-get 'reviewThreads .pullRequest)))
          (pending (car (alist-get 'reviews .pullRequest))))
      (list :threads (mapcar #'car decoded)
            :comments (apply #'append (mapcar #'cdr decoded))
            :pending-review
            (and pending
                 (let-alist pending
                   (prrr-pending-review-create :pr-id pr-id
                                               :review-id .id
                                               :commit-oid .commit.oid
                                               :body .body
                                               :created-at .createdAt)))
            :viewed
            (mapcar (lambda (file)
                      (let-alist file
                        (prrr-viewed-create :pr-id pr-id
                                            :path .path
                                            :state (prrr-github--viewed-state .viewerViewedState)
                                            :fetched-at fetched-at)))
                    (alist-get 'files .pullRequest))
            :head-oid (alist-get 'headRefOid .pullRequest)))))
```

Add the request after `prrr-github-fetch-teams`:

```elisp
(defun prrr-github-fetch-review-data (host owner name number me callback)
  "Fetch Threads, Pending Review, Viewed flags and head of OWNER/NAME#NUMBER.
HOST is the API host; ME the viewer's login, used to find the Pending
Review.  CALLBACK receives the plist of `prrr-github-decode-review-data'
with rows stamped with the current time."
  (prrr-github--query host prrr-github-review-data-query
    ((owner owner) (name name) (number number) (me me))
    :callback (lambda (data &rest _)
                (let ((pr-id (alist-get 'id (alist-get 'pullRequest
                                                       (cdr (assq 'repository data))))))
                  (funcall callback
                           (prrr-github-decode-review-data data pr-id
                                                           (prrr-github--now)))))))
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `make compile lint && make test TESTS=test/prrr-github-test.el`
Expected: `Ran 21 tests, 21 results as expected`.

- [ ] **Step 6: Commit**

```bash
git add prrr-github.el test/prrr-github-test.el test/fixtures/github/review-data.eld
git commit -m "feat(github): per-PR review data query, decoder and fetch"
```

---

### Task 7: Fixture recording script

**Files:**
- Create: `scripts/record-fixtures.el`

**Interfaces:**
- Consumes: `prrr-github--query`, `prrr-github-queue-query`, `prrr-github-teams-query`, `prrr-github-review-data-query`.
- Produces: `test/fixtures/github/recorded/{queue,teams,review-data}.eld` (git-ignored since Task 1).

- [ ] **Step 1: Write the script**

```elisp
;;; record-fixtures.el --- Re-record GitHub fixtures from a real repository  -*- lexical-binding: t -*-

;; Copyright (C) 2026  Wesley Hargrove

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Records the raw callback data of the three foundation queries from a
;; real repository, so the committed fixtures can be refreshed when
;; GitHub's shape changes.  Never run in CI.
;;
;;   PRRR_FIXTURE_REPO=owner/name PRRR_FIXTURE_PR=12 PRRR_FIXTURE_USER=login \
;;   emacs -Q --batch --eval '(setq package-user-dir (expand-file-name ".deps"))' \
;;         --eval '(package-initialize)' -L . -l scripts/record-fixtures.el
;;
;; Authentication is forge's: the token for api.github.com must be in
;; your auth-source as the forge manual describes; without one, ghub's
;; own error is the output.  Results go to test/fixtures/github/recorded/,
;; which is git-ignored because it holds real logins.  Replace every name
;; with an `example' name before copying a file over the committed
;; fixture of the same name.

;;; Code:

(require 'cl-lib)
(require 'prrr-github)

(defconst record-fixtures--root
  (file-name-directory
   (directory-file-name (file-name-directory load-file-name)))
  "Root of the prrr checkout.")

(defvar record-fixtures--pending 3
  "Requests still in flight.")

(defun record-fixtures--save (name data)
  "Write DATA to recorded/NAME.eld and exit once every request is done."
  (let ((dir (expand-file-name "test/fixtures/github/recorded/" record-fixtures--root)))
    (make-directory dir t)
    (with-temp-file (expand-file-name (concat name ".eld") dir)
      (pp data (current-buffer)))
    (message "record-fixtures: wrote %s%s.eld" dir name)
    (when (zerop (cl-decf record-fixtures--pending))
      (kill-emacs 0))))

(let ((repo (getenv "PRRR_FIXTURE_REPO"))
      (number (getenv "PRRR_FIXTURE_PR"))
      (me (getenv "PRRR_FIXTURE_USER")))
  (unless (and repo number me)
    (message "record-fixtures: set PRRR_FIXTURE_REPO, PRRR_FIXTURE_PR and PRRR_FIXTURE_USER")
    (kill-emacs 2))
  (pcase-let ((`(,owner ,name) (split-string repo "/")))
    (prrr-github--query "api.github.com" prrr-github-queue-query
      ((owner owner) (name name))
      :callback (lambda (data &rest _) (record-fixtures--save "queue" data)))
    (prrr-github--query "api.github.com" prrr-github-teams-query
      ((me (vector me)))
      :callback (lambda (data &rest _) (record-fixtures--save "teams" data)))
    (prrr-github--query "api.github.com" prrr-github-review-data-query
      ((owner owner) (name name) (number (string-to-number number)) (me me))
      :callback (lambda (data &rest _) (record-fixtures--save "review-data" data)))
    (while t
      (accept-process-output nil 0.2))))

;;; record-fixtures.el ends here
```

If Task 5 chose form B, the teams call passes `nil` as its variables.

- [ ] **Step 2: Verify the script loads and refuses to run without its inputs**

Run: `emacs -Q --batch --eval '(setq package-user-dir (expand-file-name ".deps"))' --eval '(package-initialize)' -L . -l scripts/record-fixtures.el; echo "exit $?"`
Expected: the `set PRRR_FIXTURE_REPO ...` message and `exit 2`. Then `make compile lint` to confirm nothing regressed (the script is outside `SRC` and is not compiled or linted).

- [ ] **Step 3: Commit**

```bash
git add scripts/record-fixtures.el
git commit -m "chore: script to re-record GitHub fixtures from a real repository"
```

---

### Task 8: `prrr-state.el` structs and the For Me Review State

**Files:**
- Create: `prrr-state.el`, `test/prrr-state-test.el`
- Modify: `prrr.el` (add `(require 'prrr-state)`)

**Interfaces:**
- Consumes: `prrr-pr-meta` accessors from Task 2.
- Produces: `prrr-pr` struct (`prrr-pr-create`; slots `id number title author draft-p assignees created-at updated-at head-oid base-ref head-ref cross-repo-p`, `assignees` a list of logins); `prrr-queue-entry` struct (`prrr-queue-entry-create`; slots `pr state group partition stack-pos stack-size dimmed-p`); `prrr-state-for-me-order`; `(prrr-state-review-state PR META ME TEAMS) -> symbol or nil`; internals `(prrr-state--viewer-review META)`, `(prrr-state--requested-p META ME)`, `(prrr-state--team-requests META TEAMS)`, `(prrr-state--teammate-reviews META ME TEAMS)`. TEAMS is a list of combined-slug strings. META may be nil.

- [ ] **Step 1: Write the failing tests**

`test/prrr-state-test.el` (header as in Task 1, first line `;;; prrr-state-test.el --- Tests for prrr-state  -*- lexical-binding: t -*-`):

```elisp
;;; Commentary:

;; Every rule of SPEC.md section 5 has its own test built from
;; constructed structs; nothing here touches forge, a buffer or the
;; network.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'prrr-test-helper)
(require 'prrr-state)

(defconst prrr-state-test--me "example-me")
(defconst prrr-state-test--teams '("example-org/reviewers"))
(defconst prrr-state-test--head "1111111111111111111111111111111111111111")
(defconst prrr-state-test--old "0000000000000000000000000000000000000000")

(cl-defun prrr-state-test--pr (&key (id "PR_1") (number 1) (title "Example")
                                    (author "example-alice") draft-p assignees
                                    (created-at "2026-09-01T00:00:00Z")
                                    (updated-at "2026-09-05T00:00:00Z")
                                    (head-oid prrr-state-test--head)
                                    (base-ref "main") (head-ref "feature-1")
                                    cross-repo-p)
  "Build a `prrr-pr' with sensible defaults."
  (prrr-pr-create :id id :number number :title title :author author
                  :draft-p draft-p :assignees assignees :created-at created-at
                  :updated-at updated-at :head-oid head-oid :base-ref base-ref
                  :head-ref head-ref :cross-repo-p cross-repo-p))

(cl-defun prrr-state-test--meta (&key (pr-id "PR_1") (head-oid prrr-state-test--head)
                                      review-requests latest-reviews
                                      viewer-latest-review viewer-latest-review-request
                                      (created-at "2026-09-01T00:00:00Z"))
  "Build a `prrr-pr-meta' with sensible defaults."
  (prrr-pr-meta-create :pr-id pr-id :forge-repo-id "example-repo-id" :number 1
                       :head-oid head-oid :review-requests review-requests
                       :latest-reviews latest-reviews
                       :viewer-latest-review viewer-latest-review
                       :viewer-latest-review-request viewer-latest-review-request
                       :created-at created-at :fetched-at "2026-10-10T12:00:00Z"))

(defun prrr-state-test--state (pr meta)
  "Review State of PR with META for the test viewer and Teams."
  (prrr-state-review-state pr meta prrr-state-test--me prrr-state-test--teams))

;;;; Review State, For Me group (SPEC section 5, first match wins)

(ert-deftest prrr-state-test-review-state-new-commits ()
  "My latest submitted review is on a commit other than head."
  (should (eq 'new-commits
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--old))))))

(ert-deftest prrr-state-test-review-state-new-commits-beats-requested ()
  (should (eq 'new-commits
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :review-requests '((user "example-me"))
                :viewer-latest-review (list "COMMENTED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--old))))))

(ert-deftest prrr-state-test-review-state-new-commits-needs-a-commit ()
  "Review Focus 5: a review whose commit is gone (nil) is not new-commits."
  (should (eq 'approved
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :viewer-latest-review '("APPROVED" "2026-09-02T00:00:00Z" nil))))))

(ert-deftest prrr-state-test-review-state-requested-from-review-requests ()
  (should (eq 'requested
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta :review-requests '((user "example-me")))))))

(ert-deftest prrr-state-test-review-state-re-requested-after-my-review ()
  "A fresh request after my review at head wins over my old verdict."
  (should (eq 'requested
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :review-requests '((user "example-me"))
                :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--head))))))

(ert-deftest prrr-state-test-review-state-requested-from-viewer-request-without-review ()
  (should (eq 'requested
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta :viewer-latest-review-request "example-alice")))))

(ert-deftest prrr-state-test-review-state-old-viewer-request-does-not-outrank-my-review ()
  "viewerLatestReviewRequest is history once I reviewed and left reviewRequests."
  (should (eq 'approved
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :viewer-latest-review-request "example-alice"
                :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--head))))))

(ert-deftest prrr-state-test-review-state-team-requested ()
  (should (eq 'team-requested
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta :review-requests '((team "example-org/reviewers")))))))

(ert-deftest prrr-state-test-review-state-other-team-request-is-nothing ()
  (should (null (prrr-state-test--state
                 (prrr-state-test--pr)
                 (prrr-state-test--meta :review-requests '((team "example-org/platform")))))))

(ert-deftest prrr-state-test-review-state-teammate-reviewed ()
  "Someone else reviewed on behalf of one of my Teams."
  (should (eq 'teammate-reviewed
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :latest-reviews (list (list "example-bob" "APPROVED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--head
                                            '("example-org/reviewers"))))))))

(ert-deftest prrr-state-test-review-state-teammate-review-satisfies-team-request ()
  "A Team request still listed is served once a teammate reviewed for the Team."
  (should (eq 'teammate-reviewed
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :review-requests '((team "example-org/reviewers"))
                :latest-reviews (list (list "example-bob" "COMMENTED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--head
                                            '("example-org/reviewers"))))))))

(ert-deftest prrr-state-test-review-state-my-own-on-behalf-review-is-not-a-teammate ()
  (should (eq 'approved
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :latest-reviews (list (list "example-me" "APPROVED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--head
                                            '("example-org/reviewers")))
                :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--head))))))

(ert-deftest prrr-state-test-review-state-changes-requested ()
  (should (eq 'changes-requested
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :viewer-latest-review (list "CHANGES_REQUESTED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--head))))))

(ert-deftest prrr-state-test-review-state-approved ()
  (should (eq 'approved
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--head))))))

(ert-deftest prrr-state-test-review-state-commented ()
  (should (eq 'commented
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :viewer-latest-review (list "COMMENTED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--head))))))

(ert-deftest prrr-state-test-review-state-dismissed-counts-as-commented ()
  "A dismissed verdict is still a touch; it shows as commented."
  (should (eq 'commented
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :viewer-latest-review (list "DISMISSED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--head))))))

(ert-deftest prrr-state-test-review-state-pending-viewer-review-is-ignored ()
  "Review Focus 1: my unsubmitted Pending Review is not a touch."
  (should (null (prrr-state-test--state
                 (prrr-state-test--pr)
                 (prrr-state-test--meta
                  :viewer-latest-review (list "PENDING" nil prrr-state-test--old)))))
  (should (eq 'assigned
              (prrr-state-test--state
               (prrr-state-test--pr :assignees '("example-me"))
               (prrr-state-test--meta
                :viewer-latest-review (list "PENDING" nil prrr-state-test--old))))))

(ert-deftest prrr-state-test-review-state-assigned ()
  (should (eq 'assigned
              (prrr-state-test--state (prrr-state-test--pr :assignees '("example-bob" "example-me"))
                                      (prrr-state-test--meta)))))

(ert-deftest prrr-state-test-review-state-assigned-without-meta ()
  (should (eq 'assigned
              (prrr-state-test--state (prrr-state-test--pr :assignees '("example-me")) nil))))

(ert-deftest prrr-state-test-review-state-nothing ()
  (should (null (prrr-state-test--state (prrr-state-test--pr) (prrr-state-test--meta))))
  (should (null (prrr-state-test--state (prrr-state-test--pr) nil))))

(ert-deftest prrr-state-test-review-state-order-is-first-match ()
  "The states are tried in SPEC order."
  (should (equal '(new-commits requested team-requested teammate-reviewed
                   changes-requested approved commented assigned)
                 prrr-state-for-me-order)))

(provide 'prrr-state-test)
;;; prrr-state-test.el ends here
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test TESTS=test/prrr-state-test.el`
Expected: `Cannot open load file: prrr-state`.

- [ ] **Step 3: Write `prrr-state.el`**

First line `;;; prrr-state.el --- Pure Review Queue rules for prrr  -*- lexical-binding: t -*-`, license block, then:

```elisp
;;; Commentary:

;; Pure functions implementing SPEC.md section 5: the Review State of a
;; PR for the viewer, Queue Group membership, the Awaiting me / Served
;; partitions and their FIFO ordering, Stack detection, and the final
;; ordered Review Queue.  Inputs are `prrr-pr' (built by the caller from
;; forge's object) and `prrr-pr-meta' rows; there is no buffer, network
;; or forge-object access, so every rule is unit-tested with constructed
;; structs.
;;
;; Line mapping across Ranges is milestone 5 and is not here yet.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'prrr-db)

;;;; Structs

(cl-defstruct (prrr-pr (:constructor prrr-pr-create) (:copier nil))
  "A Pull Request as the Review Queue sees it.
ID is the GitHub node id (forge's `their-id'), which joins to
`prrr-pr-meta-pr-id'.  ASSIGNEES is a list of logins.  BASE-REF and
HEAD-REF are branch names, nil when the branch is gone.  CROSS-REPO-P
is non-nil for a PR from a fork."
  id number title author draft-p assignees created-at updated-at
  head-oid base-ref head-ref cross-repo-p)

(cl-defstruct (prrr-queue-entry (:constructor prrr-queue-entry-create)
                                (:copier nil))
  "One row of the Review Queue.
PR is the `prrr-pr'.  STATE is the Review State (For Me) or Mine state,
nil for a dimmed context row.  GROUP is `for-me' or `mine'.  PARTITION
is `awaiting' or `served' in For Me, nil in Mine.  STACK-POS is the
1-based position of PR in its Stack, bottom first, and STACK-SIZE the
Stack's length (1 for a lone PR).  DIMMED-P marks a row shown only for
context: a non-qualifying Stack member or a draft requested from me."
  pr state group partition stack-pos stack-size dimmed-p)

;;;; Helpers over meta rows

(defun prrr-state--viewer-review (meta)
  "Return META's viewer-latest-review unless it is nil or still pending.
A Pending Review is not a touch, so it is ignored everywhere."
  (let ((review (and meta (prrr-pr-meta-viewer-latest-review meta))))
    (and review (not (equal (nth 0 review) "PENDING")) review)))

(defun prrr-state--requested-p (meta me)
  "Non-nil when META shows a current review request for ME.
Either ME is in the current review requests (GitHub removes a request
once it is answered, so this means an unanswered or renewed request),
or someone requested ME and ME has not reviewed yet."
  (and meta
       (or (member (list 'user me) (prrr-pr-meta-review-requests meta))
           (and (prrr-pr-meta-viewer-latest-review-request meta)
                (null (prrr-state--viewer-review meta))))
       t))

(defun prrr-state--team-requests (meta teams)
  "Return the combined slugs of TEAMS that are requested on META."
  (cl-loop for (kind name) in (and meta (prrr-pr-meta-review-requests meta))
           when (and (eq kind 'team) (member name teams))
           collect name))

(defun prrr-state--teammate-reviews (meta me teams)
  "Return META's latest reviews by others than ME on behalf of one of TEAMS."
  (cl-loop for review in (and meta (prrr-pr-meta-latest-reviews meta))
           for (login _state _submitted-at _commit-oid slugs) = review
           when (and (not (equal login me))
                     (cl-intersection slugs teams :test #'equal))
           collect review))

;;;; Review State

(defconst prrr-state-for-me-order
  '(new-commits requested team-requested teammate-reviewed
    changes-requested approved commented assigned)
  "Review States of the For Me group in the order they are tried.")

(defun prrr-state-review-state (pr meta me teams)
  "Return the Review State of PR for the viewer ME, or nil.
META is PR's `prrr-pr-meta' or nil; TEAMS the viewer's Team slugs.
First match wins, in the order of `prrr-state-for-me-order'."
  (let ((review (prrr-state--viewer-review meta)))
    (cond
     ((and review (nth 2 review)
           (not (equal (nth 2 review) (prrr-pr-head-oid pr))))
      'new-commits)
     ((prrr-state--requested-p meta me)
      'requested)
     ((and (prrr-state--team-requests meta teams)
           (null (prrr-state--teammate-reviews meta me teams)))
      'team-requested)
     ((prrr-state--teammate-reviews meta me teams)
      'teammate-reviewed)
     ((and review (equal (nth 0 review) "CHANGES_REQUESTED"))
      'changes-requested)
     ((and review (equal (nth 0 review) "APPROVED"))
      'approved)
     (review                            ; COMMENTED or DISMISSED
      'commented)
     ((member me (prrr-pr-assignees pr))
      'assigned))))

(provide 'prrr-state)
;;; prrr-state.el ends here
```

Add `(require 'prrr-state)` to `prrr.el` after `(require 'prrr-github)`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make compile lint && make test TESTS=test/prrr-state-test.el`
Expected: `Ran 22 tests, 22 results as expected`.

- [ ] **Step 5: Commit**

```bash
git add prrr-state.el prrr.el test/prrr-state-test.el
git commit -m "feat(state): prrr-pr and queue-entry structs; For Me Review State"
```

---

### Task 9: Mine state, For Me membership and partition

**Files:**
- Modify: `prrr-state.el` (insert before `(provide 'prrr-state)`), `test/prrr-state-test.el`

**Interfaces:**
- Consumes: Task 8 helpers.
- Produces: `prrr-state-mine-order`; `(prrr-state-mine-state PR META ME) -> draft | awaiting-review | changes-requested | approved | reviewed`; `(prrr-state-for-me-p PR META ME TEAMS)`; `(prrr-state--direct-p PR META ME)`; `(prrr-state-partition PR STATE) -> awaiting | served`.

- [ ] **Step 1: Write the failing tests**

Insert before `(provide 'prrr-state-test)`:

```elisp
;;;; Mine state

(defun prrr-state-test--mine (pr meta)
  "Mine state of PR with META for the test viewer."
  (prrr-state-mine-state pr meta prrr-state-test--me))

(ert-deftest prrr-state-test-mine-state-draft ()
  (should (eq 'draft (prrr-state-test--mine
                      (prrr-state-test--pr :author "example-me" :draft-p t)
                      (prrr-state-test--meta
                       :latest-reviews '(("example-carol" "CHANGES_REQUESTED"
                                          "2026-09-02T00:00:00Z" "abc" nil)))))))

(ert-deftest prrr-state-test-mine-state-awaiting-review ()
  (should (eq 'awaiting-review
              (prrr-state-test--mine (prrr-state-test--pr :author "example-me")
                                     (prrr-state-test--meta))))
  (should (eq 'awaiting-review
              (prrr-state-test--mine (prrr-state-test--pr :author "example-me") nil))))

(ert-deftest prrr-state-test-mine-state-changes-requested-beats-approved ()
  (should (eq 'changes-requested
              (prrr-state-test--mine
               (prrr-state-test--pr :author "example-me")
               (prrr-state-test--meta
                :latest-reviews '(("example-dave" "APPROVED" "2026-09-02T00:00:00Z" "abc" nil)
                                  ("example-carol" "CHANGES_REQUESTED" "2026-09-03T00:00:00Z" "abc" nil)))))))

(ert-deftest prrr-state-test-mine-state-approved-beats-commented ()
  (should (eq 'approved
              (prrr-state-test--mine
               (prrr-state-test--pr :author "example-me")
               (prrr-state-test--meta
                :latest-reviews '(("example-dave" "COMMENTED" "2026-09-02T00:00:00Z" "abc" nil)
                                  ("example-carol" "APPROVED" "2026-09-03T00:00:00Z" "abc" nil)))))))

(ert-deftest prrr-state-test-mine-state-reviewed ()
  "COMMENTED and DISMISSED reviews by others mean reviewed."
  (should (eq 'reviewed
              (prrr-state-test--mine
               (prrr-state-test--pr :author "example-me")
               (prrr-state-test--meta
                :latest-reviews '(("example-dave" "COMMENTED" "2026-09-02T00:00:00Z" "abc" nil))))))
  (should (eq 'reviewed
              (prrr-state-test--mine
               (prrr-state-test--pr :author "example-me")
               (prrr-state-test--meta
                :latest-reviews '(("example-dave" "DISMISSED" "2026-09-02T00:00:00Z" nil nil)))))))

(ert-deftest prrr-state-test-mine-state-ignores-my-own-review ()
  (should (eq 'awaiting-review
              (prrr-state-test--mine
               (prrr-state-test--pr :author "example-me")
               (prrr-state-test--meta
                :latest-reviews '(("example-me" "APPROVED" "2026-09-02T00:00:00Z" "abc" nil)))))))

(ert-deftest prrr-state-test-mine-state-deleted-reviewer ()
  "Review Focus 2: a review with a nil login counts as someone else's."
  (should (eq 'changes-requested
              (prrr-state-test--mine
               (prrr-state-test--pr :author "example-me")
               (prrr-state-test--meta
                :latest-reviews '((nil "CHANGES_REQUESTED" "2026-09-02T00:00:00Z" nil nil)))))))

(ert-deftest prrr-state-test-mine-order ()
  (should (equal '(changes-requested awaiting-review approved reviewed draft)
                 prrr-state-mine-order)))

;;;; For Me membership

(defun prrr-state-test--for-me-p (pr meta)
  "Whether PR with META is in For Me for the test viewer."
  (prrr-state-for-me-p pr meta prrr-state-test--me prrr-state-test--teams))

(ert-deftest prrr-state-test-for-me-p-requested ()
  (should (prrr-state-test--for-me-p (prrr-state-test--pr)
                                     (prrr-state-test--meta :review-requests '((user "example-me"))))))

(ert-deftest prrr-state-test-for-me-p-team-requested ()
  (should (prrr-state-test--for-me-p (prrr-state-test--pr)
                                     (prrr-state-test--meta :review-requests '((team "example-org/reviewers"))))))

(ert-deftest prrr-state-test-for-me-p-teammate-reviewed ()
  (should (prrr-state-test--for-me-p
           (prrr-state-test--pr)
           (prrr-state-test--meta
            :latest-reviews (list (list "example-bob" "APPROVED" "2026-09-02T00:00:00Z"
                                        prrr-state-test--head '("example-org/reviewers")))))))

(ert-deftest prrr-state-test-for-me-p-assigned ()
  (should (prrr-state-test--for-me-p (prrr-state-test--pr :assignees '("example-me")) nil)))

(ert-deftest prrr-state-test-for-me-p-ever-reviewed-by-me ()
  (should (prrr-state-test--for-me-p
           (prrr-state-test--pr)
           (prrr-state-test--meta
            :viewer-latest-review (list "COMMENTED" "2026-09-02T00:00:00Z" prrr-state-test--head)))))

(ert-deftest prrr-state-test-for-me-p-nothing ()
  (should-not (prrr-state-test--for-me-p (prrr-state-test--pr) (prrr-state-test--meta)))
  (should-not (prrr-state-test--for-me-p (prrr-state-test--pr) nil)))

(ert-deftest prrr-state-test-for-me-p-never-my-own-pr ()
  (should-not (prrr-state-test--for-me-p
               (prrr-state-test--pr :author "example-me" :assignees '("example-me"))
               (prrr-state-test--meta :review-requests '((user "example-me"))))))

(ert-deftest prrr-state-test-for-me-p-draft-excluded-unless-direct ()
  "Drafts are out even when team-requested or reviewed by me ..."
  (should-not (prrr-state-test--for-me-p
               (prrr-state-test--pr :draft-p t)
               (prrr-state-test--meta :review-requests '((team "example-org/reviewers")))))
  (should-not (prrr-state-test--for-me-p
               (prrr-state-test--pr :draft-p t)
               (prrr-state-test--meta
                :viewer-latest-review (list "COMMENTED" "2026-09-02T00:00:00Z" prrr-state-test--head))))
  ;; ... but in when requested directly from me or assigned to me.
  (should (prrr-state-test--for-me-p
           (prrr-state-test--pr :draft-p t)
           (prrr-state-test--meta :review-requests '((user "example-me")))))
  (should (prrr-state-test--for-me-p (prrr-state-test--pr :draft-p t :assignees '("example-me"))
                                     nil)))

;;;; Partition

(ert-deftest prrr-state-test-partition-awaiting-states ()
  (dolist (state '(new-commits requested team-requested assigned))
    (should (eq 'awaiting (prrr-state-partition (prrr-state-test--pr) state)))))

(ert-deftest prrr-state-test-partition-served-states ()
  (dolist (state '(teammate-reviewed changes-requested approved commented))
    (should (eq 'served (prrr-state-partition (prrr-state-test--pr) state)))))

(ert-deftest prrr-state-test-partition-draft-is-always-served ()
  "A draft requested from me stays out of Awaiting me until marked ready."
  (should (eq 'served (prrr-state-partition (prrr-state-test--pr :draft-p t) 'requested)))
  (should (eq 'served (prrr-state-partition (prrr-state-test--pr :draft-p t) 'assigned))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test TESTS=test/prrr-state-test.el SELECTOR='"mine\\|for-me-p\\|partition"'`
Expected: failures with `void-function prrr-state-mine-state` and friends.

- [ ] **Step 3: Implement**

Insert before `(provide 'prrr-state)`:

```elisp
;;;; Mine state

(defconst prrr-state-mine-order
  '(changes-requested awaiting-review approved reviewed draft)
  "Mine states in display order: the first needs my action most.")

(defun prrr-state-mine-state (pr meta me)
  "Return the Mine state of PR authored by ME, given META (or nil).
Other people's latest reviews decide it: CHANGES_REQUESTED beats
APPROVED beats any other review; no review is `awaiting-review'; a
draft is `draft' whatever the reviews say."
  (if (prrr-pr-draft-p pr)
      'draft
    (let ((states (cl-loop for (login state) in (and meta (prrr-pr-meta-latest-reviews meta))
                           unless (equal login me)
                           collect state)))
      (cond ((member "CHANGES_REQUESTED" states) 'changes-requested)
            ((member "APPROVED" states) 'approved)
            (states 'reviewed)
            (t 'awaiting-review)))))

;;;; Membership and partition

(defun prrr-state--direct-p (pr meta me)
  "Non-nil when PR is requested directly from ME or assigned to ME."
  (or (prrr-state--requested-p meta me)
      (and (member me (prrr-pr-assignees pr)) t)))

(defun prrr-state-for-me-p (pr meta me teams)
  "Non-nil when PR belongs in the For Me group for ME with TEAMS.
PR must not be authored by ME and must have a Review State.  A draft
is in only when requested directly from ME or assigned to ME."
  (and (not (equal (prrr-pr-author pr) me))
       (prrr-state-review-state pr meta me teams)
       (or (not (prrr-pr-draft-p pr))
           (prrr-state--direct-p pr meta me))
       t))

(defun prrr-state-partition (pr state)
  "Return `awaiting' or `served' for PR in Review State STATE.
Awaiting me holds new-commits, requested, team-requested and assigned
\(assigned implies no review of mine, since any review matches an
earlier state).  Drafts are always Served."
  (if (and (memq state '(new-commits requested team-requested assigned))
           (not (prrr-pr-draft-p pr)))
      'awaiting
    'served))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make compile lint && make test TESTS=test/prrr-state-test.el`
Expected: `Ran 40 tests, 40 results as expected`.

- [ ] **Step 5: Commit**

```bash
git add prrr-state.el test/prrr-state-test.el
git commit -m "feat(state): Mine state, For Me membership and partition rules"
```

---

### Task 10: Stack detection

**Files:**
- Modify: `prrr-state.el` (insert before `(provide 'prrr-state)`), `test/prrr-state-test.el`

**Interfaces:**
- Consumes: `prrr-pr` accessors.
- Produces: `(prrr-state-stacks PRS DEFAULT-BRANCH) -> list of Stacks`, each Stack a list of `prrr-pr` bottom-first; every PR in PRS appears in exactly one Stack; `(prrr-state--parent PR PRS DEFAULT-BRANCH) -> prrr-pr or nil`.

- [ ] **Step 1: Write the failing tests**

Insert before `(provide 'prrr-state-test)`:

```elisp
;;;; Stacks

(defun prrr-state-test--ids (stacks)
  "Ids of STACKS, a list of lists of `prrr-pr'."
  (mapcar (lambda (stack) (mapcar #'prrr-pr-id stack)) stacks))

(ert-deftest prrr-state-test-stacks-chain-bottom-first ()
  "A chain is one Stack, bottom first, whatever the input order."
  (let ((bottom (prrr-state-test--pr :id "B" :base-ref "main" :head-ref "step-1"))
        (middle (prrr-state-test--pr :id "M" :base-ref "step-1" :head-ref "step-2"))
        (top (prrr-state-test--pr :id "T" :base-ref "step-2" :head-ref "step-3")))
    (should (equal '(("B" "M" "T"))
                   (prrr-state-test--ids (prrr-state-stacks (list top bottom middle) "main"))))
    (should (equal '(("B" "M" "T"))
                   (prrr-state-test--ids (prrr-state-stacks (list bottom middle top) "main"))))))

(ert-deftest prrr-state-test-stacks-independent-prs-are-singletons ()
  (let ((a (prrr-state-test--pr :id "A" :head-ref "a"))
        (b (prrr-state-test--pr :id "B" :head-ref "b")))
    (should (equal '(("A") ("B")) (prrr-state-test--ids (prrr-state-stacks (list a b) "main"))))))

(ert-deftest prrr-state-test-stacks-parent-must-be-open ()
  "A PR whose parent was merged (absent from PRS) is a bottom on its own."
  (let ((orphan (prrr-state-test--pr :id "O" :base-ref "merged-branch" :head-ref "o")))
    (should (equal '(("O")) (prrr-state-test--ids (prrr-state-stacks (list orphan) "main"))))))

(ert-deftest prrr-state-test-stacks-cross-repo-parent-is-not-a-parent ()
  "Review Focus 3: a fork PR's head is not a base for anyone."
  (let ((fork (prrr-state-test--pr :id "F" :base-ref "main" :head-ref "feature" :cross-repo-p t))
        (child (prrr-state-test--pr :id "C" :base-ref "feature" :head-ref "child")))
    (should (equal '(("F") ("C")) (prrr-state-test--ids (prrr-state-stacks (list fork child) "main"))))))

(ert-deftest prrr-state-test-stacks-deleted-branches ()
  "Review Focus 3: nil refs never match."
  (let ((no-head (prrr-state-test--pr :id "H" :base-ref "main" :head-ref nil))
        (no-base (prrr-state-test--pr :id "N" :base-ref nil :head-ref "n"))
        (child (prrr-state-test--pr :id "C" :base-ref "n" :head-ref "c")))
    (should (equal '(("H") ("N" "C"))
                   (prrr-state-test--ids (prrr-state-stacks (list no-head no-base child) "main"))))))

(ert-deftest prrr-state-test-stacks-cycle-terminates ()
  "Review Focus 3: two PRs based on each other form one Stack, once."
  (let ((a (prrr-state-test--pr :id "A" :base-ref "b" :head-ref "a"))
        (b (prrr-state-test--pr :id "B" :base-ref "a" :head-ref "b")))
    (let ((stacks (prrr-state-stacks (list a b) "main")))
      (should (= 1 (length stacks)))
      (should (equal '("A" "B") (sort (mapcar #'prrr-pr-id (car stacks)) #'string<))))))

(ert-deftest prrr-state-test-stacks-branching-stack-keeps-siblings-after-parent ()
  "Two PRs on the same parent stay in the parent's Stack, depth first."
  (let ((bottom (prrr-state-test--pr :id "B" :base-ref "main" :head-ref "base"))
        (left (prrr-state-test--pr :id "L" :base-ref "base" :head-ref "left"))
        (left-top (prrr-state-test--pr :id "LT" :base-ref "left" :head-ref "left-top"))
        (right (prrr-state-test--pr :id "R" :base-ref "base" :head-ref "right")))
    (should (equal '(("B" "L" "LT" "R"))
                   (prrr-state-test--ids
                    (prrr-state-stacks (list bottom left left-top right) "main"))))))

(ert-deftest prrr-state-test-stacks-default-branch-is-never-a-parent ()
  "A PR based on the default branch is a bottom even if some PR's head has that name."
  (let ((odd (prrr-state-test--pr :id "O" :base-ref "develop" :head-ref "main"))
        (normal (prrr-state-test--pr :id "N" :base-ref "main" :head-ref "n")))
    (should (equal '(("O") ("N")) (prrr-state-test--ids (prrr-state-stacks (list odd normal) "main"))))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test TESTS=test/prrr-state-test.el SELECTOR='"stacks"'`
Expected: 8 failures, `void-function prrr-state-stacks`.

- [ ] **Step 3: Implement**

Insert before `(provide 'prrr-state)`:

```elisp
;;;; Stacks

(defun prrr-state--parent (pr prs default-branch)
  "Return the PR in PRS that PR is stacked on, or nil.
The parent is the PR whose `head-ref' equals PR's `base-ref' and that
is not from a fork.  A PR based on DEFAULT-BRANCH, or on a branch no
open PR has as its head, has no parent."
  (let ((base (prrr-pr-base-ref pr)))
    (and base
         (not (equal base default-branch))
         (seq-find (lambda (candidate)
                     (and (not (eq candidate pr))
                          (not (prrr-pr-cross-repo-p candidate))
                          (equal (prrr-pr-head-ref candidate) base)))
                   prs))))

(defun prrr-state--descend (pr parents seen)
  "Return PR followed by its descendants in PARENTS, depth first.
PARENTS is an alist (CHILD . PARENT); SEEN a hash table of visited PRs,
which stops cycles."
  (puthash pr t seen)
  (cons pr
        (cl-mapcan (lambda (child) (prrr-state--descend child parents seen))
                   (cl-loop for (child . parent) in parents
                            when (and (eq parent pr) (not (gethash child seen)))
                            collect child))))

(defun prrr-state-stacks (prs default-branch)
  "Group PRS, the open PRs of one repository, into Stacks.
Return a list of Stacks in the order their bottoms appear in PRS; each
Stack is a list of `prrr-pr' from the bottom (based on DEFAULT-BRANCH
or on no open PR) upwards, depth first when a PR has several children.
Every PR appears exactly once; a cycle is broken at the PR met first."
  (let ((parents (mapcar (lambda (pr) (cons pr (prrr-state--parent pr prs default-branch)))
                         prs))
        (seen (make-hash-table :test #'eq))
        (stacks nil))
    (dolist (pr prs)
      (unless (gethash pr seen)
        (let ((bottom pr) (walked (list pr)))
          (while-let ((parent (alist-get bottom parents))
                      ((not (memq parent walked)))
                      ((not (gethash parent seen))))
            (push parent walked)
            (setq bottom parent))
          (push (prrr-state--descend bottom parents seen) stacks))))
    (nreverse stacks)))
```

`alist-get` finds the struct because the alist's keys are the struct objects themselves and its default test is `eq`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make compile lint && make test TESTS=test/prrr-state-test.el`
Expected: `Ran 48 tests, 48 results as expected`.

- [ ] **Step 5: Commit**

```bash
git add prrr-state.el test/prrr-state-test.el
git commit -m "feat(state): Stack detection with fork, deleted-branch and cycle guards"
```

---

### Task 11: Queue assembly and FIFO ordering

**Files:**
- Modify: `prrr-state.el` (insert before `(provide 'prrr-state)`), `test/prrr-state-test.el`

**Interfaces:**
- Consumes: everything above.
- Produces: `(prrr-state-queue PRS METAS ME TEAMS DEFAULT-BRANCH) -> (:for-me ENTRIES :mine ENTRIES)`, ENTRIES ordered lists of `prrr-queue-entry`; `(prrr-state--touched-at PR META) -> string`; `(prrr-state--mine-rank STATE) -> integer`.

Ordering rules encoded (SPEC section 5): For Me lists Awaiting me (sorted by `created-at` ascending) before Served (sorted by my latest review's `submittedAt`, falling back to the PR's `updated-at`, ascending). Mine sorts by `prrr-state-mine-order` rank, then `created-at` ascending within a rank. A Stack with any qualifying member is emitted whole, bottom-first, at the position of its best member; members that do not qualify are dimmed with `state` nil; a PR authored by me is never emitted in For Me.

- [ ] **Step 1: Write the failing tests**

Insert before `(provide 'prrr-state-test)`:

```elisp
;;;; Queue assembly

(defun prrr-state-test--queue (prs metas)
  "Build the queue of PRS and METAS for the test viewer."
  (prrr-state-queue prs metas prrr-state-test--me prrr-state-test--teams "main"))

(defun prrr-state-test--rows (entries)
  "Summarise ENTRIES as (ID STATE PARTITION DIMMED-P STACK-POS STACK-SIZE)."
  (mapcar (lambda (e) (list (prrr-pr-id (prrr-queue-entry-pr e))
                            (prrr-queue-entry-state e)
                            (prrr-queue-entry-partition e)
                            (prrr-queue-entry-dimmed-p e)
                            (prrr-queue-entry-stack-pos e)
                            (prrr-queue-entry-stack-size e)))
          entries))

(ert-deftest prrr-state-test-queue-awaiting-sorted-by-created-at ()
  (let ((prs (list (prrr-state-test--pr :id "A" :head-ref "a" :created-at "2026-09-03T00:00:00Z")
                   (prrr-state-test--pr :id "B" :head-ref "b" :created-at "2026-09-01T00:00:00Z")
                   (prrr-state-test--pr :id "C" :head-ref "c" :created-at "2026-09-02T00:00:00Z")))
        (metas (list (prrr-state-test--meta :pr-id "A" :review-requests '((user "example-me")))
                     (prrr-state-test--meta :pr-id "B" :review-requests '((team "example-org/reviewers")))
                     (prrr-state-test--meta :pr-id "C" :viewer-latest-review
                                            (list "APPROVED" "2026-09-02T12:00:00Z" prrr-state-test--old)))))
    (should (equal '(("B" team-requested awaiting nil 1 1)
                     ("C" new-commits awaiting nil 1 1)
                     ("A" requested awaiting nil 1 1))
                   (prrr-state-test--rows (plist-get (prrr-state-test--queue prs metas) :for-me))))))

(ert-deftest prrr-state-test-queue-served-after-awaiting-sorted-by-touch ()
  "Served sorts by my last review time; teammate-reviewed falls back to updated-at."
  (let ((prs (list (prrr-state-test--pr :id "S1" :head-ref "s1" :created-at "2026-09-01T00:00:00Z"
                                        :updated-at "2026-09-09T00:00:00Z")
                   (prrr-state-test--pr :id "S2" :head-ref "s2" :created-at "2026-09-02T00:00:00Z")
                   (prrr-state-test--pr :id "S3" :head-ref "s3" :created-at "2026-09-03T00:00:00Z")
                   (prrr-state-test--pr :id "W" :head-ref "w" :created-at "2026-09-08T00:00:00Z")))
        (metas (list (prrr-state-test--meta
                      :pr-id "S1"
                      :latest-reviews (list (list "example-bob" "APPROVED" "2026-09-04T00:00:00Z"
                                                  prrr-state-test--head '("example-org/reviewers"))))
                     (prrr-state-test--meta
                      :pr-id "S2"
                      :viewer-latest-review (list "COMMENTED" "2026-09-07T00:00:00Z" prrr-state-test--head))
                     (prrr-state-test--meta
                      :pr-id "S3"
                      :viewer-latest-review (list "APPROVED" "2026-09-06T00:00:00Z" prrr-state-test--head))
                     (prrr-state-test--meta :pr-id "W" :review-requests '((user "example-me"))))))
    (should (equal '(("W" requested awaiting nil 1 1)
                     ("S3" approved served nil 1 1)
                     ("S2" commented served nil 1 1)
                     ("S1" teammate-reviewed served nil 1 1))
                   (prrr-state-test--rows (plist-get (prrr-state-test--queue prs metas) :for-me))))))

(ert-deftest prrr-state-test-queue-mine-sorted-by-rank-then-created-at ()
  (let ((prs (list (prrr-state-test--pr :id "D" :author "example-me" :head-ref "d" :draft-p t
                                        :created-at "2026-09-01T00:00:00Z")
                   (prrr-state-test--pr :id "A2" :author "example-me" :head-ref "a2"
                                        :created-at "2026-09-04T00:00:00Z")
                   (prrr-state-test--pr :id "CR" :author "example-me" :head-ref "cr"
                                        :created-at "2026-09-05T00:00:00Z")
                   (prrr-state-test--pr :id "A1" :author "example-me" :head-ref "a1"
                                        :created-at "2026-09-02T00:00:00Z")
                   (prrr-state-test--pr :id "OK" :author "example-me" :head-ref "ok"
                                        :created-at "2026-09-03T00:00:00Z")
                   (prrr-state-test--pr :id "RV" :author "example-me" :head-ref "rv"
                                        :created-at "2026-09-01T00:00:00Z")))
        (metas (list (prrr-state-test--meta
                      :pr-id "CR" :latest-reviews '(("example-carol" "CHANGES_REQUESTED" "t" "abc" nil)))
                     (prrr-state-test--meta
                      :pr-id "OK" :latest-reviews '(("example-carol" "APPROVED" "t" "abc" nil)))
                     (prrr-state-test--meta
                      :pr-id "RV" :latest-reviews '(("example-carol" "COMMENTED" "t" "abc" nil))))))
    (should (equal '(("CR" changes-requested nil nil 1 1)
                     ("A1" awaiting-review nil nil 1 1)
                     ("A2" awaiting-review nil nil 1 1)
                     ("OK" approved nil nil 1 1)
                     ("RV" reviewed nil nil 1 1)
                     ("D" draft nil nil 1 1))
                   (prrr-state-test--rows (plist-get (prrr-state-test--queue prs metas) :mine))))))

(ert-deftest prrr-state-test-queue-my-pr-never-in-for-me ()
  (let ((prs (list (prrr-state-test--pr :id "M" :author "example-me" :assignees '("example-me"))))
        (metas (list (prrr-state-test--meta :pr-id "M" :review-requests '((user "example-me"))))))
    (let ((queue (prrr-state-test--queue prs metas)))
      (should (null (plist-get queue :for-me)))
      (should (equal '(("M" awaiting-review nil nil 1 1))
                     (prrr-state-test--rows (plist-get queue :mine)))))))

(ert-deftest prrr-state-test-queue-draft-requested-is-dimmed-and-served ()
  (let ((prs (list (prrr-state-test--pr :id "D" :draft-p t)))
        (metas (list (prrr-state-test--meta :pr-id "D" :review-requests '((user "example-me"))))))
    (should (equal '(("D" requested served t 1 1))
                   (prrr-state-test--rows (plist-get (prrr-state-test--queue prs metas) :for-me))))))

(ert-deftest prrr-state-test-queue-unlisted-prs-are-absent ()
  (let ((prs (list (prrr-state-test--pr :id "X")))
        (metas (list (prrr-state-test--meta :pr-id "X"))))
    (let ((queue (prrr-state-test--queue prs metas)))
      (should (null (plist-get queue :for-me)))
      (should (null (plist-get queue :mine))))))

(ert-deftest prrr-state-test-queue-stack-stays-together-sorted-by-best-member ()
  "A Stack sits where its best member would, whole, with others dimmed."
  (let ((prs (list (prrr-state-test--pr :id "LONE" :head-ref "lone" :created-at "2026-09-02T00:00:00Z")
                   (prrr-state-test--pr :id "BOTTOM" :head-ref "step-1" :created-at "2026-09-03T00:00:00Z")
                   (prrr-state-test--pr :id "TOP" :base-ref "step-1" :head-ref "step-2"
                                        :created-at "2026-09-01T00:00:00Z")))
        (metas (list (prrr-state-test--meta :pr-id "LONE" :review-requests '((user "example-me")))
                     (prrr-state-test--meta :pr-id "BOTTOM")
                     (prrr-state-test--meta :pr-id "TOP" :review-requests '((user "example-me"))))))
    (should (equal '(("BOTTOM" nil nil t 1 2)
                     ("TOP" requested awaiting nil 2 2)
                     ("LONE" requested awaiting nil 1 1))
                   (prrr-state-test--rows (plist-get (prrr-state-test--queue prs metas) :for-me))))))

(ert-deftest prrr-state-test-queue-stack-in-for-me-omits-my-own-member ()
  (let ((prs (list (prrr-state-test--pr :id "MINE" :author "example-me" :head-ref "step-1")
                   (prrr-state-test--pr :id "THEIRS" :base-ref "step-1" :head-ref "step-2")))
        (metas (list (prrr-state-test--meta :pr-id "MINE")
                     (prrr-state-test--meta :pr-id "THEIRS" :review-requests '((user "example-me"))))))
    (let ((queue (prrr-state-test--queue prs metas)))
      (should (equal '(("THEIRS" requested awaiting nil 2 2))
                     (prrr-state-test--rows (plist-get queue :for-me))))
      (should (equal '(("MINE" awaiting-review nil nil 1 2)
                       ("THEIRS" nil nil t 2 2))
                     (prrr-state-test--rows (plist-get queue :mine)))))))

(ert-deftest prrr-state-test-queue-stack-with-awaiting-member-sorts-before-served ()
  (let ((prs (list (prrr-state-test--pr :id "S" :head-ref "s" :created-at "2026-09-01T00:00:00Z")
                   (prrr-state-test--pr :id "B" :head-ref "b1" :created-at "2026-09-05T00:00:00Z")
                   (prrr-state-test--pr :id "T" :base-ref "b1" :head-ref "b2"
                                        :created-at "2026-09-06T00:00:00Z")))
        (metas (list (prrr-state-test--meta
                      :pr-id "S"
                      :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z" prrr-state-test--head))
                     (prrr-state-test--meta
                      :pr-id "B"
                      :viewer-latest-review (list "APPROVED" "2026-09-07T00:00:00Z" prrr-state-test--head))
                     (prrr-state-test--meta :pr-id "T" :review-requests '((user "example-me"))))))
    (should (equal '("B" "T" "S")
                   (mapcar #'car (prrr-state-test--rows
                                  (plist-get (prrr-state-test--queue prs metas) :for-me)))))))

(ert-deftest prrr-state-test-queue-missing-meta-and-timestamps-do-not-signal ()
  "A PR without a meta row or timestamps still lists when assigned."
  (let ((prs (list (prrr-state-test--pr :id "A" :assignees '("example-me") :created-at nil
                                        :updated-at nil))))
    (should (equal '(("A" assigned awaiting nil 1 1))
                   (prrr-state-test--rows (plist-get (prrr-state-test--queue prs nil) :for-me))))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test TESTS=test/prrr-state-test.el SELECTOR='"queue"'`
Expected: 10 failures, `void-function prrr-state-queue`.

- [ ] **Step 3: Implement**

Insert before `(provide 'prrr-state)`:

```elisp
;;;; Queue assembly

(defun prrr-state--touched-at (pr meta)
  "Return when I last touched PR: my review's submittedAt, else updated-at."
  (or (nth 1 (prrr-state--viewer-review meta))
      (prrr-pr-updated-at pr)
      ""))

(defun prrr-state--mine-rank (state)
  "Return the position of Mine STATE in `prrr-state-mine-order'."
  (or (cl-position state prrr-state-mine-order) (length prrr-state-mine-order)))

(defun prrr-state--for-me-pair (pr meta me teams pos size)
  "Return (KEY . ENTRY) for PR in the For Me group, or nil for my own PR.
META is PR's meta row or nil; POS and SIZE place PR in its Stack.  KEY
is a sort string for a qualifying PR (Awaiting me sorts before Served,
then by creation time or last touch) and nil for a dimmed context
member of a Stack."
  (unless (equal (prrr-pr-author pr) me)
    (let* ((member-p (prrr-state-for-me-p pr meta me teams))
           (state (and member-p (prrr-state-review-state pr meta me teams)))
           (partition (and member-p (prrr-state-partition pr state))))
      (cons (and member-p
                 (if (eq partition 'awaiting)
                     (format "0:%s" (or (prrr-pr-created-at pr) ""))
                   (format "1:%s" (prrr-state--touched-at pr meta))))
            (prrr-queue-entry-create
             :pr pr :state state :group 'for-me :partition partition
             :stack-pos pos :stack-size size
             :dimmed-p (and (or (not member-p) (prrr-pr-draft-p pr)) t))))))

(defun prrr-state--mine-pair (pr meta me pos size)
  "Return (KEY . ENTRY) for PR in the Mine group.
META is PR's meta row or nil; POS and SIZE place PR in its Stack.  KEY
sorts by Mine state rank then creation time; it is nil for a PR by
someone else, which is a dimmed context member of a Stack."
  (let* ((mine-p (equal (prrr-pr-author pr) me))
         (state (and mine-p (prrr-state-mine-state pr meta me))))
    (cons (and mine-p
               (format "%d:%s" (prrr-state--mine-rank state)
                       (or (prrr-pr-created-at pr) "")))
          (prrr-queue-entry-create
           :pr pr :state state :group 'mine :partition nil
           :stack-pos pos :stack-size size
           :dimmed-p (not mine-p)))))

(defun prrr-state--group (stacks make)
  "Assemble one Queue Group from STACKS.
MAKE is called with a PR, its 1-based position and its Stack's size and
returns (KEY . ENTRY) or nil to leave the PR out.  A Stack is listed
when any member has a non-nil KEY; Stacks sort by their smallest KEY
and keep their members together, bottom first."
  (let ((listed nil))
    (dolist (stack stacks)
      (let* ((size (length stack))
             (pairs (delq nil (cl-loop for pr in stack
                                       for pos from 1
                                       collect (funcall make pr pos size))))
             (keys (delq nil (mapcar #'car pairs))))
        (when keys
          (push (cons (car (sort keys #'string<)) (mapcar #'cdr pairs)) listed))))
    (apply #'append
           (mapcar #'cdr (sort (nreverse listed)
                               (lambda (a b) (string< (car a) (car b))))))))

(defun prrr-state-queue (prs metas me teams default-branch)
  "Return the ordered Review Queue as (:for-me ENTRIES :mine ENTRIES).
PRS are the repository's open `prrr-pr's, METAS their `prrr-pr-meta'
rows (missing rows are allowed), ME the viewer's login, TEAMS the
viewer's Team slugs and DEFAULT-BRANCH the repository's default branch.
ENTRIES are `prrr-queue-entry' lists ordered as SPEC section 5
describes."
  (let ((meta-table (make-hash-table :test #'equal))
        (stacks (prrr-state-stacks prs default-branch)))
    (dolist (meta metas)
      (puthash (prrr-pr-meta-pr-id meta) meta meta-table))
    (list :for-me (prrr-state--group
                   stacks
                   (lambda (pr pos size)
                     (prrr-state--for-me-pair pr (gethash (prrr-pr-id pr) meta-table)
                                              me teams pos size)))
          :mine (prrr-state--group
                 stacks
                 (lambda (pr pos size)
                   (prrr-state--mine-pair pr (gethash (prrr-pr-id pr) meta-table)
                                          me pos size))))))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make compile lint && make test`
Expected: all three suites pass (13 db, 21 github, 58 state: `Ran 92 tests, 92 results as expected`).

- [ ] **Step 5: Commit**

```bash
git add prrr-state.el test/prrr-state-test.el
git commit -m "feat(state): ordered Review Queue with partitions and Stacks"
```

---

### Task 12: Continuous integration

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: the `Makefile` targets from Task 1.

- [ ] **Step 1: Write the workflow**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    name: Emacs ${{ matrix.emacs }}
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        emacs: ["29.4", "30.1", "31.1"]
    steps:
      - uses: actions/checkout@v4
      - uses: purcell/setup-emacs@master
        with:
          version: ${{ matrix.emacs }}
      - name: Install dependencies from MELPA and GNU ELPA
        run: make deps
      - name: Byte-compile with warnings as errors
        run: make compile
      - name: package-lint and checkdoc
        run: make lint
      - name: ERT suite (no network)
        run: make test
```

- [ ] **Step 2: Validate the sequence locally and sweep for forbidden content**

Run, from a tree where `git status` shows only `.github/workflows/ci.yml` as untracked:

```bash
rm -rf .deps && make deps compile lint test
grep -rn "forge--" --include='*.el' . ; echo "forge-- hits above (expect none)"
grep -rn '/home/\|~/\.emacs\.d' --include='*.el' --include='*.yml' --include='Makefile' . ; echo "personal path hits above (expect none)"
```

Expected: the make sequence exits 0 with `Ran 92 tests`; both greps print nothing before their trailer line.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: run deps, compile, lint and tests on Emacs 29.4, 30.1 and 31.1"
```

---

## Self-review notes

- **Spec coverage.** Section 2 file layout: Tasks 1, 2, 4, 8. Section 3 tables and structs: Task 2. Section 4 queue, teams and per-PR queries: Tasks 4-6 (mutations, pagination beyond ghub's own, and rate-limit pauses are milestone 4 and `prrr-sync.el`). Section 5 Review State, membership, partitions, ordering and Stacks: Tasks 8-11 (rendering is milestone 2). Section 11 is observed in shape only (callbacks are the seam; nothing here blocks). Section 12 has no database-only render yet to measure; `make bench` is the stub section 15 allows. Section 13: ERT, `.eld` fixtures, stubbed `ghub-query`, no network, package-lint/checkdoc/byte-compile in CI (Tasks 1, 4, 12); `make test-live`, the git fixture repository and the benchmark harness belong to milestones 2-3. Section 14: license, headers, Package-Requires, Makefile (Task 1); `prrr-pkg.el`, README and CHANGELOG are milestone 8.
- **Not mapped on purpose.** The second `teammate-reviewed` signal in section 5 (a Team request that disappeared after another member's review) needs timeline items no query in this milestone fetches; only the `onBehalfOf` signal is implemented. The unresolved-Thread count on the Mine line is a rendering input from the `thread` table and belongs to the queue section in milestone 2. The pending review's own comments (section 4) are not selected: they are decoded from `reviewThreads`, where their side lives.
- **Placeholder scan.** Every code step carries the full code; the two conditional branches (Task 4 Step 4, Task 5 Step 4) each spell out both outcomes.
- **Type consistency.** `latest-reviews` entries are `(LOGIN STATE SUBMITTED-AT COMMIT-OID ON-BEHALF-OF-SLUGS)` and `viewer-latest-review` is `(STATE SUBMITTED-AT COMMIT-OID)` in the struct docstring (Task 2), the decoders (Task 4), the state helpers (`nth 1` is submitted-at, `nth 2` is commit-oid; Tasks 8 and 11) and every test. SPEC section 3 lists commit-oid before submitted-at; this plan fixes the order above and the struct docstring is the reference. `prrr-github-fetch-queue` takes FORGE-REPO-ID as a trailing optional argument so the decoder can stamp it, one more than the signature in the brief.
- **Review Focus.** Each of the five lines names the task whose tests pin it (Tasks 2, 4, 8, 9, 10).
