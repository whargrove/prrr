# Prototype: keymap and transient menus for the Review Buffer and Review Queue

Type: prototype
Status: open
Blocked by: 01, 06, 08, 09
Part of: ../map.md

## Question

Produce the full key table and the transient menu layout for the Review
Buffer and the Review Queue section, as a throwaway prototype the human can
load and press keys in (menus can call stubs). Constraints: every action has
a mnemonic single key; the transient mirrors them exactly; no collisions with
the magit-diff-mode and magit-section keys the user still needs (TAB, n, p,
RET, g, q, j); which key opens the menu (`?` versus `C-o` versus `h`);
sub-menus for comment, review, range, stack, viewed, and agent actions. The
resolution is the key table and menu structure, recorded for the spec.
