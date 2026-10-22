---
id: deci-d19cb2e7
type: decision
project: menegroth
parent_id: plan-b2670c25
title: 'Code steward mandate: logic flow stays readable'
node_label: Code steward mandate
tags: coordinator,steward,architecture,logic-flow
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-3f59d412
created_at: '2026-10-22T01:14:41.602297+00:00'
updated_at: '2026-10-22T01:14:41.602297+00:00'
invalidates: note-61fb1dd6
---
User confirmed the code-steward mandate on 2026-10-21 and added the governing requirement: the logic flow through the suite stays readable.

The steward is a checker. It reports and does not edit. It inherits the coordinating model; the user switches that agent to Opus before a steward pass. Installed as the code-steward persona in .cursor/agents.yaml (loaded on the next coordinator start; not restarted during the live cycle-12 run).

Primary test, on every change and again before a new family of systems: if ten more systems are added this same way, can a reader follow one named sequence from a public entry to the leaf check and back to the result, name the owner of each concept, and see which way the calls go? If not, P0, even when the numbers are right.

Logic flow sequence: what was requested, which gate ran, which method ran, which check governed, what was returned. A one-entry branch, a value silently replaced downstream, or a jump from StructuralSynthesizer into a private StructuralSizer helper breaks it. Fallbacks and failures are named steps.

Dependence: Asap → StructuralSizer → StructuralSynthesizer, and inside the sizer trace → types → Constants → loads → materials → optimize → codes → members/slabs/foundations. One concept, one home. One clause, one function. A new system names the seam it extends. A parallel pipeline is a P0.

Six surfaces carry the same facts (arguments, caller-visible result, snapshot restore, trace, API schema, report). tc is threaded from design_building to the leaf. Citations carry source_id, clause, and page; ENGINEERING JUDGMENT is labeled as judgment. Dead code and hot-path cost are in scope; fail-closed branches, protected oracles, and walls/lateral are not cleanup targets.

P0/P1 become a separate engineer task. P2 does not open a fix cycle.
