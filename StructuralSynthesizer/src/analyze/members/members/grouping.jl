# =============================================================================
# Single member-group sizing (Phase 6 catalog-override seam)
# =============================================================================

# First non-`nothing` argument (left-to-right), or `nothing` when all are unset.
# Unlike `something`, it may return `nothing` (so it works for the strength-only
# `deflection_limit = nothing` default), and it short-circuits.
_first_set() = nothing
_first_set(x, rest...) = x === nothing ? _first_set(rest...) : x

"""
    size_member_group!(struc, gid; catalog=StructuralSizer.all_W(),
                        material=StructuralSizer.A992_Steel,
                        member_edge_group=:beams, max_depth=Inf*u"m",
                        resolution=200, reanalyze=true, deflection_limit=nothing,
                        override=nothing)

Size a **single** steel `MemberGroup` (`struc.member_groups[gid]`), honouring an
optional per-design [`MemberGroupSizingOverride`](@ref) passed via `override`
(Run 4, Part 1 — obtained from `params.member_group_overrides` through
[`resolve_member_group_override`](@ref)).

Each sizing input is resolved with `_first_set` (first non-`nothing`), highest
first:

```julia
resolved_catalog          = _first_set(override.catalog, catalog)
resolved_deflection_limit = _first_set(override.deflection_limit, deflection_limit)
resolved_max_depth        = _first_set(override.max_depth, max_depth)
```

An `override === nothing` (its default) uses the caller's kwargs. A populated
`override` field wins for this group only. A framing level restricts its catalog
through `FramingLevel.beam_options`, which the batched [`size_beams!`](@ref)
path reads. The resolved catalog is passed to the per-group AISC selector
(`StructuralSizer.optimize_binary_search`, which is optimal per independent
group), and the winning section is written back to the group, its members, and
the ASAP elements — mirroring [`size_steel_members!`](@ref) for one group.

The model must already be analysed (solved) so `member_group_demands` can
envelope internal forces; this function does not add loads.

Returns the sized `MemberGroup`.
"""
function size_member_group!(
    struc::BuildingStructure,
    gid::UInt64;
    catalog = StructuralSizer.all_W(),
    material = StructuralSizer.A992_Steel,
    member_edge_group::Symbol = :beams,
    max_depth = Inf * u"m",
    resolution::Int = 200,
    reanalyze::Bool = true,
    deflection_limit::Union{Nothing, Real} = nothing,
    override::Union{Nothing, MemberGroupSizingOverride} = nothing,
)
    # member_group_demands rebuilds the groups and envelopes internal forces,
    # so fetch the (possibly recreated) group after.
    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        member_group_demands(struc; member_edge_group=member_edge_group, resolution=resolution)

    haskey(struc.member_groups, gid) ||
        throw(ArgumentError("no MemberGroup with id $gid in struc.member_groups"))
    group = struc.member_groups[gid]

    g_idx = findfirst(==(gid), group_ids)
    g_idx === nothing && throw(ArgumentError(
        "MemberGroup $gid has no demands in edge group :$member_edge_group"))

    # Override resolution (Run 4, Part 1). Precedence, highest first:
    #   1. the per-design `member_group_overrides[gid]` entry (`override`),
    #   2. the caller's global default kwarg.
    # ENGINEERING KNOBS (not published-code factors): catalog / deflection limit /
    # max depth are sizing inputs. A `nothing` override (the default) uses the
    # caller's kwargs.
    ovr_catalog = override === nothing ? nothing : override.catalog
    ovr_defl    = override === nothing ? nothing : override.deflection_limit
    ovr_depth   = override === nothing ? nothing : override.max_depth

    resolved_catalog          = _first_set(ovr_catalog, catalog)
    resolved_deflection_limit = _first_set(ovr_defl, deflection_limit)
    resolved_max_depth        = _first_set(ovr_depth, max_depth)

    geometry = StructuralSizer.SteelMemberGeometry(
        L_totals[g_idx]; Lb=Lb_govs[g_idx], Cb=Cb_govs[g_idx],
        Kx=Kx_govs[g_idx], Ky=Ky_govs[g_idx])

    checker = StructuralSizer.AISCChecker(;
        max_depth=resolved_max_depth, deflection_limit=resolved_deflection_limit)

    result = StructuralSizer.optimize_binary_search(
        checker, [demands[g_idx]], [geometry], resolved_catalog, material)

    # Catalog sections usually carry material=nothing; stamp the group's material.
    chosen = copy(result.sections[1])
    chosen.material = material
    group.section = chosen

    member_array = if member_edge_group === :columns || (member_edge_group isa Union{AbstractVector{Symbol}, Tuple} && :columns in member_edge_group)
        struc.columns
    elseif member_edge_group === :struts || (member_edge_group isa Union{AbstractVector{Symbol}, Tuple} && :struts in member_edge_group)
        struc.struts
    else
        struc.beams
    end
    skel = struc.skeleton
    edge_ids_in_group = Set(get(skel.groups_edges, member_edge_group, Int[]))
    asap_sec = StructuralSizer.to_asap_section(chosen, material)

    for m_idx in group.member_indices
        m = member_array[m_idx]
        L_raw = sum(struc.segments[i].L for i in segment_indices(m))
        L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
        set_section!(m, chosen)
        set_volumes!(m, MaterialVolumes(
            _volume_key(material) => StructuralSizer.self_weight_area(chosen) * L_total))
        for seg_idx in segment_indices(m)
            edge_idx = struc.segments[seg_idx].edge_idx
            edge_idx in edge_ids_in_group || continue
            struc.asap_model.frame_elements[edge_idx].section = asap_sec
        end
    end

    if reanalyze
        Asap.process!(struc.asap_model)
        _solve_struc_model!(struc)
    end

    return group
end
