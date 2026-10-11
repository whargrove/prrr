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
         (prrr-sync--teams-tried-at nil)
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
  "Within `prrr-sync-timeout' a pull is running; the attempt rule alone would allow one."
  (prrr-sync-test--with-clean-status
    (let ((prrr-sync-timeout 7200))
      (puthash "example-repo-id" '(:state pulling :attempted-at "2026-10-10T11:00:00Z")
               prrr-sync--status)
      (should-not (prrr-sync-queue-due-p "example-repo-id" nil prrr-sync-test--now)))))

(ert-deftest prrr-sync-test-due-p-recent-failed-attempt-waits ()
  "A failure refreshes the buffer; that refresh must not pull again (Review Focus 1)."
  (prrr-sync-test--with-clean-status
    (puthash "example-repo-id" '(:state offline :attempted-at "2026-10-10T11:59:00Z")
             prrr-sync--status)
    (should-not (prrr-sync-queue-due-p "example-repo-id" nil prrr-sync-test--now))))

(ert-deftest prrr-sync-test-due-p-zero-stale-after-still-spaces-retries ()
  "M4: with `prrr-queue-stale-after' at 0 a failing pull must not loop."
  (prrr-sync-test--with-clean-status
    (let ((prrr-queue-stale-after 0))
      (puthash "example-repo-id" '(:state offline :attempted-at "2026-10-10T11:59:50Z")
               prrr-sync--status)
      (should-not (prrr-sync-queue-due-p "example-repo-id" nil prrr-sync-test--now))
      (should (prrr-sync-queue-due-p "example-repo-id" nil
                                     (encode-time '(0 1 12 10 10 2026 nil nil t)))))))

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
      (setq prrr-sync--teams-tried-at (prrr-sync--timestamp))
      (prrr-test-with-ghub-dispatch `((repository . ,(prrr-test-fixture "queue")))
        (prrr-sync-pull (prrr-sync-test--repo))
        (should (equal '(repository) prrr-test-requests))))))

(ert-deftest prrr-sync-test-pull-failure-records-status-and-keeps-rows ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (prrr-db-insert (prrr-sync-test--meta "2026-10-01T00:00:00Z"))
      (setq prrr-sync--teams-tried-at (prrr-sync--timestamp))
      (prrr-test-with-ghub-error-stub '(error http 502) nil
        (prrr-sync-pull (prrr-sync-test--repo)))
      (should (eq 'offline (plist-get (prrr-sync-status "example-repo-id") :state)))
      (should (prrr-db-get 'pullreq-meta "PR_1")))))

(ert-deftest prrr-sync-test-pull-teams-failure-still-pulls-the-queue ()
  "A token without read:org cannot list Teams; the queue still fills (I1).
The stored Teams stay, the failure is not retried before
`prrr-sync-teams-max-age', and the status is ok with a message."
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (prrr-db-replace-teams (list (prrr-team-create :combined-slug "example-org/reviewers"
                                                     :fetched-at "2026-01-01T00:00:00Z")))
      (let ((requests nil))
        (cl-letf (((symbol-function 'ghub-query)
                   (lambda (query _variables &rest args)
                     (let ((field (car (cadr query))))
                       (push field requests)
                       (if (eq field 'viewer)
                           (funcall (plist-get args :errorback) '(error http 403) nil nil nil)
                         (funcall (plist-get args :callback) (prrr-test-fixture "queue")))))))
          (prrr-sync-pull (prrr-sync-test--repo)))
        (should (equal '(repository viewer) requests)))
      (let ((status (prrr-sync-status "example-repo-id")))
        (should (eq 'ok (plist-get status :state)))
        (should (equal "Teams unavailable: GitHub rejected the token (HTTP 403)"
                       (plist-get status :message))))
      (should (prrr-db-select 'pullreq-meta :forge-repo-id "example-repo-id"))
      (should (equal '("example-org/reviewers")
                     (mapcar #'prrr-team-combined-slug (prrr-db-select 'team))))
      (should-not (prrr-sync--teams-due-p)))))

(ert-deftest prrr-sync-test-pull-queue-signal-after-teams-sends-each-query-once ()
  "A signal while sending the queue query fails the pull; Teams are not blamed."
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (let ((requests nil))
        (cl-letf (((symbol-function 'ghub-query)
                   (lambda (query _variables &rest args)
                     (let ((field (car (cadr query))))
                       (push field requests)
                       (if (eq field 'viewer)
                           (funcall (plist-get args :callback) (prrr-test-fixture "teams"))
                         (error "Required GitHub token does not exist"))))))
          (prrr-sync-pull (prrr-sync-test--repo)))
        (should (equal '(repository viewer) requests)))
      (let ((status (prrr-sync-status "example-repo-id")))
        (should (eq 'error (plist-get status :state)))
        (should (string-match-p "token" (plist-get status :message)))))))

(ert-deftest prrr-sync-test-teams-due-p-at-now ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (prrr-db-replace-teams (list (prrr-team-create :combined-slug "example-org/reviewers"
                                                     :fetched-at "2026-10-10T00:00:00Z")))
      (should-not (prrr-sync--teams-due-p prrr-sync-test--now))
      (should (prrr-sync--teams-due-p (encode-time '(0 0 1 11 10 2026 nil nil t)))))))

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
      (setq prrr-sync--teams-tried-at (prrr-sync--timestamp))
      (cl-letf (((symbol-function 'ghub-query)
                 (lambda (&rest _) (error "Required GitHub token does not exist"))))
        (prrr-sync-pull (prrr-sync-test--repo)))
      (should (string-match-p "token" (plist-get (prrr-sync-status "example-repo-id") :message))))))

(ert-deftest prrr-sync-test-pull-ignored-while-pulling ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (puthash "example-repo-id" (list :state 'pulling :attempted-at (prrr-sync--timestamp))
               prrr-sync--status)
      (prrr-test-with-ghub-dispatch nil
        (should-not (prrr-sync-pull (prrr-sync-test--repo)))
        (should (null prrr-test-requests))))))

(ert-deftest prrr-sync-test-pull-refreshes-buffer-later-not-now ()
  "The refresh is deferred so a synchronous answer cannot re-enter a refresh."
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (setq prrr-sync--teams-tried-at (prrr-sync--timestamp))
      (let ((refreshed nil) (scheduled nil))
        (with-temp-buffer
          (cl-letf (((symbol-function 'magit-refresh-buffer) (lambda (&rest _) (setq refreshed t)))
                    ((symbol-function 'run-at-time)
                     (lambda (time _repeat fn &rest args)
                       (when (equal time 0) (push (cons fn args) scheduled)))))
            (prrr-test-with-ghub-dispatch `((repository . ,(prrr-test-fixture "queue")))
              (prrr-sync-pull (prrr-sync-test--repo) (current-buffer)))
            (should-not refreshed)
            (should (= 1 (length scheduled)))
            (apply (caar scheduled) (cdar scheduled))
            (should refreshed)))))))

;;;; No answer (C1)

(defmacro prrr-sync-test--with-silent-ghub (callbacks timers &rest body)
  "Run BODY with `ghub-query' never answering and timers captured.
CALLBACKS is bound to the callbacks of the requests sent, newest
first; TIMERS to the (SECONDS FUNCTION . ARGS) of every `run-at-time'
call, newest first.  Nothing is scheduled for real."
  (declare (indent 2))
  `(let ((,callbacks nil) (,timers nil))
     (cl-letf (((symbol-function 'ghub-query)
                (lambda (_query _variables &rest args)
                  (push (plist-get args :callback) ,callbacks)))
               ((symbol-function 'run-at-time)
                (lambda (time _repeat fn &rest args)
                  (push (cons time (cons fn args)) ,timers))))
       ,@body)))

(defun prrr-sync-test--fire-watchdog (timers)
  "Run the watchdog among the captured TIMERS."
  (let ((watchdog (seq-find (lambda (timer) (equal (car timer) prrr-sync-timeout)) timers)))
    (should watchdog)
    (apply (cadr watchdog) (cddr watchdog))))

(ert-deftest prrr-sync-test-pull-without-answer-goes-offline-after-timeout ()
  "A pull ghub never answers, as when the connection fails, ends as offline."
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (setq prrr-sync--teams-tried-at (prrr-sync--timestamp))
      (prrr-sync-test--with-silent-ghub callbacks timers
        (ignore callbacks)
        (should (prrr-sync-pull (prrr-sync-test--repo)))
        (should (eq 'pulling (plist-get (prrr-sync-status "example-repo-id") :state)))
        (prrr-sync-test--fire-watchdog timers)
        (let ((status (prrr-sync-status "example-repo-id")))
          (should (eq 'offline (plist-get status :state)))
          (should (equal "No answer from GitHub" (plist-get status :message))))
        (should (prrr-sync-queue-due-p "example-repo-id" nil
                                       (time-add (current-time) (1+ prrr-queue-stale-after))))))))

(ert-deftest prrr-sync-test-late-answer-after-timeout-is-ignored ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (setq prrr-sync--teams-tried-at (prrr-sync--timestamp))
      (prrr-sync-test--with-silent-ghub callbacks timers
        (prrr-sync-pull (prrr-sync-test--repo))
        (prrr-sync-test--fire-watchdog timers)
        (funcall (car callbacks) (prrr-test-fixture "queue"))
        (should (eq 'offline (plist-get (prrr-sync-status "example-repo-id") :state)))
        (should-not (prrr-db-select 'pullreq-meta :forge-repo-id "example-repo-id"))))))

(ert-deftest prrr-sync-test-answer-before-timeout-makes-watchdog-a-no-op ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (setq prrr-sync--teams-tried-at (prrr-sync--timestamp))
      (prrr-sync-test--with-silent-ghub callbacks timers
        (prrr-sync-pull (prrr-sync-test--repo))
        (funcall (car callbacks) (prrr-test-fixture "queue"))
        (prrr-sync-test--fire-watchdog timers)
        (should (eq 'ok (plist-get (prrr-sync-status "example-repo-id") :state)))))))

(ert-deftest prrr-sync-test-due-p-pulling-older-than-timeout-is-not-pulling ()
  (prrr-sync-test--with-clean-status
    (puthash "example-repo-id" '(:state pulling :attempted-at "2026-10-10T11:00:00Z")
             prrr-sync--status)
    (should (prrr-sync-queue-due-p "example-repo-id" nil prrr-sync-test--now))))

(ert-deftest prrr-sync-test-pull-restarts-a-pull-older-than-timeout ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (setq prrr-sync--teams-tried-at (prrr-sync--timestamp))
      (puthash "example-repo-id" '(:state pulling :attempted-at "2020-01-01T00:00:00Z")
               prrr-sync--status)
      (prrr-test-with-ghub-dispatch `((repository . ,(prrr-test-fixture "queue")))
        (should (prrr-sync-pull (prrr-sync-test--repo)))
        (should (equal '(repository) prrr-test-requests))))))

;;;; Commands

(ert-deftest prrr-sync-test-current-repository-needs-a-tracked-github-repository ()
  (cl-letf (((symbol-function 'forge-get-repository) #'ignore))
    (should-error (prrr-sync-current-repository) :type 'user-error))
  (cl-letf (((symbol-function 'forge-get-repository)
             (lambda (&rest _) (forge-gitlab-repository :id "example-gitlab-id"))))
    (should-error (prrr-sync-current-repository) :type 'user-error))
  (let ((repo (prrr-sync-test--repo)))
    (cl-letf (((symbol-function 'forge-get-repository) (lambda (&rest _) repo)))
      (should (eq repo (prrr-sync-current-repository))))))

(defmacro prrr-sync-test--with-pull-command (started calls messages &rest body)
  "Run BODY with `prrr-pull's collaborators stubbed.
`prrr-sync-pull' returns STARTED.  CALLS collects (FUNCTION ARGS...)
of `forge-pull' and `prrr-sync-pull'; MESSAGES the formatted messages."
  (declare (indent 3))
  `(let ((,calls nil) (,messages nil) (repo (prrr-sync-test--repo)))
     (with-temp-buffer
       (let ((status-buffer (current-buffer)))
         (cl-letf (((symbol-function 'forge-get-repository) (lambda (&rest _) repo))
                   ((symbol-function 'magit-get-mode-buffer) (lambda (&rest _) status-buffer))
                   ((symbol-function 'forge-pull)
                    (lambda () (interactive) (push (list 'forge-pull) ,calls)))
                   ((symbol-function 'prrr-sync-pull)
                    (lambda (repo buffer) (push (list 'prrr-sync-pull repo buffer) ,calls)
                      ,started))
                   ((symbol-function 'message)
                    (lambda (format &rest args) (push (apply #'format format args) ,messages))))
           ,@body)))))

(ert-deftest prrr-sync-test-pull-command-pulls-forge-and-the-queue ()
  (prrr-sync-test--with-pull-command t calls messages
    (prrr-pull)
    (should (equal (list (list 'prrr-sync-pull repo status-buffer) (list 'forge-pull)) calls))
    (should (string-match-p "Pulling the Review Queue of example-org/example-repo"
                            (car messages)))))

(ert-deftest prrr-sync-test-pull-command-says-when-a-pull-is-running ()
  "Nothing was started, so the command must not claim it is pulling (C1)."
  (prrr-sync-test--with-pull-command nil calls messages
    (ignore calls)
    (prrr-pull)
    (should (string-match-p "already running" (car messages)))
    (should-not (string-match-p "Pulling" (car messages)))))

(ert-deftest prrr-sync-test-refresh-teams-stores-and-refreshes-status-buffer ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (let ((repo (prrr-sync-test--repo)) (scheduled nil))
        (with-temp-buffer
          (let ((status-buffer (current-buffer)))
            (cl-letf (((symbol-function 'forge-get-repository) (lambda (&rest _) repo))
                      ((symbol-function 'magit-get-mode-buffer) (lambda (&rest _) status-buffer))
                      ((symbol-function 'run-at-time)
                       (lambda (_time _repeat fn &rest args) (push (cons fn args) scheduled)))
                      ((symbol-function 'message) #'ignore))
              (prrr-test-with-ghub-dispatch `((viewer . ,(prrr-test-fixture "teams")))
                (prrr-refresh-teams))
              (should (= 2 (length (prrr-db-select 'team))))
              (should (member (list #'prrr-sync--refresh status-buffer) scheduled)))))))))

(ert-deftest prrr-sync-test-refresh-teams-needs-a-login ()
  (prrr-sync-test--with-clean-status
    (let ((prrr-github-user nil) (repo (prrr-sync-test--repo)))
      (cl-letf (((symbol-function 'magit-get) #'ignore)
                ((symbol-function 'forge-get-repository) (lambda (&rest _) repo)))
        (should-error (prrr-refresh-teams) :type 'user-error)))))
;;;; Refetch

(defconst prrr-sync-test--pr "PR_kwDOexample0000001"
  "The PR of the review-data fixture.")

(defun prrr-sync-test--pullreq ()
  "The fixture's pull request as a forge object, without a database."
  (forge-pullreq :id "forge-1" :number 1 :their-id prrr-sync-test--pr))

(ert-deftest prrr-sync-test-refetch-stores-review-data ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (prrr-test-with-ghub-dispatch `((repository . ,(prrr-test-fixture "review-data")))
        (should (prrr-sync-refetch (prrr-sync-test--repo) (prrr-sync-test--pullreq)))
        (should (= 5 (length (plist-get (prrr-db-review-data prrr-sync-test--pr) :threads))))
        (let ((status (prrr-sync-review-status prrr-sync-test--pr)))
          (should (eq 'ok (plist-get status :state)))
          (should (equal "1111111111111111111111111111111111111111"
                         (plist-get status :head-oid))))))))

(ert-deftest prrr-sync-test-refetch-not-while-running ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (puthash (cons 'review prrr-sync-test--pr)
               (list :state 'pulling :attempted-at (prrr-sync--timestamp))
               prrr-sync--status)
      (prrr-test-with-ghub-dispatch nil
        (should-not (prrr-sync-refetch (prrr-sync-test--repo) (prrr-sync-test--pullreq)))
        (should-not prrr-test-requests)))))

(ert-deftest prrr-sync-test-refetch-waits-for-rate-limit ()
  (prrr-sync-test--with-clean-status
    (puthash (cons 'review prrr-sync-test--pr)
             '(:state rate-limited :attempted-at "2026-10-10T11:00:00Z"
               :reset-at "2026-10-10T12:30:00Z")
             prrr-sync--status)
    (should-not (prrr-sync-refetch-due-p prrr-sync-test--pr prrr-sync-test--now))
    (should (prrr-sync-refetch-due-p prrr-sync-test--pr
                                     (encode-time '(0 31 12 10 10 2026 nil nil t))))))

(ert-deftest prrr-sync-test-refetch-failure-keeps-stored-rows ()
  "Review Focus 5: offline keeps the database copy and says so."
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (prrr-db-insert (prrr-test-thread :id "KEPT"))
      (prrr-test-with-ghub-error-stub '(error http 502) nil
        (prrr-sync-refetch (prrr-sync-test--repo)
                           (forge-pullreq :id "forge-1" :number 1 :their-id "PR_1")))
      (should (eq 'offline (plist-get (prrr-sync-review-status "PR_1") :state)))
      (should (equal '("KEPT") (mapcar #'prrr-thread-thread-id (prrr-db-select 'thread)))))))

(ert-deftest prrr-sync-test-refetch-without-login-is-an-error-status ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (let ((prrr-github-user nil))
        (cl-letf (((symbol-function 'magit-get) #'ignore))
          (prrr-test-with-ghub-dispatch nil
            (prrr-sync-refetch (prrr-sync-test--repo) (prrr-sync-test--pullreq))
            (should-not prrr-test-requests))))
      (should (eq 'error (plist-get (prrr-sync-review-status prrr-sync-test--pr) :state))))))

(ert-deftest prrr-sync-test-refetch-late-answer-ignored ()
  "An answer after the watchdog ended the refetch changes nothing."
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (let ((callback nil))
        (cl-letf (((symbol-function 'ghub-query)
                   (lambda (_query _variables &rest args)
                     (setq callback (plist-get args :callback)))))
          (prrr-sync-refetch (prrr-sync-test--repo) (prrr-sync-test--pullreq)))
        (let ((token (plist-get (prrr-sync-review-status prrr-sync-test--pr) :token)))
          (prrr-sync--finish (cons 'review prrr-sync-test--pr) token
                             '(:kind offline :message "No answer from GitHub" :reset-at nil)
                             nil))
        (funcall callback (prrr-test-fixture "review-data"))
        (should-not (prrr-db-select 'thread))
        (should (eq 'offline (plist-get (prrr-sync-review-status prrr-sync-test--pr) :state)))))))

(ert-deftest prrr-sync-test-refetch-and-pull-keep-separate-status ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (prrr-test-with-ghub-dispatch `((repository . ,(prrr-test-fixture "review-data")))
        (prrr-sync-refetch (prrr-sync-test--repo) (prrr-sync-test--pullreq)))
      (should-not (prrr-sync-status "example-repo-id")))))

;;;; Describe

(ert-deftest prrr-sync-test-describe ()
  (should (equal "pulling…" (prrr-sync-describe '(:state pulling))))
  (should (equal "refreshing…" (prrr-sync-describe '(:state pulling) "refreshing…")))
  (should (equal "offline" (prrr-sync-describe '(:state offline :message "No answer"))))
  (should (equal "GitHub rejected the token (HTTP 401)"
                 (prrr-sync-describe '(:state auth :message "GitHub rejected the token (HTTP 401)"))))
  (should (string-prefix-p "rate limited until "
                           (prrr-sync-describe '(:state rate-limited
                                                 :reset-at "2026-10-10T12:30:00Z"))))
  (should-not (prrr-sync-describe '(:state ok)))
  (should-not (prrr-sync-describe nil)))

;;;; The Outbox

(defconst prrr-sync-test--anchor
  '(:path "src/example.el" :line 12 :side right :subject-type line)
  "The anchor of the test comments.")

(defconst prrr-sync-test--mark-viewed '((data (markFileAsViewed (clientMutationId))))
  "GitHub's answer to markFileAsViewed.")

(defun prrr-sync-test--write (kind payload)
  "Hand the write KIND with PAYLOAD to the fixture PR to the Outbox."
  (prrr-sync-write (prrr-sync-test--repo) (prrr-sync-test--pullreq) kind payload))

(defun prrr-sync-test--queue (kind payload)
  "Queue the write KIND with PAYLOAD for the fixture PR without sending anything."
  (prrr-sync--outbox-add prrr-sync-test--pr kind
                         (append (list :target (prrr-sync--target (prrr-sync-test--repo)
                                                                  (prrr-sync-test--pullreq)))
                                 payload)))

(defun prrr-sync-test--store-pending-review ()
  "Store the viewer's Pending Review of the fixture PR."
  (prrr-db-insert (prrr-pending-review-create :pr-id prrr-sync-test--pr
                                              :review-id "PRR_kwDOexamplePending1"
                                              :commit-oid "1111")))

(defun prrr-sync-test--input (field)
  "Return the input of the last request whose top-level field is FIELD."
  (alist-get 'input (cdr (assq field prrr-test-variables))))

(ert-deftest prrr-sync-test-outbox-shows-at-once-then-confirms ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (let ((callback nil) (sent nil))
        (cl-letf (((symbol-function 'ghub-query)
                   (lambda (_query variables &rest args)
                     (setq sent variables callback (plist-get args :callback)))))
          (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor :body "Nit."
                                               :commit "1111")))
        (should (equal '((input (pullRequestReviewId . "PRR_kwDOexamplePending1")
                                (path . "src/example.el") (body . "Nit.") (line . 12)
                                (side . "RIGHT")))
                       sent))
        (let ((comment (car (last (plist-get (prrr-sync-review-data prrr-sync-test--pr)
                                             :comments)))))
          (should (prrr-state-local-id-p (prrr-comment-comment-id comment)))
          (should (eq 'unsent (prrr-comment-local-state comment))))
        (funcall callback (prrr-test-fixture "add-thread"))
        (should-not (prrr-db-outbox-rows))
        (let ((comment (prrr-db-get 'review-comment "PRRC_kwDOexampleNew01")))
          (should (equal '("PRRT_kwDOexampleNew01" pending sent "PRR_kwDOexamplePending1" "2001")
                         (list (prrr-comment-thread-id comment) (prrr-comment-state comment)
                               (prrr-comment-local-state comment)
                               (prrr-comment-review-id comment)
                               (prrr-comment-database-id comment)))))
        (should (prrr-db-get 'thread "PRRT_kwDOexampleNew01"))))))

(ert-deftest prrr-sync-test-outbox-creates-the-pending-review ()
  "SPEC section 7: the first pending comment creates the Pending Review, after looking."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch
          `((repository . ,(prrr-test-fixture "pending-review-none"))
            (addPullRequestReview . ,(prrr-test-fixture "create-review"))
            (addPullRequestReviewThread . ,(prrr-test-fixture "add-thread")))
        (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor :body "Nit."
                                             :commit "1111"))
        (should (equal '(repository addPullRequestReview addPullRequestReviewThread)
                       prrr-test-requests))
        (should (equal "1111" (alist-get 'commitOID (prrr-sync-test--input
                                                     'addPullRequestReview))))
        (should (equal "PRR_kwDOexampleNew01"
                       (prrr-pending-review-review-id
                        (prrr-db-get 'pending-review prrr-sync-test--pr))))))))

(ert-deftest prrr-sync-test-outbox-reuses-the-pending-review-found ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch
          `((repository . ,(prrr-test-fixture "pending-review"))
            (addPullRequestReviewThread . ,(prrr-test-fixture "add-thread")))
        (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor :body "Nit."
                                             :commit "1111"))
        (should (equal '(repository addPullRequestReviewThread) prrr-test-requests))
        (should (equal "PRR_kwDOexamplePending1"
                       (alist-get 'pullRequestReviewId
                                  (prrr-sync-test--input 'addPullRequestReviewThread))))))))

(ert-deftest prrr-sync-test-outbox-reply-to-an-unsent-thread ()
  "Review Focus 3: a reply waits for its Thread, then goes out under GitHub's id."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (let ((callbacks nil) (fields nil))
        (cl-letf (((symbol-function 'ghub-query)
                   (lambda (query variables &rest args)
                     (push (cons (car (cadr query)) variables) fields)
                     (push (plist-get args :callback) callbacks))))
          (let ((thread (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor
                                                             :body "Nit." :commit "1111"))))
            (prrr-sync-test--write 'reply (list :thread-id (plist-get (prrr-outbox-payload thread)
                                                                      :thread)
                                                :body "And this."))
            (should (= 1 (length fields)))
            (funcall (car callbacks) (prrr-test-fixture "add-thread"))
            (should (equal 'addPullRequestReviewThreadReply (car (car fields))))
            (should (equal "PRRT_kwDOexampleNew01"
                           (alist-get 'pullRequestReviewThreadId
                                      (alist-get 'input (cdr (car fields))))))
            (funcall (car callbacks) (prrr-test-fixture "add-reply"))
            (should-not (prrr-db-outbox-rows))
            (should (equal "PRRT_kwDOexampleNew01"
                           (prrr-comment-thread-id
                            (prrr-db-get 'review-comment "PRRC_kwDOexampleNew02"))))))))))

(ert-deftest prrr-sync-test-outbox-failure-kept-and-retried ()
  "Review Focus 1: a failed write stays, shows, and goes out on retry."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch '((markFileAsViewed . (:error (error http 502))))
        (prrr-sync-test--write 'viewed '(:path "a.el" :viewed t)))
      (let ((row (car (prrr-db-outbox-rows))))
        (should (equal "GitHub returned HTTP 502" (prrr-outbox-last-error row)))
        (should (= 1 (prrr-outbox-attempts row))))
      (should (eq 'viewed (prrr-viewed-state
                           (car (plist-get (prrr-sync-review-data prrr-sync-test--pr) :viewed)))))
      (prrr-test-with-ghub-dispatch `((markFileAsViewed . ,prrr-sync-test--mark-viewed))
        (prrr-sync-retry prrr-sync-test--pr))
      (should-not (prrr-db-outbox-rows))
      (should (eq 'viewed (prrr-viewed-state (prrr-db-get 'viewed prrr-sync-test--pr "a.el")))))))

(ert-deftest prrr-sync-test-outbox-failed-write-holds-back-its-pr-only ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch '((markFileAsViewed . (:error (error http 502))))
        (prrr-sync-test--write 'viewed '(:path "a.el" :viewed t)))
      (prrr-test-with-ghub-dispatch `((markFileAsViewed . ,prrr-sync-test--mark-viewed))
        (prrr-sync-test--queue 'viewed '(:path "b.el" :viewed t))
        (prrr-sync--outbox-add "PR_other" 'viewed
                               '(:target (:host "api.github.com" :pr-id "PR_other" :me "example-me")
                                 :path "c.el" :viewed t))
        (prrr-sync--outbox-pump)
        (should (equal '(markFileAsViewed) prrr-test-requests))
        (should (equal "PR_other" (alist-get 'pullRequestId
                                             (prrr-sync-test--input 'markFileAsViewed)))))
      (should (equal '("a.el" "b.el")
                     (mapcar (lambda (row) (plist-get (prrr-outbox-payload row) :path))
                             (prrr-db-outbox-rows)))))))

(ert-deftest prrr-sync-test-outbox-rate-limit-pauses ()
  "SPEC section 11: a rate limit pauses the Outbox until it resets."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch
          '((markFileAsViewed . (:error (errors ((type . "RATE_LIMITED") (message . "Slow down"))))))
        (prrr-sync-test--write 'viewed '(:path "a.el" :viewed t)))
      (should-not (prrr-outbox-last-error (car (prrr-db-outbox-rows))))
      (should (string-prefix-p "rate limited until" (prrr-sync-outbox-describe)))
      (should prrr-sync--outbox-scheduled)
      (prrr-test-with-ghub-dispatch nil
        (prrr-sync-retry prrr-sync-test--pr)
        (should-not prrr-test-requests)))))

(ert-deftest prrr-sync-test-outbox-spaces-mutations ()
  "SPEC section 4: a second apart."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (let ((prrr-sync--mutation-spacing 1.0))
        (prrr-test-with-ghub-dispatch `((markFileAsViewed . ,prrr-sync-test--mark-viewed))
          (prrr-sync-test--write 'viewed '(:path "a.el" :viewed t))
          (prrr-sync-test--write 'viewed '(:path "b.el" :viewed t))
          (should (= 1 (length prrr-test-requests)))
          (let ((timer (seq-find (lambda (timer) (and (numberp (car timer))
                                                      (< 0 (car timer) 1.01)))
                                 prrr-test-timers)))
            (should timer)
            (funcall (nth 1 timer)))
          (should (= 2 (length prrr-test-requests)))
          (should-not (prrr-db-outbox-rows)))))))

(ert-deftest prrr-sync-test-outbox-no-answer-then-late-answer ()
  "A write without an answer fails as offline; an answer that comes later still counts."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (let ((callback nil))
        (cl-letf (((symbol-function 'ghub-query)
                   (lambda (_query _variables &rest args)
                     (setq callback (plist-get args :callback)))))
          (prrr-sync-test--write 'viewed '(:path "a.el" :viewed t)))
        (let ((watchdog (seq-find (lambda (timer) (eql (car timer) prrr-sync-timeout))
                                  prrr-test-timers)))
          (apply (nth 1 watchdog) (nth 2 watchdog)))
        (should (equal "No answer from GitHub" (prrr-outbox-last-error (car (prrr-db-outbox-rows)))))
        (should-not prrr-sync--outbox-sending)
        (funcall callback prrr-sync-test--mark-viewed)
        (should-not (prrr-db-outbox-rows))
        (should (prrr-db-get 'viewed prrr-sync-test--pr "a.el"))))))

(ert-deftest prrr-sync-test-outbox-sends-after-a-restart ()
  "A queued write carries all it needs: no forge object, no buffer."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--queue 'viewed '(:path "a.el" :viewed t)))
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch `((markFileAsViewed . ,prrr-sync-test--mark-viewed))
        (prrr-sync-retry)
        (should (equal '(markFileAsViewed) prrr-test-requests))
        (should-not (prrr-db-outbox-rows))))))

(ert-deftest prrr-sync-test-outbox-discard-takes-dependents ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (prrr-test-with-ghub-dispatch '((addPullRequestReviewThread . (:error (error http 502))))
        (let ((thread (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor
                                                           :body "Nit." :commit "1111"))))
          (prrr-sync-test--write 'reply (list :thread-id (plist-get (prrr-outbox-payload thread)
                                                                    :thread)
                                              :body "More."))
          (should (= 2 (prrr-sync-discard (prrr-outbox-id thread))))
          (should-not (prrr-db-outbox-rows))
          (should-not (plist-get (prrr-sync-review-data prrr-sync-test--pr) :comments)))))))

(ert-deftest prrr-sync-test-outbox-needs-a-login ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (let ((prrr-github-user nil))
        (cl-letf (((symbol-function 'magit-get) #'ignore))
          (should-error (prrr-sync-test--write 'viewed '(:path "a.el" :viewed t))
                        :type 'user-error)))
      (should-not (prrr-db-outbox-rows)))))

;;;; Reconciliation

(ert-deftest prrr-sync-test-refetch-keeps-queued-writes ()
  "SPEC 7, bead prrr-8ok: a refetch keeps unsent writes, then retries them."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch `((markFileAsViewed . (:error (error http 502)))
                                      (repository . ,(prrr-test-fixture "review-data")))
        (prrr-sync-test--write 'viewed '(:path "docs/notes.md" :viewed t))
        (should (prrr-sync-refetch (prrr-sync-test--repo) (prrr-sync-test--pullreq)))
        (let ((view (prrr-sync-review-data prrr-sync-test--pr)))
          (should (= 5 (length (plist-get view :threads))))
          (should (eq 'viewed (prrr-viewed-state
                               (seq-find (lambda (flag)
                                           (equal "docs/notes.md" (prrr-viewed-path flag)))
                                         (plist-get view :viewed))))))
        (should (equal '(markFileAsViewed repository markFileAsViewed) prrr-test-requests))))))

(ert-deftest prrr-sync-test-refetch-raced-by-a-write-is-not-stored ()
  "Review Focus 2: an answer that may miss a write is dropped and fetched again."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (let ((callback nil))
        (cl-letf (((symbol-function 'ghub-query)
                   (lambda (_query _variables &rest args)
                     (setq callback (plist-get args :callback)))))
          (prrr-sync-refetch (prrr-sync-test--repo) (prrr-sync-test--pullreq)))
        ;; A write of the PR succeeds while the refetch is out.
        (puthash prrr-sync-test--pr (prrr-sync--target (prrr-sync-test--repo)
                                                       (prrr-sync-test--pullreq))
                 prrr-sync--outbox-dirty)
        (funcall callback (prrr-test-fixture "review-data"))
        (should-not (prrr-db-select 'thread))
        (should (eq 'ok (plist-get (prrr-sync-review-status prrr-sync-test--pr) :state)))
        (prrr-test-with-ghub-dispatch `((repository . ,(prrr-test-fixture "review-data")))
          (prrr-test-run-timers 'prrr-sync--refetch)
          (should (equal '(repository) prrr-test-requests)))
        (should (= 5 (length (prrr-db-select 'thread))))
        (should-not (gethash prrr-sync-test--pr prrr-sync--outbox-dirty))))))

(ert-deftest prrr-sync-test-refetch-while-a-write-is-out-is-not-stored ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch `((repository . ,(prrr-test-fixture "review-data")))
        (setq prrr-sync--outbox-sending
              (prrr-sync-test--queue 'viewed '(:path "a.el" :viewed t)))
        (prrr-sync-refetch (prrr-sync-test--repo) (prrr-sync-test--pullreq))
        (should-not (prrr-db-select 'thread))
        (should (gethash prrr-sync-test--pr prrr-sync--outbox-dirty))))))

(ert-deftest prrr-sync-test-outbox-refetches-once-done ()
  "After its last write of a PR succeeds, the Outbox refetches the PR, from a timer."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch `((markFileAsViewed . ,prrr-sync-test--mark-viewed)
                                      (repository . ,(prrr-test-fixture "review-data")))
        (prrr-sync-test--write 'viewed '(:path "a.el" :viewed t))
        (should (equal '(markFileAsViewed) prrr-test-requests))
        (prrr-test-run-timers 'prrr-sync--refetch)
        (should (equal '(markFileAsViewed repository) prrr-test-requests))))))

(ert-deftest prrr-sync-test-refetch-names-a-published-thread ()
  "A reply to a Thread published at once goes out once a refetch names the Thread."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      ;; What a successful Immediate Publish leaves: GitHub's comment id in a local Thread.
      (prrr-db-insert (prrr-comment-create :comment-id "PRRC_kwDOexample0000006"
                                           :thread-id "local:T" :pr-id prrr-sync-test--pr
                                           :state 'submitted :local-state 'sent))
      (prrr-sync-test--queue 'reply '(:thread-id "local:T" :comment "local:R" :body "More."))
      (prrr-test-with-ghub-dispatch
          `((repository . ,(prrr-test-fixture "review-data"))
            (addPullRequestReviewThreadReply . ,(prrr-test-fixture "add-reply")))
        (prrr-sync-refetch (prrr-sync-test--repo) (prrr-sync-test--pullreq))
        (should (equal '(repository addPullRequestReviewThreadReply) prrr-test-requests))
        (should (equal "PRRT_kwDOexample0000005"
                       (alist-get 'pullRequestReviewThreadId
                                  (prrr-sync-test--input 'addPullRequestReviewThreadReply))))))))

(provide 'prrr-sync-test)
;;; prrr-sync-test.el ends here
