# =============================================================================
# Incremental variation test — invalidation matrix (DesignSession)
# =============================================================================
#
# In-suite twin of `scripts/runners/verify_design_graph_incremental.jl`. Proves
# the Run-2 variation API (`DesignSession` / `redesign` / `vary` /
# `dirty_frontier`) obeys the exact-first incremental contract: for each
# representative parameter variation it asserts BOTH
#
#   (a) SKIP  — the nodes the engine ACTUALLY recomputed == the expected dirty
#               frontier, and a column-only variation and the chosen load-ish
#               variation NEVER recompute :slab_sizing; AND
#   (b) EXACT — the incremental `BuildingDesign` matches a from-scratch
#               `design_building(struc, varied_params)` at rtol=1e-8 on a
#               COMPREHENSIVE per-member signature (`_design_signature`): beam
#               sizes, column/beam capacity + interaction + axial ratios,
#               ok/feasibility flags, punching stud counts, and per-strip rebar —
#               not merely the 15 aggregate scalars (which cannot catch a
#               per-member provenance omission such as an unpatterned member).
#
# A node-skip is never asserted without the paired comprehensive-equivalence check.
#
# Variations (mapped to what the engine actually supports — the prepared
# baseline is fixed, so any PREPARE_AFFECTING_FIELDS change requires a fresh
# session; see StructuralSynthesizer/src/design_graph/scheduler.jl):
#
#   • column-only (`:beams`)                  → frontier [:members], slab clean
#   • load-ish (`:foundation_options` soil)   → frontier [:foundations], slab+members clean
#       NOTE: live load (`:loads`) is PREPARE-AFFECTING (baked into the prepared
#       Asap model), so we substitute the closest non-prepare, demand-side
#       (load-ish) override — foundation soil bearing — which must not invalidate
#       slab sizing. The from-scratch reference uses the SAME soil (not faked).
#   • slab-type swap (`:floor`)               → prepare-affecting: guard fires
#   • concrete strength (`:materials`)        → prepare-affecting: guard fires
#   • geometry (`:geometry_is_centerline`)    → prepare-affecting: guard fires
#
# Run standalone:
#   julia --project=StructuralSynthesizer \
#       StructuralSynthesizer/test/design_graph/test_design_graph_incremental.jl
# =============================================================================

using StructuralSynthesizer
using StructuralSizer
using Test
using Unitful
using Asap  # registers u"kgCO2e" (embodied-carbon unit)

const _SR = StructuralSizer
const _SS = StructuralSynthesizer

# Lightweight duck-typed column stand-ins for the direct `_adopt_larger_column!`
# unit tests (Findings 3 + 4). `_adopt_larger_column!` is untyped on its args and
# only touches `.c1`, `.c2`, `.shape`, `.base.section`, `.base.volumes`, so these
# isolate the merge logic without constructing a full `Column`. (Julia requires
# `struct` definitions at top level — they cannot live inside a `@testset`.)
mutable struct _FakeBase; section; volumes; end
mutable struct _FakeCol; c1; c2; shape; base::_FakeBase; end
_mkcol(c1, c2, sect; shape = :rectangular, vol = [1.0]) =
    _FakeCol(c1, c2, shape, _FakeBase(sect, vol))
# Section stand-in exposing `As_total` — the field `_column_section_steel_area`
# reads as the dimensional-TIE non-downgrade proxy (P2a). `id` keeps distinct
# sections `!==` / distinguishable even when steel areas are equal.
mutable struct _FakeSection; id; As_total; end
_mksect(id, As_total) = _FakeSection(id, As_total)

# Same 15 invariants as test_design_graph_equivalence.jl (mirrored, not weakened).
const _INVARIANT_COLS = (
    :h_m, :M0_kNm,
    :punch_ratio, :defl_ratio,
    :As_cs_in2, :As_ms_in2, :As_total_in2,
    :col_min_in, :col_max_in,
    :ec_total_kgco2e, :ec_per_area_kgco2e_m2,
    :fdn_max_B_ft, :fdn_max_L_ft, :fdn_max_D_in, :fdn_max_util,
)

# Flat-plate DDM + spread foundations (matches the equivalence test fixture).
function _build_flat_plate(; soil = _SR.medium_sand,
                             concrete = NWC_4000,
                             geometry_is_centerline::Bool = false)
    skel  = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name                   = "test_incremental",
        floor                  = FlatPlateOptions(method = DDM()),
        materials              = MaterialOptions(concrete = concrete, rebar = Rebar_60),
        max_iterations         = 5,
        skip_visualization     = true,
        geometry_is_centerline = geometry_is_centerline,
        foundation_options     = FoundationParameters(
            soil    = soil,
            options = _SR.FoundationOptions(strategy = :all_spread),
        ),
    )
    return struc, params
end

# Beam/column vault building (stage 2 = `_size_beams_columns!`, genuinely sizes
# steel beams from `params.beams`; no foundations, so terminal node is :members).
function _build_beam_column(; beams = nothing)
    skel  = gen_medium_office(30.0u"ft", 24.0u"ft", 12.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name               = "test_incremental_beam_column",
        floor              = _SR.VaultOptions(lambda = 8.0, material = _SR.NWC_4000),
        beams              = beams,
        max_iterations     = 5,
        skip_visualization = true,
    )
    return struc, params
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

# Mirror of test_design_graph_equivalence.jl:_extract_invariants (15 invariants).
function _extract_invariants(design::BuildingDesign)
    slabs = collect(values(design.slabs))
    @assert !isempty(slabs) "design has no slabs"

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

# NaN-aware closeness (two NaNs equal); matches the equivalence test's `_close`.
function _close(a, b; rtol::Float64 = 1e-8, atol::Float64 = 1e-10)
    if a isa AbstractFloat && b isa AbstractFloat
        (isnan(a) && isnan(b)) && return true
        return isapprox(a, b; rtol = rtol, atol = atol)
    end
    return isequal(a, b)
end

# -----------------------------------------------------------------------------
# Comprehensive per-member design signature (P2 hardening).
# -----------------------------------------------------------------------------
# The 15-scalar invariant tuple above is an AGGREGATE summary (global maxima); it
# is NOT bit-identical — it omits per-member beam sizes, column/beam
# capacity/interaction/axial ratios, ok/feasibility flags, punching stud counts,
# and per-strip rebar, so a provenance omission (e.g. an unpatterned member) can
# slip past it. `_design_signature` flattens EVERY such output field into a
# deterministic (label => value) list; two designs with an equal signature are
# output-equivalent across all compared fields. Values are reduced to plain
# Float64 / Bool / String / Symbol so `_close` can compare them at rtol=1e-8.
function _design_signature(design::BuildingDesign)
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
function _same_signature(a::Vector{Pair{String, Any}}, b::Vector{Pair{String, Any}};
                         rtol::Float64 = 1e-8, atol::Float64 = 1e-10)
    da = Dict(a); db = Dict(b)
    Set(keys(da)) == Set(keys(db)) || return (false, "field set differs")
    for (k, va) in da
        _close(va, db[k]; rtol = rtol, atol = atol) || return (false, k)
    end
    return (true, "none")
end

# -----------------------------------------------------------------------------
# Fine per-slab topology helpers.
# -----------------------------------------------------------------------------
# `:slab_sizing` is decomposed into one `:slab_sizing_s{idx}` node per slab, so a
# slabbed building has NO coarse `NODE_SLAB_SIZING` node. Enumerate the actual
# slab-node keys from a session's graph so recompute/restore/frontier assertions
# are independent of the slab count.
_slab_keys(g)  = NodeKey[k for k in _SS.topological_order(g) if _SS.is_slab_node_key(k)]
_slab_set(g)   = Set(_slab_keys(g))
_graph_of(session) = session.engine.graph
# Slab-bearing topological levels == slab-stage barrier `sync_asap!` flushes.
_slab_sync_count(g) =
    count(lvl -> any(_SS.is_slab_node_key, lvl), _SS.topological_levels(g))

# Multi-STORY flat plate → one slab per story. After Finding 1 all slab nodes are
# edgeless roots ⇒ they occupy ONE topological level holding MULTIPLE fine per-slab
# nodes (the multi-node-per-level fixture), independent of `slab_parallel_batches`.
function _build_multistory_flat_plate(; soil = _SR.medium_sand, concrete = NWC_4000)
    skel  = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 3)   # 3 stories
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name               = "test_incremental_multistory",
        floor              = FlatPlateOptions(method = DDM()),
        materials          = MaterialOptions(concrete = concrete, rebar = Rebar_60),
        max_iterations     = 5,
        skip_visualization = true,
        foundation_options = FoundationParameters(
            soil    = soil,
            options = _SR.FoundationOptions(strategy = :all_spread),
        ),
    )
    return struc, params
end

# LATERAL-THRUST-GOVERNED vault: larger span at the same span/rise ratio raises
# `H = w·L·λ/8`, the baked LateralThrust edge load that drives the steel members —
# so the vault thrust (and its sync-path refresh) is load-bearing on the result.
# `:individual` grouping ⇒ 4 slabs. After Finding 1 all slab nodes are edgeless
# roots ⇒ ONE topological level / ONE barrier sync (independent of
# `slab_parallel_batches`).
function _build_thrust_vault(; beams = nothing)
    skel  = gen_medium_office(40.0u"ft", 32.0u"ft", 12.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name               = "test_incremental_thrust_vault",
        floor              = _SR.VaultOptions(lambda = 10.0, material = _SR.NWC_4000),
        beams              = beams,
        max_iterations     = 5,
        skip_visualization = true,
    )
    return struc, params
end

# P0 fixture (Finding 1): SINGLE-story, MULTI-BAY flat plate with
# `grouping = :individual` ⇒ one slab PER cell that SHARE interior supporting
# columns. A 3×2 bay grid is deliberately chosen over 2×2: in 2×2 the single
# centre column is shared by ALL four slabs (a COMPLETE conflict graph → greedy
# coloring assigns colors in index order → flattened batch order == eachindex, so
# NO reorder and no P0). In a 3×2 grid the two mid-edge cells conflict with all
# others while corner cells do not, so `slab_conflict_coloring`'s largest-degree-
# first greedy coloring produces a NON-identity permutation whose flattened batch
# order ≠ eachindex — the exact condition under which the pre-fix batch-ordered
# fine graph diverged from the single-threaded coarse `size_slabs!` reference
# (flat-plate slab sizing reads LIVE shared column c1/c2, and columns grow
# monotonically, so per-slab output is ORDER-DEPENDENT). Large bays + HEAVY loads
# (125 psf LL, 40 psf SDL) make the columns PUNCHING-GOVERNED so they genuinely
# grow across slabs — the order effect on the final sizes is then well outside
# rtol=1e-8 (verified: batch vs eachindex order yields different column c1/c2).
# (A lightly loaded fixture leaves columns at ACI minimum, growth-free and
# order-INSENSITIVE, which would mask the P0.)
function _build_individual_flat_plate(; soil = _SR.medium_sand, concrete = NWC_4000)
    skel  = gen_medium_office(60.0u"ft", 48.0u"ft", 12.0u"ft", 3, 2, 1)   # 3×2 bays, 1 story
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name               = "test_incremental_individual",
        floor              = FlatPlateOptions(method = DDM(), grouping = :individual),
        materials          = MaterialOptions(concrete = concrete, rebar = Rebar_60),
        loads              = GravityLoads(floor_LL = 125.0u"psf", roof_LL = 125.0u"psf",
                                          floor_SDL = 40.0u"psf", roof_SDL = 40.0u"psf"),
        max_iterations     = 5,
        skip_visualization = true,
        foundation_options = FoundationParameters(
            soil    = soil,
            options = _SR.FoundationOptions(strategy = :all_spread),
        ),
    )
    return struc, params
end

# Coarse independent oracle: runs the PRE-GRAPH stage loop directly (`build_pipeline`
# stage 1 = `size_slabs!` over ALL slabs, NOT `build_design_graph`'s per-slab nodes),
# so comparing `design_building` (fine graph) against it proves the per-slab
# decomposition reproduces the monolithic result. Mirrors verify_design_graph.jl.
function _run_coarse_reference(struc::BuildingStructure, params::DesignParameters)
    t_start = time()
    prepare!(struc, params)
    for stage in build_pipeline(params)
        stage.fn(struc)
        stage.needs_sync && sync_asap!(struc; params = params)
    end
    if params.uniform_column_sizing !== :off
        n_harmonized = _SS.harmonize_uniform_column_sizes!(struc, params)
        n_harmonized > 0 && sync_asap!(struc; params = params)
    end
    design = capture_design(struc, params; t_start = t_start)
    restore!(struc; geometry_is_centerline = params.geometry_is_centerline)
    return design
end

# Alternate-order slab oracle (Finding 1 P0 witness): runs the SAME pipeline as
# `_run_coarse_reference` but sizes the slabs in an EXPLICIT `order` instead of
# `eachindex`. `_col_cache=nothing` matches the fine graph, so ORDER is the ONLY
# variable between two calls with different orders (Finding 5: the cache is
# result-neutral). Used to prove that batch order ≠ eachindex order diverges
# (the P0), and that `design_building`'s eachindex fine graph matches eachindex.
function _design_with_slab_order(struc::BuildingStructure, params::DesignParameters,
                                 order::AbstractVector{<:Integer})
    t_start = time()
    prepare!(struc, params)
    floor_opts  = _SS.resolve_floor_options(params)
    column_opts = _SS._get_column_opts(params)
    # Stage 1 (slab sizing) in the GIVEN order — mirrors build_pipeline's stage-1
    # body (size_slabs! + update_slab_volumes!) minus the shared _col_cache.
    for sidx in order
        _SR.size_slab!(struc, sidx; options = floor_opts, column_opts = column_opts,
                       max_iterations = params.max_iterations, verbose = false,
                       _col_cache = nothing, fire_rating = params.fire_rating)
    end
    _SS.update_slab_volumes!(struc; options = floor_opts)
    sync_asap!(struc; params = params)
    # Remaining stages (members, foundations) exactly as build_pipeline emits them.
    for stage in build_pipeline(params)[2:end]
        stage.fn(struc)
        stage.needs_sync && sync_asap!(struc; params = params)
    end
    if params.uniform_column_sizing !== :off
        n_harmonized = _SS.harmonize_uniform_column_sizes!(struc, params)
        n_harmonized > 0 && sync_asap!(struc; params = params)
    end
    design = capture_design(struc, params; t_start = t_start)
    restore!(struc; geometry_is_centerline = params.geometry_is_centerline)
    return design
end

# Build + analyse a simply-supported 20 ft steel beam under a factored line load
# (mirrors scripts/runners/run_phase6_catalog_smoke.jl `_build_beam_struc`). This
# is the ISOLATED per-group `size_member_group!` path — the ONLY path that honors
# `member_group_overrides`. NOTE: this path is NOT reached by `design_building`
# (its member stage runs batched `size_beams!` / global `size_columns!` MIP /
# flat-plate `_reconcile_columns!`), so overrides are exercised here directly.
function _build_override_beam_struc()
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
    for seg in struc.segments          # continuous bracing → Lb≈0 (LTB not governing)
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

println("Testing DesignSession invalidation matrix (skip + comprehensive equivalence)...")

