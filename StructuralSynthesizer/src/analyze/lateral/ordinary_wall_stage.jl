# Ordinary concrete wall checks inside design_building.
#
# Each straight pier is checked on its own cut, including a leg of a joined
# assembly. Thickness stays fixed. A joined leg uses its clear length.
# ρl and ρt are raised on a fixed grid when the given ratios fail a strength
# check. A failing check is recorded. The corner between legs is shear friction.

"""Checks and seismic story-drift comparisons for one ordinary-wall run."""
struct OrdinaryWallResult
    checks::Dict{Int, Vector{WallCheckRecord}}
    drift::Vector{SeismicStoryDriftCheck}
    "Largest finite θ on the ELF drift cases."
    max_story_stability::Float64
    "§12.8.7 factor 1/(1−θ) for each entry of `drift`, in the same order."
    pdelta_multipliers::Vector{Float64}
    "Wall share of the unfactored dead vertical force, one entry per story."
    gravity_shares::Vector{WallGravityShare}
    "Empty unless the lateral system is row F."
    interactive_shear::Vector{InteractiveStoryShearCheck}
    "Empty unless the lateral system is row F."
    frame_members::Vector{FrameMemberCheck}
    "Type 5 as used: the caller's statement, or a nonparallel element found in the geometry."
    type5_horizontal_irregularity::Bool
    "Walls (and row F beams) on neither plan axis."
    nonparallel_elements::Vector{String}
    "True when the §12.5.1.2(a) 100% + 30% effects were used instead of one direction at a time."
    orthogonal_combination::Bool
end

