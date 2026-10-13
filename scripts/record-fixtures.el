;;; record-fixtures.el --- Re-record GitHub fixtures from a real repository  -*- lexical-binding: t -*-

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

;; Records the raw callback data of the three foundation queries from a
;; real repository, so the committed fixtures can be refreshed when
;; GitHub's shape changes.  Never run in CI.
;;
;;   PRRR_FIXTURE_REPO=owner/name PRRR_FIXTURE_PR=12 PRRR_FIXTURE_USER=login \
;;   $EMACS -Q --batch --eval '(setq package-user-dir (expand-file-name ".deps"))' \
;;         --eval '(package-initialize)' -L . -l scripts/record-fixtures.el
;;
;; Authentication is forge's: the token for api.github.com must be in
;; your auth-source as the forge manual describes; without one, ghub's
;; own error is the output.  Results go to test/fixtures/github/recorded/,
;; which is git-ignored because it holds real logins.  Replace every name
;; with an `example' name before copying a file over the committed
;; fixture of the same name.

;;; Code:

(require 'cl-lib)
(require 'prrr-github)

(defconst record-fixtures--usage
  "record-fixtures: set PRRR_FIXTURE_REPO (owner/name), PRRR_FIXTURE_PR (digits) and PRRR_FIXTURE_USER"
  "Message printed when the environment variables are missing or malformed.")

(defconst record-fixtures--root
  (file-name-directory
   (directory-file-name (file-name-directory load-file-name)))
  "Root of the prrr checkout.")

(defvar record-fixtures--pending 4
  "Requests still in flight.")

(defun record-fixtures--save (name data)
  "Write DATA to recorded/NAME.eld and count the request as done."
  (let ((dir (expand-file-name "test/fixtures/github/recorded/" record-fixtures--root)))
    (make-directory dir t)
    (with-temp-file (expand-file-name (concat name ".eld") dir)
      (pp data (current-buffer)))
    (message "record-fixtures: wrote %s%s.eld" dir name)
    (cl-decf record-fixtures--pending)))

(defun record-fixtures--failed (name err)
  "Report that the NAME request failed with ERR and exit non-zero."
  (message "record-fixtures: %s failed: %S" name err)
  (kill-emacs 1))

(let ((repo (getenv "PRRR_FIXTURE_REPO"))
      (number (getenv "PRRR_FIXTURE_PR"))
      (me (getenv "PRRR_FIXTURE_USER")))
  (unless (and repo number me
               (string-match-p "\\`[^/]+/[^/]+\\'" repo)
               (string-match-p "\\`[0-9]+\\'" number)
               (> (length me) 0))
    (message "%s" record-fixtures--usage)
    (kill-emacs 2))
  (pcase-let ((`(,owner ,name) (split-string repo "/")))
    (prrr-github--query "api.github.com" prrr-github-queue-query
      ((owner owner) (name name))
      :callback (lambda (data &rest _)
                  (record-fixtures--save "queue" data)
                  ;; The batch refresh names the open PRs the queue query found.
                  (let ((ids (mapcar (lambda (pr) (alist-get 'id pr))
                                     (seq-take (alist-get 'pullRequests
                                                          (alist-get 'repository data))
                                               prrr-github-nodes-per-request))))
                    (prrr-github--query "api.github.com" prrr-github-pr-nodes-query
                      ((ids (vconcat ids)))
                      :callback (lambda (data &rest _) (record-fixtures--save "pr-nodes" data))
                      :errorback (lambda (err &rest _)
                                   (record-fixtures--failed "pr-nodes" err)))))
      :errorback (lambda (err &rest _) (record-fixtures--failed "queue" err)))
    (prrr-github--query "api.github.com" prrr-github-teams-query
      ((me (vector me)))
      :callback (lambda (data &rest _) (record-fixtures--save "teams" data))
      :errorback (lambda (err &rest _) (record-fixtures--failed "teams" err)))
    (prrr-github--query "api.github.com" prrr-github-review-data-query
      ((owner owner) (name name) (number (string-to-number number)) (me me))
      :callback (lambda (data &rest _) (record-fixtures--save "review-data" data))
      :errorback (lambda (err &rest _) (record-fixtures--failed "review-data" err)))
    (while (> record-fixtures--pending 0)
      (accept-process-output nil 0.2))
    (kill-emacs 0)))

;;; record-fixtures.el ends here
