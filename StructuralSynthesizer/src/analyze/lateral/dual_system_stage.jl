# Dual-system stage: a moment frame and shear walls (or a concrete core) share
# the lateral load in proportion to their rigidities, and the moment frame alone
# is proportioned for at least 25% of the design seismic force (ASCE 7-22
# §12.2.5.1, corpus: asce-7-22, PDF page 177).
#
# A new stage per decision deci-7a4e26c2 (kept separate from the concrete-wall
# stage, which refuses non-wall systems). It reuses the shared ELF, wind,
# gravity, and design-drift plumbing; the core reuses the wall FEM. The analysis
# backbone (this file) produces the solved cases, the design story drift, and the
# moment-frame designation, then runs the dual-specific checks:
#   1. §12.2.5.1 story-shear-share proxy — in-loop, from the combined model (done),
#   2. frame-member strength with second-order (B1/B2) demands, steel (done; RC pending),
#   3. the separate frame-only capability gate at 25% of the base shear (done; steel).
# Only the RC frame-member path remains, tracked in `struc.stage_diagnostics[:dual]`.

"""Analysis backbone of one dual-system run: drift, θ, and the moment frame."""
struct DualSystemResult
    "Design story-drift checks for both axes, on the §12.8.7 1/(1−θ) multiplier."
    drift::Vector{SeismicStoryDriftCheck}
    "Largest finite θ on the ELF drift cases."
    max_story_stability::Float64
    "§12.8.7 factor 1/(1−θ) for each entry of `drift`, in the same order."
    pdelta_multipliers::Vector{Float64}
    "Moment-frame member designation (indices into struc.beams / struc.columns)."
    moment_frame::@NamedTuple{beams::Vector{Int}, columns::Vector{Int}, source::Symbol}
    "Steel frame-member strength checks (AISC 360-16 App. 8 B1/B2) under the combined-system seismic demands; one entry per checked steel member."
    frame_members::Vector{FrameMemberCheck}
    "§12.2.5.1 25% story-shear-share proxy (in-loop): the moment frame's governing share of each story shear in the combined model, one entry per (story, direction)."
    frame_shares::Vector{FrameShareCheck}
    "§12.2.5.1 frame-only capability gate: bare-frame story stability θ at 25% of the design base shear, one entry per (story, direction)."
    capability_stability::Vector{FrameCapabilityStability}
    "§12.2.5.1 frame-only capability gate: each steel moment-frame member under the 25% frame-only demand (AISC App. 8); one entry per checked steel member."
    capability_members::Vector{FrameMemberCheck}
    "Table 12.2-1 dual row used on the X plan axis."
    row_x::Symbol
    "Table 12.2-1 dual row used on the Y plan axis."
    row_y::Symbol
    "Dual-specific checks not yet built; empty once all three are wired."
    pending::Vector{String}
end

