# =============================================================================
# Beam demands from the story shell
# =============================================================================
#
# Each part is designed for the forces it carries in the shell. That is the
# lower-bound basis of designing from an elastic analysis (ACI 318-11 §8.3.1,
# corpus: aci-318-11, page 112; §13.5.1, page 248): the shell is in
# equilibrium, so a floor whose every part resists its own share is safe.
#   • The beam takes its frame forces. Asap reports them at the shell node,
#     through the rigid offset, so a hung concrete web's moment already holds
#     its axial force times the offset. The slab compression that balances
#     that force is the flange the beam design uses.
#   • The slab keeps its own bending; its bars are sized from it.
# The flange width therefore belongs to the beam's capacity, not this demand.
#
# The demand is enveloped over the same factored, patterned cases as the
# slab bars. Beam sizing takes the larger of this and the tributary demand.
# A composite steel beam also keeps one moment field per case: its anchors
# are designed on each case's own zero-moment points.

"""
    ShellMomentField

Frame moment along one beam in one load combination of the story shell,
sagging positive, in N·m. Called with the station as a fraction of the beam,
from the same end as [`beam_signed_moment_field`](@ref). `breakpoints` are the
piece boundaries, where the slope of the moment changes.
"""
struct ShellMomentField
    starts::Vector{Float64}
    lengths::Vector{Float64}
    total::Float64
    flip::Bool
    sgn::Vector{Float64}
    V0::Vector{Float64}
    M0::Vector{Float64}
    weight::Float64
    props::Vector{Asap.ElementProps}
    loads::Vector{Vector{Asap.AbstractLoad}}
    breakpoints::Vector{Float64}
end

function (f::ShellMomentField)(s::Real)
    x = clamp(Float64(s), 0.0, 1.0) * f.total
    f.flip && (x = f.total - x)
    k = clamp(searchsortedlast(f.starts, x), 1, length(f.starts))
    xl = clamp(x - f.starts[k], 0.0, f.lengths[k])
    M = f.V0[k] * xl + f.M0[k]
    if f.weight != 0 && !isempty(f.loads[k])
        xs = Float64[xl]
        P, My, Vy, Mz, Vz = zeros(1), zeros(1), zeros(1), zeros(1), zeros(1)
        for ld in f.loads[k]
            Asap.accumulate_force!(ld, xs, P, My, Vy, Mz, Vz, f.props[k])
        end
        M += f.weight * My[1]
    end
    return (f.sgn[k] * M) * u"N*m"
end

"""
    ShellBeamDemand

Story-shell demand on one beam, enveloped over [`StructuralSizer.StoryLoadCases`](@ref).
`Mu_pos` and `Mu_neg` are the sagging and hogging frame moments (N·m) about
the slab mid-plane. `Vu` is the largest frame shear (N). `moment_fields` is
one [`ShellMomentField`](@ref) per load combination; it is empty when the
beam's field origin was not given.

`simple` is true for a steel beam on simple connections at both ends. Its
`Mu_neg` and `moment_fields` are reported only: sizing keeps the frame
model's simple-span hogging and zero-moment points (see
[`analyze_story_shell`](@ref)).
"""
struct ShellBeamDemand
    Mu_pos::Float64
    Mu_neg::Float64
    Vu::Float64
    moment_fields::Vector{ShellMomentField}
    simple::Bool
end

ShellBeamDemand(Mu_pos, Mu_neg, Vu, fields = ShellMomentField[]) =
    ShellBeamDemand(Mu_pos, Mu_neg, Vu, fields, false)

"""`d` marked as a steel beam on simple connections at both ends."""
_as_simple(d::ShellBeamDemand) = ShellBeamDemand(d.Mu_pos, d.Mu_neg, d.Vu, d.moment_fields, true)

"""Hogging that sizes the beam: zero for a simple-connection steel beam."""
_design_Mu_neg(d::ShellBeamDemand) = d.simple ? 0.0 : d.Mu_neg

"""Moment fields that place studs: none for a simple-connection steel beam."""
_design_moment_fields(d::ShellBeamDemand) = d.simple ? ShellMomentField[] : d.moment_fields

