# Added longitudinal bars at the ends of a special pier.
#
# The web ratio already placed stays. Bars are added only over a zone: the
# boundary-element length when one is required, and 0.15ℓw where §18.10.2.4
# applies (continuous, one critical section, hw/ℓw ≥ 2). The area is the
# larger of that minimum and the area the strength combinations still need.
# On a flange, that area is sized on the flanged section, with the return's
# vertical bars in the flange zone. The added group is still the same at
# each end.

"""End bars placed at one pier, the same group at each end."""
struct BoundaryEndReinforcement
    zone_m::Float64
    bar::Int
    tie::Int
    layers::Int
    per_layer::Int
    spacing_m::Float64
    "Added area at one end [m²]."
    area_m2::Float64
    "Centroid of that area, measured from the wall end [m]."
    inset_m::Float64
    "True when §18.10.2.4 set a minimum."
    from_ratio::Bool
    "§18.10.2.4(b) extension past the critical section [m], or `nothing`."
    extension_m::Union{Nothing, Float64}
end

"""
    design_boundary_end_bars(struc, indices, grown_by_wall, lw_by_wall, material;
                            placed=...) -> Dict{Int, BoundaryEndReinforcement}

One entry per pier in `indices` that gets added bars. `placed` is the
previous pass, and its area is in the neutral-axis depth this pass reads.
A pier with no zone keeps no entry.
"""
function design_boundary_end_bars(struc, indices, grown_by_wall, lw_by_wall, material;
                                 placed::Dict{Int, BoundaryEndReinforcement}=Dict{Int, BoundaryEndReinforcement}(),
                                 elf=nothing, plan_axis::NTuple{2, Float64}=(1.0, 0.0))
    out = Dict{Int, BoundaryEndReinforcement}()
    for idx in indices
        found = _pier_end_reinforcement(struc, idx, grown_by_wall[idx], lw_by_wall[idx],
                                        material, get(placed, idx, nothing), elf, plan_axis)
        found === nothing || (out[idx] = found)
    end
    return out
end

"True when the two layouts are the same bars."
function _same_end_bars(a::Dict{Int, BoundaryEndReinforcement},
                       b::Dict{Int, BoundaryEndReinforcement})
    keys(a) == keys(b) || return false
    for (i, bar) in a
        other = b[i]
        (bar.bar == other.bar && bar.layers == other.layers &&
            bar.per_layer == other.per_layer &&
            abs(bar.area_m2 - other.area_m2) <= 1e-8) || return false
    end
    return true
end

