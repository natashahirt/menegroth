# =============================================================================
# Warm-State Incremental Engine Verify Harness (Run 6)
# =============================================================================
#
# Proves the Run-6 warm-state / factorization-aware reuse additions are
# EXACT-FIRST — every opt-in reuse path is bit-identical to the cold path it
# replaces — WITHOUT touching the external/Asap submodule and WITHOUT perturbing
# the default (cold) path (the existing gates cover that unchanged).
#
#   1. WARM == COLD ENGINE — an incremental run with `warm=true` (routing the
#      shared read-only column P-M cache into slab-node reruns, Part C) yields a
#      byte-identical `design_signature` AND an identical `last_recomputed` set
#      as the default `warm=false` run, for:
#        (i)   a full incremental run (all nodes dirty),
#        (ii)  a loads-only variation (`:load_combinations` — dirties the whole
#              chain, exercising the warm slab-cache reuse),
#        (iii) a members-only variation (`:collinear_grouping` — dirties only
#              `:members`).
#   2. FACTORIZATION REUSE (Part A) — `sync_asap!(...; loads_only=true)` reuses
#      the cached CHOLMOD factor and re-solves the new RHS; with K unchanged this
#      is bit-identical (element forces AND global `u`) to the default full
#      `sync_asap!` that refactorizes.
#   3. MIP WARM START (Part B) — seeding `optimize_discrete` with a prior solution
#      (`mip_start`) does NOT change the chosen sections when the solver proves
#      `OPTIMAL`: a correct prior start and a deliberately-wrong prior start both
#      return the cold optimum. The warm result is trusted ONLY under `OPTIMAL`.
#
# Usage:
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer \
#       scripts/runners/verify_warm_state_incremental.jl
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
# Fixture: identical 2×2-bay flat-plate DDM building used by the Run-2 gate, so
# the warm-vs-cold comparison exercises the same structure as the exact-first
# reference.
# -----------------------------------------------------------------------------
function build_building(; soil = SR.medium_sand)
    skel  = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name               = "verify_warm_state_incremental",
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

# Comprehensive per-member design signature — the same bit-identity signature the
# Run-2 gate uses (columns, beams, slabs, foundations, summary).
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
        push!(sig, "beam$k.weight_kg"     => ustrip(u"kg", b.weight))
    end
    for k in sort(collect(keys(design.slabs)))
        s = design.slabs[k]
        push!(sig, "slab$k.thk_m"       => ustrip(u"m", s.thickness))
        push!(sig, "slab$k.M0_kNm"      => isnothing(s.M0) ? NaN : ustrip(u"kN*m", s.M0))
        push!(sig, "slab$k.defl_ratio"  => s.deflection_ratio)
        push!(sig, "slab$k.punch_ratio" => s.punching_max_ratio)
        push!(sig, "slab$k.converged"   => s.converged)
        push!(sig, "slab$k.n_stud_cols" => s.n_stud_cols)
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
        push!(sig, "fdn$k.L_ft"          => ustrip(u"ft",   f.length))
        push!(sig, "fdn$k.W_ft"          => ustrip(u"ft",   f.width))
        push!(sig, "fdn$k.D_in"          => ustrip(u"inch", f.depth))
        push!(sig, "fdn$k.bearing_ratio" => f.bearing_ratio)
        push!(sig, "fdn$k.ok"            => f.ok)
    end
    push!(sig, "sum.all_checks_pass" => design.summary.all_checks_pass)
    push!(sig, "sum.critical_ratio"  => design.summary.critical_ratio)
    push!(sig, "sum.ec_kgco2e"       => ustrip(u"kgCO2e", design.summary.embodied_carbon))
    return sig
end

_close(a, b) = (a isa AbstractFloat && b isa AbstractFloat) ?
    ((isnan(a) && isnan(b)) || isapprox(a, b; rtol = 0.0, atol = 0.0) || a == b) :
    isequal(a, b)

"Compare two design signatures for EXACT identity; returns (ok, first_mismatch)."
function same_signature(a, b)
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

# Run the SAME variation on a cold and a warm engine and assert byte-identity of
# both the captured design and the recomputed-node set.
function warm_equals_cold!(label, cold_engine, warm_engine, params)
    d_cold = redesign_incremental!(cold_engine, params; warm = false)
    d_warm = redesign_incremental!(warm_engine, params; warm = true)
    ok_sig, bad = same_signature(design_signature(d_cold), design_signature(d_warm))
    record!("$label: warm design == cold design (mismatch: $bad)", ok_sig)
    rc_cold = SS.last_recomputed(cold_engine)
    rc_warm = SS.last_recomputed(warm_engine)
    record!("$label: warm last_recomputed == cold ($(rc_cold) vs $(rc_warm))",
            Set(rc_cold) == Set(rc_warm))
    return nothing
