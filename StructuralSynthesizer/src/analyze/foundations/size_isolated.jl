"""Size each foundation in `struc.foundations` as-is (no strategy / grouping logic)."""
function _size_foundation!(
    struc::BuildingStructure;
    soil::StructuralSizer.Soil,
    opts::StructuralSizer.FoundationOptions = StructuralSizer.FoundationOptions(),
    demands::Union{Nothing, Vector{StructuralSizer.FoundationDemand}} = nothing,
    tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
    concrete::StructuralSizer.Concrete = StructuralSizer.NWC_4000,
    rebar::StructuralSizer.Metal = StructuralSizer.Rebar_60,
    pier_width = 0.3u"m",
    kwargs...
)
    isempty(struc.foundations) && throw(ArgumentError(
        "No foundations. Call initialize_foundations!() first."))

    demands = isnothing(demands) ? support_demands(struc) : demands
    n_fnd = length(struc.foundations)

    StructuralSizer.emit!(tc, :workflow, "_size_foundation!", "", :enter;
                          n_foundations=n_fnd,
                          code=string(opts.code))

    # ── Per-foundation sizing closure ────────────────────────────────────
    _size_one_fnd!(f_idx) = begin
        fnd = struc.foundations[f_idx]
        n_supp = length(fnd.support_indices)

        if opts.code == :aci
            _size_fnd_aci!(struc, f_idx, fnd, n_supp, demands, soil, opts; tc=tc)
        else
            _size_fnd_is!(struc, f_idx, fnd, n_supp, demands, soil,
                          concrete, rebar, pier_width; tc=tc, kwargs...)
        end
    end

    # ── Dispatch (threaded or serial) ────────────────────────────────────
    if Threads.nthreads() > 1
        Threads.@threads for f_idx in 1:n_fnd
            _size_one_fnd!(f_idx)
        end
    else
        for f_idx in 1:n_fnd
            _size_one_fnd!(f_idx)
        end
    end

    total_concrete = sum(StructuralSizer.concrete_volume(f.result) for f in struc.foundations)
    total_steel    = sum(StructuralSizer.steel_volume(f.result)    for f in struc.foundations)
    @info "Sized $(length(struc.foundations)) foundations ($(opts.code))" total_concrete total_steel

    StructuralSizer.emit!(tc, :workflow, "_size_foundation!", "", :exit;
                          total_concrete_m3=Float64(ustrip(u"m^3", total_concrete)),
                          total_steel_m3=Float64(ustrip(u"m^3", total_steel)))

    return struc
end

# ─────────────────────────────────────────────────────────────────────────────
# ACI 318-11 dispatch
# ─────────────────────────────────────────────────────────────────────────────

"""
Gross concrete inertia of the columns on this mat and of the concrete beams
that frame into those supports.

ACI 336.2R Eq. (5-2) (corpus: aci-336-combined-footings-mats, PDF page 8).
`I_B` is about the axis of the strip checked on width `B` (spans in x,
`c1` taken along x). `I_L` is the other axis. A steel beam is left out:
the equation uses one modulus, the footing's `E'`. A T-beam contributes
its stem only. The slab width that belongs in `Ib` was not readable.
"""
function _mat_framed_inertia(struc, supp_indices)
    I_B = 0.0u"m^4"
    I_L = 0.0u"m^4"
    verts = Set{Int}()
    for i in supp_indices
        s = struc.supports[i]
        push!(verts, s.vertex_idx)
        c1, c2 = s.c1, s.c2
        (isnothing(c1) || isnothing(c2) || c1 <= 0u"m" || c2 <= 0u"m") && continue
        if s.shape == :circular
            I = π * c1^4 / 64
            I_B += I
            I_L += I
        else
            I_B += c2 * c1^3 / 12
            I_L += c1 * c2^3 / 12
        end
    end
    skel = struc.skeleton
    for beam in struc.beams
        sec = section(beam)
        I = if sec isa StructuralSizer.RCBeamSection
            sec.b * sec.h^3 / 12
        elseif sec isa StructuralSizer.RCTBeamSection
            sec.bw * sec.h^3 / 12
        else
            nothing
        end
        I === nothing && continue
        isempty(beam.base.segment_indices) && continue
        edge = struc.segments[beam.base.segment_indices[1]].edge_idx
        (edge < 1 || edge > length(skel.edge_indices)) && continue
        v1, v2 = skel.edge_indices[edge]
        (v1 in verts || v2 in verts) || continue
        p1 = Meshes.coords(skel.vertices[v1])
        p2 = Meshes.coords(skel.vertices[v2])
        dx = abs(Float64(ustrip(u"m", p2.x - p1.x)))
        dy = abs(Float64(ustrip(u"m", p2.y - p1.y)))
        if dx >= dy
            I_B += I
        else
            I_L += I
        end
    end
    return (I_B = I_B, I_L = I_L)
