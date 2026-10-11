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
(require 'prrr-sync)

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
  (when-let ((base-rev (oref pullreq base-rev)))
    (and (magit-rev-verify base-rev)
         (magit-git-string "merge-base" base-rev head))))

(defface prrr-diff-viewed '((t :inherit success))
  "The Viewed mark on a file heading."
  :group 'prrr)

;;;; Buffer state

(defvar-local prrr-diff--pullreq nil
  "The `forge-pullreq' this Review Buffer shows.")

(defvar-local prrr-diff--base nil
  "Oid of the merge base the diff starts at, or nil; set by each refresh.")

(defvar-local prrr-diff--head nil
  "Oid of the head the diff ends at, or nil; set by each refresh.")

(defvar-local prrr-diff--threads nil
  "Hash table from Thread id to the `prrr-thread' shown; set by each refresh.")

(defvar-local prrr-diff--file-threads nil
  "Hash table from path to its `prrr-file-threads'; set by each refresh.")

;;;; Washing

(defun prrr-diff--insert-anchored (anchors side line comments)
  "Insert the Threads ANCHORS holds for LINE of SIDE, and remove them.
COMMENTS maps Thread ids to their Review Comments."
  (when line
    (let ((key (cons side line)))
      (dolist (thread (gethash key anchors))
        (prrr-thread-insert thread (gethash (prrr-thread-thread-id thread) comments)))
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
           (new (car (car (last ranges)))))
      (magit-delete-line)
      (magit-insert-section (hunk (cons about ranges) nil
                                  :combined combined
                                  :from-range (if combined (butlast ranges) (car ranges))
                                  :to-range (car (last ranges))
                                  :about about)
        (magit-insert-heading
          (propertize (concat heading "\n") 'font-lock-face 'magit-diff-hunk-heading))
        (while (not (or (eobp) (looking-at "^[^-+\s\\]")))
          (let ((old-line nil) (new-line nil))
            (pcase (char-after)
              (?\s (setq old-line old new-line new) (cl-incf old) (cl-incf new))
              (?- (setq old-line old) (cl-incf old))
              (?+ (setq new-line new) (cl-incf new)))
            (forward-line)
            (prrr-diff--insert-anchored anchors 'left old-line comments)
            (prrr-diff--insert-anchored anchors 'right new-line comments)))))
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
                            (eq type 'outdated-files))))))

(defun prrr-diff--insert-note (text)
  "Insert TEXT as a dimmed, indented line."
  (insert (propertize (concat prrr-thread-indent text "\n") 'font-lock-face 'magit-dimmed)))

(defun prrr-diff--wash-file (file threads comments base head)
  "Insert FILE's diff from BASE to HEAD, with its Threads, at point.
FILE is a `prrr-diff-file'; THREADS its `prrr-file-threads' or nil;
COMMENTS maps Thread ids to their Review Comments.  File Comments come
first, then the hunks with their Threads, then two hidden groups: the
Threads whose line is not in this diff (`not-in-range') and the
outdated ones (`outdated').  Runs inside a deferred section body, where
`magit-git-wash' cannot be used, so the diff is inserted, narrowed to,
stripped of its header and washed hunk by hunk.  A diff without hunks
becomes a one-line note."
  (let ((anchors (make-hash-table :test #'equal))
        (lines (and threads (prrr-file-threads-lines threads))))
    (dolist (thread (and threads (prrr-file-threads-file-comments threads)))
      (prrr-thread-insert thread (gethash (prrr-thread-thread-id thread) comments)))
    (dolist (thread lines)
      (let ((key (prrr-state-thread-anchor thread)))
        (puthash key (append (gethash key anchors) (list thread)) anchors)))
    (let ((beg (point)))
      (apply #'magit-git-insert "diff" "--no-ext-diff" "--no-color" "-p" "-M" base head "--"
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
                                           (gethash (prrr-state-thread-anchor thread) anchors))
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
              (when-let ((child (seq-find (lambda (child) (= (oref child start) stop))
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

(defvar-keymap prrr-diff-mode-map
  :doc "Keys of the Review Buffer (SPEC section 9)."
  :parent magit-diff-mode-map)

(define-derived-mode prrr-diff-mode magit-diff-mode "prrr"
  "Review one pull request: its diff with Threads inline.

\\{prrr-diff-mode-map}"
  :interactive nil
  :group 'prrr
  ;; Folds survive a refresh only through the visibility cache; hunks
  ;; are cheap to rebuild and are left out.
  (setq-local magit-section-cache-visibility '(file thread file-comment))
  ;; magit's hunk fontifier walks every line of a hunk, Threads included.
  (setq-local magit-diff-fontify-hunk nil))

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

(defun prrr-diff--insert-files (base head data)
  "Insert one `file' section per file changed from BASE to HEAD.
DATA is the PR's stored review data (`prrr-db-review-data').  Viewed
files start hidden; the eager budget decides for the others.  Sets
`prrr-diff--threads' and `prrr-diff--file-threads'.  Return the
Threads whose file is not in the diff."
  (let* ((files (prrr-diff--changes base head))
         (layout (prrr-state-thread-layout (plist-get data :threads)
                                           (mapcar #'prrr-diff-file-path files)))
         (comments (prrr-diff--comments-table (plist-get data :comments)))
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
          (magit-insert-section (file path (not (member path eager))
                                      :source (prrr-diff-file-orig file)
                                      :binary (prrr-diff-file-binary-p file))
            (magit-insert-heading (prrr-diff--file-heading file threads (member path viewed)))
            (magit-insert-section-body
              (prrr-diff--wash-file file threads comments base head))))))
    (cdr layout)))

(defun prrr-diff--posts (pullreq)
  "Return PULLREQ's Discussion Comments, oldest first."
  (oref pullreq posts))

(defun prrr-diff--short (oid)
  "Return the first seven characters of OID."
  (substring oid 0 (min 7 (length oid))))

(defun prrr-diff--status-line (pullreq base head data)
  "Return the header's status line for PULLREQ.
BASE and HEAD are the diffed oids, either may be nil; DATA is the
stored review data.  Names the Range, the Pending Review's comments,
what the last refetch said, and whether GitHub's head differs from the
local one."
  (let* ((status (prrr-sync-review-status (oref pullreq their-id)))
         (github-head (plist-get status :head-oid))
         (pending (seq-count (lambda (comment) (eq (prrr-comment-state comment) 'pending))
                             (plist-get data :comments))))
    (string-join
     (delq nil
           (list (if base
                     (format "Range: default, %s..%s" (prrr-diff--short base)
                             (prrr-diff--short head))
                   "Range: unavailable")
                 (and (plist-get data :pending-review)
                      (format "Pending Review: %d comment%s" pending (if (= pending 1) "" "s")))
                 (prrr-sync-describe status "refreshing…")
                 (and github-head head (not (equal github-head head))
                      (format "GitHub's head is %s: run forge-pull, then g"
                              (prrr-diff--short github-head)))))
     "  ·  ")))

(defun prrr-diff--insert-header (pullreq base head data)
  "Insert the header of PULLREQ's Review Buffer.
The title, a status line (`prrr-diff--status-line' of BASE, HEAD and
DATA), and hidden `description' and `discussion' sections."
  (magit-insert-section (prrr-header)
    (magit-insert-heading
      (propertize (format "#%d %s" (oref pullreq number) (oref pullreq title))
                  'font-lock-face 'magit-section-heading))
    (insert (propertize (prrr-diff--status-line pullreq base head data)
                        'font-lock-face 'magit-dimmed)
            "\n")
    (magit-insert-section (description nil t)
      (magit-insert-heading "Description")
      (if (string-empty-p (string-trim (or (oref pullreq body) "")))
          (prrr-diff--insert-note "No description")
        (forge-insert-post pullreq nil)))
    (let ((posts (prrr-diff--posts pullreq)))
      (magit-insert-section section (discussion nil t)
        ;; Without this, forge's `forge-discussion-section-map' applies.
        (oset section keymap nil)
        (magit-insert-heading (format "Discussion (%d)" (length posts)))
        (dolist (post posts)
          (forge-insert-post post pullreq))))
    (insert "\n")))

(defun prrr-diff-refresh-buffer ()
  "Insert the Review Buffer of `prrr-diff--pullreq' from git and the database.
The refresh function of `prrr-diff-mode', run by `magit-refresh-buffer'."
  (let* ((pullreq prrr-diff--pullreq)
         (ref (prrr-diff--head-ref pullreq))
         (head (magit-rev-verify ref))
         (base (and head (prrr-diff--merge-base pullreq head)))
         (data (prrr-db-review-data (oref pullreq their-id))))
    (setq prrr-diff--base base
          prrr-diff--head head
          magit-buffer-diff-range (and base (concat base ".." head)))
    (setq magit-section-inhibit-markers 'delay)
    (magit-insert-section (diffbuf)
      (prrr-diff--insert-header pullreq base head data)
      (cond ((not head)
             (prrr-diff--insert-note
              (format "%s is missing: run `forge-pull', then g" ref)))
            ((not base)
             (prrr-diff--insert-note
              (format "The base commit %s is not available locally: run `forge-pull', then g"
                      (or (oref pullreq base-rev) "(unknown)"))))
            (t (prrr-diff--insert-group 'outdated-files "Threads on files not in this diff"
                                        (prrr-diff--insert-files base head data)
                                        (prrr-diff--comments-table (plist-get data :comments))))))
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

(provide 'prrr-diff)
;;; prrr-diff.el ends here
