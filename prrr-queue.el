;;; prrr-queue.el --- The Review Queue section in magit-status  -*- lexical-binding: t -*-

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

;; The Review Queue (SPEC section 5): a section in magit-status listing
;; the open PRs that need the viewer, in two Queue Groups, For Me and
;; Mine, ordered and stacked by `prrr-state'.  It renders only from
;; the database and forge's objects; `prrr-sync' pulls in the
;; background when the inputs are stale.
;;
;; A row is a section of type `pullreq' whose value is forge's
;; `forge-pullreq', so forge's commands work on it.  Its keymap
;; `prrr-queue-row-map' puts prrr's keys (`prrr-queue-section-map') in
;; front of forge's.  `prrr-queue--rows' maps each row
;; section to its `prrr-queue-entry' for Stack navigation.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'parse-time)
(require 'magit)
(require 'forge)
(require 'prrr-db)
(require 'prrr-github)
(require 'prrr-state)
(require 'prrr-sync)
(require 'prrr)

;;;; Options

(defcustom prrr-queue-show-drafts t
  "Whether the Review Queue shows draft pull requests."
  :type 'boolean
  :group 'prrr)

(defcustom prrr-queue-show-served t
  "Whether the Review Queue shows the Served partition of For Me."
  :type 'boolean
  :group 'prrr)

;;;; Faces

(defface prrr-queue-state-new-commits '((t :inherit warning))
  "Review State badge: new commits since my review."
  :group 'prrr)
(defface prrr-queue-state-requested '((t :inherit font-lock-keyword-face :weight bold))
  "Review State badge: my review is requested."
  :group 'prrr)
(defface prrr-queue-state-team-requested '((t :inherit font-lock-function-name-face))
  "Review State badge: one of my Teams is requested."
  :group 'prrr)
(defface prrr-queue-state-teammate-reviewed '((t :inherit shadow))
  "Review State badge: a teammate reviewed in my place."
  :group 'prrr)
(defface prrr-queue-state-changes-requested '((t :inherit error))
  "Review State or Mine state badge: changes requested."
  :group 'prrr)
(defface prrr-queue-state-approved '((t :inherit success))
  "Review State or Mine state badge: approved."
  :group 'prrr)
(defface prrr-queue-state-commented '((t :inherit font-lock-doc-face))
  "Review State badge: I commented."
  :group 'prrr)
(defface prrr-queue-state-assigned '((t :inherit font-lock-type-face))
  "Review State badge: assigned to me."
  :group 'prrr)
(defface prrr-queue-state-awaiting-review '((t :inherit font-lock-keyword-face))
  "Mine state badge: no review yet."
  :group 'prrr)
(defface prrr-queue-state-reviewed '((t :inherit font-lock-doc-face))
  "Mine state badge: reviewed with comments only."
  :group 'prrr)
(defface prrr-queue-state-draft '((t :inherit shadow))
  "Mine state badge: draft."
  :group 'prrr)
(defface prrr-queue-dimmed '((t :inherit magit-dimmed))
  "A row shown only for context: a Stack member that does not qualify, or a draft."
  :group 'prrr)

;;;; Keymaps

(defvar-keymap prrr-queue-heading-map
  :doc "Keys on the Review Queue heading and its group headings."
  "G" #'prrr-pull
  "C-o" #'prrr-queue-menu)

(defvar-keymap prrr-queue-section-map
  :doc "Keys on a Review Queue row (SPEC section 9).
RET opens forge's topic buffer until the Review Buffer arrives."
  :parent prrr-queue-heading-map
  "RET" #'prrr-open-topic
  "o" #'prrr-open-topic
  "b" #'prrr-browse
  "B" #'prrr-checkout
  ">" #'prrr-stack-up
  "<" #'prrr-stack-down)

(defvar prrr-queue-row-map
  (make-composed-keymap (list prrr-queue-section-map) forge-pullreq-section-map)
  "The keymap of a Review Queue row.
`prrr-queue-section-map' first, then forge's `forge-pullreq-section-map',
so forge's own pull request keys keep working on rows.")

;;;; Formatting

(defconst prrr-queue--badge-width
  (apply #'max (mapcar (lambda (state) (length (symbol-name state)))
                       (append prrr-state-for-me-order prrr-state-mine-order)))
  "Width of the state badge column.")

(defun prrr-queue--ago (timestamp now)
  "Return how long before NOW TIMESTAMP was, such as \"5m\" or \"2d\".
The units are \"now\", minutes, hours, days, months (\"mo\", 30 days)
and years.  Both are ISO 8601 strings.  Return \"\" when TIMESTAMP is nil; a
TIMESTAMP after NOW is \"now\"."
  (if (not (and timestamp now))
      ""
    (let ((seconds (max 0 (float-time (time-subtract (parse-iso8601-time-string now)
                                                     (parse-iso8601-time-string timestamp))))))
      (cond ((< seconds 60) "now")
            ((< seconds 3600) (format "%dm" (/ seconds 60)))
            ((< seconds 86400) (format "%dh" (/ seconds 3600)))
            ((< seconds (* 30 86400)) (format "%dd" (/ seconds 86400)))
            ((< seconds (* 365 86400)) (format "%dmo" (/ seconds (* 30 86400))))
            (t (format "%dy" (/ seconds (* 365 86400))))))))

(defun prrr-queue--status-text (status me)
  "Return the heading suffix for sync STATUS and viewer ME.
STATUS is a `prrr-sync-status' plist or nil.  The empty string when
there is nothing to say."
  (let ((text
         (if (null me)
             "no GitHub login: set github.user or `prrr-github-user'"
           (pcase (plist-get status :state)
             ('pulling "pulling…")
             ('offline "offline")
             ('rate-limited
              (format "rate limited until %s"
                      (format-time-string "%H:%M" (parse-iso8601-time-string
                                                   (plist-get status :reset-at)))))
             ((or 'ok 'auth 'not-found 'error) (plist-get status :message))))))
    (if text
        (propertize (format " (%s)" text) 'font-lock-face 'magit-dimmed)
      "")))

(defun prrr-queue--line (entry number-width depth unresolved now width)
  "Return the text of ENTRY's row, without a newline.
NUMBER-WIDTH is the width of the PR number column, DEPTH the row's
depth among the visible rows of its Stack, UNRESOLVED its count of
unresolved Threads, NOW the current ISO timestamp and WIDTH the
columns to fit.  The title is truncated so the row fits WIDTH whenever
WIDTH leaves it at least ten columns.  The Stack marker shows the
row's true position, which may skip hidden rows (prrr-knu.5)."
  (let* ((pr (prrr-queue-entry-pr entry))
         (state (prrr-queue-entry-state entry))
         (dimmed (prrr-queue-entry-dimmed-p entry))
         (size (prrr-queue-entry-stack-size entry))
         (ago (prrr-queue--ago (prrr-pr-updated-at pr) now))
         (number (string-pad (format "#%d" (prrr-pr-number pr)) number-width))
         (badge (propertize (string-pad (if state (symbol-name state) "")
                                        prrr-queue--badge-width)
                            'font-lock-face
                            (and state (intern (format "prrr-queue-state-%s" state)))))
         (prefix (concat (propertize number 'font-lock-face 'forge-topic-slug-open)
                         "  " (make-string (* 2 depth) ?\s) badge "  "))
         (suffix (concat "  " (propertize (or (prrr-pr-author pr) "")
                                          'font-lock-face 'magit-log-author)
                         (and size (> size 1)
                              (format "  ⟰ %d/%d" (prrr-queue-entry-stack-pos entry) size))
                         (and (> unresolved 0) (format "  %d unresolved" unresolved))
                         (and (not (string-empty-p ago))
                              (concat "  " (propertize ago 'font-lock-face 'magit-log-date)))))
         (title-width (max 10 (- width (string-width prefix) (string-width suffix))))
         (title (truncate-string-to-width (or (prrr-pr-title pr) "") title-width nil nil "…"))
         (line (concat prefix title suffix)))
    (if dimmed
        (propertize line 'font-lock-face 'prrr-queue-dimmed)
      line)))

;;;; Insertion

(defvar-local prrr-queue--rows nil
  "The Review Queue rows of this buffer as (SECTION . ENTRY), in display order.")

(defun prrr-queue--count (entries)
  "Return how many ENTRIES qualify (have a state)."
  (seq-count #'prrr-queue-entry-state entries))

(defun prrr-queue--insert-rows (entries pullreqs inputs number-width)
  "Insert one row section per entry of ENTRIES.
PULLREQS maps PR ids to forge objects; INPUTS and NUMBER-WIDTH are as
in `prrr-queue-insert'."
  (let ((stack-id nil) (depth 0)
        (unresolved (plist-get inputs :unresolved)))
    (dolist (entry entries)
      (if (equal (prrr-queue-entry-stack-id entry) stack-id)
          (cl-incf depth)
        (setq stack-id (prrr-queue-entry-stack-id entry)
              depth 0))
      (let* ((id (prrr-pr-id (prrr-queue-entry-pr entry)))
             (pullreq (gethash id pullreqs)))
        (magit-insert-section row (pullreq pullreq)
          (oset row keymap 'prrr-queue-row-map)
          (insert (prrr-queue--line entry number-width depth
                                    (or (and unresolved (gethash id unresolved)) 0)
                                    (plist-get inputs :now) (plist-get inputs :width))
                  "\n")
          (push (cons row entry) prrr-queue--rows))))))

(defun prrr-queue-insert (inputs)
  "Insert the Review Queue section described by INPUTS at point.
INPUTS is a plist: :pairs, a list of (FORGE-PULLREQ . PRRR-PR) for the
repository's open PRs; :metas, their `prrr-pr-meta' rows; :teams, the
viewer's Team slugs; :me, the viewer's login or nil; :default-branch;
:unresolved, a hash table from PR id to unresolved Thread count, or
nil; :status, a `prrr-sync-status' plist or nil; :now, an ISO
timestamp; :width, the columns rows should fit.  Without a login only
the heading is inserted.  The groups are collapsed when both are
empty.  Sets `prrr-queue--rows'."
  (let* ((me (plist-get inputs :me))
         (pairs (plist-get inputs :pairs))
         (pullreqs (make-hash-table :test #'equal))
         (queue (and me (prrr-state-queue (mapcar #'cdr pairs) (plist-get inputs :metas)
                                          me (plist-get inputs :teams)
                                          (plist-get inputs :default-branch))))
         (groups (mapcar (lambda (group)
                           (list (car group) (cdr group)
                                 (prrr-state-filter-queue
                                  (plist-get queue (if (eq (car group) 'for-me) :for-me :mine))
                                  :show-drafts prrr-queue-show-drafts
                                  :show-served prrr-queue-show-served)))
                         '((for-me . "For me") (mine . "Mine"))))
         (empty (seq-every-p (lambda (group) (null (nth 2 group))) groups))
         (number-width (apply #'max 2 (mapcar (lambda (pair)
                                                (length (format "#%d" (prrr-pr-number (cdr pair)))))
                                              pairs))))
    (dolist (pair pairs)
      (puthash (prrr-pr-id (cdr pair)) (car pair) pullreqs))
    (setq prrr-queue--rows nil)
    (magit-insert-section root (prrr-queue)
      (oset root keymap 'prrr-queue-heading-map)
      (magit-insert-heading
        (propertize "Review Queue" 'font-lock-face 'magit-section-heading)
        (prrr-queue--status-text (plist-get inputs :status) me))
      (when me
        (pcase-dolist (`(,group ,title ,entries) groups)
          (magit-insert-section section (prrr-queue-group group empty)
            (oset section keymap 'prrr-queue-heading-map)
            (magit-insert-heading
              (propertize (format "%s (%d)" title (prrr-queue--count entries))
                          'font-lock-face 'magit-section-secondary-heading))
            (prrr-queue--insert-rows entries pullreqs inputs number-width))))
      (insert "\n"))
    (setq prrr-queue--rows (nreverse prrr-queue--rows))))

;;;; From forge

(defun prrr-queue--assignees (pullreq)
  "Return the logins assigned to forge's PULLREQ."
  (mapcar #'cadr (oref pullreq assignees)))

(defun prrr-queue-pr (pullreq)
  "Return the `prrr-pr' the Review Queue rules see for forge's PULLREQ.
HEAD-OID is forge's head-rev; the Review State prefers the head stored
with the PR's meta row (`prrr-state--head-oid'), so forge's matters only
for a PR prrr has not pulled yet."
  (prrr-pr-create :id (oref pullreq their-id)
                  :number (oref pullreq number)
                  :title (oref pullreq title)
                  :author (oref pullreq author)
                  :draft-p (and (oref pullreq draft-p) t)
                  :assignees (prrr-queue--assignees pullreq)
                  :created-at (oref pullreq created)
                  :updated-at (oref pullreq updated)
                  :head-oid (oref pullreq head-rev)
                  :base-ref (oref pullreq base-ref)
                  :head-ref (oref pullreq head-ref)
                  :cross-repo-p (and (oref pullreq cross-repo-p) t)))

(defun prrr-queue--open-pullreqs (repo metas)
  "Return forge's open pull requests of REPO that have a row in METAS.
METAS are REPO's `prrr-pr-meta' rows; each is looked up in forge by
number.  A row whose PR forge does not know or no longer has open is
dropped.  A forge PR without a row waits for the next prrr pull: this
keeps the cost bounded by the open PRs instead of the repository's
whole history, which `(oref repo pullreqs)' would load."
  (seq-filter (lambda (pullreq) (and pullreq (eq (oref pullreq state) 'open)))
              (mapcar (lambda (meta) (forge-get-pullreq repo (prrr-pr-meta-number meta)))
                      (seq-filter (lambda (meta) (numberp (prrr-pr-meta-number meta)))
                                  metas))))

(defun prrr-queue--width ()
  "Return the columns rows should fit: the buffer's window, else 80."
  (if-let ((window (get-buffer-window (current-buffer))))
      (window-body-width window)
    80))

(defun prrr-queue--inputs (repo)
  "Gather the `prrr-queue-insert' INPUTS of REPO from forge and the database."
  (let* ((id (oref repo id))
         (metas (prrr-db-select 'pullreq-meta :forge-repo-id id))
         (pairs (mapcar (lambda (pullreq) (cons pullreq (prrr-queue-pr pullreq)))
                        (prrr-queue--open-pullreqs repo metas))))
    (list :pairs pairs
          :metas metas
          :teams (mapcar #'prrr-team-combined-slug (prrr-db-select 'team))
          :me (prrr-github-viewer)
          :default-branch (oref repo default-branch)
          :unresolved (prrr-db-unresolved-thread-counts
                       (mapcar (lambda (pair) (prrr-pr-id (cdr pair))) pairs))
          :status (prrr-sync-status id)
          :now (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t)
          :width (prrr-queue--width))))

;;;; The magit-status section

(defun prrr-queue--announce-preserved-outbox ()
  "Warn once about Outbox rows kept across a database schema reset."
  (when-let ((rows (prrr-db-take-preserved-outbox)))
    (display-warning
     'prrr
     (format (concat "prrr's database was reset for a new layout; "
                     "%d unsent write(s) are kept in the Outbox: %s")
             (length rows)
             (mapconcat (lambda (row)
                          (format "%s on %s" (prrr-outbox-kind row) (prrr-outbox-pr-id row)))
                        rows ", "))
     :warning)))

(defun prrr-queue--insert-error (err)
  "Insert a Review Queue heading that reports ERR."
  (magit-insert-section (prrr-queue)
    (magit-insert-heading
      (propertize "Review Queue" 'font-lock-face 'magit-section-heading)
      (propertize (format " (error: %s)" (error-message-string err)) 'font-lock-face 'error))
    (insert "\n")))

(defun prrr-queue-insert-section ()
  "Insert the Review Queue into a `magit-status' buffer.
A `magit-status-sections-hook' function.  Inserts nothing outside a
GitHub repository tracked by forge.  Starts a background pull when the
stored inputs are stale (`prrr-sync-queue-due-p').  Any error becomes a
one-line section, so the rest of the status buffer still renders; text
inserted before the error is removed first."
  (when-let* ((_ (forge-db t))
              (repo (forge-get-repository :tracked?))
              (_ (cl-typep repo 'forge-github-repository)))
    (let ((start (point)))
      (condition-case err
          (let ((inputs (prrr-queue--inputs repo))
                (id (oref repo id)))
            (prrr-queue--announce-preserved-outbox)
            (when (prrr-sync-queue-due-p id (plist-get inputs :metas))
              (prrr-sync-pull repo (current-buffer)))
            (prrr-queue-insert (plist-put inputs :status (prrr-sync-status id))))
        (error
         (message "Review Queue failed: %s" (error-message-string err))
         (delete-region start (point))
         (setq prrr-queue--rows nil)
         (prrr-queue--insert-error err))))))

;;;###autoload
(define-minor-mode prrr-queue-mode
  "Show the Review Queue in the `magit-status' buffer of GitHub repositories.
The section goes right before forge's list of pull requests."
  :global t
  :group 'prrr
  (if prrr-queue-mode
      (magit-add-section-hook 'magit-status-sections-hook #'prrr-queue-insert-section
                              #'forge-insert-pullreqs)
    (remove-hook 'magit-status-sections-hook #'prrr-queue-insert-section)))

;;;###autoload
(defun prrr-queue ()
  "Show the Review Queue of the current repository.
Turns on `prrr-queue-mode' when it is off, opens the repository's
`magit-status' buffer and moves point to the Review Queue."
  (interactive)
  (unless prrr-queue-mode
    (prrr-queue-mode 1))
  (magit-status-setup-buffer)
  (if-let ((section (magit-get-section '((prrr-queue) (status)))))
      (magit-section-goto section)
    (user-error "No Review Queue here: prrr needs a GitHub repository tracked by forge")))

;;;; Rows

(defun prrr-queue-entry-at-point ()
  "Return the `prrr-queue-entry' of the Review Queue row at point, or nil."
  (cdr (assq (magit-current-section) prrr-queue--rows)))

(defun prrr-queue-move-in-stack (direction)
  "Move point to the next row of the current row's Stack in DIRECTION.
DIRECTION is `up' or `down'.  Only the displayed rows of the current
Queue Group are considered.  Return non-nil when point moved; signal a
`user-error' when point is not on a Review Queue row."
  (let* ((entry (or (prrr-queue-entry-at-point)
                    (user-error "Not on a Review Queue row")))
         (group (prrr-queue-entry-group entry))
         (target (prrr-state-stack-neighbour
                  (mapcar #'cdr (seq-filter (lambda (row)
                                              (eq (prrr-queue-entry-group (cdr row)) group))
                                            prrr-queue--rows))
                  entry direction)))
    (when target
      (magit-section-goto (car (rassq target prrr-queue--rows)))
      t)))

(provide 'prrr-queue)
;;; prrr-queue.el ends here
