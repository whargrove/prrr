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

(defun prrr-range-test--line ()
  "Return the text of the line at point."
  (buffer-substring-no-properties (line-beginning-position) (line-end-position)))

(defun prrr-range-test--commit-range (from to)
  "Return the `commit' Range from the revision FROM to TO."
  (prrr-range-create :kind 'commit :start (prrr-diff-test--rev from)
                     :end (prrr-diff-test--rev to)))

;;;; Positions

(ert-deftest prrr-range-test-position ()
  (prrr-diff-test--with-buffer nil
    (pcase-let ((`(,start . ,end) (prrr-diff-ends)))
      (prrr-diff-test--goto-line "src/example.el" "+line thirty")
      (should (equal (list "src/example.el" 'right 30 end) (prrr-diff-position)))
      (prrr-diff-test--goto-line "src/example.el" "-line 30")
      (should (equal (list "src/example.el" 'left 30 start) (prrr-diff-position)))
      (goto-char (oref (prrr-diff-test--file-section "src/example.el") start))
      (should (equal '("src/example.el" nil nil nil) (prrr-diff-position)))
      (goto-char (point-min))
      (should-not (prrr-diff-position)))))

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

(provide 'prrr-range-test)
;;; prrr-range-test.el ends here
