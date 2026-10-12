;;; prrr-api.el --- Agent API: read and write a review without a buffer  -*- lexical-binding: t -*-

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

;; SPEC section 10.  Public functions an agent calls in process or
;; through `emacsclient -e'.  Each takes a PR designator: a
;; `forge-pullreq', or (REPO . NUMBER) with REPO a `forge-repository'
;; or "OWNER/NAME" on github.com.  Reads return alists whose keys are
;; the JSON keys `prrr-api-export' writes; writes go through the
;; Outbox like the Review Buffer's.  Nothing here needs a buffer.
;;
;; A Range designator is nil or (default), a `prrr-range',
;; \(since-review), (since-opened), (commit OID) or (between FROM TO).
;; Unlike the Review Buffer, the API never fetches: a Range whose
;; commits are not in the repository is a `user-error'.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'magit)
(require 'forge)
(require 'prrr-db)
(require 'prrr-github)
(require 'prrr-state)
(require 'prrr-sync)
(require 'prrr-queue)
(require 'prrr-diff)

;;;; Designators

(cl-defstruct (prrr-api--context (:constructor prrr-api--context-create) (:copier nil))
  "A PR resolved for the API: forge's objects, its worktree and commits.
HEAD is the local commit of refs/pullreqs/NUMBER; MERGE-BASE that of
the PR's base commit and HEAD, or nil when the base is not local."
  pullreq repo directory head merge-base)

(defun prrr-api--repository (repo)
  "Return the forge repository REPO designates, or signal a `user-error'.
REPO is a `forge-repository' or \"OWNER/NAME\" of a repository on
github.com that forge tracks."
  (or (cond ((cl-typep repo 'forge-repository) repo)
            ((and (stringp repo) (string-match "\\`\\([^/ ]+\\)/\\([^/ ]+\\)\\'" repo))
             (forge-get-repository (list "github.com" (match-string 1 repo) (match-string 2 repo))
                                   nil :tracked?)))
      (user-error "Forge tracks no repository %S" repo)))

(defun prrr-api--pullreq (pr)
  "Return forge's pull request for the designator PR, or signal a `user-error'."
  (pcase pr
    ((pred (lambda (x) (cl-typep x 'forge-pullreq))) pr)
    (`(,repo . ,(and number (pred natnump)))
     (let ((repository (prrr-api--repository repo)))
       (or (forge-get-pullreq repository number)
           (user-error "Forge knows no pull request #%d of %s/%s; run `forge-pull'"
                       number (oref repository owner) (oref repository name)))))
    (_ (user-error "Not a pull request: %S (use (\"OWNER/NAME\" . NUMBER))" pr))))

(defun prrr-api--context (pr)
  "Resolve the designator PR into a `prrr-api--context'.
Signal a `user-error' when forge knows no worktree of its repository
or the PR's head has not been fetched."
  (let* ((pullreq (prrr-api--pullreq pr))
         (repo (forge-get-repository pullreq))
         (directory (or (forge-get-worktree repo)
                        (user-error "No worktree of %s/%s is known; visit it in magit once"
                                    (oref repo owner) (oref repo name))))
         (default-directory directory)
         (ref (format "refs/pullreqs/%d" (oref pullreq number)))
         (head (or (magit-rev-verify ref)
                   (user-error "%s is missing; run `forge-pull'" ref))))
    (prrr-api--context-create :pullreq pullreq :repo repo :directory directory :head head
                              :merge-base (prrr-diff-pullreq-merge-base pullreq head))))

