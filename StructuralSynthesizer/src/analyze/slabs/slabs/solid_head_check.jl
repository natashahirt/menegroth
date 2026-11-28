# Punching on a solved rectangular rib grillage.
#
# The frame is [`analyze_rectangle_grillage`](@ref). Each corner is a column
# support: the upward reaction is the shear the floor delivers, and the
# rotation is released, so the unbalanced moment is zero. ACI 318-11
# §11.11.1.2 (corpus: aci-318-11, page 200) places one section at d/2 from
# the column, through the solid head, and another at d/2 from the head face.
# §11.1.3.1 (page 166) places the rib's one-way shear at d from that face.
#
# This checks the head at the size already cut into the frame. Growth is
# [`resolve_arrangement_heads`](@ref), on the rib bays.

"""Index `(i, j)` of rib-network node `node`. `i` runs fastest."""
function _grillage_node_ij(node::Int, nξ::Int)
    nx = nξ + 1
    z = node - 1
    return (z % nx, z ÷ nx)
end

"""`(ξ side, η side)` of the corner head that owns grid point `(i, j)`."""
function _grillage_corner_key(i::Int, j::Int, nξ::Int, nη::Int, solid_head::Float64)
    ξ = i / nξ
    η = j / nη
    ξs = ξ <= solid_head + 1e-8 ? 0 : ξ >= 1 - solid_head - 1e-8 ? 1 : nothing
    ηs = η <= solid_head + 1e-8 ? 0 : η >= 1 - solid_head - 1e-8 ? 1 : nothing
    (ξs === nothing || ηs === nothing) && return nothing
    return (ξs, ηs)
end

"""Element length in metres, from the solved length or the node positions."""
function _element_length_m(el)
    L = el.length
    Lm = L isa Unitful.Quantity ? ustrip(u"m", L) : Float64(L)
    Lm > 1e-12 && return Lm
    a, b = el.nodeStart.position, el.nodeEnd.position
    return hypot(ustrip(u"m", b[1] - a[1]), ustrip(u"m", b[2] - a[2]),
                 ustrip(u"m", b[3] - a[3]))
end

"""
Global vertical component of the internal shear, in newtons.

Positive is global +Z. The rib's local axes decide which of `Vy` and `Vz`
is vertical; a new frame element rolls π/2, which puts global Z in local y.
"""
function _vertical_shear_N(el, loads, x_m::Float64)
    L = _element_length_m(el)
    L > 0 || throw(ArgumentError("a rib piece has no length"))
    (-1e-9 <= x_m <= L + 1e-9) || throw(ArgumentError(
        "shear is asked for at $x_m m on a rib $L m long"))
    x = clamp(x_m, 0.0, L)
    n = max(8, ceil(Int, L / 0.025) + 1)
    fd = Asap.ElementForceAndDisplacement(el, loads; resolution = n)
    xs = fd.forces.x
    length(xs) >= 2 || throw(ArgumentError("the rib shear diagram needs two stations"))
    xs_m = xs[1] isa Unitful.Quantity ? [ustrip(u"m", v) for v in xs] : xs
    i = clamp(searchsortedlast(xs_m, x), 1, length(xs_m) - 1)
    denom = xs_m[i + 1] - xs_m[i]
    t = denom == 0 ? 0.0 : (x - xs_m[i]) / denom
    Vy = (1 - t) * fd.forces.Vy[i] + t * fd.forces.Vy[i + 1]
    Vz = (1 - t) * fd.forces.Vz[i] + t * fd.forces.Vz[i + 1]
    ly, lz = el.LCS[2], el.LCS[3]
    (length(ly) == 3 && length(lz) == 3) || throw(ArgumentError("the rib has no local axes"))
    return Vy * ly[3] + Vz * lz[3]
end

"""Solved node at plan `(x, y)`, in metres."""
function _grillage_node_at(model, x::Float64, y::Float64)
    for node in model.nodes
        px = ustrip(u"m", node.position[1])
        py = ustrip(u"m", node.position[2])
        hypot(px - x, py - y) <= 1e-6 && return node
    end
    throw(ArgumentError("no grillage node at ($x, $y) m"))
end

