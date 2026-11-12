# Reserved `_analysis_caches` key for the last pattern-case solve. Not a slab
# index — `clear_geometry_caches!` drops it with the rest of the cache.
const _PATTERN_SOLVE_CACHE_KEY = 0

"""Fingerprint of frame-section K and GravityLoad occupancy.

Used to detect a stale `pattern_u` after `Asap.update!` / section change /
member self-weight (ACI 318-11 §13.7.6.3–13.7.6.4, corpus: aci-318-11, page 261).
"""
function _pattern_cache_token(struc::BuildingStructure)
    model = struc.asap_model
    (isnothing(model) || isempty(model.frame_elements)) && return UInt(0)
    h = zero(UInt)
    for el in model.frame_elements
        s = el.section
        h = hash((ustrip(u"m^4", s.Ix), ustrip(u"m^4", s.Iy), ustrip(u"m^2", s.A)), h)
    end
    n_g = count(ld -> ld isa Asap.GravityLoad, model.loads)
    return hash((h, n_g, length(model.loads)))
end

function _store_pattern_solve_cache!(struc::BuildingStructure, cases, u_cases)
    inner = get!(Dict{Symbol, Any}, struc._analysis_caches, _PATTERN_SOLVE_CACHE_KEY)
    inner[:pattern_cases] = cases
    inner[:pattern_u] = u_cases
    inner[:pattern_token] = _pattern_cache_token(struc)
    return
end

function _get_pattern_solve_cache(struc::BuildingStructure)
    inner = get(struc._analysis_caches, _PATTERN_SOLVE_CACHE_KEY, nothing)
    inner === nothing && return nothing
    cases = get(inner, :pattern_cases, nothing)
    u_cases = get(inner, :pattern_u, nothing)
    (cases === nothing || u_cases === nothing) && return nothing
    return (cases, u_cases)
end

function _pattern_cache_is_current(struc::BuildingStructure)
    inner = get(struc._analysis_caches, _PATTERN_SOLVE_CACHE_KEY, nothing)
    inner === nothing && return false
    token = get(inner, :pattern_token, nothing)
    token === nothing && return false
    return token === _pattern_cache_token(struc)
end

function _clear_pattern_solve_cache!(struc::BuildingStructure)
    inner = get(struc._analysis_caches, _PATTERN_SOLVE_CACHE_KEY, nothing)
    inner === nothing && return
    delete!(inner, :pattern_cases)
    delete!(inner, :pattern_u)
    delete!(inner, :pattern_token)
    return
end

"""
Rebuild pattern `(u, loads)` from the current K and GravityLoad set.

No-op when no pattern cache has been written. Call after `Asap.update!` /
`Asap.solve!` that changes stiffness or member self-weight so
`member_group_demands` (which prefers this cache) does not size from the
pre-change `pattern_u` (ACI 318-11 §13.7.6.3–13.7.6.4, corpus: aci-318-11,
page 261).
"""
function _refresh_pattern_solve_cache!(struc::BuildingStructure)
    inner = get(struc._analysis_caches, _PATTERN_SOLVE_CACHE_KEY, nothing)
    inner === nothing && return
    (haskey(inner, :pattern_cases) || haskey(inner, :pattern_u)) || return
    model = struc.asap_model
    (isnothing(model) || !model.processed) && return
    cases = _generate_pattern_cases(struc)
    if length(cases) <= 1
        _clear_pattern_solve_cache!(struc)
        return
    end
    u_cases = Asap.solve(model, cases)
    _store_pattern_solve_cache!(struc, cases, u_cases)
    # An unshored composite mesh keeps pattern dead load on the steel section.
    # AISC 360-22 Commentary §I3.1b (corpus: aisc-360-22, PDF p. 500).
    _recapture_unshored_pattern_dead!(struc)
    return
end

