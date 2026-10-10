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

(defconst prrr-state-test--me "example-me")
(defconst prrr-state-test--teams '("example-org/reviewers"))
(defconst prrr-state-test--head "1111111111111111111111111111111111111111")
(defconst prrr-state-test--old "0000000000000000000000000000000000000000")

(cl-defun prrr-state-test--pr (&key (id "PR_1") (number 1) (title "Example")
                                    (author "example-alice") draft-p assignees
                                    (created-at "2026-09-01T00:00:00Z")
                                    (updated-at "2026-09-05T00:00:00Z")
                                    (head-oid prrr-state-test--head)
                                    (base-ref "main") (head-ref "feature-1")
                                    cross-repo-p)
  "Build a `prrr-pr' with sensible defaults.
Keyword arguments: ID, NUMBER, TITLE, AUTHOR, DRAFT-P, ASSIGNEES,
CREATED-AT, UPDATED-AT, HEAD-OID, BASE-REF, HEAD-REF and CROSS-REPO-P."
  (prrr-pr-create :id id :number number :title title :author author
                  :draft-p draft-p :assignees assignees :created-at created-at
                  :updated-at updated-at :head-oid head-oid :base-ref base-ref
                  :head-ref head-ref :cross-repo-p cross-repo-p))

(cl-defun prrr-state-test--meta (&key (pr-id "PR_1") (head-oid prrr-state-test--head)
                                      review-requests latest-reviews
                                      viewer-latest-review viewer-latest-review-request
                                      (created-at "2026-09-01T00:00:00Z"))
  "Build a `prrr-pr-meta' with sensible defaults.
Keyword arguments: PR-ID, HEAD-OID, REVIEW-REQUESTS, LATEST-REVIEWS,
VIEWER-LATEST-REVIEW, VIEWER-LATEST-REVIEW-REQUEST and CREATED-AT."
  (prrr-pr-meta-create :pr-id pr-id :forge-repo-id "example-repo-id" :number 1
                       :head-oid head-oid :review-requests review-requests
                       :latest-reviews latest-reviews
                       :viewer-latest-review viewer-latest-review
                       :viewer-latest-review-request viewer-latest-review-request
                       :created-at created-at :fetched-at "2026-10-10T12:00:00Z"))

(defun prrr-state-test--state (pr meta)
  "Review State of PR with META for the test viewer and Teams."
  (prrr-state-review-state pr meta prrr-state-test--me prrr-state-test--teams))

;;;; Review State, For Me group (SPEC section 5, first match wins)

(ert-deftest prrr-state-test-review-state-new-commits ()
  "My latest submitted review is on a commit other than head."
  (should (eq 'new-commits
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--old))))))

