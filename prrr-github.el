;;; prrr-github.el --- GitHub GraphQL access for prrr  -*- lexical-binding: t -*-

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

;; Every GitHub call prrr makes lives here.  Queries are written in
;; ghub's Lisp GraphQL DSL and sent through `forge-query', so the host,
;; the token and pagination come from forge.  The decoders are pure
;; functions from the callback data to `prrr-db' structs and are tested
;; against the fixtures under test/fixtures/github/.
;;
;; Response shape (facts note): the callback receives
;; (data (repository ...)); `let-alist' works on it directly.  A
;; connection written as [(:edges t)] arrives as a plain list of node
;; alists.  JSON null and false both arrive as nil.
;;
;; Mutations arrive in milestone 4; this file is read-only until then.

;;; Code:

(require 'cl-lib)
(require 'let-alist)
(require 'forge)
(require 'prrr-db)

;;;; Queries

(eval-and-compile
  (defconst prrr-github-queue-query
    '(repository [(owner $owner String!) (name $name String!)]
       (pullRequests [(:edges t) (states . (OPEN))]
         id number headRefOid createdAt isDraft
         (author login)
         (reviewRequests [(:edges t)]
           (requestedReviewer "__typename ... on User { login } ... on Team { combinedSlug }\n"))
         (latestReviews [(:edges t)]
           (author login) state submittedAt (commit oid)
           (onBehalfOf [(:edges t)] combinedSlug))
         (viewerLatestReview state submittedAt (commit oid))
         (viewerLatestReviewRequest login)))
    "Review Queue inputs of one repository (SPEC section 4).
Variables: $owner and $name.  Pages every open PR."))

(eval-and-compile
  (defconst prrr-github-teams-query
    '(viewer login
       (organizations [(:edges t)]
         login
         (teams [(:edges t) (userLogins $me \[String!\])] slug combinedSlug)))
    "The viewer's Teams in every organization (SPEC section 4).
Variable: $me, a one-element list holding the viewer's login.  The
type is the symbol `[String!]' because ghub prints a vector type as
`(String!)', which GraphQL rejects."))

(defmacro prrr-github--query (host query-symbol variables &rest keys)
  "Send the query stored in QUERY-SYMBOL to HOST through `forge-query'.
VARIABLES is a literal list of (NAME FORM) pairs, FORM being evaluated
at call time; KEYS are `forge-query' keyword arguments such as
:callback.  `forge-query' takes its query and variable names
literally, so the constant named by QUERY-SYMBOL is spliced into the
call at macro-expansion time."
  (declare (indent 2))
  `(forge-query ,host ,(symbol-value query-symbol) ,variables ,@keys))

(defun prrr-github--now ()
  "Return the current UTC time as GitHub formats timestamps."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))

;;;; Decoding the queue

(defun prrr-github--review-requests (nodes)
  "Decode reviewRequests NODES into (user LOGIN) and (team SLUG) pairs.
Requested reviewers of other kinds (bots, mannequins) are dropped."
  (delq nil
        (mapcar (lambda (node)
                  (let-alist node
                    (pcase .requestedReviewer.__typename
                      ("User" (list 'user .requestedReviewer.login))
                      ("Team" (list 'team .requestedReviewer.combinedSlug)))))
                nodes)))

(defun prrr-github--latest-reviews (nodes)
  "Decode latestReviews NODES.
Each result is (LOGIN STATE SUBMITTED-AT COMMIT-OID ON-BEHALF-OF-SLUGS)."
  (mapcar (lambda (node)
            (let-alist node
              (list .author.login .state .submittedAt .commit.oid
                    (mapcar (lambda (team) (alist-get 'combinedSlug team))
                            .onBehalfOf))))
          nodes))

(defun prrr-github--viewer-review (node)
  "Decode a viewerLatestReview NODE into (STATE SUBMITTED-AT COMMIT-OID)."
  (and node (let-alist node (list .state .submittedAt .commit.oid))))

(defun prrr-github-decode-queue (data forge-repo-id &optional fetched-at)
  "Decode queue query DATA into a list of `prrr-pr-meta'.
FORGE-REPO-ID is stored in every row; FETCHED-AT is the timestamp to
record, nil when the caller stamps rows itself."
  (let-alist data
    (mapcar (lambda (pr)
              (let-alist pr
                (prrr-pr-meta-create
                 :pr-id .id
                 :forge-repo-id forge-repo-id
                 :number .number
                 :head-oid .headRefOid
                 :review-requests (prrr-github--review-requests .reviewRequests)
                 :latest-reviews (prrr-github--latest-reviews .latestReviews)
                 :viewer-latest-review (prrr-github--viewer-review .viewerLatestReview)
                 :viewer-latest-review-request .viewerLatestReviewRequest.login
                 :created-at .createdAt
                 :fetched-at fetched-at)))
            .repository.pullRequests)))

;;;; Decoding teams

(defun prrr-github-decode-teams (data &optional fetched-at)
  "Decode viewer teams DATA into a list of `prrr-team' stamped FETCHED-AT."
  (let-alist data
    (cl-mapcan (lambda (org)
                 (let ((org-login (alist-get 'login org)))
                   (mapcar (lambda (team)
                             (let-alist team
                               (prrr-team-create :combined-slug .combinedSlug
                                                 :org org-login
                                                 :slug .slug
                                                 :fetched-at fetched-at)))
                           (alist-get 'teams org))))
               .viewer.organizations)))

;;;; Requests

(defun prrr-github-fetch-queue (host owner name callback &optional forge-repo-id)
  "Fetch the Review Queue inputs of OWNER/NAME on HOST.
CALLBACK receives a list of `prrr-pr-meta' stamped with the current
time and FORGE-REPO-ID."
  (prrr-github--query host prrr-github-queue-query
    ((owner owner) (name name))
    :callback (lambda (data &rest _)
                (funcall callback
                         (prrr-github-decode-queue data forge-repo-id
                                                   (prrr-github--now))))))

(defun prrr-github-fetch-teams (host me callback)
  "Fetch the Teams of the viewer ME on HOST.
CALLBACK receives a list of `prrr-team' stamped with the current time."
  (prrr-github--query host prrr-github-teams-query
    ((me (vector me)))
    :callback (lambda (data &rest _)
                (funcall callback
                         (prrr-github-decode-teams data (prrr-github--now))))))

(provide 'prrr-github)
;;; prrr-github.el ends here
