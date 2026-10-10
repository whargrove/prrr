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
