EMACS    ?= emacs
DEPS_DIR := $(CURDIR)/.deps
SRC      := prrr-db.el prrr-github.el prrr-state.el prrr-sync.el prrr-queue.el prrr-diff.el prrr-stack.el prrr-transient.el prrr.el
TESTS    ?= test/prrr-db-test.el test/prrr-github-test.el test/prrr-state-test.el test/prrr-sync-test.el test/prrr-queue-test.el test/prrr-diff-test.el test/prrr-test.el
SELECTOR ?= t

BATCH := $(EMACS) -Q --batch \
  --eval '(setq package-user-dir "$(DEPS_DIR)")' \
  --eval '(package-initialize)' \
  -L . -L test

# Like BATCH but without -L ., so a compiled copy on load-path wins.
BENCH := $(EMACS) -Q --batch \
  --eval '(setq package-user-dir "$(DEPS_DIR)")' \
  --eval '(package-initialize)'

.PHONY: deps compile lint test bench clean

deps:
	$(EMACS) -Q --batch --eval '(setq package-user-dir "$(DEPS_DIR)")' \
	  -l scripts/install-deps.el

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(wildcard $(SRC)) $(wildcard test/*.el) $(wildcard bench/*.el); \
	  status=$$?; rm -f *.elc test/*.elc bench/*.elc; exit $$status

lint:
	$(BATCH) -l package-lint \
	  --eval '(setq package-lint-main-file "prrr.el")' \
	  -f package-lint-batch-and-exit $(wildcard $(SRC))
	$(BATCH) --eval '(progn (require (quote checkdoc)) (setq checkdoc-verb-check-experimental-flag nil) (defvar prrr-checkdoc-failed nil) (setq checkdoc-create-error-function (lambda (text start _end &optional _unfixable) (setq prrr-checkdoc-failed t) (message "%s:%d: %s" (buffer-file-name) (line-number-at-pos start) text) nil)) (dolist (file command-line-args-left) (checkdoc-file file)) (kill-emacs (if prrr-checkdoc-failed 1 0)))' \
	  $(wildcard $(SRC)) $(wildcard test/*.el) $(wildcard bench/*.el)

test:
	$(BATCH) -l test/prrr-test-helper.el $(addprefix -l ,$(wildcard $(TESTS))) \
	  --eval '(ert-run-tests-batch-and-exit (quote $(SELECTOR)))'

# The budget is for the byte-compiled package, which is what users run.
# Build a throwaway compiled copy so the working tree stays free of .elc.
bench:
	@dir=$$(mktemp -d) && trap 'rm -rf "$$dir"' EXIT && \
	  cp $(SRC) bench/*.el "$$dir" && \
	  $(BENCH) -L "$$dir" -f batch-byte-compile $(addprefix "$$dir"/,$(SRC)) "$$dir"/prrr-queue-bench.el && \
	  $(BENCH) -L "$$dir" -l "$$dir"/prrr-queue-bench.elc -f prrr-queue-bench-run

clean:
	rm -f *.elc test/*.elc bench/*.elc