(defmacro prrr-api--in (context &rest body)
  "Run BODY in CONTEXT's worktree."
  (declare (indent 1) (debug t))
  `(let ((default-directory (prrr-api--context-directory ,context)))
     ,@body))

(defun prrr-api--pr-id (context)
  "Return the node id of CONTEXT's pull request."
  (oref (prrr-api--context-pullreq context) their-id))

;;;; Ranges

(defun prrr-api--range (context range)
  "Return RANGE, a Range designator, as a `prrr-range' for CONTEXT.
RANGE is nil or (default), a `prrr-range', (since-review),
\(since-opened), (commit OID) or (between FROM TO).  Signal a
`user-error' for anything else, or when RANGE's start is unknown."
  (let ((pr-id (prrr-api--pr-id context)))
    (pcase range
      ((or 'nil '(default)) (prrr-range-create :kind 'default))
      ((pred prrr-range-p) range)
      ('(since-review)
       (prrr-range-create
        :kind 'since-review
        :start (or (prrr-state-since-review-start (prrr-db-get 'pullreq-meta pr-id))
                   (user-error "No submitted review of yours is known for this pull request"))))
      ('(since-opened)
       (prrr-range-create
        :kind 'since-opened
        :start (or (when-let* ((bookmark (prrr-db-get 'pr-bookmark pr-id)))
                     (prrr-bookmark-last-opened-head-oid bookmark))
                   (user-error "This pull request has no Bookmark yet"))))
      (`(commit ,(and oid (pred stringp)))
       (prrr-api--in context
         (unless (magit-commit-p oid)
           (user-error "Commit %s is not in the repository" oid))
         (prrr-range-create :kind 'commit :end oid
                            :start (or (magit-rev-parse (concat oid "^"))
                                       (user-error "Commit %s has no parent" oid)))))
      (`(between ,(and from (pred stringp)) ,(and to (pred stringp)))
       (prrr-range-create :kind 'between :start from :end to))
      (_ (user-error "Not a Range: %S" range)))))

(defun prrr-api--ends (context range)
  "Return (START . END), the commits RANGE designates in CONTEXT.
Signal a `user-error' when either is not in the repository: the
Review Buffer fetches missing commits, the API does not."
  (let ((ends (prrr-state-range-ends (prrr-api--range context range)
                                     (prrr-api--context-merge-base context)
                                     (prrr-api--context-head context))))
    (prrr-api--in context
      (dolist (oid (list (car ends) (cdr ends)))
        (unless (and oid (magit-commit-p oid))
          (user-error (concat "Commit %s is not in the repository;"
                              " show this Range in the Review Buffer once to fetch it")
                      (or oid "(merge base)")))))
    ends))

;;;; Alists

(defun prrr-api--side (side)
  "Return SIDE, `left' or `right', as the JSON side \"old\" or \"new\"."
  (pcase side ('left "old") ('right "new")))

(defun prrr-api--comment-alist (comment)
  "Return COMMENT, a `prrr-comment', as an alist."
  `((comment_id . ,(prrr-comment-comment-id comment))
    (database_id . ,(prrr-comment-database-id comment))
    (author . ,(prrr-comment-author comment))
    (body . ,(prrr-comment-body comment))
    (at . ,(prrr-comment-created-at comment))
    (state . ,(symbol-name (prrr-comment-state comment)))
    (local_state . ,(symbol-name (or (prrr-comment-local-state comment) 'sent)))
    (agent . ,(and (prrr-comment-agent-p comment) t))))

(defun prrr-api--thread-alist (thread comments)
  "Return THREAD with its COMMENTS, oldest first, as an alist.
start_line equals end_line for a one-line Thread; both are nil for a
File Comment or an outdated Thread without a line."
  (let ((line (prrr-thread-line thread)))
    `((thread_id . ,(prrr-thread-thread-id thread))
      (type . ,(if (eq (prrr-thread-subject-type thread) 'file) "file" "line"))
      (file . ,(prrr-thread-path thread))
      (start_line . ,(or (prrr-thread-start-line thread) line))
      (end_line . ,line)
      (side . ,(prrr-api--side (prrr-thread-side thread)))
      (outdated . ,(and (prrr-thread-outdated-p thread) t))
      (resolved . ,(and (prrr-thread-resolved-p thread) t))
      (comments . ,(mapcar #'prrr-api--comment-alist comments)))))

(defun prrr-api--review-data (context)
  "Return CONTEXT's review data with its queued writes applied.
The plist is as `prrr-sync-review-data' returns."
  (prrr-sync-review-data (prrr-api--pr-id context)))

(defun prrr-api--threads (data)
  "Return the thread alists of review DATA, in stored order."
  (let ((comments (plist-get data :comments)))
    (mapcar (lambda (thread)
              (prrr-api--thread-alist
               thread (seq-filter (lambda (c) (equal (prrr-comment-thread-id c)
                                                      (prrr-thread-thread-id thread)))
                                  comments)))
            (plist-get data :threads))))

;;;; Reads

;;;###autoload
(defun prrr-api-threads (pr &optional range)
  "Return the Threads of PR with their comments, as alists.
PR is a pull request designator (see the Commentary).  With RANGE, a
Range designator, keep only the Threads on files the Range changes.
Queued comments are included with local_state \"unsent\" (or
\"proposed\")."
  (let* ((context (prrr-api--context pr))
         (threads (prrr-api--threads (prrr-api--review-data context))))
    (if (null range)
        threads
      (let* ((ends (prrr-api--ends context range))
             (files (prrr-api--in context
                      (magit-git-lines "diff" "--name-only" "-M" (car ends) (cdr ends)))))
        (seq-filter (lambda (thread) (member (alist-get 'file thread) files)) threads)))))

;;;###autoload
(defun prrr-api-diff (pr &optional range file)
  "Return the unified diff of PR for RANGE, or of FILE only, as a string.
PR is a pull request designator and RANGE a Range designator, the
default Range when nil (see the Commentary)."
  (let* ((context (prrr-api--context pr))
         (ends (prrr-api--ends context range)))
    (prrr-api--in context
      (with-temp-buffer
        (apply #'magit-git-insert "diff" "--no-ext-diff" "--no-color" "-M" (car ends) (cdr ends)
               (and file (list "--" file)))
        (buffer-string)))))

;;;###autoload
(defun prrr-api-pending (pr)
  "Return PR's Pending Review: its review_id, commit, body and comments.
PR is a pull request designator (see the Commentary).  Each comment
alist also names its thread_id, file, end_line and side."
  (let* ((context (prrr-api--context pr))
         (data (prrr-api--review-data context))
         (review (plist-get data :pending-review))
         (threads (plist-get data :threads)))
    `((review_id . ,(and review (prrr-pending-review-review-id review)))
      (commit . ,(and review (prrr-pending-review-commit-oid review)))
      (body . ,(or (and review (prrr-pending-review-body review)) ""))
      (comments
       . ,(delq nil
                (mapcar
                 (lambda (comment)
                   (when (eq (prrr-comment-state comment) 'pending)
                     (let ((thread (seq-find (lambda (thread)
                                               (equal (prrr-thread-thread-id thread)
                                                      (prrr-comment-thread-id comment)))
                                             threads)))
                       (append (prrr-api--comment-alist comment)
                               `((thread_id . ,(prrr-comment-thread-id comment))
                                 (file . ,(and thread (prrr-thread-path thread)))
                                 (end_line . ,(and thread (prrr-thread-line thread)))
                                 (side . ,(and thread
                                               (prrr-api--side (prrr-thread-side thread)))))))))
                 (plist-get data :comments)))))))

;;;###autoload
(defun prrr-api-pullreq (pr)
  "Return a summary of PR as an alist: identity, commits, Review State, counts.
PR is a pull request designator (see the Commentary).  pending counts
the Pending Review's comments, agent those of them an agent added,
unresolved the Threads not resolved."
  (let* ((context (prrr-api--context pr))
         (pullreq (prrr-api--context-pullreq context))
         (repo (prrr-api--context-repo context))
         (pr-id (prrr-api--pr-id context))
         (meta (prrr-db-get 'pullreq-meta pr-id))
         (data (prrr-api--review-data context))
         (pending (seq-filter (lambda (c) (eq (prrr-comment-state c) 'pending))
                              (plist-get data :comments)))
         (me (prrr-api--in context (prrr-github-viewer)))
         (state (and me (prrr-state-review-state
                         (prrr-queue-pr pullreq meta) meta me
                         (mapcar #'prrr-team-combined-slug (prrr-db-select 'team))))))
    `((repository . ,(format "%s/%s" (oref repo owner) (oref repo name)))
      (number . ,(oref pullreq number))
      (id . ,pr-id)
      (title . ,(oref pullreq title))
      (author . ,(oref pullreq author))
      (url . ,(forge-get-url pullreq))
      (draft . ,(and (oref pullreq draft-p) t))
      (base_ref . ,(oref pullreq base-ref))
      (head_ref . ,(oref pullreq head-ref))
      (head . ,(prrr-api--context-head context))
      (merge_base . ,(prrr-api--context-merge-base context))
      (review_state . ,(and state (symbol-name state)))
      (pending . ,(length pending))
      (agent . ,(seq-count #'prrr-comment-agent-p pending))
      (unresolved . ,(seq-count (lambda (thread) (not (prrr-thread-resolved-p thread)))
                                (plist-get data :threads))))))

(provide 'prrr-api)
;;; prrr-api.el ends here
