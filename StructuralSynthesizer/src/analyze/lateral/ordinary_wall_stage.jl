# Ordinary concrete wall checks inside design_building.
#
# Each straight pier is checked on its own cut, including a leg of a joined
# assembly. Thickness stays fixed. A joined leg uses its clear length.
# ρl and ρt are the lightest grid ratios that pass the current demands.
# A ratio already on the wall is not kept. A failing check is recorded.
# The corner between legs is shear friction.

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
    "Special-boundary decisions for piers on row A.1 or B.4. Empty otherwise."
    boundary::Dict{Int, SpecialBoundaryDecision}
    "One decision per vertical segment beside an opening. Empty for a solid pier."
    opening_edges::Dict{Int, Vector{SpecialBoundaryDecision}}
    "Added end bars on special piers. Empty when the web steel is enough and §18.10.2.4 does not apply."
    end_bars::Dict{Int, BoundaryEndReinforcement}
    "Gravity beams and columns under §12.12.4. Empty outside Seismic Design Categories D, E, and F."
    induced::Vector{GravityInducedCheck}
end

"""
    design_ordinary_walls!(struc, params; tc=nothing) -> OrdinaryWallResult or nothing

Check every ordinary pier when `params.lateral` is set. A joined assembly
is checked leg by leg. The corner is shear friction.

`lateral === nothing` still sizes every pier. The demands are the gravity
strength combinations only. Wind and earthquake are not invented. The
empirical bearing factor is Table 11.5.3.2's restrained value, the
floor-to-floor wall. A building with no walls returns without a result.

A wall with openings is not checked on its gross length. Its vertical
segments use [`check_pier_segment`](@ref). A narrow segment is checked when
the story end moments show the story is nonsway. A horizontal segment
longer than four times its depth uses the beam flexure and shear checks.
A shorter segment is one deep-beam strut and one tie.

When lateral design was requested:

- `wall_inputs` is required. Pressures, `ρ`, and the seismic statements are
  not assumed. `R`, `Cd`, and `Ω0` come from the Table 12.2-1 row of each
  direction. A Seismic Design Category that a row marks NP is refused.
- Each direction is [`WallsSeismicSystem`](@ref) (`:A1`, `:A3`, `:B4`, or
  `:B6`) or [`InteractiveShearWallFrameSystem`](@ref) (row F). `:A1` and
  `:B4` supply the special-wall `R`, `Cd`, and `Ω0` for Seismic Design
  Categories B and C. The pier strength checks stay the ordinary checks.
  On those rows each solid pier records a §18.10.6.3 boundary decision.
  Continuity is taken from the stack. A single critical section is the base
  of a continuous line on the §18.10.6.2 route. Shear is Ve, and end bars are
  added where §18.10.2.4 or the boundary element needs them. When the thickness jump is on, a
  pier whose web is short of the §18.10.6.4 compression-zone width grows
  by itself to the next inch that covers that shortfall. A flange in
  compression does not resize the web. When an element is required and
  `params.floor` states a concrete strength, §18.10.6.4(h) is recorded.
  A design that does not state one records nothing. Ordinary rows record
  nothing, so this floor does not move them.
  The assignment is
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
  shear friction. The ordinary check does not use a flange. The special-boundary
  stress does, when a perpendicular wall meets one end or both (§18.10.5.2).
- A rigid diaphragm puts story forces on the masters. A flexible diaphragm
  sends each `(Fx, Fy)` to the lines of seismic-system walls the declared
  systems name ([`flexible_diaphragm_layout!`](@ref)): simple spans between
  lines by tributary seismic weight (wind: by floor width), and the walls of
  one line tied along it so they share by stiffness. ASCE 7-22 §12.8.4 and
  §12.8.4.1 (corpus: asce-7-22, PDF page 187). Story drift and θ are read at
  the center of mass between the lines. The 5% accidental eccentricity is not
  applied: §12.8.4.2.1 requires it only where diaphragms are not flexible.
- A `:semirigid` membrane floor takes story forces on its nodes by seismic
  weight, accidental torsion as nodal forces, and wind on its exterior edge
  ([`_semirigid_story_loads`](@ref)). Drift is read from the plan rigid motion
  fitted to the seismic-system wall tops ([`semirigid_sfrs!`](@ref)). Like a
  flexible floor it has no master, so member forces are first-order and the
  seismic ones are multiplied by the §12.8.7 factor. A full-plate `:shell`
  floor is refused.
- Demands are the unified frame-shell solution: unfactored gravity, Chapter 27
  wind, and ELF strength cases. Each strength combination is applied once per
  group (gravity with wind and earthquake omitted, each wind case, each `QE`
  case). Wind cases are not crossed with `QE` cases.
- Thickness starts as the given pier thickness. When a strength check or
  story drift fails and `params.jump_wall_thickness` is true, each group
  named by `params.wall_thickness_grouping` moves to the thinnest inch the
  proxy accepts, then this stage remeshes and checks again. The default
  grouping is `:pier`, so a local failure thickens that wall only. `:all`
  is one group and one confirm. A grouping finer than `:all` can change
  relative stiffness, so the stage re-solves until those groups stop
  growing. Drift and interactive story shear are building results, so
  they still move every group. Length is not changed. `ρt` is the lightest
  grid ratio that covers the largest shear, then `ρl` walks up from the
  §11.6.2 floor until axial-flexure passes. Both are chosen again from
  that floor on every call. Special shear and the row F story-shear bump
  run after that and only raise. This function does not scale shell `E`.
  When `wall_inputs` states cracked stiffness, `to_asap!` has already
  applied it.
- With rigid masters, member forces include second-order story sway. Each
  distinct factored gravity `(D, L, roof)` builds one story stiffness from
  the vertical forces of that gravity, and the unfactored cases are solved
  on it and superposed (Wilson & Habibullah 1987, Eq. 7, corpus:
  wilson-habibullah-1987-pdelta, PDF page 6). ACI 318-19 §11.4.1.3
  (PDF page 169) sends walls to §6.6.4, §6.7, or §6.8, and §6.2.5.3
  (PDF page 72) records a failing check when one action's second-order
  moment exceeds 1.4 times that action's first-order moment. Gravity is one
  action. Wind or Eh is the other. The summed moment is the strength demand
  and is not the ratio. A flexible diaphragm has no master, so the
  lateral run stays first-order. §6.6.4.6 is not applied.
- Design story drifts stay on the ASCE 7-22 §12.8.7 multiplier `1/(1−θ)`
  (corpus: asce-7-22, PDF page 188). On a rigid diaphragm the member forces
  come from the story stiffness and are not multiplied again. On a flexible
  or semirigid floor the seismic member forces are multiplied by the same
  factor. θ > θmax is refused by the ELF analysis. The factor is 1 where
  θ ≤ 0.10.
- Seismic Design Categories D, E, and F calculate the moments and shears
  the design displacement δDE produces in the reinforced-concrete gravity
  frame. Within the design strength, the member is detailed to ACI 318-19
  §18.14.3.2. Otherwise, and when the displacement was not available, it is
  detailed to §18.14.3.3.
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
    isempty(struc.walls) || _require_wall_thickness_grouping(params)
    analyze! = params.lateral === nothing ? _analyze_gravity_walls! : _analyze_lateral_walls!
    grouping = params.wall_thickness_grouping
    budget = params.jump_wall_thickness ? _wall_thickness_pass_cap(grouping) + 1 : 1
    result = nothing
    run = StructuralSizer.settle!(; budget) do pass
        out = analyze!(struc, params; tc)
        out === nothing && return false
        result = out.result
        params.jump_wall_thickness || return false
        targets = propose_wall_thicknesses(struc.walls, out.trials, result;
                                           grouping, SDS=out.SDS,
                                           constraint=params.wall_catalog_constraint,
                                           t_limit=params.wall_thickness_limit)
        any(_thickness_grows(w.thickness, t) for (w, t) in zip(struc.walls, targets)) ||
            return false
        # The last analysis stands: a jump now would leave walls no pass checked.
        pass < budget || return true
        @info "Ordinary wall thickness jump" grouping pass targets
        apply_wall_thickness!(struc, params, targets; tc)
        return true
    end
    if run.converged
        delete!(struc.stage_diagnostics, :walls)
    else
        struc.stage_diagnostics[:walls] =
            "Wall thickness was still growing after $(run.steps) analyses " *
            "(wall_thickness_grouping = :$grouping); the last analysis stands."
    end
    return result
end

"""One lateral wall analysis at the current thickness: `(result, trials, SDS)`."""
function _analyze_lateral_walls!(struc::BuildingStructure, params::DesignParameters;
                                 tc::Union{Nothing, StructuralSizer.TraceCollector}=nothing)
    StructuralSizer.emit!(tc, :pipeline, "design_ordinary_walls!", "stage_ordinary_walls", :enter)
    # A throw below must not leave a previous run's checks or support
    # reactions in place.
    struc.ordinary_wall_result = nothing
    struc.foundation_lateral = nothing

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
    # hn is the highest story above the lowest. stories_z starts at the base,
    # so this is the height from the base to the roof.
    elevs = _elf_story_elevations(struc.skeleton)
    hn = isempty(elevs) ? nothing : (maximum(elevs) - minimum(elevs)) * u"m"
    sysx = concrete_shear_wall_system(table_12_2_1_row(sx), inputs.sdc; hn = hn)
    sysy = concrete_shear_wall_system(table_12_2_1_row(sy), inputs.sdc; hn = hn)
    struc.site.sdc = inputs.sdc

    prepare_lateral_model!(struc, params.lateral)
    isempty(struc.wall_mesh.piers) && throw(ArgumentError(
        "ordinary wall stage: the wall mesh is empty. to_asap! has not meshed the walls."))
    # No rigid master: a flexible floor or a semirigid membrane. Either way the
    # member forces stay first-order.
    flexible = isempty(struc.asap_rigid_links)
    if struc.diaphragm_layout isa SemirigidDiaphragmLayout
        semirigid_sfrs!(struc, params.lateral)
    elseif flexible
        flexible_diaphragm_layout!(struc, params.lateral)
    else
        struc.diaphragm_layout = nothing
    end

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
        extra_directions=inputs.extra_directions,
        gust_site=inputs.wind_gust_site)
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
        plan_axis=axis,
        flexible_accidental_torsion=inputs.flexible_accidental_torsion)
    effects = seismic_effect_cases(elf; orthogonal)
    θmax = _max_drift_theta(elf)
    # Eh is multiplied by ρ. On a rigid diaphragm the member forces come from
    # the story stiffness, so P-delta is in the forces and is not multiplied
    # again. A flexible or semirigid floor stays first-order. Its seismic
    # member forces, including pierced segments and joined corners, are
    # multiplied by the §12.8.7 factor 1/(1−θ). Design story drifts use that
    # same factor from the unscaled drift solution, once.
    pdelta_in_forces = true
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
        pdelta_included_in_member_forces=pdelta_in_forces,
        rho_applied_to_eh=true)
    system_checks(struc, sx; seismic_design_category=inputs.sdc)
    _systems_agree(sx, sy) || system_checks(struc, sy; seismic_design_category=inputs.sdc)
    # Δa/ρ is the moment-frame story-drift limit. This system does not pass ρ.
    # Design story drift uses 1/(1−θ). Member forces use the story stiffness.
    drift, pdelta_multipliers = _story_drift_with_pdelta(elf;
        risk_category=inputs.risk_category,
        system=inputs.drift_system,
        orthogonal)

    second = flexible ? nothing :
             _build_second_order(struc, basic; wind, elf, effects)
    shares = _wall_dead_load_shares(struc, basic, elf)
    gravity_row = if sysx.row === :B6 || sysy.row === :B6
        :B6
    elseif sysx.row === :B4 || sysy.row === :B4
        :B4
    else
        sysx.row
    end
    _refuse_building_frame_gravity!(gravity_row, shares)
    prepared = Tuple{Int, Any, Vector{CombinedWallAction}, Any, Vector, Any}[]
    grown_by_wall = Dict{Int, Vector{CombinedWallAction}}()
    lw_by_wall = Dict{Int, typeof(1.0u"m")}()
    ρt_by_wall = Dict{Int, Union{Nothing, Float64}}()
    n_raised = 0
    max_ρl = 0.0
    max_ρt = 0.0
    for pier in _solid_piers(struc)
        wall_index = pier.wall_index
        wall = struc.walls[wall_index]
        assembly = _assembly_of(struc.wall_mesh, wall_index)
        gravity = _gravity_raised_to_shell(struc,
            pier_gravity_actions(struc, basic, pier), wall_index)
        batches = _pier_action_batches(struc, pier, basic, wind, elf, second,
                                       gravity, inputs, effects)
        grown = CombinedWallAction[]
        for batch in batches
            append!(grown, batch.growns)
        end
        lw, Moop, basis, ρt_strength, raised = _select_pier_steel!(
            struc, wall_index, grown, inputs.material)
        raised && (n_raised += 1)
        grown_by_wall[wall_index] = grown
        lw_by_wall[wall_index] = lw
        ρt_by_wall[wall_index] = ρt_strength
        push!(prepared, (wall_index, assembly, grown, ρt_strength, batches,
                         (moment = Moop, basis = basis)))
    end
    interactive = InteractiveStoryShearCheck[]
    frame_members = FrameMemberCheck[]
    directions = Symbol[]
    sx isa InteractiveShearWallFrameSystem && push!(directions, :x)
    sy isa InteractiveShearWallFrameSystem && push!(directions, :y)
    if !isempty(directions)
        second === nothing && throw(ArgumentError(
            "ordinary wall stage: row F needs the story stiffness, and a " *
            "flexible diaphragm has no rigid master to build it."))
        # Both directions of row F share one Cd. A single interactive direction
        # uses that direction's row.
        frame_system = sx isa InteractiveShearWallFrameSystem ? sysx : sysy
        interactive = _enforce_interactive_wall_shear!(
            struc, elf, inputs.material, grown_by_wall, ρt_by_wall, directions)
        frame_members = _check_interactive_frames!(
            struc, basic, elf, second, inputs, frame_system, directions, effects;
            member_opts = (columns = params.columns, beams = params.beams),
            beam_opts_by_group = _beam_opts_by_group(struc, params.beams),
            uniform_columns = params.uniform_column_sizing)
    end
    # The boundary route is fixed by geometry and δu, not by the steel, so it
    # can be read before the special shear raises ρl. The decisions recorded
    # below are taken again with the final steel.
    special = Int[]
    displacement = Set{Int}()
    for (wall_index, assembly, grown, _, _, _) in prepared
        wall = struc.walls[wall_index]
        direction = _pier_axis_direction(wall, axis)
        _pier_on_special_row(direction, sysx.row, sysy.row) || continue
        push!(special, wall_index)
        route = special_boundary_decision(
            wall, struc.walls, wall_index, assembly, grown, inputs.material;
            elf=elf, pier_direction=direction).route
        route === :displacement && push!(displacement, wall_index)
    end
    end_bars = Dict{Int, BoundaryEndReinforcement}()
    shear_terms = Dict{Int, SpecialShearTerms}()
    for _pass in 1:12
        shear_terms = design_special_wall_shear!(
            struc, special, grown_by_wall, lw_by_wall, ρt_by_wall, inputs.material;
            displacement, end_bars)
        fresh = design_boundary_end_bars(
            struc, special, grown_by_wall, lw_by_wall, inputs.material;
            placed = end_bars, elf, plan_axis = axis)
        _same_end_bars(fresh, end_bars) && break
        end_bars = fresh
        _pass == 12 && throw(ArgumentError(
            "special wall: the end bars and the shear steel were still moving after 12 passes."))
    end
    checks = Dict{Int, Vector{WallCheckRecord}}()
    for (wall_index, assembly, _, _, batches, slab) in prepared
        wall = struc.walls[wall_index]
        ρt_strength = ρt_by_wall[wall_index]
        max_ρl = max(max_ρl, wall.ρl)
        max_ρt = max(max_ρt, wall.ρt)
        records = WallCheckRecord[]
        ends = get(end_bars, wall_index, nothing)
        for batch in batches
            _each_second_order(records, wall, batch.firsts, batch.growns;
                material=inputs.material, wall_index, case=batch.case,
                boundary=inputs.boundary, assembly, what=batch.what, ρt_strength,
                plan_axis=axis, lw=lw_by_wall[wall_index], Moop=slab.moment,
                slab_basis=slab.basis, ends,
                first_parts=batch.first_parts, grown_parts=batch.grown_parts)
        end
        if haskey(shear_terms, wall_index)
            append!(records, special_shear_records(
                wall, wall_index, _pier_axis_direction(wall, axis),
                shear_terms[wall_index], batches, inputs.material))
        end
        checks[wall_index] = records
    end
    opening_edges = Dict{Int, Vector{SpecialBoundaryDecision}}()
    n_open, max_ρl, max_ρt = _design_pierced_segments!(
        checks, struc, basic, second;
        material_of=(_, _) -> inputs.material,
        boundary=inputs.boundary, plan_axis=axis,
        max_ρl, max_ρt, wind, elf, effects, rho=inputs.rho, SDS=inputs.SDS,
        opening_edges, fc_floor=_boundary_floor_fc(params),
        row_x=sysx.row, row_y=sysy.row)
    n_raised += n_open
    joint_sets = second
    if joint_sets === nothing && any(a -> a.joined, struc.wall_mesh.assemblies)
        joint_sets = _build_first_order(struc, basic; wind, elf, effects)
    end
    _record_joined_joints!(checks, struc, basic, wind, joint_sets, effects, inputs, axis;
                           elf = second === nothing ? elf : nothing)
    _record_story_shear!(checks, interactive, struc, axis)
    _record_frame_members!(checks, struc, frame_members, axis)
    @info "Ordinary wall reinforcement" n_piers=length(checks) n_raised max_ρl max_ρt type5 orthogonal

    boundary = Dict{Int, SpecialBoundaryDecision}()
    for (wall_index, assembly, grown, _, _, _) in prepared
        wall = struc.walls[wall_index]
        direction = _pier_axis_direction(wall, axis)
        _pier_on_special_row(direction, sysx.row, sysy.row) || continue
        bars = get(end_bars, wall_index, nothing)
        boundary[wall_index] = special_boundary_decision(
            wall, struc.walls, wall_index, assembly, grown, inputs.material;
            fc_floor=_boundary_floor_fc(params), elf=elf, pier_direction=direction,
            end_area = bars === nothing ? nothing : bars.area_m2,
            end_inset = bars === nothing ? nothing : bars.inset_m)
    end
    induced = gravity_induced_checks(struc, elf, basic, inputs.material, params, inputs.sdc;
                                    Cdx = sysx.Cd, Cdy = sysy.Cd, Ie = inputs.Ie, SDS = inputs.SDS)
    result = OrdinaryWallResult(checks, drift, θmax, pdelta_multipliers,
                                shares, interactive, frame_members,
                                type5, nonparallel, orthogonal, boundary, opening_edges,
                                end_bars, induced)
    struc.ordinary_wall_result = result
    trials = WallThicknessTrial[]
    for (wall_index, assembly, grown, _, _, slab) in prepared
        push!(trials, _trial_for_pier(
            struc, wall_index, grown, lw_by_wall[wall_index], slab.moment,
            inputs.material, inputs.boundary, assembly,
            get(shear_terms, wall_index, nothing); slab_basis=slab.basis))
    end
    # Support reactions for §2.3 and §2.4. The foundation stage runs after
    # this one and reads them. A gravity-only building leaves the field empty.
    struc.foundation_lateral = if isempty(struc.asap_rigid_links)
        nothing
    else
        foundation_lateral_cases(struc, basic, wind, elf, effects;
                                 roof=inputs.roof, rho=inputs.rho, SDS=inputs.SDS)
    end
    StructuralSizer.emit!(tc, :pipeline, "design_ordinary_walls!", "stage_ordinary_walls", :exit;
                          n_walls=length(checks), n_drift=length(drift))
    return (result = result, trials = trials, SDS = inputs.SDS)
end

"""
    _analyze_gravity_walls!(struc, params; tc=nothing) -> (result, trials, SDS) or nothing

