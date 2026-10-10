;;; install-deps.el --- Install prrr's dependencies into .deps/  -*- lexical-binding: t -*-

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

;; Run by `make deps' with `package-user-dir' already pointing at the
;; project-local .deps/ directory.  Installs the newest archive version
;; of each dependency, replacing built-in copies (transient on Emacs 29)
;; when the archive is newer.

;;; Code:

(require 'package)

(setq package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                         ("melpa" . "https://melpa.org/packages/"))
      package-install-upgrade-built-in t)

(package-initialize)
(package-refresh-contents)

(defun install-deps--newest (name)
  "Return the newest archive description of package NAME."
  (car (sort (copy-sequence (cdr (assq name package-archive-contents)))
             (lambda (a b)
               (version-list-< (package-desc-version b)
                               (package-desc-version a))))))

(dolist (name '(compat transient emacsql magit forge package-lint))
  (let ((desc (install-deps--newest name)))
    (unless desc
      (error "install-deps: %s is not in any configured archive" name))
    (if (package-installed-p name (package-desc-version desc))
        (message "install-deps: %s %s already installed"
                 name (package-version-join (package-desc-version desc)))
      (message "install-deps: installing %s %s"
               name (package-version-join (package-desc-version desc)))
      (package-install desc))))

;;; install-deps.el ends here
