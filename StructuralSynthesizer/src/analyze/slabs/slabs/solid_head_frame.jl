# Solid-head punching on the solved building frame.
#
# The rectangle check in `solid_head_check.jl` solves one panel with released
# corners: each column takes that panel's reaction and no moment. On the
# building frame a column takes the shear of every panel around it, and the
# column ends hold the moment the floor transfers. This file reads both from
# the column elements at the slab joint, for the full load and every pattern
# case, and checks the head that all adjacent panels form around the column.
#
# Sections, ACI 318-11 §11.11.1.2 (corpus: aci-318-11, page 200): d/2 from the
# column through the head, with γv Mu transferred by eccentric shear
# (§11.11.7.1, page 209), and d/2 from the head edge. One-way rib shear is at
# d from the head face (§11.1.3.1, page 166).

"""A length or a bare metre value, as a `Float64` in metres."""
_metres_value(x::Unitful.Quantity) = ustrip(u"m", x)
_metres_value(x::Real) = Float64(x)

"""Node position in metres."""
_node_xyz_m(node) = (_metres_value(node.position[1]), _metres_value(node.position[2]),
                     _metres_value(node.position[3]))

"""Loads on element `k` in a case load map, empty when the map does not reach it."""
_case_loads(load_map, el) = el.elementID <= length(load_map) ? load_map[el.elementID] :
                            Asap.AbstractLoad[]

"""
Head panels of every solid-head slab whose ribs are sized.

Each entry carries the panel, its rectangle axes, the head fraction, the sized
rib web, the concrete, the elevation, and the smallest factored dead pressure
on its cells. A slab whose ribs are not sized yet is skipped.
"""
function _solid_head_panels(struc, params)
    out = NamedTuple[]
    combo = governing_combo(params)
    for (si, slab) in enumerate(struc.slabs)
        level = _grillage_level(slab)
        level === nothing && continue
        pat = level.pattern
        (pat isa IsoparametricPattern && pat.solid_head > 0) || continue
        panel = _solid_head_panel(struc, slab)
        panel === nothing && throw(ArgumentError(
            "a solid head is checked on a quadrilateral panel, and slab $si is not one"))
        _sized_rib_depth(struc, level) === nothing && continue
        web = _sized_rib_web(struc, level)
        web === nothing && throw(ArgumentError(
            "slab $si has a sized rib depth and no rib section"))
        concrete = _solid_head_concrete(level)
        concrete === nothing && throw(ArgumentError(
            "slab $si has a solid head, and the framing level has no concrete"))
        Lx, Ly = _rectangle_sides_m(panel)
        p00 = StructuralSizer.physical_coords(panel, 0.0, 0.0)
        p10 = StructuralSizer.physical_coords(panel, 1.0, 0.0)
        p01 = StructuralSizer.physical_coords(panel, 0.0, 1.0)
        eξ = ((p10[1] - p00[1]) / Lx, (p10[2] - p00[2]) / Lx)
        eη = ((p01[1] - p00[1]) / Ly, (p01[2] - p00[2]) / Ly)
        q_dead = minimum(uconvert(u"Pa", combo.D * (struc.cells[ci].sdl + struc.cells[ci].self_weight))
                         for ci in slab.cell_indices)
        push!(out, (slab_idx = si, panel = panel, Lx = Lx, Ly = Ly, eξ = eξ, eη = eη,
                    nξ = pat.n_xi, nη = pat.n_eta, s = Float64(pat.solid_head),
                    bw = web[1], d = web[2], h = web[3], concrete = concrete,
                    z = _slab_face_z_m(struc, slab), q_dead = q_dead))
    end
    return out
end

"""
Panel corners at each joint, keyed by plan position and elevation rounded to
the millimetre. Each value lists `(panel entry, ξ side, η side)`.
"""
function _head_joints(panels)
    joints = Dict{NTuple{3, Int}, Vector{Tuple{NamedTuple, Int, Int}}}()
    for p in panels, (ξs, ηs) in ((0, 0), (1, 0), (0, 1), (1, 1))
        xy = StructuralSizer.physical_coords(p.panel, Float64(ξs), Float64(ηs))
        key = (round(Int, 1000 * xy[1]), round(Int, 1000 * xy[2]), round(Int, 1000 * p.z))
        push!(get!(joints, key, Tuple{NamedTuple, Int, Int}[]), (p, ξs, ηs))
    end
    return joints
