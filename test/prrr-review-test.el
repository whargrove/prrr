;;; prrr-review-test.el --- ERT tests for commenting and the Pending Review  -*- lexical-binding: t -*-

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

;; The commenting commands in the fixture PR's Review Buffer, with the
;; Outbox sending synchronously to stubbed GitHub answers.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'prrr-test-helper)
(require 'prrr-diff-test)
(require 'prrr-review)
(require 'prrr-transient)

(defmacro prrr-review-test--with-buffer (answers &rest body)
  "Run BODY in the fixture PR's Review Buffer, its review data stored.
GitHub answers each request from ANSWERS, as for
`prrr-test-with-ghub-dispatch'.  The Outbox sends at once.  A capture
buffer the body opens is confirmed with `prrr-review-test--send'."
  (declare (indent 1))
  `(prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
     (prrr-test-with-outbox
       (cl-letf (((symbol-function 'forge-get-repository)
                  (lambda (&rest _) (forge-github-repository :id "r" :owner "example-org"
                                                             :name "example-repo"
                                                             :apihost "api.github.com"))))
         (prrr-test-with-ghub-dispatch ,answers
           (unwind-protect (progn ,@body)
             (dolist (buffer (buffer-list))
               (when (string-prefix-p "*prrr comment*" (buffer-name buffer))
                 (kill-buffer buffer)))))))))

(defun prrr-review-test--send (text)
  "Type TEXT in the open capture buffer and confirm it."
  (with-current-buffer (seq-find (lambda (buffer)
                                   (string-prefix-p "*prrr comment*" (buffer-name buffer)))
                                 (buffer-list))
    (insert text)
    (prrr-comment-confirm)))

(defun prrr-review-test--capture-header ()
  "Return the header of the open capture buffer."
  (with-current-buffer (seq-find (lambda (buffer)
                                   (string-prefix-p "*prrr comment*" (buffer-name buffer)))
                                 (buffer-list))
    (prrr-comment--header)))

(ert-deftest prrr-review-test-comment-joins-pending-review ()
  (prrr-review-test--with-buffer `((addPullRequestReviewThread . ,(prrr-test-fixture "add-thread")))
    (prrr-diff-test--goto-line "src/example.el" "+line twelve")
    (prrr-comment nil)
    (should (string-match-p "src/example\\.el:12 right" (prrr-review-test--capture-header)))
    (prrr-review-test--send "Nit.")
    (should (equal '(addPullRequestReviewThread) prrr-test-requests))
    (let ((comment (prrr-db-get 'review-comment "PRRC_kwDOexampleNew01")))
      (should (equal "Nit." (prrr-comment-body comment)))
      (should (eq 'pending (prrr-comment-state comment))))
    (should (eq (current-buffer) (get-buffer (prrr-diff--buffer-name (prrr-diff-test--pullreq)))))))

(ert-deftest prrr-review-test-comment-offline-shows-failed ()
  "Review Focus 1: a comment that cannot be sent shows, marked failed."
  (prrr-review-test--with-buffer '((addPullRequestReviewThread . (:error (error http 502))))
    (prrr-diff-test--goto-line "src/example.el" "+line twelve")
    (prrr-comment nil)
    (prrr-review-test--send "Nit.")
    (magit-refresh-buffer)
    (goto-char (point-min))
    (should (re-search-forward "^    example-me  [0-9-]+  pending  failed: GitHub returned HTTP 502$" nil t))
    (should (re-search-forward "^      Nit\\.$" nil t))))

(ert-deftest prrr-review-test-comment-immediate ()
  (prrr-review-test--with-buffer nil
    (prrr-test-with-rest-stub (prrr-test-fixture "publish-comment") captured
      (prrr-diff-test--goto-line "src/example.el" "+line twelve")
      (prrr-comment t)
      (should (string-match-p "publish now" (prrr-review-test--capture-header)))
      (prrr-review-test--send "Now.")
      (should (equal "/repos/example-org/example-repo/pulls/1/comments" (cadr captured)))
      (should (eq 'submitted (prrr-comment-state (prrr-db-get 'review-comment "PRRC_kwDOexampleNew03")))))))

(ert-deftest prrr-review-test-menu-switch-means-immediate ()
  (let ((transient-current-command 'prrr-menu))
    (cl-letf (((symbol-function 'transient-args) (lambda (_) '("--immediate"))))
      (should (prrr-review--immediate-p nil))))
  (should-not (prrr-review--immediate-p nil))
  (should (prrr-review--immediate-p '(4))))

(ert-deftest prrr-review-test-file-comment ()
  (prrr-review-test--with-buffer `((addPullRequestReviewThread . ,(prrr-test-fixture "add-thread")))
    (goto-char (oref (prrr-diff-test--file-section "README.md") start))
    (prrr-comment-file nil)
    (prrr-review-test--send "Split this file.")
    (should (equal "FILE" (alist-get 'subjectType
                                     (alist-get 'input (cdr (assq 'addPullRequestReviewThread prrr-test-variables))))))))

(ert-deftest prrr-review-test-reply-to-thread ()
  (prrr-review-test--with-buffer `((addPullRequestReviewThreadReply . ,(prrr-test-fixture "add-reply")))
    (let ((thread (car (oref (car (prrr-diff-test--hunks "src/example.el")) children))))
      (goto-char (oref thread start))
      (prrr-reply nil)
      (should (string-match-p "Reply on src/example\\.el, line 12" (prrr-review-test--capture-header)))
      (prrr-review-test--send "Agreed.")
      (should (equal "PRRT_kwDOexample0000001"
                     (alist-get 'pullRequestReviewThreadId
                                (alist-get 'input (cdr (assq 'addPullRequestReviewThreadReply
                                                              prrr-test-variables))))))
      (should (equal "PRR_kwDOexamplePending1"
                     (alist-get 'pullRequestReviewId
                                (alist-get 'input (cdr (assq 'addPullRequestReviewThreadReply
                                                              prrr-test-variables)))))))))

(ert-deftest prrr-review-test-reply-immediate-uses-database-id ()
  (prrr-review-test--with-buffer nil
    (prrr-test-with-rest-stub (prrr-test-fixture "publish-reply") captured
      (let ((thread (car (oref (car (prrr-diff-test--hunks "src/example.el")) children))))
        (goto-char (oref thread start))
        (prrr-reply t)
        (prrr-review-test--send "Done.")
        (should (equal "/repos/example-org/example-repo/pulls/1/comments/1001/replies"
                       (cadr captured)))))))

(ert-deftest prrr-review-test-edit-own-comment-only ()
  (prrr-review-test--with-buffer '((updatePullRequestReviewComment
                                    . ((data (updatePullRequestReviewComment (clientMutationId))))))
    (let* ((thread (car (oref (car (prrr-diff-test--hunks "src/example.el")) children)))
           (bob (car (oref thread children)))
           (mine (cadr (oref thread children))))
      (goto-char (oref bob start))
      (should-error (prrr-edit-comment) :type 'user-error)
      (goto-char (oref mine start))
      (prrr-edit-comment)
      (with-current-buffer (seq-find (lambda (buffer)
                                       (string-prefix-p "*prrr comment*" (buffer-name buffer)))
                                     (buffer-list))
        (should (equal "Yes, fixing." (buffer-string)))
        (erase-buffer))
      (prrr-review-test--send "Yes, fixed.")
      (should (equal "Yes, fixed." (prrr-comment-body (prrr-db-get 'review-comment
                                                                   "PRRC_kwDOexample0000002")))))))

(ert-deftest prrr-review-test-delete-own-comment ()
  (prrr-review-test--with-buffer '((deletePullRequestReviewComment
                                    . ((data (deletePullRequestReviewComment (clientMutationId))))))
    (let ((thread (car (oref (car (prrr-diff-test--hunks "src/example.el")) children))))
      (goto-char (oref (cadr (oref thread children)) start))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (prrr-delete-comment))
      (should-not (prrr-db-get 'review-comment "PRRC_kwDOexample0000002"))
      (should (prrr-db-get 'thread "PRRT_kwDOexample0000001")))))

(ert-deftest prrr-review-test-toggle-resolved ()
  (prrr-review-test--with-buffer '((resolveReviewThread . ((data (resolveReviewThread (clientMutationId))))))
    (let ((thread (car (oref (car (prrr-diff-test--hunks "src/example.el")) children))))
      (goto-char (oref thread start))
      (prrr-toggle-resolved)
      (should (equal '(resolveReviewThread) prrr-test-requests))
      (should (prrr-thread-resolved-p (prrr-db-get 'thread "PRRT_kwDOexample0000001"))))))

(ert-deftest prrr-review-test-resolve-refused ()
  (prrr-review-test--with-buffer nil
    (let ((thread (prrr-db-get 'thread "PRRT_kwDOexample0000001")))
      (setf (prrr-thread-resolvable-p thread) nil)
      (prrr-db-insert thread)
      (magit-refresh-buffer)
      (goto-char (oref (car (oref (car (prrr-diff-test--hunks "src/example.el")) children)) start))
      (should-error (prrr-toggle-resolved) :type 'user-error)
      (should-not prrr-test-requests))))

(ert-deftest prrr-review-test-discussion-comment ()
  (prrr-review-test--with-buffer '((addComment . ((data (addComment (clientMutationId))))))
    (let ((pulled nil))
      (cl-letf (((symbol-function 'forge-pull-topic) (lambda (topic) (interactive) (setq pulled topic))))
        (prrr-discussion-comment)
        (should-not (string-match-p "publish now\\|Pending Review" (prrr-review-test--capture-header)))
        (prrr-review-test--send "Thanks!")
        (should (equal '(addComment) prrr-test-requests))
        (should (equal prrr-diff-test--pr
                       (alist-get 'subjectId (alist-get 'input (cdr (assq 'addComment prrr-test-variables))))))
        (should pulled)))))

(ert-deftest prrr-review-test-suggest ()
  (prrr-review-test--with-buffer nil
    (prrr-diff-test--goto-line "src/example.el" "+line twelve")
    (prrr-comment-suggest nil)
    (with-current-buffer (seq-find (lambda (buffer)
                                     (string-prefix-p "*prrr comment*" (buffer-name buffer)))
                                   (buffer-list))
      (should (equal "```suggestion\nline twelve\n```\n" (buffer-string)))
      (prrr-comment-abort))
    (prrr-diff-test--goto-line "src/example.el" "-line 12")
    (should-error (prrr-comment-suggest nil) :type 'user-error)))

(ert-deftest prrr-review-test-suggest-without-lines ()
  "Inside a Thread there are no diff lines to suggest a change to."
  (prrr-review-test--with-buffer nil
    (goto-char (oref (car (oref (car (prrr-diff-test--hunks "src/example.el")) children)) start))
    (should-error (prrr-comment-suggest nil) :type 'user-error)
    (should-not (seq-find (lambda (buffer)
                            (string-prefix-p "*prrr comment*" (buffer-name buffer)))
                          (buffer-list)))))

(ert-deftest prrr-review-test-keys-and-menus-agree ()
  "SPEC section 9: milestone 4's keys, in the buffer and the menu."
  (pcase-dolist (`(,key . ,command) prrr-diff--review-keys)
    (should (eq command (keymap-lookup prrr-diff-mode-map key)))
    (let ((suffix (transient-get-suffix 'prrr-menu key)))
      (should (eq command (plist-get (if (vectorp suffix) (aref suffix 2) (cdr suffix))
                                     :command)))))
  (let ((switch (transient-get-suffix 'prrr-menu "-i")))
    (should (equal "--immediate" (plist-get (if (vectorp switch) (aref switch 2) (cdr switch))
                                           :argument)))))

(provide 'prrr-review-test)
;;; prrr-review-test.el ends here
