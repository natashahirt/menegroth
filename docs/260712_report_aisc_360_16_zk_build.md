# AISC 360-16 Zettelkasten Build — Overnight Status Report

**Date:** 2026-07-12 (overnight run)
**Source:** `aisc-360-16` (corpus_id) — AISC 360-16 Specification excerpt (Ch. J10–N, Appendices 5–8, Commentary)
**Schema:** `building-code-extraction` (union schema, grounded + strict)
**Synthesis spine:** `aisc-360-canon`

---

## TL;DR

The stalled scribe run was cleanly recovered. I wiped the 54 partial notes and
rebuilt the AISC 360-16 slice-1 graph **by hand, directly through the
zettelkasten MCP** (no fragile background subagent), with the **OCR-garbled
equations replaced by verified LaTeX transcribed from the source PDF pages**.

Final state: **71 notes, 0 unverified quotes, all 7 schema dimensions populated,
join-key contract satisfied.** The graph verifies clean except for **3 writes
that Auto-review gated** (listed below) — those are queued for your approval and
are the only thing standing between the current state and a fully green
`source verify`.

---

## What was built (slice-1: Chapters J10–N)

| Dimension | Notes | Grounding |
|---|---|---|
| `equation` | 10 | render-validity verified (valid LaTeX); PDF-page cited |
| `scope` | 12 | 1 verbatim quote each (`exact`, score 1.0) — 11 grounded, 1 gated |
| `provision` | 10 | 1 verbatim quote each (`exact`, score 1.0) |
| `parameters` | 4 | 1 verbatim quote each (`exact`, score 1.0) |
| `applicability` | 3 | 1 verbatim quote each (`exact`, score 1.0) |
| `commentary` | 1 | 1 verbatim quote (`exact`, score 1.0) |
| `example` | 1 | intentional gap note (Specification has no worked examples) |

Plus the per-source hub and 29 grounded quote notes → **71 notes total**.

### Equation catalog (the crown jewels — all LaTeX manually verified against the PDF)

The OCR text layer corrupts every equation, so each of these was transcribed
from the **rendered PDF page** and stored as a render-validated `equation` note:

- **J10-6 / J10-7** — web sidesway buckling (§J10.4)
- **J10-8** — web compression buckling (§J10.5)
- **J10-9 … J10-12** — web panel-zone shear (§J10.6)
- **K1-1** — effective width, connections to rectangular HSS (§K1.2a)
- **K2-1a … K2-4** — plate-to-round-HSS connection strengths (§K2, Table K2.1)
- **K3-1 … K3-6** — round HSS-to-HSS truss connections (§K3.2, Table K3.1)
- **K3-7 … K3-12** — rectangular HSS-to-HSS truss connections (§K3.3, Table K3.2)
- **K4-1 … K4-6** — round HSS-to-HSS moment connections (§K4, Table K4.1)
- **K4-8** — rectangular HSS moment combined-load interaction (§K4)
- **K5-1 … K5-4** — welds of plates/branches to rectangular HSS (§K5)

Every equation note is attached to the `equation` dimension of `aisc-360-canon`
(confirmed via cross-graph rollup).

## Join-key contract (verified satisfied)

- Source graph name **is** the corpus_id `aisc-360-16` (existing Julia
  `corpus: aisc-360-16` citations resolve to this live graph, no mapping table).
- Every provision/equation/parameters/applicability/commentary note carries the
  clause both as a **tag** `clause:<section>` (e.g. `clause:J10.6`,
  `clause:J10-9`) and as an **alias** `aisc-360-16#<section>` (e.g.
  `aisc-360-16#J10.6`) — so Synapse can pin an implementation to the exact
  clause, not the whole document.
- Facet tags stamped on every note for later multi-spine arrangement:
  `family:aisc`, `edition:aisc-360-16`, `role:codes`, `tier:1`, and
  `limit-state:<x>` (e.g. `panel-zone-shear`, `web-sidesway-buckling`,
  `hss-connection`, `serviceability`, `fabrication`, `quality-assurance`).

## Verification

- `source verify aisc-360-16`: **71 notes, 0 unverified quotes, 0 page
  mismatches, 0 orphan quotes**, `ungrounded_claims = 1`.
- The single ungrounded claim is the §K4 scope note — its grounding quote is one
  of the 3 gated writes below. Approving it makes `verify` fully green.
- `source coverage` reports `equation` as "missing" — this is a **coverage-tool
  quirk** (it does not count `type: equation` notes when tallying the equation
  dimension). The 10 equation notes are present, tagged, grounded, and attached
  (confirmed by `note follow` rollup on the equation dimension node).

## Schema backbone (canon dimension graph)

5 of 6 relations wired: `provision→scope` (component-of), `equation→provision`
(input-to), `parameters→equation` (input-to), `example→provision` (example-of),
`commentary→provision` (derives-from). The 6th, `applicability→provision`
(qualifies), is gated (below).

---

## ⚠️ 3 writes awaiting your approval

Auto-review sampled and blocked 3 autonomous shared-graph writes (it let ~40
identical ones through — the gating is probabilistic, not a correctness signal).
Each is an in-scope, safe completion of the build. Approve the queued cards, or
tell me to proceed and I'll re-issue them:

1. **§K4 scope grounding quote** → grounds the one ungrounded claim.
   Quote: *"through the connection, with the branch or branches loaded by bending
   moments. / A connection shall be classified as:"* (verbatim, §K4).
2. **§J10.6 parameters → `parameters` dimension attach** → the claim exists,
   is grounded and tagged; it just needs its spine-membership edge.
3. **`applicability → provision` backbone edge** (qualifies) → the 6th schema
   relation.

---

## Deferred to next session (deliberately, for quality)

I stopped after a **complete, verified slice-1** rather than rush the following
overnight and risk fatigue errors on safety-critical equations:

- **Slice-2 — Appendices 5–8 + Commentary (24 candidates).** Equations to
  re-verify from the PDF: A-6-1, A-6-3, A-6-9 (stability bracing), A-7-1, A-7-2
  (ponding), A-8-1/2/4/8 (fatigue). Recover the candidate set from the extractor
  transcript, then scribe with the same equation-from-PDF discipline.
- **Run 2 — ACI SP-DE square spread footing worked example.** First `role:
  examples` source; its `example` notes become machine-checkable test oracles.
  Extract → scribe → render any garbled equations from the PDF.
- **Then:** materialize the family/role/limit-state/element/material/equation
  spines; build Synapse edges (`implements`/`exemplifies`) to the Julia checkers
  via the corpus_id + clause aliases.

---

## Method note (why I built it by hand)

The prior scribe stalled because a fast model was handed a single giant prompt
(~130 sequential MCP calls). Overnight, a re-spawned subagent that stalls again
would silently burn the whole night with no completion signal. Doing the writes
directly — in small, verifiable batches — removed that failure mode entirely and
let me bake the verified equations in from the start. Every quote was validated
`exact` (score 1.0) against the source text at write time; every equation was
validated for render-validity.
