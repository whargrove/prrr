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
Stack's length (1 for a lone PR).  DIMMED-P marks a row shown only for
context: a non-qualifying Stack member or a draft requested from me."
  pr state group partition stack-pos stack-size dimmed-p)

;;;; Helpers over meta rows

(defun prrr-state--viewer-review (meta)
  "Return META's viewer-latest-review unless it is nil or still pending.
A Pending Review is not a touch, so it is ignored everywhere."
  (let ((review (and meta (prrr-pr-meta-viewer-latest-review meta))))
    (and review (not (equal (nth 0 review) "PENDING")) review)))

(defun prrr-state--requested-p (meta me)
  "Non-nil when META shows a current review request for ME.
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

(defun prrr-state--parent (pr prs default-branch)
  "Return the PR in PRS that PR is stacked on, or nil.
The parent is the PR whose `head-ref' equals PR's `base-ref' and that
is not from a fork.  A PR based on DEFAULT-BRANCH, or on a branch no
open PR has as its head, has no parent."
  (let ((base (prrr-pr-base-ref pr)))
    (and base
         (not (equal base default-branch))
         (seq-find (lambda (candidate)
                     (and (not (eq candidate pr))
                          (not (prrr-pr-cross-repo-p candidate))
                          (equal (prrr-pr-head-ref candidate) base)))
                   prs))))

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
Every PR appears exactly once; a cycle is broken at the PR met first."
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

(provide 'prrr-state)
;;; prrr-state.el ends here
