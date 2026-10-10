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

(provide 'prrr-state-test)
;;; prrr-state-test.el ends here
