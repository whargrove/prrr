;;; prrr-range.el --- Ranges of the Review Buffer  -*- lexical-binding: t -*-

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

;; Ranges (SPEC section 8): which two commits the Review Buffer
;; diffs.  The commands here choose one: the default Range, since my
;; last review, since I last opened the pull request, one commit, or
;; between two commits.  Switching keeps point on the same file and
;; line when the new Range shows that line, found again at the new
;; Range's commits through `git diff -U0' and `prrr-state-map-line'.
;; The rules are pure functions in prrr-state.el; prrr-diff.el draws.

;;; Code:

(require 'magit)
(require 'prrr-state)
(require 'prrr-diff)

;;;; Switching

(defun prrr-range--map-line (path line from to)
  "Return the number at commit TO of LINE of PATH at commit FROM, or nil.
nil when the commits in between remove or rewrite that line."
  (if (equal from to)
      line
    (prrr-state-map-line
     (prrr-state-parse-hunk-ranges
      (magit-git-output "diff" "--no-ext-diff" "--no-color" "-U0" from to "--" path))
     line)))

(defun prrr-range--restore (position)
  "Move to POSITION, from `prrr-diff-position', in the Range now shown.
The line is looked for on the right side, then on the left; failing
both, point goes to the file's heading.  When the file is not in the
diff, point stays where the redraw left it."
  (pcase-let ((`(,path ,_side ,line ,commit) position)
              (`(,start . ,end) (prrr-diff-ends)))
    (when (and start end)
      (or (and line
               (or (when-let* ((right (prrr-range--map-line path line commit end)))
                     (prrr-diff-goto-line path 'right right))
                   (when-let* ((left (prrr-range--map-line path line commit start)))
                     (prrr-diff-goto-line path 'left left))))
          (prrr-diff-goto-line path nil nil)))))

(defun prrr-range--switch (range)
  "Show RANGE, keeping point on the same file and line when it shows them."
  (let ((position (prrr-diff-position)))
    (prrr-diff-show-range range)
    (when position
      (prrr-range--restore position))))

;;;###autoload
(defun prrr-goto-default-range ()
  "Show the default Range, at the file and line point is on.
Lines that are read-only in another Range take comments there (SPEC
section 8)."
  (interactive)
  (prrr-diff-pullreq)
  (prrr-range--switch (prrr-range-create :kind 'default)))

(provide 'prrr-range)
;;; prrr-range.el ends here
