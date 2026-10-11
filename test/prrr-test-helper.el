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

;; Loaded by `make test' before every test file.  Provides
;; `prrr-test-root' (the repository root), `prrr-test-fixture' (path to
;; a file under test/fixtures), `prrr-db-with-test-db' (run BODY against
;; a fresh temporary database) and `prrr-test-with-ghub-stub' (run BODY
;; with ghub's GraphQL entry point stubbed) and
;; `prrr-test-with-ghub-error-stub' (the same,
;; failing every request).  `prrr-test-with-rest-stub' does
;; the same for ghub's REST entry point.  The builders `prrr-test-pr',
;; `prrr-test-meta' and `prrr-test-thread', and the constants `prrr-test-me',
;; `prrr-test-teams', `prrr-test-head' and `prrr-test-old' serve the
;; tests of the pure rules.  `prrr-test-with-repo' runs BODY in a fresh
;; copy of the git fixture repository built by test/fixtures/make-repo.sh,
;; and `prrr-test-repo-base' is its main's tip, the PR's base-rev.
;; `prrr-test-with-outbox' runs BODY with an empty Outbox that sends at once and
;; records timers in `prrr-test-timers'; `prrr-test-run-timers' runs them.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'prrr)
(require 'prrr-db)
(require 'prrr-state)

(defmacro prrr-db-with-test-db (&rest body)
  "Run BODY with `prrr-db' returning a fresh in-memory database."
  (declare (indent 0) (debug t))
  `(let ((prrr-db--connection (emacsql-sqlite-open nil)))
     (unwind-protect
         (progn (prrr-db--init prrr-db--connection) ,@body)
       (emacsql-close prrr-db--connection))))

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

(defmacro prrr-test-with-ghub-error-stub (err headers &rest body)
  "Run BODY with `ghub-query' failing every request with ERR and HEADERS.
The errorback runs synchronously, as ghub calls it: with ERR, HEADERS,
a nil status and a nil request.  A request without an errorback fails
the test, because ghub would signal."
  (declare (indent 2) (debug (form form body)))
  `(cl-letf (((symbol-function 'ghub-query)
              (lambda (_query _variables &rest args)
                (let ((errorback (plist-get args :errorback)))
                  (unless errorback
                    (ert-fail "request sent without an errorback"))
                  (funcall errorback ,err ,headers nil nil)))))
     ,@body))

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

(defconst prrr-test-me "example-me")
(defconst prrr-test-teams '("example-org/reviewers"))
(defconst prrr-test-head "1111111111111111111111111111111111111111")
(defconst prrr-test-old "0000000000000000000000000000000000000000")

(cl-defun prrr-test-pr (&key (id "PR_1") (number 1) (title "Example")
                                    (author "example-alice") draft-p assignees
                                    (created-at "2026-09-01T00:00:00Z")
                                    (updated-at "2026-09-05T00:00:00Z")
                                    (head-oid prrr-test-head)
                                    (base-ref "main") (head-ref "feature-1")
                                    cross-repo-p)
  "Build a `prrr-pr' with sensible defaults.
Keyword arguments: ID, NUMBER, TITLE, AUTHOR, DRAFT-P, ASSIGNEES,
CREATED-AT, UPDATED-AT, HEAD-OID, BASE-REF, HEAD-REF and CROSS-REPO-P."
  (prrr-pr-create :id id :number number :title title :author author
                  :draft-p draft-p :assignees assignees :created-at created-at
                  :updated-at updated-at :head-oid head-oid :base-ref base-ref
                  :head-ref head-ref :cross-repo-p cross-repo-p))

(cl-defun prrr-test-meta (&key (pr-id "PR_1") (number 1) (head-oid prrr-test-head)
                                      review-requests latest-reviews
                                      viewer-latest-review viewer-latest-review-request
                                      (created-at "2026-09-01T00:00:00Z"))
  "Build a `prrr-pr-meta' with sensible defaults.
Keyword arguments: PR-ID, NUMBER, HEAD-OID, REVIEW-REQUESTS, LATEST-REVIEWS,
VIEWER-LATEST-REVIEW, VIEWER-LATEST-REVIEW-REQUEST and CREATED-AT."
  (prrr-pr-meta-create :pr-id pr-id :forge-repo-id "example-repo-id" :number number
                       :head-oid head-oid :review-requests review-requests
                       :latest-reviews latest-reviews
                       :viewer-latest-review viewer-latest-review
                       :viewer-latest-review-request viewer-latest-review-request
                       :created-at created-at :fetched-at "2026-10-10T12:00:00Z"))

(cl-defun prrr-test-thread (&key (id "T_1") (path "src/example.el") (line 12) start-line
                                 (side 'right) (subject-type 'line) outdated-p resolved-p)
  "Build a `prrr-thread' of PR_1 with sensible defaults.
Keyword arguments: ID, PATH, LINE, START-LINE, SIDE, SUBJECT-TYPE,
OUTDATED-P and RESOLVED-P."
  (prrr-thread-create :thread-id id :pr-id "PR_1" :path path :line line
                      :start-line start-line :side side
                      :start-side (and start-line side)
                      :subject-type subject-type :outdated-p outdated-p
                      :resolved-p resolved-p :original-line line))

(defvar prrr-test-requests nil
  "Top-level fields of the requests seen by `prrr-test-with-ghub-dispatch'.")

(defvar prrr-test-variables nil
  "In `prrr-test-with-ghub-dispatch': (FIELD . VARIABLES) of each request.
Newest first.")

(defmacro prrr-test-with-ghub-dispatch (alist &rest body)
  "Run BODY with `ghub-query' answering each request from ALIST.
ALIST maps the request's top-level field (`repository', `viewer', or a
mutation such as `addPullRequestReviewThread') to its answer: a
fixture datum; a function of the query and the variables that returns
one; or (:error ERR), which fails the request as ghub does, with ERR
and no headers.  Answers come synchronously.  The variable
`prrr-test-requests' collects the top-level field of every request,
oldest first, and `prrr-test-variables' their variables."
  (declare (indent 1) (debug (form body)))
  `(let ((prrr-test-requests nil)
         (prrr-test-variables nil))
     (cl-letf (((symbol-function 'ghub-query)
                (lambda (query variables &rest args)
                  (let* ((field (car (cadr query)))
                         (answer (or (alist-get field ,alist)
                                     (ert-fail (list "unexpected request" field))))
                         (answer (if (functionp answer) (funcall answer query variables) answer)))
                    (setq prrr-test-requests (append prrr-test-requests (list field)))
                    (push (cons field variables) prrr-test-variables)
                    (if (eq (car-safe answer) :error)
                        (funcall (plist-get args :errorback) (cadr answer) nil nil nil)
                      (funcall (plist-get args :callback) answer))))))
       ,@body)))

(defvar prrr-test-repo-base nil
  "Inside `prrr-test-with-repo': the oid of main's tip, the PR's base-rev.")

(defmacro prrr-test-with-repo (&rest body)
  "Run BODY in a fresh copy of the Review Buffer fixture repository.
`default-directory' is the repository, built by
test/fixtures/make-repo.sh: refs/pullreqs/1 is the PR's head and
`prrr-test-repo-base' main's tip.  The copy is deleted afterwards."
  (declare (indent 0) (debug t))
  (let ((dir (make-symbol "dir")))
    `(let ((,dir (make-temp-file "prrr-repo" t)))
       (unwind-protect
           (progn
             (unless (zerop (call-process "sh" nil nil nil
                                          (expand-file-name "test/fixtures/make-repo.sh"
                                                            prrr-test-root)
                                          ,dir))
               (error "Building the fixture repository failed"))
             (let* ((default-directory (file-name-as-directory ,dir))
                    ;; The developer's git configuration (diff.context, say)
                    ;; must not change what the tests see.
                    (process-environment (append (list "GIT_CONFIG_GLOBAL=/dev/null"
                                                       "GIT_CONFIG_NOSYSTEM=1")
                                                 process-environment))
                    (prrr-test-repo-base (car (process-lines "git" "rev-parse" "main"))))
               ,@body))
         (delete-directory ,dir t)))))

(defmacro prrr-test-with-rest-stub (answer captured &rest body)
  "Run BODY with `ghub-request' answering every request with ANSWER.
CAPTURED is bound to (METHOD RESOURCE PARAMS) of the last request.
ANSWER is the decoded JSON value handed to the callback, or
\(:error ERR HEADERS) to call the errorback with ERR and HEADERS as
ghub does.  Both run synchronously."
  (declare (indent 2) (debug (form symbolp body)))
  `(let ((,captured nil))
     (cl-letf (((symbol-function 'ghub-request)
                (lambda (method resource params &rest args)
                  (setq ,captured (list method resource params))
                  (let ((answer ,answer))
                    (if (eq (car-safe answer) :error)
                        (funcall (plist-get args :errorback)
                                 (plist-get answer :error) (plist-get answer :headers) nil nil)
                      (funcall (plist-get args :callback) answer nil nil nil))))))
       ,@body)))

(defvar prrr-test-timers nil
  "In `prrr-test-with-outbox': (TIME FUNCTION ARGS) of each timer, newest first.")

(defmacro prrr-test-with-outbox (&rest body)
  "Run BODY with an empty Outbox, no spacing between mutations, and no timers.
`run-at-time' records its calls in `prrr-test-timers' instead of
setting timers, so nothing runs later; run one with
`prrr-test-run-timers'.  The viewer is \"example-me\"."
  (declare (indent 0) (debug t))
  `(let ((prrr-sync--outbox-sending nil)
         (prrr-sync--outbox-token 0)
         (prrr-sync--outbox-mutated-at 0.0)
         (prrr-sync--outbox-creations nil)
         (prrr-sync--outbox-paused-until nil)
         (prrr-sync--outbox-scheduled nil)
         (prrr-sync--outbox-started nil)
         (prrr-sync--outbox-buffers (make-hash-table :test #'equal))
         (prrr-sync--outbox-dirty (make-hash-table :test #'equal))
         (prrr-sync--renames (make-hash-table :test #'equal))
         (prrr-sync--posted (make-hash-table :test #'equal))
         (prrr-sync--retry-pump-at nil)
         (prrr-sync--status (make-hash-table :test #'equal))
         (prrr-sync--mutation-spacing 0)
         (prrr-github-user "example-me")
         (prrr-test-timers nil))
     (cl-letf (((symbol-function 'run-at-time)
                (lambda (time _repeat function &rest args)
                  (push (list time function args) prrr-test-timers)
                  nil)))
       ,@body)))

(defun prrr-test-run-timers (function)
  "Run, and forget, the recorded timers that call FUNCTION, oldest first."
  (let ((due (reverse (seq-filter (lambda (timer) (eq (nth 1 timer) function))
                                  prrr-test-timers))))
    (setq prrr-test-timers (seq-difference prrr-test-timers due #'eq))
    (dolist (timer due)
      (apply (nth 1 timer) (nth 2 timer)))))

(provide 'prrr-test-helper)
;;; prrr-test-helper.el ends here
