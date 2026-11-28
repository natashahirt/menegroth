"""
    floor_design_request(struc, slab_idx; options, column_options=nothing, ...)

Build the immutable `StructuralSizer` request for one declared slab.

The returned value contains only source identity and design policy. The live
`BuildingStructure` remains owned by `StructuralSynthesizer`; flat-plate
requests also carry a normalized immutable engineering input.
"""
_flat_plate_length(value) = isnothing(value) ? nothing : uconvert(u"m", value)

function _flat_plate_span_input(spans)
    StructuralSizer.FlatPlateSpanInput(
        uconvert(u"m", spans.primary),
        uconvert(u"m", spans.secondary),
        (Float64(spans.axis[1]), Float64(spans.axis[2])),
        uconvert(u"m", spans.isotropic),
    )
end

function _flat_plate_above_support(column)
    isnothing(column) && return nothing
    return StructuralSizer.FlatPlateAboveSupportInput(
        _flat_plate_length(column.c1),
        _flat_plate_length(column.c2),
        column.shape,
        column.θ,
        uconvert(u"m", column.base.L),
        column.concrete,
    )
end

function _flat_plate_design_input(struc::BuildingStructure, slab_idx::Int)
    skeleton = struc.skeleton
    topology = StructuralSizer.FlatPlateTopologyInput(
        Matrix{Float64}(skeleton.geometry.vertex_coords),
        [Int[index for index in face] for face in skeleton.face_vertex_indices],
        [Int[index for index in face] for face in skeleton.face_edge_indices],
        Tuple{Int, Int}[(Int(edge[1]), Int(edge[2])) for edge in skeleton.edge_indices],
        deepcopy(skeleton.faces),
    )
    cells = StructuralSizer.FlatPlateCellInput[
        StructuralSizer.FlatPlateCellInput(
            cell.face_idx,
            cell.position,
            uconvert(u"m^2", cell.area),
            uconvert(u"kPa", cell.sdl),
            uconvert(u"kPa", cell.live_load),
            uconvert(u"kPa", cell.self_weight),
            _flat_plate_span_input(cell.spans),
        )
        for cell in struc.cells
    ]
    floors = StructuralSizer.FlatPlateFloorInput[
        StructuralSizer.FlatPlateFloorInput(
            copy(slab.cell_indices),
            _flat_plate_span_input(slab.spans),
            slab.floor_type,
            deepcopy(slab.result),
            deepcopy(slab.drop_panel),
            copy(StructuralSizer.supporting_wall_segments(struc, slab)),
            StructuralSizer.flat_plate_wall_piers(struc, slab),
        )
        for slab in struc.slabs
    ]
    supports = StructuralSizer.FlatPlateSupportInput[
        StructuralSizer.FlatPlateSupportInput(
            column_idx,
            column.vertex_idx,
            _flat_plate_length(column.c1),
            _flat_plate_length(column.c2),
            column.shape,
            column.θ,
            column.story,
            column.position,
            column.corner_kind,
            column.corner_angle,
            copy(column.boundary_edge_dirs),
            copy(column.boundary_inward_normals),
            column.structural_offset,
            uconvert(u"m", column.base.L),
            deepcopy(column.base.section),
            column.concrete,
            copy(column.tributary_cell_indices),
            copy(column.tributary_cell_areas),
            _flat_plate_above_support(column.column_above),
        )
        for (column_idx, column) in pairs(struc.columns)
    ]
    return StructuralSizer.FlatPlateDesignInput(
        slab_idx,
        topology,
        cells,
        floors,
        supports,
    )
end

function floor_design_request(
    struc::BuildingStructure,
    slab_idx::Int;
    options::StructuralSizer.AbstractFloorOptions,
    column_options = nothing,
    max_iterations::Int = 10,
    fire_rating::Real = 0.0,
)
    slab_idx in eachindex(struc.slabs) || throw(BoundsError(struc.slabs, slab_idx))
    system = StructuralSizer.floor_type(struc.slabs[slab_idx].floor_type)
    input = system isa Union{StructuralSizer.FlatPlate, StructuralSizer.FlatSlab} ?
        _flat_plate_design_input(struc, slab_idx) :
        nothing
    return StructuralSizer.FloorDesignRequest(
        StructuralSizer.FloorSource(slab_idx),
        system,
        options,
        column_options;
        input = input,
        max_iterations = max_iterations,
        fire_rating = fire_rating,
    )