"""Upward support reaction. A downward reaction is refused."""
function _upward_reaction(node)
    rx = node.reaction
    (rx isa AbstractVector && length(rx) >= 3) || throw(ArgumentError(
        "the corner support has no vertical reaction"))
    Vu = uconvert(u"N", rx[3])
    Vu < -1.0u"N" && throw(ArgumentError(
        "the corner reaction is the upward force on the joint, got $Vu"))
    return max(Vu, zero(Vu))
end

"""Loads on one solved frame element."""
function _element_loads(load_map, el)
    id = el.elementID
    (1 <= id <= length(load_map)) || throw(ArgumentError(
        "rib element $id is outside the solved load map"))
    return load_map[id]
end

"""
Absolute vertical shear delivered to `node` by every rib that frames into it.

Two edge ribs meet a corner of this grid. Their end shears are the support
reaction when the joint is in equilibrium.
"""
function _support_shear(model, node, load_map)
    nx = ustrip(u"m", node.position[1])
    ny = ustrip(u"m", node.position[2])
    total = 0.0
    n_meet = 0
    for el in model.frame_elements
        function here(p)
            hypot(ustrip(u"m", p[1]) - nx, ustrip(u"m", p[2]) - ny) <= 1e-6
        end
        on_start = here(el.nodeStart.position)
        on_end = here(el.nodeEnd.position)
        (on_start || on_end) || continue
        L = _element_length_m(el)
        x = on_start ? 0.0 : L
        total += abs(_vertical_shear_N(el, _element_loads(load_map, el), x))
        n_meet += 1
    end
    n_meet > 0 || throw(ArgumentError("no rib frames into the corner support"))
    return total * u"N"
end

"""
Paths of the rib pieces outside each corner head, walked away from the face.

Each path is `(piece index, from the start node)`. The first step begins at
the head face.
"""
function _ribs_leaving_head(pieces, nξ::Int, nη::Int, solid_head::Float64)
    paths = Dict{NTuple{2, Int}, Vector{Vector{Tuple{Int, Bool}}}}(
        (0, 0) => [], (1, 0) => [], (0, 1) => [], (1, 1) => [])
    i = 1
    n = length(pieces)
    while i <= n
        j = i
        while j < n && pieces[j + 1].rib == pieces[i].rib
            j += 1
        end
        for k in i:(j - 1)
            left, right = pieces[k], pieces[k + 1]
            left.solid == right.solid && continue
            left.b == right.a || throw(ArgumentError(
                "two pieces of one rib do not share their node"))
            if left.solid
                start, step = k + 1, 1
            else
                start, step = k, -1
            end
            path = Tuple{Int, Bool}[]
            t = start
            while i <= t <= j && !pieces[t].solid
                push!(path, (t, step == 1))
                t += step
            end
            isempty(path) && throw(ArgumentError(
                "a rib leaves the solid head with no piece outside it"))
            key = _grillage_corner_key(_grillage_node_ij(left.b, nξ)..., nξ, nη, solid_head)
            key === nothing && throw(ArgumentError(
                "a solid-head transition is not on a corner head"))
            push!(paths[key], path)
        end
        i = j + 1
    end
    return paths
end

"""Absolute vertical shear at `distance_m` from the head face, along `path`."""
function _shear_from_face(path, elements, load_map, distance_m::Float64)
    distance_m >= 0 || throw(ArgumentError(
        "the distance from the head face is not negative, got $distance_m m"))
    remaining = distance_m
    for (idx, from_start) in path
        el = elements[idx]
        L = _element_length_m(el)
        L > 0 || throw(ArgumentError("a rib piece outside the head has no length"))
        if remaining <= L + 1e-9
            x = from_start ? min(remaining, L) : max(L - remaining, 0.0)
            return abs(_vertical_shear_N(el, _element_loads(load_map, el), x)) * u"N"
        end
        remaining -= L
    end
    throw(ArgumentError(
        "the section $(distance_m) m from the head face falls past the rib"))
end

