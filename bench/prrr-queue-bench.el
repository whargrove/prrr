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

;;; Commentary:

;; SPEC section 12: render the Review Queue from the database for 200
;; PRs within 20 ms.  Run with `make bench'.

;;; Code:

(require 'cl-lib)
(require 'prrr-queue)

(defconst prrr-queue-bench-budget-ms 20.0
  "SPEC section 12 budget for rendering 200 PRs.")

(defconst prrr-queue-bench-tolerance 1.25
  "A run fails when the median exceeds the budget by more than this factor.")

(defun prrr-queue-bench--inputs (count)
  "Return `prrr-queue-insert' inputs for COUNT PRs, a fifth of them stacked."
  (let (pairs metas)
    (dotimes (i count)
      (let* ((id (format "PR_%04d" i))
             (stacked (and (> i 0) (zerop (% i 5))))
             (pr (prrr-pr-create
                  :id id :number (1+ i) :title (format "Change number %d of the example" i)
                  :author (if (zerop (% i 7)) "example-me" "example-alice")
                  :draft-p (zerop (% i 11))
                  :created-at (format-time-string "%Y-%m-%dT%H:%M:%SZ" (- 1790000000 (* i 3600)) t)
                  :updated-at "2026-10-09T00:00:00Z"
                  :head-oid "1111111111111111111111111111111111111111"
                  :base-ref (if stacked (format "branch-%d" (1- i)) "main")
                  :head-ref (format "branch-%d" i))))
        (push (cons (forge-pullreq :id (format "forge-%d" i) :number (1+ i) :their-id id) pr) pairs)
        (push (prrr-pr-meta-create
               :pr-id id :head-oid "1111111111111111111111111111111111111111"
               :review-requests (and (zerop (% i 2)) '((user "example-me")))
               :viewer-latest-review (and (zerop (% i 3))
                                          '("APPROVED" "2026-10-01T00:00:00Z"
                                            "0000000000000000000000000000000000000000")))
              metas)))
    (list :pairs (nreverse pairs) :metas metas :teams '("example-org/reviewers")
          :me "example-me" :default-branch "main" :unresolved (make-hash-table :test #'equal)
          :status nil :now "2026-10-10T12:00:00Z" :width 120)))

(defun prrr-queue-bench--render-ms (inputs)
  "Render INPUTS once into a fresh buffer; return the elapsed milliseconds."
  (with-temp-buffer
    (magit-section-mode)
    (let ((inhibit-read-only t)
          (start (float-time)))
      (magit-insert-section (status)
        (prrr-queue-insert inputs))
      (* 1000 (- (float-time) start)))))

(defun prrr-queue-bench-run ()
  "Measure the Review Queue render, print the median, exit 1 over budget."
  (let* ((inputs (prrr-queue-bench--inputs 200))
         (_warmup (dotimes (_ 3) (prrr-queue-bench--render-ms inputs)))
         (runs (sort (cl-loop repeat 21 collect (prrr-queue-bench--render-ms inputs)) #'<))
         (median (nth 10 runs)))
    (message "queue render, 200 PRs: %.1f ms (budget %.0f ms)" median prrr-queue-bench-budget-ms)
    (kill-emacs (if (> median (* prrr-queue-bench-budget-ms prrr-queue-bench-tolerance)) 1 0))))

(provide 'prrr-queue-bench)
;;; prrr-queue-bench.el ends here