Size every pier from the gravity strength combinations, at the current
thickness. [`design_ordinary_walls!`](@ref) runs the thickness jumps.

No wind case and no earthquake case are built. The roof pressure already
stored on the building is the `:Lr` companion, the same default
[`solve_gravity_basic_cases`](@ref) uses. The empirical bearing factor is
`:restrained` (`k = 0.8`), ACI 318-19 Table 11.5.3.2 (corpus: the factor
already tabulated in [`wall_empirical_k`](@ref)): a floor-to-floor wall,
braced against translation, with rotation restrained. That is the monolithic
wall-to-slab joint this model builds.

When rigid-diaphragm masters exist, member forces include the story
geometric stiffness of each factored gravity, as the lateral stage does.
Without those masters the combinations stay first-order. The pier cut is
the shell and frame solution. Tributary area that was assigned to a column
is not added again.

A building with no walls returns `nothing`. `ρl` and `ρt` are chosen on the
same grid the lateral stage uses, from the code floor, not from the ratios
already on the wall. Concrete comes
from the wall when it has one, otherwise from the column material cascade.
Rebar is that cascade.
"""
function _analyze_gravity_walls!(struc::BuildingStructure, params::DesignParameters;
                                 tc::Union{Nothing, StructuralSizer.TraceCollector}=nothing)
    if isempty(struc.walls)
        struc.ordinary_wall_result = nothing
        struc.foundation_lateral = nothing
        return nothing
    end
    StructuralSizer.emit!(tc, :pipeline, "design_ordinary_walls!", "stage_ordinary_walls", :enter)
    struc.ordinary_wall_result = nothing
    struc.foundation_lateral = nothing
    # No lateral system is declared, so no wall lines are tied. A semirigid
    # membrane belongs to the model and stays.
    struc.diaphragm_layout isa SemirigidDiaphragmLayout || (struc.diaphragm_layout = nothing)
    isnothing(struc.asap_model) && throw(ArgumentError(
        "ordinary wall stage: the building has walls and no Asap model. " *
        "Run to_asap! before sizing them."))
    isempty(struc.wall_mesh.piers) && throw(ArgumentError(
        "ordinary wall stage: the wall mesh is empty. to_asap! has not meshed the walls."))

    # The stored roof pressure is one number. :Lr is the companion the
    # unfactored gravity solve already uses when the caller has not named snow
    # or rain.
    basic = solve_gravity_basic_cases(struc; roof=:Lr, params=params)
    for (i, symbol) in enumerate(basic.symbols)
        _require_gravity_cut_equilibrium(struc, basic.u[i], basic.loads[i], symbol)
    end
    second = isempty(struc.asap_rigid_links) ? nothing :
             _build_second_order(struc, basic)

    checks = Dict{Int, Vector{WallCheckRecord}}()
    n_raised = 0
    max_ρl = 0.0
    max_ρt = 0.0
    trials = WallThicknessTrial[]
    for pier in _solid_piers(struc)
        wall_index = pier.wall_index
        wall = struc.walls[wall_index]
        assembly = _assembly_of(struc.wall_mesh, wall_index)
        material = _gravity_wall_material(wall, params)
        gravity = _gravity_raised_to_shell(struc,
            pier_gravity_actions(struc, basic, pier), wall_index)
        firsts = _gravity_strength_actions(gravity)
        growns = second === nothing ? firsts :
                 _second_order_gravity_actions(struc, pier, basic, second)
        lw, Moop, basis, ρt_strength, raised = _select_pier_steel!(
            struc, wall_index, growns, material)
        raised && (n_raised += 1)
        max_ρl = max(max_ρl, wall.ρl)
        max_ρt = max(max_ρt, wall.ρt)
        records = WallCheckRecord[]
        _each_second_order(records, wall, firsts, growns;
            material, wall_index, case=:D, boundary=:restrained, assembly,
            what="gravity", ρt_strength, lw=lw, Moop=Moop, slab_basis=basis)
        checks[wall_index] = records
        push!(trials, _trial_for_pier(
            struc, wall_index, growns, lw, Moop, material, :restrained, assembly;
            slab_basis=basis))
    end
    n_open, max_ρl, max_ρt = _design_pierced_segments!(
        checks, struc, basic, second;
        material_of=(wall, _) -> _gravity_wall_material(wall, params),
        boundary=:restrained, plan_axis=(1.0, 0.0), max_ρl, max_ρt)
    n_raised += n_open
    @info "Ordinary wall reinforcement" n_piers=length(checks) n_raised max_ρl max_ρt gravity_only=true

    result = OrdinaryWallResult(
        checks, SeismicStoryDriftCheck[], 0.0, Float64[],
        WallGravityShare[], InteractiveStoryShearCheck[], FrameMemberCheck[],
        false, String[], false, Dict{Int, SpecialBoundaryDecision}(),
        Dict{Int, Vector{SpecialBoundaryDecision}}(),
        Dict{Int, BoundaryEndReinforcement}(),
        GravityInducedCheck[])
    struc.ordinary_wall_result = result
    struc.foundation_lateral = nothing
    StructuralSizer.emit!(tc, :pipeline, "design_ordinary_walls!", "stage_ordinary_walls", :exit;
                          n_walls=length(checks), n_drift=0)
    return (result = result, trials = trials, SDS = 0.0)
end

"""
Concrete from the wall when it has one, otherwise the column cascade.
Rebar is the column cascade. No grade is invented beyond that cascade.
"""
function _gravity_wall_material(wall, params)
    rebar = resolve_column_rebar(params.materials)
    concrete = wall.concrete === nothing ?
               resolve_column_concrete(params.materials) : wall.concrete
    return ReinforcedConcreteMaterial(concrete, rebar)
end

"""
Story masters above the base, the base elevation, and the base master.

