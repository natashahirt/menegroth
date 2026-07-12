---
id: citation-join-key
name: citation-join-key
category: pattern
tags: citation,corpus,clause,synapse,join-key,grounding
status: active
created_at: '2026-07-12T23:09:25.947352+00:00'
updated_at: '2026-07-12T23:09:25.947352+00:00'
---
# Skill (pattern): citation-join-key

`corpus_id#clause` is the single identifier shared across the whole knowledge
graph. It already appears verbatim in code and tests today, so it is the join
key that makes code <-> canon <-> test links deterministic (no fuzzy/embedding
match needed).

**Where it appears (all the same string):**
- Zettelkasten note id: the corpus_id is the note identity; clause-level notes
  are `corpus_id#clause` under the document/family spine.
- Code comments: `# ACI 318-11 S8.5.1 (corpus: aci-318-11, page 115)` and
  docstrings (`.cursor/rules/corpus.mdc`).
- `CheckResult(..., "ACI 318-11 10.3.6")` provision strings.
- Test headers: `# (corpus: sp-de-combined-footing-aci318-14)`.
- Report lines and synapse edges.

**Synapse edges (build via the shared key, not embeddings):**
- `implements`: code symbol -> clause note (`corpus_id#clause`). Emitted in the
  implement stage for each clause a function encodes.
- `verifies`: test -> worked-example case note -> the code it exercises. Emitted
  in the test stage.

**Discipline.**
- Every code-derived formula/limit carries its `corpus_id` + clause + page.
- Non-code choices are tagged `ENGINEERING JUDGMENT` (no fake citation).
- Clause-level granularity: a citation resolves to the exact provision
  (`corpus_id#clause`), not just the document - this is what powers the
  "suspicious number -> exact clause -> worked example -> code" report jump.
- Never mint a fresh id for something that already has a corpus_id; reuse it so
  existing citations upgrade into live edges automatically.
