;;; prrr-stack.el --- Moving up and down a Stack  -*- lexical-binding: t -*-

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

;; Stack navigation (SPEC section 8).  In the Review Queue `>' and `<'
;; move point to the next row of the same Stack.  The Review Buffer
;; opens the neighbouring PR instead; that arrives in milestone 5.

;;; Code:

(require 'prrr-queue)

(defun prrr-stack--move (direction)
  "Move to the PR next to the current one in its Stack, in DIRECTION."
  (unless (prrr-queue-move-in-stack direction)
    (user-error (if (eq direction 'up) "Top of the Stack" "Bottom of the Stack"))))

;;;###autoload
(defun prrr-stack-up ()
  "Move to the pull request above the current one in its Stack."
  (interactive)
  (prrr-stack--move 'up))

;;;###autoload
(defun prrr-stack-down ()
  "Move to the pull request below the current one in its Stack."
  (interactive)
  (prrr-stack--move 'down))

(provide 'prrr-stack)
;;; prrr-stack.el ends here