The base master may be absent. [`story_axial_profiles`](@ref) then requires
the base nodes to be fixed in plan.
"""
function _gravity_diaphragm_geometry(struc)
    master_at = _elf_masters(struc)
    elevs = sort!(unique(_elf_story_elevations(struc.skeleton)))
    isempty(elevs) && throw(ArgumentError(
        "ordinary wall stage: the skeleton has no story elevation."))
    zbase = elevs[1]
    masters = Tuple{Float64, Asap.Node}[]
    for z in elevs
        z <= zbase + WALL_CUT_ZTOL_M && continue
        node = get(master_at, round(Int, z * 1000), nothing)
        node === nothing && throw(ArgumentError(
            "ordinary wall stage: the story at $(z) m has no rigid-diaphragm " *
            "master. Set DesignParameters.diaphragm_mode to :rigid before prepare!."))
        push!(masters, (Float64(z), node))
    end
    isempty(masters) && throw(ArgumentError(
        "ordinary wall stage: no story sits above the base, so the story " *
        "stiffness has no master."))
    base_master = get(master_at, round(Int, zbase * 1000), nothing)
    return masters, zbase, base_master
end

"""
Solid piers, one per wall.

A wall with openings is left for the segment checks. A second pier on the
same wall throws.
"""
function _solid_piers(struc)
    seen = Set{Int}()
    out = WallPierMesh[]
    for pier in struc.wall_mesh.piers
        wall_index = pier.wall_index
        isempty(struc.walls[wall_index].openings) || continue
        wall_index in seen && throw(ArgumentError(
            "ordinary wall stage: wall $wall_index has more than one pier."))
        push!(seen, wall_index)
        push!(out, pier)
    end
    return out
end

"""
Raise `ρl` and `ρt` for one pier.