@testset "DesignSession invalidation matrix" begin

    @testset "base session == design_building" begin
        struc_ref, base = _build_flat_plate()
        ref = design_building(struc_ref, base)
        ref_inv = _extract_invariants(ref)

        struc_s, base_s = _build_flat_plate()
        session = DesignSession(struc_s, base_s)
        base_inv = _extract_invariants(base_design(session))

        for col in _INVARIANT_COLS
            @test _close(getproperty(ref_inv, col), getproperty(base_inv, col))
        end
        # Comprehensive per-member equivalence (P2 hardening) — not just the 15
        # aggregate scalars.
        ok_sig, bad_sig = _same_signature(_design_signature(ref),
                                          _design_signature(base_design(session)))
        @test ok_sig || error("base session signature mismatch at $bad_sig")
        # Fine topology: the single flat-plate slab is :slab_sizing_s1, so "all
        # sizing nodes" = every per-slab node ∪ {:members, :foundations}.
        @test Set(last_recomputed(session)) ==
              (_slab_set(_graph_of(session)) ∪ Set([NODE_MEMBERS, NODE_FOUNDATIONS]))
        @test isempty(last_restored(session))
    end

    # ── column-only: :beams dirties ONLY :members; :slab_sizing stays clean ──
    @testset "column-only (:beams) → only :members, slab clean" begin
        struc_bc, base_bc = _build_beam_column()
        session = DesignSession(struc_bc, base_bc)
        beams_variant = _SR.SteelBeamOptions(deflection_limit = 1/480)

        # (a) SKIP — frontier + actual recompute set exclude :slab_sizing.
        @test dirty_frontier(session; beams = beams_variant) == [NODE_MEMBERS]
        @test !requires_new_engine(session; beams = beams_variant)

        inc = redesign(session; beams = beams_variant)
        @test last_recomputed(session) == [NODE_MEMBERS]
        @test !any(_SS.is_slab_node_key, last_recomputed(session))
        # No foundations on the vault, so restored == exactly the slab nodes.
        @test Set(last_restored(session)) == _slab_set(_graph_of(session))

        # (b) EXACT — comprehensive per-member equivalence to a from-scratch design
        # with the SAME override (not just the 15 aggregate scalars).
        struc_ref, _ = _build_beam_column(beams = beams_variant)
        ref = design_building(struc_ref, with(base_bc; beams = beams_variant))
        ref_inv = _extract_invariants(ref)
        inc_inv = _extract_invariants(inc)
        for col in _INVARIANT_COLS
            @test _close(getproperty(ref_inv, col), getproperty(inc_inv, col))
        end
        ok_sig, bad_sig = _same_signature(_design_signature(ref), _design_signature(inc))
        @test ok_sig || error("column-only signature mismatch at $bad_sig")
    end

    # ── load-ish (foundation soil): dirties ONLY :foundations ────────────────
    @testset "load-ish (:foundation_options) → only :foundations, slab+members clean" begin
        struc_s, base = _build_flat_plate()
        session = DesignSession(struc_s, base)
        base_inv = _extract_invariants(base_design(session))

        soil_variant = FoundationParameters(
            soil    = _SR.soft_clay,
            options = _SR.FoundationOptions(strategy = :all_spread))

        # (a) SKIP.
        @test dirty_frontier(session; foundation_options = soil_variant) == [NODE_FOUNDATIONS]
        @test !requires_new_engine(session; foundation_options = soil_variant)

        inc = redesign(session; foundation_options = soil_variant)
        @test last_recomputed(session) == [NODE_FOUNDATIONS]
        @test !any(_SS.is_slab_node_key, last_recomputed(session))
        @test !(NODE_MEMBERS in last_recomputed(session))
        @test Set(last_restored(session)) == (_slab_set(_graph_of(session)) ∪ Set([NODE_MEMBERS]))

        # (b) EXACT — comprehensive per-member equivalence to a from-scratch design
        # with the SAME soil (not just the 15 aggregate scalars).
        struc_ref, _ = _build_flat_plate(soil = _SR.soft_clay)
        ref = design_building(struc_ref, with(base; foundation_options = soil_variant))
        ref_inv = _extract_invariants(ref)
        inc_inv = _extract_invariants(inc)
        for col in _INVARIANT_COLS
            @test _close(getproperty(ref_inv, col), getproperty(inc_inv, col))
        end
        ok_sig, bad_sig = _same_signature(_design_signature(ref), _design_signature(inc))
        @test ok_sig || error("load-ish signature mismatch at $bad_sig")

        # Slab/column invariants unchanged vs base (only the soil changed).
        @test _close(inc_inv.h_m, base_inv.h_m)
        @test _close(inc_inv.col_max_in, base_inv.col_max_in)
        @test _close(inc_inv.punch_ratio, base_inv.punch_ratio)
        @test _close(inc_inv.As_total_in2, base_inv.As_total_in2)

        # `vary` (NamedTuple form) is equivalent to `redesign`. Run it on a FRESH
        # session so the frontier is genuinely [:foundations]: the `session` above
        # was already varied to `soil_variant`, so re-applying the identical
        # variation to it is a correct idempotent no-op (recomputes Symbol[]), which
        # would NOT exercise the [:foundations] recompute this check intends.
        struc_s2, base2 = _build_flat_plate()
        session2 = DesignSession(struc_s2, base2)
        inc2 = vary(session2, (; foundation_options = soil_variant))
        @test last_recomputed(session2) == [NODE_FOUNDATIONS]
        @test _close(_extract_invariants(inc2).fdn_max_util, inc_inv.fdn_max_util)
        ok_sig2, bad_sig2 = _same_signature(_design_signature(inc2), _design_signature(inc))
        @test ok_sig2 || error("vary/redesign signature mismatch at $bad_sig2")
    end

    # ── load_combinations on a VAULT (structural-effects) → non-prepare, refreshed ──
    # `:load_combinations` is NON-prepare-affecting: `sync_asap!` refreshes every
    # load MAGNITUDE it drives — INCLUDING the vault-thrust edge line loads
    # `to_asap!` bakes from `governing_combo(params)` (VaultResult → LateralThrust).
    # The vault is the case that guards the P1: base `[strength_1_4D]` (D=1.4, L=0)
    # → varied `[strength_1_2D_1_6L]` (D=1.2, L=1.6) changes `first()`/
    # `governing_combo`, hence the baked thrust. Without the sync-path refresh the
    # incremental thrust would stay frozen at 1.4D and the equivalence check below
    # would FAIL — exactly the reverted-fix regression this case exists to catch.
    @testset "load_combinations on VAULT → [:slab_sizing,:members], output-equivalent" begin
        struc_lc, base_lc0 = _build_beam_column()
        base_lc = with(base_lc0; load_combinations = [_SR.strength_1_4D])
        session = DesignSession(struc_lc, base_lc)
        lc_variant = [_SR.strength_1_2D_1_6L]

        # (a) SKIP — non-prepare; frontier + recompute set are exactly the
        # load-magnitude-dependent sizing nodes (every per-slab node, then :members).
        @test !requires_new_engine(session; load_combinations = lc_variant)
        @test dirty_frontier(session; load_combinations = lc_variant) ==
              vcat(_slab_keys(_graph_of(session)), [NODE_MEMBERS])

        inc = redesign(session; load_combinations = lc_variant)
        @test Set(last_recomputed(session)) ==
              (_slab_set(_graph_of(session)) ∪ Set([NODE_MEMBERS]))

        # (b) EXACT — comprehensive per-member equivalence to a from-scratch design
        # at the SAME new combos (the sync refresh rebuilds the vault thrust so the
        # incremental model matches the from-scratch one).
        struc_ref, base_ref0 = _build_beam_column()
        ref = design_building(struc_ref, with(base_ref0; load_combinations = lc_variant))
        ref_inv = _extract_invariants(ref)
        inc_inv = _extract_invariants(inc)
        for col in _INVARIANT_COLS
            @test _close(getproperty(ref_inv, col), getproperty(inc_inv, col))
        end
        ok_sig, bad_sig = _same_signature(_design_signature(ref), _design_signature(inc))
        @test ok_sig || error("load_combinations (vault) signature mismatch at $bad_sig")

        # The variation must be a REAL change (base-combo vs varied-combo differ),
        # so the equivalence above is not a coincidental frozen-thrust no-op.
        struc_base_ref, base_base_ref0 = _build_beam_column()
        ref_base = design_building(struc_base_ref, with(base_base_ref0; load_combinations = [_SR.strength_1_4D]))
        diff_ok, _ = _same_signature(_design_signature(ref_base), _design_signature(ref))
        @test !diff_ok
    end

    # ── prepare-affecting variations: the guard must fire (fresh session req.) ──
    @testset "prepare-affecting overrides require a fresh session" begin
        struc_s, base = _build_flat_plate()
        session = DesignSession(struc_s, base)

        # slab-type swap (:floor).
        floor_variant = FlatSlabOptions()
        @test requires_new_engine(session; floor = floor_variant)
        @test Set(dirty_frontier(session; floor = floor_variant)) ==
              (_slab_set(_graph_of(session)) ∪ Set([NODE_MEMBERS, NODE_FOUNDATIONS]))
        @test_throws ArgumentError redesign(session; floor = floor_variant)

        # concrete strength (:materials).
        mat_variant = MaterialOptions(concrete = NWC_6000, rebar = Rebar_60)
        @test requires_new_engine(session; materials = mat_variant)
        @test_throws ArgumentError redesign(session; materials = mat_variant)

        # geometry (:geometry_is_centerline).
        @test requires_new_engine(session; geometry_is_centerline = true)
        @test_throws ArgumentError redesign(session; geometry_is_centerline = true)

        # pattern_loading (:none → :checkerboard) — a BUILD-TIME load-object
        # decision sync_asap! cannot retrofit (see scheduler.jl audit comment). It
        # must be prepare-affecting: the guard must fire rather than silently
        # returning an UNPATTERNED, unconservative design.
        @test requires_new_engine(session; pattern_loading = :checkerboard)
        # It is NOT in any node param slice (it lives in PREPARE_AFFECTING_FIELDS),
        # so the slice-based frontier is empty — the guard, not the frontier, is
        # what protects against this change.
        @test isempty(dirty_frontier(session; pattern_loading = :checkerboard))
        @test_throws ArgumentError redesign(session; pattern_loading = :checkerboard)

        # The documented remedy: a fresh session at the new geometry designs cleanly.
        struc_geo, params_geo = _build_flat_plate(geometry_is_centerline = true)
        session_geo = DesignSession(struc_geo, params_geo)
        @test !isempty(base_design(session_geo).slabs)
    end

    # ── Prove the pattern_loading guard protects a REAL difference (not a no-op) ──
    # If :checkerboard produced the same demands as :none, the guard would be
    # masking a harmless no-op. It does NOT. Discrete member sizing can round out a
    # small demand change, so we prove it at the level the P0 actually endangers —
    # the GOVERNING MEMBER MOMENT. Patterned (checkerboard) live load envelopes
    # member forces strictly UPWARD versus the :none baseline (classic
    # continuous-member result; ACI 318-11 §13.7.6): max positive span moment
    # occurs under alternate-span loading, not all-spans loaded. An engine that
    # silently skipped patterning over a :none baseline would UNDER-predict these
    # demands — the unconservative outcome the guard prevents. (The vault routes
    # slab pressure through thrust line-loads, so patterns don't apply there —
    # hence a flat plate here, matching test/analyze/test_pattern_loading.jl.)
    @testset "pattern_loading raises governing member moment (guard protects real change)" begin
        forces_none = _prepared_frame_forces(pattern_loading = :none)
        forces_pat  = _prepared_frame_forces(pattern_loading = :checkerboard)
        @test length(forces_none) == length(forces_pat)

        upward = true       # every DOF enveloped ≥ baseline (within numerical tol)
        n_strict = 0        # DOFs where patterning is STRICTLY higher (real change)
        gov_none = 0.0; gov_pat = 0.0
        for (fn, fp) in zip(forces_none, forces_pat)
            for k in eachindex(fn)
                a = abs(fn[k]); b = abs(fp[k])
                gov_none = max(gov_none, a); gov_pat = max(gov_pat, b)
                b >= a - 1e-6 || (upward = false)
                b > a + 1e-3 && (n_strict += 1)
            end
        end
        @test upward                       # patterning never lowers a demand
        @test n_strict > 0                 # and strictly raises at least one → real change
        @test gov_pat >= gov_none - 1e-6   # governing demand is at least as high
    end

    # ── EXACT-FIRST DECOMPOSITION: fine per-slab nodes == coarse size_slabs! ──────
    # `design_building` executes the FINE per-slab graph; `_run_coarse_reference`
    # runs the monolithic `size_slabs!` stage loop. Equal comprehensive signatures
    # ⇒ decomposing slab sizing into per-slab nodes reproduces the coarse result
    # byte-for-byte (rtol=1e-8). After Finding 1 EVERY slab node is a root in ONE
    # topological level ordered by `eachindex`, so both the 3-story flat plate
    # (3 slabs) and the vault (4 slabs) exercise a multi-NODE single level; the
    # single post-level barrier sync matches the coarse single post-slab-stage sync.
    @testset "exact-first decomposition (fine per-slab graph == coarse size_slabs!)" begin
        struc_fine, ms_params = _build_multistory_flat_plate()
        fine = design_building(struc_fine, ms_params)
        struc_coarse, _ = _build_multistory_flat_plate()
        coarse = _run_coarse_reference(struc_coarse, ms_params)
        @test length(fine.slabs) >= 2                # multi-node level is meaningful
        ok_ms, bad_ms = _same_signature(_design_signature(coarse), _design_signature(fine))
        @test ok_ms || error("3-slab flat plate fine≠coarse at $bad_ms")

        struc_vf, v_params = _build_thrust_vault()
        fine_v = design_building(struc_vf, v_params)
        struc_vc, _ = _build_thrust_vault()
        coarse_v = _run_coarse_reference(struc_vc, v_params)
        @test length(fine_v.slabs) >= 2              # multi-node decomposition is meaningful
        ok_v, bad_v = _same_signature(_design_signature(coarse_v), _design_signature(fine_v))
        @test ok_v || error("vault fine≠coarse at $bad_v")
    end

    # ── FINDING 1 (P0, exact-first): slab processing ORDER == eachindex, NOT batch ─
    # A multi-bay `grouping=:individual` flat plate whose slabs SHARE columns is the
    # P0 trigger: `slab_parallel_batches` (greedy conflict coloring) reorders the
    # slabs vs `eachindex`, and because flat-plate slab sizing reads LIVE shared
    # column c1/c2 (monotonic growth), that reorder changes per-slab results. This
    # test (a) PROVES the fixture is a genuine trigger (multi-batch, shared column
    # across batches, batch order ≠ eachindex), (b) REPRODUCES the divergence
    # (sizing in batch order ≠ sizing in eachindex order), and (c) proves the FIX:
    # `design_building`'s fine graph is byte-identical (rtol=1e-8) to the
    # single-threaded coarse `size_slabs!` reference AND orders its slab nodes in
    # one `eachindex`-ordered level with a single barrier sync.
    @testset "exact-first slab order (individual multi-bay flat plate == eachindex)" begin
        # (a) Fixture is a genuine P0 trigger.
        struc_probe, params_probe = _build_individual_flat_plate()
        prepare!(struc_probe, params_probe)
        n = length(struc_probe.slabs)
        batches = struc_probe.slab_parallel_batches
        @test n >= 2                                          # multi-bay → multiple slabs
        @test length(batches) >= 2                            # coloring splits into ≥2 batches
        batch_order = reduce(vcat, batches)
        @test sort(batch_order) == collect(1:n)               # a valid permutation of all slabs
        @test batch_order != collect(1:n)                     # …that REORDERS vs eachindex
        # ≥1 column shared across two DIFFERENT batches ⇒ order is result-affecting.
        _cols_of(sidx) = Set(_SS._slab_supporting_columns(struc_probe, sidx))
        shared_across_batches = false
        for bi in 1:length(batches), bj in (bi+1):length(batches)
            for si in batches[bi], sj in batches[bj]
                isempty(intersect(_cols_of(si), _cols_of(sj))) || (shared_across_batches = true)
            end
        end
        @test shared_across_batches

        # (b) REPRODUCE the P0: batch order diverges from eachindex order.
        struc_e, params_e = _build_individual_flat_plate()
        d_each  = _design_with_slab_order(struc_e, params_e, collect(1:n))
        struc_b, params_b = _build_individual_flat_plate()
        d_batch = _design_with_slab_order(struc_b, params_b, batch_order)
        diverges, _ = _same_signature(_design_signature(d_each), _design_signature(d_batch))
        @test !diverges                # batch order ≠ eachindex order → the P0 is real

        # (c) FIX: design_building (fine graph) == single-threaded coarse eachindex.
        struc_fine, params_fine = _build_individual_flat_plate()
        fine = design_building(struc_fine, params_fine)
        struc_coarse, params_coarse = _build_individual_flat_plate()
        coarse = _run_coarse_reference(struc_coarse, params_coarse)
        ok, bad = _same_signature(_design_signature(coarse), _design_signature(fine))
        @test ok || error("individual flat plate fine≠coarse (order P0) at $bad")
        # And the fine graph matches the eachindex ORACLE too (isolates order alone).
        ok_e, bad_e = _same_signature(_design_signature(d_each), _design_signature(fine))
        @test ok_e || error("individual flat plate fine≠eachindex-oracle at $bad_e")

        # Fine graph topology: slab nodes ordered by eachindex in ONE level.
        session = DesignSession(struc_fine, params_fine)
        g = _graph_of(session)
        @test _slab_keys(g) == [_SS.slab_node_key(i) for i in 1:n]   # ascending slab_idx
        @test _slab_sync_count(g) == 1                               # single barrier sync
    end

    # ── MULTI-NODE-LEVEL: a global slab-param dirties ALL slab nodes, ONE sync ────
    # 3-story flat plate → all 3 per-slab nodes share ONE topological level (single
    # `slab_parallel_batches` batch). A global slab-affecting param (`:load_combinations`,
    # non-prepare) dirties EVERY slab node; the scheduler recomputes them all in that
    # one level (one barrier `sync_asap!`) and the result is output-equivalent to a
    # from-scratch design_building at the new combos. This is the ACHIEVABLE multi-node
    # behavior (all siblings move together); dirtying exactly ONE sibling is DEFERRED.
    @testset "multi-node-level: global slab-param recomputes all slab nodes, one barrier sync" begin
        struc_probe, base_probe = _build_multistory_flat_plate()
        session_probe = DesignSession(struc_probe, base_probe)
        g_probe = _graph_of(session_probe)
        @test length(_slab_set(g_probe)) >= 2        # genuinely multi-node
        @test _slab_sync_count(g_probe) == 1         # all slab nodes in ONE level → one sync

        base_combo = with(base_probe; load_combinations = [_SR.strength_1_4D])
        struc_ml, _ = _build_multistory_flat_plate()
        session_ml = DesignSession(struc_ml, base_combo)
        g_ml = _graph_of(session_ml)
        variant = [_SR.strength_1_2D_1_6L]

        @test !requires_new_engine(session_ml; load_combinations = variant)
        inc = redesign(session_ml; load_combinations = variant)
        @test _slab_set(g_ml) ⊆ Set(last_recomputed(session_ml))   # ALL slab nodes recomputed

        struc_ref, _ = _build_multistory_flat_plate()
        ref = design_building(struc_ref, with(base_combo; load_combinations = variant))
        ref_inv = _extract_invariants(ref); inc_inv = _extract_invariants(inc)
        for col in _INVARIANT_COLS
            @test _close(getproperty(ref_inv, col), getproperty(inc_inv, col))
        end
        ok_sig, bad_sig = _same_signature(_design_signature(ref), _design_signature(inc))
        @test ok_sig || error("multi-node-level signature mismatch at $bad_sig")
    end

    # ── EXACT-FIRST GUARD (P1): a partial-slab target is REJECTED ────────────────
    # Repro of the critic P1: fine per-slab nodes are edgeless roots, so
    # `run_target!(engine, params; target = slab_node_key(2))` would memoize ONLY
    # node 2 (its transitive closure is {slab_2}). A later run-to-terminal would
    # then classify a MIXED clean/dirty slab level and take the divergent partial-
    # restore overlay — node 2 having been sized in the WRONG monotonic column-
    # growth context vs from-scratch. The guard in `run_target!` makes that memo
    # state UNREPRESENTABLE: any target whose closure covers a STRICT SUBSET of the
    # slab roots is rejected. Here we assert the clean rejection (Option A) AND that
    # legitimate full runs (terminal / :members / no target) still work and stay
    # output-equivalent to a from-scratch design_building. Pre-fix this scenario
    # DIVERGED silently; post-fix it cannot even be expressed.
    @testset "exact-first guard (P1): partial-slab target rejected, full run still exact" begin
        struc, params = _build_multistory_flat_plate()
        engine = _SS.prepare_engine(struc, params)   # prepare! populates slabs + graph
        slab_roots = _slab_set(engine.graph)
        @test length(slab_roots) >= 3                        # ≥3 slabs share columns

        # A bare single-slab target (strict subset of slab roots) → clean rejection.
        @test_throws ArgumentError _SS.run_target!(engine, params;
                                                   target = _SS.slab_node_key(2))
        # A two-of-three slab set is still a strict subset → also rejected (only
        # meaningful when there are ≥3 slabs, guaranteed above).
        @test_throws ArgumentError _SS.run_target!(engine, params;
                                                   target = _SS.slab_node_key(1))

        # The throw leaves the engine usable (guard fires before any mutation):
        # a legitimate FULL run (default target = terminal) recomputes every slab
        # root and reproduces from-scratch design_building byte-for-byte.
        inc = _SS.redesign_incremental!(engine, params)
        @test slab_roots ⊆ Set(_SS.last_recomputed(engine))   # ALL slab roots run
        struc_ref, _ = _build_multistory_flat_plate()
        ref = design_building(struc_ref, params)
        ok_full, bad_full = _same_signature(_design_signature(ref), _design_signature(inc))
        @test ok_full || error("full-run incremental ≠ from-scratch at $bad_full")

        # Targeting :members (which depends on ALL slab roots) is a legitimate full
        # slab coverage → NOT rejected.
        struc2, params2 = _build_multistory_flat_plate()
        engine2 = _SS.prepare_engine(struc2, params2)
        @test _SS.run_target!(engine2, params2; target = NODE_MEMBERS) isa Tuple
    end

    # ── THRUST-GOVERNED VAULT: incremental/graph path == from-scratch ────────────
    # A larger-span vault whose baked LateralThrust edge loads drive the steel
    # members. The base session run (fine graph + level barriers) must reproduce
    # from-scratch design_building, and a `:load_combinations` variation (which
    # changes the governing combo → the baked thrust) must stay output-equivalent —
    # i.e. the vault thrust is REFRESHED on the incremental sync path, not frozen.
    @testset "thrust-governed vault: incremental == from-scratch (base + thrust-combo variation)" begin
        struc_tv, base_tv0 = _build_thrust_vault()
        base_tv = with(base_tv0; load_combinations = [_SR.strength_1_4D])
        session_tv = DesignSession(struc_tv, base_tv)

        struc_tv_ref, _ = _build_thrust_vault()
        ref_base = design_building(struc_tv_ref, base_tv)
        ok_b, bad_b = _same_signature(_design_signature(ref_base),
                                      _design_signature(base_design(session_tv)))
        @test ok_b || error("thrust vault base session ≠ design_building at $bad_b")

        variant = [_SR.strength_1_2D_1_6L]
        inc = redesign(session_tv; load_combinations = variant)
        @test Set(last_recomputed(session_tv)) ==
              (_slab_set(_graph_of(session_tv)) ∪ Set([NODE_MEMBERS]))
        struc_tv_ref2, base_tv_ref20 = _build_thrust_vault()
        ref = design_building(struc_tv_ref2, with(base_tv_ref20; load_combinations = variant))
        ok_v, bad_v = _same_signature(_design_signature(ref), _design_signature(inc))
        @test ok_v || error("thrust vault variation incremental ≠ from-scratch at $bad_v")
        # The variation is a REAL change (base vs varied differ) — not a frozen-thrust no-op.
        diff_ok, _ = _same_signature(_design_signature(ref_base), _design_signature(ref))
        @test !diff_ok
    end

    # ── DEFERRAL NOTE (documented invariant of this test) ────────────────────────
    # True per-slab / per-beam-group INDEPENDENT variation — dirtying EXACTLY ONE
    # sibling node while its peers stay clean — is NOT achievable under the current
    # GLOBAL-parameter model: a slab-affecting field is read identically by every
    # per-slab node (so it dirties them ALL, above) and a non-slab field dirties
    # NONE. A mixed clean/dirty slab level needs per-group OVERRIDE params (Option A),
    # which adds new safety-critical DesignParameters fields + a prepare-affecting
    # classification and is DEFERRED pending user sign-off (per code-accuracy.mdc —
    # do not guess new mechanics). Because no end-to-end variation produces a MIXED
    # slab level, the partial-restore path (`restore_slab_node_writes!` /
    # `_adopt_larger_column!`) is UNREACHABLE by the end-to-end cases above; it is
    # instead covered by the DIRECT unit tests in the "partial per-slab restore"
    # testset below (Findings 3 + 4). It is deliberately NOT faked here with a
    # prepare-affecting change.

    # ── FINDING 2 (P1): traced design_building preserves the legacy slab envelope ─
    # The fine per-slab graph emits per-node `size_slab!` events; Finding 2 restores
    # the legacy `stage_1_slabs` + `size_slabs!` enter/decision/exit ENVELOPE around
    # them so a traced `design_building` is byte-identical to the pre-Run-3 sequence.
    # Oracle = the legacy coarse stage loop with the SAME TraceCollector wiring.
    @testset "solver_trace envelope (Finding 2): design_building == legacy slab trace" begin
        # Compare the full ordered (layer, stage, element_id, event_type) sequence,
        # restricted to the slab-stage envelope + per-slab events (timestamps and
        # the data payload are excluded — timing is nondeterministic).
        _slab_stage_key(ev) =
            (ev.stage in ("size_slabs!", "size_slab!")) ||
            (ev.stage == "build_pipeline" && ev.element_id == "stage_1_slabs")
        _seq(events) = [(ev.layer, ev.stage, ev.element_id, ev.event_type)
                        for ev in events if _slab_stage_key(ev)]

        # Fine-graph trace (design_building routes ALL slab sizing through the graph).
        struc_g, params_g = _build_multistory_flat_plate()
        tc_g = _SR.TraceCollector()
        design_building(struc_g, params_g; tc = tc_g)
        seq_graph = _seq(tc_g.events)

        # Legacy coarse-loop oracle with identical trace wiring.
        struc_c, params_c = _build_multistory_flat_plate()
        tc_c = _SR.TraceCollector()
        prepare!(struc_c, params_c)
        for stage in build_pipeline(params_c; tc = tc_c)
            stage.fn(struc_c)
            stage.needs_sync && sync_asap!(struc_c; params = params_c)
        end
        seq_legacy = _seq(tc_c.events)

        @test !isempty(seq_graph)
        @test seq_graph == seq_legacy
        # Envelope present and correctly bracketed.
        @test (:pipeline, "build_pipeline", "stage_1_slabs", :enter) in seq_graph
        @test (:slab, "size_slabs!", "", :enter) in seq_graph
        @test (:slab, "size_slabs!", "", :decision) in seq_graph
        @test (:slab, "size_slabs!", "", :exit) in seq_graph
        @test (:pipeline, "build_pipeline", "stage_1_slabs", :exit) in seq_graph
        # One `size_slab!` :enter per slab, nested inside the envelope.
        n_slab = length(struc_g.slabs)
        @test count(==((:slab, "size_slab!", "", :enter)), seq_graph) == 0  # element_id is the slab idx, not ""
        @test count(t -> t[2] == "size_slab!" && t[4] == :enter, seq_graph) == n_slab
        # The size_slabs! :enter opens before the first size_slab!, :exit closes after the last.
        i_open  = findfirst(==((:slab, "size_slabs!", "", :enter)), seq_graph)
        i_close = findfirst(==((:slab, "size_slabs!", "", :exit)), seq_graph)
        i_first_slab = findfirst(t -> t[2] == "size_slab!" && t[4] == :enter, seq_graph)
        i_last_slab  = findlast(t -> t[2] == "size_slab!" && t[4] == :exit,  seq_graph)
        @test i_open < i_first_slab
        @test i_last_slab < i_close
    end

    # ── FINDINGS 3 + 4: DIRECT unit tests for the partial-restore merge helpers ───
    # `restore_slab_node_writes!` and `_adopt_larger_column!` are the mixed-level
    # overlay path. They are UNREACHABLE end-to-end under the global-parameter model
    # (see the deferral note above), so they are covered here directly.
    @testset "partial per-slab restore (Findings 3 + 4): merge helpers" begin

        # ---- _adopt_larger_column! (duck-typed on c1/c2/shape/base.section/volumes;
        #      the lightweight `_FakeCol`/`_FakeBase`/`_mkcol` are defined at file top).
        @testset "_adopt_larger_column!: monotonic max-merge on dims" begin
            # Snapshot LARGER → dst grows and adopts snapshot section/shape/volumes.
            dcol = _mkcol(12.0, 12.0, :secA; shape = :rectangular, vol = [1.0])
            scol = _mkcol(16.0, 14.0, :secB; shape = :circular,   vol = [2.0])
            _SS._adopt_larger_column!(dcol, scol)
            @test dcol.c1 == 16.0 && dcol.c2 == 14.0     # grew to the larger dims
            @test dcol.base.section == :secB             # adopted larger section
            @test dcol.shape == :circular
            @test dcol.base.volumes == [2.0]
            @test dcol.base.volumes !== scol.base.volumes  # deep-copied, not aliased

            # Snapshot SMALLER → dst keeps its own (larger) dims AND its own section
            # (must NOT attach the snapshot's smaller section to larger dims).
            dcol2 = _mkcol(20.0, 18.0, :secBig; shape = :rectangular, vol = [9.0])
            scol2 = _mkcol(12.0, 12.0, :secSmall; shape = :circular,  vol = [1.0])
            _SS._adopt_larger_column!(dcol2, scol2)
            @test dcol2.c1 == 20.0 && dcol2.c2 == 18.0   # unchanged (never shrinks)
            @test dcol2.base.section == :secBig          # kept its own section
            @test dcol2.shape == :rectangular
            @test dcol2.base.volumes == [9.0]
        end

        @testset "_adopt_larger_column!: Finding 4 (P2a) — dimensional-TIE non-downgrade" begin
            # Tie, snapshot section is HEAVIER (more steel) → adopt it (non-downgrade).
            dcol = _mkcol(14.0, 14.0, _mksect(:stale, 1.0); shape = :rectangular, vol = [1.0])
            scol = _mkcol(14.0, 14.0, _mksect(:fresh, 2.0); shape = :circular,    vol = [3.0])
            _SS._adopt_larger_column!(dcol, scol)
            @test dcol.c1 == 14.0 && dcol.c2 == 14.0     # dims unchanged (tie)
            @test dcol.base.section.id == :fresh         # heavier section adopted
            @test dcol.shape == :circular
            @test dcol.base.volumes == [3.0]
            @test dcol.base.volumes !== scol.base.volumes  # deep-copied

            # REVERSE DIRECTION (P2a): dcol already holds the FRESH HEAVIER section,
            # snapshot is a STALE LIGHTER one on a tie → must NOT downgrade.
            dcol_h = _mkcol(14.0, 14.0, _mksect(:heavy, 3.0); shape = :circular,    vol = [7.0])
            scol_l = _mkcol(14.0, 14.0, _mksect(:light, 1.0); shape = :rectangular, vol = [2.0])
            _SS._adopt_larger_column!(dcol_h, scol_l)
            @test dcol_h.base.section.id == :heavy       # kept the heavier section
            @test dcol_h.shape == :circular              # kept its own shape
            @test dcol_h.base.volumes == [7.0]           # kept its own volumes

            # Tie, EQUAL steel area (a_new == a_old) → adopt permitted (≥, no downgrade).
            dcol_eq = _mkcol(14.0, 14.0, _mksect(:a, 2.0); shape = :rectangular, vol = [1.0])
            scol_eq = _mkcol(14.0, 14.0, _mksect(:b, 2.0); shape = :circular,    vol = [4.0])
            _SS._adopt_larger_column!(dcol_eq, scol_eq)
            @test dcol_eq.base.section.id == :b
            @test dcol_eq.base.volumes == [4.0]

            # Tie but steel area UNKNOWN (symbol sections, no `As_total`) → cannot
            # prove non-downgrade → conservatively KEEP dcol.
            dcol_u = _mkcol(14.0, 14.0, :stale; shape = :rectangular, vol = [1.0])
            scol_u = _mkcol(14.0, 14.0, :fresh; shape = :circular,    vol = [3.0])
            _SS._adopt_larger_column!(dcol_u, scol_u)
            @test dcol_u.base.section == :stale          # kept (proxy unavailable)
            @test dcol_u.shape == :rectangular
            @test dcol_u.base.volumes == [1.0]

            # Dims tie AND section identical (===) → no-op (harmless).
            same = _mksect(:same, 2.0)
            dcol2 = _mkcol(14.0, 14.0, same; shape = :rectangular, vol = [1.0])
            scol2 = _mkcol(14.0, 14.0, same; shape = :rectangular, vol = [1.0])
            _SS._adopt_larger_column!(dcol2, scol2)
            @test dcol2.base.section === same
        end

        @testset "_adopt_larger_column!: INCOMPARABLE dims never mismatch (P2a)" begin
            # dst=(10,20), src=(12,18): neither dominates. Component-wise max (12,20)
            # matches NEITHER section, so we KEEP dcol's own (dims, section) pair
            # rather than grow one dim while shrinking the other or attach a section
            # that matches no footprint.
            dcol = _mkcol(10.0, 20.0, _mksect(:dst, 5.0); shape = :rectangular, vol = [1.0])
            scol = _mkcol(12.0, 18.0, _mksect(:src, 9.0); shape = :circular,    vol = [2.0])
            _SS._adopt_larger_column!(dcol, scol)
            @test dcol.c1 == 10.0 && dcol.c2 == 20.0     # unchanged (no shrink on c2)
            @test dcol.base.section.id == :dst           # kept — no dims/section mismatch
            @test dcol.shape == :rectangular
            @test dcol.base.volumes == [1.0]

            # Symmetric incomparable case (dst=(12,18), src=(10,20)) → also keep dcol.
            dcol2 = _mkcol(12.0, 18.0, _mksect(:dst2, 5.0); shape = :rectangular, vol = [3.0])
            scol2 = _mkcol(10.0, 20.0, _mksect(:src2, 9.0); shape = :circular,    vol = [4.0])
            _SS._adopt_larger_column!(dcol2, scol2)
            @test dcol2.c1 == 12.0 && dcol2.c2 == 18.0
            @test dcol2.base.section.id == :dst2
        end

        # ---- restore_slab_node_writes! (needs real BuildingStructures) -----------
        @testset "restore_slab_node_writes!: overlay + max-merge + no sibling clobber" begin
            # Build a fully designed multi-slab structure to snapshot from.
            struc, params = _build_multistory_flat_plate()
            prepare!(struc, params)
            for stage in build_pipeline(params)
                stage.fn(struc)
                stage.needs_sync && sync_asap!(struc; params = params)
            end
            @test length(struc.slabs) >= 2

            src = _SS.capture_node_state(struc)         # deep, independent snapshot
            dst = _SS.restore_node_state(src)           # independent working copy
            sidx = 1
            other = 2
            cols = _SS._slab_supporting_columns(dst, sidx)
            @test !isempty(cols)

            # `Slab.result` is non-nullable, so we perturb dst by SWAPPING slab 1's
            # result/volumes with a distinct object (slab 2's, deep-copied) and
            # zeroing its cells' loads; the overlay must restore slab 1 to src.
            dst.slabs[sidx].result  = deepcopy(dst.slabs[other].result)
            dst.slabs[sidx].volumes = deepcopy(dst.slabs[other].volumes)
            @test dst.slabs[sidx].result !== src.slabs[sidx].result   # genuinely perturbed
            for ci in dst.slabs[sidx].cell_indices
                (ci >= 1 && ci <= length(dst.cells)) || continue
                dst.cells[ci].self_weight = zero(dst.cells[ci].self_weight)
                dst.cells[ci].live_load   = zero(dst.cells[ci].live_load)
            end
            # Sibling slab 2 must be left untouched by the overlay.
            sib_result_before = dst.slabs[other].result
            # Shrink slab 1's supporting columns so the max-merge must grow them back.
            for ci in cols
                c = dst.columns[ci]
                isnothing(c.c1) && continue
                c.c1 = c.c1 / 2
                c.c2 = c.c2 / 2
            end
            # Choose one supporting column and make dst STRICTLY LARGER than src to
            # prove the max-merge RETAINS the larger sibling size.
            big_ci = first(cols)
            src_c1 = src.columns[big_ci].c1
            if !isnothing(src_c1)
                dst.columns[big_ci].c1 = src_c1 * 3
                dst.columns[big_ci].c2 = src.columns[big_ci].c2 * 3
            end
            dst_big_c1_before = dst.columns[big_ci].c1

            _SS.restore_slab_node_writes!(dst, src, sidx, cols)

            # Overlay: slab 1's owned outputs restored from src.
            @test dst.slabs[sidx].result === src.slabs[sidx].result
            @test dst.slabs[sidx].volumes === src.slabs[sidx].volumes
            for ci in src.slabs[sidx].cell_indices
                (ci >= 1 && ci <= length(dst.cells)) || continue
                @test dst.cells[ci].self_weight == src.cells[ci].self_weight
                @test dst.cells[ci].live_load   == src.cells[ci].live_load
            end
            # Max-merge: the shrunk columns grew back up to at least src size…
            for ci in cols
                ci == big_ci && continue
                sc = src.columns[ci]
                isnothing(sc.c1) && continue
                @test dst.columns[ci].c1 >= sc.c1
                @test dst.columns[ci].c2 >= sc.c2
            end
            # …and the deliberately-larger column RETAINED its larger size (monotonic).
            @test dst.columns[big_ci].c1 == dst_big_c1_before

            # No sibling clobber: slab 2 untouched (identity preserved).
            @test dst.slabs[other].result === sib_result_before
        end

        @testset "restore_slab_node_writes!: no aliasing into the snapshot" begin
            struc, params = _build_multistory_flat_plate()
            prepare!(struc, params)
            for stage in build_pipeline(params)
                stage.fn(struc)
                stage.needs_sync && sync_asap!(struc; params = params)
            end
            src = _SS.capture_node_state(struc)
            dst = _SS.restore_node_state(src)
            sidx = 1
            cols = _SS._slab_supporting_columns(dst, sidx)
            # dst is a deepcopy of src, so supporting-column dims TIE while their
            # sections are distinct objects → the overlay takes the Finding 4
            # section-adoption path, which deep-copies volumes.
            _SS.restore_slab_node_writes!(dst, src, sidx, cols)
            # The column volumes overlaid via _adopt_larger_column! are deep-copied,
            # so the dst working copy never aliases the src snapshot's volumes.
            for ci in cols
                dcol = dst.columns[ci]; scol = src.columns[ci]
                (isnothing(dcol.base.volumes) || isnothing(scol.base.volumes)) && continue
                @test dcol.base.volumes !== scol.base.volumes
            end
        end
    end

    # =========================================================================
    # Run 4 / Phase B — member_group_overrides
    # =========================================================================
    # SCOPE: Phase B makes `member_group_overrides` LIVE for the HONORABLE case —
    # an EFFECTIVE override on a STEEL BEAM member group on a beam/column floor,
    # threaded into the batched `size_beams!` → `optimize_discrete` solve as a
    # per-group feasible-narrowing mask (`_beam_override_union_and_feasible`). Such
    # overrides DO change the target group's result (testset (vii)) while leaving
    # every other group byte-identical. UN-HONORABLE effective targets are still
    # refused fail-loud (ArgumentError, message-pinned): flat-plate/flat-slab
    # floors, non-steel-beam sizing, `n_max_sections > 0`, and column/strut groups.
    # These tests prove: the isolated `size_member_group!` mechanism (non-vacuous),
    # the byte-identical happy path (empty / vacuous), the fail-loud guard on
    # un-honorable targets, and (vii) the LIVE honorable steel-beam-group case.
    @testset "member_group_overrides (Run 4 / Phase B)" begin
        # A restricted 2-section catalog. Both W-shapes are much heavier than the
        # free optimum for this beam, so a section drawn from it proves the
        # override was honored; the lighter of the two (W21X44) is the pick.
        custom2 = [W("W21X44"), W("W24X68")]
        custom_names = Set(s.name for s in custom2)

        # (iv) DesignParameters default: member_group_overrides is empty.
        @testset "default is empty" begin
            @test isempty(DesignParameters().member_group_overrides)
            @test DesignParameters().member_group_overrides isa
                  Dict{UInt64, MemberGroupSizingOverride}
        end

        # (iii) resolve_member_group_override: present gid → entry, absent → nothing.
        @testset "resolve_member_group_override lookup" begin
            ovr = MemberGroupSizingOverride(catalog = custom2)
            params = DesignParameters(
                member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                    UInt64(7) => ovr))
            @test resolve_member_group_override(params, UInt64(7)) === ovr
            @test resolve_member_group_override(params, UInt64(999)) === nothing
            # empty overrides → nothing for every gid (all callers stay byte-identical).
            @test resolve_member_group_override(DesignParameters(), UInt64(7)) === nothing
        end

        # (i) NON-VACUOUS: an override that restricts the catalog picks a DIFFERENT
        #     section than no override, i.e. it actually changes the design.
        @testset "override changes the sized section (non-vacuous)" begin
            # Baseline: no override → free optimum (a light shape NOT in custom2).
            struc0 = _build_override_beam_struc()
            build_member_groups!(struc0; member_type = :beams)
            gid0 = first(keys(struc0.member_groups))
            size_member_group!(struc0, gid0; member_edge_group = :beams,
                               material = A992_Steel, reanalyze = true)
            free_name = struc0.member_groups[gid0].section.name
            @test free_name ∉ custom_names

            # With a params-sourced override → section MUST come from custom2, and
            # MUST differ from the free optimum (the design genuinely changed).
            struc1 = _build_override_beam_struc()
            build_member_groups!(struc1; member_type = :beams)
            gid1 = first(keys(struc1.member_groups))
            params = DesignParameters(
                member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                    gid1 => MemberGroupSizingOverride(catalog = custom2)))
            size_member_group!(struc1, gid1; member_edge_group = :beams,
                               material = A992_Steel, reanalyze = true,
                               override = resolve_member_group_override(params, gid1))
            ovr_name = struc1.member_groups[gid1].section.name
            @test ovr_name ∈ custom_names
            @test ovr_name == "W21X44"
            @test ovr_name != free_name          # the override actually changed the pick
        end

        # (ii) PRECEDENCE: override entry beats MemberGroup.catalog_override beats
        #      the global default kwarg.
        @testset "precedence: override > catalog_override > default" begin
            # Two disjoint restricted catalogs whose optima differ.
            cat_group = [W("W24X68")]              # only W24X68 available
            cat_ovr   = [W("W21X44")]              # only W21X44 available

            # (a) override present → override wins over BOTH the group seam and default.
            struc = _build_override_beam_struc()
            build_member_groups!(struc; member_type = :beams)
            gid = first(keys(struc.member_groups))
            struc.member_groups[gid].catalog_override = cat_group   # would give W24X68
            size_member_group!(struc, gid; member_edge_group = :beams,
                               material = A992_Steel, reanalyze = true,
                               override = MemberGroupSizingOverride(catalog = cat_ovr))
            @test struc.member_groups[gid].section.name == "W21X44"  # override won

            # (b) no override, group seam present → the MemberGroup.catalog_override wins
            #     over the global default catalog (Phase 6 behavior preserved).
            struc2 = _build_override_beam_struc()
            build_member_groups!(struc2; member_type = :beams)
            gid2 = first(keys(struc2.member_groups))
            struc2.member_groups[gid2].catalog_override = cat_group
            size_member_group!(struc2, gid2; member_edge_group = :beams,
                               material = A992_Steel, reanalyze = true)  # override=nothing
            @test struc2.member_groups[gid2].section.name == "W24X68"  # group seam won

            # (c) neither → the global default catalog (all_W) free optimum, not in
            #     either restricted set.
            struc3 = _build_override_beam_struc()
            build_member_groups!(struc3; member_type = :beams)
            gid3 = first(keys(struc3.member_groups))
            size_member_group!(struc3, gid3; member_edge_group = :beams,
                               material = A992_Steel, reanalyze = true)
            @test struc3.member_groups[gid3].section.name ∉
                  Set(["W21X44", "W24X68"])
        end

        # (v) FAIL-LOUD: design_building REFUSES a non-empty member_group_overrides,
        #     and is BYTE-IDENTICAL for the EMPTY (default) case. The coarse pipeline
        #     never routes through size_member_group! (it runs batched size_beams! /
        #     global size_columns! MIP / flat-plate _reconcile_columns!), so honoring
        #     an override is impossible here; the run_pre_sizing_validation guard raises
        #     an ArgumentError rather than silently returning a default-catalog design.
        #     The honored path is proven non-vacuously by the size_member_group! tests
        #     above (free=W16X26 vs override=W21X44); those are intentionally unchanged.
        @testset "design_building refuses non-empty member_group_overrides; empty is byte-identical" begin
            # Message-pinned throw assertion (P2b): the thrown ArgumentError MUST be
            # the member_group_overrides guard, not any unrelated ArgumentError.
            _throws_guard(f) = try
                f()
                @test false  # expected the guard to throw
            catch e
                @test e isa ArgumentError &&
                      occursin("member_group_overrides", sprint(showerror, e))
            end

            # (a) EMPTY (default) → design_building runs; an explicit-empty dict is
            #     byte-identical to the plain default (adding the field/guard changed
            #     nothing on the happy path).
            struc_a, base_a = _build_flat_plate()
            des_default = design_building(struc_a, base_a)

            struc_b, base_b = _build_flat_plate()
            base_b.member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}()  # explicit empty
            des_empty = design_building(struc_b, base_b)

            ok, bad = _same_signature(_design_signature(des_default),
                                      _design_signature(des_empty))
            @test ok || error("explicit-empty member_group_overrides perturbed design_building: $bad")

            # (a2) POPULATED-but-VACUOUS (P2a): a dict whose only entry is all-unset
            #      (`nothing` catalog/deflection_limit/max_depth) is a DOCUMENTED no-op
            #      per the MemberGroupSizingOverride docstring. It MUST NOT throw, and
            #      design_building must be BYTE-IDENTICAL to the default (guard/docstring
            #      consistency — the guard refuses only EFFECTIVE overrides).
            struc_vac, base_vac = _build_flat_plate()
            base_vac.member_group_overrides =
                Dict{UInt64, MemberGroupSizingOverride}(
                    UInt64(1) => MemberGroupSizingOverride())  # all fields nothing
            @test !_SS._is_effective(base_vac.member_group_overrides[UInt64(1)])
            des_vac = design_building(struc_vac, base_vac)  # must NOT throw
            ok_vac, bad_vac = _same_signature(_design_signature(des_default),
                                              _design_signature(des_vac))
            @test ok_vac || error("all-unset member_group_overrides perturbed design_building: $bad_vac")

            # (b) NON-EMPTY EFFECTIVE (a real gid, real override) → design_building
            #     THROWS the fail-loud guard (was previously a silent no-op).
            struc_c, base_c = _build_flat_plate()
            base_c.member_group_overrides =
                Dict{UInt64, MemberGroupSizingOverride}(
                    UInt64(1) => MemberGroupSizingOverride(
                        catalog = [W("W21X44")], deflection_limit = 1/480))
            _throws_guard(() -> design_building(struc_c, base_c))

            # (b2) PATH-COMPLETE (P1): the exported design-producing VARIATION entry
            #      points (`redesign` / `vary` / `redesign_incremental!`) must ALSO
            #      refuse an effective override injected as a variation kwarg — the
            #      sweep door is exactly where a researcher injects per-group overrides,
            #      and it never re-enters run_pre_sizing_validation. Each must throw the
            #      SAME guard (message-pinned), not silently return an UNCHANGED design.
            eff_ovr = Dict{UInt64, MemberGroupSizingOverride}(
                UInt64(1) => MemberGroupSizingOverride(catalog = [W("W21X44")]))

            struc_r, base_r = _build_flat_plate()
            session_r = DesignSession(struc_r, base_r)   # clean base (no override)
            _throws_guard(() -> redesign(session_r; member_group_overrides = eff_ovr))
            _throws_guard(() -> vary(session_r, (; member_group_overrides = eff_ovr)))

            # redesign_incremental! on a directly-built engine: effective override on
            # the effective params must throw the guard. The base engine is built with
            # a CLEAN base (prepare_engine runs the same validation), then the variation
            # params carry the effective override.
            struc_ri, base_ri = _build_flat_plate()
            engine_ri = _SS.prepare_engine(struc_ri, base_ri)
            variant_ri = with(base_ri; member_group_overrides = eff_ovr)
            _throws_guard(() -> _SS.redesign_incremental!(engine_ri, variant_ri))

            # (b3) PRIMITIVE PATH 1 (Run 4, Part 1 backstop): the exported low-level
            #      chain build_design_graph -> execute_graph! -> capture_design
            #      BYPASSES run_pre_sizing_validation entirely, yet capture_design is
            #      the UNIVERSAL choke point where every BuildingDesign is
            #      materialized. Prepare/build/execute run on a CLEAN base (they never
            #      throw), then the effective override is threaded into the params
            #      handed to capture_design — which MUST refuse it rather than return a
            #      design that silently drops the override.
            struc_g, base_g = _build_flat_plate()
            prepare!(struc_g, base_g)
            graph_g = _SS.build_design_graph(struc_g, base_g)
            _SS.execute_graph!(graph_g, struc_g, base_g)
            params_g = with(base_g; member_group_overrides = eff_ovr)
            _throws_guard(() -> _SS.capture_design(struc_g, params_g))

            # (b4) PRIMITIVE PATH 2: manual run_target! + capture_incremental_design
            #      also bypasses the variation-door guard but routes through
            #      capture_design. Run the engine to the terminal node on a CLEAN base,
            #      then capture with the effective override — the choke point must
            #      throw the SAME guard (message-pinned).
            struc_t, base_t = _build_flat_plate()
            engine_t = _SS.prepare_engine(struc_t, base_t)
            _SS.run_target!(engine_t, base_t)
            params_t = with(base_t; member_group_overrides = eff_ovr)
            _throws_guard(() -> _SS.capture_incremental_design(engine_t, params_t))

            # (c) Phase B: `member_group_overrides` is now a `:members` param-slice
            # input (the batched steel-beam stage honors it — see provenance.jl
            # NODE_MEMBERS), so a change DIRTIES the member frontier. It is still NOT
            # prepare-affecting (no geometry/load re-prepare), so the incremental
            # engine is reused rather than rebuilt.
            struc_d, base_d = _build_flat_plate()
            session = DesignSession(struc_d, base_d)
            frontier = dirty_frontier(session;
                member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                    UInt64(1) => MemberGroupSizingOverride(catalog = [W("W21X44")])))
            @test NODE_MEMBERS in frontier
            @test !requires_new_engine(session;
                member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                    UInt64(1) => MemberGroupSizingOverride(catalog = [W("W21X44")])))
        end

        # (vi) STRUCTURAL enforcement (Run 4, Part 1 hardening): the guard now lives
        #      inside the `BuildingDesign(struc, params)` constructor — the SINGLE
        #      universal choke point through which every BuildingDesign is
        #      materialized (design_building, redesign, vary, redesign_incremental!,
        #      and the primitive build_design_graph/execute_graph!/capture_design and
        #      run_target!/capture_incremental_design paths ALL route here). A direct
        #      constructor call with an EFFECTIVE override MUST throw the same guard,
        #      so no present-or-future caller can materialize a design that silently
        #      drops the override. Empty and populated-but-vacuous (all-unset) dicts
        #      MUST construct without throwing, matching the design_building happy path.
        @testset "BuildingDesign constructor enforces the guard (STRUCTURAL)" begin
            _throws_guard(f) = try
                f()
                @test false  # expected the guard to throw
            catch e
                @test e isa ArgumentError &&
                      occursin("member_group_overrides", sprint(showerror, e))
            end

            struc_x, base_x = _build_flat_plate()

            # (a) DEFAULT (empty) override → constructs without throwing.
            @test BuildingDesign(struc_x, base_x) isa BuildingDesign

            # (b) EXPLICIT EMPTY dict → constructs without throwing.
            base_empty = with(base_x;
                member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}())
            des_empty = BuildingDesign(struc_x, base_empty)
            @test des_empty isa BuildingDesign
            @test isempty(des_empty.beams) && isempty(des_empty.columns) &&
                  isempty(des_empty.slabs) && isempty(des_empty.foundations)

            # (c) POPULATED-but-VACUOUS (all fields nothing) → documented no-op, MUST
            #     NOT throw and constructs an equivalent empty design.
            vac_ovr = Dict{UInt64, MemberGroupSizingOverride}(
                UInt64(1) => MemberGroupSizingOverride())  # all fields nothing
            @test !_SS._is_effective(vac_ovr[UInt64(1)])
            base_vac = with(base_x; member_group_overrides = vac_ovr)
            des_vac = BuildingDesign(struc_x, base_vac)
            @test des_vac isa BuildingDesign
            @test isempty(des_vac.beams) && isempty(des_vac.columns) &&
                  isempty(des_vac.slabs) && isempty(des_vac.foundations)

            # (d) EFFECTIVE override → the constructor THROWS the fail-loud guard
            #     (message-pinned), regardless of the entry point.
            eff_ovr = Dict{UInt64, MemberGroupSizingOverride}(
                UInt64(1) => MemberGroupSizingOverride(
                    catalog = [W("W21X44")], deflection_limit = 1/480))
            base_eff = with(base_x; member_group_overrides = eff_ovr)
            _throws_guard(() -> BuildingDesign(struc_x, base_eff))
        end

        # (vii) PHASE B: effective steel-beam-group overrides are LIVE on a
        #       beam/column (:vault) floor. An override narrows only its group's
        #       feasible set in the batched size_beams! path; from-scratch and the
        #       incremental engine route the identical threading.
        @testset "effective steel-beam-group override is LIVE (Phase B)" begin
            _throws_guard(f) = try
                f(); @test false
            catch e
                @test e isa ArgumentError &&
                      occursin("member_group_overrides", sprint(showerror, e))
            end

            # Canonical section name for steel-beam group `gid`, read from the
            # CAPTURED `design_building` return: after a :vault design the beam
            # members drop `.section` (→ `section(b) === nothing`) and
            # `struc.member_groups` is `empty!`-rebuilt per member_type (holds only
            # the column groups after beams THEN columns). `BuildingDesign.beams` is
            # keyed by beam INDEX; `BeamDesignResult.section_obj` survives capture
            # (see report_summary.jl), so map gid → beam index via `group_id` and
            # read the section object's name. (`section_size` is `string(sec)`, the
            # full struct repr, not the W-shape name.)
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

            # Deterministic beam gids from the DESIGNED free fixture. Raw skeletons
            # have no materialized member groups (`build_member_groups!` on a raw
            # struct yields an empty map — groups exist only after a sizing pass), so
            # design first and enumerate `group_id` off the designed beams.
            struc_free, base_free = _build_beam_column()
            des_free = design_building(struc_free, base_free)
            beam_gids = sort(unique(group_id(b) for b in struc_free.beams))
            @test length(beam_gids) >= 2
            target_gid = first(beam_gids)

            # Free (no-override) sized section for the target group.
            free_sec = beam_secname(struc_free, des_free, target_gid)

            # Heaviest W (max area ⇒ adequate; default max_depth = Inf), distinct
            # from the light free optimum.
            all_w = _SR.all_W()
            heavy = all_w[argmax([_SR.section_area(s) for s in all_w])]

            # (a) single-section catalog override ⇒ sized to EXACTLY that section,
            #     and it CHANGES the design relative to the free optimum.
            struc_ov, base_ov0 = _build_beam_column()
            base_ov = with(base_ov0; member_group_overrides =
                Dict{UInt64, MemberGroupSizingOverride}(
                    target_gid => MemberGroupSizingOverride(catalog = [heavy])))
            des_ov = design_building(struc_ov, base_ov)
            forced = beam_secname(struc_ov, des_ov, target_gid)
            @test forced == heavy.name
            @test forced != free_sec

            # (b) exact-first isolation: all OTHER beam groups unchanged vs free.
            @test all(g -> g == target_gid ||
                           beam_secname(struc_ov, des_ov, g) ==
                           beam_secname(struc_free, des_free, g), beam_gids)

            # (c) ORACLE: from-scratch WITH override == incremental engine WITH
            #     override (comprehensive per-member signature).
            struc_inc, base_inc = _build_beam_column()
            engine_inc = prepare_engine(struc_inc, base_inc)
            run_target!(engine_inc, base_inc)                   # clean base first
            variant_inc = with(base_inc; member_group_overrides =
                Dict{UInt64, MemberGroupSizingOverride}(
                    target_gid => MemberGroupSizingOverride(catalog = [heavy])))
            rc_inc, _ = run_target!(engine_inc, variant_inc)
            inc_ov = capture_incremental_design(engine_inc, variant_inc)
            @test NODE_MEMBERS in rc_inc
            ok_ovsig, bad_ovsig = _same_signature(_design_signature(des_ov),
                                                  _design_signature(inc_ov))
            @test ok_ovsig || error("from-scratch vs incremental override mismatch: $bad_ovsig")

            # (d) UN-HONORABLE targets still throw (message-pinned): a COLUMN-group
            #     override on the beam/column floor, and a beam override under a
            #     flat-plate floor.
            struc_cg, base_cg = _build_beam_column()
            design_building(struc_cg, base_cg)
            col_gid = first(sort(unique(group_id(c) for c in struc_cg.columns)))
            struc_cg2, base_cg2 = _build_beam_column()
            base_cg_ov = with(base_cg2; member_group_overrides =
                Dict{UInt64, MemberGroupSizingOverride}(
                    col_gid => MemberGroupSizingOverride(catalog = [heavy])))
            _throws_guard(() -> design_building(struc_cg2, base_cg_ov))

            struc_fpo, base_fpo = _build_flat_plate()
            base_fpo_ov = with(base_fpo; member_group_overrides =
                Dict{UInt64, MemberGroupSizingOverride}(
                    target_gid => MemberGroupSizingOverride(catalog = [heavy])))
            _throws_guard(() -> design_building(struc_fpo, base_fpo_ov))
        end

        # (viii) PHASE B REVIEW FIXES — the four precedence/completeness/defense gaps
        #        (A-revert) MemberGroup.catalog_override is a documented NO-OP in the
        #            batched path (honored only by size_member_group!),
        #        (B) a LOOSER deflection_limit/max_depth override was a silent no-op,
        #        (C) no SZ-layer guardrail coupling `feasible` with n_max_sections>0,
        #        (D) the variation door used the params-only (column-blind) guard.
        @testset "Phase B review fixes (A/B/C/D)" begin
            _throws_guard(f) = try
                f(); @test false
            catch e
                @test e isa ArgumentError &&
                      occursin("member_group_overrides", sprint(showerror, e))
            end

            all_w = _SR.all_W()
            heavy = all_w[argmax([_SR.section_area(s) for s in all_w])]

            # [A-revert] A beam group carrying ONLY a MemberGroup.catalog_override
            #     (Phase 6 seam) and EMPTY member_group_overrides must be a NO-OP in
            #     the BATCHED size_beams! path — catalog_override is honored solely by
            #     the isolated size_member_group! path (proven by testset (ii)), never
            #     by the batched design_building / incremental path (it was never
            #     honored here pre-Phase-B, and honoring it opened a regression). So
            #     the sized section is BYTE-IDENTICAL to the no-override free optimum,
            #     NOT narrowed to `heavy`.
            struc_cofree = _build_override_beam_struc()
            build_member_groups!(struc_cofree; member_type = :beams)
            size_beams!(struc_cofree, _SR.SteelBeamOptions(); reanalyze = false)
            gid_cof = first(keys(struc_cofree.member_groups))
            free_co = struc_cofree.member_groups[gid_cof].section.name
            @test free_co != heavy.name                      # free optimum ≠ the seam catalog

            struc_co = _build_override_beam_struc()
            build_member_groups!(struc_co; member_type = :beams)
            gid_co = first(keys(struc_co.member_groups))
            struc_co.member_groups[gid_co].catalog_override = [heavy]   # ONLY the seam
            size_beams!(struc_co, _SR.SteelBeamOptions(); reanalyze = false)  # no per-design override
            @test struc_co.member_groups[gid_co].section.name == free_co   # seam ignored → byte-identical

            # Real steel-beam / column gids on the vault fixture (only exist after a
            # sizing pass — enumerate off a DESIGNED structure).
            struc_probe, base_probe = _build_beam_column()
            design_building(struc_probe, base_probe)
            beam_gid = first(sort(unique(group_id(b) for b in struc_probe.beams)))
            col_gid  = first(sort(unique(group_id(c) for c in struc_probe.columns)))

            # [B] A LOOSER override is refused fail-loud (the batched mask only tightens,
            #     so a looser knob is a silent no-op). deflection_limit is an L/δ ratio:
            #     1/240 is LOOSER than the global default 1/360.
            struc_bl, base_bl = _build_beam_column()
            _throws_guard(() -> design_building(struc_bl, with(base_bl;
                member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                    beam_gid => MemberGroupSizingOverride(deflection_limit = 1/240)))))
            # max_depth LOOSER than an explicit finite global (24" > 12").
            struc_bd, base_bd = _build_beam_column()
            _throws_guard(() -> design_building(struc_bd, with(base_bd;
                beams = _SR.SteelBeamOptions(max_depth = 12.0u"inch"),
                member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                    beam_gid => MemberGroupSizingOverride(max_depth = 24.0u"inch")))))
            # TIGHTENING (1/480 < global 1/360) stays HONORED — the design succeeds.
            struc_bt, base_bt = _build_beam_column()
            @test design_building(struc_bt, with(base_bt;
                member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                    beam_gid => MemberGroupSizingOverride(deflection_limit = 1/480)))) isa
                  BuildingDesign

            # [C] SZ-layer defense-in-depth: optimize_discrete with feasible !== nothing
            #     AND n_max_sections > 0 must throw (exact-first-safe ONLY when ==0).
            #     feasible length == n_groups so the length check passes and the new
            #     n_max_sections guard is what fires.
            checker_c = _SR.AISCChecker()
            demands_c = [_SR.MemberDemand(1; Mux = 100e3)]
            geoms_c   = [_SR.SteelMemberGeometry(6.0)]
            cat_c     = _SR.all_W()
            @test_throws ArgumentError _SR.optimize_discrete(
                checker_c, demands_c, geoms_c, cat_c, _SR.A992_Steel;
                feasible = [collect(1:min(3, length(cat_c)))], n_max_sections = 1)

            # [D] The variation door now uses the STRUC-AWARE guard: a COLUMN-group
            #     override via redesign/vary is refused AT THE DOOR (not only at the
            #     capture_design backstop), while an honorable BEAM-group override is
            #     NOT over-refused.
            struc_d, base_d = _build_beam_column()
            session_d = DesignSession(struc_d, base_d)
            col_ovr = Dict{UInt64, MemberGroupSizingOverride}(
                col_gid => MemberGroupSizingOverride(catalog = [heavy]))
            _throws_guard(() -> redesign(session_d; member_group_overrides = col_ovr))
            _throws_guard(() -> vary(session_d, (; member_group_overrides = col_ovr)))

            struc_d2, base_d2 = _build_beam_column()
            session_d2 = DesignSession(struc_d2, base_d2)
            beam_ovr = Dict{UInt64, MemberGroupSizingOverride}(
                beam_gid => MemberGroupSizingOverride(catalog = [heavy]))
            @test redesign(session_d2; member_group_overrides = beam_ovr) isa BuildingDesign
        end

        # (ix) PHASE B FIX CYCLE 2 — re-critic findings on the fix-cycle-1 guard:
        #      [P1-2] the pre-sizing classifier ignored collinear grouping, so an
        #             honorable override keyed on a COLLINEAR beam gid was misclassified
        #             :unknown and false-refused; [P2-3] the classifier accepted any
        #             struc.beams member, but the sizer only emits groups with a segment
        #             on a :beams edge (par_has), so a non-par_has beam override was
        #             SILENTLY dropped; [P2-4] a bare-number/ill-typed override field
        #             surfaced as a Unitful DimensionError deep in sizing instead of the
        #             pinned guard; [composite] the bare-Ix mask must not apply to a
        #             composite-beam demand (I_LB code check).
        @testset "Phase B fix cycle 2 (P1-2/P2-3/P2-4/composite)" begin
            _throws_guard(f) = try
                f(); @test false
            catch e
                @test e isa ArgumentError &&
                      occursin("member_group_overrides", sprint(showerror, e))
            end

            all_w = _SR.all_W()
            heavy = all_w[argmax([_SR.section_area(s) for s in all_w])]

            # gid → forced beam section name, read off a CAPTURED design (see (vii)).
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

            # ── [P2-4] ill-typed override fields → PINNED ArgumentError at CONSTRUCTION
            #    (design_types.jl MemberGroupSizingOverride constructor), never a bare
            #    Unitful DimensionError deep in the batched mask. ─────────────────────
            @testset "P2-4 ill-typed override fields refused at construction" begin
                # bare-number max_depth (missing length units).
                err_d = try; MemberGroupSizingOverride(max_depth = 0.4); nothing
                        catch e; e; end
                @test err_d isa ArgumentError &&
                      occursin("member_group_overrides", sprint(showerror, err_d))
                # dimensioned deflection_limit (must be a dimensionless L/δ Real).
                err_l = try; MemberGroupSizingOverride(deflection_limit = 1.0u"inch"); nothing
                        catch e; e; end
                @test err_l isa ArgumentError &&
                      occursin("member_group_overrides", sprint(showerror, err_l))
                # a WELL-typed override still constructs (regression guard).
                @test MemberGroupSizingOverride(deflection_limit = 1/360,
                                                max_depth = 18.0u"inch") isa
                      MemberGroupSizingOverride
            end

            # ── [composite] an EFFECTIVE override on a COMPOSITE-beam demand is refused
            #    fail-loud (pinned): the batched feasible mask gates deflection on
            #    bare-steel Ix, whereas the composite code check uses I_LB (AISC 360-16
            #    Commentary I3.2), so Phase B (steel-only) refuses rather than
            #    over-restrict. Exercised directly on the guard helper — batched
            #    demands are `composite === nothing` by construction, so a lightweight
            #    non-nothing composite stand-in isolates the `!== nothing` branch. ────
            @testset "composite-beam demand under an effective override → refused" begin
                gids = UInt64[UInt64(11), UInt64(22)]
                demands = [_SR.MemberDemand(1; Mux = 100e3),
                           _SR.MemberDemand(2; Mux = 100e3, composite = :composite_stub)]
                ovr_comp = Dict{UInt64, MemberGroupSizingOverride}(
                    UInt64(22) => MemberGroupSizingOverride(catalog = [W("W21X44")]))
                _throws_guard(() -> _SS._assert_no_composite_override(gids, demands, ovr_comp))
                # a NON-composite target (group 11) with the same override is fine.
                ovr_ok = Dict{UInt64, MemberGroupSizingOverride}(
                    UInt64(11) => MemberGroupSizingOverride(catalog = [W("W21X44")]))
                @test _SS._assert_no_composite_override(gids, demands, ovr_ok) === nothing
                # a VACUOUS override on the composite group is a no-op (not effective).
                ovr_vac = Dict{UInt64, MemberGroupSizingOverride}(
                    UInt64(22) => MemberGroupSizingOverride())
                @test _SS._assert_no_composite_override(gids, demands, ovr_vac) === nothing
            end

            # ── [P2-3] a beam with NO segment on a :beams edge is never emitted by the
            #    sizer (par_has == false), so its override MUST be refused fail-loud —
            #    not silently dropped. The DEFINITIVE check now lives at the SIZE-TIME
            #    gid gate inside `_size_beams_impl!` (utils.jl), where the real
            #    par_has-filtered `group_ids` are in scope (the pre-sizing classifier was
            #    REMOVED — its collinear reproduction was unreliable). Exercise the gate
            #    directly via `size_beams!`: build a beam group, then strip the :beams
            #    edge set so `member_group_demands` emits NO group; an override on that
            #    now-absent gid is refused fail-loud — even though the emitted set is
            #    empty (the gate runs BEFORE the empty-group early return). ─────────────
            @testset "P2-3 par_has-absent beam override refused at size time" begin
                struc_p3 = _build_override_beam_struc()
                build_member_groups!(struc_p3; member_type = :beams)
                beam_gid_p3 = first(keys(struc_p3.member_groups))
                struc_p3.skeleton.groups_edges[:beams] = Int[]   # par_has false for all
                _throws_guard(() -> size_beams!(struc_p3, _SR.SteelBeamOptions();
                    reanalyze = false,
                    member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                        beam_gid_p3 => MemberGroupSizingOverride(catalog = [heavy]))))
            end

            # ── [P1-2] with collinear_grouping = true the sizer decides beam grouping
            #    at SIZE time on the analysis structure (`group_collinear_members!`
            #    inside `size_beams!`), NOT in `prepare!`. A pre-sizing reproduction of
            #    that grouping is UNRELIABLE (it disagreed with the real size-time gids —
            #    e.g. 12 door-side chains vs 24 groups at size time), so the definitive
            #    honor/refuse decision is the SIZE-TIME gid gate. Key an override on the
            #    sizer's REAL size-time gid — read back from a DESIGNED struc
            #    (`group_id(struc.beams[k])` post-size, the verified data model) — and it
            #    is HONORED through design_building AND redesign_incremental!, while a
            #    column-group gid is refused fail-loud. (Pre-fix the door false-refused
            #    an override keyed on the real gid under collinear_grouping.) ───────────
            @testset "P1-2 override on real size-time gid honored (collinear_grouping)" begin
                # Stiffest W (max Ix ⇒ least deflection ⇒ guaranteed feasible; huge Zx ⇒
                # ample capacity). A max-AREA shape can fail the L/360 mask, so key on Ix.
                stiff = all_w[argmax([ustrip(u"m^4", _SR.Ix(s)) for s in all_w])]
                secname_idx(des, k) = begin
                    r = get(des.beams, k, nothing)
                    r === nothing && return nothing
                    r.section_obj === nothing ? nothing : r.section_obj.name
                end

                # Derive the sizer's ACTUAL size-time beam gids by DESIGNING once with
                # collinear_grouping on (the ONLY reliable source). Post-design,
                # group_id(struc.beams[k]) carries the gid the sizer used at size time
                # (build_member_groups! persists it) — the verified data model.
                struc_a, base_a0 = _build_beam_column()
                base_a = with(base_a0; collinear_grouping = true)
                design_building(struc_a, base_a)
                beam_gids = unique(group_id(b) for b in struc_a.beams)
                @test !isempty(beam_gids)
                target_cl = first(beam_gids)
                chain_idx = first(i for (i, b) in enumerate(struc_a.beams)
                                  if group_id(b) == target_cl)

                # (a) HONORED from-scratch: the override keyed on the REAL size-time gid
                #     passes the size-time gate (it IS in the honorable set) and forces
                #     the group to `stiff`. The pre-fix door false-refused this.
                struc_clo, base_clo0 = _build_beam_column()
                base_clo = with(base_clo0; collinear_grouping = true,
                    member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                        target_cl => MemberGroupSizingOverride(catalog = [stiff])))
                des_clo = design_building(struc_clo, base_clo)
                @test des_clo isa BuildingDesign
                @test secname_idx(des_clo, chain_idx) == stiff.name

                # (b) HONORED incrementally: the same override through redesign_incremental!
                #     recomputes members and forces the same section (same size-time gid).
                struc_cli, base_cli0 = _build_beam_column()
                base_cli = with(base_cli0; collinear_grouping = true)
                engine_cli = prepare_engine(struc_cli, base_cli)
                run_target!(engine_cli, base_cli)                    # clean base first
                variant_cli = with(base_cli; member_group_overrides =
                    Dict{UInt64, MemberGroupSizingOverride}(
                        target_cl => MemberGroupSizingOverride(catalog = [stiff])))
                rc_cli, _ = run_target!(engine_cli, variant_cli)
                @test NODE_MEMBERS in rc_cli
                inc_clo = capture_incremental_design(engine_cli, variant_cli)
                @test secname_idx(inc_clo, chain_idx) == stiff.name

                # (c) UN-HONORABLE under collinear_grouping: a COLUMN-group gid (never in
                #     the beam honorable set) is refused fail-loud at the size-time gate.
                struc_col, base_col0 = _build_beam_column()
                design_building(struc_col, base_col0)
                col_gid_cl = first(sort(unique(group_id(c) for c in struc_col.columns)))
                struc_clc, base_clc0 = _build_beam_column()
                base_clc_ov = with(base_clc0; collinear_grouping = true,
                    member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                        col_gid_cl => MemberGroupSizingOverride(catalog = [heavy])))
                _throws_guard(() -> design_building(struc_clc, base_clc_ov))
            end
        end

        # (x) PHASE B FIX CYCLE 3 — one P1 silent-drop + two defense-in-depth P2s.
        #     [P1] `_size_beams_columns!` has TWO early-returns that skip `size_beams!`
        #          (and thus the size-time gid gate) entirely: the slab-only branch and
        #          the no-beam-edges branch. On a NON-flat steel floor with columns but
        #          NO :beams edge group, an EFFECTIVE member_group_overrides entry passed
        #          every existing door and was SILENTLY DROPPED while `capture_design`
        #          still materialized a BuildingDesign. The honor-or-throw invariant is
        #          now enforced UNCONDITIONALLY inside both skip branches.
        #     [P2 section-identity] `_beam_sec_key` keys on `(typename, name)`; an
        #          override-catalog section colliding a default NAME but with DIFFERING
        #          properties was silently substituted onto the default's index. Now
        #          refused fail-loud (identical sections still dedup byte-identically).
        #     [P2 SZ] the multi-material `optimize_discrete` `feasible` index-space was
        #          unvalidated; a single-material-space (1..n_sec) mask would silently
        #          restrict to material 1. Now refused fail-loud.
        @testset "Phase B fix cycle 3 (P1 silent-drop / P2 section / P2 SZ)" begin
            _throws_guard(f) = try
                f(); @test false
            catch e
                @test e isa ArgumentError &&
                      occursin("member_group_overrides", sprint(showerror, e))
            end

            all_w = _SR.all_W()
            heavy = all_w[argmax([_SR.section_area(s) for s in all_w])]
            eff_ovr(gid) = Dict{UInt64, MemberGroupSizingOverride}(
                gid => MemberGroupSizingOverride(catalog = [heavy]))

            # ── [P1] NON-flat steel floor with columns but NO :beams edges + an
            #    EFFECTIVE override ⇒ pinned ArgumentError (NOT silently dropped), on
            #    BOTH design_building AND redesign_incremental!. Strip the vault's :beams
            #    edge set BEFORE prepare! (initialize! reads groups_edges, never
            #    repopulates it), so `_size_beams_columns!` hits the no-beam-edges skip
            #    branch. An empty override on the same stripped fixture MUST stay a strict
            #    no-op (byte-identical) — proving the guard fires only on EFFECTIVE
            #    overrides. (A slab-only :grade/:roof geometry is the OTHER residual skip
            #    branch; it is not constructible from the existing fixtures — see NOTES —
            #    but the same in-branch guard covers it.)
            @testset "P1 no-beam-edges skip branch refuses effective override" begin
                # design_building path
                struc_p1, base_p1 = _build_beam_column()
                struc_p1.skeleton.groups_edges[:beams] = Int[]
                _throws_guard(() -> design_building(struc_p1,
                    with(base_p1; member_group_overrides = eff_ovr(UInt64(1)))))

                # empty override on the SAME stripped fixture is a strict no-op.
                struc_p1e, base_p1e = _build_beam_column()
                struc_p1e.skeleton.groups_edges[:beams] = Int[]
                @test design_building(struc_p1e, base_p1e) isa BuildingDesign

                # redesign_incremental! path (routes through _size_beams_columns! too).
                struc_p1i, base_p1i = _build_beam_column()
                struc_p1i.skeleton.groups_edges[:beams] = Int[]
                engine_p1 = prepare_engine(struc_p1i, base_p1i)
                run_target!(engine_p1, base_p1i)     # clean base: columns-only, no throw
                variant_p1 = with(base_p1i; member_group_overrides = eff_ovr(UInt64(1)))
                _throws_guard(() -> _SS.redesign_incremental!(engine_p1, variant_p1))
            end

            # ── [P2 section-identity] an override-catalog section whose (typename, name)
            #    collides a DEFAULT section's name but whose PROPERTIES differ (a
            #    deep-copied default W with a halved Ix, same name) ⇒ pinned throw. A
            #    genuinely IDENTICAL section (the cached default singleton) still dedups
            #    byte-identically (no throw, real design).
            @testset "P2 name-colliding override section with differing props refused" begin
                struc_free, base_free = _build_beam_column()
                design_building(struc_free, base_free)
                target_gid = first(sort(unique(group_id(b) for b in struc_free.beams)))

                dflt_opts = _SR.SteelBeamOptions()
                dflt_cat = dflt_opts.custom_catalog === nothing ?
                    _SR.steel_column_catalog(dflt_opts.section_type, dflt_opts.catalog) :
                    dflt_opts.custom_catalog
                base_sec = first(dflt_cat)
                modified = deepcopy(base_sec)
                modified.Ix = base_sec.Ix * 0.5   # SAME name, DIFFERENT property (Ix)
                @test !_SS._sections_identical(base_sec, modified)
                @test _SS._sections_identical(base_sec, base_sec)

                struc_col, base_col = _build_beam_column()
                _throws_guard(() -> design_building(struc_col, with(base_col;
                    member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                        target_gid => MemberGroupSizingOverride(catalog = [modified])))))

                # IDENTICAL-name collision using the cached default singleton is a no-op
                # dedup (byte-identical) — the design succeeds.
                struc_id, base_id = _build_beam_column()
                @test design_building(struc_id, with(base_id;
                    member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                        target_gid => MemberGroupSizingOverride(catalog = [base_sec])))) isa
                      BuildingDesign
            end

            # ── [P2 SZ, RECONCILED fix cycle 4] the MULTI-MATERIAL optimize_discrete
            #    keeps the HARD in-range check (an out-of-range index > n_sec*n_mat is
            #    refused fail-loud) but NO LONGER throws on a "single-material-space"
            #    heuristic. A material-1-only mask (indices k = (1-1)*n_sec + j = j, all
            #    <= n_sec) is a LEGITIMATE in-range restriction, indistinguishable from a
            #    mis-spaced mask, so cycle-3's heuristic FALSE-POSITIVED it. It must now
            #    run and return a feasible result confined to material 1. The
            #    SINGLE-material overload is unchanged. This is a solver-input guard, so
            #    the message is NOT pinned on 'member_group_overrides' — just an
            #    ArgumentError on the out-of-range case.
            @testset "P2 SZ multi-material feasible index-space validated" begin
                checker = _SR.AISCChecker()
                demands = [_SR.MemberDemand(1; Mux = 100e3)]
                geoms   = [_SR.SteelMemberGeometry(6.0)]
                cat     = _SR.all_W()
                mats    = [_SR.A992_Steel, _SR.A992_Steel]   # n_mat = 2
                n_sec   = length(cat)
                # material-1-only mask (every index <= n_sec) is a LEGITIMATE in-range
                # restriction — NO throw — and the solver must pick material 1.
                res_m1 = _SR.optimize_discrete(
                    checker, demands, geoms, cat, mats;
                    feasible = [collect(1:n_sec)], n_max_sections = 0)
                @test res_m1.material_indices[1] == 1
                @test res_m1.section_indices[1] in 1:n_sec
                # out-of-range index (> n_sec * n_mat) is still refused fail-loud.
                @test_throws ArgumentError _SR.optimize_discrete(
                    checker, demands, geoms, cat, mats;
                    feasible = [[n_sec * 2 + 5]], n_max_sections = 0)
            end
        end

        # (xi) PHASE B FIX CYCLE 4 — the UNIVERSAL silent-drop fix.
        #     [P0] `size!(design)` (core/size.jl) did NOT thread
        #          `member_group_overrides` into `size_beams!`, so the honor-or-throw
        #          size-time gid gate was SKIPPED on the exported `size!` path: an
        #          honorable override was SILENTLY DROPPED, an un-honorable one silently
        #          ignored. `size!` now threads `design.params.member_group_overrides`,
        #          so the gate fires: honorable ⇒ HONORED, un-honorable ⇒ pinned throw.
        #     [P1] struc-only callers (`size_members!`, bare `size_beams!(struc,...)`)
        #          default the override from `struc.design_parameters` when none is
        #          threaded — but `BuildingStructure` has NO `design_parameters` field
        #          (building_types/structure.jl) and it is never assigned, so that
        #          default is an inert backstop and the size! thread is authoritative.
        #     [P2 sections] `_sections_identical` now dedups genuinely value-equal (but
        #          DISTINCT-object) sections (no throw) while still refusing a
        #          genuinely-differing (typename,name) collision.
        @testset "Phase B fix cycle 4 (universal size! gate / P2 sections)" begin
            _throws_guard(f) = try
                f(); @test false
            catch e
                @test e isa ArgumentError &&
                      occursin("member_group_overrides", sprint(showerror, e))
            end

            # gid → live sized section name, read from the size!/capture result
            # (`BeamDesignResult.section_obj`), mapped by beam INDEX via `group_id`.
            beam_secname_live(s, des, gid) = begin
                for (k, b) in enumerate(s.beams)
                    if group_id(b) == gid
                        r = get(des.beams, k, nothing)
                        r === nothing && return nothing
                        return r.section_obj === nothing ? nothing : r.section_obj.name
                    end
                end
                nothing
            end

            # Deterministic gids from a designed reference fixture (raw skeletons have
            # no materialized member groups). gids are stable across identical
            # `_build_beam_column()` fixtures (see testset (vii)).
            struc_ref, base_ref = _build_beam_column()
            des_ref = design_building(struc_ref, base_ref)
            beam_gids = sort(unique(group_id(b) for b in struc_ref.beams))
            @test length(beam_gids) >= 2
            target_gid = first(beam_gids)
            col_gid = first(sort(unique(group_id(c) for c in struc_ref.columns)))
            free_sec = beam_secname_live(struc_ref, des_ref, target_gid)

            all_w = _SR.all_W()
            heavy = all_w[argmax([_SR.section_area(s) for s in all_w])]

            # ── [P0] HONORABLE steel-beam override via the `size!` path ⇒ the returned
            #    design HONORS the restriction (target group sized to `heavy`), NOT a
            #    default-catalog design. Before the fix `size!` silently dropped it and
            #    returned the free optimum.
            @testset "P0 size! honors an effective steel-beam override" begin
                struc_h, base_h0 = _build_beam_column()
                base_h = with(base_h0; member_group_overrides =
                    Dict{UInt64, MemberGroupSizingOverride}(
                        target_gid => MemberGroupSizingOverride(catalog = [heavy])))
                prepare!(struc_h, base_h)
                design_h = BuildingDesign(struc_h, base_h)
                size!(design_h; verbose = false)
                forced = beam_secname_live(struc_h, design_h, target_gid)
                @test forced == heavy.name            # HONORED, not silently dropped
                @test forced != free_sec              # and it CHANGED the design
            end

            # ── [P0] UN-HONORABLE override (a COLUMN-group gid) via `size!` ⇒ pinned
            #    `member_group_overrides` ArgumentError at the size-time gate (never a
            #    silently-dropped design).
            @testset "P0 size! refuses an un-honorable override (pinned)" begin
                struc_u, base_u0 = _build_beam_column()
                base_u = with(base_u0; member_group_overrides =
                    Dict{UInt64, MemberGroupSizingOverride}(
                        col_gid => MemberGroupSizingOverride(catalog = [heavy])))
                prepare!(struc_u, base_u)
                design_u = BuildingDesign(struc_u, base_u)   # constructor door passes honorable-shaped params
                _throws_guard(() -> size!(design_u; verbose = false))
            end

            # ── [P1] `struc.design_parameters` is NOT a field of BuildingStructure and
            #    is never assigned, so struc-only callers cannot carry a per-design
            #    override in this fixture; the size_beams! dp-default is therefore an
            #    inert backstop (stays `nothing`) and the size! thread above is the
            #    authoritative universal coverage. Assert the backstop is inert: a bare
            #    size_beams! / size_members! with no override channel sizes normally and
            #    never throws the pinned guard (strict byte-identical no-op).
            @testset "P1 struc-only callers never silently drop (backstop inert)" begin
                struc_b, base_b = _build_beam_column()
                prepare!(struc_b, base_b)
                @test size_beams!(struc_b, _SR.SteelBeamOptions(); reanalyze = false) === struc_b
                struc_mm, base_mm = _build_beam_column()
                prepare!(struc_mm, base_mm)
                @test size_members!(struc_mm) === struc_mm
            end

            # ── [P2 sections] `_sections_identical` dedups genuinely value-equal but
            #    DISTINCT-object sections (deepcopy) byte-identically, while still
            #    refusing a genuinely-differing (typename,name) collision.
            @testset "P2 value-equal section collision dedups (no throw)" begin
                dflt_opts = _SR.SteelBeamOptions()
                dflt_cat = dflt_opts.custom_catalog === nothing ?
                    _SR.steel_column_catalog(dflt_opts.section_type, dflt_opts.catalog) :
                    dflt_opts.custom_catalog
                base_sec = first(dflt_cat)

                # direct contract: same object, distinct-but-equal, genuinely differing.
                @test _SS._sections_identical(base_sec, base_sec)
                @test _SS._sections_identical(base_sec, deepcopy(base_sec))
                modified = deepcopy(base_sec)
                modified.Ix = base_sec.Ix * 0.5
                @test !_SS._sections_identical(base_sec, modified)

                # integration: a value-EQUAL deepcopy of an ADEQUATE default section,
                # used as a single-section override catalog, collides that default's
                # (typename,name) key and must DEDUP (no throw) → a real design. The
                # heaviest default section is adequate for the vault beam demand.
                heavy_dflt = dflt_cat[argmax([_SR.section_area(s) for s in dflt_cat])]
                struc_dd, base_dd0 = _build_beam_column()
                base_dd = with(base_dd0; member_group_overrides =
                    Dict{UInt64, MemberGroupSizingOverride}(
                        target_gid => MemberGroupSizingOverride(catalog = [deepcopy(heavy_dflt)])))
                @test design_building(struc_dd, base_dd) isa BuildingDesign
            end

            # (xii) PHASE B FIX CYCLE 5 — close the size! front-door bypass + hardening.
            #   [P0] size!(design) now runs the SAME struc-aware guard design_building
            #        uses, BEFORE the sizing loop — a NON-STEEL beam-opts effective
            #        override MUTATED into the live dict after a short-circuited
            #        empty-dict construction is refused pinned, NOT silently dropped by
            #        the concrete/nlp/pixelframe `_size_beams_impl!` overloads.
            #   [P1] a MULTI-MATERIAL steel effective override is refused pinned (front-
            #        door check 4), never a silent collapse of the optimization to
            #        material 1.
            #   [P1/P2 backstop] the batched steel size-time gate ALSO refuses a multi-
            #        material effective override directly, so the single-material-space
            #        feasible mask never reaches the multi-material solver even if a
            #        caller skips the front door.
            #   [P2 sections] the field recursion is depth-bounded; leaf comparison is
            #        `isequal`-based (fix cycle 6 REVERTED the cycle-5 NaN-poison rule), so
            #        two sections both carrying the same unset cost=NaN sentinel dedup.
            @testset "Phase B fix cycle 5 (size! parity / multi-material / NaN identity)" begin
                # [P0] non-steel (concrete) beam opts + an override MUTATED into the live
                # dict AFTER an empty-dict construction ⇒ size! refuses pinned. The
                # constructor guard short-circuited on the then-empty dict; the size!
                # front-door guard re-runs and fires check 2 (non-steel). VaultOptions
                # floor + ConcreteBeamOptions is a constructible non-steel-beam config,
                # and prepare! never inspects params.beams, so size! reaches the guard.
                struc_c, base_c = _build_beam_column(beams = _SR.ConcreteBeamOptions())
                prepare!(struc_c, base_c)
                design_c = BuildingDesign(struc_c, base_c)
                design_c.params.member_group_overrides[target_gid] =
                    MemberGroupSizingOverride(catalog = [heavy])
                _throws_guard(() -> size!(design_c; verbose = false))

                # [P1] multi-material steel beam opts + effective override mutated in
                # after construction ⇒ size! refuses pinned (front-door check 4).
                struc_mm, base_mm = _build_beam_column(
                    beams = _SR.SteelBeamOptions(materials = [_SR.A992_Steel, _SR.S355_Steel]))
                prepare!(struc_mm, base_mm)
                design_mm = BuildingDesign(struc_mm, base_mm)
                design_mm.params.member_group_overrides[target_gid] =
                    MemberGroupSizingOverride(catalog = [heavy])
                _throws_guard(() -> size!(design_mm; verbose = false))

                # [P1/P2 backstop] bypass the front door: call the batched steel gate
                # directly with multi-material opts + an effective override ⇒ the size-
                # time gate itself refuses pinned (opts.materials !== nothing), so the
                # single-material-space feasible mask never reaches the multi-material
                # optimize_discrete (which would silently reinterpret it as material-1).
                struc_bs, base_bs = _build_beam_column()
                prepare!(struc_bs, base_bs)
                _throws_guard(() -> size_beams!(struc_bs,
                    _SR.SteelBeamOptions(materials = [_SR.A992_Steel, _SR.S355_Steel]);
                    reanalyze = false,
                    member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                        target_gid => MemberGroupSizingOverride(catalog = [heavy]))))

                # regression: an HONORABLE single-material steel override via size! is
                # still HONORED (target group sized to `heavy`, differs from the free
                # optimum) — the front-door guard passes it through untouched.
                struc_hh, base_hh0 = _build_beam_column()
                base_hh = with(base_hh0; member_group_overrides =
                    Dict{UInt64, MemberGroupSizingOverride}(
                        target_gid => MemberGroupSizingOverride(catalog = [heavy])))
                prepare!(struc_hh, base_hh)
                design_hh = BuildingDesign(struc_hh, base_hh)
                size!(design_hh; verbose = false)
                @test beam_secname_live(struc_hh, design_hh, target_gid) == heavy.name
                @test beam_secname_live(struc_hh, design_hh, target_gid) != free_sec

                # [P2 sections, fix cycle 6] Leaf comparison is `isequal`-based — the
                # cycle-5 NaN-poison rule was REVERTED. `isequal(NaN, NaN) === true` (two
                # unset sentinels do NOT differ) while `isequal(1.0, NaN) === false`
                # (genuinely different). `Metal.cost` defaults to NaN (StructuralSizer
                # materials/types.jl:79), so A992_Steel.cost is the NaN sentinel.
                @test _SS._field_identical(1.0, 1.0)
                @test _SS._field_identical(missing, missing)
                @test _SS._field_identical(NaN, NaN)
                @test !_SS._field_identical(1.0, NaN)

                # section level: two DISTINCT sections, identical except each carries a
                # DISTINCT material whose `cost` is the NaN sentinel ⇒ VALUE-EQUAL, so a
                # (typename,name) collision DEDUPS byte-identically (honored), not refused.
                dflt_opts5 = _SR.SteelBeamOptions()
                dflt_cat5 = dflt_opts5.custom_catalog === nothing ?
                    _SR.steel_column_catalog(dflt_opts5.section_type, dflt_opts5.catalog) :
                    dflt_opts5.custom_catalog
                base_sec5 = first(dflt_cat5)
                sec_nan_a = deepcopy(base_sec5); sec_nan_a.material = deepcopy(_SR.A992_Steel)
                sec_nan_b = deepcopy(base_sec5); sec_nan_b.material = deepcopy(_SR.A992_Steel)
                @test isnan(sec_nan_a.material.cost)              # sentinel precondition
                @test _SS._sections_identical(sec_nan_a, sec_nan_b)
                # control: WITHOUT a NaN material the same deepcopies still dedup.
                @test _SS._sections_identical(deepcopy(base_sec5), deepcopy(base_sec5))

                # [P2 recursion bound] a cyclic field graph terminates (returns false),
                # never StackOverflows — the depth cap backstops a self-referential graph.
                ref_a = Ref{Any}(nothing); ref_a[] = ref_a
                ref_b = Ref{Any}(nothing); ref_b[] = ref_b
                @test _SS._field_identical(ref_a, ref_b) == false
            end

            # (xiii) PHASE B FIX CYCLE 6 — three contract-completeness findings on the
            #   member_group_overrides honor-or-throw invariant:
            #   [P1-a] a steel-beam option with sizing_strategy != :discrete (e.g. :nlp)
            #          has NO honoring path (the size-time gid gate lives only in the
            #          :discrete _size_beams_impl!), so an effective override on it is
            #          refused with the PINNED guard (front-door check 4b) rather than
            #          dispatching to a missing :nlp overload (MethodError) or silently
            #          dropping.
            #   [P1-b] REVERT the cycle-5 NaN-poison over-correction: two genuinely
            #          value-equal override sections both carrying a cost=NaN material and
            #          colliding a (typename,name) key must DEDUP byte-identically (honor
            #          path), while a genuinely-differing property under the same name is
            #          still refused pinned (cycle-4 concern stays closed).
            #   [P2]   the DIRECT size_beams! path bypasses the front door, so the size-
            #          time gid gate must itself refuse a LOOSER per-group knob (mirrors
            #          front-door check 5); a tightening/equal knob stays honored.
            @testset "Phase B fix cycle 6 (:nlp guard / NaN dedup / size-time looseness)" begin
                # ── [P1-a] :nlp steel beam override ⇒ pinned refusal, NOT a MethodError.
                @testset "P1-a :nlp steel-beam override refused pinned (not MethodError)" begin
                    # via design_building (struc-aware guard → params-only check 4b).
                    struc_nlp, base_nlp0 = _build_beam_column(
                        beams = _SR.SteelBeamOptions(sizing_strategy = :nlp))
                    base_nlp = with(base_nlp0; member_group_overrides =
                        Dict{UInt64, MemberGroupSizingOverride}(
                            target_gid => MemberGroupSizingOverride(catalog = [heavy])))
                    _throws_guard(() -> design_building(struc_nlp, base_nlp))

                    # via size! (front-door guard re-run): construct with an EMPTY dict
                    # (guard short-circuits), then mutate an effective override in ⇒ size!
                    # refuses pinned BEFORE dispatching to the missing :nlp sizing overload.
                    struc_nlp2, base_nlp2 = _build_beam_column(
                        beams = _SR.SteelBeamOptions(sizing_strategy = :nlp))
                    prepare!(struc_nlp2, base_nlp2)
                    design_nlp2 = BuildingDesign(struc_nlp2, base_nlp2)
                    design_nlp2.params.member_group_overrides[target_gid] =
                        MemberGroupSizingOverride(catalog = [heavy])
                    _throws_guard(() -> size!(design_nlp2; verbose = false))
                end

                # ── [P1-b] value-equal NaN-material sections dedup; differing still refused.
                @testset "P1-b NaN-material value-equal dedups; differing refused" begin
                    dflt_opts6 = _SR.SteelBeamOptions()
                    dflt_cat6 = dflt_opts6.custom_catalog === nothing ?
                        _SR.steel_column_catalog(dflt_opts6.section_type, dflt_opts6.catalog) :
                        dflt_opts6.custom_catalog
                    base_sec6 = first(dflt_cat6)

                    # unit: two DISTINCT sections, value-equal, each carrying a fresh
                    # A992_Steel whose cost is the NaN sentinel, sharing a (typename,name)
                    # key ⇒ DEDUP (identical). Cycle-5 wrongly refused this honor path.
                    a6 = deepcopy(base_sec6); a6.material = deepcopy(_SR.A992_Steel)
                    b6 = deepcopy(base_sec6); b6.material = deepcopy(_SR.A992_Steel)
                    @test isnan(a6.material.cost)                 # NaN sentinel precondition
                    @test _SS._sections_identical(a6, b6)         # value-equal ⇒ dedup
                    @test _SS._field_identical(NaN, NaN)          # isequal(NaN,NaN) === true
                    @test !_SS._field_identical(1.0, NaN)         # isequal(1.0,NaN) === false

                    # a genuinely-DIFFERING property under the same name is STILL refused.
                    c6 = deepcopy(base_sec6); c6.Ix = base_sec6.Ix * 0.5
                    @test !_SS._sections_identical(base_sec6, c6)

                    # integration: an override catalog section that is a value-equal
                    # deepcopy of a DEFAULT section collides its (typename,name) key and
                    # must DEDUP ⇒ a real design (no spurious refusal).
                    heavy_dflt6 = dflt_cat6[argmax([_SR.section_area(s) for s in dflt_cat6])]
                    struc_dd6, base_dd6_0 = _build_beam_column()
                    base_dd6 = with(base_dd6_0; member_group_overrides =
                        Dict{UInt64, MemberGroupSizingOverride}(
                            target_gid => MemberGroupSizingOverride(
                                catalog = [deepcopy(heavy_dflt6)])))
                    @test design_building(struc_dd6, base_dd6) isa BuildingDesign

                    # integration: a name-colliding override section with a DIFFERING
                    # property is STILL refused pinned.
                    diff_sec6 = deepcopy(heavy_dflt6); diff_sec6.Ix = heavy_dflt6.Ix * 0.5
                    struc_df6, base_df6_0 = _build_beam_column()
                    base_df6 = with(base_df6_0; member_group_overrides =
                        Dict{UInt64, MemberGroupSizingOverride}(
                            target_gid => MemberGroupSizingOverride(catalog = [diff_sec6])))
                    _throws_guard(() -> design_building(struc_df6, base_df6))
                end

                # ── [P2] DIRECT size_beams! looseness gate (bypasses the front door).
                @testset "P2 size-time gate refuses looser knob; honors tightening" begin
                    # looser deflection_limit (L/δ ratio 1/180 > global default 1/360)
                    # ⇒ pinned throw at the size-time gate.
                    struc_lo, base_lo = _build_beam_column()
                    prepare!(struc_lo, base_lo)
                    _throws_guard(() -> size_beams!(struc_lo, _SR.SteelBeamOptions();
                        reanalyze = false,
                        member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                            target_gid => MemberGroupSizingOverride(deflection_limit = 1/180))))

                    # looser max_depth (24" > an explicit finite global 12") ⇒ pinned throw.
                    struc_ld, base_ld = _build_beam_column()
                    prepare!(struc_ld, base_ld)
                    _throws_guard(() -> size_beams!(struc_ld,
                        _SR.SteelBeamOptions(max_depth = 12.0u"inch");
                        reanalyze = false,
                        member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                            target_gid => MemberGroupSizingOverride(max_depth = 24.0u"inch"))))

                    # a TIGHTENING knob via the SAME direct path stays HONORED (no throw,
                    # sizes the struc). max_depth 30" is tighter than the default Inf cap
                    # and admits ample adequate sections.
                    struc_ti, base_ti = _build_beam_column()
                    prepare!(struc_ti, base_ti)
                    @test size_beams!(struc_ti, _SR.SteelBeamOptions();
                        reanalyze = false,
                        member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                            target_gid => MemberGroupSizingOverride(
                                max_depth = 30.0u"inch"))) === struc_ti
                end
            end

            # (xiv) PHASE B FIX CYCLE 7 — closing the cycle-6 red-team FAIL: three
            #   findings on the DIRECT public `size_beams!` path (which bypasses the
            #   design_types.jl front-door check 4b) plus the `_field_identical` leaf.
            #   [P1 silent-drop] a DIRECT `size_beams!(struc, SteelBeamOptions(
            #          sizing_strategy=:nlp, section_type=:w); method=:discrete,
            #          member_group_overrides=<effective>)` forces strategy=:discrete,
            #          PASSES the size-time gid gate (real gid, tightening, single-
            #          material, non-composite), builds the union catalog + feasible
            #          mask, then calls StructuralSizer.size_beams which branches NLP on
            #          opts.sizing_strategy (members/optimize/api.jl:123) and DISCARDS
            #          the mask → the override would be SILENTLY DROPPED. The
            #          `size_beams!` guard (keyed on effective_opts.sizing_strategy, NOT
            #          the resolved strategy the forced method masks) refuses it pinned.
            #   [P2 wrong error type] a pure :nlp direct call (no forced method) has no
            #          _size_beams_impl!(::SteelBeamOptions, ::Val{:nlp}) overload → the
            #          same guard throws the PINNED member_group_overrides ArgumentError
            #          instead of a bare MethodError.
            #   [P1/P2 byte-identity] a no-effective-override (vacuous/empty) :nlp call
            #          is UNCHANGED — the guard is a strict no-op, so behavior matches
            #          the no-override :nlp call exactly.
            #   [P2 signed-zero] `_field_identical` now dedups a same-typed numeric leaf
            #          that is value-equal but not `isequal` (0.0 vs -0.0), so a hand-
            #          built override section carrying a signed zero no longer triggers a
            #          spurious pinned refusal; a genuine numeric difference still refuses.
            @testset "Phase B fix cycle 7 (:nlp direct-path guard / signed-zero dedup)" begin
                # ── [P1] forced method=:discrete + :nlp opts ⇒ pinned refusal, NOT a
                #    silent drop (mask discarded by the NLP branch) and NOT a success.
                @testset "P1 forced :discrete over :nlp opts refused pinned (no silent drop)" begin
                    struc_p1, base_p1 = _build_beam_column()
                    prepare!(struc_p1, base_p1)
                    _throws_guard(() -> size_beams!(struc_p1,
                        _SR.SteelBeamOptions(sizing_strategy = :nlp, section_type = :w);
                        method = :discrete, reanalyze = false,
                        member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                            target_gid => MemberGroupSizingOverride(max_depth = 10.0u"inch"))))
                end

                # ── [P2] pure :nlp direct call ⇒ PINNED member_group_overrides
                #    ArgumentError, not a bare MethodError from the missing overload.
                @testset "P2 pure :nlp direct call refused pinned (not MethodError)" begin
                    struc_p2, base_p2 = _build_beam_column()
                    prepare!(struc_p2, base_p2)
                    err = try
                        size_beams!(struc_p2, _SR.SteelBeamOptions(sizing_strategy = :nlp);
                            reanalyze = false,
                            member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                                target_gid => MemberGroupSizingOverride(catalog = [heavy])))
                        nothing
                    catch e
                        e
                    end
                    @test err isa ArgumentError
                    @test !(err isa MethodError)
                    @test err !== nothing && occursin("member_group_overrides", sprint(showerror, err))
                end

                # ── [P1/P2 byte-identity] a vacuous/empty override on a :nlp direct call
                #    must NOT perturb the no-override :nlp behavior (which reaches
                #    dispatch and hits the missing Val{:nlp} overload) — identical
                #    exception TYPE, and in particular NOT the pinned ArgumentError the
                #    guard raises for an EFFECTIVE override.
                @testset "P1/P2 vacuous/empty :nlp override is byte-identical (no throw change)" begin
                    _exc_type(f) = try; f(); nothing; catch e; typeof(e); end

                    struc_b, base_b = _build_beam_column(); prepare!(struc_b, base_b)
                    exc_base = _exc_type(() -> size_beams!(struc_b,
                        _SR.SteelBeamOptions(sizing_strategy = :nlp); reanalyze = false))
                    @test !(exc_base <: ArgumentError)   # pre-fix behavior is a bare MethodError

                    struc_e, base_e = _build_beam_column(); prepare!(struc_e, base_e)
                    exc_empty = _exc_type(() -> size_beams!(struc_e,
                        _SR.SteelBeamOptions(sizing_strategy = :nlp); reanalyze = false,
                        member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}()))
                    @test exc_empty == exc_base

                    struc_v, base_v = _build_beam_column(); prepare!(struc_v, base_v)
                    exc_vac = _exc_type(() -> size_beams!(struc_v,
                        _SR.SteelBeamOptions(sizing_strategy = :nlp); reanalyze = false,
                        member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                            target_gid => MemberGroupSizingOverride())))  # all fields nothing
                    @test exc_vac == exc_base
                end

                # ── [P2 signed-zero] `_field_identical` dedups +0.0 vs -0.0; NaN still
                #    only matches via `isequal` (never via `==`); genuine difference refused.
                @testset "P2 signed-zero numeric leaf dedups; genuine difference refused" begin
                    # 0.0 == -0.0 is true while isequal(0.0, -0.0) is false — the cycle-7
                    # numeric value-equality clause treats them as identical.
                    @test !isequal(0.0, -0.0)                    # precondition (Base semantics)
                    @test (0.0 == -0.0) === true                 # precondition
                    @test _SS._field_identical(0.0, -0.0)
                    @test _SS._field_identical(-0.0, 0.0)
                    # a genuinely-differing numeric leaf still refuses.
                    @test !_SS._field_identical(0.0, 1.0)
                    # NaN is only matched via the isequal clause, never via ==: the
                    # cycle-5 NaN-substitution hazard is NOT reintroduced.
                    @test _SS._field_identical(NaN, NaN)         # isequal(NaN,NaN) === true
                    @test !_SS._field_identical(NaN, 0.0)        # (NaN == 0.0) is false
                    @test !_SS._field_identical(1.0, NaN)        # cycle-6 invariant preserved

                    # section level: two sections differing ONLY by +0.0 vs -0.0 on a
                    # numeric (Unitful) field must DEDUP (no spurious pinned refusal),
                    # while a real numeric difference still refuses (cycle-4 reduced-Ix).
                    dflt_opts7 = _SR.SteelBeamOptions()
                    dflt_cat7 = dflt_opts7.custom_catalog === nothing ?
                        _SR.steel_column_catalog(dflt_opts7.section_type, dflt_opts7.catalog) :
                        dflt_opts7.custom_catalog
                    base_sec7 = first(dflt_cat7)
                    pos7 = deepcopy(base_sec7); pos7.Ix = zero(base_sec7.Ix)
                    neg7 = deepcopy(base_sec7); neg7.Ix = -zero(base_sec7.Ix)
                    @test pos7.Ix == neg7.Ix                     # value-equal
                    @test _SS._field_identical(pos7.Ix, neg7.Ix) # dedup at the Ix leaf
                    @test _SS._sections_identical(pos7, neg7)    # ⇒ whole section dedups
                    diff7 = deepcopy(base_sec7); diff7.Ix = base_sec7.Ix * 0.5
                    @test !_SS._sections_identical(base_sec7, diff7)
                end
            end

            # (xv) PHASE B FIX CYCLE 8 — close the SYMMETRIC strategy gap the cycle-7
            #   red-team found. The cycle-7 `size_beams!` guard keyed on ONE input
            #   (effective_opts.sizing_strategy), so a forced `method=:nlp` with the
            #   default `opts.sizing_strategy=:discrete` slipped past it into the missing
            #   steel `Val{:nlp}` overload → a bare MethodError, violating the pinned
            #   `member_group_overrides` ArgumentError contract. The `size_beams!` guard is
            #   now a POSITIVE allowlist on the single honoring path (SteelBeamOptions +
            #   resolved strategy :discrete + opts.sizing_strategy :discrete), so BOTH
            #   `method` directions, pure :nlp, and non-steel opts are all refused pinned.
            @testset "Phase B fix cycle 8 (symmetric strategy allowlist)" begin
                # ── [P1, NEW] forced method=:nlp over default (:discrete) opts ⇒ the
                #    resolved strategy is :nlp, which has NO steel Val{:nlp} overload; the
                #    allowlist refuses it PINNED before dispatch, NOT a bare MethodError.
                @testset "P1 forced method=:nlp refused pinned (not MethodError)" begin
                    struc_m, base_m = _build_beam_column(); prepare!(struc_m, base_m)
                    err = try
                        size_beams!(struc_m, _SR.SteelBeamOptions(section_type = :w);
                            method = :nlp, reanalyze = false,
                            member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                                target_gid => MemberGroupSizingOverride(max_depth = 10.0u"inch")))
                        nothing
                    catch e
                        e
                    end
                    @test err isa ArgumentError
                    @test !(err isa MethodError)
                    @test err !== nothing && occursin("member_group_overrides", sprint(showerror, err))
                end

                # ── forced method=:discrete over :nlp opts ⇒ still refused pinned: the
                #    resolved strategy is :discrete but opts.sizing_strategy=:nlp routes the
                #    StructuralSizer NLP branch that drops the mask, so it is off the
                #    honor path (opts.sizing_strategy != :discrete).
                @testset "forced method=:discrete over :nlp opts refused pinned" begin
                    struc_d, base_d = _build_beam_column(); prepare!(struc_d, base_d)
                    _throws_guard(() -> size_beams!(struc_d,
                        _SR.SteelBeamOptions(sizing_strategy = :nlp, section_type = :w);
                        method = :discrete, reanalyze = false,
                        member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                            target_gid => MemberGroupSizingOverride(max_depth = 10.0u"inch"))))
                end

                # ── pure :nlp opts (no forced method) ⇒ refused pinned.
                @testset "pure :nlp opts refused pinned" begin
                    struc_n, base_n = _build_beam_column(); prepare!(struc_n, base_n)
                    _throws_guard(() -> size_beams!(struc_n,
                        _SR.SteelBeamOptions(sizing_strategy = :nlp);
                        reanalyze = false,
                        member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                            target_gid => MemberGroupSizingOverride(catalog = [heavy]))))
                end

                # ── [NEW] non-steel opts DIRECT call (ConcreteBeamOptions, resolved
                #    strategy :discrete) ⇒ the allowlist closes the MATERIAL dimension: a
                #    concrete Val{:discrete} overload accepts-and-IGNORES the kwarg (a
                #    silent drop pre-fix), now refused PINNED before dispatch.
                @testset "non-steel opts direct call refused pinned (material dimension)" begin
                    struc_c, base_c = _build_beam_column(); prepare!(struc_c, base_c)
                    _throws_guard(() -> size_beams!(struc_c, _SR.ConcreteBeamOptions();
                        reanalyze = false,
                        member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                            target_gid => MemberGroupSizingOverride(max_depth = 10.0u"inch"))))
                end

                # ── byte-identity: a vacuous (all-unset) override on a forced :nlp call
                #    must NOT perturb the no-override behavior — the allowlist is a strict
                #    no-op (has_eff false), so the exception TYPE matches the no-kwarg call
                #    exactly (a bare MethodError from the missing steel Val{:nlp} overload),
                #    NOT the pinned ArgumentError.
                @testset "vacuous override on :nlp is byte-identical (no throw change)" begin
                    _exc_type(f) = try; f(); nothing; catch e; typeof(e); end
                    struc_b, base_b = _build_beam_column(); prepare!(struc_b, base_b)
                    exc_base = _exc_type(() -> size_beams!(struc_b,
                        _SR.SteelBeamOptions(section_type = :w); method = :nlp,
                        reanalyze = false))
                    @test !(exc_base <: ArgumentError)   # pre-fix behavior is a bare MethodError
                    struc_v, base_v = _build_beam_column(); prepare!(struc_v, base_v)
                    exc_vac = _exc_type(() -> size_beams!(struc_v,
                        _SR.SteelBeamOptions(section_type = :w); method = :nlp,
                        reanalyze = false,
                        member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                            target_gid => MemberGroupSizingOverride())))  # all fields nothing
                    @test exc_vac == exc_base
                end

                # ── honoring UNCHANGED: steel + resolved :discrete + opts.sizing_strategy
                #    :discrete + an effective (tightening) override on a real beam gid stays
                #    on the honor path (allowlist passes through) and sizes the struc.
                @testset "steel-discrete effective override still honored" begin
                    struc_h, base_h = _build_beam_column(); prepare!(struc_h, base_h)
                    @test size_beams!(struc_h, _SR.SteelBeamOptions();
                        reanalyze = false,
                        member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                            target_gid => MemberGroupSizingOverride(
                                max_depth = 30.0u"inch"))) === struc_h
                end
            end

            # (xvi) PHASE B FIX CYCLE 9 — complete the mirror-parity set. The cycle-8
            #   red-team found the LONE remaining gap: front-door check (3)
            #   (`n_max_sections > 0`, design_types.jl) had NO size-time mirror. A DIRECT
            #   `size_beams!(struc, SteelBeamOptions(n_max_sections=2);
            #   member_group_overrides=<effective>)` on the steel-discrete honor path PASSES
            #   the cycle-8 allowlist (steel ✓, resolved :discrete ✓, opts.sizing_strategy
            #   :discrete ✓) and the multi-material / 4b / composite / gid mirrors were all
            #   silent, so the per-group mask reached the COUPLED shared-section MIP the
            #   authors marked "not exact-first-safe" for per-group narrowing — the override
            #   was MIS-HONORED on a public path (a honor-or-throw violation). The new
            #   coupling mirror at the size-time gid gate refuses it PINNED before
            #   `_beam_override_union_and_feasible` builds the mask, so the coupled MIP is
            #   never reached with an effective override. Byte-identity: the default
            #   n_max_sections=0 and a no/vacuous override are strict no-ops.
            @testset "Phase B fix cycle 9 (n_max_sections coupling mirror)" begin
                # ── [P1, NEW] effective steel-discrete override + n_max_sections=2 ⇒
                #    PINNED member_group_overrides ArgumentError at the size-time gate,
                #    BEFORE the mask is built, so the coupled MIP is never reached.
                @testset "P1 n_max_sections>0 + effective override refused pinned" begin
                    struc_nm, base_nm = _build_beam_column(); prepare!(struc_nm, base_nm)
                    err = try
                        size_beams!(struc_nm, _SR.SteelBeamOptions(n_max_sections = 2);
                            reanalyze = false,
                            member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                                target_gid => MemberGroupSizingOverride(catalog = [heavy])))
                        nothing
                    catch e
                        e
                    end
                    @test err isa ArgumentError
                    @test err !== nothing &&
                          occursin("member_group_overrides", sprint(showerror, err))
                end

                # ── [byte-identity] n_max_sections=2 with an EMPTY or vacuous (all-unset)
                #    override dict must NOT trigger the new mirror (has_eff false); the
                #    exception behavior matches the no-override n_max_sections=2 call
                #    exactly (pre-fix), and in particular never the pinned ArgumentError.
                @testset "byte-identity: empty/vacuous override + n_max_sections is no-op" begin
                    _exc_type(f) = try; f(); nothing; catch e; typeof(e); end
                    struc_b, base_b = _build_beam_column(); prepare!(struc_b, base_b)
                    exc_base = _exc_type(() -> size_beams!(struc_b,
                        _SR.SteelBeamOptions(n_max_sections = 2); reanalyze = false))
                    struc_e, base_e = _build_beam_column(); prepare!(struc_e, base_e)
                    exc_empty = _exc_type(() -> size_beams!(struc_e,
                        _SR.SteelBeamOptions(n_max_sections = 2); reanalyze = false,
                        member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}()))
                    @test exc_empty == exc_base
                    struc_v, base_v = _build_beam_column(); prepare!(struc_v, base_v)
                    exc_vac = _exc_type(() -> size_beams!(struc_v,
                        _SR.SteelBeamOptions(n_max_sections = 2); reanalyze = false,
                        member_group_overrides = Dict{UInt64, MemberGroupSizingOverride}(
                            target_gid => MemberGroupSizingOverride())))  # all fields nothing
                    @test exc_vac == exc_base

                    # explicit: the vacuous call never raises the PINNED mirror error.
                    struc_p, base_p = _build_beam_column(); prepare!(struc_p, base_p)
                    pin = try
                        size_beams!(struc_p, _SR.SteelBeamOptions(n_max_sections = 2);
                            reanalyze = false,
                            member_group_overrides =
                                Dict{UInt64, MemberGroupSizingOverride}(
                                    target_gid => MemberGroupSizingOverride()))
                        nothing
                    catch e
                        e
                    end
                    @test pin === nothing ||
                          !occursin("member_group_overrides", sprint(showerror, pin))
                end
            end

            # (xvii) PHASE B WRAP-UP — LAYER-SYMMETRIC DEFENSE-IN-DEPTH on the three
            #   NON-STEEL `_size_beams_impl!` overloads (ConcreteBeamOptions :discrete,
            #   ConcreteBeamOptions :nlp, PixelFrameBeamOptions :discrete). A PUBLIC
            #   caller can never reach these with an EFFECTIVE override — front-door
            #   check (2) (`_assert_member_group_overrides_unsupported`) and the
            #   `size_beams!` honor-path allowlist both refuse a non-steel effective
            #   override upstream — so this is DEFENSE-IN-DEPTH, backstopping a DIRECT
            #   call to the private helper and making the mirror-parity layer symmetric
            #   with the steel `Val{:discrete}` size-time gate. Each overload now self-
            #   guards with the PINNED `member_group_overrides` refusal. The guard fires
            #   at the TOP of the overload (before any sizing/analysis), so a raw fixture
            #   struc suffices. Both non-steel option types are constructible (`_SR`
            #   `Base.@kwdef` structs with all-defaulted fields; ConcreteBeamOptions is
            #   already used in cycle-5 [P0] above).
            @testset "non-steel _size_beams_impl! overloads self-guard (layer-symmetric)" begin
                eff_dd = Dict{UInt64, MemberGroupSizingOverride}(
                    target_gid => MemberGroupSizingOverride(catalog = [heavy]))
                struc_dd, _ = _build_beam_column()
                _throws_guard(() -> _SS._size_beams_impl!(
                    struc_dd, _SR.ConcreteBeamOptions(), Val(:discrete);
                    resolution = 200, reanalyze = false, gravity_factor = GRAVITY,
                    member_group_overrides = eff_dd))
                _throws_guard(() -> _SS._size_beams_impl!(
                    struc_dd, _SR.ConcreteBeamOptions(), Val(:nlp);
                    resolution = 200, reanalyze = false, gravity_factor = GRAVITY,
                    member_group_overrides = eff_dd))
                _throws_guard(() -> _SS._size_beams_impl!(
                    struc_dd, _SR.PixelFrameBeamOptions(), Val(:discrete);
                    resolution = 200, reanalyze = false, gravity_factor = GRAVITY,
                    member_group_overrides = eff_dd))
            end
        end
    end
end

println("\n✓ DesignSession invalidation matrix test passed!")
