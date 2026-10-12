;;; prrr-agent.el --- Hand a review to an agent  -*- lexical-binding: t -*-

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

;; SPEC section 10, "Send to agent".  `prrr-send-to-agent' (`@' in the
;; Review Buffer) collects the pull request, the shown Range, its diff,
;; the Threads and the Pending Review into Markdown with the user's
;; instructions and calls `prrr-agent-invoke-function'.  The default
;; gives it to an agent-shell buffer of the repository when agent-shell
;; is loaded and copies it otherwise.  This is the one file that knows
;; about a particular agent; agent-shell is never required.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'magit)
(require 'prrr-api)
(require 'prrr-diff)
(require 'prrr-thread)

(declare-function agent-shell-insert "agent-shell" (&rest args))
(declare-function agent-shell-prompt-queue "agent-shell-prompt-queue" (prompt))
(declare-function shell-maker-busy "shell-maker" ())

(defcustom prrr-agent-invoke-function #'prrr-agent-invoke-default
  "Function that hands a review to an agent.
Called with MARKDOWN, the payload, and CONTEXT, a plist with :pullreq,
:directory (the repository's worktree) and :range (a `prrr-range')."
  :type 'function
  :group 'prrr)

(defcustom prrr-agent-max-diff-lines 2000
  "Most diff lines `prrr-send-to-agent' includes; the agent asks for the rest."
  :type 'natnum
  :group 'prrr)

;;;; The payload

(defun prrr-agent--range-form (range ends)
  "Return the Range designator form that names RANGE, whose commits are ENDS.
RANGE is a `prrr-range' and ENDS its (START . END).  The default Range
is nil; any other is written as the two commits it diffs."
  (if (eq (prrr-range-kind range) 'default)
      nil
    (list 'between (car ends) (cdr ends))))

(defun prrr-agent--summary (summary range ends)
  "Return the Markdown heading of SUMMARY, a `prrr-api-pullreq' alist.
RANGE is the `prrr-range' shown and ENDS its (START . END)."
  (let-alist summary
    (concat
     (format "# Pull request #%d: %s\n\n" .number .title)
     (format "- Repository: %s\n" .repository)
     (format "- Author: %s\n" .author)
     (format "- URL: %s\n" .url)
     (and .draft "- Draft\n")
     (format "- Head: %s (%s)\n" .head .head_ref)
     (format "- Base: %s, merge base %s\n" .base_ref .merge_base)
     (format "- Range: %s, %s..%s\n" (prrr-range-kind range) (car ends) (cdr ends))
     (format "- Review State: %s\n" (or .review_state "unknown")))))

(defun prrr-agent--how (designator range-form)
  "Return the Markdown that tells the agent how to answer.
DESIGNATOR is the printed PR designator and RANGE-FORM the printed
Range designator of the diff shown."
  (let ((call (lambda (form) (format "emacsclient -e '%s'\n" form))))
    (concat
     "## How to respond\n\n"
     "Answer through prrr's API in the user's Emacs, with `emacsclient -e`.  "
     (if (eq prrr-agent-comment-mode 'proposed)
         "Each comment you add is a proposal: the user accepts or rejects it.  "
       "Each comment you add joins the user's Pending Review, marked as an agent's.  ")
     "A line comment's lines must lie in the pull request's diff; side \"old\" "
     "comments on removed lines.\n\n"
     "```sh\n"
     "# Comment on a line\n"
     (funcall call (format "(prrr-api-add-comment (quote %s) \"path/file.el\" 42 \"Comment\")"
                           designator))
     "# Comment on lines 40 to 42\n"
     (funcall call (format "(prrr-api-add-comment (quote %s) \"path/file.el\" 42 \"Comment\" :start-line 40)"
                           designator))
     "# Comment on a line of the old side\n"
     (funcall call (format "(prrr-api-add-comment (quote %s) \"path/file.el\" 42 \"Comment\" :side \"old\")"
                           designator))
     "# Comment on a whole file\n"
     (funcall call (format "(prrr-api-add-comment (quote %s) \"path/file.el\" nil \"Comment\" :file t)"
                           designator))
     "# Reply to a Thread\n"
     (funcall call (format "(prrr-api-reply (quote %s) \"THREAD_ID\" \"Reply\")" designator))
     "# Read the Threads again\n"
     (funcall call (format "(prrr-api-threads (quote %s))" designator))
     "# Read one file's diff\n"
     (funcall call (format "(prrr-api-diff (quote %s) (quote %s) \"path/file.el\")"
                           designator range-form))
     "```\n\n"
     "Do not submit the review: the user reads your comments and submits it.\n")))

