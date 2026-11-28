---
id: plan-1fee6060
type: plan
project: menegroth
parent_id: plan-35f67705
title: Joist flange link, then steel columns with shearheads under flat plates
node_label: Joist flange link, then steel columns with shearhe
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-0ce53f8a
created_at: '2026-11-06T14:59:53.692504+00:00'
updated_at: '2026-11-06T14:59:53.692504+00:00'
---
Order: Part A (joist flange link) first, then Part B (steel columns).

User decisions (2026-11-06):
- Flange width computed per catalog candidate web (exact ACI 318-11 §8.12.2), not one bf with bw_default=12in.
- Add a joist-proportioned T catalog (bw 4-8 in, stem <= 3.5 bw, clear spacing <= 30 in, 3/4 in cover per §7.7.1(c) -- verify clause) and wire JoistConstruction into shear so §8.13.8 (+10% Vc) and §11.4.6.1(c) (no Av,min for joist construction, aci-318-11 p.175) apply during sizing.
- Outermost joists get their own member group (one-sided §8.12.3 flange must not govern interior joists).
- Center the LinearAxisPattern joist layout (equal end gaps) instead of stepping from pmin.
- Free-edge outermost joist: §8.12.3 one-side limits.
- Fix girder ACI overhang in the same change: half CLEAR distance (web faces), and girders parallel to joists stop at the first joist. Fix only in the ACI path -- beam_side_profiles also feeds AISC §I3.1a composite widths (centerline-based, correct) and must not change.
- Steel columns under flat plates: rigid connection; punching remedy = §11.11.4 shearheads at interior columns only; edge/corner steel columns use headed studs then thicken. Footprint for the d/2 section = steel section outline (d x bf for W, B x H for HSS). Do not take §11.11.4.9 Mv credit. §11.11.4.10 anchorage reported as a requirement.

Part A scope: joists (level_of>=1) get geometric per-side clear distance to nearest parallel web (never tributary_profile, which carries cascade deposits); hf = owning slab topping total_depth; LinearAxisPattern only (others error); neighbor web of different type = previous iteration section else catalog max; NLP T-beam path needs bf(bw) or must be blocked for joists; route joists into story_shell_service _rc_flange_widths. Verify with run_concrete_rib_trial.jl + two-way-with-beams pipeline + composite regression (test_composite_context.jl).

Part B scope: lift steel gates in StructuralSizer/src/slabs/sizing.jl:57-77, graph_builder.jl:319, pipeline_spec.jl:74-76, api/validation.jl:203, _get_column_opts, pipeline/api.jl:139 fallback (PixelFrame stays rejected). Steel branches at flat-plate kernel coupling points: in-loop RC column sizing (iteration.jl:443,736; rule_of_thumb.jl:251), column_moment_distribution_factors (Ec), flat-plate FEA column stiffness, update_asap_column_sections!, _resolve_punching_failures! (no growth). New :shearheads reinforcement: §11.11.4.1-4.8 + §11.11.7.3 (aci-318-11 pp.204-211). ACI 318-19 R22.6 removed shearheads (refers to 318-14) -- edition-tied. Preliminary AISC sizing fixes a minimum outline; reconciliation size_columns!(SteelColumnOptions) after lock with catalog filtered to outline >= minimum (monotone), then one slab re-check.
