;;; prrr-sync.el --- Freshness rules for prrr  -*- lexical-binding: t -*-

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

;; When prrr pulls, and what happened the last time it did.  The
;; Review Queue renders only from the database; this file decides when
;; the database is stale, pulls in the background, stores the result
;; and records a per-repository sync status that the queue heading
;; shows (SPEC sections 5 and 11).  A pull never signals: every failure,
;; including a missing login or token, becomes the status.
;;
;; Per-PR refetches of review data live here too.  The Outbox retry
;; arrives in milestone 4.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'parse-time)
(require 'eieio)
(require 'magit-mode)
(require 'forge)
(require 'prrr-db)
(require 'prrr-github)

(defcustom prrr-queue-stale-after 300
  "Seconds after which the Review Queue inputs are pulled again.
This also spaces retries after a failed pull."
  :type 'natnum
  :group 'prrr)

(defconst prrr-sync-min-retry-spacing 30
  "Fewest seconds between two pull attempts of one repository.
Keeps a `prrr-queue-stale-after' of 0 from retrying a failing pull on
every refresh.")

(defcustom prrr-sync-timeout 60
  "Seconds a pull may wait for GitHub before it ends as offline.
Some failures, such as a refused connection, never reach prrr; the
pull then ends this many seconds after it started, and any answer
that arrives later is ignored."
  :type 'natnum
  :group 'prrr)

(defconst prrr-sync-teams-max-age (* 24 60 60)
  "Seconds after which the viewer's Teams are fetched again (SPEC section 4).")

(defvar prrr-sync--status (make-hash-table :test #'equal)
  "Sync status of each background job this session.
Keyed by forge repository id for Review Queue pulls and by the
cons (review . PR-ID) for per-PR refetches.")

(defvar prrr-sync--teams-tried-at nil
  "When the viewer's Teams were last fetched or tried this session, or nil.
Remembers a fetch that found no Team, which leaves no row behind, and
a fetch that failed, so neither is repeated before
`prrr-sync-teams-max-age'.")

(defvar prrr-sync--last-token 0
  "The token of the most recently started pull; tokens count up.")

(defconst prrr-sync-no-login
  "no GitHub login: set github.user or `prrr-github-user'"
  "Failure message when the viewer's login is unknown.")

(defun prrr-sync--timestamp (&optional time)
  "Return TIME (default now) as a GitHub-style UTC timestamp."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ" time t))

(defun prrr-sync-status (repo-id)
  "Return the sync status of the repository with forge id REPO-ID, or nil.
A plist: :state is `pulling', `ok' or a failure kind of
`prrr-github-error' (`rate-limited', `auth', `not-found', `offline',
`error'); :message describes a failure; :reset-at is when a rate
limit ends; :attempted-at is when the last pull started; :token
identifies that pull.  nil means no pull was attempted this session."
  (gethash repo-id prrr-sync--status))

(defun prrr-sync--running-p (status &optional now)
  "Non-nil when STATUS describes a pull that may still get an answer.
A `pulling' status started more than `prrr-sync-timeout' seconds
before NOW (default the current time) is not running: its watchdog
should have ended it, so it must never block a new pull."
  (and (eq (plist-get status :state) 'pulling)
       (let ((attempted-at (plist-get status :attempted-at)))
         (and attempted-at
              (string< (prrr-sync--timestamp
                        (time-subtract (or now (current-time)) prrr-sync-timeout))
                       attempted-at)))))

(defun prrr-sync-queue-due-p (repo-id metas &optional now)
  "Non-nil when the Review Queue inputs of REPO-ID should be pulled.
METAS are the repository's stored `prrr-pr-meta' rows and NOW a Lisp
time, the current time by default.  Due when there are no rows or the
newest is older than `prrr-queue-stale-after', unless a pull is
running (`prrr-sync--running-p'), a rate limit has not reset, or the
last attempt is more recent than `prrr-queue-stale-after' (at least
`prrr-sync-min-retry-spacing').  The last rule makes a failing pull
retry at that pace instead of on every refresh."
  (let* ((now (or now (current-time)))
         (now-stamp (prrr-sync--timestamp now))
         (threshold (prrr-sync--timestamp (time-subtract now prrr-queue-stale-after)))
         (retry-threshold (prrr-sync--timestamp
                           (time-subtract now (max prrr-sync-min-retry-spacing
                                                   prrr-queue-stale-after))))
         (status (prrr-sync-status repo-id))
         (reset-at (plist-get status :reset-at))
         (attempted-at (plist-get status :attempted-at))
         (newest (car (sort (delq nil (mapcar #'prrr-pr-meta-fetched-at metas))
                            (lambda (a b) (string< b a))))))
    (and (not (prrr-sync--running-p status now))
         (not (and reset-at (string< now-stamp reset-at)))
         (not (and attempted-at (string< retry-threshold attempted-at)))
         (or (null newest) (string< newest threshold)))))

(defun prrr-sync--teams-due-p (&optional now)
  "Non-nil when the viewer's Teams should be fetched before the queue.
Due when no fetch was tried this session within
`prrr-sync-teams-max-age' before NOW (a Lisp time, default the current
time) and the stored rows are missing or older than that."
  (let ((threshold (prrr-sync--timestamp
                    (time-subtract (or now (current-time)) prrr-sync-teams-max-age))))
    (and (not (and prrr-sync--teams-tried-at
                   (string< threshold prrr-sync--teams-tried-at)))
         (let ((teams (prrr-db-select 'team)))
           (or (null teams)
               (seq-some (lambda (team)
                           (string< (or (prrr-team-fetched-at team) "") threshold))
                         teams))))))

(defun prrr-sync--refresh (buffer)
  "Refresh BUFFER if it is still live."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (magit-refresh-buffer))))

(defun prrr-sync--schedule-refresh (buffer)
  "Refresh BUFFER, when non-nil, from a timer.
A timer, so an answer that arrives synchronously never refreshes a
buffer that is still being drawn."
  (when buffer
    (run-at-time 0 nil #'prrr-sync--refresh buffer)))

(defun prrr-sync--current-p (key token)
  "Non-nil when the job KEY identified by TOKEN has not ended."
  (let ((status (gethash key prrr-sync--status)))
    (and (eq (plist-get status :state) 'pulling)
         (eql (plist-get status :token) token))))

(defun prrr-sync--finish (key token outcome buffer)
  "End the job KEY identified by TOKEN and refresh BUFFER.
OUTCOME is a `prrr-github-error' plist, or (:kind ok) on success,
optionally with :head-oid.  An answer for a job that already ended, by
its watchdog or because a newer job replaced it, changes nothing."
  (when (prrr-sync--current-p key token)
    (puthash key
             (list :state (plist-get outcome :kind)
                   :message (plist-get outcome :message)
                   :reset-at (plist-get outcome :reset-at)
                   :head-oid (plist-get outcome :head-oid)
                   :attempted-at (plist-get (gethash key prrr-sync--status) :attempted-at)
                   :token token)
             prrr-sync--status)
    (prrr-sync--schedule-refresh buffer)))

(defmacro prrr-sync--guarded (fail &rest body)
  "Run BODY; turn any error into a call of FAIL with an `error' failure.
Return BODY's value, or nil after calling FAIL."
  (declare (indent 1))
  `(condition-case err
       (progn ,@body)
     (error (funcall ,fail (list :kind 'error :message (error-message-string err)
                                 :reset-at nil))
            nil)))

(defun prrr-sync--start (key buffer)
  "Record a job KEY as running and return its token.
The job ends as `offline' when it has no answer after
`prrr-sync-timeout' seconds; BUFFER is refreshed then."
  (let ((token (cl-incf prrr-sync--last-token)))
    (puthash key (list :state 'pulling :attempted-at (prrr-sync--timestamp) :token token)
             prrr-sync--status)
    (run-at-time prrr-sync-timeout nil #'prrr-sync--finish key token
                 '(:kind offline :message "No answer from GitHub" :reset-at nil)
                 buffer)
    token))

(defun prrr-sync--fetch-teams (host me then fail)
  "Fetch and store the viewer ME's Teams on HOST, then call THEN.
Call FAIL with the classified failure instead when the fetch or the
store fails.  THEN runs outside that guard, so exactly one of THEN and
FAIL runs; THEN must not signal."
  (prrr-github-fetch-teams
   host me
   (lambda (teams)
     (when (prrr-sync--guarded fail
             (prrr-db-replace-teams teams)
             (setq prrr-sync--teams-tried-at (prrr-sync--timestamp)))
       (funcall then)))
   fail))

(defun prrr-sync-pull (repo &optional buffer)
  "Pull the Review Queue inputs of REPO in the background.
REPO is a `forge-github-repository'.  Fetches the viewer's Teams first
when they are due, then the queue query, and stores both.  Teams only
refine the Review State, so a failed Teams fetch keeps the stored
Teams, is not tried again before `prrr-sync-teams-max-age', and the
pull goes on; the status is then `ok' with a :message that starts
\"Teams unavailable\".  Records the
outcome in `prrr-sync-status' and refreshes BUFFER, when live, after
the pull ends either way.  A pull without an answer ends as `offline'
after `prrr-sync-timeout' seconds.  Return non-nil when a pull
started; do nothing and return nil while a pull of REPO runs.
Never signals: every failure becomes the status."
  (let ((id (oref repo id)))
    (unless (prrr-sync--running-p (prrr-sync-status id))
      (let* ((token (prrr-sync--start id buffer))
             (host (oref repo apihost))
             (fail (lambda (failure) (prrr-sync--finish id token failure buffer)))
             (fetch-queue
              ;; NOTE, when non-nil, is the message of an `ok' outcome.
              (lambda (&optional note)
                (when (prrr-sync--current-p id token)
                  (prrr-sync--guarded fail
                    (prrr-github-fetch-queue
                     host (oref repo owner) (oref repo name)
                     (lambda (metas)
                       (when (prrr-sync--current-p id token)
                         (prrr-sync--guarded fail
                           (prrr-db-replace-pr-metas id metas)
                           (prrr-sync--finish id token (list :kind 'ok :message note)
                                              buffer))))
                     fail id)))))
             (teams-failed
              (lambda (failure)
                (setq prrr-sync--teams-tried-at (prrr-sync--timestamp))
                (funcall fetch-queue
                         (format "Teams unavailable: %s" (plist-get failure :message))))))
        (prrr-sync--guarded fail
          (let ((me (prrr-github-viewer)))
            (cond ((null me)
                   (funcall fail (list :kind 'error :message prrr-sync-no-login :reset-at nil)))
                  ((prrr-sync--teams-due-p)
                   (prrr-sync--fetch-teams host me fetch-queue teams-failed))
                  (t (funcall fetch-queue)))))
        t))))

;;;; Per-PR refetch

(defun prrr-sync-review-status (pr-id)
  "Return the status of the last refetch of the PR with node id PR-ID, or nil.
A plist like `prrr-sync-status'.  An `ok' status also has :head-oid,
the PR's head on GitHub when the refetch answered."
  (gethash (cons 'review pr-id) prrr-sync--status))

(defun prrr-sync-refetch-due-p (pr-id &optional now)
  "Non-nil when a refetch of PR-ID may start at NOW.
Not while one runs (`prrr-sync--running-p') nor before a rate limit
resets.  NOW is a Lisp time, the current time by default."
  (let ((status (prrr-sync-review-status pr-id)))
    (and (not (prrr-sync--running-p status now))
         (let ((reset-at (plist-get status :reset-at)))
           (not (and reset-at (string< (prrr-sync--timestamp now) reset-at)))))))

(defun prrr-sync-refetch (repo pullreq &optional buffer)
  "Refetch the review data of PULLREQ in the background.
The review data is its Threads, Pending Review and Viewed flags.
REPO is PULLREQ's `forge-github-repository'.  Stores the answer with
`prrr-db-replace-review-data', records the outcome in
`prrr-sync-review-status' and refreshes BUFFER, when live, once the
refetch ends either way.  Return non-nil when a refetch started; return
nil and do nothing when `prrr-sync-refetch-due-p' says no.  Never
signals: every failure becomes the status."
  (let ((pr-id (oref pullreq their-id)))
    (when (prrr-sync-refetch-due-p pr-id)
      (let* ((key (cons 'review pr-id))
             (token (prrr-sync--start key buffer))
             (fail (lambda (failure) (prrr-sync--finish key token failure buffer))))
        (prrr-sync--guarded fail
          (let ((me (prrr-github-viewer)))
            (if (null me)
                (funcall fail (list :kind 'error :message prrr-sync-no-login :reset-at nil))
              (prrr-github-fetch-review-data
               (oref repo apihost) (oref repo owner) (oref repo name) (oref pullreq number) me
               (lambda (data)
                 (when (prrr-sync--current-p key token)
                   (prrr-sync--guarded fail
                     (prrr-db-replace-review-data pr-id data)
                     (prrr-sync--finish key token
                                        (list :kind 'ok :head-oid (plist-get data :head-oid))
                                        buffer))))
               fail))))
        t))))

(defun prrr-sync-describe (status &optional busy)
  "Return a few words describing sync STATUS, or nil when all is well.
BUSY describes a job that is running; it defaults to \"pulling…\"."
  (pcase (plist-get status :state)
    ('pulling (or busy "pulling…"))
    ('offline "offline")
    ('rate-limited
     (format "rate limited until %s"
             (format-time-string "%H:%M" (parse-iso8601-time-string
                                          (plist-get status :reset-at)))))
    ((or 'ok 'auth 'not-found 'error) (plist-get status :message))))

;;;; Commands

(defun prrr-sync-current-repository ()
  "Return the current GitHub repository tracked by forge.
Signal a `user-error' when there is none."
  (let ((repo (forge-get-repository :tracked?)))
    (cond ((null repo)
           (user-error "Not in a repository tracked by forge; run `forge-add-repository' first"))
          ((not (cl-typep repo 'forge-github-repository))
           (user-error "Only GitHub repositories can be reviewed with prrr"))
          (t repo))))

;;;###autoload
(defun prrr-pull ()
  "Pull the current repository's pull requests and Review Queue inputs.
Runs `forge-pull', so new pull requests reach forge, and pulls prrr's
own queue inputs unless a pull of them is already running.  The
`magit-status' buffer refreshes when each ends."
  (interactive)
  (let ((repo (prrr-sync-current-repository)))
    (call-interactively #'forge-pull)
    (if (prrr-sync-pull repo (magit-get-mode-buffer 'magit-status-mode))
        (message "Pulling the Review Queue of %s/%s..." (oref repo owner) (oref repo name))
      (message "A pull of the Review Queue of %s/%s is already running"
               (oref repo owner) (oref repo name)))))

;;;###autoload
(defun prrr-refresh-teams ()
  "Fetch the viewer's Teams again, even if they are fresh.
The `magit-status' buffer refreshes once they are stored."
  (interactive)
  (let ((repo (prrr-sync-current-repository))
        (me (or (prrr-github-viewer)
                (user-error "No GitHub login: set github.user or `prrr-github-user'")))
        (buffer (magit-get-mode-buffer 'magit-status-mode)))
    (prrr-sync--fetch-teams
     (oref repo apihost) me
     (lambda ()
       (message "Fetched %d Teams" (length (prrr-db-select 'team)))
       (prrr-sync--schedule-refresh buffer))
     (lambda (failure) (message "Fetching Teams failed: %s" (plist-get failure :message))))))

(provide 'prrr-sync)
;;; prrr-sync.el ends here