end

"""
Plan geometry of the head that the panels at one joint form around the column.

The axes are the first panel's ξ direction `a` and `b` turned 90° from it.
Each panel takes one quadrant. Panels that share a side of the head must
agree on its extent and module count, so the head is one rectangle.
Four quadrants are `:interior`, two that share a side are `:edge`, and one
is `:corner`. A re-entrant or diagonal arrangement is refused.
"""
function _joint_head_geometry(corners)
    a = corners[1][1].eξ
    b = (-a[2], a[1])
    sides = Dict{Tuple{Symbol, Int}, NamedTuple}()
    quadrants = Set{NTuple{2, Int}}()
    function axis_of(v)
        da = v[1] * a[1] + v[2] * a[2]
        db = v[1] * b[1] + v[2] * b[2]
        abs(abs(da) - 1) <= 1e-6 && return (:a, da > 0 ? 1 : -1)
        abs(abs(db) - 1) <= 1e-6 && return (:b, db > 0 ? 1 : -1)
        throw(ArgumentError("solid-head panels at one column are not aligned"))
    end
    function add_side!(key, extent, k, p)
        side = (extent = extent, k = k, area = k * p.bw * p.h)
        old = get(sides, key, nothing)
        if old === nothing
            sides[key] = side
        elseif abs(old.extent - extent) > 1e-3 || old.k != k
            throw(ArgumentError(
                "solid-head panels at one column disagree on the head side $(key): " *
                "$(old.extent) m over $(old.k) modules and $extent m over $k"))
        end
    end
    for (p, ξs, ηs) in corners
        dξ = ξs == 0 ? p.eξ : (-p.eξ[1], -p.eξ[2])
        dη = ηs == 0 ? p.eη : (-p.eη[1], -p.eη[2])
        kξ_axis = axis_of(dξ)
        kη_axis = axis_of(dη)
        kξ_axis[1] == kη_axis[1] && throw(ArgumentError(
            "a solid-head panel's two directions fall on one axis"))
        add_side!(kξ_axis, p.s * p.Lx, StructuralSizer.ribs_across_solid_head(p.nξ, p.s), p)
        add_side!(kη_axis, p.s * p.Ly, StructuralSizer.ribs_across_solid_head(p.nη, p.s), p)
        qa = kξ_axis[1] == :a ? kξ_axis[2] : kη_axis[2]
        qb = kξ_axis[1] == :b ? kξ_axis[2] : kη_axis[2]
        (qa, qb) in quadrants && throw(ArgumentError(
            "two solid-head panels take the same quadrant of one column"))
        push!(quadrants, (qa, qb))
    end
    qs = collect(quadrants)
    nq = length(qs)
    if nq == 4
        position = :interior
    elseif nq == 1
        position = :corner
    elseif nq == 2 && (qs[1][1] == qs[2][1] || qs[1][2] == qs[2][2])
        position = :edge
    else
        throw(ArgumentError(
            "solid-head panels take $nq quadrants of one column in a shape this check does not cover"))
    end
    on(axis) = [v for (k, v) in sides if k[1] == axis]
    ext(axis) = sum(v.extent for v in on(axis))
    area(axis) = sum(v.area for v in on(axis))
    ext_a, ext_b = ext(:a) * u"m", ext(:b) * u"m"
    area_a, area_b = area(:a), area(:b)
    free_edge = nothing
    if position == :edge
        # The axis with both sides runs along the free edge.
        along_a = length(on(:a)) == 2
        free_edge = along_a ? a : b
        head_x, head_y = along_a ? (ext_b, ext_a) : (ext_a, ext_b)
    else
        head_x, head_y = ext_a, ext_b
    end
    web_area, head_width = area_a / ext_a <= area_b / ext_b ? (area_a, ext_a) : (area_b, ext_b)
    return (position = position, axis_a = a, head_x = head_x, head_y = head_y,
            web_area = web_area, head_width = head_width, free_edge = free_edge)
end