(ert-deftest prrr-state-test-review-state-new-commits-beats-requested ()
  (should (eq 'new-commits
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :review-requests '((user "example-me"))
                :viewer-latest-review (list "COMMENTED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--old))))))

(ert-deftest prrr-state-test-review-state-new-commits-needs-a-commit ()
  "Review Focus 5: a review whose commit is gone (nil) is not new-commits."
  (should (eq 'approved
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :viewer-latest-review '("APPROVED" "2026-09-02T00:00:00Z" nil))))))

(ert-deftest prrr-state-test-review-state-requested-from-review-requests ()
  (should (eq 'requested
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta :review-requests '((user "example-me")))))))

(ert-deftest prrr-state-test-review-state-re-requested-after-my-review ()
  "A fresh request after my review at head wins over my old verdict."
  (should (eq 'requested
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :review-requests '((user "example-me"))
                :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--head))))))

(ert-deftest prrr-state-test-review-state-requested-from-viewer-request-without-review ()
  (should (eq 'requested
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta :viewer-latest-review-request "example-alice")))))

(ert-deftest prrr-state-test-review-state-old-viewer-request-does-not-outrank-my-review ()
  "The viewerLatestReviewRequest is history once I reviewed and left reviewRequests."
  (should (eq 'approved
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :viewer-latest-review-request "example-alice"
                :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--head))))))

(ert-deftest prrr-state-test-review-state-team-requested ()
  (should (eq 'team-requested
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta :review-requests '((team "example-org/reviewers")))))))

(ert-deftest prrr-state-test-review-state-other-team-request-is-nothing ()
  (should (null (prrr-state-test--state
                 (prrr-state-test--pr)
                 (prrr-state-test--meta :review-requests '((team "example-org/platform")))))))

(ert-deftest prrr-state-test-review-state-teammate-reviewed ()
  "Someone else reviewed on behalf of one of my Teams."
  (should (eq 'teammate-reviewed
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :latest-reviews (list (list "example-bob" "APPROVED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--head
                                            '("example-org/reviewers"))))))))

(ert-deftest prrr-state-test-review-state-teammate-review-satisfies-team-request ()
  "A Team request still listed is served once a teammate reviewed for the Team."
  (should (eq 'teammate-reviewed
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :review-requests '((team "example-org/reviewers"))
                :latest-reviews (list (list "example-bob" "COMMENTED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--head
                                            '("example-org/reviewers"))))))))

(ert-deftest prrr-state-test-review-state-my-own-on-behalf-review-is-not-a-teammate ()
  (should (eq 'approved
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :latest-reviews (list (list "example-me" "APPROVED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--head
                                            '("example-org/reviewers")))
                :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--head))))))

(ert-deftest prrr-state-test-review-state-changes-requested ()
  (should (eq 'changes-requested
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :viewer-latest-review (list "CHANGES_REQUESTED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--head))))))

(ert-deftest prrr-state-test-review-state-approved ()
  (should (eq 'approved
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :viewer-latest-review (list "APPROVED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--head))))))

(ert-deftest prrr-state-test-review-state-commented ()
  (should (eq 'commented
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :viewer-latest-review (list "COMMENTED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--head))))))

(ert-deftest prrr-state-test-review-state-dismissed-counts-as-commented ()
  "A dismissed verdict is still a touch; it shows as commented."
  (should (eq 'commented
              (prrr-state-test--state
               (prrr-state-test--pr)
               (prrr-state-test--meta
                :viewer-latest-review (list "DISMISSED" "2026-09-02T00:00:00Z"
                                            prrr-state-test--head))))))

(ert-deftest prrr-state-test-review-state-pending-viewer-review-is-ignored ()
  "Review Focus 1: my unsubmitted Pending Review is not a touch."
  (should (null (prrr-state-test--state
                 (prrr-state-test--pr)
                 (prrr-state-test--meta
                  :viewer-latest-review (list "PENDING" nil prrr-state-test--old)))))
  (should (eq 'assigned
              (prrr-state-test--state
               (prrr-state-test--pr :assignees '("example-me"))
               (prrr-state-test--meta
                :viewer-latest-review (list "PENDING" nil prrr-state-test--old))))))

(ert-deftest prrr-state-test-review-state-assigned ()
  (should (eq 'assigned
              (prrr-state-test--state (prrr-state-test--pr :assignees '("example-bob" "example-me"))
                                      (prrr-state-test--meta)))))

(ert-deftest prrr-state-test-review-state-assigned-without-meta ()
  (should (eq 'assigned
              (prrr-state-test--state (prrr-state-test--pr :assignees '("example-me")) nil))))

(ert-deftest prrr-state-test-review-state-nothing ()
  (should (null (prrr-state-test--state (prrr-state-test--pr) (prrr-state-test--meta))))
  (should (null (prrr-state-test--state (prrr-state-test--pr) nil))))

(ert-deftest prrr-state-test-review-state-order-is-first-match ()
  "The states are tried in SPEC order."
  (should (equal '(new-commits requested team-requested teammate-reviewed
                   changes-requested approved commented assigned)
                 prrr-state-for-me-order)))

;;;; Mine state

(defun prrr-state-test--mine (pr meta)
  "Mine state of PR with META for the test viewer."
  (prrr-state-mine-state pr meta prrr-state-test--me))

(ert-deftest prrr-state-test-mine-state-draft ()
  (should (eq 'draft (prrr-state-test--mine
                      (prrr-state-test--pr :author "example-me" :draft-p t)
                      (prrr-state-test--meta
                       :latest-reviews '(("example-carol" "CHANGES_REQUESTED"
                                          "2026-09-02T00:00:00Z" "abc" nil)))))))

(ert-deftest prrr-state-test-mine-state-awaiting-review ()
  (should (eq 'awaiting-review
              (prrr-state-test--mine (prrr-state-test--pr :author "example-me")
                                     (prrr-state-test--meta))))
  (should (eq 'awaiting-review
              (prrr-state-test--mine (prrr-state-test--pr :author "example-me") nil))))

(ert-deftest prrr-state-test-mine-state-changes-requested-beats-approved ()
  (should (eq 'changes-requested
              (prrr-state-test--mine
               (prrr-state-test--pr :author "example-me")
               (prrr-state-test--meta
                :latest-reviews '(("example-dave" "APPROVED" "2026-09-02T00:00:00Z" "abc" nil)
                                  ("example-carol" "CHANGES_REQUESTED" "2026-09-03T00:00:00Z" "abc" nil)))))))

(ert-deftest prrr-state-test-mine-state-approved-beats-commented ()
  (should (eq 'approved
              (prrr-state-test--mine
               (prrr-state-test--pr :author "example-me")
               (prrr-state-test--meta
                :latest-reviews '(("example-dave" "COMMENTED" "2026-09-02T00:00:00Z" "abc" nil)
                                  ("example-carol" "APPROVED" "2026-09-03T00:00:00Z" "abc" nil)))))))

(ert-deftest prrr-state-test-mine-state-reviewed ()
  "COMMENTED and DISMISSED reviews by others mean reviewed."
  (should (eq 'reviewed
              (prrr-state-test--mine
               (prrr-state-test--pr :author "example-me")
               (prrr-state-test--meta
                :latest-reviews '(("example-dave" "COMMENTED" "2026-09-02T00:00:00Z" "abc" nil))))))
  (should (eq 'reviewed
              (prrr-state-test--mine
               (prrr-state-test--pr :author "example-me")
               (prrr-state-test--meta
                :latest-reviews '(("example-dave" "DISMISSED" "2026-09-02T00:00:00Z" nil nil)))))))

(ert-deftest prrr-state-test-mine-state-ignores-my-own-review ()
  (should (eq 'awaiting-review
              (prrr-state-test--mine
               (prrr-state-test--pr :author "example-me")
               (prrr-state-test--meta
                :latest-reviews '(("example-me" "APPROVED" "2026-09-02T00:00:00Z" "abc" nil)))))))

(ert-deftest prrr-state-test-mine-state-deleted-reviewer ()
  "A review with a nil login counts as someone else's."
  (should (eq 'changes-requested
              (prrr-state-test--mine
               (prrr-state-test--pr :author "example-me")
               (prrr-state-test--meta
                :latest-reviews '((nil "CHANGES_REQUESTED" "2026-09-02T00:00:00Z" nil nil)))))))

(ert-deftest prrr-state-test-mine-order ()
  (should (equal '(changes-requested awaiting-review approved reviewed draft)
                 prrr-state-mine-order)))

;;;; For Me membership

(defun prrr-state-test--for-me-p (pr meta)
  "Whether PR with META is in For Me for the test viewer."
  (prrr-state-for-me-p pr meta prrr-state-test--me prrr-state-test--teams))

(ert-deftest prrr-state-test-for-me-p-requested ()
  (should (prrr-state-test--for-me-p (prrr-state-test--pr)
                                     (prrr-state-test--meta :review-requests '((user "example-me"))))))

(ert-deftest prrr-state-test-for-me-p-team-requested ()
  (should (prrr-state-test--for-me-p (prrr-state-test--pr)
                                     (prrr-state-test--meta :review-requests '((team "example-org/reviewers"))))))

(ert-deftest prrr-state-test-for-me-p-teammate-reviewed ()
  (should (prrr-state-test--for-me-p
           (prrr-state-test--pr)
           (prrr-state-test--meta
            :latest-reviews (list (list "example-bob" "APPROVED" "2026-09-02T00:00:00Z"
                                        prrr-state-test--head '("example-org/reviewers")))))))

(ert-deftest prrr-state-test-for-me-p-assigned ()
  (should (prrr-state-test--for-me-p (prrr-state-test--pr :assignees '("example-me")) nil)))

(ert-deftest prrr-state-test-for-me-p-ever-reviewed-by-me ()
  (should (prrr-state-test--for-me-p
           (prrr-state-test--pr)
           (prrr-state-test--meta
            :viewer-latest-review (list "COMMENTED" "2026-09-02T00:00:00Z" prrr-state-test--head)))))

(ert-deftest prrr-state-test-for-me-p-nothing ()
  (should-not (prrr-state-test--for-me-p (prrr-state-test--pr) (prrr-state-test--meta)))
  (should-not (prrr-state-test--for-me-p (prrr-state-test--pr) nil)))

(ert-deftest prrr-state-test-for-me-p-never-my-own-pr ()
  (should-not (prrr-state-test--for-me-p
               (prrr-state-test--pr :author "example-me" :assignees '("example-me"))
               (prrr-state-test--meta :review-requests '((user "example-me"))))))

(ert-deftest prrr-state-test-for-me-p-draft-excluded-unless-direct ()
  "Drafts are out even when team-requested or reviewed by me ..."
  (should-not (prrr-state-test--for-me-p
               (prrr-state-test--pr :draft-p t)
               (prrr-state-test--meta :review-requests '((team "example-org/reviewers")))))
  (should-not (prrr-state-test--for-me-p
               (prrr-state-test--pr :draft-p t)
               (prrr-state-test--meta
                :viewer-latest-review (list "COMMENTED" "2026-09-02T00:00:00Z" prrr-state-test--head))))
  ;; ... but in when requested directly from me or assigned to me.
  (should (prrr-state-test--for-me-p
           (prrr-state-test--pr :draft-p t)
           (prrr-state-test--meta :review-requests '((user "example-me")))))
  (should (prrr-state-test--for-me-p (prrr-state-test--pr :draft-p t :assignees '("example-me"))
                                     nil)))

;;;; Partition

(ert-deftest prrr-state-test-partition-awaiting-states ()
  (dolist (state '(new-commits requested team-requested assigned))
    (should (eq 'awaiting (prrr-state-partition (prrr-state-test--pr) state)))))

(ert-deftest prrr-state-test-partition-served-states ()
  (dolist (state '(teammate-reviewed changes-requested approved commented))
    (should (eq 'served (prrr-state-partition (prrr-state-test--pr) state)))))

(ert-deftest prrr-state-test-partition-draft-is-always-served ()
  "A draft requested from me stays out of Awaiting me until marked ready."
  (should (eq 'served (prrr-state-partition (prrr-state-test--pr :draft-p t) 'requested)))
  (should (eq 'served (prrr-state-partition (prrr-state-test--pr :draft-p t) 'assigned))))

;;;; Stacks

(defun prrr-state-test--ids (stacks)
  "Ids of STACKS, a list of lists of `prrr-pr'."
  (mapcar (lambda (stack) (mapcar #'prrr-pr-id stack)) stacks))

(ert-deftest prrr-state-test-stacks-chain-bottom-first ()
  "A chain is one Stack, bottom first, whatever the input order."
  (let ((bottom (prrr-state-test--pr :id "B" :base-ref "main" :head-ref "step-1"))
        (middle (prrr-state-test--pr :id "M" :base-ref "step-1" :head-ref "step-2"))
        (top (prrr-state-test--pr :id "T" :base-ref "step-2" :head-ref "step-3")))
    (should (equal '(("B" "M" "T"))
                   (prrr-state-test--ids (prrr-state-stacks (list top bottom middle) "main"))))
    (should (equal '(("B" "M" "T"))
                   (prrr-state-test--ids (prrr-state-stacks (list bottom middle top) "main"))))))

(ert-deftest prrr-state-test-stacks-independent-prs-are-singletons ()
  "PRs whose bases are neither the default branch nor another open head are singletons."
  (let ((a (prrr-state-test--pr :id "A" :head-ref "a"))
        (b (prrr-state-test--pr :id "B" :head-ref "b")))
    (should (equal '(("A") ("B")) (prrr-state-test--ids (prrr-state-stacks (list a b) "main"))))))

(ert-deftest prrr-state-test-stacks-parent-must-be-open ()
  "A PR whose parent was merged (absent from PRS) is a bottom on its own."
  (let ((orphan (prrr-state-test--pr :id "O" :base-ref "merged-branch" :head-ref "o")))
    (should (equal '(("O")) (prrr-state-test--ids (prrr-state-stacks (list orphan) "main"))))))

(ert-deftest prrr-state-test-stacks-cross-repo-parent-is-not-a-parent ()
  "A fork PR's head is not a base for anyone."
  (let ((fork (prrr-state-test--pr :id "F" :base-ref "main" :head-ref "feature" :cross-repo-p t))
        (child (prrr-state-test--pr :id "C" :base-ref "feature" :head-ref "child")))
    (should (equal '(("F") ("C")) (prrr-state-test--ids (prrr-state-stacks (list fork child) "main"))))))

(ert-deftest prrr-state-test-stacks-deleted-branches ()
  "Nil refs never match."
  (let ((no-head (prrr-state-test--pr :id "H" :base-ref "main" :head-ref nil))
        (no-base (prrr-state-test--pr :id "N" :base-ref nil :head-ref "n"))
        (child (prrr-state-test--pr :id "C" :base-ref "n" :head-ref "c")))
    (should (equal '(("H") ("N" "C"))
                   (prrr-state-test--ids (prrr-state-stacks (list no-head no-base child) "main"))))))

(ert-deftest prrr-state-test-stacks-cycle-terminates ()
  "Two PRs based on each other form one Stack, once."
  (let ((a (prrr-state-test--pr :id "A" :base-ref "b" :head-ref "a"))
        (b (prrr-state-test--pr :id "B" :base-ref "a" :head-ref "b")))
    (let ((stacks (prrr-state-stacks (list a b) "main")))
      (should (= 1 (length stacks)))
      (should (equal '("A" "B") (sort (mapcar #'prrr-pr-id (car stacks)) #'string<))))))

(ert-deftest prrr-state-test-stacks-branching-stack-keeps-siblings-after-parent ()
  "Two PRs on the same parent stay in the parent's Stack, depth first."
  (let ((bottom (prrr-state-test--pr :id "B" :base-ref "main" :head-ref "base"))
        (left (prrr-state-test--pr :id "L" :base-ref "base" :head-ref "left"))
        (left-top (prrr-state-test--pr :id "LT" :base-ref "left" :head-ref "left-top"))
        (right (prrr-state-test--pr :id "R" :base-ref "base" :head-ref "right")))
    (should (equal '(("B" "L" "LT" "R"))
                   (prrr-state-test--ids
                    (prrr-state-stacks (list bottom left left-top right) "main"))))))

(ert-deftest prrr-state-test-stacks-default-branch-is-never-a-parent ()
  "A PR based on the default branch is a bottom even if some PR's head has that name."
  (let ((odd (prrr-state-test--pr :id "O" :base-ref "develop" :head-ref "main"))
        (normal (prrr-state-test--pr :id "N" :base-ref "main" :head-ref "n")))
    (should (equal '(("O") ("N")) (prrr-state-test--ids (prrr-state-stacks (list odd normal) "main"))))))

(provide 'prrr-state-test)
;;; prrr-state-test.el ends here
