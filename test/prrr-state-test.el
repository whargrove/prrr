;;; prrr-state-test.el --- Tests for prrr-state  -*- lexical-binding: t -*-

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

;; Every rule of SPEC.md section 5 has its own test built from
;; constructed structs; nothing here touches forge, a buffer or the
;; network.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'prrr-test-helper)
(require 'prrr-state)

(defun prrr-state-test--state (pr meta)
  "Review State of PR with META for the test viewer and Teams."
  (prrr-state-review-state pr meta prrr-test-me prrr-test-teams))

;;;; Review State, For Me group (SPEC section 5, first match wins)

(ert-deftest prrr-state-test-review-state-new-commits ()
  "My latest submitted review is on a commit other than head."
  (should (eq 'new-commits
              (prrr-state-test--state
               (prrr-test-pr)
               (prrr-test-meta
                :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z"
                                            prrr-test-old))))))

(ert-deftest prrr-state-test-review-state-new-commits-beats-requested ()
  (should (eq 'new-commits
              (prrr-state-test--state
               (prrr-test-pr)
               (prrr-test-meta
                :review-requests '((user "example-me"))
                :viewer-latest-review (list "COMMENTED" "2026-09-02T00:00:00Z"
                                            prrr-test-old))))))

(ert-deftest prrr-state-test-review-state-new-commits-needs-a-commit ()
  "Review Focus 5: a review whose commit is gone (nil) is not new-commits."
  (should (eq 'approved
              (prrr-state-test--state
               (prrr-test-pr)
               (prrr-test-meta
                :viewer-latest-review '("APPROVED" "2026-09-02T00:00:00Z" nil))))))

(ert-deftest prrr-state-test-review-state-requested-from-review-requests ()
  (should (eq 'requested
              (prrr-state-test--state
               (prrr-test-pr)
               (prrr-test-meta :review-requests '((user "example-me")))))))

(ert-deftest prrr-state-test-review-state-re-requested-after-my-review ()
  "A fresh request after my review at head wins over my old verdict."
  (should (eq 'requested
              (prrr-state-test--state
               (prrr-test-pr)
               (prrr-test-meta
                :review-requests '((user "example-me"))
                :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z"
                                            prrr-test-head))))))

(ert-deftest prrr-state-test-review-state-requested-from-viewer-request-without-review ()
  (should (eq 'requested
              (prrr-state-test--state
               (prrr-test-pr)
               (prrr-test-meta :viewer-latest-review-request "example-alice")))))

(ert-deftest prrr-state-test-review-state-old-viewer-request-does-not-outrank-my-review ()
  "The viewerLatestReviewRequest is history once I reviewed and left reviewRequests."
  (should (eq 'approved
              (prrr-state-test--state
               (prrr-test-pr)
               (prrr-test-meta
                :viewer-latest-review-request "example-alice"
                :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z"
                                            prrr-test-head))))))

(ert-deftest prrr-state-test-review-state-team-requested ()
  (should (eq 'team-requested
              (prrr-state-test--state
               (prrr-test-pr)
               (prrr-test-meta :review-requests '((team "example-org/reviewers")))))))

(ert-deftest prrr-state-test-review-state-other-team-request-is-nothing ()
  (should (null (prrr-state-test--state
                 (prrr-test-pr)
                 (prrr-test-meta :review-requests '((team "example-org/platform")))))))

(ert-deftest prrr-state-test-review-state-teammate-reviewed ()
  "Someone else reviewed on behalf of one of my Teams."
  (should (eq 'teammate-reviewed
              (prrr-state-test--state
               (prrr-test-pr)
               (prrr-test-meta
                :latest-reviews (list (list "example-bob" "APPROVED" "2026-09-02T00:00:00Z"
                                            prrr-test-head
                                            '("example-org/reviewers"))))))))

(ert-deftest prrr-state-test-review-state-teammate-review-satisfies-team-request ()
  "A Team request still listed is served once a teammate reviewed for the Team."
  (should (eq 'teammate-reviewed
              (prrr-state-test--state
               (prrr-test-pr)
               (prrr-test-meta
                :review-requests '((team "example-org/reviewers"))
                :latest-reviews (list (list "example-bob" "COMMENTED" "2026-09-02T00:00:00Z"
                                            prrr-test-head
                                            '("example-org/reviewers"))))))))

(ert-deftest prrr-state-test-review-state-my-own-on-behalf-review-is-not-a-teammate ()
  (should (eq 'approved
              (prrr-state-test--state
               (prrr-test-pr)
               (prrr-test-meta
                :latest-reviews (list (list "example-me" "APPROVED" "2026-09-02T00:00:00Z"
                                            prrr-test-head
                                            '("example-org/reviewers")))
                :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z"
                                            prrr-test-head))))))

(ert-deftest prrr-state-test-review-state-changes-requested ()
  (should (eq 'changes-requested
              (prrr-state-test--state
               (prrr-test-pr)
               (prrr-test-meta
                :viewer-latest-review (list "CHANGES_REQUESTED" "2026-09-02T00:00:00Z"
                                            prrr-test-head))))))

(ert-deftest prrr-state-test-review-state-approved ()
  (should (eq 'approved
              (prrr-state-test--state
               (prrr-test-pr)
               (prrr-test-meta
                :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z"
                                            prrr-test-head))))))

(ert-deftest prrr-state-test-review-state-commented ()
  (should (eq 'commented
              (prrr-state-test--state
               (prrr-test-pr)
               (prrr-test-meta
                :viewer-latest-review (list "COMMENTED" "2026-09-02T00:00:00Z"
                                            prrr-test-head))))))

(ert-deftest prrr-state-test-review-state-dismissed-counts-as-commented ()
  "A dismissed verdict is still a touch; it shows as commented."
  (should (eq 'commented
              (prrr-state-test--state
               (prrr-test-pr)
               (prrr-test-meta
                :viewer-latest-review (list "DISMISSED" "2026-09-02T00:00:00Z"
                                            prrr-test-head))))))

(ert-deftest prrr-state-test-review-state-pending-viewer-review-is-ignored ()
  "Review Focus 1: my unsubmitted Pending Review is not a touch."
  (should (null (prrr-state-test--state
                 (prrr-test-pr)
                 (prrr-test-meta
                  :viewer-latest-review (list "PENDING" nil prrr-test-old)))))
  (should (eq 'assigned
              (prrr-state-test--state
               (prrr-test-pr :assignees '("example-me"))
               (prrr-test-meta
                :viewer-latest-review (list "PENDING" nil prrr-test-old))))))

(ert-deftest prrr-state-test-review-state-assigned ()
  (should (eq 'assigned
              (prrr-state-test--state (prrr-test-pr :assignees '("example-bob" "example-me"))
                                      (prrr-test-meta)))))

(ert-deftest prrr-state-test-review-state-assigned-without-meta ()
  (should (eq 'assigned
              (prrr-state-test--state (prrr-test-pr :assignees '("example-me")) nil))))

(ert-deftest prrr-state-test-review-state-nothing ()
  (should (null (prrr-state-test--state (prrr-test-pr) (prrr-test-meta))))
  (should (null (prrr-state-test--state (prrr-test-pr) nil))))

(ert-deftest prrr-state-test-review-state-order-is-first-match ()
  "The states are tried in SPEC order."
  (should (equal '(new-commits requested team-requested teammate-reviewed
                   changes-requested approved commented assigned)
                 prrr-state-for-me-order)))

(ert-deftest prrr-state-test-review-state-uses-meta-head-over-forge-head ()
  "Forge's head moved but prrr's snapshot still shows my reviewed commit (prrr-knu.3)."
  (should (eq 'approved
              (prrr-state-test--state
               (prrr-test-pr :head-oid prrr-test-head)
               (prrr-test-meta :head-oid prrr-test-old
                               :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z"
                                                           prrr-test-old))))))

(ert-deftest prrr-state-test-review-state-meta-head-moved-is-new-commits ()
  "The prrr snapshot shows a push forge has not seen yet."
  (should (eq 'new-commits
              (prrr-state-test--state
               (prrr-test-pr :head-oid prrr-test-old)
               (prrr-test-meta :head-oid prrr-test-head
                               :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z"
                                                           prrr-test-old))))))

(ert-deftest prrr-state-test-review-state-without-meta-head-falls-back-to-forge ()
  (should (eq 'new-commits
              (prrr-state-test--state
               (prrr-test-pr :head-oid prrr-test-head)
               (prrr-test-meta :head-oid nil
                               :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z"
                                                           prrr-test-old))))))

;;;; Mine state

(defun prrr-state-test--mine (pr meta)
  "Mine state of PR with META for the test viewer."
  (prrr-state-mine-state pr meta prrr-test-me))

(ert-deftest prrr-state-test-mine-state-draft ()
  (should (eq 'draft (prrr-state-test--mine
                      (prrr-test-pr :author "example-me" :draft-p t)
                      (prrr-test-meta
                       :latest-reviews '(("example-carol" "CHANGES_REQUESTED"
                                          "2026-09-02T00:00:00Z" "abc" nil)))))))

(ert-deftest prrr-state-test-mine-state-awaiting-review ()
  (should (eq 'awaiting-review
              (prrr-state-test--mine (prrr-test-pr :author "example-me")
                                     (prrr-test-meta))))
  (should (eq 'awaiting-review
              (prrr-state-test--mine (prrr-test-pr :author "example-me") nil))))

(ert-deftest prrr-state-test-mine-state-changes-requested-beats-approved ()
  (should (eq 'changes-requested
              (prrr-state-test--mine
               (prrr-test-pr :author "example-me")
               (prrr-test-meta
                :latest-reviews '(("example-dave" "APPROVED" "2026-09-02T00:00:00Z" "abc" nil)
                                  ("example-carol" "CHANGES_REQUESTED" "2026-09-03T00:00:00Z" "abc" nil)))))))

(ert-deftest prrr-state-test-mine-state-approved-beats-commented ()
  (should (eq 'approved
              (prrr-state-test--mine
               (prrr-test-pr :author "example-me")
               (prrr-test-meta
                :latest-reviews '(("example-dave" "COMMENTED" "2026-09-02T00:00:00Z" "abc" nil)
                                  ("example-carol" "APPROVED" "2026-09-03T00:00:00Z" "abc" nil)))))))

(ert-deftest prrr-state-test-mine-state-reviewed ()
  "COMMENTED and DISMISSED reviews by others mean reviewed."
  (should (eq 'reviewed
              (prrr-state-test--mine
               (prrr-test-pr :author "example-me")
               (prrr-test-meta
                :latest-reviews '(("example-dave" "COMMENTED" "2026-09-02T00:00:00Z" "abc" nil))))))
  (should (eq 'reviewed
              (prrr-state-test--mine
               (prrr-test-pr :author "example-me")
               (prrr-test-meta
                :latest-reviews '(("example-dave" "DISMISSED" "2026-09-02T00:00:00Z" nil nil)))))))

(ert-deftest prrr-state-test-mine-state-ignores-my-own-review ()
  (should (eq 'awaiting-review
              (prrr-state-test--mine
               (prrr-test-pr :author "example-me")
               (prrr-test-meta
                :latest-reviews '(("example-me" "APPROVED" "2026-09-02T00:00:00Z" "abc" nil)))))))

(ert-deftest prrr-state-test-mine-state-deleted-reviewer ()
  "A review with a nil login counts as someone else's."
  (should (eq 'changes-requested
              (prrr-state-test--mine
               (prrr-test-pr :author "example-me")
               (prrr-test-meta
                :latest-reviews '((nil "CHANGES_REQUESTED" "2026-09-02T00:00:00Z" nil nil)))))))

(ert-deftest prrr-state-test-mine-order ()
  (should (equal '(changes-requested awaiting-review approved reviewed draft)
                 prrr-state-mine-order)))

;;;; For Me membership

(defun prrr-state-test--for-me-p (pr meta)
  "Whether PR with META is in For Me for the test viewer."
  (prrr-state-for-me-p pr meta prrr-test-me prrr-test-teams))

(ert-deftest prrr-state-test-for-me-p-requested ()
  (should (prrr-state-test--for-me-p (prrr-test-pr)
                                     (prrr-test-meta :review-requests '((user "example-me"))))))

(ert-deftest prrr-state-test-for-me-p-team-requested ()
  (should (prrr-state-test--for-me-p (prrr-test-pr)
                                     (prrr-test-meta :review-requests '((team "example-org/reviewers"))))))

(ert-deftest prrr-state-test-for-me-p-teammate-reviewed ()
  (should (prrr-state-test--for-me-p
           (prrr-test-pr)
           (prrr-test-meta
            :latest-reviews (list (list "example-bob" "APPROVED" "2026-09-02T00:00:00Z"
                                        prrr-test-head '("example-org/reviewers")))))))

(ert-deftest prrr-state-test-for-me-p-assigned ()
  (should (prrr-state-test--for-me-p (prrr-test-pr :assignees '("example-me")) nil)))

(ert-deftest prrr-state-test-for-me-p-ever-reviewed-by-me ()
  (should (prrr-state-test--for-me-p
           (prrr-test-pr)
           (prrr-test-meta
            :viewer-latest-review (list "COMMENTED" "2026-09-02T00:00:00Z" prrr-test-head)))))

(ert-deftest prrr-state-test-for-me-p-nothing ()
  (should-not (prrr-state-test--for-me-p (prrr-test-pr) (prrr-test-meta)))
  (should-not (prrr-state-test--for-me-p (prrr-test-pr) nil)))

(ert-deftest prrr-state-test-for-me-p-never-my-own-pr ()
  (should-not (prrr-state-test--for-me-p
               (prrr-test-pr :author "example-me" :assignees '("example-me"))
               (prrr-test-meta :review-requests '((user "example-me"))))))

(ert-deftest prrr-state-test-for-me-p-draft-excluded-unless-direct ()
  "Drafts are out even when team-requested or reviewed by me ..."
  (should-not (prrr-state-test--for-me-p
               (prrr-test-pr :draft-p t)
               (prrr-test-meta :review-requests '((team "example-org/reviewers")))))
  (should-not (prrr-state-test--for-me-p
               (prrr-test-pr :draft-p t)
               (prrr-test-meta
                :viewer-latest-review (list "COMMENTED" "2026-09-02T00:00:00Z" prrr-test-head))))
  ;; ... but in when requested directly from me or assigned to me.
  (should (prrr-state-test--for-me-p
           (prrr-test-pr :draft-p t)
           (prrr-test-meta :review-requests '((user "example-me")))))
  (should (prrr-state-test--for-me-p (prrr-test-pr :draft-p t :assignees '("example-me"))
                                     nil)))

;;;; Partition

(ert-deftest prrr-state-test-partition-awaiting-states ()
  (dolist (state '(new-commits requested team-requested assigned))
    (should (eq 'awaiting (prrr-state-partition (prrr-test-pr) state)))))

(ert-deftest prrr-state-test-partition-served-states ()
  (dolist (state '(teammate-reviewed changes-requested approved commented))
    (should (eq 'served (prrr-state-partition (prrr-test-pr) state)))))

(ert-deftest prrr-state-test-partition-draft-is-always-served ()
  "A draft requested from me stays out of Awaiting me until marked ready."
  (should (eq 'served (prrr-state-partition (prrr-test-pr :draft-p t) 'requested)))
  (should (eq 'served (prrr-state-partition (prrr-test-pr :draft-p t) 'assigned))))

;;;; Stacks

(defun prrr-state-test--ids (stacks)
  "Ids of STACKS, a list of lists of `prrr-pr'."
  (mapcar (lambda (stack) (mapcar #'prrr-pr-id stack)) stacks))

(ert-deftest prrr-state-test-stacks-chain-bottom-first ()
  "A chain is one Stack, bottom first, whatever the input order."
  (let ((bottom (prrr-test-pr :id "B" :base-ref "main" :head-ref "step-1"))
        (middle (prrr-test-pr :id "M" :base-ref "step-1" :head-ref "step-2"))
        (top (prrr-test-pr :id "T" :base-ref "step-2" :head-ref "step-3")))
    (should (equal '(("B" "M" "T"))
                   (prrr-state-test--ids (prrr-state-stacks (list top bottom middle) "main"))))
    (should (equal '(("B" "M" "T"))
                   (prrr-state-test--ids (prrr-state-stacks (list bottom middle top) "main"))))))

(ert-deftest prrr-state-test-stacks-independent-prs-are-singletons ()
  "PRs whose bases are neither the default branch nor another open head are singletons."
  (let ((a (prrr-test-pr :id "A" :head-ref "a"))
        (b (prrr-test-pr :id "B" :head-ref "b")))
    (should (equal '(("A") ("B")) (prrr-state-test--ids (prrr-state-stacks (list a b) "main"))))))

(ert-deftest prrr-state-test-stacks-parent-must-be-open ()
  "A PR whose parent was merged (absent from PRS) is a bottom on its own."
  (let ((orphan (prrr-test-pr :id "O" :base-ref "merged-branch" :head-ref "o")))
    (should (equal '(("O")) (prrr-state-test--ids (prrr-state-stacks (list orphan) "main"))))))

(ert-deftest prrr-state-test-stacks-cross-repo-parent-is-not-a-parent ()
  "A fork PR's head is not a base for anyone."
  (let ((fork (prrr-test-pr :id "F" :base-ref "main" :head-ref "feature" :cross-repo-p t))
        (child (prrr-test-pr :id "C" :base-ref "feature" :head-ref "child")))
    (should (equal '(("F") ("C")) (prrr-state-test--ids (prrr-state-stacks (list fork child) "main"))))))

(ert-deftest prrr-state-test-stacks-deleted-branches ()
  "Nil refs never match."
  (let ((no-head (prrr-test-pr :id "H" :base-ref "main" :head-ref nil))
        (no-base (prrr-test-pr :id "N" :base-ref nil :head-ref "n"))
        (child (prrr-test-pr :id "C" :base-ref "n" :head-ref "c")))
    (should (equal '(("H") ("N" "C"))
                   (prrr-state-test--ids (prrr-state-stacks (list no-head no-base child) "main"))))))

(ert-deftest prrr-state-test-stacks-cycle-terminates ()
  "Two PRs based on each other form one Stack, once."
  (let ((a (prrr-test-pr :id "A" :base-ref "b" :head-ref "a"))
        (b (prrr-test-pr :id "B" :base-ref "a" :head-ref "b")))
    (let ((stacks (prrr-state-stacks (list a b) "main")))
      (should (= 1 (length stacks)))
      (should (equal '("A" "B") (sort (mapcar #'prrr-pr-id (car stacks)) #'string<))))))

(ert-deftest prrr-state-test-stacks-branching-stack-keeps-siblings-after-parent ()
  "Two PRs on the same parent stay in the parent's Stack, depth first."
  (let ((bottom (prrr-test-pr :id "B" :base-ref "main" :head-ref "base"))
        (left (prrr-test-pr :id "L" :base-ref "base" :head-ref "left"))
        (left-top (prrr-test-pr :id "LT" :base-ref "left" :head-ref "left-top"))
        (right (prrr-test-pr :id "R" :base-ref "base" :head-ref "right")))
    (should (equal '(("B" "L" "LT" "R"))
                   (prrr-state-test--ids
                    (prrr-state-stacks (list bottom left left-top right) "main"))))))

(ert-deftest prrr-state-test-stacks-default-branch-is-never-a-parent ()
  "A PR based on the default branch is a bottom even if some PR's head has that name."
  (let ((odd (prrr-test-pr :id "O" :base-ref "develop" :head-ref "main"))
        (normal (prrr-test-pr :id "N" :base-ref "main" :head-ref "n")))
    (should (equal '(("O") ("N")) (prrr-state-test--ids (prrr-state-stacks (list odd normal) "main"))))))

(ert-deftest prrr-state-test-stacks-tie-picks-oldest-parent ()
  "Two open PRs share the head branch a third PR is based on (prrr-knu.7)."
  (let* ((old (prrr-test-pr :id "OLD" :number 7 :head-ref "shared"
                            :created-at "2026-09-01T00:00:00Z"))
         (new (prrr-test-pr :id "NEW" :number 3 :head-ref "shared" :base-ref "release"
                            :created-at "2026-09-02T00:00:00Z"))
         (child (prrr-test-pr :id "CHILD" :number 9 :base-ref "shared" :head-ref "child")))
    (dolist (prs (list (list old new child) (list child new old) (list new child old)))
      (should (eq old (prrr-state--parent child prs "main"))))))

(ert-deftest prrr-state-test-stacks-tie-on-created-at-picks-lower-number ()
  (let* ((a (prrr-test-pr :id "A" :number 4 :head-ref "shared"))
         (b (prrr-test-pr :id "B" :number 2 :head-ref "shared"))
         (child (prrr-test-pr :id "CHILD" :number 9 :base-ref "shared" :head-ref "child")))
    (should (eq b (prrr-state--parent child (list a b child) "main")))
    (should (eq b (prrr-state--parent child (list b a child) "main")))))

(ert-deftest prrr-state-test-stacks-tie-missing-created-at-counts-as-newest ()
  (let* ((dated (prrr-test-pr :id "DATED" :number 5 :head-ref "shared"))
         (undated (prrr-test-pr :id "UNDATED" :number 1 :head-ref "shared" :created-at nil))
         (child (prrr-test-pr :id "CHILD" :number 9 :base-ref "shared" :head-ref "child")))
    (should (eq dated (prrr-state--parent child (list undated dated child) "main")))))

(ert-deftest prrr-state-test-queue-entries-carry-stack-id ()
  (let* ((prs (list (prrr-test-pr :id "BOTTOM" :head-ref "step-1")
                    (prrr-test-pr :id "TOP" :base-ref "step-1" :head-ref "step-2")
                    (prrr-test-pr :id "LONE" :head-ref "lone")))
         (metas (mapcar (lambda (id) (prrr-test-meta :pr-id id :review-requests '((user "example-me"))))
                        '("BOTTOM" "TOP" "LONE")))
         (entries (plist-get (prrr-state-test--queue prs metas) :for-me)))
    (should (equal '(("BOTTOM" . "BOTTOM") ("TOP" . "BOTTOM") ("LONE" . "LONE"))
                   (mapcar (lambda (e) (cons (prrr-pr-id (prrr-queue-entry-pr e))
                                             (prrr-queue-entry-stack-id e)))
                           entries)))))


;;;; Queue assembly

(defun prrr-state-test--queue (prs metas)
  "Build the queue of PRS and METAS for the test viewer."
  (prrr-state-queue prs metas prrr-test-me prrr-test-teams "main"))

(defun prrr-state-test--rows (entries)
  "Summarise ENTRIES as (ID STATE PARTITION DIMMED-P STACK-POS STACK-SIZE)."
  (mapcar (lambda (e) (list (prrr-pr-id (prrr-queue-entry-pr e))
                            (prrr-queue-entry-state e)
                            (prrr-queue-entry-partition e)
                            (prrr-queue-entry-dimmed-p e)
                            (prrr-queue-entry-stack-pos e)
                            (prrr-queue-entry-stack-size e)))
          entries))

(ert-deftest prrr-state-test-queue-awaiting-sorted-by-created-at ()
  (let ((prs (list (prrr-test-pr :id "A" :head-ref "a" :created-at "2026-09-03T00:00:00Z")
                   (prrr-test-pr :id "B" :head-ref "b" :created-at "2026-09-01T00:00:00Z")
                   (prrr-test-pr :id "C" :head-ref "c" :created-at "2026-09-02T00:00:00Z")))
        (metas (list (prrr-test-meta :pr-id "A" :review-requests '((user "example-me")))
                     (prrr-test-meta :pr-id "B" :review-requests '((team "example-org/reviewers")))
                     (prrr-test-meta :pr-id "C" :viewer-latest-review
                                            (list "APPROVED" "2026-09-02T12:00:00Z" prrr-test-old)))))
    (should (equal '(("B" team-requested awaiting nil 1 1)
                     ("C" new-commits awaiting nil 1 1)
                     ("A" requested awaiting nil 1 1))
                   (prrr-state-test--rows (plist-get (prrr-state-test--queue prs metas) :for-me))))))

(ert-deftest prrr-state-test-queue-served-after-awaiting-sorted-by-touch ()
  "Served sorts by my last review time; teammate-reviewed falls back to updated-at."
  (let ((prs (list (prrr-test-pr :id "S1" :head-ref "s1" :created-at "2026-09-01T00:00:00Z"
                                        :updated-at "2026-09-09T00:00:00Z")
                   (prrr-test-pr :id "S2" :head-ref "s2" :created-at "2026-09-02T00:00:00Z")
                   (prrr-test-pr :id "S3" :head-ref "s3" :created-at "2026-09-03T00:00:00Z")
                   (prrr-test-pr :id "W" :head-ref "w" :created-at "2026-09-08T00:00:00Z")))
        (metas (list (prrr-test-meta
                      :pr-id "S1"
                      :latest-reviews (list (list "example-bob" "APPROVED" "2026-09-04T00:00:00Z"
                                                  prrr-test-head '("example-org/reviewers"))))
                     (prrr-test-meta
                      :pr-id "S2"
                      :viewer-latest-review (list "COMMENTED" "2026-09-07T00:00:00Z" prrr-test-head))
                     (prrr-test-meta
                      :pr-id "S3"
                      :viewer-latest-review (list "APPROVED" "2026-09-06T00:00:00Z" prrr-test-head))
                     (prrr-test-meta :pr-id "W" :review-requests '((user "example-me"))))))
    (should (equal '(("W" requested awaiting nil 1 1)
                     ("S3" approved served nil 1 1)
                     ("S2" commented served nil 1 1)
                     ("S1" teammate-reviewed served nil 1 1))
                   (prrr-state-test--rows (plist-get (prrr-state-test--queue prs metas) :for-me))))))

(ert-deftest prrr-state-test-queue-mine-sorted-by-rank-then-created-at ()
  (let ((prs (list (prrr-test-pr :id "D" :author "example-me" :head-ref "d" :draft-p t
                                        :created-at "2026-09-01T00:00:00Z")
                   (prrr-test-pr :id "A2" :author "example-me" :head-ref "a2"
                                        :created-at "2026-09-04T00:00:00Z")
                   (prrr-test-pr :id "CR" :author "example-me" :head-ref "cr"
                                        :created-at "2026-09-05T00:00:00Z")
                   (prrr-test-pr :id "A1" :author "example-me" :head-ref "a1"
                                        :created-at "2026-09-02T00:00:00Z")
                   (prrr-test-pr :id "OK" :author "example-me" :head-ref "ok"
                                        :created-at "2026-09-03T00:00:00Z")
                   (prrr-test-pr :id "RV" :author "example-me" :head-ref "rv"
                                        :created-at "2026-09-01T00:00:00Z")))
        (metas (list (prrr-test-meta
                      :pr-id "CR" :latest-reviews '(("example-carol" "CHANGES_REQUESTED" "t" "abc" nil)))
                     (prrr-test-meta
                      :pr-id "OK" :latest-reviews '(("example-carol" "APPROVED" "t" "abc" nil)))
                     (prrr-test-meta
                      :pr-id "RV" :latest-reviews '(("example-carol" "COMMENTED" "t" "abc" nil))))))
    (should (equal '(("CR" changes-requested nil nil 1 1)
                     ("A1" awaiting-review nil nil 1 1)
                     ("A2" awaiting-review nil nil 1 1)
                     ("OK" approved nil nil 1 1)
                     ("RV" reviewed nil nil 1 1)
                     ("D" draft nil nil 1 1))
                   (prrr-state-test--rows (plist-get (prrr-state-test--queue prs metas) :mine))))))

(ert-deftest prrr-state-test-queue-my-pr-never-in-for-me ()
  (let ((prs (list (prrr-test-pr :id "M" :author "example-me" :assignees '("example-me"))))
        (metas (list (prrr-test-meta :pr-id "M" :review-requests '((user "example-me"))))))
    (let ((queue (prrr-state-test--queue prs metas)))
      (should (null (plist-get queue :for-me)))
      (should (equal '(("M" awaiting-review nil nil 1 1))
                     (prrr-state-test--rows (plist-get queue :mine)))))))

(ert-deftest prrr-state-test-queue-draft-requested-is-dimmed-and-served ()
  (let ((prs (list (prrr-test-pr :id "D" :draft-p t)))
        (metas (list (prrr-test-meta :pr-id "D" :review-requests '((user "example-me"))))))
    (should (equal '(("D" requested served t 1 1))
                   (prrr-state-test--rows (plist-get (prrr-state-test--queue prs metas) :for-me))))))

(ert-deftest prrr-state-test-queue-unlisted-prs-are-absent ()
  (let ((prs (list (prrr-test-pr :id "X")))
        (metas (list (prrr-test-meta :pr-id "X"))))
    (let ((queue (prrr-state-test--queue prs metas)))
      (should (null (plist-get queue :for-me)))
      (should (null (plist-get queue :mine))))))

(ert-deftest prrr-state-test-queue-stack-stays-together-sorted-by-best-member ()
  "A Stack sits where its best member would, whole, with others dimmed."
  (let ((prs (list (prrr-test-pr :id "LONE" :head-ref "lone" :created-at "2026-09-02T00:00:00Z")
                   (prrr-test-pr :id "BOTTOM" :head-ref "step-1" :created-at "2026-09-03T00:00:00Z")
                   (prrr-test-pr :id "TOP" :base-ref "step-1" :head-ref "step-2"
                                        :created-at "2026-09-01T00:00:00Z")))
        (metas (list (prrr-test-meta :pr-id "LONE" :review-requests '((user "example-me")))
                     (prrr-test-meta :pr-id "BOTTOM")
                     (prrr-test-meta :pr-id "TOP" :review-requests '((user "example-me"))))))
    (should (equal '(("BOTTOM" nil nil t 1 2)
                     ("TOP" requested awaiting nil 2 2)
                     ("LONE" requested awaiting nil 1 1))
                   (prrr-state-test--rows (plist-get (prrr-state-test--queue prs metas) :for-me))))))

(ert-deftest prrr-state-test-queue-stack-in-for-me-omits-my-own-member ()
  (let ((prs (list (prrr-test-pr :id "MINE" :author "example-me" :head-ref "step-1")
                   (prrr-test-pr :id "THEIRS" :base-ref "step-1" :head-ref "step-2")))
        (metas (list (prrr-test-meta :pr-id "MINE")
                     (prrr-test-meta :pr-id "THEIRS" :review-requests '((user "example-me"))))))
    (let ((queue (prrr-state-test--queue prs metas)))
      (should (equal '(("THEIRS" requested awaiting nil 2 2))
                     (prrr-state-test--rows (plist-get queue :for-me))))
      (should (equal '(("MINE" awaiting-review nil nil 1 2)
                       ("THEIRS" nil nil t 2 2))
                     (prrr-state-test--rows (plist-get queue :mine)))))))

(ert-deftest prrr-state-test-queue-stack-with-awaiting-member-sorts-before-served ()
  (let ((prs (list (prrr-test-pr :id "S" :head-ref "s" :created-at "2026-09-01T00:00:00Z")
                   (prrr-test-pr :id "B" :head-ref "b1" :created-at "2026-09-05T00:00:00Z")
                   (prrr-test-pr :id "T" :base-ref "b1" :head-ref "b2"
                                        :created-at "2026-09-06T00:00:00Z")))
        (metas (list (prrr-test-meta
                      :pr-id "S"
                      :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z" prrr-test-head))
                     (prrr-test-meta
                      :pr-id "B"
                      :viewer-latest-review (list "APPROVED" "2026-09-07T00:00:00Z" prrr-test-head))
                     (prrr-test-meta :pr-id "T" :review-requests '((user "example-me"))))))
    (should (equal '("B" "T" "S")
                   (mapcar #'car (prrr-state-test--rows
                                  (plist-get (prrr-state-test--queue prs metas) :for-me)))))))

(ert-deftest prrr-state-test-queue-missing-meta-and-timestamps-do-not-signal ()
  "A PR without a meta row or timestamps still lists when assigned."
  (let ((prs (list (prrr-test-pr :id "A" :assignees '("example-me") :created-at nil
                                        :updated-at nil))))
    (should (equal '(("A" assigned awaiting nil 1 1))
                   (prrr-state-test--rows (plist-get (prrr-state-test--queue prs nil) :for-me))))))

;;;; Display filters and Stack neighbours

(defun prrr-state-test--entry (id &rest slots)
  "Build a queue entry for a PR with ID; SLOTS are entry keyword arguments."
  (apply #'prrr-queue-entry-create
         :pr (prrr-test-pr :id id :draft-p (plist-get slots :draft))
         (cl-loop for (key value) on slots by #'cddr
                  unless (eq key :draft) append (list key value))))

(ert-deftest prrr-state-test-filter-keeps-everything-by-default ()
  (let ((entries (list (prrr-state-test--entry "A" :state 'requested :partition 'awaiting :stack-id "A")
                       (prrr-state-test--entry "B" :state 'approved :partition 'served :stack-id "B"))))
    (should (equal entries (prrr-state-filter-queue entries)))))

(ert-deftest prrr-state-test-filter-hides-served ()
  (let* ((a (prrr-state-test--entry "A" :state 'requested :partition 'awaiting :stack-id "A"))
         (b (prrr-state-test--entry "B" :state 'approved :partition 'served :stack-id "B")))
    (should (equal (list a) (prrr-state-filter-queue (list a b) :show-served nil)))))

(ert-deftest prrr-state-test-filter-hides-drafts ()
  (let* ((a (prrr-state-test--entry "A" :state 'requested :partition 'awaiting :stack-id "A"))
         (d (prrr-state-test--entry "D" :draft t :state 'requested :partition 'served
                                    :dimmed-p t :stack-id "D")))
    (should (equal (list a) (prrr-state-filter-queue (list a d) :show-drafts nil)))))

(ert-deftest prrr-state-test-filter-drops-stack-left-with-only-context-rows ()
  "Hiding the only qualifying member leaves no reason to show its Stack."
  (let* ((context (prrr-state-test--entry "BOTTOM" :stack-id "BOTTOM" :stack-pos 1 :stack-size 2
                                          :dimmed-p t))
         (served (prrr-state-test--entry "TOP" :state 'approved :partition 'served
                                         :stack-id "BOTTOM" :stack-pos 2 :stack-size 2)))
    (should (null (prrr-state-filter-queue (list context served) :show-served nil)))
    (should (equal (list context served) (prrr-state-filter-queue (list context served))))))

(ert-deftest prrr-state-test-stack-neighbour-up-and-down ()
  (let* ((one (prrr-state-test--entry "ONE" :stack-id "ONE" :stack-pos 1 :stack-size 3))
         (two (prrr-state-test--entry "TWO" :stack-id "ONE" :stack-pos 2 :stack-size 3))
         (three (prrr-state-test--entry "THREE" :stack-id "ONE" :stack-pos 3 :stack-size 3))
         (other (prrr-state-test--entry "OTHER" :stack-id "OTHER" :stack-pos 1 :stack-size 1))
         (entries (list one two three other)))
    (should (eq two (prrr-state-stack-neighbour entries one 'up)))
    (should (eq three (prrr-state-stack-neighbour entries two 'up)))
    (should (null (prrr-state-stack-neighbour entries three 'up)))
    (should (eq two (prrr-state-stack-neighbour entries three 'down)))
    (should (null (prrr-state-stack-neighbour entries one 'down)))
    (should (null (prrr-state-stack-neighbour entries other 'up)))))

(ert-deftest prrr-state-test-stack-neighbour-skips-hidden-rows ()
  "Position 2 is not displayed, so up from 1 lands on 3."
  (let* ((one (prrr-state-test--entry "ONE" :stack-id "ONE" :stack-pos 1 :stack-size 3))
         (three (prrr-state-test--entry "THREE" :stack-id "ONE" :stack-pos 3 :stack-size 3)))
    (should (eq three (prrr-state-stack-neighbour (list one three) one 'up)))
    (should (eq one (prrr-state-stack-neighbour (list one three) three 'down)))))

;;;; Threads in the Review Buffer

(defun prrr-state-test--thread-ids (threads)
  "Return the ids of THREADS."
  (mapcar #'prrr-thread-thread-id threads))

(ert-deftest prrr-state-test-layout-sorts-by-kind ()
  (let* ((layout (prrr-state-thread-layout
                  (list (prrr-test-thread :id "FILE" :subject-type 'file :line nil)
                        (prrr-test-thread :id "LINE")
                        (prrr-test-thread :id "OLD" :outdated-p t)
                        (prrr-test-thread :id "NOLINE" :line nil))
                  '("src/example.el")))
         (entry (gethash "src/example.el" (car layout))))
    (should (equal '("FILE") (prrr-state-test--thread-ids (prrr-file-threads-file-comments entry))))
    (should (equal '("LINE") (prrr-state-test--thread-ids (prrr-file-threads-lines entry))))
    (should (equal '("OLD" "NOLINE") (prrr-state-test--thread-ids (prrr-file-threads-outdated entry))))
    (should (null (cdr layout)))))

(ert-deftest prrr-state-test-layout-keeps-input-order ()
  (let ((entry (gethash "a" (car (prrr-state-thread-layout
                                  (list (prrr-test-thread :id "2" :path "a" :line 30)
                                        (prrr-test-thread :id "1" :path "a" :line 5))
                                  '("a"))))))
    (should (equal '("2" "1") (prrr-state-test--thread-ids (prrr-file-threads-lines entry))))))

(ert-deftest prrr-state-test-layout-files-not-in-diff ()
  "A Thread of any kind on a file outside PATHS goes to ELSEWHERE, in order."
  (let ((layout (prrr-state-thread-layout
                 (list (prrr-test-thread :id "G1" :path "gone.el")
                       (prrr-test-thread :id "IN" :path "a")
                       (prrr-test-thread :id "G2" :path "gone.el" :subject-type 'file :line nil))
                 '("a"))))
    (should (equal '("G1" "G2") (prrr-state-test--thread-ids (cdr layout))))
    (should-not (gethash "gone.el" (car layout)))))

(ert-deftest prrr-state-test-layout-path-without-threads-absent ()
  (should (zerop (hash-table-count (car (prrr-state-thread-layout nil '("a" "b")))))))

(ert-deftest prrr-state-test-anchor ()
  (should (equal '(right . 12) (prrr-state-thread-anchor (prrr-test-thread))))
  (should (equal '(left . 7) (prrr-state-thread-anchor (prrr-test-thread :side 'left :line 7))))
  (should (equal '(right . 3) (prrr-state-thread-anchor (prrr-test-thread :side nil :line 3))))
  (should (equal '(right . 9) (prrr-state-thread-anchor
                               (prrr-test-thread :start-line 4 :line 9)))))

;;;; The Outbox

(defconst prrr-state-test--target
  '(:host "api.github.com" :owner "example-org" :name "example-repo" :number 1
    :pr-id "PR_1" :me "example-me")
  "The target of the test writes.")

(defun prrr-state-test--write (id pr-id kind payload &optional last-error)
  "A queued write ID of PR-ID with KIND, PAYLOAD and LAST-ERROR."
  (prrr-outbox-create :id id :pr-id pr-id :kind kind
                      :payload (append (list :target prrr-state-test--target) payload)
                      :created-at "2026-10-10T12:00:00Z" :attempts 0
                      :last-error last-error))

(ert-deftest prrr-state-test-outbox-next-in-order-per-pr ()
  (let ((a (prrr-state-test--write "1" "PR_1" 'viewed '(:path "a")))
        (b (prrr-state-test--write "2" "PR_1" 'viewed '(:path "b")))
        (c (prrr-state-test--write "3" "PR_2" 'viewed '(:path "c"))))
    (should (equal (cons a 0) (prrr-state-outbox-next (list a b c) nil 100.0)))
    (should (equal '("PR_1" "PR_2") (prrr-state-outbox-busy-prs (list a b c))))
    ;; A failed write holds back its PR, not the others.
    (setf (prrr-outbox-last-error a) "offline")
    (should (equal (cons c 0) (prrr-state-outbox-next (list a b c) nil 100.0)))
    (should (equal '("PR_2") (prrr-state-outbox-busy-prs (list a b c))))
    (should-not (prrr-state-outbox-next (list a b) nil 100.0))))

(ert-deftest prrr-state-test-outbox-next-waits-for-ids ()
  "A write on something GitHub has not named yet waits."
  (let ((reply (prrr-state-test--write "1" "PR_1" 'reply
                                       '(:thread-id "local:T" :comment "local:C"))))
    (should-not (prrr-state-outbox-ready-p reply))
    (should-not (prrr-state-outbox-next (list reply) nil 100.0))
    (should-not (prrr-state-outbox-busy-prs (list reply)))))

(ert-deftest prrr-state-test-outbox-next-creations-per-minute ()
  "SPEC section 4: at most 80 content creations in any minute."
  (let ((thread (prrr-state-test--write "1" "PR_1" 'thread
                                        '(:thread "local:T" :comment "local:C")))
        (viewed (prrr-state-test--write "2" "PR_1" 'viewed '(:path "a")))
        (times (number-sequence 41.0 120.0 1.0)))
    (should (= 80 (length times)))
    ;; The oldest of the 80, sent at 41, leaves the window at 101.
    (should (equal (cons thread 1.0) (prrr-state-outbox-next (list thread) times 100.0)))
    (should (equal (cons thread 0) (prrr-state-outbox-next (list thread) (cdr times) 100.0)))
    (should (equal (cons viewed 0) (prrr-state-outbox-next (list viewed) times 100.0)))))

(ert-deftest prrr-state-test-outbox-dependents ()
  (let* ((thread (prrr-state-test--write "1" "PR_1" 'thread
                                         '(:thread "local:T" :comment "local:C")))
         (reply (prrr-state-test--write "2" "PR_1" 'reply
                                        '(:thread-id "local:T" :comment "local:R")))
         (edit (prrr-state-test--write "3" "PR_1" 'edit '(:comment-id "local:R" :body "x")))
         (other (prrr-state-test--write "4" "PR_1" 'edit '(:comment-id "PRRC_1" :body "y")))
         (rows (list thread reply edit other)))
    (should (equal '("local:T" "local:C") (prrr-state-outbox-created-ids thread)))
    (should (equal (list reply edit)
                   (prrr-state-outbox-dependents rows (prrr-state-outbox-created-ids thread))))
    (should-not (prrr-state-outbox-dependents rows '("local:X")))))

(ert-deftest prrr-state-test-thread-renames ()
  (should (equal '(("local:T" . "PRRT_9"))
                 (prrr-state-thread-renames
                  (list (prrr-comment-create :comment-id "PRRC_1" :thread-id "local:T")
                        (prrr-comment-create :comment-id "PRRC_2" :thread-id "local:T")
                        (prrr-comment-create :comment-id "PRRC_3" :thread-id "PRRT_3"))
                  (list (prrr-comment-create :comment-id "PRRC_1" :thread-id "PRRT_9")
                        (prrr-comment-create :comment-id "PRRC_2" :thread-id "PRRT_9")))))
  (should-not (prrr-state-thread-renames
               (list (prrr-comment-create :comment-id "PRRC_1" :thread-id "local:T"))
               nil)))

(ert-deftest prrr-state-test-outbox-created-thread ()
  (let ((write (prrr-state-test--write
                "1" "PR_1" 'thread
                '(:thread "local:T" :comment "local:C" :body "Nit." :commit "1111"
                  :anchor (:path "a.el" :line 3 :side right :subject-type line)))))
    (pcase-let ((`(,rows . ,renames)
                 (prrr-state-outbox-created write '(:thread-id "PRRT_1" :comment-id "PRRC_1"
                                                    :created-at "2026-10-10T12:00:00Z"
                                                    :database-id "9" :review-id "PRR_1"))))
      (should (equal '(("local:T" . "PRRT_1") ("local:C" . "PRRC_1")) renames))
      (pcase-let ((`(,thread ,comment) rows))
        (should (equal '("PRRT_1" "a.el" 3 right)
                       (list (prrr-thread-thread-id thread) (prrr-thread-path thread)
                             (prrr-thread-line thread) (prrr-thread-side thread))))
        (should (equal '("PRRC_1" "PRRT_1" "example-me" "Nit." pending sent "PRR_1" "9")
                       (list (prrr-comment-comment-id comment) (prrr-comment-thread-id comment)
                             (prrr-comment-author comment) (prrr-comment-body comment)
                             (prrr-comment-state comment) (prrr-comment-local-state comment)
                             (prrr-comment-review-id comment)
                             (prrr-comment-database-id comment))))))))

(ert-deftest prrr-state-test-outbox-created-published-thread-keeps-local-id ()
  "GitHub's answer to Immediate Publish does not name the Thread."
  (let ((write (prrr-state-test--write
                "1" "PR_1" 'publish
                '(:thread "local:T" :comment "local:C" :body "Now."
                  :anchor (:path "a.el" :line 3 :side right)))))
    (pcase-let ((`((,thread ,comment) . ,renames)
                 (prrr-state-outbox-created write '(:comment-id "PRRC_1" :database-id "9"))))
      (should (equal '(("local:C" . "PRRC_1")) renames))
      (should (equal "local:T" (prrr-thread-thread-id thread)))
      (should (eq 'submitted (prrr-comment-state comment))))))

(ert-deftest prrr-state-test-outbox-created-reply ()
  (let ((write (prrr-state-test--write "1" "PR_1" 'reply
                                       '(:thread-id "PRRT_1" :comment "local:R" :body "Yes."))))
    (pcase-let ((`((,comment) . ,renames)
                 (prrr-state-outbox-created write '(:comment-id "PRRC_2" :review-id "PRR_1"))))
      (should (equal '(("local:R" . "PRRC_2")) renames))
      (should (equal "PRRT_1" (prrr-comment-thread-id comment))))))


;;;; Unconfirmed writes

(defun prrr-state-test--unconfirmed (id kind payload)
  "A write ID of PR_1 with KIND and PAYLOAD whose send got no answer."
  (prrr-state-test--write id "PR_1" kind (append payload '(:sent-at "2026-10-10T12:00:01Z"))))

(cl-defun prrr-state-test--found (&key (id "PRRC_9") (thread "PRRT_9") (author "example-me")
                                       (body "Nit.") reply-to
                                       (created-at "2026-10-10T12:00:05Z"))
  "A comment a refetch found: ID in Thread THREAD by AUTHOR.
BODY, REPLY-TO and CREATED-AT are its fields."
  (prrr-comment-create :comment-id id :thread-id thread :pr-id "PR_1" :author author
                       :body body :reply-to reply-to :created-at created-at
                       :review-id "PRR_1" :state 'pending :local-state 'sent
                       :database-id "99"))

(defun prrr-state-test--fresh (&rest comments)
  "Review data a refetch answered: Thread PRRT_9 on a.el, T1 on b.el, and COMMENTS."
  (list :threads (list (prrr-test-thread :id "PRRT_9" :path "a.el")
                       (prrr-test-thread :id "T1" :path "b.el"))
        :comments comments
        :pending-review (prrr-pending-review-create :pr-id "PR_1" :review-id "PRR_1")
        :viewed (list (prrr-viewed-create :pr-id "PR_1" :path "a.el" :state 'viewed))))

(defconst prrr-state-test--new-thread
  '(:thread "local:T" :comment "local:C" :body "Nit." :commit "1111"
    :anchor (:path "a.el" :line 12 :side right :subject-type line))
  "The payload of a new Thread on a.el.")

(ert-deftest prrr-state-test-outbox-unconfirmed-blocks-its-pr ()
  "A write whose send got no answer holds its PR as a failed one does."
  (let ((a (prrr-state-test--unconfirmed "1" 'viewed '(:path "a")))
        (b (prrr-state-test--write "2" "PR_1" 'viewed '(:path "b")))
        (c (prrr-state-test--write "3" "PR_2" 'viewed '(:path "c"))))
    (should (prrr-state-outbox-unconfirmed-p a))
    (should-not (prrr-state-outbox-unconfirmed-p b))
    (should (equal (cons c 0) (prrr-state-outbox-next (list a b c) nil 100.0)))
    (should (equal '("PR_2") (prrr-state-outbox-busy-prs (list a b c))))))

(ert-deftest prrr-state-test-outbox-awaiting-user ()
  "A failed unconfirmed write waits for the user; it shows as failed."
  (let ((waiting (prrr-state-test--unconfirmed "1" 'discussion '(:body "Thanks!")))
        (failed (prrr-state-test--write "2" "PR_2" 'discussion '(:body "Hi") "offline")))
    (should-not (prrr-state-outbox-awaiting-user-p waiting))
    (should-not (prrr-state-outbox-awaiting-user-p failed))
    (setf (prrr-outbox-last-error waiting) "No answer")
    (should (prrr-state-outbox-awaiting-user-p waiting))
    (should-not (prrr-state-outbox-next (list waiting) nil 100.0))
    (should (equal "Discussion Comment: Thanks! (failed: No answer)"
                   (prrr-state-outbox-describe waiting)))))

(ert-deftest prrr-state-test-outbox-landed-thread ()
  (let ((row (prrr-state-test--unconfirmed "1" 'thread prrr-state-test--new-thread)))
    (should (equal '(landed :comment-id "PRRC_9" :database-id "99"
                            :created-at "2026-10-10T12:00:05Z" :thread-id "PRRT_9"
                            :review-id "PRR_1")
                   (prrr-state-outbox-landed row (prrr-state-test--fresh
                                                  (prrr-state-test--found))
                                             nil)))
    ;; GitHub's clock may run a little behind ours.
    (should (eq 'landed (car (prrr-state-outbox-landed
                              row (prrr-state-test--fresh
                                   (prrr-state-test--found :created-at "2026-10-10T11:56:00Z"))
                              nil))))
    (should (eq 'missing (prrr-state-outbox-landed row (prrr-state-test--fresh) nil)))))

(ert-deftest prrr-state-test-outbox-landed-thread-near-misses ()
  "Only a new Thread by me on the anchor's path, with the body, since the write, counts."
  (let ((row (prrr-state-test--unconfirmed "1" 'publish prrr-state-test--new-thread)))
    (dolist (comment (list (prrr-state-test--found :thread "T1")
                           (prrr-state-test--found :author "example-alice")
                           (prrr-state-test--found :body "Nit!")
                           (prrr-state-test--found :reply-to "PRRC_1")
                           (prrr-state-test--found :created-at "2026-10-10T11:54:00Z")))
      (should (eq 'missing (prrr-state-outbox-landed row (prrr-state-test--fresh comment) nil))))
    ;; A comment stored before the refetch is another write's.
    (should (eq 'missing (prrr-state-outbox-landed
                          row (prrr-state-test--fresh (prrr-state-test--found)) '("PRRC_9"))))))

(ert-deftest prrr-state-test-outbox-landed-reply ()
  (let ((row (prrr-state-test--unconfirmed "1" 'reply
                                           '(:thread-id "PRRT_9" :comment "local:R"
                                             :body "Nit."))))
    (should (equal '(landed :comment-id "PRRC_9" :database-id "99"
                            :created-at "2026-10-10T12:00:05Z" :thread-id "PRRT_9"
                            :review-id "PRR_1")
                   (prrr-state-outbox-landed
                    row (prrr-state-test--fresh (prrr-state-test--found :reply-to "PRRC_1"))
                    nil)))
    (should (eq 'missing (prrr-state-outbox-landed
                          row (prrr-state-test--fresh (prrr-state-test--found :thread "T1"))
                          nil)))
    (should (eq 'missing (prrr-state-outbox-landed
                          (prrr-state-test--unconfirmed "1" 'publish-reply
                                                        '(:thread-id "PRRT_9" :body "Other."))
                          (prrr-state-test--fresh (prrr-state-test--found))
                          nil)))))

(ert-deftest prrr-state-test-outbox-landed-edit-and-delete ()
  (let ((edit (prrr-state-test--unconfirmed "1" 'edit '(:comment-id "PRRC_9" :body "Better.")))
        (delete (prrr-state-test--unconfirmed "2" 'delete '(:comment-id "PRRC_9"))))
    (should (equal '(landed) (prrr-state-outbox-landed
                              edit (prrr-state-test--fresh
                                    (prrr-state-test--found :body "Better."))
                              nil)))
    (should (eq 'missing (prrr-state-outbox-landed
                          edit (prrr-state-test--fresh (prrr-state-test--found)) nil)))
    ;; A comment gone leaves the edit nothing to do.
    (should (equal '(landed) (prrr-state-outbox-landed edit (prrr-state-test--fresh) nil)))
    (should (equal '(landed) (prrr-state-outbox-landed delete (prrr-state-test--fresh) nil)))
    (should (eq 'missing (prrr-state-outbox-landed
                          delete (prrr-state-test--fresh (prrr-state-test--found)) nil)))))

(ert-deftest prrr-state-test-outbox-landed-resolve-viewed-discard ()
  (let ((fresh (prrr-state-test--fresh)))
    (should (eq 'missing (prrr-state-outbox-landed
                          (prrr-state-test--unconfirmed "1" 'resolve
                                                        '(:thread-id "PRRT_9" :resolved t))
                          fresh nil)))
    (should (equal '(landed) (prrr-state-outbox-landed
                              (prrr-state-test--unconfirmed "1" 'resolve
                                                            '(:thread-id "PRRT_9" :resolved nil))
                              fresh nil)))
    (should (equal '(landed) (prrr-state-outbox-landed
                              (prrr-state-test--unconfirmed "1" 'viewed '(:path "a.el" :viewed t))
                              fresh nil)))
    (should (eq 'missing (prrr-state-outbox-landed
                          (prrr-state-test--unconfirmed "1" 'viewed '(:path "b.el" :viewed t))
                          fresh nil)))
    (should (equal '(landed) (prrr-state-outbox-landed
                              (prrr-state-test--unconfirmed "1" 'viewed '(:path "b.el" :viewed nil))
                              fresh nil)))
    (should (eq 'missing (prrr-state-outbox-landed
                          (prrr-state-test--unconfirmed "1" 'discard nil) fresh nil)))
    (should (equal '(landed) (prrr-state-outbox-landed
                              (prrr-state-test--unconfirmed "1" 'discard nil)
                              (plist-put (copy-sequence fresh) :pending-review nil)
                              nil)))))

(ert-deftest prrr-state-test-outbox-landed-unknown ()
  "Review data does not show Discussion Comments or a submitted review."
  (should (eq 'unknown (prrr-state-outbox-landed
                        (prrr-state-test--unconfirmed "1" 'discussion
                                                      '(:comment "local:D" :body "Thanks!"))
                        (prrr-state-test--fresh) nil)))
  (should (eq 'unknown (prrr-state-outbox-landed
                        (prrr-state-test--unconfirmed "1" 'submit '(:verdict approve :body ""))
                        (prrr-state-test--fresh) nil))))

(ert-deftest prrr-state-test-outbox-unconfirmed-shows-as-unsent ()
  (let* ((row (prrr-state-test--unconfirmed "1" 'thread prrr-state-test--new-thread))
         (view (prrr-state-outbox-view (prrr-state-test--data) (list row))))
    (should (eq 'unsent (prrr-comment-local-state
                         (gethash "local:C" (let ((table (make-hash-table :test #'equal)))
                                              (dolist (comment (plist-get view :comments) table)
                                                (puthash (prrr-comment-comment-id comment)
                                                         comment table)))))))
    (should (equal "comment on a.el:12 right: Nit. (waiting for GitHub's answer)"
                   (prrr-state-outbox-describe row)))))


;;;; What the user sees

(defun prrr-state-test--data ()
  "Stored review data: one Thread with my pending comment, and a Pending Review."
  (list :threads (list (prrr-test-thread :id "T1"))
        :comments (list (prrr-comment-create :comment-id "C1" :thread-id "T1" :pr-id "PR_1"
                                             :author "example-me" :body "Old."
                                             :state 'pending :local-state 'sent))
        :pending-review (prrr-pending-review-create :pr-id "PR_1" :review-id "PRR_1")
        :viewed nil))

(ert-deftest prrr-state-test-outbox-view-applies-writes ()
  (let* ((data (prrr-state-test--data))
         (rows (list (prrr-state-test--write "1" "PR_1" 'thread
                                             '(:thread "local:T" :comment "local:C" :body "New."
                                               :anchor (:path "b.el" :line 1 :side right)))
                     (prrr-state-test--write "2" "PR_1" 'edit '(:comment-id "C1" :body "Edited.")
                                             "offline")
                     (prrr-state-test--write "3" "PR_1" 'resolve '(:thread-id "T1" :resolved t))
                     (prrr-state-test--write "4" "PR_1" 'viewed '(:path "a.el" :viewed t))
                     (prrr-state-test--write "5" "PR_1" 'discussion
                                             '(:comment "local:D" :body "Thanks!"))
                     (prrr-state-test--write "6" "PR_1" 'submit '(:verdict approve :body ""))))
         (view (prrr-state-outbox-view data rows)))
    (should (equal '("T1" "local:T") (mapcar #'prrr-thread-thread-id (plist-get view :threads))))
    (should (equal '(("Edited." unsent) ("New." unsent))
                   (mapcar (lambda (comment) (list (prrr-comment-body comment)
                                                   (prrr-comment-local-state comment)))
                           (plist-get view :comments))))
    (should (prrr-thread-resolved-p (car (plist-get view :threads))))
    (should (eq 'viewed (prrr-viewed-state (car (plist-get view :viewed)))))
    (should (equal "Thanks!" (nth 1 (car (plist-get view :discussion)))))
    (should (equal "6" (prrr-outbox-id (plist-get view :submit))))
    (should (equal rows (plist-get view :outbox)))
    (let ((writes (plist-get view :writes)))
      (should (equal "offline" (prrr-outbox-last-error (gethash "C1" writes))))
      (should (equal "1" (prrr-outbox-id (gethash "local:C" writes))))
      (should (equal "3" (prrr-outbox-id (gethash "T1" writes))))
      (should (equal "4" (prrr-outbox-id (gethash "a.el" writes)))))
    ;; The stored rows are untouched.
    (should (equal "Old." (prrr-comment-body (car (plist-get data :comments)))))
    (should-not (prrr-thread-resolved-p (car (plist-get data :threads))))))

(ert-deftest prrr-state-test-outbox-view-delete ()
  "Deleting a Thread's last comment hides the Thread; a failed delete hides nothing."
  (let ((data (prrr-state-test--data)))
    (let ((view (prrr-state-outbox-view
                 data (list (prrr-state-test--write "1" "PR_1" 'delete '(:comment-id "C1"))))))
      (should-not (plist-get view :comments))
      (should-not (plist-get view :threads)))
    (let ((view (prrr-state-outbox-view
                 data (list (prrr-state-test--write "1" "PR_1" 'delete '(:comment-id "C1")
                                                    "GitHub returned HTTP 502")))))
      (should (= 1 (length (plist-get view :comments))))
      (should (gethash "C1" (plist-get view :writes))))))

(ert-deftest prrr-state-test-outbox-view-discard ()
  (let ((view (prrr-state-outbox-view (prrr-state-test--data)
                                      (list (prrr-state-test--write "1" "PR_1" 'discard nil)))))
    (should-not (plist-get view :pending-review))
    (should-not (plist-get view :comments))
    (should-not (plist-get view :threads))))

(ert-deftest prrr-state-test-outbox-view-keeps-threads-without-comments ()
  "A stored Thread whose comments are not stored is not the overlay's to hide."
  (let ((view (prrr-state-outbox-view (list :threads (list (prrr-test-thread)) :comments nil)
                                      nil)))
    (should (= 1 (length (plist-get view :threads))))
    (should (zerop (hash-table-count (plist-get view :writes))))))

;;;; Anchors

(ert-deftest prrr-state-test-anchor-one-line ()
  (should (equal '(:path "a" :line 12 :side right :subject-type line)
                 (prrr-state-anchor "a" '(h ?+ nil 12) '(h ?+ nil 12))))
  (should (equal '(:path "a" :line 13 :side right :subject-type line)
                 (prrr-state-anchor "a" '(h ?\s 13 13) '(h ?\s 13 13))))
  (should (equal '(:path "a" :line 12 :side left :subject-type line)
                 (prrr-state-anchor "a" '(h ?- 12 nil) '(h ?- 12 nil)))))

(ert-deftest prrr-state-test-anchor-range ()
  (should (equal '(:path "a" :line 12 :side right :start-line 9 :start-side right
                   :subject-type line)
                 (prrr-state-anchor "a" '(h ?\s 9 9) '(h ?+ nil 12))))
  (should (equal '(:path "a" :line 12 :side right :start-line 12 :start-side left
                   :subject-type line)
                 (prrr-state-anchor "a" '(h ?- 12 nil) '(h ?+ nil 12)))))

(ert-deftest prrr-state-test-anchor-refused ()
  (should-error (prrr-state-anchor "a" '(h ?+ nil 12) '(g ?+ nil 30)) :type 'user-error)
  (should-error (prrr-state-anchor "a" '(h ?\\ nil nil) '(h ?\\ nil nil)) :type 'user-error))

(ert-deftest prrr-state-test-anchor-label ()
  (should (equal "a:12 right" (prrr-state-anchor-label '(:path "a" :line 12 :side right))))
  (should (equal "a:9-12 right"
                 (prrr-state-anchor-label '(:path "a" :line 12 :side right
                                            :start-line 9 :start-side right))))
  (should (equal "a:12 left-12 right"
                 (prrr-state-anchor-label '(:path "a" :line 12 :side right
                                            :start-line 12 :start-side left))))
  (should (equal "a" (prrr-state-anchor-label (prrr-state-file-anchor "a")))))

(ert-deftest prrr-state-test-suggestion-body ()
  (should (equal "```suggestion\nline twelve\nline 13\n```\n"
                 (prrr-state-suggestion-body '((?+ . "line twelve") (?\s . "line 13")))))
  (should-error (prrr-state-suggestion-body '((?- . "line 12"))) :type 'user-error))
;;;; Suggestions

(ert-deftest prrr-state-test-split-suggestions ()
  (should (equal '((text . "Try this:") (suggestion "a" "b") (text . "Thanks."))
                 (prrr-state-split-suggestions "Try this:\n```suggestion\na\nb\n```\nThanks.")))
  (should (equal '((suggestion "a") (suggestion "b"))
                 (prrr-state-split-suggestions "```suggestion\na\n```\n```suggestion\nb\n```")))
  (should (equal '((text . "plain\n\nmore")) (prrr-state-split-suggestions "plain\n\nmore\n")))
  (should-not (prrr-state-split-suggestions "")))

(ert-deftest prrr-state-test-split-suggestions-empty-block ()
  "An empty block deletes the lines; one with an empty line replaces them by it."
  (should (equal '((suggestion)) (prrr-state-split-suggestions "```suggestion\n```")))
  (should (equal '((suggestion "")) (prrr-state-split-suggestions "```suggestion\n\n```"))))

(ert-deftest prrr-state-test-suggestion-diff ()
  (should (equal '((?\s . "a") (?- . "b") (?+ . "B") (?\s . "c"))
                 (prrr-state-suggestion-diff '("a" "b" "c") '("a" "B" "c"))))
  (should (equal '((?- . "x")) (prrr-state-suggestion-diff '("x") nil)))
  (should (equal '((?+ . "y")) (prrr-state-suggestion-diff nil '("y")))))

;;;; Submit

(ert-deftest prrr-state-test-submit-problem ()
  (should-not (prrr-state-submit-problem 'approve "" 0))
  (should-not (prrr-state-submit-problem 'request-changes "" 2))
  (should-not (prrr-state-submit-problem 'comment "Looks fine." 0))
  (should (prrr-state-submit-problem 'request-changes "  " 0))
  (should (prrr-state-submit-problem 'comment "" 0)))

(ert-deftest prrr-state-test-outbox-describe ()
  (should (equal "comment on a.el:3 right: First line (failed: offline)"
                 (prrr-state-outbox-describe
                  (prrr-state-test--write "1" "PR_1" 'thread
                                          '(:body "First line\nsecond"
                                            :anchor (:path "a.el" :line 3 :side right))
                                          "offline"))))
  (should (equal "mark Viewed a.el"
                 (prrr-state-outbox-describe
                  (prrr-state-test--write "1" "PR_1" 'viewed '(:path "a.el" :viewed t))))))

;;;; Ranges

(defun prrr-state-test--range (kind &optional start end)
  "A Range of KIND from START to END."
  (prrr-range-create :kind kind :start start :end end))

(ert-deftest prrr-state-test-range-ends ()
  (should (equal '("base" . "head")
                 (prrr-state-range-ends (prrr-state-test--range 'default) "base" "head")))
  (should (equal '("seen" . "head")
                 (prrr-state-range-ends (prrr-state-test--range 'since-opened "seen")
                                        "base" "head")))
  (should (equal '("parent" . "commit")
                 (prrr-state-range-ends (prrr-state-test--range 'commit "parent" "commit")
                                        "base" "head"))))

(ert-deftest prrr-state-test-range-kind-checked ()
  "A Range of a kind not in `prrr-state-range-kinds' is never made."
  (dolist (kind prrr-state-range-kinds)
    (should (eq kind (prrr-range-kind (prrr-range-create :kind kind)))))
  (should-error (prrr-range-create :kind 'since-forever))
  (should-error (prrr-range-create)))

(ert-deftest prrr-state-test-range-github-side ()
  "SPEC section 8: GitHub numbers the right side at head, the left at the merge base."
  (let ((default (prrr-state-test--range 'default))
        (since (prrr-state-test--range 'since-review "r"))
        (commit (prrr-state-test--range 'commit "p" "c")))
    (should (prrr-state-range-github-side-p default 'left))
    (should (prrr-state-range-github-side-p default 'right))
    (should-not (prrr-state-range-github-side-p since 'left))
    (should (prrr-state-range-github-side-p since 'right))
    (should-not (prrr-state-range-github-side-p commit 'left))
    (should-not (prrr-state-range-github-side-p commit 'right))))

(ert-deftest prrr-state-test-inline-sides ()
  "Review Focus 3: Threads go inline only on lines GitHub's numbers fit."
  (let ((default (prrr-state-test--range 'default))
        (since (prrr-state-test--range 'since-review "r"))
        (commit (prrr-state-test--range 'commit "p" "c")))
    (should (equal '(left right) (prrr-state-inline-sides default "h" nil)))
    (should (equal '(left right) (prrr-state-inline-sides default "h" "h")))
    (should (equal '(right) (prrr-state-inline-sides since "h" "h")))
    (should-not (prrr-state-inline-sides commit "h" "h"))
    ;; The review data was fetched at another head: its right-side
    ;; numbers are not those of the head shown, and its left-side
    ;; numbers may be at another merge base (after a rebase).
    (should-not (prrr-state-inline-sides default "h" "g"))
    (should-not (prrr-state-inline-sides since "h" "g"))))

(ert-deftest prrr-state-test-anchor-problem ()
  "Review Focus 2: only lines numbered as GitHub numbers them take comments."
  (let ((right '(:path "a.el" :line 3 :side right :subject-type line))
        (left '(:path "a.el" :line 3 :side left :subject-type line))
        (mixed '(:path "a.el" :line 4 :side right :start-line 2 :start-side left
                 :subject-type line))
        (file '(:path "a.el" :subject-type file))
        (default (prrr-state-test--range 'default))
        (since (prrr-state-test--range 'since-opened "s"))
        (between (prrr-state-test--range 'between "a" "b")))
    (dolist (anchor (list right left mixed file))
      (should-not (prrr-state-anchor-problem default anchor)))
    (should-not (prrr-state-anchor-problem since right))
    (should-not (prrr-state-anchor-problem since file))
    (should (equal "Read-only in the since-opened Range: press . to comment in the default Range"
                   (prrr-state-anchor-problem since left)))
    (should (prrr-state-anchor-problem since mixed))
    (dolist (anchor (list right left file))
      (should (prrr-state-anchor-problem between anchor)))))

(ert-deftest prrr-state-test-head-notice ()
  "SPEC section 8: the buffer says the head moved instead of redrawing."
  (let ((a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        (b "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
    (should-not (prrr-state-head-notice a a a))
    (should-not (prrr-state-head-notice a a nil))
    (should-not (prrr-state-head-notice a nil nil))
    (should (equal "head moved, press g" (prrr-state-head-notice a b b)))
    (should (equal "head moved, press g" (prrr-state-head-notice a b nil)))
    (should (equal "head moved, press g" (prrr-state-head-notice a b a)))
    (should (equal "head moved to bbbbbbb on GitHub: run forge-pull, then g"
                   (prrr-state-head-notice a a b)))))

(ert-deftest prrr-state-test-since-review-start ()
  (should (equal "abc" (prrr-state-since-review-start
                        (prrr-test-meta :viewer-latest-review
                                        '("APPROVED" "2026-09-02T00:00:00Z" "abc")))))
  (should-not (prrr-state-since-review-start
               (prrr-test-meta :viewer-latest-review '("PENDING" nil "abc"))))
  (should-not (prrr-state-since-review-start (prrr-test-meta)))
  (should-not (prrr-state-since-review-start nil)))

(ert-deftest prrr-state-test-review-commit ()
  "Bead prrr-836: the Pending Review's commit, stored or about to be created."
  (let ((thread (prrr-state-test--write "1" "PR_1" 'thread '(:commit "queued")))
        (review (prrr-pending-review-create :pr-id "PR_1" :review-id "R" :commit-oid "stored")))
    (should (equal "stored" (prrr-state-review-commit
                             (list :pending-review review :outbox (list thread)))))
    (should (equal "queued" (prrr-state-review-commit (list :outbox (list thread)))))
    (should-not (prrr-state-review-commit nil))))

(ert-deftest prrr-state-test-review-commit-counts-a-queued-reply ()
  "A reply with no Pending Review implies one on the reply's commit.
A reply that carries no commit (queued before replies did) implies none."
  (let ((reply (prrr-state-test--write "1" "PR_1" 'reply '(:commit "at-reply")))
        (old (prrr-state-test--write "2" "PR_1" 'reply nil))
        (thread (prrr-state-test--write "3" "PR_1" 'thread '(:commit "at-thread"))))
    (should (equal "at-reply" (prrr-state-review-commit (list :outbox (list old reply)))))
    (should (equal "at-reply" (prrr-state-review-commit (list :outbox (list reply thread)))))
    (should (equal "at-thread" (prrr-state-review-commit (list :outbox (list thread reply)))))
    (should-not (prrr-state-review-commit (list :outbox (list old))))))

(ert-deftest prrr-state-test-outbox-commit-problem ()
  (let ((a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        (b "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
    (should-not (prrr-state-outbox-commit-problem nil a))
    (should-not (prrr-state-outbox-commit-problem a a))
    (let ((problem (prrr-state-outbox-commit-problem a b)))
      (should (string-prefix-p "Pending Review is on aaaaaaa" problem))
      (should (string-match-p "drop it with O k" problem))
      (should-not (string-match-p "C-c C-i" problem)))))

(ert-deftest prrr-state-test-unpulled-posts ()
  "A posted Discussion Comment shows until forge lists its database id."
  (let ((posted '((:database-id 5001 :body "One.") (:database-id 5002 :body "Two."))))
    (should (equal posted (prrr-state-unpulled-posts posted nil)))
    (should (equal '((:database-id 5002 :body "Two."))
                   (prrr-state-unpulled-posts posted '(4000 5001))))
    (should-not (prrr-state-unpulled-posts posted '(5002 5001)))))

(ert-deftest prrr-state-test-review-commit-problem ()
  (let ((a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        (b "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
    (should-not (prrr-state-review-commit-problem nil a))
    (should-not (prrr-state-review-commit-problem a a))
    (should (string-prefix-p "Your Pending Review is on aaaaaaa, not on the head shown (bbbbbbb)"
                             (prrr-state-review-commit-problem a b)))))

;;;; Line mapping

(ert-deftest prrr-state-test-parse-hunk-ranges ()
  (should (equal '((12 1 12 1) (20 0 21 2) (30 3 31 0))
                 (prrr-state-parse-hunk-ranges
                  (concat "diff --git a/a.el b/a.el\n--- a/a.el\n+++ b/a.el\n"
                          "@@ -12 +12 @@ (defun a ()\n-old\n+new\n"
                          "@@ -20,0 +21,2 @@\n+one\n+two\n"
                          "@@ -30,3 +31,0 @@\n-x\n-y\n-z\n"))))
  (should-not (prrr-state-parse-hunk-ranges "")))

(ert-deftest prrr-state-test-map-line ()
  "SPEC section 13: line mapping across Ranges.
One line rewritten at 12, two lines added after 20, three removed at 30."
  (let ((hunks '((12 1 12 1) (20 0 21 2) (30 3 31 0))))
    (should (= 11 (prrr-state-map-line hunks 11)))
    (should-not (prrr-state-map-line hunks 12))
    (should (= 13 (prrr-state-map-line hunks 13)))
    (should (= 20 (prrr-state-map-line hunks 20)))
    (should (= 23 (prrr-state-map-line hunks 21)))
    (should (= 31 (prrr-state-map-line hunks 29)))
    (should-not (prrr-state-map-line hunks 30))
    (should-not (prrr-state-map-line hunks 32))
    (should (= 32 (prrr-state-map-line hunks 33)))
    (should (= 7 (prrr-state-map-line nil 7)))))

(ert-deftest prrr-state-test-map-line-at-the-top ()
  "Lines added before line 1, and line 1 removed."
  (should (= 3 (prrr-state-map-line '((0 0 1 2)) 1)))
  (should-not (prrr-state-map-line '((1 1 0 0)) 1))
  (should (= 1 (prrr-state-map-line '((1 1 0 0)) 2))))

;;;; Stack steps

(ert-deftest prrr-state-test-stack-step ()
  "SPEC section 8: > and < move along the Stack; a fork's branch is no parent."
  (let* ((bottom (prrr-test-pr :id "PR_1" :number 1 :base-ref "main" :head-ref "a"))
         (middle (prrr-test-pr :id "PR_2" :number 2 :base-ref "a" :head-ref "b"
                               :created-at "2026-09-02T00:00:00Z"))
         (later (prrr-test-pr :id "PR_3" :number 3 :base-ref "a" :head-ref "c"
                              :created-at "2026-09-03T00:00:00Z"))
         (fork (prrr-test-pr :id "PR_4" :number 4 :base-ref "main" :head-ref "b"
                             :cross-repo-p t))
         (prs (list later fork middle bottom)))
    (should (eq middle (prrr-state-stack-step bottom prs "main" 'up)))
    (should-not (prrr-state-stack-step middle prs "main" 'up))
    (should (eq bottom (prrr-state-stack-step middle prs "main" 'down)))
    (should (eq bottom (prrr-state-stack-step later prs "main" 'down)))
    (should-not (prrr-state-stack-step bottom prs "main" 'down))
    (should-not (prrr-state-stack-step fork prs "main" 'down))
    (should-error (prrr-state-stack-step bottom prs "main" 'sideways))))

;;;; Withdraw

(ert-deftest prrr-state-test-withdraw-scope ()
  "A Withdraw removes my direct review request and my assignment, whichever I have."
  (should (equal '(:review-request t :assignee t)
                 (prrr-state-withdraw-scope
                  (prrr-test-meta :review-requests '((user "example-me") (user "example-bob"))
                                  :assignees '("example-me" "example-bob"))
                  prrr-test-me)))
  (should (equal '(:review-request t :assignee nil)
                 (prrr-state-withdraw-scope
                  (prrr-test-meta :review-requests '((user "example-me")))
                  prrr-test-me)))
  (should (equal '(:review-request nil :assignee t)
                 (prrr-state-withdraw-scope
                  (prrr-test-meta :review-requests '((team "example-org/reviewers"))
                                  :assignees '("example-me"))
                  prrr-test-me)))
  (should-not (prrr-state-withdraw-scope
               (prrr-test-meta :review-requests '((team "example-org/reviewers")))
               prrr-test-me)))

(ert-deftest prrr-state-test-withdraw-problem ()
  "A Withdraw is refused when it has nothing of mine to remove, naming my requested Teams."
  (should-not (prrr-state-withdraw-problem
               (prrr-test-meta :review-requests '((user "example-me"))) prrr-test-me prrr-test-teams))
  (should (equal "Requested only through example-org/reviewers; withdrawing would drop the whole Team"
                 (prrr-state-withdraw-problem
                  (prrr-test-meta :review-requests '((team "example-org/reviewers")
                                                     (team "example-org/other")))
                  prrr-test-me prrr-test-teams)))
  (should (equal "You are neither requested nor assigned here"
                 (prrr-state-withdraw-problem
                  (prrr-test-meta :review-requests '((user "example-bob")))
                  prrr-test-me prrr-test-teams)))
  (should (equal "prrr has not pulled this pull request yet: press G"
                 (prrr-state-withdraw-problem nil prrr-test-me prrr-test-teams))))

(ert-deftest prrr-state-test-withdrawn-meta ()
  "A queued Withdraw shows at once: my request, my assignment and GitHub's flag are gone."
  (let* ((meta (prrr-test-meta :review-requests '((user "example-me") (team "example-org/reviewers"))
                               :assignees '("example-me" "example-bob")
                               :viewer-latest-review-request "RR_1"))
         (row (prrr-state-test--write "1" "PR_1" 'withdraw '(:review-request t :assignee t)))
         (shown (prrr-state-withdrawn-meta meta (list row))))
    (should (equal '((team "example-org/reviewers")) (prrr-pr-meta-review-requests shown)))
    (should (equal '("example-bob") (prrr-pr-meta-assignees shown)))
    (should-not (prrr-pr-meta-viewer-latest-review-request shown))
    ;; META itself is not changed.
    (should (equal '("example-me" "example-bob") (prrr-pr-meta-assignees meta)))))

(ert-deftest prrr-state-test-withdrawn-meta-partial-and-other-prs ()
  "Only what the Withdraw removes goes, and only another PR's Withdraw leaves META alone."
  (let ((meta (prrr-test-meta :review-requests '((user "example-me"))
                              :assignees '("example-me")
                              :viewer-latest-review-request "RR_1")))
    (let ((shown (prrr-state-withdrawn-meta
                  meta (list (prrr-state-test--write "1" "PR_1" 'withdraw
                                                     '(:review-request nil :assignee t))))))
      (should (equal '((user "example-me")) (prrr-pr-meta-review-requests shown)))
      (should (equal "RR_1" (prrr-pr-meta-viewer-latest-review-request shown)))
      (should-not (prrr-pr-meta-assignees shown)))
    (should (eq meta (prrr-state-withdrawn-meta
                      meta (list (prrr-state-test--write "1" "PR_2" 'withdraw
                                                         '(:review-request t :assignee t))
                                 (prrr-state-test--write "2" "PR_1" 'viewed '(:path "a")))))))
  (should-not (prrr-state-withdrawn-meta nil nil)))

(ert-deftest prrr-state-test-outbox-landed-withdraw ()
  "Review data cannot tell whether a Withdraw landed, and sending it again is harmless."
  (should (eq 'missing (prrr-state-outbox-landed
                        (prrr-state-test--unconfirmed "1" 'withdraw '(:review-request t :assignee t))
                        (prrr-state-test--fresh) nil))))

(ert-deftest prrr-state-test-outbox-describe-withdraw ()
  (should (equal "withdraw (review request and assignment)"
                 (prrr-state-outbox-describe
                  (prrr-state-test--write "1" "PR_1" 'withdraw '(:review-request t :assignee t)))))
  (should (equal "withdraw (review request)"
                 (prrr-state-outbox-describe
                  (prrr-state-test--write "1" "PR_1" 'withdraw '(:review-request t :assignee nil)))))
  (should (equal "withdraw (assignment)"
                 (prrr-state-outbox-describe
                  (prrr-state-test--write "1" "PR_1" 'withdraw '(:review-request nil :assignee t))))))

(provide 'prrr-state-test)
;;; prrr-state-test.el ends here

(ert-deftest prrr-state-test-outbox-agent-flag-reaches-comment ()
  "An agent's write shows as an agent comment before and after GitHub accepts it."
  (let* ((row (prrr-outbox-create
               :id "1" :pr-id "PR_1" :kind 'thread :attempts 0
               :payload (list :target (list :me "example-me") :thread "local:t" :comment "local:c"
                              :anchor '(:path "a.el" :line 3 :side right :subject-type line)
                              :body "Nit" :commit prrr-test-head :agent t)))
         (view (prrr-state-outbox-view (list :threads nil :comments nil) (list row)))
         (created (car (prrr-state-outbox-created
                        row '(:comment-id "C_1" :database-id "11" :created-at "2026-10-12T00:00:00Z"
                              :thread-id "T_1" :review-id "R_1")))))
    (should (prrr-comment-agent-p (car (plist-get view :comments))))
    (should (prrr-comment-agent-p (seq-find #'prrr-comment-p created)))))

(ert-deftest prrr-state-test-outbox-user-write-is-not-agent ()
  (let ((row (prrr-outbox-create :id "1" :pr-id "PR_1" :kind 'reply :attempts 0
                                 :payload (list :target (list :me "example-me") :comment "local:c"
                                                :thread-id "T_1" :body "Yes"))))
    (should-not (prrr-comment-agent-p
                 (car (plist-get (prrr-state-outbox-view (list :threads nil :comments nil) (list row))
                                 :comments))))))

;;;; Proposed comments

(defun prrr-state-test--proposal (id as)
  "A `proposed' write ID made as the kind AS."
  (prrr-outbox-create :id id :pr-id "PR_1" :kind 'proposed :attempts 0
                      :payload (append (list :target (list :me "example-me") :as as
                                             :comment (concat "local:c" id) :agent t
                                             :body "Maybe" :commit prrr-test-head)
                                       (if (eq as 'thread)
                                           (list :thread (concat "local:t" id)
                                                 :anchor '(:path "a.el" :line 3 :side right
                                                           :subject-type line))
                                         (list :thread-id "T_1")))))

(ert-deftest prrr-state-test-proposed-rows-never-send-nor-block ()
  "Review Focus 5: a proposal ahead of a PR's other writes does not hold them back."
  (let* ((target (list :me "example-me"))
         (proposal (prrr-outbox-create :id "1" :pr-id "PR_1" :kind 'proposed :attempts 0
                                       :payload (list :target target :as 'thread :thread "local:t"
                                                      :comment "local:c" :agent t :body "Maybe"
                                                      :anchor '(:path "a.el" :line 3 :side right :subject-type line)
                                                      :commit prrr-test-head)))
         (reply (prrr-outbox-create :id "2" :pr-id "PR_1" :kind 'reply :attempts 0
                                    :payload (list :target target :comment "local:r"
                                                   :thread-id "T_1" :body "Yes"))))
    (should (prrr-state-outbox-held-p proposal))
    (should (equal "2" (prrr-outbox-id (car (prrr-state-outbox-next (list proposal reply) nil 0.0)))))
    (should (equal '("PR_1") (prrr-state-outbox-busy-prs (list proposal reply))))
    (should-not (prrr-state-outbox-next (list proposal) nil 0.0))))

(ert-deftest prrr-state-test-proposed-row-shows-as-proposed-agent-comment ()
  (let* ((row (prrr-outbox-create :id "1" :pr-id "PR_1" :kind 'proposed :attempts 0
                                  :payload (list :target (list :me "example-me") :as 'thread
                                                 :thread "local:t" :comment "local:c" :agent t
                                                 :body "Maybe"
                                                 :anchor '(:path "a.el" :line 3 :side right :subject-type line)
                                                 :commit prrr-test-head)))
         (view (prrr-state-outbox-view (list :threads nil :comments nil) (list row)))
         (comment (car (plist-get view :comments))))
    (should (eq 'proposed (prrr-comment-local-state comment)))
    (should (eq 'pending (prrr-comment-state comment)))
    (should (prrr-comment-agent-p comment))
    (should (equal "local:t" (prrr-thread-thread-id (car (plist-get view :threads)))))))

(ert-deftest prrr-state-test-proposed-reply-shows-in-its-thread ()
  (let* ((view (prrr-state-outbox-view (list :threads nil :comments nil)
                                       (list (prrr-state-test--proposal "1" 'reply))))
         (comment (car (plist-get view :comments))))
    (should (equal "T_1" (prrr-comment-thread-id comment)))
    (should (equal "local:c1" (prrr-comment-comment-id comment)))
    (should (eq 'proposed (prrr-comment-local-state comment)))
    (should (eq 'pending (prrr-comment-state comment)))
    (should-not (plist-get view :threads))))

(ert-deftest prrr-state-test-proposed-survives-a-discard-in-view ()
  "A discard drops the Pending Review, which proposals are not part of."
  (let ((view (prrr-state-outbox-view
               (list :threads nil :comments nil)
               (list (prrr-state-test--proposal "1" 'thread)
                     (prrr-state-test--write "2" "PR_1" 'discard nil)))))
    (should (equal '("local:c1") (mapcar #'prrr-comment-comment-id (plist-get view :comments))))
    (should (equal '("local:t1") (mapcar #'prrr-thread-thread-id (plist-get view :threads))))))

(ert-deftest prrr-state-test-proposed-describe ()
  (should (equal "proposed comment: Maybe"
                 (prrr-state-outbox-describe (prrr-state-test--proposal "1" 'thread)))))

(ert-deftest prrr-state-test-proposed-reply-depends-on-its-thread ()
  "Dropping a queued Thread takes the proposed replies to it along."
  (let ((reply (prrr-state-test--proposal "2" 'reply)))
    (setf (prrr-outbox-payload reply) (plist-put (prrr-outbox-payload reply) :thread-id "local:t1"))
    (should (equal (list reply)
                   (prrr-state-outbox-dependents (list (prrr-state-test--proposal "1" 'thread) reply)
                                                 '("local:t1"))))))

(ert-deftest prrr-state-test-proposal-is-not-in-the-pending-review ()
  (let ((view (prrr-state-outbox-view (list :threads nil :comments nil)
                                      (list (prrr-state-test--proposal "1" 'thread)))))
    (should-not (seq-filter #'prrr-state-comment-pending-p (plist-get view :comments))))
  (should (prrr-state-comment-pending-p
           (prrr-comment-create :comment-id "C" :state 'pending :local-state 'unsent)))
  (should-not (prrr-state-comment-pending-p
               (prrr-comment-create :comment-id "C" :state 'submitted :local-state 'sent))))

(ert-deftest prrr-state-test-proposal-accepted ()
  "Accepting keeps the proposal's id and local ids, so what needs them still finds them."
  (let* ((proposal (prrr-state-test--proposal "1" 'thread))
         (accepted (prrr-state-outbox-accepted proposal "Surely")))
    (should (eq 'thread (prrr-outbox-kind accepted)))
    (should (equal "1" (prrr-outbox-id accepted)))
    (should (equal "Surely" (plist-get (prrr-outbox-payload accepted) :body)))
    (should (plist-get (prrr-outbox-payload accepted) :agent))
    (should-not (plist-member (prrr-outbox-payload accepted) :as))
    (should (equal (prrr-state-outbox-created-ids proposal)
                   (prrr-state-outbox-created-ids accepted)))
    ;; The proposal itself is unchanged.
    (should (eq 'proposed (prrr-outbox-kind proposal)))
    (should (equal "Maybe" (plist-get (prrr-outbox-payload proposal) :body)))))

(ert-deftest prrr-state-test-write-on-a-proposal-never-blocks-its-pr ()
  "Review Focus 5: a write that needs what a proposal creates waits apart.
It cannot be sent before the proposal is accepted, so it is skipped
rather than held at the head of its PR, and later writes still go."
  (let* ((proposal (prrr-state-test--proposal "1" 'thread))
         (reply (prrr-state-test--write "2" "PR_1" 'reply
                                        '(:thread-id "local:t1" :comment "local:r" :body "Yes")))
         (viewed (prrr-state-test--write "3" "PR_1" 'viewed '(:path "a.el" :viewed t)))
         (rows (list proposal reply viewed)))
    (should (prrr-state-outbox-needs-proposal-p reply rows))
    (should-not (prrr-state-outbox-needs-proposal-p viewed rows))
    (should-not (prrr-state-outbox-needs-proposal-p proposal rows))
    (should (equal "3" (prrr-outbox-id (car (prrr-state-outbox-next rows nil 0.0)))))
    (should (equal '("PR_1") (prrr-state-outbox-busy-prs rows)))
    (should-not (prrr-state-outbox-next (list proposal reply) nil 0.0))))
