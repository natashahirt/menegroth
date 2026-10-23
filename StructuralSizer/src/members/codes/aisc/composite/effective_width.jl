# ==============================================================================
# Effective Slab Width — AISC 360-16 Section I3.1a
# ==============================================================================
#
# AISC 360-16 §I3.1a — "Effective Width" (corpus: aisc-360-16, PDF p. 150),
# verbatim:
#
#   "The effective width of the concrete slab shall be the sum of the effective
#    widths for each side of the beam centerline, each of which shall not
#    exceed:
#    (a) one-eighth of the beam span, center-to-center of supports;
#    (b) one-half the distance to the centerline of the adjacent beam; or
#    (c) the distance to the edge of the slab."
#
# The cap is applied PER SIDE (each side independently ≤ L/8), which is why the
# per-station path (per_station.jl) keeps the two sides separate rather than
# capping their sum.
#
# Two entry points:
#   • Scalar path (this file) — constant beam spacing / edge distance from the
#     slab's `beam_spacing_*` / `edge_dist_*` fields. This is the regular-grid
#     implementation; it is kept byte-identical to the historical result.
#   • Per-station path (per_station.jl, `b_eff_at_station`) — a §I3.1a(a) `L/8`
#     cap applied per station against the LOCAL per-side tributary extent `d(s)`,
#     for irregular / skew / merged / continuous bays. A constant per-side extent
#     `d = spacing/2` reduces that path BYTE-IDENTICALLY to this scalar one.

"""
    get_b_eff(slab::AbstractSlabOnBeam, L_beam) -> Length

Effective width of the concrete slab for composite action per AISC 360-16 §I3.1a
(corpus: aisc-360-16, PDF p. 150).

The effective width is the sum of the effective widths on each side of the beam
centerline, each of which shall not exceed:
  (a) one-eighth of the beam span, center-to-center of supports;
  (b) one-half the distance to the centerline of the adjacent beam;
  (c) the distance to the edge of the slab.

Returns a length in the same units as `L_beam`. For irregular / skew / merged or
continuous bays where the per-side distance varies along the span, use the
per-station path `b_eff_at_station` (per_station.jl).
"""
function get_b_eff(slab::AbstractSlabOnBeam, L_beam)
    b_left  = _effective_half_width(L_beam, slab.beam_spacing_left,  slab.edge_dist_left)
    b_right = _effective_half_width(L_beam, slab.beam_spacing_right, slab.edge_dist_right)
    return b_left + b_right
end

"""
    _effective_half_width(L_beam, beam_spacing, edge_dist) -> Length

Effective width for ONE side of the beam centerline per AISC 360-16 §I3.1a
(corpus: aisc-360-16, PDF p. 150).

Limits:
  (a) `L_beam / 8`        — one-eighth of the c-to-c span;
  (b) `beam_spacing / 2`  — half the distance to the adjacent beam centerline;
  (c) `edge_dist`         — distance to the slab edge (applied when not `nothing`).
"""
function _effective_half_width(L_beam, beam_spacing, edge_dist)
    b = min(L_beam / 8, beam_spacing / 2)
    if edge_dist !== nothing
        b = min(b, edge_dist)
    end
    return b
end
