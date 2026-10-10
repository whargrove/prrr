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
;; The Outbox retry and per-PR refetch arrive with the Review Buffer
;; (milestones 3 and 4).

;;; Code:

(require 'cl-lib)
(require 'seq)
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

(defconst prrr-sync-teams-max-age (* 24 60 60)
  "Seconds after which the viewer's Teams are fetched again (SPEC section 4).")

(defvar prrr-sync--status (make-hash-table :test #'equal)
  "Sync status of each repository this session, keyed by forge repository id.")

(defvar prrr-sync--teams-fetched-at nil
  "When the viewer's Teams were last fetched this session, or nil.
Remembers a fetch that found no Team, which leaves no row behind.")

(defun prrr-sync--timestamp (&optional time)
  "Return TIME (default now) as a GitHub-style UTC timestamp."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ" time t))

(defun prrr-sync-status (repo-id)
  "Return the sync status of the repository with forge id REPO-ID, or nil.
A plist: :state is `pulling', `ok' or a failure kind of
`prrr-github-error' (`rate-limited', `auth', `not-found', `offline',
`error'); :message describes a failure; :reset-at is when a rate
limit ends; :attempted-at is when the last pull started.  nil means
no pull was attempted this session."
  (gethash repo-id prrr-sync--status))

(defun prrr-sync-queue-due-p (repo-id metas &optional now)
  "Non-nil when the Review Queue inputs of REPO-ID should be pulled.
METAS are the repository's stored `prrr-pr-meta' rows and NOW a Lisp
time, the current time by default.  Due when there are no rows or the
newest is older than `prrr-queue-stale-after', unless a pull is
running, a rate limit has not reset, or the last attempt is more
recent than `prrr-queue-stale-after'.  The last rule makes a failing
pull retry at that pace instead of on every refresh."
  (let* ((now-stamp (prrr-sync--timestamp now))
         (threshold (prrr-sync--timestamp
                     (time-subtract (or now (current-time)) prrr-queue-stale-after)))
         (status (prrr-sync-status repo-id))
         (reset-at (plist-get status :reset-at))
         (attempted-at (plist-get status :attempted-at))
         (newest (car (sort (delq nil (mapcar #'prrr-pr-meta-fetched-at metas))
                            (lambda (a b) (string< b a))))))
    (and (not (eq (plist-get status :state) 'pulling))
         (not (and reset-at (string< now-stamp reset-at)))
         (not (and attempted-at (string< threshold attempted-at)))
         (or (null newest) (string< newest threshold)))))

(defun prrr-sync--teams-due-p ()
  "Non-nil when the viewer's Teams should be fetched before the queue.
Due when no fetch happened this session within `prrr-sync-teams-max-age'
and the stored rows are missing or older than that."
  (let ((threshold (prrr-sync--timestamp
                    (time-subtract (current-time) prrr-sync-teams-max-age))))
    (and (not (and prrr-sync--teams-fetched-at
                   (string< threshold prrr-sync--teams-fetched-at)))
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

(defun prrr-sync--finish (repo-id failure buffer)
  "Record the end of REPO-ID's pull and schedule BUFFER's refresh.
FAILURE is a `prrr-github-error' plist, or nil on success.  The refresh
runs from a timer, so an answer that arrives synchronously never
refreshes a buffer that is still being drawn."
  (puthash repo-id
           (list :state (if failure (plist-get failure :kind) 'ok)
                 :message (plist-get failure :message)
                 :reset-at (plist-get failure :reset-at)
                 :attempted-at (plist-get (prrr-sync-status repo-id) :attempted-at))
           prrr-sync--status)
  (when buffer
    (run-at-time 0 nil #'prrr-sync--refresh buffer)))

(defmacro prrr-sync--guarded (fail &rest body)
  "Run BODY; turn any error into a call of FAIL with an `error' failure."
  (declare (indent 1))
  `(condition-case err
       (progn ,@body)
     (error (funcall ,fail (list :kind 'error :message (error-message-string err)
                                 :reset-at nil)))))

(defun prrr-sync--fetch-teams (host me then fail)
  "Fetch and store the viewer ME's Teams on HOST, then call THEN.
Call FAIL with the classified failure instead when the fetch fails."
  (prrr-github-fetch-teams
   host me
   (lambda (teams)
     (prrr-sync--guarded fail
       (prrr-db-replace-teams teams)
       (setq prrr-sync--teams-fetched-at (prrr-sync--timestamp))
       (funcall then)))
   fail))

(defun prrr-sync-pull (repo &optional buffer)
  "Pull the Review Queue inputs of REPO in the background.
REPO is a `forge-github-repository'.  Fetches the viewer's Teams first
when they are due, then the queue query, and stores both.  Records the
outcome in `prrr-sync-status' and refreshes BUFFER, when live, after
the pull ends either way.  Does nothing while a pull of REPO runs.
Never signals: every failure becomes the status."
  (let ((id (oref repo id)))
    (unless (eq (plist-get (prrr-sync-status id) :state) 'pulling)
      (puthash id (list :state 'pulling :attempted-at (prrr-sync--timestamp))
               prrr-sync--status)
      (let* ((host (oref repo apihost))
             (fail (lambda (failure) (prrr-sync--finish id failure buffer)))
             (fetch-queue
              (lambda ()
                (prrr-github-fetch-queue
                 host (oref repo owner) (oref repo name)
                 (lambda (metas)
                   (prrr-sync--guarded fail
                     (prrr-db-replace-pr-metas id metas)
                     (prrr-sync--finish id nil buffer)))
                 fail id))))
        (prrr-sync--guarded fail
          (let ((me (prrr-github-viewer)))
            (cond ((null me)
                   (funcall fail (list :kind 'error
                                       :message "no GitHub login: set github.user or `prrr-github-user'"
                                       :reset-at nil)))
                  ((prrr-sync--teams-due-p)
                   (prrr-sync--fetch-teams host me fetch-queue fail))
                  (t (funcall fetch-queue)))))))))

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
own queue inputs.  The `magit-status' buffer refreshes when each ends."
  (interactive)
  (let ((repo (prrr-sync-current-repository)))
    (call-interactively #'forge-pull)
    (prrr-sync-pull repo (magit-get-mode-buffer 'magit-status-mode))
    (message "Pulling the Review Queue of %s/%s..." (oref repo owner) (oref repo name))))

;;;###autoload
(defun prrr-refresh-teams ()
  "Fetch the viewer's Teams again, even if they are fresh."
  (interactive)
  (let ((repo (prrr-sync-current-repository))
        (me (or (prrr-github-viewer)
                (user-error "No GitHub login: set github.user or `prrr-github-user'"))))
    (prrr-sync--fetch-teams
     (oref repo apihost) me
     (lambda () (message "Fetched %d Teams" (length (prrr-db-select 'team))))
     (lambda (failure) (message "Fetching Teams failed: %s" (plist-get failure :message))))))

(provide 'prrr-sync)
;;; prrr-sync.el ends here