"""
Hogging moment at `distance_m` from the head face, along `path`.

The sign is [`_asap_signed_My_envelopes`](@ref): local `My`, with the sign of
local y's vertical component, and hogging the opposite of sagging. A rib
whose local y is horizontal returns zero. Sagging returns zero.
"""
function _hogging_from_face(path, elements, load_map, distance_m::Float64)
    distance_m >= 0 || throw(ArgumentError(
        "the distance from the head face is not negative, got $distance_m m"))
    remaining = distance_m
    for (idx, from_start) in path
        el = elements[idx]
        L = _element_length_m(el)
        L > 0 || throw(ArgumentError("a rib piece outside the head has no length"))
        if remaining <= L + 1e-9
            x = from_start ? min(remaining, L) : max(L - remaining, 0.0)
            return _hogging_N_m(el, _element_loads(load_map, el), x) * u"N*m"
        end
        remaining -= L
    end
    throw(ArgumentError(
        "the section $(distance_m) m from the head face falls past the rib"))
end

"""Hogging moment (N·m) at `x_m` on one rib element. See `_hogging_from_face`."""
function _hogging_N_m(el, loads, x_m::Float64)
    L = _element_length_m(el)
    L > 0 || throw(ArgumentError("a rib piece has no length"))
    x = clamp(x_m, 0.0, L)
    n = max(8, ceil(Int, L / 0.025) + 1)
    fd = Asap.ElementForceAndDisplacement(el, loads; resolution = n)
    xs = fd.forces.x
    xs_m = xs[1] isa Unitful.Quantity ? [ustrip(u"m", v) for v in xs] : xs
    i = clamp(searchsortedlast(xs_m, x), 1, length(xs_m) - 1)
    denom = xs_m[i + 1] - xs_m[i]
    t = denom == 0 ? 0.0 : (x - xs_m[i]) / denom
    My0 = (1 - t) * fd.forces.My[i] + t * fd.forces.My[i + 1]
    My = My0 isa Unitful.Quantity ? ustrip(u"N*m", My0) : My0
    ly_z = el.LCS[2][3]
    abs(ly_z) < 1e-8 && return 0.0
    s = ly_z > 0 ? 1.0 : -1.0
    return max(0.0, -My * s)
end

