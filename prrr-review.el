;;; prrr-review.el --- Commenting and the Pending Review  -*- lexical-binding: t -*-

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

;; The Review Buffer's commands that write (SPEC sections 7 and 9):
;; comment on a line, a range or a file, reply, edit, delete, resolve,
;; suggest, post a Discussion Comment, submit the Pending Review with
;; a Verdict or discard it, and act on the Outbox.  Each command reads
;; what is at point from `prrr-diff', asks for the text in a capture
;; buffer from `prrr-thread', and hands the write to the Outbox
;; (`prrr-sync-write'), which shows it at once and sends it in the
;; background.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'transient)
(require 'forge)
(require 'prrr-db)
(require 'prrr-state)
(require 'prrr-github)
(require 'prrr-sync)
(require 'prrr-thread)
(require 'prrr-diff)

(defun prrr-review--immediate-p (arg)
  "Non-nil when a comment command should publish at once.
That is when ARG, its prefix argument, is non-nil, or when it was run
from `prrr-menu' with the -i switch on (SPEC section 9)."
  (or (and arg t)
      (and (eq transient-current-command 'prrr-menu)
           (transient-arg-value "--immediate" (transient-args 'prrr-menu)))))

(defun prrr-review--write (pullreq kind payload)
  "Hand the write KIND with PAYLOAD to PULLREQ to the Outbox.
The current buffer refreshes as the write goes out."
  (prrr-sync-write (forge-get-repository pullreq) pullreq kind payload (current-buffer)))

(defun prrr-review--comment-on (anchor immediate body)
  "Capture a comment on ANCHOR and send it as a new Thread.
IMMEDIATE is the initial choice of Immediate Publish; BODY the initial
text."
  (let ((pullreq (prrr-diff-pullreq))
        (head (prrr-diff-head)))
    (prrr-comment-capture
     (prrr-state-anchor-label anchor)
     (lambda (text now)
       (prrr-review--write pullreq (if now 'publish 'thread)
                           (list :anchor anchor :body text :commit head)))
     :body body :immediate immediate)))

;;;###autoload
(defun prrr-comment (immediate)
  "Comment on the diff line at point, or on the region's lines.
The comment joins your Pending Review.  With IMMEDIATE, interactively
a prefix argument or the -i switch of `prrr-menu', it is published at
once; the capture buffer can switch either way."
  (interactive (list (prrr-review--immediate-p current-prefix-arg)))
  (prrr-review--comment-on (prrr-diff-anchor) immediate nil))

;;;###autoload
(defun prrr-comment-file (immediate)
  "Comment on the file at point as a whole: a File Comment.
IMMEDIATE is as for `prrr-comment'."
  (interactive (list (prrr-review--immediate-p current-prefix-arg)))
  (prrr-review--comment-on (prrr-diff-file-anchor) immediate nil))

;;;###autoload
(defun prrr-comment-suggest (immediate)
  "Suggest a change to the line at point, or to the region's lines.
The capture buffer starts with a suggestion block holding the lines,
to edit into what they should be.  IMMEDIATE is as for `prrr-comment'."
  (interactive (list (prrr-review--immediate-p current-prefix-arg)))
  (let ((anchor (prrr-diff-anchor))
        (lines (prrr-diff-region-lines)))
    (unless lines
      (user-error "No diff lines to suggest a change to"))
    (prrr-review--comment-on anchor immediate (prrr-state-suggestion-body lines))))

(defun prrr-review--thread ()
  "Return the Thread at point, or signal a `user-error'."
  (or (prrr-diff-thread-at-point) (user-error "No Thread here")))

;;;###autoload
(defun prrr-reply (immediate)
  "Reply to the Thread at point.
The reply joins your Pending Review; IMMEDIATE is as for `prrr-comment'."
  (interactive (list (prrr-review--immediate-p current-prefix-arg)))
  (let ((pullreq (prrr-diff-pullreq))
        (thread (prrr-review--thread)))
    (prrr-comment-capture
     (format "Reply on %s" (prrr-thread-label thread))
     (lambda (text now)
       (prrr-review--write pullreq (if now 'publish-reply 'reply)
                           (list :thread-id (prrr-thread-thread-id thread) :body text)))
     :immediate immediate)))

(defun prrr-review--own-comment ()
  "Return your comment at point, or signal a `user-error'."
  (let ((comment (or (prrr-diff-comment-at-point) (user-error "No comment here"))))
    (unless (equal (prrr-comment-author comment) (prrr-github-viewer))
      (user-error "Only your own comments can be changed"))
    comment))

;;;###autoload
(defun prrr-edit-comment ()
  "Edit your comment at point, pending or submitted."
  (interactive)
  (let ((pullreq (prrr-diff-pullreq))
        (comment (prrr-review--own-comment)))
    (prrr-comment-capture
     "Edit your comment"
     (lambda (text _now)
       (prrr-review--write pullreq 'edit (list :comment-id (prrr-comment-comment-id comment)
                                               :body text)))
     :body (prrr-comment-body comment) :immediate-allowed nil)))

;;;###autoload
(defun prrr-delete-comment ()
  "Delete your comment at point, pending or submitted, after confirmation."
  (interactive)
  (let ((pullreq (prrr-diff-pullreq))
        (comment (prrr-review--own-comment)))
    (when (y-or-n-p "Delete this comment? ")
      (prrr-review--write pullreq 'delete
                          (list :comment-id (prrr-comment-comment-id comment))))))

;;;###autoload
(defun prrr-discussion-comment ()
  "Write a Discussion Comment on the pull request; it is published at once."
  (interactive)
  (let ((pullreq (prrr-diff-pullreq)))
    (prrr-comment-capture
     (format "Discussion Comment on #%d" (oref pullreq number))
     (lambda (text _now) (prrr-review--write pullreq 'discussion (list :body text)))
     :immediate t :immediate-allowed nil)))

;;;###autoload
(defun prrr-toggle-resolved ()
  "Resolve the Thread at point, or unresolve it."
  (interactive)
  (let* ((pullreq (prrr-diff-pullreq))
         (thread (prrr-review--thread))
         (resolved (prrr-thread-resolved-p thread)))
    (cond ((prrr-state-local-id-p (prrr-thread-thread-id thread))
           (user-error "This Thread is not on GitHub yet"))
          ((not (prrr-thread-resolvable-p thread))
           (user-error "GitHub does not let you %s this Thread"
                       (if resolved "unresolve" "resolve"))))
    (prrr-review--write pullreq 'resolve (list :thread-id (prrr-thread-thread-id thread)
                                               :resolved (not resolved)))))

(provide 'prrr-review)
;;; prrr-review.el ends here