end

"""Indices of columns whose tributary cells overlap the requested floor."""
function _floor_support_indices(struc::BuildingStructure, slab_idx::Int)
    slab_cells = Set(struc.slabs[slab_idx].cell_indices)
    return [
        column_idx for (column_idx, column) in pairs(struc.columns)
        if !isempty(column.tributary_cell_indices) &&
           !isdisjoint(column.tributary_cell_indices, slab_cells)
    ]
end

function _floor_cell_updates(struc::BuildingStructure, slab_idx::Int)
    updates = StructuralSizer.FloorCellLoadUpdate[]
    for cell_idx in struc.slabs[slab_idx].cell_indices
        cell = struc.cells[cell_idx]
        push!(
            updates,
            StructuralSizer.FloorCellLoadUpdate(
                cell_idx,
                deepcopy(cell.self_weight),
                deepcopy(cell.live_load),
            ),
        )
    end
    return updates
end

function _floor_support_updates(struc::BuildingStructure, slab_idx::Int)
    updates = StructuralSizer.FloorSupportUpdate[]
    for column_idx in _floor_support_indices(struc, slab_idx)
        column = struc.columns[column_idx]
        push!(
            updates,
            StructuralSizer.FloorSupportUpdate(
                column_idx,
                deepcopy(column.c1),
                deepcopy(column.c2),
                column.shape,
                deepcopy(column.base.section),
                deepcopy(column.base.volumes),
            ),
        )
    end
    return updates
end

"""
    design_floor(struc, request; ...) -> FloorDesignOutcome

Evaluate one floor against isolated working state.

The input structure is never mutated. Flat-plate requests use the pure Sizer
kernel; transitional systems use an isolated copy. A successful outcome carries
a complete proposal for floor-owned fields, cell loads, and support changes.
Failed outcomes carry diagnostics but no installable proposal.
"""
function design_floor(
    struc::BuildingStructure,
    request::StructuralSizer.FloorDesignRequest;
    verbose::Bool = false,
    workspace::StructuralSizer.FloorDesignWorkspace =
        StructuralSizer.prepare_floor_design_workspace(request),
    tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
)
    slab_idx = request.source.index
    slab_idx in eachindex(struc.slabs) || throw(BoundsError(struc.slabs, slab_idx))
    actual_system = StructuralSizer.floor_type(struc.slabs[slab_idx].floor_type)
    typeof(actual_system) === typeof(request.system) ||
        throw(ArgumentError(
            "floor source $slab_idx resolves to $(typeof(actual_system)), " *
            "but the request declares $(typeof(request.system))",
        ))

    if request.input isa StructuralSizer.FlatPlateDesignInput
        # Same per-slab trace the mutable `size_slab!` kernel emits. The flat-plate
        # kernel designs from an immutable request and does not emit it itself.
        slab_id = string(slab_idx)
        StructuralSizer.emit!(tc, :slab, "size_slab!", slab_id, :enter;
                              floor_type=string(struc.slabs[slab_idx].floor_type),
                              options_type=string(typeof(request.input)))
        outcome = StructuralSizer.design_floor(
            request;
            verbose = verbose,
            workspace = workspace,
            tc = tc,
        )
        StructuralSizer.emit!(tc, :slab, "size_slab!", slab_id, :exit;
                              result_type=string(typeof(outcome)),
                              status=string(outcome.status))
        StructuralSizer.is_installable(outcome) || return outcome

        proposal = outcome.proposal
        support_updates = StructuralSizer.FloorSupportUpdate[
            StructuralSizer.FloorSupportUpdate(
                update.source_index,
                update.c1,
                update.c2,
                update.shape,
                update.section,
                deepcopy(struc.columns[update.source_index].base.volumes),
            )
            for update in proposal.support_updates
        ]
        owner_proposal = StructuralSizer.FloorDesignProposal(
            proposal.result,
            proposal.details,
            proposal.drop_panel,
            proposal.cell_updates,
            support_updates,
        )
        return StructuralSizer.FloorDesignOutcome(
            outcome.status,
            owner_proposal,
            outcome.details,
            outcome.diagnostics,
            outcome.iterations,
        )
    end

    working = deepcopy(struc)
    support_kwargs = NamedTuple()
    if request.system isa StructuralSizer.TwoWay
        support = classify_two_way_supports(working, working.slabs[slab_idx].cell_indices)
        if support.action === :throw
            throw(ArgumentError(support.message))
        elseif support.action === :flat_plate
            throw(ArgumentError(
                "floor $slab_idx is :two_way and has no beams. initialize! designs " *
                "that panel as :flat_plate; this request is still :two_way."))
        end
        support_kwargs = (
            wall_supported = support.wall_supported,
            missing_edge_beam = support.missing_edge_beam,
        )
    end
    outcome = StructuralSizer.size_slab!(
        working,
        request;
        verbose = verbose,
        _col_cache = workspace.column_cache,
        defer_asap_process = true,
        tc = tc,
        support_kwargs...,
    )
    StructuralSizer.is_installable(outcome) || return outcome

    slab_idx = request.source.index
    slab = working.slabs[slab_idx]
    proposal = StructuralSizer.FloorDesignProposal(
        deepcopy(slab.result),
        deepcopy(slab.design_details),
        deepcopy(slab.drop_panel),
        _floor_cell_updates(working, slab_idx),
        _floor_support_updates(working, slab_idx),
    )
    return StructuralSizer.FloorDesignOutcome(
        outcome.status,
        proposal,
        deepcopy(outcome.details),
        copy(outcome.diagnostics),
        outcome.iterations,
    )
