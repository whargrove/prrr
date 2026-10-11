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
;; (`prrr-state-thread-layout').  Line mapping across Ranges is
;; milestone 5 and is not here yet.
;;
;; The Outbox's rules are here as well: which queued write goes next,
;; which writes depend on which, and what a write leaves behind once
;; GitHub accepts it.  prrr-sync.el carries them out.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'prrr-db)

;;;; Structs

(cl-defstruct (prrr-pr (:constructor prrr-pr-create) (:copier nil))
  "A Pull Request as the Review Queue sees it.
ID is the GitHub node id (forge's `their-id'), which joins to
`prrr-pr-meta-pr-id'.  ASSIGNEES is a list of logins.  BASE-REF and
HEAD-REF are branch names, nil when the branch is gone.  CROSS-REPO-P
is non-nil for a PR from a fork.  HEAD-OID is forge's head-rev; the
Review State prefers the head stored in the PR's `prrr-pr-meta' (see
`prrr-state--head-oid')."
  id number title author draft-p assignees created-at updated-at
  head-oid base-ref head-ref cross-repo-p)

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
requested from me."
  pr state group partition stack-pos stack-size stack-id dimmed-p)

;;;; Helpers over meta rows

(defun prrr-state--viewer-review (meta)
  "Return META's viewer-latest-review unless it is nil or still pending.
A Pending Review is not a touch, so it is ignored everywhere."
  (let ((review (and meta (prrr-pr-meta-viewer-latest-review meta))))
    (and review (not (equal (nth 0 review) "PENDING")) review)))

(defun prrr-state--requested-p (meta me)
  "Return non-nil when META holds a current review request for ME.
Either ME is in the current review requests (GitHub removes a request
once it is answered, so this means an unanswered or renewed request),
or someone requested ME and ME has not reviewed yet."
  (and meta
       (or (member (list 'user me) (prrr-pr-meta-review-requests meta))
           (and (prrr-pr-meta-viewer-latest-review-request meta)
                (null (prrr-state--viewer-review meta))))
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
  '(new-commits requested team-requested teammate-reviewed
    changes-requested approved commented assigned)
  "Review States of the For Me group in the order they are tried.")

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
      'commented)
     ((member me (prrr-pr-assignees pr))
      'assigned))))

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
Awaiting me holds new-commits, requested, team-requested and assigned
\(assigned implies no review of mine, since any review matches an
earlier state).  Drafts are always Served."
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

(cl-defun prrr-state-filter-queue (entries &key (show-drafts t) (show-served t))
  "Return ENTRIES without the rows the viewer chose to hide.
ENTRIES is one Queue Group from `prrr-state-queue'.  Unless
SHOW-DRAFTS, rows of draft PRs are dropped; unless SHOW-SERVED, rows in
the Served partition are dropped.  A Stack left with only context rows
\(rows without a state) is dropped entirely, so no row is shown without
a reason.  Kept rows keep their order, STACK-POS and STACK-SIZE: a
Stack's visible rows need not be contiguous positions."
  (let* ((kept (seq-remove
                (lambda (entry)
                  (or (and (not show-drafts)
                           (prrr-pr-draft-p (prrr-queue-entry-pr entry)))
                      (and (not show-served)
                           (eq (prrr-queue-entry-partition entry) 'served))))
                entries))
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
    submit discard)
  "Kinds of write the Outbox sends, and the payload of each.
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
  discard        nothing more.")

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
    (pcase (prrr-outbox-kind row)
      ((or 'reply 'publish-reply 'resolve) (list (plist-get payload :thread-id)))
      ((or 'edit 'delete) (list (plist-get payload :comment-id))))))

(defun prrr-state-outbox-ready-p (row)
  "Non-nil when every id the write ROW acts on is GitHub's.
A write that acts on something still known by a local id waits."
  (not (seq-some #'prrr-state-local-id-p (prrr-state-outbox-references row))))

(defun prrr-state--outbox-heads (rows)
  "Return the first row of each PR among ROWS, in the order of ROWS."
  (let ((seen nil) (heads nil))
    (dolist (row rows)
      (unless (member (prrr-outbox-pr-id row) seen)
        (push (prrr-outbox-pr-id row) seen)
        (push row heads)))
    (nreverse heads)))

(defun prrr-state--sendable-p (row)
  "Non-nil when the write ROW, the first of its PR, may be sent."
  (and (null (prrr-outbox-last-error row)) (prrr-state-outbox-ready-p row)))

(defun prrr-state-outbox-busy-prs (rows)
  "Return the ids of the PRs among ROWS whose first write may be sent.
The writes of one PR go out in order, so a failed or waiting first
write holds back the rest of its PR."
  (mapcar #'prrr-outbox-pr-id
          (seq-filter #'prrr-state--sendable-p (prrr-state--outbox-heads rows))))

(defun prrr-state-outbox-next (rows creations now)
  "Choose the write the Outbox sends next.
ROWS are every queued `prrr-outbox' row, oldest first; CREATIONS the
times, as floats, at which content creations were sent; NOW the
current float time.  Each PR's writes go out in order: only its first
write is a candidate, and only when it has not failed and acts on no
local id.  The oldest candidate wins.  Return nil when there is none,
else (ROW . WAIT): send ROW after WAIT seconds, which is 0 unless ROW
creates content and `prrr-state-creations-per-minute' were sent in the
last minute."
  (when-let ((row (seq-find #'prrr-state--sendable-p (prrr-state--outbox-heads rows))))
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
CREATED-AT is its creation time."
  (let ((payload (prrr-outbox-payload row)))
    (prrr-comment-create :comment-id comment-id :thread-id thread-id
                         :pr-id (prrr-outbox-pr-id row)
                         :author (plist-get (plist-get payload :target) :me)
                         :body (plist-get payload :body) :created-at created-at
                         :state (if (memq (prrr-outbox-kind row) '(thread reply))
                                    'pending
                                  'submitted)
                         :local-state 'unsent :agent-p nil)))

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
`unsent'.  A failed delete or discard changes nothing, so what it was
meant to remove stays in view.  The result has DATA's keys plus:
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
        (pcase (prrr-outbox-kind row)
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
               (when (eq (prrr-comment-state comment) 'pending)
                 (push (prrr-comment-thread-id comment) emptied)))
             (setq pending nil
                   comments (seq-remove (lambda (comment)
                                          (eq (prrr-comment-state comment) 'pending))
                                        comments))))
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

(provide 'prrr-state)
;;; prrr-state.el ends here
