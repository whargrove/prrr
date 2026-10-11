;;; prrr-diff.el --- The Review Buffer  -*- lexical-binding: t -*-

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

;; The Review Buffer (SPEC section 6): one pull request's diff, from
;; its merge base to its head, with its Threads inline.  It renders
;; from local git and prrr's database, never from the network.
;;
;; Rendering is hybrid lazy.  One `git diff --raw --numstat' lists the
;; changed files, each a collapsed `file' section.  The first files,
;; within `prrr-eager-files' and `prrr-eager-lines', are washed at
;; once; every other file is washed on its first expansion through a
;; deferred section body.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'magit)
(require 'forge)
(require 'prrr-db)
(require 'prrr-state)

(defcustom prrr-eager-files 30
  "Most files washed when a Review Buffer opens.
The others are washed when first expanded."
  :type 'natnum
  :group 'prrr)

(defcustom prrr-eager-lines 2000
  "Most changed lines washed when a Review Buffer opens.
The first file that would pass this limit, or `prrr-eager-files', and
every file after it, are washed when first expanded."
  :type 'natnum
  :group 'prrr)

;;;; Changed files

(cl-defstruct (prrr-diff-file (:constructor prrr-diff-file-create) (:copier nil))
  "One changed file of a diff.
PATH is the file at head; ORIG the file at base when it was renamed or
copied, else nil.  STATUS is magit's word for the change: \"modified\",
\"new file\", \"deleted\", \"renamed\", \"copied\" or \"typechange\".
ADDED and DELETED count lines; both are 0 for a BINARY-P file."
  path orig status added deleted binary-p)

(defun prrr-diff--status-name (letter)
  "Return magit's word for git's status LETTER."
  (pcase letter
    (?A "new file")
    (?D "deleted")
    (?R "renamed")
    (?C "copied")
    (?T "typechange")
    (_ "modified")))

(defun prrr-diff-parse-changes (output)
  "Parse the OUTPUT of `git diff -z -M --raw --numstat' into `prrr-diff-file's.
Files come in git's order.  Git prints every raw record (status and
names) before the numstat records (line counts), in the same order."
  (let ((tokens (split-string output "\0"))
        (files nil)
        (counts nil))
    (while tokens
      (let ((token (pop tokens)))
        (cond
         ((string-prefix-p ":" token)
          (let* ((letter (aref (car (last (split-string token " "))) 0))
                 (orig (and (memq letter '(?R ?C)) (pop tokens))))
            (push (prrr-diff-file-create :path (pop tokens) :orig orig
                                         :status (prrr-diff--status-name letter))
                  files)))
         ((string-match "\\`\\([0-9]+\\|-\\)\t\\([0-9]+\\|-\\)\t" token)
          (when (= (match-end 0) (length token))
            ;; A rename or copy: its two names follow as tokens.
            (pop tokens)
            (pop tokens))
          (push (cons (match-string 1 token) (match-string 2 token)) counts)))))
    (cl-mapcar (lambda (file count)
                 (let ((binary (equal (car count) "-")))
                   (setf (prrr-diff-file-binary-p file) binary
                         (prrr-diff-file-added file)
                         (if binary 0 (string-to-number (car count)))
                         (prrr-diff-file-deleted file)
                         (if binary 0 (string-to-number (cdr count))))
                   file))
               (nreverse files) (nreverse counts))))

(defun prrr-diff--changes (base head)
  "Return the files changed from BASE to HEAD as `prrr-diff-file's."
  (prrr-diff-parse-changes
   (magit-git-output "diff" "--no-ext-diff" "-z" "-M" "--raw" "--numstat" base head)))

(defun prrr-diff--eager-paths (files viewed)
  "Return the paths among FILES to wash when the buffer opens.
FILES are `prrr-diff-file's in buffer order; the paths in VIEWED are
skipped.  Files are taken from the top until `prrr-eager-files' files
or `prrr-eager-lines' changed lines; the first file that would pass
either limit ends the run."
  (let ((count 0) (lines 0) (paths nil))
    (catch 'done
      (dolist (file files)
        (unless (member (prrr-diff-file-path file) viewed)
          (let ((size (+ (prrr-diff-file-added file) (prrr-diff-file-deleted file))))
            (when (or (>= count prrr-eager-files) (> (+ lines size) prrr-eager-lines))
              (throw 'done nil))
            (cl-incf count)
            (cl-incf lines size)
            (push (prrr-diff-file-path file) paths)))))
    paths))

(defun prrr-diff--merge-base (pullreq head)
  "Return the merge base of PULLREQ's base commit and HEAD, or nil.
nil when forge recorded no base commit or it is not in the repository."
  (when-let ((base-rev (oref pullreq base-rev)))
    (and (magit-rev-verify base-rev)
         (magit-git-string "merge-base" base-rev head))))

(provide 'prrr-diff)
;;; prrr-diff.el ends here
