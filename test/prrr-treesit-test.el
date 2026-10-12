;;; prrr-treesit-test.el --- Tests for prrr-treesit  -*- lexical-binding: t -*-

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

;; Tree-sitter highlighting of the Review Buffer, on the C fixture
;; repository.  Tests that need the C grammar skip without it.  No network.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'prrr-test-helper)
(require 'prrr-treesit)

;;;; Languages

(define-derived-mode prrr-treesit-test-foo-mode fundamental-mode "foo"
  "A mode with a tree-sitter counterpart, for the lookup tests.")

(define-derived-mode prrr-treesit-test-foo-ts-mode fundamental-mode "foo-ts"
  "The tree-sitter counterpart of `prrr-treesit-test-foo-mode'.")

(define-derived-mode prrr-treesit-test-bar-mode fundamental-mode "bar"
  "A mode without a tree-sitter counterpart, for the lookup tests.")

(define-derived-mode prrr-treesit-test-nogrammar-ts-mode fundamental-mode "nogrammar"
  "A tree-sitter mode whose grammar is missing: it only warns, as real ones do."
  (treesit-ready-p 'prrr-no-such-language))

(define-derived-mode prrr-treesit-test-broken-ts-mode fundamental-mode "broken"
  "A tree-sitter mode that fails."
  (error "Broken mode"))

(defvar prrr-treesit-test--hooked nil
  "Set by `prrr-treesit-test-foo-ts-mode-hook' when it runs.")

(defmacro prrr-treesit-test--with-languages (alist &rest body)
  "Run BODY with `auto-mode-alist' ALIST, no remapping and an empty rules cache."
  (declare (indent 1))
  `(let ((auto-mode-alist ,alist)
         (major-mode-remap-alist nil)
         (prrr-treesit--languages (make-hash-table :test #'eq)))
     (cl-letf (((symbol-function 'major-mode-remap)
                (lambda (mode) (or (alist-get mode major-mode-remap-alist) mode))))
       ,@body)))

(ert-deftest prrr-treesit-test-mode-from-auto-mode-alist ()
  (prrr-treesit-test--with-languages '(("\\.foo\\'" . prrr-treesit-test-foo-ts-mode))
    (should (eq 'prrr-treesit-test-foo-ts-mode (prrr-treesit-mode "src/a.foo")))
    (should-not (prrr-treesit-mode "src/a.unknown"))))

(ert-deftest prrr-treesit-test-ts-counterpart-stands-in ()
  "FOO-ts-mode stands in for FOO-mode; a mode without one gives nil."
  (prrr-treesit-test--with-languages '(("\\.foo\\'" . prrr-treesit-test-foo-mode)
                                       ("\\.bar\\'" . prrr-treesit-test-bar-mode))
    (should (eq 'prrr-treesit-test-foo-ts-mode (prrr-treesit-mode "a.foo")))
    (should-not (prrr-treesit-mode "a.bar"))))

(ert-deftest prrr-treesit-test-remap-wins ()
  (prrr-treesit-test--with-languages '(("\\.bar\\'" . prrr-treesit-test-bar-mode))
    (let ((major-mode-remap-alist '((prrr-treesit-test-bar-mode
                                     . prrr-treesit-test-foo-ts-mode))))
      (should (eq 'prrr-treesit-test-foo-ts-mode (prrr-treesit-mode "a.bar"))))))

(ert-deftest prrr-treesit-test-suffix-stripping-entries-pass-over ()
  "An entry asking to strip a suffix and look again names no mode."
  (prrr-treesit-test--with-languages '(("\\.gz\\'" nil jka-compr)
                                       ("\\.foo\\'" . prrr-treesit-test-foo-ts-mode))
    (should-not (prrr-treesit-mode "a.gz"))
    (should (eq 'prrr-treesit-test-foo-ts-mode (prrr-treesit-mode "a.foo")))))

(ert-deftest prrr-treesit-test-c-rules ()
  "C files borrow c-ts-mode's compiled rules, cached per mode."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-languages '(("\\.c\\'" . c-mode))
    (let ((rules (prrr-treesit-rules "src/a.c")))
      (should (eq 'c (car rules)))
      (should (cdr rules))
      (should (seq-some (lambda (setting) (eq t (nth 1 setting))) (cdr rules)))
      (should (eq rules (prrr-treesit-rules "src/b.c"))))))

(ert-deftest prrr-treesit-test-mode-hooks-never-run ()
  "Borrowing rules runs no hook the user put on the mode."
  (prrr-treesit-test--with-languages '(("\\.foo\\'" . prrr-treesit-test-foo-ts-mode))
    (let ((prrr-treesit-test--hooked nil)
          (prrr-treesit-test-foo-ts-mode-hook
           (list (lambda () (setq prrr-treesit-test--hooked t)))))
      (prrr-treesit-rules "a.foo")
      (should-not prrr-treesit-test--hooked))))

(ert-deftest prrr-treesit-test-missing-grammar-is-silent ()
  "A mode without its grammar gives no rules and no warning, and is cached."
  (prrr-treesit-test--with-languages '(("\\.ng\\'" . prrr-treesit-test-nogrammar-ts-mode))
    (when (get-buffer "*Warnings*") (kill-buffer "*Warnings*"))
    (should-not (prrr-treesit-rules "a.ng"))
    (should-not (get-buffer "*Warnings*"))
    (should (eq 'none (gethash 'prrr-treesit-test-nogrammar-ts-mode
                               prrr-treesit--languages)))))

(ert-deftest prrr-treesit-test-broken-mode-reported-once ()
  (prrr-treesit-test--with-languages '(("\\.br\\'" . prrr-treesit-test-broken-ts-mode))
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (push (apply #'format format args) messages))))
        (should-not (prrr-treesit-rules "a.br"))
        (should-not (prrr-treesit-rules "b.br")))
      (should (= 1 (length messages)))
      (should (string-match-p "prrr-treesit-test-broken-ts-mode" (car messages)))
      (should (string-match-p "Broken mode" (car messages))))))

(ert-deftest prrr-treesit-test-no-treesit-no-rules ()
  "Emacs built without tree-sitter highlights nothing and runs no mode."
  (prrr-treesit-test--with-languages '(("\\.br\\'" . prrr-treesit-test-broken-ts-mode))
    (cl-letf (((symbol-function 'treesit-available-p) #'ignore))
      (should-not (prrr-treesit-rules "a.br"))
      (should (zerop (hash-table-count prrr-treesit--languages))))))

(provide 'prrr-treesit-test)
;;; prrr-treesit-test.el ends here
