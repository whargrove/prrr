;;; prrr-db-test.el --- Tests for prrr-db  -*- lexical-binding: t -*-

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

;; Schema, structs, connection lifecycle and CRUD of `prrr-db', run
;; against an in-memory SQLite database.

;;; Code:

(require 'ert)
(require 'prrr-test-helper)
(require 'prrr-db)
(require 'prrr-github)
(require 'seq)

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
      (emacsql db [:insert :into outbox :values $v1]
               (list (vector 1 "PR_1" 'comment "payload"
                             "2026-10-10T12:00:00Z" 0 nil)))
      (prrr-db-reset db)
      (should (null (emacsql db [:select * :from pr-bookmark])))
      (should (= 1 (length (emacsql db [:select * :from outbox])))))))

(ert-deftest prrr-db-test-row-to-struct-rejects-wrong-arity ()
  "A row with fewer values than the table has columns is an error."
  (should-error (prrr-db--row-to-struct 'outbox (list 1 "PR_1"))
                :type 'error))

(ert-deftest prrr-db-test-open-creates-directory ()
  "Review Focus 4: `prrr-db' creates the database's directory."
  (let* ((dir (make-temp-file "prrr-db-test-" t))
         (prrr-database-file (expand-file-name "nested/dir/prrr.sqlite" dir))
         (prrr-db--connection nil)
         (opened 0)
         (prrr-db-open-hook (list (lambda () (cl-incf opened)))))
    (unwind-protect
        (progn
          (should (emacsql-live-p (prrr-db)))
          (should (= 1 opened))
          (should (file-exists-p prrr-database-file))
          (should (eq (prrr-db) prrr-db--connection))
          ;; The hook runs when the database opens, not on every use.
          (should (= 1 opened))
          (prrr-db-close)
          (should (null prrr-db--connection)))
      (prrr-db-close)
      (delete-directory dir t))))

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

;;;; Queue additions