"""
    design_ordinary_walls!(struc, params; tc=nothing) -> OrdinaryWallResult or nothing

Check every ordinary pier when `params.lateral` is set. A joined assembly
is checked leg by leg. The corner is shear friction.

`lateral === nothing` clears `struc.ordinary_wall_result` and returns. A
gravity-only building is not given wind or seismic cases.

When lateral design was requested:

- `wall_inputs` is required. Pressures, `ρ`, and the seismic statements are
  not assumed. `R`, `Cd`, and `Ω0` come from the Table 12.2-1 row of each
  direction. A Seismic Design Category that a row marks NP is refused.
- Each direction is [`WallsSeismicSystem`](@ref) (`:A3` or `:B6`) or
  [`InteractiveShearWallFrameSystem`](@ref) (row F). The assignment is
  [`BuildingUnit`](@ref). [`OutriggerSystem`](@ref) and
  [`IsolatedWallShare`](@ref) are refused rather than given a pier fallback.
  §12.2.5.8 runs only in a direction whose system is row F.
- Row B.6 is refused when the walls carry more than 20% of a story's
  unfactored dead vertical force. The 20% is a project limit for commentary
  C12.2.1. The share is reported for every row.
- Row F checks §12.2.5.8. The walls' Σ φVn must be at least 75% of the design
  story shear, and ρt is raised on the grid when it is short. The frames are
  solved without the wall shells at 25% of the story shear. A frame member
  with no reinforced-concrete section is recorded as failing.
- A joined assembly is checked leg by leg on the clear length. The corner is
  shear friction. The special-wall flange width is not applied.
- Story forces need rigid-diaphragm masters (`diaphragm_mode = :rigid`).
- Demands are the unified frame-shell solution: unfactored gravity, Chapter 27
  wind, and ELF strength cases. Each strength combination is applied once per
  group (gravity with wind and earthquake omitted, each wind case, each `QE`
  case). Wind cases are not crossed with `QE` cases.
- Thickness and length are not changed. `ρt` is set from the largest
  shear, then `ρl` walks up the grid until axial-flexure passes. A ratio
  already on the wall is not reduced. This function does not scale shell
  `E`. When `wall_inputs` states cracked stiffness, `to_asap!` has already
  applied it.
- Member forces include second-order story sway. Each distinct factored
  gravity `(D, L, roof)` builds one story stiffness from the vertical forces
  of that gravity, and the unfactored cases are solved on it and superposed
  (Wilson & Habibullah 1987, Eq. 7, corpus: wilson-habibullah-1987-pdelta,
  PDF page 6). ACI 318-19 §11.4.1.3 (PDF page 169) sends walls to §6.6.4,
  §6.7, or §6.8, and §6.2.5.3 (PDF page 72) records a failing check when a
  factored moment exceeds 1.4 times the first-order moment.
- Design story drifts stay on the ASCE 7-22 §12.8.7 multiplier `1/(1−θ)`
  (corpus: asce-7-22, PDF page 188). Member forces are not multiplied by it
  as well. θ > θmax is refused by the ELF analysis. The factor is 1 where
  θ ≤ 0.10.
- Seismic Design Categories D, E, and F still throw from
  [`system_checks`](@ref): deformation compatibility is not built.
- "X" and "Y" are the plan axes of `params.lateral.plan_axis`. A wall or a
  row F beam on neither axis is a Type 5 nonparallel system irregularity
  (Table 12.3-1, corpus: asce-7-22, PDF page 180), whatever the caller stated.
  Such an element is refused when the two axes have different systems:
  §12.2.2 gives each orthogonal axis its own row, and the element is in both.
- The 100% + 30% effects of §12.5.1.2(a) replace the one-direction cases
  when `wall_inputs.orthogonal_combination` asks for them, or when §12.5.3 or
  §12.5.4 does not permit the independent procedure. Wall forces, the row F
  frame forces, and story drift then use those 16 effects. Story drift is
  checked along both axes of every effect.
- A skewed wall counts `φVn·|cos α|` toward the row F 75% sum on each axis.

The story cut at each pier bottom is checked for the unfactored gravity cases,
and again for each factored-gravity displacement on its story stiffness. A
cut that does not balance withholds the wall checks.

`rho` is applied to `Eh` on the earthquake combinations, so the seismic gate
is called with `rho_applied_to_eh = true`.
"""
function design_ordinary_walls!(struc::BuildingStructure, params::DesignParameters;
                                tc::Union{Nothing, StructuralSizer.TraceCollector}=nothing)
    if params.lateral === nothing
        struc.ordinary_wall_result = nothing
        return nothing
    end
    StructuralSizer.emit!(tc, :pipeline, "design_ordinary_walls!", "stage_ordinary_walls", :enter)
    # A throw below must not leave a previous run's checks in place.
    struc.ordinary_wall_result = nothing

    inputs = params.wall_inputs
    inputs isa OrdinaryWallInputs || throw(ArgumentError(
        "ordinary wall stage: lateral design was requested and wall_inputs is " *
        "missing. Wind pressures, ELF inputs, and the seismic-provision " *
        "statements are not assumed."))
    sx = params.lateral.system_x
    sy = params.lateral.system_y
    for system in (sx, sy)
        (system isa WallsSeismicSystem || system isa InteractiveShearWallFrameSystem) ||
            throw(ArgumentError(
                "ordinary wall stage: the lateral system is $(typeof(system)). " *
                "This stage checks ordinary concrete walls. Another system is not " *
                "given a wall-pier fallback."))
    end
    params.lateral.assignment isa BuildingUnit || throw(ArgumentError(
        "ordinary wall stage: the demand assignment is " *
        "$(typeof(params.lateral.assignment)). Only BuildingUnit, the pier " *
        "cut of the unified displacement, is accepted."))
    inputs.roof in (:Lr, :S, :R) || throw(ArgumentError(
        "ordinary wall stage: the roof companion must be :Lr, :S, or :R, " *
        "the one roof pressure on the building. Got $(inputs.roof)."))
    # This stage builds the story stiffness itself. A model that already
    # carried P-delta would be softened twice.
    if inputs.pdelta_included_in_member_forces
        throw(ArgumentError(
            "ordinary wall stage: pdelta_included_in_member_forces is true, so " *
            "the solved forces already include P-delta. This stage adds the " *
            "story geometric stiffness and would count it twice. Member forces " *
            "are not also multiplied by 1/(1−θ) (ASCE 7-22 §12.8.7, corpus: " *
            "asce-7-22, PDF page 188). Set the flag to false."))
    end
    # R, Cd, and Ω0 are each direction's row. A category a row marks NP stops here.
    sysx = ordinary_concrete_seismic_system(table_12_2_1_row(sx), inputs.sdc)
    sysy = ordinary_concrete_seismic_system(table_12_2_1_row(sy), inputs.sdc)

    prepare_lateral_model!(struc, params.lateral)
    if isempty(struc.asap_rigid_links)
        throw(ArgumentError(
            "ordinary wall stage: wind and seismic story forces need " *
            "rigid-diaphragm masters, and asap_rigid_links is empty. Set " *
            "DesignParameters.diaphragm_mode to :rigid before prepare!."))
    end
    isempty(struc.wall_mesh.piers) && throw(ArgumentError(
        "ordinary wall stage: the wall mesh is empty. to_asap! has not meshed the walls."))

    axis = params.lateral.plan_axis
    row_f = sx isa InteractiveShearWallFrameSystem || sy isa InteractiveShearWallFrameSystem
    nonparallel = nonparallel_system_elements(struc, axis; frames=row_f)
    if !isempty(nonparallel) && !_systems_agree(sx, sy)
        throw(ArgumentError(
            "ordinary wall stage: $(first(nonparallel)) is on neither plan axis, and " *
            "the two axes have different seismic systems. ASCE 7-22 §12.2.2 (corpus: " *
            "asce-7-22, PDF page 176) assigns a system to each orthogonal axis. An " *
            "element on neither axis resists both, so it has no single row. Use one " *
            "system, or a plan axis the element is parallel to."))
    end
    # Table 12.3-1 Type 5 (corpus: asce-7-22, PDF page 180).
    type5 = inputs.type5_horizontal_irregularity || !isempty(nonparallel)
    # ASCE 7-22 §12.5.2–§12.5.4 (corpus: asce-7-22, PDF pages 183–184).
    orthogonal = inputs.orthogonal_combination || orthogonal_combination_required(;
        sdc=inputs.sdc,
        type1_horizontal_irregularity=inputs.type1_horizontal_irregularity,
        type5_horizontal_irregularity=type5,
        orthogonal_12_5_4_conditions_absent=inputs.orthogonal_12_5_4_conditions_absent)

    basic = solve_gravity_basic_cases(struc; roof=inputs.roof, params=params)
    for (i, symbol) in enumerate(basic.symbols)
        _require_gravity_cut_equilibrium(struc, basic.u[i], basic.loads[i], symbol)
    end
    # Figure 27.3-1 roof pressures are not applied. `inputs.roof` is the gravity
    # companion, so it is not passed as the wind roof shape (the default is :flat).
    wind = wind_story_analysis(struc;
        directions=inputs.directions,
        qz=inputs.qz,
        qh=inputs.qh,
        Kd=inputs.Kd,
        G=inputs.G,
        GCpi=inputs.GCpi,
        extra_directions=inputs.extra_directions)
    elf = elf_story_analysis(struc;
        method=inputs.method,
        SDS=inputs.SDS,
        S1=inputs.S1,
        R=sysx.R,
        Ie=inputs.Ie,
        T=inputs.T,
        Cd=sysx.Cd,
        β=inputs.β,
        SD1=inputs.SD1,
        TL=inputs.TL,
        Sa=inputs.Sa,
        Ω0=sysx.Ω0,
        between=inputs.between,
        Ry=sysy.R,
        Cdy=sysy.Cd,
        Ω0y=sysy.Ω0,
        plan_axis=axis)
    effects = seismic_effect_cases(elf; orthogonal)
    θmax = _max_drift_theta(elf)
    # Eh is multiplied by ρ. Member forces come from the story stiffness, so
    # the gate is told P-delta is in the forces. Design story drifts still
    # use 1/(1−θ); that multiplier is not also applied to the forces.
    require_seismic_wall_demand_provisions(;
        sdc=inputs.sdc,
        model_uses_cracked_section_stiffness=inputs.model_uses_cracked_section_stiffness,
        sustained_lateral_loads=inputs.sustained_lateral_loads,
        sustained_lateral_divisor_applied=inputs.sustained_lateral_divisor_applied,
        type1_horizontal_irregularity=inputs.type1_horizontal_irregularity,
        type5_horizontal_irregularity=type5,
        orthogonal_combination_applied=orthogonal,
        orthogonal_12_5_4_conditions_absent=inputs.orthogonal_12_5_4_conditions_absent,
        ax_applied_to_accidental_torsion=inputs.ax_applied_to_accidental_torsion,
        theta=θmax,
        pdelta_included_in_member_forces=true,
        rho_applied_to_eh=true)
    system_checks(struc, sx; seismic_design_category=inputs.sdc)
    _systems_agree(sx, sy) || system_checks(struc, sy; seismic_design_category=inputs.sdc)
    # Δa/ρ is the moment-frame story-drift limit. This system does not pass ρ.
    # Design story drift uses 1/(1−θ). Member forces use the story stiffness.
    drift, pdelta_multipliers = _story_drift_with_pdelta(elf;
        risk_category=inputs.risk_category,
        system=inputs.drift_system,
        orthogonal)

    second = _build_story_second_order(struc, basic, wind, elf, effects)
    shares = _wall_dead_load_shares(struc, basic, elf)
    gravity_row = sysx.row === :B6 || sysy.row === :B6 ? :B6 : sysx.row
    _refuse_building_frame_gravity!(gravity_row, shares)
    prepared = Tuple{Int, Any, Vector{CombinedWallAction}, Any, Vector}[]
    grown_by_wall = Dict{Int, Vector{CombinedWallAction}}()
    lw_by_wall = Dict{Int, typeof(1.0u"m")}()
    ρt_by_wall = Dict{Int, Union{Nothing, Float64}}()
    n_raised = 0
    max_ρl = 0.0
    max_ρt = 0.0
    for pier in struc.wall_mesh.piers
        wall_index = pier.wall_index
        haskey(grown_by_wall, wall_index) && throw(ArgumentError(
            "ordinary wall stage: wall $wall_index has more than one pier."))
        wall = struc.walls[wall_index]
        assembly = _assembly_of(struc.wall_mesh, wall_index)
        gravity = pier_gravity_actions(struc, basic, pier)
        batches = _pier_action_batches(struc, pier, basic, wind, elf, second,
                                       gravity, inputs, effects)
        grown = CombinedWallAction[]
        for (_, _, growns, _) in batches
            append!(grown, growns)
        end
        ρl0 = wall.ρl
        ρt0 = wall.ρt
        lw = joined_clear_length(wall, struc.walls, wall_index) * u"m"
        lw_by_wall[wall_index] = lw
        ρt_strength = select_ordinary_wall_reinforcement!(
            wall, grown, inputs.material; hw=_stacked_wall_height(wall), lw=lw)
        (wall.ρl > ρl0 + 1e-12 || wall.ρt > ρt0 + 1e-12) && (n_raised += 1)
        grown_by_wall[wall_index] = grown
        ρt_by_wall[wall_index] = ρt_strength
        push!(prepared, (wall_index, assembly, grown, ρt_strength, batches))
    end
    interactive = InteractiveStoryShearCheck[]
    frame_members = FrameMemberCheck[]
    directions = Symbol[]
    sx isa InteractiveShearWallFrameSystem && push!(directions, :x)
    sy isa InteractiveShearWallFrameSystem && push!(directions, :y)
    if !isempty(directions)
        # Both directions of row F share one Cd. A single interactive direction
        # uses that direction's row.
        frame_system = sx isa InteractiveShearWallFrameSystem ? sysx : sysy
        interactive = _enforce_interactive_wall_shear!(
            struc, elf, inputs.material, grown_by_wall, ρt_by_wall, directions)
        frame_members = _check_interactive_frames!(
            struc, basic, elf, second, inputs, frame_system, directions, effects)
    end
    checks = Dict{Int, Vector{WallCheckRecord}}()
    for (wall_index, assembly, _, ρt_strength, batches) in prepared
        wall = struc.walls[wall_index]
        max_ρl = max(max_ρl, wall.ρl)
        max_ρt = max(max_ρt, wall.ρt)
        records = WallCheckRecord[]
        for (case, firsts, growns, what) in batches
            _each_second_order(records, wall, firsts, growns;
                material=inputs.material, wall_index, case,
                boundary=inputs.boundary, assembly, what, ρt_strength,
                plan_axis=axis, lw=lw_by_wall[wall_index])
        end
        checks[wall_index] = records
    end
    _record_joined_joints!(checks, struc, basic, wind, second, effects, inputs, axis)
    _record_story_shear!(checks, interactive, struc, axis)
    _record_frame_members!(checks, struc, frame_members, axis)
    @info "Ordinary wall reinforcement" n_piers=length(checks) n_raised max_ρl max_ρt type5 orthogonal

    result = OrdinaryWallResult(checks, drift, θmax, pdelta_multipliers,
                                shares, interactive, frame_members,
                                type5, nonparallel, orthogonal)
    struc.ordinary_wall_result = result
    StructuralSizer.emit!(tc, :pipeline, "design_ordinary_walls!", "stage_ordinary_walls", :exit;
                          n_walls=length(checks), n_drift=length(drift))
    return result