"""
Column elements with an end at `xyz`, as `(element index, joint at start, below)`.

`below` is true when the element's other end is lower. Each is checked to be
vertical, which is what lets the joint moments come from `K u` alone: a
column's self-weight is axial and has no fixed-end moment.
"""
function _joint_column_elements(struc, xyz; tol::Float64 = 1e-3)
    model = struc.asap_model
    hits = Tuple{Int, Bool, Bool, Int}[]
    for (ci, col) in enumerate(struc.columns), si in segment_indices(col)
        e = struc.segments[si].edge_idx
        e < 1 && continue
        for k in _frame_element_indices(struc, e)
            el = model.frame_elements[k]
            ps = _node_xyz_m(el.nodeStart)
            pe = _node_xyz_m(el.nodeEnd)
            at_start = all(abs(ps[i] - xyz[i]) <= tol for i in 1:3)
            at_end = all(abs(pe[i] - xyz[i]) <= tol for i in 1:3)
            (at_start || at_end) || continue
            abs(el.LCS[1][3]) >= 1 - 1e-6 || throw(ArgumentError(
                "column $ci at a solid head is not vertical"))
            other = at_start ? pe : ps
            push!(hits, (k, at_start, other[3] < xyz[3], ci))
        end
    end
    return hits
end

"""
Shear the floor delivers to the joint and the moment it transfers, for one case.

`Vu` is the compression in the columns below less the compression in the
columns above, at the joint. The moment is the sum of the column end moments
at the joint, in global axes; with no moment applied at the node, that is the
moment the floor transfers. Returns `(Vu, M)` with `M` the global `(x, y)`
components, in N and N·m.
"""
function _joint_case_demand(model, cols, u, load_map)
    Vu = 0.0
    M = [0.0, 0.0, 0.0]
    for (k, at_start, below, _) in cols
        el = model.frame_elements[k]
        loads = _case_loads(load_map, el)
        all(ld -> ld isa Asap.GravityLoad, loads) || throw(ArgumentError(
            "a column at a solid head carries a load other than its self weight, " *
            "so its end moment is not K u alone"))
        f = _element_forces_from_u(el, u, loads; resolution = 3)
        P = at_start ? f.P[1] : f.P[end]
        Vu += below ? -P : P
        Fe = el.K * u[el.globalID]
        M .+= at_start ? Fe[4:6] : Fe[10:12]
    end
    return Vu, (M[1], M[2])
end

"""Vertical shear (N) at `x_m` along `el` for displacements `u` and `loads`."""
function _vertical_shear_from_u(el, u, loads, x_m::Float64)
    L = Asap.ElementProps(el).L
    n = max(8, ceil(Int, L / 0.025) + 1)
    f = _element_forces_from_u(el, u, loads; resolution = n)
    xs = range(0.0, L, n)
    x = clamp(x_m, 0.0, L)
    i = clamp(searchsortedlast(xs, x), 1, n - 1)
    t = (x - xs[i]) / (xs[i + 1] - xs[i])
    Vy = (1 - t) * f.Vy[i] + t * f.Vy[i + 1]
    Vz = (1 - t) * f.Vz[i] + t * f.Vz[i + 1]
    return Vy * el.LCS[2][3] + Vz * el.LCS[3][3]
end

"""
Hogging moment (N·m) at `x_m` along `el`.

Same sign as [`_asap_signed_My_envelopes`](@ref): hogging is the opposite of
sagging on local `My`. A horizontal local y has no signed hogging there, and
this returns zero.
"""
function _hogging_from_u(el, u, loads, x_m::Float64)
    L = Asap.ElementProps(el).L
    n = max(8, ceil(Int, L / 0.025) + 1)
    f = _element_forces_from_u(el, u, loads; resolution = n)
    xs = range(0.0, L, n)
    x = clamp(x_m, 0.0, L)
    i = clamp(searchsortedlast(xs, x), 1, n - 1)
    t = (x - xs[i]) / (xs[i + 1] - xs[i])
    My = (1 - t) * f.My[i] + t * f.My[i + 1]
    ly_z = el.LCS[2][3]
    abs(ly_z) < 1e-8 && return 0.0
    s = ly_z > 0 ? 1.0 : -1.0
    return max(0.0, -My * s)
end

