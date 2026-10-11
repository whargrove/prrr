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
;;
;; The review tables hold only what GitHub sent or accepted.  Writes
;; GitHub has not accepted yet are rows of the `outbox' table, which
;; the Outbox in prrr-sync.el reads and changes through the functions
;; of the part "The Outbox".

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

(defconst prrr-db-schema-version 2
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
`file'; OUTDATED-P and RESOLVED-P are booleans.  RESOLVABLE-P is
non-nil when GitHub lets the viewer resolve the Thread, or unresolve
it when it is resolved."
  thread-id pr-id path line start-line side start-side subject-type
  outdated-p resolved-p resolvable-p original-line original-commit fetched-at)

(cl-defstruct (prrr-comment (:constructor prrr-comment-create) (:copier nil))
  "A Review Comment inside a Thread (table `review-comment').
STATE is `pending' or `submitted' (GitHub's).  LOCAL-STATE is `sent' for
a row GitHub sent or accepted, `unsent' for one the Outbox has not sent
yet (only in `prrr-state-outbox-view', never stored) and `proposed' for
an agent's proposal (milestone 7).  AGENT-P marks comments added through
the API.  DATABASE-ID is GitHub's numeric id as a string, which its
REST endpoints take."
  comment-id thread-id pr-id author body created-at updated-at reply-to
  review-id state local-state agent-p database-id)

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
  "A write GitHub has not accepted yet (table `outbox').
ID increases with time, so the Outbox sends in id order.  KIND and
PAYLOAD are as `prrr-state-outbox-kinds' describes.  ATTEMPTS counts
the sends that failed; LAST-ERROR is the last failure's message, nil
when the write is waiting to be sent."
  id pr-id kind payload created-at attempts last-error)

;;;; Schema

(defconst prrr-db--tables
  '((pullreq-meta prrr-pr-meta
     ([(pr-id :primary-key) forge-repo-id number head-oid review-requests
       latest-reviews viewer-latest-review viewer-latest-review-request
       created-at fetched-at]))
    (thread prrr-thread
     ([(thread-id :primary-key) pr-id path line start-line side start-side
       subject-type outdated-p resolved-p resolvable-p original-line original-commit
       fetched-at]))
    (review-comment prrr-comment
     ([(comment-id :primary-key) thread-id pr-id author body created-at
       updated-at reply-to review-id state local-state agent-p database-id]))
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
anything else; `prrr-db--init' sets it and
`prrr-db-take-preserved-outbox' hands the rows out once.")

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

(defvar prrr-db-open-hook nil
  "Functions run, with no argument, each time `prrr-db' opens the database.
The connection is open and usable when they run.")

(defun prrr-db ()
  "Return the open connection to `prrr-database-file', opening it if needed.
The file's directory is created when missing.  Opening it runs
`prrr-db-open-hook'."
  (unless (and prrr-db--connection (emacsql-live-p prrr-db--connection))
    (let ((file (expand-file-name prrr-database-file)))
      (make-directory (file-name-directory file) t)
      (setq prrr-db--connection (emacsql-sqlite-open file))
      (prrr-db--init prrr-db--connection)
      (run-hooks 'prrr-db-open-hook)))
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

;;;; Queue inputs

(defun prrr-db-take-preserved-outbox ()
  "Return the Outbox rows kept by the last schema reset, and forget them.
Each row is handed out once, so whoever shows them to the user calls
this and nothing is announced twice.  The rows stay in the `outbox'
table."
  (prog1 prrr-db-preserved-outbox
    (setq prrr-db-preserved-outbox nil)))

