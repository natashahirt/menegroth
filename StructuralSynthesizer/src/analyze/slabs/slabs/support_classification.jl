# A :two_way panel is classified from the skeleton before it is sized.
#
# ACI 318-11 §9.5.3.1 (corpus: aci-318-11, page 133) sends a slab with no
# interior beams to §9.5.3.2. §9.5.3.3 (page 134) is the beam-supported
# thickness, and §9.5.3.3(d) adds 10% where a discontinuous edge has no
# beam with αf ≥ 0.8. A wall is a line support. It fills an edge, and a
# panel bounded by walls on every side stays two-way under §9.5.3.3(c).

"""Result of classifying one `:two_way` slab from its boundary edges."""
struct TwoWaySupportClass
    action::Symbol
    wall_supported::Bool
    missing_edge_beam::Bool
    message::String
end

"""Story faces, which are the horizontal panels. Vertical wall faces are left out."""
function _horizontal_story_faces(skel)
    faces = Int[]
    for story in values(skel.stories)
        append!(faces, story.faces)
    end
    return unique!(faces)
end

"""Horizontal faces when the skeleton has no stories yet: coplanar faces at one Z."""
function _coplanar_horizontal_faces(skel)
    geom = skel.geometry
    geom === nothing && return collect(eachindex(skel.face_edge_indices))
    vc = geom.vertex_coords
    faces = Int[]
    for (i, vis) in enumerate(skel.face_vertex_indices)
        isempty(vis) && continue
        z0 = vc[first(vis), 3]
        all(v -> abs(vc[v, 3] - z0) <= 1e-4, vis) && push!(faces, i)
    end
    return faces
end

"""Plan line of one edge, in metres, with the endpoints ordered."""
function _edge_plan_key(skel, edge::Int)
    i, j = skel.edge_indices[edge]
    vc = skel.geometry.vertex_coords
    a = (round(vc[i, 1]; digits=4), round(vc[i, 2]; digits=4))
    b = (round(vc[j, 1]; digits=4), round(vc[j, 2]; digits=4))
    return a <= b ? (a, b) : (b, a)
end

"""
Plan lines of `:walls` edges. A pier is drawn on the story below the slab it
holds, so it is a different edge from the slab boundary and matches in plan.
"""
function _wall_plan_keys(skel)
    keys = Set{Tuple{NTuple{2, Float64}, NTuple{2, Float64}}}()
    skel.geometry === nothing && return keys
    for edge in get(skel.groups_edges, :walls, Int[])
        push!(keys, _edge_plan_key(skel, edge))
    end
    return keys
end

"""How many horizontal panels share each edge. Two or more means an interior edge."""
function _horizontal_edge_counts(skel)
    faces = isempty(skel.stories) ? _coplanar_horizontal_faces(skel) : _horizontal_story_faces(skel)
    counts = Dict{Int, Int}()
    for face in faces
        face in eachindex(skel.face_edge_indices) || continue
        for edge in skel.face_edge_indices[face]
            counts[edge] = get(counts, edge, 0) + 1
        end
    end
    return counts
end