"""Hogging moment at `distance_m` from the head face along `path`, for one case."""
function _path_hogging(model, path, u, load_map, distance_m::Float64)
    remaining = distance_m
    for (k, from_start) in path
        el = model.frame_elements[k]
        L = Asap.ElementProps(el).L
        if remaining <= L + 1e-9
            x = from_start ? min(remaining, L) : max(L - remaining, 0.0)
            return _hogging_from_u(el, u, _case_loads(load_map, el), x) * u"N*m"
        end
        remaining -= L
    end
    throw(ArgumentError(
        "the section $(distance_m) m from the head face falls past the rib"))
end

"""
Concrete ribs leaving the head at one joint, each as `(path, bw, d, outward)`.

A rib leaves when one end of a frame element on the slab sits on the face of
a panel's corner head and its midpoint is outside that head. `path` walks
away from the face through collinear elements, as `(element index, from
start)`. A member that is not a concrete rib (a steel girder) is sized by its
own beam checks and is skipped here. An unsized one is refused.
"""
function _ribs_leaving_joint(struc, corners, z, element_beam)
    model = struc.asap_model
    tol = 1e-3
    flat = Int[]
    adj = Dict{UInt, Vector{Int}}()
    for (k, el) in enumerate(model.frame_elements)
        ps, pe = _node_xyz_m(el.nodeStart), _node_xyz_m(el.nodeEnd)
        (abs(ps[3] - z) <= tol && abs(pe[3] - z) <= tol) || continue
        push!(flat, k)
        push!(get!(adj, objectid(el.nodeStart), Int[]), k)
        push!(get!(adj, objectid(el.nodeEnd), Int[]), k)
    end
    leaving = Dict{Int, NamedTuple}()
    for (p, ξs, ηs) in corners
        ptol = 1e-4
        ξf = ξs == 0 ? p.s : 1 - p.s
        ηf = ηs == 0 ? p.s : 1 - p.s
        in_ξ(ξ, t) = ξs == 0 ? ξ <= p.s + t : ξ >= 1 - p.s - t
        in_η(η, t) = ηs == 0 ? η <= p.s + t : η >= 1 - p.s - t
        function param(xy)
            ξ, η = try
                StructuralSizer.parametric_coords(p.panel, xy[1], xy[2])
            catch
                return nothing
            end
            (-ptol <= ξ <= 1 + ptol && -ptol <= η <= 1 + ptol) || return nothing
            return (ξ, η)
        end
        for k in flat
            haskey(leaving, k) && continue
            el = model.frame_elements[k]
            ps, pe = _node_xyz_m(el.nodeStart), _node_xyz_m(el.nodeEnd)
            mid = param(((ps[1] + pe[1]) / 2, (ps[2] + pe[2]) / 2))
            mid === nothing && continue
            in_ξ(mid[1], -ptol) && in_η(mid[2], -ptol) && continue
            for (from_start, q) in ((true, ps), (false, pe))
                c = param((q[1], q[2]))
                c === nothing && continue
                (in_ξ(c[1], ptol) && in_η(c[2], ptol)) || continue
                (abs(c[1] - ξf) <= ptol || abs(c[2] - ηf) <= ptol) || continue
                bi = get(element_beam, k, nothing)
                bi === nothing && throw(ArgumentError(
                    "frame element $k leaves a solid head and belongs to no beam"))
                sec = section(struc.beams[bi])
                sec === nothing && throw(ArgumentError(
                    "beam $bi leaves a solid head and is not sized"))
                dims = _rib_web_dims(sec)
                dims === nothing && break
                dxy = from_start ? (pe[1] - ps[1], pe[2] - ps[2]) :
                                   (ps[1] - pe[1], ps[2] - pe[2])
                Lxy = hypot(dxy...)
                outward = Lxy > 1e-12 ? (dxy[1] / Lxy, dxy[2] / Lxy) : nothing
                leaving[k] = (path = _collinear_path(model, adj, k, from_start),
                              bw = dims[1], d = dims[2], outward = outward)
                break
            end
        end
    end
    return collect(values(leaving))
end

