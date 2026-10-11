;;; prrr-diff.el --- The Review Buffer  -*- lexical-binding: t -*-

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

;; The Review Buffer (SPEC section 6): one pull request's diff, from
;; its merge base to its head, with its Threads inline.  It renders
;; from local git and prrr's database, never from the network.
;;
;; Rendering is hybrid lazy.  One `git diff --raw --numstat' lists the
;; changed files, each a collapsed `file' section.  The first files,
;; within `prrr-eager-files' and `prrr-eager-lines', are washed at
;; once; every other file is washed on its first expansion through a
;; deferred section body.
;;
;; A hunk's Threads are child sections of the hunk.  magit assumes
;; hunks have none, so three touch points adapt it: a
;; `magit-section-paint' method scoped to `prrr-diff-mode', and advice
;; on `magit-diff-hunk-line' and `magit-diff--hunk-section'.  CI runs
;; against MELPA magit, so a change there shows up as a failing test.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'magit)
(require 'forge)
(require 'prrr-db)
(require 'prrr-state)
(require 'prrr-thread)
(require 'prrr)
(require 'prrr-sync)

(declare-function prrr-menu "prrr-transient" ())

(defcustom prrr-eager-files 30
  "Most files washed when a Review Buffer opens.
The others are washed when first expanded."
  :type 'natnum
  :group 'prrr)

(defcustom prrr-eager-lines 2000
  "Most changed lines washed when a Review Buffer opens.
The first file that would pass this limit, or `prrr-eager-files', and
every file after it, are washed when first expanded."
  :type 'natnum
  :group 'prrr)

;;;; Changed files

(cl-defstruct (prrr-diff-file (:constructor prrr-diff-file-create) (:copier nil))
  "One changed file of a diff.
PATH is the file at head; ORIG the file at base when it was renamed or
copied, else nil.  STATUS is magit's word for the change: \"modified\",
\"new file\", \"deleted\", \"renamed\", \"copied\" or \"typechange\".
ADDED and DELETED count lines; both are 0 for a BINARY-P file."
  path orig status added deleted binary-p)

(defun prrr-diff--status-name (letter)
  "Return magit's word for git's status LETTER."
  (pcase letter
    (?A "new file")
    (?D "deleted")
    (?R "renamed")
    (?C "copied")
    (?T "typechange")
    (_ "modified")))

(defun prrr-diff-parse-changes (output)
  "Parse the OUTPUT of `git diff -z -M --raw --numstat' into `prrr-diff-file's.
Files come in git's order.  Git prints every raw record (status and
names) before the numstat records (line counts), in the same order."
  (let ((tokens (split-string output "\0"))
        (files nil)
        (counts nil))
    (while tokens
      (let ((token (pop tokens)))
        (cond
         ((string-prefix-p ":" token)
          (let* ((letter (aref (car (last (split-string token " "))) 0))
                 (orig (and (memq letter '(?R ?C)) (pop tokens))))
            (push (prrr-diff-file-create :path (pop tokens) :orig orig
                                         :status (prrr-diff--status-name letter))
                  files)))
         ((string-match "\\`\\([0-9]+\\|-\\)\t\\([0-9]+\\|-\\)\t" token)
          (when (= (match-end 0) (length token))
            ;; A rename or copy: its two names follow as tokens.
            (pop tokens)
            (pop tokens))
          (push (cons (match-string 1 token) (match-string 2 token)) counts)))))
    (cl-mapcar (lambda (file count)
                 (let ((binary (equal (car count) "-")))
                   (setf (prrr-diff-file-binary-p file) binary
                         (prrr-diff-file-added file)
                         (if binary 0 (string-to-number (car count)))
                         (prrr-diff-file-deleted file)
                         (if binary 0 (string-to-number (cdr count))))
                   file))
               (nreverse files) (nreverse counts))))

(defun prrr-diff--changes (base head)
  "Return the files changed from BASE to HEAD as `prrr-diff-file's."
  (prrr-diff-parse-changes
   (magit-git-output "diff" "--no-ext-diff" "-z" "-M" "--raw" "--numstat" base head)))

(defun prrr-diff--eager-paths (files viewed)
  "Return the paths among FILES to wash when the buffer opens.
FILES are `prrr-diff-file's in buffer order; the paths in VIEWED are
skipped.  Files are taken from the top until `prrr-eager-files' files
or `prrr-eager-lines' changed lines; the first file that would pass
either limit ends the run."
  (let ((count 0) (lines 0) (paths nil))
    (catch 'done
      (dolist (file files)
        (unless (member (prrr-diff-file-path file) viewed)
          (let ((size (+ (prrr-diff-file-added file) (prrr-diff-file-deleted file))))
            (when (or (>= count prrr-eager-files) (> (+ lines size) prrr-eager-lines))
              (throw 'done nil))
            (cl-incf count)
            (cl-incf lines size)
            (push (prrr-diff-file-path file) paths)))))
    paths))

(defun prrr-diff--merge-base (pullreq head)
  "Return the merge base of PULLREQ's base commit and HEAD, or nil.
nil when forge recorded no base commit or it is not in the repository."
  (when-let* ((base-rev (oref pullreq base-rev)))
    (and (magit-rev-verify base-rev)
         (magit-git-string "merge-base" base-rev head))))

(defface prrr-diff-viewed '((t :inherit success))
  "The Viewed mark on a file heading."
  :group 'prrr)

;;;; Buffer state

(defvar-local prrr-diff--pullreq nil
  "The `forge-pullreq' this Review Buffer shows.")

(defvar-local prrr-diff--range (prrr-range-create :kind 'default)
  "The `prrr-range' this Review Buffer shows.")

(defvar-local prrr-diff--start nil
  "Oid of the commit the diff starts at, or nil; set by each refresh.")

(defvar-local prrr-diff--end nil
  "Oid of the commit the diff ends at, or nil; set by each refresh.")

(defvar-local prrr-diff--head nil
  "Oid of the PR head the buffer shows, or nil; set by each refresh.")

(defvar-local prrr-diff--threads nil
  "Hash table from Thread id to the `prrr-thread' shown; set by each refresh.")

(defvar-local prrr-diff--file-threads nil
  "Hash table from path to its `prrr-file-threads'; set by each refresh.")

(defvar-local prrr-diff--data nil
  "The review data shown, from `prrr-sync-review-data'; set by each refresh.")

(defvar-local prrr-diff--comments nil
  "Hash table from comment id to the `prrr-comment' shown; set by each refresh.")

;;;; Washing

(defun prrr-diff--anchored-lines (thread right-lines)
  "Return the text of THREAD's lines that RIGHT-LINES holds, in order.
RIGHT-LINES maps new-file line numbers to their text."
  (let ((line (prrr-thread-line thread)))
    (delq nil (mapcar (lambda (number) (gethash number right-lines))
                      (number-sequence (or (prrr-thread-start-line thread) line) line)))))

(defun prrr-diff--insert-anchored (anchors side line comments right-lines)
  "Insert the Threads ANCHORS holds for LINE of SIDE, and remove them.
COMMENTS maps Thread ids to their Review Comments.  RIGHT-LINES maps
the new-file numbers of the hunk's lines so far to their text, against
which a right-side Thread's suggestions are shown."
  (when line
    (let ((key (cons side line)))
      (dolist (thread (gethash key anchors))
        (prrr-thread-insert thread (gethash (prrr-thread-thread-id thread) comments)
                            :writes (plist-get prrr-diff--data :writes)
                            :lines (and (eq side 'right)
                                        (prrr-diff--anchored-lines thread right-lines))))
      (remhash key anchors))))

(defun prrr-diff--wash-hunk (anchors comments)
  "Wash the hunk at point as `magit-diff-wash-hunk' does, with its Threads.
After each diff line, the Threads ANCHORS holds for that line are
inserted as children of the hunk (`prrr-diff--insert-anchored').
COMMENTS maps Thread ids to their Review Comments.  Return non-nil when
there was a hunk."
  (when (looking-at "^@\\{2,\\} \\(.+?\\) @\\{2,\\}\\(?: \\(.*\\)\\)?")
    (let* ((heading (match-string 0))
           (ranges (mapcar (lambda (str)
                             (let ((range (mapcar #'string-to-number
                                                  (split-string (substring str 1) ","))))
                               ;; A single line is +1 rather than +1,1.
                               (if (length= range 1) (nconc range (list 1)) range)))
                           (split-string (match-string 1))))
           (about (match-string 2))
           (combined (length= ranges 3))
           (old (car (car ranges)))
           (new (car (car (last ranges))))
           (right-lines (and (> (hash-table-count anchors) 0) (make-hash-table))))
      (magit-delete-line)
      (magit-insert-section section (hunk (cons about ranges) nil
                                          :combined combined
                                          :from-range (if combined (butlast ranges) (car ranges))
                                          :to-range (car (last ranges))
                                          :about about)
        (oset section keymap 'prrr-diff-hunk-section-map)
        (magit-insert-heading
          (propertize (concat heading "\n") 'font-lock-face 'magit-diff-hunk-heading))
        (while (not (or (eobp) (looking-at "^[^-+\s\\]")))
          (let ((old-line nil) (new-line nil))
            (pcase (char-after)
              (?\s (setq old-line old new-line new) (cl-incf old) (cl-incf new))
              (?- (setq old-line old) (cl-incf old))
              (?+ (setq new-line new) (cl-incf new)))
            (when (and right-lines new-line)
              (puthash new-line (buffer-substring-no-properties (1+ (point)) (line-end-position))
                       right-lines))
            (forward-line)
            (prrr-diff--insert-anchored anchors 'left old-line comments right-lines)
            (prrr-diff--insert-anchored anchors 'right new-line comments right-lines)))))
    t))

(defun prrr-diff--insert-group (type title threads comments)
  "Insert THREADS in a hidden section of TYPE headed TITLE, unless there are none.
COMMENTS maps Thread ids to their Review Comments.  A group outside
any file names each Thread's file."
  (when threads
    (magit-insert-section ((eval type) nil t)
      (magit-insert-heading
        (propertize (format "%s%s (%d)\n" prrr-thread-indent title (length threads))
                    'font-lock-face 'magit-section-secondary-heading))
      (dolist (thread threads)
        (prrr-thread-insert thread (gethash (prrr-thread-thread-id thread) comments)
                            :with-path (eq type 'outdated-files)
                            :writes (plist-get prrr-diff--data :writes))))))

(defun prrr-diff--insert-note (text)
  "Insert TEXT as a dimmed, indented line."
  (insert (propertize (concat prrr-thread-indent text "\n") 'font-lock-face 'magit-dimmed)))

(defun prrr-diff--wash-file (file threads comments sides start end)
  "Insert FILE's diff from START to END at point.
FILE is a `prrr-diff-file'; THREADS its `prrr-file-threads' or nil;
COMMENTS maps Thread ids to their Review Comments.  File Comments come
first, then the hunks with their Threads, then two hidden groups: the
Threads whose line is not in this diff (`not-in-range') and the
outdated ones (`outdated').  A Thread is on a line of this diff only
when its side is among SIDES (`prrr-state-inline-sides').  Runs
inside a deferred section body, where `magit-git-wash' cannot be
used, so the diff is inserted, narrowed to, stripped of its header
and washed hunk by hunk.  A diff without hunks becomes a one-line
note."
  (let* ((anchors (make-hash-table :test #'equal))
         (lines (and threads (prrr-file-threads-lines threads)))
         (placed (seq-filter (lambda (thread)
                               (memq (car (prrr-state-thread-anchor thread)) sides))
                             lines)))
    (dolist (thread (and threads (prrr-file-threads-file-comments threads)))
      (prrr-thread-insert thread (gethash (prrr-thread-thread-id thread) comments)
                          :writes (plist-get prrr-diff--data :writes)))
    (dolist (thread placed)
      (let ((key (prrr-state-thread-anchor thread)))
        (puthash key (append (gethash key anchors) (list thread)) anchors)))
    (let ((beg (point)))
      (apply #'magit-git-insert "diff" "--no-ext-diff" "--no-color" "-p" "-M" start end "--"
             (delq nil (list (prrr-diff-file-orig file) (prrr-diff-file-path file))))
      (save-restriction
        (narrow-to-region beg (point))
        (goto-char beg)
        (if (re-search-forward "^@@" nil t)
            (progn
              (delete-region beg (match-beginning 0))
              (goto-char beg)
              (magit-wash-sequence (lambda () (prrr-diff--wash-hunk anchors comments))))
          (delete-region beg (point-max))
          (prrr-diff--insert-note (if (prrr-diff-file-binary-p file)
                                      "Binary file, not shown"
                                    "No changed lines")))
        (goto-char (point-max))))
    (prrr-diff--insert-group 'not-in-range "Not in this diff"
                             (seq-filter (lambda (thread)
                                           (or (not (memq thread placed))
                                               (gethash (prrr-state-thread-anchor thread)
                                                        anchors)))
                                         lines)
                             comments)
    (prrr-diff--insert-group 'outdated "Outdated"
                             (and threads (prrr-file-threads-outdated threads))
                             comments)))

(defun prrr-diff--content-markers ()
  "Make every section's content position a marker.
With `magit-section-inhibit-markers' set to `delay', magit turns only
start and end into markers when the root section finishes.  An
integer content goes stale once a deferred body inserts text above it,
and then folding and RET act on the wrong lines."
  (magit-map-sections
   (lambda (section)
     (let ((content (oref section content)))
       (when (integerp content)
         (oset section content (copy-marker content)))))))

;;;; Magit coupling

(cl-defmethod magit-section-paint ((section magit-hunk-section) highlight
                                   &context (major-mode prrr-diff-mode))
  "Paint the diff lines of SECTION in MAJOR-MODE `prrr-diff-mode', not its Threads.
magit's method paints every line after point up to the section's end.
It runs once per run of diff lines, with the end moved to the next
child, starting on the line before the run.  HIGHLIGHT is passed on."
  (let ((children (oref section children)))
    (if (not children)
        (cl-call-next-method)
      (let ((end (oref section end))
            (from (point)))
        (unwind-protect
            (dolist (stop (append (mapcar (lambda (child) (oref child start)) children)
                                  (list end)))
              (save-excursion
                (goto-char from)
                (oset section end stop)
                (cl-call-next-method section highlight))
              (when-let* ((child (seq-find (lambda (child) (= (oref child start) stop))
                                          children)))
                ;; magit's method skips the line point is on: the
                ;; child's last line, so painting resumes after it.
                (setq from (save-excursion (goto-char (oref child end))
                                           (forward-line -1)
                                           (point)))))
          (oset section end end))))))

(defun prrr-diff--hunk-line (orig section goto-from)
  "Call ORIG, `magit-diff-hunk-line', counting only SECTION's diff lines.
In a Review Buffer a hunk's Thread children are not diff lines, and a
point inside one counts as the diff line the Thread follows.
GOTO-FROM is as for ORIG."
  (if (not (and (derived-mode-p 'prrr-diff-mode) (oref section children)))
      (funcall orig section goto-from)
    (save-excursion
      (goto-char (line-beginning-position))
      (let ((at (magit-section-at)))
        (unless (eq at section)
          (while (and at (not (eq (oref at parent) section)))
            (setq at (oref at parent)))
          (when at
            (goto-char (oref at start))
            (forward-line -1)
            ;; Several Threads can follow one diff line: step past them.
            (while (and (not (bobp)) (not (eq (magit-section-at) section)))
              (forward-line -1)))))
      (let ((content (oref section content)))
        (when (< (point) content)
          (goto-char content)
          (re-search-forward "^[-+]")
          (goto-char (line-beginning-position)))
        (let ((target (point))
              (offset 0))
          (goto-char content)
          (while (< (point) target)
            (when (and (eq (magit-section-at) section)
                       (not (eq (char-after) (if goto-from ?+ ?-))))
              (cl-incf offset))
            (forward-line))
          (+ (car (if goto-from (oref section from-range) (oref section to-range)))
             offset))))))

(defun prrr-diff--hunk-section (orig)
  "Call ORIG, `magit-diff--hunk-section', skipping a File Comment.
magit takes a file's first child for its first hunk; in a Review
Buffer that child may be a File Comment."
  (let ((section (funcall orig)))
    (if (and section
             (derived-mode-p 'prrr-diff-mode)
             (not (eq (oref section type) 'hunk)))
        (seq-find (lambda (child)
                    (and (eq (oref child type) 'hunk)
                         (not (equal (oref child value) '(chmod)))))
                  (oref (oref section parent) children))
      section)))

(advice-add 'magit-diff-hunk-line :around #'prrr-diff--hunk-line)
(advice-add 'magit-diff--hunk-section :around #'prrr-diff--hunk-section)

;;;; Mode and refresh

(defconst prrr-diff--review-keys
  '(("c" . prrr-comment) ("C" . prrr-comment-file) ("r" . prrr-reply)
    ("e" . prrr-edit-comment) ("k" . prrr-delete-comment)
    ("d" . prrr-discussion-comment) ("R" . prrr-toggle-resolved)
    ("s" . prrr-comment-suggest)
    ("S" . prrr-submit) ("O" . prrr-outbox)
    ("D" . prrr-range) ("." . prrr-goto-default-range) ("m" . prrr-mark-seen)
    (">" . prrr-stack-up) ("<" . prrr-stack-down))
  "The commenting and reviewing keys of a Review Buffer (SPEC section 9).
They are bound in the section keymaps too, which win over the mode's
and in which magit binds several of them.")

(defconst prrr-diff--later-keys
  '("@" "L")
  "Keys that later milestones give to prrr in a Review Buffer (SPEC section 9).
They are `undefined' until then, so magit's diff arguments or log never
run from a Review Buffer.")

(defun prrr-diff--bind-review-keys (map)
  "Bind the review keys in MAP and make the later keys `undefined'; return MAP.
They are `prrr-diff--review-keys' and `prrr-diff--later-keys'."
  (pcase-dolist (`(,key . ,command) prrr-diff--review-keys)
    (keymap-set map key command))
  (dolist (key prrr-diff--later-keys)
    (keymap-set map key #'undefined))
  map)

(defvar prrr-diff-file-section-map
  (prrr-diff--bind-review-keys (define-keymap :parent magit-file-section-map))
  "Keymap of a Review Buffer's `file' sections.
A section's keymap is a text property, which wins over
`prrr-diff-mode-map'; magit's, which applies by type name,
binds keys of `prrr-diff--review-keys' such as `C'.")

(defvar prrr-diff-hunk-section-map
  (prrr-diff--bind-review-keys (define-keymap :parent magit-hunk-section-map))
  "Keymap of a Review Buffer's `hunk' sections.
See `prrr-diff-file-section-map' for why it exists.")

(defvar prrr-diff-mode-map
  (prrr-diff--bind-review-keys
   (define-keymap
     :parent magit-diff-mode-map
     "]" #'prrr-next-thread
     "[" #'prrr-previous-thread
     "}" #'prrr-next-unresolved
     "{" #'prrr-previous-unresolved
     "J" #'prrr-next-file
     "K" #'prrr-previous-file
     "j" #'prrr-jump-to-file
     "v" #'prrr-toggle-viewed
     "z" #'prrr-collapse-all
     "Z" #'prrr-expand-all
     "o" #'prrr-open-topic
     "b" #'prrr-browse
     "B" #'prrr-checkout
     "g" #'prrr-refresh
     "G" #'prrr-refetch
     "?" #'prrr-menu
     "C-o" #'prrr-menu))
  "Keys of the Review Buffer (SPEC section 9).
The keys of `prrr-diff--review-keys' and `prrr-diff--later-keys' are bound
here and in the section keymaps.")

(define-derived-mode prrr-diff-mode magit-diff-mode "prrr"
  "Review one pull request: its diff with Threads inline.

\\{prrr-diff-mode-map}"
  :interactive nil
  :group 'prrr
  ;; A fold survives a refresh only when the visibility cache records
  ;; it, and the cache records the user's toggles of these types only.
  ;; Every open refreshes once its refetch answers.  Hunks are left
  ;; out: they start shown and are named by line ranges, which change
  ;; with the diff.
  (setq-local magit-section-cache-visibility
              '(file thread file-comment review-comment description discussion
                     not-in-range outdated outdated-files))
  ;; magit's hunk fontifier walks every line of a hunk, Threads included.
  (setq-local magit-diff-fontify-hunk nil)
  ;; Leaving the buffer, by killing it or quitting its window, ends a
  ;; visit: since-opened starts from what the visit showed.
  (add-hook 'kill-buffer-hook #'prrr-diff-record-bookmark nil t)
  (add-hook 'quit-window-hook #'prrr-diff-record-bookmark nil t))

(defun prrr-diff-record-bookmark ()
  "Record the head this Review Buffer shows as its pull request's Bookmark.
Run when the user leaves it: when the buffer is killed, its window
quit, or another PR of its Stack replaces it, and when opening the buffer
again moves its head (SPEC section 8).  Does
nothing when no head is shown.  A failure is reported, not raised, so
leaving still works."
  (when (and prrr-diff--pullreq prrr-diff--head)
    (condition-case err
        (prrr-sync-record-bookmark prrr-diff--pullreq prrr-diff--head)
      (error (message "prrr: the Bookmark was not recorded: %s"
                      (error-message-string err))))))

(defun prrr-diff--head-ref (pullreq)
  "Return the ref forge fetches PULLREQ's head to."
  (format "refs/pullreqs/%d" (oref pullreq number)))

(defun prrr-diff--viewed-paths (viewed)
  "Return the paths among VIEWED rows that GitHub marks `viewed'.
A `dismissed' file changed since it was viewed, so it does not count."
  (mapcar #'prrr-viewed-path
          (seq-filter (lambda (row) (eq (prrr-viewed-state row) 'viewed)) viewed)))

(defun prrr-diff--comments-table (comments)
  "Return a hash table from Thread id to its COMMENTS, in their order."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (comment (reverse comments))
      (push comment (gethash (prrr-comment-thread-id comment) table)))
    table))

(defun prrr-diff--thread-count (threads)
  "Return how many Threads THREADS, a `prrr-file-threads' or nil, holds."
  (if threads
      (+ (length (prrr-file-threads-file-comments threads))
         (length (prrr-file-threads-lines threads))
         (length (prrr-file-threads-outdated threads)))
    0))

(defun prrr-diff--file-heading (file threads viewed-p)
  "Return the heading of FILE with the count of its THREADS, marked when VIEWED-P."
  (let ((count (prrr-diff--thread-count threads)))
    (concat (magit-format-file 'diff (prrr-diff-file-path file) 'magit-diff-file-heading
                               (prrr-diff-file-status file) (prrr-diff-file-orig file))
            (and (> count 0) (format "  %d thread%s" count (if (= count 1) "" "s")))
            (and viewed-p (propertize "  ✓ viewed" 'font-lock-face 'prrr-diff-viewed))
            "\n")))

(defun prrr-diff--insert-files (sides start end data comments)
  "Insert one `file' section per file changed from START to END.
SIDES are the sides whose line Threads show inline
\(`prrr-state-inline-sides').  DATA is the PR's stored
review data (`prrr-db-review-data'); COMMENTS maps its Thread ids to
their Review Comments.  Viewed files start hidden; the eager budget
decides for the others.  Sets `prrr-diff--threads' and
`prrr-diff--file-threads'.  Return the Threads whose file is not in
the diff."
  (let* ((files (prrr-diff--changes start end))
         (layout (prrr-state-thread-layout (plist-get data :threads)
                                           (mapcar #'prrr-diff-file-path files)))
         (viewed (prrr-diff--viewed-paths (plist-get data :viewed)))
         (eager (prrr-diff--eager-paths files viewed)))
    (setq prrr-diff--file-threads (car layout)
          prrr-diff--threads (make-hash-table :test #'equal))
    (dolist (thread (plist-get data :threads))
      (puthash (prrr-thread-thread-id thread) thread prrr-diff--threads))
    (if (null files)
        (prrr-diff--insert-note "No changes")
      (dolist (file files)
        (let* ((path (prrr-diff-file-path file))
               (threads (gethash path (car layout))))
          (magit-insert-section section (file path (not (member path eager))
                                              :source (prrr-diff-file-orig file)
                                              :binary (prrr-diff-file-binary-p file))
            (oset section keymap 'prrr-diff-file-section-map)
            (magit-insert-heading (prrr-diff--file-heading file threads (member path viewed)))
            (magit-insert-section-body
              (prrr-diff--wash-file file threads comments sides start end))))))
    (cdr layout)))

(defun prrr-diff--posts (pullreq)
  "Return PULLREQ's Discussion Comments, oldest first."
  (oref pullreq posts))

(defun prrr-diff--outbox-status (data)
  "Describe the Outbox of the review DATA for the header, or return nil."
  (let* ((outbox (plist-get data :outbox))
         (failed (seq-count #'prrr-outbox-last-error outbox))
         (unsent (- (length outbox) failed)))
    (when outbox
      (concat "Outbox: "
              (string-join (delq nil (list (and (> unsent 0) (format "%d unsent" unsent))
                                           (and (> failed 0) (format "%d failed, O to act" failed))))
                           ", ")))))

(defun prrr-diff--range-status (view)
  "Name the Range of VIEW for the header (see `prrr-diff--status-line')."
  (let ((start (plist-get view :start))
        (end (plist-get view :end)))
    (if (and start end)
        (format "Range: %s, %s..%s" (prrr-range-kind (plist-get view :range))
                (prrr-state-short-oid start) (prrr-state-short-oid end))
      "Range: unavailable")))

(defun prrr-diff--status-line (pullreq view data)
  "Return the header's status line for PULLREQ.
VIEW describes what the buffer diffs, a plist: :range, the
`prrr-range'; :start and :end, the commits diffed, either may be nil;
:head, the PR head shown; :local, the head forge fetched, or nil;
:rewritten, non-nil when the Range's start is not an ancestor of its
end.  DATA is the review data shown.  Names the Range and whether
history was rewritten, the Pending Review's comments, the Outbox, a
queued Submit, what the last refetch said, and whether the head moved
away from the one shown (`prrr-state-head-notice')."
  (let* ((status (prrr-sync-review-status (oref pullreq their-id)))
         (submit (plist-get data :submit))
         (pending (seq-count (lambda (comment) (eq (prrr-comment-state comment) 'pending))
                             (plist-get data :comments))))
    (string-join
     (delq nil
           (list (prrr-diff--range-status view)
                 (and (plist-get view :rewritten) "history rewritten")
                 (and (or (plist-get data :pending-review) (> pending 0))
                      (format "Pending Review: %d comment%s" pending (if (= pending 1) "" "s")))
                 (prrr-diff--outbox-status data)
                 (and submit
                      (format "submitting (%s)…"
                              (plist-get (prrr-outbox-payload submit) :verdict)))
                 (prrr-sync-outbox-describe)
                 (prrr-sync-describe status "refreshing…")
                 (prrr-state-head-notice (plist-get view :head) (plist-get view :local)
                                         (plist-get status :head-oid))))
     "  ·  ")))

(defun prrr-diff--insert-header (pullreq view data)
  "Insert the header of PULLREQ's Review Buffer.
The title, a status line (`prrr-diff--status-line' of VIEW and DATA),
and hidden `description' and `discussion' sections.  The discussion
lists forge's posts, then the Discussion Comments GitHub accepted that
forge has not pulled yet (`prrr-sync-posted-discussion'), then DATA's
unsent ones."
  (magit-insert-section (prrr-header)
    (magit-insert-heading
      (propertize (format "#%d %s" (oref pullreq number) (oref pullreq title))
                  'font-lock-face 'magit-section-heading))
    (insert (propertize (prrr-diff--status-line pullreq view data)
                        'font-lock-face 'magit-dimmed)
            "\n")
    (magit-insert-section (description nil t)
      (magit-insert-heading "Description")
      (if (string-empty-p (string-trim (or (oref pullreq body) "")))
          (prrr-diff--insert-note "No description")
        (forge-insert-post pullreq nil)))
    (let* ((posts (prrr-diff--posts pullreq))
           (sent (prrr-sync-posted-discussion (oref pullreq their-id) posts))
           (unsent (plist-get data :discussion)))
      (magit-insert-section section (discussion nil t)
        ;; Without this, forge's `forge-discussion-section-map' applies.
        (oset section keymap nil)
        (magit-insert-heading (format "Discussion (%d)"
                                      (+ (length posts) (length sent) (length unsent))))
        (dolist (post posts)
          (forge-insert-post post pullreq))
        (dolist (post sent)
          (prrr-thread-insert-sent-post (plist-get post :body)))
        (pcase-dolist (`(,_id ,body ,row) unsent)
          (prrr-thread-insert-unsent-post body row))))
    (insert "\n")))

(defun prrr-diff--missing-commit (range start end)
  "Return START or END when it is not in the repository, else nil.
START and END are RANGE's commits.  Those of the `default' Range were
just found, so only the other kinds are checked."
  (unless (eq (prrr-range-kind range) 'default)
    (seq-find (lambda (oid) (not (magit-commit-p oid))) (list start end))))

(defun prrr-diff-refresh-buffer ()
  "Insert the Review Buffer of `prrr-diff--pullreq' from git and the database.
The refresh function of `prrr-diff-mode', run by `magit-refresh-buffer'.
It diffs the commits of `prrr-diff--range' (`prrr-state-range-ends').
The PR head is the one the buffer already shows, if any: only opening
the buffer and `prrr-refresh' move it to the head forge fetched, so
nothing changes under the user when forge fetches a new head.  The
review data is `prrr-sync-review-data''s: what GitHub sent, with the
Outbox's writes applied."
  (let* ((pullreq prrr-diff--pullreq)
         (range prrr-diff--range)
         (ref (prrr-diff--head-ref pullreq))
         (local (magit-rev-verify ref))
         (head (or prrr-diff--head local))
         (merge-base (and head (eq (prrr-range-kind range) 'default)
                          (prrr-diff--merge-base pullreq head)))
         (ends (prrr-state-range-ends range merge-base head))
         (start (and head (car ends)))
         (end (and head (cdr ends)))
         (missing (and start (prrr-diff--missing-commit range start end)))
         (view (list :range range :start start :end end :head head :local local
                     :rewritten (and start (not missing)
                                     (not (eq (prrr-range-kind range) 'default))
                                     (not (magit-rev-ancestor-p start end)))))
         (data (prrr-sync-review-data (oref pullreq their-id))))
    (setq prrr-diff--start start
          prrr-diff--end end
          prrr-diff--head head
          prrr-diff--data data
          prrr-diff--comments (make-hash-table :test #'equal)
          magit-buffer-diff-range (and start (concat start ".." end)))
    (dolist (comment (plist-get data :comments))
      (puthash (prrr-comment-comment-id comment) comment prrr-diff--comments))
    ;; magit resets this to nil when the root section finishes; a
    ;; failed refresh must not leave later insertions without markers.
    (setq magit-section-inhibit-markers 'delay)
    (unwind-protect
        (magit-insert-section (diffbuf)
          (prrr-diff--insert-header pullreq view data)
          (cond ((not head)
                 (prrr-diff--insert-note
                  (format "%s is missing: run `forge-pull', then g" ref)))
                ((not start)
                 (prrr-diff--insert-note
                  (format "The base commit %s is not available locally: run `forge-pull', then g"
                          (or (oref pullreq base-rev) "(unknown)"))))
                (missing
                 (prrr-diff--insert-note
                  (format "The commit %s of this Range is not available locally: D picks another"
                          (prrr-state-short-oid missing))))
                (t (let* ((comments (prrr-diff--comments-table (plist-get data :comments)))
                          (sides (prrr-state-inline-sides
                                  range head (plist-get (prrr-sync-review-status
                                                         (oref pullreq their-id))
                                                        :head-oid)))
                          (elsewhere (prrr-diff--insert-files sides start end data comments)))
                     (prrr-diff--insert-group 'outdated-files "Threads on files not in this diff"
                                              elsewhere comments)))))
      (setq magit-section-inhibit-markers nil))
    (prrr-diff--content-markers)))

(defun prrr-diff--buffer-name (pullreq)
  "Return the name of PULLREQ's Review Buffer."
  (format "prrr: %s #%d"
          (file-name-nondirectory (directory-file-name (or (magit-toplevel) default-directory)))
          (oref pullreq number)))

(defun prrr-diff-setup-buffer (pullreq)
  "Show the Review Buffer of PULLREQ, creating it when needed; return it.
There is one buffer per pull request.  `forge-buffer-topic' is set too,
so forge's commands, and `prrr-current-pullreq', act on PULLREQ."
  (magit-setup-buffer #'prrr-diff-mode nil
    :buffer (prrr-diff--buffer-name pullreq)
    (prrr-diff--pullreq pullreq)
    (forge-buffer-topic pullreq)
    (magit-buffer-diff-type 'committed)
    (magit-buffer-diff-range nil)
    (magit-buffer-diff-typearg nil)
    (magit-buffer-diff-args nil)
    (magit-buffer-diff-files nil)
    (magit-buffer-revision nil)))

;;;; Opening

(defun prrr-diff--end-visit-before-reopen (pullreq)
  "Record the Bookmark of PULLREQ's open Review Buffer if opening moves its head.
Opening always shows the head forge fetched, so a buffer showing an
older head ends the visit of that head here, as leaving would
\(`prrr-diff-record-bookmark').  At the same head the visit goes on."
  (when-let* ((buffer (get-buffer (prrr-diff--buffer-name pullreq))))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'prrr-diff-mode)
                 prrr-diff--head
                 (not (equal prrr-diff--head
                             (magit-rev-verify (prrr-diff--head-ref pullreq)))))
        (prrr-diff-record-bookmark)))))

(defun prrr-diff-open (pullreq)
  "Show the Review Buffer of PULLREQ and refetch its review data in the background.
The buffer renders at once from the database and refreshes when the
refetch ends.  The commit of the viewer's latest review is pinned
\(`prrr-sync-pin').  The buffer shows the head forge fetched; when it
was open at an older head, that head is recorded as the Bookmark
first.  When forge has not fetched the PR's head ref, offer to run
`forge-pull' and signal a `user-error' instead of opening.  Return the
buffer."
  (let ((ref (prrr-diff--head-ref pullreq)))
    (unless (magit-rev-verify ref)
      (when (y-or-n-p (format "%s is missing; run `forge-pull' now? " ref))
        (call-interactively #'forge-pull))
      (user-error (concat "%s is missing: open the pull request again once forge has fetched it"
                          " (if it stays missing, run `forge-add-pullreq-refspec')")
                  ref)))
  ;; prrr learns the viewer's review commit when it pulls the Review
  ;; Queue; pinning it here keeps since-review working after a force-push.
  (prrr-sync-pin (oref pullreq number)
                 (prrr-state-since-review-start
                  (prrr-db-get 'pullreq-meta (oref pullreq their-id))))
  (prrr-diff--end-visit-before-reopen pullreq)
  ;; The refetch starts before the one render, so the header says
  ;; "refreshing…" from the start; its answer refreshes from a timer,
  ;; never during the render.
  (let ((buffer (get-buffer-create (prrr-diff--buffer-name pullreq))))
    (prrr-sync-refetch (forge-get-repository pullreq) pullreq buffer)
    (prrr-diff-setup-buffer pullreq)))

(defun prrr-diff-pullreq ()
  "Return the current Review Buffer's pull request.
Signal a `user-error' outside a Review Buffer."
  (or (and (derived-mode-p 'prrr-diff-mode) prrr-diff--pullreq)
      (user-error "Not in a Review Buffer")))

(defun prrr-diff-live-numbers (toplevel)
  "Return the numbers of the PRs shown in live Review Buffers of TOPLEVEL.
TOPLEVEL is a repository's top-level directory.  A Review Buffer is
live from its creation until it is killed."
  (let (numbers)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (derived-mode-p 'prrr-diff-mode)
                   prrr-diff--pullreq
                   (equal toplevel (magit-toplevel)))
          (push (oref prrr-diff--pullreq number) numbers))))
    numbers))

;;;###autoload
(defun prrr-refetch ()
  "Refetch this pull request's Threads, Pending Review and Viewed flags now.
The buffer shows \"refreshing…\" until the answer arrives, then redraws.
`g' redraws from the database without fetching."
  (interactive)
  (let ((pullreq (prrr-diff-pullreq)))
    (if (prrr-sync-refetch (forge-get-repository pullreq) pullreq (current-buffer))
        (magit-refresh-buffer)
      (message "Not refetching: %s"
               (or (prrr-sync-describe (prrr-sync-review-status (oref pullreq their-id))
                                       "a refetch is running")
                   "try again shortly")))))

;;;###autoload
(defun prrr-refresh ()
  "Redraw the Review Buffer at the pull request's current head.
Every other redraw, such as the one after a refetch or a write, keeps
the head the buffer shows, so the diff never changes under you; the
header says \"head moved, press g\" instead (SPEC section 8)."
  (interactive)
  (prrr-diff-pullreq)
  (setq prrr-diff--head nil)
  (magit-refresh))

(defun prrr-diff-head ()
  "Return the oid of the PR head the current Review Buffer shows, or nil.
Comments are made on that head; the Range may end elsewhere."
  prrr-diff--head)

(defun prrr-diff-show-range (range)
  "Show RANGE, a `prrr-range', in the current Review Buffer."
  (prrr-diff-pullreq)
  (setq prrr-diff--range range)
  (magit-refresh-buffer))

(defun prrr-diff--hunk-of (section)
  "Return the `hunk' section SECTION is in, or nil."
  (while (and section (not (eq (oref section type) 'hunk)))
    (setq section (oref section parent)))
  section)

(defun prrr-diff--walk-hunk (hunk function)
  "Call FUNCTION at the start of each diff line of HUNK, in order.
FUNCTION receives the line's KIND, OLD and NEW, as `prrr-diff--line-at'
describes them, with point at the line's start.  The lines of the
hunk's Threads are skipped."
  (save-excursion
    (goto-char (oref hunk content))
    (let ((old (car (oref hunk from-range)))
          (new (car (oref hunk to-range))))
      (while (< (point) (oref hunk end))
        (when (eq (magit-section-at) hunk)
          (let ((kind (char-after)))
            (funcall function kind
                     (and (memq kind '(?- ?\s)) old)
                     (and (memq kind '(?+ ?\s)) new))
            (pcase kind
              (?\s (cl-incf old) (cl-incf new))
              (?- (cl-incf old))
              (?+ (cl-incf new)))))
        (forward-line)))))

(defun prrr-diff--line-at (pos)
  "Describe the diff line at POS as (HUNK KIND OLD NEW TEXT), or nil.
HUNK is the line's `hunk' section, KIND its first character, OLD and
NEW its numbers in the old and new file (nil on a side it is not on),
TEXT the line without KIND.  A position in a Thread counts as the diff
line the Thread follows.  nil off a hunk and on a hunk's heading."
  (save-excursion
    (goto-char pos)
    (goto-char (line-beginning-position))
    (let* ((at (magit-section-at))
           (hunk (prrr-diff--hunk-of at)))
      (when hunk
        (unless (eq at hunk)
          (goto-char (oref at start))
          (forward-line -1)
          ;; Several Threads can follow one diff line: step past them.
          (while (and (not (bobp)) (not (eq (magit-section-at) hunk)))
            (forward-line -1)))
        (when (>= (point) (oref hunk content))
          (let ((target (point)))
            (catch 'found
              (prrr-diff--walk-hunk
               hunk (lambda (kind old new)
                      (when (= (point) target)
                        (throw 'found
                               (list hunk kind old new
                                     (buffer-substring-no-properties
                                      (min (1+ (point)) (line-end-position))
                                      (line-end-position)))))))
              nil)))))))

(defun prrr-diff--region-ends ()
  "Return (BEG . END), the first and last position the comment commands use.
The region's when it is active, else point twice.  A region ending at
the start of a line ends on the line before."
  (if (use-region-p)
      (let ((beg (region-beginning))
            (end (region-end)))
        (cons beg (if (and (> end beg) (save-excursion (goto-char end) (bolp)))
                      (1- end)
                    end)))
    (cons (point) (point))))

(defun prrr-diff--commentable (anchor)
  "Return ANCHOR when the Range shown takes a comment on it.
Signal a `user-error' saying why not otherwise
\(`prrr-state-anchor-problem')."
  (when-let* ((problem (prrr-state-anchor-problem prrr-diff--range anchor)))
    (user-error "%s" problem))
  anchor)

(defun prrr-diff-anchor ()
  "Return the anchor of a comment on the line at point or the region's lines.
See `prrr-state-anchor'.  Signal a `user-error' off the diff's lines,
across hunks, or on lines the Range shown does not let you comment on."
  (prrr-diff-pullreq)
  (pcase-let* ((`(,beg . ,end) (prrr-diff--region-ends))
               (first (or (prrr-diff--line-at beg)
                          (user-error "Not on a diff line; C comments on the file")))
               (last (or (prrr-diff--line-at end)
                         (user-error "The region does not end on a diff line")))
               (file (oref (car first) parent)))
    (prrr-diff--commentable
     (prrr-state-anchor (oref file value) (seq-take first 4) (seq-take last 4)))))

(defun prrr-diff-file-anchor ()
  "Return the anchor of a File Comment on the file at point.
Signal a `user-error' when the Range shown does not end at the head."
  (prrr-diff-pullreq)
  (prrr-diff--commentable
   (prrr-state-file-anchor
    (oref (or (prrr-diff--file-at-point) (user-error "No file here")) value))))

(defun prrr-diff-region-lines ()
  "Return the diff lines of the line at point or of the region, as (KIND . TEXT).
Lines of Threads in between are left out."
  (pcase-let* ((`(,beg . ,end) (prrr-diff--region-ends))
               (lines nil))
    (save-excursion
      (goto-char beg)
      (goto-char (line-beginning-position))
      (while (<= (point) end)
        (let ((line (and (prrr-diff--hunk-of (magit-section-at))
                         (eq (magit-section-at) (prrr-diff--hunk-of (magit-section-at)))
                         (prrr-diff--line-at (point)))))
          (when line
            (push (cons (nth 1 line) (nth 4 line)) lines)))
        (forward-line)))
    (nreverse lines)))

(defun prrr-diff--section-of (types)
  "Return the section around point whose type is one of TYPES, or nil."
  (let ((section (magit-current-section)))
    (while (and section (not (memq (oref section type) types)))
      (setq section (oref section parent)))
    section))

(defun prrr-diff-thread-at-point ()
  "Return the `prrr-thread' at point, as the buffer shows it, or nil."
  (when-let* ((section (prrr-diff--section-of '(thread file-comment))))
    (gethash (oref section value) prrr-diff--threads)))

(defun prrr-diff-comment-at-point ()
  "Return the `prrr-comment' at point, as the buffer shows it, or nil."
  (when-let* ((section (prrr-diff--section-of '(review-comment))))
    (gethash (oref section value) prrr-diff--comments)))

;;;; Positions

(defun prrr-diff-ends ()
  "Return (START . END), the commits the current Review Buffer diffs.
Either is nil when the diff could not be drawn."
  (cons prrr-diff--start prrr-diff--end))

(defun prrr-diff-merge-base ()
  "Return the merge base of the current Review Buffer's PR and its head, or nil.
The head is the one the buffer shows."
  (and prrr-diff--head (prrr-diff--merge-base prrr-diff--pullreq prrr-diff--head)))

(defun prrr-diff-position ()
  "Return where point is in the diff, as (PATH SIDE LINE COMMIT NAME), or nil.
PATH is the file around point.  On a removed line, SIDE is `left' and
LINE its number at COMMIT, the commit the diff starts at; on any other
diff line SIDE is `right' and LINE its number at the commit the diff
ends at.  NAME is the file's path at COMMIT: its old path on the left
side of a renamed or copied file, else PATH.  Elsewhere in the file,
the \"\\ No newline at end of file\" lines included, SIDE, LINE,
COMMIT and NAME are nil.  nil outside every file."
  (when-let* ((file (prrr-diff--file-at-point)))
    (let ((path (oref file value)))
      (pcase (prrr-diff--line-at (point))
        (`(,_hunk ?- ,old ,_new ,_text)
         (list path 'left old prrr-diff--start (or (oref file source) path)))
        (`(,_hunk ,_kind ,_old ,(and new (pred integerp)) ,_text)
         (list path 'right new prrr-diff--end path))
        (_ (list path nil nil nil nil))))))

(defun prrr-diff-old-path (path)
  "Return the path at the diff's start of the file the diff shows as PATH.
That is its old path when the diff renames or copies it, else PATH.
nil when the diff does not show PATH."
  (when-let* ((file (prrr-diff--file path)))
    (or (oref file source) path)))

(defun prrr-diff-goto-line (path side line)
  "Move to LINE of SIDE in the diff of PATH and return non-nil, or return nil.
SIDE `right' counts lines at the commit the diff ends at, `left' at the
one it starts at; a context line has both numbers.  The file is
expanded, and washed when needed.  Without LINE, move to the file's
heading.  Return nil, and leave point alone, when PATH is not in the
diff or LINE is not in its hunks."
  (when-let* ((file (prrr-diff--file path)))
    (magit-section-show file)
    (if (not line)
        (progn (magit-section-goto file) t)
      (when-let* ((pos (catch 'found
                         (dolist (hunk (oref file children))
                           (when (eq (oref hunk type) 'hunk)
                             (prrr-diff--walk-hunk
                              hunk (lambda (_kind old new)
                                     (when (eql line (if (eq side 'left) old new))
                                       (throw 'found (point)))))))
                         nil)))
        (goto-char pos)
        t))))

;;;; Commands

(defun prrr-diff--files ()
  "Return the `file' sections of the buffer, in order."
  (seq-filter (lambda (section) (eq (oref section type) 'file))
              (oref magit-root-section children)))

(defun prrr-diff--file (path)
  "Return the `file' section of PATH, or nil when the diff does not show PATH."
  (seq-find (lambda (file) (equal (oref file value) path)) (prrr-diff--files)))

(defun prrr-diff--file-at-point ()
  "Return the `file' section around point, or nil."
  (let ((section (magit-current-section)))
    (while (and section (not (eq (oref section type) 'file)))
      (setq section (oref section parent)))
    section))

(defun prrr-diff--file-near-point (offset)
  "Return the file OFFSET files after the one around point, or nil.
A negative OFFSET counts backwards.  Before the first file, the first
file is one after point; after the last, the last is one before it."
  (let* ((files (prrr-diff--files))
         (current (prrr-diff--file-at-point))
         (index (cond (current (+ (seq-position files current) offset))
                      ((and files (< (point) (oref (car files) start)))
                       (if (> offset 0) (1- offset) -1))
                      (t (if (< offset 0) (+ (length files) offset) (length files))))))
    (and (<= 0 index) (nth index files))))

(defun prrr-next-file ()
  "Move to the next file of the diff."
  (interactive)
  (prrr-diff-pullreq)
  (magit-section-goto (or (prrr-diff--file-near-point 1) (user-error "No next file"))))

(defun prrr-previous-file ()
  "Move to the previous file of the diff."
  (interactive)
  (prrr-diff-pullreq)
  (magit-section-goto (or (prrr-diff--file-near-point -1) (user-error "No previous file"))))

(defun prrr-jump-to-file (path)
  "Move to the file PATH of the diff and expand it.
Interactively, read PATH with completion over the diff's files."
  (interactive
   (progn (prrr-diff-pullreq)
          (list (completing-read "Jump to file: "
                                 (mapcar (lambda (file) (oref file value)) (prrr-diff--files))
                                 nil t))))
  (let ((file (or (prrr-diff--file path)
                  (user-error "No file %s in this diff" path))))
    (magit-section-show file)
    (magit-section-goto file)))

(defun prrr-diff--thread-sections (container)
  "Return the `thread' and `file-comment' sections in CONTAINER, in order."
  (let ((sections nil))
    (magit-map-sections (lambda (section)
                          (when (memq (oref section type) '(thread file-comment))
                            (push section sections)))
                        container)
    (nreverse sections)))

(defun prrr-diff--threads-of (path)
  "Return every Thread the buffer shows in the file PATH."
  (when-let* ((entry (and prrr-diff--file-threads (gethash path prrr-diff--file-threads))))
    (append (prrr-file-threads-file-comments entry)
            (prrr-file-threads-lines entry)
            (prrr-file-threads-outdated entry))))

(defun prrr-diff--reveal (section)
  "Show SECTION and every section around it."
  (let ((chain nil))
    (while section
      (push section chain)
      (setq section (oref section parent)))
    (dolist (outer chain)
      (when (oref outer hidden)
        (magit-section-show outer)))))

(defun prrr-diff--goto-thread (forward wanted)
  "Move to the next Thread after point, or before it unless FORWARD.
Only Threads whose `prrr-thread' satisfies WANTED count.  A file not
washed yet is expanded when it holds such a Thread, and the target is
revealed wherever it is folded.  Signal a `user-error' when there is
none."
  (prrr-diff-pullreq)
  ;; HERE is a marker that advances with insertions at it: washing a file
  ;; above point (or one ending at point) must not leave HERE behind its
  ;; Threads.
  (let* ((here (copy-marker (line-beginning-position) t))
         (containers (append (prrr-diff--files)
                             (seq-filter (lambda (section)
                                           (eq (oref section type) 'outdated-files))
                                         (oref magit-root-section children))))
         (found
          (catch 'found
            (dolist (container (if forward containers (reverse containers)))
              (when (if forward (> (oref container end) here) (< (oref container start) here))
                (when (and (oref container washer)
                           (seq-some wanted (prrr-diff--threads-of (oref container value))))
                  (magit-section-show container))
                (let ((candidates
                       (seq-filter (lambda (section)
                                     (and (funcall wanted
                                                   (gethash (oref section value) prrr-diff--threads))
                                          (if forward
                                              (> (oref section start) here)
                                            (< (oref section start) here))))
                                   (prrr-diff--thread-sections container))))
                  (when candidates
                    (throw 'found (if forward (car candidates) (car (last candidates))))))))
            nil)))
    (set-marker here nil)
    (unless found
      (user-error (if forward "No next Thread" "No previous Thread")))
    (prrr-diff--reveal found)
    (magit-section-goto found)))

(defun prrr-diff--unresolved-p (thread)
  "Non-nil when THREAD is not resolved."
  (and thread (not (prrr-thread-resolved-p thread))))

(defun prrr-next-thread ()
  "Move to the next Thread or File Comment."
  (interactive)
  (prrr-diff--goto-thread t #'identity))

(defun prrr-previous-thread ()
  "Move to the previous Thread or File Comment."
  (interactive)
  (prrr-diff--goto-thread nil #'identity))

(defun prrr-next-unresolved ()
  "Move to the next unresolved Thread or File Comment."
  (interactive)
  (prrr-diff--goto-thread t #'prrr-diff--unresolved-p))

(defun prrr-previous-unresolved ()
  "Move to the previous unresolved Thread or File Comment."
  (interactive)
  (prrr-diff--goto-thread nil #'prrr-diff--unresolved-p))

(defun prrr-collapse-all ()
  "Fold every file of the diff."
  (interactive)
  (prrr-diff-pullreq)
  (mapc #'magit-section-hide (prrr-diff--files)))

(defconst prrr-diff--expand-all-quietly 100
  "Most files `prrr-expand-all' washes without asking first.")

(defun prrr-expand-all ()
  "Expand every file of the diff, washing the files not washed yet.
Asks first when that means washing more than
`prrr-diff--expand-all-quietly' files, which takes seconds."
  (interactive)
  (prrr-diff-pullreq)
  (let* ((files (prrr-diff--files))
         (unwashed (seq-count (lambda (file) (oref file washer)) files)))
    (when (or (<= unwashed prrr-diff--expand-all-quietly)
              (y-or-n-p (format "Wash %d more files? " unwashed)))
      (mapc #'magit-section-show files))))

(defun prrr-diff--viewed-p (path)
  "Non-nil when the buffer shows PATH as Viewed."
  (member path (prrr-diff--viewed-paths (plist-get prrr-diff--data :viewed))))

(defun prrr-toggle-viewed ()
  "Mark the file at point Viewed on GitHub and fold it, or unmark it.
Marking moves to the next file, as GitHub does.  The change shows at
once and reaches GitHub through the Outbox."
  (interactive)
  (let* ((pullreq (prrr-diff-pullreq))
         (file (or (prrr-diff--file-at-point) (user-error "No file here")))
         (path (oref file value))
         (viewed (not (prrr-diff--viewed-p path))))
    ;; Folding first records the fold in the visibility cache, so the
    ;; refresh below agrees with the Viewed flag.
    (if viewed (magit-section-hide file) (magit-section-show file))
    (magit-section-goto file)
    (prrr-sync-write (forge-get-repository pullreq) pullreq 'viewed
                     (list :path path :viewed viewed) (current-buffer))
    (magit-refresh-buffer)
    (when-let* ((next (and viewed (prrr-diff--file-near-point 1))))
      (magit-section-goto next))))

(provide 'prrr-diff)
;;; prrr-diff.el ends here