end

"""
First-order and second-order strength actions for one pier.

Each entry is `(case, first-order actions, second-order actions, label)`.
The second-order actions are the ones the reinforcement search and the
recorded checks both use.
"""
function _pier_action_batches(struc, pier, basic, wind, elf, second, gravity, inputs,
                              effects::AbstractVector{SeismicEffectCase})
    batches = Tuple{Symbol, Vector{CombinedWallAction}, Vector{CombinedWallAction}, String}[]
    push!(batches, (:D,
        _gravity_strength_actions(gravity),
        _second_order_gravity_actions(struc, pier, basic, second),
        "gravity"))
    wind1 = wind_pier_actions(struc, wind, pier)
    for (i, action) in enumerate(wind1)
        push!(batches, (_wind_case_symbol(i, wind.cases[i]),
            _wind_strength_actions(gravity, action),
            _second_order_wind_actions(struc, pier, basic, second, i),
            "wind case $i"))
    end
    qe_actions = seismic_strength_pier_actions(struc, elf, pier, effects)
    for (k, action) in enumerate(qe_actions)
        push!(batches, (effects[k].label,
            _seismic_strength_actions(gravity, action, inputs.rho, inputs.SDS),
            _second_order_seismic_actions(struc, pier, basic, second, k,
                                          inputs.rho, inputs.SDS),
            "QE $(effects[k].label)"))
    end
    return batches
