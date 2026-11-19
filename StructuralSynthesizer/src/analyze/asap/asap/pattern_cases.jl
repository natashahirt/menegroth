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
    u_cases = Asap.solve(model, cases, struc.asap_rigid_links)
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
        _solve_struc_model!(struc)
        return
    end
    
    # Full-loading solve (mutating) — sets model.u, node.displacement, element.forces
    _solve_struc_model!(struc)
    
    # Multi-case solve (non-mutating) — reuses cached K factorization
    u_cases = Asap.solve(model, cases, struc.asap_rigid_links)
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

"""
    member_self_weight_acceleration(params) -> Acceleration

Acceleration on every frame `GravityLoad` of the building model: `D·g`,
with `D` the dead factor of `governing_combo(params)`. Member self-weight is
dead load `D` in ACI 318-11 Eq. (9-1) through (9-7) (§9.2.1; corpus:
aci-318-11, page 123). The pattern cases store slab dead load at the same
factor.

Loads for unfactored cases (service reactions, gravity basic cases, ELF
seismic weight) use [`unfactored_gravity_load`](@ref) copies.
"""
member_self_weight_acceleration(params::DesignParameters) =
    uconvert(u"m/s^2", Float64(governing_combo(params).D) * GRAVITY)

"""Copy of a member self-weight load at `g` (unfactored `ρ A g`)."""
unfactored_gravity_load(ld::Asap.GravityLoad) = Asap.GravityLoad(ld.element, GRAVITY, ld.id)

"""Set every frame `GravityLoad` on the model to [`member_self_weight_acceleration`](@ref)."""
function _sync_member_self_weight!(struc::BuildingStructure, params::DesignParameters)
    model = struc.asap_model
    isnothing(model) && return
    a = member_self_weight_acceleration(params)
    for ld in model.loads
        ld isa Asap.GravityLoad && (ld.factor = a)
    end
    return
end

"""
Dead factor for wall and drop-panel self-weight.

Pattern solves store slab dead as `combo.D * D`. The single gravity solve
stores an envelope. These weights use that same choice: `combo.D` when the
dead and live tributaries are split, and the dead-only envelope otherwise.
The envelope of a pure dead load is the largest `D` factor in the set.
"""
function _self_weight_dead_factor(params::DesignParameters; patterned::Bool)
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
    factor = _self_weight_dead_factor(params; patterned)
    for ld in wall_self_weight_loads(shells)
        ld.pressure = factor * ld.pressure
        push!(loads, ld)
    end
    return loads
end

"""True when the model's slab dead and live tributaries are stored split (pattern solve)."""
function _pattern_dead_split(struc::BuildingStructure, params::DesignParameters)
    params.pattern_loading != :none || return false
    any(!isempty, values(struc.cell_dead_loads)) && return true
    layout = flat_plate_shell_layout(struc)
    return layout !== nothing && layout.split
end

"""Rewrite `:wall_self_weight` pressures from the shells and the current dead factor."""
function _sync_wall_self_weight!(struc::BuildingStructure, params::DesignParameters)
    model = struc.asap_model
    isnothing(model) && return
    factor = _self_weight_dead_factor(params; patterned=_pattern_dead_split(struc, params))
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
on the two-way alternate-panel cases (corpus: aci-318-11, page 261). Stored
`cell_live_loads` are already full factored live (`combo.L * live`). This
copy multiplies that pressure by 3/4 and does not mutate the stored load.
§13.7.6.4 (same page) keeps the full-load case unscaled.

