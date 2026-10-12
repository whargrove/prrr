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
;; Per-PR refetches of review data live here too, and so does the
;; Outbox, the one way prrr writes to GitHub (SPEC section 7): a
;; command hands `prrr-sync-write' a kind of write and its payload;
;; the Outbox stores it, shows it at once through
;; `prrr-sync-review-data', and sends the queued writes one at a time,
;; in order per PR, a second apart, retrying failures on the next
;; write, the next refetch or `prrr-sync-retry'.  A write whose send
;; got no answer is unconfirmed: it holds back its PR until a refetch
;; shows whether it reached GitHub.  Its rules are pure functions in
;; prrr-state.el.
;;
;; The Bookmark, the head the viewer last saw, is recorded here too,
;; and so is pinning: every commit a Range may start at later is kept
;; under refs/prrr/ so that neither a force-push nor git's garbage
;; collection takes it away.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'parse-time)
(require 'eieio)
(require 'magit-mode)
(require 'magit-git)
(require 'forge)
(require 'prrr-db)
(require 'prrr-github)
(require 'prrr-state)

(defcustom prrr-queue-stale-after 300
  "Seconds after which the Review Queue inputs are pulled again.
This also spaces retries after a failed pull."
  :type 'natnum
  :group 'prrr)

(defconst prrr-sync-min-retry-spacing 30
  "Fewest seconds between two pull attempts of one repository.
Keeps a `prrr-queue-stale-after' of 0 from retrying a failing pull on
every refresh.")

