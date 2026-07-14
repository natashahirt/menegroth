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
# Invariant set — the SAME 15 columns as verify_design_graph.jl (mirrored, not
# weakened). Output-equivalence is asserted over all 15 at rtol=1e-8.
# -----------------------------------------------------------------------------
const INVARIANT_COLS = (
    :h_m, :M0_kNm,
    :punch_ratio, :defl_ratio,
    :As_cs_in2, :As_ms_in2, :As_total_in2,
    :col_min_in, :col_max_in,
    :ec_total_kgco2e, :ec_per_area_kgco2e_m2,
    :fdn_max_B_ft, :fdn_max_L_ft, :fdn_max_D_in, :fdn_max_util,
)

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
# Comprehensive per-member design signature (P2 hardening).
# -----------------------------------------------------------------------------
# The 15 INVARIANT_COLS above are an AGGREGATE summary (global maxima); they are
# NOT bit-identical — they omit per-member beam sizes, column/beam
# capacity/interaction/axial ratios, ok/feasibility flags, punching stud counts,
# and per-strip rebar, so a provenance omission (e.g. an unpatterned member) can
# slip past them (exactly how the pattern_loading P0 escaped gate 3).
# `design_signature` flattens EVERY such output field into a deterministic
# (label => value) list; equal signatures ⇒ output-equivalent across all compared
# fields (values reduced to plain Float64/Bool/String/Symbol).
function design_signature(design::BuildingDesign)
    sig = Pair{String, Any}[]

    for k in sort(collect(keys(design.columns)))
        c = design.columns[k]
        push!(sig, "col$k.c1_in"             => ustrip(u"inch", c.c1))
        push!(sig, "col$k.c2_in"             => ustrip(u"inch", c.c2))
        push!(sig, "col$k.shape"             => c.shape)
        push!(sig, "col$k.section"           => c.section_size)
        push!(sig, "col$k.axial_ratio"       => c.axial_ratio)
        push!(sig, "col$k.interaction_ratio" => c.interaction_ratio)
        push!(sig, "col$k.ok"                => c.ok)
        if c.punching !== nothing
            push!(sig, "col$k.punch_ratio" => c.punching.ratio)
            push!(sig, "col$k.punch_ok"    => c.punching.ok)
        end
    end

    for k in sort(collect(keys(design.beams)))
        b = design.beams[k]
        push!(sig, "beam$k.section"       => b.section_size)
        push!(sig, "beam$k.flexure_ratio" => b.flexure_ratio)
        push!(sig, "beam$k.shear_ratio"   => b.shear_ratio)
        push!(sig, "beam$k.ok"            => b.ok)
        push!(sig, "beam$k.len_m"         => ustrip(u"m",  b.member_length))
        push!(sig, "beam$k.weight_kg"     => ustrip(u"kg", b.weight))
    end

    for k in sort(collect(keys(design.slabs)))
        s = design.slabs[k]
        push!(sig, "slab$k.thk_m"             => ustrip(u"m", s.thickness))
        push!(sig, "slab$k.M0_kNm"            => isnothing(s.M0) ? NaN : ustrip(u"kN*m", s.M0))
        push!(sig, "slab$k.defl_ratio"        => s.deflection_ratio)
        push!(sig, "slab$k.defl_ok"           => s.deflection_ok)
        push!(sig, "slab$k.punch_ratio"       => s.punching_max_ratio)
        push!(sig, "slab$k.punch_ok"          => s.punching_ok)
        push!(sig, "slab$k.converged"         => s.converged)
        push!(sig, "slab$k.integrity_ok"      => s.integrity_ok)
        push!(sig, "slab$k.has_studs"         => s.has_studs)
        push!(sig, "slab$k.n_stud_cols"       => s.n_stud_cols)
        push!(sig, "slab$k.stud_rails_max"    => s.stud_rails_max)
        push!(sig, "slab$k.stud_per_rail_max" => s.stud_per_rail_max)
        r = s.sizer_result
        if !isnothing(r)
            for fld in (:column_strip_reinf, :middle_strip_reinf,
                        :secondary_column_strip_reinf, :secondary_middle_strip_reinf)
                hasproperty(r, fld) || continue
                for (i, sr) in enumerate(getproperty(r, fld))
                    push!(sig, "slab$k.$fld[$i].As_in2" => ustrip(u"inch^2", sr.As_provided))
                end
            end
        end
    end

    for k in sort(collect(keys(design.foundations)))
        f = design.foundations[k]
        push!(sig, "fdn$k.L_ft"           => ustrip(u"ft",   f.length))
        push!(sig, "fdn$k.W_ft"           => ustrip(u"ft",   f.width))
        push!(sig, "fdn$k.D_in"           => ustrip(u"inch", f.depth))
        push!(sig, "fdn$k.bearing_ratio"  => f.bearing_ratio)
        push!(sig, "fdn$k.punching_ratio" => f.punching_ratio)
        push!(sig, "fdn$k.flexure_ratio"  => f.flexure_ratio)
        push!(sig, "fdn$k.ok"             => f.ok)
        push!(sig, "fdn$k.group_id"       => f.group_id)
    end

    push!(sig, "sum.all_checks_pass"  => design.summary.all_checks_pass)
    push!(sig, "sum.critical_ratio"   => design.summary.critical_ratio)
    push!(sig, "sum.critical_element" => design.summary.critical_element)
    push!(sig, "sum.ec_kgco2e"        => ustrip(u"kgCO2e", design.summary.embodied_carbon))
    return sig
