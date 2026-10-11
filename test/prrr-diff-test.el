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
(require 'prrr-transient)

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

(defvar prrr-diff-test--posts nil
  "The Discussion Comments `prrr-diff--posts' returns in tests.")

(defmacro prrr-diff-test--with-buffer (setup &rest body)
  "Open the fixture PR's Review Buffer and run BODY in it.
SETUP runs first, inside the fixture repository and a fresh database.
`prrr-diff--posts' returns `prrr-diff-test--posts'."
  (declare (indent 1))
  `(prrr-db-with-test-db
     (prrr-test-with-repo
       ,setup
       (cl-letf (((symbol-function 'prrr-diff--posts)
                  (lambda (_pullreq) prrr-diff-test--posts)))
         (let ((buffer (prrr-diff-setup-buffer (prrr-diff-test--pullreq))))
           (unwind-protect
               (with-current-buffer buffer ,@body)
             (kill-buffer buffer)))))))

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
      (cl-letf (((symbol-function 'prrr-diff--posts) #'ignore))
        (let ((buffer (prrr-diff-setup-buffer
                       (forge-pullreq :id "forge-1" :number 1 :title "T" :their-id "PR_1"
                                      :base-rev nil :body nil))))
          (unwind-protect
              (with-current-buffer buffer
                (should-not (prrr-diff-test--files))
                (should (string-match-p "base commit .* not available locally"
                                        (buffer-string))))
            (kill-buffer buffer)))))))

(ert-deftest prrr-diff-test-missing-head-note ()
  (prrr-db-with-test-db
    (prrr-test-with-repo
      (call-process "git" nil nil nil "update-ref" "-d" "refs/pullreqs/1")
      (cl-letf (((symbol-function 'prrr-diff--posts) #'ignore))
        (let ((buffer (prrr-diff-setup-buffer (prrr-diff-test--pullreq))))
          (unwind-protect
              (with-current-buffer buffer
                (should (string-match-p "refs/pullreqs/1 is missing" (buffer-string))))
            (kill-buffer buffer)))))))

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

(ert-deftest prrr-diff-test-second-thread-on-one-line ()
  "From inside a second Thread on one line, both line and visit see that line."
  (prrr-diff-test--with-buffer
      (progn (prrr-diff-test--store-fixture)
             (prrr-db-insert (prrr-thread-create :thread-id "T_SECOND" :pr-id prrr-diff-test--pr
                                                 :path "src/example.el" :line 12 :side 'right
                                                 :subject-type 'line)))
    (let* ((hunk (car (prrr-diff-test--hunks "src/example.el")))
           (second (cadr (oref hunk children))))
      (should (equal "T_SECOND" (oref second value)))
      (goto-char (oref second start))
      (should (= 12 (magit-diff-hunk-line hunk nil)))
      (prrr-thread-visit)
      (with-current-buffer (window-buffer)
        (should (string-match-p "example\\.el\\.~" (buffer-name)))
        (should (= 12 (line-number-at-pos)))
        (kill-buffer)))))

;;;; Header

(defun prrr-diff-test--status-line ()
  "Return the header's status line."
  (save-excursion
    (goto-char (oref (magit-get-section '((prrr-header) (diffbuf))) content))
    (buffer-substring-no-properties (line-beginning-position) (line-end-position))))

(ert-deftest prrr-diff-test-header-title-and-range ()
  (prrr-diff-test--with-buffer nil
    (goto-char (point-min))
    (should (looking-at "#1 Example change$"))
    (should (string-match-p
             (format "\\`Range: default, %s\\.\\.%s"
                     (substring (car (process-lines "git" "rev-parse" "main~1")) 0 7)
                     (substring (car (process-lines "git" "rev-parse" "refs/pullreqs/1")) 0 7))
             (prrr-diff-test--status-line)))))

(ert-deftest prrr-diff-test-header-pending-review ()
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (should (string-match-p "Pending Review: 1 comment\\b" (prrr-diff-test--status-line)))))

