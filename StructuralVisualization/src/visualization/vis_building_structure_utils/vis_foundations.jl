# Foundation visualization utilities
#
# Draws spread, strip (combined), and mat footings as 3D boxes.
# Shared helpers keep geometry code DRY across footing types.

# =============================================================================
# Shared Geometry Helpers
# =============================================================================

"""
    _footing_box_mesh(cx, cy, z_top, half_bx, half_by, D)

Create a triangulated box mesh for a footing centered at `(cx, cy)`.
Returns `(vertices, faces)` for `GLMakie.mesh!`.
"""
function _footing_box_mesh(cx, cy, z_top, half_bx, half_by, D)
    z_bot = z_top - D
    x0, x1 = cx - half_bx, cx + half_bx
    y0, y1 = cy - half_by, cy + half_by

    verts = GLMakie.Point3f[
        (x0, y0, z_bot), (x1, y0, z_bot),
        (x1, y1, z_bot), (x0, y1, z_bot),
        (x0, y0, z_top), (x1, y0, z_top),
        (x1, y1, z_top), (x0, y1, z_top),
    ]

    tris = GLMakie.TriangleFace[
        (1,2,3), (1,3,4),   # bottom
        (5,7,6), (5,8,7),   # top
        (1,6,2), (1,5,6),   # front  (y_min)
        (3,8,4), (3,7,8),   # back   (y_max)
        (1,4,8), (1,8,5),   # left   (x_min)
        (2,6,7), (2,7,3),   # right  (x_max)
    ]

    return verts, tris
end

"""Draw box outline edges for visual clarity."""
function _draw_box_edges!(ax, verts; color=:gray40, linewidth=0.5)
    edge_pairs = [
        (1,2),(2,3),(3,4),(4,1),   # bottom
        (5,6),(6,7),(7,8),(8,5),   # top
        (1,5),(2,6),(3,7),(4,8),   # verticals
    ]
    for (a, b) in edge_pairs
        GLMakie.lines!(ax, [verts[a], verts[b]], color=color, linewidth=linewidth)
    end
end

"""Get support positions (in meters) for a foundation's support indices."""
function _support_positions_m(fdn, struc)
    return [let pos = struc.asap_model.nodes[struc.supports[i].node_idx].position
        (ustrip(u"m", pos[1]), ustrip(u"m", pos[2]), ustrip(u"m", pos[3]))
    end for i in fdn.support_indices]
end

"""Compute centroid of (x, y, z) tuples."""
function _centroid_xyz(pts)
    n = length(pts)
    cx = sum(p[1] for p in pts) / n
    cy = sum(p[2] for p in pts) / n
    cz = sum(p[3] for p in pts) / n
    return (cx, cy, cz)
end

# =============================================================================
# Spread Footing
# =============================================================================

"""
    draw_spread_footing!(ax, fdn, struc; color, alpha, show_rebar)

Draw a spread footing as a 3D box at the support location.
"""
function draw_spread_footing!(ax, fdn::Foundation, struc::BuildingStructure;
                               color=:gray70, alpha=0.7, show_rebar=false)
    result = fdn.result
    result isa StructuralSizer.SpreadFootingResult || return

    B = ustrip(u"m", result.B)
    L = ustrip(u"m", result.L_ftg)
    D = ustrip(u"m", result.D)

    pts = _support_positions_m(fdn, struc)
    cx, cy, _ = _centroid_xyz(pts)

    verts, tris = _footing_box_mesh(cx, cy, 0.0, B / 2, L / 2, D)
    mesh = GLMakie.GeometryBasics.Mesh(verts, tris)
    GLMakie.mesh!(ax, mesh, color=(color, alpha), transparency=true)
    _draw_box_edges!(ax, verts)

    if show_rebar && result.rebar_count > 0
        _draw_spread_rebar!(ax, cx, cy, 0.0, B, L, result)
    end
end

