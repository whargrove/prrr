;;; prrr-thread-test.el --- ERT tests for rendering Threads  -*- lexical-binding: t -*-

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

;; Rendering one Thread and its Review Comments into a magit-section buffer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'prrr-test-helper)
(require 'prrr-thread)

(cl-defun prrr-thread-test--comment (&key (id "C_1") (thread "T_1") (author "example-bob")
                                          (body "Looks odd.") (state 'submitted) updated-at)
  "A Review Comment of Thread THREAD.
ID, AUTHOR, BODY, STATE and UPDATED-AT default to sensible values."
  (prrr-comment-create :comment-id id :thread-id thread :pr-id "PR_1" :author author
                       :body body :created-at "2026-09-02T10:00:00Z" :updated-at updated-at
                       :state state :local-state 'sent))

(defmacro prrr-thread-test--with-render (form &rest body)
  "Evaluate FORM inside a root section of a fresh buffer, then run BODY there.
BODY sees `section', the first child of the root."
  (declare (indent 1))
  `(with-temp-buffer
     (magit-section-mode)
     (let ((inhibit-read-only t))
       (magit-insert-section (root)
         ,form))
     (let ((section (car (oref magit-root-section children))))
       (goto-char (point-min))
       ,@body)))

(defun prrr-thread-test--lines ()
  "The buffer's lines, without properties."
  (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n" t))

(ert-deftest prrr-thread-test-line-thread ()
  (prrr-thread-test--with-render
      (prrr-thread-insert (prrr-test-thread)
                          (list (prrr-thread-test--comment)
                                (prrr-thread-test--comment :id "C_2" :author "example-me"
                                                           :body "Fixed.\nTwice."
                                                           :updated-at "2026-09-03T00:00:00Z")))
    (should (eq 'thread (oref section type)))
    (should (equal "T_1" (oref section value)))
    (should-not (oref section hidden))
    (should (eq 'prrr-thread-section-map (oref section keymap)))
    (should (equal '("    Thread  line 12  2 comments"
                     "    example-bob  2026-09-02"
                     "      Looks odd."
                     "    example-me  2026-09-02  edited"
                     "      Fixed."
                     "      Twice.")
                   (prrr-thread-test--lines)))
    (should (equal '("C_1" "C_2") (mapcar (lambda (child) (oref child value))
                                          (oref section children))))
    (should (equal '(review-comment review-comment)
                   (mapcar (lambda (child) (oref child type)) (oref section children))))))

(ert-deftest prrr-thread-test-resolved-range-thread-is-hidden ()
  (prrr-thread-test--with-render
      (prrr-thread-insert (prrr-test-thread :start-line 1 :line 3 :resolved-p t)
                          (list (prrr-thread-test--comment)))
    (should (oref section hidden))
    (should (looking-at "    Thread  lines 1-3  1 comment  resolved$"))
    (should (eq 'prrr-thread-resolved (get-text-property (+ (point) 4) 'font-lock-face)))))

(ert-deftest prrr-thread-test-left-side-and-pending ()
  (prrr-thread-test--with-render
      (prrr-thread-insert (prrr-test-thread :side 'left :line 7)
                          (list (prrr-thread-test--comment :state 'pending)))
    (should (eq 'thread (oref section type)))
    (should (looking-at "    Thread  line 7, left  1 comment  1 pending$"))
    (forward-line)
    (should (looking-at "    example-bob  2026-09-02  pending$"))))

(ert-deftest prrr-thread-test-file-comment ()
  (prrr-thread-test--with-render
      (prrr-thread-insert (prrr-test-thread :subject-type 'file :line nil)
                          (list (prrr-thread-test--comment)))
    (should (eq 'file-comment (oref section type)))
    (should (looking-at "    File comment  file  1 comment$"))))

(ert-deftest prrr-thread-test-with-path-and-outdated-line ()
  "Away from its file a Thread names the file; an outdated one its original line."
  (prrr-thread-test--with-render
      (prrr-thread-insert (prrr-thread-create :thread-id "T_9" :pr-id "PR_1" :path "src/old.el"
                                              :line nil :original-line 40 :side 'left
                                              :subject-type 'line :outdated-p t)
                          nil :with-path t)
    (should (eq 'thread (oref section type)))
    (should (looking-at "    Thread  src/old.el, line 40, left  0 comments$"))))

(ert-deftest prrr-thread-test-ghost-author-and-empty-body ()
  (prrr-thread-test--with-render
      (prrr-thread-insert (prrr-test-thread)
                          (list (prrr-thread-test--comment :author nil :body nil)))
    (should (eq 'thread (oref section type)))
    (forward-line)
    (should (looking-at "    ghost  2026-09-02$"))))

;;;; Unsent writes, agents and suggestions

(defun prrr-thread-test--row (id &optional error)
  "A queued write with ID, failed with ERROR when non-nil."
  (prrr-outbox-create :id id :pr-id "PR_1" :kind 'edit :payload nil
                      :created-at "2026-10-10T12:00:00Z" :attempts (if error 1 0)
                      :last-error error))

(ert-deftest prrr-thread-test-unsent-and-failed ()
  (let ((writes (make-hash-table :test #'equal)))
    (puthash "C_1" (prrr-thread-test--row "1") writes)
    (puthash "C_2" (prrr-thread-test--row "2" "GitHub returned HTTP 502") writes)
    (prrr-thread-test--with-render
        (prrr-thread-insert (prrr-test-thread)
                            (list (prrr-thread-test--comment)
                                  (prrr-thread-test--comment :id "C_2" :author "example-me"))
                            :writes writes)
      (should (eq 'thread (oref section type)))
      (forward-line)
      (should (looking-at "    example-bob  2026-09-02  unsent$"))
      (should (eq 'prrr-unsent (get-text-property (- (line-end-position) 2) 'font-lock-face)))
      (forward-line 2)
      (should (looking-at "    example-me  2026-09-02  failed: GitHub returned HTTP 502$"))
      (should (eq 'prrr-failed (get-text-property (- (line-end-position) 2) 'font-lock-face))))))

(ert-deftest prrr-thread-test-unconfirmed ()
  "A write whose send got no answer is unsent, waiting for GitHub's answer."
  (let ((writes (make-hash-table :test #'equal))
        (row (prrr-thread-test--row "1")))
    (setf (prrr-outbox-payload row) '(:sent-at "2026-10-10T12:00:01Z"))
    (puthash "C_1" row writes)
    (prrr-thread-test--with-render
        (prrr-thread-insert (prrr-test-thread) (list (prrr-thread-test--comment))
                            :writes writes)
      (should (eq 'thread (oref section type)))
      (forward-line)
      (should (looking-at "    example-bob  2026-09-02  waiting for GitHub's answer$"))
      (should (eq 'prrr-unsent (get-text-property (- (line-end-position) 2)
                                                  'font-lock-face))))))

(ert-deftest prrr-thread-test-agent-comment ()
  (let ((comment (prrr-thread-test--comment)))
    (setf (prrr-comment-agent-p comment) t)
    (prrr-thread-test--with-render
        (prrr-thread-insert (prrr-test-thread) (list comment))
      (should (eq 'thread (oref section type)))
      (forward-line)
      (should (looking-at "    example-bob  2026-09-02  agent$")))))

(ert-deftest prrr-thread-test-proposed-comment ()
  "An agent's proposal says so, and is not called unsent: it is never sent."
  (let ((comment (prrr-thread-test--comment))
        (writes (make-hash-table :test #'equal))
        (row (prrr-thread-test--row "1")))
    (setf (prrr-comment-agent-p comment) t
          (prrr-comment-state comment) 'pending
          (prrr-comment-local-state comment) 'proposed
          (prrr-outbox-kind row) 'proposed)
    (puthash "C_1" row writes)
    (prrr-thread-test--with-render
        (prrr-thread-insert (prrr-test-thread) (list comment) :writes writes)
      (should (eq 'thread (oref section type)))
      (forward-line)
      (should (looking-at "    example-bob  2026-09-02  agent  proposed$"))
      (should (eq 'prrr-agent (get-text-property (- (line-end-position) 2) 'font-lock-face))))))

(ert-deftest prrr-thread-test-suggestion-as-mini-diff ()
  (prrr-thread-test--with-render
      (prrr-thread-insert (prrr-test-thread)
                          (list (prrr-thread-test--comment
                                 :body "Rename it:\n```suggestion\nline 12\n```\nThanks."))
                          :lines '("line twelve"))
    (should (eq 'thread (oref section type)))
    (should (equal '("    Thread  line 12  1 comment"
                     "    example-bob  2026-09-02"
                     "      Rename it:"
                     "      Suggested change:"
                     "      -line twelve"
                     "      +line 12"
                     "      Thanks.")
                   (prrr-thread-test--lines)))
    (goto-char (point-min))
    (re-search-forward "^      \\+line 12")
    (should (eq 'magit-diff-added (get-text-property (- (point) 2) 'font-lock-face)))))

(ert-deftest prrr-thread-test-unsent-discussion-comment ()
  (prrr-thread-test--with-render
      (prrr-thread-insert-unsent-post "Thanks!" (prrr-thread-test--row "9"))
    (should (eq 'unsent-post (oref section type)))
    (should (equal '("    Your Discussion Comment  unsent" "      Thanks!")
                   (prrr-thread-test--lines)))))


;;;; The capture buffer

(defmacro prrr-thread-test--with-capture (args &rest body)
  "Open a capture buffer from a scratch buffer and run BODY in it.
ARGS follow the label and the confirm function of `prrr-comment-capture'.
`confirmed' collects (TEXT IMMEDIATE BUFFER) of each confirm and
`origin' is the scratch buffer."
  (declare (indent 1))
  `(let ((confirmed nil)
         (origin (generate-new-buffer "prrr-test-origin")))
     (unwind-protect
         (with-current-buffer origin
           (insert "line one\nline two\n")
           (goto-char 10)
           (let ((capture (apply #'prrr-comment-capture "src/a.el:3 right"
                                 (lambda (text immediate)
                                   (push (list text immediate (current-buffer)) confirmed))
                                 (list ,@args))))
             (with-current-buffer capture
               ,@body)))
       (dolist (buffer (buffer-list))
         (when (string-prefix-p "*prrr comment*" (buffer-name buffer))
           (kill-buffer buffer)))
       (kill-buffer origin))))

(ert-deftest prrr-thread-test-capture-window-is-not-a-side-window ()
  "The capture buffer never sits in a side window (prrr-lrc).
Transient shows its menus in the bottom side window, slot 0, and took
the capture window over for Emacs's emoji skin-tone chooser."
  (prrr-thread-test--with-capture ()
    (let ((window (get-buffer-window (current-buffer))))
      (should window)
      (should-not (window-parameter window 'window-side)))))

(ert-deftest prrr-thread-test-capture-confirm ()
  (prrr-thread-test--with-capture ()
    (should (eq 'prrr-comment-mode major-mode))
    (should (derived-mode-p 'text-mode))
    (should (string-match-p "src/a\\.el:3 right" (prrr-comment--header)))
    (should (string-match-p "Pending Review" (prrr-comment--header)))
    (insert "  Looks odd.  \n")
    (let ((capture (current-buffer)))
      (prrr-comment-confirm)
      (should-not (buffer-live-p capture)))
    (should (equal (list (list "Looks odd." nil origin)) confirmed))
    (should (eq (current-buffer) origin))
    (should (= 10 (point)))))

(ert-deftest prrr-thread-test-capture-confirm-strips-text-properties ()
  "The confirmed text carries no text properties.
gfm-mode's fontification of a fenced block puts the capture buffer
itself into some of them, and a buffer cannot be stored."
  (prrr-thread-test--with-capture ()
    (insert (propertize "```suggestion\nx\n```" 'face 'bold 'prrr-test (current-buffer)))
    (prrr-comment-confirm)
    (let ((text (car (car confirmed))))
      (should (equal "```suggestion\nx\n```" text))
      (should-not (text-properties-at 0 text)))))

(ert-deftest prrr-thread-test-capture-keys ()
  (prrr-thread-test--with-capture ()
    (should (eq 'prrr-comment-confirm (key-binding (kbd "C-c C-c"))))
    (should (eq 'prrr-comment-abort (key-binding (kbd "C-c C-k"))))
    (should (eq 'prrr-comment-toggle-immediate (key-binding (kbd "C-c C-i"))))))

(ert-deftest prrr-thread-test-capture-empty-refused ()
  "Review Focus 5: an empty comment is refused and the buffer stays."
  (prrr-thread-test--with-capture ()
    (insert "  \n")
    (should-error (prrr-comment-confirm) :type 'user-error)
    (should (eq major-mode 'prrr-comment-mode))
    (should-not confirmed)))

(ert-deftest prrr-thread-test-capture-allow-empty ()
  (prrr-thread-test--with-capture (:allow-empty t)
    (prrr-comment-confirm)
    (should (equal "" (car (car confirmed))))))

(ert-deftest prrr-thread-test-capture-abort ()
  (prrr-thread-test--with-capture (:body "Draft")
    (should (equal "Draft" (buffer-string)))
    (let ((capture (current-buffer)))
      (prrr-comment-abort)
      (should-not (buffer-live-p capture)))
    (should-not confirmed)))

(ert-deftest prrr-thread-test-capture-toggle-immediate ()
  (prrr-thread-test--with-capture (:immediate t)
    (should (string-match-p "publish now" (prrr-comment--header)))
    (prrr-comment-toggle-immediate)
    (insert "Later.")
    (prrr-comment-confirm)
    (should (equal '("Later." nil) (seq-take (car confirmed) 2)))))

(ert-deftest prrr-thread-test-capture-fixed-choice ()
  (prrr-thread-test--with-capture (:immediate t :immediate-allowed nil)
    (should-error (prrr-comment-toggle-immediate) :type 'user-error)
    (should-not (string-match-p "publish now" (prrr-comment--header)))))

(ert-deftest prrr-thread-test-capture-keeps-text-when-sending-fails ()
  "Review Focus 5: when the command refuses the text, nothing is lost."
  (let ((origin (generate-new-buffer "prrr-test-origin")))
    (unwind-protect
        (with-current-buffer origin
          (with-current-buffer (prrr-comment-capture "x" (lambda (_text _now) (user-error "No")))
            (insert "Keep me.")
            (should-error (prrr-comment-confirm) :type 'user-error)
            (should (equal "Keep me." (buffer-string)))
            (kill-buffer)))
      (kill-buffer origin))))

(defun prrr-thread-test--draw (extra)
  "Draw two file sections in the current buffer, after an EXTRA one when non-nil.
Like a redraw of the Review Buffer: everything is erased first."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (prrr-thread-test-root)
      (when extra
        (magit-insert-section (note 'extra) (insert "a new section\n")))
      (magit-insert-section (file "a.el") (insert "a heading\na one\na two\n"))
      (magit-insert-section (file "b.el") (insert "b heading\nb one\nb two\n")))))

(defmacro prrr-thread-test--with-redrawn-capture (finish)
  "Capture from line \"b one\", redraw the origin, then run FINISH.
FINISH is the command that ends the capture; point must come back."
  `(let ((origin (generate-new-buffer "prrr-test-origin")))
     (unwind-protect
         (progn
           (switch-to-buffer origin)
           (magit-section-mode)
           (prrr-thread-test--draw nil)
           (goto-char (point-min))
           (search-forward "b one")
           (backward-char 2)
           (with-current-buffer (prrr-comment-capture "b.el" #'ignore)
             (insert "Text.")
             (with-current-buffer origin (prrr-thread-test--draw t))
             (,finish))
           (should (eq (current-buffer) origin))
           (should (equal "b one" (buffer-substring (line-beginning-position)
                                                    (line-end-position))))
           (should (= 3 (current-column))))
       (kill-buffer origin))))

(ert-deftest prrr-thread-test-capture-confirm-survives-a-redraw ()
  "SPEC 7: confirm returns point to the anchor, even after the Outbox redrew the buffer."
  (prrr-thread-test--with-redrawn-capture prrr-comment-confirm))

(ert-deftest prrr-thread-test-capture-abort-survives-a-redraw ()
  (prrr-thread-test--with-redrawn-capture prrr-comment-abort))

(ert-deftest prrr-thread-test-capture-keeps-point-with-an-active-region ()
  "Starting a capture on a region in a hunk leaves point and the region alone.
magit's hunk method of `magit-section-get-relative-position' moves
point while a region is active."
  (let ((origin (generate-new-buffer "prrr-test-origin")))
    (unwind-protect
        (with-current-buffer origin
          (magit-section-mode)
          (let ((inhibit-read-only t))
            (magit-insert-section (prrr-thread-test-root)
              (magit-insert-section (magit-hunk-section "a.el")
                (insert "@@ -1,3 +1,3 @@\n one\n-two\n+deux\n three\n"))))
          (transient-mark-mode 1)
          (goto-char (point-min))
          (search-forward "-two")
          (set-mark (line-beginning-position))
          (search-forward "deux")
          (activate-mark)
          (let ((before (point)))
            (prrr-comment-capture "a.el:2 right" #'ignore)
            (should (= before (with-current-buffer origin (point))))))
      (dolist (buffer (buffer-list))
        (when (string-prefix-p "*prrr comment*" (buffer-name buffer))
          (kill-buffer buffer)))
      (kill-buffer origin))))

(ert-deftest prrr-thread-test-capture-origin-killed ()
  "Review Focus 5: confirming after the Review Buffer is gone still sends."
  (let ((confirmed nil)
        (origin (generate-new-buffer "prrr-test-origin")))
    (with-current-buffer origin
      (with-current-buffer (prrr-comment-capture "x" (lambda (text _now) (push text confirmed)))
        (kill-buffer origin)
        (insert "Still sent.")
        (prrr-comment-confirm)))
    (should (equal '("Still sent.") confirmed))))

(provide 'prrr-thread-test)
;;; prrr-thread-test.el ends here
