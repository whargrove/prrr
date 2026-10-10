# Review Queue: Review States, ordering, and Stack display

Type: grilling
Status: open
Blocked by: 04
Part of: ../map.md

## Question

Define the Review Queue precisely. Decide the full Review State enum per PR
(awaiting my review; awaiting my team, teammate reviewed; I approved; I
requested changes; I commented; new commits since my review) and how each
shows in the queue line. Decide ordering within each Queue Group, whether a
PR can appear in both groups, how a Stack is displayed in the queue (indented
chain, bottom first?), and what information the queue line carries (number,
title, author, state, counts of unresolved Threads, stack position). Decide
the refresh model: when the queue recomputes, and whether it needs the
database. Record the resolved vocabulary in `CONTEXT.md`.