(defun prrr-db-replace-pr-metas (forge-repo-id metas)
  "Make METAS the only `pullreq-meta' rows of FORGE-REPO-ID.
METAS are the repository's open PRs, so rows of PRs that closed since
the last pull disappear.  One transaction."
  (let ((db (prrr-db)))
    (emacsql-with-transaction db
      (prrr-db-delete 'pullreq-meta :forge-repo-id forge-repo-id)
      (when metas
        (emacsql db [:insert-or-replace :into pullreq-meta :values $v1]
                 (mapcar #'prrr-db--struct-to-row metas))))
    nil))

(defun prrr-db-replace-teams (teams)
  "Make TEAMS, a list of `prrr-team', the viewer's only Teams.  One transaction."
  (let ((db (prrr-db)))
    (emacsql-with-transaction db
      (prrr-db-delete 'team)
      (when teams
        (emacsql db [:insert-or-replace :into team :values $v1]
                 (mapcar #'prrr-db--struct-to-row teams))))
    nil))

(defun prrr-db-unresolved-thread-counts (pr-ids)
  "Return a hash table from each of PR-IDS to its number of unresolved Threads.
A PR with no unresolved Thread, or whose Threads were never fetched, is
absent from the table."
  (let ((counts (make-hash-table :test #'equal)))
    (when pr-ids
      (pcase-dolist (`(,pr-id ,count)
                     (emacsql (prrr-db)
                              [:select [pr-id (funcall count *)] :from thread
                               :where (and (in pr-id $v1) (isnull resolved-p))
                               :group-by pr-id]
                              (vconcat pr-ids)))
        (puthash pr-id count counts)))
    counts))

;;;; Review data

(defun prrr-db-replace-review-data (pr-id data &optional renames)
  "Make DATA the only stored review data of PR-ID.
DATA is the plist `prrr-github-decode-review-data' returns, or nil: its
:threads, :comments, :pending-review and :viewed replace every
`thread', `review-comment', `pending-review' and `viewed' row of PR-ID.
These tables hold only what GitHub sent or accepted; the Outbox's
unsent writes live in the `outbox' table, which this leaves alone apart
from RENAMES, an alist from local id to GitHub's applied to the PR's
queued writes.  One transaction."
  (let ((db (prrr-db)))
    (emacsql-with-transaction db
      (dolist (table '(thread review-comment pending-review viewed))
        (prrr-db-delete table :pr-id pr-id))
      (dolist (rows (list (plist-get data :threads)
                          (plist-get data :comments)
                          (delq nil (list (plist-get data :pending-review)))
                          (plist-get data :viewed)))
        (when rows
          (emacsql db (vector :insert-or-replace :into (prrr-db--table-of (car rows))
                              :values '$v1)
                   (mapcar #'prrr-db--struct-to-row rows))))
      (prrr-db--rename-outbox-ids pr-id renames))
    nil))

(defun prrr-db-review-data (pr-id)
  "Return the stored review data of PR-ID.
A plist like the DATA of `prrr-db-replace-review-data': :threads in the
order they were stored, :comments oldest first, :pending-review or nil,
and :viewed.  A PR never fetched has nil for each."
  (list :threads (prrr-db-select 'thread :pr-id pr-id)
        :comments (sort (prrr-db-select 'review-comment :pr-id pr-id)
                        (lambda (a b)
                          (string< (or (prrr-comment-created-at a) "")
                                   (or (prrr-comment-created-at b) ""))))
        :pending-review (prrr-db-get 'pending-review pr-id)
        :viewed (prrr-db-select 'viewed :pr-id pr-id)))

;;;; The Outbox

(defun prrr-db-outbox-rows (&optional pr-id)
  "Return the queued writes of PR-ID, or of every PR when nil, oldest first.
Rows are `prrr-outbox' structs ordered by id, which the Outbox makes
increase with time."
  (mapcar (lambda (row) (prrr-db--row-to-struct 'outbox row))
          (if pr-id
              (emacsql (prrr-db) [:select * :from outbox :where (= pr-id $s1)
                                  :order-by [(asc id)]]
                       pr-id)
            (emacsql (prrr-db) [:select * :from outbox :order-by [(asc id)]]))))

(defun prrr-db-outbox-clear-errors (&optional pr-id)
  "Forget the last error of every queued write of PR-ID, or of every PR when nil.
Their attempts count is kept."
  (if pr-id
      (emacsql (prrr-db) [:update outbox :set (= last-error $s1) :where (= pr-id $s2)]
               nil pr-id)
    (emacsql (prrr-db) [:update outbox :set (= last-error $s1)] nil)))

(defun prrr-db--rename (tree renames)
  "Return a copy of TREE in which each string that is a key of RENAMES is replaced.
RENAMES is an alist from old to new string; TREE is built of conses and atoms."
  (cond ((stringp tree) (or (cdr (assoc tree renames)) tree))
        ((consp tree) (cons (prrr-db--rename (car tree) renames)
                            (prrr-db--rename (cdr tree) renames)))
        (t tree)))

(defun prrr-db--rename-outbox-ids (pr-id renames)
  "Replace the ids in RENAMES in the payloads of PR-ID's queued writes.
RENAMES is an alist from local id to GitHub's id.  Runs inside the
caller's transaction."
  (when renames
    (dolist (row (prrr-db-outbox-rows pr-id))
      (let ((payload (prrr-db--rename (prrr-outbox-payload row) renames)))
        (unless (equal payload (prrr-outbox-payload row))
          (setf (prrr-outbox-payload row) payload)
          (prrr-db-insert row))))))

(cl-defun prrr-db-outbox-done (id &key insert delete renames)
  "Record that GitHub accepted the queued write ID, in one transaction.
The write's row leaves the `outbox' table.  DELETE lists (TABLE . PLIST)
pairs, each deleting the rows `prrr-db-delete' would; then the structs
in INSERT are stored.  RENAMES, an alist from local id to GitHub's id,
is applied to the payloads of the PR's other queued writes, so a write
that needs what this one created now names it as GitHub does."
  (let ((db (prrr-db))
        (row (prrr-db-get 'outbox id)))
    (emacsql-with-transaction db
      (prrr-db-delete 'outbox :id id)
      (pcase-dolist (`(,table . ,plist) delete)
        (apply #'prrr-db-delete table plist))
      (mapc #'prrr-db-insert insert)
      (when row
        (prrr-db--rename-outbox-ids (prrr-outbox-pr-id row) renames)))
    nil))

(provide 'prrr-db)
;;; prrr-db.el ends here