"""Collinear elements from element `k`, walked away from the start or end node."""
function _collinear_path(model, adj, k::Int, from_start::Bool)
    path = Tuple{Int, Bool}[(k, from_start)]
    el = model.frame_elements[k]
    dir = el.LCS[1]
    dir = from_start ? dir : -dir
    far = from_start ? el.nodeEnd : el.nodeStart
    seen = Set{Int}(k)
    while true
        next = nothing
        for j in get(adj, objectid(far), Int[])
            j in seen && continue
            ej = model.frame_elements[j]
            fs = ej.nodeStart === far
            dj = fs ? ej.LCS[1] : -ej.LCS[1]
            sum(dj .* dir) >= 1 - 1e-6 || continue
            next = (j, fs)
            break
        end
        next === nothing && return path
        push!(path, next)
        push!(seen, next[1])
        ej = model.frame_elements[next[1]]
        far = next[2] ? ej.nodeEnd : ej.nodeStart
    end
end

"""Absolute vertical shear at `distance_m` from the head face along `path`, for one case."""
function _path_shear(model, path, u, load_map, distance_m::Float64)
    remaining = distance_m
    for (k, from_start) in path
        el = model.frame_elements[k]
        L = Asap.ElementProps(el).L
        if remaining <= L + 1e-9
            x = from_start ? min(remaining, L) : max(L - remaining, 0.0)
            return abs(_vertical_shear_from_u(el, u, _case_loads(load_map, el), x)) * u"N"
        end
        remaining -= L
    end
    throw(ArgumentError(
        "the section $(distance_m) m from the head face falls past the rib"))
end

"""Frame element index → beam index, over every beam segment."""
function _element_beam_map(struc)
    out = Dict{Int, Int}()
    for (bi, beam) in enumerate(struc.beams), si in segment_indices(beam)
        e = struc.segments[si].edge_idx
        e < 1 && continue
        for k in _frame_element_indices(struc, e)
            out[k] = bi
        end
    end
    return out
end

