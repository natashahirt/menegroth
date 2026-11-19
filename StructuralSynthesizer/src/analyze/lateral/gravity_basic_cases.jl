# =============================================================================
# Unfactored gravity basic cases
# =============================================================================
# Dead, floor live, and one roof companion are separate load vectors. They
# share one stiffness factorization, including the rigid-diaphragm reduction
# when the building has one. Combination factors are not applied here.

"""
Unfactored gravity cases and the displacement of each.

`symbols` is `[:D, :L, roof]`. `roof` is the one companion the caller named,
`:Lr`, `:S`, or `:R`. `loads[i]` is unfactored. `u[i]` is the full
displacement vector for that case, slaves included. The three vectors come
from one factorization.
"""
struct GravityBasicCases
    symbols::Vector{Symbol}
    loads::Vector{Vector{Asap.AbstractLoad}}
    u::Vector{Vector{Float64}}
end

"""
    solve_gravity_basic_cases(struc; roof=:Lr, params=DesignParameters()) -> GravityBasicCases

Solve unfactored dead, floor live, and one roof companion on the current
stiffness.

Dead is cell superimposed dead plus cell self-weight, wall self-weight
(`ρ t g` on the wall triangles), and any member `GravityLoad` already on the
model, copied at `g` so they are unfactored `ρ A g`, plus unfactored
fire-protection coating and drop-panel weight. Floor live is `:L`. Live
on a `:roof` face is the companion named by `roof`, and it is not also put
in `:L`. Grade and unknown faces have no tributary cache and are omitted,
the same cells the factored path skips.

`roof` is one of `:Lr`, `:S`, or `:R`. [`GravityLoads`](@ref) stores a single
roof pressure, `roof_LL`, so only one companion exists. Snow and rain are
that pressure only when the caller says so.

The solve is [`Asap.solve`](@ref) on the rigid-link reduced system when the
building has diaphragm links, and on the unreduced stiffness otherwise. It
does not replace `model.u` or the factored loads used for member sizing.
"""
function solve_gravity_basic_cases(struc::BuildingStructure;
                                   roof::Symbol=:Lr,
                                   params::DesignParameters=DesignParameters())
    roof in (:Lr, :S, :R) || throw(ArgumentError(
        "gravity basic cases: the roof companion must be one of :Lr, :S, :R " *
        "(got :$roof). Pass the one load the roof pressure is."))
    model = struc.asap_model
    isnothing(model) && throw(ArgumentError(
        "gravity basic cases: the building has no Asap model. Run to_asap! first."))
    model.processed || Asap.process!(model)

    dead = Asap.AbstractLoad[]
    live = Asap.AbstractLoad[]
    roof_loads = Asap.AbstractLoad[]
    roof_faces = Set(get(struc.skeleton.groups_faces, :roof, Int[]))
    combo = LoadCombination(name=:unfactored, D=1.0, L=1.0)
    elements = model.frame_elements
    edge_strips = slab_edge_strips_by_cell(struc)
    fp = flat_plate_shell_layout(struc)
    for (cell_idx, cell) in enumerate(struc.cells)
        if fp !== nothing && haskey(fp.cell_shells, cell_idx)
            # The panel's own shells carry it; its edge strip stays on the frame slot.
            q_dead = cell.sdl + cell.self_weight
            cell_dead, cell_live = _flat_plate_unfactored_cell_loads(
                fp, cell_idx, q_dead, cell.live_load)
            cell_dead, cell_live = Asap.AbstractLoad[cell_dead], Asap.AbstractLoad[cell_live]
            strips = get(edge_strips, cell_idx, NamedTuple[])
            _append_edge_strip_loads!(cell_dead, Asap.TributaryLoad[], elements, strips,
                                      uconvert(u"Pa", q_dead))
            _append_edge_strip_loads!(cell_live, Asap.TributaryLoad[], elements, strips,
                                      uconvert(u"Pa", cell.live_load))
            append!(dead, cell_dead)
            append!(cell.face_idx in roof_faces ? roof_loads : live, cell_live)
            continue
        end
        # Grade and unknown faces are not given a tributary cache. The factored
        # path in to_asap! skips them the same way.
        (cell.floor_type == :grade || cell.floor_type == :unknown) && continue
        isnothing(cell_edge_tributaries(struc, cell_idx)) && throw(ArgumentError(
            "gravity basic cases: cell $cell_idx has no tributary cache. " *
            "compute_cell_tributaries! first."))
        bucket = Asap.AbstractLoad[]
        cell_dead, cell_live = _create_cell_tributary_loads!(
            bucket, elements, struc.skeleton, struc, cell, cell_idx, params;
            split_dead_live=true, combo=combo, edge_strips=edge_strips)
        append!(dead, cell_dead)
        if cell.face_idx in roof_faces
            append!(roof_loads, cell_live)
        else
            append!(live, cell_live)
        end
    end
    wall_shells = [sh for sh in model.shell_elements if sh isa Asap.ShellTri3 && sh.id === :wall]
    append!(dead, wall_self_weight_loads(wall_shells))
    for ld in model.loads
        ld isa Asap.GravityLoad && push!(dead, unfactored_gravity_load(ld))
    end
    append!(dead, unfactored_fire_coating_loads(model))
    append!(dead, unfactored_drop_panel_loads(struc))

    symbols = Symbol[:D, :L, roof]
    cases = Vector{Asap.AbstractLoad}[dead, live, roof_loads]
    u = Asap.solve(model, cases, lateral_solve_links(struc))
    return GravityBasicCases(symbols, cases, u)
end