Returns the clear length, the envelope slab moment, the pressure basis that
pairs that moment with each combination, the strength `ρt`, and whether
either ratio moved up.
"""
function _select_pier_steel!(struc, wall_index::Int, grown, material)
    wall = struc.walls[wall_index]
    ρl0 = wall.ρl
    ρt0 = wall.ρt
    lw = joined_clear_length(wall, struc.walls, wall_index) * u"m"
    Moop = _slab_moment_into_wall(struc, wall, lw)
    basis = _governing_slab_basis(struc, wall)
    ρt_strength = select_ordinary_wall_reinforcement!(
        wall, grown, material; hw=_stacked_wall_height(wall), lw=lw, Moop=Moop,
        slab_basis=basis)
    raised = wall.ρl > ρl0 + 1e-12 || wall.ρt > ρt0 + 1e-12
    return lw, Moop, basis, ρt_strength, raised
end

"""
One basic case on one pier: first-order actions, second-order actions, and
the moment parts of each.

`first_parts[i]` and `grown_parts[i]` are the gravity moment and the wind or
Eh moment of action `i`. They add to that action's `M`. The second-order
actions are the ones the reinforcement search and the recorded checks use.
"""
struct PierStrengthBatch
    case::Symbol
    firsts::Vector{CombinedWallAction}
    growns::Vector{CombinedWallAction}
    what::String
    first_parts::Vector{Vector{Float64}}
    grown_parts::Vector{Vector{Float64}}
    function PierStrengthBatch(case, firsts, growns, what, first_parts, grown_parts)
        n = length(firsts)
        (n == length(growns) == length(first_parts) == length(grown_parts)) ||
            throw(ArgumentError(
                "ordinary wall stage: $what has $n first-order combinations, " *
                "$(length(growns)) second-order combinations, " *
                "$(length(first_parts)) first-order moment parts, and " *
                "$(length(grown_parts)) second-order moment parts."))
        _require_moment_parts(firsts, first_parts, what, "first-order")
        _require_moment_parts(growns, grown_parts, what, "second-order")
        return new(case, firsts, growns, what, first_parts, grown_parts)
    end
end

"The parts of one action add to its in-plane moment, within 1 N·m."
function _require_moment_parts(actions, parts, what, which)
    for (i, (action, part)) in enumerate(zip(actions, parts))
        length(part) == 2 || throw(ArgumentError(
            "ordinary wall stage: $what $which combination $i has " *
            "$(length(part)) moment parts. Gravity and the lateral action are the two."))
        abs(sum(part) - action.M) <= 1.0 || throw(ArgumentError(
            "ordinary wall stage: $what $which combination $i moment parts " *
            "sum to $(sum(part)) N·m and the combination moment is $(action.M) N·m."))
    end
    return nothing
end

"""
First-order and second-order strength actions for one pier.

