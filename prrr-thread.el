;;; prrr-thread.el --- Threads and Review Comments in the Review Buffer  -*- lexical-binding: t -*-

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

;; Renders one Thread, or File Comment, and its Review Comments as
;; magit sections (SPEC section 6).  The Review Buffer decides where a
;; Thread goes; this file decides how it looks.  A Thread section's
;; value is the Thread id and a comment section's value the comment
;; id, so a refetch that changes nothing else keeps their folds.
;; A comment or Thread the Outbox has not sent shows `unsent', or `failed:' and
;; GitHub's words; a suggestion block shows as a mini diff against the
;; anchored lines.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'magit-section)
(require 'magit-diff)
(require 'prrr-db)
(require 'prrr-state)

(defface prrr-thread-heading '((t :inherit magit-diff-hunk-heading :extend t))
  "Heading of an unresolved Thread or File Comment."
  :group 'prrr)

(defface prrr-thread-resolved '((t :inherit (shadow prrr-thread-heading)))
  "Heading of a resolved Thread."
  :group 'prrr)

(defface prrr-comment-author '((t :inherit magit-log-author))
  "Author of a Review Comment."
  :group 'prrr)

(defface prrr-comment-date '((t :inherit magit-log-date))
  "Date of a Review Comment."
  :group 'prrr)

(defface prrr-comment-pending '((t :inherit warning))
  "Marks a Review Comment that belongs to the Pending Review."
  :group 'prrr)

(defface prrr-unsent '((t :inherit shadow :slant italic))
  "Marks a comment or change GitHub has not accepted yet."
  :group 'prrr)

(defface prrr-failed '((t :inherit error))
  "Marks a comment or change GitHub refused or could not be sent."
  :group 'prrr)

(defface prrr-agent '((t :inherit font-lock-builtin-face))
  "Marks a comment an agent wrote through prrr's API."
  :group 'prrr)

(defface prrr-suggestion-heading '((t :inherit magit-diff-hunk-heading))
  "Heading of a suggested change inside a comment."
  :group 'prrr)


(defvar-keymap prrr-thread-section-map
  :doc "Keys on a Thread, a File Comment and their Review Comments.
RET visits the anchored line: magit's own RET cannot, because a Thread
is not part of the diff."
  "RET" #'prrr-thread-visit)

(defconst prrr-thread-indent "    "
  "Indentation of a Thread's lines, which sets them apart from diff lines.")

(defun prrr-thread--location (thread)
  "Describe where THREAD is anchored, such as \"line 12\" or \"lines 1-3, left\"."
  (let ((line (or (prrr-thread-line thread) (prrr-thread-original-line thread)))
        (start (prrr-thread-start-line thread)))
    (concat (cond ((eq (prrr-thread-subject-type thread) 'file) "file")
                  ((null line) "no line")
                  ((and start (/= start line)) (format "lines %d-%d" start line))
                  (t (format "line %d" line)))
            (and (eq (prrr-thread-side thread) 'left) ", left"))))

(defun prrr-thread-label (thread)
  "Describe where THREAD is, such as \"src/a.el, line 12\", for a header."
  (concat (prrr-thread-path thread) ", " (prrr-thread--location thread)))

(defun prrr-thread--row-note (row)
  "Return \"  unsent\", or \"  failed: \" and the error, for the queued write ROW."
  (if-let ((error (prrr-outbox-last-error row)))
      (propertize (concat "  failed: " error) 'font-lock-face 'prrr-failed)
    (propertize "  unsent" 'font-lock-face 'prrr-unsent)))

(defun prrr-thread--write-note (id writes)
  "Return the note on the queued write of ID in WRITES, or nil.
WRITES is the :writes table of `prrr-state-outbox-view'; see
`prrr-thread--row-note' for the note."
  (when-let ((row (and writes id (gethash id writes))))
    (prrr-thread--row-note row)))

(defun prrr-thread-insert-unsent-post (body row)
  "Insert the Discussion Comment BODY that the queued write ROW will post.
A section of type `unsent-post' whose value is ROW's id."
  (magit-insert-section (unsent-post (prrr-outbox-id row))
    (magit-insert-heading
      prrr-thread-indent
      (propertize "Your Discussion Comment" 'font-lock-face 'prrr-comment-author)
      (prrr-thread--row-note row)
      "\n")
    (prrr-thread--insert-body body nil)))

(defun prrr-thread--heading (thread comments with-path writes)
  "Return the heading line of THREAD, which holds COMMENTS.
WITH-PATH non-nil puts the file before the location; WRITES is as for
`prrr-thread--write-note'."
  (let* ((resolved (prrr-thread-resolved-p thread))
         (count (length comments))
         (pending (seq-count (lambda (comment) (eq (prrr-comment-state comment) 'pending))
                             comments)))
    (concat (propertize
             (concat prrr-thread-indent
                     (if (eq (prrr-thread-subject-type thread) 'file) "File comment" "Thread")
                     "  "
                     (and with-path (concat (prrr-thread-path thread) ", "))
                     (prrr-thread--location thread)
                     (format "  %d comment%s" count (if (= count 1) "" "s"))
                     (and resolved "  resolved")
                     (and (> pending 0) (format "  %d pending" pending)))
             'font-lock-face (if resolved 'prrr-thread-resolved 'prrr-thread-heading))
            (prrr-thread--write-note (prrr-thread-thread-id thread) writes)
            "\n")))

(defun prrr-thread--date (timestamp)
  "Return the date part of the ISO TIMESTAMP, or \"\"."
  (if (and timestamp (>= (length timestamp) 10)) (substring timestamp 0 10) ""))

(defun prrr-thread--insert-body (body lines)
  "Insert the comment BODY, its suggestions as mini diffs against LINES.
LINES are the text of the lines the Thread is anchored to, or nil."
  (dolist (part (prrr-state-split-suggestions (or body "")))
    (pcase part
      (`(text . ,text)
       (dolist (line (split-string text "\n"))
         (insert prrr-thread-indent "  " line "\n")))
      (`(suggestion . ,new)
       (insert prrr-thread-indent "  "
               (propertize "Suggested change:" 'font-lock-face 'prrr-suggestion-heading) "\n")
       (pcase-dolist (`(,char . ,line) (prrr-state-suggestion-diff lines new))
         (insert prrr-thread-indent "  "
                 (propertize (concat (string char) line)
                             'font-lock-face (pcase char
                                               (?- 'magit-diff-removed)
                                               (?+ 'magit-diff-added)
                                               (_ 'magit-diff-context)))
                 "\n"))))))

(defun prrr-thread--insert-comment (comment writes lines)
  "Insert COMMENT as a section of type `review-comment'.
WRITES is as for `prrr-thread--write-note'; LINES as for
`prrr-thread--insert-body'."
  (magit-insert-section section (review-comment (prrr-comment-comment-id comment))
    (oset section keymap 'prrr-thread-section-map)
    (magit-insert-heading
      prrr-thread-indent
      (propertize (or (prrr-comment-author comment) "ghost") 'font-lock-face 'prrr-comment-author)
      "  "
      (propertize (prrr-thread--date (prrr-comment-created-at comment))
                  'font-lock-face 'prrr-comment-date)
      (and (prrr-comment-updated-at comment) "  edited")
      (and (eq (prrr-comment-state comment) 'pending)
           (propertize "  pending" 'font-lock-face 'prrr-comment-pending))
      (and (prrr-comment-agent-p comment)
           (propertize "  agent" 'font-lock-face 'prrr-agent))
      (prrr-thread--write-note (prrr-comment-comment-id comment) writes)
      "\n")
    (prrr-thread--insert-body (prrr-comment-body comment) lines)))

(cl-defun prrr-thread-insert (thread comments &key with-path writes lines)
  "Insert THREAD and its COMMENTS, oldest first, as a section.
The section type is `file-comment' for a File Comment and `thread'
otherwise; its value is the Thread id and its children are one
`review-comment' section per comment.  A resolved Thread starts
hidden.  WITH-PATH non-nil names the file in the heading, for a Thread
shown away from its file.  WRITES, the :writes table of
`prrr-state-outbox-view', marks what GitHub has not accepted yet.
LINES, the text of the anchored lines, shows suggestions as mini
diffs against them."
  (magit-insert-section section ((eval (if (eq (prrr-thread-subject-type thread) 'file)
                                           'file-comment
                                         'thread))
                                 (prrr-thread-thread-id thread)
                                 (prrr-thread-resolved-p thread))
    (oset section keymap 'prrr-thread-section-map)
    (magit-insert-heading (prrr-thread--heading thread comments with-path writes))
    (dolist (comment comments)
      (prrr-thread--insert-comment comment writes lines))))

(defun prrr-thread--section-at-point ()
  "Return the `thread' or `file-comment' section around point, or nil."
  (let ((section (magit-current-section)))
    (while (and section (not (memq (oref section type) '(thread file-comment))))
      (setq section (oref section parent)))
    section))

(defun prrr-thread-visit ()
  "Visit the file line the Thread at point is anchored to.
A Thread inside a hunk visits the diff line it follows, through magit's
`magit-diff-visit-file'; any other Thread visits its file."
  (interactive)
  (let* ((section (or (prrr-thread--section-at-point) (user-error "No Thread here")))
         (parent (oref section parent))
         (file parent))
    (while (and file (not (eq (oref file type) 'file)))
      (setq file (oref file parent)))
    (unless file
      (user-error "This Thread's file is not in the diff"))
    (save-excursion
      (if (eq (oref parent type) 'hunk)
          (progn (goto-char (oref section start))
                 (forward-line -1)
                 ;; Several Threads can follow one diff line: step past
                 ;; them to the diff line itself.
                 (while (and (not (bobp)) (not (eq (magit-section-at) parent)))
                   (forward-line -1)))
        (goto-char (oref file start)))
      (call-interactively #'magit-diff-visit-file))))

(provide 'prrr-thread)
;;; prrr-thread.el ends here