"""Draw rebar grid on top of a spread footing."""
function _draw_spread_rebar!(ax, cx, cy, z_top, B, L,
                              result::StructuralSizer.SpreadFootingResult)
    n = result.rebar_count
    n <= 0 && return
    cover = 0.075  # 75 mm

    # X-direction bars
    for y in range(cy - L/2 + cover, cy + L/2 - cover; length=n)
        GLMakie.lines!(ax,
            [GLMakie.Point3f(cx - B/2 + cover, y, z_top + 0.01),
             GLMakie.Point3f(cx + B/2 - cover, y, z_top + 0.01)],
            color=:brown, linewidth=1.5)
    end

    # Y-direction bars
    for x in range(cx - B/2 + cover, cx + B/2 - cover; length=n)
        GLMakie.lines!(ax,
            [GLMakie.Point3f(x, cy - L/2 + cover, z_top + 0.01),
             GLMakie.Point3f(x, cy + L/2 - cover, z_top + 0.01)],
            color=:brown, linewidth=1.5)
    end
end

# =============================================================================
# Strip (Combined) Footing
# =============================================================================

"""
    draw_strip_footing!(ax, fdn, struc; color, alpha, show_columns)

Draw a strip/combined footing as an elongated 3D box aligned along its
support axis, with optional column markers.
"""
function draw_strip_footing!(ax, fdn::Foundation, struc::BuildingStructure;
                              color=RGBAf(0.55, 0.55, 0.60, 1.0),
                              alpha=0.7, show_columns=true)
    result = fdn.result
    result isa StructuralSizer.StripFootingResult || return

    B = ustrip(u"m", result.B)
    L = ustrip(u"m", result.L_ftg)
    D = ustrip(u"m", result.D)

    pts = _support_positions_m(fdn, struc)
    cx, cy, _ = _centroid_xyz(pts)

    # Same `_support_strip_axes` contract as design / API serialize (deci-311bd2d0).
    # Do not use Δx >= Δy (silent X on SI-ulp ties; can disagree with governing :y).
    if length(pts) >= 2
        along_x = StructuralSynthesizer._visualization_strip_along_x(
            struc, collect(Int, fdn.support_indices))
    else
        along_x = true
    end

    half_long = L / 2
    half_short = B / 2
    half_bx = along_x ? half_long : half_short
    half_by = along_x ? half_short : half_long

    verts, tris = _footing_box_mesh(cx, cy, 0.0, half_bx, half_by, D)
    mesh = GLMakie.GeometryBasics.Mesh(verts, tris)
    GLMakie.mesh!(ax, mesh, color=(color, alpha), transparency=true)
    _draw_box_edges!(ax, verts)

    # Dashed centreline along the strip axis
    if along_x
        GLMakie.lines!(ax,
            [GLMakie.Point3f(cx - half_bx, cy, 0.005),
             GLMakie.Point3f(cx + half_bx, cy, 0.005)],
            color=:gray30, linewidth=0.8, linestyle=:dash)
    else
        GLMakie.lines!(ax,
            [GLMakie.Point3f(cx, cy - half_by, 0.005),
             GLMakie.Point3f(cx, cy + half_by, 0.005)],
            color=:gray30, linewidth=0.8, linestyle=:dash)
    end

    # Column location markers on top face
    if show_columns
        for p in pts
            GLMakie.scatter!(ax,
                [GLMakie.Point3f(p[1], p[2], 0.01)],
                color=:gray20, markersize=6, marker=:cross)
        end
    end
end

# =============================================================================
# Mat Footing
# =============================================================================

