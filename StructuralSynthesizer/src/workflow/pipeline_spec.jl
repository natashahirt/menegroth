# =============================================================================
# Pipeline Construction
# =============================================================================

"""
    build_pipeline(params::DesignParameters) -> Vector{PipelineStage}

Compose the design pipeline from `DesignParameters`.

Returns a vector of `PipelineStage`s. Each stage has a `.fn` closure that
mutates the structure (sizing members, updating loads) and a `.needs_sync`
flag.  The outer loop calls `sync_asap!` only for stages that need it.

# Stages (by floor type)

**Flat plate** (:flat_plate)
1. Size slabs (DDM/EFM/FEA — includes column P-M design)
2. Reconcile columns (take max of slab-designed and Asap-found)
3. Size ordinary walls (a thickness jump remeshes here)
4. Size foundations (if requested), on the wall thickness that jump left

**One-way slab / two-way slab** (:one_way, :two_way)
1. Size slabs
2. Size beams + columns (iterative convergence loop)
3. Size ordinary walls
4. Size foundations (if requested)

**Vault** (:vault)
1. Size slabs (vault geometry)
2. Size beams + columns (iterative — beam must resist thrust)
3. Size ordinary walls
4. Size foundations (if requested)
"""
function build_pipeline end  # forward declaration for docstring

"""
    PipelineStage

Tagged stage: pairs a mutating function with a flag indicating whether the
outer loop should call `sync_asap!` afterwards.

- `needs_sync=true`  → full load update + solve after the stage
- `needs_sync=false` → stage either self-syncs or doesn't touch the model
"""
struct PipelineStage
    fn::Function
    needs_sync::Bool
end

# Trace registry entries for documented functions.
StructuralSizer.TRACE_REGISTRY[(:build_pipeline, :pipeline)] =
    StructuralSizer.TracedFunctionMeta(
        :build_pipeline,
        :pipeline,
        [:enter, :exit, :decision],
        nothing,
        @__FILE__,
        @__LINE__,
    )

function build_pipeline(params::DesignParameters;
                        tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing)
    stages = PipelineStage[]
    
    floor_opts = resolve_floor_options(params)
    floor_type = _infer_floor_type(floor_opts)

    StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "", :enter;
                          floor_type=string(floor_type),
                          floor_opts_type=string(typeof(floor_opts)))
    
    # Extract column options for flat plate/slab sizing (needed for design_details)
    column_opts = _get_column_opts(params)
    if floor_type in (:flat_plate, :flat_slab) && column_opts isa StructuralSizer.PixelFrameColumnOptions
        StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "", :failure;
                              error="ArgumentError",
                              message="Flat plate/slab requires reinforced concrete columns; PixelFrame columns not supported.")
        throw(ArgumentError(
            "Flat plate/slab requires reinforced concrete columns. " *
            "PixelFrame columns are not supported for beamless slab systems."))
    end
    
    StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "", :decision;
                          floor_type=string(floor_type),
                          needs_beams_columns=(floor_type ∉ (:flat_plate, :flat_slab)),
                          needs_foundations=(!isnothing(params.foundation_options)),
                          needs_ordinary_walls=true)
    
    # ─── Stage 1: Slab sizing (always) ─── needs sync to push slab self-weight
    push!(stages, PipelineStage(struc -> begin
        StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_1_slabs", :enter;
                              floor_type=string(floor_type))
        slab_opts = [_floor_options_for_slab(struc, i, params, floor_opts)
                     for i in eachindex(struc.slabs)]
        design_floors!(
            struc;
            options = floor_opts,
            slab_options = slab_opts,
            column_options = column_opts,
            max_iterations = params.max_iterations,
            fire_rating = params.fire_rating,
            verbose = false,
            tc = tc,
        )
        update_slab_volumes!(struc; options=floor_opts, slab_options=slab_opts)
        StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_1_slabs", :exit)
    end, true))
    
    # ─── Stage 2: Beam + column sizing ───
    # Uniform column sizing runs inside this stage (inside the beam/column
    # loop for beam-based floors), so walls and foundations see the final
    # columns.
    flat = floor_type in (:flat_plate, :flat_slab)
    size_members! = flat ?
        struc -> _design_flat_plate_members!(struc, params; tc=tc) :
        struc -> _size_beams_columns!(struc, params; tc=tc)
    stage_name = flat ? "stage_2_reconcile" : "stage_2_beams_columns"
    push!(stages, PipelineStage(struc -> begin
        StructuralSizer.emit!(tc, :pipeline, "build_pipeline", stage_name, :enter)
        size_members!(struc)
        StructuralSizer.emit!(tc, :pipeline, "build_pipeline", stage_name, :exit)
    end, !flat))
    
    # Ordinary walls before foundations. A thickness jump calls `to_asap!`
    # and re-solves inside this stage. ACI 318-11 §15.2.2 (aci-318-11, page
    # 271) sizes the base from the unfactored force on the wall that will be
    # built, so the footing must see that thickness. Reinforcement alone does
    # not change stiffness, and the jump solves itself, so this stage does
    # not ask the outer loop to sync. After a jump the members are sized
    # again on the new model (see `_walls_with_member_recheck!`).
    push!(stages, PipelineStage(
        struc -> _walls_with_member_recheck!(struc, params, size_members!;
                                             sync_after_members = !flat, tc=tc), false))

    # Foundations read the solved model and do not change it.
    if !isnothing(params.foundation_options)
        push!(stages, PipelineStage(struc -> begin
            StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_foundations", :enter)
            _size_foundations!(struc, params.foundation_options; tc=tc)
            StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_foundations", :exit)
        end, false))
    end
    
    StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "", :exit;
                          n_stages=length(stages))
    return stages
