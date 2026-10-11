;;; prrr.el --- Review GitHub pull requests with magit and forge  -*- lexical-binding: t -*-

;; Copyright (C) 2026  Wesley Hargrove

;; Author: Wesley Hargrove <wesleyhargrove@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (magit "4.7") (forge "0.5") (emacsql "4.4") (transient "0.13") (compat "31"))
;; URL: https://github.com/whargrove/prrr
;; Keywords: vc, tools

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

;; prrr reviews GitHub pull requests inside Emacs on top of magit and
;; forge: a Review Queue in magit-status, a Review Buffer with Threads
;; inline, and a server-side Pending Review with batched Submit.
;;
;; This file is the entry point.  It holds the customization group and
;; the commands shared by the Review Queue and the Review Buffer, and
;; loads nothing else: every other command is reached through an
;; autoload, so `(require 'prrr)' at startup costs no forge, magit or
;; database load.  Turn the Review Queue on with `prrr-queue-mode'.
;; `prrr-review' is the way into the Review Buffer.

;;; Code:

(defgroup prrr nil
  "Review GitHub pull requests with magit and forge."
  :group 'tools
  :prefix "prrr-")

;; Explicit autoloads, so a plain clone on `load-path' works without a
;; generated autoloads file.  Each costs nothing until its command runs.
(autoload 'prrr-queue-mode "prrr-queue"
  "Show the Review Queue in the `magit-status' buffer of GitHub repositories." t)
(autoload 'prrr-queue "prrr-queue" "Show the Review Queue of the current repository." t)
(autoload 'prrr-pull "prrr-sync"
  "Pull the current repository's pull requests and Review Queue inputs." t)
(autoload 'prrr-refresh-teams "prrr-sync" "Fetch the viewer's Teams again." t)
(autoload 'prrr-stack-up "prrr-stack" "Move to the next PR up the current Stack." t)
(autoload 'prrr-stack-down "prrr-stack" "Move to the next PR down the current Stack." t)
(autoload 'prrr-refetch "prrr-diff" "Refetch this pull request's review data now." t)
(autoload 'prrr-queue-menu "prrr-transient" "Show the Review Queue commands." t)
(autoload 'prrr-menu "prrr-transient" "Show the Review Buffer commands." t)
(autoload 'prrr-comment "prrr-review" "Comment on the diff line at point, or on the region's lines." t)
(autoload 'prrr-comment-file "prrr-review" "Comment on the file at point as a whole." t)
(autoload 'prrr-comment-suggest "prrr-review" "Suggest a change to the line at point or the region's lines." t)
(autoload 'prrr-reply "prrr-review" "Reply to the Thread at point." t)
(autoload 'prrr-edit-comment "prrr-review" "Edit your comment at point." t)
(autoload 'prrr-delete-comment "prrr-review" "Delete your comment at point." t)
(autoload 'prrr-discussion-comment "prrr-review" "Write a Discussion Comment on the pull request." t)
(autoload 'prrr-toggle-resolved "prrr-review" "Resolve the Thread at point, or unresolve it." t)
(autoload 'prrr-submit "prrr-transient" "Submit your Pending Review with a Verdict, or discard it." t)
(autoload 'prrr-outbox "prrr-transient" "Act on this pull request's unsent writes." t)

(declare-function forge-current-pullreq "forge-pullreq" (&optional demand))
(declare-function forge-visit-topic "forge-commands" (topic))
(declare-function forge-browse-pullreq "forge-commands" (pull-request))
(declare-function forge-checkout-pullreq "forge-commands" (pullreq))
(declare-function forge-read-pullreq "forge-pullreq" (prompt))
(declare-function forge-get-pullreq "forge-core" (&rest args))
(declare-function prrr-diff-open "prrr-diff" (pullreq))

(defun prrr-current-pullreq ()
  "Return forge's pull request at point or being visited.
Signal a `user-error' when there is none."
  (require 'forge)
  (or (forge-current-pullreq)
      (user-error "No pull request here")))

;;;###autoload
(defun prrr-open-topic ()
  "Show the current pull request in forge's topic buffer."
  (interactive)
  (forge-visit-topic (prrr-current-pullreq)))

;;;###autoload
(defun prrr-browse ()
  "Open the current pull request on GitHub."
  (interactive)
  (forge-browse-pullreq (prrr-current-pullreq)))

;;;###autoload
(defun prrr-checkout ()
  "Check out the current pull request's branch with forge."
  (interactive)
  (forge-checkout-pullreq (prrr-current-pullreq)))

;;;###autoload
(defun prrr-review (pullreq)
  "Review PULLREQ in its Review Buffer.
Interactively, the pull request at point, else one read with forge's
reader; with a prefix argument, always read one."
  (interactive
   (progn
     (require 'forge)
     (list (or (and (not current-prefix-arg) (forge-current-pullreq))
               (forge-get-pullreq (forge-read-pullreq "Review pull request: "))))))
  (require 'prrr-diff)
  (prrr-diff-open pullreq))

(provide 'prrr)
;;; prrr.el ends here
