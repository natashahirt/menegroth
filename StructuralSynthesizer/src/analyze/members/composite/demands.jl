# -----------------------------------------------------------------------------
# Exact FEM demand field M(s) (reuse of the TributaryLoad internal-force field)
# -----------------------------------------------------------------------------

"""
    _element_signed_moment_at(el, loads, x_m) -> Float64

Signed strong-axis internal moment `My` (N·m) of Asap frame element `el` at local
abscissa `x_m` (m), from the CURRENT solved displacements (`el.nodeStart/.nodeEnd`
displacements baked into `el`) plus the exact closed-form `TributaryLoad`
contribution. Mirrors `Asap.ElementForceAndDisplacement`'s force path
(`Flocal = R·K·u_global`, then `accumulate_force!`) evaluated at the single
station `x_m`, so there is NO grid sampling and NO new demand machinery.
"""
function _element_signed_moment_at(el, loads, x_m::Float64)
    dofs = Asap.etype2DOF[typeof(el)]
    ep = Asap.ElementProps(el)
    ug = Vector{Float64}(undef, 12)
    Asap._fill_uglobal!(ug, el)
    Flocal = el.R * (el.K * ug)
    @inbounds for i in 1:12
        Flocal[i] *= dofs[i]
    end
    Vystart = Flocal[2]
    Mystart = Flocal[6]

    xs = Float64[x_m]
    P  = Float64[0.0]
    My = Float64[Vystart * x_m - Mystart]
    Vy = Float64[Vystart]
    Mz = Float64[0.0]
    Vz = Float64[0.0]
    for load in loads
        Asap.accumulate_force!(load, xs, P, My, Vy, Mz, Vz, ep)
    end
    return My[1]
end

# -----------------------------------------------------------------------------
# Interior supports of a chained beam (§I3.1a span, center-to-center of supports)
# -----------------------------------------------------------------------------

"""
    beam_support_lookup(struc) -> NamedTuple

Vertices that can support a beam, built once per structure for
[`beam_interior_supports`](@ref): `fixed` holds vertices where a column or
wall edge ends, or that are in the `:support` group. `through` counts, per
vertex, the beams that pass through it (the vertex is interior to the beam's
chain).
"""
function beam_support_lookup(struc::BuildingStructure)
    skel = struc.skeleton
    fixed = Set{Int}(get(skel.groups_vertices, :support, Int[]))
    for grp in (:columns, :walls)
        for e in get(skel.groups_edges, grp, Int[])
            a, b = skel.edge_indices[e]
            push!(fixed, a, b)
        end
    end
    through = Dict{Int, Int}()
    for beam in struc.beams
        verts = _beam_chain_vertices(struc, beam)
        for v in @view verts[2:end-1]
            through[v] = get(through, v, 0) + 1
        end
    end
    return (; fixed, through)
end

"""Ordered skeleton vertices along `beam`, matching `segment_indices(beam)`."""
function _beam_chain_vertices(struc::BuildingStructure, beam::Beam)
    edges = [struc.segments[si].edge_idx for si in segment_indices(beam)]
    return _ordered_chain_vertices(struc.skeleton, edges)
end

"""
    beam_interior_supports(struc, beam; lookup=beam_support_lookup(struc)) -> Vector{Float64}

Fractions of the beam length at its interior supports. A beam drawn as one
line across several bays is one member; AISC 360-22 §I3.1a(a) (corpus:
aisc-360-22, PDF p. 168) measures `L/8` on "the beam span, center-to-center
of supports", so each bay needs its own span.

# ENGINEERING JUDGMENT
An interior chain vertex is a support when a column, a wall, or a `:support`
vertex is there, or when another beam passes straight through it. A beam that
only ends on this one is carried by it and is not a support. Where two
continuous beams cross, each counts the other as a support; more supports
give shorter spans and smaller effective widths.
"""
function beam_interior_supports(struc::BuildingStructure, beam::Beam;
                                lookup = beam_support_lookup(struc))
    verts = _beam_chain_vertices(struc, beam)
    length(verts) <= 2 && return Float64[]
    skel = struc.skeleton
    xyz(v) = (c = Meshes.coords(skel.vertices[v]);
              (ustrip(u"m", c.x), ustrip(u"m", c.y), ustrip(u"m", c.z)))
    cum = zeros(length(verts))
    for k in 2:length(verts)
        a, b = xyz(verts[k - 1]), xyz(verts[k])
        cum[k] = cum[k - 1] + sqrt(sum(abs2, a .- b))
    end
    total = cum[end]
    out = Float64[]
    for k in 2:(length(verts) - 1)
        v = verts[k]
        # This beam counts itself once in `through`.
        if v in lookup.fixed || get(lookup.through, v, 0) >= 2
            push!(out, cum[k] / total)
        end
    end
    return out
end

"""
    beam_signed_moment_field(struc, beam) -> (M_of_s, breakpoints)

Return a callable `M_of_s(s) -> Moment` giving the EXACT, continuity-correct
signed demand moment at normalized station `s ∈ [0, 1]` along `beam` (SAGGING
POSITIVE, hogging negative), plus the `breakpoints` where the field's segment
structure changes (element boundaries and `TributaryLoad` width breakpoints).

The sign is physical sagging-positive, obtained with the same `ly_z` convention
as `_asap_signed_My_envelopes`. The model must already be solved (call
`to_asap!` + `solve!` / the sizing pipeline first). Reuses the Asap internal-force
recovery exactly — no Riemann sampling, no new demand path.
"""
function beam_signed_moment_field(struc::BuildingStructure, beam::Beam)
    segs = segment_indices(beam)
    isempty(segs) && throw(ArgumentError("beam has no segments"))

    # Per-segment element, loads, physical length, and sagging-sign.
    els = Any[]; loads_per = Any[]; len_m = Float64[]; sag_sign = Float64[]
    element_loads = Asap.get_elemental_loads(struc.asap_model)
    for si in segs
        seg = struc.segments[si]
        # A subdivided bay keeps the parent element at the skeleton index, with
        # zero stiffness, and stores the loaded children beside it.
        for el_idx in _frame_element_indices(struc, seg.edge_idx)
            el = struc.asap_model.frame_elements[el_idx]
            push!(els, el)
            push!(loads_per, element_loads[el.elementID])
            # The element's own length: the force recovery asserts 0 ≤ x ≤ that length,
            # and the segment's stored length can differ from it.
            push!(len_m, Float64(Asap.ElementProps(el).L))
            ly_z = el.LCS[2][3]
            push!(sag_sign, ly_z >= 0 ? 1.0 : -1.0)   # map My → sagging-positive
        end
    end
    total = sum(len_m)

    # Cumulative normalized breakpoints at element boundaries.
    cum = cumsum(len_m)
    bps = Float64[0.0]
    for c in cum
        push!(bps, c / total)
    end
    bps = unique!(clamp.(bps, 0.0, 1.0))

    function M_of_s(s::Real)
        sc = clamp(Float64(s), 0.0, 1.0)
        x_global = sc * total
        # Locate the element and local abscissa.
        acc = 0.0
        k = 1
        while k < length(len_m) && x_global > acc + len_m[k]
            acc += len_m[k]; k += 1
        end
        x_local = clamp(x_global - acc, 0.0, len_m[k])
        My = _element_signed_moment_at(els[k], loads_per[k], x_local)
        return (My * sag_sign[k]) * u"N*m"
    end

    return (M_of_s, bps)
end

