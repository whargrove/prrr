;;; prrr-stack-test.el --- Tests for prrr-stack  -*- lexical-binding: t -*-

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

;; Stack navigation in the Review Buffer, on the fixture repository
;; with a second pull request stacked on the first.  No network.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'prrr-test-helper)
(require 'prrr-diff-test)
(require 'prrr-stack)

(defun prrr-stack-test--bottom ()
  "The fixture's pull request, every slot the Review Queue reads bound.
Its base is main, its head branch feature."
  (let ((pullreq (prrr-diff-test--pullreq)))
    (dolist (slot '((state . open) (draft-p . nil) (updated . "2026-09-01T00:00:00Z")
                    (head-rev . nil) (base-ref . "main") (head-ref . "feature")
                    (cross-repo-p . nil)))
      (eieio-oset pullreq (car slot) (cdr slot)))
    pullreq))

(defun prrr-stack-test--top ()
  "A pull request stacked on the fixture's: its base is the fixture's head branch."
  (forge-pullreq :id "forge-2" :number 2 :title "On top" :their-id "PR_2" :state 'open
                 :draft-p nil :base-ref "feature" :head-ref "top" :cross-repo-p nil
                 :base-rev prrr-test-repo-base :head-rev nil :author "example-alice"
                 :created "2026-09-02T00:00:00Z" :updated "2026-09-02T00:00:00Z" :body ""))

(defmacro prrr-stack-test--with-stack (&rest body)
  "Run BODY in the fixture PR's Review Buffer, with a PR stacked on it.
The fixture PR's base is main, its head branch feature."
  (declare (indent 0))
  `(let ((get-repository (symbol-function 'forge-get-repository))
         (bottom (prrr-stack-test--bottom))
         (top (prrr-stack-test--top)))
     (prrr-diff-test--with-buffer
         (call-process "git" nil nil nil "update-ref" "refs/pullreqs/2" "refs/pullreqs/1")
       (cl-letf (((symbol-function 'forge-get-repository)
                  (lambda (&rest args)
                    (if (forge-pullreq-p (car args))
                        (let ((repo (forge-github-repository :id "example-repo-id")))
                          (oset repo default-branch "main")
                          repo)
                      (apply get-repository args))))
                 ((symbol-function 'prrr-queue-open-pullreqs)
                  (lambda (_repo _metas) (list top bottom)))
                 ((symbol-function 'prrr-queue--assignees) #'ignore)
                 ((symbol-function 'prrr-sync-refetch) #'ignore))
         (setq prrr-diff--pullreq bottom)
         (unwind-protect (progn ,@body)
           (when-let* ((buffer (get-buffer (prrr-diff--buffer-name top))))
             (kill-buffer buffer)))))))

(ert-deftest prrr-stack-test-up-opens-the-pr-above-here ()
  "SPEC section 8: > opens the PR above at its default Range, in the same window."
  (prrr-stack-test--with-stack
    (let ((window (selected-window)))
      (prrr-stack-up)
      (should (equal (prrr-diff--buffer-name top) (buffer-name (window-buffer window))))
      (with-current-buffer (window-buffer window)
        (should (eq top (prrr-diff-pullreq)))
        (should (eq 'default (prrr-range-kind prrr-diff--range)))
        (should-error (prrr-stack-up) :type 'user-error)
        (prrr-stack-down)
        (should (eq bottom (prrr-diff-pullreq)))))))

(ert-deftest prrr-stack-test-moving-records-the-bookmark ()
  "SPEC section 8: stepping to the next PR leaves this one, so its Bookmark is recorded."
  (prrr-stack-test--with-stack
    (let ((head (prrr-diff-head)))
      (should-not (prrr-db-get 'pr-bookmark prrr-diff-test--pr))
      (prrr-stack-up)
      (should (equal head (prrr-bookmark-last-opened-head-oid
                           (prrr-db-get 'pr-bookmark prrr-diff-test--pr)))))))

(ert-deftest prrr-stack-test-bottom-of-the-stack ()
  "Going down from the bottom PR of a Stack signals a `user-error'."
  (prrr-stack-test--with-stack
    (should (equal '(user-error "Bottom of the Stack")
                   (should-error (prrr-stack-down) :type 'user-error)))))

(provide 'prrr-stack-test)
;;; prrr-stack-test.el ends here