end

"""
    _walls_with_member_recheck!(struc, params, size_members!; sync_after_members,
                                tc=nothing, max_rounds=4)

Run the ordinary-wall stage. When it jumps a wall thickness, the members were
checked on a model that no longer exists, so they are sized again on the new
one (followed by `sync_asap!` when `sync_after_members`, as the member stage
gets in the pipeline). When the row F frame check sets a new section floor
(`struc.frame_section_floors`) or stores new rows for NLP sizing
(`struc.frame_floor_demands`), the members are sized again the same way.
A frame column that fails its P–M check on the wall solution is floored at
its current section and sized again too: the member stage ran before the
walls were in the model, and a wall that does not change thickness still
changes the column forces. If that changes any member section, the walls
and frames are checked again against those members.

Wall thickness only grows, in whole inches, and a floor only moves to a
heavier catalog section, so the rounds end. `max_rounds` is a backstop; when
it is reached, `stage_diagnostics[:wall_members]` says so and the last
analysis stands.
"""
function _walls_with_member_recheck!(struc::BuildingStructure, params::DesignParameters,
                                     size_members!::Function;
                                     sync_after_members::Bool,
                                     tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
                                     max_rounds::Int = 4)
    delete!(struc.stage_diagnostics, :wall_members)
    member_sections() = vcat(Any[_story_beam_section(struc, b) for b in struc.beams],
                             Any[section(c) for c in struc.columns])
    thicknesses() = [w.thickness for w in struc.walls]
    floors() = (copy(struc.frame_section_floors),
                Dict(gid => copy(r) for (gid, r) in struc.frame_floor_demands))
    floors_same((fa, ra), (fb, rb)) = ra == rb && keys(fa) == keys(fb) &&
                                      all(_sections_identical(fa[k], fb[k]) for k in keys(fa))
    for round in 1:max_rounds
        t_before = thicknesses()
        f_before = floors()
        result = design_ordinary_walls!(struc, params; tc=tc)
        thickness_same = t_before == thicknesses()
        floors_unchanged = floors_same(f_before, floors())
        # A failing column is floored here. The flag stays true even when the
        # floor was already there, so the members are sized once on this
        # solution; an unchanged section ends the rounds below.
        overstressed = _floor_overstressed_frame_columns!(struc, params)
        thickness_same && floors_unchanged && !overstressed && return result
        before = member_sections()
        size_members!(struc)
        sync_after_members && sync_asap!(struc; params)
        held = all(_sections_identical(a, b) for (a, b) in zip(before, member_sections()))
        StructuralSizer.emit!(tc, :workflow, "_walls_with_member_recheck!", "", :decision;
                              round = round, members_changed = !held,
                              columns_overstressed = overstressed)
        held && return result
    end
    struc.stage_diagnostics[:wall_members] =
        "Walls and members were still changing each other after $max_rounds rounds " *
        "of wall thickness jumps, row F frame resizing, and frame-column " *
        "re-sizing; the last analysis stands."
    return struc.ordinary_wall_result
end

"""
Submit a floor for each RC frame column that fails P–M, and return whether
any column failed.

The floor is the section that just failed. [`submit_column_section_floor!`](@ref)
records it; this function does not choose a replacement. Discrete sizing then
keeps that section or a heavier one. A floor already at least that heavy is
left alone. The caller still sizes once; if the section does not change, that
round is the last. The floor is not trimmed: the section already failed this
check. Flat-plate columns are judged by the slab check, not these frame
forces. Steel columns are left to their own sizer. A column option set that
cannot keep a catalog floor still counts as overstressed, so the members are
sized once on the wall solution.
"""
function _floor_overstressed_frame_columns!(struc::BuildingStructure, params::DesignParameters)
    opts = params.columns
    opts isa StructuralSizer.ConcreteColumnOptions || return false
    envs = column_force_envelopes(struc, params)
    isempty(envs) && return false
    supported = flat_plate_supported_columns(struc)
    can_floor = opts.sizing_strategy !== :nlp && opts.materials === nothing &&
                opts.n_max_sections == 0
    overstressed = false
    for (i, col) in enumerate(struc.columns)
        i in supported && continue
        haskey(envs, i) || continue
        checked = rc_frame_column_check(col, opts, frame_column_demand(envs[i]))
        (checked === nothing || checked.passed) && continue
        overstressed = true
        can_floor || continue
        submit_column_section_floor!(struc, opts, group_id(col), section(col))
    end
    return overstressed
end
