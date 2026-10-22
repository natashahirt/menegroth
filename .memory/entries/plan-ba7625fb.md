---
id: plan-ba7625fb
type: plan
project: menegroth
parent_id: plan-b2670c25
title: Wiring pass 1–5 then corpus pass 6–9 before ribbed slabs
node_label: Wiring pass 1–5 then corpus pass 6–9 before ribbed
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-23780c45
created_at: '2026-10-22T18:33:53.608427+00:00'
updated_at: '2026-10-22T18:33:53.608427+00:00'
---
User approved two sequential passes. Wave 1 (this run): wiring only, verify-first. (1) Confirm member_group_demands already envelopes pattern cases; fix only a path that still sizes strength from full-load displacements. (2) ACI 318-11 §13.7.6.3 0.75 live-load factor on pattern cases — _generate_pattern_cases currently emits full + two full-live checkerboards. (3) Forward existing Pu_t and Mux_neg into AISC 360-16 §H1 (size_columns raw API, size_w_nlp, composite context). (4) Warn when FlatPlateOptions.col_I_factor disagrees with params.column_I_factor; params stay the owner. (5) Strip footing Mu uses each column's own c_across, not one c_across_max for every band. Then targeted tests. Wave 2 after wave 1 is green: edge-punching second-axis Jc (corpus stop), centroid eccentricity vs spSlab, sloped-rafter sag/hog sign, rolled-web Cv1 §G2.1(b) corpus check. Reviewer skipped. Critic only on the code-factor items. Wall endpoint-overhang already fixed (deci-f691b344) and is out of scope.
