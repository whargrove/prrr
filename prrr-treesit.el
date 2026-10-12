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


;;;; Highlighting a file section

(defvar prrr-treesit--paint nil
  "While one side of a file is colored: a vector of the (BEG . END) it may color.
In order and not overlapping.")

(defun prrr-treesit--first-range (pos)
  "Return the index of the first range of `prrr-treesit--paint' ending after POS."
  (let ((low 0)
        (high (length prrr-treesit--paint)))
    (while (< low high)
      (let ((middle (/ (+ low high) 2)))
        (if (<= (cdr (aref prrr-treesit--paint middle)) pos)
            (setq low (1+ middle))
          (setq high middle))))
    low))

(defun prrr-treesit--fontify (start end face override &optional bound-start bound-end)
  "Apply FACE from START to END as `treesit-fontify-with-override' does.
OVERRIDE, BOUND-START and BOUND-END are as for that function.  The face
goes on `prrr-treesit-face', not `face', and only within the ranges of
`prrr-treesit--paint': a node spanning several lines also spans the
other side's lines and the Threads between them."
  (when (and bound-start bound-end)
    (setq start (max start bound-start)
          end (min end bound-end)))
  (let ((index (prrr-treesit--first-range start)))
    (while (and (< index (length prrr-treesit--paint))
                (< (car (aref prrr-treesit--paint index)) end))
      (let ((beg (max start (car (aref prrr-treesit--paint index))))
            (stop (min end (cdr (aref prrr-treesit--paint index)))))
        (when (< beg stop)
          (pcase override
            ('nil (unless (text-property-not-all beg stop 'prrr-treesit-face nil)
                    (put-text-property beg stop 'prrr-treesit-face face)))
            ('t (put-text-property beg stop 'prrr-treesit-face face))
            ('append (font-lock-append-text-property beg stop 'prrr-treesit-face face))
            ('prepend (font-lock-prepend-text-property beg stop 'prrr-treesit-face face))
            ('keep (font-lock-fillin-text-property beg stop 'prrr-treesit-face face))
            (_ (signal 'treesit-font-lock-error
                       (list "Unrecognized value of :override option" override))))))
      (cl-incf index))))

(defun prrr-treesit--fontify-side (rules parse paint)
  "Parse the ranges PARSE with RULES' language and color those of PAINT.
RULES is (LANGUAGE . SETTINGS) from `prrr-treesit-rules'.  PARSE and
PAINT are lists of (BEG . END) in order, PAINT a subset of PARSE.  The
parser lives only for this call.  Settings whose capture is a function
call `treesit-fontify-with-override' themselves, so that is
`prrr-treesit--fontify' meanwhile."
  (when paint
    (let ((language (car rules))
          (start (car (car parse)))
          (end (cdr (car (last parse))))
          (parser (treesit-parser-create (car rules) nil t)))
      (unwind-protect
          (let ((prrr-treesit--paint (vconcat paint)))
            (treesit-parser-set-included-ranges parser parse)
            (cl-letf (((symbol-function 'treesit-fontify-with-override)
                       #'prrr-treesit--fontify))
              (dolist (setting (cdr rules))
                (let ((query (nth 0 setting))
                      (override (nth 3 setting)))
                  (when (and (eq (nth 1 setting) t)
                             (eq (treesit-query-language query) language))
                    (pcase-dolist (`(,face . ,node)
                                   (treesit-query-capture (treesit-parser-root-node parser)
                                                          query start end))
                      (cond ((facep face)
                             (prrr-treesit--fontify (treesit-node-start node)
                                                    (treesit-node-end node)
                                                    face override))
                            ((functionp face)
                             (funcall face node override start end)))))))))
        (treesit-parser-delete parser)))))

(defun prrr-treesit--lines (file)
  "Return the diff lines of FILE, a `file' section, as (KIND BEG . END).
In order.  KIND is the line's first character, BEG..END its text after
it through the newline.  Threads, \"No newline\" markers and the
hunks of combined diffs are left out."
  (let ((lines nil))
    (dolist (hunk (oref file children))
      (when (and (eq (oref hunk type) 'hunk) (not (oref hunk combined)))
        (prrr-diff-walk-hunk
         hunk (lambda (kind _old _new)
                (when (memq kind '(?\s ?+ ?-))
                  (push (cons kind (cons (1+ (point))
                                         (min (point-max) (1+ (line-end-position)))))
                        lines))))))
    (nreverse lines)))

(defun prrr-treesit-highlight (file)
  "Highlight the syntax of the diff lines of FILE, a Review Buffer `file' section.
The new side (context and added lines) and the old side (context and
removed lines) are parsed apart, each as one text; context lines take
the new side's faces.  Faces go on `prrr-treesit-face' and are merged
into `font-lock-face' (`prrr-treesit--merge').  Does nothing when no
rules highlight the file (`prrr-treesit-rules'), it has no diff lines,
or the buffer is too large for tree-sitter."
  (when-let* ((rules (prrr-treesit-rules (oref file value)))
              ((treesit-ready-p (car rules) t))
              (lines (prrr-treesit--lines file)))
    (let ((new nil) (old nil) (removed nil))
      (pcase-dolist (`(,kind . ,range) lines)
        (unless (eq kind ?-) (push range new))
        (unless (eq kind ?+) (push range old))
        (when (eq kind ?-) (push range removed)))
      (setq new (nreverse new) old (nreverse old) removed (nreverse removed))
      (with-silent-modifications
        (prrr-treesit--fontify-side rules new new)
        (prrr-treesit--fontify-side rules old removed))
      (prrr-treesit--merge (cadr (car lines)) (cddr (car (last lines)))))))

(defun prrr-treesit--merge (start end)
  "Put the faces of `prrr-treesit-face' in front of `font-lock-face', START to END.
magit paints a diff line by setting its `font-lock-face' to the line's
face, so this runs after every paint.  Running it twice changes nothing."
  (with-silent-modifications
    (let ((pos start))
      (while (< pos end)
        (let ((next (next-single-property-change pos 'prrr-treesit-face nil end))
              (tokens (ensure-list (get-text-property pos 'prrr-treesit-face))))
          (when tokens
            (let ((at pos))
              (while (< at next)
                (let ((stop (next-single-property-change at 'font-lock-face nil next))
                      (line (ensure-list (get-text-property at 'font-lock-face))))
                  (put-text-property at stop 'font-lock-face
                                     (append tokens (seq-difference line tokens)))
                  (setq at stop)))))
          (setq pos next))))))

(defvar-local prrr-treesit--done nil
  "Weak table of the `file' sections highlighted, or on their way, here.
Each refresh makes new sections, so it starts them all afresh.")

(defun prrr-treesit--highlight-reporting (file)
  "Run `prrr-treesit-highlight' on FILE; report a failure rather than raise it.
It runs while magit paints, where an error would break the whole redraw."
  (condition-case err
      (prrr-treesit-highlight file)
    (error (message "prrr: highlighting %s failed: %s"
                    (oref file value) (error-message-string err)))))

(defvar-local prrr-treesit--queue nil
  "The `file' sections waiting for the idle timer, oldest first.")

(defvar-local prrr-treesit--timer nil
  "The idle timer that highlights `prrr-treesit--queue', or nil.")

(defun prrr-treesit--request (file)
  "Highlight FILE, a `file' section, unless it was already or highlighting is off.
A file painted during a refresh, or longer than
`prrr-highlight-max-lines', waits for Emacs to be idle, so neither the
first paint nor a refresh waits on it.  `magit--refreshing-buffer-p' is
magit's own flag for deferring paint work in a refresh."
  (when (and prrr-highlight (eq (oref file type) 'file))
    (unless prrr-treesit--done
      (setq prrr-treesit--done (make-hash-table :test #'eq :weakness 'key)))
    (unless (gethash file prrr-treesit--done)
      (puthash file t prrr-treesit--done)
      (if (or magit--refreshing-buffer-p
              (> (count-lines (oref file content) (oref file end)) prrr-highlight-max-lines))
          (prrr-treesit--enqueue file)
        (prrr-treesit--highlight-reporting file)))))

(defun prrr-treesit--enqueue (file)
  "Queue FILE to be highlighted when Emacs is next idle."
  (setq prrr-treesit--queue (nconc prrr-treesit--queue (list file)))
  (unless prrr-treesit--timer
    (setq prrr-treesit--timer
          (run-with-idle-timer 0 nil #'prrr-treesit--drain (current-buffer)))))

(defun prrr-treesit--live-p (file)
  "Non-nil when FILE is still a section of the current buffer.
A refresh replaces every section."
  (eq file (magit-get-section (magit-section-ident file))))

(defun prrr-treesit--drain (buffer)
  "Highlight the queued files of BUFFER, oldest first, yielding to input.
A file a refresh replaced is dropped: its new section queues itself
when painted.  What is left when input arrives waits for the next idle
time."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq prrr-treesit--timer nil)
      (while (and prrr-treesit--queue (not (input-pending-p)))
        (let ((file (pop prrr-treesit--queue)))
          (when (prrr-treesit--live-p file)
            (prrr-treesit--highlight-reporting file))))
      (when prrr-treesit--queue
        (setq prrr-treesit--timer
              (run-with-idle-timer 0 nil #'prrr-treesit--drain buffer))))))

(defun prrr-treesit--cancel ()
  "Cancel this buffer's idle highlighting; for `kill-buffer-hook'."
  (when prrr-treesit--timer
    (cancel-timer prrr-treesit--timer)
    (setq prrr-treesit--timer nil)))

(defun prrr-treesit--setup ()
  "Make killing this Review Buffer cancel its idle highlighting (SPEC section 11)."
  (add-hook 'kill-buffer-hook #'prrr-treesit--cancel nil t))

(add-hook 'prrr-diff-mode-hook #'prrr-treesit--setup)

;;;###autoload
(defun prrr-toggle-highlight ()
  "Toggle syntax highlighting in this Review Buffer.
Sets `prrr-highlight' in this buffer only, rereads the languages'
highlighting rules, so a changed `treesit-font-lock-level' applies, and
redraws at the head shown."
  (interactive)
  (unless (derived-mode-p 'prrr-diff-mode)
    (user-error "Not in a Review Buffer"))
  (setq-local prrr-highlight (not prrr-highlight))
  (clrhash prrr-treesit--languages)
  (magit-refresh-buffer)
  (message "Syntax highlighting %s" (if prrr-highlight "on" "off")))

(cl-defmethod magit-section-paint :after ((section magit-hunk-section) _highlight
                                          &context (major-mode prrr-diff-mode))
  "Highlight the file of SECTION once, and put its syntax faces back.
magit paints a hunk when it is first shown, and again whenever point
enters or leaves it, each time resetting `font-lock-face'."
  (prrr-treesit--request (oref section parent))
  (prrr-treesit--merge (oref section start) (oref section end)))

(provide 'prrr-treesit)
;;; prrr-treesit.el ends here