"""
    check_rectangle_grillage_heads(solved; Lx, Ly, nξ, nη, solid_head,
                                   column_x, column_y, d_head, h_head,
                                   bw, d_rib, h_rib, concrete, qu, topping)
        -> Vector{NamedTuple}

Column punching, rib-web punching, and one-way rib shear at each corner.

`solved` is [`analyze_rectangle_grillage`](@ref) for one rectangular panel,
so every support is a corner. `Vu` is the upward reaction. `qu` is the
factored panel pressure already on that frame; the load inside the outer
section is subtracted. The equivalent thickness is the smaller of the two
rib directions: one web per module the head covers, over that head width
(spSlab Eq. 2-14). One-way shear is read at `d_rib` from the head face.

`topping` classifies the head ([`classify_solid_head`](@ref)). Without it
the classification is `nothing`.

The corner rotation is released, so `Mub` is zero. Eccentric shear on the
rib-web section stays off, and the joist increase is not applied: no joist
is passed until the rib is known to meet §8.13.
"""
function check_rectangle_grillage_heads(solved;
        Lx::Real, Ly::Real, nξ::Integer, nη::Integer, solid_head::Real,
        column_x::Length, column_y::Length,
        d_head::Length, h_head::Length,
        bw::Length, d_rib::Length, h_rib::Length,
        concrete::StructuralSizer.Concrete,
        qu::Pressure,
        topping::Union{Nothing, Length} = nothing,
        fy::Union{Nothing, Pressure} = nothing)
    (Lx > 0 && Ly > 0) || throw(ArgumentError(
        "a rib panel needs positive sides, got $Lx by $Ly"))
    (nξ >= 1 && nη >= 1) || throw(ArgumentError(
        "a rib grid needs at least one bay each way, got $nξ by $nη"))
    column_x > zero(column_x) && column_y > zero(column_y) || throw(ArgumentError(
        "the column is positive in both directions, got $column_x by $column_y"))
    h_head > zero(h_head) || throw(ArgumentError("the solid head depth is positive, got $h_head"))
    zero(d_head) < d_head <= h_head || throw(ArgumentError(
        "the head's effective depth is positive and within the head, got $d_head in $h_head"))
    bw > zero(bw) || throw(ArgumentError("the rib web is positive, got $bw"))
    h_rib > zero(h_rib) || throw(ArgumentError("the rib depth is positive, got $h_rib"))
    zero(d_rib) < d_rib <= h_rib || throw(ArgumentError(
        "the rib's effective depth is positive and within the rib, got $d_rib in $h_rib"))
    qu >= zero(qu) || throw(ArgumentError("the factored panel pressure is not negative, got $qu"))
    if topping !== nothing
        topping > zero(topping) || throw(ArgumentError(
            "the topping thickness is positive, got $topping"))
        topping <= h_head || throw(ArgumentError(
            "the solid head is $h_head deep and the topping on it is $topping"))
    end
    pieces = solved.network.pieces
    elements = solved.model.frame_elements
    n_expected = nξ * (nη + 1) + nη * (nξ + 1)
    length(pieces) == n_expected || throw(ArgumentError(
        "the rib network is not an $nξ by $nη grid"))
    length(pieces) == length(elements) || throw(ArgumentError(
        "the solved frame and the rib network do not match"))
    any(p -> p.solid, pieces) || throw(ArgumentError("the grillage has no solid head"))
    s = Float64(solid_head)
    kξ = StructuralSizer.ribs_across_solid_head(nξ, s)
    kη = StructuralSizer.ribs_across_solid_head(nη, s)
    head_x = s * Lx * u"m"
    head_y = s * Ly * u"m"
    # One web per module. The thinner smear is the thickness the stress uses.
    area_ξ = kξ * bw * h_rib
    area_η = kη * bw * h_rib
    if area_ξ / head_x <= area_η / head_y
        web_area, head_width, web_direction = area_ξ, head_x, :ξ
    else
        web_area, head_width, web_direction = area_η, head_y, :η
    end
    section = StructuralSizer.rib_web_critical_section(head_x, head_y, d_head;
                                                       position = :corner)
    classification = topping === nothing ? nothing :
        StructuralSizer.classify_solid_head(;
            span_x = Lx * u"m", span_y = Ly * u"m",
            from_center_x = head_x, from_center_y = head_y,
            projection = h_head - topping, slab_thickness = topping,
            column_x = column_x, column_y = column_y)
    col = (position = :corner, c1 = column_x, c2 = column_y, shape = :rectangular)
    Mub = 0.0u"N" * u"m"
    moment_note = "This frame releases the corner rotation, so the unbalanced moment is zero."
    load_map = Asap.get_elemental_loads(solved.model)
    leaving = _ribs_leaving_head(pieces, Int(nξ), Int(nη), s)
    d_m = ustrip(u"m", d_rib)
    heads = NamedTuple[]
    for (ξs, ηs) in ((0, 0), (1, 0), (0, 1), (1, 1))
        paths = leaving[(ξs, ηs)]
        isempty(paths) && throw(ArgumentError(
            "corner ($ξs, $ηs) has no rib leaving the solid head"))
        node = _grillage_node_at(solved.model, ξs == 0 ? 0.0 : Float64(Lx),
                                 ηs == 0 ? 0.0 : Float64(Ly))
        Vu = _upward_reaction(node)
        ribs = NamedTuple[]
        for path in paths
            push!(ribs, (
                Vu = _shear_from_face(path, elements, load_map, d_m),
                bw = bw,
                d = d_rib,
                joist = nothing,
                at_face = _shear_from_face(path, elements, load_map, 0.0),
                Mu = _hogging_from_face(path, elements, load_map, 0.0),
                stem = let
                    depth = h_rib - something(topping, zero(h_rib))
                    depth >= zero(depth) || throw(ArgumentError(
                        "the topping is deeper than the rib, got $topping in $h_rib"))
                    depth
                end,
            ))
        end
        chk = StructuralSizer.check_solid_head_punching(
            col, Vu, Mub, d_head, h_head, concrete.fc′, ribs;
            b0 = section.b0, web_area = web_area, head_width = head_width,
            side_long = section.side_long, side_short = section.side_short,
            position = :corner, qu = qu, section_area = section.section_area,
            λ = concrete.λ, fy = fy)
        push!(heads, (
            corner = (ξs, ηs),
            Vu = Vu,
            Mub = Mub,
            moment_note = moment_note,
            classification = classification,
            support_shear = _support_shear(solved.model, node, load_map),
            web_direction = web_direction,
            ribs_ξ = kξ,
            ribs_η = kη,
            head_x = head_x,
            head_y = head_y,
            section = section,
            ribs_demand = ribs,
            check = chk,
        ))
    end
    return heads
end

