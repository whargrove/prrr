;;; prrr-thread-test.el --- ERT tests for rendering Threads  -*- lexical-binding: t -*-

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

;; Rendering one Thread and its Review Comments into a magit-section buffer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'prrr-test-helper)
(require 'prrr-thread)

(cl-defun prrr-thread-test--comment (&key (id "C_1") (thread "T_1") (author "example-bob")
                                          (body "Looks odd.") (state 'submitted) updated-at)
  "A Review Comment of Thread THREAD.
ID, AUTHOR, BODY, STATE and UPDATED-AT default to sensible values."
  (prrr-comment-create :comment-id id :thread-id thread :pr-id "PR_1" :author author
                       :body body :created-at "2026-09-02T10:00:00Z" :updated-at updated-at
                       :state state :local-state 'sent))

(defmacro prrr-thread-test--with-render (form &rest body)
  "Evaluate FORM inside a root section of a fresh buffer, then run BODY there.
BODY sees `section', the first child of the root."
  (declare (indent 1))
  `(with-temp-buffer
     (magit-section-mode)
     (let ((inhibit-read-only t))
       (magit-insert-section (root)
         ,form))
     (let ((section (car (oref magit-root-section children))))
       (goto-char (point-min))
       ,@body)))

(defun prrr-thread-test--lines ()
  "The buffer's lines, without properties."
  (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n" t))

(ert-deftest prrr-thread-test-line-thread ()
  (prrr-thread-test--with-render
      (prrr-thread-insert (prrr-test-thread)
                          (list (prrr-thread-test--comment)
                                (prrr-thread-test--comment :id "C_2" :author "example-me"
                                                           :body "Fixed.\nTwice."
                                                           :updated-at "2026-09-03T00:00:00Z")))
    (should (eq 'thread (oref section type)))
    (should (equal "T_1" (oref section value)))
    (should-not (oref section hidden))
    (should (eq 'prrr-thread-section-map (oref section keymap)))
    (should (equal '("    Thread  line 12  2 comments"
                     "    example-bob  2026-09-02"
                     "      Looks odd."
                     "    example-me  2026-09-02  edited"
                     "      Fixed."
                     "      Twice.")
                   (prrr-thread-test--lines)))
    (should (equal '("C_1" "C_2") (mapcar (lambda (child) (oref child value))
                                          (oref section children))))
    (should (equal '(review-comment review-comment)
                   (mapcar (lambda (child) (oref child type)) (oref section children))))))

(ert-deftest prrr-thread-test-resolved-range-thread-is-hidden ()
  (prrr-thread-test--with-render
      (prrr-thread-insert (prrr-test-thread :start-line 1 :line 3 :resolved-p t)
                          (list (prrr-thread-test--comment)))
    (should (oref section hidden))
    (should (looking-at "    Thread  lines 1-3  1 comment  resolved$"))
    (should (eq 'prrr-thread-resolved (get-text-property (+ (point) 4) 'font-lock-face)))))

(ert-deftest prrr-thread-test-left-side-and-pending ()
  (prrr-thread-test--with-render
      (prrr-thread-insert (prrr-test-thread :side 'left :line 7)
                          (list (prrr-thread-test--comment :state 'pending)))
    (should (eq 'thread (oref section type)))
    (should (looking-at "    Thread  line 7, left  1 comment  1 pending$"))
    (forward-line)
    (should (looking-at "    example-bob  2026-09-02  pending$"))))

(ert-deftest prrr-thread-test-file-comment ()
  (prrr-thread-test--with-render
      (prrr-thread-insert (prrr-test-thread :subject-type 'file :line nil)
                          (list (prrr-thread-test--comment)))
    (should (eq 'file-comment (oref section type)))
    (should (looking-at "    File comment  file  1 comment$"))))

(ert-deftest prrr-thread-test-with-path-and-outdated-line ()
  "Away from its file a Thread names the file; an outdated one its original line."
  (prrr-thread-test--with-render
      (prrr-thread-insert (prrr-thread-create :thread-id "T_9" :pr-id "PR_1" :path "src/old.el"
                                              :line nil :original-line 40 :side 'left
                                              :subject-type 'line :outdated-p t)
                          nil t)
    (should (eq 'thread (oref section type)))
    (should (looking-at "    Thread  src/old.el, line 40, left  0 comments$"))))

(ert-deftest prrr-thread-test-ghost-author-and-empty-body ()
  (prrr-thread-test--with-render
      (prrr-thread-insert (prrr-test-thread)
                          (list (prrr-thread-test--comment :author nil :body nil)))
    (should (eq 'thread (oref section type)))
    (forward-line)
    (should (looking-at "    ghost  2026-09-02$"))))

(provide 'prrr-thread-test)
;;; prrr-thread-test.el ends here
