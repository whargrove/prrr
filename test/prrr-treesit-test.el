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
(require 'prrr-diff-test)

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

(define-derived-mode prrr-treesit-test-leaky-ts-mode fundamental-mode "leaky"
  "A tree-sitter mode that changes mode selection, as loading a real one can."
  (push '("\\.zz\\'" . ignore) auto-mode-alist)
  (push '("zz" . ignore) interpreter-mode-alist)
  (when (boundp 'major-mode-remap-defaults)
    (push '(prrr-treesit-test-bar-mode . ignore) major-mode-remap-defaults)))

(define-derived-mode prrr-treesit-test-chatty-ts-mode fundamental-mode "chatty"
  "A tree-sitter mode that talks, as `python-ts-mode' does."
  (message "prrr-treesit-test chatter"))

(defalias 'prrr-treesit-test-foo-alias-mode #'prrr-treesit-test-foo-mode
  "An alias of `prrr-treesit-test-foo-mode', as `javascript-mode' is of `js-mode'.")

(defalias 'prrr-treesit-test-foo-alias-alias-mode #'prrr-treesit-test-foo-alias-mode
  "An alias of an alias.")

(defvar prrr-treesit-test--hooked nil
  "Set by `prrr-treesit-test-foo-ts-mode-hook' when it runs.")

(defmacro prrr-treesit-test--with-languages (alist &rest body)
  "Run BODY with `auto-mode-alist' ALIST, no remapping and an empty rules cache.
`prrr-highlight-modes' is empty."
  (declare (indent 1))
  `(let ((auto-mode-alist ,alist)
         (prrr-highlight-modes nil)
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

(ert-deftest prrr-treesit-test-aliases-resolved ()
  "An alias is followed to its mode before FOO-ts-mode is looked for."
  (prrr-treesit-test--with-languages '(("\\.fa\\'" . prrr-treesit-test-foo-alias-mode)
                                       ("\\.faa\\'" . prrr-treesit-test-foo-alias-alias-mode))
    (should (eq 'prrr-treesit-test-foo-ts-mode (prrr-treesit-mode "a.fa")))
    (should (eq 'prrr-treesit-test-foo-ts-mode (prrr-treesit-mode "a.faa")))))

(ert-deftest prrr-treesit-test-option-regexp ()
  "A file-name regexp of `prrr-highlight-modes' comes before `auto-mode-alist'."
  (prrr-treesit-test--with-languages '(("\\.bar\\'" . prrr-treesit-test-bar-mode))
    (let ((prrr-highlight-modes '(("\\.qux\\'" . prrr-treesit-test-foo-ts-mode)
                                  ("/special\\.bar\\'" . prrr-treesit-test-foo-ts-mode))))
      (should (eq 'prrr-treesit-test-foo-ts-mode (prrr-treesit-mode "src/a.qux")))
      (should (eq 'prrr-treesit-test-foo-ts-mode (prrr-treesit-mode "src/special.bar")))
      (should-not (prrr-treesit-mode "src/other.bar")))))

(ert-deftest prrr-treesit-test-option-mode ()
  "A mode key of `prrr-highlight-modes' names the ts-mode for that mode."
  (prrr-treesit-test--with-languages '(("\\.bar\\'" . prrr-treesit-test-bar-mode)
                                       ("\\.foo\\'" . prrr-treesit-test-foo-mode))
    (let ((prrr-highlight-modes
           '((prrr-treesit-test-bar-mode . prrr-treesit-test-foo-ts-mode)
             (prrr-treesit-test-foo-mode . prrr-treesit-test-nogrammar-ts-mode))))
      (should (eq 'prrr-treesit-test-foo-ts-mode (prrr-treesit-mode "a.bar")))
      (should (eq 'prrr-treesit-test-nogrammar-ts-mode (prrr-treesit-mode "a.foo"))))))

(ert-deftest prrr-treesit-test-option-undefined-skipped ()
  "Entries of `prrr-highlight-modes' naming an undefined mode are passed over."
  (prrr-treesit-test--with-languages '(("\\.foo\\'" . prrr-treesit-test-foo-mode)
                                       ("\\.bar\\'" . prrr-treesit-test-bar-mode))
    (let ((prrr-highlight-modes
           '(("\\.qux\\'" . prrr-treesit-test-no-such-ts-mode)
             ("\\.qux\\'" . prrr-treesit-test-foo-ts-mode)
             ("\\.foo\\'" . prrr-treesit-test-no-such-ts-mode)
             (prrr-treesit-test-foo-mode . prrr-treesit-test-no-such-ts-mode)
             (prrr-treesit-test-bar-mode . prrr-treesit-test-no-such-ts-mode))))
      (should (eq 'prrr-treesit-test-foo-ts-mode (prrr-treesit-mode "a.qux")))
      (should (eq 'prrr-treesit-test-foo-ts-mode (prrr-treesit-mode "a.foo")))
      (should-not (prrr-treesit-mode "a.bar")))))

(ert-deftest prrr-treesit-test-case-folded-second-pass ()
  "As visiting does, a name matching no entry is tried again ignoring case."
  (prrr-treesit-test--with-languages '(("\\.c\\'" . c-mode)
                                       ("\\.foo\\'" . prrr-treesit-test-foo-ts-mode))
    (should (eq 'c-ts-mode (prrr-treesit-mode "src/FOO.C")))
    (should (eq 'prrr-treesit-test-foo-ts-mode (prrr-treesit-mode "A.FOO")))
    (let ((auto-mode-case-fold nil))
      (should-not (prrr-treesit-mode "A.FOO")))))

(ert-deftest prrr-treesit-test-stock-languages ()
  "On a stock Emacs, common languages find their ts-mode."
  (let ((prrr-highlight-modes (eval (car (get 'prrr-highlight-modes 'standard-value)) t)))
    (pcase-dolist (`(,path . ,mode) '(("src/a.js" . js-ts-mode)
                                      ("bin/run.sh" . bash-ts-mode)
                                      ("src/main.rs" . rust-ts-mode)
                                      ("package.json" . json-ts-mode)
                                      ("cmd/main.go" . go-ts-mode)
                                      ("go.mod" . go-mod-ts-mode)
                                      ("web/a.ts" . typescript-ts-mode)
                                      ("Dockerfile" . dockerfile-ts-mode)
                                      ("index.html" . html-ts-mode)))
      (when (fboundp mode)
        (should (equal (cons path mode) (cons path (prrr-treesit-mode path))))))))

(ert-deftest prrr-treesit-test-mode-selection-unchanged ()
  "Borrowing rules leaves how files are visited as it was."
  (let ((auto-mode-alist (cons '("\\.lk\\'" . prrr-treesit-test-leaky-ts-mode)
                               auto-mode-alist))
        (interpreter-mode-alist interpreter-mode-alist)
        (prrr-treesit--languages (make-hash-table :test #'eq)))
    (cl-progv (and (boundp 'major-mode-remap-defaults) '(major-mode-remap-defaults))
        (and (boundp 'major-mode-remap-defaults) (list major-mode-remap-defaults))
      (let ((before (list auto-mode-alist interpreter-mode-alist
                          (bound-and-true-p major-mode-remap-defaults))))
        (prrr-treesit-rules "a.lk")
        (should (equal before (list auto-mode-alist interpreter-mode-alist
                                    (bound-and-true-p major-mode-remap-defaults))))))))

(ert-deftest prrr-treesit-test-real-modes-leave-mode-selection ()
  "Loading real ts-modes to borrow their rules adds no entry or remap."
  (skip-unless (treesit-language-available-p 'c))
  (let ((auto-mode-alist auto-mode-alist)
        (interpreter-mode-alist interpreter-mode-alist)
        (prrr-treesit--languages (make-hash-table :test #'eq)))
    (cl-progv (and (boundp 'major-mode-remap-defaults) '(major-mode-remap-defaults))
        (and (boundp 'major-mode-remap-defaults) (list major-mode-remap-defaults))
      (let ((before (list auto-mode-alist interpreter-mode-alist
                          (bound-and-true-p major-mode-remap-defaults))))
        (pcase-dolist (`(,language . ,path) '((c . "src/a.c") (rust . "src/a.rs")
                                              (go . "src/a.go")))
          (when (treesit-language-available-p language)
            (should (prrr-treesit-rules path))))
        (should (equal before (list auto-mode-alist interpreter-mode-alist
                                    (bound-and-true-p major-mode-remap-defaults))))))))

(ert-deftest prrr-treesit-test-mode-bodies-silent ()
  "What a ts-mode prints while its rules are borrowed reaches no one."
  (prrr-treesit-test--with-languages '(("\\.ch\\'" . prrr-treesit-test-chatty-ts-mode))
    (prrr-treesit-rules "a.ch")
    (with-current-buffer (messages-buffer)
      (should-not (save-excursion
                    (goto-char (point-min))
                    (search-forward "prrr-treesit-test chatter" nil t))))))

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


;;;; Highlighting

(defmacro prrr-treesit-test--with-buffer (&rest body)
  "Open the C fixture's Review Buffer, every file collapsed, and run BODY.
Highlighting is on, with C rules from `c-ts-mode'."
  (declare (indent 0))
  `(let ((prrr-test-repo-script "make-c-repo.sh")
         (prrr-eager-files 0)
         (prrr-highlight t)
         (auto-mode-alist (cons '("\\.c\\'" . c-mode) auto-mode-alist))
         (prrr-treesit--languages (make-hash-table :test #'eq)))
     (prrr-diff-test--with-buffer nil
       ,@body)))

(defun prrr-treesit-test--find (text)
  "Return the position of the first TEXT in the buffer, after its line's prefix."
  (save-excursion
    (goto-char (point-min))
    (search-forward text)
    (match-beginning 0)))

(defun prrr-treesit-test--faces (pos)
  "Return the syntax faces at POS, as a list."
  (ensure-list (get-text-property pos 'prrr-treesit-face)))

(ert-deftest prrr-treesit-test-nothing-before-shown ()
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (should-not (text-property-not-all (point-min) (point-max) 'prrr-treesit-face nil))))

(ert-deftest prrr-treesit-test-expanding-highlights-both-sides ()
  "Added, context and removed lines get their faces; prefixes and headings none."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (magit-section-show (prrr-diff-test--file-section "src/sample.c"))
    (let ((added (prrr-treesit-test--find "int answer = 42"))
          (removed (prrr-treesit-test--find "int answer = 41"))
          (context (prrr-treesit-test--find "\"%d\\n\""))
          (comment (prrr-treesit-test--find "/* print the answer */")))
      (should (memq 'font-lock-type-face (prrr-treesit-test--faces added)))
      (should (memq 'font-lock-type-face (prrr-treesit-test--faces removed)))
      (should (memq 'font-lock-string-face (prrr-treesit-test--faces context)))
      (should (memq 'font-lock-comment-face (prrr-treesit-test--faces comment)))
      (should-not (prrr-treesit-test--faces (1- added)))
      (should-not (prrr-treesit-test--faces (1- removed)))
      (let ((hunk (car (prrr-diff-test--hunks "src/sample.c"))))
        (should-not (text-property-not-all (oref hunk start) (oref hunk content)
                                           'prrr-treesit-face nil))))))

(ert-deftest prrr-treesit-test-line-face-kept-behind-tokens ()
  "The token face comes first in `font-lock-face'; the diff line's face stays."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (magit-section-show (prrr-diff-test--file-section "src/sample.c"))
    (let ((faces (ensure-list (get-text-property (prrr-treesit-test--find "int answer = 42")
                                                 'font-lock-face))))
      (should (eq 'font-lock-type-face (car faces)))
      (should (seq-some (lambda (face) (memq face '(magit-diff-added magit-diff-added-highlight)))
                        faces)))))

(ert-deftest prrr-treesit-test-repaint-keeps-faces ()
  "Magit resets `font-lock-face' on every paint; the syntax faces come back."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (let ((hunk (car (prrr-diff-test--hunks "src/sample.c")))
          (pos (prrr-treesit-test--find "int answer = 42")))
      (dolist (highlight '(t nil t))
        (save-excursion
          (goto-char (oref hunk start))
          (let ((inhibit-read-only t))
            (magit-section-paint hunk highlight)))
        (let ((faces (ensure-list (get-text-property pos 'font-lock-face))))
          (should (eq 'font-lock-type-face (car faces)))
          (should (= 1 (seq-count (lambda (face) (eq face 'font-lock-type-face)) faces)))
          (should (memq (if highlight 'magit-diff-added-highlight 'magit-diff-added) faces)))))))

(ert-deftest prrr-treesit-test-threads-not-colored ()
  "A Thread inside a hunk gets no syntax faces; the lines after it still do."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (prrr-db-insert (prrr-thread-create :thread-id "T_C" :pr-id prrr-diff-test--pr
                                        :path "src/sample.c" :line 3 :side 'right
                                        :subject-type 'line))
    (magit-refresh-buffer)
    (let* ((hunk (car (prrr-diff-test--hunks "src/sample.c")))
           (thread (car (oref hunk children))))
      (should (eq 'thread (oref thread type)))
      (should-not (text-property-not-all (oref thread start) (oref thread end)
                                         'prrr-treesit-face nil))
      (should (memq 'font-lock-type-face
                    (prrr-treesit-test--faces (prrr-treesit-test--find "int main")))))))

(ert-deftest prrr-treesit-test-no-grammar-no-faces ()
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (let ((file (prrr-diff-test--file-section "notes.txt")))
      (magit-section-show file)
      (should-not (text-property-not-all (oref file start) (oref file end)
                                         'prrr-treesit-face nil)))))

(ert-deftest prrr-treesit-test-off-means-no-faces ()
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (setq-local prrr-highlight nil)
    (magit-section-show (prrr-diff-test--file-section "src/sample.c"))
    (should-not (text-property-not-all (point-min) (point-max) 'prrr-treesit-face nil))))

(ert-deftest prrr-treesit-test-highlighted-once ()
  "Showing, hiding, showing and repainting highlight a file once."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (let ((calls 0)
          (highlight (symbol-function 'prrr-treesit-highlight))
          (file (prrr-diff-test--file-section "src/sample.c")))
      (cl-letf (((symbol-function 'prrr-treesit-highlight)
                 (lambda (section) (cl-incf calls) (funcall highlight section))))
        (magit-section-show file)
        (magit-section-hide file)
        (magit-section-show file)
        (let ((hunk (car (prrr-diff-test--hunks "src/sample.c"))))
          (save-excursion (goto-char (oref hunk start))
                         (let ((inhibit-read-only t))
                           (magit-section-paint hunk t)))))
      (should (= 1 calls)))))

(ert-deftest prrr-treesit-test-failure-reported-not-raised ()
  "A failing highlight is a message; the file still shows."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (let ((messages nil)
          (file (prrr-diff-test--file-section "src/sample.c")))
      (cl-letf (((symbol-function 'prrr-treesit-highlight)
                 (lambda (_section) (error "Parser exploded")))
                ((symbol-function 'message)
                 (lambda (format &rest args) (push (apply #'format format args) messages))))
        (magit-section-show file))
      (should-not (oref file hidden))
      (should (seq-some (lambda (text) (string-match-p "src/sample.c.*Parser exploded" text))
                        messages)))))

(ert-deftest prrr-treesit-test-hunk-inside-comment ()
  "A hunk starting inside a block comment highlights without error, in its file only."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (let ((file (prrr-diff-test--file-section "src/comment.c")))
      (magit-section-show file)
      ;; The fragment starts inside the comment, so the grammar sees code, not
      ;; a comment: the changed line may be mis-colored (a known limit).
      (should (text-property-not-all (oref file start) (oref file end) 'prrr-treesit-face nil)))))

(ert-deftest prrr-treesit-test-function-capture-and-no-face ()
  "A capture that is a function colors too; the `face' property is never written."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (let ((file (prrr-diff-test--file-section "src/sample.c")))
      (magit-section-show file)
      (should (memq 'font-lock-function-name-face
                    (prrr-treesit-test--faces (prrr-treesit-test--find "main"))))
      (should-not (text-property-not-all (oref file start) (oref file end) 'face nil)))))

(ert-deftest prrr-treesit-test-file-without-hunks ()
  "A renamed file with no hunks shows its note and gets no faces."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (let ((file (prrr-diff-test--file-section "src/renamed.c")))
      (prrr-treesit-highlight file)
      (magit-section-show file)
      (should-not (text-property-not-all (oref file start) (oref file end)
                                         'prrr-treesit-face nil)))))

;;;; Deferral and the toggle

(defvar prrr-treesit-test--idle nil
  "The (BUFFER) arguments of the idle timers set, newest first.")

(defmacro prrr-treesit-test--with-idle-stub (&rest body)
  "Run BODY with `run-with-idle-timer' recording into `prrr-treesit-test--idle'."
  (declare (indent 0))
  `(let ((prrr-treesit-test--idle nil))
     (cl-letf (((symbol-function 'run-with-idle-timer)
                (lambda (_secs _repeat _function &rest args)
                  (push args prrr-treesit-test--idle)
                  'prrr-treesit-test-timer))
               ((symbol-function 'cancel-timer) #'ignore))
       ,@body)))

(defun prrr-treesit-test--colored-p (path)
  "Non-nil when the `file' section of PATH has syntax faces."
  (let ((file (prrr-diff-test--file-section path)))
    (text-property-not-all (oref file start) (oref file end) 'prrr-treesit-face nil)))

(ert-deftest prrr-treesit-test-refresh-defers-to-idle ()
  "Files shown by a refresh wait for the idle timer, so first paint does not."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-idle-stub
    (prrr-treesit-test--with-buffer
      (setq-local prrr-eager-files 10)
      (magit-refresh-buffer)
      (should-not (prrr-treesit-test--colored-p "src/sample.c"))
      (should prrr-treesit-test--idle)
      (prrr-treesit--drain (current-buffer))
      (should (prrr-treesit-test--colored-p "src/sample.c")))))

(ert-deftest prrr-treesit-test-large-file-defers-to-idle ()
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-idle-stub
    (prrr-treesit-test--with-buffer
      (let ((prrr-highlight-max-lines 30))
        (magit-section-show (prrr-diff-test--file-section "src/sample.c"))
        (should (prrr-treesit-test--colored-p "src/sample.c"))
        (magit-section-show (prrr-diff-test--file-section "src/big.c"))
        (should-not (prrr-treesit-test--colored-p "src/big.c"))
        (prrr-treesit--drain (current-buffer))
        (should (prrr-treesit-test--colored-p "src/big.c"))))))

(ert-deftest prrr-treesit-test-drain-skips-stale-sections ()
  "A refresh while a file waits leaves the old section unhighlighted, without error."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-idle-stub
    (prrr-treesit-test--with-buffer
      (let ((prrr-highlight-max-lines 30)
            (highlighted nil)
            (highlight (symbol-function 'prrr-treesit-highlight)))
        (magit-section-show (prrr-diff-test--file-section "src/big.c"))
        (let ((stale (prrr-diff-test--file-section "src/big.c")))
          (magit-refresh-buffer)
          (cl-letf (((symbol-function 'prrr-treesit-highlight)
                     (lambda (section) (push section highlighted) (funcall highlight section))))
            (prrr-treesit--drain (current-buffer)))
          (should-not (memq stale highlighted))
          (should (prrr-treesit-test--colored-p "src/big.c")))))))

(ert-deftest prrr-treesit-test-drain-yields-to-input ()
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-idle-stub
    (prrr-treesit-test--with-buffer
      (let ((prrr-highlight-max-lines 30))
        (magit-section-show (prrr-diff-test--file-section "src/big.c"))
        (setq prrr-treesit-test--idle nil)
        (cl-letf (((symbol-function 'input-pending-p) (lambda (&rest _) t)))
          (prrr-treesit--drain (current-buffer)))
        (should-not (prrr-treesit-test--colored-p "src/big.c"))
        (should prrr-treesit--queue)
        (should prrr-treesit-test--idle)))))

(ert-deftest prrr-treesit-test-kill-cancels-timer ()
  (skip-unless (treesit-language-available-p 'c))
  (let ((buffer nil) (timer nil))
    (prrr-treesit-test--with-buffer
      (let ((prrr-highlight-max-lines 30))
        (magit-section-show (prrr-diff-test--file-section "src/big.c"))
        (setq buffer (current-buffer) timer prrr-treesit--timer)
        (should (memq timer timer-idle-list))))
    (should-not (buffer-live-p buffer))
    (should-not (memq timer timer-idle-list))))

(ert-deftest prrr-treesit-test-ceiling ()
  "Files over ten times `prrr-highlight-max-lines' are never highlighted."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-idle-stub
    (prrr-treesit-test--with-buffer
      (let ((prrr-highlight-max-lines 3))
        (magit-section-show (prrr-diff-test--file-section "src/sample.c"))
        (magit-section-show (prrr-diff-test--file-section "src/big.c"))
        (prrr-treesit--drain (current-buffer))
        (should (prrr-treesit-test--colored-p "src/sample.c"))
        (should-not (prrr-treesit-test--colored-p "src/big.c"))
        (should-not prrr-treesit--queue)))))

(ert-deftest prrr-treesit-test-reopen-keeps-toggle ()
  "L lasts for the buffer: reopening it, which reruns its mode, keeps it off."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-idle-stub
    (prrr-treesit-test--with-buffer
      (prrr-toggle-highlight)
      (should-not prrr-highlight)
      (should (eq (current-buffer) (prrr-diff-setup-buffer (prrr-diff-test--pullreq))))
      (should-not prrr-highlight)
      (magit-section-show (prrr-diff-test--file-section "src/sample.c"))
      (should-not (prrr-treesit-test--colored-p "src/sample.c")))))

(ert-deftest prrr-treesit-test-reopen-cancels-timer ()
  "Reopening the buffer cancels the idle highlighting it had pending."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-buffer
    (let ((prrr-highlight-max-lines 30))
      (magit-section-show (prrr-diff-test--file-section "src/big.c"))
      (let ((timer prrr-treesit--timer))
        (should (memq timer timer-idle-list))
        (prrr-diff-setup-buffer (prrr-diff-test--pullreq))
        (should-not (memq timer timer-idle-list))
        ;; The reopened buffer may queue its files again, under one timer.
        (should (>= 1 (seq-count (lambda (timer)
                                   (equal (list (current-buffer)) (timer--args timer)))
                                 timer-idle-list)))))))

(ert-deftest prrr-treesit-test-toggle ()
  "L turns highlighting off in this buffer only, and back on."
  (skip-unless (treesit-language-available-p 'c))
  (prrr-treesit-test--with-idle-stub
    (prrr-treesit-test--with-buffer
      (magit-section-show (prrr-diff-test--file-section "src/sample.c"))
      (should (prrr-treesit-test--colored-p "src/sample.c"))
      (prrr-toggle-highlight)
      (should-not prrr-highlight)
      (should (default-value 'prrr-highlight))
      (should (zerop (hash-table-count prrr-treesit--languages)))
      (should-not (text-property-not-all (point-min) (point-max) 'prrr-treesit-face nil))
      (prrr-toggle-highlight)
      (should prrr-highlight)
      (prrr-treesit--drain (current-buffer))
      (should (prrr-treesit-test--colored-p "src/sample.c")))))

(ert-deftest prrr-treesit-test-l-key ()
  (should (eq 'prrr-toggle-highlight (keymap-lookup prrr-diff-mode-map "L")))
  (should (eq 'prrr-toggle-highlight (keymap-lookup prrr-diff-file-section-map "L")))
  (should (eq 'prrr-toggle-highlight (keymap-lookup prrr-diff-hunk-section-map "L"))))

(provide 'prrr-treesit-test)
;;; prrr-treesit-test.el ends here
