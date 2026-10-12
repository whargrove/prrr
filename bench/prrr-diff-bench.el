;;; prrr-diff-bench.el --- Review Buffer render budgets  -*- lexical-binding: t -*-

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

;; SPEC section 12: the Review Buffer budgets.  Run with `make bench'.
;; Generates repositories of 417 and 2,516 changed files with
;; bench/make-diff-repo.sh and measures first paint, expanding one
;; 300-line file, and a refresh with three files expanded, each as the
;; median of several runs in a fresh buffer.  The expanded files are C,
;; highlighted when the C grammar is installed
;; (`treesit-install-language-grammar'); without it the expand budget is
;; measured unhighlighted and says so.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'prrr-diff)
(require 'prrr-treesit)

(defconst prrr-diff-bench-tolerance 1.25
  "A run fails when a median exceeds its budget by more than this factor.")

(defconst prrr-diff-bench--script
  (expand-file-name "make-diff-repo.sh" (file-name-directory (or load-file-name buffer-file-name)))
  "The repository generator next to this file.")

(defun prrr-diff-bench--ms (function)
  "Call FUNCTION; return the elapsed milliseconds."
  (let ((start (float-time)))
    (funcall function)
    (* 1000 (- (float-time) start))))

(defun prrr-diff-bench--median (numbers)
  "Return the median of NUMBERS, an odd-length list."
  (nth (/ (length numbers) 2) (sort (copy-sequence numbers) #'<)))

(defun prrr-diff-bench--pullreq ()
  "The generated repository's pull request."
  (forge-pullreq :id "bench-1" :number 1 :title "Bench" :their-id "PR_bench"
                 :base-rev (car (process-lines "git" "rev-parse" "main"))
                 :author "example-alice" :created "2026-09-01T00:00:00Z" :body ""))

(defun prrr-diff-bench--open (pullreq)
  "Open PULLREQ's Review Buffer in a fresh buffer; return the milliseconds."
  (when-let* ((old (get-buffer (prrr-diff--buffer-name pullreq))))
    (kill-buffer old))
  (garbage-collect)
  (prrr-diff-bench--ms (lambda () (prrr-diff-setup-buffer pullreq))))

(defun prrr-diff-bench--buffer (pullreq)
  "Return PULLREQ's Review Buffer."
  (get-buffer (prrr-diff--buffer-name pullreq)))

(defun prrr-diff-bench--unwashed ()
  "Return the current Review Buffer's files not washed yet."
  (seq-filter (lambda (file) (oref file washer)) (prrr-diff--files)))

(defun prrr-diff-bench--check-highlighted (file)
  "Signal an error when expanding FILE did not highlight it though it could."
  (when (and (prrr-treesit-rules "x.c")
             (not (text-property-not-all (oref file start) (oref file end)
                                         'prrr-treesit-face nil)))
    (error "Expanding %s did not highlight it" (oref file value))))

(defun prrr-diff-bench--measure (files)
  "Measure a repository of FILES changed files; return a plist of medians.
:open is first paint in a fresh buffer, :expand washing one file not
washed yet, :refresh `magit-refresh-buffer' with three more files
expanded."
  (let* ((dir (make-temp-file "prrr-bench" t))
         (repo (expand-file-name "r" dir)))
    (unwind-protect
        (progn
          (unless (zerop (call-process "sh" nil nil nil prrr-diff-bench--script repo
                                       (number-to-string files)))
            (error "Building the benchmark repository failed"))
          (let* ((default-directory (file-name-as-directory repo))
                 (pullreq (prrr-diff-bench--pullreq))
                 (opens (cl-loop repeat 5 collect (prrr-diff-bench--open pullreq)))
                 (expands (with-current-buffer (prrr-diff-bench--buffer pullreq)
                            (mapcar (lambda (file)
                                      (prog1 (prrr-diff-bench--ms (lambda () (magit-section-show file)))
                                        (prrr-diff-bench--check-highlighted file)))
                                    (seq-filter (lambda (file) (string-suffix-p ".c" (oref file value)))
                                                (prrr-diff-bench--unwashed)))))
                 (refreshes (progn
                              (prrr-diff-bench--open pullreq)
                              (with-current-buffer (prrr-diff-bench--buffer pullreq)
                                (mapc #'magit-section-show (seq-take (prrr-diff-bench--unwashed) 3))
                                (cl-loop repeat 5 collect
                                         (prrr-diff-bench--ms #'magit-refresh-buffer))))))
            (kill-buffer (prrr-diff-bench--buffer pullreq))
            (list :open (prrr-diff-bench--median opens)
                  :expand (prrr-diff-bench--median expands)
                  :refresh (prrr-diff-bench--median refreshes))))
      (delete-directory dir t))))

(defun prrr-diff-bench--check (label ms budget)
  "Print LABEL's MS against BUDGET; return non-nil when over the tolerance."
  (message "%s: %.1f ms (budget %.0f ms, fails over %.0f ms)"
           label ms budget (* budget prrr-diff-bench-tolerance))
  (> ms (* budget prrr-diff-bench-tolerance)))

(defun prrr-diff-bench-run ()
  "Measure the Review Buffer budgets of SPEC section 12; exit 1 over budget."
  (unless (treesit-language-available-p 'c)
    (message "No C grammar: the expand budget is measured without highlighting"))
  (let* ((prrr-database-file (make-temp-file "prrr-bench" nil ".sqlite"))
         ;; The Outbox stays out of the measurements.
         (prrr-db-open-hook nil)
         ;; The bench has no forge database; the PR has no Discussion Comments.
         (_ (advice-add (quote prrr-diff--posts) :override #'ignore))
         (small (prrr-diff-bench--measure 417))
         (large (prrr-diff-bench--measure 2516))
         (over (delq nil
                     (list (prrr-diff-bench--check "review open, 417 files"
                                                   (plist-get small :open) 150)
                           (prrr-diff-bench--check "review open, 2516 files"
                                                   (plist-get large :open) 500)
                           (prrr-diff-bench--check "expand one 300-line file"
                                                   (plist-get small :expand) 25)
                           (prrr-diff-bench--check "refresh, 3 expanded, 417 files"
                                                   (plist-get small :refresh) 250)))))
    (prrr-db-close)
    (delete-file prrr-database-file)
    (kill-emacs (if over 1 0))))

(provide 'prrr-diff-bench)
;;; prrr-diff-bench.el ends here
