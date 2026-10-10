;; The viewer's Teams across organizations, as the forge-query callback
;; receives them.  `teams' is an edges connection, so it arrives flat.
(data
 (viewer
  (login . "example-me")
  (organizations
   ((login . "example-org")
    (teams
     ((slug . "reviewers") (combinedSlug . "example-org/reviewers"))
     ((slug . "platform") (combinedSlug . "example-org/platform"))))
   ((login . "example-other-org")
    (teams)))))