Beams and one-way slabs do not use this factor. ACI 318-19 §6.4.2 (corpus:
aci-318-19, page 75) puts the full factored live load on alternate spans and
on adjacent spans. §6.4.3 leaves two-way systems on their own rule.
"""
function _pattern_alternate_live(ld::Asap.TributaryLoad)
    # ACI 318-11 §13.7.6.3 — three-quarters of the full factored live load
    # (corpus: aci-318-11, page 261). Two-way panels only.
    Asap.TributaryLoad(ld.element, copy(ld.positions), ld.widths,
                       0.75 * ld.pressure, ld.direction, ld.id)
end

# Same §13.7.6.3 factor on a flat-plate panel's shell pressure.
_pattern_alternate_live(ld::Asap.AreaLoad) =
    Asap.AreaLoad(ld.shells, 0.75 * ld.pressure; direction = ld.direction, id = ld.id)

const _TWO_WAY_PATTERN_FLOORS = (:two_way, :flat_plate, :flat_slab, :waffle)

"""Cell centroids of the floors that take a live-load pattern. Grade and vault cells are omitted."""
function _pattern_cell_points(struc::BuildingStructure)
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    pts = NamedTuple{(:ci, :x, :y, :z, :two_way), Tuple{Int, Float64, Float64, Float64, Bool}}[]
    for (ci, cell) in enumerate(struc.cells)
        cell.floor_type == :grade && continue
        cell.floor_type == :vault && continue
        vis = skel.face_vertex_indices[cell.face_idx]
        isempty(vis) && continue
        push!(pts, (
            ci = ci,
            x = sum(vc[v, 1] for v in vis) / length(vis),
            y = sum(vc[v, 2] for v in vis) / length(vis),
            z = sum(vc[v, 3] for v in vis) / length(vis),
            two_way = cell.floor_type in _TWO_WAY_PATTERN_FLOORS,
        ))
    end
    return pts
end

"""
Spans along one plan axis. Each line is a vector of spans, and each span is
the cell indices at that station. ACI 318-19 §6.4.2 (page 75) patterns a
line of spans, so X-spanning and Y-spanning lines are built separately.
"""
function _span_lines(pts, along::Symbol)
    groups = Dict{NTuple{2, Float64}, Vector{Int}}()
    for (i, p) in enumerate(pts)
        key = along == :x ?
            (round(p.y; digits=3), round(p.z; digits=3)) :
            (round(p.x; digits=3), round(p.z; digits=3))
        push!(get!(groups, key, Int[]), i)
    end
    lines = Vector{Vector{Int}}[]
    for idxs in values(groups)
        xs = [along == :x ? pts[i].x : pts[i].y for i in idxs]
        stations = sort(unique(round.(xs; digits=3)))
        spans = [Int[] for _ in stations]
        for (i, x) in zip(idxs, xs)
            s = findfirst(==(round(x; digits=3)), stations)
            push!(spans[s], pts[i].ci)
        end
        push!(lines, spans)
    end
    return lines
end

"Live-load cell sets of §6.4.2: alternate spans, then each pair of adjacent spans. The all-loaded set is omitted."
function _section_642_cell_sets(lines)
    allcells = Int[]
    for line in lines
        for span in line
            append!(allcells, span)
        end
    end
    unique!(sort!(allcells))
    sets = Vector{Int}[]
    function consider!(cells)
        cells = unique(sort(cells))
        (isempty(cells) || cells == allcells) && return
        any(s -> s == cells, sets) && return
        push!(sets, cells)
    end
    for parity in 0:1
        cells = Int[]
        for line in lines
            for (s, span) in enumerate(line)
                (s % 2) == parity && append!(cells, span)
            end
        end
        consider!(cells)
    end
    maxn = maximum(length, lines; init=0)
    for j in 1:(maxn - 1)
        cells = Int[]
        for line in lines
            length(line) > j || continue
            append!(cells, line[j])
            append!(cells, line[j + 1])
        end
        consider!(cells)
    end
    return sets
end

"Stored live loads of `cells` (tributary and flat-plate shell), at full factored pressure."
function _cells_live(struc::BuildingStructure, cells)
    loads = Asap.AbstractLoad[]
    layout = flat_plate_shell_layout(struc)
    for ci in cells
        append!(loads, get(struc.cell_live_loads, ci, Asap.TributaryLoad[]))
        layout === nothing || haskey(layout.live, ci) && push!(loads, layout.live[ci])
    end
    return loads
end

"""
Generate pattern loading cases from the dead/live tributary load dicts.

1. Full loading (dead + all live), ACI 318-11 §13.7.6.4 and ACI 318-19 §6.4.3
2. Checkerboard of two-way cells at 3/4 live, ACI 318-11 §13.7.6.3
3. Beam and one-way arrangements at full live, ACI 318-19 §6.4.2:
   the span and alternate spans, and each pair of adjacent spans

Dead load, member self-weight, wall weight, fire coating, drop panels, and
vault thrust are on every case. Vault thrust is the factored line load
`:vault_thrust`; it is not a cell tributary and used to be dropped.
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
    fp = flat_plate_shell_layout(struc)
    if fp !== nothing && fp.split
        append!(dead_all, values(fp.dead))
        append!(live_all, values(fp.live))
    end
    
    # Full loading
    case_full = Asap.AbstractLoad[dead_all; live_all]
    
    # Two-way panels only. ACI 318-11 §13.7.6.3 (corpus: aci-318-11, page 261).
    # Beams and one-way spans are the §6.4.2 cases below, at full live.
    pts = _pattern_cell_points(struc)
    two_way = Set(p.ci for p in pts if p.two_way)
    set_a, set_b = _checkerboard_partition(struc)
    live_a = _cells_live(struc, filter(in(two_way), set_a))
    live_b = _cells_live(struc, filter(in(two_way), set_b))
    live_a_pat = Asap.AbstractLoad[_pattern_alternate_live(ld) for ld in live_a]
    live_b_pat = Asap.AbstractLoad[_pattern_alternate_live(ld) for ld in live_b]

    # ACI 318-19 §6.4.2 (corpus: aci-318-19, page 75): full factored live on
    # alternate spans, and on each pair of adjacent spans, along each plan axis.
    span_sets = Vector{Int}[]
    for along in (:x, :y)
        append!(span_sets, _section_642_cell_sets(_span_lines(pts, along)))
    end

    # Dead extras ride on every case. Vault thrust is already factored
    # (`dead * D + live * L`) and is not split, so the whole line load is kept.
    extras = Asap.AbstractLoad[]
    model = struc.asap_model
    if !isnothing(model)
        for ld in model.loads
            if ld isa Asap.GravityLoad
                push!(extras, Asap.GravityLoad(ld.element, ld.factor, ld.id))
            elseif (ld isa Asap.AreaLoad && ld.id === :wall_self_weight) ||
                   (ld isa Asap.LineLoad && ld.id === FIRE_COATING_LOAD_ID) ||
                   (ld isa Asap.NodeForce && ld.id === DROP_PANEL_LOAD_ID) ||
                   (ld isa Asap.LineLoad && ld.id === :vault_thrust)
                push!(extras, ld)
            end
        end
    end

    cases = Vector{Asap.AbstractLoad}[]
    push!(cases, Asap.AbstractLoad[case_full; extras])
    if !isempty(live_a_pat)
        push!(cases, Asap.AbstractLoad[dead_all; live_a_pat; extras])
    end
    if !isempty(live_b_pat)
        push!(cases, Asap.AbstractLoad[dead_all; live_b_pat; extras])
    end
    for cells in span_sets
        live = _cells_live(struc, cells)
        isempty(live) && continue
        push!(cases, Asap.AbstractLoad[dead_all; live; extras])
    end
    return cases
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