function _pier_end_reinforcement(struc, idx, actions, lw, material, previous, elf, plan_axis)
    wall = struc.walls[idx]
    assembly = _assembly_of(struc.wall_mesh, idx)
    direction = _pier_axis_direction(wall, plan_axis)
    decision = special_boundary_decision(
        wall, struc.walls, idx, assembly, actions, material;
        elf = direction in (:X, :Y) ? elf : nothing,
        pier_direction = direction in (:X, :Y) ? direction : nothing,
        end_area = previous === nothing ? nothing : previous.area_m2,
        end_inset = previous === nothing ? nothing : previous.inset_m)
    code_min = decision.continuous && decision.single_critical_section &&
        decision.hw_m / ustrip(u"m", lw) >= 2.0
    boundary_length = nothing
    if decision.required === true
        decision.zone_length_m === nothing && throw(ArgumentError(
            "end bars: wall $idx requires a boundary element and its length is not known."))
        boundary_length = decision.zone_length_m * u"m"
    end
    zone = special_end_zone(lw; boundary_length, code_minimum = code_min)
    zone.zone === nothing && return nothing
    fc = material.concrete.fc′
    fy = material.rebar.Fy
    floor = code_min ? ustrip(u"m^2", special_end_minimum_area(fc, fy, lw, wall.thickness).area) : 0.0
    pairs = Tuple{Float64, Float64}[(a.N, a.M) for a in actions]
    inset_guess = ustrip(u"m", zone.zone) / 2
    fc_Pa = ustrip(u"Pa", fc)
    fy_Pa = ustrip(u"Pa", fy)
    Es = ustrip(u"Pa", material.rebar.E)
    lw_m = ustrip(u"m", lw)
    t_m = ustrip(u"m", wall.thickness)
    Ast = wall.ρl * lw_m * t_m
    flange = _boundary_flange(wall, struc.walls, idx, assembly, _stacked_wall_height(wall))
    pos = flange === nothing ? nothing : flange.positive
    neg = flange === nothing ? nothing : flange.negative
    one = (pos === nothing) ⊻ (neg === nothing)
    only = pos !== nothing ? pos : neg
    needed = boundary_end_area_si(fc_Pa, fy_Pa, Es, lw_m, t_m, Ast, inset_guess, pairs, floor;
                                 flange_at = one ? (pos !== nothing ? :positive : :negative) : nothing,
                                 tf = one ? ustrip(u"m", only.tf) : 0.0,
                                 bf = one ? ustrip(u"m", only.bf) : 0.0,
                                 As_flange = one ? only.As_m2 : 0.0,
                                 tf_pos = pos === nothing ? 0.0 : ustrip(u"m", pos.tf),
                                 bf_pos = pos === nothing ? 0.0 : ustrip(u"m", pos.bf),
                                 As_pos = pos === nothing ? 0.0 : pos.As_m2,
                                 tf_neg = neg === nothing ? 0.0 : ustrip(u"m", neg.tf),
                                 bf_neg = neg === nothing ? 0.0 : ustrip(u"m", neg.bf),
                                 As_neg = neg === nothing ? 0.0 : neg.As_m2)
    (needed === nothing || needed <= 0) && return nothing
    layout = _layout_that_passes(fc_Pa, fy_Pa, Es, lw_m, t_m, Ast, pairs,
                                needed, zone.zone, wall.thickness; flange)
    layout === nothing && return nothing
    extension = nothing
    if code_min
        reach = lw
        for a in actions
            a.combination in _BOUNDARY_EARTHQUAKE || continue
            abs(a.V) > 1.0 || continue
            found = special_end_bar_extension(lw, abs(a.M) * u"N*m", abs(a.V) * u"N")
            reach = max(reach, found.extension)
        end
        extension = ustrip(u"m", reach)
    end
    return BoundaryEndReinforcement(
        ustrip(u"m", zone.zone), layout.bar, layout.tie, layout.layers, layout.per_layer,
        ustrip(u"m", layout.spacing), ustrip(u"m^2", layout.area), ustrip(u"m", layout.inset),
        code_min, extension)
end

"""
Layout of at least `needed`, enlarged until the placed bars pass.

hx can place more steel than `needed`. The check uses the placed area and
its centroid. On a flange, the return's bars are in that check. Four
enlargements cover a step up in bar size. `nothing` when No. 11 at hx still
fails.
"""
function _layout_that_passes(fc, fy, Es, lw, t, Ast, pairs, needed, zone, thickness;
                            flange=nothing)
    target = needed * u"m^2"
    for _ in 1:4
        layout = boundary_end_bar_layout(target, zone, thickness)
        As = ustrip(u"m^2", layout.area)
        inset = ustrip(u"m", layout.inset)
        ok = true
        ρ = (Ast + 2 * As) / (lw * t)
        ax = wall_pure_axial_capacity_si(fc, fy, lw, t, ρ)
        for (Nu, Mu) in pairs
            if Nu > 0.65 * ax.Pn_max
                ok = false
                break
            end
            cap = if flange === nothing
                wall_end_bar_capacity_si(fc, fy, Es, lw, t, Ast, As, inset, Nu)
            else
                _flange_capacity_si(fc, fy, Es, lw, t, Ast, Nu, flange, Mu;
                                   As_end = As, inset = inset)
            end
            if !cap.converged || abs(Mu) > cap.φMn + 1.0
                ok = false
                break
            end
        end
        ok && return layout
        target = 1.25 * layout.area
    end
    return nothing
end