(ert-deftest prrr-db-test-take-preserved-outbox-returns-once ()
  (let ((prrr-db-preserved-outbox (list (prrr-outbox-create :id "o1" :kind 'comment))))
    (should (equal '("o1") (mapcar #'prrr-outbox-id (prrr-db-take-preserved-outbox))))
    (should (null prrr-db-preserved-outbox))
    (should (null (prrr-db-take-preserved-outbox)))))

(ert-deftest prrr-db-test-replace-pr-metas-replaces-only-that-repository ()
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-pr-meta-create :pr-id "CLOSED" :forge-repo-id "repo-a"))
    (prrr-db-insert (prrr-pr-meta-create :pr-id "OTHER" :forge-repo-id "repo-b"))
    (prrr-db-replace-pr-metas "repo-a"
                              (list (prrr-pr-meta-create :pr-id "OPEN-1" :forge-repo-id "repo-a")
                                    (prrr-pr-meta-create :pr-id "OPEN-2" :forge-repo-id "repo-a")))
    (should (equal '("OPEN-1" "OPEN-2")
                   (mapcar #'prrr-pr-meta-pr-id
                           (prrr-db-select 'pullreq-meta :forge-repo-id "repo-a"))))
    (should (prrr-db-get 'pullreq-meta "OTHER"))))

(ert-deftest prrr-db-test-replace-pr-metas-with-none-empties-the-repository ()
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-pr-meta-create :pr-id "CLOSED" :forge-repo-id "repo-a"))
    (prrr-db-replace-pr-metas "repo-a" nil)
    (should (null (prrr-db-select 'pullreq-meta :forge-repo-id "repo-a")))))

(ert-deftest prrr-db-test-replace-teams ()
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-team-create :combined-slug "example-org/old"))
    (prrr-db-replace-teams (list (prrr-team-create :combined-slug "example-org/new")))
    (should (equal '("example-org/new")
                   (mapcar #'prrr-team-combined-slug (prrr-db-select 'team))))))

(ert-deftest prrr-db-test-unresolved-thread-counts ()
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-thread-create :thread-id "t1" :pr-id "P1" :resolved-p nil))
    (prrr-db-insert (prrr-thread-create :thread-id "t2" :pr-id "P1" :resolved-p nil))
    (prrr-db-insert (prrr-thread-create :thread-id "t3" :pr-id "P1" :resolved-p t))
    (prrr-db-insert (prrr-thread-create :thread-id "t4" :pr-id "P2" :resolved-p t))
    (prrr-db-insert (prrr-thread-create :thread-id "t5" :pr-id "P3" :resolved-p nil))
    (let ((counts (prrr-db-unresolved-thread-counts '("P1" "P2"))))
      (should (= 2 (gethash "P1" counts)))
      (should (null (gethash "P2" counts)))
      (should (null (gethash "P3" counts))))
    (should (zerop (hash-table-count (prrr-db-unresolved-thread-counts nil))))))

;;;; Review data

(defconst prrr-db-test--pr "PR_kwDOexample0000001"
  "The PR of the review-data fixture.")

(defun prrr-db-test--review-data ()
  "The review-data fixture, decoded."
  (prrr-github-decode-review-data (prrr-test-fixture "review-data") prrr-db-test--pr
                                  "2026-10-10T12:00:00Z"))

(ert-deftest prrr-db-test-review-data-round-trip ()
  (prrr-db-with-test-db
    (prrr-db-replace-review-data prrr-db-test--pr (prrr-db-test--review-data))
    (let ((data (prrr-db-review-data prrr-db-test--pr)))
      (should (equal '("PRRT_kwDOexample0000001" "PRRT_kwDOexample0000002"
                       "PRRT_kwDOexample0000003" "PRRT_kwDOexample0000004"
                       "PRRT_kwDOexample0000005")
                     (mapcar #'prrr-thread-thread-id (plist-get data :threads))))
      (should (equal '("PRRC_kwDOexample0000004" "PRRC_kwDOexample0000001"
                       "PRRC_kwDOexample0000002" "PRRC_kwDOexample0000003"
                       "PRRC_kwDOexample0000005" "PRRC_kwDOexample0000006")
                     (mapcar #'prrr-comment-comment-id (plist-get data :comments))))
      (should (equal "PRR_kwDOexamplePending1"
                     (prrr-pending-review-review-id (plist-get data :pending-review))))
      (should (= 3 (length (plist-get data :viewed)))))))

(ert-deftest prrr-db-test-review-data-replaces-old-rows ()
  "A Thread deleted on GitHub disappears; the Pending Review too once submitted."
  (prrr-db-with-test-db
    (prrr-db-replace-review-data prrr-db-test--pr (prrr-db-test--review-data))
    (let ((data (prrr-db-test--review-data)))
      (prrr-db-replace-review-data
       prrr-db-test--pr
       (list :threads (cdr (plist-get data :threads))
             :comments (seq-remove (lambda (comment)
                                     (equal (prrr-comment-thread-id comment)
                                            "PRRT_kwDOexample0000001"))
                                   (plist-get data :comments))
             :pending-review nil
             :viewed nil)))
    (let ((data (prrr-db-review-data prrr-db-test--pr)))
      (should (= 4 (length (plist-get data :threads))))
      (should (= 4 (length (plist-get data :comments))))
      (should-not (plist-get data :pending-review))
      (should-not (plist-get data :viewed)))))

(ert-deftest prrr-db-test-review-data-other-pr-untouched ()
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-test-thread :id "OTHER"))
    (prrr-db-replace-review-data prrr-db-test--pr (prrr-db-test--review-data))
    (prrr-db-replace-review-data prrr-db-test--pr nil)
    (should (equal '("OTHER") (mapcar #'prrr-thread-thread-id (prrr-db-select 'thread))))))

(ert-deftest prrr-db-test-review-data-never-fetched ()
  (prrr-db-with-test-db
    (should (equal '(:threads nil :comments nil :pending-review nil :viewed nil)
                   (prrr-db-review-data "PR_never")))))

;;;; The Outbox

(defun prrr-db-test--write (id pr-id kind payload &optional last-error)
  "A queued write ID of PR-ID with KIND, PAYLOAD and LAST-ERROR."
  (prrr-outbox-create :id id :pr-id pr-id :kind kind :payload payload
                      :created-at "2026-10-10T12:00:00Z" :attempts 0
                      :last-error last-error))

(ert-deftest prrr-db-test-outbox-rows-oldest-first ()
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-db-test--write "2" "PR_1" 'viewed '(:path "b")))
    (prrr-db-insert (prrr-db-test--write "1" "PR_1" 'viewed '(:path "a")))
    (prrr-db-insert (prrr-db-test--write "3" "PR_2" 'viewed '(:path "c")))
    ;; Replacing a row moves it to the end of rowid order, not of the Outbox.
    (prrr-db-insert (prrr-db-test--write "1" "PR_1" 'viewed '(:path "a") "offline"))
    (should (equal '("1" "2" "3") (mapcar #'prrr-outbox-id (prrr-db-outbox-rows))))
    (should (equal '("1" "2") (mapcar #'prrr-outbox-id (prrr-db-outbox-rows "PR_1"))))
    (should (equal '(:path "a") (prrr-outbox-payload (car (prrr-db-outbox-rows)))))))

(ert-deftest prrr-db-test-outbox-clear-errors ()
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-db-test--write "1" "PR_1" 'viewed nil "offline"))
    (prrr-db-insert (prrr-db-test--write "2" "PR_2" 'viewed nil "offline"))
    (prrr-db-outbox-clear-errors "PR_1")
    (should (equal '(nil "offline") (mapcar #'prrr-outbox-last-error (prrr-db-outbox-rows))))
    (prrr-db-outbox-clear-errors)
    (should (equal '(nil nil) (mapcar #'prrr-outbox-last-error (prrr-db-outbox-rows))))))

(ert-deftest prrr-db-test-outbox-clear-errors-keeps ()
  "A row KEEP accepts keeps its error."
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-db-test--write "1" "PR_1" 'viewed '(:keep t) "check"))
    (prrr-db-insert (prrr-db-test--write "2" "PR_1" 'viewed nil "offline"))
    (prrr-db-insert (prrr-db-test--write "3" "PR_2" 'viewed nil "offline"))
    (let ((keep (lambda (row) (plist-get (prrr-outbox-payload row) :keep))))
      (prrr-db-outbox-clear-errors "PR_1" keep)
      (should (equal '("check" nil "offline")
                     (mapcar #'prrr-outbox-last-error (prrr-db-outbox-rows))))
      (prrr-db-outbox-clear-errors nil keep)
      (should (equal '("check" nil nil)
                     (mapcar #'prrr-outbox-last-error (prrr-db-outbox-rows)))))))

(ert-deftest prrr-db-test-outbox-done ()
  "The write leaves, its rows arrive, and the PR's other writes learn GitHub's ids."
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-db-test--write "1" "PR_1" 'thread '(:thread "local:T" :comment "local:C")))
    (prrr-db-insert (prrr-db-test--write "2" "PR_1" 'reply '(:thread-id "local:T" :comment "local:R")))
    (prrr-db-insert (prrr-db-test--write "3" "PR_2" 'reply '(:thread-id "local:T")))
    (prrr-db-insert (prrr-test-thread :id "GONE"))
    (prrr-db-outbox-done "1"
                         :insert (list (prrr-test-thread :id "PRRT_1"))
                         :delete '((thread :thread-id "GONE"))
                         :renames '(("local:T" . "PRRT_1")))
    (should (equal '("2" "3") (mapcar #'prrr-outbox-id (prrr-db-outbox-rows))))
    (should (equal '(:thread-id "PRRT_1" :comment "local:R")
                   (prrr-outbox-payload (prrr-db-get 'outbox "2"))))
    (should (equal '(:thread-id "local:T") (prrr-outbox-payload (prrr-db-get 'outbox "3"))))
    (should (equal '("PRRT_1") (mapcar #'prrr-thread-thread-id (prrr-db-select 'thread))))))

(ert-deftest prrr-db-test-review-data-keeps-the-outbox ()
  "Bead prrr-8ok: a refetch replaces GitHub's rows, not the queued writes."
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-db-test--write "1" prrr-db-test--pr 'reply
                                         '(:thread-id "local:T" :comment "local:R")))
    (prrr-db-replace-review-data prrr-db-test--pr (prrr-db-test--review-data)
                                 '(("local:T" . "PRRT_kwDOexample0000005")))
    (should (equal '(:thread-id "PRRT_kwDOexample0000005" :comment "local:R")
                   (prrr-outbox-payload (car (prrr-db-outbox-rows prrr-db-test--pr)))))))

(ert-deftest prrr-db-test-new-columns-round-trip ()
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-thread-create :thread-id "T" :pr-id "PR_1" :resolvable-p t))
    (prrr-db-insert (prrr-comment-create :comment-id "C" :thread-id "T" :pr-id "PR_1"
                                         :database-id "1001"))
    (should (prrr-thread-resolvable-p (prrr-db-get 'thread "T")))
    (should (equal "1001" (prrr-comment-database-id (prrr-db-get 'review-comment "C"))))))

(provide 'prrr-db-test)
;;; prrr-db-test.el ends here