"""Side lengths of a rectangular panel, in metres. A skewed panel is refused."""
function _rectangle_sides_m(panel)
    p00 = StructuralSizer.physical_coords(panel, 0.0, 0.0)
    p10 = StructuralSizer.physical_coords(panel, 1.0, 0.0)
    p11 = StructuralSizer.physical_coords(panel, 1.0, 1.0)
    p01 = StructuralSizer.physical_coords(panel, 0.0, 1.0)
    dist(a, b) = hypot(b[1] - a[1], b[2] - a[2])
    Lx = dist(p00, p10)
    Ly = dist(p00, p01)
    (Lx > 0 && Ly > 0) || throw(ArgumentError(
        "a rib panel needs positive sides, got $Lx by $Ly"))
    abs(Lx - dist(p01, p11)) <= 1e-4 && abs(Ly - dist(p10, p11)) <= 1e-4 ||
        throw(ArgumentError(
            "the solid-head check is one rectangle, and this panel's opposite sides differ"))
    ex = (p10[1] - p00[1], p10[2] - p00[2])
    ey = (p01[1] - p00[1], p01[2] - p00[2])
    abs(ex[1] * ey[1] + ex[2] * ey[2]) <= 1e-4 * Lx * Ly || throw(ArgumentError(
        "the solid-head check is one rectangle, and this panel is skewed"))
    return Lx, Ly
end

"""Web width, effective depth, and overall depth of a concrete rib."""
function _rib_web_dims(sec::StructuralSizer.RCTBeamSection)
    return (_as_metres(sec.bw), _as_metres(sec.d), _as_metres(sec.h))
end
function _rib_web_dims(sec::StructuralSizer.RCBeamSection)
    return (_as_metres(sec.b), _as_metres(sec.d), _as_metres(sec.h))
end
_rib_web_dims(::Any) = nothing

"""
Web the solid-head checks use, or `nothing` when no rib is sized yet.

ENGINEERING JUDGMENT: rib pieces are sized one by one, so they need not match.
The head's soffit is the deepest rib (`h`). The rib-web check uses the
narrowest web and the smallest effective depth, which is a section no larger
than every rib framing into the head. One shared section returns that section.
"""
function _sized_rib_web(struc, level::FramingLevel)
    gid = level.solid_group_id
    dims = Tuple{typeof(1.0u"m"), typeof(1.0u"m"), typeof(1.0u"m")}[]
    for bi in level_member_indices(struc, level)
        gid !== nothing && group_id(struc.beams[bi]) == gid && continue
        _level_rib(level, struc.beams[bi]) || continue
        sec = section(struc.beams[bi])
        sec === nothing && continue
        one = _rib_web_dims(sec)
        one === nothing && throw(ArgumentError(
            "slab $(level.slab_idx) has a solid head, and a sized rib is a $(typeof(sec))."))
        push!(dims, one)
    end
    isempty(dims) && return nothing
    return (minimum(d[1] for d in dims), minimum(d[2] for d in dims),
            maximum(d[3] for d in dims))
end

"""Columns whose vertex is within `tol` metres of `xy`."""
function _columns_at(struc, xy; tol::Float64 = 1e-2)
    hits = Any[]
    nvert = length(struc.skeleton.vertices)
    for col in struc.columns
        v = col.vertex_idx
        (v isa Integer && 1 <= v <= nvert) || continue
        p = _vertex_xy_m(struc.skeleton, v)
        hypot(p[1] - xy[1], p[2] - xy[2]) <= tol && push!(hits, col)
    end
    return hits
end

"""
Smallest column face among the four panel corners, in metres.

The rectangle check uses one column. The smaller face is the one that
check uses, so a larger column at another corner is not reported as the
smaller one's capacity.
"""
function _panel_column_size(struc, panel)
    cx = typeof(1.0u"m")[]
    cy = typeof(1.0u"m")[]
    for (ξ, η) in ((0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0))
        xy = StructuralSizer.physical_coords(panel, ξ, η)
        sized = Tuple{typeof(1.0u"m"), typeof(1.0u"m")}[]
        for col in _columns_at(struc, xy)
            (col.c1 === nothing || col.c2 === nothing) && continue
            push!(sized, (_as_metres(col.c1), _as_metres(col.c2)))
        end
        isempty(sized) && throw(ArgumentError(
            "a solid-head panel corner at $(xy) m has no sized column"))
        push!(cx, minimum(s[1] for s in sized))
        push!(cy, minimum(s[2] for s in sized))
    end
    return minimum(cx), minimum(cy)