"""
One field per load combination along the ordered `pieces`. `flip` is true
when station 0 of the building-model field is at the far end of the pieces.
"""
function _shell_moment_fields(pieces, cases, elemental_loads, flip::Bool)
    n = length(pieces)
    lengths = [Float64(Asap.ElementProps(el).L) for el in pieces]
    starts = cumsum(vcat(0.0, lengths[1:end-1]))
    total = sum(lengths)
    sgn = [el.LCS[2][3] > 0 ? 1.0 : -1.0 for el in pieces]
    props = [Asap.ElementProps(el) for el in pieces]
    loads = [Vector{Asap.AbstractLoad}(elemental_loads[el.elementID]) for el in pieces]
    # End values with no member load. The weight case adds its load at the station.
    ends(u) = [(f = _element_forces_from_u(el, u, (); resolution = 2); (f.Vy[1], f.My[1]))
               for el in pieces]
    w_end = ends(cases.u_weight)
    unit_end = [ends(u) for u in cases.u_unit]
    bps = [(flip ? total - x : x) / total for x in vcat(starts, total)]
    bps = sort!(unique!(clamp.(bps, 0.0, 1.0)))
    out = ShellMomentField[]
    for c in cases.combinations
        V0 = [c.weight * w_end[k][1] for k in 1:n]
        M0 = [c.weight * w_end[k][2] for k in 1:n]
        for (i, q) in enumerate(c.panel), k in 1:n
            V0[k] += q * unit_end[i][k][1]
            M0[k] += q * unit_end[i][k][2]
        end
        push!(out, ShellMomentField(starts, lengths, total, flip, sgn, V0, M0,
                                    c.weight, props, loads, bps))
    end
    return out
end

"""
Envelope one beam's frame forces over the load cases. `pieces` are the
beam's frame elements; `elemental_loads[i]` are the loads on frame `i` in
the beam-weight case.
"""
function _shell_beam_demand(pieces, cases, elemental_loads; resolution::Int = 5)
    isempty(cases.combinations) && throw(ArgumentError("story load cases have no combination"))
    Mpos = 0.0
    Mneg = 0.0
    Vmax = 0.0
    for el in pieces
        ly_z = el.LCS[2][3]
        abs(ly_z) > 1e-8 || throw(ArgumentError(
            "story shell beam $(el.id) has no vertical local axis"))
        # Sagging is sign(ly·ẑ)·My (see `_asap_signed_My_envelopes`).
        sgn = ly_z > 0 ? 1.0 : -1.0
        fw = _element_forces_from_u(el, cases.u_weight, elemental_loads[el.elementID];
                                    resolution = resolution)
        fi = [_element_forces_from_u(el, u, (); resolution = resolution) for u in cases.u_unit]
        for j in 1:resolution, c in cases.combinations
            M = c.weight * fw.My[j]
            V = c.weight * fw.Vy[j]
            for (i, q) in enumerate(c.panel)
                M += q * fi[i].My[j]
                V += q * fi[i].Vy[j]
            end
            Mpos = max(Mpos, sgn * M)
            Mneg = max(Mneg, -sgn * M)
            Vmax = max(Vmax, abs(V))
        end
    end
    return ShellBeamDemand(Mpos, Mneg, Vmax)
end

_plan_xy(node) = (ustrip(u"m", node.position[1]), ustrip(u"m", node.position[2]))

"""
True when `origin` is the far end of the ordered `pieces`. Throws when it is
at neither end.
"""
function _field_flip(pieces, origin; tol::Float64 = 1e-3)
    a = _plan_xy(first(pieces).nodeStart)
    b = _plan_xy(last(pieces).nodeEnd)
    da = hypot(a[1] - origin[1], a[2] - origin[2])
    db = hypot(b[1] - origin[1], b[2] - origin[2])
    min(da, db) <= tol || throw(ArgumentError(
        "story shell beam $(first(pieces).id) does not start or end at its field origin $origin"))
    return db < da
end

"""
    story_shell_beam_demands(model, frames, beam_index, cases; origins, resolution=5)
        -> Dict{Int, ShellBeamDemand}

Shell demand on each beam of a solved story shell, keyed by beam index.
`beam_index` maps a frame id to the beam's index in `struc.beams`; frames
with an id it does not name are skipped. `origins[i]` is the plan point at
station 0 of beam `i`'s building-model moment field; a beam named there also
gets one [`ShellMomentField`](@ref) per load combination.
"""
function story_shell_beam_demands(model, frames, beam_index::AbstractDict{Symbol, Int}, cases;
                                  origins::AbstractDict{Int} = Dict{Int, NTuple{2, Float64}}(),
                                  resolution::Int = 5)
    elemental_loads = Asap.get_elemental_loads(
        Asap.AbstractLoad[ld for ld in model.loads if ld isa Asap.GravityLoad],
        length(model.frame_elements))
    pieces_of = Dict{Symbol, Vector{eltype(frames)}}()
    for el in frames
        push!(get!(() -> eltype(frames)[], pieces_of, el.id), el)
    end
    out = Dict{Int, ShellBeamDemand}()
    for (id, pieces) in pieces_of
        i = get(beam_index, id, nothing)
        i === nothing && continue
        d = _shell_beam_demand(pieces, cases, elemental_loads; resolution = resolution)
        origin = get(origins, i, nothing)
        if origin !== nothing
            fields = _shell_moment_fields(pieces, cases, elemental_loads,
                                          _field_flip(pieces, origin))
            d = ShellBeamDemand(d.Mu_pos, d.Mu_neg, d.Vu, fields, d.simple)
        end
        out[i] = d
    end
    return out
end