end

"""
`(combination, alternative, gravity key)` for the gravity readings.

Combination 3 is the floor-live reading (`:L`). Wind and earthquake are
not in this list. First-order actions, second-order actions, and corner
shear all walk this list.
"""
function _gravity_readings(roof::Symbol)
    out = Tuple{LoadCombination, Symbol, GravityStiffnessKey}[]
    for combo in asce7_strength_combinations
        if combo.name === :strength_1_2D_1_6Lr
            push!(out, (combo, :L, _gravity_key(combo, roof; live=true)))
        elseif combo.W == 0.0 && combo.E == 0.0 && combo.Ev == 0.0
            push!(out, (combo, :only, _gravity_key(combo, roof)))
        end
    end
    return out
end

"""Wind readings. Combination 3 is the `0.5W` reading (`:W`)."""
function _wind_readings(roof::Symbol)
    out = Tuple{LoadCombination, Symbol, GravityStiffnessKey}[]
    for combo in asce7_strength_combinations
        if combo.name === :strength_1_2D_1_6Lr
            push!(out, (combo, :W, _gravity_key(combo, roof; live=false)))
        elseif combo.W != 0.0 && combo.E == 0.0 && combo.Ev == 0.0
            push!(out, (combo, :only, _gravity_key(combo, roof)))
        end
    end
    return out
end

"""Earthquake readings. `Eh = ρ QE` is applied by the caller. `Ev` is axial only."""
function _seismic_readings(roof::Symbol)
    out = Tuple{LoadCombination, Symbol, GravityStiffnessKey}[]
    for combo in asce7_strength_combinations
        (combo.E != 0.0 || combo.Ev != 0.0) || continue
        push!(out, (combo, :only, _gravity_key(combo, roof)))
    end
    return out
end

