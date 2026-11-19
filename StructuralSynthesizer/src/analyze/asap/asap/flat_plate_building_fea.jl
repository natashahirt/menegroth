# =============================================================================
# FEA(source = :building): one flat-plate slab read from the building model
# =============================================================================

StructuralSizer.building_fea_available(struc::BuildingStructure, slab) =
    _flat_plate_layout_slab(struc, slab) !== nothing

"""Index of `slab` in the flat-plate shell layout, or `nothing`."""
function _flat_plate_layout_slab(struc::BuildingStructure, slab)
    layout = flat_plate_shell_layout(struc)
    layout === nothing && return nothing
    for (si, s) in enumerate(struc.slabs)
        (s === slab || s.cell_indices == slab.cell_indices) || continue
        return haskey(layout.slab_shells, si) && !isempty(layout.slab_shells[si]) ? si : nothing
    end
    return nothing
end

"""Vertical frame elements at each node, split into the one below and the one above."""
function _vertical_elements_at(model, wanted::Set{UInt64})
    below = Dict{UInt64, Vector{Asap.Element}}()
    above = Dict{UInt64, Vector{Asap.Element}}()
    for el in model.frame_elements
        el isa Asap.Element || continue
        a, b = el.nodeStart, el.nodeEnd
        pa, pb = ustrip.(u"m", a.position), ustrip.(u"m", b.position)
        hypot(pb[1] - pa[1], pb[2] - pa[2]) <= 1e-6 * max(abs(pb[3] - pa[3]), 1.0) || continue
        abs(pb[3] - pa[3]) > 1e-6 || continue
        for (nd, other_z) in ((a, pb[3]), (b, pa[3]))
            id = objectid(nd)
            id in wanted || continue
            side = other_z < _node_z_m(nd) ? below : above
            push!(get!(() -> Asap.Element[], side, id), el)
        end
    end
    return below, above
end

"""`(Fz, Mx, My)` at `node` of the end forces `K u + Q` of `el`, in global axes (N, N·m)."""
function _element_end_force(el::Asap.Element, U::Vector{Float64}, Q, node::Asap.Node)
    F = el.K * U[el.globalID]
    Q === nothing || (F .+= Q)
    o = el.nodeStart === node ? 0 : 6
    return (F[o + 3], F[o + 4], F[o + 5])
end

_sum3(a, b) = (a[1] + b[1], a[2] + b[2], a[3] + b[3])
_scale3(s, a) = (s * a[1], s * a[2], s * a[3])

