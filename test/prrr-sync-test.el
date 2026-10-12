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
(require 'prrr-diff)

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
         (prrr-sync--teams-failure nil)
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
        (should (equal "Teams unavailable: GitHub denied access (HTTP 403)"
                       (plist-get status :message))))
      (should (prrr-db-select 'pullreq-meta :forge-repo-id "example-repo-id"))
      (should (equal '("example-org/reviewers")
                     (mapcar #'prrr-team-combined-slug (prrr-db-select 'team))))
      (should-not (prrr-sync--teams-due-p)))))


(defun prrr-sync-test--pull-with-teams (teams-answer)
  "Pull the test repository; the Teams query answers with TEAMS-ANSWER.
TEAMS-ANSWER is (:error ERR) or (:value VALUE); the queue query
answers with the queue fixture.  Return the pull's status."
  (cl-letf (((symbol-function 'ghub-query)
             (lambda (query _variables &rest args)
               (cond ((not (eq (car (cadr query)) 'viewer))
                      (funcall (plist-get args :callback) (prrr-test-fixture "queue")))
                     ((plist-member teams-answer :error)
                      (funcall (plist-get args :errorback) (plist-get teams-answer :error) nil nil nil))
                     (t (funcall (plist-get args :callback) (plist-get teams-answer :value)))))))
    (prrr-sync-pull (prrr-sync-test--repo)))
  (prrr-sync-status "example-repo-id"))

(ert-deftest prrr-sync-test-pull-keeps-teams-unavailable-until-teams-succeed ()
  "The note outlives the failing pull: the Teams stay stale until a success."
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (prrr-sync-test--pull-with-teams '(:error (error http 401)))
      (should-not (prrr-sync--teams-due-p))
      (should (equal "Teams unavailable: GitHub rejected the token (HTTP 401)"
                     (plist-get (prrr-sync-test--pull-with-teams '(:error (error http 401)))
                                :message))))))

(ert-deftest prrr-sync-test-pull-retries-teams-after-an-offline-failure ()
  "A network blip does not cost a day of Teams: the next pull tries again."
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (prrr-sync-test--pull-with-teams '(:error (error connection-failed "refused")))
      (should (prrr-sync--teams-due-p))
      (should (string-prefix-p "Teams unavailable: "
                               (plist-get (prrr-sync-test--pull-with-teams
                                           '(:error (error http 429)))
                                          :message)))
      (should (prrr-sync--teams-due-p)))))

(ert-deftest prrr-sync-test-teams-success-clears-teams-unavailable ()
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (prrr-sync-test--pull-with-teams '(:error (error connection-failed "refused")))
      (let ((status (prrr-sync-test--pull-with-teams
                     `(:value ,(prrr-test-fixture "teams")))))
        (should (eq 'ok (plist-get status :state)))
        (should-not (plist-get status :message)))
      (should-not prrr-sync--teams-failure)
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

(ert-deftest prrr-sync-test-outbox-thread-on-another-commit-fails ()
  "Bead prrr-836: a Thread never joins a Pending Review on another commit."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (prrr-test-with-ghub-dispatch nil
        (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor :body "Nit."
                                             :commit "2222"))
        (should-not prrr-test-requests)
        (should (string-prefix-p "Pending Review is on 1111: copy this comment"
                                 (prrr-outbox-last-error (car (prrr-db-outbox-rows)))))))))

(ert-deftest prrr-sync-test-outbox-refuses-a-thread-for-a-review-found-on-another-commit ()
  "A Pending Review found at GitHub, not stored, refuses a Thread on another commit too."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (cl-letf (((symbol-function 'prrr-github-find-pending-review)
                 (lambda (_host _owner _name _number _me callback _errorback)
                   (funcall callback (prrr-pending-review-create
                                      :pr-id prrr-sync-test--pr :review-id "PRR_found"
                                      :commit-oid "1111")))))
        (prrr-test-with-ghub-dispatch nil
          (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor :body "Nit."
                                               :commit "2222"))
          (should-not prrr-test-requests)
          (should (string-prefix-p "Pending Review is on 1111: copy this comment"
                                   (prrr-outbox-last-error (car (prrr-db-outbox-rows)))))
          (should (= 1 (length (prrr-db-outbox-rows)))))))))

(ert-deftest prrr-sync-test-refused-thread-is-not-a-creation ()
  "A Thread the Outbox refuses never reaches GitHub, so it does not use the creation budget."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (prrr-test-with-ghub-dispatch nil
        (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor :body "Nit."
                                             :commit "2222"))
        (should-not prrr-sync--outbox-creations)))))

(ert-deftest prrr-sync-test-sent-thread-is-a-creation ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (prrr-test-with-ghub-dispatch
          `((addPullRequestReviewThread . ,(prrr-test-fixture "add-thread")))
        (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor :body "Nit."
                                             :commit "1111"))
        (should (= 1 (length prrr-sync--outbox-creations)))))))

(ert-deftest prrr-sync-test-outbox-reply-creates-the-pending-review-on-its-commit ()
  "A reply with no Pending Review creates one on the head the reply was written at."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch
          `((repository . ,(prrr-test-fixture "pending-review-none"))
            (addPullRequestReview . ,(prrr-test-fixture "create-review"))
            (addPullRequestReviewThreadReply . ,(prrr-test-fixture "add-reply")))
        (prrr-sync-test--write 'reply (list :thread-id "PRRT_kwDOexampleThread1" :body "Yes."
                                            :commit prrr-test-head))
        (should (equal prrr-test-head
                       (alist-get 'commitOID (prrr-sync-test--input 'addPullRequestReview))))))))

(ert-deftest prrr-sync-test-outbox-creates-the-pending-review ()
  "SPEC section 7: the first pending comment creates the Pending Review, after looking."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch
          `((repository . ,(prrr-test-fixture "pending-review-none"))
            (addPullRequestReview . ,(prrr-test-fixture "create-review"))
            (addPullRequestReviewThread . ,(prrr-test-fixture "add-thread")))
        (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor :body "Nit."
                                             :commit prrr-test-head))
        (should (equal '(repository addPullRequestReview addPullRequestReviewThread)
                       prrr-test-requests))
        (should (equal prrr-test-head
                       (alist-get 'commitOID (prrr-sync-test--input 'addPullRequestReview))))
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
                                             :commit prrr-test-head))
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
  "A write without an answer is unconfirmed; an answer that comes later still counts."
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
        (let ((row (car (prrr-db-outbox-rows))))
          (should-not (prrr-outbox-last-error row))
          (should (prrr-state-outbox-unconfirmed-p row)))
        (should-not prrr-sync--outbox-sending)
        (funcall callback prrr-sync-test--mark-viewed)
        (should-not (prrr-db-outbox-rows))
        (should (prrr-db-get 'viewed prrr-sync-test--pr "a.el"))))))

(ert-deftest prrr-sync-test-outbox-late-answer-to-a-discarded-write-refetches ()
  "Bead prrr-9tu: GitHub did what a discarded write asked, so the PR is refetched."
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
        (prrr-sync-discard (prrr-outbox-id (car (prrr-db-outbox-rows))))
        (should-not (prrr-db-outbox-rows))
        (funcall callback prrr-sync-test--mark-viewed)
        (should (gethash prrr-sync-test--pr prrr-sync--outbox-dirty))))))

(ert-deftest prrr-sync-test-outbox-late-answer-to-a-discarded-write-renames ()
  "GitHub made what a discarded write asked for, so its ids are still learned.
A reply that names the Thread's local id, from a buffer drawn before the
discard, reaches the Thread under GitHub's id."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (let ((callback nil))
        (cl-letf (((symbol-function 'ghub-query)
                   (lambda (_query _variables &rest args)
                     (setq callback (plist-get args :callback)))))
          (let* ((thread (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor
                                                              :body "Nit." :commit "1111")))
                 (local (plist-get (prrr-outbox-payload thread) :thread)))
            (prrr-test-run-timers 'prrr-sync--outbox-timed-out)
            (prrr-sync-discard (prrr-outbox-id thread))
            (prrr-sync-test--queue 'reply (list :thread-id local :comment "local:R"
                                                :body "More."))
            (prrr-test-with-ghub-dispatch
                `((addPullRequestReviewThreadReply . ,(prrr-test-fixture "add-reply")))
              (funcall callback (prrr-test-fixture "add-thread"))
              (should (equal "PRRT_kwDOexampleNew01" (gethash local prrr-sync--renames)))
              (should (equal '(addPullRequestReviewThreadReply) prrr-test-requests))
              (should (equal "PRRT_kwDOexampleNew01"
                             (alist-get 'pullRequestReviewThreadId
                                        (prrr-sync-test--input
                                         'addPullRequestReviewThreadReply))))
              (should-not (prrr-db-outbox-rows)))))))))

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

(ert-deftest prrr-sync-test-outbox-discard-of-an-unknown-write-drops-none ()
  "A write sent between choosing it and confirming is gone: none dropped, not nil."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (should (eql 0 (prrr-sync-discard "no-such-write"))))))

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

(defun prrr-sync-test--age-refetch-attempt ()
  "Make the last refetch of the fixture PR look older than the retry spacing."
  (let ((key (cons 'review prrr-sync-test--pr)))
    (puthash key (plist-put (copy-sequence (gethash key prrr-sync--status)) :attempted-at
                            (prrr-sync--timestamp
                             (time-subtract nil (1+ prrr-sync-min-retry-spacing))))
             prrr-sync--status)))

(defun prrr-sync-test--refetch-timers ()
  "The recorded timers that start a refetch."
  (seq-filter (lambda (timer) (eq (nth 1 timer) 'prrr-sync--refetch)) prrr-test-timers))

(ert-deftest prrr-sync-test-outbox-retries-a-failed-refetch ()
  "A reply to a Thread published at once does not need G when the refetch fails.
The reply waits for the Thread's id, which only a refetch brings; a
failed refetch is tried again on a later pump, no sooner than
`prrr-sync-min-retry-spacing' after it started, and the Outbox pumps
by itself then."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      ;; What a successful Immediate Publish leaves: GitHub's comment id in a
      ;; local Thread, and its PR marked for a refetch.
      (prrr-db-insert (prrr-comment-create :comment-id "PRRC_kwDOexample0000006"
                                           :thread-id "local:T" :pr-id prrr-sync-test--pr
                                           :state 'submitted :local-state 'sent))
      (let ((reply (prrr-sync-test--queue 'reply '(:thread-id "local:T" :comment "local:R"
                                                   :body "More."))))
        (prrr-sync--outbox-mark-dirty reply))
      (prrr-test-with-ghub-dispatch '((repository . (:error (error http 502))))
        (prrr-sync--outbox-pump)
        (prrr-test-run-timers 'prrr-sync--refetch)
        (should (equal '(repository) prrr-test-requests))
        (should (gethash prrr-sync-test--pr prrr-sync--outbox-dirty))
        ;; Too soon: a pump now does not refetch.
        (prrr-sync--outbox-pump)
        (should-not (prrr-sync-test--refetch-timers))
        (should (seq-find (lambda (timer) (eq (nth 1 timer) 'prrr-sync--retry-pump))
                          prrr-test-timers)))
      (prrr-sync-test--age-refetch-attempt)
      (prrr-test-with-ghub-dispatch
          `((repository . ,(prrr-test-fixture "review-data"))
            (addPullRequestReviewThreadReply . ,(prrr-test-fixture "add-reply")))
        (prrr-test-run-timers 'prrr-sync--retry-pump)
        (prrr-test-run-timers 'prrr-sync--refetch)
        (should (equal '(repository addPullRequestReviewThreadReply) prrr-test-requests))
        (should (equal "PRRT_kwDOexample0000005"
                       (alist-get 'pullRequestReviewThreadId
                                  (prrr-sync-test--input 'addPullRequestReviewThreadReply))))
        (should-not (prrr-db-outbox-rows))))))

(ert-deftest prrr-sync-test-outbox-refetch-after-a-recent-failure-is-pumped ()
  "A PR changed shortly after a failed refetch is refetched once spacing allows.
The failed refetch was a Review Buffer's, which the Outbox did not need;
the Outbox still pumps by itself when the PR may be refetched, so the
reply waiting for its Thread's id does not need G."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (prrr-test-with-ghub-dispatch '((repository . (:error (error http 502))))
        (prrr-sync-refetch (prrr-sync-test--repo) (prrr-sync-test--pullreq)))
      (setq prrr-test-timers nil)
      ;; Then an Immediate Publish succeeds: its comment sits in a local Thread.
      (prrr-db-insert (prrr-comment-create :comment-id "PRRC_kwDOexample0000006"
                                           :thread-id "local:T" :pr-id prrr-sync-test--pr
                                           :state 'submitted :local-state 'sent))
      (prrr-sync--outbox-mark-dirty
       (prrr-sync-test--queue 'reply '(:thread-id "local:T" :comment "local:R" :body "More.")))
      (prrr-sync--outbox-pump)
      (should-not (prrr-sync-test--refetch-timers))
      (let ((pumps (seq-filter (lambda (timer) (eq (nth 1 timer) 'prrr-sync--retry-pump))
                               prrr-test-timers)))
        (should (= 1 (length pumps)))
        (should (< 0 (car (car pumps)) (1+ prrr-sync-min-retry-spacing))))
      ;; Another pump meanwhile does not stack a second timer.
      (prrr-sync--outbox-pump)
      (should (= 1 (seq-count (lambda (timer) (eq (nth 1 timer) 'prrr-sync--retry-pump))
                              prrr-test-timers)))
      (prrr-sync-test--age-refetch-attempt)
      (prrr-test-with-ghub-dispatch
          `((repository . ,(prrr-test-fixture "review-data"))
            (addPullRequestReviewThreadReply . ,(prrr-test-fixture "add-reply")))
        (prrr-test-run-timers 'prrr-sync--retry-pump)
        (prrr-test-run-timers 'prrr-sync--refetch)
        (should (equal '(repository addPullRequestReviewThreadReply) prrr-test-requests))
        (should-not (prrr-db-outbox-rows))))))

(ert-deftest prrr-sync-test-outbox-retries-a-refetch-without-answer ()
  "A refetch the Outbox needed that GitHub never answers is tried again too."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (puthash prrr-sync-test--pr (prrr-sync--target (prrr-sync-test--repo)
                                                     (prrr-sync-test--pullreq))
               prrr-sync--outbox-dirty)
      (prrr-sync--outbox-pump)
      (cl-letf (((symbol-function 'ghub-query) #'ignore))
        (prrr-test-run-timers 'prrr-sync--refetch))
      (should-not (gethash prrr-sync-test--pr prrr-sync--outbox-dirty))
      (let ((watchdog (seq-find (lambda (timer) (eql (car timer) prrr-sync-timeout))
                                prrr-test-timers)))
        (apply (nth 1 watchdog) (nth 2 watchdog)))
      (should (eq 'offline (plist-get (prrr-sync-review-status prrr-sync-test--pr) :state)))
      (should (gethash prrr-sync-test--pr prrr-sync--outbox-dirty)))))

(ert-deftest prrr-sync-test-failed-refetch-not-needed-is-not-retried ()
  "A refetch the Outbox did not ask for, such as a Review Buffer's, is not retried."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch '((repository . (:error (error http 502))))
        (prrr-sync-refetch (prrr-sync-test--repo) (prrr-sync-test--pullreq))
        (should (equal '(repository) prrr-test-requests))
        (should-not (gethash prrr-sync-test--pr prrr-sync--outbox-dirty))))))

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

;;;; Writes confirmed after their target was sent

(defun prrr-sync-test--sent-thread ()
  "Comment on the fixture PR and let GitHub accept it.
Return the local ids it was written under, as (THREAD . COMMENT)."
  (prrr-sync-test--store-pending-review)
  (prrr-test-with-ghub-dispatch
      `((addPullRequestReviewThread . ,(prrr-test-fixture "add-thread")))
    (let ((payload (prrr-outbox-payload
                    (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor
                                                         :body "Nit." :commit "1111")))))
      (should-not (prrr-db-outbox-rows))
      (cons (plist-get payload :thread) (plist-get payload :comment)))))

(ert-deftest prrr-sync-test-outbox-reply-confirmed-after-its-thread-was-sent ()
  "Review Focus 3: a reply naming a Thread's local id after its success goes out."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (let ((ids (prrr-sync-test--sent-thread)))
        (prrr-test-with-ghub-dispatch
            `((addPullRequestReviewThreadReply . ,(prrr-test-fixture "add-reply")))
          (prrr-sync-test--write 'reply (list :thread-id (car ids) :body "And this."))
          (should (equal '(addPullRequestReviewThreadReply) prrr-test-requests))
          (should (equal "PRRT_kwDOexampleNew01"
                         (alist-get 'pullRequestReviewThreadId
                                    (prrr-sync-test--input 'addPullRequestReviewThreadReply))))
          (should-not (prrr-db-outbox-rows)))))))

(ert-deftest prrr-sync-test-outbox-edit-confirmed-after-its-comment-was-sent ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (let ((ids (prrr-sync-test--sent-thread)))
        (prrr-test-with-ghub-dispatch
            '((updatePullRequestReviewComment . ((data (updatePullRequestReviewComment
                                                        (clientMutationId))))))
          (prrr-sync-test--write 'edit (list :comment-id (cdr ids) :body "Better."))
          (should (equal "PRRC_kwDOexampleNew01"
                         (alist-get 'pullRequestReviewCommentId
                                    (prrr-sync-test--input 'updatePullRequestReviewComment))))
          (should-not (prrr-db-outbox-rows))
          (should (equal "Better." (prrr-comment-body
                                    (prrr-db-get 'review-comment "PRRC_kwDOexampleNew01")))))))))

(ert-deftest prrr-sync-test-outbox-delete-confirmed-after-its-comment-was-sent ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (let ((ids (prrr-sync-test--sent-thread)))
        (prrr-test-with-ghub-dispatch
            '((deletePullRequestReviewComment . ((data (deletePullRequestReviewComment
                                                        (clientMutationId))))))
          (prrr-sync-test--write 'delete (list :comment-id (cdr ids)))
          (should (equal "PRRC_kwDOexampleNew01"
                         (alist-get 'id (prrr-sync-test--input
                                         'deletePullRequestReviewComment))))
          (should-not (prrr-db-outbox-rows))
          (should-not (prrr-db-get 'review-comment "PRRC_kwDOexampleNew01")))))))

(ert-deftest prrr-sync-test-outbox-reply-confirmed-after-a-refetch-named-its-thread ()
  "A reply naming a published Thread's local id after the refetch that renamed it goes out."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (prrr-db-insert (prrr-comment-create :comment-id "PRRC_kwDOexample0000006"
                                           :thread-id "local:T" :pr-id prrr-sync-test--pr
                                           :state 'submitted :local-state 'sent))
      (prrr-test-with-ghub-dispatch
          `((repository . ,(prrr-test-fixture "review-data"))
            (addPullRequestReviewThreadReply . ,(prrr-test-fixture "add-reply")))
        (prrr-sync-refetch (prrr-sync-test--repo) (prrr-sync-test--pullreq))
        (prrr-sync-test--write 'reply '(:thread-id "local:T" :body "More."))
        (should (equal '(repository addPullRequestReviewThreadReply) prrr-test-requests))
        (should (equal "PRRT_kwDOexample0000005"
                       (alist-get 'pullRequestReviewThreadId
                                  (prrr-sync-test--input 'addPullRequestReviewThreadReply))))))))

;;;; Unconfirmed writes (bead prrr-3ha)

(defun prrr-sync-test--landed-data (&optional body)
  "The review-data fixture with my new Thread on src/example.el, made now.
Its one comment, PRRC_kwDOexampleLanded in PRRT_kwDOexampleLanded, has
BODY, \"Nit.\" by default, as a Thread the Outbox could not confirm left it."
  (let* ((data (copy-tree (prrr-test-fixture "review-data")))
         (pr (cdr (assq 'pullRequest (cdr (assq 'repository (cdr data))))))
         (threads (assq 'reviewThreads pr)))
    (setcdr threads
            (append (cdr threads)
                    `(((id . "PRRT_kwDOexampleLanded") (path . "src/example.el") (line . 12)
                       (startLine) (diffSide . "RIGHT") (startDiffSide) (originalLine . 12)
                       (isOutdated) (isResolved) (subjectType . "LINE")
                       (viewerCanResolve . t) (viewerCanUnresolve . t)
                       (comments
                        ((id . "PRRC_kwDOexampleLanded") (fullDatabaseId . "2009")
                         (author (login . "example-me")) (body . ,(or body "Nit."))
                         (createdAt . ,(prrr-sync--timestamp)) (lastEditedAt) (replyTo)
                         (state . "PENDING")
                         (pullRequestReview (id . "PRR_kwDOexamplePending1"))
                         (originalCommit (oid . ,prrr-test-head))))))))
    data))

(defun prrr-sync-test--unconfirmed-thread ()
  "Comment on the fixture PR; GitHub never answers, and the watchdog ends the send.
The Pending Review is the review-data fixture's.  Return the row of the write."
  (prrr-db-insert (prrr-pending-review-create :pr-id prrr-sync-test--pr
                                              :review-id "PRR_kwDOexamplePending1"
                                              :commit-oid prrr-test-head))
  (cl-letf (((symbol-function 'ghub-query) #'ignore))
    (prog1 (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor :body "Nit."
                                                :commit prrr-test-head))
      (prrr-test-run-timers 'prrr-sync--outbox-timed-out))))

(ert-deftest prrr-sync-test-outbox-timeout-then-retry-does-not-resend ()
  "A write without an answer is unconfirmed: a retry re-checks the PR, never resends."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (let ((sent 0))
        (cl-letf (((symbol-function 'ghub-query) (lambda (&rest _) (cl-incf sent))))
          (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor :body "Nit."
                                               :commit "1111"))
          (should (plist-get (prrr-outbox-payload (car (prrr-db-outbox-rows))) :sent-at))
          (prrr-test-run-timers 'prrr-sync--outbox-timed-out)
          (should-not prrr-sync--outbox-sending)
          (let ((row (car (prrr-db-outbox-rows))))
            (should (prrr-state-outbox-unconfirmed-p row))
            (should-not (prrr-outbox-last-error row)))
          ;; The PR is refetched to decide, though its first write is not sent.
          (should (gethash prrr-sync-test--pr prrr-sync--outbox-dirty))
          (should (seq-find (lambda (timer) (eq (nth 1 timer) 'prrr-sync--refetch))
                            prrr-test-timers))
          (remhash prrr-sync-test--pr prrr-sync--outbox-dirty)
          (prrr-sync-retry prrr-sync-test--pr)
          (should (gethash prrr-sync-test--pr prrr-sync--outbox-dirty))
          (prrr-sync-retry)
          (should (= 1 sent)))))))

(ert-deftest prrr-sync-test-outbox-refetch-confirms-an-unconfirmed-thread ()
  "A refetch that finds the comment records it once, with GitHub's ids, and renames."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (let* ((thread (prrr-sync-test--unconfirmed-thread))
             (local (plist-get (prrr-outbox-payload thread) :thread)))
        (prrr-test-with-ghub-dispatch nil
          (prrr-sync-test--write 'reply (list :thread-id local :body "And this."))
          (should-not prrr-test-requests))
        (prrr-test-with-ghub-dispatch
            `((repository . ,(prrr-sync-test--landed-data))
              (addPullRequestReviewThreadReply . ,(prrr-test-fixture "add-reply")))
          (prrr-test-run-timers 'prrr-sync--refetch)
          ;; Any later request is the refetch that follows the reply's success.
          (should (equal '(repository addPullRequestReviewThreadReply)
                         (seq-take prrr-test-requests 2)))
          (should (equal "PRRT_kwDOexampleLanded"
                         (alist-get 'pullRequestReviewThreadId
                                    (prrr-sync-test--input 'addPullRequestReviewThreadReply)))))
        (should-not (prrr-db-outbox-rows))
        (should (equal "PRRT_kwDOexampleLanded" (gethash local prrr-sync--renames)))
        (should (= 1 (seq-count (lambda (comment) (equal "Nit." (prrr-comment-body comment)))
                                (prrr-db-select 'review-comment :pr-id prrr-sync-test--pr))))
        (should (equal "2009" (prrr-comment-database-id
                               (prrr-db-get 'review-comment "PRRC_kwDOexampleLanded"))))))))

(ert-deftest prrr-sync-test-outbox-refetch-without-the-write-resends-it ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--unconfirmed-thread)
      (prrr-test-with-ghub-dispatch
          `((repository . ,(prrr-sync-test--landed-data "Something else."))
            (addPullRequestReviewThread . ,(prrr-test-fixture "add-thread")))
        (prrr-test-run-timers 'prrr-sync--refetch)
        (should (equal '(repository addPullRequestReviewThread) prrr-test-requests)))
      (should-not (prrr-db-outbox-rows))
      (should (prrr-db-get 'review-comment "PRRC_kwDOexampleNew01")))))

(ert-deftest prrr-sync-test-outbox-edit-of-an-unconfirmed-comment-waits ()
  "An edit while the creation is unconfirmed is its own write, sent once it is confirmed."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (let ((comment (plist-get (prrr-outbox-payload (prrr-sync-test--unconfirmed-thread))
                                :comment)))
        (prrr-test-with-ghub-dispatch nil
          (prrr-sync-test--write 'edit (list :comment-id comment :body "Better.")))
        (should (equal '(thread edit) (mapcar #'prrr-outbox-kind (prrr-db-outbox-rows))))
        (should (equal "Nit." (plist-get (prrr-outbox-payload (car (prrr-db-outbox-rows)))
                                         :body)))
        (prrr-test-with-ghub-dispatch
            `((repository . ,(prrr-sync-test--landed-data))
              (updatePullRequestReviewComment . ((data (updatePullRequestReviewComment
                                                        (clientMutationId))))))
          (prrr-test-run-timers 'prrr-sync--refetch)
          ;; Any later request is the refetch that follows the edit's success.
          (should (equal '(repository updatePullRequestReviewComment)
                         (seq-take prrr-test-requests 2)))
          (let ((input (prrr-sync-test--input 'updatePullRequestReviewComment)))
            (should (equal "PRRC_kwDOexampleLanded"
                           (alist-get 'pullRequestReviewCommentId input)))
            (should (equal "Better." (alist-get 'body input)))))
        (should-not (prrr-db-outbox-rows))))))

(ert-deftest prrr-sync-test-outbox-restart-refetches-before-sending ()
  "Bead prrr-nfa: a write cut off by a restart is checked, then sent, without a buffer."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--queue 'viewed (list :path "docs/notes.md" :viewed t
                                           :sent-at (prrr-sync--timestamp))))
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch
          `((repository . ,(prrr-test-fixture "review-data"))
            (markFileAsViewed . ,prrr-sync-test--mark-viewed))
        (prrr-sync-outbox-start)
        (prrr-sync-outbox-start)
        (should (= 1 (seq-count (lambda (timer) (eq (nth 1 timer) 'prrr-sync--outbox-pump))
                                prrr-test-timers)))
        (prrr-test-run-timers 'prrr-sync--outbox-pump)
        (should-not prrr-test-requests)
        (prrr-test-run-timers 'prrr-sync--refetch)
        (should (equal '(repository markFileAsViewed) prrr-test-requests))
        (should-not (prrr-db-outbox-rows))))))

(ert-deftest prrr-sync-test-outbox-starts-when-the-database-opens ()
  "Opening the database is the one step every entry point takes first."
  (should (memq #'prrr-sync-outbox-start prrr-db-open-hook)))

(ert-deftest prrr-sync-test-outbox-discard-of-an-unconfirmed-write-refetches ()
  "An unconfirmed write may be dropped; the PR is refetched to show what GitHub has."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--unconfirmed-thread)
      (clrhash prrr-sync--outbox-dirty)
      (should (= 1 (prrr-sync-discard (prrr-outbox-id (car (prrr-db-outbox-rows))))))
      (should-not (prrr-db-outbox-rows))
      (should (gethash prrr-sync-test--pr prrr-sync--outbox-dirty)))))

(defvar prrr-sync-test--held nil
  "Requests `prrr-sync-test--with-held-answers' held, newest first.")

(defmacro prrr-sync-test--with-held-answers (answers &rest body)
  "Run BODY with `ghub-query' answering `repository' requests from ANSWERS.
ANSWERS is a function of no argument returning the review data to
answer with.  Every other request is held: its field, callback and
errorback are pushed onto `prrr-sync-test--held', newest first."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'ghub-query)
              (lambda (query _variables &rest args)
                (let ((field (car (cadr query))))
                  (if (and (eq field 'repository) ,answers)
                      (funcall (plist-get args :callback) (funcall ,answers))
                    (push (list field (plist-get args :callback) (plist-get args :errorback))
                          prrr-sync-test--held))))))
     ,@body))

(ert-deftest prrr-sync-test-outbox-late-setup-starts-no-mutation ()
  "A Pending Review found after the watchdog ended the send adds no Thread."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (let ((prrr-sync-test--held nil))
        (prrr-sync-test--with-held-answers nil
          (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor :body "Nit."
                                               :commit prrr-test-head))
          (should (equal '(repository) (mapcar #'car prrr-sync-test--held)))
          (prrr-test-run-timers 'prrr-sync--outbox-timed-out)
          (funcall (nth 1 (car prrr-sync-test--held)) (prrr-test-fixture "pending-review"))
          (should (equal '(repository) (mapcar #'car prrr-sync-test--held)))
          (should-not prrr-sync--outbox-creations)
          (should (prrr-state-outbox-unconfirmed-p (car (prrr-db-outbox-rows)))))))))

(ert-deftest prrr-sync-test-outbox-late-success-records-the-stored-row ()
  "An edit made after a refetch judged the write missing is not lost to a late success."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (let ((prrr-sync-test--held nil))
        (prrr-db-insert (prrr-pending-review-create :pr-id prrr-sync-test--pr
                                                    :review-id "PRR_kwDOexamplePending1"
                                                    :commit-oid prrr-test-head))
        (prrr-sync-test--with-held-answers
            (lambda () (prrr-sync-test--landed-data "Something else."))
          (let* ((row (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor
                                                           :body "Nit." :commit prrr-test-head)))
                 (comment (plist-get (prrr-outbox-payload row) :comment))
                 (first (car prrr-sync-test--held)))
            (prrr-test-run-timers 'prrr-sync--outbox-timed-out)
            ;; The refetch says missing; a rate limit keeps it from going out again.
            (setq prrr-sync--outbox-paused-until "2999-01-01T00:00:00Z")
            (prrr-test-run-timers 'prrr-sync--refetch)
            (should-not (prrr-state-outbox-unconfirmed-p (car (prrr-db-outbox-rows))))
            (prrr-sync-test--write 'edit (list :comment-id comment :body "Better."))
            (should (= 1 (length (prrr-db-outbox-rows))))
            (funcall (nth 1 first) (prrr-test-fixture "add-thread"))
            (should (equal "Better." (prrr-comment-body
                                      (prrr-db-get 'review-comment "PRRC_kwDOexampleNew01"))))
            ;; GitHub has the old body: an edit carries the new one there.
            (let ((edit (car (prrr-db-outbox-rows))))
              (should (eq 'edit (prrr-outbox-kind edit)))
              (should (equal '("PRRC_kwDOexampleNew01" "Better.")
                             (list (plist-get (prrr-outbox-payload edit) :comment-id)
                                   (plist-get (prrr-outbox-payload edit) :body)))))))))))

(ert-deftest prrr-sync-test-outbox-late-failure-of-an-earlier-send-is-ignored ()
  "A failure answering the first send leaves the marker of the second alone."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (let ((prrr-sync-test--held nil))
        (prrr-sync-test--with-held-answers (lambda () (prrr-test-fixture "review-data"))
          (prrr-sync-test--write 'viewed '(:path "docs/notes.md" :viewed t))
          (let ((first (car prrr-sync-test--held)))
            (prrr-test-run-timers 'prrr-sync--outbox-timed-out)
            ;; The refetch says missing and the write goes out again, a second later.
            (cl-letf (((symbol-function 'prrr-sync--timestamp)
                       (lambda (&optional _time) "2099-01-01T00:00:00Z")))
              (prrr-test-run-timers 'prrr-sync--refetch))
            (should (= 2 (length prrr-sync-test--held)))
            (prrr-test-run-timers 'prrr-sync--outbox-timed-out)
            (funcall (nth 2 first) '(error http 502) nil nil nil)
            (let ((row (car (prrr-db-outbox-rows))))
              (should (equal "2099-01-01T00:00:00Z"
                             (plist-get (prrr-outbox-payload row) :sent-at)))
              (should-not (prrr-outbox-last-error row))
              (should (= 0 (prrr-outbox-attempts row))))))))))

(ert-deftest prrr-sync-test-outbox-late-failure-is-recorded ()
  "A failure that answers after the watchdog counts, without touching the next send."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (let ((errorback nil))
        (cl-letf (((symbol-function 'ghub-query)
                   (lambda (_query _variables &rest args)
                     (setq errorback (plist-get args :errorback)))))
          (prrr-sync-test--write 'viewed '(:path "a.el" :viewed t)))
        (prrr-test-run-timers 'prrr-sync--outbox-timed-out)
        (let ((other (prrr-outbox-create :id "other" :pr-id "PR_other" :kind 'viewed)))
          ;; Another PR's write is being sent now.
          (setq prrr-sync--outbox-sending other)
          (cl-incf prrr-sync--outbox-token)
          (funcall errorback '(error http 502) nil nil nil)
          (should (eq other prrr-sync--outbox-sending)))
        (let ((row (car (prrr-db-outbox-rows))))
          (should (equal "GitHub returned HTTP 502" (prrr-outbox-last-error row)))
          (should (= 1 (prrr-outbox-attempts row)))
          (should-not (prrr-state-outbox-unconfirmed-p row)))))))

(ert-deftest prrr-sync-test-outbox-unconfirmed-discussion-fails-asking-to-check ()
  "A refetch cannot show a Discussion Comment: the user checks the PR, then decides."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (cl-letf (((symbol-function 'ghub-query) #'ignore))
        (prrr-sync-test--write 'discussion '(:body "Thanks!"))
        (prrr-test-run-timers 'prrr-sync--outbox-timed-out))
      (prrr-test-with-ghub-dispatch `((repository . ,(prrr-test-fixture "review-data")))
        (prrr-test-run-timers 'prrr-sync--refetch)
        (should (equal '(repository) prrr-test-requests)))
      (let ((row (car (prrr-db-outbox-rows))))
        (should (equal prrr-sync-unconfirmed-message (prrr-outbox-last-error row)))
        (should (string-match-p "check" (prrr-outbox-last-error row)))
        (should (prrr-state-outbox-awaiting-user-p row))))))

(defun prrr-sync-test--discussion-awaiting-user ()
  "Post a Discussion Comment GitHub never answers; a refetch cannot confirm it."
  (cl-letf (((symbol-function 'ghub-query) #'ignore))
    (prrr-sync-test--write 'discussion '(:body "Thanks!"))
    (prrr-test-run-timers 'prrr-sync--outbox-timed-out))
  (prrr-test-with-ghub-dispatch `((repository . ,(prrr-test-fixture "review-data")))
    (prrr-test-run-timers 'prrr-sync--refetch))
  (setq prrr-test-timers nil)
  (should (prrr-state-outbox-awaiting-user-p (car (prrr-db-outbox-rows)))))

(ert-deftest prrr-sync-test-outbox-awaiting-user-survives-a-refetch ()
  "A later refetch keeps a write a refetch could not confirm for the user."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--discussion-awaiting-user)
      (prrr-test-with-ghub-dispatch `((repository . ,(prrr-test-fixture "review-data")))
        (should (prrr-sync-refetch (prrr-sync-test--repo) (prrr-sync-test--pullreq)))
        (prrr-test-run-timers 'prrr-sync--outbox-pump)
        (should (equal '(repository) prrr-test-requests)))
      (should (equal prrr-sync-unconfirmed-message
                     (prrr-outbox-last-error (car (prrr-db-outbox-rows))))))))

(ert-deftest prrr-sync-test-outbox-awaiting-user-survives-another-write ()
  "Another write on the PR does not send it either."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--discussion-awaiting-user)
      (prrr-test-with-ghub-dispatch `((repository . ,(prrr-test-fixture "review-data")))
        (prrr-sync-test--write 'viewed '(:path "a.el" :viewed t))
        (prrr-test-run-timers 'prrr-sync--refetch)
        (should-not (memq 'addComment prrr-test-requests))
        (should-not (memq 'markFileAsViewed prrr-test-requests)))
      (let ((row (car (prrr-db-outbox-rows))))
        (should (eq 'discussion (prrr-outbox-kind row)))
        (should (prrr-state-outbox-awaiting-user-p row))))))

(ert-deftest prrr-sync-test-outbox-awaiting-user-goes-on-resend ()
  "The user's retry (O r) sends it, and what waited behind it."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--discussion-awaiting-user)
      (prrr-test-with-ghub-dispatch `((addComment . ,(prrr-test-fixture "add-comment")))
        (prrr-sync-retry prrr-sync-test--pr)
        (should-not prrr-test-requests)
        (prrr-sync-resend prrr-sync-test--pr)
        (should (equal '(addComment) prrr-test-requests)))
      (should-not (prrr-db-outbox-rows)))))

;;;; Every kind of write

(ert-deftest prrr-sync-test-outbox-publish ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-rest-stub (prrr-test-fixture "publish-comment") captured
        (let ((row (prrr-sync-test--write 'publish (list :anchor prrr-sync-test--anchor
                                                         :body "Now." :commit "1111"))))
          (should (equal "/repos/example-org/example-repo/pulls/1/comments" (cadr captured)))
          (let ((comment (prrr-db-get 'review-comment "PRRC_kwDOexampleNew03")))
            (should (equal (plist-get (prrr-outbox-payload row) :thread)
                           (prrr-comment-thread-id comment)))
            (should (eq 'submitted (prrr-comment-state comment)))
            (should (equal "3001" (prrr-comment-database-id comment)))))))))

(ert-deftest prrr-sync-test-outbox-success-without-ids-is-unconfirmed ()
  "GitHub made the comment, but its answer does not name it: never resent blindly.
Another write on the PR does not send it again; the refetch that finds
the comment records it once."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (let ((posts 0))
        (prrr-test-with-rest-stub
            (progn (cl-incf posts)
                   (mapcar (lambda (pair) (if (eq (car pair) 'node_id) (list 'node_id) pair))
                           (prrr-test-fixture "publish-comment")))
            captured
          (let ((row (prrr-sync-test--write 'publish (list :anchor prrr-sync-test--anchor
                                                           :body "Nit." :commit prrr-test-head))))
            (should (equal "POST" (car captured)))
            (let ((stored (prrr-db-get 'outbox (prrr-outbox-id row))))
              (should (prrr-state-outbox-unconfirmed-p stored))
              (should-not (prrr-outbox-last-error stored)))
            (should-not prrr-sync--outbox-sending)
            (should (gethash prrr-sync-test--pr prrr-sync--outbox-dirty))
            (prrr-test-with-ghub-dispatch nil
              (prrr-sync-test--write 'viewed '(:path "a.el" :viewed t))
              (should-not prrr-test-requests))
            (should (= 1 posts))
            (prrr-test-with-ghub-dispatch `((repository . ,(prrr-sync-test--landed-data))
                                            (markFileAsViewed . ,prrr-sync-test--mark-viewed))
              (prrr-test-run-timers 'prrr-sync--refetch)
              (should (equal '(repository markFileAsViewed) (seq-take prrr-test-requests 2))))
            (should (= 1 posts))
            (should-not (prrr-db-outbox-rows))
            (should (= 1 (seq-count (lambda (comment) (equal "Nit." (prrr-comment-body comment)))
                                    (prrr-db-select 'review-comment
                                                    :pr-id prrr-sync-test--pr))))))))))

(ert-deftest prrr-sync-test-outbox-publish-reply ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-db-replace-review-data
       prrr-sync-test--pr
       (prrr-github-decode-review-data (prrr-test-fixture "review-data") prrr-sync-test--pr))
      (prrr-test-with-rest-stub (prrr-test-fixture "publish-reply") captured
        (prrr-sync-test--write 'publish-reply '(:thread-id "PRRT_kwDOexample0000001"
                                                :body "Done."))
        (should (equal "/repos/example-org/example-repo/pulls/1/comments/1001/replies"
                       (cadr captured)))
        (should (prrr-db-get 'review-comment "PRRC_kwDOexampleNew04"))))))

(ert-deftest prrr-sync-test-outbox-discussion-pulls-the-topic ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (let ((pulled nil))
        (with-temp-buffer
          (setq-local forge-buffer-topic 'example-topic)
          (cl-letf (((symbol-function 'forge-pull-topic)
                     (lambda (topic) (interactive) (setq pulled topic))))
            (prrr-test-with-ghub-dispatch `((addComment . ,(prrr-test-fixture "add-comment")))
              (prrr-sync-write (prrr-sync-test--repo) (prrr-sync-test--pullreq) 'discussion
                               '(:body "Thanks!") (current-buffer))
              (should (equal prrr-sync-test--pr
                             (alist-get 'subjectId (prrr-sync-test--input 'addComment)))))))
        (should (eq 'example-topic pulled))
        (should-not (prrr-db-outbox-rows))))))

(ert-deftest prrr-sync-test-outbox-discussion-shows-until-forge-has-it ()
  "A posted Discussion Comment stays visible until forge's topic lists it."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch `((addComment . ,(prrr-test-fixture "add-comment")))
        (prrr-sync-test--write 'discussion '(:body "Thanks!")))
      (should-not (prrr-db-outbox-rows))
      (should-not (plist-get (prrr-sync-review-data prrr-sync-test--pr) :discussion))
      (let ((posted (prrr-sync-posted-discussion prrr-sync-test--pr nil)))
        (should (equal '(("Thanks!" 5001))
                       (mapcar (lambda (post) (list (plist-get post :body)
                                                    (plist-get post :database-id)))
                               posted))))
      (should (prrr-sync-posted-discussion
               prrr-sync-test--pr (list (forge-pullreq-post :id "other" :number 4001))))
      (should-not (prrr-sync-posted-discussion
                   prrr-sync-test--pr (list (forge-pullreq-post :id "p" :number 5001)))))))

(ert-deftest prrr-sync-test-outbox-edit-amends-an-unsent-comment ()
  "Review Focus 3: editing what GitHub has not got changes the queued write."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (prrr-test-with-ghub-dispatch '((addPullRequestReviewThread . (:error (error http 502))))
        (let* ((thread (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor
                                                            :body "Nit." :commit "1111")))
               (comment (plist-get (prrr-outbox-payload thread) :comment)))
          (should (equal (prrr-outbox-id thread)
                         (prrr-outbox-id (prrr-sync-test--write 'edit (list :comment-id comment
                                                                         :body "Better.")))))
          (should (equal '(thread) (mapcar #'prrr-outbox-kind (prrr-db-outbox-rows))))
          (should (equal "Better." (plist-get (prrr-outbox-payload (car (prrr-db-outbox-rows)))
                                              :body)))
          ;; The edit retried the write.
          (should (equal '(addPullRequestReviewThread addPullRequestReviewThread)
                         prrr-test-requests)))))))

(ert-deftest prrr-sync-test-outbox-edit-of-a-comment-being-sent-queues ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (cl-letf (((symbol-function 'ghub-query) #'ignore))
        (let* ((thread (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor
                                                            :body "Nit." :commit "1111")))
               (comment (plist-get (prrr-outbox-payload thread) :comment)))
          (prrr-sync-test--write 'edit (list :comment-id comment :body "Better."))
          (should (equal '(thread edit) (mapcar #'prrr-outbox-kind (prrr-db-outbox-rows))))
          (should (equal "Better." (prrr-comment-body
                                    (car (last (plist-get (prrr-sync-review-data
                                                           prrr-sync-test--pr)
                                                          :comments)))))))))))

(ert-deftest prrr-sync-test-outbox-delete-drops-an-unsent-comment ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (prrr-test-with-ghub-dispatch '((addPullRequestReviewThread . (:error (error http 502))))
        (let* ((thread (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor
                                                            :body "Nit." :commit "1111")))
               (comment (plist-get (prrr-outbox-payload thread) :comment)))
          (should-not (prrr-sync-test--write 'delete (list :comment-id comment)))
          (should-not (prrr-db-outbox-rows))
          (should-not (plist-get (prrr-sync-review-data prrr-sync-test--pr) :threads)))))))

(ert-deftest prrr-sync-test-outbox-edit-delete-resolve-sent ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-db-replace-review-data
       prrr-sync-test--pr
       (prrr-github-decode-review-data (prrr-test-fixture "review-data") prrr-sync-test--pr))
      (prrr-test-with-ghub-dispatch
          '((updatePullRequestReviewComment . ((data (updatePullRequestReviewComment
                                                      (clientMutationId)))))
            (deletePullRequestReviewComment . ((data (deletePullRequestReviewComment
                                                      (clientMutationId)))))
            (resolveReviewThread . ((data (resolveReviewThread (clientMutationId))))))
        (prrr-sync-test--write 'edit '(:comment-id "PRRC_kwDOexample0000002" :body "Fixed."))
        (prrr-sync-test--write 'resolve '(:thread-id "PRRT_kwDOexample0000001" :resolved t))
        (prrr-sync-test--write 'delete '(:comment-id "PRRC_kwDOexample0000006"))
        (should (equal '(updatePullRequestReviewComment resolveReviewThread
                         deletePullRequestReviewComment)
                       prrr-test-requests)))
      (should (equal "Fixed." (prrr-comment-body
                               (prrr-db-get 'review-comment "PRRC_kwDOexample0000002"))))
      (should (prrr-thread-resolved-p (prrr-db-get 'thread "PRRT_kwDOexample0000001")))
      ;; The deleted comment was its Thread's only one.
      (should-not (prrr-db-get 'review-comment "PRRC_kwDOexample0000006"))
      (should-not (prrr-db-get 'thread "PRRT_kwDOexample0000005")))))

(ert-deftest prrr-sync-test-outbox-submit-touches-the-pr ()
  "SPEC section 7: Submit sends the review and moves the PR to Served."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (prrr-db-insert (prrr-comment-create :comment-id "C1" :thread-id "T1"
                                           :pr-id prrr-sync-test--pr
                                           :state 'pending :local-state 'sent))
      (prrr-db-insert (prrr-pr-meta-create :pr-id prrr-sync-test--pr
                                           :forge-repo-id "example-repo-id" :number 1))
      (prrr-test-with-ghub-dispatch '((submitPullRequestReview
                                       . ((data (submitPullRequestReview (clientMutationId))))))
        (prrr-sync-test--write 'submit '(:verdict approve :body "LGTM" :commit "1111"))
        (should (equal "APPROVE" (alist-get 'event (prrr-sync-test--input
                                                    'submitPullRequestReview)))))
      (should-not (prrr-db-get 'pending-review prrr-sync-test--pr))
      (should (eq 'submitted (prrr-comment-state (prrr-db-get 'review-comment "C1"))))
      (should (equal '("APPROVED" "1111")
                     (let ((review (prrr-pr-meta-viewer-latest-review
                                    (prrr-db-get 'pullreq-meta prrr-sync-test--pr))))
                       (list (nth 0 review) (nth 2 review))))))))

(ert-deftest prrr-sync-test-outbox-submit-without-a-pending-review ()
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-test-with-ghub-dispatch
          `((repository . ,(prrr-test-fixture "pending-review-none"))
            (addPullRequestReview . ((data (addPullRequestReview (clientMutationId))))))
        (prrr-sync-test--write 'submit '(:verdict approve :body "" :commit "1111"))
        (should (equal '(repository addPullRequestReview) prrr-test-requests))
        (should (equal "APPROVE" (alist-get 'event (prrr-sync-test--input
                                                    'addPullRequestReview))))
        (should-not (prrr-db-outbox-rows))))))

(ert-deftest prrr-sync-test-outbox-discard-drops-queued-pending-writes ()
  "Review Focus 3: discarding takes the queued pending comments with it."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-sync-test--store-pending-review)
      (prrr-db-insert (prrr-comment-create :comment-id "C1" :thread-id "T1"
                                           :pr-id prrr-sync-test--pr
                                           :state 'pending :local-state 'sent))
      (prrr-db-insert (prrr-thread-create :thread-id "T1" :pr-id prrr-sync-test--pr))
      (prrr-db-insert (prrr-thread-create :thread-id "T2" :pr-id prrr-sync-test--pr))
      (prrr-db-insert (prrr-comment-create :comment-id "C2" :thread-id "T2"
                                           :pr-id prrr-sync-test--pr
                                           :state 'submitted :local-state 'sent))
      (prrr-db-insert (prrr-comment-create :comment-id "C3" :thread-id "T2"
                                           :pr-id prrr-sync-test--pr
                                           :state 'pending :local-state 'sent))
      (prrr-test-with-ghub-dispatch
          '((addPullRequestReviewThread . (:error (error http 502)))
            (deletePullRequestReview . ((data (deletePullRequestReview (clientMutationId))))))
        (prrr-sync-test--write 'thread (list :anchor prrr-sync-test--anchor :body "Nit."
                                             :commit "1111"))
        (prrr-sync-test--write 'discard nil)
        (should (equal '(addPullRequestReviewThread deletePullRequestReview) prrr-test-requests)))
      (should-not (prrr-db-outbox-rows))
      (should-not (prrr-db-get 'pending-review prrr-sync-test--pr))
      (should-not (prrr-db-get 'review-comment "C1"))
      (should-not (prrr-db-get 'thread "T1"))
      (should-not (prrr-db-get 'review-comment "C3"))
      (should (prrr-db-get 'thread "T2"))
      (should (prrr-db-get 'review-comment "C2")))))

;;;; Bookmark and pinned commits

(ert-deftest prrr-sync-test-pin-keeps-a-commit ()
  "SPEC section 8: pinning a commit creates its ref, once however often it is pinned."
  (prrr-test-with-repo
    (let ((first (car (process-lines "git" "rev-parse" "refs/pullreqs/1~1"))))
      (should (prrr-sync-pin 1 first))
      (should (equal (list first)
                     (process-lines "git" "rev-parse" (format "refs/prrr/1/%s" first))))
      ;; The ref is there once, however often the commit is pinned.
      (should (prrr-sync-pin 1 first))
      (should (equal (list (format "refs/prrr/1/%s" first))
                     (process-lines "git" "for-each-ref" "--format=%(refname)" "refs/prrr/"))))))

(ert-deftest prrr-sync-test-pin-unknown-commit ()
  (prrr-test-with-repo
    (should-not (prrr-sync-pin 1 "2222222222222222222222222222222222222222"))
    (should-not (prrr-sync-pin 1 nil))
    (should-not (process-lines "git" "for-each-ref" "refs/prrr/"))))

(ert-deftest prrr-sync-test-record-bookmark ()
  (prrr-db-with-test-db
    (prrr-test-with-repo
      (let ((head (car (process-lines "git" "rev-parse" "refs/pullreqs/1")))
            (pullreq (forge-pullreq :id "forge-1" :number 1 :their-id "PR_1")))
        (should (prrr-sync-record-bookmark pullreq head))
        (let ((bookmark (prrr-db-get 'pr-bookmark "PR_1")))
          (should (equal head (prrr-bookmark-last-opened-head-oid bookmark)))
          (should (prrr-bookmark-last-opened-at bookmark)))
        (should (equal (list head)
                       (process-lines "git" "rev-parse" (format "refs/prrr/1/%s" head))))))))

(ert-deftest prrr-sync-test-record-bookmark-of-a-missing-commit ()
  "The Bookmark is recorded even when its commit cannot be pinned."
  (prrr-db-with-test-db
    (prrr-test-with-repo
      (let ((missing "2222222222222222222222222222222222222222"))
        (should-not (prrr-sync-record-bookmark
                     (forge-pullreq :id "forge-1" :number 1 :their-id "PR_1") missing))
        (should (equal missing (prrr-bookmark-last-opened-head-oid
                                (prrr-db-get 'pr-bookmark "PR_1"))))
        (should-not (process-lines "git" "for-each-ref" "refs/prrr/"))))))

(defun prrr-sync-test--pin-refs ()
  "Return the sorted names of the pins in the repository of `default-directory'."
  (sort (process-lines "git" "for-each-ref" "--format=%(refname:strip=2)" "refs/prrr/")
        #'string<))

(ert-deftest prrr-sync-test-prune-pins-of-closed-pullreqs ()
  "SPEC section 8: only the pins of PRs that are no longer open go."
  (prrr-test-with-repo
    (let ((head (car (process-lines "git" "rev-parse" "refs/pullreqs/1")))
          (first (car (process-lines "git" "rev-parse" "refs/pullreqs/1~1"))))
      (dolist (number '(1 2 3))
        (prrr-sync-pin number head))
      (prrr-sync-pin 3 first)
      (should (= 3 (prrr-sync-prune-pins '(1))))
      (should (equal (list (format "1/%s" head)) (prrr-sync-test--pin-refs)))
      (should (= 0 (prrr-sync-prune-pins '(1)))))))

(ert-deftest prrr-sync-test-prune-pins-keeps-a-live-review-buffer ()
  "A PR whose Review Buffer is live keeps its pins, closed or not."
  (prrr-test-with-repo
    (let ((head (car (process-lines "git" "rev-parse" "refs/pullreqs/1"))))
      (prrr-sync-pin 2 head)
      (prrr-sync-pin 3 head)
      (with-temp-buffer
        (setq major-mode 'prrr-diff-mode
              prrr-diff--pullreq (forge-pullreq :id "forge-2" :number 2))
        (should (= 1 (prrr-sync-prune-pins nil))))
      (should (equal (list (format "2/%s" head)) (prrr-sync-test--pin-refs)))
      ;; Once the buffer is gone, so are the pins.
      (should (= 1 (prrr-sync-prune-pins nil)))
      (should-not (prrr-sync-test--pin-refs)))))

(ert-deftest prrr-sync-test-prune-pins-without-pins ()
  (prrr-test-with-repo
    (should (= 0 (prrr-sync-prune-pins '(1))))))

(ert-deftest prrr-sync-test-pull-prunes-pins-of-closed-pullreqs ()
  "A pull prunes against the PRs it just stored: the fixture queue has 1, 2 and 3."
  (prrr-db-with-test-db
    (prrr-sync-test--with-clean-status
      (prrr-test-with-repo
        (let ((head (car (process-lines "git" "rev-parse" "refs/pullreqs/1"))))
          (prrr-test-with-ghub-dispatch `((viewer . ,(prrr-test-fixture "teams"))
                                          (repository . ,(prrr-test-fixture "queue")))
            (cl-letf (((symbol-function 'forge-get-worktree)
                       (lambda (_) default-directory)))
              (prrr-sync-pin 3 head)
              (prrr-sync-pin 999 head)
              (prrr-sync-pull (prrr-sync-test--repo))
              (should (eq 'ok (plist-get (prrr-sync-status "example-repo-id") :state)))
              (should (equal (list (format "3/%s" head))
                             (prrr-sync-test--pin-refs))))))))))

(provide 'prrr-sync-test)
;;; prrr-sync-test.el ends here
