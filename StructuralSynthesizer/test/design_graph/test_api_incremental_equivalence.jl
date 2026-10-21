# =============================================================================
# API Incremental-Path Equivalence Gate  (Phase 2 P0-1)
# =============================================================================
#
# PROVES the SAFETY CONTRACT of the Phase-2 P0-1 wiring that routes POST /design
# and chat `run_design` through `redesign_incremental!` for a PARAM-ONLY change:
#
#   For any `(struc, base_params)` and any varied `params` whose changed
#   `DesignParameters` fields are DISJOINT from `PREPARE_AFFECTING_FIELDS`, the
#   design the API now returns on the incremental path
#
#       session = DesignSession(struc, base_params)
#       inc     = redesign_incremental!(session.engine, varied_params)
#
#   MUST be output-equivalent (exact-first, rtol=1e-8 / atol=1e-10 on the
#   comprehensive per-member `design_signature`) to the cold reference the API
#   would otherwise have produced
#
#       ref = design_building(struc, varied_params)
#
# This is EXACTLY the engine call `_design_with_incremental!` (api/routes.jl)
# makes when `_param_only_change(session, params)` is true — so comparing
# `redesign_incremental!` vs `design_building` over the same `(struc, params)` is
# the faithful unit of the API routing. We deliberately do NOT spin up the HTTP
# server: the server only *selects* between these two engine calls; the numeric
# safety lives entirely in their equivalence.
#
# It MIRRORS the exact-first harness in
# `scripts/runners/verify_design_graph_incremental.jl` +
# `test/design_graph/_verify_shared.jl` (design_signature / same_signature,
# rtol=1e-8/atol=1e-10; build_flat_plate / build_beam_column fixtures; param-only
# mutation via `SS.with(params; field=val)`). It must NOT load StructuralStudies
# (second-Asap-identity hazard) — it depends ONLY on StructuralSynthesizer and the
# shared verify include, exactly as the runners do.
#
# ADVERSARIAL CASE (chat fast-mode concern):  the chat `run_design` fast path
# CAPS `max_iterations` (and `mip_time_limit_sec`) for a quick preview, then a
# later full run bumps them back up. `max_iterations` is NOT prepare-affecting —
# it lives in the `:slab_sizing` + `:members` node param slices (provenance.jl) —
# so a session baseline built at a CAPPED `max_iterations` that is redesigned up
# to the FULL value must still match a COLD run at the FULL value. If it diverges,
# `max_iterations` is being reused stale and MUST be reclassified prepare-affecting
# (or the chat baseline must be built at full params). We assert equivalence and
# FAIL loudly on any mismatch, naming the field + fixture + signature label.
#
# Usage:
#   SS_ENABLE_VISUALIZATION=false SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD=false \
#       julia --project=StructuralSynthesizer \
#       StructuralSynthesizer/test/design_graph/test_api_incremental_equivalence.jl
#
# Exit code: 0 when all equivalence assertions pass, 1 otherwise.
# =============================================================================

ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] =
    get(ENV, "SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD", "false")

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", ".."))
Pkg.instantiate()

using Asap
using StructuralSizer
using StructuralSynthesizer
using Unitful
using Printf

const SR = StructuralSizer
const SS = StructuralSynthesizer

# Shared verify helpers (design_signature / same_signature). Included AFTER the
# `using` preamble so BuildingDesign + the u"kgCO2e" unit (registered by Asap)
# resolve at include time — same contract as the sibling runners.
include(joinpath(@__DIR__, "_verify_shared.jl"))

# -----------------------------------------------------------------------------
# Fixtures — copied VERBATIM (same spans, params, units) from
# verify_design_graph_incremental.jl so this gate is provenance-comparable to the
# exact-first Run-2 gate. Only the two fixtures this gate needs are reproduced.
# -----------------------------------------------------------------------------

# Flat-plate DDM + spread foundations.
function build_flat_plate(; soil = SR.medium_sand,
                            concrete = NWC_4000,
                            max_iterations::Int = 5)
    skel  = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name               = "test_api_incremental_equivalence_flat_plate",
        floor              = FlatPlateOptions(method = DDM()),
        materials          = MaterialOptions(concrete = concrete, rebar = Rebar_60),
        max_iterations     = max_iterations,
        skip_visualization = true,
        foundation_options = FoundationParameters(
            soil    = soil,
            options = SR.FoundationOptions(strategy = :all_spread),
        ),
    )
    return struc, params
end

