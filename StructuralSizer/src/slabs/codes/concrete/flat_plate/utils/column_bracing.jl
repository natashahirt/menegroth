# Flat-plate column bracing and the alignment-chart k.
#
# ACI 318-11 §10.10.5 (corpus: aci-318-11, page 154) requires every story to
# be designated nonsway or sway. §10.10.5.2: nonsway when
# Q = ΣPu Δo / (Vus ℓc) ≤ 0.05. Nonsway columns are designed by §10.10.6,
# sway columns by §10.10.7.
#
# R10.10.6.3 (page 156) recommends k = 1.0 for a braced column. A lower k
# is allowed only from the alignment chart with the §10.10.4.1 stiffnesses.
# This path keeps that recommendation for a nonsway story.
#
# A sway story uses Fig. R10.10.1.1 (page 150). ψ = Σ(EI/ℓ)_columns /
# Σ(EI/ℓ)_slab, with the §10.10.4.1 factors (page 153): 0.70 Ig for the
# column and 0.25 Ig for a flat plate. A footing that is not built as a
# rigid joint uses ψ = 10 (McCormac & Brown, 9th ed., slender-column chapter,
# corpus: textbook-mccormac-reinforced-concrete-9e).

const _FLAT_PLATE_COL_I = 0.70
const _FLAT_PLATE_SLAB_I = 0.25
const _FLAT_PLATE_FOOTING_PSI = 10.0

"""
    flat_plate_story_is_sway(struc, slab, col) -> Bool

§10.10.5.2 when `col.story_properties` is present. Otherwise a wall that
meets the slab is the bracing element and the story is nonsway by
inspection (R10.10.5, page 154). No wall and no Q is not designated
nonsway: the story is sway.
"""
function flat_plate_story_is_sway(struc, slab, col)
    # The design kernel's support has no story_properties. A building column
    # does, once compute_story_properties! has run.
    if hasproperty(col, :story_properties)
        sp = col.story_properties
        if sp !== nothing
            story = SwayStoryProperties(sp.ΣPu, 0.0, sp.Vus, sp.Δo, sp.lc)
            return is_sway_frame(story)
        end
    end
    return isempty(supporting_wall_segments(struc, slab))
end

"""How many slab spans frame into `col` along `direction` (1 or 2)."""
function _framing_span_count(struc, col, slab, direction)
    skel = struc.skeleton
    skel.geometry === nothing && throw(ArgumentError(
        "flat-plate ψ needs the skeleton geometry"))
    vc = skel.geometry.vertex_coords
    col.vertex_idx in axes(vc, 1) || throw(ArgumentError(
        "column vertex $(col.vertex_idx) is not in the skeleton"))
    vx, vy = vc[col.vertex_idx, 1], vc[col.vertex_idx, 2]
    pos = neg = false
    for ci in slab.cell_indices
        ci in col.tributary_cell_indices || continue
        vis = skel.face_vertex_indices[struc.cells[ci].face_idx]
        isempty(vis) && continue
        cx = sum(vc[v, 1] for v in vis) / length(vis)
        cy = sum(vc[v, 2] for v in vis) / length(vis)
        s = (cx - vx) * direction[1] + (cy - vy) * direction[2]
        s > 0.05 && (pos = true)
        s < -0.05 && (neg = true)
    end
    n = (pos ? 1 : 0) + (neg ? 1 : 0)
    n >= 1 || throw(ArgumentError(
        "column at vertex $(col.vertex_idx) has no slab span along $direction"))
    return n
end

"""ψ at a slab joint. `n_columns` is 1 at a roof and 2 where a column continues."""
function _flat_plate_joint_ψ(col, slab, struc, h::Length, direction, span::Length,
                             transverse::Length; n_columns::Int)
    Ic = _col_moment_of_inertia(col, direction)
    H = ustrip(u"inch", col.base.L)
    H > 1.0 || throw(ArgumentError("column length must be positive; got $(col.base.L)"))
    h_in = ustrip(u"inch", h)
    l1 = ustrip(u"inch", span)
    l2 = ustrip(u"inch", transverse)
    (h_in > 0 && l1 > 0 && l2 > 0) || throw(ArgumentError(
        "ψ needs a positive slab thickness and both spans"))
    Is = l2 * h_in^3 / 12
    n_spans = _framing_span_count(struc, col, slab, direction)
    num = n_columns * _FLAT_PLATE_COL_I * Ic / H
    den = n_spans * _FLAT_PLATE_SLAB_I * Is / l1
    den > 0 || throw(ArgumentError("slab stiffness in ψ is zero"))
    return num / den
end

"""Span length along `direction`, and the transverse width, from the slab axes."""
function _spans_along(slab, direction)
    ax = slab.spans.axis
    align = abs(Float64(ax[1]) * direction[1] + Float64(ax[2]) * direction[2])
    if align >= 0.5
        return slab.spans.primary, slab.spans.secondary
    end
    return slab.spans.secondary, slab.spans.primary
end

"""Chart k for bending in the vertical plane of `direction`."""
function _flat_plate_axis_k(col, slab, struc, h, direction)
    span, transverse = _spans_along(slab, direction)
    n_top = col.column_above === nothing ? 1 : 2
    ψ_top = _flat_plate_joint_ψ(col, slab, struc, h, direction, span, transverse;
                               n_columns = n_top)
    ψ_bot = if col.story <= 0
        _FLAT_PLATE_FOOTING_PSI
    else
        _flat_plate_joint_ψ(col, slab, struc, h, direction, span, transverse;
                           n_columns = 2)
    end
    return alignment_chart_k(ψ_top, ψ_bot; sway = true)
end

"""
    flat_plate_column_geometry(col, slab, struc; h) -> ConcreteMemberGeometry

Slenderness geometry for one flat-plate column.

Nonsway (§10.10.5.2, or a wall by inspection): braced, k = 1 about both
axes (R10.10.6.3). Sway: unbraced, k from Fig. R10.10.1.1 in each plan
direction. Sets `col.braced` to the designation.
"""
function flat_plate_column_geometry(col, slab, struc; h::Length)
    (isnothing(col.c1) || isnothing(col.c2)) && throw(ArgumentError(
        "flat-plate column k needs c1 and c2"))
    sway = flat_plate_story_is_sway(struc, slab, col)
    # The kernel support has no braced flag. The geometry returned below
    # carries the designation either way.
    hasproperty(col, :braced) && (col.braced = !sway)
    if !sway
        return ConcreteMemberGeometry(col.base.L; Lu = col.base.L,
                                      kx = 1.0, ky = 1.0, braced = true)
    end
    θ = col_orientation(col)
    dir_c1 = (cos(θ), sin(θ))
    dir_c2 = (-sin(θ), cos(θ))
    kx = _flat_plate_axis_k(col, slab, struc, h, dir_c1)
    ky = _flat_plate_axis_k(col, slab, struc, h, dir_c2)
    return ConcreteMemberGeometry(col.base.L; Lu = col.base.L,
                                  kx = kx, ky = ky, braced = false)
end

"""One geometry per column, in `columns` order, at slab thickness `h`."""
function flat_plate_column_geometries(columns, slab, struc; h::Length)
    return [flat_plate_column_geometry(col, slab, struc; h) for col in columns]
end