"""
    StructuralSizer.building_fea_analysis!(struc::BuildingStructure, slab, columns, h, setup; ...)

`slab` at thickness `h` and modulus `Ecs`, read from the building model.

The slab's triangles take `h`; its columns take their RC sections at the trial
size. One factorization of the building stiffness then carries three kinds of
case: unfactored dead (every flat-plate floor, member and wall self-weight,
drop panels), unfactored live on every flat-plate floor, and, with
`use_pattern`, live on each cell of this slab alone. This slab's cells carry
`setup.qD` and `setup.qL`; every other floor carries its current cell pressure.

Column forces are the column ends at the slab node: the sum below and above is
the joint, as for the per-slab stubs. They are enveloped over the load
combinations and, with patterns, over each pattern of this slab's cells
(ACI 318-11 §13.7.6, corpus: aci-318-11, page 261). Each component is its own
envelope, so the set is not concurrent.

`Δ_panel` is the largest factored deflection of a slab node below the mean of
its supports, scaled to gross section by `FLAT_PLATE_CRACKED_I`.
ENGINEERING JUDGMENT: the deflection check reads a gross-section value, and
the building slab is at 0.25 Ig; the support mean removes column shortening.

ENGINEERING JUDGMENT: floors that are not flat-plate shells are left out of
these cases. They reach this slab's joints only through frame action.
"""
function StructuralSizer.building_fea_analysis!(struc::BuildingStructure, slab, columns,
                                                h, setup; Ecs, ν::Float64 = 0.20,
                                                use_pattern::Bool = false,
                                                drop_panel = nothing, verbose::Bool = false)
    _flat_plate_mesh_stale(struc) &&
        update_analysis!(struc, :geometry; params = flat_plate_shell_layout(struc).params)
    sidx = _flat_plate_layout_slab(struc, slab)
    sidx === nothing && throw(ArgumentError(
        "FEA(source = :building): the building model has no shells for this slab"))
    layout = flat_plate_shell_layout(struc)
    params = layout.params
    model = struc.asap_model

    # ── Trial section on this slab and its columns ──
    changed = _set_flat_plate_slab_section!(layout, struc, sidx,
                                            Float64(ustrip(u"m", h)),
                                            Float64(ustrip(u"Pa", Ecs)))
    layout.ν = ν
    for col in columns
        (col.c1 === nothing || col.c2 === nothing) && continue
        changed |= _set_column_frame_section!(struc, col, _rc_column_frame_section(col, params))
    end
    if changed
        Asap.update!(model; values_only = true)
        _clear_pattern_solve_cache!(struc)
    end

    # ── Load cases ──
    elements = model.frame_elements
    strips = slab_edge_strips_by_cell(struc)
    D = Asap.AbstractLoad[]
    L = Asap.AbstractLoad[]
    cell_live = Dict{Int, Vector{Asap.AbstractLoad}}()
    own = Set(slab.cell_indices)
    for ci in sort!(collect(keys(layout.cell_shells)))
        cell = struc.cells[ci]
        qd, ql = ci in own ? (setup.qD, setup.qL) : (cell.sdl + cell.self_weight, cell.live_load)
        d, l = _flat_plate_unfactored_cell_loads(layout, ci, qd, ql)
        push!(D, d)
        live = Asap.AbstractLoad[l]
        cs = get(strips, ci, NamedTuple[])
        _append_edge_strip_loads!(D, Asap.TributaryLoad[], elements, cs, uconvert(u"Pa", qd))
        _append_edge_strip_loads!(live, Asap.TributaryLoad[], elements, cs, uconvert(u"Pa", ql))
        append!(L, live)
        ci in own && (cell_live[ci] = live)
    end
    gravity = Dict{UInt64, Asap.GravityLoad}()
    for ld in model.loads
        if ld isa Asap.GravityLoad
            g = unfactored_gravity_load(ld)
            push!(D, g)
            gravity[objectid(ld.element)] = g
        end
    end
    wall_shells = Asap.ShellTri3[sh for sh in model.shell_elements
                                 if sh isa Asap.ShellTri3 && sh.id === :wall]
    append!(D, wall_self_weight_loads(wall_shells))
    append!(D, unfactored_drop_panel_loads(struc))

    order = Int[ci for ci in slab.cell_indices if haskey(cell_live, ci)]
    cases = Vector{Asap.AbstractLoad}[D, L]
    use_pattern && foreach(ci -> push!(cases, cell_live[ci]), order)
    U = Asap.solve(model, cases, struc.asap_rigid_links)
    U_D, U_L = U[1], U[2]
    U_cell = Dict{Int, Vector{Float64}}()
    if use_pattern
        for (j, ci) in enumerate(order)
            U_cell[ci] = U[2 + j]
        end
    end

    combos = StructuralSizer._LOAD_COMBOS
    patterns = use_pattern ? StructuralSizer.generate_load_patterns(length(slab.cell_indices)) :
               Vector{Symbol}[]
    # Live displacement of one pattern: the loaded cells of this slab.
    pattern_live(pat, field) = begin
        acc = nothing
        for (j, load_type) in enumerate(pat)
            load_type === :dead_plus_live || continue
            v = get(field, slab.cell_indices[j], nothing)
            v === nothing && continue
            acc = acc === nothing ? v : _sum3(acc, v)
        end
        acc === nothing ? (0.0, 0.0, 0.0) : acc
    end

    # ── Cache: this slab's triangles ──
    tris = layout.slab_shells[sidx]
    αD, αL = first(combos)
    view = StructuralSizer.FEASlabView(tris, model.nodes, αD .* U_D .+ αL .* U_L)
    cache = StructuralSizer.FEAModelCache()
    cache.model = view
    cache.shells = tris
    cache.drop_panel = drop_panel
    StructuralSizer._precompute_element_data!(cache, view, struc, slab)
    cache.element_data_D = _element_moments(tris, U_D)
    cache.element_data_L = _element_moments(tris, U_L)
    cache.U_D = U_D
    for (ci, Uc) in U_cell
        cache.cell_live_moments[ci] = _element_moments(tris, Uc)
        cache.cell_live_displacements[ci] = Uc
    end
    cache.initialized = true

    # ── Column joint forces ──
    col_nodes = Asap.Node[model.nodes[col.vertex_idx] for col in columns]
    below, above = _vertical_elements_at(model, Set(objectid(nd) for nd in col_nodes))
    ax_len = hypot(setup.span_axis...)
    ax = ax_len > 1e-9 ? (setup.span_axis[1] / ax_len, setup.span_axis[2] / ax_len) : (1.0, 0.0)
    forces = _empty_joint_forces(length(columns))
    for (i, nd) in enumerate(col_nodes)
        els_b = get(below, objectid(nd), Asap.Element[])
        els_a = get(above, objectid(nd), Asap.Element[])
        side(els, Uv, with_gravity) = begin
            acc = (0.0, 0.0, 0.0)
            for el in els
                g = with_gravity ? get(gravity, objectid(el), nothing) : nothing
                Q = g === nothing ? nothing : _element_Q(el, Asap.AbstractLoad[g])
                acc = _sum3(acc, _element_end_force(el, Uv, Q, nd))
            end
            acc
        end
        bD, aD = side(els_b, U_D, true), side(els_a, U_D, true)
        bL, aL = side(els_b, U_L, false), side(els_a, U_L, false)
        cb = Dict(ci => side(els_b, U_cell[ci], false) for ci in keys(U_cell))
        ca = Dict(ci => side(els_a, U_cell[ci], false) for ci in keys(U_cell))
        for (cD, cL) in combos
            _envelope_joint!(forces, i, ax,
                _sum3(_scale3(cD, bD), _scale3(cL, bL)),
                _sum3(_scale3(cD, aD), _scale3(cL, aL)))
            for pat in patterns
                _envelope_joint!(forces, i, ax,
                    _sum3(_scale3(cD, bD), _scale3(cL, pattern_live(pat, cb))),
                    _sum3(_scale3(cD, aD), _scale3(cL, pattern_live(pat, ca))))
            end
        end
        stub_b = isempty(els_b) ? nothing : _stub_half(first(els_b), nd)
        stub_a = isempty(els_a) ? nothing : _stub_half(first(els_a), nd)
        if stub_b !== nothing
            cache.col_stubs[i] = (below = stub_b, above = stub_a)
        elseif stub_a !== nothing
            cache.col_stubs[i] = (below = stub_a, above = nothing)
        end
    end

    Δ_panel = _building_panel_deflection(layout, tris, col_nodes, U_D, U_L, U_cell,
                                         combos, patterns, slab.cell_indices)
    verbose && @debug "FEA(source = :building)" slab = sidx n_tri = length(tris) n_cases = length(cases) Δ_panel
    return (cache = cache, forces = _joint_forces_with_units(forces), Δ_panel = Δ_panel)
