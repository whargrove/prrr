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

;;;; Writes

(defcustom prrr-agent-comment-mode 'pending
  "Where comments an agent adds through the API go.
`pending': straight to the Pending Review, flagged as the agent's.
`proposed': kept local until you accept (\\[prrr-accept-comment]) or
reject each one."
  :type '(choice (const :tag "Pending Review" pending) (const :tag "Proposed" proposed))
  :group 'prrr)

(defcustom prrr-agent-comment-prefix ""
  "Text put before the body of every comment an agent writes."
  :type 'string
  :group 'prrr)

(defcustom prrr-api-confirm-submit t
  "Non-nil means `prrr-api-submit' asks you before it submits."
  :type 'boolean
  :group 'prrr)

(defun prrr-api--normalize-side (side)
  "Return SIDE, a symbol or JSON string, as `left' or `right'."
  (pcase side
    ((or 'nil 'right "new" "right") 'right)
    ((or 'left "old" "left") 'left)
    (_ (user-error "Not a side: %S (use \"new\" or \"old\")" side))))

(defun prrr-api--hunks (context path side)
  "Return the (FIRST . LAST) line ranges PATH's hunks cover on SIDE in CONTEXT.
SIDE `left' reads the old lines of each hunk, `right' the new ones."
  (prrr-api--in context
    (let (hunks)
      (dolist (line (magit-git-lines "diff" "--no-ext-diff" "--no-color" "-M"
                                     (prrr-api--context-merge-base context)
                                     (prrr-api--context-head context) "--" path))
        (when (string-match "^@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"
                            line)
          (let* ((old (eq side 'left))
                 (first (string-to-number (match-string (if old 1 3) line)))
                 (count (if (match-string (if old 2 4) line)
                            (string-to-number (match-string (if old 2 4) line))
                          1)))
            (when (> count 0)
              (push (cons first (+ first count -1)) hunks)))))
      (nreverse hunks))))

(cl-defun prrr-api--anchor (context path line &key start-line side file)
  "Return the anchor of a new comment on PATH in CONTEXT.
Signal a `user-error' when the comment cannot go there.
LINE, START-LINE, SIDE and FILE are as in `prrr-api-add-comment'.  The
anchor has the keys and order `prrr-state-anchor' gives the Review
Buffer's comments, so both queue the same write for the same line."
  (let* ((side (prrr-api--normalize-side side))
         (anchor (if file
                     (prrr-state-file-anchor path)
                   (unless (natnump line) (user-error "A line comment needs a line number"))
                   ;; GitHub refuses startLine > line only when the write is sent.
                   (when (and start-line (> start-line line))
                     (user-error "START-LINE must not come after LINE: %d is after %d"
                                 start-line line))
                   (append (list :path path :line line :side side)
                           (and start-line (/= start-line line)
                                (list :start-line start-line :start-side side))
                           (list :subject-type 'line)))))
    (when-let* ((problem (prrr-state-anchor-problem (prrr-range-create :kind 'default) anchor)))
      (user-error "%s" problem))
    (let ((hunks (prrr-api--hunks context path side)))
      (unless hunks
        (user-error "%s is not changed by this pull request" path))
      (unless file
        (let ((first (or start-line line)))
          (unless (seq-find (lambda (hunk) (and (<= (car hunk) (min first line))
                                                (<= (max first line) (cdr hunk))))
                            hunks)
            (user-error "%s:%d is not in the diff; %s lines in the diff: %s"
                        path line (if (eq side 'left) "old" "new")
                        (mapconcat (lambda (hunk) (format "%d-%d" (car hunk) (cdr hunk)))
                                   hunks ", "))))))
    anchor))

(defun prrr-api--sync-write (context kind payload)
  "Queue the write KIND with PAYLOAD for CONTEXT's pull request.
Run in CONTEXT's worktree, where `prrr-github-viewer' finds the login.
Return what `prrr-sync-write' returns."
  (prrr-api--in context
    (prrr-sync-write (prrr-api--context-repo context) (prrr-api--context-pullreq context)
                     kind payload)))

(defun prrr-api--write (context kind payload)
  "Queue the agent's write KIND with PAYLOAD for CONTEXT.
Return the local id of the comment it creates.
KIND is `thread' or `reply'.  The body gets `prrr-agent-comment-prefix'
and the write the agent flag; in `proposed' mode it is queued as a
proposal (`prrr-agent-comment-mode')."
  (let* ((payload (append (list :body (concat prrr-agent-comment-prefix (plist-get payload :body))
                                :agent t)
                          payload))
         (row (if (eq prrr-agent-comment-mode 'proposed)
                  (prrr-api--sync-write context 'proposed (append (list :as kind) payload))
                (prrr-api--sync-write context kind payload))))
    (plist-get (prrr-outbox-payload row) :comment)))

(defun prrr-api--check-commit (context data)
  "Signal a `user-error' when DATA's Pending Review is not on CONTEXT's head.
DATA is CONTEXT's review data."
  (when-let* ((problem (prrr-state-review-commit-problem (prrr-state-review-commit data)
                                                         (prrr-api--context-head context))))
    (user-error "%s" problem)))

;;;###autoload
(cl-defun prrr-api-add-comment (pr path line body &key start-line side file)
  "Add BODY as a new Thread on PATH at LINE of PR, as an agent comment.
PR is a pull request designator.  START-LINE makes it a multi-line
comment ending at LINE; SIDE is \"new\" (default) or \"old\", or the
symbols `right' and `left'.  With FILE non-nil it is a File Comment
and LINE is ignored.  Lines must lie in the pull request's diff.
Return the comment's local id; GitHub's id replaces it once sent."
  (let* ((context (prrr-api--context pr))
         (anchor (prrr-api--anchor context path line :start-line start-line :side side :file file)))
    (prrr-api--check-commit context (prrr-api--review-data context))
    (prrr-api--write context 'thread (list :anchor anchor :body body
                                           :commit (prrr-api--context-head context)))))

;;;###autoload
(defun prrr-api-reply (pr thread-id body)
  "Reply BODY to the Thread THREAD-ID of PR, as an agent comment.
Return the reply's local id."
  (let* ((context (prrr-api--context pr))
         (data (prrr-api--review-data context)))
    (unless (seq-find (lambda (thread) (equal (prrr-thread-thread-id thread) thread-id))
                      (plist-get data :threads))
      (user-error "PR has no Thread %s" thread-id))
    (prrr-api--write context 'reply (list :thread-id thread-id :body body
                                          :commit (prrr-api--context-head context)))))

;;;###autoload
(defun prrr-api-delete-pending-comment (pr comment-id)
  "Delete the comment COMMENT-ID from PR's Pending Review.
Only the viewer's pending comments, queued or sent, can be deleted.
Return t."
  (let* ((context (prrr-api--context pr))
         (comment (seq-find (lambda (c) (equal (prrr-comment-comment-id c) comment-id))
                            (plist-get (prrr-api--review-data context) :comments))))
    (unless (and comment (eq (prrr-comment-state comment) 'pending)
                 (equal (prrr-comment-author comment) (prrr-api--in context (prrr-github-viewer))))
      (user-error "No pending comment %s of yours" comment-id))
    (prrr-api--sync-write context 'delete (list :comment-id comment-id))
    t))

(defun prrr-api--verdict (verdict)
  "Return VERDICT, a symbol or string, as a Verdict symbol.
That is `approve', `request-changes' or `comment'."
  (pcase verdict
    ((or 'approve "approve") 'approve)
    ((or 'request-changes "request-changes" "request_changes") 'request-changes)
    ((or 'comment "comment") 'comment)
    (_ (user-error "Not a Verdict: %S (approve, request-changes or comment)" verdict))))

;;;###autoload
(defun prrr-api-submit (pr verdict &optional body)
  "Submit PR's Pending Review with VERDICT and BODY.
VERDICT is `approve', `request-changes' or `comment' (or a string).
Unless `prrr-api-confirm-submit' is nil, ask the user first, showing
the counts of pending and agent comments.  Return t when queued, nil
when the user declined."
  (let* ((context (prrr-api--context pr))
         (verdict (prrr-api--verdict verdict))
         (body (or body ""))
         (pending (seq-filter (lambda (c) (eq (prrr-comment-state c) 'pending))
                              (plist-get (prrr-api--review-data context) :comments)))
         (agents (seq-count #'prrr-comment-agent-p pending)))
    (when-let* ((problem (prrr-state-submit-problem verdict body (length pending))))
      (user-error "%s" problem))
    (when (or (not prrr-api-confirm-submit)
              (yes-or-no-p (format "An agent asks to Submit #%d (%s) with %d pending comment(s)%s. Submit? "
                                   (oref (prrr-api--context-pullreq context) number) verdict
                                   (length pending)
                                   (if (> agents 0) (format ", %d by an agent" agents) ""))))
      (prrr-api--sync-write context 'submit (list :verdict verdict :body body
                                                  :commit (prrr-api--context-head context)))
      (condition-case err
          (prrr-api--in context
            (prrr-sync-record-bookmark (prrr-api--context-pullreq context)
                                       (prrr-api--context-head context)))
        (error (message "prrr: could not record the Bookmark: %s" (error-message-string err))))
      t)))

(provide 'prrr-api)
;;; prrr-api.el ends here
