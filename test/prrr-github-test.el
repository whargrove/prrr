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
    (should (equal "RR_kwDOexample0000001" (prrr-pr-meta-viewer-latest-review-request (nth 0 metas))))
    (should (equal '("COMMENTED" "2026-09-04T08:00:00Z"
                     "2222222222222222222222222222222222222200")
                   (prrr-pr-meta-viewer-latest-review (nth 1 metas))))
    (should (null (prrr-pr-meta-viewer-latest-review-request (nth 1 metas))))))

(ert-deftest prrr-github-test-decode-queue-assignees ()
  (let ((metas (prrr-github-decode-queue (prrr-test-fixture "queue") nil)))
    (should (equal '("example-me" "example-bob") (prrr-pr-meta-assignees (nth 0 metas))))
    (should (null (prrr-pr-meta-assignees (nth 1 metas))))))

(ert-deftest prrr-github-test-decode-queue-empty-repository ()
  (should (null (prrr-github-decode-queue '(data (repository (pullRequests))) nil))))

(ert-deftest prrr-github-test-fetch-queue-sends-query-and-decodes ()
  (prrr-test-with-ghub-stub (prrr-test-fixture "queue") captured
    (let (result)
      (prrr-github-fetch-queue "api.github.com" "example-org" "example-repo"
                               (lambda (metas) (setq result metas))
                               (lambda (err) (ert-fail (list "unexpected errorback" err)))
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

(ert-deftest prrr-github-test-decode-teams ()
  (let ((teams (prrr-github-decode-teams (prrr-test-fixture "teams")
                                         "2026-10-10T12:00:00Z")))
    (should (= 2 (length teams)))
    (should (cl-every #'prrr-team-p teams))
    (should (equal '("example-org/reviewers" "example-org/platform")
                   (mapcar #'prrr-team-combined-slug teams)))
    (should (equal '("reviewers" "platform") (mapcar #'prrr-team-slug teams)))
    (should (equal '("example-org" "example-org") (mapcar #'prrr-team-org teams)))
    (should (equal "2026-10-10T12:00:00Z" (prrr-team-fetched-at (car teams))))))

(ert-deftest prrr-github-test-decode-teams-no-organizations ()
  (should (null (prrr-github-decode-teams
                 '(data (viewer (login . "example-me") (organizations)))))))

(ert-deftest prrr-github-test-fetch-teams-sends-login-and-decodes ()
  (prrr-test-with-ghub-stub (prrr-test-fixture "teams") captured
    (let (result)
      (prrr-github-fetch-teams "api.github.com" "example-me"
                               (lambda (teams) (setq result teams))
                               (lambda (err) (ert-fail (list "unexpected errorback" err))))
      (should (equal `(query ,prrr-github-teams-query) (nth 0 captured)))
      (should (equal (list (cons (quote me) ["example-me"])) (nth 1 captured)))
      (should (= 2 (length result)))
      (should (stringp (prrr-team-fetched-at (car result)))))))

(defun prrr-github-test--review-data ()
  "Decode the review-data fixture for PR_kwDOexample0000001."
  (prrr-github-decode-review-data (prrr-test-fixture "review-data")
                                  "PR_kwDOexample0000001"
                                  "2026-10-10T12:00:00Z"))

(ert-deftest prrr-github-test-decode-review-data-crlf-body ()
  "Bodies written in GitHub's web UI end lines with CRLF; suggestions in them must still show."
  (let* ((crlf "Try:\r\n```suggestion\r\n(when x\r\n```\r\n")
         (data (cl-subst crlf "Typo in the title." (prrr-test-fixture "review-data")
                         :test #'equal))
         (comment (seq-find (lambda (c) (string-prefix-p "Try:" (prrr-comment-body c)))
                            (plist-get (prrr-github-decode-review-data data "PR_1") :comments))))
    (should (equal "Try:\n```suggestion\n(when x\n```\n" (prrr-comment-body comment)))
    (should (equal '((text . "Try:") (suggestion "(when x"))
                   (prrr-state-split-suggestions (prrr-comment-body comment))))))

(ert-deftest prrr-github-test-decode-review-data-threads ()
  (let ((threads (plist-get (prrr-github-test--review-data) :threads)))
    (should (= 5 (length threads)))
    (should (cl-every #'prrr-thread-p threads))
    (should (cl-every (lambda (th) (equal "PR_kwDOexample0000001" (prrr-thread-pr-id th)))
                      threads))
    (let ((open (nth 0 threads)))
      (should (equal "PRRT_kwDOexample0000001" (prrr-thread-thread-id open)))
      (should (equal "src/example.el" (prrr-thread-path open)))
      (should (= 12 (prrr-thread-line open)))
      (should (null (prrr-thread-start-line open)))
      (should (eq 'right (prrr-thread-side open)))
      (should (null (prrr-thread-start-side open)))
      (should (eq 'line (prrr-thread-subject-type open)))
      (should (null (prrr-thread-outdated-p open)))
      (should (null (prrr-thread-resolved-p open)))
      (should (= 12 (prrr-thread-original-line open)))
      (should (equal "1111111111111111111111111111111111111111"
                     (prrr-thread-original-commit open)))
      (should (equal "2026-10-10T12:00:00Z" (prrr-thread-fetched-at open))))))

(ert-deftest prrr-github-test-decode-review-data-resolved-range-thread ()
  (let ((th (nth 1 (plist-get (prrr-github-test--review-data) :threads))))
    (should (eq t (prrr-thread-resolved-p th)))
    (should (= 1 (prrr-thread-start-line th)))
    (should (eq 'right (prrr-thread-start-side th)))))

(ert-deftest prrr-github-test-decode-review-data-outdated-thread ()
  (let ((th (nth 2 (plist-get (prrr-github-test--review-data) :threads))))
    (should (eq t (prrr-thread-outdated-p th)))
    (should (null (prrr-thread-line th)))
    (should (= 40 (prrr-thread-original-line th)))
    (should (eq 'left (prrr-thread-side th)))
    (should (equal "0000000000000000000000000000000000000001"
                   (prrr-thread-original-commit th)))))

(ert-deftest prrr-github-test-decode-review-data-file-thread ()
  (let ((th (nth 3 (plist-get (prrr-github-test--review-data) :threads))))
    (should (eq 'file (prrr-thread-subject-type th)))
    (should (null (prrr-thread-line th)))
    (should (equal "docs/notes.md" (prrr-thread-path th)))))

(ert-deftest prrr-github-test-decode-review-data-comments ()
  (let ((comments (plist-get (prrr-github-test--review-data) :comments)))
    (should (= 6 (length comments)))
    (should (cl-every #'prrr-comment-p comments))
    (let ((first (nth 0 comments)) (reply (nth 1 comments)) (pending (nth 5 comments)))
      (should (equal "PRRC_kwDOexample0000001" (prrr-comment-comment-id first)))
      (should (equal "PRRT_kwDOexample0000001" (prrr-comment-thread-id first)))
      (should (equal "PR_kwDOexample0000001" (prrr-comment-pr-id first)))
      (should (equal "example-bob" (prrr-comment-author first)))
      (should (equal "Should this be a `when'?" (prrr-comment-body first)))
      (should (equal "2026-09-02T10:00:00Z" (prrr-comment-created-at first)))
      (should (null (prrr-comment-updated-at first)))
      (should (null (prrr-comment-reply-to first)))
      (should (equal "PRR_kwDOexample0000001" (prrr-comment-review-id first)))
      (should (eq 'submitted (prrr-comment-state first)))
      (should (eq 'sent (prrr-comment-local-state first)))
      (should (null (prrr-comment-agent-p first)))
      (should (equal "PRRC_kwDOexample0000001" (prrr-comment-reply-to reply)))
      (should (equal "2026-09-02T11:05:00Z" (prrr-comment-updated-at reply)))
      (should (eq 'pending (prrr-comment-state pending)))
      (should (equal "PRR_kwDOexamplePending1" (prrr-comment-review-id pending))))))

(ert-deftest prrr-github-test-decode-review-data-pending-review ()
  (let ((pending (plist-get (prrr-github-test--review-data) :pending-review)))
    (should (prrr-pending-review-p pending))
    (should (equal "PR_kwDOexample0000001" (prrr-pending-review-pr-id pending)))
    (should (equal "PRR_kwDOexamplePending1" (prrr-pending-review-review-id pending)))
    (should (equal "1111111111111111111111111111111111111111"
                   (prrr-pending-review-commit-oid pending)))
    (should (equal "" (prrr-pending-review-body pending)))
    (should (equal "2026-09-04T09:00:00Z" (prrr-pending-review-created-at pending)))))

(ert-deftest prrr-github-test-decode-review-data-viewed ()
  (let ((viewed (plist-get (prrr-github-test--review-data) :viewed)))
    (should (equal '(("src/example.el" . viewed) ("README.md" . dismissed)
                     ("docs/notes.md" . unviewed))
                   (mapcar (lambda (v) (cons (prrr-viewed-path v) (prrr-viewed-state v)))
                           viewed)))
    (should (cl-every (lambda (v) (equal "PR_kwDOexample0000001" (prrr-viewed-pr-id v)))
                      viewed))
    (should (equal "2026-10-10T12:00:00Z" (prrr-viewed-fetched-at (car viewed))))))

(ert-deftest prrr-github-test-decode-review-data-head-oid ()
  (should (equal "1111111111111111111111111111111111111111"
                 (plist-get (prrr-github-test--review-data) :head-oid))))

(ert-deftest prrr-github-test-decode-review-data-without-pending-review ()
  (let ((result (prrr-github-decode-review-data
                 '(data (repository (pullRequest (id . "PR_1") (headRefOid . "abc")
                                                 (reviewThreads) (reviews) (files))))
                 "PR_1")))
    (should (null (plist-get result :threads)))
    (should (null (plist-get result :comments)))
    (should (null (plist-get result :pending-review)))
    (should (null (plist-get result :viewed)))
    (should (equal "abc" (plist-get result :head-oid)))))

(ert-deftest prrr-github-test-fetch-review-data-sends-variables-and-decodes ()
  (prrr-test-with-ghub-stub (prrr-test-fixture "review-data") captured
    (let (result)
      (prrr-github-fetch-review-data "api.github.com" "example-org" "example-repo" 1
                                     "example-me" (lambda (data) (setq result data))
                                     (lambda (err) (ert-fail (list "unexpected errorback" err))))
      (should (equal `(query ,prrr-github-review-data-query) (nth 0 captured)))
      (should (equal '((owner . "example-org") (name . "example-repo") (number . 1) (me . "example-me"))
                     (nth 1 captured)))
      (should (= 5 (length (plist-get result :threads))))
      (should (equal "PR_kwDOexample0000001"
                     (prrr-thread-pr-id (car (plist-get result :threads)))))
      (should (stringp (prrr-thread-fetched-at (car (plist-get result :threads))))))))


;;;; Errors (prrr-knu.1, prrr-knu.2)

(defconst prrr-github-test--now (encode-time '(0 0 12 10 10 2026 nil nil t))
  "2026-10-10T12:00:00Z as a Lisp time.")

(ert-deftest prrr-github-test-error-graphql-rate-limited ()
  (should (equal '(:kind rate-limited :message "API rate limit exceeded"
                   :reset-at "2026-10-10T12:30:00Z")
                 (prrr-github-error
                  '(errors ((type . "RATE_LIMITED") (message . "API rate limit exceeded")))
                  '(("X-RateLimit-Reset" . "1791635400"))
                  prrr-github-test--now))))

(ert-deftest prrr-github-test-error-graphql-not-found ()
  (should (eq 'not-found
              (plist-get (prrr-github-error
                          '(errors ((type . "NOT_FOUND")
                                    (message . "Could not resolve to a PullRequest with the number of 9."))))
                         :kind))))

(ert-deftest prrr-github-test-error-graphql-other-keeps-first-message ()
  (should (equal '(:kind error :message "Something broke" :reset-at nil)
                 (prrr-github-error '(errors ((message . "Something broke")) ((message . "And more")))))))

(ert-deftest prrr-github-test-error-http-401-is-auth ()
  (should (eq 'auth (plist-get (prrr-github-error '(error http 401)) :kind))))

(ert-deftest prrr-github-test-error-http-403-without-limit-headers-is-auth ()
  (should (eq 'auth (plist-get (prrr-github-error '(error http 403) nil) :kind))))

(ert-deftest prrr-github-test-error-http-403-naming-a-rate-limit-is-secondary-limit ()
  "GitHub's secondary limit is a 403 whose message names it; wait a minute.
x-ratelimit-reset belongs to the primary limit and must not set the wait."
  (should (equal '(:kind rate-limited :message "GitHub secondary rate limit (HTTP 403)"
                   :reset-at "2026-10-10T12:01:00Z")
                 (prrr-github-error
                  '(error http 403 ((message . "You have exceeded a secondary rate limit. Please wait a few minutes before you try again.")))
                  '(("x-ratelimit-remaining" . "12")
                    ("x-ratelimit-reset" . "1791633600"))
                  prrr-github-test--now))))

(ert-deftest prrr-github-test-error-http-403-with-quota-left-is-a-denial ()
  "A permission or SSO 403 carries quota headers too; it is no limit."
  (should (equal '(:kind auth
                   :message "GitHub denied access (HTTP 403): Resource protected by organization SAML enforcement."
                   :reset-at nil)
                 (prrr-github-error
                  '(error http 403 ((message . "Resource protected by organization SAML enforcement.")))
                  '(("x-ratelimit-remaining" . "4990")
                    ("x-ratelimit-reset" . "1791633600"))
                  prrr-github-test--now))))

(ert-deftest prrr-github-test-error-http-403-without-body-is-a-denial ()
  (should (equal '(:kind auth :message "GitHub denied access (HTTP 403)" :reset-at nil)
                 (prrr-github-error '(error http 403) '(("x-ratelimit-remaining" . "12"))))))

(ert-deftest prrr-github-test-error-http-429-without-headers-waits-a-minute ()
  (should (equal '(:kind rate-limited :message "GitHub secondary rate limit (HTTP 429)"
                   :reset-at "2026-10-10T12:01:00Z")
                 (prrr-github-error '(error http 429) nil prrr-github-test--now))))

(ert-deftest prrr-github-test-error-http-403-secondary-limit-uses-retry-after ()
  (should (equal '(:kind rate-limited :message "GitHub rate limit (HTTP 403)"
                   :reset-at "2026-10-10T12:01:30Z")
                 (prrr-github-error '(error http 403) '(("retry-after" . "90"))
                                    prrr-github-test--now))))

(ert-deftest prrr-github-test-error-rate-limit-without-headers-waits-a-minute ()
  (should (equal "2026-10-10T12:01:00Z"
                 (plist-get (prrr-github-error '(errors ((type . "RATE_LIMITED") (message . "slow down")))
                                               nil prrr-github-test--now)
                            :reset-at))))

(ert-deftest prrr-github-test-error-http-502-is-offline ()
  (should (eq 'offline (plist-get (prrr-github-error '(error http 502)) :kind))))

(ert-deftest prrr-github-test-error-connection-failed-is-offline ()
  (let ((classified (prrr-github-error '(error connection-failed "failed with code 111\n"
                                               :host "api.github.com" :service 443))))
    (should (eq 'offline (plist-get classified :kind)))
    (should (string-match-p "connection-failed" (plist-get classified :message)))))

(ert-deftest prrr-github-test-error-unknown-shape-is-error ()
  (should (eq 'error (plist-get (prrr-github-error 'surprise) :kind))))

(ert-deftest prrr-github-test-fetch-queue-failure-reaches-errorback ()
  (prrr-test-with-ghub-error-stub '(error http 502) nil
    (let (failure)
      (prrr-github-fetch-queue "api.github.com" "example-org" "example-repo"
                               (lambda (_) (ert-fail "callback on failure"))
                               (lambda (err) (setq failure err)))
      (should (eq 'offline (plist-get failure :kind))))))

(ert-deftest prrr-github-test-fetch-teams-failure-reaches-errorback ()
  (prrr-test-with-ghub-error-stub '(error http 401) nil
    (let (failure)
      (prrr-github-fetch-teams "api.github.com" "example-me"
                               (lambda (_) (ert-fail "callback on failure"))
                               (lambda (err) (setq failure err)))
      (should (eq 'auth (plist-get failure :kind))))))

(ert-deftest prrr-github-test-fetch-queue-decode-error-reaches-errorback ()
  "An answer of an unexpected shape fails the request instead of signalling (C1)."
  (prrr-test-with-ghub-stub '(data (repository (pullRequests . 5))) captured
    (ignore captured)
    (let (failure)
      (prrr-github-fetch-queue "api.github.com" "example-org" "example-repo"
                               (lambda (_) (ert-fail "callback on a decode error"))
                               (lambda (err) (setq failure err)))
      (should (eq 'error (plist-get failure :kind)))
      (should (string-match-p "decode" (plist-get failure :message))))))

(ert-deftest prrr-github-test-fetch-teams-decode-error-reaches-errorback ()
  (prrr-test-with-ghub-stub '(data (viewer (organizations . 5))) captured
    (ignore captured)
    (let (failure)
      (prrr-github-fetch-teams "api.github.com" "example-me"
                               (lambda (_) (ert-fail "callback on a decode error"))
                               (lambda (err) (setq failure err)))
      (should (eq 'error (plist-get failure :kind))))))

(ert-deftest prrr-github-test-fetch-callback-error-is-not-an-errorback ()
  "Only decoding is guarded: an error in CALLBACK itself is the caller's."
  (prrr-test-with-ghub-stub (prrr-test-fixture "teams") captured
    (ignore captured)
    (should-error (prrr-github-fetch-teams "api.github.com" "example-me"
                                           (lambda (_) (error "Caller bug"))
                                           (lambda (_) (ert-fail "errorback on a caller error"))))))

(ert-deftest prrr-github-test-decode-review-data-null-pull-request ()
  (should (null (prrr-github-decode-review-data '(data (repository (pullRequest))) nil))))

(ert-deftest prrr-github-test-fetch-review-data-null-pull-request-is-not-found ()
  "GitHub answered without errors but with a null pullRequest (prrr-knu.2)."
  (prrr-test-with-ghub-stub '(data (repository (pullRequest))) captured
    (ignore captured)
    (let (failure)
      (prrr-github-fetch-review-data "api.github.com" "example-org" "example-repo" 9 "example-me"
                                     (lambda (_) (ert-fail "null PR reached the callback"))
                                     (lambda (err) (setq failure err)))
      (should (eq 'not-found (plist-get failure :kind)))
      (should (string-match-p "example-org/example-repo#9" (plist-get failure :message))))))

;;;; Viewer

(ert-deftest prrr-github-test-viewer-option-wins ()
  (let ((prrr-github-user "example-me"))
    (cl-letf (((symbol-function 'magit-get) (lambda (&rest _) "example-other")))
      (should (equal "example-me" (prrr-github-viewer))))))

(ert-deftest prrr-github-test-viewer-falls-back-to-git-config ()
  (let ((prrr-github-user nil))
    (cl-letf (((symbol-function 'magit-get)
               (lambda (&rest keys) (and (equal keys '("github.user")) "example-me"))))
      (should (equal "example-me" (prrr-github-viewer))))))

;;;; Mutations

(ert-deftest prrr-github-test-set-viewed-sends-mark ()
  (prrr-test-with-ghub-stub '((data (markFileAsViewed (clientMutationId)))) captured
    (let ((done nil))
      (prrr-github-set-viewed "api.github.com" "PR_1" "src/a.el" t
                              (lambda () (setq done t)) (lambda (_) (ert-fail "errorback")))
      (should done)
      (should (eq 'mutation (car (car captured))))
      (should (eq 'markFileAsViewed (car (cadr (car captured)))))
      (should (equal '((input (pullRequestId . "PR_1") (path . "src/a.el")))
                     (cadr captured))))))

(ert-deftest prrr-github-test-set-viewed-sends-unmark ()
  (prrr-test-with-ghub-stub '((data (unmarkFileAsViewed (clientMutationId)))) captured
    (prrr-github-set-viewed "api.github.com" "PR_1" "src/a.el" nil #'ignore #'ignore)
    (should (eq 'unmarkFileAsViewed (car (cadr (car captured)))))))

(ert-deftest prrr-github-test-set-viewed-failure-reaches-errorback ()
  (prrr-test-with-ghub-error-stub '(error http 401) nil
    (let ((failure nil))
      (prrr-github-set-viewed "api.github.com" "PR_1" "src/a.el" t
                              (lambda () (ert-fail "callback"))
                              (lambda (f) (setq failure f)))
      (should (eq 'auth (plist-get failure :kind))))))

;;;; Writes

(defconst prrr-github-test--anchor
  '(:path "src/example.el" :line 12 :side right :start-line 10 :start-side right :subject-type line)
  "A range anchor on the right side.")

(ert-deftest prrr-github-test-decode-review-data-database-id-and-resolvable ()
  (let ((data (prrr-github-decode-review-data (prrr-test-fixture "review-data") "PR_1")))
    (should (equal "1001" (prrr-comment-database-id (car (plist-get data :comments)))))
    (should (prrr-thread-resolvable-p (car (plist-get data :threads))))))

(ert-deftest prrr-github-test-find-pending-review ()
  (prrr-test-with-ghub-stub (prrr-test-fixture "pending-review") captured
    (let ((found :none))
      (prrr-github-find-pending-review "api.github.com" "example-org" "example-repo" 1 "example-me"
                                       (lambda (review) (setq found review))
                                       (lambda (f) (ert-fail f)))
      (should (equal "PRR_kwDOexamplePending1" (prrr-pending-review-review-id found)))
      (should (equal "PR_kwDOexample0000001" (prrr-pending-review-pr-id found)))
      (should (equal "example-me" (alist-get 'me (cadr captured)))))))

(ert-deftest prrr-github-test-find-pending-review-none ()
  (prrr-test-with-ghub-stub (prrr-test-fixture "pending-review-none") captured
    (let ((found :none))
      (prrr-github-find-pending-review "api.github.com" "o" "n" 1 "me"
                                       (lambda (review) (setq found review)) #'ert-fail)
      (should (null found))
      (should captured))))

(ert-deftest prrr-github-test-create-pending-review ()
  (prrr-test-with-ghub-stub (prrr-test-fixture "create-review") captured
    (let ((review nil))
      (prrr-github-create-pending-review "api.github.com" "PR_1" "1111" (lambda (r) (setq review r)) #'ert-fail)
      (should (eq 'mutation (car (car captured))))
      (should (equal '((input (pullRequestId . "PR_1") (commitOID . "1111"))) (cadr captured)))
      (should (equal "PRR_kwDOexampleNew01" (prrr-pending-review-review-id review)))
      (should (equal "PR_1" (prrr-pending-review-pr-id review))))))

(ert-deftest prrr-github-test-add-thread-range ()
  (prrr-test-with-ghub-stub (prrr-test-fixture "add-thread") captured
    (let ((result nil))
      (prrr-github-add-thread "api.github.com" "PRR_1" prrr-github-test--anchor "Nit."
                              (lambda (r) (setq result r)) #'ert-fail)
      (should (equal '((input (pullRequestReviewId . "PRR_1") (path . "src/example.el") (body . "Nit.")
                              (line . 12) (side . "RIGHT") (startLine . 10) (startSide . "RIGHT")))
                     (cadr captured)))
      (should (equal '(:thread-id "PRRT_kwDOexampleNew01" :comment-id "PRRC_kwDOexampleNew01"
                       :database-id "2001" :created-at "2026-10-10T12:00:00Z")
                     result)))))

(ert-deftest prrr-github-test-add-thread-file ()
  (prrr-test-with-ghub-stub (prrr-test-fixture "add-thread") captured
    (prrr-github-add-thread "api.github.com" "PRR_1" '(:path "a.el" :subject-type file) "Split."
                            #'ignore #'ert-fail)
    (should (equal '((input (pullRequestReviewId . "PRR_1") (path . "a.el") (body . "Split.")
                            (subjectType . "FILE")))
                   (cadr captured)))))

(ert-deftest prrr-github-test-add-reply ()
  (prrr-test-with-ghub-stub (prrr-test-fixture "add-reply") captured
    (let ((result nil))
      (prrr-github-add-reply "api.github.com" "PRR_1" "PRRT_1" "Agreed." (lambda (r) (setq result r)) #'ert-fail)
      (should (equal '((input (pullRequestReviewThreadId . "PRRT_1") (pullRequestReviewId . "PRR_1") (body . "Agreed.")))
                     (cadr captured)))
      (should (equal "PRRC_kwDOexampleNew02" (plist-get result :comment-id))))))

(defconst prrr-github-test--unnamed
  '(:kind unconfirmed :message "GitHub's answer does not name what it made" :reset-at nil)
  "The failure of a creation GitHub answered without naming what it made.")

(defmacro prrr-github-test--null-payload (answer call)
  "Check that CALL, answered with ANSWER, fails as unconfirmed.
CALL is a function of a callback and an errorback that sends the request."
  `(prrr-test-with-ghub-stub ,answer captured
     (let ((failure nil))
       (funcall ,call #'ert-fail (lambda (f) (setq failure f)))
       (should captured)
       (should (equal prrr-github-test--unnamed failure)))))

(ert-deftest prrr-github-test-add-thread-null-payload-is-unconfirmed ()
  "A null Thread without errors must not count as success: it would be lost.
Nor as a plain failure: GitHub may have made it, so it is unconfirmed."
  (dolist (answer '((data (addPullRequestReviewThread (thread)))
                    (data (addPullRequestReviewThread))))
    (prrr-github-test--null-payload answer
      (lambda (callback errorback)
        (prrr-github-add-thread "api.github.com" "PRR_1" prrr-github-test--anchor "Nit."
                                callback errorback)))))

(ert-deftest prrr-github-test-add-reply-null-payload-is-unconfirmed ()
  (prrr-github-test--null-payload '(data (addPullRequestReviewThreadReply (comment)))
    (lambda (callback errorback)
      (prrr-github-add-reply "api.github.com" "PRR_1" "PRRT_1" "x" callback errorback))))

(ert-deftest prrr-github-test-create-review-null-payload-is-unconfirmed ()
  (prrr-github-test--null-payload '(data (addPullRequestReview (pullRequestReview)))
    (lambda (callback errorback)
      (prrr-github-create-pending-review "api.github.com" "PR_1" "1111" callback errorback))))

(defun prrr-github-test--without-node-id (fixture)
  "Return the REST answer FIXTURE with a null node_id."
  (mapcar (lambda (pair) (if (eq (car pair) 'node_id) (list 'node_id) pair))
          (prrr-test-fixture fixture)))

(ert-deftest prrr-github-test-rest-null-node-id-is-unconfirmed ()
  "A REST answer without GitHub's node id does not name the comment it made.
GitHub did make it (the answer is a success), but prrr cannot store a
comment without its id; the failure is `unconfirmed', as for the
GraphQL creations, so the Outbox lets a refetch find the comment
instead of sending it again."
  (pcase-dolist (`(,fixture . ,call)
                 `(("publish-comment"
                    . ,(lambda (callback errorback)
                         (prrr-github-publish-comment "api.github.com" "o" "n" 1 "1111"
                                                      prrr-github-test--anchor "Now."
                                                      callback errorback)))
                   ("publish-reply"
                    . ,(lambda (callback errorback)
                         (prrr-github-publish-reply "api.github.com" "o" "n" 1 "1001" "Done."
                                                    callback errorback)))))
    (prrr-test-with-rest-stub (prrr-github-test--without-node-id fixture) captured
      (let ((failure nil))
        (funcall call #'ert-fail (lambda (f) (setq failure f)))
        (should captured)
        (should (equal prrr-github-test--unnamed failure))))))

(ert-deftest prrr-github-test-write-failure-reaches-errorback ()
  (prrr-test-with-ghub-error-stub '(errors ((type . "UNPROCESSABLE") (message . "one pending review"))) nil
    (let ((failure nil))
      (prrr-github-add-reply "api.github.com" "PRR_1" "PRRT_1" "x" #'ert-fail (lambda (f) (setq failure f)))
      (should (equal '(:kind error :message "one pending review" :reset-at nil) failure)))))

(ert-deftest prrr-github-test-error-http-422-is-a-refusal ()
  (should (equal '(:kind error :message "GitHub refused: Validation Failed (line must be part of the diff)" :reset-at nil)
                 (prrr-github-error '(error http 422 ((message . "Validation Failed")
                                                      (errors ((message . "line must be part of the diff")))))))))

(ert-deftest prrr-github-test-publish-comment ()
  (prrr-test-with-rest-stub (prrr-test-fixture "publish-comment") captured
    (let ((result nil))
      (prrr-github-publish-comment "api.github.com" "example-org" "example-repo" 1 "1111"
                                   prrr-github-test--anchor "Now." (lambda (r) (setq result r)) #'ert-fail)
      (should (equal '("POST" "/repos/example-org/example-repo/pulls/1/comments"
                       ((body . "Now.") (commit_id . "1111") (path . "src/example.el") (line . 12)
                        (side . "RIGHT") (start_line . 10) (start_side . "RIGHT") (subject_type . "line")))
                     captured))
      (should (equal '(:comment-id "PRRC_kwDOexampleNew03" :database-id "3001" :created-at "2026-10-10T12:02:00Z")
                     result)))))

(ert-deftest prrr-github-test-publish-file-comment ()
  (prrr-test-with-rest-stub (prrr-test-fixture "publish-comment") captured
    (prrr-github-publish-comment "api.github.com" "o" "n" 1 "1111" '(:path "a.el" :subject-type file) "File."
                                 #'ignore #'ert-fail)
    (should (equal '((body . "File.") (commit_id . "1111") (path . "a.el") (subject_type . "file"))
                   (nth 2 captured)))))

(ert-deftest prrr-github-test-publish-reply ()
  (prrr-test-with-rest-stub (prrr-test-fixture "publish-reply") captured
    (let ((result nil))
      (prrr-github-publish-reply "api.github.com" "o" "n" 1 "1001" "Done." (lambda (r) (setq result r)) #'ert-fail)
      (should (equal '("POST" "/repos/o/n/pulls/1/comments/1001/replies" ((body . "Done."))) captured))
      (should (equal "3002" (plist-get result :database-id))))))

(ert-deftest prrr-github-test-publish-refused ()
  (prrr-test-with-rest-stub '(:error (error http 422 ((message . "Validation Failed")))) captured
    (let ((failure nil))
      (prrr-github-publish-reply "api.github.com" "o" "n" 1 "1001" "x" #'ert-fail (lambda (f) (setq failure f)))
      (should (equal "GitHub refused: Validation Failed" (plist-get failure :message)))
      (should (equal "POST" (car captured))))))

(ert-deftest prrr-github-test-add-discussion-comment ()
  "A Discussion Comment's answer names it, so the Review Buffer can show it until forge has it."
  (prrr-test-with-ghub-stub (prrr-test-fixture "add-comment") captured
    (let ((result nil))
      (prrr-github-add-discussion-comment "api.github.com" "PR_1" "Hi"
                                          (lambda (r) (setq result r)) #'ert-fail)
      (should (equal '((input (subjectId . "PR_1") (body . "Hi"))) (cadr captured)))
      (should (equal '(:comment-id "IC_kwDOexampleNew01" :database-id 5001
                       :created-at "2026-10-10T12:05:00Z")
                     result)))))

(ert-deftest prrr-github-test-add-discussion-comment-null-payload-is-unconfirmed ()
  (prrr-github-test--null-payload '(data (addComment (commentEdge)))
    (lambda (callback errorback)
      (prrr-github-add-discussion-comment "api.github.com" "PR_1" "Hi" callback errorback))))

(ert-deftest prrr-github-test-forge-mutations ()
  (pcase-dolist (`(,call ,mutation ,input)
                 `((,(lambda (cb eb) (prrr-github-edit-comment "h" "C_1" "New" cb eb))
                    updatePullRequestReviewComment ((pullRequestReviewCommentId . "C_1") (body . "New")))
                   (,(lambda (cb eb) (prrr-github-delete-comment "h" "C_1" cb eb))
                    deletePullRequestReviewComment ((id . "C_1")))
                   (,(lambda (cb eb) (prrr-github-set-resolved "h" "T_1" t cb eb))
                    resolveReviewThread ((threadId . "T_1")))
                   (,(lambda (cb eb) (prrr-github-set-resolved "h" "T_1" nil cb eb))
                    unresolveReviewThread ((threadId . "T_1")))
                   (,(lambda (cb eb) (prrr-github-submit-review "h" "PRR_1" "PR_1" "1111" 'request-changes "Fix." cb eb))
                    submitPullRequestReview ((pullRequestReviewId . "PRR_1") (event . "REQUEST_CHANGES") (body . "Fix.")))
                   (,(lambda (cb eb) (prrr-github-submit-review "h" nil "PR_1" "1111" 'approve "" cb eb))
                    addPullRequestReview ((pullRequestId . "PR_1") (commitOID . "1111") (event . "APPROVE") (body . "")))
                   (,(lambda (cb eb) (prrr-github-discard-review "h" "PRR_1" cb eb))
                    deletePullRequestReview ((pullRequestReviewId . "PRR_1")))))
    (prrr-test-with-ghub-stub `((data (,mutation (clientMutationId)))) captured
      (let ((done nil))
        (funcall call (lambda () (setq done t)) #'ert-fail)
        (should done)
        (should (equal (list mutation (list (cons 'input input)))
                       (list (car (cadr (car captured))) (cadr captured))))))))

(ert-deftest prrr-github-test-remove-review-request ()
  (prrr-test-with-rest-stub '((number . 1)) captured
    (let ((called nil))
      (prrr-github-remove-review-request "api.github.com" "o" "n" 1 "example-me"
                                         (lambda () (setq called t)) #'ert-fail)
      (should called)
      (should (equal '("DELETE" "/repos/o/n/pulls/1/requested_reviewers"
                       ((reviewers . ["example-me"])))
                     captured)))))

(ert-deftest prrr-github-test-remove-assignee ()
  (prrr-test-with-rest-stub '((number . 1)) captured
    (let ((called nil))
      (prrr-github-remove-assignee "api.github.com" "o" "n" 1 "example-me"
                                   (lambda () (setq called t)) #'ert-fail)
      (should called)
      (should (equal '("DELETE" "/repos/o/n/issues/1/assignees" ((assignees . ["example-me"])))
                     captured)))))

(ert-deftest prrr-github-test-remove-review-request-refused ()
  (prrr-test-with-rest-stub '(:error (error http 403 ((message . "Must have admin rights")))) captured
    (let ((failure nil))
      (prrr-github-remove-review-request "api.github.com" "o" "n" 1 "example-me"
                                         #'ert-fail (lambda (f) (setq failure f)))
      (should (equal "GitHub denied access (HTTP 403): Must have admin rights" (plist-get failure :message)))
      (should (equal "DELETE" (car captured))))))

(provide 'prrr-github-test)
;;; prrr-github-test.el ends here