"""
Solve the Asap model with multiple pattern loading cases.

The full-loading displacement vector is kept in `model.u` for downstream
deflection checks and `node.displacement` queries (this function does not
overwrite `model.u` after the initial `solve!`).

Per-case displacements and loads are stored on `struc` so
`member_group_demands` can envelope signed M+/M− and shears at stations
(ACI 318-11 §13.7.6.3–13.7.6.4, corpus: aci-318-11, page 261). Sizing
must not read the per-DOF `element.forces` abs-envelope — that envelope is
non-concurrent and is retained only for existing `el.forces` consumers.
"""
function _solve_with_patterns!(struc::BuildingStructure, params::DesignParameters)
    model = struc.asap_model
    cases = _generate_pattern_cases(struc)
    
    if length(cases) <= 1
        _clear_pattern_solve_cache!(struc)
        Asap.solve!(model)
        return
    end
    
    # Full-loading solve (mutating) — sets model.u, node.displacement, element.forces
    Asap.solve!(model)
    
    # Multi-case solve (non-mutating) — reuses cached K factorization
    u_cases = Asap.solve(model, cases)
    _store_pattern_solve_cache!(struc, cases, u_cases)
    
    # Per-DOF abs envelope on el.forces (NOT used for member sizing; see
    # member_group_demands). Kept so existing el.forces readers stay valid.
    n_el = length(model.frame_elements)
    n_el == 0 && return
    
    for el in model.frame_elements
        gid = el.globalID
        best_forces = copy(el.forces)  # start from full-loading forces
        
        for (case_idx, (u, loads)) in enumerate(zip(u_cases, cases))
            case_idx == 1 && continue  # case 1 is full loading (already in best_forces)
            
            # Compute element forces: R * (K * u_e + Q_e)
            u_e = u[gid]
            Q_e = _element_Q(el, loads)
            forces_i = el.R * (el.K * u_e + Q_e)
            
            # Keep the value with larger absolute magnitude at each DOF
            for k in eachindex(forces_i)
                if abs(forces_i[k]) > abs(best_forces[k])
                    best_forces[k] = forces_i[k]
                end
            end
        end
        
        el.forces = best_forces
    end
end

"""
Compute the fixed-end force vector Q for an element from a given load set.
Returns the accumulated `R' * q(load)` for all loads attached to this element.
"""
function _element_Q(el::Asap.Element, loads::Vector{<:Asap.AbstractLoad})
    Q = zeros(length(el.globalID))
    for load in loads
        load isa Asap.ElementLoad || continue
        load.element === el || continue
        Q .+= el.R' * Asap.q(load)
    end
    return Q
end

"""Check whether pattern loading should actually run (`:auto` skips if L/D ≤ 0.75)."""
function _should_run_patterns(struc::BuildingStructure, params::DesignParameters)
    params.pattern_loading == :checkerboard && return true
    # :auto — skip if L/D ≤ 0.75 for ALL non-grade cells (ACI 318-11 §13.7.6.2)
    for cell in struc.cells
        cell.floor_type == :grade && continue
        D = ustrip(u"Pa", cell.sdl + cell.self_weight)
        D < 1e-12 && continue
        L = ustrip(u"Pa", cell.live_load)
        L / D > 0.75 && return true
    end
    return false
end

"""Dead-load factor already baked into `cell_dead_loads` (ACI 318-11 §9.2.1)."""
function _pattern_dead_factor(struc::BuildingStructure)
    for (ci, cell) in enumerate(struc.cells)
        dls = get(struc.cell_dead_loads, ci, nothing)
        (dls === nothing || isempty(dls)) && continue
        unfact = cell.sdl + cell.self_weight
        iszero(ustrip(unfact)) && continue
        p = first(dls).pressure
        return Float64(ustrip(uconvert(unit(unfact), p) / unfact))
    end
    return 1.0
end

"""
Dead factor for wall self-weight.

Pattern solves store slab dead as `combo.D * D`. The single gravity solve
stores an envelope. Wall weight uses that same choice: `combo.D` when the
dead and live tributaries are split, and the dead-only envelope otherwise.
The envelope of a pure dead load is the largest `D` factor in the set.
"""
function _wall_self_weight_dead_factor(params::DesignParameters; patterned::Bool)
    patterned && return Float64(governing_combo(params).D)
    combos = params.load_combinations
    isempty(combos) && throw(ArgumentError(
        "wall self-weight: load_combinations is empty, so the dead factor " *
        "cannot be taken from the envelope."))
    return ustrip(u"Pa", envelope_pressure(combos, 1.0u"Pa", 0.0u"Pa"))
end

