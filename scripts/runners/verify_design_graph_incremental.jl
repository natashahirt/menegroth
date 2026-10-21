# =============================================================================
# Incremental Variation Verify Harness — Invalidation Matrix (Run 2)
# =============================================================================
#
# The EXACT-FIRST proof for the Run-2 variation API (`DesignSession` /
# `redesign` / `vary` / `dirty_frontier`). For each representative parameter
# variation it asserts BOTH halves of the incremental contract — a node-skip
# claim is only valid when the SAME variation is also proven output-equivalent to
# a from-scratch `design_building`:
#
#   (a) SKIP  — the nodes the engine ACTUALLY recomputed == the expected dirty
#               frontier, and in particular a column-only variation and the
#               chosen load-ish variation NEVER recompute :slab_sizing.
#   (b) EXACT — the incremental `BuildingDesign` matches a from-scratch
#               `design_building(struc, varied_params)` at rtol=1e-8 on BOTH the
#               15 aggregate invariants AND a COMPREHENSIVE per-member signature
#               (beam sizes, column/beam capacity+interaction+axial ratios, ok
#               flags, punching stud counts, per-strip rebar; see
#               `design_signature`) — the aggregate scalars alone cannot catch a
#               per-member provenance omission (exactly how the pattern_loading P0
#               escaped gate 3).
#
# Representative variations (mapped to what THIS engine actually supports —
# `design_building` is untouched, and the engine fixes the prepared baseline so
# any PREPARE_AFFECTING_FIELDS change requires a fresh session, see scheduler.jl):
#
#   • column-only     — change beam sizing options (`:beams`), a member-slice
#                       field read by :members but NOT :slab_sizing and NOT
#                       prepare-affecting. Frontier == [:members]; :slab_sizing
#                       stays clean. (Exercised on a beam/column vault building
#                       whose :members stage genuinely sizes steel beams.)
#   • load-ish        — change foundation soil (`:foundation_options`). NOTE:
#                       live load (`:loads`) IS a PREPARE_AFFECTING_FIELD in this
#                       codebase (baseline loads are baked into the prepared Asap
#                       model), so the engine guard blocks it and it cannot be
#                       incrementally re-derived. We SUBSTITUTE the closest
#                       non-prepare, demand-side (load-ish) override — the
#                       foundation soil bearing capacity — which changes the
#                       downstream foundation demand WITHOUT invalidating slab
#                       sizing. Frontier == [:foundations]; :slab_sizing +
#                       :members stay clean. (The assertion is real, not faked:
#                       the from-scratch reference uses the SAME soil.)
#   • slab-type swap  — change `:floor` (FlatPlate → FlatSlab). `:floor` is
#                       prepare-affecting → assert the guard fires / a fresh
#                       session is required (no partial frontier).
#   • concrete str.   — change `:materials` (NWC_4000 → NWC_6000). Prepare-
#                       affecting → assert the guard fires.
#   • geometry/span   — change `:geometry_is_centerline`. Geometry interpretation
#                       is prepare-affecting → assert the guard fires (a real
#                       geometry/span change means a different `struc` entirely,
#                       so a fresh engine is required rather than a partial
#                       frontier).
#
# Usage:
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer \
#       scripts/runners/verify_design_graph_incremental.jl
#
# Exit code: 0 when all checks pass, 1 otherwise.
# =============================================================================

ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] =
    get(ENV, "SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD", "false")

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))
Pkg.instantiate()

using Asap
using StructuralSizer
using StructuralSynthesizer
using Unitful
using Printf

const SR = StructuralSizer
const SS = StructuralSynthesizer

# Shared verify helpers (INVARIANT_COLS, design_signature, same_signature) —
# single canonical copy. Included AFTER the `using` preamble above so BuildingDesign
# + the u"kgCO2e" unit (registered by Asap) resolve at include time. See the file
# header for the `_close` contract (left local to each runner).
include(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer",
                 "test", "design_graph", "_verify_shared.jl"))

# -----------------------------------------------------------------------------
# Fixtures — reuse the exact buildings the sibling gates exercise.
# -----------------------------------------------------------------------------
# Flat-plate DDM + spread foundations (matches verify_design_graph.jl /
# verify_incremental_engine.jl), so the invariant set lines up across gates.
function build_flat_plate(; soil = SR.medium_sand,
                            concrete = NWC_4000,
                            geometry_is_centerline::Bool = false)
    skel  = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name                   = "verify_design_graph_incremental",
        floor                  = FlatPlateOptions(method = DDM()),
        materials              = MaterialOptions(concrete = concrete, rebar = Rebar_60),
        max_iterations         = 5,
        skip_visualization     = true,
        geometry_is_centerline = geometry_is_centerline,
        foundation_options     = FoundationParameters(
            soil    = soil,
            options = SR.FoundationOptions(strategy = :all_spread),
        ),
    )
    return struc, params
end

# Beam/column vault building (matches verify_design_graph.jl case 2): a vault
# floor routes stage 2 to `_size_beams_columns!`, which genuinely sizes steel
# beams from `params.beams` — so a `:beams` override is a real member-only change.
# No foundations (terminal node is :members), so a members-slice change yields a
# frontier of exactly [:members].
function build_beam_column(; beams = nothing)
    skel  = gen_medium_office(30.0u"ft", 24.0u"ft", 12.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name               = "verify_design_graph_incremental_beam_column",
        floor              = SR.VaultOptions(lambda = 8.0, material = SR.NWC_4000),
        beams              = beams,
        max_iterations     = 5,
        skip_visualization = true,
    )
    return struc, params
end

# Multi-STORY flat plate → one slab PER story (`:by_floor` grouping), all on
# distinct (story-local) columns, so `slab_parallel_batches` groups every slab
# into a SINGLE batch = a single topological LEVEL holding MULTIPLE fine per-slab
# nodes. This is the multi-node-per-level fixture (3 slabs, one barrier sync). A
# global slab-affecting param dirties ALL of them at once (the achievable
# multi-node behavior; per-slab INDEPENDENT dirtying is deferred — see NOTES).
function build_multistory_flat_plate(; soil = SR.medium_sand, concrete = NWC_4000)
    skel  = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 3)   # 3 stories
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name               = "verify_design_graph_incremental_multistory",
        floor              = FlatPlateOptions(method = DDM()),
        materials          = MaterialOptions(concrete = concrete, rebar = Rebar_60),
        max_iterations     = 5,
        skip_visualization = true,
        foundation_options = FoundationParameters(
            soil    = soil,
            options = SR.FoundationOptions(strategy = :all_spread),
        ),
    )
    return struc, params
end

# LATERAL-THRUST-GOVERNED vault: a larger-span vault at the same span/rise ratio
# raises the horizontal thrust `H = w·L·λ/8` that `to_asap!` bakes as edge
# LateralThrust line-loads (VaultResult → thrust), so the steel members sized in
# `_size_beams_columns!` are driven by the vault thrust rather than gravity alone
# — making design_building's sized-vs-estimate thrust OBSERVABLE and the vault
# sync-refresh path load-bearing on the result. `:individual` grouping ⇒ one slab
# per bay (4 slabs). After Finding 1 ALL slab nodes are edgeless roots, so the
# graph places them in a SINGLE topological level with exactly ONE barrier sync
# (regardless of `slab_parallel_batches`); the byte-identity claim (per-slab
# decomposition == coarse `size_slabs!`) is what this fixture stresses end-to-end.
# No foundations, so the terminal node is :members.
function build_thrust_vault(; beams = nothing)
    skel  = gen_medium_office(40.0u"ft", 32.0u"ft", 12.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name               = "verify_design_graph_incremental_thrust_vault",
        floor              = SR.VaultOptions(lambda = 10.0, material = SR.NWC_4000),
        beams              = beams,
        max_iterations     = 5,
        skip_visualization = true,
    )
    return struc, params
end

# Simply-supported 20 ft steel beam, solved — the ISOLATED per-group
# `size_member_group!` path (the ONLY path that honors `member_group_overrides`).
# Mirrors run_phase6_catalog_smoke.jl `_build_beam_struc`. NOTE: `design_building`
# does NOT reach this path (its member stage runs batched `size_beams!` / global
# `size_columns!` MIP / flat-plate `_reconcile_columns!`), so overrides are
# exercised against `size_member_group!` directly, not via design_building.
function build_override_beam_struc()
    L_m = ustrip(u"m", 20.0u"ft")
    skel = BuildingSkeleton{Float64}()
    id1 = add_vertex!(skel, [0.0, 0.0, 0.0])
    id2 = add_vertex!(skel, [L_m, 0.0, 0.0])
    e1  = add_element!(skel, id1, id2)
    skel.groups_edges[:beams] = [e1]
    skel.groups_vertices[:support] = [id1, id2]
    rebuild_geometry_cache!(skel)

    struc = BuildingStructure(skel)
    initialize_segments!(struc)
    for seg in struc.segments
        seg.Lb = zero(seg.L)
    end
    initialize_members!(struc)
    to_asap!(struc)
    model = struc.asap_model
    model.nodes[id1].dof = [false, false, false, false, false, false]
    model.nodes[id2].dof = [true,  true,  false, true,  true,  true]
    w_si = uconvert(u"N/m", 2.8u"kip/ft")
    push!(model.loads, Asap.LineLoad(model.elements[e1], [0.0u"N/m", 0.0u"N/m", -w_si]))
    Asap.process!(model)
    Asap.solve!(model)
    return struc
end