Each batch is one basic case. The second-order actions are the ones the
reinforcement search and the recorded checks both use.
"""
function _pier_action_batches(struc, pier, basic, wind, elf, second, gravity, inputs,
                              effects::AbstractVector{SeismicEffectCase})
    batches = PierStrengthBatch[]
    # No story stiffness: the combinations stay the first-order actions.
    grav = _gravity_strength_actions(gravity)
    grav2 = second === nothing ? grav :
            _second_order_gravity_actions(struc, pier, basic, second)
    push!(batches, PierStrengthBatch(:D, grav, grav2, "gravity",
                                     _paired_moment_parts(grav), _paired_moment_parts(grav2)))
    wind1 = wind_pier_actions(struc, wind, pier)
    for (i, action) in enumerate(wind1)
        first = _wind_strength_actions(gravity, action)
        first_parts = _wind_moment_parts(gravity, action)
        if second === nothing
            growns, grown_parts = first, first_parts
        else
            growns, grown_parts = _second_order_wind_actions(struc, pier, basic, second, i)
        end
        push!(batches, PierStrengthBatch(
            _wind_case_symbol(i, wind.cases[i]), first, growns, "wind case $i",
            first_parts, grown_parts))
    end
    qe_actions = second === nothing ?
        [_pdelta_scaled_qe(struc, elf, pier, e) for e in effects] :
        seismic_strength_pier_actions(struc, elf, pier, effects)
    for (k, action) in enumerate(qe_actions)
        first = _seismic_strength_actions(gravity, action, inputs.rho, inputs.SDS)
        first_parts = _seismic_moment_parts(gravity, action, inputs.rho, inputs.SDS)
        if second === nothing
            growns, grown_parts = first, first_parts
        else
            growns, grown_parts = _second_order_seismic_actions(
                struc, pier, basic, second, k, inputs.rho, inputs.SDS)
        end
        push!(batches, PierStrengthBatch(
            effects[k].label, first, growns, "QE $(effects[k].label)",
            first_parts, grown_parts))
    end
    return batches
end

"""
Gravity moment and a zero lateral moment for each gravity combination.