end

"""
    design_floors!(struc; options, slab_options=nothing, column_options=nothing, ...) -> Vector{FloorDesignOutcome}

Design all declared floors in stable source order. Each floor is evaluated on
isolated state and installed before the next request, so successful monotonic
support growth is visible to later floors while a failed floor installs nothing.
`slab_options[i]`, when given, replaces `options` for slab `i` (scoped overrides).
"""
function design_floors!(
    struc::BuildingStructure;
    options::StructuralSizer.AbstractFloorOptions,
    slab_options::Union{Nothing, AbstractVector} = nothing,
    column_options = nothing,
    max_iterations::Int = 10,
    fire_rating::Real = 0.0,
    verbose::Bool = false,
    tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
)
    slab_indices = collect(eachindex(struc.slabs))
    workspace = nothing
    outcomes = StructuralSizer.FloorDesignOutcome[]

    StructuralSizer.emit!(
        tc,
        :slab,
        "size_slabs!",
        "",
        :enter;
        n_slabs = length(slab_indices),
        options_type = string(typeof(options)),
        has_column_opts = !isnothing(column_options),
        max_iterations = max_iterations,
    )
    StructuralSizer.emit!(tc, :slab, "size_slabs!", "", :decision; parallel = false)
    slab_options === nothing || length(slab_options) == length(slab_indices) ||
        throw(ArgumentError("slab_options has $(length(slab_options)) entries for $(length(slab_indices)) slabs"))
    warn_vault_openings!(struc)
    for slab_idx in slab_indices
        request = floor_design_request(
            struc,
            slab_idx;
            options = slab_options === nothing ? options : slab_options[slab_idx],
            column_options = column_options,
            max_iterations = max_iterations,
            fire_rating = fire_rating,
        )
        # Only a flat plate or flat slab builds the column cache, so a leading
        # vault or one-way slab must not fix an empty workspace for later slabs.
        if isnothing(workspace) || (isnothing(workspace.column_cache) &&
                                    request.system isa Union{StructuralSizer.FlatPlate, StructuralSizer.FlatSlab})
            workspace = StructuralSizer.prepare_floor_design_workspace(request)
        end
        outcome = design_floor!(
            struc,
            request;
            verbose = verbose,
            workspace = workspace,
            tc = tc,
        )
        _require_installable_floor(outcome, request.source.index)
        push!(outcomes, outcome)
    end
    StructuralSizer.emit!(tc, :slab, "size_slabs!", "", :exit)
    return outcomes