"""Gravity combinations, once. Combination 3 is the floor-live reading (`:L`)."""
function _gravity_strength_actions(gravity::PierGravityActions)
    out = CombinedWallAction[]
    for (combo, alt, _) in _gravity_readings(gravity.roof)
        push!(out, combine_wall_action(combo, gravity; alternative=alt))
    end
    isempty(out) && throw(ArgumentError(
        "ordinary wall stage: no gravity strength combination was selected."))
    return out
end

"""Wind combinations for one wind case. Combination 3 is the `0.5W` reading."""
function _wind_strength_actions(gravity::PierGravityActions, wind::WallAction)
    out = CombinedWallAction[]
    for (combo, alt, _) in _wind_readings(gravity.roof)
        push!(out, combine_wall_action(combo, gravity; wind, alternative=alt))
    end
    isempty(out) && throw(ArgumentError(
        "ordinary wall stage: no wind strength combination was selected."))
    return out
end

"""Earthquake combinations for one strength `QE`. `Eh = ρ QE` on N, V, and M."""
function _seismic_strength_actions(gravity::PierGravityActions, qe::WallAction,
                                   rho::Real, SDS::Real)
    out = CombinedWallAction[]
    for (combo, alt, _) in _seismic_readings(gravity.roof)
        push!(out, combine_wall_action(combo, gravity; qe, rho, SDS, alternative=alt))
    end
    isempty(out) && throw(ArgumentError(
        "ordinary wall stage: no earthquake strength combination was selected."))
    return out
end

function _require_gravity_cut_equilibrium(struc, u, loads, symbol;
                                          geometric_stiffness=nothing)
    seen = Float64[]
    for pier in struc.wall_mesh.piers
        z = _pier_bottom(pier)
        any(s -> abs(s - z) <= WALL_CUT_ZTOL_M, seen) && continue
        push!(seen, z)
        eq = check_story_cut_equilibrium(struc.asap_model, u, struc.wall_mesh, loads, z;
                                         fixed_end_from_loads=true,
                                         geometric_stiffness)
        eq.passed || throw(ArgumentError(
            "ordinary wall stage: the $symbol story cut at z = $(z) m is not " *
            "in equilibrium (residual $(eq.residual)). The wall is not checked " *
            "on that result."))
    end
    return nothing
end

"""One factored gravity and the component displacements solved on its `K_G`."""
struct StorySecondOrderSet
    key::GravityStiffnessKey
    "Unfactored `D`, `L`, roof, then every wind case, then every seismic effect `QE`."
    u::Vector{Vector{Float64}}
    nwind::Int
    nqe::Int
    "Story geometric stiffness this displacement was solved on."
    Kg::SparseMatrixCSC{Float64, Int}
end

"""
Factored-gravity keys the strength combinations ask for.

Combination 3 has two: floor live with no wind, and `0.5W` with no floor
live. Wind and earthquake that share `(D, L, roof)` share one entry.
"""
function _stage_gravity_keys(roof::Symbol)
    keys = GravityStiffnessKey[]
    for combo in asce7_strength_combinations
        if combo.name === :strength_1_2D_1_6Lr
            _pushkey!(keys, _gravity_key(combo, roof; live=true))
            _pushkey!(keys, _gravity_key(combo, roof; live=false))
        elseif combo.W == 0.0 && combo.E == 0.0 && combo.Ev == 0.0
            _pushkey!(keys, _gravity_key(combo, roof))
        elseif combo.W != 0.0 && combo.E == 0.0 && combo.Ev == 0.0
            _pushkey!(keys, _gravity_key(combo, roof))
        end
        if combo.E != 0.0 || combo.Ev != 0.0
            _pushkey!(keys, _gravity_key(combo, roof))
        end
    end
    return keys
end

function _pushkey!(keys, key)
    key in keys || push!(keys, key)
    return keys
end

"""`(D, L, roof)` of one combination. `live=false` is combination 3's wind reading."""
function _gravity_key(combo, roof::Symbol; live::Bool=true)
    R = roof === :Lr ? combo.Lr : roof === :S ? combo.S : roof === :R ? combo.R :
        throw(ArgumentError("roof companion must be :Lr, :S, or :R, got :$roof."))
    return GravityStiffnessKey(Float64(combo.D), live ? Float64(combo.L) : 0.0, Float64(R))
end

