;;; prrr-db.el --- SQLite schema, structs and CRUD for prrr  -*- lexical-binding: t -*-

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

(defcustom prrr-database-file
  (expand-file-name "prrr-database.sqlite" user-emacs-directory)
  "File holding prrr's SQLite database.
One database serves every repository.  Created on first use."
  :type 'file
  :group 'prrr)

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
by table constraints.  The struct's slots equal the columns in order.
The `outbox' column layout is frozen until 1.0, because `prrr-db-reset'
never recreates that table and its old rows must stay readable.")

(defun prrr-db--table-entry (table)
  "Return the `prrr-db--tables' entry of TABLE, or signal an error."
  (or (assq table prrr-db--tables)
      (error "Unknown prrr-db table: %s" table)))

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
  "Build TABLE's struct from ROW, a list of column values.
Signal an error when ROW does not have one value per slot."
  (let* ((struct (prrr-db--struct table))
         (slots (prrr-db--slot-names struct)))
    (unless (= (length row) (length slots))
      (error "Row for table %s has %d values, expected %d"
             table (length row) (length slots)))
    (apply (intern (format "%s-create" struct))
           (cl-loop for slot in slots
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
  (emacsql-with-transaction db
    (dolist (entry prrr-db--tables)
      (unless (prrr-db--table-exists-p db (nth 0 entry))
        (emacsql db (vector :create-table (nth 0 entry) (nth 2 entry)))))
    (unless (prrr-db--table-exists-p db 'schema-version)
      (emacsql db [:create-table schema-version ([version])]))
    (emacsql db [:delete :from schema-version])
    (emacsql db [:insert :into schema-version :values $v1]
             (list (vector prrr-db-schema-version)))))

(defun prrr-db--drop-table (db table)
  "Drop TABLE from DB if it exists."
  (when (prrr-db--table-exists-p db table)
    (emacsql db (vector :drop-table table))))

(defun prrr-db-reset (&optional db)
  "Drop and recreate every table except `outbox' in DB.
DB defaults to the open connection.  The stored schema version becomes
`prrr-db-schema-version'.  Return DB."
  (let ((db (or db (prrr-db))))
    (emacsql-with-transaction db
      (dolist (entry prrr-db--tables)
        (unless (eq (nth 0 entry) 'outbox)
          (prrr-db--drop-table db (nth 0 entry))))
      (prrr-db--create-tables db))
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
row is returned.  Rows come back in rowid order; a row replaced by
`prrr-db-insert' moves to the end."
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

(provide 'prrr-db)
;;; prrr-db.el ends here
