# =============================================================================
# Pinned-joist envelope for one-way concrete joist floors
# =============================================================================
#
# A monolithic joist is moment-connected to the beams it frames into. Where a
# beam line has no column under it (it lands on a girder), the girder sags, the
# joists hang off the stiffer line at their other end as fixed cantilevers, and
# the beam line and girders under it are unloaded. Beam sizing therefore also
# solves the frame with the joist ends pinned, which sends every joist's load to
# both of its supports, and sizes each beam group for the larger of the two
# strength demands. Waffle grillages are excluded: their ribs act two-way.

"""
    _pinned_joist_releases(struc) -> Dict{Int, Symbol}

Frame element index → end release for the joists of every concrete one-way joist
level (`role = :joist`, `LinearAxisPattern`), with each joist's outer ends
pinned and its torsion kept. Interior nodes of a joist chain stay continuous.
Empty when the building has no such level.
"""
function _pinned_joist_releases(struc::BuildingStructure)
    out = Dict{Int, Symbol}()
    nodes = struc.asap_model.nodes
    frames = struc.asap_model.frame_elements
    for slab in struc.slabs, fl in slab.framing_levels
        fl.role === :joist && fl.pattern isa LinearAxisPattern || continue
        _volume_key(fl.material) isa StructuralSizer.Concrete || continue
        for mi in level_member_indices(struc, fl)
            1 <= mi <= length(struc.beams) || continue
            beam = struc.beams[mi]
            beam.role === :joist || continue
            v1, v2 = _member_end_vertices(struc, beam)
            ends = (nodes[v1], nodes[v2])
            n_pinned = 0
            for si in segment_indices(beam), ei in _frame_element_indices(struc, struc.segments[si].edge_idx)
                el = frames[ei]
                pin_start = any(n -> n === el.nodeStart, ends)
                pin_end = any(n -> n === el.nodeEnd, ends)
                (pin_start || pin_end) || continue
                out[ei] = pin_start && pin_end ? :joist : pin_start ? :freefixed : :fixedfree
                n_pinned += pin_start + pin_end
            end
            n_pinned == 2 || error(
                "pinned-joist solve: joist $mi has $n_pinned frame element ends at its " *
                "end vertices ($v1, $v2); expected 2")
        end
    end
    return out
end

"""
    _with_pinned_joists(f, struc, releases)

Call `f()` while `struc` holds a solved copy of its Asap model in which the frame
elements in `releases` have those end releases. The cell loads, rigid links,
pattern-case cache, and member groups are swapped with the model and restored
afterwards, so `struc` is unchanged when this returns.
"""
function _with_pinned_joists(f, struc::BuildingStructure, releases::AbstractDict{Int, Symbol})
    dicts = (struc.cell_tributary_loads, struc.cell_dead_loads, struc.cell_live_loads)
    keys_of = [collect(keys(d)) for d in dicts]
    cases = [Asap.AbstractLoad[d[k]...] for (d, ks) in zip(dicts, keys_of) for k in ks]
    pinned = Asap.with_releases(struc.asap_model, releases;
                                links = struc.asap_rigid_links, load_cases = cases)
    swapped = Dict{Int, Vector{Asap.TributaryLoad}}[]
    i = 0
    for ks in keys_of
        d = Dict{Int, Vector{Asap.TributaryLoad}}()
        for k in ks
            d[k] = Vector{Asap.TributaryLoad}(pinned.load_cases[i += 1])
        end
        push!(swapped, d)
    end

    saved = (struc.asap_model, struc.asap_rigid_links, struc.cell_tributary_loads,
             struc.cell_dead_loads, struc.cell_live_loads, struc._analysis_caches,
             struc.member_groups)
    had_patterns = _get_pattern_solve_cache(struc) !== nothing
    try
        struc.asap_model = pinned.model
        struc.asap_rigid_links = pinned.links
        struc.cell_tributary_loads, struc.cell_dead_loads, struc.cell_live_loads = swapped
        struc._analysis_caches = Dict(k => v for (k, v) in saved[6]
                                      if k != _PATTERN_SOLVE_CACHE_KEY)
        struc.member_groups = Dict{UInt64, MemberGroup}()
        Asap.process!(struc.asap_model)
        _solve_struc_model!(struc)
        if had_patterns
            pattern_cases = _generate_pattern_cases(struc)
            if length(pattern_cases) > 1
                u_cases = Asap.solve(struc.asap_model, pattern_cases, struc.asap_rigid_links)
                _store_pattern_solve_cache!(struc, pattern_cases, u_cases)
            end
        end
        return f()
    finally
        (struc.asap_model, struc.asap_rigid_links, struc.cell_tributary_loads,
         struc.cell_dead_loads, struc.cell_live_loads, struc._analysis_caches,
         struc.member_groups) = saved
    end
end

"""
    _envelope_demand(a, b) -> MemberDemand

`a` with each strength demand raised to `b`'s where `b`'s is larger: axial
tension and compression, sagging and hogging moment, weak-axis moment, both
shears, and torsion, each enveloped on its own as `member_group_demands` does
across load cases. Service deflections, `I_ref`, and the column end moments
are `a`'s.
"""
function _envelope_demand(a::StructuralSizer.MemberDemand, b::StructuralSizer.MemberDemand)
    return StructuralSizer.MemberDemand(a.member_idx;
        Pu_c = max(a.Pu_c, b.Pu_c), Pu_t = max(a.Pu_t, b.Pu_t),
        Mux = max(a.Mux, b.Mux),
        Mux_pos = max(a.Mux_pos, b.Mux_pos), Mux_neg = max(a.Mux_neg, b.Mux_neg),
        Muy = max(a.Muy, b.Muy),
        Vu_strong = max(a.Vu_strong, b.Vu_strong), Vu_weak = max(a.Vu_weak, b.Vu_weak),
        Tu = max(a.Tu, b.Tu),
        δ_max_LL = a.δ_max_LL, δ_max_total = a.δ_max_total, I_ref = a.I_ref,
        composite = a.composite, transverse_load = a.transverse_load)
end