end

"""
Put `sec` on `col`'s frame elements. Returns `true` when any element had a
different stiffness, so the building must be refactored.
"""
function _set_column_frame_section!(struc::BuildingStructure, col, sec)
    els = struc.asap_model.frame_elements
    key(s) = (ustrip(u"m^2", s.A), ustrip(u"m^4", s.Ix), ustrip(u"m^4", s.Iy),
              ustrip(u"m^4", s.J), ustrip(u"Pa", s.E), ustrip(u"Pa", s.G))
    changed = false
    for seg_idx in segment_indices(col)
        e = struc.segments[seg_idx].edge_idx
        1 <= e <= length(els) || continue
        els[e].section isa Asap.Section && key(els[e].section) == key(sec) && continue
        els[e].section = sec
        changed = true
    end
    return changed
end

"""Bending moments of each triangle at displacement `U`."""
function _element_moments(tris, U::Vector{Float64})
    ws = Asap.ShellMomentWorkspace()
    M = zeros(3)
    out = Vector{StructuralSizer.ElementMoments}(undef, length(tris))
    for (k, tri) in enumerate(tris)
        Asap.bending_moments!(M, tri, U, ws)
        out[k] = StructuralSizer.ElementMoments(M[1], M[2], M[3])
    end
    return out
end

