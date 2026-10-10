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
;; This file holds the customization group and the user options.  The
;; database lives in `prrr-db', GitHub access in `prrr-github', and the
;; pure Review Queue rules in `prrr-state'.

;;; Code:

(require 'prrr-db)

(defgroup prrr nil
  "Review GitHub pull requests with magit and forge."
  :group 'tools
  :prefix "prrr-")

(defcustom prrr-database-file
  (expand-file-name "prrr-database.sqlite" user-emacs-directory)
  "File holding prrr's SQLite database.
One database serves every repository.  Created on first use."
  :type 'file)

(defcustom prrr-github-user nil
  "GitHub login of the viewer.
When nil, the `github.user' Git variable is used, as forge does."
  :type '(choice (const :tag "Use the github.user Git variable" nil)
                 (string :tag "Login")))

(defcustom prrr-queue-stale-after 300
  "Seconds after which the Review Queue inputs are pulled again."
  :type 'natnum)

(provide 'prrr)
;;; prrr.el ends here
