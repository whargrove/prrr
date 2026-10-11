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
;; and without the menu.  The Review Buffer's `prrr-menu' arrives in
;; milestone 3.

;;; Code:

(require 'transient)
(require 'magit-mode)
(require 'prrr)
(require 'prrr-queue)
(require 'prrr-stack)
(require 'prrr-sync)

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

(provide 'prrr-transient)
;;; prrr-transient.el ends here