"""
    classify_two_way_supports(struc, cell_indices) -> TwoWaySupportClass

Classify one slab from the `:beams` and `:walls` edges on its cells.

- No beam edge, and not every edge a wall: `:flat_plate`. Columns, or
  columns and walls, are the flat-plate supports. A core is this case.
- Every edge a wall: `:keep`, `wall_supported`. Corner columns do not
  change it. The slab spans wall to wall.
- Beams exist and an interior edge has neither a beam nor a wall: `:throw`.
- Beams exist and a building-edge beam is missing: `:keep`,
  `missing_edge_beam`. A wall fills that edge.
"""
function classify_two_way_supports(struc::BuildingStructure, cell_indices)
    skel = struc.skeleton
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    walls = Set(get(skel.groups_edges, :walls, Int[]))
    wall_plans = _wall_plan_keys(skel)
    counts = _horizontal_edge_counts(skel)
    edges = Int[]
    faces = Int[]
    for cell_idx in cell_indices
        face = struc.cells[cell_idx].face_idx
        push!(faces, face)
        append!(edges, skel.face_edge_indices[face])
    end
    unique!(sort!(edges))
    unique!(sort!(faces))
    supported_by_wall(edge) = edge in walls ||
        (skel.geometry !== nothing && _edge_plan_key(skel, edge) in wall_plans)
    n_beams = count(e -> e in beams, edges)
    all_walls = !isempty(edges) && all(supported_by_wall, edges)
    interior_gaps = Int[]
    exterior_open = Int[]
    for edge in edges
        supported = edge in beams || supported_by_wall(edge)
        interior = get(counts, edge, 1) >= 2
        if !supported && interior
            push!(interior_gaps, edge)
        elseif !supported
            push!(exterior_open, edge)
        end
    end
    if n_beams == 0
        if all_walls
            return TwoWaySupportClass(:keep, true, false, "")
        end
        return TwoWaySupportClass(:flat_plate, false, false, "")
    end
    if !isempty(interior_gaps)
        return TwoWaySupportClass(:throw, false, false,
            "floor_type :two_way has a beam on some edges of face(s) $(faces), " *
            "but interior edge(s) $(interior_gaps) have neither a beam nor a wall. " *
            "An interior edge between panels needs a beam or a wall. A missing " *
            "beam on the building edge is allowed and thickens the slab 10% " *
            "(ACI 318-11 §9.5.3.3(d)).")
    end
    return TwoWaySupportClass(:keep, false, !isempty(exterior_open), "")
end

"""Flat-plate options carrying the concrete and bars of the options being replaced."""
function _flat_plate_options_from(opts::StructuralSizer.FlatPlateOptions)
    return opts
end

function _flat_plate_options_from(opts::StructuralSizer.FlatSlabOptions)
    return opts.base
end

function _flat_plate_options_from(opts::StructuralSizer.TwoWayOptions)
    return StructuralSizer.FlatPlateOptions(
        material = opts.material, cover = opts.cover, bar_size = opts.bar_size)
end

function _flat_plate_options_from(opts::StructuralSizer.OneWayOptions)
    return StructuralSizer.FlatPlateOptions(
        material = opts.material, cover = opts.cover, bar_size = opts.bar_size)
end

_flat_plate_options_from(::StructuralSizer.AbstractFloorOptions) = StructuralSizer.FlatPlateOptions()

"""Face indices of one slab spec, for the conversion warning."""
function _spec_face_indices(struc, spec)
    return [struc.cells[i].face_idx for i in spec.cell_indices]
end

