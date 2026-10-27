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
;; Writes are here too.  Most go through `forge-mutate' or
;; `forge-rest'.  `forge-mutate' selects only clientMutationId, so the
;; four mutations whose answer prrr reads (creating the Pending
;; Review, a Thread, a reply, a Discussion Comment) go through
;; `prrr-github--mutate', which calls `ghub-query' with forge's token
;; as `forge-query' does.

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
  (defconst prrr-github--pr-meta-fields
    '(id number headRefOid createdAt isDraft
      (author login)
      (reviewRequests [(:edges t)]
        (requestedReviewer "__typename ... on User { login } ... on Team { combinedSlug }\n"))
      (latestReviews [(:edges t)]
        (author login) state submittedAt (commit oid)
        (onBehalfOf [(:edges t)] combinedSlug))
      (viewerLatestReview state submittedAt (commit oid))
      (viewerLatestReviewRequest id)
      (assignees [(:edges t)] login)
      additions deletions changedFiles)
    "The fields of one PR that a `prrr-pr-meta' row is decoded from."))

(eval-and-compile
  (defconst prrr-github-queue-query
    `(repository [(owner $owner String!) (name $name String!)]
       (pullRequests [(:edges t) (states . (OPEN))]
         ,@prrr-github--pr-meta-fields))
    "Review Queue inputs of one repository (SPEC section 4).
Variables: $owner and $name.  Pages every open PR."))

(eval-and-compile
  (defconst prrr-github-pr-nodes-query
    `(nodes [(ids $ids \[ID!\]!)]
       (,(intern "... on PullRequest") state ,@prrr-github--pr-meta-fields))
    "The queue fields of the PRs named by id, plus their state (SPEC section 4).
Variable: $ids, a vector of at most `prrr-github-nodes-per-request'
node ids.  The inline fragment is a symbol: ghub's query language
has no fragments, but prints a symbol's name as is.  GitHub answers
with one node per id, in order, null for a node it cannot return."))

(defconst prrr-github-nodes-per-request 100
  "Most ids one nodes(ids:) query may name.")

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
             id (author login) body createdAt lastEditedAt (replyTo id) state fullDatabaseId
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

(defun prrr-github--pr-meta (pr forge-repo-id fetched-at)
  "Decode the node PR into a `prrr-pr-meta'.
PR was selected as `prrr-github--pr-meta-fields'.  FORGE-REPO-ID and
FETCHED-AT are stored in the row."
  (let-alist pr
    (prrr-pr-meta-create
     :pr-id .id
     :forge-repo-id forge-repo-id
     :number .number
     :head-oid .headRefOid
     :review-requests (prrr-github--review-requests .reviewRequests)
     :latest-reviews (prrr-github--latest-reviews .latestReviews)
     :viewer-latest-review (prrr-github--viewer-review .viewerLatestReview)
     :viewer-latest-review-request .viewerLatestReviewRequest.id
     :assignees (mapcar (lambda (user) (alist-get 'login user)) .assignees)
     :additions .additions
     :deletions .deletions
     :changed-files .changedFiles
     :created-at .createdAt
     :fetched-at fetched-at)))

(defun prrr-github-decode-queue (data forge-repo-id &optional fetched-at)
  "Decode queue query DATA into a list of `prrr-pr-meta'.
FORGE-REPO-ID is stored in every row; FETCHED-AT is the timestamp to
record, nil when the caller stamps rows itself."
  (let-alist data
    (mapcar (lambda (pr) (prrr-github--pr-meta pr forge-repo-id fetched-at))
            .repository.pullRequests)))

(defun prrr-github-decode-pr-nodes (data ids forge-repo-id &optional fetched-at)
  "Decode DATA, the answer to `prrr-github-pr-nodes-query' for IDS.
Return (:open METAS :gone IDS): a `prrr-pr-meta' per node still open,
stamped FORGE-REPO-ID and FETCHED-AT, and the ids of IDS whose PR is
no longer open or that GitHub did not return."
  (let ((open (cl-loop for pr in (alist-get 'nodes data)
                       when (and pr (equal (alist-get 'state pr) "OPEN"))
                       collect (prrr-github--pr-meta pr forge-repo-id fetched-at))))
    (list :open open
          :gone (seq-remove (lambda (id) (seq-some (lambda (meta) (equal id (prrr-pr-meta-pr-id meta)))
                                                   open))
                            ids))))

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

(defun prrr-github--database-id (value)
  "Return the database id VALUE as a string, or nil.
GitHub sends a BigInt as a string in GraphQL and a number in REST."
  (and value (format "%s" value)))

(defun prrr-github--comment (node thread-id pr-id)
  "Decode a review comment NODE of THREAD-ID on PR-ID into a `prrr-comment'.
The body's line ends become newlines: GitHub's web UI sends CRLF,
which would hide suggestion blocks and show as ^M."
  (let-alist node
    (prrr-comment-create
     :comment-id .id
     :thread-id thread-id
     :pr-id pr-id
     :author .author.login
     :body (and .body (string-replace "\r\n" "\n" .body))
     :created-at .createdAt
     :updated-at .lastEditedAt
     :reply-to .replyTo.id
     :review-id .pullRequestReview.id
     :state (if (equal .state "PENDING") 'pending 'submitted)
     :local-state 'sent
     :agent-p nil
     :database-id (prrr-github--database-id .fullDatabaseId))))

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
           :resolvable-p (and (if .isResolved .viewerCanUnresolve .viewerCanResolve) t)
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

(defun prrr-github--refusal (payload)
  "Describe GitHub's refusal of a write, given the PAYLOAD of its HTTP 422."
  (let* ((message (and (consp payload) (alist-get 'message payload)))
         (first (and (consp payload) (car (alist-get 'errors payload))))
         (detail (if (stringp first) first (and (consp first) (alist-get 'message first)))))
    (cond ((and message detail) (format "GitHub refused: %s (%s)" message detail))
          (message (format "GitHub refused: %s" message))
          (t "GitHub refused the request (HTTP 422)"))))

(defun prrr-github--http-message (rest)
  "Return the message GitHub sent with an HTTP failure, or \"\".
REST is what follows the status code in ghub's (error http CODE ...);
ghub appends the decoded response body last when an errorback is set."
  (let* ((payload (car (last rest)))
         (message (and (consp payload) (alist-get 'message payload))))
    (if (stringp message) message "")))

(defun prrr-github-error (err &optional headers now)
  "Classify ERR, a failed request, as (:kind KIND :message TEXT :reset-at TIME).
ERR is what ghub hands an errorback: (errors ERROR...) for GraphQL
errors, (error http CODE) for HTTP failures, (error SYMBOL ...) for
transport failures.  HEADERS is the response header alist; NOW, a Lisp
time defaulting to the current time, anchors a retry-after delay.
KIND is one of:
  `rate-limited'  a primary or secondary limit; RESET-AT says when it ends.
                  The secondary limit is an HTTP 429, or a 403 whose
                  message names a rate limit;
  `auth'          the token was rejected (HTTP 401), or access was denied
                  (any other 403: permissions, SSO, an IP allow-list);
  `not-found'     the repository or pull request does not exist;
  `offline'       no connection or a server error, worth retrying later;
  `error'         anything else, such as GitHub refusing a write (HTTP 422).
A request whose success answer does not name what it created fails
as `unconfirmed' instead (`prrr-github--created').
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
      (`(error http ,code . ,rest)
       (cond ((and (memq code '(403 429))
                   (or (equal (prrr-github--header headers "x-ratelimit-remaining") "0")
                       (prrr-github--header headers "retry-after")))
              (list :kind 'rate-limited
                    :message (format "GitHub rate limit (HTTP %d)" code)
                    :reset-at (prrr-github--reset-at headers now)))
             ((or (eq code 429)
                  (and (eq code 403)
                       (string-match-p "rate limit" (prrr-github--http-message rest))))
              ;; GitHub's secondary limit without retry-after.  Only its
              ;; message tells it from a permission, SSO or IP allow-list
              ;; denial, which carries the same quota headers.  GitHub says
              ;; to wait at least a minute; x-ratelimit-reset belongs to the
              ;; primary limit.
              (list :kind 'rate-limited
                    :message (format "GitHub secondary rate limit (HTTP %d)" code)
                    :reset-at (format-time-string "%Y-%m-%dT%H:%M:%SZ" (time-add now 60) t)))
             ((eq code 401)
              (list :kind 'auth :message "GitHub rejected the token (HTTP 401)" :reset-at nil))
             ((eq code 403)
              (let ((message (prrr-github--http-message rest)))
                (list :kind 'auth
                      :message (if (string-empty-p message)
                                   "GitHub denied access (HTTP 403)"
                                 (format "GitHub denied access (HTTP 403): %s" message))
                      :reset-at nil)))
             ((eq code 422)
              (list :kind 'error :message (prrr-github--refusal (car (last rest))) :reset-at nil))
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

(defun prrr-github-fetch-pr-metas (host ids callback errorback &optional forge-repo-id)
  "Fetch the queue fields of the PRs with node ids IDS on HOST.
One request per `prrr-github-nodes-per-request' ids, all sent at once.
CALLBACK receives the merged (:open METAS :gone IDS) of
`prrr-github-decode-pr-nodes', the rows stamped with the current time
and FORGE-REPO-ID, once every request answered.  ERRORBACK receives
the first failure, classified by `prrr-github-error', or an `error'
failure when an answer cannot be decoded; the other answers are then
dropped.  Exactly one of the two is called."
  (let* ((chunks (seq-partition ids prrr-github-nodes-per-request))
         (pending (length chunks))
         (failed nil)
         (open nil)
         (gone nil))
    (dolist (chunk chunks)
      (prrr-github--query host prrr-github-pr-nodes-query
        ((ids (vconcat chunk)))
        :callback (prrr-github--callback
                   (lambda (data)
                     (prrr-github-decode-pr-nodes data chunk forge-repo-id (prrr-github--now)))
                   (lambda (answer)
                     (unless failed
                       (setq open (append open (plist-get answer :open))
                             gone (append gone (plist-get answer :gone)))
                       (when (zerop (cl-decf pending))
                         (funcall callback (list :open open :gone gone)))))
                   (lambda (failure)
                     (unless failed
                       (setq failed t)
                       (funcall errorback failure))))
        :errorback (prrr-github--errorback
                    (lambda (failure)
                      (unless failed
                        (setq failed t)
                        (funcall errorback failure))))))))

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

;;;; Mutations

(defun prrr-github-set-viewed (host pr-id path viewed callback errorback)
  "Mark PATH of the pull request with node id PR-ID as Viewed on HOST.
With VIEWED nil, unmark it.  CALLBACK receives no argument once GitHub
accepts.  ERRORBACK receives a failure classified by
`prrr-github-error'.  Exactly one of the two is called."
  (let ((callback (prrr-github--callback #'ignore (lambda (_) (funcall callback)) errorback))
        (errorback (prrr-github--errorback errorback)))
    (if viewed
        (forge-mutate host markFileAsViewed ((pullRequestId pr-id) (path path))
          :callback callback :errorback errorback)
      (forge-mutate host unmarkFileAsViewed ((pullRequestId pr-id) (path path))
        :callback callback :errorback errorback))))

;;;; Writes

(defun prrr-github--input (&rest pairs)
  "Return the alist of NAME VALUE PAIRS whose VALUE is non-nil."
  (let ((input nil))
    (while pairs
      (let ((name (pop pairs)) (value (pop pairs)))
        (when value (push (cons name value) input))))
    (nreverse input)))

(defun prrr-github--side-name (side)
  "Return GitHub's DiffSide for SIDE, `left' or `right', or nil."
  (pcase side ('left "LEFT") ('right "RIGHT")))

(defun prrr-github--anchor-input (anchor)
  "Return the fields of ANCHOR, a plist as `prrr-state-anchor' returns.
The alist names them as GraphQL does.  A line anchor leaves subjectType
out, LINE being GitHub's default and REST refusing \"line\" beside a
line; a File Comment has neither line nor side.  The Pending Review and
Immediate Publish both send these fields, so the two cannot drift."
  (let ((file (eq (plist-get anchor :subject-type) 'file)))
    (prrr-github--input
     'path (plist-get anchor :path)
     'line (and (not file) (plist-get anchor :line))
     'side (and (not file) (prrr-github--side-name (plist-get anchor :side)))
     'startLine (and (not file) (plist-get anchor :start-line))
     'startSide (and (not file) (prrr-github--side-name (plist-get anchor :start-side)))
     'subjectType (and file "FILE"))))

(defconst prrr-github--rest-anchor-names
  '((path . path) (line . line) (side . side) (startLine . start_line)
    (startSide . start_side) (subjectType . subject_type))
  "REST's name of each field `prrr-github--anchor-input' returns.")

(defun prrr-github--rest-anchor-params (anchor)
  "Return the fields of ANCHOR as REST names them.
REST spells the File Comment's subject_type in lower case."
  (mapcar (pcase-lambda (`(,name . ,value))
            (cons (alist-get name prrr-github--rest-anchor-names)
                  (if (eq name 'subjectType) (downcase value) value)))
          (prrr-github--anchor-input anchor)))

(eval-and-compile
  (defconst prrr-github-pending-review-query
    '(repository [(owner $owner String!) (name $name String!)]
       (pullRequest [(number $number Int!)]
         id
         (reviews [(:edges t) (states . (PENDING)) (author $me String!)]
           id (commit oid) body createdAt)))
    "The viewer's Pending Review of one PR.
Variables: $owner, $name, $number and $me.")

  (defconst prrr-github-create-review-mutation
    '(mutation (addPullRequestReview [(input $input AddPullRequestReviewInput!)]
                 (pullRequestReview id (commit oid) body createdAt)))
    "Create a Pending Review; selects the new review.")

  (defconst prrr-github-add-thread-mutation
    '(mutation (addPullRequestReviewThread [(input $input AddPullRequestReviewThreadInput!)]
                 (thread id (comments [(first 1)] (nodes id createdAt fullDatabaseId)))))
    "Add a Thread to a Pending Review; selects the Thread and its comment.")

  (defconst prrr-github-add-reply-mutation
    '(mutation (addPullRequestReviewThreadReply
                [(input $input AddPullRequestReviewThreadReplyInput!)]
                (comment id createdAt fullDatabaseId)))
    "Add a reply to a Thread in a Pending Review; selects the new comment.")

  (defconst prrr-github-add-comment-mutation
    '(mutation (addComment [(input $input AddCommentInput!)]
                 (commentEdge (node id databaseId createdAt))))
    "Post a Discussion Comment; selects the new comment.
databaseId, not fullDatabaseId: forge stores that one as the number of
its post."))

(defun prrr-github--mutate (host document input decode callback errorback)
  "Send the GraphQL mutation DOCUMENT to HOST with INPUT as its $input.
`forge-mutate' selects only clientMutationId, and these mutations
create things whose ids prrr needs, so DOCUMENT selects them and goes
through `ghub-query' with forge's token, as `forge-query' does.  DECODE
turns the answer's data into what CALLBACK receives; ERRORBACK receives
a failure classified by `prrr-github-error'.  Exactly one is called."
  (ghub-query document `((input . ,input))
    :auth 'forge :host host :forge 'github
    :callback (prrr-github--callback decode callback errorback)
    :errorback (prrr-github--errorback errorback)))

(defun prrr-github--created (id)
  "Return ID, GitHub's id of what a request created.
GitHub can answer a creation with success but without the id: a null
GraphQL payload with no errors, or a REST answer without a node_id.
GitHub may have made the thing all the same, and prrr cannot store it
without its id, so this signals `prrr-github-failure' with an
`unconfirmed' failure: the write counts neither as done nor as failed,
and the Outbox has a refetch decide whether it landed."
  (or id
      (signal 'prrr-github-failure
              (list :kind 'unconfirmed :message "GitHub's answer does not name what it made"
                    :reset-at nil))))

(defun prrr-github--pending-review (node pr-id)
  "Decode a PullRequestReview NODE of PR-ID into a `prrr-pending-review'."
  (let-alist node
    (prrr-pending-review-create :pr-id pr-id :review-id .id :commit-oid .commit.oid
                                :body .body :created-at .createdAt)))

(defun prrr-github-find-pending-review (host owner name number me callback errorback)
  "Find the Pending Review of ME on OWNER/NAME#NUMBER on HOST.
CALLBACK receives a `prrr-pending-review', or nil when ME has none.
ERRORBACK receives a failure classified by `prrr-github-error'; a
response without the pull request is a `not-found' failure.  Exactly
one of the two is called."
  (prrr-github--query host prrr-github-pending-review-query
    ((owner owner) (name name) (number number) (me me))
    :callback
    (prrr-github--callback
     (lambda (data)
       (let ((pr (alist-get 'pullRequest (cdr (assq 'repository data)))))
         (unless pr
           (signal 'prrr-github-failure
                   (list :kind 'not-found
                         :message (format "Pull request %s/%s#%s not found" owner name number)
                         :reset-at nil)))
         (let ((review (car (alist-get 'reviews pr))))
           (and review (prrr-github--pending-review review (alist-get 'id pr))))))
     callback errorback)
    :errorback (prrr-github--errorback errorback)))

(defun prrr-github-create-pending-review (host pr-id commit callback errorback)
  "Create the viewer's Pending Review on the PR with node id PR-ID on HOST.
The review is on COMMIT, the head the user commented on.  CALLBACK
receives the new `prrr-pending-review'; ERRORBACK a failure classified
by `prrr-github-error'."
  (prrr-github--mutate
   host prrr-github-create-review-mutation
   (prrr-github--input 'pullRequestId pr-id 'commitOID commit)
   (lambda (data)
     (let ((review (alist-get 'pullRequestReview (alist-get 'addPullRequestReview data))))
       (prrr-github--created (alist-get 'id review))
       (prrr-github--pending-review review pr-id)))
   callback errorback))

(defun prrr-github-add-thread (host review-id anchor body callback errorback)
  "On HOST, add a Thread at ANCHOR to the Pending Review REVIEW-ID.
BODY is its first comment.
ANCHOR is a plist as `prrr-state-anchor' returns.  CALLBACK receives
\(:thread-id :comment-id :database-id :created-at) of what GitHub made;
ERRORBACK a failure classified by `prrr-github-error'."
  (prrr-github--mutate
   host prrr-github-add-thread-mutation
   (append (prrr-github--input 'pullRequestReviewId review-id 'body body)
           (prrr-github--anchor-input anchor))
   (lambda (data)
     (let* ((thread (alist-get 'thread (alist-get 'addPullRequestReviewThread data)))
            (comment (car (alist-get 'nodes (alist-get 'comments thread)))))
       (let-alist comment
         (list :thread-id (prrr-github--created (alist-get 'id thread))
               :comment-id (prrr-github--created .id)
               :database-id (prrr-github--database-id .fullDatabaseId)
               :created-at .createdAt))))
   callback errorback))

(defun prrr-github-add-reply (host review-id thread-id body callback errorback)
  "On HOST, reply BODY to the Thread THREAD-ID in the Pending Review REVIEW-ID.
CALLBACK receives (:comment-id :database-id :created-at); ERRORBACK a
failure classified by `prrr-github-error'."
  (prrr-github--mutate
   host prrr-github-add-reply-mutation
   (prrr-github--input 'pullRequestReviewThreadId thread-id
                       'pullRequestReviewId review-id 'body body)
   (lambda (data)
     (let-alist (alist-get 'addPullRequestReviewThreadReply data)
       (list :comment-id (prrr-github--created .comment.id)
             :database-id (prrr-github--database-id .comment.fullDatabaseId)
             :created-at .comment.createdAt)))
   callback errorback))

(defun prrr-github--rest-comment (data)
  "Decode the review comment DATA a REST call answered with.
Return (:comment-id :database-id :created-at).  Like the GraphQL
creations, an answer without GitHub's node id fails as `unconfirmed'
\(`prrr-github--created'): prrr names every comment by that id, so a
comment stored without one could be neither edited, deleted nor
matched by a refetch."
  (let-alist data
    (list :comment-id (prrr-github--created .node_id)
          :database-id (prrr-github--database-id .id)
          :created-at .created_at)))

(defun prrr-github-publish-comment (host owner name number commit anchor body
                                         callback errorback)
  "Publish BODY at ANCHOR of OWNER/NAME#NUMBER on HOST at once.
This is Immediate Publish of a new Thread: GitHub's REST endpoint for
one review comment, on COMMIT, the head the user commented on.  ANCHOR
is a plist as `prrr-state-anchor' returns.  CALLBACK receives
\(:comment-id :database-id :created-at); GitHub's answer does not name
the new Thread.  ERRORBACK receives a failure classified by
`prrr-github-error'.
`forge-rest' takes its parameters as literal bindings, and the anchor's
are computed, so this goes through `forge--rest'."
  (forge--rest host "POST" (format "/repos/%s/%s/pulls/%s/comments" owner name number)
    `((body . ,body) (commit_id . ,commit) ,@(prrr-github--rest-anchor-params anchor))
    :callback (prrr-github--callback #'prrr-github--rest-comment callback errorback)
    :errorback (prrr-github--errorback errorback)))

(defun prrr-github-publish-reply (host owner name number database-id body
                                       callback errorback)
  "Publish BODY at once as a reply on OWNER/NAME#NUMBER on HOST.
DATABASE-ID is GitHub's database id of the first comment of the
Thread replied to; GitHub's REST endpoint takes no other.  CALLBACK
receives (:comment-id :database-id :created-at); ERRORBACK a failure
classified by `prrr-github-error'."
  (forge-rest host "POST"
    (format "/repos/%s/%s/pulls/%s/comments/%s/replies" owner name number database-id)
    ((body body))
    :callback (prrr-github--callback #'prrr-github--rest-comment callback errorback)
    :errorback (prrr-github--errorback errorback)))

(defun prrr-github-remove-review-request (host owner name number login callback errorback)
  "Remove the review request of LOGIN from OWNER/NAME#NUMBER on HOST.
GitHub's REST endpoint; GraphQL has no removal of one reviewer.
CALLBACK is called with no argument; ERRORBACK receives a failure
classified by `prrr-github-error'."
  (forge-rest host "DELETE"
    (format "/repos/%s/%s/pulls/%s/requested_reviewers" owner name number)
    ((reviewers (vector login)))
    :callback (prrr-github--ignore-answer callback errorback)
    :errorback (prrr-github--errorback errorback)))

(defun prrr-github-remove-assignee (host owner name number login callback errorback)
  "Unassign LOGIN from OWNER/NAME#NUMBER on HOST.
A pull request's assignees are its issue's.  CALLBACK is called with no
argument; ERRORBACK receives a failure classified by `prrr-github-error'."
  (forge-rest host "DELETE" (format "/repos/%s/%s/issues/%s/assignees" owner name number)
    ((assignees (vector login)))
    :callback (prrr-github--ignore-answer callback errorback)
    :errorback (prrr-github--errorback errorback)))

(defun prrr-github--ignore-answer (callback errorback)
  "Return a ghub callback that calls CALLBACK with no argument.
ERRORBACK receives a failure if CALLBACK's caller signals."
  (prrr-github--callback #'ignore (lambda (_) (funcall callback)) errorback))

(defun prrr-github-add-discussion-comment (host pr-id body callback errorback)
  "Post BODY as a Discussion Comment on the PR with node id PR-ID on HOST.
CALLBACK receives (:comment-id :database-id :created-at) of the new
comment; :database-id is the integer forge stores as the post's
number, so the Review Buffer can tell when forge has pulled it.
ERRORBACK receives a failure classified by `prrr-github-error'."
  (prrr-github--mutate
   host prrr-github-add-comment-mutation
   (prrr-github--input 'subjectId pr-id 'body body)
   (lambda (data)
     (let-alist (alist-get 'addComment data)
       (list :comment-id (prrr-github--created .commentEdge.node.id)
             :database-id .commentEdge.node.databaseId
             :created-at .commentEdge.node.createdAt)))
   callback errorback))

(defun prrr-github-edit-comment (host comment-id body callback errorback)
  "Make BODY the text of the review comment COMMENT-ID on HOST.
CALLBACK receives no argument; ERRORBACK a classified failure."
  (forge-mutate host updatePullRequestReviewComment
    ((pullRequestReviewCommentId comment-id) (body body))
    :callback (prrr-github--ignore-answer callback errorback)
    :errorback (prrr-github--errorback errorback)))

(defun prrr-github-delete-comment (host comment-id callback errorback)
  "Delete the review comment COMMENT-ID on HOST.
CALLBACK receives no argument; ERRORBACK a classified failure."
  (forge-mutate host deletePullRequestReviewComment ((id comment-id))
    :callback (prrr-github--ignore-answer callback errorback)
    :errorback (prrr-github--errorback errorback)))

(defun prrr-github-set-resolved (host thread-id resolved callback errorback)
  "Resolve the Thread THREAD-ID on HOST, or unresolve it when RESOLVED is nil.
CALLBACK receives no argument; ERRORBACK a classified failure."
  (let ((callback (prrr-github--ignore-answer callback errorback))
        (errorback (prrr-github--errorback errorback)))
    (if resolved
        (forge-mutate host resolveReviewThread ((threadId thread-id))
          :callback callback :errorback errorback)
      (forge-mutate host unresolveReviewThread ((threadId thread-id))
        :callback callback :errorback errorback))))

(defun prrr-github--event (verdict)
  "Return GitHub's PullRequestReviewEvent for VERDICT."
  (pcase-exhaustive verdict
    ('approve "APPROVE")
    ('request-changes "REQUEST_CHANGES")
    ('comment "COMMENT")))

(defun prrr-github-submit-review (host review-id pr-id commit verdict body
                                       callback errorback)
  "Submit the viewer's review of the PR with node id PR-ID on HOST.
VERDICT is `approve', `request-changes' or `comment'; BODY the summary.
REVIEW-ID is the Pending Review to submit; when nil, a review with no
comments is created and submitted at once on COMMIT.  CALLBACK receives
no argument; ERRORBACK a classified failure."
  (let ((callback (prrr-github--ignore-answer callback errorback))
        (errorback (prrr-github--errorback errorback))
        (event (prrr-github--event verdict)))
    (if review-id
        (forge-mutate host submitPullRequestReview
          ((pullRequestReviewId review-id) (event event) (body body))
          :callback callback :errorback errorback)
      (forge-mutate host addPullRequestReview
        ((pullRequestId pr-id) (commitOID commit) (event event) (body body))
        :callback callback :errorback errorback))))

(defun prrr-github-discard-review (host review-id callback errorback)
  "Delete the Pending Review REVIEW-ID and its comments on HOST.
CALLBACK receives no argument; ERRORBACK a classified failure."
  (forge-mutate host deletePullRequestReview ((pullRequestReviewId review-id))
    :callback (prrr-github--ignore-answer callback errorback)
    :errorback (prrr-github--errorback errorback)))

(provide 'prrr-github)
;;; prrr-github.el ends here
