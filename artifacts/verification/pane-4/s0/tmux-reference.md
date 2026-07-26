# tmux Normative Reference (scripted probes)

tmux version: tmux 3.7b
Session 101x41. Geometry tags: L/R(left/right), T/B(top/bottom), fw/fh(full width/height), hw/hh(half).

## Split-in-place flows

| Flow | Resulting geometry |
|---|---|
| `-` then `|` on BOTTOM (anchor) | p1(LTfwhh) + p2(LBhwhh) + p3(RBhwhh*) |
| `-` then `|` on TOP | p1(LThwhh) + p2(RThwhh*) + p3(LBfwhh) |
| `|` then `-` on RIGHT | p1(LThwfh) + p2(RThwhh) + p3(RBhwhh*) |
| `|` then `-` on LEFT | p1(LThwhh) + p2(LBhwhh*) + p3(RThwfh) |
| stacked 2x2: `-`, `|` bottom, `|` top | p1(LThwhh) + p2(RThwhh*) + p3(LBhwhh) + p4(RBhwhh) |
| sideBySide 2x2: `|`, `-` right, `-` left | p1(LThwhh) + p2(LBhwhh*) + p3(RThwhh) + p4(RBhwhh) |

## Focus crossing (select-pane -L/-R/-U/-D) per shape

For each shape: from every pane, every direction; result pane geometry (or 'no-op').

### sideBySide leading .two (left T/B + right full)
| From | Dir | Lands |
|---|---|---|
| p1(LThwhh) | L | p3(RThwfh) |
| p1(LThwhh) | R | p3(RThwfh) |
| p1(LThwhh) | U | p2(LBhwhh) |
| p1(LThwhh) | D | p2(LBhwhh) |
| p2(LBhwhh) | L | p3(RThwfh) |
| p2(LBhwhh) | R | p3(RThwfh) |
| p2(LBhwhh) | U | p1(LThwhh) |
| p2(LBhwhh) | D | p1(LThwhh) |
| p3(RThwfh) | L | p2(LBhwhh) |
| p3(RThwfh) | R | p2(LBhwhh) |
| p3(RThwfh) | U | no-op |
| p3(RThwfh) | D | no-op |

### sideBySide trailing .two (left full + right T/B)
| From | Dir | Lands |
|---|---|---|
| p1(LThwfh) | L | p3(RBhwhh) |
| p1(LThwfh) | R | p3(RBhwhh) |
| p1(LThwfh) | U | no-op |
| p1(LThwfh) | D | no-op |
| p2(RThwhh) | L | p1(LThwfh) |
| p2(RThwhh) | R | p1(LThwfh) |
| p2(RThwhh) | U | p3(RBhwhh) |
| p2(RThwhh) | D | p3(RBhwhh) |
| p3(RBhwhh) | L | p1(LThwfh) |
| p3(RBhwhh) | R | p1(LThwfh) |
| p3(RBhwhh) | U | p2(RThwhh) |
| p3(RBhwhh) | D | p2(RThwhh) |

### sideBySide 2x2
| From | Dir | Lands |
|---|---|---|
| p1(LThwhh) | L | p3(RThwhh) |
| p1(LThwhh) | R | p3(RThwhh) |
| p1(LThwhh) | U | p2(LBhwhh) |
| p1(LThwhh) | D | p2(LBhwhh) |
| p2(LBhwhh) | L | p4(RBhwhh) |
| p2(LBhwhh) | R | p4(RBhwhh) |
| p2(LBhwhh) | U | p1(LThwhh) |
| p2(LBhwhh) | D | p1(LThwhh) |
| p3(RThwhh) | L | p1(LThwhh) |
| p3(RThwhh) | R | p1(LThwhh) |
| p3(RThwhh) | U | p4(RBhwhh) |
| p3(RThwhh) | D | p4(RBhwhh) |
| p4(RBhwhh) | L | p2(LBhwhh) |
| p4(RBhwhh) | R | p2(LBhwhh) |
| p4(RBhwhh) | U | p3(RThwhh) |
| p4(RBhwhh) | D | p3(RThwhh) |

