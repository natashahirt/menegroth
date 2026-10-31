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

Size a **single** steel `MemberGroup` (`struc.member_groups[gid]`), honouring both
its per-group `catalog_override` (Phase 6 seam) and an optional per-design
[`MemberGroupSizingOverride`](@ref) passed via `override` (Run 4, Part 1 — obtained
from `params.member_group_overrides` through
[`resolve_member_group_override`](@ref)).

Each sizing input is resolved with `_first_set` (first non-`nothing`), which
establishes a THREE-level precedence, highest first:

```julia
resolved_catalog          = _first_set(override.catalog, group.catalog_override, catalog)
resolved_deflection_limit = _first_set(override.deflection_limit, deflection_limit)
resolved_max_depth        = _first_set(override.max_depth, max_depth)
```

So an `override === nothing` (its default) collapses to exactly the pre-Run-4
resolution — `catalog` falls to `something(group.catalog_override, catalog)`,
`deflection_limit`/`max_depth` to the caller's kwargs — making this call
byte-for-byte identical to before for every existing caller. A populated
`override` field wins over the `MemberGroup` seam and the global default for
*this group only*. The resolved catalog is passed to the per-group AISC selector
(`StructuralSizer.optimize_binary_search`, which is optimal per independent
group), and the winning section is written back to the group, its members, and
the ASAP elements — mirroring [`size_steel_members!`](@ref) for one group.

The model must already be analysed (solved) so `member_group_demands` can
envelope internal forces; this function does not add loads.

!!! note "Phase 5 seam"
    `materialize_level!` (Phase 5, not yet implemented) is expected to set
    `group.catalog_override = level.catalog_override` from the owning
    [`FramingLevel`](@ref) before calling `size_member_group!`, so a joist level
    with a restricted catalog (e.g. a specific set of W-shapes) sizes against
    exactly that catalog. `build_member_groups!` preserves the override across
    its rebuild so it survives the demand-extraction pass.

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
    # member_group_demands rebuilds the groups (preserving catalog_override) and
    # envelopes internal forces, so fetch the (possibly recreated) group after.
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
    #   2. `MemberGroup.catalog_override` (catalog only — Phase 6 seam),
    #   3. the caller's global default kwarg.
    # ENGINEERING KNOBS (not published-code factors): catalog / deflection limit /
    # max depth are sizing inputs. A `nothing` override (the default) collapses each
    # to the pre-Run-4 resolution, so this is byte-identical for every existing call.
    ovr_catalog = override === nothing ? nothing : override.catalog
    ovr_defl    = override === nothing ? nothing : override.deflection_limit
    ovr_depth   = override === nothing ? nothing : override.max_depth

    resolved_catalog          = _first_set(ovr_catalog, group.catalog_override, catalog)
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
            _volume_key(material) => StructuralSizer.section_area(chosen) * L_total))
        for seg_idx in segment_indices(m)
            edge_idx = struc.segments[seg_idx].edge_idx
            edge_idx in edge_ids_in_group || continue
            struc.asap_model.frame_elements[edge_idx].section = asap_sec
        end
    end

    if reanalyze
        Asap.process!(struc.asap_model)
        Asap.solve!(struc.asap_model)
    end

    return group
end


# =============================================================================
# T-Beam Flange Parameters (ACI 318-11 §8.12.2)
# =============================================================================

"""
    _compute_flange_params(struc, group_ids, L_totals; bw_default=12.0u"inch")
        -> (bf_vec, hf_vec)

Compute effective T-beam flange width and slab thickness per beam group.

For each beam group:
1. Finds adjacent slabs via edge→slab mapping
2. Extracts slab thickness (`hf`) as the minimum across adjacent slabs
3. Determines beam position (`:interior` or `:edge`) from `edge_face_counts`
   — boundary edges (count=1) indicate edge beams
4. Reads each beam's per-side tributary profiles (`beam_side_profiles`)
5. Computes the effective flange width at the governing sagging station via
   `governing_flange_width` (ACI 318-11 §8.12.2 / §8.12.3 applied per station)

Groups without adjacent slabs get `bf = nothing`, `hf = nothing`.

# Returns
`(bf_vec, hf_vec)` — vectors of `Union{Nothing, Length}` per group.
"""
function _compute_flange_params(
    struc::BuildingStructure,
    group_ids::Vector{UInt64},
    L_totals::Vector{Float64};
    bw_default::Unitful.Length = 12.0u"inch",
)
    skel = struc.skeleton

    # Build edge → slab thickness mapping
    edge_slab_hf = Dict{Int, Vector{typeof(1.0u"m")}}()
    for slab in struc.slabs
        hf = uconvert(u"m", StructuralSizer.total_depth(slab.result))
        for cell_idx in slab.cell_indices
            face_idx = struc.cells[cell_idx].face_idx
            for e_idx in skel.face_edge_indices[face_idx]
                push!(get!(Vector{typeof(1.0u"m")}, edge_slab_hf, e_idx), hf)
            end
        end
    end

    member_array = struc.beams
    n_groups = length(group_ids)

    bf_vec = Vector{Union{Nothing, typeof(1.0u"m")}}(nothing, n_groups)
    hf_vec = Vector{Union{Nothing, typeof(1.0u"m")}}(nothing, n_groups)

    for (g_idx, gid) in enumerate(group_ids)
        mg = struc.member_groups[gid]

        slab_hfs = typeof(1.0u"m")[]
        sizehint!(slab_hfs, 4)  # typical: 1-4 edges per member group
        beam_idxs = Int[]

        for m_idx in mg.member_indices
            m = member_array[m_idx]
            push!(beam_idxs, m_idx)
            for seg_idx in segment_indices(m)
                edge_idx = struc.segments[seg_idx].edge_idx
                if haskey(edge_slab_hf, edge_idx)
                    append!(slab_hfs, edge_slab_hf[edge_idx])
                end
            end
        end

        # No adjacent slabs → stays rectangular
        isempty(slab_hfs) && continue

        hf = minimum(slab_hfs)
        hf_vec[g_idx] = hf

        # Span used for the §8.12.2 / §8.12.3 length caps. Same center-to-center
        # group length the previous scalar path passed as `ln`.
        ln = L_totals[g_idx] * u"m"

        # Per beam: bf at the sagging station that maximizes M⁺/bf, from the
        # per-side tributary profiles (ACI 318-11 §8.12.2 / §8.12.3, corpus:
        # aci-318-11, PDF p. 119). A group shares one section, so the group
        # width is the narrowest of those governing widths.
        bf_group = nothing
        for m_idx in beam_idxs
            m = member_array[m_idx]
            left, right = beam_side_profiles(struc, m)
            (left === nothing && right === nothing) && continue
            M_of_s, demand_bps = beam_signed_moment_field(struc, m)
            bf_m = StructuralSizer.governing_flange_width(
                bw_default, hf, ln, M_of_s;
                left = left, right = right, extra_breakpoints = demand_bps)
            bf_group = bf_group === nothing ? bf_m : min(bf_group, bf_m)
        end
        bf_group === nothing && continue
        bf_vec[g_idx] = bf_group
    end

    return bf_vec, hf_vec
end

