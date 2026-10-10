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
;; `forge-pullreq', so forge's commands work on it, with prrr's own
;; keymap `prrr-queue-section-map'.  `prrr-queue--rows' maps each row
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
  :doc "Keys on the Review Queue heading and its group headings.")

(defvar-keymap prrr-queue-section-map
  :doc "Keys on a Review Queue row (SPEC section 9)."
  :parent prrr-queue-heading-map)

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
             ((or 'auth 'not-found 'error) (plist-get status :message))))))
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
         (badge (propertize (string-pad (if state (symbol-name state) "") prrr-queue--badge-width)
                            'font-lock-face (and state (intern (format "prrr-queue-state-%s" state)))))
         (prefix (concat (propertize number 'font-lock-face 'forge-topic-slug-open)
                         "  " (make-string (* 2 depth) ?\s) badge "  "))
         (suffix (concat "  " (propertize (or (prrr-pr-author pr) "") 'font-lock-face 'magit-log-author)
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
          (oset row keymap 'prrr-queue-section-map)
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

(provide 'prrr-queue)
;;; prrr-queue.el ends here