"""
Solve every unfactored component on each distinct factored-gravity stiffness.

`K_G` comes from the first-order factored gravity of that key. Lateral loads
are not in that gravity, and the matrix is not iterated. The factored-gravity
displacement on `K_G` is checked at each pier-bottom cut, with `−K_G u`
counted on the applied side.
"""
function _build_story_second_order(struc, basic, wind, elf,
                                   effects::AbstractVector{SeismicEffectCase})
    roof = basic.symbols[3]
    model = struc.asap_model
    masters = [(lv.elevation_m, lv.master) for lv in elf.levels]
    isempty(masters) && throw(ArgumentError(
        "ordinary wall stage: the ELF analysis has no level, so the story " *
        "stiffness has no master."))
    base = first(elf.levels).elevation_m - first(elf.levels).story_height_m
    base_master = get(_elf_masters(struc), round(Int, base * 1000), nothing)
    wind_cases = [_wind_loads(wind.levels, c.Fx_kN, c.Fy_kN, c.Mz_kN_m) for c in wind.cases]
    qe_cases = [seismic_effect_loads(elf, e) for e in effects]
    batch = Vector{Vector{Asap.AbstractLoad}}()
    append!(batch, basic.loads)
    append!(batch, wind_cases)
    append!(batch, qe_cases)
    sets = Dict{GravityStiffnessKey, StorySecondOrderSet}()
    for key in _stage_gravity_keys(roof)
        u1 = key.D .* basic.u[1] .+ key.L .* basic.u[2] .+ key.roof .* basic.u[3]
        loads = vcat(scale_story_loads(basic.loads[1], key.D),
                     scale_story_loads(basic.loads[2], key.L),
                     scale_story_loads(basic.loads[3], key.roof))
        profiles = story_axial_profiles(model, u1, struc.wall_mesh, masters, base;
                                        loads=loads, base_master=base_master)
        Kg = story_geometric_stiffness(model, profiles)
        u2 = Asap.solve(model, batch, struc.asap_rigid_links; geometric_stiffness=Kg)
        ug = key.D .* u2[1] .+ key.L .* u2[2] .+ key.roof .* u2[3]
        _require_gravity_cut_equilibrium(struc, ug, loads,
            "factored gravity D=$(key.D) L=$(key.L) $(roof)=$(key.roof)";
            geometric_stiffness=Kg)
        sets[key] = StorySecondOrderSet(key, u2, length(wind_cases), length(qe_cases), Kg)
    end
    return sets
end

function _second_order_gravity(struc, pier, basic, set::StorySecondOrderSet)
    wall = struc.walls[pier.wall_index]
    actions = ntuple(3) do i
        pier_wall_action(wall, pier, set.u[i];
                         loads=basic.loads[i], fixed_end_from_loads=true)
    end
    return PierGravityActions(basic.symbols[3], actions...)
end

"""Lateral pier action from a component solved on `K_G`. Nodal story forces have no element `Q`."""
function _second_order_lateral(struc, pier, u)
    wall = struc.walls[pier.wall_index]
    return pier_wall_action(wall, pier, u;
                            loads=Asap.AbstractLoad[], fixed_end_from_loads=true)
end

function _second_order_gravity_actions(struc, pier, basic, second)
    out = CombinedWallAction[]
    for (combo, alt, key) in _gravity_readings(basic.symbols[3])
        grown = _second_order_gravity(struc, pier, basic, second[key])
        push!(out, combine_wall_action(combo, grown; alternative=alt))
    end
    return out
end

function _second_order_wind_actions(struc, pier, basic, second, i::Int)
    out = CombinedWallAction[]
    for (combo, alt, key) in _wind_readings(basic.symbols[3])
        set = second[key]
        grown = _second_order_gravity(struc, pier, basic, set)
        wind = _second_order_lateral(struc, pier, set.u[3 + i])
        push!(out, combine_wall_action(combo, grown; wind, alternative=alt))
    end
    return out
end

function _second_order_seismic_actions(struc, pier, basic, second, k::Int, rho, SDS)
    nwind = first(values(second)).nwind
    out = CombinedWallAction[]
    for (combo, alt, key) in _seismic_readings(basic.symbols[3])
        set = second[key]
        grown = _second_order_gravity(struc, pier, basic, set)
        qe = _second_order_lateral(struc, pier, set.u[3 + nwind + k])
        push!(out, combine_wall_action(combo, grown; qe, rho, SDS, alternative=alt))
    end
    return out
end

function _each_second_order(records, wall, first_actions, second_actions;
                             material, wall_index, case, boundary, assembly, what,
                             ρt_strength=nothing, plan_axis=(1.0, 0.0),
                             lw::Union{Nothing,Unitful.Length}=nothing)
    length(first_actions) == length(second_actions) || throw(ArgumentError(
        "ordinary wall stage: $what has $(length(first_actions)) first-order " *
        "combinations and $(length(second_actions)) second-order combinations."))
    for (first, grown) in zip(first_actions, second_actions)
        _accept_second_order!(records, wall, first, grown;
                              material, wall_index, case, boundary, assembly,
                              ρt_strength, plan_axis, lw)
    end
    return records
end

function _accept_second_order!(records, wall, first::CombinedWallAction,
                               grown::CombinedWallAction;
                               material, wall_index, case, boundary, assembly,
                               ρt_strength=nothing, plan_axis=(1.0, 0.0),
                               lw::Union{Nothing,Unitful.Length}=nothing)
    (first.combination === grown.combination && first.alternative === grown.alternative) ||
        throw(ArgumentError(
            "ordinary wall stage: first-order $(first.combination)/$(first.alternative) " *
            "does not match second-order $(grown.combination)/$(grown.alternative)."))
    _record_second_order_moment!(records, wall, first, grown; wall_index, case, plan_axis)
    append!(records, check_ordinary_wall(wall, CombinedWallAction[grown];
                                         material, wall_index, case, boundary, assembly,
                                         ρt_strength, plan_axis, lw))
    return records
end

