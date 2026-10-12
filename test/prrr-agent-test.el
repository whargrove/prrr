;;; prrr-agent-test.el --- Tests for prrr-agent  -*- lexical-binding: t -*-

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

;; Send to agent: the Markdown payload, the default hand-off with
;; agent-shell stubbed (it need not be installed), and `@' in the
;; Review Buffer.  No network.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'prrr-test-helper)
(require 'prrr-agent)
(require 'prrr-api-test)
(require 'prrr-review-test)

(ert-deftest prrr-agent-test-markdown-sections ()
  (prrr-api-test--with-pr
    (let ((md (prrr-agent-markdown pullreq nil "Check the error handling.")))
      (should (string-match-p "^# Pull request #1" md))
      (should (string-match-p "Check the error handling\\." md))
      (should (string-match-p "^## Diff" md))
      (should (string-match-p "^```diff" md))
      (should (string-match-p "prrr-api-add-comment" md))
      (should (string-match-p "(\"example-org/example-repo\" \\. 1)" md)))))

(ert-deftest prrr-agent-test-markdown-lists-threads-and-pending ()
  "The agent gets each Thread's id, to reply, and the Pending Review."
  (prrr-api-test--with-pr
    (prrr-api-add-comment pullreq "src/example.el" 12 "Consider a guard.")
    (let ((md (prrr-agent-markdown pullreq nil "")))
      (should-not (string-match-p "^## Instructions" md))
      (should (string-match-p "^## Pending Review" md))
      (should (string-match-p "^- src/example\\.el:12 (agent): Consider a guard\\." md))
      (should (string-match-p "^## Threads" md))
      (dolist (thread (prrr-api-threads pullreq))
        (should (string-search (alist-get 'thread_id thread) md)))
      (should-not (string-match-p "diff cut after" md)))))

(ert-deftest prrr-agent-test-long-diff-is-cut ()
  (prrr-api-test--with-pr
    (let* ((prrr-agent-max-diff-lines 3)
           (md (prrr-agent-markdown pullreq nil "")))
      (should (string-match-p "diff cut after 3 lines" md))
      (should (string-match-p "src/example\\.el" md)))))

(ert-deftest prrr-agent-test-default-without-agent-shell-copies ()
  (let ((kill-ring nil))
    (cl-letf (((symbol-function 'prrr-agent--shell) (lambda (_) nil)))
      (prrr-agent-invoke-default "payload" (list :directory default-directory)))
    (should (equal "payload" (car kill-ring)))))

(ert-deftest prrr-agent-test-default-queues-when-busy-else-submits ()
  (let ((shell (generate-new-buffer " *fake agent*")) calls)
    (unwind-protect
        (cl-letf (((symbol-function 'prrr-agent--shell) (lambda (_) shell))
                  ((symbol-function 'shell-maker-busy) (lambda () t))
                  ((symbol-function 'agent-shell-prompt-queue)
                   (lambda (text) (push (list 'queue text) calls)))
                  ((symbol-function 'agent-shell-insert)
                   (lambda (&rest args) (push (cons 'insert args) calls))))
          (prrr-agent-invoke-default "p1" nil)
          (cl-letf (((symbol-function 'shell-maker-busy) (lambda () nil)))
            (prrr-agent-invoke-default "p2" nil)))
      (kill-buffer shell))
    (should (equal '(queue "p1") (nth 1 calls)))
    (should (equal "p2" (plist-get (cdr (nth 0 calls)) :text)))
    (should (plist-get (cdr (nth 0 calls)) :submit))))

(ert-deftest prrr-agent-test-no-shell-without-agent-shell ()
  "Without agent-shell loaded there is no shell to find, whatever the buffers."
  (unless (featurep 'agent-shell)
    (should-not (prrr-agent--shell default-directory))))

(ert-deftest prrr-agent-test-at-sends-the-review-buffer-range ()
  "`@' asks for instructions, then hands the payload and the shown Range on."
  (prrr-review-test--with-buffer nil
    (let ((pullreq (prrr-diff-pullreq))
          (worktree default-directory)
          sent)
      (oset pullreq draft-p nil)
      (oset pullreq cross-repo-p nil)
      (oset pullreq head-rev nil)
      (oset pullreq base-ref "main")
      (oset pullreq head-ref "feature")
      (cl-letf (((symbol-function 'forge-get-worktree) (lambda (_) worktree))
                ((symbol-function 'forge-get-url)
                 (lambda (_) "https://github.com/example-org/example-repo/pull/1")))
        (let ((prrr-agent-invoke-function
               (lambda (markdown context) (setq sent (list markdown context)))))
          (call-interactively (key-binding (kbd "@")))
          (should-not sent)
          (prrr-review-test--send "Look at errors")))
      (should (string-match-p "Look at errors" (nth 0 sent)))
      (should (eq prrr-diff--range (plist-get (nth 1 sent) :range)))
      (should (eq pullreq (plist-get (nth 1 sent) :pullreq)))
      (should (equal worktree (plist-get (nth 1 sent) :directory))))))

(ert-deftest prrr-agent-test-diff-fence-outlasts-the-diff ()
  "Final review 11: a ``` line in the diff does not close the fence early."
  (let* ((diff (concat "diff --git a/README.md b/README.md\n"
                       "@@ -1,3 +1,4 @@\n"
                       " ```\n"
                       "+````sh\n"
                       " code\n"))
         (md (prrr-agent--diff diff '("README.md"))))
    (should (string-match-p "^`````diff\n" md))
    (should (string-match-p "\n`````\n\\'" md))
    (should (string-search " ```\n+````sh\n code\n" md)))
  (should (string-match-p "^```diff\n" (prrr-agent--diff " plain\n" '("a")))))

(provide 'prrr-agent-test)
;;; prrr-agent-test.el ends here
