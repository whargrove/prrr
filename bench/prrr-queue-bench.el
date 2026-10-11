;;; prrr-queue-bench.el --- Review Queue render budget  -*- lexical-binding: t -*-

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

;; SPEC section 12: render the Review Queue from the database for 200
;; PRs within 20 ms.  Run with `make bench'.
;;
;; The measured cost is what a magit-status refresh pays: gathering
;; the inputs from forge's and prrr's databases (`prrr-queue--inputs')
;; plus inserting the section.  Both databases are generated in a
;; temporary directory: a repository with 3000 PRs in forge, 200 of
;; them open, and prrr meta rows for the 200 open ones.  Every run
;; reads the repository object afresh, as each refresh does.

;;; Code:

(require 'cl-lib)
(require 'prrr-queue)

(defconst prrr-queue-bench-budget-ms 20.0
  "SPEC section 12 budget for showing 200 open PRs from the database.")

(defconst prrr-queue-bench-tolerance 1.25
  "A run fails when the median exceeds the budget by more than this factor.")

(defconst prrr-queue-bench--repo-id (base64-encode-string "github.com:R_example" t)
  "Forge id of the generated repository.")

(defun prrr-queue-bench--pullreq-id (number)
  "Return the forge id of PR NUMBER of the generated repository.
This is how forge derives a topic id, so `forge-get-pullreq' finds it."
  (base64-encode-string
   (format "%s:pullreq%d" (base64-decode-string prrr-queue-bench--repo-id) number)
   t))

(defun prrr-queue-bench--fill-forge (total open)
  "Store a repository with TOTAL PRs, the first OPEN of them open, in forge.
A fifth of the open PRs are stacked on the previous one."
  (let ((repo (forge-github-repository :id prrr-queue-bench--repo-id
                                       :githost "github.com" :apihost "api.github.com"
                                       :owner "example-org" :name "example-repo")))
    (oset repo default-branch "main")
    (closql-insert (forge-db) repo)
    (emacsql-with-transaction (forge-db)
      (dotimes (i total)
        (let ((stacked (and (> i 0) (< i open) (zerop (% i 5)))))
          (closql-insert
           (forge-db)
           (forge-pullreq :id (prrr-queue-bench--pullreq-id (1+ i))
                          :repository prrr-queue-bench--repo-id
                          :number (1+ i) :their-id (format "PR_%04d" i)
                          :state (if (< i open) 'open 'merged)
                          :title (format "Change number %d of the example" i)
                          :author (if (zerop (% i 7)) "example-me" "example-alice")
                          :draft-p (zerop (% i 11))
                          :created (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                                                       (- 1790000000 (* i 3600)) t)
                          :updated "2026-10-09T00:00:00Z"
                          :head-rev "1111111111111111111111111111111111111111"
                          :base-ref (if stacked (format "branch-%d" (1- i)) "main")
                          :head-ref (format "branch-%d" i)
                          :cross-repo-p nil)))))))

(defun prrr-queue-bench--fill-prrr (open)
  "Store prrr's meta rows for the first OPEN PRs, and the viewer's Team."
  (prrr-db-replace-teams (list (prrr-team-create :combined-slug "example-org/reviewers"
                                                 :org "example-org" :slug "reviewers"
                                                 :fetched-at "2026-10-10T00:00:00Z")))
  (prrr-db-replace-pr-metas
   prrr-queue-bench--repo-id
   (cl-loop for i below open
            collect (prrr-pr-meta-create
                     :pr-id (format "PR_%04d" i) :forge-repo-id prrr-queue-bench--repo-id
                     :number (1+ i) :head-oid "1111111111111111111111111111111111111111"
                     :review-requests (and (zerop (% i 2)) '((user "example-me")))
                     :viewer-latest-review
                     (and (zerop (% i 3))
                          '("APPROVED" "2026-10-01T00:00:00Z"
                            "0000000000000000000000000000000000000000"))
                     :created-at "2026-09-01T00:00:00Z"
                     :fetched-at "2026-10-10T12:00:00Z"))))

(defun prrr-queue-bench--run-once ()
  "Gather the inputs and render them once; return (INPUTS-MS RENDER-MS)."
  (with-temp-buffer
    (magit-section-mode)
    (let* ((inhibit-read-only t)
           (start (float-time))
           (repo (closql-get (forge-db) prrr-queue-bench--repo-id 'forge-github-repository))
           (inputs (prrr-queue--inputs repo))
           (gathered (float-time)))
      (magit-insert-section (status)
        (prrr-queue-insert inputs))
      (list (* 1000 (- gathered start)) (* 1000 (- (float-time) gathered))))))

(defun prrr-queue-bench--median (numbers)
  "Return the median of NUMBERS, an odd-length list."
  (nth (/ (length numbers) 2) (sort (copy-sequence numbers) #'<)))

(defun prrr-queue-bench-run ()
  "Measure gathering and rendering the Review Queue; exit 1 over budget.
Prints the median of the inputs, the render and their total."
  (let* ((dir (make-temp-file "prrr-bench" t))
         (forge-database-file (expand-file-name "forge.sqlite" dir))
         (prrr-database-file (expand-file-name "prrr.sqlite" dir))
         (prrr-github-user "example-me")
         (over nil))
    (unwind-protect
        (progn
          (prrr-queue-bench--fill-forge 3000 200)
          (prrr-queue-bench--fill-prrr 200)
          (dotimes (_ 3) (prrr-queue-bench--run-once))
          (let* ((runs (cl-loop repeat 21 collect (prrr-queue-bench--run-once)))
                 (inputs (prrr-queue-bench--median (mapcar #'car runs)))
                 (render (prrr-queue-bench--median (mapcar #'cadr runs)))
                 (total (prrr-queue-bench--median
                         (mapcar (lambda (run) (+ (car run) (cadr run))) runs))))
            (message (concat "queue, 200 open of 3000 PRs: inputs %.1f ms + render %.1f ms"
                             " = %.1f ms (budget %.0f ms, fails over %.0f ms)")
                     inputs render total prrr-queue-bench-budget-ms
                     (* prrr-queue-bench-budget-ms prrr-queue-bench-tolerance))
            (setq over (> total (* prrr-queue-bench-budget-ms prrr-queue-bench-tolerance)))))
      (emacsql-close (forge-db))
      (prrr-db-close)
      (delete-directory dir t))
    (kill-emacs (if over 1 0))))

(provide 'prrr-queue-bench)
;;; prrr-queue-bench.el ends here