"""
Record ACI 318-19 §6.2.5.3 when the second-order moment is above the limit.

The strength checks still use the second-order forces. This record is the
limit on them. Both moments under 1 N·m are not a ratio.

# Citation
ACI 318-19 §6.2.5.3 (corpus: aci-318-19, PDF page 72): Mu including
second-order effects shall not exceed 1.4 Mu due to first-order effects.
"""
function _record_second_order_moment!(records, wall, first::CombinedWallAction,
                                      grown::CombinedWallAction; wall_index, case,
                                      plan_axis=(1.0, 0.0))
    a2 = abs(grown.M)
    a1 = abs(first.M)
    (a2 <= 1.0 && a1 <= 1.0) && return records
    # ACI 318-19 §6.2.5.3 (corpus: aci-318-19, PDF page 72).
    limit = 1.4 * a1
    a2 <= limit + 1.0 && return records
    push!(records, WallCheckRecord(
        wall_index, wall.story, _pier_axis_direction(wall, plan_axis), case,
        grown.combination, grown.alternative, "second-order moment",
        false, a1 == 0.0 ? Inf : a2 / a1, a2, limit,
        "ACI 318-19 §6.2.5.3"))
    return records
end

function _max_drift_theta(analysis::ElfStoryAnalysis)
    θmax = 0.0
    found = false
    for case in analysis.cases
        case.purpose === :drift || continue
        for θ in case.θ
            θ === nothing && throw(ArgumentError(
                "ordinary wall stage: a drift case has no stability coefficient θ."))
            isfinite(θ) || throw(ArgumentError(
                "ordinary wall stage: a drift case has a non-finite θ ($θ)."))
            θmax = max(θmax, Float64(θ))
            found = true
        end
    end
    found || throw(ArgumentError(
        "ordinary wall stage: the ELF analysis has no drift case, so θ is unknown."))
    return θmax
end

function _assembly_of(mesh::WallMesh, wall_index::Int)
    for assembly in mesh.assemblies
        wall_index in assembly.wall_indices && return assembly
    end
    throw(ArgumentError(
        "ordinary wall stage: wall $wall_index has a pier and no assembly."))
end

function _wind_case_symbol(i::Int, case::WindStoryCase)
    d2 = case.direction_2 === nothing ? "none" :
         "$(case.direction_2[1])_$(case.direction_2[2])"
    return Symbol("W$(i)_$(case.kind)_$(case.direction[1])_$(case.direction[2])_" *
                  "$(d2)_$(case.sign_1)_$(case.sign_2)")
end

"""
    _scale_seismic_action(action, multiplier) -> WallAction

Scale one seismic pier resultant by the §12.8.7 factor.

The factor is 1 where θ ≤ 0.10 and `1/(1−θ)` where `0.10 < θ ≤ θmax`.
Gravity and wind are not passed here. `Ev` is applied later from dead load,
so this scale does not touch it.

# Citation
ASCE 7-22 §12.8.7 (corpus: asce-7-22, PDF page 188): where θ is greater
than 0.10 but less than or equal to θmax, displacements and member forces
may be multiplied by 1.0/(1−θ).
"""
function _scale_seismic_action(action::WallAction, multiplier::Real)
    m = Float64(multiplier)
    (isfinite(m) && m > 0) || throw(ArgumentError(
        "ordinary wall stage: the P-delta multiplier must be a positive " *
        "finite number; got $multiplier."))
    return WallAction(action.N * m, action.V * m, action.M * m,
                      action.Vo * m, action.Mo * m)
end

"""
Multiplier stored on the drift case of the same direction and torsion.

A strength case leaves `multiplier` empty. In this linear model Δ scales
with V, so θ of the strength case equals θ of the matching drift case.
"""
function _drift_multiplier(elf::ElfStoryAnalysis, direction::Symbol, torsion::Symbol,
                           level_index::Int)
    hits = ElfCase[]
    for case in elf.cases
        case.purpose === :drift || continue
        case.direction === direction && case.torsion === torsion || continue
        push!(hits, case)
    end
    length(hits) == 1 || throw(ArgumentError(
        "ordinary wall stage: expected one drift case for $direction $torsion, " *
        "found $(length(hits))."))
    1 <= level_index <= length(only(hits).multiplier) || throw(ArgumentError(
        "ordinary wall stage: level $level_index is outside the drift case."))
    m = only(hits).multiplier[level_index]
    m === nothing && throw(ArgumentError(
        "ordinary wall stage: the $direction $torsion drift case has no " *
        "P-delta multiplier at level $level_index."))
    return Float64(m)
end

"""
ELF level whose story height is this pier.

`Wall.story` is the skeleton story at the bottom of the pier. The matching
level is the lowest ELF level above that elevation. Its θ is the stability
coefficient of the story between the two.
"""
function _elf_level_index(struc::BuildingStructure, elf::ElfStoryAnalysis, wall)
    haskey(struc.skeleton.stories, wall.story) || throw(ArgumentError(
        "ordinary wall stage: wall story $(wall.story) is not on the skeleton."))
    z_bot = ustrip(u"m", struc.skeleton.stories[wall.story].elevation)
    best = 0
    best_z = Inf
    for (i, lv) in enumerate(elf.levels)
        lv.elevation_m > z_bot + 1e-6 || continue
        if lv.elevation_m < best_z
            best = i
            best_z = lv.elevation_m
        end
    end
    best == 0 && throw(ArgumentError(
        "ordinary wall stage: wall story $(wall.story) at z = $(z_bot) m " *
        "has no ELF level above it."))
    return best