end

"""Dispatch a single foundation through the ACI 318 sizing path (spread, strip, or mat)."""
function _size_fnd_aci!(struc, f_idx, fnd, n_supp, demands, soil, opts;
                        tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing)
    mat = opts.spread_params.material   # ReinforcedConcreteMaterial (concrete + rebar)

    # Keep this lightweight: this function is called once per foundation.
    # Use :decision (not :enter/:exit) to avoid bloating tier=:failures traces.
    StructuralSizer.emit!(tc, :workflow, "_size_fnd_aci!", "foundation_$f_idx", :decision;
                          foundation_type=string(fnd.foundation_type),
                          n_supports=n_supp)

    # ACI 318-11 §15.8.1.2 — tensile force across the interface is not a
    # compression footing demand (corpus: aci-318-11, page 275).
    if _all_uplift(demands, fnd.support_indices)
        StructuralSizer.emit!(tc, :workflow, "_size_fnd_aci!", "foundation_$f_idx", :decision;
                              skipped_uplift=true)
        @warn "Foundation $f_idx in factored uplift — skipping compression footing (ACI 318-11 §15.8.1.2)"
        return
    end

    if fnd.foundation_type == :mat
        _mixed_sign_Pu(demands, fnd.support_indices) && error(
            "Foundation $f_idx mixed-sign Pu on a mat cannot design tensile " *
            "interface steel; form a strip or refuse (ACI 318-11 §15.8.1.2(b), " *
            "corpus: aci-318-11, page 275).")
        # Mat foundation — all supports in one slab
        mat_demands = [_lateral_column_demand(struc, demands[i]) for i in fnd.support_indices]
        column_service, column_strength = _aligned_column_actions(
            struc, fnd.support_indices)
        positions = _support_positions_xy(struc, fnd.support_indices)
        framed = _mat_framed_inertia(struc, fnd.support_indices)
        loads = StructuralSizer.footing_loads(; demands=mat_demands, positions=positions,
            column_service=column_service, column_strength=column_strength)
        result = StructuralSizer.design_footing(StructuralSizer.MatFoundation(), loads, soil;
            opts=opts.mat_params, tc=tc, framed_I_B=framed.I_B, framed_I_L=framed.I_L)
        _assign_foundation!(struc, f_idx, fnd, result, :mat, mat)

    elseif fnd.foundation_type == :spread && n_supp == 1
        demand = demands[fnd.support_indices[1]]
        actions = foundation_actions_at(struc, demand.group_idx)
        cs = actions === nothing ? Vector{StructuralSizer.FootingAction}[] : [actions.service]
        cu = actions === nothing ? Vector{StructuralSizer.FootingAction}[] : [actions.strength]
        positions = _support_positions_xy(struc, [fnd.support_indices[1]])
        loads = StructuralSizer.footing_loads(; demands=[demand], positions=positions,
            column_service=cs, column_strength=cu)
        result = StructuralSizer.design_footing(StructuralSizer.SpreadFooting(), loads, soil;
            opts=opts.spread_params, tc=tc)
        _assign_foundation!(struc, f_idx, fnd, result, :spread, mat)

    elseif fnd.foundation_type in (:combined, :strip) || n_supp > 1
        # ACI 318-11 §15.8.1.2(b) (corpus: aci-318-11, page 275): a mixed-sign
        # couple must be a strip so tensile interface steel is designed, not
        # omitted by an isolated spread.
        # Gravity demands keep the centroid on the D+L resultant. The
        # action lists are the other combinations, each with its own forces.
        strip_demands = [demands[i] for i in fnd.support_indices]
        column_service, column_strength = _aligned_column_actions(
            struc, fnd.support_indices)
        axes = _support_strip_axes(struc, fnd.support_indices)
        results = map(axes) do axis
            positions = _support_positions_along_axis(struc, fnd.support_indices, axis)
            loads = StructuralSizer.footing_loads(; demands=strip_demands, positions=positions,
                column_service=column_service, column_strength=column_strength)
            StructuralSizer.design_footing(StructuralSizer.StripFooting(), loads, soil;
                opts=opts.strip_params, tc=tc, strip_axis=axis)
        end
        result = _governing_strip_result(results)
        if _mixed_sign_Pu(demands, fnd.support_indices)
            (result isa StructuralSizer.StripFootingResult &&
             ustrip(u"m^2", result.As_tensile) > 0) || error(
                "Foundation $f_idx mixed-sign strip omitted As_tensile " *
                "(ACI 318-11 §15.8.1.2(b), corpus: aci-318-11, page 275).")
        end
        _assign_foundation!(struc, f_idx, fnd, result, :strip, mat)
    else
        @warn "Foundation type $(fnd.foundation_type) not wired for ACI, skipping"
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# IS 456 legacy dispatch
# ─────────────────────────────────────────────────────────────────────────────