_stub_half(el, nd) = (element = el,
                      base_node = el.nodeStart === nd ? el.nodeEnd : el.nodeStart,
                      slab_node = nd)

"""Joint-force envelope in SI, filled by [`_envelope_joint!`](@ref)."""
function _empty_joint_forces(n::Int)
    z() = zeros(n)
    return (Vu = z(), Mu = z(), Mub = z(), Mx = z(), My = z(),
            Mub_below = z(), Mx_below = z(), My_below = z(),
            Mub_above = z(), Mx_above = z(), My_above = z())
end

"""Keep the signed value of larger magnitude."""
_absmax(old, new) = abs(new) > abs(old) ? new : old

"""
Fold one combination's column-end forces `(Fz, Mx, My)` below and above the
slab node into column `i`'s envelope. Same quantities as
`StructuralSizer._extract_fea_column_forces`.
"""
function _envelope_joint!(f, i, ax, b, a)
    Fz, Mx, My = b[1] + a[1], b[2] + a[2], b[3] + a[3]
    mub(mx, my) = abs(ax[1] * my - ax[2] * mx)
    f.Vu[i] = max(f.Vu[i], abs(Fz))
    f.Mu[i] = max(f.Mu[i], hypot(Mx, My))
    f.Mub[i] = max(f.Mub[i], mub(Mx, My))
    f.Mx[i] = _absmax(f.Mx[i], Mx)
    f.My[i] = _absmax(f.My[i], My)
    f.Mub_below[i] = max(f.Mub_below[i], mub(b[2], b[3]))
    f.Mx_below[i] = _absmax(f.Mx_below[i], b[2])
    f.My_below[i] = _absmax(f.My_below[i], b[3])
    f.Mub_above[i] = max(f.Mub_above[i], mub(a[2], a[3]))
    f.Mx_above[i] = _absmax(f.Mx_above[i], a[2])
    f.My_above[i] = _absmax(f.My_above[i], a[3])
    return f
end

function _joint_forces_with_units(f)
    kip = StructuralSizer.kip
    force(v) = [uconvert(kip, x * u"N") for x in v]
    moment(v) = [uconvert(kip * u"ft", x * u"N*m") for x in v]
    return (Vu = force(f.Vu), Mu = moment(f.Mu), Mub = moment(f.Mub),
            Mx = moment(f.Mx), My = moment(f.My),
            Mub_below = moment(f.Mub_below), Mx_below = moment(f.Mx_below),
            My_below = moment(f.My_below),
            Mub_above = moment(f.Mub_above), Mx_above = moment(f.Mx_above),
            My_above = moment(f.My_above))
end

"""
Largest factored deflection of a slab node below the mean of its supports,
over the combinations and patterns, at gross section.
"""
function _building_panel_deflection(layout, tris, col_nodes, U_D, U_L, U_cell,
                                    combos, patterns, cell_indices)
    seen = Set{UInt64}()
    slab_z = Int[]
    support_z = Int[]
    for tri in tris, nd in tri.nodes
        objectid(nd) in seen && continue
        push!(seen, objectid(nd))
        push!(slab_z, nd.globalID[3])
        objectid(nd) in layout.wall_nodes && push!(support_z, nd.globalID[3])
    end
    append!(support_z, (nd.globalID[3] for nd in col_nodes))
    isempty(support_z) && return 0.0u"m"
    # Only the slab and support z-DOFs are read.
    gids = vcat(slab_z, support_z)
    n_slab = length(slab_z)
    wD, wL = U_D[gids], U_L[gids]
    w_cell = Dict(ci => Uc[gids] for (ci, Uc) in U_cell)
    worst = 0.0
    function fold!(w)
        ref = sum(view(w, (n_slab + 1):length(w))) / length(support_z)
        worst = max(worst, maximum(ref .- view(w, 1:n_slab)))
    end
    for (cD, cL) in combos
        fold!(cD .* wD .+ cL .* wL)
        for pat in patterns
            w = cD .* wD
            for (j, t) in enumerate(pat)
                t === :dead_plus_live || continue
                wc = get(w_cell, cell_indices[j], nothing)
                wc === nothing || (w .+= cL .* wc)
            end
            fold!(w)
        end
    end
    return FLAT_PLATE_CRACKED_I * worst * u"m"
end
