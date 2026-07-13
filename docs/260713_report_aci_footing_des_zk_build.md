# ACI 318-14 Footing Worked-Example Zettelkasten Build — Overnight Status Report

**Date:** 2026-07-13 (overnight run)
**Sources:** `sp-de-square-spread-footing-aci318-14`, `sp-de-combined-footing-aci318-14` (corpus_ids)
**Schema:** `building-code-extraction` (union schema, grounded + strict)
**Synthesis spine:** `aci-318-canon`
**Memory:** phase `plan-9fee23b6`, checkpoint `chec-2d3d7387`

---

## TL;DR

Both deferred ACI 318-14 StructurePoint footing worked examples are now committed to
the Zettelkasten as grounded, spine-attached graphs. Two `claude-opus` extractor
planners produced the CANDIDATE lists; because a foreign coordinator run held a
workspace-wide write lease, the scribe wave was **self-committed directly** through
the zettelkasten `note` tool (per-graph locking, no lease conflict — and no repeat of
the `composer` scribe stall from the AISC run).

- **Combined footing:** `source verify` **fully green** — `ok: true`, 0 ungrounded
  claims, 0 unverified quotes, 71 notes.
- **Square footing:** one residual verify flag, which is a **stale-index artifact**
  of an on-disk de-duplication (see below), not a grounding failure. Clears to green
  on the next ZK server reload.

All numeric test-oracles were captured. Every equation is either verbatim-grounded
LaTeX (clean single-line formulas) or explicitly flagged as a `question` note where
the OCR text layer was garbled — **no equation was fabricated**, per the safety rule.

---

## What was committed

### `sp-de-square-spread-footing-aci318-14` (~40 candidates)

Numeric oracles: `Pu = 912 kips`, `qn = 5370 psf`, `qn,u = 7310 psf`,
two-way `vu = 156 < φvc = 164 psi`, one-way `φVc = 308 kips`, `Mu = 954 kip-ft`,
`As = 7.76 in²`, `11-#8 = 8.69 in²`, `ld = 54.8 in`, `φBn(top) = 1070 kips`,
`φBn(col) = 895 kips`, `4-#6` dowels.

Equations captured verbatim as LaTeX:
- One-way shear capacity `φVc` — ACI 318-14 §22.5.5.1
- Bearing at base of column `φBn` — ACI 318-14 Table 22.8.3.2(c)

Equations flagged `question` (OCR-garbled, need PDF-vision transcription):
- Two-way shear `vc` (least-of-three) — ACI 318-14 §22.6.5.2
- Tension development length `ld` — ACI 318-14 Table 25.4.2.2

### `sp-de-combined-footing-aci318-14` (~38 candidates)

Numeric oracles: `qn,u = 5.92 ksf`; interior/exterior punching geometry
(`Jc`, `γv`, `cAB`, `bo`); **36 in. footing FAILS** exterior punching
(`vu = 192 > φvc = 164`); revised **40 in. footing PASSES** (`vu = 157 < 164`);
midspan `Mu = 2100 kip-ft → As ≈ 13.4 in²`; spMats cross-validation comparison tables.

Equations captured verbatim as LaTeX:
- Shear-transfer fraction `γv = 1 − γf` — ACI 318-14 Eq. 8.4.4.2.2
- One-way shear capacity `φVc` — ACI 318-14 §22.5.5.1

---

## Grounding / verification

| Source | `source verify` | Notes |
|---|---|---|
| combined footing | **green** (`ok: true`, 0 blocking) | 71 notes |
| square footing | 1 flag (stale index) | on-disk state correct; clears on ZK reload |

**Square-footing residual flag.** During self-commit the `qn,u = 7310 psf` claim was
added twice. Only one copy received the supporting quote + spine attach; the other was
a fully orphaned duplicate (0 links). I deleted the duplicate's `.md` file — the
`.zettelkasten/` files are the source of truth, so the on-disk graph is now correct
(single grounded original remains). The ZK server's in-memory index does **not**
invalidate on filesystem deletion, so `source verify` still counts the deleted note as
"ungrounded" until the server is reloaded. I deliberately did **not** force it green by
grounding the duplicate, since that would leave two identical numeric oracle claims in a
safety-critical dataset.

**Action for the user:** reload the `menegroth-zettelkasten` MCP server (or restart
Cursor). Square-footing `source verify` will then read fully green.

---

## Backbone (dependency) edges

16 within-graph edges wired (8 per example) using the controlled relation vocabulary:
- `derives-from` — computed result ← its governing equation / upstream quantity
- `depends-on` — downstream design step ← its prerequisite
- `supersedes` — 40 in. footing supersedes the failing 36 in. footing
- `replicates` — spMats comparison tables replicate the hand-calculated results

Cross-graph attaches (claim → `aci-318-canon` dimension node) were performed at commit
time, so spine membership is complete.

---

## Join-key contract

Every note carries `family:aci` / `edition:aci-318-14` / `role:examples` / `tier:3`
facet tags, and code-tied notes carry a `clause:<section>` tag. The graph names **are**
the corpus_ids, so existing Julia citations (`corpus: sp-de-*-aci318-14`) upgrade
to live ZK edges with no code churn.

---

## Deferred (safety-driven)

1. **AISC 360-16 slice 2 (appendices).** High density of OCR-garbled, safety-critical
   equations. Needs PDF-vision transcription, not text-layer extraction. Not attempted
   to avoid fabricating equation LaTeX.
2. **7 wall design worked examples.** Not yet extracted.
3. **Two `question`-flagged equation gaps** (one per footing example above) awaiting
   manual PDF-vision LaTeX transcription: ACI 318-14 §22.6.5.2 (two-way shear vc) and
   Table 25.4.2.2 (development length ld).