(ert-deftest prrr-diff-test-header-shows-refetch-status ()
  "Review Focus 5: the header says why the data may be old."
  (let ((prrr-sync--status (make-hash-table :test #'equal)))
    (puthash (cons 'review prrr-diff-test--pr)
             (list :state 'pulling :attempted-at (prrr-sync--timestamp)) prrr-sync--status)
    (prrr-diff-test--with-buffer nil
      (should (string-match-p "refreshing…" (prrr-diff-test--status-line)))
      (puthash (cons 'review prrr-diff-test--pr) '(:state offline) prrr-sync--status)
      (magit-refresh-buffer)
      (should (string-match-p "offline" (prrr-diff-test--status-line))))))

(ert-deftest prrr-diff-test-header-github-head-differs ()
  "Review Focus 1: GitHub's head is ahead of the local ref."
  (let ((prrr-sync--status (make-hash-table :test #'equal)))
    (puthash (cons 'review prrr-diff-test--pr)
             '(:state ok :head-oid "2222222222222222222222222222222222222222")
             prrr-sync--status)
    (prrr-diff-test--with-buffer nil
      (should (string-match-p "GitHub's head is 2222222: run forge-pull, then g"
                              (prrr-diff-test--status-line))))))

(ert-deftest prrr-diff-test-header-description-and-discussion ()
  (let ((prrr-diff-test--posts
         (list (forge-pullreq-post :id "post-1" :author "example-bob"
                                   :created "2026-09-03T00:00:00Z" :body "Nice."))))
    (prrr-diff-test--with-buffer nil
      (let ((description (magit-get-section '((description) (prrr-header) (diffbuf))))
            (discussion (magit-get-section '((discussion) (prrr-header) (diffbuf)))))
        (should (oref description hidden))
        (should (string-match-p "Why this change\\." (prrr-diff-test--text description)))
        (should (oref discussion hidden))
        (should (string-match-p "\\`Discussion (1)" (prrr-diff-test--text discussion)))
        (should (string-match-p "Nice\\." (prrr-diff-test--text discussion)))
        (should-not (oref discussion keymap))))))

(ert-deftest prrr-diff-test-header-empty-description ()
  (prrr-db-with-test-db
    (prrr-test-with-repo
      (cl-letf (((symbol-function 'prrr-diff--posts) #'ignore))
        (let ((buffer (prrr-diff-setup-buffer
                       (forge-pullreq :id "forge-1" :number 1 :title "T" :their-id "PR_1"
                                      :base-rev prrr-test-repo-base :author "example-alice"
                                      :created "2026-09-01T00:00:00Z" :body ""))))
          (unwind-protect
              (with-current-buffer buffer
                (should (string-match-p
                         "No description"
                         (prrr-diff-test--text
                          (magit-get-section '((description) (prrr-header) (diffbuf)))))))
            (kill-buffer buffer)))))))

;;;; Opening

(defmacro prrr-diff-test--with-open-stubs (&rest body)
  "Run BODY with the network and forge's database stubbed for opening.
`prrr-sync-refetch' records its calls in `refetches'; posts are empty."
  (declare (indent 0))
  `(let ((refetches nil)
         (get-repository (symbol-function 'forge-get-repository)))
     (cl-letf (((symbol-function 'prrr-sync-refetch)
                (lambda (repo pullreq buffer) (push (list repo pullreq buffer) refetches) t))
               ;; Only prrr's own lookup by pull request is stubbed: forge's mode
               ;; hook asks for the repository of the buffer and needs a real answer.
               ((symbol-function 'forge-get-repository)
                (lambda (&rest args)
                  (if (forge-pullreq-p (car args)) 'example-repo (apply get-repository args))))
               ((symbol-function 'prrr-diff--posts) #'ignore))
       ,@body)))

(ert-deftest prrr-diff-test-open-shows-buffer-and-refetches ()
  (prrr-db-with-test-db
    (prrr-test-with-repo
      (prrr-diff-test--with-open-stubs
        (let* ((pullreq (prrr-diff-test--pullreq))
               (buffer (prrr-diff-open pullreq)))
          (unwind-protect
              (progn
                (should (eq 'prrr-diff-mode (buffer-local-value 'major-mode buffer)))
                (should (equal (list (list 'example-repo pullreq buffer)) refetches))
                ;; Review Focus 5: a redraw never refetches.
                (with-current-buffer buffer (magit-refresh-buffer))
                (should (= 1 (length refetches)))
                (with-current-buffer buffer
                  ;; Away from the "#1" in the title, which forge would parse.
                  (goto-char (point-max))
                  (should (eq pullreq (prrr-current-pullreq)))))
            (kill-buffer buffer)))))))

(ert-deftest prrr-diff-test-review-missing-ref-offers-pull ()
  "Review Focus 1: no Review Buffer without the PR's head."
  (prrr-db-with-test-db
    (prrr-test-with-repo
      (call-process "git" nil nil nil "update-ref" "-d" "refs/pullreqs/1")
      (prrr-diff-test--with-open-stubs
        (let ((pulled nil))
          (cl-letf (((symbol-function 'forge-pull) (lambda (&rest _) (interactive) (setq pulled t))))
            (cl-letf (((symbol-function 'y-or-n-p) #'ignore))
              (should-error (prrr-diff-open (prrr-diff-test--pullreq)) :type 'user-error)
              (should-not pulled))
            (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
              (should-error (prrr-diff-open (prrr-diff-test--pullreq)) :type 'user-error)
              (should pulled))
            (should-not refetches)
            (should-not (get-buffer (prrr-diff--buffer-name (prrr-diff-test--pullreq))))))))))

(ert-deftest prrr-diff-test-refetch-command ()
  (prrr-db-with-test-db
    (prrr-test-with-repo
      (prrr-diff-test--with-open-stubs
        (let ((buffer (prrr-diff-open (prrr-diff-test--pullreq))))
          (unwind-protect
              (with-current-buffer buffer
                (setq refetches nil)
                (prrr-refetch)
                (should (= 1 (length refetches))))
            (kill-buffer buffer)))))))

(ert-deftest prrr-diff-test-refetch-outside-review-buffer ()
  (with-temp-buffer
    (should-error (prrr-refetch) :type 'user-error)))

;;;; Commands

(defun prrr-diff-test--at ()
  "Return (TYPE . VALUE) of the section at point."
  (let ((section (magit-current-section)))
    (cons (oref section type) (oref section value))))

(ert-deftest prrr-diff-test-next-and-previous-file ()
  (prrr-diff-test--with-buffer nil
    (goto-char (point-min))
    (prrr-next-file)
    (should (equal '(file . "README.md") (prrr-diff-test--at)))
    (prrr-next-file)
    (should (equal '(file . "data.bin") (prrr-diff-test--at)))
    (prrr-previous-file)
    (should (equal '(file . "README.md") (prrr-diff-test--at)))
    (should-error (prrr-previous-file) :type 'user-error)
    (prrr-jump-to-file "src/old.el")
    (should (equal '(file . "src/old.el") (prrr-diff-test--at)))
    (should-error (prrr-next-file) :type 'user-error)))

(ert-deftest prrr-diff-test-jump-to-file-expands-it ()
  (let ((prrr-eager-files 0))
    (prrr-diff-test--with-buffer nil
      (prrr-jump-to-file "docs/notes.md")
      (should-not (oref (prrr-diff-test--file-section "docs/notes.md") hidden)))))

(ert-deftest prrr-diff-test-next-thread-washes-and-reveals ()
  "] reaches Threads in files not washed yet and inside folded groups."
  (let ((prrr-eager-files 0))
    (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
      (goto-char (point-min))
      (let ((seen nil))
        (dotimes (_ 5)
          (prrr-next-thread)
          (should-not (invisible-p (point)))
          (push (cdr (prrr-diff-test--at)) seen))
        (should (equal '("PRRT_kwDOexample0000002" "PRRT_kwDOexample0000004"
                         "PRRT_kwDOexample0000001" "PRRT_kwDOexample0000005"
                         "PRRT_kwDOexample0000003")
                       (nreverse seen))))
      (should-error (prrr-next-thread) :type 'user-error)
      (prrr-previous-thread)
      (should (equal "PRRT_kwDOexample0000005" (cdr (prrr-diff-test--at)))))))

(ert-deftest prrr-diff-test-next-unresolved-skips-resolved ()
  (let ((prrr-eager-files 0))
    (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
      (goto-char (point-min))
      (prrr-next-unresolved)
      (should (equal "PRRT_kwDOexample0000004" (cdr (prrr-diff-test--at))))
      ;; The only Thread before it, on README.md, is resolved.
      (should-error (prrr-previous-unresolved) :type 'user-error))))

(ert-deftest prrr-diff-test-collapse-and-expand-all ()
  (let ((prrr-eager-files 1))
    (prrr-diff-test--with-buffer nil
      (prrr-expand-all)
      (dolist (path (prrr-diff-test--files))
        (should-not (oref (prrr-diff-test--file-section path) hidden)))
      (prrr-collapse-all)
      (dolist (path (prrr-diff-test--files))
        (should (oref (prrr-diff-test--file-section path) hidden))))))

(ert-deftest prrr-diff-test-toggle-viewed ()
  "Toggling Viewed writes through the Outbox, shows at once and folds."
  (prrr-diff-test--with-buffer nil
    (prrr-test-with-outbox
      (cl-letf (((symbol-function 'forge-get-repository)
                 (lambda (&rest _) (forge-github-repository :id "r" :owner "example-org"
                                                            :name "example-repo"
                                                            :apihost "api.github.com"))))
        (prrr-test-with-ghub-stub '((data (markFileAsViewed (clientMutationId)))) captured
          (prrr-jump-to-file "README.md")
          (prrr-toggle-viewed)
          (should (eq 'markFileAsViewed (car (cadr (car captured)))))
          (should (eq 'viewed (prrr-viewed-state (prrr-db-get 'viewed prrr-diff-test--pr "README.md"))))
          (let ((readme (prrr-diff-test--file-section "README.md")))
            (should (oref readme hidden))
            (should (string-match-p "✓ viewed" (prrr-diff-test--text readme))))
          (should (equal '(file . "data.bin") (prrr-diff-test--at)))
          (prrr-jump-to-file "README.md")
          (prrr-toggle-viewed)
          (should (eq 'unviewed (prrr-viewed-state
                                 (prrr-db-get 'viewed prrr-diff-test--pr "README.md"))))
          (should-not (oref (prrr-diff-test--file-section "README.md") hidden))
          (should (equal '(file . "README.md") (prrr-diff-test--at))))))))

(ert-deftest prrr-diff-test-toggle-viewed-offline-shows-at-once ()
  "Review Focus 1: offline, the flag shows and folds, and stays in the Outbox."
  (prrr-diff-test--with-buffer nil
    (prrr-test-with-outbox
      (cl-letf (((symbol-function 'forge-get-repository)
                 (lambda (&rest _) (forge-github-repository :id "r" :owner "example-org"
                                                            :name "example-repo"
                                                            :apihost "api.github.com"))))
        (prrr-test-with-ghub-error-stub '(error http 502) nil
          (prrr-jump-to-file "README.md")
          (prrr-toggle-viewed))
        (should-not (prrr-db-get 'viewed prrr-diff-test--pr "README.md"))
        (should (= 1 (length (prrr-db-outbox-rows prrr-diff-test--pr))))
        (let ((readme (prrr-diff-test--file-section "README.md")))
          (should (oref readme hidden))
          (should (string-match-p "✓ viewed" (prrr-diff-test--text readme))))))))

(ert-deftest prrr-diff-test-keys-and-menu-agree ()
  "SPEC section 9: every key of this milestone, in the buffer and the menu."
  (pcase-dolist (`(,key . ,command)
                 '(("]" . prrr-next-thread) ("[" . prrr-previous-thread)
                   ("}" . prrr-next-unresolved) ("{" . prrr-previous-unresolved)
                   ("J" . prrr-next-file) ("K" . prrr-previous-file)
                   ("j" . prrr-jump-to-file) ("v" . prrr-toggle-viewed)
                   ("z" . prrr-collapse-all) ("Z" . prrr-expand-all)
                   ("o" . prrr-open-topic) ("b" . prrr-browse) ("B" . prrr-checkout)
                   ("g" . magit-refresh) ("G" . prrr-refetch)))
    (should (eq command (keymap-lookup prrr-diff-mode-map key)))
    (let ((suffix (transient-get-suffix 'prrr-menu key)))
      (should (eq command (plist-get (if (vectorp suffix) (aref suffix 2) (cdr suffix))
                                     :command)))))
  (should (eq 'prrr-menu (keymap-lookup prrr-diff-mode-map "?")))
  (should (eq 'prrr-menu (keymap-lookup prrr-diff-mode-map "C-o")))
  (should (eq 'magit-dispatch (keymap-lookup prrr-diff-mode-map "h"))))

(ert-deftest prrr-diff-test-later-keys-do-nothing-yet ()
  "Magit's diff arguments, log and friends never run in a Review Buffer.
Checked by the effective binding on a file heading, a hunk line and a
Thread, where section keymaps apply on top of the mode's."
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (let* ((file (prrr-diff-test--file-section "src/example.el"))
           (hunk (car (prrr-diff-test--hunks "src/example.el")))
           (thread (car (oref hunk children))))
      (pcase-dolist (`(,where . ,position) `((file-heading . ,(oref file start))
                                             (hunk-line . ,(oref hunk content))
                                             (thread . ,(oref thread start))))
        (goto-char position)
        (dolist (key prrr-diff--later-keys)
          (should (equal (list where key 'undefined)
                         (list where key (key-binding (kbd key))))))
        (pcase-dolist (`(,key . ,command) prrr-diff--review-keys)
          (should (equal (list where key command)
                         (list where key (key-binding (kbd key))))))))))

(ert-deftest prrr-diff-test-previous-thread-washes-files-before-point ()
  "[ reaches Threads in unwashed files above point, whose washing shifts point."
  (let ((prrr-eager-files 0))
    (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
      (goto-char (point-max))
      (let ((seen nil))
        (dotimes (_ 5)
          (prrr-previous-thread)
          (should-not (invisible-p (point)))
          (push (cdr (prrr-diff-test--at)) seen))
        (should (equal '("PRRT_kwDOexample0000003" "PRRT_kwDOexample0000005"
                         "PRRT_kwDOexample0000001" "PRRT_kwDOexample0000004"
                         "PRRT_kwDOexample0000002")
                       (nreverse seen))))
      (should-error (prrr-previous-thread) :type 'user-error))))

;;;; Refreshing

(ert-deftest prrr-diff-test-open-shows-refreshing ()
  "SPEC section 7: the header says \"refreshing…\" while the opening refetch runs."
  (let ((prrr-sync--status (make-hash-table :test #'equal)))
    (prrr-db-with-test-db
      (prrr-test-with-repo
        (prrr-diff-test--with-open-stubs
          (cl-letf (((symbol-function 'prrr-sync-refetch)
                     (lambda (repo pullreq buffer)
                       (push (list repo pullreq buffer) refetches)
                       (puthash (cons 'review (oref pullreq their-id))
                                (list :state 'pulling :attempted-at (prrr-sync--timestamp))
                                prrr-sync--status)
                       t)))
            (let ((buffer (prrr-diff-open (prrr-diff-test--pullreq))))
              (unwind-protect
                  (with-current-buffer buffer
                    (should (equal (list buffer) (mapcar #'caddr refetches)))
                    (should (string-match-p "refreshing…" (prrr-diff-test--status-line))))
                (kill-buffer buffer)))))))))

(ert-deftest prrr-diff-test-refresh-keeps-shown-groups ()
  "A refresh keeps the Description and the Thread groups as the user left them."
  (prrr-diff-test--with-buffer (progn (prrr-diff-test--store-fixture)
                                      (prrr-diff-test--store-extra-threads))
    (let ((not-in-range (lambda ()
                          (seq-find (lambda (child) (eq (oref child type) 'not-in-range))
                                    (oref (prrr-diff-test--file-section "src/example.el")
                                          children)))))
      (magit-section-show (magit-get-section '((description) (prrr-header) (diffbuf))))
      (magit-section-show (prrr-diff-test--file-section "src/example.el"))
      (magit-section-show (funcall not-in-range))
      (magit-section-show (magit-get-section '((outdated-files) (diffbuf))))
      (magit-refresh-buffer)
      (should-not (oref (magit-get-section '((description) (prrr-header) (diffbuf))) hidden))
      (should-not (oref (funcall not-in-range) hidden))
      (should-not (oref (magit-get-section '((outdated-files) (diffbuf))) hidden)))))

(ert-deftest prrr-diff-test-failed-refresh-restores-markers ()
  "A refresh that signals does not leave sections inserted without markers."
  (prrr-diff-test--with-buffer nil
    (cl-letf (((symbol-function 'prrr-diff--insert-header)
               (lambda (&rest _) (error "Example failure"))))
      (should-error (magit-refresh-buffer)))
    (should-not magit-section-inhibit-markers)))

;;;; Anchors

(defun prrr-diff-test--goto-line (path text)
  "Move to the diff line of PATH that reads TEXT, expanding PATH."
  (prrr-diff-test--hunks path)
  (goto-char (oref (prrr-diff-test--file-section path) start))
  (re-search-forward (concat "^" (regexp-quote text) "$"))
  (goto-char (line-beginning-position)))

(defmacro prrr-diff-test--with-region (from to &rest body)
  "Run BODY with the region over the lines FROM to TO of src/example.el.
FROM and TO are the texts of the lines."
  (declare (indent 2))
  `(let ((transient-mark-mode t))
     (prrr-diff-test--goto-line "src/example.el" ,from)
     (push-mark (point) t t)
     (prrr-diff-test--goto-line "src/example.el" ,to)
     (goto-char (line-end-position))
     ,@body))

(ert-deftest prrr-diff-test-anchor-added-line ()
  (prrr-diff-test--with-buffer nil
    (prrr-diff-test--goto-line "src/example.el" "+line twelve")
    (should (equal '(:path "src/example.el" :line 12 :side right :subject-type line)
                   (prrr-diff-anchor)))))

(ert-deftest prrr-diff-test-anchor-removed-line-is-left ()
  (prrr-diff-test--with-buffer nil
    (prrr-diff-test--goto-line "src/example.el" "-line 12")
    (should (equal '(:path "src/example.el" :line 12 :side left :subject-type line)
                   (prrr-diff-anchor)))))

(ert-deftest prrr-diff-test-anchor-context-line ()
  (prrr-diff-test--with-buffer nil
    (prrr-diff-test--goto-line "src/example.el" " line 13")
    (should (equal '(:path "src/example.el" :line 13 :side right :subject-type line)
                   (prrr-diff-anchor)))))

(ert-deftest prrr-diff-test-anchor-region-is-a-range ()
  (prrr-diff-test--with-buffer nil
    (prrr-diff-test--with-region " line 10" "+line twelve"
      (should (equal '(:path "src/example.el" :line 12 :side right
                       :start-line 10 :start-side right :subject-type line)
                     (prrr-diff-anchor))))))

(ert-deftest prrr-diff-test-anchor-region-ending-at-a-line-start ()
  "A region that ends where a line starts covers the lines before it."
  (prrr-diff-test--with-buffer nil
    (let ((transient-mark-mode t))
      (prrr-diff-test--goto-line "src/example.el" " line 10")
      (push-mark (point) t t)
      (prrr-diff-test--goto-line "src/example.el" "+line twelve")
      (should (equal '(:path "src/example.el" :line 12 :side left
                       :start-line 10 :start-side right :subject-type line)
                     (prrr-diff-anchor))))))

(ert-deftest prrr-diff-test-anchor-across-hunks-refused ()
  (prrr-diff-test--with-buffer nil
    (prrr-diff-test--with-region "+line twelve" "+line thirty"
      (should-error (prrr-diff-anchor) :type 'user-error))))

(ert-deftest prrr-diff-test-anchor-in-a-thread ()
  "Point in a Thread anchors to the diff line the Thread follows."
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (let ((hunk (car (prrr-diff-test--hunks "src/example.el"))))
      (goto-char (oref (car (oref hunk children)) start))
      (forward-line 1)
      (should (equal '(:path "src/example.el" :line 12 :side right :subject-type line)
                     (prrr-diff-anchor))))))

(ert-deftest prrr-diff-test-anchor-off-diff-lines ()
  (prrr-diff-test--with-buffer nil
    (let ((hunk (car (prrr-diff-test--hunks "src/example.el")))
          (file (prrr-diff-test--file-section "src/example.el")))
      (goto-char (oref hunk start))
      (should-error (prrr-diff-anchor) :type 'user-error)
      (goto-char (oref file start))
      (should-error (prrr-diff-anchor) :type 'user-error)
      (should (equal '(:path "src/example.el" :subject-type file) (prrr-diff-file-anchor))))))

(ert-deftest prrr-diff-test-region-lines-skip-threads ()
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (prrr-diff-test--with-region " line 11" " line 13"
      (should (equal '((?\s . "line 11") (?- . "line 12") (?+ . "line twelve") (?\s . "line 13"))
                     (prrr-diff-region-lines))))))

(ert-deftest prrr-diff-test-thread-and-comment-at-point ()
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (let* ((hunk (car (prrr-diff-test--hunks "src/example.el")))
           (thread (car (oref hunk children))))
      (goto-char (oref thread start))
      (should (equal "PRRT_kwDOexample0000001" (prrr-thread-thread-id (prrr-diff-thread-at-point))))
      (should-not (prrr-diff-comment-at-point))
      (goto-char (oref (cadr (oref thread children)) start))
      (should (equal "PRRC_kwDOexample0000002" (prrr-comment-comment-id (prrr-diff-comment-at-point))))
      (should (equal "PRRT_kwDOexample0000001" (prrr-thread-thread-id (prrr-diff-thread-at-point)))))))
;;;; Unsent writes and suggestions

(ert-deftest prrr-diff-test-suggestion-against-anchored-lines ()
  "A suggestion on a right-side Thread is a mini diff against its lines."
  (prrr-diff-test--with-buffer
      (progn (prrr-diff-test--store-fixture)
             (prrr-db-insert (prrr-comment-create
                              :comment-id "C_SUGGEST" :thread-id "PRRT_kwDOexample0000001"
                              :pr-id prrr-diff-test--pr :author "example-carol"
                              :body "```suggestion\nline 12\n```"
                              :created-at "2026-09-05T00:00:00Z" :state 'submitted
                              :local-state 'sent)))
    (prrr-diff-test--hunks "src/example.el")
    (goto-char (point-min))
    (re-search-forward "^      Suggested change:\n      -line twelve\n      \\+line 12$")))

(ert-deftest prrr-diff-test-header-counts-the-outbox ()
  "SPEC section 6: the header counts the Outbox; unsent Discussion Comments show."
  (prrr-diff-test--with-buffer
      (progn
        (prrr-diff-test--store-fixture)
        (prrr-db-insert (prrr-outbox-create :id "1" :pr-id prrr-diff-test--pr :kind 'viewed
                                            :payload '(:path "a.el" :viewed t) :attempts 0))
        (prrr-db-insert (prrr-outbox-create :id "2" :pr-id prrr-diff-test--pr :kind 'discussion
                                            :payload '(:comment "local:D" :body "Thanks!")
                                            :attempts 1 :last-error "offline")))
    (let ((status (prrr-diff-test--status-line)))
      (should (string-match-p "Pending Review: 1 comment" status))
      (should (string-match-p "Outbox: 1 unsent, 1 failed, O to act" status)))
    (let ((discussion (magit-get-section '((discussion) (prrr-header) (diffbuf)))))
      (should (string-match-p "Discussion (1)" (prrr-diff-test--text discussion)))
      (should (string-match-p "Your Discussion Comment  failed: offline"
                              (prrr-diff-test--text discussion))))))

;;;; Ranges

(defun prrr-diff-test--rev (rev)
  "Return the oid of REV in the fixture repository."
  (car (process-lines "git" "rev-parse" rev)))

(defun prrr-diff-test--group (path type)
  "Return the values of the Threads in PATH's hidden group of TYPE."
  (let ((file (prrr-diff-test--file-section path)))
    (magit-section-show file)
    (mapcar (lambda (child) (oref child value))
            (oref (seq-find (lambda (child) (eq (oref child type) type))
                            (oref file children))
                  children))))

(ert-deftest prrr-diff-test-range-since-review ()
  "SPEC section 8: a Range from an earlier commit to the head."
  (prrr-diff-test--with-buffer (progn (prrr-diff-test--store-fixture)
                                      (prrr-diff-test--store-extra-threads))
    (let ((first (prrr-diff-test--rev "refs/pullreqs/1~1")))
      (prrr-diff-show-range (prrr-range-create :kind 'since-review :start first))
      (should (equal '("src/example.el") (prrr-diff-test--files)))
      (should (string-match-p
               (format "\\`Range: since-review, %s\\.\\.%s  ·  "
                       (substring first 0 7)
                       (substring (prrr-diff-test--rev "refs/pullreqs/1") 0 7))
               (prrr-diff-test--status-line)))
      (should (equal (prrr-diff-test--rev "refs/pullreqs/1") (prrr-diff-head)))
      ;; The right side is numbered at the head: line 30's Thread stays inline.
      (let ((hunk (car (prrr-diff-test--hunks "src/example.el"))))
        (should (equal '("PRRT_kwDOexample0000005")
                       (mapcar (lambda (child) (oref child value)) (oref hunk children)))))
      ;; Line 12 is not in this diff; the left side is not numbered as GitHub does.
      (should (equal '("PRRT_kwDOexample0000001" "T_NIR" "T_LEFT")
                     (prrr-diff-test--group "src/example.el" 'not-in-range))))))

(ert-deftest prrr-diff-test-range-commit-shows-no-thread-inline ()
  "Review Focus 3: a Range that ends before the head numbers no line as GitHub does."
  (prrr-diff-test--with-buffer (prrr-diff-test--store-fixture)
    (prrr-diff-show-range (prrr-range-create :kind 'commit
                                             :start (prrr-diff-test--rev "refs/pullreqs/1~2")
                                             :end (prrr-diff-test--rev "refs/pullreqs/1~1")))
    (should (equal '("README.md" "data.bin" "docs/notes.md" "src/example.el"
                     "src/moved-to.el" "src/old.el")
                   (prrr-diff-test--files)))
    (should (string-match-p "\\`Range: commit, " (prrr-diff-test--status-line)))
    (should-not (string-match-p "+line thirty"
                                (prrr-diff-test--text
                                 (prrr-diff-test--file-section "src/example.el"))))
    (should (equal '("PRRT_kwDOexample0000001" "PRRT_kwDOexample0000005")
                   (prrr-diff-test--group "src/example.el" 'not-in-range)))))

(defun prrr-diff-test--force-push ()
  "Make the PR's head a new commit on its base, as a force-push does.
The old head stays as the branch feature."
  (call-process "git" nil nil nil "checkout" "-q" "-b" "rewritten" "main~1")
  (with-temp-file "src/example.el"
    (insert "rewritten\n"))
  (call-process "git" nil nil nil "commit" "-q" "-a" "-m" "rewritten")
  (call-process "git" nil nil nil "update-ref" "refs/pullreqs/1" "HEAD"))

(ert-deftest prrr-diff-test-range-history-rewritten ()
  "SPEC section 8: a start that is not an ancestor of the head is diffed tree to tree."
  (prrr-diff-test--with-buffer (prrr-diff-test--force-push)
    (prrr-diff-show-range (prrr-range-create :kind 'since-opened
                                             :start (prrr-diff-test--rev "feature")))
    (should (string-match-p (concat "\\`Range: since-opened, [0-9a-f]\\{7\\}\\.\\.[0-9a-f]\\{7\\}"
                                    "  ·  history rewritten")
                            (prrr-diff-test--status-line)))
    ;; Tree to tree: every file of the old head that differs shows.
    (should (member "README.md" (prrr-diff-test--files)))
    (should (member "src/example.el" (prrr-diff-test--files)))))

(ert-deftest prrr-diff-test-range-missing-commit ()
  (prrr-diff-test--with-buffer nil
    (prrr-diff-show-range (prrr-range-create :kind 'since-review
                                             :start "2222222222222222222222222222222222222222"))
    (should-not (prrr-diff-test--files))
    (should (string-match-p "The commit 2222222 of this Range is not available locally"
                            (buffer-string)))))

(provide 'prrr-diff-test)
;;; prrr-diff-test.el ends here