# Beam/column vault building: a vault floor routes stage 2 to
# `_size_beams_columns!`, which genuinely sizes steel beams from `params.beams`.
function build_beam_column(; beams = nothing, max_iterations::Int = 5)
    skel  = gen_medium_office(30.0u"ft", 24.0u"ft", 12.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name               = "test_api_incremental_equivalence_beam_column",
        floor              = SR.VaultOptions(lambda = 8.0, material = SR.NWC_4000),
        beams              = beams,
        max_iterations     = max_iterations,
        skip_visualization = true,
    )
    return struc, params
end

# NaN-aware closeness (two NaNs equal) — the `_close` that `same_signature`
# late-binds. Identical numeric behavior (rtol=1e-8, atol=1e-10) to the sibling
# gates; left local per the _verify_shared.jl contract.
function _close(a, b; rtol::Float64 = 1e-8, atol::Float64 = 1e-10)
    if a isa AbstractFloat && b isa AbstractFloat
        (isnan(a) && isnan(b)) && return true
        return isapprox(a, b; rtol = rtol, atol = atol)
    end
    return isequal(a, b)
end

# -----------------------------------------------------------------------------
const CHECKS = Tuple{String, Bool}[]
record!(name, ok) = (push!(CHECKS, (name, ok)); @printf("  %s  %s\n", ok ? "✓" : "✗", name))

"""
    api_equiv(label, fresh_fixture, base_params, varied_params) -> Bool

The faithful API unit. `fresh_fixture()` returns a PRISTINE `(struc, _)` on each
call (design_building mutates `struc`, so cold ref and the session baseline each
need their own). Builds:

  - cold reference: `ref = design_building(struc_ref, varied_params)`
    (what the API returns when it runs cold)
  - incremental:    `session = DesignSession(struc_s, base_params)`;
                    `inc = redesign_incremental!(session.engine, varied_params)`
    (what the API returns on the param-only incremental path)

and records `same_signature(design_signature(ref), design_signature(inc))` at
rtol=1e-8. Returns the pass/fail Bool (so adversarial callers can branch).
"""
function api_equiv(label::String, fresh_fixture, base_params::DesignParameters,
                   varied_params::DesignParameters)
    struc_ref, _ = fresh_fixture()
    ref = design_building(struc_ref, varied_params)

    struc_s, _ = fresh_fixture()
    session = DesignSession(struc_s, base_params)          # exactly what the API caches
    inc = redesign_incremental!(session.engine, varied_params)  # exactly what the API calls

    ok, bad = same_signature(design_signature(ref), design_signature(inc))
    record!("$label: redesign_incremental! == design_building (per-member signature; mismatch: $bad)", ok)
    return ok
end

