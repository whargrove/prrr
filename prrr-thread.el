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
;; The capture buffer, `prrr-comment-mode', is here too: it takes a label and a
;; function to call with the text, so it never needs to know about the diff
;; (SPEC section 2).

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
  "Return the note on the queued write ROW.
\"  failed: \" and the error for a failed write; \"  waiting for
GitHub's answer\" for an unconfirmed one, which is unsent too
\(`prrr-state-outbox-unconfirmed-p'); nil for a proposal, which is
never sent (`prrr-state-outbox-held-p'); else \"  unsent\"."
  (cond
   ((prrr-state-outbox-held-p row) nil)
   ((prrr-outbox-last-error row)
    (propertize (concat "  failed: " (prrr-outbox-last-error row)) 'font-lock-face 'prrr-failed))
   (t
    (propertize (if (prrr-state-outbox-unconfirmed-p row)
                    "  waiting for GitHub's answer"
                  "  unsent")
                'font-lock-face 'prrr-unsent))))

(defun prrr-thread--write-note (id writes)
  "Return the note on the queued write of ID in WRITES, or nil.
WRITES is the :writes table of `prrr-state-outbox-view'; see
`prrr-thread--row-note' for the note."
  (when-let* ((row (and writes id (gethash id writes))))
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

(defun prrr-thread-insert-sent-post (body)
  "Insert the Discussion Comment BODY that GitHub accepted from the Outbox.
For one forge has not pulled yet (`prrr-sync-posted-discussion').  A
section of type `sent-post'; no command acts on it, since the Outbox
holds it no more."
  (magit-insert-section (sent-post)
    (magit-insert-heading
      prrr-thread-indent
      (propertize "Your Discussion Comment" 'font-lock-face 'prrr-comment-author)
      (propertize "  sent" 'font-lock-face 'magit-dimmed)
      "\n")
    (prrr-thread--insert-body body nil)))

(defun prrr-thread--heading (thread comments with-path writes)
  "Return the heading line of THREAD, which holds COMMENTS.
WITH-PATH non-nil puts the file before the location; WRITES is as for
`prrr-thread--write-note'."
  (let* ((resolved (prrr-thread-resolved-p thread))
         (count (length comments))
         (pending (seq-count #'prrr-state-comment-pending-p comments)))
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
      (and (prrr-state-comment-pending-p comment)
           (propertize "  pending" 'font-lock-face 'prrr-comment-pending))
      (and (prrr-comment-agent-p comment)
           (propertize "  agent" 'font-lock-face 'prrr-agent))
      (and (eq (prrr-comment-local-state comment) 'proposed)
           (propertize "  proposed" 'font-lock-face 'prrr-agent))
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
;;;; The capture buffer

(defvar-keymap prrr-comment-mode-map
  :doc "Keys of a buffer in which a comment is written."
  "C-c C-c" #'prrr-comment-confirm
  "C-c C-k" #'prrr-comment-abort
  "C-c C-i" #'prrr-comment-toggle-immediate)

(defalias 'prrr-comment--parent-mode
  (if (require 'markdown-mode nil t) 'gfm-mode 'text-mode)
  "The mode `prrr-comment-mode' derives from.
GitHub's Markdown mode when markdown-mode is installed, which forge
requires, else `text-mode'.")

(define-derived-mode prrr-comment-mode prrr-comment--parent-mode "prrr-comment"
  "Write a comment for prrr.
\\<prrr-comment-mode-map>\\[prrr-comment-confirm] sends the comment, \\[prrr-comment-abort] drops it.
\\[prrr-comment-toggle-immediate] switches between the Pending Review and
Immediate Publish.

\\{prrr-comment-mode-map}"
  :interactive nil
  :group 'prrr
  (setq-local header-line-format '(:eval (prrr-comment--header))))

(defvar-local prrr-comment--label nil
  "What the comment is about, as the header line says.")

(defvar-local prrr-comment--on-confirm nil
  "Function called with the text and the immediate choice on confirm.")

(defvar-local prrr-comment--immediate nil
  "Non-nil when the comment is published at once.")

(defvar-local prrr-comment--immediate-allowed t
  "Non-nil when the user may change `prrr-comment--immediate'.")

(defvar-local prrr-comment--allow-empty nil
  "Non-nil when an empty text may be confirmed.")

(defvar-local prrr-comment--origin nil
  "Marker where the capture was started.")

(defvar-local prrr-comment--section-position nil
  "Where in its magit section the capture was started, or nil.
A list (SECTION LINE CHAR) as `magit-section-goto-successor' takes.
The origin marker alone would not do: the Outbox redraws the Review
Buffer while the user writes, and a redraw erases the buffer, which
moves every marker in it to the top.")

(defvar-local prrr-comment--windows nil
  "The window configuration to restore when the capture ends.")

(defun prrr-comment--header ()
  "Return the header line of a capture buffer."
  (concat " " prrr-comment--label
          (and prrr-comment--immediate-allowed
               (if prrr-comment--immediate "  ·  publish now" "  ·  Pending Review"))
          (substitute-command-keys
           (concat "  ·  \\<prrr-comment-mode-map>\\[prrr-comment-confirm] send, "
                   "\\[prrr-comment-abort] cancel"
                   (and prrr-comment--immediate-allowed
                        ", \\[prrr-comment-toggle-immediate] publish now or later")))))

(cl-defun prrr-comment-capture (label on-confirm &key body immediate (immediate-allowed t)
                                      allow-empty)
  "Open a buffer to write a comment about LABEL, and return it.
LABEL says what the comment is about, as `prrr-state-anchor-label' or
`prrr-thread-label' do; the header line shows it.  BODY is the initial
text.  IMMEDIATE is the initial choice between the Pending Review (nil)
and Immediate Publish; IMMEDIATE-ALLOWED nil fixes it.  ALLOW-EMPTY
non-nil lets an empty text be confirmed.

On confirm, ON-CONFIRM is called with the trimmed text and the
immediate choice, in the buffer the capture started from; then the
capture buffer closes and the windows, with point where it was, come
back.  Point returns to the same place in the same magit section,
even when the buffer was redrawn meanwhile.  When ON-CONFIRM
signals, the capture buffer stays, so no text is lost."
  (let ((origin (point-marker))
        ;; magit's hunk method moves point while a region is active.
        (section-position (when-let* ((section (magit-section-at)))
                            (cons section (save-excursion
                                            (magit-section-get-relative-position section)))))
        (windows (current-window-configuration))
        (buffer (generate-new-buffer "*prrr comment*")))
    (with-current-buffer buffer
      (prrr-comment-mode)
      (setq prrr-comment--label label
            prrr-comment--on-confirm on-confirm
            prrr-comment--immediate immediate
            prrr-comment--immediate-allowed immediate-allowed
            prrr-comment--allow-empty allow-empty
            prrr-comment--origin origin
            prrr-comment--section-position section-position
            prrr-comment--windows windows)
      (when body
        (insert body)))
    (pop-to-buffer buffer '((display-buffer-in-side-window) (side . bottom)
                            (window-height . 0.3)))
    buffer))

(defun prrr-comment--close ()
  "Kill the current capture buffer and bring the windows back."
  (let ((windows prrr-comment--windows)
        (origin prrr-comment--origin)
        (section-position prrr-comment--section-position))
    (kill-buffer (current-buffer))
    (when windows
      (set-window-configuration windows))
    (when (and origin (buffer-live-p (marker-buffer origin)))
      (set-buffer (marker-buffer origin))
      (unless (and section-position
                   (apply #'magit-section-goto-successor section-position))
        (goto-char origin)))))

(defun prrr-comment-confirm ()
  "Send the comment of this buffer and close it."
  (interactive)
  (let ((text (string-trim (buffer-string)))
        (on-confirm prrr-comment--on-confirm)
        (immediate prrr-comment--immediate)
        (origin prrr-comment--origin))
    (when (and (string-empty-p text) (not prrr-comment--allow-empty))
      (user-error (substitute-command-keys
                   "Nothing to send; \\<prrr-comment-mode-map>\\[prrr-comment-abort] cancels")))
    (if (and origin (buffer-live-p (marker-buffer origin)))
        (with-current-buffer (marker-buffer origin)
          (funcall on-confirm text immediate))
      (funcall on-confirm text immediate))
    (prrr-comment--close)))

(defun prrr-comment-abort ()
  "Drop the comment of this buffer and close it."
  (interactive)
  (prrr-comment--close)
  (message "Comment dropped"))

(defun prrr-comment-toggle-immediate ()
  "Switch this comment between the Pending Review and Immediate Publish."
  (interactive)
  (unless prrr-comment--immediate-allowed
    (user-error "This one cannot switch between Pending Review and Immediate Publish"))
  (setq prrr-comment--immediate (not prrr-comment--immediate))
  (force-mode-line-update)
  (message (if prrr-comment--immediate
               "Publish at once"
             "Add to the Pending Review")))

(provide 'prrr-thread)
;;; prrr-thread.el ends here