### stacked leading .two (top L/R + bottom full)
| From | Dir | Lands |
|---|---|---|
| p1(LThwhh) | L | p2(RThwhh) |
| p1(LThwhh) | R | p2(RThwhh) |
| p1(LThwhh) | U | p3(LBfwhh) |
| p1(LThwhh) | D | p3(LBfwhh) |
| p2(RThwhh) | L | p1(LThwhh) |
| p2(RThwhh) | R | p1(LThwhh) |
| p2(RThwhh) | U | p3(LBfwhh) |
| p2(RThwhh) | D | p3(LBfwhh) |
| p3(LBfwhh) | L | no-op |
| p3(LBfwhh) | R | no-op |
| p3(LBfwhh) | U | p2(RThwhh) |
| p3(LBfwhh) | D | p2(RThwhh) |

### stacked trailing .two (top full + bottom L/R)
| From | Dir | Lands |
|---|---|---|
| p1(LTfwhh) | L | no-op |
| p1(LTfwhh) | R | no-op |
| p1(LTfwhh) | U | p3(RBhwhh) |
| p1(LTfwhh) | D | p3(RBhwhh) |
| p2(LBhwhh) | L | p3(RBhwhh) |
| p2(LBhwhh) | R | p3(RBhwhh) |
| p2(LBhwhh) | U | p1(LTfwhh) |
| p2(LBhwhh) | D | p1(LTfwhh) |
| p3(RBhwhh) | L | p2(LBhwhh) |
| p3(RBhwhh) | R | p2(LBhwhh) |
| p3(RBhwhh) | U | p1(LTfwhh) |
| p3(RBhwhh) | D | p1(LTfwhh) |

### stacked 2x2
| From | Dir | Lands |
|---|---|---|
| p1(LThwhh) | L | p2(RThwhh) |
| p1(LThwhh) | R | p2(RThwhh) |
| p1(LThwhh) | U | p3(LBhwhh) |
| p1(LThwhh) | D | p3(LBhwhh) |
| p2(RThwhh) | L | p1(LThwhh) |
| p2(RThwhh) | R | p1(LThwhh) |
| p2(RThwhh) | U | p4(RBhwhh) |
| p2(RThwhh) | D | p4(RBhwhh) |
| p3(LBhwhh) | L | p4(RBhwhh) |
| p3(LBhwhh) | R | p4(RBhwhh) |
| p3(LBhwhh) | U | p1(LThwhh) |
| p3(LBhwhh) | D | p1(LThwhh) |
| p4(RBhwhh) | L | p3(LBhwhh) |
| p4(RBhwhh) | R | p3(LBhwhh) |
| p4(RBhwhh) | U | p2(RThwhh) |
| p4(RBhwhh) | D | p2(RThwhh) |

## MRU (most-recently-used) probes: full-span source crossing into a split band

| Scenario | Lands |
|---|---|
| visit R-bottom, L, then R | p3(RBhwhh) |
| then visit R-top, L, then R | p2(RThwhh) |
| visit B-right, U, then D | p3(RBhwhh) |
| then visit B-left, U, then D | p2(LBhwhh) |

## IMPORTANT: reading the raw tables (wrap-around caveat)

The probes above ran with tmux's DEFAULT edge behavior, which WRAPS at window
edges (e.g. `L` from a leftmost pane wraps to the rightmost pane; `U` from a
top pane wraps to the bottom). Rows where a boundary move lands on the
opposite edge are tmux wrap-around, NOT crossing semantics.

**Modeleaf normative adaptation (per the approved plan and the shipped,
user-approved 86e0b04 behavior): boundary moves are strict no-ops — no wrap.**
Interpret every raw row through that filter: a row is normative for Modeleaf
only when the move crosses an interior divider; edge-wrap rows map to no-op.

## Derived normative rules (Modeleaf-normative)

1. Splits are IN-PLACE: only the active pane divides; siblings never rearrange (verified: all six flow rows).
2. Crossing an interior divider from a split band lands in the geometrically overlapping (same-slot) pane; memory is ignored (verified: both 2x2 tables — LT->RT, LB->RB, etc.).
3. Crossing from a full-span pane into a split band lands on that band's most-recently-used member; unvisited bands default to the first (top/left) member (verified: MRU probes, both axes).
4. Boundary moves are strict no-ops (Modeleaf adaptation; tmux default wraps instead).
5. Perpendicular moves stay within the active band.
6. Probe binary: tmux 3.7b on this machine (original verification was 3.6a; rules 1-3 and 5 are identical across both).
