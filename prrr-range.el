;;; prrr-range.el --- Ranges of the Review Buffer  -*- lexical-binding: t -*-

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

;; Ranges (SPEC section 8): which two commits the Review Buffer
;; diffs.  The commands here choose one: the default Range, since my
;; last review, since I last opened the pull request, one commit, or
;; between two commits.  Switching keeps point on the same file and
;; line when the new Range shows that line, found again at the new
;; Range's commits through `git diff -U0' and `prrr-state-map-line'.
;; A start commit missing locally, as after a force-push, is fetched
;; by sha from the pull request's remote; when that fails, the buffer
;; shows the default Range and says why.  The rules are pure functions
;; in prrr-state.el; prrr-diff.el draws.

;;; Code:

(require 'seq)
(require 'magit)
(require 'forge)
(require 'prrr-db)
(require 'prrr-state)
(require 'prrr-sync)
(require 'prrr-diff)

;;;; Switching

(defun prrr-range--map-line (line from from-path to to-path)
  "Return the number at commit TO of LINE of FROM-PATH at commit FROM, or nil.
TO-PATH is the file's path at TO, which differs from FROM-PATH across
a rename.  nil when the commits in between remove or rewrite that
line, or when either commit has no such file."
  (if (and (equal from to) (equal from-path to-path))
      line
    (with-temp-buffer
      ;; Diffing the two blobs needs no rename detection.
      (and (zerop (magit-git-insert "diff" "--no-ext-diff" "--no-color" "-U0"
                                    (concat from ":" from-path) (concat to ":" to-path)))
           (prrr-state-map-line (prrr-state-parse-hunk-ranges (buffer-string)) line)))))

(defun prrr-range--restore (position)
  "Move to POSITION, from `prrr-diff-position', in the Range now shown.
