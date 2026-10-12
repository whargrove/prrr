;;; prrr-test.el --- Tests for the prrr entry point  -*- lexical-binding: t -*-

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

;; The package entry point: what loading prrr.el costs, and the shared PR commands.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'forge)          ; loaded before the stubs below replace its functions
(require 'prrr-test-helper)
(require 'prrr)
(require 'prrr-diff)

(ert-deftest prrr-test-require-prrr-does-not-load-forge ()
  "Loading prrr.el (prrr-knu.6) loads neither forge, magit nor the database."
  (let ((output
         (with-temp-buffer
           (call-process (expand-file-name invocation-name invocation-directory)
                         nil '(t nil) nil
                         "-Q" "--batch"
                         "--eval" (format "(progn (setq package-user-dir %S) (package-initialize))"
                                          package-user-dir)
                         "-L" prrr-test-root
                         "--eval" "(progn (require 'prrr) (prin1 (list (featurep 'forge) (featurep 'magit) (featurep 'emacsql))))")
           (buffer-string))))
    (should (equal "(nil nil nil)" (string-trim output)))))

(ert-deftest prrr-test-require-prrr-autoloads-every-command ()
  "A plain clone on `load-path' has no generated autoloads file (I3).
`(require \\='prrr)' alone must make every entry command callable."
  (let ((output
         (with-temp-buffer
           (call-process (expand-file-name invocation-name invocation-directory)
                         nil '(t nil) nil
                         "-Q" "--batch"
                         "--eval" (format "(progn (setq package-user-dir %S) (package-initialize))"
                                          package-user-dir)
                         "-L" prrr-test-root
                         "--eval" (concat "(progn (require 'prrr) (let (missing)"
                                         " (dolist (command '(prrr-queue-mode prrr-queue prrr-pull prrr-refresh-teams"
                                         " prrr-stack-up prrr-stack-down prrr-queue-menu"
                                         " prrr-comment prrr-reply prrr-submit prrr-outbox"
                                         " prrr-range prrr-goto-default-range prrr-mark-seen prrr-refresh"
                                         " prrr-show-since-review prrr-show-since-opened"
                                         " prrr-show-commit prrr-show-between prrr-send-to-agent"
                                         " prrr-accept-comment))"
                                         " (unless (and (autoloadp (symbol-function command)) (commandp command))"
                                         " (push command missing)))"
                                         " (prin1 missing)))"))
           (buffer-string))))
    (should (equal "nil" (string-trim output)))))

(ert-deftest prrr-test-require-prrr-autoloads-every-api-function ()
  "`(require \\='prrr)' alone makes the Agent API callable (Review Focus 2).
An agent's `emacsclient -e' may be the first thing to call it."
  (let ((output
         (with-temp-buffer
           (call-process (expand-file-name invocation-name invocation-directory)
                         nil '(t nil) nil
                         "-Q" "--batch"
                         "--eval" (format "(progn (setq package-user-dir %S) (package-initialize))"
                                          package-user-dir)
                         "-L" prrr-test-root
                         "--eval" (concat "(progn (require 'prrr) (let (missing)"
                                         " (dolist (function '(prrr-api-pullreq prrr-api-threads"
                                         " prrr-api-diff prrr-api-pending prrr-api-add-comment prrr-api-reply"
                                         " prrr-api-delete-pending-comment prrr-api-submit"
                                         " prrr-api-export prrr-api-import))"
                                         " (unless (and (fboundp function)"
                                         " (autoloadp (symbol-function function)))"
                                         " (push function missing)))"
                                         " (prin1 missing)))"))
           (buffer-string))))
    (should (equal "nil" (string-trim output)))))

(ert-deftest prrr-test-current-pullreq-signals-without-one ()
  (cl-letf (((symbol-function 'forge-current-pullreq) #'ignore))
    (should-error (prrr-current-pullreq) :type 'user-error)))

(ert-deftest prrr-test-shared-commands-act-on-current-pullreq ()
  (let ((pullreq (forge-pullreq :id "forge-1" :number 1))
        (calls nil))
    (cl-letf (((symbol-function 'forge-current-pullreq) (lambda (&rest _) pullreq))
              ((symbol-function 'forge-visit-topic) (lambda (topic) (push (cons 'visit topic) calls)))
              ((symbol-function 'forge-browse-pullreq) (lambda (pr) (push (cons 'browse pr) calls)))
              ((symbol-function 'forge-checkout-pullreq) (lambda (pr) (push (cons 'checkout pr) calls))))
      (prrr-open-topic)
      (prrr-browse)
      (prrr-checkout))
    (should (equal (list (cons 'checkout pullreq) (cons 'browse pullreq) (cons 'visit pullreq))
                   calls))))

(ert-deftest prrr-test-review-reads-pullreq-without-one-at-point ()
  (let ((pullreq (forge-pullreq :id "forge-9" :number 9))
        (opened nil))
    (cl-letf (((symbol-function 'forge-current-pullreq) #'ignore)
              ((symbol-function 'forge-read-pullreq) (lambda (&rest _) "forge-9"))
              ((symbol-function 'forge-get-pullreq) (lambda (id) (and (equal id "forge-9") pullreq)))
              ((symbol-function 'prrr-diff-open) (lambda (pr) (setq opened pr))))
      (call-interactively #'prrr-review))
    (should (eq pullreq opened))))

(ert-deftest prrr-test-review-uses-pullreq-at-point ()
  (let ((pullreq (forge-pullreq :id "forge-3" :number 3))
        (opened nil))
    (cl-letf (((symbol-function 'forge-current-pullreq) (lambda (&rest _) pullreq))
              ((symbol-function 'forge-read-pullreq) (lambda (&rest _) (ert-fail "prompted")))
              ((symbol-function 'prrr-diff-open) (lambda (pr) (setq opened pr))))
      (call-interactively #'prrr-review))
    (should (eq pullreq opened))))

(provide 'prrr-test)
;;; prrr-test.el ends here
