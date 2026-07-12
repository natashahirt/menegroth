---
id: report-feedback-contract
name: report-feedback-contract
category: pattern
tags: report,trace,contract,citation,corpus,synapse,provenance,jump-link,verifies
status: active
created_at: '2026-07-12T23:18:51.335356+00:00'
updated_at: '2026-07-12T23:18:51.335356+00:00'
---
# Skill (pattern): report-feedback-contract

Stage 4 of `implement-design-system`. Defines how menegroth's engineering /
validation reports emit machine-traceable identifiers so the reported numbers
close the loop back into the knowledge graph - an LLM or engineer can jump from
any number to the exact code clause, the worked example that validates it, the
code that produced it, and the design decision behind it. Also powers the
"zero un-cited magic numbers" gate in the definition of done.

Companion: `citation-join-key` (the corpus_id#clause identity), `worked-example-case`.

## The jump-link chain (what every reported number must resolve to)

```
number  ->  check  ->  clause (corpus_id#clause)  ->  worked-example case (corpus_id?)
                                     |                          |
                                     v                          v
                              code symbol (file#function)   memory decision id (why)
```

Bidirectional: from a zk clause note you can also find every report value that
cites it, and from a case note every report line that verifies it.

## Where reports live today (the surfaces this contract applies to)
- Validation reports: `StructuralSynthesizer/test/report_generators/*.jl`
  generate `StructuralSynthesizer/test/reports/*.txt` (e.g. `report_composite_beam`
  in `composite_beam_report.jl`). Human/LLM-readable ASCII; clauses today live in
  section labels as free text, e.g. "Positive Flexural Strength (AISC I3.2a)",
  checks like "Stud diameter (I8.1)". Each generator returns a results NamedTuple.
- Production report: `StructuralSynthesizer/src/postprocess/engineering_report.jl`
  (plain text) + `report_tables.jl` helpers (`section_break`, `fv`, `pass_fail`).
- Diagnostic JSON: `StructuralSynthesizer/src/api/diagnose.jl` `checks[]` already
  carries a `code_clause` field, but it is HARDCODED, not sourced from the checker.
- The only checker-native clause source is `CheckResult.code_clause`
  (`StructuralSizer/src/optimize/core/interface.jl`), which flows into
  `design.solver_trace` and `explain_trace_lookup` - not into the reports.

## The contract

A report is graph-traceable when it satisfies all of:

1. **Clause token.** Every section/check derived from code carries a parseable
   citation token `[corpus:<corpus_id>#<clause>]` in addition to its human label.
   Example: `Positive Flexural Strength (AISC I3.2a)  [corpus:aisc-360-16#I3.2a]`.
   The free-text clause and the token must agree.

2. **Check provenance.** Each design check (a demand-vs-capacity comparison)
   records: `quantity`, `demand`, `capacity`, `ratio`, `pass`, `units`, and its
   `clause` token. Non-code choices carry `judgment: <reason>` instead of a
   clause (never a fake citation) - mirrors `.cursor/rules/corpus.mdc`.

3. **Worked-example anchor.** A report section that reproduces a published
   worked example (e.g. "DG9 Example 5.1 - W10x49", "AISC Example I-1") declares
   the case id (= the example's corpus_id, see `worked-example-case`) and emits
   `computed | expected | tolerance | pass`. This is the `verifies` edge and the
   discrepancy gate: computed outside tolerance -> HARD STOP, report it.

4. **Structured sidecar (the graph-facing artifact).** Alongside `<name>.txt`
   the generator emits `<name>.report.json`: a list of records
   `{quantity, value, units, demand, capacity, ratio, pass,
     clause: "corpus_id#clause" | null, judgment: str | null,
     case: "corpus_id" | null, code: "file#function", decision: "deci-..." | null}`.
   The .txt stays human-facing; the .json is what the loop parses (robust vs.
   regexing prose). Both derive from ONE collector so there is no divergence.

5. **Citations-used manifest.** The report footer lists the full set of
   `corpus_id#clause` it touched and the case ids it validated. This set MUST
   equal the canon manifest gathered in stage 1 (any delta = a gap to resolve).

## Feedback direction (report -> graph), run by the `record`/`report` stage
- Parse the sidecar; for each record with a `clause`, ensure a synapse
  `implements` edge (code#function -> clause note); for each `case`, a `verifies`
  edge (report/test -> case note -> code).
- Register the report as a memory `document` whose `links_to` = the clause notes
  + case notes it cites.
- Gate: every numeric design result must have a `clause` OR a `judgment`; any
  bare number is an un-cited-magic-number failure. Any `case` record with
  pass=false is a HARD STOP.

## Minimal wiring points (implementation, do via the loop later)
- `report_tables.jl` / the generators' `_chk` and `_row2` closures gain optional
  `clause=`, `case=`, `code=` kwargs that (a) render the compact token inline and
  (b) push a record into a `ReportCollector` accumulated per report.
- Emit the collector as `<name>.report.json` next to the `.txt`.
- Add a clause normalizer: free-text checker strings ("AISC 360-16 G2",
  "ACI 318-19 22.5") -> canonical `corpus_id#clause` ("aisc-360-16#G2",
  "aci-318-19#22.5"). Source the token from `CheckResult.code_clause` wherever a
  check flows from the sizer, so the report token and the checker agree by
  construction.
- Optional: replace the hardcoded `code_clause` in `diagnose.jl` with the
  normalized token from `CheckResult` so the API diagnose path and the reports
  share one source of truth.

## Definition of done for a report
Every design number carries a clause token or a judgment tag; every worked-example
section declares its case id with computed/expected/tolerance/pass; the sidecar
JSON is emitted; the citations-used manifest equals the canon manifest; synapse
implements/verifies edges created; report registered as a memory document.
