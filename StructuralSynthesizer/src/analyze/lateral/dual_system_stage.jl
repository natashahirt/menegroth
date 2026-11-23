# Dual-system stage: a moment frame and shear walls (or a concrete core) share
# the lateral load in proportion to their rigidities, and the moment frame alone
# is proportioned for at least 25% of the design seismic force (ASCE 7-22
# §12.2.5.1, corpus: asce-7-22, PDF page 177).
#
# A new stage per decision deci-7a4e26c2 (kept separate from the concrete-wall
# stage, which refuses non-wall systems). It reuses the shared ELF, wind,
# gravity, and design-drift plumbing; the core reuses the wall FEM. The analysis
# backbone (this file) produces the solved cases, the design story drift, and the
# moment-frame designation. The three dual-specific checks are wired in follow-on
# increments and, until then, are named in `struc.stage_diagnostics[:dual]`:
#   1. §12.2.5.1 story-shear-share proxy (needs the per-story frame/wall split),
#   2. frame-member strength with second-order (B1/B2) demands for steel/RC,
#   3. the separate frame-only capability gate at 25% of the base shear.

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
drift (with the §12.8.7 P-delta multiplier), and records the moment-frame member
designation (user override or auto; see [`moment_frame_members`](@ref)). The
§12.2.5.1 share check, the frame-member strength checks, and the frame-only
capability gate are recorded as pending in `struc.stage_diagnostics[:dual]` until
their increments land.

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
    effects = seismic_effect_cases(elf; orthogonal)   # built for the pending checks
    drift, pdelta_multipliers = _story_drift_with_pdelta(elf;
        risk_category=inputs.risk_category, system=inputs.drift_system, orthogonal)
    θmax = _max_drift_theta(elf)

    pending = [
        "§12.2.5.1 25% story-shear-share proxy (per-story frame/wall split)",
        "frame-member strength with B1/B2 second-order demands (steel/RC)",
        "separate frame-only capability gate at 25% of the design base shear",
    ]
    struc.stage_diagnostics[:dual] =
        "Dual-system analysis backbone ran (drift + θ + moment-frame designation). " *
        "Pending dual-specific checks: " * join(pending, "; ") * "."

    return DualSystemResult(drift, θmax, pdelta_multipliers, mf,
                            table_12_2_1_row(sx), table_12_2_1_row(sy), pending)
end
