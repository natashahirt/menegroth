# Solid head of a waffle, as a rectangular cross section.
#
# The domes stop at the column, so the concrete there is a solid rectangle of
# the full depth. ACI 318-11 §13.7.3.1 (corpus: aci-318-11, page 259) permits
# the gross concrete section for the slab-beam's moment of inertia. The
# torsion constant of that rectangle is ACI 318-11 Eq. (13-6) (page 255).
#
# A level rib bends vertically about local z, so that inertia is Iy and its
# shear area is Az. Asap's rectangular beam and its shell both take the
# effective shear area as 5/6 of the gross area. Each rib family owns the
# solid head's width once: the ξ ribs share the head's ξ width, and the η
# ribs share its η width. Orthogonal bending is then the plate's, once
# each way.

"""Effective shear area over gross area for a rectangular section."""
const _RECTANGULAR_SHEAR_FACTOR = 5 / 6

"""
    solid_head_section(width, depth, concrete) -> Asap.Section

Gross rectangle `width` by `depth`.

`Iy` is `width * depth³ / 12`, the vertical bending inertia of a level rib.
`Ix` is `depth * width³ / 12`, bending in the plane of the floor. `Az` is
the vertical shear area and `Ay` the in-plane shear area, each
`5/6` of the gross area. `J` is ACI 318-11 Eq. (13-6). `G` is `E / (2(1+ν))`
from the concrete.
"""
function solid_head_section(width::Length, depth::Length, concrete::Concrete;
                            density = nothing)
    (width > zero(width) && depth > zero(depth)) || throw(ArgumentError(
        "a solid head needs a positive width and depth, got $width by $depth"))
    # `density` overrides `concrete.ρ` when the two rib families share the
    # head, and when only the projection below the topping is weighed.
    # Stiffness stays the gross rectangle either way.
    ρ = density === nothing ? concrete.ρ : density
    A = width * depth
    # Vertical bending is Iy. In-plane bending is Ix.
    Iy = slab_moment_of_inertia(width, depth)
    Ix = slab_moment_of_inertia(depth, width)
    J = torsional_constant_C(width, depth)
    shear = _RECTANGULAR_SHEAR_FACTOR * A
    G = concrete.E / (2 * (1 + concrete.ν))
    return Asap.Section(A, concrete.E, G, Ix, Iy, J, ρ; Ay = shear, Az = shear)
end

"""
    classify_solid_head(; span_x, span_y, from_center_x, from_center_y,
                          projection, slab_thickness, column_x, column_y)

ACI 318-11 §13.2.5 (corpus: aci-318-11, PDF page 244): a drop panel projects
below the slab at least one quarter of the adjacent slab thickness, and
extends each way from the support centerline at least one sixth of the span
measured center-to-center of supports.

ACI 318-11 §13.2.6 (same page): a shear cap projects below the slab and
extends horizontally from the column face at least as far as the projection
is thick.

R13.2.5: a projection smaller than §13.2.5 may be used as a shear cap. Shear
is checked at the sections of §11.11.1.2. Flexure and minimum-thickness
credit belong to a drop panel, not to a shear cap.

Every length is a `Length`. Returns `(kind, drop_panel, shear_cap)`. `kind`
is `:drop_panel` when §13.2.5 is met, `:shear_cap` when only §13.2.6 is met,
and `:undersized` when neither is.
"""
function classify_solid_head(;
        span_x::Length, span_y::Length,
        from_center_x::Length, from_center_y::Length,
        projection::Length, slab_thickness::Length,
        column_x::Length, column_y::Length)
    for (name, x) in (("span_x", span_x), ("span_y", span_y),
                      ("slab_thickness", slab_thickness),
                      ("column_x", column_x), ("column_y", column_y))
        x > zero(x) || throw(ArgumentError("$name must be positive, got $x"))
    end
    projection >= zero(projection) || throw(ArgumentError(
        "a projection below the slab is not negative, got $projection"))
    # §13.2.5. "At least" is inclusive.
    drop_depth = projection >= slab_thickness / 4
    drop_extent = from_center_x >= span_x / 6 && from_center_y >= span_y / 6
    drop = drop_depth && drop_extent
    # §13.2.6. Distance from the column face, each way.
    face_x = from_center_x - column_x / 2
    face_y = from_center_y - column_y / 2
    cap = projection > zero(projection) && face_x >= projection && face_y >= projection
    kind = drop ? :drop_panel : cap ? :shear_cap : :undersized
    return (kind = kind, drop_panel = drop, shear_cap = cap)
