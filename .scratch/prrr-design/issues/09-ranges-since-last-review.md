# Ranges: selecting commits, since-last-review, and Viewed interaction

Type: grilling
Status: open
Blocked by: 02, 03
Part of: ../map.md

## Question

Decide the Range model. How the user picks a Range (default merge-base to
head; a single commit; between two commits; since my last review); how
"since my last review" is computed from review history; whether commenting is
allowed on non-default Ranges per the API research, and if so how line
numbers map; how the Viewed flag behaves when the Range is not the default
(GitHub's flag is per PR, not per range); and how Stack navigation sets the
Range when moving to the PR above or below.
