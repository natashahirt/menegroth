# -----------------------------------------------------------------------------
# Per-element analysis stiffness
# -----------------------------------------------------------------------------

"""
Normalized station at the midpoint of each segment of `beam`, in the same
length coordinate as [`beam_signed_moment_field`](@ref).
"""
function _beam_segment_midpoints(struc::BuildingStructure, beam::Beam)
    segs = segment_indices(beam)
    isempty(segs) && throw(ArgumentError("beam has no segments"))
    edges = Int[]
    lengths = Float64[]
    for si in segs
        seg = struc.segments[si]
        for el_idx in _frame_element_indices(struc, seg.edge_idx)
            el = struc.asap_model.frame_elements[el_idx]
            push!(edges, el_idx)
            push!(lengths, Float64(Asap.ElementProps(el).L))
        end
    end
    total = sum(lengths)
    total > 0 || throw(ArgumentError("beam has zero length"))
    stations = Float64[]
    acc = 0.0
    for L in lengths
        push!(stations, (acc + 0.5 * L) / total)
        acc += L
    end
    return edges, stations
end

"""Replace only the strong-axis inertia of an Asap section."""
function _section_with_Ix(sec::Asap.Section, Ix)
    Asap.Section(sec.A, sec.E, sec.G, Ix, sec.Iy, sec.J, sec.ρ;
                 Ay = sec.Ay, Az = sec.Az)
end

"""
    apply_composite_element_stiffness!(struc, beam, section, material, slab, ΣQn_at;
        left=nothing, right=nothing, supports=Float64[], Asr=0.0u"mm^2", d_rebar=0.0u"m")

Write one strong-axis inertia onto each frame element of `beam`.

The element is given the inertia at its midpoint. A sagging midpoint uses
`I_LB` with `ΣQn_at(region)` for the sagging region that contains it. A
hogging midpoint uses the cracked section. The steel area, moduli, weak-axis
inertia, torsion, and density stay as they are.

# ENGINEERING JUDGMENT
AISC 360-22 Commentary Eq. C-I3-5 (corpus: aisc-360-22, PDF p. 502) permits
one constant inertia for the elastic analysis. Assigning a different inertia
to each element is a refinement of that constant. One element still has one
inertia, so a bay modeled as a single element cannot represent both the
hogging zone and the sagging zone; the midpoint decides the whole element.

This changes the analysis stiffness only. [`composite_deflection_scale`](@ref)
still assumes the solved model carries the bare-steel inertia, so do not scale
a deflection that was solved with these inertias.
"""
function apply_composite_element_stiffness!(struc::BuildingStructure, beam::Beam,
                                            section, material, slab, ΣQn_at;
                                            left = nothing, right = nothing,
                                            supports::AbstractVector{<:Real} = Float64[],
                                            Asr = 0.0u"mm^2", d_rebar = 0.0u"m")
    M_of_s, _ = beam_signed_moment_field(struc, beam)
    regions = positive_moment_regions(M_of_s)
    edges, stations = _beam_segment_midpoints(struc, beam)
    for (edge_idx, s) in zip(edges, stations)
        el = struc.asap_model.frame_elements[edge_idx]
        Ix = composite_inertia_at_station(section, material, slab, _beam_span_length(beam),
                                          s, M_of_s, ΣQn_at;
                                          left = left, right = right, supports = supports,
                                          Asr = Asr, d_rebar = d_rebar, regions = regions)
        el.section = _section_with_Ix(el.section, Ix)
    end
    return struc
end

"""Plan point, in metres, at station 0 of [`beam_signed_moment_field`](@ref)."""
function _beam_field_origin(struc::BuildingStructure, beam::Beam)
    segs = segment_indices(beam)
    isempty(segs) && throw(ArgumentError("beam has no segments"))
    idx = first(_frame_element_indices(struc, struc.segments[first(segs)].edge_idx))
    p = struc.asap_model.frame_elements[idx].nodeStart.position
    return (ustrip(u"m", p[1]), ustrip(u"m", p[2]))
end

