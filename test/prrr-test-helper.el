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
;; failing every request).  The builders `prrr-test-pr',
;; `prrr-test-meta' and `prrr-test-thread', and the constants `prrr-test-me',
;; `prrr-test-teams', `prrr-test-head' and `prrr-test-old' serve the
;; tests of the pure rules.

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

(defmacro prrr-test-with-ghub-dispatch (alist &rest body)
  "Run BODY with `ghub-query' answering each request from ALIST.
ALIST maps the query's top-level field (`repository' or `viewer') to
the fixture datum to answer with.  Callbacks run synchronously.  The
variable `prrr-test-requests' collects the top-level field of every
request, oldest first."
  (declare (indent 1) (debug (form body)))
  `(let ((prrr-test-requests nil))
     (cl-letf (((symbol-function 'ghub-query)
                (lambda (query _variables &rest args)
                  (let ((field (car (cadr query))))
                    (setq prrr-test-requests (append prrr-test-requests (list field)))
                    (funcall (plist-get args :callback)
                             (or (alist-get field ,alist)
                                 (ert-fail (list "unexpected request" field))))))))
       ,@body)))

(provide 'prrr-test-helper)
;;; prrr-test-helper.el ends here
