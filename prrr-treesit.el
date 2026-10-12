;;; prrr-treesit.el --- Syntax highlighting in the Review Buffer  -*- lexical-binding: t -*-

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

;; Deferred per-file tree-sitter highlighting (SPEC section 6).  A
;; file's language is the one visiting it would choose, and its
;; highlighting rules are borrowed from that language's ts-mode, run
;; once in a temporary buffer.  Files without a grammar are left
;; unhighlighted.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'treesit)
(require 'warnings)
(require 'prrr-diff)

(defcustom prrr-highlight t
  "Whether Review Buffers highlight the syntax of their diff lines.
Highlighting needs Emacs built with tree-sitter and the grammar of a
file's language; files without one are left unhighlighted."
  :type 'boolean
  :group 'prrr)

(defcustom prrr-highlight-max-lines 3000
  "Largest file section, in lines, highlighted as soon as it is shown.
A larger one is highlighted when Emacs is next idle."
  :type 'natnum
  :group 'prrr)

;;;; Languages

(defvar prrr-treesit--languages (make-hash-table :test #'eq)
  "Cache from a tree-sitter major mode to (LANGUAGE . SETTINGS), or `none'.
SETTINGS are the mode's compiled `treesit-font-lock-settings', with the
features `treesit-font-lock-level' enables.  `none' when the mode
offers no rules here, for want of a grammar, say.")

(defun prrr-treesit--auto-mode (path)
  "Return the major mode `auto-mode-alist' gives PATH, or nil.
Only entries naming a mode count: one asking to strip a suffix and look
again, as a compressed file's does, is passed over."
  (let ((case-fold-search nil))
    (seq-some (lambda (entry)
                (and (cdr entry) (symbolp (cdr entry))
                     (string-match-p (car entry) path)
                     (cdr entry)))
              auto-mode-alist)))

(defun prrr-treesit--remap (mode)
  "Return the mode MODE is remapped to, else MODE.
On Emacs 30 and later `major-mode-remap' also reads
`major-mode-remap-defaults'; Emacs 29 has only `major-mode-remap-alist'."
  (if (fboundp 'major-mode-remap)
      (major-mode-remap mode)
    (or (alist-get mode major-mode-remap-alist) mode)))

(defun prrr-treesit-mode (path)
  "Return the tree-sitter major mode whose rules highlight PATH, or nil.
The mode is the one visiting PATH would choose, through `auto-mode-alist'
and the remapping options.  When that is FOO-mode, not a tree-sitter
mode, FOO-ts-mode stands in if it is defined: prrr borrows only its
highlighting rules, so how the user edits is unchanged."
  (when-let* ((mode (prrr-treesit--auto-mode path)))
    (let* ((mode (prrr-treesit--remap mode))
           (name (symbol-name mode)))
      (cond ((string-suffix-p "-ts-mode" name) mode)
            ((string-suffix-p "-mode" name)
             (let ((ts (intern-soft (concat (string-remove-suffix "-mode" name) "-ts-mode"))))
               (and ts (fboundp ts) ts)))))))

(defun prrr-treesit--extract (mode)
  "Run MODE in a temporary buffer; return its (LANGUAGE . SETTINGS) or nil.
Its mode hooks are delayed and never run, so nothing the user hooked
on, a language server say, starts.  Warnings are silenced: a missing
grammar means no highlighting, not a message."
  (with-temp-buffer
    (let ((warning-minimum-level :emergency)
          (warning-minimum-log-level :emergency))
      (delay-mode-hooks (funcall mode)))
    (when-let* ((settings treesit-font-lock-settings)
                (language (if-let* ((primary (bound-and-true-p treesit-primary-parser)))
                              (treesit-parser-language primary)
                            (treesit-query-language (nth 0 (car settings))))))
      (cons language settings))))

(defun prrr-treesit-rules (path)
  "Return the (LANGUAGE . SETTINGS) that highlight PATH, or nil.
See `prrr-treesit--languages'.  A mode that fails is reported once
and cached as offering none."
  (when-let* (((treesit-available-p))
              (mode (prrr-treesit-mode path)))
    (let ((rules (gethash mode prrr-treesit--languages)))
      (unless rules
        (setq rules (or (condition-case err
                            (prrr-treesit--extract mode)
                          (error (message "prrr: no highlighting from %s: %s"
                                          mode (error-message-string err))
                                 nil))
                        'none))
        (puthash mode rules prrr-treesit--languages))
      (unless (eq rules 'none) rules))))

(provide 'prrr-treesit)
;;; prrr-treesit.el ends here
