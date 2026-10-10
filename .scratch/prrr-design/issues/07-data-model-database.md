# Data model and local database: what is cached, keys, and invalidation

Type: grilling
Status: open
Blocked by: 02, 03, 04
Part of: ../map.md

## Question

Design prrr's own SQLite schema (via emacsql, alongside forge's database)
and its freshness rules. Decide which entities are stored (Threads and
Review Comments, Pending Review, Viewed flags, Teams, per-PR Review State
inputs, Range bookmarks such as "last reviewed head"), their keys, how they
relate to forge's PR ids, what is fetched on Review Buffer open versus on the
explicit invalidate-and-refetch chord, and how writes (new comment, reply,
viewed) update the database before or after the server confirms. Decide what
the queue reads from the database so it renders with no network. Decide the
local retry queue for failed publishes. The resolution is the schema and the
freshness rules, written so the spec can include them.
