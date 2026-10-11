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

(provide 'prrr-diff-test)
;;; prrr-diff-test.el ends here
