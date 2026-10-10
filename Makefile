EMACS    ?= emacs
DEPS_DIR := $(CURDIR)/.deps
SRC      := prrr-db.el prrr-github.el prrr-state.el prrr-sync.el prrr-queue.el prrr.el
TESTS    ?= test/prrr-db-test.el test/prrr-github-test.el test/prrr-state-test.el test/prrr-sync-test.el test/prrr-queue-test.el
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
	  -f batch-byte-compile $(wildcard $(SRC)) $(wildcard test/*.el); \
	  status=$$?; rm -f *.elc test/*.elc; exit $$status

lint:
	$(BATCH) -l package-lint \
	  --eval '(setq package-lint-main-file "prrr.el")' \
	  -f package-lint-batch-and-exit $(wildcard $(SRC))
	$(BATCH) --eval '(progn (require (quote checkdoc)) (setq checkdoc-verb-check-experimental-flag nil) (defvar prrr-checkdoc-failed nil) (setq checkdoc-create-error-function (lambda (text start _end &optional _unfixable) (setq prrr-checkdoc-failed t) (message "%s:%d: %s" (buffer-file-name) (line-number-at-pos start) text) nil)) (dolist (file command-line-args-left) (checkdoc-file file)) (kill-emacs (if prrr-checkdoc-failed 1 0)))' \
	  $(wildcard $(SRC)) $(wildcard test/*.el)

test:
	$(BATCH) -l test/prrr-test-helper.el $(addprefix -l ,$(wildcard $(TESTS))) \
	  --eval '(ert-run-tests-batch-and-exit (quote $(SELECTOR)))'

bench:
	@echo "no benchmarks yet"

clean:
	rm -f *.elc test/*.elc
