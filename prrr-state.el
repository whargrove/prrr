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
;; partitions and their FIFO ordering, Stack detection, and the final
;; ordered Review Queue.  Inputs are `prrr-pr' (built by the caller from
;; forge's object) and `prrr-pr-meta' rows; there is no buffer, network
;; or forge-object access, so every rule is unit-tested with constructed
;; structs.
;;
;; Line mapping across Ranges is milestone 5 and is not here yet.

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
is non-nil for a PR from a fork."
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

(defun prrr-state-review-state (pr meta me teams)
  "Return the Review State of PR for the viewer ME, or nil.
META is PR's `prrr-pr-meta' or nil; TEAMS the viewer's Team slugs.
First match wins, in the order of `prrr-state-for-me-order'."
  (let ((review (prrr-state--viewer-review meta)))
    (cond
     ((and review (nth 2 review)
           (not (equal (nth 2 review) (prrr-pr-head-oid pr))))
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
             (_ (dolist (pair pairs)
                    (setf (prrr-queue-entry-stack-id (cdr pair))
                          (prrr-pr-id (car stack)))))
             (keys (delq nil (mapcar #'car pairs))))
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

(provide 'prrr-state)
;;; prrr-state.el ends here