# Prepared + synced flat-plate frame-element forces for a given `pattern_loading`.
# Mirrors the proven fixture in test/analyze/test_pattern_loading.jl (60'×60' bays,
# 50 psf live) — large spans + high L/D so checkerboard partitions produce a
# meaningful force envelope. `to_asap!`/`sync_asap!` are READ-only here (called,
# not edited) to obtain the governing member demands the pattern_loading guard
# protects. Returns the per-element force vectors (plain internal-unit scalars).
function _prepared_frame_forces(; pattern_loading::Symbol)
    skel  = gen_medium_office(60.0u"ft", 60.0u"ft", 12.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    opts  = FlatPlateOptions(material = RC_4000_60, method = DDM(),
                             cover = 0.75u"inch", bar_size = 5)
    initialize!(struc; floor_type = :flat_plate, floor_opts = opts)
    for cell in struc.cells
        cell.sdl       = uconvert(u"kN/m^2", 20.0u"psf")
        cell.live_load = uconvert(u"kN/m^2", 50.0u"psf")
    end
    for col in struc.columns
        col.c1 = 16.0u"inch"; col.c2 = 16.0u"inch"
    end
    params = DesignParameters(pattern_loading = pattern_loading)
    to_asap!(struc; params = params)
    sync_asap!(struc; params = params)
    return [collect(el.forces) for el in struc.asap_model.frame_elements]
end

# -----------------------------------------------------------------------------
# INVARIANT_COLS — the SAME 15 columns as verify_design_graph.jl (mirrored, not
# weakened), asserted over all 15 at rtol=1e-8. Now defined in the shared copy
# included above (test/design_graph/_verify_shared.jl).
# -----------------------------------------------------------------------------

# Mirror of verify_design_graph.jl:extract_invariants (same units, same
# reductions) so this gate is provenance-comparable to the exact-first Run-1 gate.
function extract_invariants(design::BuildingDesign)
    slabs = collect(values(design.slabs))
    isempty(slabs) && error("extract_invariants: design has no slabs")

    h_m    = maximum(ustrip(u"m", s.thickness) for s in slabs)
    M0_kNm = maximum(isnothing(s.M0) ? NaN : ustrip(u"kN*m", s.M0) for s in slabs)
    punch  = maximum(s.punching_max_ratio for s in slabs)
    defl   = maximum(s.deflection_ratio  for s in slabs)

    As_cs = 0.0u"inch^2"
    As_ms = 0.0u"inch^2"
    for s in slabs
        r = s.sizer_result
        isnothing(r) && continue
        hasproperty(r, :column_strip_reinf) &&
            (As_cs += sum(sr.As_provided for sr in r.column_strip_reinf; init = 0.0u"inch^2"))
        hasproperty(r, :middle_strip_reinf) &&
            (As_ms += sum(sr.As_provided for sr in r.middle_strip_reinf; init = 0.0u"inch^2"))
    end

    cols_in = [ustrip(u"inch", c.c1) for c in values(design.columns) if c.c1 > 0.0u"m"]
    col_min = isempty(cols_in) ? NaN : minimum(cols_in)
    col_max = isempty(cols_in) ? NaN : maximum(cols_in)

    ec_total = ustrip(u"kgCO2e", design.summary.embodied_carbon)
    struc    = design.structure
    area_m2  = 0.0
    for idx in keys(design.slabs)
        (idx < 1 || idx > length(struc.slabs)) && continue
        for ci in struc.slabs[idx].cell_indices
            (ci < 1 || ci > length(struc.cells)) && continue
            area_m2 += ustrip(u"m^2", struc.cells[ci].area)
        end
    end
    ec_per_area = area_m2 > 0.0 ? ec_total / area_m2 : NaN

    B_ft = L_ft = D_in = util = NaN
    for f in values(design.foundations)
        b = ustrip(u"ft",   f.width)
        l = ustrip(u"ft",   f.length)
        d = ustrip(u"inch", f.depth)
        u = max(f.bearing_ratio, f.punching_ratio, f.flexure_ratio)
        B_ft = isnan(B_ft) ? b : max(B_ft, b)
        L_ft = isnan(L_ft) ? l : max(L_ft, l)
        D_in = isnan(D_in) ? d : max(D_in, d)
        util = isnan(util) ? u : max(util, u)
    end

    return (
        h_m = h_m, M0_kNm = M0_kNm,
        punch_ratio = punch, defl_ratio = defl,
        As_cs_in2 = ustrip(u"inch^2", As_cs),
        As_ms_in2 = ustrip(u"inch^2", As_ms),
        As_total_in2 = ustrip(u"inch^2", As_cs + As_ms),
        col_min_in = col_min, col_max_in = col_max,
        ec_total_kgco2e = ec_total, ec_per_area_kgco2e_m2 = ec_per_area,
        fdn_max_B_ft = B_ft, fdn_max_L_ft = L_ft,
        fdn_max_D_in = D_in, fdn_max_util = util,
    )
end

# NaN-aware closeness (two NaNs equal); identical to the sibling gates' `_close`.
function _close(a, b; rtol::Float64 = 1e-8, atol::Float64 = 1e-10)
    if a isa AbstractFloat && b isa AbstractFloat
        (isnan(a) && isnan(b)) && return true
        return isapprox(a, b; rtol = rtol, atol = atol)
    end
    return isequal(a, b)
end

"Return (ok, first_mismatch_col) comparing all 15 invariants at rtol=1e-8."
function same_invariants(a, b)
    for col in INVARIANT_COLS
        _close(getproperty(a, col), getproperty(b, col)) || return (false, col)
    end
    return (true, :none)
end

# -----------------------------------------------------------------------------
# design_signature / same_signature — the comprehensive per-member output
# signature and its comparator — now live in the shared canonical copy included
# above (test/design_graph/_verify_shared.jl). `same_signature` late-binds this
# file's local `_close` (defined above).
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Fine per-slab topology helpers.
# -----------------------------------------------------------------------------
# `:slab_sizing` is decomposed into one `:slab_sizing_s{idx}` node per slab
# (`slab_node_key`). Enumerate the ACTUAL slab-node keys from a session's graph
# in topological order so recompute/restore/frontier assertions are independent
# of the slab count and never hard-code the (now-nonexistent for slabbed
# buildings) coarse `NODE_SLAB_SIZING` key.
slab_keys(g)  = NodeKey[k for k in SS.topological_order(g) if SS.is_slab_node_key(k)]
slab_set(g)   = Set(slab_keys(g))
graph_of(session) = session.engine.graph
# The number of topological LEVELS that contain a slab node == the number of
# slab-stage barrier `sync_asap!` flushes. After Finding 1 every slab node is an
# edgeless ROOT, so ALL slab nodes fall in ONE level ⇒ this is exactly 1 for every
# slabbed building (one barrier sync per completed slab level, and there is only
# one such level regardless of `slab_parallel_batches`).
function slab_sync_count(g)
    count(lvl -> any(SS.is_slab_node_key, lvl), SS.topological_levels(g))
end

# -----------------------------------------------------------------------------
# Coarse independent oracle (for the exact-first DECOMPOSITION proof).
# -----------------------------------------------------------------------------
# Runs the PRE-GRAPH stage loop DIRECTLY — `build_pipeline`'s coarse stage 1 is
# `size_slabs!(struc)` over ALL slabs at once (NOT `build_design_graph`'s per-slab
# nodes) — so it is an independent oracle for the fine per-slab decomposition.
# Mirrors verify_design_graph.jl:run_reference_path exactly (prepare → coarse
# stage loop → harmonize → capture → restore), minus visualization. Comparing
# `design_building` (which now executes the FINE per-slab graph) against this
# proves the per-slab-node path reproduces the monolithic `size_slabs!` result.
function run_coarse_reference(struc::BuildingStructure, params::DesignParameters)
    t_start = time()
    prepare!(struc, params)
    for stage in build_pipeline(params)
        stage.fn(struc)
        stage.needs_sync && sync_asap!(struc; params = params)
    end
    if params.uniform_column_sizing !== :off
        n_harmonized = SS.harmonize_uniform_column_sizes!(struc, params)
        n_harmonized > 0 && sync_asap!(struc; params = params)
    end
    design = capture_design(struc, params; t_start = t_start)
    restore!(struc; geometry_is_centerline = params.geometry_is_centerline)
    return design
end

# -----------------------------------------------------------------------------
const CHECKS = Tuple{String, Bool}[]
record!(name, ok) = (push!(CHECKS, (name, ok)); @printf("  %s  %s\n", ok ? "✓" : "✗", name))

# -----------------------------------------------------------------------------
function main()
    println("="^70)
    println("Incremental variation verify — invalidation matrix (DesignSession)")
    println("="^70)

    # ── Base session equivalence (sanity: the session's BASE run matches
    #    design_building bit-for-bit before any variation) ────────────────────
    println("\n[0] Base DesignSession run == design_building (flat-plate)")
    struc_ref, base_params = build_flat_plate()
    ref_base = design_building(struc_ref, base_params)
    ref_base_inv = extract_invariants(ref_base)

    struc_s, base_params_s = build_flat_plate()
    session = DesignSession(struc_s, base_params_s)
    base_inv = extract_invariants(base_design(session))
    ok0, bad0 = same_invariants(ref_base_inv, base_inv)
    record!("base session design matches design_building (mismatch: $bad0)", ok0)
    ok0sig, bad0sig = same_signature(design_signature(ref_base),
                                     design_signature(base_design(session)))
    record!("base session comprehensive per-member signature matches (mismatch: $bad0sig)", ok0sig)
    # Fine topology: the single flat-plate slab is node :slab_sizing_s1, so "all
    # sizing nodes" = every per-slab node ∪ {:members, :foundations}.
    record!("base run recomputes all sizing nodes",
            Set(last_recomputed(session)) ==
                (slab_set(graph_of(session)) ∪ Set([NODE_MEMBERS, NODE_FOUNDATIONS])))

    # ── VARIATION 1: column-only (`:beams`) on a beam/column vault building ───
    # `:beams` is read by :members (not :slab_sizing) and is NOT prepare-
    # affecting, so it must dirty ONLY :members and leave :slab_sizing clean.
    println("\n[1] column-only (:beams) → only :members recomputes, slab clean")
    struc_bc, base_bc = build_beam_column()                       # base: beams = nothing
    session_bc = DesignSession(struc_bc, base_bc)
    # Tighter LL deflection limit (1/480 vs default 1/360) — a genuine member-
    # slice change the vault's steel-beam sizing reads.
    beams_variant = SR.SteelBeamOptions(deflection_limit = 1/480)

    frontier_col = dirty_frontier(session_bc; beams = beams_variant)
    record!("column-only frontier == [:members] (got $frontier_col)",
            frontier_col == [NODE_MEMBERS])
    record!("column-only preview: not prepare-affecting",
            !requires_new_engine(session_bc; beams = beams_variant))

    inc_col = redesign(session_bc; beams = beams_variant)
    rc_col = last_recomputed(session_bc)
    rs_col = last_restored(session_bc)
    record!("column-only recomputed == [:members] (got $rc_col)", rc_col == [NODE_MEMBERS])
    record!("column-only did NOT recompute any slab node", !any(SS.is_slab_node_key, rc_col))
    # No foundations on the vault, so the restored set is EXACTLY the slab nodes.
    record!("column-only restored all slab nodes (got $rs_col)",
            Set(rs_col) == slab_set(graph_of(session_bc)))

    # Output-equivalent (rtol=1e-8) to a from-scratch design_building with the SAME override.
    struc_bc_ref, _ = build_beam_column(beams = beams_variant)
    ref_col = design_building(struc_bc_ref,
        SS.with(base_bc; beams = beams_variant))
    ok_col, bad_col = same_invariants(extract_invariants(ref_col), extract_invariants(inc_col))
    record!("column-only incremental == from-scratch (mismatch: $bad_col)", ok_col)
    ok_colsig, bad_colsig = same_signature(design_signature(ref_col), design_signature(inc_col))
    record!("column-only comprehensive per-member signature matches (mismatch: $bad_colsig)", ok_colsig)

    # ── VARIATION 2: load-ish (`:foundation_options` soil) on flat-plate ──────
    # Substitute for live load (which is prepare-affecting): the foundation soil
    # bearing capacity is a downstream, demand-side (load-ish) parameter read
    # ONLY by :foundations. It must dirty ONLY :foundations and leave both
    # :slab_sizing and :members clean.
    println("\n[2] load-ish (:foundation_options soil) → only :foundations, slab+members clean")
    soil_variant = FoundationParameters(
        soil    = SR.soft_clay,
        options = SR.FoundationOptions(strategy = :all_spread))

    frontier_load = dirty_frontier(session; foundation_options = soil_variant)
    record!("load-ish frontier == [:foundations] (got $frontier_load)",
            frontier_load == [NODE_FOUNDATIONS])
    record!("load-ish preview: not prepare-affecting",
            !requires_new_engine(session; foundation_options = soil_variant))

    inc_load = redesign(session; foundation_options = soil_variant)
    rc_load = last_recomputed(session)
    rs_load = last_restored(session)
    record!("load-ish recomputed == [:foundations] (got $rc_load)", rc_load == [NODE_FOUNDATIONS])
    record!("load-ish did NOT recompute any slab node", !any(SS.is_slab_node_key, rc_load))
    record!("load-ish did NOT recompute :members", !(NODE_MEMBERS in rc_load))
    record!("load-ish restored all slab nodes + :members (got $rs_load)",
            Set(rs_load) == (slab_set(graph_of(session)) ∪ Set([NODE_MEMBERS])))

    # Output-equivalent (rtol=1e-8) to a from-scratch design_building with the SAME soil.
    struc_load_ref, _ = build_flat_plate(soil = SR.soft_clay)
    ref_load = design_building(struc_load_ref,
        SS.with(base_params; foundation_options = soil_variant))
    ok_load, bad_load = same_invariants(extract_invariants(ref_load), extract_invariants(inc_load))
    record!("load-ish incremental == from-scratch (mismatch: $bad_load)", ok_load)
    ok_loadsig, bad_loadsig = same_signature(design_signature(ref_load), design_signature(inc_load))
    record!("load-ish comprehensive per-member signature matches (mismatch: $bad_loadsig)", ok_loadsig)

    # Slab/column invariants must be UNCHANGED vs base (only soil changed).
    inc_load_inv = extract_invariants(inc_load)
    record!("load-ish leaves slab/column invariants unchanged vs base",
            _close(inc_load_inv.h_m, base_inv.h_m) &&
            _close(inc_load_inv.col_max_in, base_inv.col_max_in) &&
            _close(inc_load_inv.punch_ratio, base_inv.punch_ratio) &&
            _close(inc_load_inv.As_total_in2, base_inv.As_total_in2))

    # ── VARIATION 3: slab-type swap (`:floor`) — PREPARE-AFFECTING guard ──────
    println("\n[3] slab-type swap (:floor FlatPlate→FlatSlab) → guard requires fresh session")
    floor_variant = FlatSlabOptions()
    record!("slab-type swap flagged prepare-affecting",
            requires_new_engine(session; floor = floor_variant))
    record!("slab-type swap frontier reaches whole chain (structural upper bound)",
            Set(dirty_frontier(session; floor = floor_variant)) ==
                (slab_set(graph_of(session)) ∪ Set([NODE_MEMBERS, NODE_FOUNDATIONS])))
    guarded_floor = false
    try
        redesign(session; floor = floor_variant)
    catch e
        guarded_floor = e isa ArgumentError
    end
    record!("slab-type swap redesign throws ArgumentError (guard)", guarded_floor)

    # ── VARIATION 4: concrete strength (`:materials`) — PREPARE-AFFECTING ─────
    println("\n[4] concrete strength (:materials NWC_4000→NWC_6000) → guard fires")
    mat_variant = MaterialOptions(concrete = NWC_6000, rebar = Rebar_60)
    record!("concrete-strength flagged prepare-affecting",
            requires_new_engine(session; materials = mat_variant))
    guarded_mat = false
    try
        redesign(session; materials = mat_variant)
    catch e
        guarded_mat = e isa ArgumentError
    end
    record!("concrete-strength redesign throws ArgumentError (guard)", guarded_mat)

    # ── VARIATION 5: geometry (`:geometry_is_centerline`) — PREPARE-AFFECTING ─
    println("\n[5] geometry (:geometry_is_centerline) → guard fires (fresh engine)")
    record!("geometry change flagged prepare-affecting",
            requires_new_engine(session; geometry_is_centerline = true))
    guarded_geo = false
    try
        redesign(session; geometry_is_centerline = true)
    catch e
        guarded_geo = e isa ArgumentError
    end
    record!("geometry redesign throws ArgumentError (guard)", guarded_geo)

    # A fresh session at the varied geometry designs cleanly (the documented
    # remedy: rebuild the session rather than incrementally re-derive geometry).
    struc_geo, params_geo = build_flat_plate(geometry_is_centerline = true)
    session_geo = DesignSession(struc_geo, params_geo)
    record!("fresh session at new geometry produces a valid design",
            !isempty(base_design(session_geo).slabs))

    # ── VARIATION 6: pattern_loading (:none → :checkerboard) — PREPARE-AFFECTING ─
    # pattern_loading selects WHICH load objects `to_asap!` builds (split
    # dead/live for patterns vs a combined tributary load for :none); `sync_asap!`
    # gates its multi-case pattern solve on those split vectors being non-empty, so
    # over a :none baseline it can NEVER upgrade to a patterned solve — it would
    # silently emit an UNPATTERNED, unconservative design. It is therefore a
    # BUILD-TIME structural decision and must be prepare-affecting: the guard fires.
    println("\n[6] pattern_loading (:none→:checkerboard) → guard fires (fresh engine)")
    record!("pattern_loading change flagged prepare-affecting",
            requires_new_engine(session; pattern_loading = :checkerboard))
    # It lives in PREPARE_AFFECTING_FIELDS, not a node param slice, so the
    # slice-based frontier is empty — the guard (not the frontier) is the backstop.
    record!("pattern_loading not in any node param slice (empty frontier)",
            isempty(dirty_frontier(session; pattern_loading = :checkerboard)))
    guarded_pat = false
    try
        redesign(session; pattern_loading = :checkerboard)
    catch e
        guarded_pat = e isa ArgumentError
    end
    record!("pattern_loading redesign throws ArgumentError (guard)", guarded_pat)

    # Prove the guard protects a REAL difference (not masking a no-op). Discrete
    # member sizing can round out a small demand change, so we prove it at the
    # level the P0 actually endangers — the GOVERNING MEMBER MOMENT. Patterned
    # (checkerboard) live load envelopes member forces strictly UPWARD versus the
    # :none baseline (classic continuous-member result; ACI 318-11 §13.7.6): the
    # max positive span moment occurs under alternate-span loading, not all-spans.
    # So an engine that silently skipped patterning over a :none baseline would
    # UNDER-predict these demands — exactly the unconservative outcome the guard
    # prevents. (The vault routes slab pressure through thrust line-loads, so
    # patterns don't apply there — hence a flat plate here, matching the proven
    # fixture in test/analyze/test_pattern_loading.jl.)
    forces_none = _prepared_frame_forces(pattern_loading = :none)
    forces_pat  = _prepared_frame_forces(pattern_loading = :checkerboard)
    upward = true            # every DOF enveloped ≥ baseline (within numerical tol)
    n_strict = 0             # DOFs where patterning is STRICTLY higher (real change)
    gov_none = 0.0; gov_pat = 0.0
    for (fn, fp) in zip(forces_none, forces_pat)
        for k in eachindex(fn)
            a = abs(fn[k]); b = abs(fp[k])
            gov_none = max(gov_none, a); gov_pat = max(gov_pat, b)
            b >= a - 1e-6 || (upward = false)
            b > a + 1e-3 && (n_strict += 1)
        end
    end
    record!("checkerboard envelopes member moments strictly upward vs :none " *
            "(upward=$upward, strict DOFs=$n_strict, gov $(round(gov_pat, digits=1)) ≥ $(round(gov_none, digits=1)))",
            upward && n_strict > 0 && gov_pat >= gov_none - 1e-6)

    # ── VARIATION 7: load_combinations on a VAULT (structural-effects) ────────
    # `:load_combinations` is NON-prepare-affecting: `sync_asap!` refreshes every
    # load MAGNITUDE it drives, INCLUDING the vault-thrust edge line loads
    # `to_asap!` bakes from `governing_combo(params)` (VaultResult → LateralThrust).
    # A vault emits structural_effects, so this is the case that guards the P1: a
    # base `[strength_1_4D]` (D=1.4, L=0) → varied `[strength_1_2D_1_6L]` (D=1.2,
    # L=1.6) changes `first()`/`governing_combo`, hence the baked thrust. Assert
    # (a) the frontier/recompute set is exactly [:slab_sizing, :members] and the
    # change is non-prepare, and (b) the incremental redesign is OUTPUT-EQUIVALENT
    # (rtol=1e-8) to a from-scratch design_building at the new combos. Without the
    # sync-path refresh the incremental thrust would stay frozen at 1.4D and this
    # equivalence check would FAIL — exactly the reverted-fix regression.
    println("\n[7] load_combinations on VAULT → [:slab_sizing,:members] recompute, output-equivalent")
    struc_lc, base_lc0 = build_beam_column()
    base_lc = SS.with(base_lc0; load_combinations = [SR.strength_1_4D])
    session_lc = DesignSession(struc_lc, base_lc)
    lc_variant = [SR.strength_1_2D_1_6L]

    record!("load_combinations (vault) not prepare-affecting",
            !requires_new_engine(session_lc; load_combinations = lc_variant))
    frontier_lc = dirty_frontier(session_lc; load_combinations = lc_variant)
    # Fine topology: the frontier is every per-slab node (topological order) then
    # :members — both read the load MAGNITUDE that sync refreshes.
    expected_lc_frontier = vcat(slab_keys(graph_of(session_lc)), [NODE_MEMBERS])
    record!("load_combinations (vault) frontier == [slab nodes…,:members] (got $frontier_lc)",
            frontier_lc == expected_lc_frontier)

    inc_lc = redesign(session_lc; load_combinations = lc_variant)
    rc_lc = last_recomputed(session_lc)
    record!("load_combinations (vault) recomputed == [slab nodes…,:members] (got $rc_lc)",
            Set(rc_lc) == (slab_set(graph_of(session_lc)) ∪ Set([NODE_MEMBERS])))

    struc_lc_ref, base_lc_ref0 = build_beam_column()
    ref_lc = design_building(struc_lc_ref, SS.with(base_lc_ref0; load_combinations = lc_variant))
    ok_lc, bad_lc = same_invariants(extract_invariants(ref_lc), extract_invariants(inc_lc))
    record!("load_combinations (vault) incremental == from-scratch (mismatch: $bad_lc)", ok_lc)
    ok_lcsig, bad_lcsig = same_signature(design_signature(ref_lc), design_signature(inc_lc))
    record!("load_combinations (vault) comprehensive per-member signature matches (mismatch: $bad_lcsig)", ok_lcsig)

    # Guard is only meaningful if the two combos differ at the design level; prove
    # the varied-combo from-scratch design is NOT identical to the base-combo one
    # (otherwise a frozen-thrust bug could hide behind a coincidental no-op).
    struc_lc_base_ref, base_lc_base_ref0 = build_beam_column()
    ref_lc_base = design_building(struc_lc_base_ref, SS.with(base_lc_base_ref0; load_combinations = [SR.strength_1_4D]))
    diff_ok, _ = same_signature(design_signature(ref_lc_base), design_signature(ref_lc))
    record!("load_combinations variation is a REAL change (base vs varied differ)", !diff_ok)

    # ── [8] EXACT-FIRST DECOMPOSITION: fine per-slab nodes == coarse size_slabs! ─
    # `design_building` now executes the FINE per-slab graph; `run_coarse_reference`
    # runs the monolithic `size_slabs!` stage loop. Equal comprehensive signatures
    # ⇒ decomposing slab sizing into per-slab nodes reproduces the coarse result
    # byte-for-byte (rtol=1e-8) — on BOTH a 3-story flat plate (3 slabs) and a vault
    # (4 slabs). After Finding 1 every slab node is a root, so each building has
    # exactly ONE slab level and ONE barrier sync; the decomposition proof does not
    # depend on `slab_parallel_batches` shaping the graph into multiple levels.
    println("\n[8] exact-first DECOMPOSITION: fine per-slab graph == coarse size_slabs!")
    struc_ms_fine, ms_params = build_multistory_flat_plate()
    fine_ms = design_building(struc_ms_fine, ms_params)
    struc_ms_coarse, _ = build_multistory_flat_plate()
    coarse_ms = run_coarse_reference(struc_ms_coarse, ms_params)
    record!("multi-story flat plate has ≥2 slabs (multi-node level meaningful)",
            length(fine_ms.slabs) >= 2)
    ok_ms, bad_ms = same_signature(design_signature(coarse_ms), design_signature(fine_ms))
    record!("3-slab flat plate: fine per-slab graph == coarse size_slabs! (mismatch: $bad_ms)", ok_ms)

    struc_v_fine, v_params = build_thrust_vault()
    fine_v = design_building(struc_v_fine, v_params)
    struc_v_coarse, _ = build_thrust_vault()
    coarse_v = run_coarse_reference(struc_v_coarse, v_params)
    record!("thrust vault has ≥2 slabs (per-slab decomposition meaningful)",
            length(fine_v.slabs) >= 2)
    ok_v, bad_v = same_signature(design_signature(coarse_v), design_signature(fine_v))
    record!("thrust vault: fine per-slab graph == coarse size_slabs! (mismatch: $bad_v)", ok_v)

    # ── [9] MULTI-NODE-LEVEL: global slab-param dirties ALL slab nodes, one sync ──
    # 3-story flat plate → all 3 per-slab nodes are roots ⇒ ONE topological level
    # (independent of `slab_parallel_batches`). A global slab-affecting param (`:load_combinations`,
    # non-prepare) dirties EVERY slab node; the scheduler recomputes them all in
    # that one level and flushes the level-barrier `sync_asap!` EXACTLY ONCE, then
    # the result is output-equivalent to a from-scratch design_building at the new
    # combos. (This is the ACHIEVABLE multi-node behavior — a global param moves all
    # siblings together; dirtying exactly ONE sibling is DEFERRED, see NOTES below.)
    println("\n[9] MULTI-NODE-LEVEL: global slab-param → all slab nodes recompute, ONE barrier sync")
    struc_ml, base_ml = build_multistory_flat_plate()
    session_ml = DesignSession(struc_ml, base_ml)
    g_ml = graph_of(session_ml)
    slabs_ml = slab_set(g_ml)
    record!("multi-story flat plate → all slab nodes in ONE level (got $(slab_sync_count(g_ml)))",
            length(slabs_ml) >= 2 && slab_sync_count(g_ml) == 1)

    ml_variant = [SR.strength_1_2D_1_6L]
    base_ml_combo = SS.with(base_ml; load_combinations = [SR.strength_1_4D])
    # Rebuild the session pinned to a definite base combo so the variant is a real change.
    struc_ml2, _ = build_multistory_flat_plate()
    session_ml = DesignSession(struc_ml2, base_ml_combo)
    g_ml = graph_of(session_ml)
    slabs_ml = slab_set(g_ml)
    record!("multi-node-level not prepare-affecting",
            !requires_new_engine(session_ml; load_combinations = ml_variant))
    inc_ml = redesign(session_ml; load_combinations = ml_variant)
    rc_ml  = last_recomputed(session_ml)
    record!("multi-node-level recomputed ALL slab nodes (got $rc_ml)",
            slabs_ml ⊆ Set(rc_ml))
    # From-scratch reference at the SAME varied combos.
    struc_ml_ref, _ = build_multistory_flat_plate()
    ref_ml = design_building(struc_ml_ref, SS.with(base_ml_combo; load_combinations = ml_variant))
    ok_ml, bad_ml2 = same_invariants(extract_invariants(ref_ml), extract_invariants(inc_ml))
    record!("multi-node-level incremental == from-scratch (mismatch: $bad_ml2)", ok_ml)
    ok_mlsig, bad_mlsig = same_signature(design_signature(ref_ml), design_signature(inc_ml))
    record!("multi-node-level comprehensive per-member signature matches (mismatch: $bad_mlsig)", ok_mlsig)

    # ── [10] THRUST-GOVERNED VAULT: incremental/graph path == from-scratch ───────
    # A larger-span vault whose baked LateralThrust edge loads drive the steel
    # members. Assert the full incremental engine run (fine graph + level barriers)
    # reproduces from-scratch design_building, AND that a `:load_combinations`
    # variation (which changes the governing combo → the baked thrust) stays
    # output-equivalent — i.e. the vault thrust is correctly REFRESHED on the
    # incremental sync path, not frozen at the base combo.
    println("\n[10] THRUST-GOVERNED VAULT: incremental == from-scratch (base + thrust-combo variation)")
    struc_tv, base_tv0 = build_thrust_vault()
    base_tv = SS.with(base_tv0; load_combinations = [SR.strength_1_4D])
    session_tv = DesignSession(struc_tv, base_tv)
    # Base session run == design_building on the thrust vault.
    struc_tv_ref, _ = build_thrust_vault()
    ref_tv_base = design_building(struc_tv_ref, base_tv)
    ok_tvb, bad_tvb = same_signature(design_signature(ref_tv_base),
                                     design_signature(base_design(session_tv)))
    record!("thrust vault base session == design_building (mismatch: $bad_tvb)", ok_tvb)

    tv_variant = [SR.strength_1_2D_1_6L]
    inc_tv = redesign(session_tv; load_combinations = tv_variant)
    rc_tv  = last_recomputed(session_tv)
    record!("thrust vault variation recomputes all slab nodes + :members (got $rc_tv)",
            Set(rc_tv) == (slab_set(graph_of(session_tv)) ∪ Set([NODE_MEMBERS])))
    struc_tv_ref2, base_tv_ref20 = build_thrust_vault()
    ref_tv = design_building(struc_tv_ref2, SS.with(base_tv_ref20; load_combinations = tv_variant))
    ok_tv, bad_tv2 = same_signature(design_signature(ref_tv), design_signature(inc_tv))
    record!("thrust vault variation incremental == from-scratch (mismatch: $bad_tv2)", ok_tv)
    # Prove the thrust-combo variation is a REAL change (not a coincidental no-op).
    diff_tv, _ = same_signature(design_signature(ref_tv_base), design_signature(ref_tv))
    record!("thrust vault load_combinations is a REAL change (base vs varied differ)", !diff_tv)

    # ── DEFERRAL NOTE (documented invariant of this gate) ───────────────────────
    # True per-slab / per-beam-group INDEPENDENT variation — a change that dirties
    # EXACTLY ONE sibling node while leaving the others clean — is NOT achievable
    # under the current GLOBAL-parameter model: a slab-affecting field
    # (:load_combinations, :floor, :materials, …) is read identically by every
    # per-slab node, so it dirties them ALL at once (section [9]), and a non-slab
    # field dirties NONE. Producing a mixed clean/dirty slab level requires per-group
    # OVERRIDE parameters (Option A: e.g. per-slab load or thickness overrides),
    # which introduces new safety-critical DesignParameters fields + a
    # prepare-affecting classification and is DEFERRED to a follow-up run pending
    # user sign-off (per code-accuracy.mdc — do not guess new mechanics). The
    # partial-restore path (`restore_slab_node_writes!` / `_adopt_larger_column!`)
    # that a mixed level would exercise is therefore UNREACHABLE end-to-end, now
    # ENFORCED (not merely assumed) by the partial-slab-target guard in
    # `run_target!` (section [11] below exercises the guard directly). It is covered
    # by DIRECT unit tests otherwise (StructuralSynthesizer/test/design_graph/
    # test_design_graph_incremental.jl, "partial per-slab restore (Findings 3 + 4)");
    # it is deliberately NOT faked here with a prepare-affecting change.

    # ── [11] EXACT-FIRST GUARD: a partial-slab target is REJECTED (critic P1) ─────
    # Fine per-slab nodes are edgeless ROOTS, so `run_target!(engine, params;
    # target = slab_node_key(k))` would memoize ONLY node k — and a later run to the
    # terminal would then classify a MIXED clean/dirty slab level and take the
    # divergent partial-restore overlay (node k having been sized in the WRONG
    # monotonic column-growth context vs from-scratch). The guard makes that memo
    # state unrepresentable: any target whose closure covers a STRICT SUBSET of the
    # slab roots is rejected. We assert the clean rejection AND that a legitimate
    # FULL run still reproduces from-scratch design_building. Pre-fix this DIVERGED
    # silently; post-fix it cannot be expressed. `DesignSession(target=…)` /
    # `redesign(…, target=…)` route their target through the same guard.
    println("\n[11] EXACT-FIRST GUARD: partial-slab target rejected, full run still exact")
    struc_g1, params_g1 = build_multistory_flat_plate()
    engine_g = prepare_engine(struc_g1, params_g1)   # prepare! populates slabs + graph
    roots_g = slab_set(engine_g.graph)
    record!("guard fixture has ≥3 slab roots sharing columns (got $(length(roots_g)))",
            length(roots_g) >= 3)
    rejected_single = false
    try
        run_target!(engine_g, params_g1; target = SS.slab_node_key(2))
    catch err
        rejected_single = err isa ArgumentError
    end
    record!("bare single-slab target :$(SS.slab_node_key(2)) rejected (ArgumentError)", rejected_single)
    # The throw leaves the engine usable (guard fires before any mutation): a full
    # run recomputes every slab root and matches from-scratch byte-for-byte.
    inc_g = redesign_incremental!(engine_g, params_g1)
    record!("full run after rejection recomputes ALL slab roots (got $(last_recomputed(engine_g)))",
            roots_g ⊆ Set(last_recomputed(engine_g)))
    struc_g_ref, _ = build_multistory_flat_plate()
    ref_g = design_building(struc_g_ref, params_g1)
    ok_g, bad_g = same_signature(design_signature(ref_g), design_signature(inc_g))
    record!("full run incremental == from-scratch (mismatch: $bad_g)", ok_g)
    # A :members target depends on ALL slab roots → legitimate full coverage, NOT rejected.
    struc_g2, params_g2 = build_multistory_flat_plate()
    engine_g2 = prepare_engine(struc_g2, params_g2)
    members_ok = false
    try
        run_target!(engine_g2, params_g2; target = NODE_MEMBERS)
        members_ok = true
    catch
        members_ok = false
    end
    record!(":members target (covers all slab roots) is accepted", members_ok)

    # ── [12] RUN 4 / PHASE B: member_group_overrides ─────────────────────────
    # SCOPE: Phase B makes `member_group_overrides` LIVE for the HONORABLE case —
    # an EFFECTIVE override on a STEEL BEAM member group on a beam/column floor,
    # sized via the batched `size_beams!` → `optimize_discrete` path (see
    # `_size_beams_impl!` / `_beam_override_union_and_feasible`). The override
    # narrows only that group's feasible set and DOES change its result ([12b]).
    # UN-HONORABLE effective targets are still refused fail-loud (ArgumentError,
    # message-pinned on 'member_group_overrides'): flat-plate/flat-slab floors,
    # non-steel-beam sizing, `n_max_sections > 0`, and column/strut groups. The
    # blocks below prove: the isolated `size_member_group!` mechanism, the
    # byte-identical happy path (empty / vacuous), and the fail-loud guard on the
    # un-honorable targets (all exercised here on a flat-plate fixture, which is an
    # un-honorable FLOOR — so every effective override on it must throw).
    println("\n[12] Run 4 Part 1: member_group_overrides on size_member_group! (non-vacuous)")
    custom2 = [SR.W("W21X44"), SR.W("W24X68")]
    custom_names = Set(s.name for s in custom2)

    # default empty + resolve lookup
    record!("DesignParameters default member_group_overrides empty",
            isempty(DesignParameters().member_group_overrides))
    ovr_probe = MemberGroupSizingOverride(catalog = custom2)
    params_probe = DesignParameters(
        member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(UInt64(7) => ovr_probe))
    record!("resolve_member_group_override: present gid → entry, absent → nothing",
            resolve_member_group_override(params_probe, UInt64(7)) === ovr_probe &&
            resolve_member_group_override(params_probe, UInt64(999)) === nothing)

    # non-vacuous: override picks a DIFFERENT section than no override
    struc_ov0 = build_override_beam_struc()
    build_member_groups!(struc_ov0; member_type = :beams)
    gid_ov0 = first(keys(struc_ov0.member_groups))
    size_member_group!(struc_ov0, gid_ov0; member_edge_group = :beams,
                       material = A992_Steel, reanalyze = true)
    free_name = struc_ov0.member_groups[gid_ov0].section.name

    struc_ov1 = build_override_beam_struc()
    build_member_groups!(struc_ov1; member_type = :beams)
    gid_ov1 = first(keys(struc_ov1.member_groups))
    params_ov = DesignParameters(
        member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
            gid_ov1 => MemberGroupSizingOverride(catalog = custom2)))
    size_member_group!(struc_ov1, gid_ov1; member_edge_group = :beams,
                       material = A992_Steel, reanalyze = true,
                       override = resolve_member_group_override(params_ov, gid_ov1))
    ov_name = struc_ov1.member_groups[gid_ov1].section.name
    record!("override changes sized section (got free=$free_name, override=$ov_name)",
            free_name ∉ custom_names && ov_name ∈ custom_names && ov_name != free_name)

    # precedence: override > MemberGroup.catalog_override > global default.
    # BOTH candidate sections must be FEASIBLE for this fixture so the test isolates
    # PRECEDENCE, not catalog adequacy. The 20 ft fixed-pinned beam's governing
    # moment is the HOGGING moment at the fixed end, and the hogging Chapter-F LTB
    # check (ϕMn_neg ≥ Mux_neg at Lb=L, Cb=1.0 — checker.jl `_hogging_ltb_inputs`)
    # rejects deep, LTB-weak shapes such as W21X44 (ϕMn_neg ≈ 103 kip·ft < 140).
    # W24X68 (0.39) and W24X103 (0.20) both pass; the override-supplied W24X68 must
    # win over the lower-precedence MemberGroup.catalog_override.
    struc_pr = build_override_beam_struc()
    build_member_groups!(struc_pr; member_type = :beams)
    gid_pr = first(keys(struc_pr.member_groups))
    struc_pr.member_groups[gid_pr].catalog_override = [SR.W("W24X103")]  # loses to the override
    size_member_group!(struc_pr, gid_pr; member_edge_group = :beams,
                       material = A992_Steel, reanalyze = true,
                       override = MemberGroupSizingOverride(catalog = [SR.W("W24X68")]))
    record!("precedence: override beats MemberGroup.catalog_override",
            struc_pr.member_groups[gid_pr].section.name == "W24X68")

    # (a) EMPTY (default): design_building runs; an explicit-empty dict is
    #     byte-identical to the plain default (the field/guard changed nothing on
    #     the happy path).
    struc_e0, base_e0 = build_flat_plate()
    des_default = design_building(struc_e0, base_e0)
    struc_e1, base_e1 = build_flat_plate()
    base_e1.member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}()  # explicit empty
    des_empty = design_building(struc_e1, base_e1)
    ok_np, bad_np = same_signature(design_signature(des_default), design_signature(des_empty))
    record!("design_building: explicit-empty member_group_overrides byte-identical to default (mismatch: $bad_np)", ok_np)

    # Message-pinned guard check (P2b): the ArgumentError must be the
    # member_group_overrides guard, not any unrelated ArgumentError.
    guard_threw(f) = try
        f(); false
    catch err
        err isa ArgumentError && occursin("member_group_overrides", sprint(showerror, err))
    end

    # (a2) POPULATED-but-VACUOUS (P2a): a dict whose only entry is all-unset is a
    #      DOCUMENTED no-op (MemberGroupSizingOverride docstring). It must NOT throw
    #      and design_building must be BYTE-IDENTICAL to the default (guard/docstring
    #      consistency — only EFFECTIVE overrides are refused).
    struc_vac, base_vac = build_flat_plate()
    base_vac.member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
        UInt64(1) => MemberGroupSizingOverride())  # all fields nothing
    des_vac = design_building(struc_vac, base_vac)  # must NOT throw
    ok_vac, bad_vac = same_signature(design_signature(des_default), design_signature(des_vac))
    record!("design_building: all-unset member_group_overrides is a no-op, byte-identical (mismatch: $bad_vac)",
            !SS._is_effective(base_vac.member_group_overrides[UInt64(1)]) && ok_vac)

    # (b) NON-EMPTY EFFECTIVE (real gid, real override): design_building REFUSES it
    #     (fail-loud ArgumentError, message-pinned) rather than silently returning a
    #     default-catalog design — the coarse pipeline cannot route the override
    #     through size_member_group!.
    struc_e2, base_e2 = build_flat_plate()
    base_e2.member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
        UInt64(1) => MemberGroupSizingOverride(catalog = [SR.W("W21X44")],
                                               deflection_limit = 1/480))
    record!("design_building throws guard ArgumentError on effective member_group_overrides",
            guard_threw(() -> design_building(struc_e2, base_e2)))

    # (b2) PATH-COMPLETE (P1): the exported design-producing VARIATION entry points
    #      (redesign / vary / redesign_incremental!) must ALSO refuse an effective
    #      override injected as a variation kwarg — the sweep door never re-enters
    #      run_pre_sizing_validation, and its graph never calls size_member_group!, so
    #      an unguarded effective override yields an empty dirty frontier + a silently
    #      UNCHANGED design. Each must throw the SAME guard (message-pinned).
    eff_ovr = Dict{UInt64, MemberGroupSizingOverride}(
        UInt64(1) => MemberGroupSizingOverride(catalog = [SR.W("W21X44")]))
    struc_rd, base_rd = build_flat_plate()
    session_rd = DesignSession(struc_rd, base_rd)  # clean base (no override)
    record!("redesign throws guard ArgumentError on effective member_group_overrides",
            guard_threw(() -> redesign(session_rd; member_group_overrides = eff_ovr)))
    record!("vary throws guard ArgumentError on effective member_group_overrides",
            guard_threw(() -> vary(session_rd, (; member_group_overrides = eff_ovr))))
    struc_ri, base_ri = build_flat_plate()
    engine_ri = prepare_engine(struc_ri, base_ri)
    variant_ri = SS.with(base_ri; member_group_overrides = eff_ovr)
    record!("redesign_incremental! throws guard ArgumentError on effective member_group_overrides",
            guard_threw(() -> redesign_incremental!(engine_ri, variant_ri)))

    # (b3) PRIMITIVE PATH 1 (Run 4, Part 1 backstop): the low-level chain
    #      build_design_graph -> execute_graph! -> capture_design bypasses
    #      run_pre_sizing_validation, but capture_design is the UNIVERSAL choke point
    #      that materializes every BuildingDesign. Prepare/build/execute on a CLEAN
    #      base, then hand an effective override to capture_design — it must throw.
    struc_g, base_g = build_flat_plate()
    prepare!(struc_g, base_g)
    graph_g = build_design_graph(struc_g, base_g)
    execute_graph!(graph_g, struc_g, base_g)
    params_g = SS.with(base_g; member_group_overrides = eff_ovr)
    record!("capture_design (primitive graph path) throws guard on effective member_group_overrides",
            guard_threw(() -> capture_design(struc_g, params_g)))

    # (b4) PRIMITIVE PATH 2: manual run_target! + capture_incremental_design routes
    #      through capture_design. Run the engine to terminal on a CLEAN base, then
    #      capture with the effective override — the choke point must throw.
    struc_t, base_t = build_flat_plate()
    engine_t = prepare_engine(struc_t, base_t)
    run_target!(engine_t, base_t)
    params_t = SS.with(base_t; member_group_overrides = eff_ovr)
    record!("capture_incremental_design (primitive run_target! path) throws guard on effective member_group_overrides",
            guard_threw(() -> capture_incremental_design(engine_t, params_t)))

    # (b5) STRUCTURAL enforcement (Run 4, Part 1 hardening): the guard now lives in
    #      the BuildingDesign(struc, params) constructor — the SINGLE universal choke
    #      point through which every BuildingDesign is materialized. A direct
    #      constructor call with an EFFECTIVE override MUST throw the same guard, so no
    #      present-or-future caller can bypass it. Empty and populated-but-vacuous
    #      (all-unset) overrides MUST construct without throwing.
    struc_x, base_x = build_flat_plate()
    record!("BuildingDesign constructor: default (empty) override constructs",
            BuildingDesign(struc_x, base_x) isa BuildingDesign)
    base_x_empty = SS.with(base_x;
        member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}())
    record!("BuildingDesign constructor: explicit-empty override constructs",
            BuildingDesign(struc_x, base_x_empty) isa BuildingDesign)
    vac_ovr = Dict{UInt64, MemberGroupSizingOverride}(
        UInt64(1) => MemberGroupSizingOverride())  # all fields nothing
    base_x_vac = SS.with(base_x; member_group_overrides = vac_ovr)
    record!("BuildingDesign constructor: vacuous (all-unset) override constructs",
            !SS._is_effective(vac_ovr[UInt64(1)]) &&
            BuildingDesign(struc_x, base_x_vac) isa BuildingDesign)
    base_x_eff = SS.with(base_x; member_group_overrides = eff_ovr)
    record!("BuildingDesign constructor throws guard on effective member_group_overrides",
            guard_threw(() -> BuildingDesign(struc_x, base_x_eff)))

    # ── [12b] PHASE B: effective steel-beam-group overrides are LIVE ──────────
    # The honorable case: a beam/column floor (:vault) with multiple steel beam
    # groups. An effective per-group catalog override narrows THAT group's feasible
    # set in the batched `size_beams!` path and changes only its result; from-scratch
    # and the incremental engine route the identical threading.
    println("\n[12b] Phase B: member_group_overrides LIVE on steel beam groups (beam/column floor)")

    # Canonical section name assigned to steel-beam group `gid`, read from the
    # CAPTURED `design_building` return (a `BuildingDesign`). It cannot be read back
    # off the designed structure: after a :vault design the individual beam members
    # drop their `.section` (it lives on the shared MemberGroup, so `section(b)` is
    # `nothing`), and `struc.member_groups` is `empty!`-rebuilt per member_type on
    # every sizing pass — after beams THEN columns it holds only the column groups.
    # `BuildingDesign.beams` is keyed by beam INDEX (position in `struc.beams`), and
    # each `BeamDesignResult.section_obj` survives capture (see report_summary.jl),
    # so map gid → beam index via `group_id` and read the section object's name.
    # (`section_size` is `string(sec)`, the full struct repr, not the W-shape name.)
    beam_secname(s, des, gid) = begin
        for (k, b) in enumerate(s.beams)
            if group_id(b) == gid
                r = get(des.beams, k, nothing)
                r === nothing && return nothing
                return r.section_obj === nothing ? nothing : r.section_obj.name
            end
        end
        nothing
    end

    # Free (no-override) design first — raw skeleton structs have no materialized
    # members, so beam member groups (and their deterministic singleton gids) only
    # exist AFTER a sizing pass. Enumerate the real steel-beam gids from the DESIGNED
    # structure's members.
    struc_free, base_free = build_beam_column()
    des_free = design_building(struc_free, base_free)
    beam_gids = sort(unique(group_id(b) for b in struc_free.beams))
    record!("beam/column (:vault) fixture exposes >= 2 steel beam groups (got $(length(beam_gids)))",
            length(beam_gids) >= 2)
    target_gid = first(beam_gids)
    free_sec = beam_secname(struc_free, des_free, target_gid)

    # Heaviest W (max area ⇒ max Zx/Ix/Aw ⇒ adequate for any office beam; default
    # max_depth = Inf), distinct from the light free optimum.
    all_w = SR.all_W()
    heavy = all_w[argmax([SR.section_area(s) for s in all_w])]

    # (i) single-section catalog override ⇒ the group is sized to EXACTLY that section.
    struc_ov, base_ov0 = build_beam_column()
    base_ov = SS.with(base_ov0; member_group_overrides =
        Dict{UInt64, MemberGroupSizingOverride}(
            target_gid => MemberGroupSizingOverride(catalog = [heavy])))
    des_ov = design_building(struc_ov, base_ov)
    forced = beam_secname(struc_ov, des_ov, target_gid)
    record!("single-section catalog override sizes target beam group to that section (got $forced, want $(heavy.name))",
            forced == heavy.name)
    record!("effective override CHANGES the design vs free (free=$free_sec, forced=$forced)",
            forced != free_sec)

    # (ii) exact-first isolation: every OTHER beam group is byte-identical to free.
    other_ok = all(g -> g == target_gid ||
                        beam_secname(struc_ov, des_ov, g) ==
                        beam_secname(struc_free, des_free, g), beam_gids)
    record!("override narrows ONLY its group; all other beam groups byte-identical", other_ok)

    # (iii) ORACLE: from-scratch WITH override == incremental engine WITH override,
    #       both routing the batched size_beams! threading (per-member signature).
    struc_inc, base_inc = build_beam_column()
    engine_inc = prepare_engine(struc_inc, base_inc)
    run_target!(engine_inc, base_inc)                          # clean base first
    variant_inc = SS.with(base_inc; member_group_overrides =
        Dict{UInt64, MemberGroupSizingOverride}(
            target_gid => MemberGroupSizingOverride(catalog = [heavy])))
    rc_inc, _ = run_target!(engine_inc, variant_inc)
    inc_ov = capture_incremental_design(engine_inc, variant_inc)
    record!("effective override marks :members dirty in the incremental engine (got $rc_inc)",
            NODE_MEMBERS in rc_inc)
    ok_ovsig, bad_ovsig = same_signature(design_signature(des_ov), design_signature(inc_ov))
    record!("from-scratch WITH override == incremental WITH override (per-member signature, mismatch: $bad_ovsig)",
            ok_ovsig)

    # (iv) UN-HONORABLE targets on the SAME beam/column floor still throw
    #      (message-pinned): a COLUMN-group override. Enumerate a real column gid
    #      from a DESIGNED structure — `build_member_groups!` on a raw skeleton
    #      yields an empty map (member groups only exist after a sizing pass), so
    #      read `group_id` off the designed columns instead.
    struc_cg, base_cg = build_beam_column()
    design_building(struc_cg, base_cg)
    col_gid = first(sort(unique(group_id(c) for c in struc_cg.columns)))
    struc_cg2, base_cg2 = build_beam_column()
    base_cg_ov = SS.with(base_cg2; member_group_overrides =
        Dict{UInt64, MemberGroupSizingOverride}(
            col_gid => MemberGroupSizingOverride(catalog = [heavy])))
    record!("column-group override on beam/column floor throws guard (message-pinned)",
            guard_threw(() -> design_building(struc_cg2, base_cg_ov)))
    #      and a beam-group override under a FLAT-PLATE floor (un-honorable floor).
    struc_fpo, base_fpo = build_flat_plate()
    base_fpo_ov = SS.with(base_fpo; member_group_overrides =
        Dict{UInt64, MemberGroupSizingOverride}(
            target_gid => MemberGroupSizingOverride(catalog = [heavy])))
    record!("beam override under flat-plate floor throws guard (message-pinned)",
            guard_threw(() -> design_building(struc_fpo, base_fpo_ov)))

    # Run 4 / Phase B: `member_group_overrides` is now a `:members` param-slice input
    # (the batched steel-beam stage honors it — see provenance.jl NODE_MEMBERS), so a
    # change DIRTIES the member frontier. It is still NOT prepare-affecting (no
    # geometry/load re-prepare), so the incremental engine is reused, not rebuilt.
    struc_fr, base_fr = build_flat_plate()
    session_fr = DesignSession(struc_fr, base_fr)
    fr_ovr = Dict{UInt64, MemberGroupSizingOverride}(
        UInt64(1) => MemberGroupSizingOverride(catalog = [SR.W("W21X44")]))
    record!("member_group_overrides change → dirties :members frontier, not prepare-affecting",
            (NODE_MEMBERS in dirty_frontier(session_fr; member_group_overrides = fr_ovr)) &&
            !requires_new_engine(session_fr; member_group_overrides = fr_ovr))

    # ── [12c] Finding A-revert: MemberGroup.catalog_override is a NO-OP in the batched path ──
    # A beam group carrying ONLY a MemberGroup.catalog_override (Phase 6 seam) and
    # EMPTY member_group_overrides must be a NO-OP in the batched size_beams! path —
    # catalog_override is honored solely by the isolated size_member_group! path
    # (never here: it was never honored pre-Phase-B, and honoring it opened a
    # regression). So the sized section is BYTE-IDENTICAL to the no-override free
    # optimum, NOT narrowed to the seam catalog.
    println("\n[12c] Finding A-revert: MemberGroup.catalog_override is a no-op in batched size_beams!")
    heavy_co = SR.all_W()[argmax([SR.section_area(s) for s in SR.all_W()])]
    struc_cofree = build_override_beam_struc()
    build_member_groups!(struc_cofree; member_type = :beams)
    size_beams!(struc_cofree, SR.SteelBeamOptions(); reanalyze = false)
    gid_cof = first(keys(struc_cofree.member_groups))
    free_co = struc_cofree.member_groups[gid_cof].section.name
    struc_co = build_override_beam_struc()
    build_member_groups!(struc_co; member_type = :beams)
    gid_co = first(keys(struc_co.member_groups))
    struc_co.member_groups[gid_co].catalog_override = [heavy_co]   # ONLY the seam
    size_beams!(struc_co, SR.SteelBeamOptions(); reanalyze = false)  # no per-design override
    co_sized = struc_co.member_groups[gid_co].section.name
    record!("MemberGroup.catalog_override is a no-op in batched size_beams!, byte-identical to free (got $co_sized, free=$free_co; seam=$(heavy_co.name))",
            co_sized == free_co && co_sized != heavy_co.name)

    # ── [12d] Finding B: LOOSER deflection_limit/max_depth override refused fail-loud ──
    # The batched path always intersects the per-group mask with the global
    # AISCChecker screening, so a per-group knob can only TIGHTEN; a LOOSER knob would
    # be a silent no-op. The struc-aware guard refuses it fail-loud; TIGHTENING honored.
    println("\n[12d] Finding B: looser deflection_limit/max_depth refused; tightening honored")
    struc_bl, base_bl = build_beam_column()
    base_bl_loose = SS.with(base_bl; member_group_overrides =
        Dict{UInt64, MemberGroupSizingOverride}(
            target_gid => MemberGroupSizingOverride(deflection_limit = 1/240)))  # looser than 1/360
    record!("looser deflection_limit override on beam group throws guard (message-pinned)",
            guard_threw(() -> design_building(struc_bl, base_bl_loose)))
    struc_bd, base_bd0 = build_beam_column()
    base_bd = SS.with(base_bd0; beams = SR.SteelBeamOptions(max_depth = 12.0u"inch"),
        member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
            target_gid => MemberGroupSizingOverride(max_depth = 24.0u"inch")))  # looser than 12"
    record!("looser max_depth override on beam group throws guard (message-pinned)",
            guard_threw(() -> design_building(struc_bd, base_bd)))
    struc_bt, base_bt = build_beam_column()
    base_bt_tight = SS.with(base_bt; member_group_overrides =
        Dict{UInt64, MemberGroupSizingOverride}(
            target_gid => MemberGroupSizingOverride(deflection_limit = 1/480)))  # tighter than 1/360
    tight_ok = try
        design_building(struc_bt, base_bt_tight) isa BuildingDesign
    catch
        false
    end
    record!("tightening deflection_limit override is honored (design succeeds)", tight_ok)

    # ── [12e] Finding C: SZ-layer guard — feasible!==nothing requires n_max_sections==0 ──
    println("\n[12e] Finding C: optimize_discrete rejects feasible + n_max_sections>0 (SZ layer)")
    checker_c = SR.AISCChecker()
    demands_c = [SR.MemberDemand(1; Mux = 100e3)]
    geoms_c   = [SR.SteelMemberGeometry(6.0)]
    cat_c     = SR.all_W()
    sz_threw = try
        SR.optimize_discrete(checker_c, demands_c, geoms_c, cat_c, SR.A992_Steel;
                             feasible = [collect(1:min(3, length(cat_c)))], n_max_sections = 1)
        false
    catch err
        err isa ArgumentError &&
            occursin("feasible", sprint(showerror, err)) &&
            occursin("n_max_sections", sprint(showerror, err))
    end
    record!("optimize_discrete throws on feasible!==nothing with n_max_sections>0 (SZ layer)", sz_threw)

    # ── [12f] Finding D: variation door uses the STRUC-AWARE guard ──────────────
    # A column-group override injected via redesign/vary is refused AT THE DOOR
    # (struc-aware), not only at the capture_design backstop; an honorable beam-group
    # override is NOT over-refused.
    println("\n[12f] Finding D: column override refused at variation door; beam override honored")
    struc_dd, base_dd = build_beam_column()
    design_building(struc_dd, base_dd)                        # discover a real column gid
    col_gid_d = first(sort(unique(group_id(c) for c in struc_dd.columns)))
    struc_ds, base_ds = build_beam_column()
    session_d = DesignSession(struc_ds, base_ds)
    col_ovr_d = Dict{UInt64, MemberGroupSizingOverride}(
        col_gid_d => MemberGroupSizingOverride(catalog = [heavy_co]))
    record!("redesign refuses column-group override at the door (message-pinned)",
            guard_threw(() -> redesign(session_d; member_group_overrides = col_ovr_d)))
    record!("vary refuses column-group override at the door (message-pinned)",
            guard_threw(() -> vary(session_d, (; member_group_overrides = col_ovr_d))))
    struc_ds2, base_ds2 = build_beam_column()
    session_d2 = DesignSession(struc_ds2, base_ds2)
    beam_ovr_d = Dict{UInt64, MemberGroupSizingOverride}(
        target_gid => MemberGroupSizingOverride(catalog = [heavy_co]))
    beam_door_ok = try
        redesign(session_d2; member_group_overrides = beam_ovr_d) isa BuildingDesign
    catch
        false
    end
    record!("honorable beam-group override passes the variation door (not over-refused)", beam_door_ok)

    # ── [12g] FIX CYCLE 2: P1-2 / P2-3 / P2-4 / composite ──────────────────────
    # Re-critic findings on the fix-cycle-1 guard.
    println("\n[12g] Fix cycle 2: P1-2 collinear / P2-3 par_has / P2-4 units / composite")

    # [P2-4] ill-typed override fields → PINNED ArgumentError at CONSTRUCTION, never
    # a bare Unitful DimensionError deep in the batched mask.
    p24_bare = try; MemberGroupSizingOverride(max_depth = 0.4); false
               catch e; e isa ArgumentError && occursin("member_group_overrides", sprint(showerror, e)); end
    record!("P2-4: bare-number max_depth refused at construction (pinned)", p24_bare)
    p24_dim = try; MemberGroupSizingOverride(deflection_limit = 1.0u"inch"); false
              catch e; e isa ArgumentError && occursin("member_group_overrides", sprint(showerror, e)); end
    record!("P2-4: dimensioned deflection_limit refused at construction (pinned)", p24_dim)
    record!("P2-4: well-typed override still constructs",
            MemberGroupSizingOverride(deflection_limit = 1/360, max_depth = 18.0u"inch") isa
                MemberGroupSizingOverride)

    # [composite] an EFFECTIVE override on a COMPOSITE-beam demand is refused fail-loud
    # (pinned). The batched mask gates deflection on bare-steel Ix while the composite
    # code check uses I_LB (AISC 360-16 Commentary I3.2). Exercised on the guard helper
    # with a lightweight non-nothing composite stand-in (batched demands are
    # composite===nothing by construction).
    gids_comp = UInt64[UInt64(11), UInt64(22)]
    demands_comp = [SR.MemberDemand(1; Mux = 100e3),
                    SR.MemberDemand(2; Mux = 100e3, composite = :composite_stub)]
    ovr_comp = Dict{UInt64, MemberGroupSizingOverride}(
        UInt64(22) => MemberGroupSizingOverride(catalog = [SR.W("W21X44")]))
    record!("composite: effective override on composite-beam demand refused (pinned)",
            guard_threw(() -> SS._assert_no_composite_override(gids_comp, demands_comp, ovr_comp)))
    ovr_comp_ok = Dict{UInt64, MemberGroupSizingOverride}(
        UInt64(11) => MemberGroupSizingOverride(catalog = [SR.W("W21X44")]))
    record!("composite: non-composite target with same override is fine",
            SS._assert_no_composite_override(gids_comp, demands_comp, ovr_comp_ok) === nothing)

    # [P2-3] a beam with NO segment on a :beams edge is never emitted by the sizer
    # (par_has == false); its override MUST be refused fail-loud, not silently dropped.
    # The DEFINITIVE check now lives at the SIZE-TIME gid gate inside _size_beams_impl!
    # (the pre-sizing classifier was REMOVED — its collinear reproduction disagreed with
    # the real size-time gids). Strip the :beams edge set so member_group_demands emits
    # NO group, then an override on that now-absent gid is refused fail-loud at size time
    # — even with an empty emitted set (the gate runs BEFORE the empty-group early return).
    struc_p3 = build_override_beam_struc()
    build_member_groups!(struc_p3; member_type = :beams)
    beam_gid_p3 = first(keys(struc_p3.member_groups))
    struc_p3.skeleton.groups_edges[:beams] = Int[]      # par_has false for every beam
    record!("P2-3: par_has-absent beam override refused fail-loud at size time (not silently dropped)",
            guard_threw(() -> size_beams!(struc_p3, SR.SteelBeamOptions(); reanalyze = false,
                member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                    beam_gid_p3 => MemberGroupSizingOverride(catalog = [heavy])))))

    # [P1-2] with collinear_grouping = true the sizer decides beam grouping at SIZE
    # time on the analysis structure (group_collinear_members! inside size_beams!), NOT
    # in prepare!. A pre-sizing reproduction of that grouping is UNRELIABLE (it disagreed
    # with the real size-time gids — e.g. 12 door-side chains vs 24 groups at size time),
    # so the definitive honor/refuse decision is the SIZE-TIME gid gate. Key an override
    # on the sizer's REAL size-time gid — read back from a DESIGNED struc
    # (group_id(struc.beams[k]) post-size, the verified data model) — and it is HONORED
    # through design_building AND redesign_incremental!, while a column-group gid throws.
    stiff = all_w[argmax([ustrip(u"m^4", SR.Ix(s)) for s in all_w])]
    secname_idx(des, k) = begin
        r = get(des.beams, k, nothing)
        r === nothing && return nothing
        r.section_obj === nothing ? nothing : r.section_obj.name
    end
    struc_a, base_a0 = build_beam_column()
    base_a = SS.with(base_a0; collinear_grouping = true)
    design_building(struc_a, base_a)
    beam_gids_a = unique(group_id(b) for b in struc_a.beams)
    record!("P1-2: real size-time beam gids readable from designed struc (collinear_grouping)",
            !isempty(beam_gids_a))
    target_cl = first(beam_gids_a)
    chain_idx = first(i for (i, b) in enumerate(struc_a.beams) if group_id(b) == target_cl)

    struc_clo, base_clo0 = build_beam_column()
    base_clo = SS.with(base_clo0; collinear_grouping = true,
        member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
            target_cl => MemberGroupSizingOverride(catalog = [stiff])))
    clo_ok = try
        des_clo = design_building(struc_clo, base_clo)
        des_clo isa BuildingDesign && secname_idx(des_clo, chain_idx) == stiff.name
    catch
        false
    end
    record!("P1-2: override on real size-time gid HONORED through design_building (collinear_grouping)", clo_ok)

    struc_cli, base_cli0 = build_beam_column()
    base_cli = SS.with(base_cli0; collinear_grouping = true)
    engine_cli = prepare_engine(struc_cli, base_cli)
    run_target!(engine_cli, base_cli)                       # clean base first
    variant_cli = SS.with(base_cli; member_group_overrides =
        Dict{UInt64, MemberGroupSizingOverride}(
            target_cl => MemberGroupSizingOverride(catalog = [stiff])))
    cli_ok = try
        rc_cli, _ = run_target!(engine_cli, variant_cli)
        inc_clo = capture_incremental_design(engine_cli, variant_cli)
        (NODE_MEMBERS in rc_cli) && secname_idx(inc_clo, chain_idx) == stiff.name
    catch
        false
    end
    record!("P1-2: override on real size-time gid HONORED through redesign_incremental!", cli_ok)

    struc_col, base_col0 = build_beam_column()
    design_building(struc_col, base_col0)
    col_gid_cl = first(sort(unique(group_id(c) for c in struc_col.columns)))
    struc_clc, base_clc0 = build_beam_column()
    base_clc_ov = SS.with(base_clc0; collinear_grouping = true,
        member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
            col_gid_cl => MemberGroupSizingOverride(catalog = [heavy])))
    record!("P1-2: column-group gid under collinear_grouping refused at size time (pinned)",
            guard_threw(() -> design_building(struc_clc, base_clc_ov)))

    # ── [12h] FIX CYCLE 3: P1 silent-drop / P2 section-identity / P2 SZ feasible ──
    println("\n[12h] Fix cycle 3: P1 skip-branch silent-drop / P2 section / P2 SZ")

    # [P1] `_size_beams_columns!` has TWO early-returns that skip size_beams! (and the
    # size-time gid gate): the slab-only branch and the no-beam-edges branch. On a
    # NON-flat steel floor with columns but NO :beams edges, an EFFECTIVE override
    # passed every existing door and was SILENTLY DROPPED while capture_design still
    # produced a BuildingDesign. Strip the vault's :beams edge set (initialize! reads
    # groups_edges, never repopulates it) → the no-beam-edges skip branch fires → the
    # honor-or-throw invariant now refuses the effective override fail-loud, on BOTH
    # design_building AND redesign_incremental!. An empty override stays a strict no-op.
    eff_ovr_p1 = Dict{UInt64, MemberGroupSizingOverride}(
        UInt64(1) => MemberGroupSizingOverride(catalog = [heavy]))
    struc_p1, base_p1 = build_beam_column()
    struc_p1.skeleton.groups_edges[:beams] = Int[]
    record!("P1: no-beam-edges skip branch refuses effective override via design_building (pinned)",
            guard_threw(() -> design_building(struc_p1,
                SS.with(base_p1; member_group_overrides = eff_ovr_p1))))

    struc_p1e, base_p1e = build_beam_column()
    struc_p1e.skeleton.groups_edges[:beams] = Int[]
    p1_empty_ok = try
        design_building(struc_p1e, base_p1e) isa BuildingDesign
    catch
        false
    end
    record!("P1: empty override on stripped-beams fixture is a strict no-op (byte-identical)", p1_empty_ok)

    struc_p1i, base_p1i = build_beam_column()
    struc_p1i.skeleton.groups_edges[:beams] = Int[]
    engine_p1 = prepare_engine(struc_p1i, base_p1i)
    run_target!(engine_p1, base_p1i)     # clean base: columns-only, no throw
    variant_p1 = SS.with(base_p1i; member_group_overrides = eff_ovr_p1)
    record!("P1: no-beam-edges skip branch refuses effective override via redesign_incremental! (pinned)",
            guard_threw(() -> redesign_incremental!(engine_p1, variant_p1)))

    # [P2 section-identity] an override-catalog section colliding a DEFAULT name but with
    # DIFFERING properties (a deep-copied default W with a halved Ix, same name) ⇒ pinned
    # throw. A genuinely IDENTICAL section (the cached default singleton) still dedups
    # byte-identically (no throw, real design).
    struc_free_p2, base_free_p2 = build_beam_column()
    design_building(struc_free_p2, base_free_p2)
    target_gid_p2 = first(sort(unique(group_id(b) for b in struc_free_p2.beams)))
    dflt_opts_p2 = SR.SteelBeamOptions()
    dflt_cat_p2 = dflt_opts_p2.custom_catalog === nothing ?
        SR.steel_column_catalog(dflt_opts_p2.section_type, dflt_opts_p2.catalog) :
        dflt_opts_p2.custom_catalog
    base_sec_p2 = first(dflt_cat_p2)
    modified_p2 = deepcopy(base_sec_p2)
    modified_p2.Ix = base_sec_p2.Ix * 0.5   # SAME name, DIFFERENT property (Ix)
    record!("P2 section: _sections_identical distinguishes differing props",
            !SS._sections_identical(base_sec_p2, modified_p2) &&
            SS._sections_identical(base_sec_p2, base_sec_p2))

    struc_c_p2, base_c_p2 = build_beam_column()
    record!("P2 section: name-colliding override with differing props refused (pinned)",
            guard_threw(() -> design_building(struc_c_p2, SS.with(base_c_p2;
                member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                    target_gid_p2 => MemberGroupSizingOverride(catalog = [modified_p2]))))))

    struc_id_p2, base_id_p2 = build_beam_column()
    p2_identical_ok = try
        design_building(struc_id_p2, SS.with(base_id_p2;
            member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                target_gid_p2 => MemberGroupSizingOverride(catalog = [base_sec_p2])))) isa BuildingDesign
    catch
        false
    end
    record!("P2 section: identical-name collision (cached singleton) dedups byte-identically", p2_identical_ok)

    # [P2 SZ, RECONCILED fix cycle 4] the MULTI-MATERIAL optimize_discrete keeps the
    # HARD in-range check (out-of-range index > n_sec*n_mat refused fail-loud) but NO
    # LONGER throws on a "single-material-space" heuristic: a material-1-only mask
    # (indices k = (1-1)*n_sec + j = j, all <= n_sec) is a LEGITIMATE in-range
    # restriction, indistinguishable from a mis-spaced mask, so cycle-3's heuristic
    # FALSE-POSITIVED it. It must now run and return a feasible result confined to
    # material 1. Solver-input guard — ArgumentError only on the out-of-range case; the
    # single-material overload is unchanged.
    checker_mm = SR.AISCChecker()
    demands_mm = [SR.MemberDemand(1; Mux = 100e3)]
    geoms_mm   = [SR.SteelMemberGeometry(6.0)]
    cat_mm     = SR.all_W()
    mats_mm    = [SR.A992_Steel, SR.A992_Steel]   # n_mat = 2
    n_sec_mm   = length(cat_mm)
    sz_m1_ok = try
        res_m1 = SR.optimize_discrete(checker_mm, demands_mm, geoms_mm, cat_mm, mats_mm;
                                      feasible = [collect(1:n_sec_mm)], n_max_sections = 0)
        res_m1.material_indices[1] == 1 && res_m1.section_indices[1] in 1:n_sec_mm
    catch
        false
    end
    record!("P2 SZ: multi-material material-1-only in-range mask honored (no throw, picks material 1)", sz_m1_ok)
    sz_oor_threw = try
        SR.optimize_discrete(checker_mm, demands_mm, geoms_mm, cat_mm, mats_mm;
                             feasible = [[n_sec_mm * 2 + 5]], n_max_sections = 0)
        false
    catch e
        e isa ArgumentError
    end
    record!("P2 SZ: multi-material out-of-range feasible index refused (ArgumentError)", sz_oor_threw)

    # ── [12i] FIX CYCLE 4: universal size! gate / struc-only backstop / P2 sections ──
    println("\n[12i] Fix cycle 4: universal size! gate / struc-only backstop / P2 section dedup")

    # Deterministic gids from a designed reference fixture (stable across identical
    # build_beam_column() fixtures).
    struc_c4ref, base_c4ref = build_beam_column()
    des_c4ref = design_building(struc_c4ref, base_c4ref)
    beam_gids_c4 = sort(unique(group_id(b) for b in struc_c4ref.beams))
    target_gid_c4 = first(beam_gids_c4)
    col_gid_c4 = first(sort(unique(group_id(c) for c in struc_c4ref.columns)))
    free_sec_c4 = beam_secname(struc_c4ref, des_c4ref, target_gid_c4)

    # [P0] HONORABLE steel-beam override via the exported size!(design) path ⇒ the
    # returned design HONORS the restriction (target group sized to heavy), NOT a
    # silently-dropped default-catalog design.
    struc_h4, base_h40 = build_beam_column()
    base_h4 = SS.with(base_h40; member_group_overrides =
        Dict{UInt64, MemberGroupSizingOverride}(
            target_gid_c4 => MemberGroupSizingOverride(catalog = [heavy])))
    prepare!(struc_h4, base_h4)
    design_h4 = BuildingDesign(struc_h4, base_h4)
    size!(design_h4; verbose = false)
    forced_h4 = beam_secname(struc_h4, design_h4, target_gid_c4)
    record!("P0: size! honors an effective steel-beam override (not silently dropped)",
            forced_h4 == heavy.name && forced_h4 != free_sec_c4)

    # [P0] UN-HONORABLE override (a COLUMN-group gid) via size! ⇒ pinned throw at the
    # size-time gate (never a silently-dropped design).
    struc_u4, base_u40 = build_beam_column()
    base_u4 = SS.with(base_u40; member_group_overrides =
        Dict{UInt64, MemberGroupSizingOverride}(
            col_gid_c4 => MemberGroupSizingOverride(catalog = [heavy])))
    prepare!(struc_u4, base_u4)
    design_u4 = BuildingDesign(struc_u4, base_u4)
    record!("P0: size! refuses an un-honorable override (pinned member_group_overrides)",
            guard_threw(() -> size!(design_u4; verbose = false)))

    # [P1] struc.design_parameters is NOT a field of BuildingStructure and is never
    # assigned, so the size_beams! dp-default is an inert backstop (stays nothing) and
    # the size! thread is authoritative. Assert the backstop is inert: bare
    # size_beams! / size_members! with no override channel size normally, never
    # throwing the pinned guard.
    struc_b4, base_b4 = build_beam_column()
    prepare!(struc_b4, base_b4)
    p1_backstop_ok = try
        (size_beams!(struc_b4, SR.SteelBeamOptions(); reanalyze = false) === struc_b4)
    catch
        false
    end
    record!("P1: bare size_beams! with no override channel is a strict no-op (backstop inert)", p1_backstop_ok)
    struc_mm4, base_mm4 = build_beam_column()
    prepare!(struc_mm4, base_mm4)
    p1_members_ok = try
        (size_members!(struc_mm4) === struc_mm4)
    catch
        false
    end
    record!("P1: bare size_members! with no override channel is a strict no-op (never silent drop)", p1_members_ok)

    # [P2 sections] _sections_identical dedups genuinely value-equal but DISTINCT-object
    # sections (deepcopy) while still refusing a genuinely-differing collision.
    dflt_opts_c4 = SR.SteelBeamOptions()
    dflt_cat_c4 = dflt_opts_c4.custom_catalog === nothing ?
        SR.steel_column_catalog(dflt_opts_c4.section_type, dflt_opts_c4.catalog) :
        dflt_opts_c4.custom_catalog
    base_sec_c4 = first(dflt_cat_c4)
    record!("P2 section: value-equal distinct-object section dedups (no over-refusal)",
            SS._sections_identical(base_sec_c4, deepcopy(base_sec_c4)) &&
            SS._sections_identical(base_sec_c4, base_sec_c4))
    heavy_dflt_c4 = dflt_cat_c4[argmax([SR.section_area(s) for s in dflt_cat_c4])]
    struc_dd4, base_dd40 = build_beam_column()
    base_dd4 = SS.with(base_dd40; member_group_overrides =
        Dict{UInt64, MemberGroupSizingOverride}(
            target_gid_c4 => MemberGroupSizingOverride(catalog = [deepcopy(heavy_dflt_c4)])))
    p2_dedup_ok = try
        design_building(struc_dd4, base_dd4) isa BuildingDesign
    catch
        false
    end
    record!("P2 section: value-equal deepcopy override colliding a default name dedups (no throw)", p2_dedup_ok)

    # ── [12j] FIX CYCLE 5: size! front-door parity / multi-material backstop / NaN id ──
    println("\n[12j] Fix cycle 5: size! front-door guard parity / multi-material backstop / NaN identity")

    # [P0] non-steel (concrete) beam opts + an override MUTATED into the live dict AFTER
    # an empty-dict construction ⇒ size! refuses pinned. The constructor guard short-
    # circuited on the then-empty dict; the size! front-door guard re-runs and fires
    # check 2 (non-steel). prepare! never inspects params.beams, so size! reaches it.
    struc_c5, base_c5 = build_beam_column(beams = SR.ConcreteBeamOptions())
    prepare!(struc_c5, base_c5)
    design_c5 = BuildingDesign(struc_c5, base_c5)
    design_c5.params.member_group_overrides[target_gid_c4] =
        MemberGroupSizingOverride(catalog = [heavy])
    record!("P0: size! refuses a non-steel-beam effective override mutated post-construct (pinned)",
            guard_threw(() -> size!(design_c5; verbose = false)))

    # [P1] multi-material steel beam opts + effective override mutated in after
    # construction ⇒ size! refuses pinned (front-door check 4), never a silent collapse
    # to material 1.
    struc_mm5, base_mm5 = build_beam_column(
        beams = SR.SteelBeamOptions(materials = [SR.A992_Steel, SR.S355_Steel]))
    prepare!(struc_mm5, base_mm5)
    design_mm5 = BuildingDesign(struc_mm5, base_mm5)
    design_mm5.params.member_group_overrides[target_gid_c4] =
        MemberGroupSizingOverride(catalog = [heavy])
    record!("P1: size! refuses a multi-material steel effective override (pinned, check 4)",
            guard_threw(() -> size!(design_mm5; verbose = false)))

    # [P1/P2 backstop] bypass the front door: the batched steel size-time gate itself
    # refuses a multi-material effective override (opts.materials !== nothing), so the
    # single-material-space feasible mask never reaches the multi-material solver.
    struc_bs5, base_bs5 = build_beam_column()
    prepare!(struc_bs5, base_bs5)
    record!("P1/P2 backstop: batched steel gate refuses multi-material override directly (pinned)",
            guard_threw(() -> size_beams!(struc_bs5,
                SR.SteelBeamOptions(materials = [SR.A992_Steel, SR.S355_Steel]);
                reanalyze = false,
                member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                    target_gid_c4 => MemberGroupSizingOverride(catalog = [heavy])))))

    # regression: an HONORABLE single-material steel override via size! is still HONORED.
    struc_hh5, base_hh50 = build_beam_column()
    base_hh5 = SS.with(base_hh50; member_group_overrides =
        Dict{UInt64, MemberGroupSizingOverride}(
            target_gid_c4 => MemberGroupSizingOverride(catalog = [heavy])))
    prepare!(struc_hh5, base_hh5)
    design_hh5 = BuildingDesign(struc_hh5, base_hh5)
    size!(design_hh5; verbose = false)
    forced_hh5 = beam_secname(struc_hh5, design_hh5, target_gid_c4)
    record!("regression: size! still HONORS an honorable single-material steel override",
            forced_hh5 == heavy.name && forced_hh5 != free_sec_c4)

    # [P2 sections, fix cycle 6] Leaf comparison is `isequal`-based — the cycle-5
    # NaN-poison rule was REVERTED. `isequal(NaN, NaN) === true` (two unset sentinels do
    # NOT differ) while `isequal(1.0, NaN) === false`. Metal.cost defaults to NaN, so
    # A992_Steel.cost is the NaN sentinel; a `missing` field still dedups too.
    record!("P2 NaN: _field_identical treats a both-NaN sentinel leaf as identical (isequal)",
            SS._field_identical(1.0, 1.0) && SS._field_identical(missing, missing) &&
            SS._field_identical(NaN, NaN) && !SS._field_identical(1.0, NaN))

    dflt_opts_c5 = SR.SteelBeamOptions()
    dflt_cat_c5 = dflt_opts_c5.custom_catalog === nothing ?
        SR.steel_column_catalog(dflt_opts_c5.section_type, dflt_opts_c5.catalog) :
        dflt_opts_c5.custom_catalog
    base_sec_c5 = first(dflt_cat_c5)
    sec_nan_a5 = deepcopy(base_sec_c5); sec_nan_a5.material = deepcopy(SR.A992_Steel)
    sec_nan_b5 = deepcopy(base_sec_c5); sec_nan_b5.material = deepcopy(SR.A992_Steel)
    record!("P2 NaN: two value-equal sections both carrying a cost=NaN sentinel field dedup",
            isnan(sec_nan_a5.material.cost) &&
            SS._sections_identical(sec_nan_a5, sec_nan_b5) &&
            SS._sections_identical(deepcopy(base_sec_c5), deepcopy(base_sec_c5)))

    # [P2 recursion bound] a cyclic field graph terminates (returns false), never
    # StackOverflows — the depth cap backstops a self-referential section-field graph.
    ref_a5 = Ref{Any}(nothing); ref_a5[] = ref_a5
    ref_b5 = Ref{Any}(nothing); ref_b5[] = ref_b5
    record!("P2 recursion: _field_identical is depth-bounded on a cyclic graph (no StackOverflow)",
            SS._field_identical(ref_a5, ref_b5) == false)

    # ── [12k] FIX CYCLE 6: :nlp guard / NaN dedup / size-time looseness ──────────
    println("\n[12k] Fix cycle 6: :nlp override guard / NaN-material dedup / size-time looseness")

    # [P1-a] a steel-beam option with sizing_strategy != :discrete (e.g. :nlp) has NO
    # honoring path (the size-time gid gate lives only in the :discrete _size_beams_impl!),
    # so an effective override on it is refused with the PINNED guard (front-door check
    # 4b) — NOT a raw MethodError, and never a silent drop. Assert via design_building
    # AND via size!.
    struc_nlp6, base_nlp60 = build_beam_column(beams = SR.SteelBeamOptions(sizing_strategy = :nlp))
    base_nlp6 = SS.with(base_nlp60; member_group_overrides =
        Dict{UInt64, MemberGroupSizingOverride}(
            target_gid_c4 => MemberGroupSizingOverride(catalog = [heavy])))
    record!("P1-a: design_building refuses a :nlp steel-beam effective override (pinned, not MethodError)",
            guard_threw(() -> design_building(struc_nlp6, base_nlp6)))

    struc_nlp62, base_nlp62 = build_beam_column(beams = SR.SteelBeamOptions(sizing_strategy = :nlp))
    prepare!(struc_nlp62, base_nlp62)
    design_nlp62 = BuildingDesign(struc_nlp62, base_nlp62)   # empty dict ⇒ constructor guard passes
    design_nlp62.params.member_group_overrides[target_gid_c4] =
        MemberGroupSizingOverride(catalog = [heavy])
    record!("P1-a: size! refuses a :nlp steel-beam effective override (pinned, not MethodError)",
            guard_threw(() -> size!(design_nlp62; verbose = false)))

    # [P1-b] two genuinely value-equal override sections both carrying a cost=NaN material
    # and colliding a (typename,name) key DEDUP byte-identically (honor path); a
    # name-colliding section with a DIFFERING property is STILL refused pinned.
    dflt_opts_c6 = SR.SteelBeamOptions()
    dflt_cat_c6 = dflt_opts_c6.custom_catalog === nothing ?
        SR.steel_column_catalog(dflt_opts_c6.section_type, dflt_opts_c6.catalog) :
        dflt_opts_c6.custom_catalog
    base_sec_c6 = first(dflt_cat_c6)
    a6 = deepcopy(base_sec_c6); a6.material = deepcopy(SR.A992_Steel)
    b6 = deepcopy(base_sec_c6); b6.material = deepcopy(SR.A992_Steel)
    c6 = deepcopy(base_sec_c6); c6.Ix = base_sec_c6.Ix * 0.5
    record!("P1-b: value-equal cost=NaN sections dedup; differing property still distinct",
            isnan(a6.material.cost) && SS._sections_identical(a6, b6) &&
            SS._field_identical(NaN, NaN) && !SS._field_identical(1.0, NaN) &&
            !SS._sections_identical(base_sec_c6, c6))

    heavy_dflt_c6 = dflt_cat_c6[argmax([SR.section_area(s) for s in dflt_cat_c6])]
    struc_dd6, base_dd60 = build_beam_column()
    base_dd6 = SS.with(base_dd60; member_group_overrides =
        Dict{UInt64, MemberGroupSizingOverride}(
            target_gid_c4 => MemberGroupSizingOverride(catalog = [deepcopy(heavy_dflt_c6)])))
    p1b_dedup_ok = try
        design_building(struc_dd6, base_dd6) isa BuildingDesign
    catch
        false
    end
    record!("P1-b: value-equal deepcopy override colliding a default name dedups (no throw)", p1b_dedup_ok)

    diff_sec_c6 = deepcopy(heavy_dflt_c6); diff_sec_c6.Ix = heavy_dflt_c6.Ix * 0.5
    struc_df6, base_df60 = build_beam_column()
    base_df6 = SS.with(base_df60; member_group_overrides =
        Dict{UInt64, MemberGroupSizingOverride}(
            target_gid_c4 => MemberGroupSizingOverride(catalog = [diff_sec_c6])))
    record!("P1-b: name-colliding override with a DIFFERING property still refused (pinned)",
            guard_threw(() -> design_building(struc_df6, base_df6)))

    # [P2] the DIRECT size_beams! path bypasses the front door, so the size-time gid gate
    # must itself refuse a LOOSER per-group knob (mirrors front-door check 5). A tightening
    # knob via the same direct path stays HONORED. deflection_limit is an L/δ ratio, so
    # LOOSER = numerically LARGER (1/180 > default 1/360); max_depth LOOSER = LARGER.
    struc_lo6, base_lo6 = build_beam_column()
    prepare!(struc_lo6, base_lo6)
    record!("P2: direct size_beams! refuses a looser deflection_limit override (pinned)",
            guard_threw(() -> size_beams!(struc_lo6, SR.SteelBeamOptions(); reanalyze = false,
                member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                    target_gid_c4 => MemberGroupSizingOverride(deflection_limit = 1/180)))))

    struc_ld6, base_ld6 = build_beam_column()
    prepare!(struc_ld6, base_ld6)
    record!("P2: direct size_beams! refuses a looser max_depth override (pinned)",
            guard_threw(() -> size_beams!(struc_ld6, SR.SteelBeamOptions(max_depth = 12.0u"inch");
                reanalyze = false,
                member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                    target_gid_c4 => MemberGroupSizingOverride(max_depth = 24.0u"inch")))))

    struc_ti6, base_ti6 = build_beam_column()
    prepare!(struc_ti6, base_ti6)
    p2_tighten_ok = try
        (size_beams!(struc_ti6, SR.SteelBeamOptions(); reanalyze = false,
            member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                target_gid_c4 => MemberGroupSizingOverride(max_depth = 30.0u"inch"))) === struc_ti6)
    catch
        false
    end
    record!("P2: direct size_beams! HONORS a tightening override via the same path (no throw)", p2_tighten_ok)

    # ── Summary ──────────────────────────────────────────────────────────────
    println("\n" * "="^70)
    npass = count(c -> c[2], CHECKS)
    if npass == length(CHECKS)
        println("✓ ALL CHECKS PASS ($npass/$(length(CHECKS)))")
        println("="^70)
        return 0
    else
        println("✗ $(length(CHECKS) - npass) CHECK(S) FAILED ($npass/$(length(CHECKS)))")
        for (name, ok) in CHECKS
            ok || println("    FAIL: $name")
        end
        println("="^70)
        return 1
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
