# =============================================================================
# Monolithic column self-weight coupling (FE influence coefficients)
# =============================================================================
#
# In the real member stage a steel column group's governing axial demand `Pu_c`
# is an FE REACTION read off the solved Asap model (`member_group_demands` →
# `_element_forces_from_u`), NOT an explicit tributary accumulation. When a column
# section changes, its self-weight `ρ·A·g·L` changes, which changes the axial it
# carries AND — because the moment frame is statically indeterminate — the axial
# that redistributes onto every other column. The classic sizing loop chases that
# feedback by "size against the current self-weight → re-solve → re-size", a
# Picard ratchet that only climbs one catalog step per pass and never certifies
# the self-consistent optimum.
#
# This module removes the ratchet for the LINEAR-regime case. For a linear-elastic
# model the internal axial at a fixed station of column `i` is a linear functional
# of the load vector, and an element's self-weight enters that load only through a
# section-INDEPENDENT shape scaled by its area `A`. Hence
#
#     Pu_c_i(sections) = base_i + Σ_g φ_{i,g} · A(section_g),
#
# where `φ_{i,g}` is the exact per-unit-area influence of column group `g`'s
# self-weight on group `i`'s governing axial — a constant of the frozen-stiffness
# model. That is precisely a [`LinearCapacityCoupling`] (with per-(target,source)
# influence coefficients), so the coupled column sizing becomes ONE certified MILP
# via `optimize_discrete(; coupling)`.
#
# Exactness and safety. Because changing a section's AREA changes only the LOAD
# (not the stiffness matrix `K`), `Asap.linear_response` returns the EXACT Δu for a
# self-weight change, so `φ` is exact for the current `K`. The only approximation
# is freezing `K` (and which station/ case governs) across a section change; that
# is GUIDANCE only — the surrounding member loop's held-check and
# `_verify_installed_design!` re-solve and re-check every installed column, so a
# stale linearization can never pass an unsafe design, at worst costing one
# correction pass. The construction was validated to machine precision against
# fresh full re-solves on an indeterminate frame in
# `scripts/runners/selfweight_influence_proving_slice.jl`.
#
# Scope. This is the STEEL, discrete, single-material, full-load-governs regime
# only; `build_column_selfweight_coupling` returns `nothing` (caller falls back to
# the ratchet) whenever that regime does not hold.

"""
    _column_group_frame_elements(struc, group_ids) -> Vector{Vector{Int}}

For each column group (aligned to `group_ids`), the Asap `frame_elements` indices
of every segment of every column member in the group. These are the elements
whose self-weight scales with the group's chosen section. Assumes
`build_member_groups!(struc; member_type=:columns)` has populated
`struc.member_groups` (as `member_group_demands` does).
"""
function _column_group_frame_elements(struc::BuildingStructure, group_ids)
    n_el = length(struc.asap_model.frame_elements)
    out = Vector{Vector{Int}}(undef, length(group_ids))
    for (g, gid) in enumerate(group_ids)
        ids = Int[]
        mg = get(struc.member_groups, gid, nothing)
        if mg !== nothing
            for m_idx in mg.member_indices
                col = struc.columns[m_idx]
                for seg_idx in segment_indices(col)
                    edge_idx = struc.segments[seg_idx].edge_idx
                    (edge_idx < 1 || edge_idx > n_el) && continue
                    for i in _frame_element_indices(struc, edge_idx)
                        (1 <= i <= n_el) && push!(ids, i)
                    end
                end
            end
        end
        out[g] = unique!(ids)
    end
    return out
end

"""
    _group_gravity_loads(model, frame_el_idxs) -> Dict{Int, Asap.GravityLoad}

Map an Asap frame-element INDEX to the `GravityLoad` (self-weight) the model
carries on it, restricted to the elements in `frame_el_idxs` (the union over all
column groups). Built from `model.loads`, so it uses the model's exact `ρ·A·g`
(`GravityLoad` ⇒ `w = section.ρ · section.A · factor`, global −Z).
"""
function _group_gravity_loads(model, frame_el_idxs::Set{Int})
    by_elementID = Dict{UInt, Asap.GravityLoad}()
    for ld in model.loads
        ld isa Asap.GravityLoad || continue
        by_elementID[ld.element.elementID] = ld
    end
    out = Dict{Int, Asap.GravityLoad}()
    for i in frame_el_idxs
        el = model.frame_elements[i]
        g = get(by_elementID, el.elementID, nothing)
        g === nothing || (out[i] = g)
    end
    return out
end

"""
    _selfweight_nodal_load(model, grav_loads, el_idxs) -> Vector{Float64}

Effective nodal load vector (length `nDOFs`) of the current self-weight of the
frame elements `el_idxs`. The solve is `u = K⁻¹(P − Pf)`, so an element load
contributes `−Pf` to the effective right-hand side; `populate_load!` assembles
`Pf`, and this returns its negation summed over the group's gravity loads. The
vector scales linearly with the group's section area (same shape), so dividing by
the current area yields the per-unit-area self-weight load used for the influence.
"""
function _selfweight_nodal_load(model, grav_loads::Dict{Int, Asap.GravityLoad}, el_idxs)
    Pf = zeros(model.nDOFs)
    for i in el_idxs
        ld = get(grav_loads, i, nothing)
        ld === nothing || Asap.populate_load!(Pf, ld)
    end
    Pf .= .-Pf
    return Pf
