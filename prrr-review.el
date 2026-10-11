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
text.  A comment for the Pending Review is refused, and the capture
buffer kept, when that review is on another commit than the head shown
\(`prrr-state-review-commit-problem')."
  (let ((pullreq (prrr-diff-pullreq))
        (head (prrr-diff-head)))
    (prrr-comment-capture
     (prrr-state-anchor-label anchor)
     (lambda (text now)
       (unless now
         (when-let* ((problem (prrr-state-review-commit-problem
                               (prrr-state-review-commit
                                (prrr-sync-review-data (oref pullreq their-id)))
                               head)))
           (user-error "%s" problem)))
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

;;;; Submit and the Outbox

(defun prrr-review--pending (data)
  "Return the pending comments of the review DATA."
  (seq-filter (lambda (comment) (eq (prrr-comment-state comment) 'pending))
              (plist-get data :comments)))

(defun prrr-review--submit (verdict)
  "Capture a summary and submit the Pending Review with VERDICT.
VERDICT is `approve', `request-changes' or `comment'.  The header
counts the pending comments and those an agent wrote; Submit asks
again when there are agent comments (SPEC section 7).  Submitting
records the head shown as the Bookmark (SPEC section 8)."
  (let* ((pullreq (prrr-diff-pullreq))
         (head (prrr-diff-head))
         (pending (prrr-review--pending (prrr-sync-review-data (oref pullreq their-id))))
         (agents (seq-count #'prrr-comment-agent-p pending)))
    (prrr-comment-capture
     (format "Submit, %s: %d pending comment%s%s"
             (pcase verdict
               ('approve "approve")
               ('request-changes "request changes")
               ('comment "comment"))
             (length pending) (if (= (length pending) 1) "" "s")
             (if (> agents 0) (format ", %d by an agent" agents) ""))
     (lambda (text _now)
       (when-let* ((problem (prrr-state-submit-problem verdict text (length pending))))
         (user-error "%s" problem))
       (when (and (> agents 0)
                  (not (yes-or-no-p (format "Submit %d comment%s an agent wrote? "
                                            agents (if (= agents 1) "" "s")))))
         (user-error "Not submitted"))
       (prrr-review--write pullreq 'submit (list :verdict verdict :body text :commit head))
       ;; The Submit is queued: a failure from here on must not keep
       ;; the capture open, where confirming again would queue another.
       (when head
         (condition-case err
             (prrr-sync-record-bookmark pullreq head)
           (error (message "prrr: the Bookmark was not recorded: %s"
                           (error-message-string err))))))
     :immediate-allowed nil :allow-empty t)))

;;;###autoload
(defun prrr-submit-approve ()
  "Submit your Pending Review, approving the pull request."
  (interactive)
  (prrr-review--submit 'approve))

;;;###autoload
(defun prrr-submit-request-changes ()
  "Submit your Pending Review, requesting changes."
  (interactive)
  (prrr-review--submit 'request-changes))

;;;###autoload
(defun prrr-submit-comment ()
  "Submit your Pending Review as comments, without a Verdict for merging."
  (interactive)
  (prrr-review--submit 'comment))

;;;###autoload
(defun prrr-discard-pending ()
  "Discard your Pending Review and its comments, after confirmation."
  (interactive)
  (let* ((pullreq (prrr-diff-pullreq))
         (data (prrr-sync-review-data (oref pullreq their-id)))
         (count (length (prrr-review--pending data))))
    (unless (or (plist-get data :pending-review) (> count 0))
      (user-error "You have no Pending Review on this pull request"))
    (when (yes-or-no-p (format "Discard your Pending Review and its %d comment%s? "
                               count (if (= count 1) "" "s")))
      (prrr-review--write pullreq 'discard nil))))

;;;###autoload
(defun prrr-outbox-retry ()
  "Send this pull request's failed writes again now.
That includes a write GitHub never answered that a refetch could not
confirm, which only this command sends again."
  (interactive)
  (let ((pullreq (prrr-diff-pullreq)))
    (prrr-sync-resend (oref pullreq their-id) (current-buffer))
    (message "Sending the Outbox again")))

(defun prrr-review--read-write (data)
  "Return the id of one of the queued writes of the review DATA.
The write of the comment or Thread at point, else one read with
completion."
  (let* ((writes (plist-get data :writes))
         (at-point (or (let ((comment (prrr-diff-comment-at-point)))
                         (and comment (gethash (prrr-comment-comment-id comment) writes)))
                       (let ((thread (prrr-diff-thread-at-point)))
                         (and thread (gethash (prrr-thread-thread-id thread) writes))))))
    (if at-point
        (prrr-outbox-id at-point)
      (let ((choices (mapcar (lambda (row) (cons (prrr-state-outbox-describe row)
                                                 (prrr-outbox-id row)))
                             (or (plist-get data :outbox)
                                 (user-error "The Outbox of this pull request is empty")))))
        (cdr (assoc (completing-read "Discard write: " choices nil t) choices))))))

;;;###autoload
(defun prrr-outbox-discard (id)
  "Drop the queued write ID of this pull request, after confirmation.
Interactively, the write of the comment or Thread at point, else one
read with completion.  Writes that need what it creates go too."
  (interactive
   (list (prrr-review--read-write
          (prrr-sync-review-data (oref (prrr-diff-pullreq) their-id)))))
  (when (yes-or-no-p "Drop this unsent write? ")
    (let ((count (prrr-sync-discard id)))
      (message "Dropped %d write%s" count (if (eql count 1) "" "s")))))

(provide 'prrr-review)
;;; prrr-review.el ends here