"""Append wall-triangle self-weight, factored as dead load."""
function _append_factored_wall_self_weight!(loads, shells, params::DesignParameters;
                                           patterned::Bool)
    factor = _wall_self_weight_dead_factor(params; patterned)
    for ld in wall_self_weight_loads(shells)
        ld.pressure = factor * ld.pressure
        push!(loads, ld)
    end
    return loads
end

"""Rewrite `:wall_self_weight` pressures from the shells and the current dead factor."""
function _sync_wall_self_weight!(struc::BuildingStructure, params::DesignParameters)
    model = struc.asap_model
    isnothing(model) && return
    patterned = params.pattern_loading != :none &&
                !isempty(struc.cell_dead_loads) &&
                any(!isempty, values(struc.cell_dead_loads))
    factor = _wall_self_weight_dead_factor(params; patterned)
    for ld in model.loads
        (ld isa Asap.AreaLoad && ld.id === :wall_self_weight) || continue
        isempty(ld.shells) && continue
        ld.pressure = factor * unfactored_wall_self_weight_pressure(first(ld.shells))
    end
    return
end

"""
Copy one factored tributary live load at three-quarters pressure.

ACI 318-11 §13.7.6.3 permits three-quarters of the full factored live load
on the existing alternate-span cases (corpus: aci-318-11, page 261). Stored
`cell_live_loads` are already full factored live (`combo.L * live`). This
copy multiplies that pressure by 3/4 and does not mutate the stored load.
§13.7.6.4 (same page) keeps the full-load case unscaled.
"""
function _pattern_alternate_live(ld::Asap.TributaryLoad)
    # ACI 318-11 §13.7.6.3 — three-quarters of the full factored live load
    # (corpus: aci-318-11, page 261).
    Asap.TributaryLoad(ld.element, copy(ld.positions), ld.widths,
                       0.75 * ld.pressure, ld.direction, ld.id)
end

"""
Generate pattern loading cases from the dead/live tributary load dicts.

Returns a vector of load vectors:
1. Full loading (dead + all live) — unscaled, ACI 318-11 §13.7.6.4
2. Checkerboard A (dead + 3/4 live on "even" cells) — ACI 318-11 §13.7.6.3
3. Checkerboard B (dead + 3/4 live on "odd" cells) — ACI 318-11 §13.7.6.3

Alternate-span layout is unchanged. Only the patterned live pressure is
reduced. Dead load and member self-weight are not scaled.
"""
function _generate_pattern_cases(struc::BuildingStructure)
    dead_all = Asap.AbstractLoad[]
    sizehint!(dead_all, sum(length(v) for (_, v) in struc.cell_dead_loads; init=0))
    live_all = Asap.AbstractLoad[]
    sizehint!(live_all, sum(length(v) for (_, v) in struc.cell_live_loads; init=0))
    for (_, loads) in struc.cell_dead_loads
        append!(dead_all, loads)
    end
    for (_, loads) in struc.cell_live_loads
        append!(live_all, loads)
    end
    
    # Full loading
    case_full = Asap.AbstractLoad[dead_all; live_all]
    
    # Recomputed each call: it depends on `struc.cells` as well as the
    # skeleton, and it is linear in the cell count.
    set_a, set_b = _checkerboard_partition(struc)
    
    live_a = Asap.TributaryLoad[]
    live_b = Asap.TributaryLoad[]
    for ci in set_a
        append!(live_a, get(struc.cell_live_loads, ci, Asap.TributaryLoad[]))
    end
    for ci in set_b
        append!(live_b, get(struc.cell_live_loads, ci, Asap.TributaryLoad[]))
    end

    # ACI 318-11 §13.7.6.3 — three-quarters of the full factored live load on
    # the existing alternate-span cases (corpus: aci-318-11, page 261).
    # case_full above stays at full factored live (§13.7.6.4, same page).
    live_a_pat = Asap.AbstractLoad[_pattern_alternate_live(ld) for ld in live_a]
    live_b_pat = Asap.AbstractLoad[_pattern_alternate_live(ld) for ld in live_b]

    case_a = Asap.AbstractLoad[dead_all; live_a_pat]
    case_b = Asap.AbstractLoad[dead_all; live_b_pat]

    # Member self-weight is not in the cell tributary dicts. Include every
    # Asap.GravityLoad on the model so a section change that updates ρA
    # (and K) is visible in pattern u (ACI 318-11 §13.7.6.3–13.7.6.4,
    # corpus: aci-318-11, page 261).
    # cell_dead_loads are already factored (combo.D, ACI 318-11 §9.2.1,
    # corpus: aci-318-11, page 123). GravityLoad.factor is g (unfactored ρAg).
    # Scale copies so pattern cases do not mix unfactored self-weight with
    # factored cell dead loads.
    model = struc.asap_model
    if !isnothing(model)
        gloads_raw = [ld for ld in model.loads if ld isa Asap.GravityLoad]
        if !isempty(gloads_raw)
            Df = _pattern_dead_factor(struc)
            gloads = Asap.AbstractLoad[Asap.GravityLoad(ld.element, Df * ld.factor)
                                      for ld in gloads_raw]
            case_full = Asap.AbstractLoad[case_full; gloads]
            case_a = Asap.AbstractLoad[case_a; gloads]
            case_b = Asap.AbstractLoad[case_b; gloads]
        end
        # Wall self-weight is already multiplied by the dead factor. It stays
        # with dead in every pattern case. It is not a live load.
        wsw = Asap.AbstractLoad[ld for ld in model.loads
                                if ld isa Asap.AreaLoad && ld.id === :wall_self_weight]
        if !isempty(wsw)
            case_full = Asap.AbstractLoad[case_full; wsw]
            case_a = Asap.AbstractLoad[case_a; wsw]
            case_b = Asap.AbstractLoad[case_b; wsw]
        end
        # Façade line loads are already multiplied by the dead factor. They
        # stay with dead in every pattern case. They are not a live load.
        clad = Asap.AbstractLoad[ld for ld in model.loads
                                 if ld isa Asap.LineLoad && ld.id === :cladding]
        if !isempty(clad)
            case_full = Asap.AbstractLoad[case_full; clad]
            case_a = Asap.AbstractLoad[case_a; clad]
            case_b = Asap.AbstractLoad[case_b; clad]
        end
    end
    
    return [case_full, case_a, case_b]
