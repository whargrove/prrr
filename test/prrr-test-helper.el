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
(require 'prrr-db)

(defmacro prrr-db-with-test-db (&rest body)
  "Run BODY with `prrr-db' returning a fresh in-memory database."
  (declare (indent 0) (debug t))
  `(let ((prrr-db--connection (emacsql-sqlite-open nil)))
     (unwind-protect
         (progn (prrr-db--init prrr-db--connection) ,@body)
       (emacsql-close prrr-db--connection))))

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
