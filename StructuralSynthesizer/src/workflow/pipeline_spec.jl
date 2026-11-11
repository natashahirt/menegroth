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
3. Size foundations (if requested)

**One-way slab / two-way slab** (:one_way, :two_way)
1. Size slabs
2. Size beams + columns (iterative convergence loop)
3. Size foundations (if requested)

**Vault** (:vault)
1. Size slabs (vault geometry)
2. Size beams + columns (iterative — beam must resist thrust)
3. Size foundations (if requested)
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
                          needs_ordinary_walls=(params.lateral !== nothing))
    
    # ─── Stage 1: Slab sizing (always) ─── needs sync to push slab self-weight
    push!(stages, PipelineStage(struc -> begin
        StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_1_slabs", :enter;
                              floor_type=string(floor_type))
        design_floors!(
            struc;
            options = floor_opts,
            column_options = column_opts,
            max_iterations = params.max_iterations,
            fire_rating = params.fire_rating,
            verbose = false,
            tc = tc,
        )
        update_slab_volumes!(struc; options=floor_opts)
        StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_1_slabs", :exit)
    end, true))
    
    # ─── Stage 2: Beam + column sizing ───
    if floor_type in (:flat_plate, :flat_slab)
        push!(stages, PipelineStage(struc -> begin
            StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_2_reconcile", :enter)
            _reconcile_columns!(struc, params; tc=tc)
            StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_2_reconcile", :exit)
        end, false))
    else
        push!(stages, PipelineStage(struc -> begin
            StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_2_beams_columns", :enter)
            _size_beams_columns!(struc, params; tc=tc)
            StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_2_beams_columns", :exit)
        end, true))
    end
    
    # ─── Stage 3: Foundations (if requested) ─── no Asap model changes
    if !isnothing(params.foundation_options)
        push!(stages, PipelineStage(struc -> begin
            StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_3_foundations", :enter)
            _size_foundations!(struc, params.foundation_options; tc=tc)
            StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_3_foundations", :exit)
        end, false))
    end

    # Ordinary walls, only when lateral design was requested. The checks do not
    # change stiffness, so the stage does not sync the model. A gravity-only
    # building keeps the two stages above.
    if params.lateral !== nothing
        push!(stages, PipelineStage(
            struc -> _walls_with_member_recheck!(struc, params; tc=tc), false))
    end
    
    StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "", :exit;
                          n_stages=length(stages))
    return stages
end

"""
Run the ordinary-wall stage. When the row F frame check sets a new section
floor, or stores new rows for NLP sizing, size the members again and check
the frame on those sections. Wall
thickness is left to the wall stage itself. `max_rounds` is a backstop; when
it is reached, `stage_diagnostics[:wall_members]` says so and the last
analysis stands.
"""
function _walls_with_member_recheck!(struc::BuildingStructure, params::DesignParameters;
                                     tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
                                     max_rounds::Int = 4)
    delete!(struc.stage_diagnostics, :wall_members)
    floors() = (copy(struc.frame_section_floors),
                Dict(gid => copy(r) for (gid, r) in struc.frame_floor_demands))
    floors_same((fa, ra), (fb, rb)) = ra == rb && keys(fa) == keys(fb) &&
                                      all(_sections_identical(fa[k], fb[k]) for k in keys(fa))
    member_sections() = vcat(Any[b.base.section for b in struc.beams],
                             Any[c.base.section for c in struc.columns])
    flat = _infer_floor_type(resolve_floor_options(params)) in (:flat_plate, :flat_slab)
    for round in 1:max_rounds
        f_before = floors()
        result = design_ordinary_walls!(struc, params; tc=tc)
        floors_same(f_before, floors()) && return result
        before = member_sections()
        if flat
            _reconcile_columns!(struc, params; tc=tc)
        else
            _size_beams_columns!(struc, params; tc=tc)
        end
        held = all(_sections_identical(a, b) for (a, b) in zip(before, member_sections()))
        StructuralSizer.emit!(tc, :workflow, "_walls_with_member_recheck!", "", :decision;
                              round = round, members_changed = !held)
        held && return result
    end
    struc.stage_diagnostics[:wall_members] =
        "Walls and members were still changing each other after $max_rounds rounds " *
        "of row F frame resizing; the last analysis stands."
    return struc.ordinary_wall_result
end