end

"""Physical length of one panel edge."""
function _edge_length(panel::IsoParametricPanel, a::Int, b::Int)
    p, q = panel.corners[a], panel.corners[b]
    return hypot(q[1] - p[1], q[2] - p[2])
end

"""
    solid_piece_widths(grid) -> Vector{Float64}

Width, in metres, of the solid rectangle on each [`rib_network`](@ref) piece.
A piece outside a solid head is zero.

The four corner heads do not overlap (`solid_head` < 1/2). The rib lines of
one family that cross one head share that head's width equally, so the
shares add up to the head. ξ-ribs share `solid_head` times the ξ edge. η-ribs
share `solid_head` times the η edge. Pieces along one rib line are in series
and each carries that line's full share. A panel that is not a rectangle
throws: the closed-form width is the rectangle's.
"""
function solid_piece_widths(grid::WaffleRibGrid)
    c = grid.panel.corners
    Lξ = _edge_length(grid.panel, 1, 2)
    Lη = _edge_length(grid.panel, 1, 4)
    (Lξ > 0 && Lη > 0) || throw(ArgumentError(
        "a solid head needs positive panel edges"))
    # Opposite edges equal, and adjacent edges perpendicular.
    _edge_length(grid.panel, 4, 3) ≈ Lξ || throw(ArgumentError(
        "the solid-head width is for a rectangle"))
    _edge_length(grid.panel, 2, 3) ≈ Lη || throw(ArgumentError(
        "the solid-head width is for a rectangle"))
    ex = (c[2][1] - c[1][1], c[2][2] - c[1][2])
    ey = (c[4][1] - c[1][1], c[4][2] - c[1][2])
    abs(ex[1] * ey[1] + ex[2] * ey[2]) <= 1e-8 * Lξ * Lη || throw(ArgumentError(
        "the solid-head width is for a rectangle"))
    net = rib_network(grid)
    widths = zeros(length(net.pieces))
    s = grid.solid_head
    s <= 0 && return widths
    # Head key → (piece index, rib line index) of every solid piece in it.
    groups = Dict{Tuple{Symbol, Symbol, Symbol}, Vector{Tuple{Int, Int}}}()
    nξ, nη = grid.nξ, grid.nη
    # Piece order is the network's: ξ-family first, then η-family.
    k = 0
    for i in 0:nξ
        ξ = i / nξ
        for j in 0:(nη - 1)
            k += 1
            net.pieces[k].solid || continue
            η = (j + 0.5) / nη
            push!(get!(groups, (:ξ, _head_side(ξ, s), _head_side(η, s)), Tuple{Int, Int}[]), (k, i))
        end
    end
    for j in 0:nη
        η = j / nη
        for i in 0:(nξ - 1)
            k += 1
            net.pieces[k].solid || continue
            ξ = (i + 0.5) / nξ
            push!(get!(groups, (:η, _head_side(ξ, s), _head_side(η, s)), Tuple{Int, Int}[]), (k, j))
        end
    end
    k == length(net.pieces) || throw(ArgumentError(
        "the solid-head widths and the rib network do not match"))
    for ((family, ξ_side, η_side), members) in groups
        (ξ_side === :out || η_side === :out) && throw(ArgumentError(
            "a piece marked solid does not lie in a corner head"))
        head = family === :ξ ? s * Lξ : s * Lη
        share = head / length(unique(last.(members)))
        for (piece, _) in members
            widths[piece] = share
        end
    end
    return widths
end

"""`:lo` at 0, `:hi` at 1, `:out` in the open middle."""
function _head_side(t::Real, solid_head::Real)
    t <= solid_head && return :lo
    t >= 1 - solid_head && return :hi
    return :out
end