"""Dispatch a single foundation through the IS 456 legacy sizing path."""
function _size_fnd_is!(struc, f_idx, fnd, n_supp, demands, soil,
                       concrete, rebar, pier_width; tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing, kwargs...)
    if _all_uplift(demands, fnd.support_indices)
        @warn "Foundation $f_idx in factored uplift — skipping compression footing (ACI 318-11 §15.8.1.2)"
        return
    end

    if fnd.foundation_type == :spread && n_supp == 1
        demand = demands[fnd.support_indices[1]]
        result = StructuralSizer.design_footing(StructuralSizer.SpreadFooting(), 
            demand, soil, concrete, rebar; pier_width=pier_width, kwargs...)
        volumes = _compute_foundation_volumes(result, concrete, rebar)
        struc.foundations[f_idx] = Foundation(
            fnd.support_indices, result;
            foundation_type=:spread, group_id=fnd.group_id, volumes=volumes)

    elseif fnd.foundation_type == :combined || n_supp > 1
        total_Pu = sum(demands[i].Pu for i in fnd.support_indices)
        total_Ps = sum(demands[i].Ps for i in fnd.support_indices)
        # Propagate envelope Mux/Muy — dropping them understated eccentric
        # bearing (ACI 336.2R §3.2.1 / §4.1).
        gov_Mux = maximum(abs(demands[i].Mux) for i in fnd.support_indices)
        gov_Muy = maximum(abs(demands[i].Muy) for i in fnd.support_indices)
        combined_demand = StructuralSizer.FoundationDemand(f_idx;
            Pu=total_Pu, Ps=total_Ps, Mux=gov_Mux, Muy=gov_Muy)
        result = StructuralSizer.design_footing(StructuralSizer.SpreadFooting(), 
            combined_demand, soil, concrete, rebar; pier_width=pier_width, kwargs...)
        volumes = _compute_foundation_volumes(result, concrete, rebar)
        struc.foundations[f_idx] = Foundation(
            fnd.support_indices, result;
            foundation_type=:combined, group_id=fnd.group_id, volumes=volumes)
        @warn "Combined footing designed as equivalent spread footing (IS simplified)"
    else
        @warn "Foundation type $(fnd.foundation_type) not implemented (IS), skipping"
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

"""Assign a sized foundation result back into struc, computing material volumes."""
function _assign_foundation!(struc, f_idx, fnd, result, ftype::Symbol, mat)
    concrete_mat = mat.concrete
    rebar_mat    = mat.rebar
    volumes = _compute_foundation_volumes(result, concrete_mat, rebar_mat)
    struc.foundations[f_idx] = Foundation(
        fnd.support_indices, result;
        foundation_type=ftype, group_id=fnd.group_id, volumes=volumes,
        wall_indices=fnd.wall_indices)
end

"""Compute material volumes for a foundation from its result."""
function _compute_foundation_volumes(result::R, concrete, rebar) where R<:AbstractFoundationResult
    MaterialVolumes(
        concrete => StructuralSizer.concrete_volume(result),
        rebar => StructuralSizer.steel_volume(result)
    )
end

