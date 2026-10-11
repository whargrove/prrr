;;; prrr-range-test.el --- Tests for prrr-range  -*- lexical-binding: t -*-

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

;; Ranges in the fixture repository of test/fixtures/make-repo.sh,
;; whose PR has two commits: "first" makes every change but line
;; 30's, the head rewrites line 30.  No network.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'prrr-test-helper)
(require 'prrr-diff-test)
(require 'prrr-range)
(require 'prrr-transient)

(defun prrr-range-test--line ()
  "Return the text of the line at point."
  (buffer-substring-no-properties (line-beginning-position) (line-end-position)))

(defun prrr-range-test--commit-range (from to)
  "Return the `commit' Range from the revision FROM to TO."
  (prrr-range-create :kind 'commit :start (prrr-diff-test--rev from)
                     :end (prrr-diff-test--rev to)))

(defun prrr-range-test--push (message change)
  "Commit what the function CHANGE does on top of the PR's head; make it the head.
MESSAGE is the commit's message.  The commit before it stays as the
branch feature's parent."
  (call-process "git" nil nil nil "checkout" "-q" "feature")
  (funcall change)
  (call-process "git" nil nil nil "-c" "user.name=example" "-c" "user.email=example@example.com"
                "commit" "-q" "-a" "-m" message)
  (call-process "git" nil nil nil "update-ref" "refs/pullreqs/1" "HEAD"))

(defun prrr-range-test--rewrite (path from to)
  "Replace the line FROM of PATH with TO."
  (with-temp-file path
    (insert-file-contents path)
    (re-search-forward (concat "^" (regexp-quote from) "$"))
    (replace-match to t t)))

;;;; Positions

(ert-deftest prrr-range-test-position ()
  (prrr-diff-test--with-buffer nil
    (pcase-let ((`(,start . ,end) (prrr-diff-ends)))
      (prrr-diff-test--goto-line "src/example.el" "+line thirty")
      (should (equal (list "src/example.el" 'right 30 end "src/example.el") (prrr-diff-position)))
      (prrr-diff-test--goto-line "src/example.el" "-line 30")
      (should (equal (list "src/example.el" 'left 30 start "src/example.el") (prrr-diff-position)))
      (goto-char (oref (prrr-diff-test--file-section "src/example.el") start))
      (should (equal '("src/example.el" nil nil nil nil) (prrr-diff-position)))
      (goto-char (point-min))
      (should-not (prrr-diff-position)))))

(ert-deftest prrr-range-test-position-on-no-newline ()
  "A \"\\ No newline at end of file\" line is no line of either side."
  (prrr-diff-test--with-buffer
      (prrr-range-test--push "no newline"
                             (lambda ()
                               (with-temp-file "src/example.el"
                                 (insert-file-contents "src/example.el")
                                 (goto-char (point-max))
                                 (delete-char -1))))
    (prrr-diff-test--goto-line "src/example.el" "\\ No newline at end of file")
    (should (equal '("src/example.el" nil nil nil nil) (prrr-diff-position)))))

(ert-deftest prrr-range-test-position-of-a-renamed-file ()
  "The left side of a renamed file names the line in the file's old path."
  (prrr-diff-test--with-buffer
      (prrr-range-test--push "five"
                             (lambda () (prrr-range-test--rewrite "src/moved-to.el" "moved 5" "moved five")))
    (prrr-diff-test--goto-line "src/moved-to.el" "-moved 5")
    (should (equal (list "src/moved-to.el" 'left 5 (car (prrr-diff-ends)) "src/moved-from.el")
                   (prrr-diff-position)))))

(ert-deftest prrr-range-test-goto-line ()
  (let ((prrr-eager-files 0))
    (prrr-diff-test--with-buffer nil
      (should (prrr-diff-goto-line "src/example.el" 'right 13))
      (should (equal " line 13" (prrr-range-test--line)))
      (should (prrr-diff-goto-line "src/example.el" 'left 30))
      (should (equal "-line 30" (prrr-range-test--line)))
      (should (prrr-diff-goto-line "src/example.el" 'right 30))
      (should (equal "+line thirty" (prrr-range-test--line)))
      (let ((here (point)))
        (should-not (prrr-diff-goto-line "src/example.el" 'right 20))
        (should-not (prrr-diff-goto-line "src/gone.el" 'right 1))
        (should (= here (point))))
      (should (prrr-diff-goto-line "README.md" nil nil))
      (should (looking-at "modified +README\\.md")))))

;;;; Switching

(ert-deftest prrr-range-test-goto-default-from-since-review ()
  "SPEC section 8: `.' shows the default Range at the same line."
  (prrr-diff-test--with-buffer nil
    (prrr-diff-show-range (prrr-range-create :kind 'since-review
                                             :start (prrr-diff-test--rev "refs/pullreqs/1~1")))
    (prrr-diff-test--goto-line "src/example.el" "+line thirty")
    (prrr-goto-default-range)
    (should (eq 'default (prrr-range-kind prrr-diff--range)))
    (should (equal '("README.md" "data.bin" "docs/notes.md" "src/example.el"
                     "src/moved-to.el" "src/old.el")
                   (prrr-diff-test--files)))
    (should (equal "+line thirty" (prrr-range-test--line)))))

(ert-deftest prrr-range-test-goto-default-maps-the-line ()
  "Review Focus 4: a line of an older commit is found again at the head."
  (prrr-diff-test--with-buffer nil
    (prrr-diff-show-range (prrr-range-test--commit-range "refs/pullreqs/1~2"
                                                         "refs/pullreqs/1~1"))
    (prrr-diff-test--goto-line "src/example.el" "+line twelve")
    (prrr-goto-default-range)
    (should (equal "+line twelve" (prrr-range-test--line)))))

(ert-deftest prrr-range-test-switch-keeps-a-left-line ()
  "A removed line the new Range also removes is found on its left side."
  (prrr-diff-test--with-buffer nil
    (prrr-diff-test--goto-line "src/example.el" "-line 30")
    (prrr-range--switch (prrr-range-test--commit-range "refs/pullreqs/1~1" "refs/pullreqs/1"))
    (should (equal "-line 30" (prrr-range-test--line)))))

(ert-deftest prrr-range-test-switch-keeps-a-left-line-of-a-renamed-file ()
  "A removed line of a renamed file is mapped from its old path."
  (prrr-diff-test--with-buffer
      (prrr-range-test--push "five"
                             (lambda () (prrr-range-test--rewrite "src/moved-to.el" "moved 5" "moved five")))
    (prrr-diff-test--goto-line "src/moved-to.el" "-moved 5")
    (prrr-range--switch (prrr-range-test--commit-range "refs/pullreqs/1~1" "refs/pullreqs/1"))
    (should (equal "-moved 5" (prrr-range-test--line)))))

(ert-deftest prrr-range-test-switch-outside-a-review-buffer ()
  (with-temp-buffer
    (should-error (prrr-range--switch (prrr-range-create :kind 'default)) :type 'user-error)
    (should-not (local-variable-p 'prrr-range--fetching))))

(ert-deftest prrr-range-test-switch-to-a-range-without-the-line ()
  "Review Focus 4: a line the new Range does not show leaves point on its file."
  (prrr-diff-test--with-buffer nil
    (prrr-diff-test--goto-line "src/example.el" " line 13")
    (prrr-range--switch (prrr-range-test--commit-range "refs/pullreqs/1~1" "refs/pullreqs/1"))
    (should (looking-at "modified +src/example\\.el"))))

(ert-deftest prrr-range-test-switch-to-a-range-without-the-file ()
  (prrr-diff-test--with-buffer nil
    (prrr-diff-test--goto-line "README.md" "+Better title")
    (prrr-range--switch (prrr-range-test--commit-range "refs/pullreqs/1~1" "refs/pullreqs/1"))
    (should (equal '("src/example.el") (prrr-diff-test--files)))))

;;;; Choosing a Range

(defun prrr-range-test--store-review (oid)
  "Store a meta row of the fixture PR whose viewer's latest review is on OID."
  (prrr-db-insert (prrr-test-meta :pr-id prrr-diff-test--pr
                                  :viewer-latest-review
                                  (list "COMMENTED" "2026-09-02T00:00:00Z" oid))))

(defun prrr-range-test--choose (label)
  "Return a `completing-read' stand-in that picks the choice starting with LABEL."
  (lambda (_prompt table &rest _)
    (or (seq-find (lambda (choice) (string-prefix-p label choice))
                  (all-completions "" table))
        (ert-fail (list "no choice" label)))))

(defun prrr-range-test--remote-commit ()
  "Make a commit only the remote origin has; return its oid.
origin is a clone of the fixture repository with one more commit.  It
lives inside the fixture's .git, so it goes when the fixture goes."
  (let ((remote (expand-file-name ".git/prrr-remote")))
    (call-process "git" nil nil nil "clone" "-q" "--no-local" "." remote)
    (let ((default-directory (file-name-as-directory remote)))
      (call-process "git" nil nil nil "checkout" "-q" "-b" "extra")
      (with-temp-file "extra"
        (insert "extra\n"))
      (call-process "git" nil nil nil "add" "extra")
      (call-process "git" nil nil nil "-c" "user.name=example" "-c" "user.email=example@example.com"
                    "commit" "-q" "-m" "extra"))
    (call-process "git" nil nil nil "remote" "add" "origin" remote)
    (car (process-lines "git" "-C" remote "rev-parse" "extra"))))

(defmacro prrr-range-test--with-remote (&rest body)
  "Run BODY with forge's repository of the fixture PR on the remote origin."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'forge-get-repository)
              (lambda (&rest _) (forge-github-repository :id "r" :owner "example-org"
                                                         :name "example-repo" :remote "origin"))))
     ,@body))

(defun prrr-range-test--wait-for-fetch ()
  "Wait until the Review Buffer's fetch ended, at most ten seconds."
  (with-timeout (10 (ert-fail "the fetch did not end"))
    (while prrr-range--fetching
      (accept-process-output nil 0.05))))

(ert-deftest prrr-range-test-since-review ()
  (prrr-diff-test--with-buffer nil
    (let ((first (prrr-diff-test--rev "refs/pullreqs/1~1")))
      (prrr-range-test--store-review first)
      (prrr-show-since-review)
      (should (equal (prrr-range-create :kind 'since-review :start first) prrr-diff--range))
      (should (equal '("src/example.el") (prrr-diff-test--files)))
      ;; The review's commit is pinned against a force-push.
      (should (equal (list first)
                     (process-lines "git" "rev-parse" (format "refs/prrr/1/%s" first)))))))

(ert-deftest prrr-range-test-since-review-without-a-review ()
  (prrr-diff-test--with-buffer nil
    (should-error (prrr-show-since-review) :type 'user-error)
    (should (eq 'default (prrr-range-kind prrr-diff--range)))))

(ert-deftest prrr-range-test-since-review-at-the-head ()
  "Review Focus 4: nothing new since the review is an empty diff, not an error."
  (prrr-diff-test--with-buffer nil
    (prrr-range-test--store-review (prrr-diff-head))
    (prrr-show-since-review)
    (should (eq 'since-review (prrr-range-kind prrr-diff--range)))
    (should-not (prrr-diff-test--files))
    (should (string-match-p "^    No changes$" (buffer-string)))))

(ert-deftest prrr-range-test-since-opened ()
  (prrr-diff-test--with-buffer nil
    ;; The message names the key the buffer binds to `prrr-mark-seen'.
    (goto-char (point-min))
    (use-local-map (define-keymap "M" #'prrr-mark-seen))
    (unwind-protect
        (should (string-suffix-p "and with M" (cadr (should-error (prrr-show-since-opened)
                                                                  :type 'user-error))))
      (use-local-map prrr-diff-mode-map))
    (prrr-db-insert (prrr-bookmark-create :pr-id prrr-diff-test--pr
                                          :last-opened-head-oid
                                          (prrr-diff-test--rev "refs/pullreqs/1~1")))
    (prrr-show-since-opened)
    (should (eq 'since-opened (prrr-range-kind prrr-diff--range)))
    (should (equal '("src/example.el") (prrr-diff-test--files)))))

(ert-deftest prrr-range-test-since-review-fetches-a-missing-start ()
  "SPEC section 8: a start commit missing locally is fetched by sha."
  (prrr-diff-test--with-buffer nil
    (prrr-range-test--with-remote
      (let ((extra (prrr-range-test--remote-commit)))
        (prrr-range-test--store-review extra)
        (should-not (magit-commit-p extra))
        (prrr-show-since-review)
        (should (eq 'default (prrr-range-kind prrr-diff--range)))
        (prrr-range-test--wait-for-fetch)
        (should (equal (prrr-range-create :kind 'since-review :start extra) prrr-diff--range))
        (should (member "extra" (prrr-diff-test--files)))))))

(ert-deftest prrr-range-test-since-review-falls-back-to-default ()
  "SPEC section 8: a start that cannot be fetched leaves the default Range, and says so."
  (prrr-diff-test--with-buffer nil
    (prrr-range-test--with-remote
      (prrr-range-test--remote-commit)
      (prrr-range-test--store-review "2222222222222222222222222222222222222222")
      (let ((messages nil))
        (cl-letf (((symbol-function 'message)
                   (lambda (format &rest args)
                     (when format (push (apply #'format-message format args) messages)))))
          (prrr-show-since-review)
          (prrr-range-test--wait-for-fetch))
        (should (eq 'default (prrr-range-kind prrr-diff--range)))
        (should (member "Could not fetch 2222222, so this is the default Range" messages))))))

(defmacro prrr-range-test--noting-callbacks (var &rest body)
  "Run BODY with VAR set to non-nil once a fetch's callback has returned.
The callback of `prrr-range--fetch' signalling leaves VAR nil."
  (declare (indent 1))
  (let ((fetch (make-symbol "fetch")))
    `(let ((,var nil)
           (,fetch (symbol-function 'prrr-range--fetch)))
       (cl-letf (((symbol-function 'prrr-range--fetch)
                  (lambda (&rest args)
                    (let ((callback (car (last args))))
                      (apply ,fetch (append (butlast args)
                                            (list (lambda (fetched)
                                                    (funcall callback fetched)
                                                    (setq ,var t)))))))))
         ,@body))))

(defun prrr-range-test--wait-for (predicate)
  "Wait until PREDICATE returns non-nil, at most ten seconds."
  (with-timeout (10 (ert-fail "waited ten seconds"))
    (while (not (funcall predicate))
      (accept-process-output nil 0.05))))

(ert-deftest prrr-range-test-overtaken-fetch-changes-nothing ()
  "A fetch that ends after another Range was chosen keeps that Range."
  (prrr-diff-test--with-buffer nil
    (prrr-range-test--with-remote
      (let ((extra (prrr-range-test--remote-commit)))
        (prrr-range-test--store-review extra)
        (prrr-range-test--noting-callbacks ended
          (prrr-show-since-review)
          (prrr-show-commit (prrr-diff-test--rev "refs/pullreqs/1"))
          (prrr-range-test--wait-for (lambda () ended)))
        (should (magit-commit-p extra))
        (should (eq 'commit (prrr-range-kind prrr-diff--range)))))))

(ert-deftest prrr-range-test-fetch-outlives-its-buffer ()
  "A fetch that ends after its Review Buffer was killed does nothing."
  (prrr-diff-test--with-buffer nil
    (prrr-range-test--with-remote
      (prrr-range-test--store-review (prrr-range-test--remote-commit))
      (prrr-range-test--noting-callbacks ended
        (prrr-show-since-review)
        (kill-buffer (current-buffer))
        (prrr-range-test--wait-for (lambda () ended))))))

(ert-deftest prrr-range-test-fetch-ends-when-magit-sentinel-fails ()
  "An error in magit's sentinel does not leave the fetch pending.
The sentinel is called here, not by Emacs: in batch mode an error in a
process sentinel kills Emacs."
  (let ((process (make-process :name "prrr-test" :command '("true") :noquery t
                               :sentinel #'ignore))
        (fetched 'never))
    (while (process-live-p process)
      (accept-process-output process 0.05))
    (cl-letf (((symbol-function 'magit-process-sentinel)
               (lambda (&rest _) (error "Example failure"))))
      (should-error (funcall (prrr-range--fetch-sentinel (lambda (ok) (setq fetched ok)))
                             process "finished\n")))
    (should (eq t fetched))))

(ert-deftest prrr-range-test-fetch-asks-forge-once ()
  "Starting the fetch of a missing start looks the PR's repository up once.
forge's own lookups, as when magit's process buffer is set up, do not count."
  (prrr-diff-test--with-buffer nil
    (prrr-range-test--with-remote
      (prrr-range-test--store-review (prrr-range-test--remote-commit))
      (let ((calls 0)
            (lookup (symbol-function 'forge-get-repository)))
        (unwind-protect
            (cl-letf (((symbol-function 'forge-get-repository)
                       (lambda (&rest args)
                         (when (cl-typep (car args) 'forge-pullreq)
                           (cl-incf calls))
                         (apply lookup args))))
              (prrr-show-since-review))
          ;; The fetch must end before the fixture repository goes.
          (prrr-range-test--wait-for-fetch))
        (should (= 1 calls))))))

(ert-deftest prrr-range-test-commit ()
  (prrr-diff-test--with-buffer nil
    (let ((head (prrr-diff-test--rev "refs/pullreqs/1"))
          (first (prrr-diff-test--rev "refs/pullreqs/1~1")))
      (should (equal (list (cons first "first") (cons head "head"))
                     (prrr-range--commits (prrr-diff-merge-base))))
      (cl-letf (((symbol-function 'completing-read)
                 (prrr-range-test--choose (substring head 0 7))))
        (call-interactively #'prrr-show-commit))
      (should (equal (prrr-range-create :kind 'commit :start first :end head) prrr-diff--range))
      (should (equal '("src/example.el") (prrr-diff-test--files))))))

(ert-deftest prrr-range-test-between ()
  (prrr-diff-test--with-buffer nil
    (let ((base (prrr-diff-merge-base))
          (first (prrr-diff-test--rev "refs/pullreqs/1~1"))
          (prompts nil)
          (merge-bases 0)
          (merge-base (symbol-function 'prrr-diff-merge-base)))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt table &rest _)
                   (push (cons prompt (all-completions "" table)) prompts)
                   (car (all-completions "" table))))
                ((symbol-function 'prrr-diff-merge-base)
                 (lambda () (cl-incf merge-bases) (funcall merge-base))))
        (call-interactively #'prrr-show-between))
      (should (equal (prrr-range-create :kind 'between :start base :end first) prrr-diff--range))
      ;; The merge base is found once.
      (should (= 1 merge-bases))
      ;; From offers the merge base and every commit but the last; To the commits after From.
      (should (equal '(2 2) (mapcar (lambda (prompt) (length (cdr prompt))) prompts)))
      (should (string-match-p "(merge base)" (car (cdr (cadr prompts)))))
      (should (member "README.md" (prrr-diff-test--files)))
      (should-not (string-match-p "+line thirty" (buffer-string))))))

(ert-deftest prrr-range-test-empty-choice ()
  "An empty answer at a commit prompt chooses nothing and keeps the Range."
  (prrr-diff-test--with-buffer nil
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "")))
      (should (equal '(user-error "No commit chosen")
                     (should-error (call-interactively #'prrr-show-commit)
                                   :type 'user-error))))
    (let ((asked 0))
      ;; From is answered, To is left empty.
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _)
                   (if (= (cl-incf asked) 1) (car (all-completions "" table)) ""))))
        (should (equal '(user-error "No commit chosen")
                       (should-error (call-interactively #'prrr-show-between)
                                     :type 'user-error))))
      (should (= 2 asked)))
    (should (eq 'default (prrr-range-kind prrr-diff--range)))))

;;;; Bookmark

(defun prrr-range-test--bookmark ()
  "Return the head the fixture PR's Bookmark holds, or nil."
  (when-let* ((bookmark (prrr-db-get 'pr-bookmark prrr-diff-test--pr)))
    (prrr-bookmark-last-opened-head-oid bookmark)))

(ert-deftest prrr-range-test-bookmark-on-kill-not-on-open ()
  "SPEC section 8: the Bookmark is recorded when the visit ends, never on open."
  (prrr-diff-test--with-buffer nil
    (should-not (prrr-range-test--bookmark))
    (let ((head (prrr-diff-head))
          (repo default-directory))
      (kill-buffer (current-buffer))
      (should (equal head (prrr-range-test--bookmark)))
      (should (equal (list head) (process-lines "git" "-C" repo "rev-parse"
                                                (format "refs/prrr/1/%s" head)))))))

(ert-deftest prrr-range-test-kill-without-a-head ()
  "A Review Buffer that shows no head records no Bookmark when killed."
  (prrr-diff-test--with-buffer (call-process "git" nil nil nil "update-ref" "-d" "refs/pullreqs/1")
    (should-not (prrr-diff-head))
    (kill-buffer (current-buffer))
    (should-not (prrr-range-test--bookmark))))

(ert-deftest prrr-range-test-bookmark-on-quit ()
  (prrr-diff-test--with-buffer nil
    (let ((head (prrr-diff-head)))
      (quit-window nil (get-buffer-window (current-buffer)))
      (should (equal head (prrr-range-test--bookmark))))))

(ert-deftest prrr-range-test-bookmark-is-the-head-shown ()
  "Review Focus 1: the head the user saw, not the one forge fetched meanwhile."
  (prrr-diff-test--with-buffer nil
    (let ((head (prrr-diff-head)))
      (call-process "git" nil nil nil "update-ref" "refs/pullreqs/1"
                    (prrr-diff-test--rev "refs/pullreqs/1~1"))
      (magit-refresh-buffer)
      (kill-buffer (current-buffer))
      (should (equal head (prrr-range-test--bookmark))))))

(ert-deftest prrr-range-test-mark-seen ()
  (prrr-diff-test--with-buffer nil
    (prrr-mark-seen)
    (should (equal (prrr-diff-head) (prrr-range-test--bookmark)))))

(ert-deftest prrr-range-test-open-pins-the-review-commit ()
  "SPEC section 8: the commit of my latest review is pinned when the PR opens."
  (prrr-db-with-test-db
    (prrr-test-with-repo
      (prrr-diff-test--with-open-stubs
        (let ((first (prrr-diff-test--rev "refs/pullreqs/1~1"))
              (repo default-directory))
          (prrr-range-test--store-review first)
          (kill-buffer (prrr-diff-open (prrr-diff-test--pullreq)))
          (should (equal (list first) (process-lines "git" "-C" repo "rev-parse"
                                                     (format "refs/prrr/1/%s" first)))))))))

;;;; Keys

(ert-deftest prrr-range-test-keys-and-menus-agree ()
  "SPEC section 9: D opens the Range menu; . m > < are keys and in the main menu.
The keys are bound in the file and hunk section maps too, which win
over the mode's."
  (pcase-dolist (`(,key . ,command) '(("D" . prrr-range) ("." . prrr-goto-default-range)
                                      ("m" . prrr-mark-seen) (">" . prrr-stack-up)
                                      ("<" . prrr-stack-down)))
    (should (eq command (keymap-lookup prrr-diff-mode-map key)))
    (should (eq command (keymap-lookup prrr-diff-hunk-section-map key)))
    (should (eq command (keymap-lookup prrr-diff-file-section-map key)))
    (let ((suffix (transient-get-suffix 'prrr-menu key)))
      (should (eq command (plist-get (if (vectorp suffix) (aref suffix 2) (cdr suffix))
                                     :command)))))
  (pcase-dolist (`(,key . ,command) '(("d" . prrr-goto-default-range)
                                      ("r" . prrr-show-since-review)
                                      ("o" . prrr-show-since-opened)
                                      ("c" . prrr-show-commit)
                                      ("b" . prrr-show-between)))
    (let ((suffix (transient-get-suffix 'prrr-range key)))
      (should (eq command (plist-get (if (vectorp suffix) (aref suffix 2) (cdr suffix))
                                     :command))))))

(provide 'prrr-range-test)
;;; prrr-range-test.el ends here