"""
    _apply_two_way_supports!(struc, slab_specs, floor_opts) -> slab_specs

Rewrite `:two_way` specs before sizing. A beamless panel becomes
`:flat_plate` and keeps the caller's concrete on flat-plate options.
A broken interior line throws. Specs that share a group id must classify
the same way, because one group is sized once.
"""
function _apply_two_way_supports!(struc::BuildingStructure, slab_specs, floor_opts;
                                   joists_planned::Bool = false)
    classes = Vector{Union{Nothing, TwoWaySupportClass}}(undef, length(slab_specs))
    for (i, spec) in enumerate(slab_specs)
        classes[i] = spec.floor_type === :two_way ?
            classify_two_way_supports(struc, spec.cell_indices) : nothing
    end
    for class in classes
        class === nothing && continue
        class.action === :throw && throw(ArgumentError(class.message))
    end

    by_group = Dict{UInt64, Vector{Int}}()
    for (i, spec) in enumerate(slab_specs)
        push!(get!(by_group, spec.group_id, Int[]), i)
    end
    for (gid, idxs) in by_group
        kinds = map(idxs) do i
            class = classes[i]
            class === nothing ? slab_specs[i].floor_type :
                (class.action, class.wall_supported, class.missing_edge_beam)
        end
        length(unique(kinds)) == 1 && continue
        throw(ArgumentError(
            "slab group $gid mixes support classifications $(unique(kinds)). " *
            "Split the group so each design sees one support condition."))
    end

    converted = Int[]
    walled = Int[]
    open_edge = Int[]
    for i in eachindex(slab_specs)
        class = classes[i]
        class === nothing && continue
        spec = slab_specs[i]
        faces = _spec_face_indices(struc, spec)
        if class.action === :flat_plate && joists_planned
            # The ribs are the framing. They are materialized after this
            # classification, so a beamless panel is not a flat plate.
            slab_specs[i] = merge(spec, (;
                wall_supported = false,
                missing_edge_beam = false))
        elseif class.action === :flat_plate
            source = spec.floor_opts_override === nothing ? floor_opts : spec.floor_opts_override
            slab_specs[i] = merge(spec, (;
                floor_type = :flat_plate,
                floor_opts_override = _flat_plate_options_from(source),
                wall_supported = false,
                missing_edge_beam = false,
                reclassified = true))
            append!(converted, faces)
        else
            slab_specs[i] = merge(spec, (;
                wall_supported = class.wall_supported,
                missing_edge_beam = class.missing_edge_beam))
            class.wall_supported && append!(walled, faces)
            class.missing_edge_beam && append!(open_edge, faces)
        end
    end
    if !isempty(converted)
        @warn "floor_type :two_way has no beams on face(s) $(sort!(unique!(converted))); designing those panels as :flat_plate (ACI 318-11 §9.5.3.1). A core wall is a line support on that flat plate, not a beam."
    end
    if !isempty(walled)
        @info "face(s) $(sort!(unique!(walled))) are supported on walls on every side; the two-way thickness is ACI 318-11 §9.5.3.3(c)"
    end
    if !isempty(open_edge)
        @info "face(s) $(sort!(unique!(open_edge))) are missing a building-edge beam; the two-way thickness includes the 10% of ACI 318-11 §9.5.3.3(d)"
    end
    # Flat plate designs one slab per story (`grouping = :by_floor`). Leaving
    # the converted panels as one slab per bay makes every frame one span, so
    # the direct design method refuses a floor that does have three spans.
    return _merge_reclassified_flat_plates(struc, slab_specs)
end

"""Story index of a spec, or `-1` when its face is not on a story."""
function _spec_story(struc, spec)
    face = struc.cells[first(spec.cell_indices)].face_idx
    for (story_idx, story) in struc.skeleton.stories
        face in story.faces && return story_idx
    end
    return -1
end

"""
    _merge_reclassified_flat_plates(struc, slab_specs) -> slab_specs

Combine panels that were redesigned as flat plates into one slab per story.
Panels that were requested as a flat plate are already grouped and are left
as they are. A story whose panels carry different options stays unmerged.
"""
function _merge_reclassified_flat_plates(struc, slab_specs)
    stories = Dict{Int, Vector{Int}}()
    passthrough = Int[]
    for (i, spec) in enumerate(slab_specs)
        if !(hasproperty(spec, :reclassified) && spec.reclassified)
            push!(passthrough, i)
            continue
        end
        push!(get!(stories, _spec_story(struc, spec), Int[]), i)
    end
    out = NamedTuple[]
    for i in passthrough
        push!(out, slab_specs[i])
    end
    for (story, idxs) in sort!(collect(stories); by=first)
        specs = slab_specs[idxs]
        length(specs) == 1 && (push!(out, specs[1]); continue)
        # `unique(f, itr)` keeps elements of `itr`, not `f`'s values. Collect
        # the fields, or the merged spec stores a panel where options belong.
        opts = unique(s.floor_opts_override for s in specs)
        mats = unique(s.material_override for s in specs)
        if length(opts) != 1 || length(mats) != 1
            append!(out, specs)
            continue
        end
        cells = vcat((copy(s.cell_indices) for s in specs)...)
        push!(out, (;
            cell_indices = cells,
            spans_gov = StructuralSizer.governing_spans([s.spans_gov for s in specs]),
            sdl_gov = maximum(s.sdl_gov for s in specs),
            live_gov = maximum(s.live_gov for s in specs),
            floor_type = :flat_plate,
            floor_opts_override = only(opts),
            material_override = only(mats),
            group_id = UInt64(hash((:reclassified_flat_plate, story))),
            wall_supported = false,
            missing_edge_beam = false,
            reclassified = true,
        ))
    end
    return out
end