end

"Compare two design signatures; returns (ok, first_mismatch_label)."
function same_signature(a::Vector{Pair{String, Any}}, b::Vector{Pair{String, Any}})
    da = Dict(a); db = Dict(b)
    Set(keys(da)) == Set(keys(db)) || return (false, "field set differs")
    for (k, va) in da
        _close(va, db[k]) || return (false, k)
    end
    return (true, "none")
end

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

    # ── [12] RUN 4, PART 1: member_group_overrides infrastructure ─────────────
    # HONEST SCOPE: `member_group_overrides` is honored ONLY on the isolated
    # per-group `size_member_group!` path. `design_building`'s member stage runs
    # batched `size_beams!` / global `size_columns!` MIP / flat-plate
    # `_reconcile_columns!`, none of which route through `size_member_group!`, so
    # it CANNOT honor an override. Rather than silently ignore it, `design_building`
    # now FAILS LOUD: a non-empty `member_group_overrides` raises an `ArgumentError`
    # (guard in `run_pre_sizing_validation`, which every `design_building` and
    # `DesignSession`/engine construction runs); the empty (default) case is
    # byte-identical. Fine per-beam-group incremental nodes (Part 2) are therefore
    # NOT shipped — they would only be verifiable if a group were sized independently,
    # which this codebase's `design_building` never does. We prove the override
    # MECHANISM directly on `size_member_group!` (non-vacuous), plus the fail-loud
    # guard on `design_building` (the honest evidence of the Part-1 limitation).
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

    # precedence: override > MemberGroup.catalog_override > global default
    struc_pr = build_override_beam_struc()
    build_member_groups!(struc_pr; member_type = :beams)
    gid_pr = first(keys(struc_pr.member_groups))
    struc_pr.member_groups[gid_pr].catalog_override = [SR.W("W24X68")]  # would give W24X68
    size_member_group!(struc_pr, gid_pr; member_edge_group = :beams,
                       material = A992_Steel, reanalyze = true,
                       override = MemberGroupSizingOverride(catalog = [SR.W("W21X44")]))
    record!("precedence: override beats MemberGroup.catalog_override",
            struc_pr.member_groups[gid_pr].section.name == "W21X44")

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

    # not prepare-affecting, not in any node slice → empty dirty frontier.
    struc_fr, base_fr = build_flat_plate()
    session_fr = DesignSession(struc_fr, base_fr)
    fr_ovr = Dict{UInt64, MemberGroupSizingOverride}(
        UInt64(1) => MemberGroupSizingOverride(catalog = [SR.W("W21X44")]))
    record!("member_group_overrides change → empty dirty frontier, not prepare-affecting",
            isempty(dirty_frontier(session_fr; member_group_overrides = fr_ovr)) &&
            !requires_new_engine(session_fr; member_group_overrides = fr_ovr))

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
