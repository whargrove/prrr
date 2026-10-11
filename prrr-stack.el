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
;; move point to the next row of the same Stack.  In a Review Buffer
;; they open the pull request above or below in the same window, at
;; its own default Range: each pull request diffs against its own
;; base.

;;; Code:

(require 'seq)
(require 'forge)
(require 'prrr-db)
(require 'prrr-state)
(require 'prrr-queue)
(require 'prrr-diff)

(defun prrr-stack--neighbour (pullreq direction)
  "Return forge's pull request next to PULLREQ in its Stack in DIRECTION, or nil.
DIRECTION is `up' or `down' (`prrr-state-stack-step').  The Stack is
made of the open pull requests prrr pulled, as in the Review Queue,
and PULLREQ."
  (let* ((repo (forge-get-repository pullreq))
         (id (oref pullreq their-id))
         (others (seq-remove (lambda (other) (equal (oref other their-id) id))
                             (prrr-queue-open-pullreqs
                              repo (prrr-db-select 'pullreq-meta :forge-repo-id (oref repo id)))))
         (pullreqs (cons pullreq others))
         (prs (mapcar #'prrr-queue-pr pullreqs))
         (next (prrr-state-stack-step (car prs) prs (oref repo default-branch) direction)))
    (and next (seq-find (lambda (other) (equal (oref other their-id) (prrr-pr-id next)))
                        pullreqs))))

(defun prrr-stack--display-here (buffer)
  "Show BUFFER in the selected window and return that window."
  (display-buffer buffer '(display-buffer-same-window)))

(defun prrr-stack--move (direction)
  "Move to the PR next to the current one in its Stack, in DIRECTION.
In a Review Buffer, open that PR's Review Buffer in the same window;
in the Review Queue, move point to its row.  Moving leaves the current
Review Buffer, so its Bookmark is recorded (`prrr-diff-record-bookmark')."
  (let ((none (if (eq direction 'up) "Top of the Stack" "Bottom of the Stack")))
    (if (derived-mode-p 'prrr-diff-mode)
        (let ((next (or (prrr-stack--neighbour (prrr-diff-pullreq) direction)
                        (user-error "%s" none)))
              (magit-display-buffer-function #'prrr-stack--display-here))
          (prrr-diff-record-bookmark)
          (prrr-diff-open next))
      (unless (prrr-queue-move-in-stack direction)
        (user-error "%s" none)))))

;;;###autoload
(defun prrr-stack-up ()
  "Move to the pull request above the current one in its Stack.
In a Review Buffer, its Review Buffer opens in the same window."
  (interactive)
  (prrr-stack--move 'up))

;;;###autoload
(defun prrr-stack-down ()
  "Move to the pull request below the current one in its Stack.
In a Review Buffer, its Review Buffer opens in the same window."
  (interactive)
  (prrr-stack--move 'down))

(provide 'prrr-stack)
;;; prrr-stack.el ends here
