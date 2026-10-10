;;; prrr-sync-test.el --- Tests for prrr-sync  -*- lexical-binding: t -*-

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

;; Freshness rules and the background pull, with ghub stubbed and an
;; in-memory database.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'prrr-test-helper)
(require 'prrr-sync)

(defconst prrr-sync-test--now (encode-time '(0 0 12 10 10 2026 nil nil t))
  "2026-10-10T12:00:00Z.")

(defun prrr-sync-test--repo ()
  "Return a GitHub repository object that needs no forge database."
  (let ((repo (forge-github-repository :id "example-repo-id" :owner "example-org"
                                       :name "example-repo" :apihost "api.github.com")))
    (oset repo default-branch "main")
    repo))

(defmacro prrr-sync-test--with-clean-status (&rest body)
  "Run BODY with an empty sync status table and the test viewer."
  (declare (indent 0))
  `(let ((prrr-sync--status (make-hash-table :test #'equal))
         (prrr-sync--teams-fetched-at nil)
         (prrr-github-user "example-me"))
     ,@body))

(defun prrr-sync-test--meta (fetched-at)
  "A meta row of the test repository fetched at FETCHED-AT."
  (prrr-pr-meta-create :pr-id "PR_1" :forge-repo-id "example-repo-id" :fetched-at fetched-at))

;;;; Due

(ert-deftest prrr-sync-test-due-p-never-pulled ()
  (prrr-sync-test--with-clean-status
    (should (prrr-sync-queue-due-p "example-repo-id" nil prrr-sync-test--now))))

(ert-deftest prrr-sync-test-due-p-fresh-rows ()
  (prrr-sync-test--with-clean-status
    (should-not (prrr-sync-queue-due-p "example-repo-id"
                                       (list (prrr-sync-test--meta "2026-10-10T11:58:00Z"))
                                       prrr-sync-test--now))))

(ert-deftest prrr-sync-test-due-p-stale-rows ()
  (prrr-sync-test--with-clean-status
    (should (prrr-sync-queue-due-p "example-repo-id"
                                   (list (prrr-sync-test--meta "2026-10-10T11:50:00Z"))
                                   prrr-sync-test--now))))

(ert-deftest prrr-sync-test-due-p-not-while-pulling ()
  (prrr-sync-test--with-clean-status
    (puthash "example-repo-id" '(:state pulling :attempted-at "2026-10-10T11:00:00Z")
             prrr-sync--status)
    (should-not (prrr-sync-queue-due-p "example-repo-id" nil prrr-sync-test--now))))

(ert-deftest prrr-sync-test-due-p-recent-failed-attempt-waits ()
  "A failure refreshes the buffer; that refresh must not pull again (Review Focus 1)."
  (prrr-sync-test--with-clean-status
    (puthash "example-repo-id" '(:state offline :attempted-at "2026-10-10T11:59:00Z")
             prrr-sync--status)
    (should-not (prrr-sync-queue-due-p "example-repo-id" nil prrr-sync-test--now))))

(ert-deftest prrr-sync-test-due-p-old-failed-attempt-retries ()
  (prrr-sync-test--with-clean-status
    (puthash "example-repo-id" '(:state offline :attempted-at "2026-10-10T11:50:00Z")
             prrr-sync--status)
    (should (prrr-sync-queue-due-p "example-repo-id" nil prrr-sync-test--now))))

(ert-deftest prrr-sync-test-due-p-waits-for-rate-limit-reset ()
  (prrr-sync-test--with-clean-status
    (puthash "example-repo-id" '(:state rate-limited :attempted-at "2026-10-10T11:00:00Z"
                                 :reset-at "2026-10-10T12:30:00Z")
             prrr-sync--status)
    (should-not (prrr-sync-queue-due-p "example-repo-id" nil prrr-sync-test--now))
    (should (prrr-sync-queue-due-p "example-repo-id" nil
                                   (encode-time '(0 31 12 10 10 2026 nil nil t))))))

;;;; Pull

(ert-deftest prrr-sync-test-pull-stores-metas-and-teams ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (prrr-test-with-ghub-dispatch `((viewer . ,(prrr-test-fixture "teams"))
                                      (repository . ,(prrr-test-fixture "queue")))
        (prrr-sync-pull (prrr-sync-test--repo))
        (should (equal '(viewer repository) prrr-test-requests))
        (should (prrr-db-select 'pullreq-meta :forge-repo-id "example-repo-id"))
        (should (prrr-db-select 'team))
        (should (eq 'ok (plist-get (prrr-sync-status "example-repo-id") :state)))
        (should (stringp (plist-get (prrr-sync-status "example-repo-id") :attempted-at)))))))

(ert-deftest prrr-sync-test-pull-skips-fresh-teams ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (prrr-db-replace-teams (list (prrr-team-create :combined-slug "example-org/reviewers"
                                                     :fetched-at (prrr-sync--timestamp))))
      (prrr-test-with-ghub-dispatch `((repository . ,(prrr-test-fixture "queue")))
        (prrr-sync-pull (prrr-sync-test--repo))
        (should (equal '(repository) prrr-test-requests))))))

(ert-deftest prrr-sync-test-pull-no-teams-fetched-this-session-is-not-refetched ()
  "A viewer in no Team has no rows; one fetch per day is enough."
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (setq prrr-sync--teams-fetched-at (prrr-sync--timestamp))
      (prrr-test-with-ghub-dispatch `((repository . ,(prrr-test-fixture "queue")))
        (prrr-sync-pull (prrr-sync-test--repo))
        (should (equal '(repository) prrr-test-requests))))))

(ert-deftest prrr-sync-test-pull-failure-records-status-and-keeps-rows ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (prrr-db-insert (prrr-sync-test--meta "2026-10-01T00:00:00Z"))
      (setq prrr-sync--teams-fetched-at (prrr-sync--timestamp))
      (prrr-test-with-ghub-error-stub '(error http 502) nil
        (prrr-sync-pull (prrr-sync-test--repo)))
      (should (eq 'offline (plist-get (prrr-sync-status "example-repo-id") :state)))
      (should (prrr-db-get 'pullreq-meta "PR_1")))))

(ert-deftest prrr-sync-test-pull-failure-of-teams-stops-the-pull ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (prrr-test-with-ghub-error-stub '(error http 401) nil
        (prrr-sync-pull (prrr-sync-test--repo)))
      (should (eq 'auth (plist-get (prrr-sync-status "example-repo-id") :state))))))

(ert-deftest prrr-sync-test-pull-without-login-records-error-and-sends-nothing ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (let ((prrr-github-user nil))
        (cl-letf (((symbol-function 'magit-get) #'ignore))
          (prrr-test-with-ghub-dispatch nil
            (prrr-sync-pull (prrr-sync-test--repo))
            (should (null prrr-test-requests)))))
      (let ((status (prrr-sync-status "example-repo-id")))
        (should (eq 'error (plist-get status :state)))
        (should (string-match-p "github.user" (plist-get status :message)))))))

(ert-deftest prrr-sync-test-pull-synchronous-signal-becomes-status ()
  "Forge signals at once when no token is configured."
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (setq prrr-sync--teams-fetched-at (prrr-sync--timestamp))
      (cl-letf (((symbol-function 'ghub-query)
                 (lambda (&rest _) (error "Required GitHub token does not exist"))))
        (prrr-sync-pull (prrr-sync-test--repo)))
      (should (string-match-p "token" (plist-get (prrr-sync-status "example-repo-id") :message))))))

(ert-deftest prrr-sync-test-pull-ignored-while-pulling ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (puthash "example-repo-id" '(:state pulling) prrr-sync--status)
      (prrr-test-with-ghub-dispatch nil
        (prrr-sync-pull (prrr-sync-test--repo))
        (should (null prrr-test-requests))))))

(ert-deftest prrr-sync-test-pull-refreshes-buffer-later-not-now ()
  "The refresh is deferred so a synchronous answer cannot re-enter a refresh."
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (setq prrr-sync--teams-fetched-at (prrr-sync--timestamp))
      (let ((refreshed nil) (scheduled nil))
        (with-temp-buffer
          (cl-letf (((symbol-function 'magit-refresh-buffer) (lambda (&rest _) (setq refreshed t)))
                    ((symbol-function 'run-at-time)
                     (lambda (_time _repeat fn &rest args) (push (cons fn args) scheduled))))
            (prrr-test-with-ghub-dispatch `((repository . ,(prrr-test-fixture "queue")))
              (prrr-sync-pull (prrr-sync-test--repo) (current-buffer)))
            (should-not refreshed)
            (should (= 1 (length scheduled)))
            (apply (caar scheduled) (cdar scheduled))
            (should refreshed)))))))

(provide 'prrr-sync-test)
;;; prrr-sync-test.el ends here