end

"""Compression (N, +ve) at `idx` of `el` from displacement `u` plus `loads`."""
function _axial_compression_at(el, u::AbstractVector{<:Real}, loads, idx::Int; resolution::Int)
    f = _element_forces_from_u(el, u, loads; resolution = resolution)
    return -Float64(f.P[idx])
end

"""
    _column_current_area(struc, el_idx) -> Float64

Cross-sectional area (m²) of the Asap frame element's CURRENT section — the area
`GravityLoad` uses for that element's self-weight. `0.0` when unavailable.
"""
function _column_current_area(struc::BuildingStructure, el_idx::Int)
    el = struc.asap_model.frame_elements[el_idx]
    A = el.section.A
    return A isa Unitful.Quantity ? ustrip(u"m^2", A) : Float64(A)
end

"""
    _governing_station(struc, el_idxs, element_loads; resolution)
        -> (Pu_c, el_star_idx, station_idx)

The frame element and station in `el_idxs` carrying the largest full-load
compression, and that compression. Mirrors `member_group_demands`' column
envelope (`min(P)` over the full-load `_element_forces_from_u`), so `Pu_c` equals
the group's reported `demands[i].Pu_c` in the full-load-governs regime.
"""
function _governing_station(struc::BuildingStructure, el_idxs, element_loads; resolution::Int)
    u = struc.asap_model.u
    Pu_c = -Inf
    el_star = 0
    station = 1
    for i in el_idxs
        el = struc.asap_model.frame_elements[i]
        f = _element_forces_from_u(el, u, element_loads[el.elementID]; resolution = resolution)
        for k in eachindex(f.P)
            comp = -Float64(f.P[k])
            if comp > Pu_c
                Pu_c = comp
                el_star = i
                station = k
            end
        end
    end
    return Pu_c, el_star, station
end

"""Rebuild a steel column `MemberDemand` with a different compression `Puc`, all else held."""
function _demand_with_axial(d::StructuralSizer.MemberDemand, Puc::Real)
    return StructuralSizer.MemberDemand(d.member_idx;
        Pu_c = Puc, Pu_t = d.Pu_t, Mux = d.Mux, Mux_pos = d.Mux_pos, Mux_neg = d.Mux_neg,
        Muy = d.Muy, M1x = d.M1x, M2x = d.M2x, M1y = d.M1y, M2y = d.M2y,
        Vu_strong = d.Vu_strong, Vu_weak = d.Vu_weak, Tu = d.Tu,
        δ_max_LL = d.δ_max_LL, δ_max_total = d.δ_max_total, I_ref = d.I_ref,
        composite = d.composite, transverse_load = d.transverse_load, lt = d.lt)
end

"""
    _max_axial_capacity(checker, cache, s, section, material, d, geom; seed)
        -> Float64

Largest compression (N) section `s` can carry for a group with demand `d` (its
frozen moments/tension/geometry), found by bisection on `is_feasible`, which is
monotone decreasing in `Pu_c`. `0.0` when the section fails even at zero axial
(its moments alone govern — it is screened out of the group regardless). This
inverts the SAME checker `optimize_discrete` screens and `_verify_installed_design!`
re-checks with, so the capacity row is consistent with both.
"""
function _max_axial_capacity(checker, cache, s::Int, section, material,
                             d::StructuralSizer.MemberDemand, geom; seed::Float64,
                             tol::Float64 = 1.0)
    feas(P) = is_feasible(checker, cache, s, section, material, _demand_with_axial(d, P), geom)
    feas(0.0) || return 0.0
    hi = max(seed, 1.0)
    # Bracket: double `hi` until infeasible (or give up and treat as effectively
    # unbounded — a section this strong is never the binding capacity).
    for _ in 1:64
        feas(hi) || break
        hi *= 2.0
        hi > 1.0e15 && return hi
    end
    lo = 0.0
    while hi - lo > tol
        mid = 0.5 * (lo + hi)
        feas(mid) ? (lo = mid) : (hi = mid)
    end
    return lo
end

