;;; prrr-diff-test.el --- Tests for prrr-diff  -*- lexical-binding: t -*-

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

;; The Review Buffer, rendered in batch from the fixture repository of
;; test/fixtures/make-repo.sh and review data stored in a temporary
;; database.  No network.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'prrr-test-helper)
(require 'prrr-diff)
(require 'prrr-github)

;;;; Changed files

(ert-deftest prrr-diff-test-parse-changes-kinds ()
  "Review Focus 2: every kind of change becomes one file with its status."
  (let ((files (prrr-diff-parse-changes
                (concat ":100644 100644 aaa bbb M\0a.el\0"
                        ":000000 100644 000 ccc A\0new.el\0"
                        ":100644 000000 ddd 000 D\0gone.el\0"
                        ":100644 100644 eee eee R100\0old/name.el\0new/name.el\0"
                        ":100644 100644 fff ggg M\0img.png\0"
                        "3\t1\ta.el\0"
                        "10\t0\tnew.el\0"
                        "0\t5\tgone.el\0"
                        "0\t0\t\0old/name.el\0new/name.el\0"
                        "-\t-\timg.png\0"))))
    (should (equal '("a.el" "new.el" "gone.el" "new/name.el" "img.png")
                   (mapcar #'prrr-diff-file-path files)))
    (should (equal '("modified" "new file" "deleted" "renamed" "modified")
                   (mapcar #'prrr-diff-file-status files)))
    (should (equal '(nil nil nil "old/name.el" nil) (mapcar #'prrr-diff-file-orig files)))
    (should (equal '(3 10 0 0 0) (mapcar #'prrr-diff-file-added files)))
    (should (equal '(1 0 5 0 0) (mapcar #'prrr-diff-file-deleted files)))
    (should (equal '(nil nil nil nil t) (mapcar #'prrr-diff-file-binary-p files)))))

(ert-deftest prrr-diff-test-parse-changes-empty ()
  (should-not (prrr-diff-parse-changes "")))

(ert-deftest prrr-diff-test-parse-changes-tab-in-name ()
  "A path may hold a tab; the count fields never do."
  (let ((file (car (prrr-diff-parse-changes
                    (concat ":100644 100644 aaa bbb M\0odd\tname\0"
                            "1\t0\todd\tname\0")))))
    (should (equal "odd\tname" (prrr-diff-file-path file)))))

(ert-deftest prrr-diff-test-changes-from-git ()
  "The PR's files from its merge base; main's later CHANGELOG is not one."
  (prrr-test-with-repo
    (let* ((head (car (process-lines "git" "rev-parse" "refs/pullreqs/1")))
           (base (car (process-lines "git" "merge-base" "main" head)))
           (files (prrr-diff--changes base head)))
      (should (equal '("README.md" "data.bin" "docs/notes.md" "src/example.el"
                       "src/moved-to.el" "src/old.el")
                     (mapcar #'prrr-diff-file-path files)))
      (should (equal '("modified" "modified" "modified" "modified" "renamed" "deleted")
                     (mapcar #'prrr-diff-file-status files)))
      (should (equal "src/moved-from.el" (prrr-diff-file-orig (nth 4 files))))
      (should (prrr-diff-file-binary-p (nth 1 files))))))

(ert-deftest prrr-diff-test-merge-base ()
  (prrr-test-with-repo
    (let ((head (car (process-lines "git" "rev-parse" "refs/pullreqs/1")))
          (expected (car (process-lines "git" "rev-parse" "main~1"))))
      (should (equal expected
                     (prrr-diff--merge-base
                      (forge-pullreq :id "f" :number 1 :base-rev prrr-test-repo-base) head)))
      (should-not (prrr-diff--merge-base (forge-pullreq :id "f" :number 1 :base-rev nil) head))
      (should-not (prrr-diff--merge-base
                   (forge-pullreq :id "f" :number 1
                                  :base-rev "2222222222222222222222222222222222222222")
                   head)))))

;;;; Eager budget

(defun prrr-diff-test--file (path size)
  "A changed file PATH with SIZE added lines."
  (prrr-diff-file-create :path path :status "modified" :added size :deleted 0))

(ert-deftest prrr-diff-test-eager-stops-at-file-count ()
  (let ((prrr-eager-files 2) (prrr-eager-lines 1000))
    (should (equal '("b" "a")
                   (prrr-diff--eager-paths (list (prrr-diff-test--file "a" 1)
                                                 (prrr-diff-test--file "b" 1)
                                                 (prrr-diff-test--file "c" 1))
                                           nil)))))

(ert-deftest prrr-diff-test-eager-stops-at-first-file-over-lines ()
  "A huge file ends the run, so it never stalls the open."
  (let ((prrr-eager-files 10) (prrr-eager-lines 100))
    (should (equal '("a")
                   (prrr-diff--eager-paths (list (prrr-diff-test--file "a" 60)
                                                 (prrr-diff-test--file "b" 50)
                                                 (prrr-diff-test--file "c" 1))
                                           nil)))
    (should-not (prrr-diff--eager-paths (list (prrr-diff-test--file "huge" 20000)
                                              (prrr-diff-test--file "small" 1))
                                        nil))))

(ert-deftest prrr-diff-test-eager-skips-viewed ()
  (let ((prrr-eager-files 2) (prrr-eager-lines 1000))
    (should (equal '("c" "a")
                   (prrr-diff--eager-paths (list (prrr-diff-test--file "a" 1)
                                                 (prrr-diff-test--file "b" 1)
                                                 (prrr-diff-test--file "c" 1))
                                           '("b"))))))

;;;; Review Buffer

(defconst prrr-diff-test--pr "PR_kwDOexample0000001"
  "The PR of the review-data fixture.")

(defun prrr-diff-test--pullreq ()
  "The fixture repository's pull request, as forge would hold it."
  (forge-pullreq :id "forge-1" :number 1 :title "Example change" :their-id prrr-diff-test--pr
                 :base-rev prrr-test-repo-base :author "example-alice"
                 :created "2026-09-01T00:00:00Z" :body "Why this change."))

(defun prrr-diff-test--store-fixture ()
  "Store the review-data fixture for the fixture PR."
  (prrr-db-replace-review-data
   prrr-diff-test--pr
   (prrr-github-decode-review-data (prrr-test-fixture "review-data") prrr-diff-test--pr
                                   "2026-10-10T12:00:00Z")))

(defmacro prrr-diff-test--with-buffer (setup &rest body)
  "Open the fixture PR's Review Buffer and run BODY in it.
SETUP runs first, inside the fixture repository and a fresh database."
  (declare (indent 1))
  `(prrr-db-with-test-db
     (prrr-test-with-repo
       ,setup
       (let ((buffer (prrr-diff-setup-buffer (prrr-diff-test--pullreq))))
         (unwind-protect
             (with-current-buffer buffer ,@body)
           (kill-buffer buffer))))))

(defun prrr-diff-test--file-section (path)
  "Return the `file' section of PATH in the current Review Buffer."
  (magit-get-section `((file . ,path) (diffbuf))))

(defun prrr-diff-test--files ()
  "Return the paths of the `file' sections, in order."
  (mapcar (lambda (section) (oref section value))
          (seq-filter (lambda (section) (eq (oref section type) 'file))
                      (oref magit-root-section children))))

(defun prrr-diff-test--text (section)
  "Return SECTION's text without properties."
  (buffer-substring-no-properties (oref section start) (oref section end)))

(ert-deftest prrr-diff-test-files-from-merge-base ()
  (prrr-diff-test--with-buffer nil
    (should (eq 'prrr-diff-mode major-mode))
    (should (equal '("README.md" "data.bin" "docs/notes.md" "src/example.el"
                     "src/moved-to.el" "src/old.el")
                   (prrr-diff-test--files)))
    (should (equal (format "%s..%s"
                           (car (process-lines "git" "rev-parse" "main~1"))
                           (car (process-lines "git" "rev-parse" "refs/pullreqs/1")))
                   magit-buffer-diff-range))
    (should (eq 'committed magit-buffer-diff-type))))

(ert-deftest prrr-diff-test-eager-files-washed-others-deferred ()
  (let ((prrr-eager-files 2))
    (prrr-diff-test--with-buffer nil
      (let ((readme (prrr-diff-test--file-section "README.md"))
            (notes (prrr-diff-test--file-section "docs/notes.md")))
        (should-not (oref readme hidden))
        (should (eq 'hunk (oref (car (oref readme children)) type)))
        (should (oref notes hidden))
        (should (oref notes washer))
        (should-not (oref notes children))))))

(ert-deftest prrr-diff-test-lazy-file-washes-on-expand ()
  (let ((prrr-eager-files 0))
    (prrr-diff-test--with-buffer nil
      (let ((notes (prrr-diff-test--file-section "docs/notes.md")))
        (magit-section-show notes)
        (should-not (oref notes washer))
        (should (equal '(hunk) (mapcar (lambda (child) (oref child type))
                                       (oref notes children))))
        (should (string-match-p "^\\+A second note\\.$" (prrr-diff-test--text notes)))))))

(ert-deftest prrr-diff-test-bodies-without-hunks ()
  "Review Focus 2: binary files and pure renames get a one-line body."
  (let ((prrr-eager-files 100))
    (prrr-diff-test--with-buffer nil
      (let ((binary (prrr-diff-test--file-section "data.bin"))
            (moved (prrr-diff-test--file-section "src/moved-to.el"))
            (old (prrr-diff-test--file-section "src/old.el")))
        (should (string-match-p "^    Binary file, not shown$" (prrr-diff-test--text binary)))
        (should (string-match-p "^renamed +src/moved-from\\.el -> src/moved-to\\.el"
                                (prrr-diff-test--text moved)))
        (should (string-match-p "^    No changed lines$" (prrr-diff-test--text moved)))
        (should (string-match-p "^deleted +src/old\\.el" (prrr-diff-test--text old)))
        (should (eq 'hunk (oref (car (oref old children)) type)))
        (dolist (section (list binary moved old))
          (should-not (seq-find (lambda (child) (eq (oref child type) 'file))
                                (oref section children))))))))

(ert-deftest prrr-diff-test-viewed-file-folded-and-marked ()
  (let ((prrr-eager-files 100))
    (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
      (let ((example (prrr-diff-test--file-section "src/example.el"))
            (readme (prrr-diff-test--file-section "README.md")))
        (should (oref example hidden))
        (should (string-match-p "✓ viewed" (prrr-diff-test--text example)))
        ;; DISMISSED means the file changed since it was viewed: not folded.
        (should-not (oref readme hidden))
        (should-not (string-match-p "viewed" (prrr-diff-test--text readme)))))))

(ert-deftest prrr-diff-test-positions-after-lazy-wash ()
  "Review Focus 3: expanding a file keeps every later section's positions right."
  (let ((prrr-eager-files 0))
    (prrr-diff-test--with-buffer nil
      (magit-section-show (prrr-diff-test--file-section "docs/notes.md"))
      (magit-map-sections
       (lambda (section)
         (let ((content (oref section content)))
           (when content
             (should (markerp content))
             (should (<= (oref section start) content (oref section end)))))))
      (let ((old (prrr-diff-test--file-section "src/old.el")))
        (magit-section-show old)
        (magit-section-hide old)
        (goto-char (oref old start))
        (should (looking-at "deleted +src/old\\.el"))
        (should (invisible-p (oref old content)))
        (should-not (invisible-p (oref old start)))))))

(ert-deftest prrr-diff-test-missing-base-note ()
  "Review Focus 1: no base commit renders a note instead of files."
  (prrr-db-with-test-db
    (prrr-test-with-repo
      (let ((buffer (prrr-diff-setup-buffer
                     (forge-pullreq :id "forge-1" :number 1 :title "T" :their-id "PR_1"
                                    :base-rev nil :body nil))))
        (unwind-protect
            (with-current-buffer buffer
              (should-not (prrr-diff-test--files))
              (should (string-match-p "base commit .* not available locally"
                                      (buffer-string))))
          (kill-buffer buffer))))))

(ert-deftest prrr-diff-test-missing-head-note ()
  (prrr-db-with-test-db
    (prrr-test-with-repo
      (call-process "git" nil nil nil "update-ref" "-d" "refs/pullreqs/1")
      (let ((buffer (prrr-diff-setup-buffer (prrr-diff-test--pullreq))))
        (unwind-protect
            (with-current-buffer buffer
              (should (string-match-p "refs/pullreqs/1 is missing" (buffer-string))))
          (kill-buffer buffer))))))

(ert-deftest prrr-diff-test-one-buffer-per-pr ()
  (prrr-diff-test--with-buffer nil
    (should (eq (current-buffer) (prrr-diff-setup-buffer (prrr-diff-test--pullreq))))))

(ert-deftest prrr-diff-test-refresh-keeps-expanded-lazy-file ()
  (let ((prrr-eager-files 0))
    (prrr-diff-test--with-buffer nil
      (magit-section-show (prrr-diff-test--file-section "docs/notes.md"))
      (magit-refresh-buffer)
      (let ((notes (prrr-diff-test--file-section "docs/notes.md")))
        (should-not (oref notes hidden))
        (should (oref notes children))))))

;;;; Threads

(defun prrr-diff-test--hunks (path)
  "Return the hunk sections of PATH, expanding the file."
  (let ((file (prrr-diff-test--file-section path)))
    (magit-section-show file)
    (seq-filter (lambda (child) (eq (oref child type) 'hunk)) (oref file children))))

(defun prrr-diff-test--line-before (section)
  "Return the text of the line before SECTION."
  (save-excursion
    (goto-char (oref section start))
    (forward-line -1)
    (buffer-substring-no-properties (line-beginning-position) (line-end-position))))

(defun prrr-diff-test--store-extra-threads ()
  "Store Threads the fixture lacks: not in range, on the left side, on a gone file."
  (dolist (thread (list (prrr-thread-create :thread-id "T_NIR" :pr-id prrr-diff-test--pr
                                            :path "src/example.el" :line 20 :side 'right
                                            :subject-type 'line)
                        (prrr-thread-create :thread-id "T_LEFT" :pr-id prrr-diff-test--pr
                                            :path "src/example.el" :line 30 :side 'left
                                            :subject-type 'line)
                        (prrr-thread-create :thread-id "T_GONE" :pr-id prrr-diff-test--pr
                                            :path "src/gone.el" :line 2 :side 'right
                                            :subject-type 'line)))
    (prrr-db-insert thread)))

(ert-deftest prrr-diff-test-thread-after-its-line ()
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (let* ((hunks (prrr-diff-test--hunks "src/example.el"))
           (first (car (oref (car hunks) children)))
           (pending (car (oref (cadr hunks) children))))
      (should (eq 'thread (oref first type)))
      (should (equal "PRRT_kwDOexample0000001" (oref first value)))
      (should (equal "+line twelve" (prrr-diff-test--line-before first)))
      (should (equal "PRRT_kwDOexample0000005" (oref pending value)))
      (should (equal "+line thirty" (prrr-diff-test--line-before pending))))))

(ert-deftest prrr-diff-test-left-thread-after-removed-line ()
  (prrr-diff-test--with-buffer (progn (prrr-diff-test--store-fixture)
                                      (prrr-diff-test--store-extra-threads))
    (let ((left (seq-find (lambda (child) (equal "T_LEFT" (oref child value)))
                          (oref (cadr (prrr-diff-test--hunks "src/example.el")) children))))
      (should (equal "-line 30" (prrr-diff-test--line-before left))))))

(ert-deftest prrr-diff-test-range-thread-after-last-line-and-folded ()
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (let ((thread (car (oref (car (prrr-diff-test--hunks "README.md")) children))))
      (should (equal "PRRT_kwDOexample0000002" (oref thread value)))
      (should (equal "+Some text," (prrr-diff-test--line-before thread)))
      (should (oref thread hidden)))))

(ert-deftest prrr-diff-test-file-comment-comes-first ()
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (let ((file (prrr-diff-test--file-section "docs/notes.md")))
      (magit-section-show file)
      (should (equal '(file-comment hunk)
                     (mapcar (lambda (child) (oref child type)) (oref file children)))))))

(ert-deftest prrr-diff-test-thread-not-in-range ()
  "Review Focus 1: a Thread whose line is not in the diff is kept, folded away."
  (prrr-diff-test--with-buffer (progn (prrr-diff-test--store-fixture)
                                      (prrr-diff-test--store-extra-threads))
    (let* ((file (prrr-diff-test--file-section "src/example.el"))
           (group (progn (magit-section-show file)
                         (seq-find (lambda (child) (eq (oref child type) 'not-in-range))
                                   (oref file children)))))
      (should group)
      (should (oref group hidden))
      (should (equal '("T_NIR") (mapcar (lambda (child) (oref child value))
                                        (oref group children)))))))

(ert-deftest prrr-diff-test-outdated-thread-grouped ()
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (let* ((file (prrr-diff-test--file-section "src/old.el"))
           (group (progn (magit-section-show file)
                         (seq-find (lambda (child) (eq (oref child type) 'outdated))
                                   (oref file children)))))
      (should (oref group hidden))
      (should (equal '("PRRT_kwDOexample0000003")
                     (mapcar (lambda (child) (oref child value)) (oref group children)))))))

(ert-deftest prrr-diff-test-threads-on-files-not-in-diff ()
  (prrr-diff-test--with-buffer (progn (prrr-diff-test--store-fixture)
                                      (prrr-diff-test--store-extra-threads))
    (let ((group (magit-get-section '((outdated-files) (diffbuf)))))
      (should (oref group hidden))
      (should (equal '("T_GONE") (mapcar (lambda (child) (oref child value))
                                         (oref group children))))
      (should (string-match-p "src/gone\\.el, line 2" (prrr-diff-test--text group))))))

(ert-deftest prrr-diff-test-heading-counts-threads ()
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (should (string-match-p "src/example\\.el  2 threads"
                            (prrr-diff-test--text (prrr-diff-test--file-section "src/example.el"))))))

(ert-deftest prrr-diff-test-ret-after-thread ()
  "Review Focus 4: a diff line after a Thread maps to its own file line."
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (let* ((hunk (car (prrr-diff-test--hunks "src/example.el")))
           (thread (car (oref hunk children))))
      (goto-char (oref thread end))
      (should (looking-at " line 13$"))
      (should (= 13 (magit-diff-hunk-line hunk nil)))
      (goto-char (oref thread start))
      (forward-line 2)
      (should (= 12 (magit-diff-hunk-line hunk nil))))))

(ert-deftest prrr-diff-test-thread-visit ()
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (let ((thread (car (oref (car (prrr-diff-test--hunks "src/example.el")) children))))
      (goto-char (oref thread start))
      (prrr-thread-visit)
      (with-current-buffer (window-buffer)
        (should (string-match-p "example\\.el\\.~" (buffer-name)))
        (should (= 12 (line-number-at-pos)))
        (kill-buffer)))))

(ert-deftest prrr-diff-test-ret-on-file-with-file-comment ()
  "The RET of magit on a file heading skips a File Comment to the first hunk."
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (let ((file (prrr-diff-test--file-section "docs/notes.md")))
      (magit-section-show file)
      (goto-char (oref file start))
      (magit-diff-visit-file (magit-file-at-point))
      (with-current-buffer (window-buffer)
        (should (string-match-p "notes\\.md\\.~" (buffer-name)))
        (kill-buffer)))))

(ert-deftest prrr-diff-test-paint-keeps-thread-faces ()
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (let* ((hunk (car (prrr-diff-test--hunks "src/example.el")))
           (thread (car (oref hunk children))))
      (goto-char (oref hunk content))
      (magit-section-update-highlight t)
      (should (eq 'prrr-thread-heading
                  (get-text-property (+ (oref thread start) 4) 'font-lock-face)))
      (should (memq (get-text-property (oref thread end) 'font-lock-face)
                    '(magit-diff-context magit-diff-context-highlight))))))

(ert-deftest prrr-diff-test-refresh-keeps-thread-fold ()
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (magit-section-hide (car (oref (car (prrr-diff-test--hunks "src/example.el")) children)))
    (magit-refresh-buffer)
    (let ((file (prrr-diff-test--file-section "src/example.el")))
      (should-not (oref file hidden))
      (should (oref (car (oref (car (prrr-diff-test--hunks "src/example.el")) children))
                    hidden)))))

(provide 'prrr-diff-test)
;;; prrr-diff-test.el ends here