"""
    design_dual_system!(struc, params; tc=nothing) -> DualSystemResult or nothing

Analyze a dual seismic system (ASCE 7-22 §12.2.5.1): a moment frame plus shear
walls / core. Requires `params.lateral` to carry a [`DualSystem`](@ref) on each
axis, the [`BuildingUnit`](@ref) assignment, and `params.wall_inputs` for the
pressures and seismic-provision statements. `R`, `Cd`, and `Ω0` come from each
direction's Table 12.2-1 dual row via `dual_seismic_system`, which refuses a row
that is NP in the Seismic Design Category.

The Asap model must already be processed (`to_asap!` run) with both the moment
frame and the core/walls. A building with no walls returns without a result, the
same convention as the ordinary-wall stage.

This backbone solves the gravity, wind, and ELF cases, measures the design story
drift (with the §12.8.7 P-delta multiplier), records the moment-frame member
designation (user override or auto; see [`moment_frame_members`](@ref)), runs the
§12.2.5.1 in-loop share proxy ([`dual_frame_shear_shares`](@ref)), the steel
frame-member strength checks ([`dual_frame_member_checks`](@ref)), and the
frame-only capability gate at 25% of the base shear
([`dual_frame_capability_gate`](@ref)). Only the RC frame-member path remains,
tracked in `struc.stage_diagnostics[:dual]`.

# Citation
ASCE 7-22 §12.2.5.1 (corpus: asce-7-22, PDF page 177) and Table 12.2-1 Sections
D and E (corpus: asce-7-22, PDF pages 174-175).
"""
function design_dual_system!(struc::BuildingStructure, params::DesignParameters;
                             tc::Union{Nothing, StructuralSizer.TraceCollector}=nothing)
    isempty(struc.walls) && return nothing

    params.lateral === nothing && throw(ArgumentError(
        "dual system stage: params.lateral is nothing. This stage runs only for " *
        "a requested dual seismic system."))
    sx = params.lateral.system_x
    sy = params.lateral.system_y
    for system in (sx, sy)
        system isa DualSystem || throw(ArgumentError(
            "dual system stage: the lateral system is $(typeof(system)). This " *
            "stage analyzes dual systems (ASCE 7-22 §12.2.5.1). A concrete-wall " *
            "system belongs to the ordinary-wall stage."))
    end
    params.lateral.assignment isa BuildingUnit || throw(ArgumentError(
        "dual system stage: the demand assignment is " *
        "$(typeof(params.lateral.assignment)). Only BuildingUnit is accepted."))

    inputs = params.wall_inputs
    inputs isa OrdinaryWallInputs || throw(ArgumentError(
        "dual system stage: lateral design was requested and wall_inputs is " *
        "missing. Wind pressures, ELF inputs, and the seismic-provision " *
        "statements are not assumed."))
    inputs.roof in (:Lr, :S, :R) || throw(ArgumentError(
        "dual system stage: the roof companion must be :Lr, :S, or :R. " *
        "Got $(inputs.roof)."))
    # This stage builds the story geometric stiffness itself; a model already
    # carrying P-delta would be softened twice (ASCE 7-22 §12.8.7).
    inputs.pdelta_included_in_member_forces && throw(ArgumentError(
        "dual system stage: pdelta_included_in_member_forces is true, so the " *
        "solved forces already include P-delta. This stage adds the story " *
        "geometric stiffness and would count it twice (ASCE 7-22 §12.8.7, " *
        "corpus: asce-7-22, PDF page 188). Set the flag to false."))

    struc.asap_model.processed || throw(ArgumentError(
        "dual system stage: the Asap model is not processed. Call to_asap! first " *
        "so the moment frame and the core are assembled and solved."))

    # R, Cd, Ω0 from each axis's dual row; an NP category stops here.
    sysx = dual_seismic_system(table_12_2_1_row(sx), inputs.sdc)
    sysy = dual_seismic_system(table_12_2_1_row(sy), inputs.sdc)
    struc.site.sdc = inputs.sdc

    prepare_lateral_model!(struc, params.lateral)
    mf = moment_frame_members(struc)
    isempty(mf.beams) && throw(ArgumentError(
        "dual system stage: no moment-frame beams were designated. Flag the " *
        "frame with lateral_role=:moment_frame, or provide primary girders " *
        "(role=:girder) for the auto default. The moment frame must resist ≥25% " *
        "of the design seismic force (ASCE 7-22 §12.2.5.1, corpus: asce-7-22, " *
        "PDF page 177)."))

    # Diaphragm handling mirrors the ordinary-wall stage.
    flexible = isempty(struc.asap_rigid_links)
    if struc.diaphragm_layout isa SemirigidDiaphragmLayout
        semirigid_sfrs!(struc, params.lateral)
    elseif flexible
        flexible_diaphragm_layout!(struc, params.lateral)
    else
        struc.diaphragm_layout = nothing
    end

    axis = params.lateral.plan_axis

    basic = solve_gravity_basic_cases(struc; roof=inputs.roof, params=params)
    for (i, symbol) in enumerate(basic.symbols)
        _require_gravity_cut_equilibrium(struc, basic.u[i], basic.loads[i], symbol)
    end

    wind = wind_story_analysis(struc;
        directions=inputs.directions, qz=inputs.qz, qh=inputs.qh, Kd=inputs.Kd,
        G=inputs.G, GCpi=inputs.GCpi, extra_directions=inputs.extra_directions,
        gust_site=inputs.wind_gust_site)

    elf = elf_story_analysis(struc;
        method=inputs.method, SDS=inputs.SDS, S1=inputs.S1,
        R=sysx.R, Ie=inputs.Ie, T=inputs.T, Cd=sysx.Cd, β=inputs.β,
        SD1=inputs.SD1, TL=inputs.TL, Sa=inputs.Sa, Ω0=sysx.Ω0,
        between=inputs.between, Ry=sysy.R, Cdy=sysy.Cd, Ω0y=sysy.Ω0,
        plan_axis=axis, flexible_accidental_torsion=inputs.flexible_accidental_torsion)

    orthogonal = inputs.orthogonal_combination
    effects = seismic_effect_cases(elf; orthogonal)
    drift, pdelta_multipliers = _story_drift_with_pdelta(elf;
        risk_category=inputs.risk_category, system=inputs.drift_system, orthogonal)
    θmax = _max_drift_theta(elf)

    # Increments (1) and (2) read the same first-order full-model solve; build it
    # once (D, L, roof, every wind case, every seismic effect) and share it.
    set = first(values(_build_first_order(struc, basic; wind, elf, effects)))

    # Increment (2): steel frame-member strength under the combined-system seismic
    # demands with AISC 360-16 Appendix 8 B1/B2 amplification (deci-93f9b5ce).
    frame_members, skipped = dual_frame_member_checks(struc, set, basic, elf, effects, inputs, mf)
    failed = count(c -> !c.passed, frame_members)

    # Increment (1): §12.2.5.1 25% story-shear-share proxy — the moment frame's
    # share of each story shear in the combined model (deci-7d2c3467, in-loop).
    frame_shares = dual_frame_shear_shares(struc, set, elf, effects, mf)
    short = count(c -> !c.passed, frame_shares)

    # Increment (3): the authoritative frame-only capability gate — the bare
    # moment frame alone must carry 25% of the design base shear (deci-7d2c3467).
    second = _build_second_order(struc, basic; wind, elf, effects)
    directions = Symbol[:x, :y]
    cap_stability, cap_members, cap_skipped =
        dual_frame_capability_gate(struc, second, basic, elf, effects, inputs, sysx, mf, directions)
    unstable = count(c -> !c.passed, cap_stability)
    cap_failed = count(c -> !c.passed, cap_members)

    pending = String[]  # all three dual-specific checks are now wired (RC member path aside)
    frame_note = "Steel frame-member strength (AISC App. 8 B1/B2): " *
        "$(length(frame_members)) checked, $failed failing" *
        (skipped > 0 ? ", $skipped non-steel member(s) skipped (RC path pending)" : "") * ". "
    share_note = "§12.2.5.1 frame share (in-loop proxy): $(length(frame_shares)) " *
        "story-direction(s) checked, $short below 25%. "
    gate_note = "§12.2.5.1 frame-only capability gate (25% base shear): " *
        "$(length(cap_stability)) story-direction θ check(s), $unstable over θmax; " *
        "$(length(cap_members)) steel member(s), $cap_failed failing" *
        (cap_skipped > 0 ? ", $cap_skipped non-steel skipped (RC path pending)" : "") * "."
    struc.stage_diagnostics[:dual] =
        "Dual-system analysis backbone ran (drift + θ + moment-frame designation). " *
        frame_note * share_note * gate_note

    return DualSystemResult(drift, θmax, pdelta_multipliers, mf, frame_members, frame_shares,
                            cap_stability, cap_members,
                            table_12_2_1_row(sx), table_12_2_1_row(sy), pending)
end
