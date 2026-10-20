;;; prrr-queue-test.el --- Tests for prrr-queue  -*- lexical-binding: t -*-

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

;; Rendering the Review Queue section into a magit-section buffer from
;; constructed inputs; no forge database and no network.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'prrr-test-helper)
(require 'prrr-queue)

(defun prrr-queue-test--pair (&rest args)
  "Return (PULLREQ . PR) for `prrr-test-pr' ARGS with a matching forge object."
  (let ((pr (apply #'prrr-test-pr args)))
    (cons (forge-pullreq :id (format "forge-%s" (prrr-pr-id pr))
                         :number (prrr-pr-number pr)
                         :title (prrr-pr-title pr)
                         :their-id (prrr-pr-id pr))
          pr)))

(cl-defun prrr-queue-test--inputs (pairs metas &key (me prrr-test-me) status unresolved (width 100))
  "INPUTS for `prrr-queue-insert' over PAIRS and METAS.
Keys ME, STATUS, UNRESOLVED and WIDTH set the matching input."
  (list :pairs pairs :metas metas :teams prrr-test-teams :me me
        :default-branch "main" :unresolved unresolved :status status
        :now "2026-10-10T12:00:00Z" :width width))

(defmacro prrr-queue-test--with-render (inputs &rest body)
  "Render INPUTS into a fresh magit-section buffer and run BODY there."
  (declare (indent 1))
  `(with-temp-buffer
     (magit-section-mode)
     (let ((inhibit-read-only t))
       (magit-insert-section (status)
         (prrr-queue-insert ,inputs)))
     (goto-char (point-min))
     ,@body))

(defun prrr-queue-test--line-of (number)
  "Return the text of the row of PR NUMBER in the current buffer."
  (goto-char (point-min))
  (re-search-forward (format "^#%d " number))
  (buffer-substring-no-properties (line-beginning-position) (line-end-position)))

(defun prrr-queue-test--group (group)
  "Return the section of GROUP (`for-me' or `mine') in the current buffer."
  (seq-find (lambda (section) (eq (oref section value) group))
            (oref (car (oref magit-root-section children)) children)))

;;;; Structure

(ert-deftest prrr-queue-test-heading-and-group-counts ()
  (prrr-queue-test--with-render
      (prrr-queue-test--inputs
       (list (prrr-queue-test--pair :id "A" :number 1)
             (prrr-queue-test--pair :id "M" :number 2 :author "example-me" :head-ref "mine"))
       (list (prrr-test-meta :pr-id "A" :review-requests '((user "example-me")))))
    (should (looking-at "Review Queue\n"))
    (should (search-forward "For me (1)" nil t))
    (should (search-forward "Mine (1)" nil t))))

(ert-deftest prrr-queue-test-row-value-is-the-forge-pullreq ()
  (let ((pair (prrr-queue-test--pair :id "A" :number 7)))
    (prrr-queue-test--with-render
        (prrr-queue-test--inputs (list pair)
                                 (list (prrr-test-meta :pr-id "A" :review-requests '((user "example-me")))))
      (prrr-queue-test--line-of 7)
      (should (eq (car pair) (magit-section-value-if 'pullreq)))
      (should (eq 'prrr-queue-row-map (oref (magit-current-section) keymap)))
      (should (equal "A" (prrr-pr-id (prrr-queue-entry-pr (cdr (car prrr-queue--rows)))))))))

(ert-deftest prrr-queue-test-rows-follow-queue-order ()
  (prrr-queue-test--with-render
      (prrr-queue-test--inputs
       (list (prrr-queue-test--pair :id "NEW" :number 2 :head-ref "n" :created-at "2026-09-05T00:00:00Z")
             (prrr-queue-test--pair :id "OLD" :number 1 :head-ref "o" :created-at "2026-09-01T00:00:00Z"))
       (list (prrr-test-meta :pr-id "NEW" :review-requests '((user "example-me")))
             (prrr-test-meta :pr-id "OLD" :review-requests '((user "example-me")))))
    (should (< (progn (re-search-forward "^#1 ") (point))
               (progn (re-search-forward "^#2 ") (point))))))

(ert-deftest prrr-queue-test-empty-queue-collapsed ()
  "Review Focus 3: nothing pulled yet, no open PRs."
  (prrr-queue-test--with-render (prrr-queue-test--inputs nil nil)
    (should (search-forward "For me (0)" nil t))
    (should (search-forward "Mine (0)" nil t))
    (should (oref (prrr-queue-test--group 'for-me) hidden))
    (should (oref (prrr-queue-test--group 'mine) hidden))))

(ert-deftest prrr-queue-test-non-empty-queue-expanded ()
  (prrr-queue-test--with-render
      (prrr-queue-test--inputs (list (prrr-queue-test--pair :id "A" :number 1))
                               (list (prrr-test-meta :pr-id "A" :review-requests '((user "example-me")))))
    (should-not (oref (prrr-queue-test--group 'for-me) hidden))))

;;;; Stacks (prrr-knu.5)

(ert-deftest prrr-queue-test-stack-missing-bottom-is-not-indented ()
  "My own bottom PR is in Mine, so For Me shows a one-row Stack."
  (prrr-queue-test--with-render
      (prrr-queue-test--inputs
       (list (prrr-queue-test--pair :id "MINE" :number 1 :author "example-me" :head-ref "step-1")
             (prrr-queue-test--pair :id "THEIRS" :number 2 :base-ref "step-1" :head-ref "step-2"))
       (list (prrr-test-meta :pr-id "MINE")
             (prrr-test-meta :pr-id "THEIRS" :review-requests '((user "example-me")))))
    (let ((line (prrr-queue-test--line-of 2)))
      (should (string-prefix-p "#2  requested" line))
      (should (string-match-p "⟰ 2/2" line)))))

(defun prrr-queue-test--three-stack ()
  "Inputs of a three-PR Stack, every member requested from me."
  (prrr-queue-test--inputs
   (list (prrr-queue-test--pair :id "BOTTOM" :number 1 :head-ref "step-1")
         (prrr-queue-test--pair :id "MIDDLE" :number 2 :base-ref "step-1" :head-ref "step-2")
         (prrr-queue-test--pair :id "TOP" :number 3 :base-ref "step-2" :head-ref "step-3"))
   (list (prrr-test-meta :pr-id "BOTTOM" :review-requests '((user "example-me")))
         (prrr-test-meta :pr-id "MIDDLE" :review-requests '((user "example-me")))
         (prrr-test-meta :pr-id "TOP" :review-requests '((user "example-me"))))))

(ert-deftest prrr-queue-test-stack-members-indent-one-level ()
  "Every member above a Stack's first row sits one level under it, however high."
  (prrr-queue-test--with-render (prrr-queue-test--three-stack)
    (should (string-prefix-p "#1  requested" (prrr-queue-test--line-of 1)))
    (should (string-prefix-p "#2    requested" (prrr-queue-test--line-of 2)))
    (should (string-prefix-p "#3    requested" (prrr-queue-test--line-of 3)))
    (should (string-match-p "⟰ 1/3" (prrr-queue-test--line-of 1)))
    (should (string-match-p "⟰ 3/3" (prrr-queue-test--line-of 3)))))

(defun prrr-queue-test--row-section (number)
  "Return the row section of PR NUMBER in the current buffer."
  (car (seq-find (lambda (row) (= number (prrr-pr-number (prrr-queue-entry-pr (cdr row)))))
                 prrr-queue--rows)))

(ert-deftest prrr-queue-test-stack-folds-under-its-first-row ()
  "TAB on a Stack's first row folds its other members away."
  (prrr-queue-test--with-render (prrr-queue-test--three-stack)
    (let ((first (prrr-queue-test--row-section 1)))
      (should (equal (list (prrr-queue-test--row-section 2) (prrr-queue-test--row-section 3))
                     (oref first children)))
      (should-not (oref first hidden))
      (magit-section-hide first)
      (should (invisible-p (oref (prrr-queue-test--row-section 3) start)))
      (should-not (invisible-p (oref first start)))
      ;; Every row is still in display order, for n, p, > and <.
      (should (equal '(1 2 3) (mapcar (lambda (row) (prrr-pr-number (prrr-queue-entry-pr (cdr row))))
                                      prrr-queue--rows))))))

(ert-deftest prrr-queue-test-lone-row-has-no-children ()
  (prrr-queue-test--with-render
      (prrr-queue-test--inputs (list (prrr-queue-test--pair :id "A" :number 1))
                               (list (prrr-test-meta :pr-id "A" :review-requests '((user "example-me")))))
    (should-not (oref (prrr-queue-test--row-section 1) children))))

(ert-deftest prrr-queue-test-lone-pr-has-no-stack-marker ()
  (prrr-queue-test--with-render
      (prrr-queue-test--inputs (list (prrr-queue-test--pair :id "A" :number 1))
                               (list (prrr-test-meta :pr-id "A" :review-requests '((user "example-me")))))
    (should-not (string-match-p "⟰" (prrr-queue-test--line-of 1)))))

;;;; Filters

(ert-deftest prrr-queue-test-hide-served ()
  (let ((prrr-queue-show-served nil))
    (prrr-queue-test--with-render
        (prrr-queue-test--inputs
         (list (prrr-queue-test--pair :id "A" :number 1 :head-ref "a")
               (prrr-queue-test--pair :id "S" :number 2 :head-ref "s"))
         (list (prrr-test-meta :pr-id "A" :review-requests '((user "example-me")))
               (prrr-test-meta :pr-id "S" :viewer-latest-review
                               (list "APPROVED" "2026-09-02T00:00:00Z" prrr-test-head))))
      (should (re-search-forward "^#1 " nil t))
      (goto-char (point-min))
      (should-not (re-search-forward "^#2 " nil t)))))

;;;; Line

(ert-deftest prrr-queue-test-line-shows-author-unresolved-and-age ()
  (let ((unresolved (make-hash-table :test #'equal)))
    (puthash "A" 3 unresolved)
    (prrr-queue-test--with-render
        (prrr-queue-test--inputs
         (list (prrr-queue-test--pair :id "A" :number 1 :title "Fix the parser"
                                      :updated-at "2026-10-08T12:00:00Z"))
         (list (prrr-test-meta :pr-id "A" :review-requests '((user "example-me"))))
         :unresolved unresolved)
      (should (string-match-p
               "^#1  requested +Fix the parser  example-alice  3 unresolved  2d$"
               (prrr-queue-test--line-of 1))))))

(ert-deftest prrr-queue-test-line-fits-width ()
  "Review Focus 5: long and wide titles are truncated to the window."
  (dolist (title (list (make-string 300 ?x) (make-string 150 ?語)))
    (prrr-queue-test--with-render
        (prrr-queue-test--inputs
         (list (prrr-queue-test--pair :id "A" :number 1 :title title))
         (list (prrr-test-meta :pr-id "A" :review-requests '((user "example-me"))))
         :width 60)
      (should (<= (string-width (prrr-queue-test--line-of 1)) 60)))))

(ert-deftest prrr-queue-test-line-dimmed-row-uses-dimmed-face ()
  (let* ((entry (prrr-queue-entry-create :pr (prrr-test-pr :number 4) :state nil
                                         :stack-pos 1 :stack-size 2 :dimmed-p t))
         (line (prrr-queue--line entry 3 0 0 "2026-10-10T12:00:00Z" 80)))
    (should (eq 'prrr-queue-dimmed (get-text-property 0 'font-lock-face line)))))

(ert-deftest prrr-queue-test-ago ()
  (let ((now "2026-10-10T12:00:00Z"))
    (should (equal "now" (prrr-queue--ago "2026-10-10T11:59:30Z" now)))
    (should (equal "5m" (prrr-queue--ago "2026-10-10T11:55:00Z" now)))
    (should (equal "3h" (prrr-queue--ago "2026-10-10T09:00:00Z" now)))
    (should (equal "2d" (prrr-queue--ago "2026-10-08T12:00:00Z" now)))
    (should (equal "2mo" (prrr-queue--ago "2026-08-10T12:00:00Z" now)))
    (should (equal "1y" (prrr-queue--ago "2025-10-01T12:00:00Z" now)))
    (should (equal "" (prrr-queue--ago nil now)))
    (should (equal "now" (prrr-queue--ago "2026-10-10T12:05:00Z" now)))))

;;;; Heading status

(ert-deftest prrr-queue-test-status-text ()
  (should (equal "" (prrr-queue--status-text nil "example-me")))
  (should (equal "" (prrr-queue--status-text '(:state ok) "example-me")))
  (should (string-match-p "(Teams unavailable: HTTP 403)"
                          (prrr-queue--status-text '(:state ok :message "Teams unavailable: HTTP 403")
                                                   "example-me")))
  (should (string-match-p "pulling" (prrr-queue--status-text '(:state pulling) "example-me")))
  (should (string-match-p "offline" (prrr-queue--status-text '(:state offline) "example-me")))
  (should (string-match-p "rate limited until [0-9][0-9]:[0-9][0-9]"
                          (prrr-queue--status-text '(:state rate-limited :reset-at "2026-10-10T12:30:00Z")
                                                   "example-me")))
  (should (string-match-p "HTTP 401"
                          (prrr-queue--status-text '(:state auth :message "GitHub rejected the token (HTTP 401)")
                                                   "example-me")))
  (should (string-match-p "github.user" (prrr-queue--status-text nil nil))))

(ert-deftest prrr-queue-test-no-login-renders-heading-only ()
  (prrr-queue-test--with-render
      (prrr-queue-test--inputs (list (prrr-queue-test--pair :id "A" :number 1)) nil :me nil)
    (should (looking-at "Review Queue (no GitHub login"))
    (should-not (re-search-forward "^#1 " nil t))))
;;;; From forge to the section

(defun prrr-queue-test--repo ()
  "A GitHub repository object that needs no forge database."
  (let ((repo (forge-github-repository :id "example-repo-id" :owner "example-org"
                                       :name "example-repo" :apihost "api.github.com")))
    (oset repo default-branch "main")
    repo))

(ert-deftest prrr-queue-test-pr-from-forge ()
  "Forge supplies the PR; its meta row supplies the assignees."
  (let* ((pullreq (forge-pullreq :id "forge-1" :number 12 :title "Add parser" :state 'open
                                 :author "example-alice" :draft-p t :their-id "PR_12"
                                 :created "2026-09-01T00:00:00Z" :updated "2026-09-03T00:00:00Z"
                                 :head-rev "abc" :base-ref "main" :head-ref "parser"
                                 :cross-repo-p nil))
         (meta (prrr-pr-meta-create :pr-id "PR_12" :number 12 :assignees '("example-me")))
         (pr (prrr-queue-pr pullreq meta)))
    (should (equal "PR_12" (prrr-pr-id pr)))
    (should (= 12 (prrr-pr-number pr)))
    (should (equal "Add parser" (prrr-pr-title pr)))
    (should (equal "example-alice" (prrr-pr-author pr)))
    (should (eq t (prrr-pr-draft-p pr)))
    (should (equal '("example-me") (prrr-pr-assignees pr)))
    (should (equal "2026-09-01T00:00:00Z" (prrr-pr-created-at pr)))
    (should (equal "2026-09-03T00:00:00Z" (prrr-pr-updated-at pr)))
    (should (equal "abc" (prrr-pr-head-oid pr)))
    (should (equal "main" (prrr-pr-base-ref pr)))
    (should (equal "parser" (prrr-pr-head-ref pr)))
    (should (null (prrr-pr-cross-repo-p pr)))
    (should (null (prrr-pr-assignees (prrr-queue-pr pullreq))))))

(defun prrr-queue-test--forge-pullreq (number their-id state)
  "A `forge-pullreq' NUMBER with id THEIR-ID in STATE, every read slot bound."
  (forge-pullreq :id (format "forge-%d" number) :number number :their-id their-id
                 :state state :title (format "Change %d" number) :author "example-alice"
                 :draft-p nil :created "2026-09-01T00:00:00Z" :updated "2026-09-02T00:00:00Z"
                 :head-rev prrr-test-head :base-ref "main"
                 :head-ref (format "change-%d" number) :cross-repo-p nil))

(ert-deftest prrr-queue-test-inputs-tolerate-forge-and-meta-drift ()
  "Review Focus 4: the queue's PRs are the open forge PRs with a prrr meta row.
Each meta row is looked up in forge by number; a row whose PR forge
closed or does not know is dropped.  A forge PR without a meta row is
not shown until the next prrr pull stores one, so forge is never asked
for the repository's whole history."
  (prrr-db-with-test-db
    (dolist (meta (list (prrr-test-meta :pr-id "CLOSED-IN-FORGE" :number 3)
                        (prrr-test-meta :pr-id "UNKNOWN-TO-FORGE" :number 4)
                        (prrr-test-meta :pr-id "OPEN" :number 5
                                        :assignees '("example-me"))))
      (prrr-db-insert meta))
    (let* ((forge (list (cons 3 (prrr-queue-test--forge-pullreq 3 "CLOSED-IN-FORGE" 'merged))
                        (cons 5 (prrr-queue-test--forge-pullreq 5 "OPEN" 'open))
                        (cons 6 (prrr-queue-test--forge-pullreq 6 "NOT-PULLED-YET" 'open))))
           (asked nil)
           (prrr-github-user "example-me"))
      (cl-letf (((symbol-function 'forge-get-pullreq)
                 (lambda (_repo number) (push number asked) (alist-get number forge))))
        (let ((inputs (prrr-queue--inputs (prrr-queue-test--repo))))
          (should (equal '(3 4 5) (sort asked #'<)))
          (should (equal '("OPEN") (mapcar (lambda (pair) (prrr-pr-id (cdr pair)))
                                           (plist-get inputs :pairs))))
          (prrr-queue-test--with-render inputs
            (should (string-match-p "assigned" (prrr-queue-test--line-of 5)))
            (goto-char (point-min))
            (should-not (re-search-forward "^#6 " nil t))))))))

(ert-deftest prrr-queue-test-inputs-apply-queued-withdraws ()
  "SPEC section 7: a queued Withdraw shows at once, before GitHub has it."
  (prrr-db-with-test-db
    (prrr-db-insert (prrr-test-meta :pr-id "OPEN" :number 5
                                    :review-requests '((user "example-me"))
                                    :assignees '("example-me")))
    (prrr-db-insert (prrr-outbox-create :id "1" :pr-id "OPEN" :kind 'withdraw
                                        :payload '(:target (:me "example-me")
                                                   :review-request t :assignee t)
                                        :created-at "2026-10-10T12:00:00Z" :attempts 0))
    (let ((prrr-github-user "example-me"))
      (cl-letf (((symbol-function 'forge-get-pullreq)
                 (lambda (_repo number)
                   (and (= number 5) (prrr-queue-test--forge-pullreq 5 "OPEN" 'open)))))
        (let* ((inputs (prrr-queue--inputs (prrr-queue-test--repo)))
               (pr (cdr (car (plist-get inputs :pairs)))))
          (should-not (prrr-pr-assignees pr))
          (should-not (prrr-pr-meta-review-requests (car (plist-get inputs :metas))))
          (prrr-queue-test--with-render inputs
            (should-not (re-search-forward "^#5 .*\\(requested\\|assigned\\)" nil t))))))))

(defmacro prrr-queue-test--with-hook-env (repo &rest body)
  "Run BODY with forge's repository lookup answering REPO."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'forge-db) (lambda (&rest _) t))
             ((symbol-function 'forge-get-repository) (lambda (&rest _) ,repo)))
     ,@body))

(defun prrr-queue-test--hook-output ()
  "Run the section hook function in a magit-section buffer; return the text."
  (with-temp-buffer
    (magit-section-mode)
    (let ((inhibit-read-only t))
      (magit-insert-section (status)
        (prrr-queue-insert-section)))
    (buffer-string)))

(ert-deftest prrr-queue-test-hook-inserts-nothing-outside-github ()
  (prrr-queue-test--with-hook-env nil
    (should (equal "" (prrr-queue-test--hook-output)))))

(ert-deftest prrr-queue-test-hook-error-becomes-a-line ()
  "Review Focus 2: the status buffer survives any error in the queue."
  (prrr-queue-test--with-hook-env (prrr-queue-test--repo)
    (cl-letf (((symbol-function 'prrr-queue--inputs)
               (lambda (_) (error "Database is locked"))))
      (let ((text (prrr-queue-test--hook-output)))
        (should (string-match-p "Review Queue (error: Database is locked)" text))))))

(ert-deftest prrr-queue-test-hook-error-while-inserting-leaves-no-stray-text ()
  "Review Focus 2 (M1): an error part-way through the rows removes what was inserted."
  (prrr-queue-test--with-hook-env (prrr-queue-test--repo)
    (cl-letf (((symbol-function 'prrr-queue--inputs)
               (lambda (_)
                 (prrr-queue-test--inputs
                  (list (prrr-queue-test--pair :id "A" :number 1))
                  (list (prrr-test-meta :pr-id "A" :review-requests '((user "example-me")))))))
              ((symbol-function 'prrr-sync-queue-due-p) #'ignore)
              ((symbol-function 'prrr-queue--line) (lambda (&rest _) (error "Boom"))))
      (with-temp-buffer
        (magit-section-mode)
        (let ((inhibit-read-only t))
          (magit-insert-section (status)
            (prrr-queue-insert-section)))
        (should (equal "Review Queue (error: Boom)\n\n" (buffer-string)))
        (should (null prrr-queue--rows))))))

(ert-deftest prrr-queue-test-hook-starts-due-pull ()
  (prrr-queue-test--with-hook-env (prrr-queue-test--repo)
    (let ((pulled nil))
      (cl-letf (((symbol-function 'prrr-queue--inputs)
                 (lambda (_) (prrr-queue-test--inputs nil nil)))
                ((symbol-function 'prrr-sync-queue-due-p) (lambda (&rest _) t))
                ((symbol-function 'prrr-sync-pull)
                 (lambda (repo buffer) (setq pulled (list (oref repo id) (bufferp buffer)))))
                ((symbol-function 'prrr-sync-status) (lambda (_) '(:state pulling))))
        (let ((text (prrr-queue-test--hook-output)))
          (should (equal '("example-repo-id" t) pulled))
          (should (string-match-p "Review Queue (pulling" text)))))))

(ert-deftest prrr-queue-test-hook-does-not-pull-when-fresh ()
  (prrr-queue-test--with-hook-env (prrr-queue-test--repo)
    (cl-letf (((symbol-function 'prrr-queue--inputs) (lambda (_) (prrr-queue-test--inputs nil nil)))
              ((symbol-function 'prrr-sync-queue-due-p) (lambda (&rest _) nil))
              ((symbol-function 'prrr-sync-pull) (lambda (&rest _) (ert-fail "pulled"))))
      (prrr-queue-test--hook-output))))

(ert-deftest prrr-queue-test-preserved-outbox-announced-once ()
  "The consumer (prrr-knu.4) shows the kept rows and clears them."
  (let ((prrr-db-preserved-outbox (list (prrr-outbox-create :id "o1" :pr-id "PR_1" :kind 'comment)))
        (warnings nil))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (type message &rest _) (push (cons type message) warnings))))
      (prrr-queue--announce-preserved-outbox)
      (prrr-queue--announce-preserved-outbox))
    (should (= 1 (length warnings)))
    (should (eq 'prrr (caar warnings)))
    (should (string-match-p "1 unsent write" (cdar warnings)))
    (should (null prrr-db-preserved-outbox))))

(ert-deftest prrr-queue-test-mode-places-section-before-forge-pullreqs ()
  (let ((magit-status-sections-hook (list #'magit-insert-status-headers #'forge-insert-pullreqs)))
    (unwind-protect
        (progn
          (prrr-queue-mode 1)
          (should (equal (list #'magit-insert-status-headers #'prrr-queue-insert-section
                               #'forge-insert-pullreqs)
                         magit-status-sections-hook))
          (prrr-queue-mode -1)
          (should-not (memq #'prrr-queue-insert-section magit-status-sections-hook)))
      (prrr-queue-mode -1))))

;;;; Keys, Stack moves and the menu

(require 'prrr-stack)
(require 'prrr-transient)

(defun prrr-queue-test--stack-inputs ()
  "Inputs with a three-PR Stack in For Me and a lone PR."
  (prrr-queue-test--inputs
   (list (prrr-queue-test--pair :id "ONE" :number 1 :head-ref "s1")
         (prrr-queue-test--pair :id "TWO" :number 2 :base-ref "s1" :head-ref "s2")
         (prrr-queue-test--pair :id "THREE" :number 3 :base-ref "s2" :head-ref "s3")
         (prrr-queue-test--pair :id "LONE" :number 4 :head-ref "lone"))
   (mapcar (lambda (id) (prrr-test-meta :pr-id id :review-requests '((user "example-me"))))
           '("ONE" "TWO" "THREE" "LONE"))))

(ert-deftest prrr-queue-test-stack-up-and-down-move-between-rows ()
  (prrr-queue-test--with-render (prrr-queue-test--stack-inputs)
    (prrr-queue-test--line-of 1)
    (prrr-stack-up)
    (should (looking-at "#2 "))
    (prrr-stack-up)
    (should (looking-at "#3 "))
    (should-error (prrr-stack-up) :type 'user-error)
    (prrr-stack-down)
    (should (looking-at "#2 "))))

(ert-deftest prrr-queue-test-stack-move-outside-a-row-signals ()
  (prrr-queue-test--with-render (prrr-queue-test--stack-inputs)
    (should-error (prrr-stack-up) :type 'user-error)))

(ert-deftest prrr-queue-test-lone-pr-has-no-stack-neighbour ()
  (prrr-queue-test--with-render (prrr-queue-test--stack-inputs)
    (prrr-queue-test--line-of 4)
    (should-error (prrr-stack-down) :type 'user-error)))

(defun prrr-queue-test--menu-command (key)
  "Return the command bound to KEY in `prrr-queue-menu'."
  (let ((suffix (transient-get-suffix 'prrr-queue-menu key)))
    (plist-get (if (vectorp suffix) (aref suffix 2) (cdr suffix)) :command)))

(ert-deftest prrr-queue-test-row-keeps-forge-keys ()
  "M2: a row is a forge pullreq section, so forge's own keys still work there.
prrr's keys win where both bind a key."
  (dolist (key '("C-c C-c" "C-<return>"))
    (should (keymap-lookup forge-pullreq-section-map key))
    (should (eq (keymap-lookup forge-pullreq-section-map key)
                (keymap-lookup prrr-queue-row-map key))))
  (should (eq 'prrr-review (keymap-lookup prrr-queue-row-map "RET"))))

(ert-deftest prrr-queue-test-menu-mirrors-row-keys ()
  "SPEC section 9: every row key has the same key and command in the menu."
  (dolist (key '("RET" "o" "b" "B" ">" "<" "G"))
    (should (prrr-queue-test--menu-command key))
    (should (eq (keymap-lookup prrr-queue-section-map key)
                (prrr-queue-test--menu-command key)))
    (should (eq (keymap-lookup prrr-queue-row-map key)
                (prrr-queue-test--menu-command key))))
  (should (eq 'prrr-queue-menu (keymap-lookup prrr-queue-section-map "C-o")))
  (should (eq 'prrr-queue-menu (keymap-lookup prrr-queue-heading-map "C-o")))
  (should (eq 'prrr-pull (keymap-lookup prrr-queue-heading-map "G"))))

(ert-deftest prrr-queue-test-menu-toggles ()
  (should (eq 'prrr-queue-toggle-drafts (prrr-queue-test--menu-command "-d")))
  (should (eq 'prrr-queue-toggle-served (prrr-queue-test--menu-command "-s")))
  (let ((prrr-queue-show-served t))
    (cl-letf (((symbol-function 'magit-refresh) #'ignore))
      (call-interactively #'prrr-queue-toggle-served))
    (should-not prrr-queue-show-served)))

(ert-deftest prrr-queue-test-refresh-for-write ()
  "A queued or landed Submit or Withdraw refreshes the buffers listing the PR (prrr-45r)."
  (prrr-test-with-outbox
    (prrr-queue-test--with-render (prrr-queue-test--inputs
                                   (list (prrr-queue-test--pair :id "A" :number 1
                                                                :assignees (list prrr-test-me)))
                                   nil)
      (let ((listing (current-buffer)))
        (with-temp-buffer
          (prrr-queue--refresh-for-write "A" 'submit)
          (prrr-queue--refresh-for-write "A" 'withdraw)
          (prrr-queue--refresh-for-write "B" 'submit)
          (prrr-queue--refresh-for-write "A" 'thread)
          (should (equal (list (list listing) (list listing))
                         (mapcar #'cl-third prrr-test-timers))))))))

(ert-deftest prrr-queue-test-muted-rows ()
  "A muted PR leaves the queue and its count; `-m' shows it dimmed as muted (prrr-6cl)."
  (let ((inputs (prrr-queue-test--inputs
                 (list (prrr-queue-test--pair :id "A" :number 1 :assignees (list prrr-test-me))
                       (prrr-queue-test--pair :id "B" :number 2 :assignees (list prrr-test-me)))
                 nil)))
    (let ((prrr-queue-show-muted nil))
      (prrr-queue-test--with-render (append (list :muted '("B")) inputs)
        (should (string-match-p "For me (1)" (buffer-string)))
        (should-not (string-match-p "^#2 " (buffer-string)))))
    (let ((prrr-queue-show-muted t))
      (prrr-queue-test--with-render (append (list :muted '("B")) inputs)
        (should (string-match-p "For me (1)" (buffer-string)))
        (should (string-match-p "^#2  muted " (prrr-queue-test--line-of 2)))
        (should (eq 'prrr-queue-dimmed
                    (get-text-property (line-beginning-position) 'font-lock-face)))))))

(ert-deftest prrr-queue-test-mute-toggles-the-row ()
  "M mutes the PR at point, M again unmutes it; the listing buffers redraw (prrr-6cl)."
  (prrr-db-with-test-db
    (prrr-test-with-outbox
      (prrr-queue-test--with-render (prrr-queue-test--inputs
                                     (list (prrr-queue-test--pair :id "A" :number 1
                                                                  :assignees (list prrr-test-me)))
                                     nil)
        (prrr-queue-test--line-of 1)
        (call-interactively #'prrr-mute)
        (should (prrr-db-get 'mute "A"))
        (should (equal (list (list (current-buffer))) (mapcar #'cl-third prrr-test-timers)))
        (call-interactively #'prrr-mute)
        (should-not (prrr-db-get 'mute "A"))))))

(ert-deftest prrr-queue-test-mute-keys ()
  "M on a row and in both menus; `-m' toggles showing muted rows."
  (should (eq 'prrr-mute (keymap-lookup prrr-queue-section-map "M")))
  (should (eq 'prrr-mute (prrr-queue-test--menu-command "M")))
  (should (eq 'prrr-queue-toggle-muted (prrr-queue-test--menu-command "-m")))
  (should (eq 'prrr-mute (alist-get "M" prrr-diff--review-keys nil nil #'equal)))
  (let ((prrr-queue-show-muted nil))
    (cl-letf (((symbol-function 'magit-refresh) #'ignore))
      (call-interactively #'prrr-queue-toggle-muted))
    (should prrr-queue-show-muted)))

(provide 'prrr-queue-test)
;;; prrr-queue-test.el ends here
