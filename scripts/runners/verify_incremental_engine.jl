# =============================================================================
# Incremental Engine Verify Harness (Run 2)
# =============================================================================
#
# Proves the new demand-driven incremental engine (prepare_engine / run_target! /
# redesign_incremental!) is CORRECT and behaves as specified, WITHOUT touching
# the untouched `design_building` reference:
#
#   1. FULL-RUN EQUIVALENCE — a full incremental run (all nodes dirty) captures a
#      BuildingDesign that matches `design_building` at rtol=1e-8 on BOTH the 15
#      aggregate invariants AND a comprehensive per-member signature (beam sizes,
#      column/beam capacity+interaction+axial ratios, ok flags, punching stud
#      counts, per-strip rebar; see `design_signature`). This is the exact-first
#      safety check — the aggregate scalars alone cannot catch a per-member
#      provenance omission.
#   2. IDEMPOTENT REUSE — re-running with identical params recomputes NOTHING
#      (all nodes restored from the memo) and yields the same design.
#   3. SELECTIVE RECOMPUTE + EARLY CUTOFF — changing only foundation params
#      recomputes only :foundations; :slab_sizing/:members are served clean. The
#      redesigned result matches a fresh design_building on the new params.
#   4. DIRTY FRONTIER (observable, no run) — the frontier for a foundation-only
#      change is exactly [:foundations]; a load-combination change reaches the
#      whole chain.
#   5. BASELINE GUARD — changing a prepare-affecting param (materials) is refused
#      (ArgumentError), never silently reused against a stale baseline.
#
# Usage:
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer \
#       scripts/runners/verify_incremental_engine.jl
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
# Fixture: 2×2-bay flat-plate DDM building with spread foundations (matches the
# Run-1 verify harness so both gates exercise the same structure).
# -----------------------------------------------------------------------------
function build_building(; soil = SR.medium_sand)
    skel  = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name               = "verify_incremental_engine",
        floor              = FlatPlateOptions(method = DDM()),
        materials          = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
        max_iterations     = 5,
        skip_visualization = true,
        foundation_options = FoundationParameters(
            soil    = soil,
            options = SR.FoundationOptions(strategy = :all_spread),
        ),
    )
    return struc, params
end

# Comparable invariant tuple (a subset of the Run-1 harness set — enough to
# detect any divergence in slabs, columns, embodied carbon, and foundations).
function invariants(design::BuildingDesign)
    slabs = collect(values(design.slabs))
    h_m   = maximum(ustrip(u"m", s.thickness) for s in slabs)
    M0    = maximum(isnothing(s.M0) ? NaN : ustrip(u"kN*m", s.M0) for s in slabs)
    punch = maximum(s.punching_max_ratio for s in slabs)
    defl  = maximum(s.deflection_ratio for s in slabs)
    cols  = [ustrip(u"inch", c.c1) for c in values(design.columns) if c.c1 > 0.0u"m"]
    col_min = isempty(cols) ? NaN : minimum(cols)
    col_max = isempty(cols) ? NaN : maximum(cols)
    ec = ustrip(u"kgCO2e", design.summary.embodied_carbon)
    B = L = D = util = NaN
    for f in values(design.foundations)
        B = isnan(B) ? ustrip(u"ft", f.width)   : max(B, ustrip(u"ft", f.width))
        L = isnan(L) ? ustrip(u"ft", f.length)  : max(L, ustrip(u"ft", f.length))
        D = isnan(D) ? ustrip(u"inch", f.depth) : max(D, ustrip(u"inch", f.depth))
        u = max(f.bearing_ratio, f.punching_ratio, f.flexure_ratio)
        util = isnan(util) ? u : max(util, u)
    end
    return (h_m=h_m, M0=M0, punch=punch, defl=defl, col_min=col_min, col_max=col_max,
            ec=ec, fdn_B=B, fdn_L=L, fdn_D=D, fdn_util=util)
end

_close(a, b) = (a isa AbstractFloat && b isa AbstractFloat) ?
    ((isnan(a) && isnan(b)) || isapprox(a, b; rtol=1e-8, atol=1e-10)) : isequal(a, b)

function same_invariants(a, b)
    for k in keys(a)
        _close(getproperty(a, k), getproperty(b, k)) || return (false, k)
    end
    return (true, :none)
end

# -----------------------------------------------------------------------------
# Comprehensive per-member design signature (P2 hardening).
# -----------------------------------------------------------------------------
# The `invariants` tuple above is an AGGREGATE summary (global maxima); it is NOT
# bit-identical — it omits per-member beam sizes, column/beam
# capacity/interaction/axial ratios, ok/feasibility flags, punching stud counts,
# and per-strip rebar, so a provenance omission (e.g. an unpatterned member) can
# slip past it. `design_signature` flattens EVERY such output field into a
# deterministic (label => value) list; equal signatures ⇒ output-equivalent
# across all compared fields (values reduced to plain Float64/Bool/String/Symbol).
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
const CHECKS = Tuple{String, Bool}[]
record!(name, ok) = (push!(CHECKS, (name, ok)); @printf("  %s  %s\n", ok ? "✓" : "✗", name))