end

"""Factored panel pressure, the envelope the grillage load uses."""
function _panel_factored_pressure(struc, slab, params)
    isempty(slab.cell_indices) && throw(ArgumentError("a grillage slab has no cells"))
    return maximum(uconvert(u"Pa", total_factored_pressure(
        struc.cells[ci], params.load_combinations)) for ci in slab.cell_indices)
end

"""Punching stress of a head check, in psi. One-way shear is a force, not this stress."""
function _head_punching_stress_psi(chk)
    psi = 0.0
    for part in (chk.column, chk.rib_web)
        hasproperty(part, :vu) || continue
        psi = max(psi, ustrip(u"psi", part.vu))
    end
    return psi
end

"""The resolver's report, or `nothing` when this level has no solid head."""
function _stored_solid_head_report(level)
    level.solid_head_report === nothing && return nothing
    pat = level.pattern
    pat isa IsoparametricPattern && pat.solid_head <= 0 && return nothing
    return level.solid_head_report
end

"""
    record_solid_head_punching!(result, struc, slab, params; frame = nothing) -> SlabDesignResult

Write the solid-head check onto `result` when this slab has one.

A level [`grow_building_solid_heads!`](@ref) has already resolved uses that
report. Otherwise `frame` is [`solid_head_frame_punching`](@ref) for the
whole building. When it covers this slab, the ratio is the worst column at
the slab's corners, with the frame's shear and unbalanced moments. A slab
with a solid head on sized ribs and neither check is an error: punching is
read only from the building model. A slab that already carries a punching
ratio keeps the worse of the two.
"""
function record_solid_head_punching!(result::SlabDesignResult, struc, slab, params;
                                     frame = nothing)
    level = _grillage_level(slab)
    report = level === nothing ? nothing : _stored_solid_head_report(level)
    if report !== nothing && !isempty(report.ratios)
        i = argmax(report.ratios)
        result.punching_max_ratio = max(result.punching_max_ratio, report.ratios[i])
        result.punching_ok = result.punching_ok && report.ok
        result.punching_vu_max_psi = max(result.punching_vu_max_psi, report.vu_psi)
        note = "Solid-head punching grew the bays around each column on the rib frame " *
               "($(report.steps) step(s), stop :$(report.stop)); governing $(report.governing[i])."
        result.analysis_status = isempty(result.analysis_status) ? note :
            result.analysis_status * " " * note
        if !result.punching_ok && isempty(result.failing_check)
            result.failing_check = "punching_shear_slab"
        end
        return result
    end
    slab_idx = findfirst(s -> s === slab, struc.slabs)
    cols = frame === nothing ? nothing : get(frame.by_slab, slab_idx, nothing)
    if cols !== nothing
        checks = [frame.joints[ci] for ci in unique(cols)]
        worst = checks[argmax([c.ratio for c in checks])]
        result.punching_max_ratio = max(result.punching_max_ratio, worst.ratio)
        result.punching_ok = result.punching_ok && all(c.ok for c in checks)
        result.punching_vu_max_psi = max(result.punching_vu_max_psi,
                                         maximum(c.vu_psi for c in checks))
        note = "Solid-head punching uses the building frame's column shear and " *
               "unbalanced moments over $(worst.n_cases) load case(s); governing " *
               "$(worst.governing) at a $(worst.position) column."
        result.analysis_status = isempty(result.analysis_status) ? note :
            result.analysis_status * " " * note
        if !result.punching_ok && isempty(result.failing_check)
            result.failing_check = "punching_shear_slab"
        end
        return result
    end
    # Punching is read only from the solved building model. A head with ribs
    # sized and neither a resolver report nor a frame check was never checked.
    level === nothing && return result
    pat = level.pattern
    has_head = !isempty(level.solid_heads) ||
               (pat isa IsoparametricPattern && pat.solid_head > 0)
    has_head || return result
    _sized_rib_depth(struc, level) === nothing && return result
    throw(ArgumentError(
        "slab $slab_idx has a solid head with sized ribs and no punching check from the " *
        "building model: the building frame was not solved, or no head check covered it"))
end