end

"""
    _story_drift_with_pdelta(analysis; risk_category, system, orthogonal=false)
        -> (checks, multipliers)

[`check_seismic_story_drift`](@ref), with each design story drift multiplied
by that story's §12.8.7 factor. `rho` is not passed: Δa/ρ is the
moment-frame limit.

With `orthogonal = true` the drifts are those of the §12.5.1.2(a) effects:
`QE(axis, ±AT) ± 0.3 QE(other axis)` on the drift cases. Each effect is read
along both plan axes, and each reading is one check. The overall sign is not
repeated, because the limit is on the magnitude.

# Engineering judgment
A combined drift along one axis is multiplied by the largest §12.8.7 factor
of that axis's drift cases at that story. §12.8.7 defines θ for one story and
one direction of force, not for a sum of two directions.

# Citation
ASCE 7-22 §12.8.7 (corpus: asce-7-22, PDF page 188) and §12.12.1
(PDF page 194), Table 12.12-1 (PDF page 195). §12.5.1.2 (PDF page 183):
drift requirements shall be satisfied for all combinations. Commentary
C12.5.1.2 (PDF page 720): use the combinations to determine the maximum story
drift in each orthogonal axis.
"""
function _story_drift_with_pdelta(analysis::ElfStoryAnalysis;
                                  risk_category::Symbol,
                                  system::Symbol,
                                  orthogonal::Bool=false)
    orthogonal && return _orthogonal_story_drift(analysis; risk_category, system)
    checks = SeismicStoryDriftCheck[]
    multipliers = Float64[]
    for case in analysis.cases
        case.purpose === :drift || continue
        for (i, lv) in enumerate(analysis.levels)
            m = case.multiplier[i]
            m === nothing && throw(ArgumentError(
                "ordinary wall stage: a drift case has no P-delta multiplier."))
            # ASCE 7-22 §12.8.7 (corpus: asce-7-22, PDF page 188):
            # displacements may be multiplied by 1.0/(1−θ). The factor is
            # already 1 where θ ≤ 0.10.
            Δ = case.design_drift_m[i] * Float64(m)
            Δa = allowable_story_drift(lv.story_height_m, risk_category, system)
            push!(multipliers, Float64(m))
            push!(checks, SeismicStoryDriftCheck(
                lv.story, case.direction, case.torsion, abs(Δ), Δa,
                story_drift_is_allowed(Δ, lv.story_height_m, risk_category, system)))
        end
    end
    isempty(checks) && throw(ArgumentError(
        "ordinary wall stage: the ELF analysis has no drift case to amplify."))
    return checks, multipliers
end

"""Largest §12.8.7 factor of the drift cases along `direction` at level `i`."""
function _axis_drift_multiplier(analysis::ElfStoryAnalysis, direction::Symbol, i::Int)
    m = 0.0
    for case in analysis.cases
        case.purpose === :drift && case.direction === direction || continue
        mi = case.multiplier[i]
        mi === nothing && throw(ArgumentError(
            "ordinary wall stage: a drift case has no P-delta multiplier."))
        m = max(m, Float64(mi))
    end
    m > 0 || throw(ArgumentError(
        "ordinary wall stage: no drift case along $direction at level $i."))
    return m
end

function _orthogonal_story_drift(analysis::ElfStoryAnalysis; risk_category::Symbol,
                                 system::Symbol)
    checks = SeismicStoryDriftCheck[]
    multipliers = Float64[]
    for effect in seismic_effect_cases(analysis; orthogonal=true, purpose=:drift)
        # ±QE is the same magnitude. Keep the positive 100% term.
        first(effect.terms)[2] > 0 || continue
        for (i, lv) in enumerate(analysis.levels)
            along = Dict(:x => 0.0, :y => 0.0)
            for (j, f) in effect.terms
                c = analysis.cases[j]
                other = c.direction === :x ? :y : :x
                along[c.direction] += f * c.design_drift_m[i]
                along[other] += f * c.design_cross_drift_m[i]
            end
            Δa = allowable_story_drift(lv.story_height_m, risk_category, system)
            for axis in (:x, :y)
                m = _axis_drift_multiplier(analysis, axis, i)
                # ASCE 7-22 §12.8.7 (corpus: asce-7-22, PDF page 188).
                Δ = along[axis] * m
                push!(multipliers, m)
                push!(checks, SeismicStoryDriftCheck(
                    lv.story, axis, effect.torsion, abs(Δ), Δa,
                    story_drift_is_allowed(Δ, lv.story_height_m, risk_category, system),
                    effect.label))
            end
        end
    end
    isempty(checks) && throw(ArgumentError(
        "ordinary wall stage: the ELF analysis has no drift case to combine."))
    return checks, multipliers
end

"""Copy ordinary-wall checks and story-drift results onto the published design."""
function _capture_ordinary_walls!(design::BuildingDesign, struc::BuildingStructure)
    result = struc.ordinary_wall_result
    result === nothing && return nothing
    for (idx, records) in result.checks
        design.walls[idx] = copy(records)
    end
    design.seismic_story_drift = Vector{Any}(result.drift)
    return nothing
end