end

"""
    install_floor_design!(struc, request, outcome) -> struc

Install a successful floor proposal in one owner-controlled operation.

All source indices and system identity are validated before the first write.
Rejected or stale outcomes therefore leave the building unchanged.
"""
function install_floor_design!(
    struc::BuildingStructure,
    request::StructuralSizer.FloorDesignRequest,
    outcome::StructuralSizer.FloorDesignOutcome;
    install_supports::Bool = true,
)
    StructuralSizer.is_installable(outcome) ||
        throw(ArgumentError("cannot install floor outcome with status $(outcome.status)"))

    slab_idx = request.source.index
    slab_idx in eachindex(struc.slabs) || throw(BoundsError(struc.slabs, slab_idx))
    slab = struc.slabs[slab_idx]
    actual_system = StructuralSizer.floor_type(slab.floor_type)
    typeof(actual_system) === typeof(request.system) ||
        throw(ArgumentError(
            "stale floor proposal: source $slab_idx is $(typeof(actual_system)), " *
            "not $(typeof(request.system))",
        ))

    proposal = outcome.proposal
    for update in proposal.cell_updates
        update.source_index in eachindex(struc.cells) ||
            throw(BoundsError(struc.cells, update.source_index))
        update.source_index in slab.cell_indices ||
            throw(ArgumentError(
                "cell $(update.source_index) is not owned by floor $slab_idx",
            ))
    end
    support_indices = Set(_floor_support_indices(struc, slab_idx))
    for update in proposal.support_updates
        update.source_index in eachindex(struc.columns) ||
            throw(BoundsError(struc.columns, update.source_index))
        update.source_index in support_indices ||
            throw(ArgumentError(
                "column $(update.source_index) is not a support of floor $slab_idx",
            ))
    end

    slab.result = deepcopy(proposal.result)
    slab.design_details = deepcopy(proposal.details)
    # Column sizes this design was checked at, below the slab and directly
    # above it (the upper column's stiffness enters the slab analysis), so a
    # later column change can be recognized as making the stored checks stale.
    # Written even when empty: a design with no record is treated as stale.
    if slab.design_details isa NamedTuple
        above_size(i) = (a = struc.columns[i].column_above;
                         a === nothing ? nothing : (deepcopy(a.c1), deepcopy(a.c2), a.shape))
        slab.design_details = merge(slab.design_details, (
            designed_supports = Dict(
                u.source_index => (deepcopy(u.c1), deepcopy(u.c2), u.shape)
                for u in proposal.support_updates),
            designed_above = Dict(
                u.source_index => above_size(u.source_index)
                for u in proposal.support_updates),
        ))
    end
    slab.drop_panel = deepcopy(proposal.drop_panel)
    for update in proposal.cell_updates
        cell = struc.cells[update.source_index]
        cell.self_weight = deepcopy(update.self_weight)
        cell.live_load = deepcopy(update.live_load)
    end
    if install_supports
        for update in proposal.support_updates
            column = struc.columns[update.source_index]
            column.c1 = deepcopy(update.c1)
            column.c2 = deepcopy(update.c2)
            column.shape = update.shape
            column.base.section = deepcopy(update.section)
            column.base.volumes = deepcopy(update.volumes)
        end
    end
    return struc
end

"""
    design_floor!(struc, request; kwargs...) -> FloorDesignOutcome

Evaluate on isolated state and install only a successful proposal.
"""
function design_floor!(
    struc::BuildingStructure,
    request::StructuralSizer.FloorDesignRequest;
    kwargs...,
)
    outcome = design_floor(struc, request; kwargs...)
    StructuralSizer.is_installable(outcome) &&
        install_floor_design!(struc, request, outcome)
    return outcome
end

function _require_installable_floor(outcome, slab_idx::Int)
    StructuralSizer.is_installable(outcome) && return outcome
    diagnostics = join((diagnostic.message for diagnostic in outcome.diagnostics), "; ")
    throw(ErrorException(
        "floor $slab_idx design was not installable ($(outcome.status)): $diagnostics",
    ))
end