"""
Record what [`apply_composite_element_stiffness!`](@ref) used for `beam`, so the
story shell can take the same inertia at its own stations.

`regions` are the sagging regions of the moment field when the inertia was
written. `ΣQn[k]` is the anchor strength of region `k`. `origin` is the plan
point at station 0 of that field.
"""
function _record_composite_stiffness!(struc::BuildingStructure, beam::Beam,
                                      section, material, slab, ΣQn_at;
                                      left = nothing, right = nothing,
                                      supports::AbstractVector{<:Real} = Float64[],
                                      Asr = 0.0u"mm^2", d_rebar = 0.0u"m")
    M_of_s, _ = beam_signed_moment_field(struc, beam)
    regions = positive_moment_regions(M_of_s)
    profiles = get!(() -> IdDict{Beam, NamedTuple}(), _composite_mesh!(struc),
                    :stiffness_profiles)
    profiles[beam] = (; section, material, slab, L = _beam_span_length(beam),
                      left, right, supports = collect(Float64, supports),
                      Asr, d_rebar, regions, ΣQn = [ΣQn_at(r) for r in regions],
                      origin = _beam_field_origin(struc, beam))
    return profiles[beam]
end

"""The recorded composite stiffness of `beam`, or `nothing`."""
function composite_stiffness_profile(struc::BuildingStructure, beam::Beam)
    mesh = _composite_mesh(struc)
    mesh === nothing && return nothing
    profiles = get(mesh, :stiffness_profiles, nothing)
    profiles === nothing && return nothing
    return get(profiles, beam, nothing)
end

"""
    composite_stiffness_at(profile, s) -> SecondMomentOfArea

Inertia at normalized station `s`, as [`composite_inertia_at_station`](@ref)
gives it: `I_LB` with the region's anchors inside a sagging region, the
cracked section outside.
"""
function composite_stiffness_at(p, s::Real)
    return composite_inertia_at_station(p.section, p.material, p.slab, p.L, s, nothing,
                                        r -> p.ΣQn[findfirst(==(r), p.regions)];
                                        left = p.left, right = p.right, supports = p.supports,
                                        Asr = p.Asr, d_rebar = p.d_rebar, regions = p.regions)
end

"""Member length for the effective-width cap. A bare number is meters."""
function _beam_span_length(beam::Beam)
    L = member_length(beam)
    return L isa Unitful.Quantity ? uconvert(u"m", L) : L * u"m"
end

"""
Sorted zero-crossing stations of the sagging regions, including the member
ends when a region reaches them.
"""
function _region_boundaries(demand_of_s)
    regions = positive_moment_regions(demand_of_s)
    bounds = Float64[]
    for r in regions
        push!(bounds, r.s_left, r.s_right)
    end
    return sort!(bounds)
end

"""
    refine_composite_stiffness!(struc, beam, section, material, slab, ΣQn_at;
        tol=1e-2, max_iter=6, kwargs...)

Assign per-element composite inertias and re-solve until the sagging-region
boundaries move by less than `tol` (a fraction of the member length), or
`max_iter` passes have run.

Each pass writes the inertias from the current moment field
([`apply_composite_element_stiffness!`](@ref)), rebuilds the element stiffness
without changing the mesh, and solves again. The same engineering judgment as
that function applies: this is a refinement of Commentary Eq. C-I3-5, not a
replacement for the strength check.

Returns `(; iterations, converged, boundaries)`.
"""
function refine_composite_stiffness!(struc::BuildingStructure, beam::Beam,
                                     section, material, slab, ΣQn_at;
                                     tol::Real = 1e-2, max_iter::Int = 6,
                                     left = nothing, right = nothing,
                                     supports::AbstractVector{<:Real} = Float64[],
                                     Asr = 0.0u"mm^2", d_rebar = 0.0u"m")
    model = struc.asap_model
    M_of_s, _ = beam_signed_moment_field(struc, beam)
    prev = _region_boundaries(M_of_s)
    converged = false
    # The loop index is local to the loop, so the count is kept separately.
    n_iter = 0
    for _ in 1:max_iter
        n_iter += 1
        apply_composite_element_stiffness!(struc, beam, section, material, slab, ΣQn_at;
                                           left = left, right = right, supports = supports,
                                           Asr = Asr, d_rebar = d_rebar)
        Asap.update!(model; values_only = true)
        Asap.solve!(model)
        M_of_s, _ = beam_signed_moment_field(struc, beam)
        now = _region_boundaries(M_of_s)
        if length(now) == length(prev) &&
                (isempty(now) || maximum(abs.(now .- prev)) <= tol)
            prev = now
            converged = true
            break
        end
        prev = now
    end
    return (; iterations = n_iter, converged = converged, boundaries = prev)
end