(defun prrr-agent--where (file line)
  "Return FILE and LINE as \"FILE:LINE\", or FILE alone when LINE is nil."
  (if line (format "%s:%d" file line) file))

(defun prrr-agent--pending (pending)
  "Return the Markdown of PENDING, a `prrr-api-pending' alist."
  (concat
   "## Pending Review\n\n"
   (if-let* ((comments (alist-get 'comments pending)))
       (mapconcat
        (lambda (comment)
          (let-alist comment
            (format "- %s (%s): %s\n" (prrr-agent--where .file .end_line)
                    (cond ((equal .local_state "proposed") "proposed")
                          (.agent "agent")
                          (t "user"))
                    .body)))
        comments "")
     "No comments yet.\n")))

(defun prrr-agent--thread-heading (thread)
  "Return where THREAD, a thread alist, is, as \"FILE:LINE\" or so."
  (let-alist thread
    (cond ((equal .type "file") (format "%s (file)" .file))
          ((null .end_line) (format "%s (outdated)" .file))
          ((and .start_line (/= .start_line .end_line))
           (format "%s:%d-%d" .file .start_line .end_line))
          (t (prrr-agent--where .file .end_line)))))

(defun prrr-agent--threads (threads)
  "Return the Markdown of THREADS, `prrr-api-threads' alists.
Unresolved Threads come first, with their comments; resolved ones
follow, one line each."
  (let ((resolved (seq-filter (lambda (thread) (alist-get 'resolved thread)) threads))
        (open (seq-remove (lambda (thread) (alist-get 'resolved thread)) threads)))
    (concat
     "## Threads\n\n"
     (if threads "" "No Threads yet.\n")
     (mapconcat
      (lambda (thread)
        (let-alist thread
          (concat (format "### %s\n\n" (prrr-agent--thread-heading thread))
                  (format "Thread %s%s%s\n\n" .thread_id
                          (if (equal .side "old") ", old side" "")
                          (if .outdated ", outdated" ""))
                  (mapconcat (lambda (comment)
                               (let-alist comment (format "**%s**: %s\n\n" .author .body)))
                             .comments ""))))
      open "")
     (and resolved "Resolved:\n\n")
     (mapconcat (lambda (thread)
                  (format "- %s, Thread %s, %d comment(s)\n"
                          (prrr-agent--thread-heading thread) (alist-get 'thread_id thread)
                          (length (alist-get 'comments thread))))
                resolved ""))))

(defun prrr-agent--diff (diff files)
  "Return the Markdown of DIFF, cut after `prrr-agent-max-diff-lines' lines.
FILES are the paths DIFF changes, named when it is cut."
  (let* ((lines (split-string (string-remove-suffix "\n" diff) "\n"))
         (cut (> (length lines) prrr-agent-max-diff-lines)))
    (concat "## Diff\n\n```diff\n"
            (string-join (if cut (seq-take lines prrr-agent-max-diff-lines) lines) "\n")
            "\n```\n"
            (and cut
                 (format (concat "\nThe diff cut after %d lines; call prrr-api-diff with a file"
                                 " for the rest.  Files changed: %s.\n")
                         prrr-agent-max-diff-lines (string-join files ", "))))))

(defun prrr-agent-markdown (pr range instructions)
  "Return the Markdown that hands PR's review to an agent.
PR is a pull request designator and RANGE a Range designator, as
`prrr-api-diff' takes them; INSTRUCTIONS is the user's text, left out
when empty.  In order: the summary, INSTRUCTIONS, how to answer
through the API, the Pending Review, the Threads and RANGE's diff,
cut after `prrr-agent-max-diff-lines' lines."
  (let* ((context (prrr-api--context pr))
         (pullreq (prrr-api--context-pullreq context))
         (summary (prrr-api-pullreq pullreq))
         (range-struct (prrr-api--range context range))
         (ends (prrr-api--ends context range))
         (designator (prin1-to-string (cons (alist-get 'repository summary)
                                            (alist-get 'number summary)))))
    (string-join
     (delq nil
           (list (prrr-agent--summary summary range-struct ends)
                 (and (not (string-empty-p (string-trim instructions)))
                      (concat "## Instructions\n\n" (string-trim instructions) "\n"))
                 (prrr-agent--how designator
                                  (prin1-to-string (prrr-agent--range-form range-struct ends)))
                 (prrr-agent--pending (prrr-api-pending pullreq))
                 (prrr-agent--threads (prrr-api-threads pullreq))
                 (prrr-agent--diff (prrr-api-diff pullreq range)
                                   (prrr-api--in context
                                     (magit-git-lines "diff" "--name-only" "-M"
                                                      (car ends) (cdr ends))))))
     "\n")))

;;;; Handing it over

(defun prrr-agent--shell (directory)
  "Return the agent-shell buffer to use for DIRECTORY, or nil.
Prefer shells whose directory is inside DIRECTORY; prompt when
several remain.  Nil when agent-shell is not loaded."
  (when (featurep 'agent-shell)
    (let* ((root (file-truename (file-name-as-directory directory)))
           (shells (seq-filter (lambda (buffer)
                                 (with-current-buffer buffer (derived-mode-p 'agent-shell-mode)))
                               (buffer-list)))
           (here (seq-filter (lambda (buffer)
                               (string-prefix-p root (file-truename
                                                      (buffer-local-value 'default-directory
                                                                          buffer))))
                             shells)))
      (pcase (or here shells)
        ('nil nil)
        (`(,only) only)
        (several (get-buffer (completing-read "Agent shell: " (mapcar #'buffer-name several)
                                              nil t)))))))

(defun prrr-agent-invoke-default (markdown context)
  "Give MARKDOWN to the repository's agent-shell, or copy it.
CONTEXT is the plist of `prrr-agent-invoke-function'.  A busy shell
queues MARKDOWN as its next prompt; an idle one gets it submitted.
Without agent-shell, MARKDOWN goes to the kill ring."
  (if-let* ((shell (prrr-agent--shell (or (plist-get context :directory) default-directory))))
      (progn
        (if (with-current-buffer shell (shell-maker-busy))
            (with-current-buffer shell (agent-shell-prompt-queue markdown))
          (agent-shell-insert :text markdown :submit t :shell-buffer shell))
        (display-buffer shell)
        (message "Sent the review to %s" (buffer-name shell)))
    (kill-new markdown)
    (message "No agent-shell: the review is in the kill ring")))

;;;###autoload
(defun prrr-send-to-agent ()
  "Send this pull request's review to an agent with your instructions.
Collects the summary, the shown Range and its diff, the Threads and
the Pending Review, and calls `prrr-agent-invoke-function'."
  (interactive)
  (let ((pullreq (prrr-diff-pullreq))
        (range (prrr-diff-range))
        (directory default-directory))
    (prrr-comment-capture
     "Instructions for the agent"
     (lambda (text _immediate)
       (funcall prrr-agent-invoke-function
                (prrr-agent-markdown pullreq range text)
                (list :pullreq pullreq :directory directory :range range)))
     :allow-empty t :immediate-allowed nil)))

(provide 'prrr-agent)
;;; prrr-agent.el ends here