end

"""
Partition non-grade cells into two checkerboard sets based on centroid parity.

For regular rectangular grids this produces the classic checkerboard. For
irregular layouts the partition is approximate but still provides useful
pattern coverage.
"""
function _checkerboard_partition(struc::BuildingStructure)
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    
    # Collect cell centroids (x, y) and floor elevations
    centroids = Dict{Int, NTuple{3, Float64}}()
    for (cell_idx, cell) in enumerate(struc.cells)
        cell.floor_type == :grade && continue
        vis = skel.face_vertex_indices[cell.face_idx]
        isempty(vis) && continue
        cx = sum(vc[v, 1] for v in vis) / length(vis)
        cy = sum(vc[v, 2] for v in vis) / length(vis)
        cz = sum(vc[v, 3] for v in vis) / length(vis)
        centroids[cell_idx] = (cx, cy, cz)
    end
    
    isempty(centroids) && return (Int[], Int[])
    
    # Find minimum grid spacings in x and y (from unique sorted centroid values)
    xs = sort(unique(round(c[1], digits=4) for c in values(centroids)))
    ys = sort(unique(round(c[2], digits=4) for c in values(centroids)))
    
    dx = length(xs) > 1 ? minimum(diff(xs)) : 1.0
    dy = length(ys) > 1 ? minimum(diff(ys)) : 1.0
    dx = max(dx, 1e-6)
    dy = max(dy, 1e-6)
    
    # Assign parity: floor to grid indices, sum, check even/odd
    # (floor avoids banker's rounding which maps 0.5 and 1.5 to the same parity)
    x0 = minimum(c[1] for c in values(centroids))
    y0 = minimum(c[2] for c in values(centroids))
    set_a = Int[]
    set_b = Int[]
    for (ci, (cx, cy, _)) in centroids
        ix = floor(Int, (cx - x0 + 0.5dx) / dx)
        iy = floor(Int, (cy - y0 + 0.5dy) / dy)
        if iseven(ix + iy)
            push!(set_a, ci)
        else
            push!(set_b, ci)
        end
    end
    
    return (set_a, set_b)
end

# update_slab_loads! and update_all_slab_loads! removed — use sync_asap!(struc; params) instead.