A gravity reading has no wind and no earthquake, so its combination moment
is the gravity part.
"""
function _paired_moment_parts(actions::Vector{CombinedWallAction})
    return [[a.M, 0.0] for a in actions]
end

"Gravity and wind moments of one wind case, in the wind-reading order."
function _wind_moment_parts(gravity::PierGravityActions, wind::WallAction)
    return [factored_inplane_moment_parts(combo, gravity; wind, alternative=alt)
            for (combo, alt, _) in _wind_readings(gravity.roof)]
end

"Gravity and Eh moments of one strength QE, in the earthquake-reading order."
function _seismic_moment_parts(gravity::PierGravityActions, qe::WallAction, rho, SDS)
    return [factored_inplane_moment_parts(combo, gravity; qe, rho, SDS, alternative=alt)
            for (combo, alt, _) in _seismic_readings(gravity.roof)]
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

With no `elf`, the batch is the three gravity cases and the keys are the
gravity readings. That is the gravity-only stage. With `elf`, the batch
appends every wind case and every seismic effect, and the keys include the
wind and earthquake readings.
"""
function _build_second_order(struc, basic; wind=nothing, elf=nothing,
                             effects=nothing)
    roof = basic.symbols[3]
    model = struc.asap_model
    if elf === nothing
        masters, base, base_master = _gravity_diaphragm_geometry(struc)
        keys = GravityStiffnessKey[]
        for (_, _, key) in _gravity_readings(roof)
            _pushkey!(keys, key)
        end
        nwind = 0
        nqe = 0
        batch = basic.loads
    else
        wind === nothing && throw(ArgumentError(
            "ordinary wall stage: story stiffness with an ELF analysis needs the wind cases."))
        effects === nothing && throw(ArgumentError(
            "ordinary wall stage: story stiffness with an ELF analysis needs the seismic effects."))
        masters = [(lv.elevation_m, lv.master) for lv in elf.levels]
        isempty(masters) && throw(ArgumentError(
            "ordinary wall stage: the ELF analysis has no level, so the story " *
            "stiffness has no master."))
        base = first(elf.levels).elevation_m - first(elf.levels).story_height_m
        base_master = get(_elf_masters(struc), round(Int, base * 1000), nothing)
        wind_cases = [_wind_loads(struc, wind.levels, c.Fx_kN, c.Fy_kN, c.Mz_kN_m,
                                  wind.centroids) for c in wind.cases]
        qe_cases = [seismic_effect_loads(struc, elf, e) for e in effects]
        nwind = length(wind_cases)
        nqe = length(qe_cases)
        batch = Vector{Vector{Asap.AbstractLoad}}()
        append!(batch, basic.loads)
        append!(batch, wind_cases)
        append!(batch, qe_cases)
        keys = _stage_gravity_keys(roof)
    end
    sets = Dict{GravityStiffnessKey, StorySecondOrderSet}()
    for key in keys
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
        sets[key] = StorySecondOrderSet(key, u2, nwind, nqe, Kg)
    end
    return sets
end

"""
Every unfactored component solved first-order, filed under each stage gravity key.

A flexible floor has no master to carry a story geometric stiffness, so every
key holds the same first-order displacements and a zero `K_G`. The lateral
components are solved with the collector ties along the wall lines
([`lateral_solve_links`](@ref)). Forces read from these sets are first-order,
like the flexible pier actions.
"""
function _build_first_order(struc, basic; wind, elf, effects)
    model = struc.asap_model
    batch = Vector{Vector{Asap.AbstractLoad}}()
    for c in wind.cases
        push!(batch, _wind_loads(struc, wind.levels, c.Fx_kN, c.Fy_kN, c.Mz_kN_m,
                                 wind.centroids))
    end
    for e in effects
        push!(batch, seismic_effect_loads(struc, elf, e))
    end
    u = Vector{Vector{Float64}}(basic.u[1:3])
    append!(u, Asap.solve(model, batch, lateral_solve_links(struc)))
    Kg = spzeros(model.nDOFs, model.nDOFs)
    sets = Dict{GravityStiffnessKey, StorySecondOrderSet}()
    for key in _stage_gravity_keys(basic.symbols[3])
        sets[key] = StorySecondOrderSet(key, u, length(wind.cases), length(effects), Kg)
    end
    return sets
end

