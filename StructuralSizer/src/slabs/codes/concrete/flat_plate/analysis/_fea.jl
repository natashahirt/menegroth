# =============================================================================
# Finite Element Analysis (FEA) — Barrel File
# =============================================================================
#
# 2D shell model with column stub frame elements for flat plate moment analysis.
#
# Include order matters — each file may depend on types/functions from earlier
# files.  The dependency graph is:
#
#   cache.jl          → FEAElementData, ElementMoments, FEAModelCache
#   geometry.jl       → slab boundary, vertex/cell geometry helpers
#   model.jl          → _build_fea_slab_model, _update_and_resolve!
#   precompute.jl     → _precompute_element_data!, _build_or_update_fea!
#   load_cases.jl     → D/L split solve, post-solve combination
#   rebar_axes.jl     → rebar direction resolution, moment rotation
#   forces.jl         → column stub force extraction
#   strips.jl         → CS polygon building, point-in-polygon classification
#   bandwidth.jl      → _section_cut_bandwidth (δ-band width heuristic)
#   delta_band.jl     → _integrate_at, _integrate_at_subset
#   nodal_field.jl    → NodalMomentField, smoothed nodal moments
#   section_cuts.jl   → CellPanel, CutLine, isoparametric section cuts
#   frame.jl          → frame-level moment extraction (full-width integration)
#   strip.jl          → design strip integration (CS/MS direct extraction)
#   moment_diagram.jl → nodal-smoothed multi-cut envelope extraction
#   torsion_discount.jl → ACI concrete torsion capacity (Mxy discount)
#   wood_armer.jl     → Wood–Armer per-element transformation
#   area_design.jl    → area-based per-element design extraction
#   dispatch.jl       → dispatch routing for design_approach + knobs
#   run.jl            → run_moment_analysis(::FEA, ...) entry point
#
# Reference: ACI 318-11 §13.2.1
# =============================================================================

using Logging
using Asap
using Meshes: coords

# ── Structs & cache ──
include("fea/cache.jl")

# ── Geometry helpers ──
include("fea/geometry.jl")

# ── Model build / update / solve ──
include("fea/model.jl")

# ── Per-element precompute + build-or-update entry point ──
include("fea/precompute.jl")

# ── D/L split solve + post-solve combination ──
include("fea/load_cases.jl")

# ── Rebar direction resolution + moment rotation ──
include("fea/rebar_axes.jl")

# ── Column stub force extraction ──
include("fea/forces.jl")

# ── Strip classification (CS/MS polygons) ──
include("fea/strips.jl")

# ── Section-cut bandwidth ──
include("fea/bandwidth.jl")

# ── δ-band moment integration ──
include("fea/delta_band.jl")

# ── Nodal moment field (area-weighted smoothing) ──
include("fea/nodal_field.jl")

# ── Isoparametric section cuts ──
include("fea/section_cuts.jl")

# ── Frame-level moment extraction ──
include("fea/frame.jl")

# ── Design strip integration ──
include("fea/strip.jl")

# ── Nodal-smoothed multi-cut envelope ──
include("fea/moment_diagram.jl")

# ── ACI concrete torsion capacity (Mxy discount) ──
include("fea/torsion_discount.jl")

# ── Wood–Armer per-element transformation ──
include("fea/wood_armer.jl")

# ── Area-based per-element design extraction ──
include("fea/area_design.jl")

# ── Dispatch routing ──
include("fea/dispatch.jl")

# ── Main entry point ──
include("fea/run.jl")

# ── Building-model source (FEA(source = :building)) ──
include("fea/building.jl")