The line is looked for on the right side, then on the left; failing
both, point goes to the file's heading.  When the file is not in the
diff, point stays where the redraw left it."
  (pcase-let ((`(,path ,_side ,line ,commit ,name) position)
              (`(,start . ,end) (prrr-diff-ends)))
    (when (and start end)
      (or (and line
               (or (when-let* ((right (prrr-range--map-line line commit name end path)))
                     (prrr-diff-goto-line path 'right right))
                   (when-let* ((old (prrr-diff-old-path path))
                               (left (prrr-range--map-line line commit name start old)))
                     (prrr-diff-goto-line path 'left left))))
          (prrr-diff-goto-line path nil nil)))))

(defvar-local prrr-range--fetching nil
  "The commit this buffer fetches to show a Range, or nil.
A fetch that ends after another Range was chosen changes nothing.")

(defun prrr-range--switch (range)
  "Show RANGE, keeping point on the same file and line when it shows them.
A fetch for an earlier choice no longer changes the Range.  Signal a
`user-error' outside a Review Buffer."
  (prrr-diff-pullreq)
  (setq prrr-range--fetching nil)
  (let ((position (prrr-diff-position)))
    (prrr-diff-show-range range)
    (when position
      (prrr-range--restore position))))

;;;###autoload
(defun prrr-goto-default-range ()
  "Show the default Range, at the file and line point is on.
Lines that are read-only in another Range take comments there (SPEC
section 8)."
  (interactive)
  (prrr-range--switch (prrr-range-create :kind 'default)))

;;;; Choosing a Range

(defun prrr-range--fetch-sentinel (callback)
  "Return the sentinel of a fetch: magit's, then CALLBACK once git ended.
CALLBACK receives non-nil when git succeeded.  It runs even when
magit's sentinel signals, so the fetch never stays pending."
  (lambda (process event)
    (unwind-protect
        (magit-process-sentinel process event)
      (when (memq (process-status process) '(exit signal))
        (funcall callback (zerop (process-exit-status process)))))))

(defun prrr-range--fetch (oid remote callback)
  "Fetch the commit OID from REMOTE, the current pull request's remote.
The fetch runs in the background, by sha (SPEC section 8); CALLBACK
receives non-nil when it succeeded."
  (let ((process (magit-run-git-async "fetch" "--no-tags" remote oid)))
    ;; The Range shown changes once the callback ran, not before.
    (process-put process 'inhibit-refresh t)
    (set-process-sentinel process (prrr-range--fetch-sentinel callback))))

(defun prrr-range--show-from (kind start)
  "Show the Range KIND from the commit START to the head.
START is pinned (`prrr-sync-pin').  When START is not in the
repository it is fetched first; when that fails, the default Range is
shown instead, with a message."
  (let* ((pullreq (prrr-diff-pullreq))
         (buffer (current-buffer))
         (show (lambda ()
                 (prrr-sync-pin (oref pullreq number) start)
                 (prrr-range--switch (prrr-range-create :kind kind :start start)))))
    (if (magit-commit-p start)
        (funcall show)
      (let ((remote (oref (forge-get-repository pullreq) remote)))
        (setq prrr-range--fetching start)
        (message "Fetching %s from %s…" (prrr-state-short-oid start) remote)
        (prrr-range--fetch
         start remote
         (lambda (fetched)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (when (equal prrr-range--fetching start)
                 (if (and fetched (magit-commit-p start))
                     (funcall show)
                   (prrr-range--switch (prrr-range-create :kind 'default))
                   (message "Could not fetch %s, so this is the default Range"
                            (prrr-state-short-oid start))))))))))))

(defun prrr-show-since-review ()
  "Show what changed since your latest submitted review.
The Range runs from that review's commit to the head; its right side
takes comments (SPEC section 8)."
  (interactive)
  (prrr-range--show-from
   'since-review
   (or (prrr-state-since-review-start
        (prrr-db-get 'pullreq-meta (oref (prrr-diff-pullreq) their-id)))
       (user-error (concat "No submitted review of yours is known for this pull request;"
                           " prrr learns of them when it pulls the Review Queue")))))

(defun prrr-show-since-opened ()
  "Show what changed since you last saw this pull request.
The Range runs from the Bookmark's head to the head; its right side
takes comments.  The Bookmark is recorded when you leave the Review
Buffer, when opening it again moves its head, when you submit, and with
`prrr-mark-seen'."
  (interactive)
  (let ((bookmark (prrr-db-get 'pr-bookmark (oref (prrr-diff-pullreq) their-id))))
    (prrr-range--show-from
     'since-opened
     (or (and bookmark (prrr-bookmark-last-opened-head-oid bookmark))
         (user-error "%s" (substitute-command-keys
                           (concat "No Bookmark yet: prrr records one when you leave this buffer,"
                                   " when you submit, and with \\[prrr-mark-seen]")))))))

(defun prrr-range--merge-base ()
  "Return the merge base of the PR and the head shown.
Signal a `user-error' when it is unknown."
  (unless (prrr-diff-head)
    (user-error "The pull request's head is missing"))
  (or (prrr-diff-merge-base) (user-error "The pull request's base is missing")))

(defun prrr-range--commits (base)
  "Return the PR's commits after BASE up to the head shown, oldest first.
Each is (OID . SUBJECT).  BASE is the merge base (`prrr-range--merge-base')."
  (let ((head (or (prrr-diff-head) (user-error "The pull request's head is missing"))))
    (mapcar (lambda (line)
              (if (string-match "\\`\\([0-9a-f]+\\) \\(.*\\)\\'" line)
                  (cons (match-string 1 line) (match-string 2 line))
                (cons line "")))
            (magit-git-lines "log" "--reverse" "--format=%H %s" (concat base ".." head)))))

(defun prrr-range--read-commit (prompt commits)
  "Read one of COMMITS, (OID . SUBJECT) pairs, with PROMPT; return its oid.
The choices keep the order of COMMITS.  An empty answer chooses
nothing: signal a `user-error'."
  (let* ((choices (mapcar (lambda (commit)
                            (cons (format "%s %s" (prrr-state-short-oid (car commit)) (cdr commit))
                                  (car commit)))
                          (or commits (user-error "No commits to choose from"))))
         (table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      '(metadata (display-sort-function . identity)
                                 (cycle-sort-function . identity))
                    (complete-with-action action choices string predicate)))))
    (or (cdr (assoc (completing-read prompt table nil t) choices))
        (user-error "No commit chosen"))))

(defun prrr-show-commit (oid)
  "Show the PR's commit OID against its parent; the Range is read-only.
Interactively, read OID among the PR's commits."
  (interactive (list (prrr-range--read-commit
                      "Show commit: " (prrr-range--commits (prrr-range--merge-base)))))
  (prrr-diff-pullreq)
  (prrr-range--switch
   (prrr-range-create :kind 'commit :end oid
                      :start (or (magit-rev-parse (concat oid "^"))
                                 (user-error "Commit %s has no parent"
                                             (prrr-state-short-oid oid))))))

(defun prrr-show-between (from to)
  "Show the diff from the commit FROM to the commit TO; the Range is read-only.
Interactively, read FROM among the merge base and the PR's commits,
then TO among the commits after it."
  (interactive
   (let* ((base (prrr-range--merge-base))
          (commits (cons (cons base "(merge base)") (prrr-range--commits base)))
          (from (prrr-range--read-commit "Diff from: " (butlast commits))))
     (list from (prrr-range--read-commit
                 "Diff to: " (cdr (seq-drop-while (lambda (commit) (not (equal (car commit) from)))
                                                  commits))))))
  (prrr-range--switch (prrr-range-create :kind 'between :start from :end to)))

;;;; Bookmark

(defun prrr-mark-seen ()
  "Record the head shown as seen: the since-opened Range starts there now.
prrr also records it when you leave the Review Buffer, when you submit, and
when opening the Review Buffer again moves its head, but not on a plain
open (SPEC section 8)."
  (interactive)
  (let ((pullreq (prrr-diff-pullreq))
        (head (or (prrr-diff-head) (user-error "The pull request's head is missing"))))
    (prrr-sync-record-bookmark pullreq head)
    (message "Marked %s seen" (prrr-state-short-oid head))))

(provide 'prrr-range)
;;; prrr-range.el ends here
