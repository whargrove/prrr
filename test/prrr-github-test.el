;;; prrr-github-test.el --- Tests for prrr-github  -*- lexical-binding: t -*-

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

;; Decoders run against the recorded fixtures under
;; test/fixtures/github/; request functions run with `ghub-query'
;; stubbed, so nothing here touches the network.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'prrr-test-helper)
(require 'prrr-github)

(ert-deftest prrr-github-test-decode-queue-one-meta-per-pr ()
  (let ((metas (prrr-github-decode-queue (prrr-test-fixture "queue")
                                         "example-repo-id" "2026-10-10T12:00:00Z")))
    (should (= 3 (length metas)))
    (should (cl-every #'prrr-pr-meta-p metas))
    (should (equal '("PR_kwDOexample0000001" "PR_kwDOexample0000002"
                     "PR_kwDOexample0000003")
                   (mapcar #'prrr-pr-meta-pr-id metas)))
    (should (equal '(1 2 3) (mapcar #'prrr-pr-meta-number metas)))
    (should (cl-every (lambda (m) (equal "example-repo-id" (prrr-pr-meta-forge-repo-id m)))
                      metas))
    (should (cl-every (lambda (m) (equal "2026-10-10T12:00:00Z" (prrr-pr-meta-fetched-at m)))
                      metas))))

(ert-deftest prrr-github-test-decode-queue-scalars ()
  (let ((meta (car (prrr-github-decode-queue (prrr-test-fixture "queue") nil))))
    (should (equal "1111111111111111111111111111111111111111" (prrr-pr-meta-head-oid meta)))
    (should (equal "2026-09-01T09:00:00Z" (prrr-pr-meta-created-at meta)))
    (should (null (prrr-pr-meta-fetched-at meta)))))

(ert-deftest prrr-github-test-decode-queue-review-requests-by-typename ()
  "Users become (user LOGIN), Teams (team COMBINED-SLUG); other kinds are dropped."
  (let ((meta (car (prrr-github-decode-queue (prrr-test-fixture "queue") nil))))
    (should (equal '((user "example-me") (team "example-org/reviewers"))
                   (prrr-pr-meta-review-requests meta)))))

(ert-deftest prrr-github-test-decode-queue-latest-reviews ()
  (let ((metas (prrr-github-decode-queue (prrr-test-fixture "queue") nil)))
    (should (equal '(("example-bob" "APPROVED" "2026-09-02T10:00:00Z"
                      "1111111111111111111111111111111111111111"
                      ("example-org/reviewers")))
                   (prrr-pr-meta-latest-reviews (nth 0 metas))))
    ;; Review Focus 2 and 5: a deleted author and a missing commit decode to nil.
    (should (equal '(("example-carol" "CHANGES_REQUESTED" "2026-09-06T07:00:00Z"
                      "3333333333333333333333333333333333333333" nil)
                     (nil "DISMISSED" "2026-09-05T12:00:00Z" nil nil))
                   (prrr-pr-meta-latest-reviews (nth 2 metas))))))

(ert-deftest prrr-github-test-decode-queue-viewer-fields ()
  (let ((metas (prrr-github-decode-queue (prrr-test-fixture "queue") nil)))
    (should (null (prrr-pr-meta-viewer-latest-review (nth 0 metas))))
    (should (equal "example-alice" (prrr-pr-meta-viewer-latest-review-request (nth 0 metas))))
    (should (equal '("COMMENTED" "2026-09-04T08:00:00Z"
                     "2222222222222222222222222222222222222200")
                   (prrr-pr-meta-viewer-latest-review (nth 1 metas))))
    (should (null (prrr-pr-meta-viewer-latest-review-request (nth 1 metas))))))

(ert-deftest prrr-github-test-decode-queue-empty-repository ()
  (should (null (prrr-github-decode-queue '(data (repository (pullRequests))) nil))))

(ert-deftest prrr-github-test-fetch-queue-sends-query-and-decodes ()
  (prrr-test-with-ghub-stub (prrr-test-fixture "queue") captured
    (let (result)
      (prrr-github-fetch-queue "api.github.com" "example-org" "example-repo"
                               (lambda (metas) (setq result metas))
                               "example-repo-id")
      (should (equal `(query ,prrr-github-queue-query) (nth 0 captured)))
      (should (equal '((owner . "example-org") (name . "example-repo")) (nth 1 captured)))
      (should (= 3 (length result)))
      (should (equal "example-repo-id" (prrr-pr-meta-forge-repo-id (car result))))
      (should (stringp (prrr-pr-meta-fetched-at (car result)))))))

(ert-deftest prrr-github-test-queue-query-shape ()
  "The query pages open PRs and selects both reviewer kinds."
  (should (eq 'repository (car prrr-github-queue-query)))
  (let ((prs (assq 'pullRequests (cddr prrr-github-queue-query))))
    (should (member '(:edges t) (append (cadr prs) nil)))
    (should (member '(states . (OPEN)) (append (cadr prs) nil)))
    (should (string-match-p "__typename.*on User { login }.*on Team { combinedSlug }"
                            (format "%S" prs)))))

(provide 'prrr-github-test)
;;; prrr-github-test.el ends here