"""
    build_column_selfweight_coupling(struc, opts, group_ids, demands, geometries,
                                     catalog, material; resolution) -> coupling | nothing

Assemble a [`StructuralSizer.LinearCapacityCoupling`] that writes every steel
column group's governing axial demand as a linear function of all groups' section
areas via exact FE self-weight influence coefficients (see this file's header).
Returns `nothing` — signalling the caller to keep the ordinary ratchet — unless
the exact regime holds:

- the Asap model is solved and every column group has a positive current area;
- the full-load solve governs each group (no pattern cases), so `demands[i].Pu_c`
  matches the full-load axial this builder linearizes.

The returned coupling constrains every column group (`groups == 1:n`), with
`weight[g][s] = A(catalog[s])` (m²), `influence[i][g] = φ_{i,g}`,
`base[i] = Pu_c_i − Σ_g A_g_cur·φ_{i,g}`, and `cap[i][s]` the section's max axial
under its frozen moments. `optimize_discrete` still screens every candidate
against `base_i`, so the coupling only ADDS the self-consistent-load certification.
"""
function build_column_selfweight_coupling(
    struc::BuildingStructure,
    opts::StructuralSizer.SteelColumnOptions,
    group_ids, demands, geometries, catalog, material;
    resolution::Int = 200,
)
    model = struc.asap_model
    (model === nothing || !model.processed || isempty(model.frame_elements)) && return nothing
    n = length(group_ids)
    n == 0 && return nothing

    group_els = _column_group_frame_elements(struc, group_ids)
    all_els = Set{Int}()
    for els in group_els
        isempty(els) && return nothing      # a group with no frame elements ⇒ bail
        union!(all_els, els)
    end

    # Current per-group area (all elements of a group share one section). A group
    # with no positive area (no section yet) cannot be linearized this pass.
    area_cur = Vector{Float64}(undef, n)
    for g in 1:n
        A = _column_current_area(struc, first(group_els[g]))
        A > 0 || return nothing
        area_cur[g] = A
    end

    grav = _group_gravity_loads(model, all_els)
    element_loads = Asap.get_elemental_loads(model)
    links = struc.asap_rigid_links

    # Per-source per-unit-area displacement response Δu_g = K⁻¹ (f_g^cur / A_g_cur),
    # one cached-factor back-substitution per source column group.
    Δu = Vector{Vector{Float64}}(undef, n)
    for g in 1:n
        f_cur = _selfweight_nodal_load(model, grav, group_els[g])
        Δu[g] = Asap.linear_response(model, f_cur ./ area_cur[g]; links = links)
    end

    # Per-target governing station, influence row φ[i][·], and base.
    sources = [collect(1:n) for _ in 1:n]
    influence = Vector{Vector{Float64}}(undef, n)
    base = Vector{Float64}(undef, n)
    no_loads = Asap.AbstractLoad[]
    for i in 1:n
        Pu_c_i, el_star, idx = _governing_station(struc, group_els[i], element_loads;
                                                  resolution = resolution)
        el = model.frame_elements[el_star]
        φ = Vector{Float64}(undef, n)
        for g in 1:n
            # Stiffness-transmitted part: compression at the governing station from
            # the per-unit-area displacement response of source g (no member load ⇒
            # axial is constant along the element).
            σ = _axial_compression_at(el, Δu[g], no_loads, idx; resolution = resolution)
            # Self term adds the element's OWN self-weight member-load part (the
            # distributed-load particular solution the recovery integrates), per
            # unit area. `el_star ∈ group i`, so only g == i carries it.
            if g == i
                ld = get(grav, el_star, nothing)
                if ld !== nothing
                    m_dir = _axial_compression_at(el, zeros(model.nDOFs), [ld], idx;
                                                  resolution = resolution)
                    σ += m_dir / area_cur[i]
                end
            end
            φ[g] = σ
        end
        influence[i] = φ
        # base_i = Pu_c_i − Σ_g A_g_cur·φ_{i,g} (the x-independent part of the axial:
        # floor loads, beam self-weight, and any non-self-weight member load on el*).
        acc = 0.0
        for g in 1:n
            acc += area_cur[g] * φ[g]
        end
        base[i] = Pu_c_i - acc
    end

    # weight[g][s] = area (m²) of candidate section s for group g (shared catalog).
    n_sec = length(catalog)
    areas = Float64[ustrip(u"m^2", StructuralSizer.section_area(catalog[s])) for s in 1:n_sec]
    weight = [copy(areas) for _ in 1:n]

    # Per-group, per-section max-axial capacity under the frozen moments, inverting
    # the same AISC checker the solve screens and the loop verifies with.
    checker = StructuralSizer.AISCChecker(; max_depth = opts.max_depth)
    cache = StructuralSizer.create_cache(checker, n_sec)
    StructuralSizer.precompute_capacities!(checker, cache, catalog, material,
                                           StructuralSizer.MinVolume())
    cap = Vector{Vector{Float64}}(undef, n)
    for i in 1:n
        d = demands[i]
        geom = geometries[i]
        # A generous seed above the current demand speeds the bisection bracket.
        seed = max(demands[i].Pu_c, base[i], 1.0) * 2.0
        cap_i = Vector{Float64}(undef, n_sec)
        for s in 1:n_sec
            cap_i[s] = _max_axial_capacity(checker, cache, s, catalog[s], material, d, geom;
                                           seed = seed)
        end
        cap[i] = cap_i
    end

    return StructuralSizer.LinearCapacityCoupling(collect(1:n), sources, base, weight, cap,
                                                  influence)
end