(defconst prrr-sync-min-timeout 10
  "The fewest seconds `prrr-sync-timeout' can make a request wait.
A smaller value would end every pull before GitHub could answer.")

(defcustom prrr-sync-timeout 60
  "Seconds a pull, refetch or change may wait for GitHub before it ends.
Some failures, such as a refused connection, never reach prrr; the
request then ends as offline this many seconds after it started, and
any answer that arrives later is ignored.  Raise it when the Review
Queue of a large repository over a slow connection keeps ending as
offline: the queue query pages through every open pull request.
Values below `prrr-sync-min-timeout' count as that minimum."
  :type '(restricted-sexp :tag "Seconds"
                          :match-alternatives
                          ((lambda (value)
                             (and (natnump value) (>= value prrr-sync-min-timeout)))))
  :group 'prrr)

(defun prrr-sync--timeout ()
  "Return `prrr-sync-timeout', raised to `prrr-sync-min-timeout' if lower."
  (max prrr-sync-timeout prrr-sync-min-timeout))

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

(defvar prrr-sync--teams-failure nil
  "Why the last Teams fetch this session failed, or nil after a success.
Pulls show it until a Teams fetch succeeds, since the stored Teams
stay stale that long.")

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
                        (time-subtract (or now (current-time)) (prrr-sync--timeout)))
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

(defconst prrr-sync--no-answer
  '(:kind offline :message "No answer from GitHub" :reset-at nil)
  "The failure of a job that got no answer within `prrr-sync-timeout'.")

(defun prrr-sync--start (key buffer &optional fail)
  "Record a job KEY as running and return its token.
The job ends as `offline' when it has no answer after
`prrr-sync-timeout' seconds; BUFFER is refreshed then.  FAIL, when
non-nil, is the job's own failure function: it receives that failure
instead and must end the job with `prrr-sync--finish'."
  (let ((token (cl-incf prrr-sync--last-token)))
    (puthash key (list :state 'pulling :attempted-at (prrr-sync--timestamp) :token token)
             prrr-sync--status)
    (if fail
        (run-at-time (prrr-sync--timeout) nil fail prrr-sync--no-answer)
      (run-at-time (prrr-sync--timeout) nil #'prrr-sync--finish key token prrr-sync--no-answer
                   buffer))
    token))

(defun prrr-sync--fetch-teams (host me then fail)
  "Fetch and store the viewer ME's Teams on HOST, then call THEN.
Call FAIL with the classified failure instead when the fetch or the
store fails.  THEN runs outside that guard, so exactly one of THEN and
FAIL runs; THEN must not signal.  Records the outcome in
`prrr-sync--teams-failure'.  A failure that retrying soon cannot fix,
such as a rejected token or a missing resource, is not tried again before
`prrr-sync-teams-max-age'; an `offline' or `rate-limited' one is
tried on the next pull."
  (let ((fail (lambda (failure)
                (setq prrr-sync--teams-failure (plist-get failure :message))
                (unless (memq (plist-get failure :kind) '(offline rate-limited))
                  (setq prrr-sync--teams-tried-at (prrr-sync--timestamp)))
                (funcall fail failure))))
    (prrr-github-fetch-teams
     host me
     (lambda (teams)
       (when (prrr-sync--guarded fail
               (prrr-db-replace-teams teams)
               (setq prrr-sync--teams-failure nil
                     prrr-sync--teams-tried-at (prrr-sync--timestamp))
               t)
         (funcall then)))
     fail)))

(defun prrr-sync--prune-pins-after-pull (repo metas)
  "Prune the pins of REPO's closed PRs, given METAS, its open ones.
The queue query pages every open PR, so a PR missing from METAS is
closed.  A failure only shows in the echo area: pins are housekeeping
and must not fail a pull whose rows are stored."
  (when-let* ((dir (forge-get-worktree repo))
              ((file-directory-p dir)))
    (condition-case err
        (let ((default-directory dir))
          (prrr-sync-prune-pins (mapcar #'prrr-pr-meta-number metas)))
      (error (message "prrr: could not prune pins of %s/%s: %s"
                      (oref repo owner) (oref repo name)
                      (error-message-string err))))))

(defun prrr-sync-pull (repo &optional buffer)
  "Pull the Review Queue inputs of REPO in the background.
REPO is a `forge-github-repository'.  Fetches the viewer's Teams first
when they are due, then the queue query, and stores both.  Teams only
refine the Review State, so a failed Teams fetch keeps the stored
Teams and the pull goes on (`prrr-sync--fetch-teams' says when it is
tried again).  Until a Teams fetch succeeds, the status is `ok' with
a :message that starts \"Teams unavailable\".  Records the
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
              (lambda (&rest _)
                (when (prrr-sync--current-p id token)
                  (prrr-sync--guarded fail
                    (prrr-github-fetch-queue
                     host (oref repo owner) (oref repo name)
                     (lambda (metas)
                       (when (prrr-sync--current-p id token)
                         (prrr-sync--guarded fail
                           (prrr-db-replace-pr-metas id metas)
                           (prrr-sync--prune-pins-after-pull repo metas)
                           (prrr-sync--finish
                            id token
                            (list :kind 'ok
                                  :message (and prrr-sync--teams-failure
                                                (format "Teams unavailable: %s"
                                                        prrr-sync--teams-failure)))
                            buffer))))
                     fail id))))))
        (prrr-sync--guarded fail
          (let ((me (prrr-github-viewer)))
            (cond ((null me)
                   (funcall fail (list :kind 'error :message prrr-sync-no-login :reset-at nil)))
                  ((prrr-sync--teams-due-p)
                   (prrr-sync--fetch-teams host me fetch-queue fetch-queue))
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

;;;; The Outbox

(defvar prrr-sync--mutation-spacing 1.0
  "Fewest seconds between one mutation's answer and the next mutation.
GitHub asks for at least a second (SPEC section 4).  Tests set it to 0.")

(defvar prrr-sync--outbox-sending nil
  "The `prrr-outbox' row being sent, or nil.  One write is sent at a time.")

(defvar prrr-sync--outbox-token 0
  "Identifies the latest send.  Counts up.")

(defvar prrr-sync--outbox-mutated-at 0.0
  "When the last mutation answered, as a float time.")

(defvar prrr-sync--outbox-creations nil
  "When each content creation of the last minute was sent, as float times.")

(defvar prrr-sync--outbox-paused-until nil
  "When the rate limit that pauses the Outbox ends, a timestamp, or nil.")

(defvar prrr-sync--outbox-scheduled nil
  "Non-nil while a timer is set to run `prrr-sync--outbox-pump'.")

(defvar prrr-sync--outbox-started nil
  "Non-nil once `prrr-sync-outbox-start' ran this session.")

(defconst prrr-sync-unconfirmed-message
  (concat "No answer from GitHub: check the pull request on GitHub, "
          "then retry (O r) or drop this write (O k)")
  "Failure of an unconfirmed write that a refetch cannot confirm.
Review data shows neither Discussion Comments nor a submitted review,
so the user checks the PR and decides whether to send it again.")

(defvar prrr-sync--outbox-buffers (make-hash-table :test #'equal)
  "Hash table from PR id to the buffer to refresh when its writes change.")

(defvar prrr-sync--outbox-dirty (make-hash-table :test #'equal)
  "Hash table from PR id to its target, for each PR GitHub may have changed.
A PR is here from a write's success, or from a send that got no
answer, until a refetch of it starts, so the Outbox refetches it once
it has nothing more to send.  A refetch that fails puts it back
\(`prrr-sync--refetch').")

(defun prrr-sync--outbox-mark-dirty (row)
  "Have the Outbox refetch the PR of the write ROW once it is idle."
  (puthash (prrr-outbox-pr-id row) (plist-get (prrr-outbox-payload row) :target)
           prrr-sync--outbox-dirty))

(defvar prrr-sync--renames (make-hash-table :test #'equal)
  "Hash table from each local id the Outbox saw renamed to GitHub's id.
A buffer drawn, or a command started, before the rename still names
the local id; `prrr-sync-write' translates it through this table.  It
lives for the session only: after a restart every buffer is drawn
from the database, where stored rows and queued writes already carry
GitHub's ids.")

(defun prrr-sync--learn-renames (renames)
  "Remember RENAMES, an alist from local id to GitHub's id."
  (pcase-dolist (`(,local . ,github) renames)
    (puthash local github prrr-sync--renames)))

(defun prrr-sync--renamed (payload)
  "Return PAYLOAD with its :thread-id and :comment-id as GitHub names them."
  (let ((renamed (copy-sequence payload)))
    (dolist (key '(:thread-id :comment-id) renamed)
      (when-let* ((github (gethash (plist-get payload key) prrr-sync--renames)))
        (setq renamed (plist-put renamed key github))))))

(defvar prrr-sync--id-counter 0
  "Last counter used by `prrr-sync--new-id'.")

(defun prrr-sync--new-id ()
  "Return a new id, unique and greater than every id returned before."
  (setq prrr-sync--id-counter (% (1+ prrr-sync--id-counter) 10000))
  (format "%s-%04d" (format-time-string "%Y%m%dT%H%M%S.%6N" nil t) prrr-sync--id-counter))

(defun prrr-sync--target (repo pullreq)
  "Return how the Outbox reaches PULLREQ of REPO on GitHub, as a plist.
Keys :host, :owner, :name, :number, :pr-id and :me, the viewer's
login.  Every write stores it, so the Outbox can send the write after a
restart without forge's objects."
  (list :host (oref repo apihost) :owner (oref repo owner) :name (oref repo name)
        :number (oref pullreq number) :pr-id (oref pullreq their-id)
        :me (prrr-github-viewer)))

(defun prrr-sync--remember-buffer (pr-id buffer)
  "Refresh BUFFER, when live, whenever the writes of PR-ID change."
  (when (and pr-id (buffer-live-p buffer))
    (puthash pr-id buffer prrr-sync--outbox-buffers)))

(defun prrr-sync--outbox-changed (pr-id)
  "Refresh the buffer remembered for PR-ID, or every one when PR-ID is nil."
  (if pr-id
      (prrr-sync--schedule-refresh (gethash pr-id prrr-sync--outbox-buffers))
    (maphash (lambda (_pr-id buffer) (prrr-sync--schedule-refresh buffer))
             prrr-sync--outbox-buffers)))

(defun prrr-sync--sending-id ()
  "Return the id of the write being sent, or nil."
  (and prrr-sync--outbox-sending (prrr-outbox-id prrr-sync--outbox-sending)))

(defun prrr-sync--local-id ()
  "Return a new local id."
  (concat prrr-state-local-prefix (prrr-sync--new-id)))

(defun prrr-sync--outbox-payload (kind payload target)
  "Return PAYLOAD of a write KIND completed with TARGET and its local ids.
A proposal gets the local ids of the kind it would become, its :as."
  (let ((kind (if (eq kind 'proposed) (plist-get payload :as) kind)))
    (append (list :target target)
            (and (memq kind '(thread publish)) (list :thread (prrr-sync--local-id)))
            (and (memq kind '(thread publish reply publish-reply discussion))
                 (list :comment (prrr-sync--local-id)))
            payload)))

(defun prrr-sync--outbox-add (pr-id kind payload)
  "Queue the write KIND with PAYLOAD for PR-ID and return its row."
  (prrr-db-insert (prrr-outbox-create :id (prrr-sync--new-id) :pr-id pr-id :kind kind
                                      :payload payload :created-at (prrr-sync--timestamp)
                                      :attempts 0 :last-error nil)))

(defun prrr-sync-write (repo pullreq kind payload &optional buffer)
  "Make the write KIND with PAYLOAD reach PULLREQ of REPO on GitHub.
KIND and PAYLOAD are as `prrr-state-outbox-kinds' describes, without
:target and the local ids, which this adds.  The write is stored in
the Outbox, so `prrr-sync-review-data' shows it at once, and is sent in
the background after the PR's earlier writes, one mutation at a time
\(SPEC section 4).  Every failed write of the PR is tried again too.
An edit or delete of a comment whose own write is queued and not yet
sent (neither being sent nor unconfirmed) changes or drops that write
instead, and a discard drops the queued writes of the Pending Review
first.  A :thread-id or :comment-id that is a local id GitHub has
since named is replaced by GitHub's id, so a command confirmed after
its target was sent still reaches it.  BUFFER, when live, refreshes
whenever the PR's writes change.  Return the `prrr-outbox' row that
carries the write, or nil when it dropped queued writes instead.
Signal a `user-error' when the viewer's login is unknown, or when the
write needs what an agent's proposal creates, such as a reply to a
proposed Thread (`prrr-state-outbox-needs-proposal-p')."
  (let* ((payload (prrr-sync--renamed payload))
         (target (prrr-sync--target repo pullreq))
         (pr-id (plist-get target :pr-id))
         (creator (and (memq kind '(edit delete))
                       (prrr-sync--outbox-creator pr-id (plist-get payload :comment-id)))))
    (unless (plist-get target :me)
      (user-error "No GitHub login: set github.user or `prrr-github-user'"))
    (unless creator
      (prrr-sync--refuse-if-needs-proposal
       (prrr-outbox-create :pr-id pr-id :kind kind :payload payload)))
    (prrr-sync--remember-buffer pr-id buffer)
    (prog1 (cond ((and creator (eq kind 'edit))
                  (setf (prrr-outbox-payload creator)
                        (plist-put (copy-sequence (prrr-outbox-payload creator))
                                   :body (plist-get payload :body)))
                  (prrr-db-insert creator))
                 (creator
                  (prrr-sync-discard (prrr-outbox-id creator))
                  nil)
                 (t
                  (when (eq kind 'discard)
                    (prrr-sync--outbox-drop-pending pr-id))
                  (prrr-sync--outbox-add pr-id kind
                                         (prrr-sync--outbox-payload kind payload target))))
      (prrr-sync-retry pr-id))))

(defun prrr-sync--refuse-if-needs-proposal (row)
  "Signal a `user-error' when the write ROW would wait on a proposal.
ROW is about to join its PR's queued writes."
  (when (prrr-state-outbox-needs-proposal-p row (prrr-db-outbox-rows (prrr-outbox-pr-id row)))
    (user-error "Accept the proposed Thread first")))

(defun prrr-sync--outbox-creator (pr-id comment-id)
  "Return the queued write of PR-ID creating COMMENT-ID, unless its send started.
A write being sent, or unconfirmed, may already have reached GitHub,
so an edit or delete of what it creates becomes a write of its own,
which waits for GitHub's id of the comment.  A write being sent is
unconfirmed too (`prrr-state-outbox-unconfirmed-p')."
  (seq-find (lambda (row)
              (and (member comment-id (prrr-state-outbox-created-ids row))
                   (not (prrr-state-outbox-unconfirmed-p row))))
            (prrr-db-outbox-rows pr-id)))

(defun prrr-sync--outbox-drop-pending (pr-id)
  "Drop PR-ID's queued writes that a discard of its Pending Review makes moot.
Those are new Threads and replies of the Pending Review, and every
queued write that needs one of them or a stored pending comment,
unless it is being sent.  An agent's proposals are not part of the
Pending Review and stay, unless they need what is dropped."
  (let* ((rows (prrr-db-outbox-rows pr-id))
         (pending (seq-filter (lambda (row) (memq (prrr-outbox-kind row) '(thread reply)))
                              rows))
         (ids (append (mapcar #'prrr-comment-comment-id
                              (prrr-db-select 'review-comment :pr-id pr-id :state 'pending))
                      (mapcan #'prrr-state-outbox-created-ids pending))))
    (dolist (row (append pending (prrr-state-outbox-dependents rows ids)))
      (unless (equal (prrr-outbox-id row) (prrr-sync--sending-id))
        (prrr-db-delete 'outbox :id (prrr-outbox-id row))))))

(defun prrr-sync--top-database-id (thread-id)
  "Return GitHub's database id of the first comment of THREAD-ID, or nil."
  (let ((comments (sort (prrr-db-select 'review-comment :thread-id thread-id)
                        (lambda (a b) (string< (or (prrr-comment-created-at a) "")
                                               (or (prrr-comment-created-at b) ""))))))
    (prrr-comment-database-id (car comments))))

(defun prrr-sync-retry (&optional pr-id buffer)
  "Send the failed writes of PR-ID again, or those of every PR when nil.
An unconfirmed write is not sent again: its PR is refetched instead,
and the refetch decides whether it landed.  One awaiting the user
\(`prrr-state-outbox-awaiting-user-p') goes out only through
`prrr-sync-resend'.  BUFFER, when live, refreshes whenever the PR's
writes change."
  (prrr-sync--remember-buffer pr-id buffer)
  (prrr-sync--outbox-recheck pr-id)
  (prrr-db-outbox-clear-errors pr-id #'prrr-state-outbox-awaiting-user-p)
  (prrr-sync--outbox-changed pr-id)
  (prrr-sync--outbox-pump))

(defun prrr-sync-resend (&optional pr-id buffer)
  "Send the failed writes of PR-ID again, as the user asked; every PR when nil.
That is `prrr-sync-retry', and also a write awaiting the user's
decision (`prrr-state-outbox-awaiting-user-p'): the user checked the
PR and wants it sent.  Writes and refetches retry through
`prrr-sync-retry' alone, so such a write never goes out twice without
the user.  BUFFER, when live, refreshes whenever the PR's writes
change."
  (dolist (row (prrr-db-outbox-rows pr-id))
    (when (prrr-state-outbox-awaiting-user-p row)
      (prrr-sync--outbox-answered row)))
  (prrr-sync-retry pr-id buffer))

(defun prrr-sync--outbox-recheck (&optional pr-id)
  "Have the Outbox refetch each PR with an unconfirmed write.
Only PR-ID, when non-nil.  The write being sent is left to its answer,
and one awaiting the user is skipped: a refetch cannot decide it."
  (dolist (row (prrr-db-outbox-rows pr-id))
    (when (and (prrr-state-outbox-unconfirmed-p row)
               (not (prrr-state-outbox-awaiting-user-p row))
               (not (equal (prrr-outbox-id row) (prrr-sync--sending-id))))
      (prrr-sync--outbox-mark-dirty row))))

(defun prrr-sync-outbox-start ()
  "Start the Outbox, once per session; later calls do nothing.
Writes queued before Emacs restarted then go out without waiting for a
Review Buffer's refetch: the PRs of unconfirmed writes, whose send the
restart cut off, are marked to be refetched first, and the pump runs
from a timer, never inside the caller.  It runs from
`prrr-db-open-hook', because opening the database is the one step
every entry point takes first: the Review Queue, a Review Buffer and
every command."
  (unless prrr-sync--outbox-started
    (setq prrr-sync--outbox-started t)
    (prrr-sync--outbox-recheck)
    (run-at-time 0 nil #'prrr-sync--outbox-pump)))

(add-hook 'prrr-db-open-hook #'prrr-sync-outbox-start)

(defun prrr-sync-discard (id)
  "Drop the queued write ID and every queued write that needs what it creates.
Return how many writes were dropped: 0 when ID is no longer queued,
as when it was sent meanwhile.  Signal a `user-error' while ID is
being sent.  An unconfirmed write may be dropped: it may have reached
GitHub all the same, so its PR is refetched to show what GitHub has."
  (if-let* ((row (prrr-db-get 'outbox id)))
      (progn
        (when (equal id (prrr-sync--sending-id))
          (user-error "That write is being sent; try again in a moment"))
        (let ((drop (cons row (prrr-state-outbox-dependents
                               (prrr-db-outbox-rows (prrr-outbox-pr-id row))
                               (prrr-state-outbox-created-ids row)))))
          (dolist (dropped drop)
            (prrr-db-delete 'outbox :id (prrr-outbox-id dropped)))
          (when (prrr-state-outbox-unconfirmed-p row)
            (prrr-sync--outbox-mark-dirty row))
          (prrr-sync--outbox-changed (prrr-outbox-pr-id row))
          (prrr-sync--outbox-pump)
          (length drop)))
    0))

(defun prrr-sync-accept (id body &optional buffer)
  "Accept the queued proposal ID with BODY as its text.
It becomes the Thread or reply it proposed, in its place in the
Outbox, and goes out like any write (`prrr-state-outbox-accepted').
BUFFER, when live, refreshes whenever the PR's writes change.  Signal
a `user-error' when ID is no longer a queued proposal, when it is a
reply to a Thread that is still a proposal, or when it is a Thread
written at another commit than the Pending Review's, whose lines
would land elsewhere (`prrr-state-review-commit-problem')."
  (let ((row (prrr-db-get 'outbox id)))
    (unless (and row (prrr-state-outbox-held-p row))
      (user-error "That proposal is no longer queued"))
    (let ((payload (prrr-outbox-payload row)))
      (when (eq (plist-get payload :as) 'thread)
        (when-let* ((problem (prrr-state-review-commit-problem
                              (prrr-state-review-commit
                               (prrr-sync-review-data (prrr-outbox-pr-id row)))
                              (plist-get payload :commit))))
          (user-error "%s" problem))))
    (let ((accepted (prrr-state-outbox-accepted row body)))
      (prrr-sync--refuse-if-needs-proposal accepted)
      (prrr-db-insert accepted))
    (prrr-sync-retry (prrr-outbox-pr-id row) buffer)))

(defun prrr-sync-review-data (pr-id)
  "Return the review data of PR-ID as the user should see it.
That is what GitHub sent at the last refetch with the PR's queued
writes applied: see `prrr-state-outbox-view' for the plist."
  (prrr-state-outbox-view (prrr-db-review-data pr-id) (prrr-db-outbox-rows pr-id)))

(defun prrr-sync-outbox-describe ()
  "Return a few words on why the Outbox is not sending, or nil."
  (when (prrr-sync--outbox-paused-p)
    (prrr-sync-describe (list :state 'rate-limited :reset-at prrr-sync--outbox-paused-until))))

(defun prrr-sync--outbox-paused-p ()
  "Non-nil while a rate limit pauses the Outbox."
  (and prrr-sync--outbox-paused-until
       (string< (prrr-sync--timestamp) prrr-sync--outbox-paused-until)))

(defun prrr-sync--outbox-schedule (seconds)
  "Run `prrr-sync--outbox-pump' in SECONDS."
  (setq prrr-sync--outbox-scheduled t)
  (run-at-time (max seconds 0) nil
               (lambda ()
                 (setq prrr-sync--outbox-scheduled nil)
                 (prrr-sync--outbox-pump))))

(defun prrr-sync--outbox-pump ()
  "Send the next write the Outbox may send, or arrange to try later.
Does nothing while a write is being sent or a timer will try later."
  (unless (or prrr-sync--outbox-sending prrr-sync--outbox-scheduled)
    (if (prrr-sync--outbox-paused-p)
        (prrr-sync--outbox-schedule
         (float-time (time-subtract (parse-iso8601-time-string prrr-sync--outbox-paused-until)
                                    nil)))
      (setq prrr-sync--outbox-paused-until nil)
      (let* ((rows (prrr-db-outbox-rows))
             (next (prrr-state-outbox-next rows prrr-sync--outbox-creations (float-time))))
        (prrr-sync--outbox-refetch-idle rows)
        (pcase next
          (`(,row . ,wait)
           (if (> wait 0)
               (prrr-sync--outbox-schedule wait)
             (prrr-sync--outbox-send row))))))))

(defun prrr-sync--outbox-current-p (token)
  "Non-nil when the send identified by TOKEN is still running."
  (and prrr-sync--outbox-sending (eql token prrr-sync--outbox-token)))

(defun prrr-sync--outbox-send (row)
  "Send the write ROW, as stored.
ROW is stored as unconfirmed, with its payload's :sent-at, before the
request starts, so a send that Emacs never sees end, by a timeout or a
restart, is not sent again blindly (`prrr-state-outbox-unconfirmed-p').
The send ends when GitHub answers, or after `prrr-sync-timeout'
seconds without an answer (`prrr-sync--outbox-timed-out')."
  (let* ((token (cl-incf prrr-sync--outbox-token))
         (done (lambda (&optional result) (prrr-sync--outbox-succeeded row token result)))
         (fail (lambda (failure) (prrr-sync--outbox-failed row token failure))))
    (setf (prrr-outbox-payload row) (plist-put (copy-sequence (prrr-outbox-payload row))
                                               :sent-at (prrr-sync--timestamp)))
    (prrr-db-insert row)
    (setq prrr-sync--outbox-sending row)
    (run-at-time (prrr-sync--timeout) nil #'prrr-sync--outbox-timed-out row token)
    (prrr-sync--guarded fail
      (prrr-sync--outbox-run row token done fail))))

(defun prrr-sync--outbox-timed-out (row token)
  "End the send of the write ROW, sent as TOKEN, that GitHub has not answered.
The sending slot is released: a mutation without an answer after
`prrr-sync-timeout' counts as ended, so other PRs' writes go on.  ROW
stays unconfirmed, holding back its PR, and the PR is refetched to
decide whether ROW landed.  Nothing happens when the send already
ended."
  (when (prrr-sync--outbox-current-p token)
    (setq prrr-sync--outbox-sending nil)
    (prrr-sync--outbox-mark-dirty row)
    (prrr-sync--outbox-changed (prrr-outbox-pr-id row))
    (prrr-sync--outbox-pump)))

(defun prrr-sync--note-creation ()
  "Count the sending write as a content creation, if its kind is one.
Called when its mutation starts, so a write the Outbox refuses before
it reaches GitHub does not use up the per-minute budget
\(`prrr-state-creations-per-minute')."
  (when (and prrr-sync--outbox-sending
             (memq (prrr-outbox-kind prrr-sync--outbox-sending) prrr-state-creation-kinds))
    (let ((now (float-time)))
      (setq prrr-sync--outbox-creations
            (cons now (seq-filter (lambda (time) (> time (- now 60)))
                                  prrr-sync--outbox-creations))))))

(defun prrr-sync--mutate (start then fail token &optional setup)
  "Run a mutation for the send TOKEN once `prrr-sync--mutation-spacing' allows.
START is called with a callback and an errorback.  THEN receives what
the callback receives, FAIL what the errorback receives.  Nothing
starts once the send TOKEN has ended, as when the watchdog ended it
while an earlier step waited for GitHub: its write stays unconfirmed
and a refetch decides it, so it never reaches GitHub twice.  Unless SETUP
is non-nil, the mutation is the sending write's own and counts as a
content creation when it starts (`prrr-sync--note-creation'); SETUP
marks one that only prepares for the write, such as creating the
Pending Review."
  (let* ((stamp (lambda () (setq prrr-sync--outbox-mutated-at (float-time))))
         (go (lambda ()
               (when (prrr-sync--outbox-current-p token)
                 (prrr-sync--guarded fail
                   (unless setup (prrr-sync--note-creation))
                   (funcall start
                            (lambda (&optional result) (funcall stamp) (funcall then result))
                            (lambda (failure) (funcall stamp) (funcall fail failure)))))))
         (wait (- (+ prrr-sync--outbox-mutated-at prrr-sync--mutation-spacing) (float-time))))
    (if (> wait 0)
        (run-at-time wait nil go)
      (funcall go))))

(defun prrr-sync--with-review (target commit create then fail token)
  "Call THEN with the viewer's Pending Review of TARGET's PR, for the send TOKEN.
THEN receives a `prrr-pending-review'.  The stored review is used when
there is one; otherwise GitHub is asked, and when it has none and
CREATE is non-nil, a review is created on COMMIT.  THEN receives nil
when there is none and CREATE is nil.  FAIL receives a classified
failure.  An answer that comes after the send TOKEN ended goes no
further, as `prrr-sync--mutate' explains."
  (let ((pr-id (plist-get target :pr-id))
        (host (plist-get target :host)))
    (if-let* ((stored (prrr-db-get 'pending-review pr-id)))
        (funcall then stored)
      (prrr-github-find-pending-review
       host (plist-get target :owner) (plist-get target :name) (plist-get target :number)
       (plist-get target :me)
       (lambda (found)
         (cond ((not (prrr-sync--outbox-current-p token)))
               (found
                (prrr-db-insert found)
                (funcall then found))
               ((not create) (funcall then nil))
               (t (prrr-sync--mutate
                   (lambda (callback errorback)
                     (prrr-github-create-pending-review host pr-id commit callback errorback))
                   (lambda (review)
                     (prrr-db-insert review)
                     (funcall then review))
                   fail token t))))
       fail))))

(defun prrr-sync--outbox-run (row token done fail)
  "Send the write ROW to GitHub, as the send TOKEN.
DONE receives GitHub's answer, a plist or nil; FAIL a classified failure.
A new Thread fails when the Pending Review it joins is on another
commit than the one its lines were numbered at
\(`prrr-state-outbox-commit-problem')."
  (let* ((payload (prrr-outbox-payload row))
         (target (plist-get payload :target))
         (host (plist-get target :host))
         (pr-id (plist-get target :pr-id))
         (commit (plist-get payload :commit))
         (body (plist-get payload :body)))
    (pcase (prrr-outbox-kind row)
      ('viewed
       (prrr-sync--mutate (lambda (callback errorback)
                            (prrr-github-set-viewed host pr-id (plist-get payload :path)
                                                    (plist-get payload :viewed)
                                                    callback errorback))
                          done fail token))
      ((and kind (or 'thread 'reply))
       (prrr-sync--with-review
        target commit t
        (lambda (review)
          (let ((review-id (prrr-pending-review-review-id review)))
            (if-let* ((problem (and (eq kind 'thread)
                                    (prrr-state-outbox-commit-problem
                                     (prrr-pending-review-commit-oid review) commit))))
                (funcall fail (list :kind 'error :message problem :reset-at nil))
              (prrr-sync--mutate
               (lambda (callback errorback)
                 (if (eq kind 'thread)
                     (prrr-github-add-thread host review-id (plist-get payload :anchor) body
                                             callback errorback)
                   (prrr-github-add-reply host review-id (plist-get payload :thread-id) body
                                          callback errorback)))
               (lambda (result) (funcall done (append (list :review-id review-id) result)))
               fail token))))
        fail token))
      ('publish
       (prrr-sync--mutate (lambda (callback errorback)
                            (prrr-github-publish-comment
                             host (plist-get target :owner) (plist-get target :name)
                             (plist-get target :number) commit (plist-get payload :anchor) body
                             callback errorback))
                          done fail token))
      ('publish-reply
       (if-let* ((top (prrr-sync--top-database-id (plist-get payload :thread-id))))
           (prrr-sync--mutate (lambda (callback errorback)
                                (prrr-github-publish-reply
                                 host (plist-get target :owner) (plist-get target :name)
                                 (plist-get target :number) top body callback errorback))
                              done fail token)
         (funcall fail '(:kind error :message "GitHub's id of this Thread is not known yet: press G"
                         :reset-at nil))))
      ('discussion
       (prrr-sync--mutate (lambda (callback errorback)
                            (prrr-github-add-discussion-comment host pr-id body callback errorback))
                          done fail token))
      ('edit
       (prrr-sync--mutate (lambda (callback errorback)
                            (prrr-github-edit-comment host (plist-get payload :comment-id) body
                                                      callback errorback))
                          done fail token))
      ('delete
       (prrr-sync--mutate (lambda (callback errorback)
                            (prrr-github-delete-comment host (plist-get payload :comment-id)
                                                        callback errorback))
                          done fail token))
      ('resolve
       (prrr-sync--mutate (lambda (callback errorback)
                            (prrr-github-set-resolved host (plist-get payload :thread-id)
                                                      (plist-get payload :resolved)
                                                      callback errorback))
                          done fail token))
      ('submit
       (prrr-sync--with-review
        target commit nil
        (lambda (review)
          (prrr-sync--mutate (lambda (callback errorback)
                               (prrr-github-submit-review
                                host (and review (prrr-pending-review-review-id review))
                                pr-id commit (plist-get payload :verdict) body
                                callback errorback))
                             done fail token))
        fail token))
      ('discard
       (prrr-sync--with-review
        target nil nil
        (lambda (review)
          (if review
              (prrr-sync--mutate (lambda (callback errorback)
                                   (prrr-github-discard-review
                                    host (prrr-pending-review-review-id review)
                                    callback errorback))
                                 done fail token)
            (funcall done)))
        fail token))
      (kind (funcall fail (list :kind 'error :message (format "Unknown write %s" kind)
                                :reset-at nil))))))

(defun prrr-sync--outbox-outcome (row result)
  "Return how the database changes once GitHub accepted the write ROW.
RESULT is GitHub's answer.  A plist of `prrr-db-outbox-done''s keys."
  (let* ((payload (prrr-outbox-payload row))
         (pr-id (prrr-outbox-pr-id row))
         (comment-id (plist-get payload :comment-id))
         (thread-id (plist-get payload :thread-id)))
    (pcase (prrr-outbox-kind row)
      ((or 'thread 'publish 'reply 'publish-reply)
       (pcase-let ((`(,rows . ,renames) (prrr-state-outbox-created row result)))
         (list :insert rows :renames renames)))
      ('viewed
       (list :insert (list (prrr-viewed-create :pr-id pr-id :path (plist-get payload :path)
                                               :state (if (plist-get payload :viewed)
                                                          'viewed
                                                        'unviewed)
                                               :fetched-at (prrr-sync--timestamp)))))
      ('edit
       (when-let* ((comment (prrr-db-get 'review-comment comment-id)))
         (setf (prrr-comment-body comment) (plist-get payload :body)
               (prrr-comment-updated-at comment) (prrr-sync--timestamp))
         (list :insert (list comment))))
      ('delete
       (let* ((comment (prrr-db-get 'review-comment comment-id))
              (thread (and comment (prrr-comment-thread-id comment))))
         (list :delete (append (list (list 'review-comment :comment-id comment-id))
                               (and thread
                                    (= 1 (length (prrr-db-select 'review-comment
                                                                 :thread-id thread)))
                                    (list (list 'thread :thread-id thread)))))))
      ('resolve
       (when-let* ((thread (prrr-db-get 'thread thread-id)))
         (setf (prrr-thread-resolved-p thread) (and (plist-get payload :resolved) t))
         (list :insert (list thread))))
      ('submit
       (list :delete (list (list 'pending-review :pr-id pr-id))
             :insert (append
                      (mapcar (lambda (comment)
                                (setf (prrr-comment-state comment) 'submitted)
                                comment)
                              (prrr-db-select 'review-comment :pr-id pr-id :state 'pending))
                      (when-let* ((meta (prrr-db-get 'pullreq-meta pr-id)))
                        (setf (prrr-pr-meta-viewer-latest-review meta)
                              (list (pcase (plist-get payload :verdict)
                                      ('approve "APPROVED")
                                      ('request-changes "CHANGES_REQUESTED")
                                      (_ "COMMENTED"))
                                    (prrr-sync--timestamp)
                                    (plist-get payload :commit)))
                        (list meta)))))
      ('discard
       (let ((pending (prrr-db-select 'review-comment :pr-id pr-id :state 'pending)))
         (list :delete (append
                        (list (list 'pending-review :pr-id pr-id))
                        (mapcar (lambda (comment)
                                  (list 'review-comment
                                        :comment-id (prrr-comment-comment-id comment)))
                                pending)
                        (mapcar (lambda (thread-id) (list 'thread :thread-id thread-id))
                                (prrr-sync--emptied-threads pending)))))))))

(defun prrr-sync--emptied-threads (pending)
  "Return the ids of the Threads whose stored comments are all pending.
PENDING is the pending comments being deleted."
  (let ((ids (delete-dups (delq nil (mapcar #'prrr-comment-thread-id pending)))))
    (seq-filter (lambda (thread-id)
                  (seq-every-p (lambda (comment) (eq 'pending (prrr-comment-state comment)))
                               (prrr-db-select 'review-comment :thread-id thread-id)))
                ids)))

(defun prrr-sync--outbox-carry-edit (sent stored result)
  "Queue an edit when the comment the write SENT made has an older body.
SENT is the write as it went out and STORED the same write as queued
when GitHub's late answer RESULT came: the user may have edited it in
place after a refetch judged it missing.  GitHub then has SENT's body,
so an edit of the comment RESULT names carries STORED's body there."
  (let ((body (plist-get (prrr-outbox-payload stored) :body)))
    (when (and (memq (prrr-outbox-kind stored) '(thread publish reply publish-reply))
               (plist-get result :comment-id)
               (not (equal body (plist-get (prrr-outbox-payload sent) :body))))
      (prrr-sync--outbox-add (prrr-outbox-pr-id stored) 'edit
                             (list :target (plist-get (prrr-outbox-payload stored) :target)
                                   :comment-id (plist-get result :comment-id)
                                   :body body)))))

(defvar prrr-comment-created-hook nil
  "Functions run with the `prrr-comment' starting a new Thread, once GitHub has it.
Runs for Threads added to the Pending Review and published at once,
whoever wrote them.")

(defvar prrr-reply-created-hook nil
  "Functions run with the `prrr-comment' of a reply, once GitHub has it.")

(defvar prrr-review-submitted-hook nil
  "Functions run once GitHub has a Submit of the Pending Review.
Each gets a plist (:pr-id :verdict :body :commit); :verdict is
`approve', `request-changes' or `comment'.")

(defun prrr-sync-run-hook (hook &rest args)
  "Run each function of HOOK with ARGS, whatever the others do.
A function that signals is named in a message instead, and the rest
still run: a hook must never stop the Outbox."
  (apply #'run-hook-wrapped hook
         (lambda (function &rest args)
           (condition-case err
               (apply function args)
             (error (message "prrr: %s function %s failed: %s"
                             hook function (error-message-string err))))
           ;; nil: go on to the next function.
           nil)
         args))

(defun prrr-sync--run-outbox-hooks (row outcome)
  "Run the hook for the write ROW that GitHub accepted.
OUTCOME is `prrr-sync--outbox-outcome' of ROW, whose rows hold the
comment a creating write made."
  (let ((payload (prrr-outbox-payload row)))
    (pcase (prrr-outbox-kind row)
      ((and (or 'thread 'publish 'reply 'publish-reply) kind)
       (when-let* ((comment (seq-find #'prrr-comment-p (plist-get outcome :insert))))
         (prrr-sync-run-hook (if (memq kind '(thread publish))
                                 'prrr-comment-created-hook
                               'prrr-reply-created-hook)
                             comment)))
      ('submit
       (prrr-sync-run-hook 'prrr-review-submitted-hook
                           (list :pr-id (prrr-outbox-pr-id row)
                                 :verdict (plist-get payload :verdict)
                                 :body (plist-get payload :body)
                                 :commit (plist-get payload :commit)))))))

(defun prrr-sync--outbox-record-success (row result)
  "Record that GitHub carried out the queued write ROW, as RESULT says.
RESULT is GitHub's answer to ROW's send or, for an unconfirmed write,
what a refetch found (`prrr-state-outbox-landed'): the same shape
either way.  ROW leaves the Outbox, what it made or changed is stored
\(`prrr-sync--outbox-outcome'), and the local ids it created are
renamed to GitHub's in the PR's queued writes and in
`prrr-sync--renames'.  A Discussion Comment shows until forge has
pulled it (`prrr-sync--outbox-record-post').  The caller refreshes
buffers and pumps."
  (let ((outcome (prrr-sync--outbox-outcome row result)))
    (apply #'prrr-db-outbox-done (prrr-outbox-id row) outcome)
    (prrr-sync--learn-renames (plist-get outcome :renames))
    (prrr-sync--run-outbox-hooks row outcome))
  (prrr-sync--outbox-record-post row result))

(defvar prrr-sync--posted (make-hash-table :test #'equal)
  "Hash table from PR id to the Discussion Comments the Outbox posted to it.
Each is a plist with :comment-id, :database-id, :body and :created-at,
oldest first.  Review data does not hold Discussion Comments, forge's
topic does, and only once forge pulls the PR; until then the Review
Buffer shows them from here (`prrr-sync-posted-discussion').  It lives
for the session only: after a restart forge's next pull shows them.")

(defun prrr-sync--outbox-record-post (row result)
  "Keep showing the Discussion Comment the write ROW posted, if it is one.
RESULT is GitHub's answer, which names the new comment.  The comment
is remembered in `prrr-sync--posted' and forge is asked to pull the
PR, where it shows once pulled."
  (when (eq (prrr-outbox-kind row) 'discussion)
    (let ((pr-id (prrr-outbox-pr-id row)))
      (puthash pr-id
               (append (gethash pr-id prrr-sync--posted)
                       (list (list :comment-id (plist-get result :comment-id)
                                   :database-id (plist-get result :database-id)
                                   :body (plist-get (prrr-outbox-payload row) :body)
                                   :created-at (plist-get result :created-at))))
               prrr-sync--posted)
      (prrr-sync--pull-topic pr-id))))

(defun prrr-sync-posted-discussion (pr-id posts)
  "Return the Discussion Comments posted to PR-ID that POSTS do not list yet.
POSTS are forge's posts of the PR (`forge-pullreq-post').  Each is a
plist with :comment-id, :database-id, :body and :created-at, oldest
first: what GitHub accepted from the Outbox this session and forge has
not pulled yet (`prrr-state-unpulled-posts')."
  (when-let* ((posted (gethash pr-id prrr-sync--posted)))
    (prrr-state-unpulled-posts posted (mapcar (lambda (post) (oref post number)) posts))))

(defun prrr-sync--outbox-record-renames (row result)
  "Learn GitHub's ids of what the write ROW created, as RESULT names them.
ROW was dropped from the Outbox before GitHub's answer RESULT came, so
nothing of it is stored: the refetch that follows shows what GitHub
made.  Its local ids are renamed all the same, in the PR's queued
writes and in `prrr-sync--renames', so a command that names one, from
a buffer drawn before the drop, still reaches what GitHub made."
  (when (memq (prrr-outbox-kind row) '(thread publish reply publish-reply))
    (let ((renames (cdr (prrr-state-outbox-created row result))))
      (prrr-db-outbox-rename (prrr-outbox-pr-id row) renames)
      (prrr-sync--learn-renames renames))))

(defun prrr-sync--outbox-succeeded (row token result)
  "Record that GitHub accepted the write ROW, sent as TOKEN, with RESULT.
A late answer, after the watchdog ended the send, is still recorded
when the write is queued and not being sent again: it did happen.  It
records the write as queued now, which the user may have edited since
a refetch judged it missing (`prrr-sync--outbox-carry-edit').
One for a write dropped meanwhile records only its renames
\(`prrr-sync--outbox-record-renames') and, for a Discussion Comment,
the comment it posted (`prrr-sync--outbox-record-post').  The PR is
refetched in any case, so it shows what GitHub has."
  (let* ((id (prrr-outbox-id row))
         (pr-id (prrr-outbox-pr-id row))
         (stored (prrr-db-get 'outbox id)))
    (when (prrr-sync--outbox-current-p token)
      (setq prrr-sync--outbox-sending nil))
    (cond ((equal id (prrr-sync--sending-id))) ; sent again: its own answer records it
          (stored (prrr-sync--outbox-record-success stored result)
                  (prrr-sync--outbox-carry-edit row stored result))
          (t (prrr-sync--outbox-record-renames row result)
             (prrr-sync--outbox-record-post row result)))
    ;; Even a write discarded meanwhile changed GitHub: refetch to show it.
    (prrr-sync--outbox-mark-dirty row)
    (prrr-sync--outbox-changed pr-id)
    (prrr-sync--outbox-pump)))

(defun prrr-sync--pull-topic (pr-id)
  "Ask forge to pull the PR of PR-ID, so a new Discussion Comment shows.
Only when the PR's Review Buffer is live, since forge needs it."
  (when-let* ((buffer (gethash pr-id prrr-sync--outbox-buffers)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when-let* ((topic (bound-and-true-p forge-buffer-topic)))
          (condition-case err
              (funcall-interactively #'forge-pull-topic topic)
            (error (message "prrr: forge could not pull the PR: %s"
                            (error-message-string err)))))))))

(defun prrr-sync--outbox-answered (row &optional error)
  "Store ROW, a queued write as read from the database, as answered.
It is no longer unconfirmed, so it may be sent again.  Return ROW.  ERROR, when
non-nil, is why it failed: ROW keeps it until a retry, and the failed
attempt is counted."
  (setf (prrr-outbox-payload row)
        (cl-loop for (key value) on (prrr-outbox-payload row) by #'cddr
                 unless (eq key :sent-at) append (list key value)))
  (when error
    (setf (prrr-outbox-attempts row) (1+ (or (prrr-outbox-attempts row) 0))
          (prrr-outbox-last-error row) error))
  (prrr-db-insert row)
  row)

(defun prrr-sync--outbox-failed (row token failure)
  "Record that the write ROW, sent as TOKEN, failed with FAILURE.
An `unconfirmed' failure is a success answer that does not name what
GitHub made (`prrr-github--created'): GitHub may have made it, so ROW
stays unconfirmed, as after a timeout (`prrr-sync--outbox-timed-out'),
and a refetch decides whether it landed; a retry never sends it again.
Any other failure is GitHub's answer (`prrr-sync--outbox-refused')."
  (if (eq (plist-get failure :kind) 'unconfirmed)
      (prrr-sync--outbox-timed-out row token)
    (prrr-sync--outbox-refused row token failure)))

(defun prrr-sync--outbox-refused (row token failure)
  "Record that GitHub answered the write ROW, sent as TOKEN, with FAILURE.
GitHub answered, so ROW is no longer unconfirmed.  A rate limit pauses
the Outbox until it ends and leaves ROW queued as it was; any other
failure stays on ROW, with the attempt counted, until a retry.  A late
answer, after the watchdog ended the send, is recorded the same way
while ROW is still unconfirmed from that very send, but leaves the
sending slot to the write being sent now."
  (let ((current (prrr-sync--outbox-current-p token)))
    (when current
      (setq prrr-sync--outbox-sending nil))
    (let* ((stored (prrr-db-get 'outbox (prrr-outbox-id row)))
           (sent-at (plist-get (prrr-outbox-payload row) :sent-at))
           (answered (and stored sent-at
                          (equal sent-at (plist-get (prrr-outbox-payload stored) :sent-at))
                          (not (equal (prrr-outbox-id row) (prrr-sync--sending-id)))))
           (rate-limited (eq (plist-get failure :kind) 'rate-limited)))
      (when answered
        (prrr-sync--outbox-answered stored (and (not rate-limited)
                                                (plist-get failure :message))))
      (when (and rate-limited (or current answered))
        (setq prrr-sync--outbox-paused-until (plist-get failure :reset-at)))
      (when (or current answered)
        (prrr-sync--outbox-changed (prrr-outbox-pr-id row))
        (prrr-sync--outbox-pump)))))

(defun prrr-sync--outbox-resolve (pr-id data taken)
  "Decide each unconfirmed write of PR-ID from DATA, its fresh review data.
TAKEN are the ids of the PR's comments stored before the refetch, as
`prrr-state-outbox-landed' takes them.  A write that landed is
recorded as a success; one that did not is no longer unconfirmed, so
it goes out again; one review data cannot show, a Discussion Comment
or a Submit, fails with `prrr-sync-unconfirmed-message' and stays
unconfirmed (`prrr-state-outbox-awaiting-user-p'), so the user checks
the PR and then sends it again (`prrr-sync-resend') or drops it.  A
comment that one write made is never taken for another's."
  (dolist (row (prrr-db-outbox-rows pr-id))
    (when (and (prrr-state-outbox-unconfirmed-p row)
               (not (equal (prrr-outbox-id row) (prrr-sync--sending-id))))
      (pcase (prrr-state-outbox-landed row data taken)
        (`(landed . ,result)
         (prrr-sync--outbox-record-success row result)
         (when-let* ((comment-id (plist-get result :comment-id)))
           (push comment-id taken)))
        ('missing (prrr-sync--outbox-answered row))
        ('unknown
         (setf (prrr-outbox-last-error row) prrr-sync-unconfirmed-message)
         (prrr-db-insert row))))))

(defun prrr-sync--refetch-retry-wait (pr-id &optional now)
  "Return how many seconds after NOW the Outbox may refetch PR-ID again.
0 unless the last refetch of PR-ID failed; then the retry starts no
sooner than `prrr-sync-min-retry-spacing' seconds after that attempt
did, and not before a rate limit resets, so a failing refetch is
retried at that pace and never on every pump.  NOW is a Lisp time,
the current time by default."
  (let* ((status (prrr-sync-review-status pr-id))
         (now (float-time now))
         (from-now (lambda (key)
                     (when-let* ((stamp (plist-get status key)))
                       (- (float-time (parse-iso8601-time-string stamp)) now)))))
    (if (memq (plist-get status :state) '(nil pulling ok))
        0
      (max 0
           (+ prrr-sync-min-retry-spacing (or (funcall from-now :attempted-at) 0))
           (or (funcall from-now :reset-at) 0)))))

(defvar prrr-sync--retry-pump-at nil
  "When the next pump `prrr-sync--schedule-retry-pump' set runs, or nil.
A float time.")

(defun prrr-sync--retry-pump ()
  "Pump the Outbox, as the timer `prrr-sync--schedule-retry-pump' set asks."
  (setq prrr-sync--retry-pump-at nil)
  (prrr-sync--outbox-pump))

(defun prrr-sync--schedule-retry-pump (seconds)
  "Pump the Outbox in SECONDS, when a refetch it waits for may start.
Unlike `prrr-sync--outbox-schedule', this holds back no send.  Nothing
new is set when a pump is already due by then, give or take the
second that a refetch's start time is rounded to, so pumps do not
stack."
  (let ((at (+ (float-time) seconds)))
    (unless (and prrr-sync--retry-pump-at (<= prrr-sync--retry-pump-at (1+ at)))
      (setq prrr-sync--retry-pump-at at)
      (run-at-time seconds nil #'prrr-sync--retry-pump))))

(defun prrr-sync--outbox-refetch-idle (rows)
  "Refetch each PR GitHub changed that has no write left to send now.
ROWS are every queued write.  A PR whose first write is unconfirmed
has none: only the refetch can let it go on.  A PR whose last refetch
failed waits for `prrr-sync--refetch-retry-wait', and the Outbox pumps
again when it is over (`prrr-sync--schedule-retry-pump'), so nothing
else need happen meanwhile.  The refetch starts from a timer, never
inside a write's answer."
  (let ((busy (prrr-state-outbox-busy-prs rows))
        (sending (and prrr-sync--outbox-sending (prrr-outbox-pr-id prrr-sync--outbox-sending))))
    (maphash (lambda (pr-id target)
               (unless (or (member pr-id busy) (equal pr-id sending))
                 (let ((wait (prrr-sync--refetch-retry-wait pr-id)))
                   (if (> wait 0)
                       (prrr-sync--schedule-retry-pump wait)
                     (run-at-time 0 nil #'prrr-sync--refetch target
                                  (gethash pr-id prrr-sync--outbox-buffers))))))
             prrr-sync--outbox-dirty)))

(defun prrr-sync-refetch (repo pullreq &optional buffer)
  "Refetch the review data of PULLREQ in the background.
The review data is its Threads, Pending Review and Viewed flags.
REPO is PULLREQ's `forge-github-repository'.  Stores the answer with
`prrr-db-replace-review-data', records the outcome in
`prrr-sync-review-status' and refreshes BUFFER, when live, once the
refetch ends either way.  A successful refetch retries the PR's failed
writes and decides its unconfirmed ones (`prrr-sync--store-review-data').
Return non-nil when a refetch started; return nil and do nothing when
`prrr-sync-refetch-due-p' says no.  Never signals: every failure
becomes the status."
  (prrr-sync--refetch (prrr-sync--target repo pullreq) buffer))

(defun prrr-sync--outbox-races-p (pr-id)
  "Non-nil when a write may have changed PR-ID on GitHub during a refetch.
That is when a write of PR-ID succeeded since the refetch started, or
one is being sent: the refetch's answer may then miss it."
  (or (gethash pr-id prrr-sync--outbox-dirty)
      (and prrr-sync--outbox-sending
           (equal pr-id (prrr-outbox-pr-id prrr-sync--outbox-sending)))))

(defun prrr-sync--store-review-data (pr-id data)
  "Store DATA, a refetch's answer, as the review data of PR-ID.
The PR's failed writes are retried, as after every refetch, except
those awaiting the user (`prrr-state-outbox-awaiting-user-p').  Then its
unconfirmed writes are decided from DATA (`prrr-sync--outbox-resolve'),
so one that a refetch cannot confirm stays failed for the user to
decide.  That happens before DATA replaces the stored rows, so what a
confirmed write stores is then replaced by GitHub's own rows, and the
comments stored before are known."
  (prrr-db-outbox-clear-errors pr-id #'prrr-state-outbox-awaiting-user-p)
  (prrr-sync--outbox-resolve pr-id data
                             (mapcar #'prrr-comment-comment-id
                                     (prrr-db-select 'review-comment :pr-id pr-id)))
  (let ((renames (prrr-state-thread-renames (prrr-db-select 'review-comment :pr-id pr-id)
                                            (plist-get data :comments))))
    (prrr-db-replace-review-data pr-id data renames)
    (prrr-sync--learn-renames renames)))

(defun prrr-sync--refetch (target buffer)
  "Refetch TARGET's PR and refresh BUFFER, as `prrr-sync-refetch' does.
TARGET is a plist from `prrr-sync--target'.  An answer that a write of
the PR may have raced is not stored: the PR stays changed, and the
Outbox refetches it once it has nothing more to send.  A refetch the
Outbox needed that fails, or gets no answer, leaves the PR changed
too, and the Outbox pumps again once it may retry
\(`prrr-sync--schedule-retry-pump'): a write waiting for an id only the
refetch brings goes out without the user's refetch."
  (let ((pr-id (plist-get target :pr-id)))
    (when (prrr-sync-refetch-due-p pr-id)
      (let* ((key (cons 'review pr-id))
             (needed (gethash pr-id prrr-sync--outbox-dirty))
             (token nil)
             (fail (lambda (failure)
                     (when (prrr-sync--current-p key token)
                       (when needed
                         (puthash pr-id target prrr-sync--outbox-dirty))
                       (prrr-sync--finish key token failure buffer)
                       (when (gethash pr-id prrr-sync--outbox-dirty)
                         (prrr-sync--schedule-retry-pump
                          (prrr-sync--refetch-retry-wait pr-id)))))))
        (setq token (prrr-sync--start key buffer fail))
        (remhash pr-id prrr-sync--outbox-dirty)
        (prrr-sync--guarded fail
          (let ((me (plist-get target :me)))
            (if (null me)
                (funcall fail (list :kind 'error :message prrr-sync-no-login :reset-at nil))
              (prrr-github-fetch-review-data
               (plist-get target :host) (plist-get target :owner) (plist-get target :name)
               (plist-get target :number) me
               (lambda (data)
                 (when (prrr-sync--current-p key token)
                   (prrr-sync--guarded fail
                     (let ((raced (prrr-sync--outbox-races-p pr-id)))
                       (if raced
                           (puthash pr-id target prrr-sync--outbox-dirty)
                         (prrr-sync--store-review-data pr-id data))
                       (prrr-sync--finish key token
                                          (list :kind 'ok :head-oid (plist-get data :head-oid))
                                          buffer)
                       (unless raced
                         (prrr-sync--remember-buffer pr-id buffer)
                         (prrr-sync--outbox-changed pr-id))
                       (prrr-sync--outbox-pump)))))
               fail))))
        t))))

;;;; Bookmark and pinned commits

(defun prrr-sync-pin (number oid)
  "Keep the commit OID of PR NUMBER from git's garbage collection.
It is pinned as the ref refs/prrr/NUMBER/OID in the repository of
`default-directory', which forge's fetches leave alone, so a commit
that a force-push left behind stays for the Ranges that start at it
\(SPEC section 8).  Return non-nil when pinned, nil when OID is not
in the repository."
  (and oid (magit-git-success "update-ref" (format "refs/prrr/%d/%s" number oid) oid)))

(defun prrr-sync-record-bookmark (pullreq oid)
  "Record OID as the head of PULLREQ the viewer last saw, and pin it.
The Bookmark (table `pr-bookmark') is where the since-opened Range
starts.  The Review Buffer records it when it closes, when opening it
again moves its head, on Submit and on `prrr-mark-seen', never on a
plain open.  Return non-nil when OID was pinned.  The Bookmark is
written even when the pin fails, which happens only when OID is not
in the repository: a since-opened Range fetches a missing start by
sha, so the Bookmark is still worth having, and there is nothing to
pin."
  (prrr-db-insert (prrr-bookmark-create :pr-id (oref pullreq their-id)
                                        :last-opened-head-oid oid
                                        :last-opened-at (prrr-sync--timestamp)))
  (prrr-sync-pin (oref pullreq number) oid))

(declare-function prrr-diff-live-numbers "prrr-diff" (toplevel))

(defun prrr-sync-prune-pins (open-numbers)
  "Delete the pins of every PR not in OPEN-NUMBERS; return how many went.
OPEN-NUMBERS are the numbers of the repository's open PRs.  Works in
the repository of `default-directory': one `git for-each-ref' lists
`refs/prrr/', one `git update-ref --stdin' deletes, in a transaction,
so a failure deletes none.  A PR that has a live Review Buffer keeps
its pins even when closed, because that buffer's Ranges may still start
at them.  Bookmarks (table `pr-bookmark') stay: a row is a few bytes,
and a PR that reopens then still has its since-opened start (the start
is fetched by sha when the pin is gone).  The git work takes a few
milliseconds (SPEC section 8), so it runs synchronously."
  (let* ((keep (append open-numbers
                       (prrr-diff-live-numbers (magit-toplevel))))
         (doomed (seq-remove
                  (lambda (ref)
                    (and (string-match "\\`refs/prrr/\\([0-9]+\\)/" ref)
                         (memq (string-to-number (match-string 1 ref)) keep)))
                  (magit-git-lines "for-each-ref" "--format=%(refname)" "refs/prrr/"))))
    (when doomed
      (with-temp-buffer
        (dolist (ref doomed)
          (insert "delete " ref "\n"))
        (unless (zerop (call-process-region (point-min) (point-max)
                                            (magit-git-executable) nil nil nil
                                            "update-ref" "--stdin"))
          (error "Pruning pins failed in %s" default-directory))))
    (length doomed)))

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
