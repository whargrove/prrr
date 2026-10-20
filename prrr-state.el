;;; prrr-state.el --- Pure Review Queue rules for prrr  -*- lexical-binding: t -*-

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

;; Pure functions implementing SPEC.md section 5: the Review State of a
;; PR for the viewer, Queue Group membership, the Awaiting me / Served
;; partitions and their FIFO ordering, Stack detection, the final ordered
;; Review Queue, the display filters, and Stack neighbours.  Inputs are
;; `prrr-pr' (built by the caller from forge's object) and
;; `prrr-pr-meta' rows; there is no buffer, network or forge-object
;; access, so every rule is unit-tested with constructed structs.
;;
;; Where the Review Buffer shows each Thread is decided here too
;; (`prrr-state-thread-layout'), and so are the Range rules: which
;; commits a Range diffs, which of its lines take comments, how a line
;; number at one commit maps to another, and which PR is next in a
;; Stack.
;;
;; The Outbox's rules are here as well: which queued write goes next,
;; which writes depend on which, what a write leaves behind once
;; GitHub accepts it, and whether an unconfirmed write landed.
;; prrr-sync.el carries them out.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'parse-time)
(require 'prrr-db)

;;;; Structs

(cl-defstruct (prrr-pr (:constructor prrr-pr-create) (:copier nil))
  "A Pull Request as the Review Queue sees it.
ID is the GitHub node id (forge's `their-id'), which joins to
`prrr-pr-meta-pr-id'.  ASSIGNEES is a list of logins.  BASE-REF and
HEAD-REF are branch names, nil when the branch is gone.  CROSS-REPO-P
is non-nil for a PR from a fork.  HEAD-OID is forge's head-rev; the
Review State prefers the head stored in the PR's `prrr-pr-meta' (see
`prrr-state--head-oid').
ADDITIONS and DELETIONS are GitHub's line counts for the whole PR, nil
until a pull stored them."
  id number title author draft-p assignees created-at updated-at
  head-oid base-ref head-ref cross-repo-p additions deletions)

(cl-defstruct (prrr-queue-entry (:constructor prrr-queue-entry-create)
                                (:copier nil))
  "One row of the Review Queue.
PR is the `prrr-pr'.  STATE is the Review State (For Me) or Mine state,
nil for a dimmed context row.  GROUP is `for-me' or `mine'.  PARTITION
is `awaiting' or `served' in For Me, nil in Mine.  STACK-POS is the
1-based position of PR in its Stack, bottom first, and STACK-SIZE the
Stack's length (1 for a lone PR).  STACK-ID is the `id' of the Stack's
bottom PR, shared by every row of one Stack.  DIMMED-P marks a row
shown only for context: a non-qualifying Stack member or a draft
requested from me.  MUTED-P marks a muted PR shown on request
\(`prrr-state-filter-queue')."
  pr state group partition stack-pos stack-size stack-id dimmed-p muted-p)

;;;; Helpers over meta rows

(defun prrr-state--viewer-review (meta)
  "Return META's viewer-latest-review unless it is nil or still pending.
A Pending Review is not a touch, so it is ignored everywhere."
  (let ((review (and meta (prrr-pr-meta-viewer-latest-review meta))))
    (and review (not (equal (nth 0 review) "PENDING")) review)))

(defun prrr-state--requested-p (meta me)
  "Return non-nil when META holds a current review request for ME.
That is ME among the current review requests: GitHub removes a
request once it is answered, so this means an unanswered or renewed
request.  META's viewer-latest-review-request does not count: GitHub
sets it for a request to one of ME's Teams as well, and keeps it after
ME has reviewed (prrr-ah1)."
  (and meta
       (member (list 'user me) (prrr-pr-meta-review-requests meta))
       t))

(defun prrr-state--team-requests (meta teams)
  "Return the combined slugs of TEAMS that are requested on META."
  (cl-loop for (kind name) in (and meta (prrr-pr-meta-review-requests meta))
           when (and (eq kind 'team) (member name teams))
           collect name))

(defun prrr-state--teammate-reviews (meta me teams)
  "Return META's latest reviews by others than ME on behalf of one of TEAMS."
  (cl-loop for review in (and meta (prrr-pr-meta-latest-reviews meta))
           for (login _state _submitted-at _commit-oid slugs) = review
           when (and (not (equal login me))
                     (cl-intersection slugs teams :test #'equal))
           collect review))

;;;; Review State

(defconst prrr-state-for-me-order
  '(new-commits assigned requested team-requested teammate-reviewed
    changes-requested approved commented)
  "Review States of the For Me group in the order they are tried.
The assignee is the pull request's primary reviewer, while a request
to me or one of my Teams is often a broadcast, so `assigned' comes
before the request states; it applies only while I have no submitted
review, so my verdict, new commits after it or a renewed request show
once I have reviewed.")

(defun prrr-state--head-oid (pr meta)
  "Return the head commit PR's Review State is judged against.
That is META's head-oid when META has one: it was fetched by the same
query as the viewer's latest review, so the two are one snapshot and
forge's separate fetch cadence cannot fake `new-commits'.  Without it,
PR's head-oid from forge."
  (or (and meta (prrr-pr-meta-head-oid meta))
      (prrr-pr-head-oid pr)))

(defun prrr-state-review-state (pr meta me teams)
  "Return the Review State of PR for the viewer ME, or nil.
META is PR's `prrr-pr-meta' or nil; TEAMS the viewer's Team slugs.
First match wins, in the order of `prrr-state-for-me-order'."
  (let ((review (prrr-state--viewer-review meta)))
    (cond
     ((and review (nth 2 review)
           (not (equal (nth 2 review) (prrr-state--head-oid pr meta))))
      'new-commits)
     ((and (null review) (member me (prrr-pr-assignees pr)))
      'assigned)
     ((prrr-state--requested-p meta me)
      'requested)
     ((and (prrr-state--team-requests meta teams)
           (null (prrr-state--teammate-reviews meta me teams)))
      'team-requested)
     ((prrr-state--teammate-reviews meta me teams)
      'teammate-reviewed)
     ((and review (equal (nth 0 review) "CHANGES_REQUESTED"))
      'changes-requested)
     ((and review (equal (nth 0 review) "APPROVED"))
      'approved)
     (review                            ; COMMENTED or DISMISSED
      'commented))))

;;;; Mine state

(defconst prrr-state-mine-order
  '(changes-requested awaiting-review approved reviewed draft)
  "Mine states in display order: the first needs my action most.")

(defun prrr-state-mine-state (pr meta me)
  "Return the Mine state of PR authored by ME, given META (or nil).
Other people's latest reviews decide it: CHANGES_REQUESTED beats
APPROVED beats any other review; no review is `awaiting-review'; a
draft is `draft' whatever the reviews say."
  (if (prrr-pr-draft-p pr)
      'draft
    (let ((states (cl-loop for (login state) in (and meta (prrr-pr-meta-latest-reviews meta))
                           unless (equal login me)
                           collect state)))
      (cond ((member "CHANGES_REQUESTED" states) 'changes-requested)
            ((member "APPROVED" states) 'approved)
            (states 'reviewed)
            (t 'awaiting-review)))))

;;;; Withdraw

(defun prrr-state-withdraw-scope (meta me)
  "Return what a Withdraw of ME from the PR of META removes, or nil.
A plist (:review-request :assignee), each non-nil when ME is directly
requested or assigned.  A request to one of ME's Teams is not ME's to
remove: dropping the Team would drop its other members too."
  (let ((review-request (and (member (list 'user me) (prrr-pr-meta-review-requests meta)) t))
        (assignee (and (member me (prrr-pr-meta-assignees meta)) t)))
    (and (or review-request assignee)
         (list :review-request review-request :assignee assignee))))

(defun prrr-state-withdraw-label (scope)
  "Name what the Withdraw SCOPE removes, as \"review request and assignment\".
SCOPE is a plist like `prrr-state-withdraw-scope' returns."
  (string-join (append (and (plist-get scope :review-request) '("review request"))
                       (and (plist-get scope :assignee) '("assignment")))
               " and "))

(defun prrr-state-withdraw-problem (meta me teams)
  "Return why ME cannot withdraw from the PR of META, or nil when ME can.
TEAMS are the combined slugs of ME's Teams.  META is nil when prrr has
not pulled the PR."
  (cond ((null meta) "prrr has not pulled this pull request yet: press G")
        ((prrr-state-withdraw-scope meta me) nil)
        ((prrr-state--team-requests meta teams)
         (format "Requested only through %s; withdrawing would drop the whole Team"
                 (string-join (prrr-state--team-requests meta teams) ", ")))
        (t "You are neither requested nor assigned here")))

(defun prrr-state-withdrawn-meta (meta rows)
  "Return META as the user sees it with the queued Withdraws among ROWS applied.
ROWS are `prrr-outbox' rows of any PRs; only META's PR's Withdraws
count.  Each removes the viewer's direct review request, with GitHub's
flag that the viewer was asked to review, or the viewer's assignment,
as its payload says.  META is returned unchanged when no Withdraw
applies, else a copy; nil stays nil."
  (let ((withdraws (and meta
                        (seq-filter (lambda (row)
                                      (and (eq (prrr-outbox-kind row) 'withdraw)
                                           (equal (prrr-outbox-pr-id row) (prrr-pr-meta-pr-id meta))))
                                    rows))))
    (dolist (row withdraws meta)
      (let* ((payload (prrr-outbox-payload row))
             (me (plist-get (plist-get payload :target) :me)))
        (when (plist-get payload :review-request)
          (setq meta (prrr-state--copy meta
                                       :review-requests (remove (list 'user me)
                                                                (prrr-pr-meta-review-requests meta))
                                       :viewer-latest-review-request nil)))
        (when (plist-get payload :assignee)
          (setq meta (prrr-state--copy meta
                                       :assignees (remove me (prrr-pr-meta-assignees meta)))))))))

(defun prrr-state-verdict-state (verdict)
  "Return GitHub's review state for the Submit VERDICT.
VERDICT is `approve', `request-changes' or `comment'."
  (pcase verdict
    ('approve "APPROVED")
    ('request-changes "CHANGES_REQUESTED")
    (_ "COMMENTED")))

(defun prrr-state-submitted-meta (meta rows teams)
  "Return META as the user sees it with the queued Submits among ROWS applied.
ROWS are `prrr-outbox' rows of any PRs; only META's PR's Submits
count.  Each makes the viewer's latest review its Verdict's state
\(`prrr-state-verdict-state'), submitted when the write was queued, at
the commit it was made against, and answers the viewer's direct review
request and the requests to TEAMS, the viewer's Team slugs, as GitHub
does once it has a member's review.  META is returned unchanged when
no Submit applies, else a copy; nil stays nil."
  (let ((submits (and meta
                      (seq-filter (lambda (row)
                                    (and (eq (prrr-outbox-kind row) 'submit)
                                         (equal (prrr-outbox-pr-id row) (prrr-pr-meta-pr-id meta))))
                                  rows))))
    (dolist (row submits meta)
      (let* ((payload (prrr-outbox-payload row))
             (me (plist-get (plist-get payload :target) :me)))
        (setq meta (prrr-state--copy
                    meta
                    :viewer-latest-review (list (prrr-state-verdict-state (plist-get payload :verdict))
                                                (prrr-outbox-created-at row)
                                                (plist-get payload :commit))
                    :review-requests (seq-remove (lambda (request)
                                                   (or (equal request (list 'user me))
                                                       (and (eq (car request) 'team)
                                                            (member (cadr request) teams))))
                                                 (prrr-pr-meta-review-requests meta))
                    :viewer-latest-review-request nil))))))

(defun prrr-state-queued-meta (meta rows teams)
  "Return META with the queued Withdraws and Submits among ROWS applied.
TEAMS are the viewer's Team slugs.  What the Review Queue renders: see
`prrr-state-withdrawn-meta' and `prrr-state-submitted-meta'."
  (prrr-state-submitted-meta (prrr-state-withdrawn-meta meta rows) rows teams))

;;;; Mentions

(defun prrr-state-mention-candidates (meta logins)
  "Return the names an @-mention on META's PR may complete to, sorted.
META is the PR's `prrr-pr-meta' or nil: its requested users and
assignees, its reviewers and its requested Teams, as org/slug, are
candidates.  LOGINS are more, such as the author, the commenters and
the repository's collaborators; nil entries are dropped, duplicates
too."
  (sort (delete-dups
         (delq nil
               (append logins
                       (and meta
                            (append
                             (mapcar #'cadr (prrr-pr-meta-review-requests meta))
                             (prrr-pr-meta-assignees meta)
                             (mapcar #'car (prrr-pr-meta-latest-reviews meta)))))))
        #'string<))

;;;; Membership and partition

(defun prrr-state--direct-p (pr meta me)
  "Non-nil when PR, with META, is requested directly from ME or assigned to ME."
  (or (prrr-state--requested-p meta me)
      (and (member me (prrr-pr-assignees pr)) t)))

(defun prrr-state-for-me-p (pr meta me teams)
  "Non-nil when PR, with META, belongs in the For Me group for ME and TEAMS.
PR must not be authored by ME and must have a Review State.  A draft
is in only when requested directly from ME or assigned to ME."
  (and (not (equal (prrr-pr-author pr) me))
       (prrr-state-review-state pr meta me teams)
       (or (not (prrr-pr-draft-p pr))
           (prrr-state--direct-p pr meta me))
       t))

(defun prrr-state-partition (pr state)
  "Return `awaiting' or `served' for PR in Review State STATE.
Awaiting me holds new-commits, assigned, requested and team-requested
\(assigned implies no review of mine).  Drafts are always Served."
  (if (and (memq state '(new-commits requested team-requested assigned))
           (not (prrr-pr-draft-p pr)))
      'awaiting
    'served))

;;;; Stacks

(defun prrr-state--older-p (a b)
  "Non-nil when PR A was opened before PR B.
Creation time decides, a PR without one counting as the newest; the
lower PR number breaks a tie."
  (let ((created-a (prrr-pr-created-at a))
        (created-b (prrr-pr-created-at b)))
    (cond ((and created-a created-b (not (equal created-a created-b)))
           (string< created-a created-b))
          ((and created-a (not created-b)) t)
          ((and created-b (not created-a)) nil)
          (t (< (or (prrr-pr-number a) 0) (or (prrr-pr-number b) 0))))))

(defun prrr-state--parent (pr prs default-branch)
  "Return the PR in PRS that PR is stacked on, or nil.
The parent is a PR whose `head-ref' equals PR's `base-ref' and that is
not from a fork.  When several open PRs have that head branch, the
oldest one is the parent (see `prrr-state--older-p'), so the answer
does not depend on the order of PRS.  A PR based on DEFAULT-BRANCH, or
on a branch no open PR has as its head, has no parent."
  (let ((base (prrr-pr-base-ref pr)))
    (and base
         (not (equal base default-branch))
         (car (sort (seq-filter (lambda (candidate)
                                  (and (not (eq candidate pr))
                                       (not (prrr-pr-cross-repo-p candidate))
                                       (equal (prrr-pr-head-ref candidate) base)))
                                prs)
                    #'prrr-state--older-p)))))

(defun prrr-state--descend (pr parents seen)
  "Return PR followed by its descendants in PARENTS, depth first.
PARENTS is an alist (CHILD . PARENT); SEEN a hash table of visited PRs,
which stops cycles."
  (puthash pr t seen)
  (cons pr
        (cl-mapcan (lambda (child) (prrr-state--descend child parents seen))
                   (cl-loop for (child . parent) in parents
                            when (and (eq parent pr) (not (gethash child seen)))
                            collect child))))

(defun prrr-state-stacks (prs default-branch)
  "Group PRS, the open PRs of one repository, into Stacks.
Return a list of Stacks in the order their bottoms appear in PRS; each
Stack is a list of `prrr-pr' from the bottom (based on DEFAULT-BRANCH
or on no open PR) upwards, depth first when a PR has several children.
In a cycle, the walk upward stops at the first PR already visited, and
the PR reached last becomes the bottom; every PR is still listed exactly
once."
  (let ((parents (mapcar (lambda (pr) (cons pr (prrr-state--parent pr prs default-branch)))
                         prs))
        (seen (make-hash-table :test #'eq))
        (stacks nil))
    (dolist (pr prs)
      (unless (gethash pr seen)
        (let* ((bottom pr)
               (walked (list pr))
               (parent (alist-get bottom parents)))
          (while (and parent
                      (not (memq parent walked))
                      (not (gethash parent seen)))
            (push parent walked)
            (setq bottom parent
                  parent (alist-get bottom parents)))
          (push (prrr-state--descend bottom parents seen) stacks))))
    (nreverse stacks)))

;;;; Queue assembly

(defun prrr-state--touched-at (pr meta)
  "Return when I last touched PR, given its META row or nil.
That is the submittedAt of my latest review, else the PR's updated-at."
  (or (nth 1 (prrr-state--viewer-review meta))
      (prrr-pr-updated-at pr)
      ""))

(defun prrr-state--mine-rank (state)
  "Return the position of Mine STATE in `prrr-state-mine-order'."
  (or (cl-position state prrr-state-mine-order) (length prrr-state-mine-order)))

(defun prrr-state--for-me-pair (pr meta me teams pos size)
  "Return (KEY . ENTRY) for PR in the For Me group, or nil for my own PR.
META is PR's meta row or nil, ME the viewer's login and TEAMS their
Team slugs; POS and SIZE place PR in its Stack.  KEY
is a sort string for a qualifying PR (Awaiting me sorts before Served,
then by creation time or last touch) and nil for a dimmed context
member of a Stack."
  (unless (equal (prrr-pr-author pr) me)
    (let* ((member-p (prrr-state-for-me-p pr meta me teams))
           (state (and member-p (prrr-state-review-state pr meta me teams)))
           (partition (and member-p (prrr-state-partition pr state))))
      (cons (and member-p
                 (if (eq partition 'awaiting)
                     (format "0:%s" (or (prrr-pr-created-at pr) ""))
                   (format "1:%s" (prrr-state--touched-at pr meta))))
            (prrr-queue-entry-create
             :pr pr :state state :group 'for-me :partition partition
             :stack-pos pos :stack-size size
             :dimmed-p (and (or (not member-p) (prrr-pr-draft-p pr)) t))))))

(defun prrr-state--mine-pair (pr meta me pos size)
  "Return (KEY . ENTRY) for PR in the Mine group.
META is PR's meta row or nil, ME the viewer's login; POS and SIZE
place PR in its Stack.  KEY
sorts by Mine state rank then creation time; it is nil for a PR by
someone else, which is a dimmed context member of a Stack."
  (let* ((mine-p (equal (prrr-pr-author pr) me))
         (state (and mine-p (prrr-state-mine-state pr meta me))))
    (cons (and mine-p
               (format "%d:%s" (prrr-state--mine-rank state)
                       (or (prrr-pr-created-at pr) "")))
          (prrr-queue-entry-create
           :pr pr :state state :group 'mine :partition nil
           :stack-pos pos :stack-size size
           :dimmed-p (not mine-p)))))

(defun prrr-state--group (stacks make)
  "Assemble one Queue Group from STACKS.
MAKE is called with a PR, its 1-based position and its Stack's size and
returns (KEY . ENTRY) or nil to leave the PR out.  A Stack is listed
when any member has a non-nil KEY; Stacks sort by their smallest KEY
and keep their members together, bottom first."
  (let ((listed nil))
    (dolist (stack stacks)
      (let* ((size (length stack))
             (pairs (delq nil (cl-loop for pr in stack
                                       for pos from 1
                                       collect (funcall make pr pos size))))
             (keys (delq nil (mapcar #'car pairs))))
        ;; Every entry carries the id of its Stack's bottom PR.
        (dolist (pair pairs)
          (setf (prrr-queue-entry-stack-id (cdr pair)) (prrr-pr-id (car stack))))
        (when keys
          (push (cons (car (sort keys #'string<)) (mapcar #'cdr pairs)) listed))))
    (apply #'append
           (mapcar #'cdr (sort (nreverse listed)
                               (lambda (a b) (string< (car a) (car b))))))))

(defun prrr-state-queue (prs metas me teams default-branch)
  "Return the ordered Review Queue as (:for-me ENTRIES :mine ENTRIES).
PRS are the repository's open `prrr-pr's, METAS their `prrr-pr-meta'
rows (missing rows are allowed), ME the viewer's login, TEAMS the
viewer's Team slugs and DEFAULT-BRANCH the repository's default branch.
ENTRIES are `prrr-queue-entry' lists ordered as SPEC section 5
describes."
  (let ((meta-table (make-hash-table :test #'equal))
        (stacks (prrr-state-stacks prs default-branch)))
    (dolist (meta metas)
      (puthash (prrr-pr-meta-pr-id meta) meta meta-table))
    (list :for-me (prrr-state--group
                   stacks
                   (lambda (pr pos size)
                     (prrr-state--for-me-pair pr (gethash (prrr-pr-id pr) meta-table)
                                              me teams pos size)))
          :mine (prrr-state--group
                 stacks
                 (lambda (pr pos size)
                   (prrr-state--mine-pair pr (gethash (prrr-pr-id pr) meta-table)
                                          me pos size))))))

;;;; Display

(cl-defun prrr-state-filter-queue (entries &key (show-drafts t) (show-served t)
                                            muted show-muted)
  "Return ENTRIES without the rows the viewer chose to hide.
ENTRIES is one Queue Group from `prrr-state-queue'.  Unless
SHOW-DRAFTS, rows of draft PRs are dropped; unless SHOW-SERVED, rows in
the Served partition are dropped.  Rows of the PRs whose ids are in
MUTED are dropped too, unless SHOW-MUTED, when they are kept as copies
with MUTED-P set.  A Stack left with only context rows \(rows without
a state) is dropped entirely, so no row is shown without a reason.
Kept rows keep their order, STACK-POS and STACK-SIZE: a Stack's
visible rows need not be contiguous positions."
  (let* ((kept (seq-remove
                (lambda (entry)
                  (or (and (not show-drafts)
                           (prrr-pr-draft-p (prrr-queue-entry-pr entry)))
                      (and (not show-served)
                           (eq (prrr-queue-entry-partition entry) 'served))
                      (and (not show-muted)
                           (member (prrr-pr-id (prrr-queue-entry-pr entry)) muted))))
                entries))
         (kept (mapcar (lambda (entry)
                         (if (member (prrr-pr-id (prrr-queue-entry-pr entry)) muted)
                             (prrr-state--copy entry :muted-p t)
                           entry))
                       kept))
         (live (mapcar #'prrr-queue-entry-stack-id
                       (seq-filter #'prrr-queue-entry-state kept))))
    (seq-filter (lambda (entry) (member (prrr-queue-entry-stack-id entry) live))
                kept)))

(defun prrr-state-stack-neighbour (entries entry direction)
  "Return the row of ENTRIES next to ENTRY in its Stack, or nil.
DIRECTION `up' finds the nearest row above ENTRY (higher STACK-POS),
`down' the nearest below.  ENTRIES are the rows of one displayed Queue
Group, so rows the viewer hid are skipped."
  (let* ((pos (prrr-queue-entry-stack-pos entry))
         (up (eq direction 'up))
         (candidates
          (seq-filter (lambda (other)
                        (and (equal (prrr-queue-entry-stack-id other)
                                    (prrr-queue-entry-stack-id entry))
                             (if up
                                 (> (prrr-queue-entry-stack-pos other) pos)
                               (< (prrr-queue-entry-stack-pos other) pos))))
                      entries)))
    (car (sort candidates
               (lambda (a b)
                 (funcall (if up #'< #'>)
                          (prrr-queue-entry-stack-pos a)
                          (prrr-queue-entry-stack-pos b)))))))

;;;; Threads in the Review Buffer

(cl-defstruct (prrr-file-threads (:constructor prrr-file-threads-create)
                                 (:copier nil))
  "The Threads of one file of a diff, by where the Review Buffer shows them.
FILE-COMMENTS are File Comments, shown first.  LINES are Threads
anchored to lines, shown after their line, or in the file's
`not-in-range' section when that line is not in the diff.  OUTDATED
are the Threads GitHub marks outdated, and line Threads without a line.
Each list keeps the input order."
  file-comments lines outdated)

(defun prrr-state-thread-layout (threads paths)
  "Sort THREADS by where the Review Buffer shows them.
PATHS are the files of the diff.  Return (TABLE . ELSEWHERE): TABLE is
a hash table from each path in PATHS that has Threads to its
`prrr-file-threads'; ELSEWHERE lists, in input order, the Threads whose
file is not in PATHS, which the buffer shows in `outdated-files'."
  (let ((known (make-hash-table :test #'equal))
        (table (make-hash-table :test #'equal))
        (elsewhere nil))
    (dolist (path paths)
      (puthash path t known))
    (dolist (thread threads)
      (let ((path (prrr-thread-path thread)))
        (if (not (gethash path known))
            (push thread elsewhere)
          (let ((entry (or (gethash path table)
                           (puthash path (prrr-file-threads-create) table))))
            (cond ((eq (prrr-thread-subject-type thread) 'file)
                   (push thread (prrr-file-threads-file-comments entry)))
                  ((or (prrr-thread-outdated-p thread) (null (prrr-thread-line thread)))
                   (push thread (prrr-file-threads-outdated entry)))
                  (t (push thread (prrr-file-threads-lines entry))))))))
    (maphash (lambda (_path entry)
               (setf (prrr-file-threads-file-comments entry)
                     (nreverse (prrr-file-threads-file-comments entry))
                     (prrr-file-threads-lines entry)
                     (nreverse (prrr-file-threads-lines entry))
                     (prrr-file-threads-outdated entry)
                     (nreverse (prrr-file-threads-outdated entry))))
             table)
    (cons table (nreverse elsewhere))))

(defun prrr-state-thread-anchor (thread)
  "Return (SIDE . LINE): the Review Buffer shows THREAD after LINE of SIDE.
SIDE is `left' for the old file and `right' for the new one, also when
GitHub sent no side.  A range Thread is shown after its last line."
  (cons (or (prrr-thread-side thread) 'right) (prrr-thread-line thread)))

;;;; The Outbox

(defconst prrr-state-outbox-kinds
  '(thread publish reply publish-reply edit delete resolve viewed discussion
    submit discard withdraw proposed)
  "Kinds of write the Outbox holds, and the payload of each.
Every payload has :target, the PR as the Outbox reaches it:
\(:host :owner :name :number :pr-id :me), :me being the viewer's login.
  thread         a new Thread in the Pending Review: :thread and
                 :comment, the local ids of the Thread and its first
                 comment; :anchor (see `prrr-state-anchor'); :body;
                 :commit, the head the user commented on.
  publish        the same, published at once (Immediate Publish).
  reply          a reply in the Pending Review: :thread-id, :comment
                 (its local id), :body.
  publish-reply  the same, published at once.
  edit           :comment-id, :body.
  delete         :comment-id.
  resolve        :thread-id, :resolved (non-nil to resolve).
  viewed         :path, :viewed (non-nil to mark Viewed).
  discussion     a Discussion Comment: :comment (its local id), :body.
  submit         :verdict (`approve', `request-changes' or `comment'),
                 :body, :commit.
  discard        nothing more.
  withdraw       :review-request and :assignee, each non-nil to remove
                 the viewer's direct review request or assignment
                 (`prrr-state-withdraw-scope').
  proposed       an agent's comment kept until the user accepts it: :as,
                 `thread' or `reply', and the payload of that kind.  Never
                 sent (`prrr-state-outbox-held-p').
A thread or reply write may also carry :agent, non-nil when an agent
wrote it through the API (prrr-api.el); the comment it makes is
flagged `agent-p'.")

(defun prrr-state-outbox-held-p (row)
  "Non-nil when the write ROW waits for the user and is never sent."
  (eq (prrr-outbox-kind row) 'proposed))

(defun prrr-state--outbox-as (row)
  "Return the kind of write ROW is shown and acts as.
ROW's kind, or for a proposal the kind it would become, its :as."
  (if (prrr-state-outbox-held-p row)
      (plist-get (prrr-outbox-payload row) :as)
    (prrr-outbox-kind row)))

(defun prrr-state-outbox-accepted (row body)
  "Return the write the proposal ROW becomes once the user accepts it with BODY.
It is the Thread or reply ROW proposed, still the agent's, with BODY
as its text.  It keeps ROW's id, and so its place in the Outbox, and
its local ids, so a queued write that needs what ROW creates, such as
a proposed reply to a proposed Thread, still finds it.  ROW is not
changed."
  (let ((payload (prrr-outbox-payload row)))
    (prrr-state--copy row
                      :kind (plist-get payload :as)
                      :payload (plist-put (cl-loop for (key value) on payload by #'cddr
                                                   unless (eq key :as)
                                                   append (list key value))
                                          :body body))))

(defun prrr-state-comment-pending-p (comment)
  "Non-nil when COMMENT is in the Pending Review.
That is a `pending' comment that is not a proposal: a proposal shows
as pending, but joins the Pending Review only once accepted."
  (and (eq (prrr-comment-state comment) 'pending)
       (not (eq (prrr-comment-local-state comment) 'proposed))))

(defconst prrr-state-local-prefix "local:"
  "Prefix of the ids prrr gives what it created before GitHub names it.")

(defun prrr-state-local-id-p (id)
  "Non-nil when ID is a local id, one GitHub has not given yet."
  (and (stringp id) (string-prefix-p prrr-state-local-prefix id)))

(defconst prrr-state-creation-kinds
  '(thread publish reply publish-reply discussion submit)
  "Kinds of write that create content on GitHub.
GitHub allows 80 content creations a minute (SPEC section 4).")

(defconst prrr-state-creations-per-minute 80
  "Most content creations the Outbox sends in any minute.")

(defun prrr-state-outbox-created-ids (row)
  "Return the local ids of what the write ROW creates."
  (let ((payload (prrr-outbox-payload row)))
    (delq nil (list (plist-get payload :thread) (plist-get payload :comment)))))

(defun prrr-state-outbox-references (row)
  "Return the ids of the existing things the write ROW acts on."
  (let ((payload (prrr-outbox-payload row)))
    (pcase (prrr-state--outbox-as row)
      ((or 'reply 'publish-reply 'resolve) (list (plist-get payload :thread-id)))
      ((or 'edit 'delete) (list (plist-get payload :comment-id))))))

(defun prrr-state-outbox-ready-p (row)
  "Non-nil when every id the write ROW acts on is GitHub's.
A write that acts on something still known by a local id waits."
  (not (seq-some #'prrr-state-local-id-p (prrr-state-outbox-references row))))

(defun prrr-state-outbox-unconfirmed-p (row)
  "Non-nil when the send of the write ROW started and got no answer yet.
Such a write is unconfirmed: it may or may not have reached GitHub.
Its payload's :sent-at, stored before the request goes out and removed
by any answer, marks it, because the `outbox' layout is frozen.  It is
never sent again blindly; a refetch of its PR decides
\(`prrr-state-outbox-landed')."
  (and (plist-get (prrr-outbox-payload row) :sent-at) t))

(defun prrr-state-outbox-awaiting-user-p (row)
  "Non-nil when the write ROW waits for the user to send it again or drop it.
It is unconfirmed and failed: a refetch could not tell whether it
reached GitHub, as for a Discussion Comment or a Submit.  It stays
unconfirmed, so neither a refetch nor another write sends it again;
only the user's retry (`prrr-sync-resend') does."
  (and (prrr-state-outbox-unconfirmed-p row) (prrr-outbox-last-error row) t))

(defun prrr-state--outbox-heads (rows)
  "Return the first row of each PR among ROWS, in the order of ROWS."
  (let ((seen nil) (heads nil))
    (dolist (row rows)
      (unless (member (prrr-outbox-pr-id row) seen)
        (push (prrr-outbox-pr-id row) seen)
        (push row heads)))
    (nreverse heads)))

(defun prrr-state--sendable-p (row)
  "Non-nil when the write ROW, the first of its PR, may be sent.
Not when it failed, waits for an id, or is unconfirmed: clearing its
error, as a retry does, does not make an unconfirmed write sendable."
  (and (null (prrr-outbox-last-error row))
       (not (prrr-state-outbox-unconfirmed-p row))
       (prrr-state-outbox-ready-p row)))

(defun prrr-state-outbox-needs-proposal-p (row rows)
  "Non-nil when the write ROW cannot go out until a proposal is accepted.
That is when ROW is not a proposal itself (`prrr-state-outbox-held-p')
and needs, directly or through other writes, an id that a proposal
among ROWS creates: a reply to a proposed Thread, say.  Such a write
would wait for that id for as long as the proposal waits for the
user, so commands refuse to queue it."
  (and (not (prrr-state-outbox-held-p row))
       (memq row (prrr-state--outbox-waiting (if (memq row rows) rows (append rows (list row)))))
       t))

(defun prrr-state--outbox-waiting (rows)
  "Return the rows among ROWS that wait for the user: proposals and what needs one."
  (let ((held (seq-filter #'prrr-state-outbox-held-p rows)))
    (append held (prrr-state-outbox-dependents
                  rows (mapcan #'prrr-state-outbox-created-ids held)))))

(defun prrr-state--outbox-candidates (rows)
  "Return the rows among ROWS the Outbox may send some day, in order.
Proposals and the writes that need them wait for the user, so they
never hold back their PR's other writes (Review Focus 5)."
  (let ((waiting (prrr-state--outbox-waiting rows)))
    (seq-remove (lambda (row) (memq row waiting)) rows)))

(defun prrr-state-outbox-busy-prs (rows)
  "Return the ids of the PRs among ROWS whose first write may be sent.
The writes of one PR go out in order, so a failed, waiting or
unconfirmed first write holds back the rest of its PR.  Proposals,
and writes that need one (`prrr-state-outbox-needs-proposal-p'), are
skipped."
  (mapcar #'prrr-outbox-pr-id
          (seq-filter #'prrr-state--sendable-p
                      (prrr-state--outbox-heads (prrr-state--outbox-candidates rows)))))

(defun prrr-state-outbox-next (rows creations now)
  "Choose the write the Outbox sends next.
ROWS are every queued `prrr-outbox' row, oldest first; CREATIONS the
times, as floats, at which content creations were sent; NOW the
current float time.  Each PR's writes go out in order: only its first
write is a candidate, and only when it has not failed, is not
unconfirmed (`prrr-state-outbox-unconfirmed-p') and acts on no local
id.  The oldest candidate wins.  Return nil when there is none,
else (ROW . WAIT): send ROW after WAIT seconds, which is 0 unless ROW
creates content and `prrr-state-creations-per-minute' were sent in the
last minute.  Proposals, and writes that need one
\(`prrr-state-outbox-needs-proposal-p'), are skipped."
  (when-let* ((row (seq-find #'prrr-state--sendable-p
                             (prrr-state--outbox-heads (prrr-state--outbox-candidates rows)))))
    (cons row
          (let ((recent (sort (seq-filter (lambda (time) (> time (- now 60))) creations) #'<)))
            (if (or (not (memq (prrr-outbox-kind row) prrr-state-creation-kinds))
                    (< (length recent) prrr-state-creations-per-minute))
                0
              (- (+ (nth (- (length recent) prrr-state-creations-per-minute) recent) 60)
                 now))))))

(defun prrr-state-outbox-dependents (rows ids)
  "Return the rows among ROWS whose write needs one of IDS.
A write needs an id it acts on, or one created by another write that
needs one of IDS.  The rows keep the order of ROWS."
  (let ((needed ids) (found nil) (changed t))
    (while changed
      (setq changed nil)
      (dolist (row rows)
        (when (and (not (memq row found))
                   (seq-some (lambda (id) (member id needed))
                             (prrr-state-outbox-references row)))
          (push row found)
          (setq needed (append (prrr-state-outbox-created-ids row) needed)
                changed t))))
    (seq-filter (lambda (row) (memq row found)) rows)))

(defun prrr-state-thread-renames (old-comments new-comments)
  "Return an alist from local Thread id to GitHub's, learned from a refetch.
OLD-COMMENTS are the stored comments; NEW-COMMENTS those GitHub just
sent.  A comment published at once is stored under GitHub's comment id
but a local Thread id, because GitHub's answer does not name the
Thread; the refetch does."
  (let ((threads (make-hash-table :test #'equal)) (renames nil))
    (dolist (comment new-comments)
      (puthash (prrr-comment-comment-id comment) (prrr-comment-thread-id comment) threads))
    (dolist (comment old-comments)
      (let ((old (prrr-comment-thread-id comment))
            (new (gethash (prrr-comment-comment-id comment) threads)))
        (when (and (prrr-state-local-id-p old) new (not (assoc old renames)))
          (push (cons old new) renames))))
    (nreverse renames)))

(defun prrr-state--outbox-thread (row thread-id)
  "Return the Thread the write ROW creates, under THREAD-ID."
  (let* ((payload (prrr-outbox-payload row))
         (anchor (plist-get payload :anchor)))
    (prrr-thread-create :thread-id thread-id :pr-id (prrr-outbox-pr-id row)
                        :path (plist-get anchor :path) :line (plist-get anchor :line)
                        :start-line (plist-get anchor :start-line)
                        :side (plist-get anchor :side)
                        :start-side (plist-get anchor :start-side)
                        :subject-type (or (plist-get anchor :subject-type) 'line)
                        :outdated-p nil :resolved-p nil :resolvable-p nil
                        :original-line (plist-get anchor :line)
                        :original-commit (plist-get payload :commit))))

(defun prrr-state--outbox-comment (row comment-id thread-id created-at)
  "Return the comment the write ROW creates, under COMMENT-ID in THREAD-ID.
CREATED-AT is its creation time.  A proposal's comment is `pending'
like the Thread or reply it would become, with a `local-state' of
`proposed'."
  (let ((payload (prrr-outbox-payload row)))
    (prrr-comment-create :comment-id comment-id :thread-id thread-id
                         :pr-id (prrr-outbox-pr-id row)
                         :author (plist-get (plist-get payload :target) :me)
                         :body (plist-get payload :body) :created-at created-at
                         :state (if (memq (prrr-state--outbox-as row) '(thread reply))
                                    'pending
                                  'submitted)
                         :local-state (if (prrr-state-outbox-held-p row) 'proposed 'unsent)
                         :agent-p (and (plist-get payload :agent) t))))

(defun prrr-state-outbox-created (row result)
  "Return (ROWS . RENAMES) once GitHub accepted the creating write ROW.
ROW's kind is `thread', `publish', `reply' or `publish-reply'.  RESULT
is GitHub's answer, a plist with :comment-id, :database-id and
:created-at, plus :thread-id and :review-id for a Thread added to the
Pending Review.  ROWS are the `prrr-thread' and `prrr-comment' to
store; RENAMES maps the write's local ids to GitHub's.  A Thread
published at once keeps its local id, since GitHub's answer does not
name it (see `prrr-state-thread-renames')."
  (let* ((payload (prrr-outbox-payload row))
         (local-thread (plist-get payload :thread))
         (thread-id (or (plist-get result :thread-id) local-thread
                        (plist-get payload :thread-id)))
         (comment (prrr-state--outbox-comment row (plist-get result :comment-id) thread-id
                                              (plist-get result :created-at))))
    (setf (prrr-comment-local-state comment) 'sent
          (prrr-comment-review-id comment) (plist-get result :review-id)
          (prrr-comment-database-id comment) (plist-get result :database-id))
    (cons (if local-thread
              (list (prrr-state--outbox-thread row thread-id) comment)
            (list comment))
          (delq nil (list (and local-thread (plist-get result :thread-id)
                               (cons local-thread (plist-get result :thread-id)))
                          (cons (plist-get payload :comment) (plist-get result :comment-id)))))))

(defun prrr-state--copy (struct &rest changes)
  "Return a copy of the row STRUCT with CHANGES, :SLOT VALUE pairs, applied."
  (let ((copy (copy-sequence struct)))
    (while changes
      (setf (cl-struct-slot-value (type-of copy) (intern (substring (symbol-name (pop changes)) 1))
                                  copy)
            (pop changes)))
    copy))

(defun prrr-state-outbox-view (data rows)
  "Return review DATA as the user sees it with the queued writes ROWS applied.
DATA is a plist like the one `prrr-db-review-data' returns; ROWS are
the PR's `prrr-outbox' rows, oldest first.  Threads, comments, the
Pending Review and Viewed flags change as each write will change them
on GitHub; created things carry their local ids and a `local-state' of
`unsent', or `proposed' for a proposal, which shows as the Thread or
reply it would become and is not part of the Pending Review.  A failed
delete or discard changes nothing, so what it was meant to remove
stays in view; an unconfirmed write shows as unsent, like any write
that has not failed.  The result has DATA's keys plus:
  :outbox      ROWS;
  :writes      a hash table from each comment id, Thread id and Viewed
               path a queued write touches to the newest such row;
  :discussion  the queued Discussion Comments as (ID BODY ROW) lists;
  :submit      the queued Submit row, or nil.
DATA's structs are never changed."
  (let ((threads (plist-get data :threads))
        (comments (plist-get data :comments))
        (pending (plist-get data :pending-review))
        (viewed (plist-get data :viewed))
        (writes (make-hash-table :test #'equal))
        (emptied nil) (discussion nil) (submit nil))
    (dolist (row rows)
      (let* ((payload (prrr-outbox-payload row))
             (failed (prrr-outbox-last-error row))
             (comment-id (plist-get payload :comment-id))
             (thread-id (plist-get payload :thread-id)))
        (pcase (prrr-state--outbox-as row)
          ((or 'thread 'publish)
           (let ((thread (plist-get payload :thread))
                 (comment (plist-get payload :comment)))
             (setq threads (append threads (list (prrr-state--outbox-thread row thread)))
                   comments (append comments
                                    (list (prrr-state--outbox-comment
                                           row comment thread (prrr-outbox-created-at row)))))
             (puthash thread row writes)
             (puthash comment row writes)))
          ((or 'reply 'publish-reply)
           (let ((comment (plist-get payload :comment)))
             (setq comments (append comments
                                    (list (prrr-state--outbox-comment
                                           row comment thread-id (prrr-outbox-created-at row)))))
             (puthash comment row writes)))
          ('edit
           (setq comments (mapcar (lambda (comment)
                                    (if (equal (prrr-comment-comment-id comment) comment-id)
                                        (prrr-state--copy comment :body (plist-get payload :body)
                                                          :local-state 'unsent)
                                      comment))
                                  comments))
           (puthash comment-id row writes))
          ('delete
           (if failed
               (puthash comment-id row writes)
             (let ((gone (seq-find (lambda (comment)
                                     (equal (prrr-comment-comment-id comment) comment-id))
                                   comments)))
               (when gone
                 (push (prrr-comment-thread-id gone) emptied)
                 (setq comments (delq gone (copy-sequence comments)))))))
          ('resolve
           (setq threads (mapcar (lambda (thread)
                                   (if (equal (prrr-thread-thread-id thread) thread-id)
                                       (prrr-state--copy thread :resolved-p
                                                         (and (plist-get payload :resolved) t))
                                     thread))
                                 threads))
           (puthash thread-id row writes))
          ('viewed
           (let ((path (plist-get payload :path)))
             (setq viewed (append (seq-remove (lambda (flag) (equal (prrr-viewed-path flag) path))
                                              viewed)
                                  (list (prrr-viewed-create
                                         :pr-id (prrr-outbox-pr-id row) :path path
                                         :state (if (plist-get payload :viewed) 'viewed 'unviewed)))))
             (puthash path row writes)))
          ('discussion
           (push (list (plist-get payload :comment) (plist-get payload :body) row) discussion))
          ('discard
           (unless failed
             (dolist (comment comments)
               (when (prrr-state-comment-pending-p comment)
                 (push (prrr-comment-thread-id comment) emptied)))
             (setq pending nil
                   comments (seq-remove #'prrr-state-comment-pending-p comments))))
          ('submit (setq submit row)))))
    (when emptied
      (let ((live (make-hash-table :test #'equal)))
        (dolist (comment comments)
          (puthash (prrr-comment-thread-id comment) t live))
        (setq threads (seq-remove (lambda (thread)
                                    (let ((id (prrr-thread-thread-id thread)))
                                      (and (member id emptied) (not (gethash id live)))))
                                  threads))))
    (list :threads threads :comments comments :pending-review pending :viewed viewed
          :outbox rows :writes writes :discussion (nreverse discussion) :submit submit)))

;;;; Unconfirmed writes

(defconst prrr-state-clock-skew 300
  "Seconds GitHub's clock may run behind ours.
A comment that an unconfirmed write may have created is looked for
from this long before the write was queued.")

(defun prrr-state--same-body-p (a b)
  "Non-nil when the comment bodies A and B are the same text.
Surrounding whitespace does not count: GitHub may trim it."
  (and a b (equal (string-trim a) (string-trim b))))

(defun prrr-state--landed-comment (row data taken thread-p)
  "Return the comment in DATA that the creating write ROW may have made, or nil.
It is by ROW's viewer, has ROW's body, was created no earlier than
`prrr-state-clock-skew' seconds before ROW was queued, and is not one
of TAKEN.  When THREAD-P, it starts a Thread on the path of ROW's
anchor; otherwise it is in ROW's :thread-id Thread."
  (let* ((payload (prrr-outbox-payload row))
         (path (plist-get (plist-get payload :anchor) :path))
         (since (- (float-time (parse-iso8601-time-string (prrr-outbox-created-at row)))
                   prrr-state-clock-skew))
         (paths (make-hash-table :test #'equal)))
    (dolist (thread (plist-get data :threads))
      (puthash (prrr-thread-thread-id thread) (prrr-thread-path thread) paths))
    (seq-find (lambda (comment)
                (and (equal (prrr-comment-author comment)
                            (plist-get (plist-get payload :target) :me))
                     (prrr-state--same-body-p (prrr-comment-body comment)
                                              (plist-get payload :body))
                     (prrr-comment-created-at comment)
                     (<= since (float-time (parse-iso8601-time-string
                                            (prrr-comment-created-at comment))))
                     (not (member (prrr-comment-comment-id comment) taken))
                     (if thread-p
                         (and (null (prrr-comment-reply-to comment))
                              (equal path (gethash (prrr-comment-thread-id comment) paths)))
                       (equal (prrr-comment-thread-id comment) (plist-get payload :thread-id)))))
              (plist-get data :comments))))

(defun prrr-state-outbox-landed (row data taken)
  "Decide from fresh review DATA whether the unconfirmed write ROW landed.
DATA is a plist like the one `prrr-github-decode-review-data' returns,
fetched after ROW's send started.  TAKEN are the ids of the comments
stored before that refetch replaced them: such a comment came from
another write or from the web, never from ROW, so it is never matched,
even when it has the same body.  Return one of:
  (landed . RESULT)  GitHub carried ROW out.  RESULT is shaped like
                     GitHub's answer to ROW's kind: for a new Thread
                     or reply the plist `prrr-state-outbox-created'
                     reads, with :thread-id and :review-id; nil for
                     the other kinds.
  `missing'          it did not land: send it again.
  `unknown'          review DATA cannot tell: Discussion Comments and
                     a submitted review are not in it.
A new Thread or reply landed when DATA has a comment by ROW's viewer
with ROW's body, made no earlier than `prrr-state-clock-skew' seconds
before ROW was queued, that starts a Thread on the anchor's path or,
for a reply, is in ROW's Thread.  An edit landed when the comment has
ROW's body, and a delete when the comment is gone; an edit of a comment
that is gone landed too, since nothing is left to do.  A resolve landed
when the Thread's resolved flag matches (or the Thread is gone), a
Viewed change when the path's flag matches, and a discard when there
is no Pending Review.  A Withdraw is always `missing': review data
cannot tell, and GitHub ignores a removal of what is already gone."
  (let* ((payload (prrr-outbox-payload row))
         (comment-id (plist-get payload :comment-id))
         (comment (seq-find (lambda (comment)
                              (equal (prrr-comment-comment-id comment) comment-id))
                            (plist-get data :comments)))
         (kind (prrr-outbox-kind row))
         (landed
          (pcase kind
            ((or 'thread 'publish 'reply 'publish-reply)
             (when-let* ((found (prrr-state--landed-comment
                                 row data taken (memq kind '(thread publish)))))
               (list :comment-id (prrr-comment-comment-id found)
                     :database-id (prrr-comment-database-id found)
                     :created-at (prrr-comment-created-at found)
                     :thread-id (prrr-comment-thread-id found)
                     :review-id (prrr-comment-review-id found))))
            ('edit (or (null comment)
                       (prrr-state--same-body-p (prrr-comment-body comment)
                                                (plist-get payload :body))))
            ('delete (null comment))
            ('resolve
             (let ((thread (seq-find (lambda (thread)
                                       (equal (prrr-thread-thread-id thread)
                                              (plist-get payload :thread-id)))
                                     (plist-get data :threads))))
               (or (null thread)
                   (eq (and (prrr-thread-resolved-p thread) t)
                       (and (plist-get payload :resolved) t)))))
            ('viewed
             (let ((flag (seq-find (lambda (flag)
                                     (equal (prrr-viewed-path flag) (plist-get payload :path)))
                                   (plist-get data :viewed))))
               (eq (and flag (eq (prrr-viewed-state flag) 'viewed))
                   (and (plist-get payload :viewed) t))))
            ('discard (null (plist-get data :pending-review)))
            ;; Review data holds neither review requests nor assignees,
            ;; and removing them again is harmless: send it again.
            ('withdraw nil)
            (_ 'unknown))))
    (cond ((eq landed 'unknown) 'unknown)
          ((null landed) 'missing)
          ((consp landed) (cons 'landed landed))
          (t (list 'landed)))))

;;;; Anchors

(defun prrr-state-anchor (path first last)
  "Return the anchor of a comment on the diff lines FIRST to LAST of PATH.
FIRST and LAST describe one diff line each, as (HUNK KIND OLD NEW):
HUNK identifies its hunk (compared with `eq'), KIND is the line's
first character (?+, ?- or ?\\s), OLD and NEW its numbers in the old
and new file, nil on a side the line is not on.  LAST may equal FIRST.
The anchor is a plist (:path :line :side :start-line :start-side
:subject-type line): a removed line is on the `left' side at its old
number, any other line on the `right' side at its new number; LAST
gives :line and :side, and FIRST, when it is another line, :start-line
and :start-side (SPEC section 7).  Signal a `user-error' when either
line is not a diff line or the two are in different hunks."
  (pcase-let ((`(,hunk ,kind ,old ,new) first)
              (`(,last-hunk ,last-kind ,last-old ,last-new) last))
    (unless (and (memq kind '(?+ ?- ?\s)) (memq last-kind '(?+ ?- ?\s)))
      (user-error "Not on a diff line"))
    (unless (eq hunk last-hunk)
      (user-error "A comment can span the lines of one hunk only"))
    (let ((side (if (eq last-kind ?-) 'left 'right))
          (line (if (eq last-kind ?-) last-old last-new))
          (start-side (if (eq kind ?-) 'left 'right))
          (start (if (eq kind ?-) old new)))
      (append (list :path path :line line :side side)
              (unless (and (eq start-side side) (eql start line))
                (list :start-line start :start-side start-side))
              (list :subject-type 'line)))))

(defun prrr-state-file-anchor (path)
  "Return the anchor of a File Comment on PATH."
  (list :path path :subject-type 'file))

(defun prrr-state-anchor-label (anchor)
  "Describe ANCHOR for a header, as \"src/a.el:3-5 right\" or \"src/a.el\"."
  (let ((path (plist-get anchor :path))
        (line (plist-get anchor :line))
        (side (plist-get anchor :side))
        (start (plist-get anchor :start-line))
        (start-side (plist-get anchor :start-side)))
    (cond ((eq (plist-get anchor :subject-type) 'file) path)
          ((null start) (format "%s:%d %s" path line side))
          ((eq start-side side) (format "%s:%d-%d %s" path start line side))
          (t (format "%s:%d %s-%d %s" path start start-side line side)))))

(defun prrr-state-suggestion-body (lines)
  "Return a comment body suggesting a replacement for LINES.
LINES are the commented diff lines as (KIND . TEXT).  Signal a
`user-error' when one was removed, since a suggestion replaces lines of
the new file."
  (when (seq-some (lambda (line) (eq (car line) ?-)) lines)
    (user-error "A suggestion replaces lines of the new file; the region has removed lines"))
  (concat "```suggestion\n" (mapconcat #'cdr lines "\n") "\n```\n"))
;;;; Suggestions

(defun prrr-state-split-suggestions (body)
  "Split BODY into its prose and its suggestion blocks, in order.
Return a list of (text . STRING) and (suggestion . LINES) pairs, LINES
being the suggested lines, nil for a block that deletes the anchored
lines.  A block opens with a line \"```suggestion\" and closes with a
line \"```\"."
  (let ((parts nil) (start 0))
    (while (string-match "^```suggestion[ \t]*\n\\(\\(?:.*\n\\)*?\\)```[ \t]*$" body start)
      (let ((text (substring body start (match-beginning 0)))
            (lines (match-string 1 body)))
        (setq start (match-end 0))
        (unless (string-empty-p (string-trim text))
          (push (cons 'text (string-trim text)) parts))
        (push (cons 'suggestion (and (not (string-empty-p lines))
                                     (split-string (string-remove-suffix "\n" lines) "\n")))
              parts)))
    (let ((rest (string-trim (substring body start))))
      (unless (string-empty-p rest)
        (push (cons 'text rest) parts)))
    (nreverse parts)))

(defun prrr-state-suggestion-diff (old new)
  "Return the mini diff from the lines OLD to the lines NEW.
A list of (CHAR . LINE): ?\\s for a line both keep at the start or the
end, ?- for one only OLD has, ?+ for one only NEW has."
  (let ((head 0) (tail 0))
    (while (and (< head (length old)) (< head (length new))
                (equal (nth head old) (nth head new)))
      (cl-incf head))
    (while (and (< tail (- (length old) head)) (< tail (- (length new) head))
                (equal (nth (- (length old) tail 1) old) (nth (- (length new) tail 1) new)))
      (cl-incf tail))
    (append (mapcar (lambda (line) (cons ?\s line)) (seq-take old head))
            (mapcar (lambda (line) (cons ?- line)) (seq-subseq old head (- (length old) tail)))
            (mapcar (lambda (line) (cons ?+ line)) (seq-subseq new head (- (length new) tail)))
            (mapcar (lambda (line) (cons ?\s line)) (seq-subseq old (- (length old) tail))))))

;;;; Submit

(defun prrr-state-submit-problem (verdict body pending)
  "Return why a Submit with VERDICT, summary BODY and PENDING comments is refused.
nil when it may go.  GitHub wants a summary or a comment for a review
that requests changes or only comments."
  (when (and (memq verdict '(request-changes comment))
             (string-empty-p (string-trim body))
             (zerop pending))
    (if (eq verdict 'request-changes)
        "Requesting changes needs a summary or a comment"
      "A comment review needs a summary or a comment")))

(defun prrr-state-outbox-describe (row)
  "Describe the queued write ROW in one line, for choosing it.
A failed write names its error; an unconfirmed one says it waits for
GitHub's answer."
  (let* ((payload (prrr-outbox-payload row))
         (body (car (split-string (or (plist-get payload :body) "") "\n")))
         (anchor (plist-get payload :anchor)))
    (concat (pcase (prrr-outbox-kind row)
              ('thread (format "comment on %s" (prrr-state-anchor-label anchor)))
              ('publish (format "comment published on %s" (prrr-state-anchor-label anchor)))
              ((or 'reply 'publish-reply) "reply")
              ('edit "edit")
              ('delete "delete a comment")
              ('resolve (if (plist-get payload :resolved) "resolve a Thread" "unresolve a Thread"))
              ('viewed (format "%s %s" (if (plist-get payload :viewed) "mark Viewed" "unmark Viewed")
                               (plist-get payload :path)))
              ('discussion "Discussion Comment")
              ('submit (format "submit (%s)" (plist-get payload :verdict)))
              ('discard "discard the Pending Review")
              ('withdraw (format "withdraw (%s)" (prrr-state-withdraw-label payload)))
              ('proposed "proposed comment")
              (kind (symbol-name kind)))
            (and (not (string-empty-p body)) (format ": %s" (truncate-string-to-width body 40 nil nil "…")))
            (cond ((prrr-outbox-last-error row)
                   (format " (failed: %s)" (prrr-outbox-last-error row)))
                  ((prrr-state-outbox-unconfirmed-p row)
                   " (waiting for GitHub's answer)")))))

;;;; Ranges

(cl-defstruct (prrr-range (:constructor prrr-range--make) (:copier nil))
  "A Range: the two commits whose diff the Review Buffer shows.
KIND is one of `prrr-state-range-kinds'.  START is the commit the diff
starts at, nil for `default', which starts at the merge base.  END is
the commit it ends at, nil for the kinds that end at the PR's head:
the head the buffer shows.  Made with `prrr-range-create'."
  kind start end)

(defconst prrr-state-range-kinds '(default since-review since-opened commit between)
  "The kinds of Range (SPEC section 8).
`default' diffs the merge base to the head, `since-review' the commit
of my latest submitted review to the head, `since-opened' the
Bookmark's head to the head, `commit' one PR commit against its
parent, and `between' one chosen commit to another.")

(cl-defun prrr-range-create (&key kind start end)
  "Return the `prrr-range' of KIND from START to END.
Signal an error when KIND is not one of `prrr-state-range-kinds': every
rule about Ranges dispatches on the kind, and an unknown one would be
drawn as if it were some other."
  (unless (memq kind prrr-state-range-kinds)
    (error "Unknown kind of Range: %S" kind))
  (prrr-range--make :kind kind :start start :end end))

(defun prrr-state-range-ends (range merge-base head)
  "Return (START . END), the commits RANGE diffs.
MERGE-BASE is the PR's merge base and HEAD the head the buffer shows."
  (cons (if (eq (prrr-range-kind range) 'default) merge-base (prrr-range-start range))
        (or (prrr-range-end range) head)))

(defun prrr-state-range-github-side-p (range side)
  "Non-nil when RANGE numbers the lines of SIDE as GitHub does.
GitHub numbers the `right' side at the PR's head and the `left' side
at its merge base.  So the right side counts in a Range that ends at
the head, the left side only in the `default' Range.  Only these lines
take comments and show their Threads inline (SPEC section 8)."
  (if (eq side 'left)
      (eq (prrr-range-kind range) 'default)
    (null (prrr-range-end range))))

(defun prrr-state-inline-sides (range shown github)
  "Return the sides, among `left' and `right', whose line Threads show inline.
RANGE is the Range shown and SHOWN the PR head the buffer shows.
GITHUB is the head the review data was fetched at, or nil when
unknown.  A Thread's line is GitHub's number in the diff from the
merge base to GITHUB, so a side is placed only when RANGE numbers it
as GitHub does (`prrr-state-range-github-side-p') and GITHUB is SHOWN
or unknown.  That holds for the left side too: at another head, as
after a rebase, the merge base may be another commit, and nothing
stored says which one GitHub numbered against.  Every other line
Thread goes to \"Not in this diff\" rather than onto a wrong line.
This governs placement only: a new comment is numbered at its own
commit (`prrr-state-anchor-problem')."
  (and (or (null github) (equal github shown))
       (seq-filter (lambda (side) (prrr-state-range-github-side-p range side))
                   '(left right))))

(defun prrr-state-anchor-problem (range anchor)
  "Return why RANGE refuses a comment on ANCHOR, or nil when it takes one.
ANCHOR is as `prrr-state-anchor' or `prrr-state-file-anchor' returns.
A File Comment needs a Range that ends at the head; a comment on lines
needs both its sides numbered as GitHub numbers them
\(`prrr-state-range-github-side-p')."
  (when (if (eq (plist-get anchor :subject-type) 'file)
            (prrr-range-end range)
          (not (and (prrr-state-range-github-side-p range (plist-get anchor :side))
                    (prrr-state-range-github-side-p
                     range (or (plist-get anchor :start-side) (plist-get anchor :side))))))
    (format "Read-only in the %s Range: press . to comment in the default Range"
            (prrr-range-kind range))))

(defun prrr-state-short-oid (oid)
  "Return the first seven characters of OID."
  (substring oid 0 (min 7 (length oid))))

(defun prrr-state-head-notice (shown local github)
  "Say how the PR's head moved away from SHOWN, the head the buffer shows.
LOCAL is the head forge fetched (refs/pullreqs/N) and GITHUB the head
the last refetch saw; either is nil when unknown.  Return nil when
neither moved.  The buffer keeps showing SHOWN until the user asks for
the new head (SPEC section 8)."
  (cond ((and github shown (not (equal github shown)) (not (equal github local)))
         (format "head moved to %s on GitHub: run forge-pull, then g"
                 (prrr-state-short-oid github)))
        ((and local shown (not (equal local shown)))
         "head moved, press g")))

(defun prrr-state-since-review-start (meta)
  "Return the commit of the viewer's latest submitted review in META, or nil.
META is a `prrr-pr-meta' or nil.  A Pending Review does not count."
  (nth 2 (prrr-state--viewer-review meta)))

(defun prrr-state-review-commit (data)
  "Return the commit of the viewer's Pending Review in review DATA, or nil.
DATA is as `prrr-state-outbox-view' returns.  That is the stored
Pending Review's commit; without one, the commit of the first queued
new Thread or reply, whose sending creates the Pending Review on it.
A reply carries the head it was written at, so the review it creates
is on that commit, not on whatever GitHub's head is by then.  A reply
queued without a commit (before replies carried one) implies none:
its review's commit is unknown, so it is skipped, and a Thread
behind it is judged by the Outbox against the review found then."
  (or (when-let* ((review (plist-get data :pending-review)))
        (prrr-pending-review-commit-oid review))
      (seq-some (lambda (row)
                  (and (memq (prrr-outbox-kind row) '(thread reply))
                       (plist-get (prrr-outbox-payload row) :commit)))
                (plist-get data :outbox))))

(defun prrr-state-unpulled-posts (posted numbers)
  "Return the POSTED Discussion Comments that forge does not list yet.
POSTED are plists with :database-id, GitHub's database id of each
Discussion Comment GitHub accepted from the Outbox; NUMBERS are the
database ids of the PR's Discussion Comments that forge lists.  A
posted comment shows until forge lists it and no longer, so it is
never missing from the Review Buffer and never there twice."
  (seq-remove (lambda (post) (member (plist-get post :database-id) numbers)) posted))

(defun prrr-state-outbox-commit-problem (review-commit commit)
  "Return why the Outbox cannot send a new Thread on COMMIT, or nil.
REVIEW-COMMIT is the commit of the Pending Review it would join.  The
Thread was already accepted, so unlike `prrr-state-review-commit-problem'
this tells the user how to get rid of the stuck write: submitting the
review (S) would only queue behind it."
  (when (and review-commit commit (not (equal review-commit commit)))
    (format (concat "Pending Review is on %s: copy this comment, drop it with O k, "
                    "then submit or discard the review")
            (prrr-state-short-oid review-commit))))

(defun prrr-state-review-commit-problem (review-commit commit)
  "Return why a new Thread on COMMIT cannot join a Pending Review on REVIEW-COMMIT.
nil when it can: there is no Pending Review, or it is on COMMIT.
GitHub anchors every Thread of a Pending Review at the review's
commit, so line numbers taken at another commit would land on other
lines (bead prrr-836)."
  (when (and review-commit commit (not (equal review-commit commit)))
    (format (concat "Your Pending Review is on %s, not on the head shown (%s): "
                    "submit or discard it first (S), or publish this comment at once (C-c C-i)")
            (prrr-state-short-oid review-commit) (prrr-state-short-oid commit))))

;;;; Line mapping

(defun prrr-state-parse-hunk-ranges (diff)
  "Return the line ranges of the hunks of DIFF, a unified diff of one file.
Each is (OLD-START OLD-COUNT NEW-START NEW-COUNT), in order, read from
the hunk headings \"@@ -OLD-START,OLD-COUNT +NEW-START,NEW-COUNT @@\";
a count left out is 1."
  (let ((ranges nil) (start 0))
    (while (string-match (concat "^@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)?"
                                 " \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@")
                         diff start)
      (push (list (string-to-number (match-string 1 diff))
                  (if (match-string 2 diff) (string-to-number (match-string 2 diff)) 1)
                  (string-to-number (match-string 3 diff))
                  (if (match-string 4 diff) (string-to-number (match-string 4 diff)) 1))
            ranges)
      (setq start (match-end 0)))
    (nreverse ranges)))

(defun prrr-state-map-line (hunks line)
  "Return the number that LINE of the old file has in the new file, or nil.
HUNKS are the line ranges of a diff without context lines (`git diff
-U0'), as `prrr-state-parse-hunk-ranges' returns them.  nil when the
diff removes or rewrites LINE.  Switching Ranges and `.' use this to
find a line again at another commit (SPEC section 8)."
  (let ((shift 0))
    (catch 'done
      (pcase-dolist (`(,old-start ,old-count ,_new-start ,new-count) hunks)
        ;; A hunk that only adds lines names the old line they follow.
        (let ((first (if (zerop old-count) (1+ old-start) old-start)))
          (cond ((< line first) (throw 'done (+ line shift)))
                ((< line (+ first old-count)) (throw 'done nil))
                (t (cl-incf shift (- new-count old-count))))))
      (+ line shift))))

;;;; Stack steps

(defun prrr-state-stack-step (pr prs default-branch direction)
  "Return the PR next to PR in its Stack in DIRECTION, or nil.
PRS are the repository's open `prrr-pr's, PR among them.  DIRECTION
`down' is the PR that PR is stacked on (see `prrr-state--parent' for
DEFAULT-BRANCH), `up' the oldest PR stacked on PR.  Any other
DIRECTION signals an error."
  (pcase direction
    ('down (prrr-state--parent pr prs default-branch))
    ('up (car (sort (seq-filter (lambda (other)
                                  (eq pr (prrr-state--parent other prs default-branch)))
                                prs)
                    #'prrr-state--older-p)))
    (_ (error "Unknown Stack direction: %S" direction))))

(provide 'prrr-state)
;;; prrr-state.el ends here
