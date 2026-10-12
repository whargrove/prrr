;;; prrr-api-test.el --- Tests for prrr-api  -*- lexical-binding: t -*-

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

;; The Agent API's reads, against the Review Buffer's fixture
;; repository and review data, with forge stubbed.  No network.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'prrr-test-helper)
(require 'prrr-api)
(require 'prrr-diff-test)

(defun prrr-api-test--pullreq ()
  "The fixture repository's pull request with every slot the summary reads.
Forge's database rows bind them all; `prrr-diff-test--pullreq' leaves
those the Review Buffer does not need unbound."
  (let ((pullreq (prrr-diff-test--pullreq)))
    (oset pullreq draft-p nil)
    (oset pullreq cross-repo-p nil)
    (oset pullreq base-ref "main")
    (oset pullreq head-ref "feature")
    (oset pullreq head-rev nil)
    pullreq))

(defconst prrr-api-test--github-down
  (mapcar (lambda (mutation) (cons mutation '(:error (error http 502))))
          '(addPullRequestReview addPullRequestReviewThread addPullRequestReviewThreadReply
            deletePullRequestReviewComment submitPullRequestReview))
  "GitHub's answer to each write the API queues: a failure.")

(defmacro prrr-api-test--with-pr (&rest body)
  "Run BODY with the fixture repository, stored review data and forge stubbed.
`pullreq' is bound to the fixture PR; `repo' to its repository.  BODY
runs from a temporary buffer outside the worktree, as `emacsclient -e'
does (Review Focus 2).  GitHub fails every write the Outbox sends, so
each stays queued for BODY to inspect and none reaches the network."
  (declare (indent 0))
  `(prrr-db-with-test-db
     (prrr-test-with-repo
       (prrr-test-with-outbox
         (let* ((worktree default-directory)
                (pullreq (prrr-api-test--pullreq))
                (repo (forge-github-repository :id "r" :owner "example-org" :name "example-repo"
                                               :githost "github.com" :apihost "api.github.com")))
           (ignore worktree pullreq repo)
           (prrr-diff-test--store-fixture)
           (cl-letf (((symbol-function 'forge-get-repository)
                      (lambda (&rest args)
                        (and (or (cl-typep (car args) 'forge-pullreq)
                                 (equal (car args) '("github.com" "example-org" "example-repo")))
                             repo)))
                     ((symbol-function 'forge-get-pullreq)
                      (lambda (_repo number) (and (= number 1) pullreq)))
                     ((symbol-function 'forge-get-worktree) (lambda (_) worktree))
                     ((symbol-function 'forge-get-url)
                      (lambda (_) "https://github.com/example-org/example-repo/pull/1")))
             (prrr-test-with-ghub-dispatch prrr-api-test--github-down
               (with-temp-buffer
                 (let ((default-directory temporary-file-directory))
                   ,@body)))))))))

(ert-deftest prrr-api-test-designators ()
  (prrr-api-test--with-pr
    (should (equal 1 (alist-get 'number (prrr-api-pullreq pullreq))))
    (should (equal 1 (alist-get 'number (prrr-api-pullreq '("example-org/example-repo" . 1)))))
    (should (equal 1 (alist-get 'number (prrr-api-pullreq (cons repo 1)))))
    (should-error (prrr-api-pullreq '("example-org/example-repo" . 99)) :type 'user-error)
    (should-error (prrr-api-pullreq "nonsense") :type 'user-error)))

(ert-deftest prrr-api-test-pullreq-summary ()
  (prrr-api-test--with-pr
    (let ((summary (prrr-api-pullreq pullreq)))
      (should (equal "example-org/example-repo" (alist-get 'repository summary)))
      (should (stringp (alist-get 'head summary)))
      (should (stringp (alist-get 'merge_base summary)))
      (should (natnump (alist-get 'pending summary))))))

(ert-deftest prrr-api-test-threads-are-alists-with-comments ()
  (prrr-api-test--with-pr
    (let ((threads (prrr-api-threads pullreq)))
      (should threads)
      (dolist (thread threads)
        (should (stringp (alist-get 'thread_id thread)))
        (should (member (alist-get 'side thread) '("new" "old" nil)))
        (should (alist-get 'comments thread))))))

(ert-deftest prrr-api-test-diff-default-and-one-file ()
  (prrr-api-test--with-pr
    (should (string-match-p "^diff --git a/src/example.el" (prrr-api-diff pullreq)))
    (let ((one (prrr-api-diff pullreq nil "src/example.el")))
      (should (string-match-p "src/example.el" one))
      (should-not (string-match-p "README.md" one)))))

(ert-deftest prrr-api-test-range-forms ()
  (prrr-api-test--with-pr
    (let* ((head (alist-get 'head (prrr-api-pullreq pullreq)))
           (commit (prrr-api-diff pullreq (list 'commit head))))
      (should (stringp commit))
      (should-error (prrr-api-diff pullreq '(commit "0000000000000000000000000000000000000001"))
                    :type 'user-error)
      (should-error (prrr-api-diff pullreq '(sideways)) :type 'user-error))))

(ert-deftest prrr-api-test-pending ()
  (prrr-api-test--with-pr
    (let ((pending (prrr-api-pending pullreq)))
      (should (listp (alist-get 'comments pending)))
      (dolist (comment (alist-get 'comments pending))
        (should (equal "pending" (alist-get 'state comment)))))))

(ert-deftest prrr-api-test-unfetched-head-is-a-clear-error ()
  (prrr-api-test--with-pr
    (let ((default-directory worktree))
      (magit-git "update-ref" "-d" "refs/pullreqs/1"))
    (should-error (prrr-api-pullreq pullreq) :type 'user-error)))

(ert-deftest prrr-api-test-add-comment-queues-an-agent-thread ()
  (prrr-api-test--with-pr
    (let* ((id (prrr-api-add-comment pullreq "src/example.el" 12 "Consider a guard."))
           (row (car (last (prrr-db-outbox-rows (oref pullreq their-id))))))
      (should (prrr-state-local-id-p id))
      (should (eq 'thread (prrr-outbox-kind row)))
      (should (plist-get (prrr-outbox-payload row) :agent))
      (should (equal '(:path "src/example.el" :line 12 :side right :subject-type line)
                     (plist-get (prrr-outbox-payload row) :anchor))))))

(ert-deftest prrr-api-test-add-comment-outside-the-diff-is-refused ()
  "Review Focus 1: GitHub would refuse it later where the agent cannot see."
  (prrr-api-test--with-pr
    (let ((err (should-error (prrr-api-add-comment pullreq "src/example.el" 200 "Far away")
                             :type 'user-error)))
      (should (string-match-p "not in the diff" (cadr err))))
    (should-error (prrr-api-add-comment pullreq "no/such/file.el" 1 "x") :type 'user-error)
    (should-not (prrr-db-outbox-rows (oref pullreq their-id)))))

(ert-deftest prrr-api-test-file-comment-and-range-comment ()
  (prrr-api-test--with-pr
    (prrr-api-add-comment pullreq "src/example.el" nil "Whole file" :file t)
    (prrr-api-add-comment pullreq "src/example.el" 12 "Two lines" :start-line 11 :side "new")
    (let ((anchors (mapcar (lambda (row) (plist-get (prrr-outbox-payload row) :anchor))
                           (prrr-db-outbox-rows (oref pullreq their-id)))))
      (should (equal '(:path "src/example.el" :subject-type file) (nth 0 anchors)))
      (should (eql 11 (plist-get (nth 1 anchors) :start-line))))))

(ert-deftest prrr-api-test-reversed-range-is-refused ()
  "GitHub refuses a start line after the line, later, where the agent cannot see."
  (prrr-api-test--with-pr
    (let ((err (should-error (prrr-api-add-comment pullreq "src/example.el" 12 "Back"
                                                   :start-line 15)
                             :type 'user-error)))
      (should (string-match-p "START-LINE must not come after LINE" (cadr err))))
    (should-not (prrr-db-outbox-rows (oref pullreq their-id)))))

(ert-deftest prrr-api-test-prefix-is-prepended ()
  (prrr-api-test--with-pr
    (let ((prrr-agent-comment-prefix "[bot] "))
      (prrr-api-add-comment pullreq "src/example.el" 12 "Hi"))
    (should (equal "[bot] Hi" (plist-get (prrr-outbox-payload
                                          (car (prrr-db-outbox-rows (oref pullreq their-id))))
                                         :body)))))

(ert-deftest prrr-api-test-reply-and-delete ()
  (prrr-api-test--with-pr
    (let* ((thread (car (prrr-api-threads pullreq)))
           (id (prrr-api-reply pullreq (alist-get 'thread_id thread) "Agreed")))
      (should (prrr-state-local-id-p id))
      (should-error (prrr-api-reply pullreq "T_nope" "x") :type 'user-error)
      ;; deleting the queued reply drops its write (prrr-sync-write's rule)
      (should (prrr-api-delete-pending-comment pullreq id))
      (should-not (seq-find (lambda (row) (eq 'reply (prrr-outbox-kind row)))
                            (prrr-db-outbox-rows (oref pullreq their-id)))))))

(ert-deftest prrr-api-test-submit-asks-the-user ()
  (prrr-api-test--with-pr
    (prrr-api-add-comment pullreq "src/example.el" 12 "Nit")
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (prompt) (should (string-match-p "1 by an agent" prompt)) nil)))
      (should-not (prrr-api-submit pullreq "comment" "Looks fine")))
    (should-not (seq-find (lambda (row) (eq 'submit (prrr-outbox-kind row)))
                          (prrr-db-outbox-rows (oref pullreq their-id))))
    (let ((prrr-api-confirm-submit nil))
      (should (prrr-api-submit pullreq 'approve)))
    (should (seq-find (lambda (row) (eq 'submit (prrr-outbox-kind row)))
                      (prrr-db-outbox-rows (oref pullreq their-id))))
    (should-error (prrr-api-submit pullreq 'shrug) :type 'user-error)))

(ert-deftest prrr-api-test-proposed-mode-queues-a-proposal ()
  "SPEC section 10: in `proposed' mode the agent's comment waits for the user."
  (prrr-api-test--with-pr
    (let* ((prrr-agent-comment-mode 'proposed)
           (id (prrr-api-add-comment pullreq "src/example.el" 12 "Consider a guard."))
           (row (car (last (prrr-db-outbox-rows (oref pullreq their-id)))))
           (listed (seq-find (lambda (comment) (equal id (alist-get 'comment_id comment)))
                             (alist-get 'comments (prrr-api-pending pullreq)))))
      (should (prrr-state-local-id-p id))
      (should (eq 'proposed (prrr-outbox-kind row)))
      (should (eq 'thread (plist-get (prrr-outbox-payload row) :as)))
      (should (plist-get (prrr-outbox-payload row) :agent))
      (should (equal "proposed" (alist-get 'local_state listed)))
      (should (alist-get 'agent listed))
      ;; Nothing is sent, and the summary does not count it as pending.
      (should-not prrr-test-requests)
      (should (equal (length (seq-filter #'prrr-state-comment-pending-p
                                         (prrr-db-select 'review-comment
                                                         :pr-id (oref pullreq their-id))))
                     (alist-get 'pending (prrr-api-pullreq pullreq)))))))

(ert-deftest prrr-api-test-reply-to-a-proposed-thread-is-refused ()
  "Review Focus 5: an agent's reply must not wait on a proposal it cannot accept."
  (prrr-api-test--with-pr
    (let* ((prrr-agent-comment-mode 'proposed)
           (_ (prrr-api-add-comment pullreq "src/example.el" 12 "Consider a guard."))
           (thread-id (plist-get (prrr-outbox-payload
                                  (car (prrr-db-outbox-rows (oref pullreq their-id))))
                                 :thread)))
      (let ((prrr-agent-comment-mode 'pending))
        (should-error (prrr-api-reply pullreq thread-id "More") :type 'user-error))
      (should (= 1 (length (prrr-db-outbox-rows (oref pullreq their-id))))))))

(provide 'prrr-api-test)
;;; prrr-api-test.el ends here