function _second_order_gravity(struc, pier, basic, set::StorySecondOrderSet)
    wall = struc.walls[pier.wall_index]
    actions = ntuple(3) do i
        pier_wall_action(wall, pier, set.u[i];
                         loads=basic.loads[i], fixed_end_from_loads=true)
    end
    return _gravity_raised_to_shell(struc,
        PierGravityActions(basic.symbols[3], actions...), pier.wall_index)
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
    parts = Vector{Float64}[]
    for (combo, alt, key) in _wind_readings(basic.symbols[3])
        set = second[key]
        grown = _second_order_gravity(struc, pier, basic, set)
        wind = _second_order_lateral(struc, pier, set.u[3 + i])
        push!(out, combine_wall_action(combo, grown; wind, alternative=alt))
        push!(parts, factored_inplane_moment_parts(combo, grown; wind, alternative=alt))
    end
    return out, parts
end

function _second_order_seismic_actions(struc, pier, basic, second, k::Int, rho, SDS)
    nwind = first(values(second)).nwind
    out = CombinedWallAction[]
    parts = Vector{Float64}[]
    for (combo, alt, key) in _seismic_readings(basic.symbols[3])
        set = second[key]
        grown = _second_order_gravity(struc, pier, basic, set)
        qe = _second_order_lateral(struc, pier, set.u[3 + nwind + k])
        push!(out, combine_wall_action(combo, grown; qe, rho, SDS, alternative=alt))
        push!(parts, factored_inplane_moment_parts(combo, grown; qe, rho, SDS, alternative=alt))
    end
    return out, parts
end

"""
Factored slab moment delivered into this pier, about its weak axis.

The panel stores the envelope at a wall support in each span direction.
A wall perpendicular to the primary span takes the primary envelope.
A wall parallel to it takes the secondary envelope. A wall between those
takes the larger. The pier's share is its clear length over the wall
centerline, so a short joined leg does not receive the whole wall's moment.
Slabs that are not at this pier's bottom or top do not load it.
"""
function _slab_moment_into_wall(struc, wall, lw)
    hasproperty(struc, :slabs) || return 0.0u"N*m"
    L = wall_length(wall)
    L > 0 || return 0.0u"N*m"
    ux, uy = (wall.x2 - wall.x1) / L, (wall.y2 - wall.y1) / L
    clear = lw isa Unitful.Quantity ? ustrip(u"m", lw) : Float64(lw)
    share = min(max(clear, 0.0) / L, 1.0)
    height = hasproperty(wall, :base) ? ustrip(u"m", wall.base.L) : nothing
    z0, z1 = _story_range_m(struc, wall.story, height)
    moment = 0.0u"N*m"
    for slab in struc.slabs
        result = slab.result
        result isa StructuralSizer.FlatPlatePanelResult || continue
        z = _slab_elevation_m(struc, slab)
        z === nothing && continue
        at_joint = (z0 !== nothing && abs(z - z0) <= 0.05) ||
                   (z1 !== nothing && abs(z - z1) <= 0.05)
        at_joint || continue
        moment = max(moment, _directed_wall_moment(result, slab, ux, uy))
    end
    return moment * share
end

"""
How the slab moment into this pier pairs with each load combination.

`qD` and `qL` are the dead and live pressures, in pascals, of the slab that
delivers the largest wall moment. `roof` is true when that slab is a roof,
so its live case is roof live rather than floor live. `faces` holds
`(D, L, roof)` in N·m for every wall face of every slab at the pier's
joints, from the panels' `wall_face_parts` in the direction
[`_directed_wall_moment`](@ref) picks. `faces` is `nothing` when a slab
that loads the pier has no parts, and the pressures pair the moment
instead. `nothing` when no flat-plate panel meets the pier.
"""
function _governing_slab_basis(struc, wall)
    hasproperty(struc, :slabs) || return nothing
    L = wall_length(wall)
    L > 0 || return nothing
    ux, uy = (wall.x2 - wall.x1) / L, (wall.y2 - wall.y1) / L
    height = hasproperty(wall, :base) ? ustrip(u"m", wall.base.L) : nothing
    z0, z1 = _story_range_m(struc, wall.story, height)
    best = 0.0
    basis = nothing
    faces = NamedTuple{(:D, :L, :roof), Tuple{Float64, Float64, Bool}}[]
    paired = true
    for slab in struc.slabs
        result = slab.result
        result isa StructuralSizer.FlatPlatePanelResult || continue
        z = _slab_elevation_m(struc, slab)
        z === nothing && continue
        at_joint = (z0 !== nothing && abs(z - z0) <= 0.05) ||
                   (z1 !== nothing && abs(z - z1) <= 0.05)
        at_joint || continue
        m = ustrip(u"N*m", _directed_wall_moment(result, slab, ux, uy))
        roof = hasproperty(slab, :floor_type) && slab.floor_type === :roof
        if m > 0
            parts = _directed_wall_face_parts(result, slab, ux, uy)
            paired &= !isempty(parts)
            for (D, Lp) in parts
                push!(faces, (D = D, L = Lp, roof = roof))
            end
        end
        m > best || continue
        qD, qL = _slab_gravity_pressures(struc, slab)
        (qD > 0 || qL > 0) || continue
        best = m
        basis = (qD = qD, qL = qL, roof = roof)
    end
    basis === nothing && return nothing
    return (basis..., faces = paired ? faces : nothing)
end

"Largest cell dead and live pressures on one slab, in pascals."
function _slab_gravity_pressures(struc, slab)
    qD = 0.0
    qL = 0.0
    hasproperty(slab, :cell_indices) || return qD, qL
    for ci in slab.cell_indices
        cell = struc.cells[ci]
        qD = max(qD, ustrip(u"Pa", cell.sdl + cell.self_weight))
        qL = max(qL, ustrip(u"Pa", cell.live_load))
    end
    return qD, qL
end

"""
Span directions whose wall moment loads a wall along `(ux, uy)`.

A wall across the primary span (|cos| ≤ 0.34) takes the primary, a wall
along it (|cos| ≥ 0.94) the secondary, and a wall between those both.
"""
function _wall_span_directions(slab, ux, uy)
    axis = StructuralSizer._get_span_axis(slab)
    dot = abs(ux * axis[1] + uy * axis[2])
    return (primary = dot < 0.94, secondary = dot > 0.34)
