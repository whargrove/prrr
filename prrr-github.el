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
;; Every request takes an ERRORBACK that receives a failure classified by
;; `prrr-github-error'; ghub's own error shapes never leave this file.
;; Mutations arrive in milestone 4.

;;; Code:

(require 'cl-lib)
(require 'let-alist)
(require 'forge)
(require 'prrr-db)

(defcustom prrr-github-user nil
  "GitHub login of the viewer.
When nil, the `github.user' Git variable is used, as forge does."
  :type '(choice (const :tag "Use the github.user Git variable" nil)
                 (string :tag "Login"))
  :group 'prrr)

(defun prrr-github-viewer ()
  "Return the viewer's GitHub login, or nil when none is configured.
`prrr-github-user' wins; otherwise the `github.user' Git variable of
the current repository, which is where forge reads it."
  (or prrr-github-user (magit-get "github.user")))

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

(eval-and-compile
  (defconst prrr-github-review-data-query
    '(repository [(owner $owner String!) (name $name String!)]
		 (pullRequest [(number $number Int!)]
			      id headRefOid
			      (reviewThreads [(:edges t)]
					     id path line startLine diffSide startDiffSide originalLine
					     isOutdated isResolved subjectType viewerCanResolve viewerCanUnresolve
					     (comments [(:edges t)]
						       id (author login) body createdAt lastEditedAt (replyTo id) state
						       (pullRequestReview id) (originalCommit oid)))
			      (reviews [(:edges t) (states . (PENDING)) (author $me String!)]
				       id (commit oid) body createdAt)
			      (files [(:edges t)] path viewerViewedState)))
    "Threads, the viewer's Pending Review, Viewed flags and head of one PR.
Variables: $owner, $name, $number and $me (the viewer's login).
The pending review's own comments are not selected: pending comments
appear in reviewThreads with state PENDING, which is where their side
comes from (research 03, section 2)."))

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

;;;; Decoding per-PR review data

(defun prrr-github--side (side)
  "Translate a DiffSide string SIDE into `left', `right' or nil."
  (pcase side ("LEFT" 'left) ("RIGHT" 'right)))

(defun prrr-github--comment (node thread-id pr-id)
  "Decode a review comment NODE of THREAD-ID on PR-ID into a `prrr-comment'."
  (let-alist node
    (prrr-comment-create
     :comment-id .id
     :thread-id thread-id
     :pr-id pr-id
     :author .author.login
     :body .body
     :created-at .createdAt
     :updated-at .lastEditedAt
     :reply-to .replyTo.id
     :review-id .pullRequestReview.id
     :state (if (equal .state "PENDING") 'pending 'submitted)
     :local-state 'sent
     :agent-p nil)))

(defun prrr-github--thread (node pr-id fetched-at)
  "Decode a reviewThreads NODE of PR-ID into (THREAD . COMMENTS).
FETCHED-AT is stamped on the Thread."
  (let-alist node
    (cons (prrr-thread-create
           :thread-id .id
           :pr-id pr-id
           :path .path
           :line .line
           :start-line .startLine
           :side (prrr-github--side .diffSide)
           :start-side (prrr-github--side .startDiffSide)
           :subject-type (if (equal .subjectType "FILE") 'file 'line)
           :outdated-p (and .isOutdated t)
           :resolved-p (and .isResolved t)
           :original-line .originalLine
           :original-commit (let-alist (car .comments) .originalCommit.oid)
           :fetched-at fetched-at)
          (mapcar (lambda (comment) (prrr-github--comment comment .id pr-id))
                  .comments))))

(defun prrr-github--viewed-state (state)
  "Translate a FileViewedState string STATE into a `prrr-viewed' state."
  (pcase state
    ("VIEWED" 'viewed)
    ("DISMISSED" 'dismissed)
    (_ 'unviewed)))

(defun prrr-github-decode-review-data (data pr-id &optional fetched-at)
  "Decode per-PR review DATA of PR-ID into a plist.
Keys: :threads (list of `prrr-thread'), :comments (list of
`prrr-comment' in Thread order), :pending-review (`prrr-pending-review'
or nil), :viewed (list of `prrr-viewed'), :head-oid.  FETCHED-AT is
stamped on Threads and Viewed rows.
Return nil when DATA has no pull request (deleted, or a wrong number)."
  (let-alist (cdr (assq 'repository data))
    (when .pullRequest
      (let ((decoded (mapcar (lambda (node) (prrr-github--thread node pr-id fetched-at))
                             (alist-get 'reviewThreads .pullRequest)))
            (pending (car (alist-get 'reviews .pullRequest))))
	(list :threads (mapcar #'car decoded)
              :comments (apply #'append (mapcar #'cdr decoded))
              :pending-review
              (and pending
                   (let-alist pending
                     (prrr-pending-review-create :pr-id pr-id
						 :review-id .id
						 :commit-oid .commit.oid
						 :body .body
						 :created-at .createdAt)))
              :viewed
              (mapcar (lambda (file)
			(let-alist file
                          (prrr-viewed-create :pr-id pr-id
                                              :path .path
                                              :state (prrr-github--viewed-state .viewerViewedState)
                                              :fetched-at fetched-at)))
                      (alist-get 'files .pullRequest))
              :head-oid (alist-get 'headRefOid .pullRequest))))))

;;;; Errors

(defun prrr-github--header (headers name)
  "Return the value of response header NAME in HEADERS, ignoring case."
  (cdr (assoc-string name headers t)))

(defun prrr-github--reset-at (headers now)
  "Return when the rate limit described by HEADERS ends, as a timestamp.
Uses x-ratelimit-reset (epoch seconds) or retry-after (seconds after
NOW, a Lisp time); without either, one minute after NOW."
  (let ((reset (prrr-github--header headers "x-ratelimit-reset"))
        (retry (prrr-github--header headers "retry-after")))
    (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                        (cond (reset (string-to-number reset))
                              (retry (time-add now (string-to-number retry)))
                              (t (time-add now 60)))
                        t)))

(defun prrr-github-error (err &optional headers now)
  "Classify ERR, a failed request, as (:kind KIND :message TEXT :reset-at TIME).
ERR is what ghub hands an errorback: (errors ERROR...) for GraphQL
errors, (error http CODE) for HTTP failures, (error SYMBOL ...) for
transport failures.  HEADERS is the response header alist; NOW, a Lisp
time defaulting to the current time, anchors a retry-after delay.
KIND is one of:
  `rate-limited'  a primary or secondary limit; RESET-AT says when it ends;
  `auth'          the token was rejected;
  `not-found'     the repository or pull request does not exist;
  `offline'       no connection or a server error, worth retrying later;
  `error'         anything else.
RESET-AT is nil unless KIND is `rate-limited'."
  (let ((now (or now (current-time))))
    (pcase err
      (`(errors . ,errors)
       (let ((types (mapcar (lambda (error) (alist-get 'type error)) errors))
             (text (or (alist-get 'message (car errors)) "GitHub GraphQL error")))
         (cond ((member "RATE_LIMITED" types)
                (list :kind 'rate-limited :message text
                      :reset-at (prrr-github--reset-at headers now)))
               ((member "NOT_FOUND" types)
                (list :kind 'not-found :message text :reset-at nil))
               (t (list :kind 'error :message text :reset-at nil)))))
      (`(error http ,code . ,_)
       (cond ((and (memq code '(403 429))
                   (or (equal (prrr-github--header headers "x-ratelimit-remaining") "0")
                       (prrr-github--header headers "retry-after")))
              (list :kind 'rate-limited
                    :message (format "GitHub rate limit (HTTP %d)" code)
                    :reset-at (prrr-github--reset-at headers now)))
             ((memq code '(401 403))
              (list :kind 'auth
                    :message (format "GitHub rejected the token (HTTP %d)" code)
                    :reset-at nil))
             ((eq code 404)
              (list :kind 'not-found :message "GitHub returned HTTP 404" :reset-at nil))
             (t (list :kind 'offline
                      :message (format "GitHub returned HTTP %s" code)
                      :reset-at nil))))
      (`(error . ,data)
       (list :kind 'offline
             :message (format "Cannot reach GitHub: %s"
                              (string-trim (mapconcat (lambda (part) (format "%s" part))
                                                      data " ")))
             :reset-at nil))
      (_ (list :kind 'error :message (format "Unexpected GitHub failure: %S" err)
               :reset-at nil)))))

(defun prrr-github--errorback (errorback)
  "Return a ghub errorback that hands ERRORBACK the classified error."
  (lambda (err headers &rest _)
    (funcall errorback (prrr-github-error err headers))))

(define-error 'prrr-github-failure "GitHub request failed")

(defun prrr-github--callback (decode callback errorback)
  "Return a ghub callback that decodes the answer and hands it to CALLBACK.
DECODE turns the answer's data into what CALLBACK receives.  When it
signals `prrr-github-failure', whose data is a classified failure, or
any other error, ERRORBACK receives the failure instead, so exactly one
of CALLBACK and ERRORBACK runs.  Errors in CALLBACK itself propagate."
  (lambda (data &rest _)
    (let ((decoded
           (condition-case err
               (list (funcall decode data))
             (prrr-github-failure (funcall errorback (cdr err)) nil)
             (error (funcall errorback
                             (list :kind 'error
                                   :message (format "Cannot decode GitHub's answer: %s"
                                                    (error-message-string err))
                                   :reset-at nil))
                    nil))))
      (when decoded
        (funcall callback (car decoded))))))

;;;; Requests

(defun prrr-github-fetch-queue (host owner name callback errorback &optional forge-repo-id)
  "Fetch the Review Queue inputs of OWNER/NAME on HOST.
CALLBACK receives a list of `prrr-pr-meta' stamped with the current
time and FORGE-REPO-ID.  ERRORBACK receives a failure classified by
`prrr-github-error', or an `error' failure when the answer cannot be
decoded; exactly one of the two is called."
  (prrr-github--query host prrr-github-queue-query
    ((owner owner) (name name))
    :callback (prrr-github--callback
               (lambda (data)
                 (prrr-github-decode-queue data forge-repo-id (prrr-github--now)))
               callback errorback)
    :errorback (prrr-github--errorback errorback)))

(defun prrr-github-fetch-teams (host me callback errorback)
  "Fetch the Teams of the viewer ME on HOST.
CALLBACK receives a list of `prrr-team' stamped with the current time.
ERRORBACK receives a failure classified by `prrr-github-error', or an
`error' failure when the answer cannot be decoded; exactly one of the
two is called."
  (prrr-github--query host prrr-github-teams-query
    ((me (vector me)))
    :callback (prrr-github--callback
               (lambda (data) (prrr-github-decode-teams data (prrr-github--now)))
               callback errorback)
    :errorback (prrr-github--errorback errorback)))

(defun prrr-github-fetch-review-data (host owner name number me callback errorback)
  "Fetch Threads, Pending Review, Viewed flags and head of OWNER/NAME#NUMBER.
HOST is the API host; ME the viewer's login, used to find the Pending
Review.  CALLBACK receives the plist of `prrr-github-decode-review-data'
with rows stamped with the current time.  ERRORBACK receives a failure
classified by `prrr-github-error'; a response without the pull request
is a `not-found' failure and never reaches CALLBACK.  Exactly one of
the two is called."
  (prrr-github--query host prrr-github-review-data-query
    ((owner owner) (name name) (number number) (me me))
    :callback
    (prrr-github--callback
     (lambda (data)
       (let ((pr-id (alist-get 'id (alist-get 'pullRequest
                                              (cdr (assq 'repository data))))))
         (or (prrr-github-decode-review-data data pr-id (prrr-github--now))
             (signal 'prrr-github-failure
                     (list :kind 'not-found
                           :message (format "Pull request %s/%s#%s not found"
                                            owner name number)
                           :reset-at nil)))))
     callback errorback)
    :errorback (prrr-github--errorback errorback)))

(provide 'prrr-github)
;;; prrr-github.el ends here