"""
    solid_head_frame_punching(struc, params) -> Union{Nothing, NamedTuple}

Solid-head punching at every head column, from the solved building frame.

`nothing` when the frame is not solved or no head has sized ribs. Otherwise
`(joints, by_slab)`: `joints` maps a column index to its worst check over
the full load and every pattern case (ACI 318-11 §13.7.6, corpus:
aci-318-11, page 261), and `by_slab` lists the column indices at each
slab's corners.

At each column, `Vu` and the two unbalanced moments come from the column
ends at the slab joint ([`_joint_case_demand`](@ref)). The head is the
rectangle every adjacent panel's corner head forms ([`_joint_head_geometry`](@ref)),
and its position must agree with the column's. The section at d/2 from the
head edge subtracts the smallest factored dead pressure over the section
area, which every case carries. One-way shear is checked in every concrete
rib leaving the head, at the rib's own d from the face.
"""
function solid_head_frame_punching(struc, params)
    model = struc.asap_model
    (model === nothing || isempty(model.frame_elements) || !model.processed) && return nothing
    panels = _solid_head_panels(struc, params)
    isempty(panels) && return nothing
    element_loads = Asap.get_elemental_loads(model)
    patterns = _pattern_demand_cases(struc, params)
    cases = Tuple{Vector{Float64}, Any}[(model.u, element_loads)]
    patterns === nothing || append!(cases, patterns)
    element_beam = _element_beam_map(struc)
    joints = Dict{Int, NamedTuple}()
    by_slab = Dict{Int, Vector{Int}}()
    for (key, corners) in _head_joints(panels)
        xyz = key ./ 1000
        cols = _joint_column_elements(struc, xyz)
        support = findfirst(c -> c[3], cols)
        support === nothing && throw(ArgumentError(
            "a solid-head panel corner at $(xyz) m has no column below it"))
        ci = cols[support][4]
        col = struc.columns[ci]
        (col.c1 === nothing || col.c2 === nothing) && throw(ArgumentError(
            "column $ci under a solid head is not sized"))
        geom = _joint_head_geometry(corners)
        geom.position == col.position || throw(ArgumentError(
            "column $ci is $(col.position), and the solid-head panels around it " *
            "make it $(geom.position): a neighbouring panel has no solid head"))
        p1 = corners[1][1]
        for (p, _, _) in corners
            p.concrete.fc′ == p1.concrete.fc′ && p.concrete.λ == p1.concrete.λ ||
                throw(ArgumentError("the solid-head panels at column $ci differ in concrete"))
        end
        # ENGINEERING JUDGMENT: each panel's head soffit is its deepest rib, so
        # the panels around one column can differ. The joint section uses the
        # shallower soffit and the smaller effective depth, concrete that is
        # present on every panel at the column.
        h_head = minimum(p.h for (p, _, _) in corners)
        d_head = minimum(p.d for (p, _, _) in corners)
        section = StructuralSizer.rib_web_critical_section(geom.head_x, geom.head_y, d_head;
                                                           position = geom.position)
        q_dead = minimum(p.q_dead for (p, _, _) in corners)
        ribs = _ribs_leaving_joint(struc, corners, xyz[3], element_beam)
        isempty(ribs) && throw(ArgumentError(
            "no concrete rib leaves the solid head at column $ci"))
        a = geom.axis_a
        col_nt = (position = col.position, c1 = _as_metres(col.c1), c2 = _as_metres(col.c2),
                  shape = col.shape, θ = col.θ, corner_kind = col.corner_kind,
                  corner_angle = col.corner_angle,
                  boundary_inward_normals = col.boundary_inward_normals,
                  boundary_edge_dirs = col.boundary_edge_dirs)
        free_edge_parallel = nothing
        if geom.free_edge !== nothing
            c1dir = (cos(col.θ), sin(col.θ))
            dotc = abs(c1dir[1] * geom.free_edge[1] + c1dir[2] * geom.free_edge[2])
            free_edge_parallel = dotc >= 1 - 1e-6 ? :c1 : dotc <= 1e-6 ? :c2 :
                throw(ArgumentError("column $ci is skewed to the slab edge"))
        end
        worst = nothing
        all_ok = true
        for (u, load_map) in cases
            Vu_N, (Mx, My) = _joint_case_demand(model, cols, u, load_map)
            Vu_N < -1.0 && throw(ArgumentError(
                "the floor lifts column $ci at a solid head ($(Vu_N) N)"))
            Vu = max(Vu_N, 0.0) * u"N"
            # The moment about the axis normal to `a` bends the span along `a`.
            # ENGINEERING JUDGMENT: positive `M_span` is the closed-form moment
            # that peaks on the +`a` side (`plan_unbalanced_moments`). The
            # components are the global end moment `K·u`. `vu` uses `|M|`.
            M_span = (-a[2] * Mx + a[1] * My) * u"N*m"
            M_perp = (a[1] * Mx + a[2] * My) * u"N*m"
            rib_demand = [(Vu = _path_shear(model, r.path, u, load_map, ustrip(u"m", r.d)),
                           bw = r.bw, d = r.d, joist = nothing,
                           outward = r.outward,
                           Mu = _path_hogging(model, r.path, u, load_map, 0.0)) for r in ribs]
            chk = StructuralSizer.check_solid_head_punching(
                col_nt, Vu, M_span, d_head, h_head, p1.concrete.fc′, rib_demand;
                Muy = M_perp, b0 = section.b0, web_area = geom.web_area,
                head_width = geom.head_width, side_long = section.side_long,
                side_short = section.side_short, position = geom.position,
                qu = q_dead, section_area = section.section_area,
                λ = p1.concrete.λ, span_axis = (a[1], a[2]), θ = col.θ,
                free_edge_parallel = free_edge_parallel,
                fy = _beam_materials(params)[2].Fy)
            all_ok &= chk.ok
            if worst === nothing || chk.ratio > worst.check.ratio
                worst = (check = chk, Vu = Vu, Mub = M_span, Muy = M_perp)
            end
        end
        joints[ci] = (ok = all_ok, ratio = worst.check.ratio,
                      governing = worst.check.governing,
                      vu_psi = _head_punching_stress_psi(worst.check),
                      Vu = worst.Vu, Mub = worst.Mub, Muy = worst.Muy,
                      direction = worst.check.direction,
                      position = geom.position, n_cases = length(cases),
                      check = worst.check)
        for (p, _, _) in corners
            push!(get!(by_slab, p.slab_idx, Int[]), ci)
        end
    end
    return (joints = joints, by_slab = by_slab)
end