"""
    draw_mat_footing!(ax, fdn, struc; color, alpha, show_columns, show_grid)

Draw a mat foundation as a large 3D slab with optional column markers and
internal grid lines representing analysis strips.
"""
function draw_mat_footing!(ax, fdn::Foundation, struc::BuildingStructure;
                            color=RGBAf(0.60, 0.60, 0.65, 1.0),
                            alpha=0.55, show_columns=true, show_grid=true)
    result = fdn.result
    result isa StructuralSizer.MatFootingResult || return

    B = ustrip(u"m", result.B)
    L = ustrip(u"m", result.L_ftg)
    D = ustrip(u"m", result.D)

    pts = _support_positions_m(fdn, struc)
    cx, cy, _ = _centroid_xyz(pts)

    verts, tris = _footing_box_mesh(cx, cy, 0.0, B / 2, L / 2, D)
    mesh = GLMakie.GeometryBasics.Mesh(verts, tris)
    GLMakie.mesh!(ax, mesh, color=(color, alpha), transparency=true)
    _draw_box_edges!(ax, verts; linewidth=0.8)

    z_top = 0.005  # slight offset above mat top for overlay lines

    # Grid lines (analysis strip representation)
    if show_grid && length(pts) >= 2
        xs = sort(unique(round(p[1]; digits=3) for p in pts))
        ys = sort(unique(round(p[2]; digits=3) for p in pts))

        for x in xs
            GLMakie.lines!(ax,
                [GLMakie.Point3f(x, cy - L/2, z_top),
                 GLMakie.Point3f(x, cy + L/2, z_top)],
                color=(:gray40, 0.4), linewidth=0.6, linestyle=:dash)
        end
        for y in ys
            GLMakie.lines!(ax,
                [GLMakie.Point3f(cx - B/2, y, z_top),
                 GLMakie.Point3f(cx + B/2, y, z_top)],
                color=(:gray40, 0.4), linewidth=0.6, linestyle=:dash)
        end
    end

    # Column location markers
    if show_columns
        col_pts = [GLMakie.Point3f(p[1], p[2], z_top + 0.005) for p in pts]
        GLMakie.scatter!(ax, col_pts,
            color=:gray15, markersize=7, marker=:cross)
    end
end

# =============================================================================
# Top-Level Dispatch
# =============================================================================

"""
    draw_foundations!(ax, struc; color, alpha, show_rebar, strip_color, mat_color)

Draw all foundations in the structure, dispatching to the appropriate
drawing function based on result type.

# Keyword Arguments
- `color`: Spread footing color (default `:gray70`)
- `alpha`: Spread footing transparency (default `0.7`)
- `show_rebar`: Show rebar grid on spread footings (default `false`)
- `strip_color`: Strip footing color (default slightly blue-gray)
- `strip_alpha`: Strip footing transparency (default `0.7`)
- `mat_color`: Mat footing color (default slightly cool gray)
- `mat_alpha`: Mat footing transparency (default `0.55`)
- `show_columns`: Show column markers on strip/mat (default `true`)
- `show_grid`: Show analysis grid on mat (default `true`)
"""
function draw_foundations!(ax, struc::BuildingStructure;
                           color=:gray70, alpha=0.7, show_rebar=false,
                           strip_color=RGBAf(0.55, 0.55, 0.60, 1.0),
                           strip_alpha=0.7,
                           mat_color=RGBAf(0.60, 0.60, 0.65, 1.0),
                           mat_alpha=0.55,
                           show_columns=true, show_grid=true)
    isempty(struc.foundations) && return

    for fdn in struc.foundations
        r = fdn.result
        if r isa StructuralSizer.SpreadFootingResult
            draw_spread_footing!(ax, fdn, struc;
                color=color, alpha=alpha, show_rebar=show_rebar)

        elseif r isa StructuralSizer.StripFootingResult
            draw_strip_footing!(ax, fdn, struc;
                color=strip_color, alpha=strip_alpha, show_columns=show_columns)

        elseif r isa StructuralSizer.MatFootingResult
            draw_mat_footing!(ax, fdn, struc;
                color=mat_color, alpha=mat_alpha,
                show_columns=show_columns, show_grid=show_grid)

        elseif r isa StructuralSizer.CombinedFootingResult
            # Legacy combined result — draw as spread box at centroid
            draw_spread_footing!(ax, fdn, struc;
                color=color, alpha=alpha, show_rebar=show_rebar)

        elseif r isa StructuralSizer.PileCapResult
            @debug "Pile cap visualization not yet implemented"

        else
            @debug "Unknown foundation result type: $(typeof(r))"
        end
    end
end
