;;; prrr-transient.el --- Transient menus for prrr  -*- lexical-binding: t -*-

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

;; Every transient prefix (SPEC section 9).  Each menu mirrors the keys
;; of the buffer or section it belongs to, so a key works the same with
;; and without the menu.  `prrr-menu' is the Review Buffer's; later
;; milestones add its groups.

;;; Code:

(require 'transient)
(require 'magit-mode)
(require 'prrr)
(require 'prrr-queue)
(require 'prrr-stack)
(require 'prrr-diff)
(require 'prrr-sync)
(require 'prrr-review)

(defun prrr-transient--shown (what value)
  "Describe a toggle for WHAT that is on when VALUE is non-nil."
  (concat "show " what " "
          (propertize (if value "[on]" "[off]")
                      'face (if value 'transient-value 'transient-inactive-value))))

(transient-define-suffix prrr-queue-toggle-drafts ()
  "Show or hide draft pull requests in the Review Queue."
  :transient t
  :description (lambda () (prrr-transient--shown "drafts" prrr-queue-show-drafts))
  (interactive)
  (setq prrr-queue-show-drafts (not prrr-queue-show-drafts))
  (magit-refresh))

(transient-define-suffix prrr-queue-toggle-served ()
  "Show or hide the Served partition of the Review Queue."
  :transient t
  :description (lambda () (prrr-transient--shown "Served" prrr-queue-show-served))
  (interactive)
  (setq prrr-queue-show-served (not prrr-queue-show-served))
  (magit-refresh))

;;;###autoload (autoload 'prrr-queue-menu "prrr-transient" nil t)
(transient-define-prefix prrr-queue-menu ()
  "Act on the Review Queue (SPEC section 9)."
  ["Show"
   ("-d" prrr-queue-toggle-drafts)
   ("-s" prrr-queue-toggle-served)]
  [["Pull request"
    ("RET" "review" prrr-review)
    ("o" "open topic" prrr-open-topic)
    ("b" "browse on GitHub" prrr-browse)
    ("B" "checkout" prrr-checkout)]
   ["Stack"
    (">" "up" prrr-stack-up)
    ("<" "down" prrr-stack-down)]
   ["Sync"
    ("G" "pull" prrr-pull)]])

;;;###autoload (autoload 'prrr-submit "prrr-transient" nil t)
(transient-define-prefix prrr-submit ()
  "Submit your Pending Review with a Verdict, or discard it (SPEC section 9)."
  [["Submit"
    ("a" "approve" prrr-submit-approve)
    ("r" "request changes" prrr-submit-request-changes)
    ("c" "comment" prrr-submit-comment)]
   ["Pending Review"
    ("k" "discard" prrr-discard-pending)]])

;;;###autoload (autoload 'prrr-outbox "prrr-transient" nil t)
(transient-define-prefix prrr-outbox ()
  "Act on this pull request's unsent writes (SPEC section 9)."
  ["Outbox"
   ("r" "retry now" prrr-outbox-retry)
   ("k" "discard one" prrr-outbox-discard)])

;;;###autoload (autoload 'prrr-menu "prrr-transient" nil t)
(transient-define-prefix prrr-menu ()
  "Act on the Review Buffer (SPEC section 9).
Milestones 5 to 7 add the Range, Stack and Agent groups."
  [["Comment"
    ("-i" "publish immediately" "--immediate")
    ("c" "on line or region" prrr-comment)
    ("C" "on file" prrr-comment-file)
    ("r" "reply" prrr-reply)
    ("e" "edit" prrr-edit-comment)
    ("k" "delete" prrr-delete-comment)
    ("d" "discussion" prrr-discussion-comment)
    ("R" "resolve or unresolve" prrr-toggle-resolved)
    ("s" "suggest a change" prrr-comment-suggest)]
   ["Review"
    ("S" "submit or discard…" prrr-submit)
    ("O" "outbox…" prrr-outbox)]]
  [["Navigate"
    ("]" "next Thread" prrr-next-thread)
    ("[" "previous Thread" prrr-previous-thread)
    ("}" "next unresolved" prrr-next-unresolved)
    ("{" "previous unresolved" prrr-previous-unresolved)
    ("J" "next file" prrr-next-file)
    ("K" "previous file" prrr-previous-file)
    ("j" "jump to file" prrr-jump-to-file)]
   ["View"
    ("v" "toggle Viewed" prrr-toggle-viewed)
    ("z" "collapse all" prrr-collapse-all)
    ("Z" "expand all" prrr-expand-all)]
   ["Open"
    ("o" "topic" prrr-open-topic)
    ("b" "browse on GitHub" prrr-browse)
    ("B" "checkout" prrr-checkout)]
   ["Sync"
    ("g" "refresh" magit-refresh)
    ("G" "refetch" prrr-refetch)]])

(provide 'prrr-transient)
;;; prrr-transient.el ends here