end

function _directed_wall_moment(result, slab, ux, uy)
    dirs = _wall_span_directions(slab, ux, uy)
    chosen = max(dirs.primary ? abs(result.M_wall) : zero(result.M_wall),
                 dirs.secondary ? abs(result.M_wall_secondary) : zero(result.M_wall))
    return uconvert(u"N*m", chosen)
end

"""`wall_face_parts` in the directions [`_directed_wall_moment`](@ref) reads."""
function _directed_wall_face_parts(result, slab, ux, uy)
    dirs = _wall_span_directions(slab, ux, uy)
    parts = NTuple{2,Float64}[]
    if dirs.primary && abs(result.M_wall) > zero(result.M_wall)
        isempty(result.wall_face_parts) && return NTuple{2,Float64}[]
        append!(parts, result.wall_face_parts)
    end
    if dirs.secondary && abs(result.M_wall_secondary) > zero(result.M_wall_secondary)
        isempty(result.wall_face_parts_secondary) && return NTuple{2,Float64}[]
        append!(parts, result.wall_face_parts_secondary)
    end
    return parts
end

function _each_second_order(records, wall, first_actions, second_actions;
                             material, wall_index, case, boundary, assembly, what,
                             ρt_strength=nothing, plan_axis=(1.0, 0.0),
                             lw::Union{Nothing,Unitful.Length}=nothing,
                             Moop=0.0u"N*m", slab_basis=nothing, ends=nothing,
                             first_parts=nothing, grown_parts=nothing)
    length(first_actions) == length(second_actions) || throw(ArgumentError(
        "ordinary wall stage: $what has $(length(first_actions)) first-order " *
        "combinations and $(length(second_actions)) second-order combinations."))
    if first_parts !== nothing || grown_parts !== nothing
        (first_parts !== nothing && grown_parts !== nothing) || throw(ArgumentError(
            "ordinary wall stage: $what has moment parts on one order only."))
        (length(first_parts) == length(first_actions) &&
         length(grown_parts) == length(second_actions)) || throw(ArgumentError(
            "ordinary wall stage: $what moment parts do not line up with the combinations."))
    end
    for (i, (first, grown)) in enumerate(zip(first_actions, second_actions))
        _accept_second_order!(records, wall, first, grown;
                              material, wall_index, case, boundary, assembly,
                              ρt_strength, plan_axis, lw, Moop, slab_basis, ends,
                              first_parts=first_parts === nothing ? nothing : first_parts[i],
                              grown_parts=grown_parts === nothing ? nothing : grown_parts[i])
    end
    return records
end

function _accept_second_order!(records, wall, first::CombinedWallAction,
                               grown::CombinedWallAction;
                               material, wall_index, case, boundary, assembly,
                               ρt_strength=nothing, plan_axis=(1.0, 0.0),
                               lw::Union{Nothing,Unitful.Length}=nothing,
                               Moop=0.0u"N*m", slab_basis=nothing, ends=nothing,
                               first_parts=nothing, grown_parts=nothing)
    (first.combination === grown.combination && first.alternative === grown.alternative) ||
        throw(ArgumentError(
            "ordinary wall stage: first-order $(first.combination)/$(first.alternative) " *
            "does not match second-order $(grown.combination)/$(grown.alternative)."))
    _record_second_order_moment!(records, wall, first, grown; wall_index, case, plan_axis,
                                 first_parts, grown_parts)
    append!(records, check_ordinary_wall(wall, CombinedWallAction[grown];
                                         material, wall_index, case, boundary, assembly,
                                         ρt_strength, plan_axis, lw, Moop,
                                         slab_basis=slab_basis, ends))
    return records
end

"""
Record ACI 318-19 §6.2.5.3 when one action's second-order moment is above the limit.

`first_parts` and `grown_parts` are the gravity moment and the wind or Eh
moment. With neither argument, the combination moment is the one action.
The strength checks still use the summed second-order forces. A part under
1 N·m on both orders is not a ratio. The recorded ratio is the largest
part that exceeds the limit.

# Citation
ACI 318-19 §6.2.5.3 (corpus: aci-318-19, PDF page 72): Mu including
second-order effects shall not exceed 1.4 Mu due to first-order effects.
R6.2.5.3 (same page): 1.4 is the secondary-to-primary moment ratio. A
stability index Q of 0.2 corresponds to 1.25, and the ASCE 7 stability
coefficient of 0.25 corresponds to 1.33.
"""
function _record_second_order_moment!(records, wall, first::CombinedWallAction,
                                      grown::CombinedWallAction; wall_index, case,
                                      plan_axis=(1.0, 0.0),
                                      first_parts=nothing, grown_parts=nothing)
    parts1 = first_parts === nothing ? [first.M] : first_parts
    parts2 = grown_parts === nothing ? [grown.M] : grown_parts
    length(parts1) == length(parts2) || throw(ArgumentError(
        "ordinary wall stage: $(first.combination) has $(length(parts1)) " *
        "first-order moment parts and $(length(parts2)) second-order moment parts."))
    worst = nothing
    for (m1, m2) in zip(parts1, parts2)
        found = _second_order_part_ratio(m2, m1)
        found === nothing && continue
        if worst === nothing || found.ratio > worst.ratio
            worst = found
        end
    end
    worst === nothing && return records
    push!(records, WallCheckRecord(
        wall_index, wall.story, _pier_axis_direction(wall, plan_axis), case,
        grown.combination, grown.alternative, "second-order moment",
        false, worst.ratio, worst.demand, worst.limit,
        "ACI 318-19 §6.2.5.3"))
    return records
end

"The secondary-to-primary ratio of one moment, or nothing when it is within 1.4."
function _second_order_part_ratio(m2, m1)
    a2 = abs(Float64(m2))
    a1 = abs(Float64(m1))
    (a2 <= 1.0 && a1 <= 1.0) && return nothing
    # ACI 318-19 §6.2.5.3 (corpus: aci-318-19, PDF page 72).
    limit = 1.4 * a1
    a2 <= limit + 1.0 && return nothing
    return (ratio = a1 == 0.0 ? Inf : a2 / a1, demand = a2, limit = limit)
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