end

function main()
    println("="^70)
    println("Warm-state incremental verify — warm reuse == cold (exact-first)")
    println("="^70)

    struc_cold, params = build_building()
    struc_warm, _      = build_building()
    cold = prepare_engine(struc_cold, params)
    warm = prepare_engine(struc_warm, params)

    # ── 1. Warm == cold across a variation sequence ─────────────────────────
    println("\n[1] Warm-state reuse is bit-identical to the cold path")
    warm_equals_cold!("full run", cold, warm, params)

    # (ii) loads-only variation — dirties the whole chain, so the warm slab nodes
    #      reuse the shared column P-M cache.
    params_load = SS.with(params;
        load_combinations = [SR.LoadCombination(name = :custom, D = 1.4, L = 1.7)])
    warm_equals_cold!("loads-only (:load_combinations)", cold, warm, params_load)

    # (iii) members-only variation — `:collinear_grouping` is a members-slice input,
    #       so only `:members` recomputes.
    params_mem = SS.with(params_load; collinear_grouping = true)
    warm_equals_cold!("members-only (:collinear_grouping)", cold, warm, params_mem)
    record!("members-only recomputes only :members (got $(SS.last_recomputed(warm)))",
            SS.last_recomputed(warm) == [SS.NODE_MEMBERS])

    # ── 2. Factorization reuse: loads_only sync == full sync (Part A) ───────
    println("\n[2] sync_asap!(loads_only=true) is bit-identical to the full sync")
    # `warm.struc` holds the terminal post-state with a solved model (processed,
    # factor present, K current). A full re-sync refactorizes; a loads_only
    # re-sync reuses the factor. With K unchanged both must be bit-identical.
    SS.sync_asap!(warm.struc; params = params_mem, loads_only = false)
    model = warm.struc.asap_model
    forces_full = [copy(el.forces) for el in model.elements]
    u_full = copy(model.u)

    SS.sync_asap!(warm.struc; params = params_mem, loads_only = true)
    forces_lo = [copy(el.forces) for el in model.elements]
    u_lo = copy(model.u)

    forces_match = length(forces_full) == length(forces_lo) &&
        all(isequal(forces_full[i], forces_lo[i]) for i in eachindex(forces_full))
    record!("loads_only element forces bit-identical to full sync", forces_match)
    record!("loads_only global displacement u bit-identical to full sync",
            isequal(u_full, u_lo))

    # ── 3. MIP warm start does not change the optimum (Part B) ──────────────
    println("\n[3] MIP warm start preserves the optimum (OPTIMAL-gated)")
    Mu = [150.0, 220.0, 90.0] .* u"kN*m"
    Vu = [100.0, 120.0, 60.0] .* u"kN"
    geoms = [SR.SteelMemberGeometry(8.0; Kx = 1.0, Ky = 1.0) for _ in 1:3]
    opts = SR.SteelBeamOptions(section_type = :w)

    r_cold = SR.size_beams(Mu, Vu, geoms, opts)
    # `status` is a JuMP/MOI `TerminationStatusCode`; compare by name to avoid a
    # direct JuMP dependency in the runner. Warm results are trusted ONLY here.
    is_opt(r) = string(r.status) == "OPTIMAL"
    if is_opt(r_cold)
        # Correct prior start.
        r_warm = SR.size_beams(Mu, Vu, geoms, opts; mip_start = copy(r_cold.section_indices))
        record!("warm start (correct prior) reaches OPTIMAL", is_opt(r_warm))
        record!("warm start (correct prior) == cold sections",
                is_opt(r_warm) && r_warm.section_indices == r_cold.section_indices)

        # Deliberately-wrong prior start (all group 1's section) — a hint only, so
        # the proven optimum must be unchanged.
        bad = fill(r_cold.section_indices[1], length(r_cold.section_indices))
        r_bad = SR.size_beams(Mu, Vu, geoms, opts; mip_start = bad)
        record!("warm start (wrong prior) == cold sections when OPTIMAL",
                is_opt(r_bad) && r_bad.section_indices == r_cold.section_indices)
    else
        record!("cold MIP reached OPTIMAL (prerequisite for warm-start checks)", false)
    end

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