# -----------------------------------------------------------------------------
function main()
    println("="^70)
    println("API incremental-path equivalence gate (redesign_incremental! == design_building)")
    println("="^70)

    # Heaviest W section (max area ⇒ adequate for any office beam), for the
    # member_group_overrides variation — distinct from the light free optimum.
    all_w = SR.all_W()
    heavy = all_w[argmax([SR.section_area(s) for s in all_w])]

    # ── FIXTURE A: FLAT-PLATE — param-only variations ────────────────────────
    println("\n[A] flat-plate fixture — param-only variations")
    _, base_fp = build_flat_plate()

    # A1. load_combinations change (slab+members node slice, non-prepare-affecting).
    api_equiv("A1 flat-plate load_combinations",
              build_flat_plate, base_fp,
              SS.with(base_fp; load_combinations = [SR.strength_1_2D_1_6L]))

    # A2. foundation soil change (foundations node slice, non-prepare-affecting;
    #     the from-scratch reference uses the SAME varied soil — a real change).
    soil_variant = FoundationParameters(
        soil    = SR.soft_clay,
        options = SR.FoundationOptions(strategy = :all_spread))
    api_equiv("A2 flat-plate foundation soil",
              build_flat_plate, base_fp,
              SS.with(base_fp; foundation_options = soil_variant))

    # A3. benign non-prepare-affecting scalar: optimize_for (members node slice).
    api_equiv("A3 flat-plate optimize_for=:carbon",
              build_flat_plate, base_fp,
              SS.with(base_fp; optimize_for = :carbon))

    # ── FIXTURE B: BEAM-COLUMN VAULT — param-only variations ──────────────────
    println("\n[B] beam/column vault fixture — param-only variations")
    _, base_bc = build_beam_column()

    # B1. load_combinations change on a VAULT (changes the baked thrust via the
    #     governing combo → the case that exercises the sync-path thrust refresh).
    api_equiv("B1 beam-column load_combinations",
              build_beam_column, base_bc,
              SS.with(base_bc; load_combinations = [SR.strength_1_2D_1_6L]))

    # B2. member_group_overrides change — an HONORABLE effective steel-beam-group
    #     override (member node slice). Discover a REAL size-time beam gid from a
    #     designed reference struc (member groups only exist after a sizing pass).
    struc_disc, base_disc = build_beam_column()
    design_building(struc_disc, base_disc)
    beam_gids = sort(unique(group_id(b) for b in struc_disc.beams))
    record!("B2 beam/column fixture exposes >= 1 steel beam group (got $(length(beam_gids)))",
            !isempty(beam_gids))
    target_gid = first(beam_gids)
    ovr = Dict{UInt64, MemberGroupSizingOverride}(
        target_gid => MemberGroupSizingOverride(catalog = [heavy]))
    api_equiv("B2 beam-column member_group_overrides (steel beam gid=$target_gid)",
              build_beam_column, base_bc,
              SS.with(base_bc; member_group_overrides = ovr))

    # ── [ADV] ADVERSARIAL: capped→full max_iterations (chat fast-mode concern) ─
    # Session baseline built at a CAPPED max_iterations (like the chat fast path),
    # then redesigned up to the FULL value, compared to a COLD run at FULL. If
    # these diverge, max_iterations is being reused stale → it must be treated as
    # prepare-affecting (or the chat baseline must use full params). PASS here
    # confirms it is correctly a param-only node-slice field (recompute catches up).
    println("\n[ADV] adversarial: capped-baseline max_iterations → full redesign vs cold-at-full")
    CAP  = 1     # chat fast-mode cap (small)
    FULL = 20    # full run

    # Sanity that the field is NOT prepare-affecting (so the direct
    # redesign_incremental! the API would make is even permitted — a prepare-
    # affecting change would make the engine guard throw instead).
    record!("ADV max_iterations is NOT a prepare-affecting field (param-only)",
            !(:max_iterations in StructuralSynthesizer.PREPARE_AFFECTING_FIELDS))

    # Flat-plate adversarial.
    _, base_cap_fp = build_flat_plate(max_iterations = CAP)
    full_fp = SS.with(base_cap_fp; max_iterations = FULL)
    adv_fp_ok = api_equiv("ADV flat-plate capped($CAP)-baseline → max_iterations=$FULL",
                          () -> build_flat_plate(max_iterations = CAP), base_cap_fp, full_fp)
    # Diagnostic: is capped-vs-full a REAL change on this fixture, or a no-op
    # (design already converged within $CAP iters)? Either way equivalence must
    # hold; this only tells us how much the adversarial case actually stressed.
    sfp_cap, _ = build_flat_plate(max_iterations = CAP)
    cold_cap_fp = design_building(sfp_cap, base_cap_fp)
    sfp_full, _ = build_flat_plate(max_iterations = CAP)
    cold_full_fp = design_building(sfp_full, full_fp)
    same_cf, _ = same_signature(design_signature(cold_cap_fp), design_signature(cold_full_fp))
    @printf("      (flat-plate: cold@%d %s cold@%d — adversarial case is %s)\n",
            CAP, same_cf ? "==" : "!=", FULL,
            same_cf ? "a convergence no-op (still a valid reuse check)" : "a REAL iteration-count change")

    # Beam-column adversarial.
    _, base_cap_bc = build_beam_column(max_iterations = CAP)
    full_bc = SS.with(base_cap_bc; max_iterations = FULL)
    adv_bc_ok = api_equiv("ADV beam-column capped($CAP)-baseline → max_iterations=$FULL",
                          () -> build_beam_column(max_iterations = CAP), base_cap_bc, full_bc)
    sbc_cap, _ = build_beam_column(max_iterations = CAP)
    cold_cap_bc = design_building(sbc_cap, base_cap_bc)
    sbc_full, _ = build_beam_column(max_iterations = CAP)
    cold_full_bc = design_building(sbc_full, full_bc)
    same_cb, _ = same_signature(design_signature(cold_cap_bc), design_signature(cold_full_bc))
    @printf("      (beam-column: cold@%d %s cold@%d — adversarial case is %s)\n",
            CAP, same_cb ? "==" : "!=", FULL,
            same_cb ? "a convergence no-op (still a valid reuse check)" : "a REAL iteration-count change")

    # ── Summary ──────────────────────────────────────────────────────────────
    println("\n" * "="^70)
    npass = count(c -> c[2], CHECKS)
    if npass == length(CHECKS)
        println("✓ ALL EQUIVALENCE CHECKS PASS ($npass/$(length(CHECKS)))")
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