# Fine per-slab topology: `:slab_sizing` is decomposed into one `:slab_sizing_s{idx}`
# node per slab. Enumerate the actual slab-node keys from the graph so the
# recomputed/restored/frontier assertions are independent of the slab count.
slab_node_keys(g) = NodeKey[k for k in SS.topological_order(g) if SS.is_slab_node_key(k)]
slab_stage_set(g) = Set(slab_node_keys(g))

function main()
    println("="^70)
    println("Incremental Engine verify — engine vs design_building")
    println("="^70)

    # ── 1. Full-run equivalence ────────────────────────────────────────────
    println("\n[1] Full incremental run == design_building")
    struc_ref, params = build_building()
    ref = design_building(struc_ref, params)
    ref_inv = invariants(ref)

    struc_e, _ = build_building()
    engine = prepare_engine(struc_e, params)
    recomputed, restored = run_target!(engine, params)
    inc = capture_incremental_design(engine, params)
    inc_inv = invariants(inc)

    ok_eq, badk = same_invariants(ref_inv, inc_inv)
    record!("full run matches design_building (mismatch: $badk)", ok_eq)
    ok_sig, badsig = same_signature(design_signature(ref), design_signature(inc))
    record!("full run comprehensive per-member signature matches (mismatch: $badsig)", ok_sig)
    expected_all = Set(slab_node_keys(engine.graph)) ∪ Set([NODE_MEMBERS, NODE_FOUNDATIONS])
    record!("first run recomputes all sizing nodes (got $(recomputed))",
            Set(recomputed) == expected_all)
    record!("first run restores nothing", isempty(restored))

    # ── 2. Idempotent reuse ────────────────────────────────────────────────
    println("\n[2] Re-run identical params → all restored, nothing recomputed")
    rc2, rs2 = run_target!(engine, params)
    inc2 = capture_incremental_design(engine, params)
    ok2, badk2 = same_invariants(ref_inv, invariants(inc2))
    record!("idempotent re-run recomputes nothing (got $(rc2))", isempty(rc2))
    record!("idempotent re-run restores all sizing nodes",
            Set(rs2) == expected_all)
    record!("idempotent re-run design unchanged (mismatch: $badk2)", ok2)

    # ── 3. Selective recompute + early cutoff (foundation-only change) ──────
    println("\n[3] Change foundation soil → only :foundations recomputes")
    params_soft = SS.with(params;
        foundation_options = FoundationParameters(
            soil    = SR.soft_clay,
            options = SR.FoundationOptions(strategy = :all_spread)))
    rc3, rs3 = run_target!(engine, params_soft)
    inc3 = capture_incremental_design(engine, params_soft)
    record!("only :foundations recomputed (got $(rc3))", rc3 == [NODE_FOUNDATIONS])
    record!("slab nodes + :members restored (early cutoff, got $(rs3))",
            Set(rs3) == (Set(slab_node_keys(engine.graph)) ∪ Set([NODE_MEMBERS])))

    # Redesigned result must match a fresh design_building on the same params.
    struc_ref3, _ = build_building(soil = SR.soft_clay)
    ref3 = design_building(struc_ref3, params_soft)
    ok3, badk3 = same_invariants(invariants(ref3), invariants(inc3))
    record!("soft-clay redesign matches design_building (mismatch: $badk3)", ok3)
    ok3sig, bad3sig = same_signature(design_signature(ref3), design_signature(inc3))
    record!("soft-clay redesign comprehensive signature matches (mismatch: $bad3sig)", ok3sig)
    # Slabs/columns must be identical to the original design (only soil changed).
    inc3_inv = invariants(inc3)
    record!("slab/column invariants unchanged by soil swap",
            _close(inc3_inv.h_m, ref_inv.h_m) &&
            _close(inc3_inv.col_max, ref_inv.col_max) &&
            _close(inc3_inv.punch, ref_inv.punch))

    # ── 4. Dirty frontier (observable, no execution) ───────────────────────
    println("\n[4] dirty_frontier resolver")
    fr_fdn = dirty_frontier(engine.graph, [:foundation_options])
    record!("foundation_options → frontier == [:foundations] (got $(fr_fdn))",
            fr_fdn == [NODE_FOUNDATIONS])
    fr_load = dirty_frontier(engine.graph, [:load_combinations])
    record!("load_combinations → frontier reaches whole chain (got $(fr_load))",
            Set(fr_load) == (Set(slab_node_keys(engine.graph)) ∪ Set([NODE_MEMBERS, NODE_FOUNDATIONS])))
    fr_none = dirty_frontier(engine.graph, [:name, :description, :display_units])
    record!("cosmetic params → empty frontier (got $(fr_none))", isempty(fr_none))

    # changed_param_fields sanity
    cf = changed_param_fields(params, params_soft)
    record!("changed_param_fields detects foundation_options change",
            :foundation_options in cf)

    # ── 5. Baseline guard ──────────────────────────────────────────────────
    println("\n[5] Prepare-affecting change is refused")
    params_mat = SS.with(params; materials = MaterialOptions(concrete = NWC_6000, rebar = Rebar_60))
    guarded = false
    try
        run_target!(engine, params_mat)
    catch e
        guarded = e isa ArgumentError
    end
    record!("changing :materials throws ArgumentError (guard)", guarded)

    # ── Summary ─────────────────────────────────────────────────────────────
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
