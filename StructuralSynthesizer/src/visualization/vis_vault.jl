# =============================================================================
# Vault Visualization
# =============================================================================
#
# Draws vault slabs as parabolic arch meshes instead of flat boxes.
# Integrates with the existing draw_slabs!/visualize(design) pipeline.
#
# Sized mode:     draw_vault!           — parabolic shell surface
# Deflected mode: draw_vault_deflected! — vault mapped onto deflected frame
#                 (bilinear interpolation of corner-node displacements)
#
# Geometry:
#   Intrados: z(x) = (4h/s²)·x·(s − x)   where h = rise, s = span
#   Extrados: z(x) = intrados(x) + thickness
# =============================================================================

"""2D dot product helper."""
_dot2(a, b) = a[1] * b[1] + a[2] * b[2]

# =============================================================================
# Core mesh builder (shared by sized and deflected modes)
# =============================================================================

"""
    _vault_mesh_data(slab, struc; n_span=40, n_depth=4)

Build the raw vertex grids for a vault's intrados and extrados surfaces.

Returns a NamedTuple with:
- `intrados`, `extrados`: `Vector{Point3f}` laid out row-major (depth × span)
- `faces`: `Vector{TriangleFace}` for the grid
- `n_s`, `n_d`: Grid dimensions
- `face_corner_indices`: Dict mapping `(row, col)` corners to skeleton vertex indices
- `cx`, `cy`, `z0`: Face centroid and elevation
- `ax_dir`, `perp_dir`: Span and depth unit vectors
- `span_min`, `span_max`, `perp_min`, `perp_max`: Extents in local coords
"""
function _vault_mesh_data(slab::Slab, struc::BuildingStructure;
                          n_span::Int=40, n_depth::Int=4)
    result = slab.result
    skel = struc.skeleton

    # ─── Face geometry ───────────────────────────────────────────────────
    cell_idx = slab.cell_indices[1]
    cell = struc.cells[cell_idx]
    v_indices = skel.face_vertex_indices[cell.face_idx]

    face_pts = [let c = Meshes.coords(skel.vertices[vi])
        (ustrip(u"m", c.x), ustrip(u"m", c.y), ustrip(u"m", c.z))
    end for vi in v_indices]

    cx = sum(p[1] for p in face_pts) / length(face_pts)
    cy = sum(p[2] for p in face_pts) / length(face_pts)
    z0 = face_pts[1][3]

    # ─── Span / depth directions ─────────────────────────────────────────
    ax_dir = slab.spans.axis
    perp_dir = (-ax_dir[2], ax_dir[1])

    span_projs = [_dot2(ax_dir,  (p[1] - cx, p[2] - cy)) for p in face_pts]
    perp_projs = [_dot2(perp_dir, (p[1] - cx, p[2] - cy)) for p in face_pts]

    span_min, span_max = extrema(span_projs)
    perp_min, perp_max = extrema(perp_projs)
    L = span_max - span_min

    # ─── Vault geometry ──────────────────────────────────────────────────
    rise_m = ustrip(u"m", result.rise)
    t_m   = ustrip(u"m", result.thickness)

    _vault_z(s) = (4.0 * rise_m / L^2) * s * (L - s)

    # ─── Vertex grids (row = depth, col = span) ─────────────────────────
    ss = range(0.0, L, length=n_span + 1)
    dd = range(perp_min, perp_max, length=n_depth + 1)

    intrados = GLMakie.Point3f[]
    extrados = GLMakie.Point3f[]

    for d in dd, s in ss
        wx = cx + (span_min + s) * ax_dir[1] + d * perp_dir[1]
        wy = cy + (span_min + s) * ax_dir[2] + d * perp_dir[2]
        zi = z0 + _vault_z(s)
        push!(intrados, GLMakie.Point3f(wx, wy, zi))
        push!(extrados, GLMakie.Point3f(wx, wy, zi + t_m))
    end

    n_s = n_span + 1
    n_d = n_depth + 1

    # ─── Triangulated faces ──────────────────────────────────────────────
    faces = GLMakie.GeometryBasics.TriangleFace{Int}[]
    for row in 1:n_d-1, col in 1:n_s-1
        i1 = (row - 1) * n_s + col
        i2 = i1 + 1
        i3 = row * n_s + col
        i4 = i3 + 1
        push!(faces, GLMakie.GeometryBasics.TriangleFace(i1, i2, i3))
        push!(faces, GLMakie.GeometryBasics.TriangleFace(i2, i4, i3))
    end

    # ─── Corner vertex indices (for deflection interpolation) ────────────
    # Map each face vertex to the (u, v) corner it's nearest to
    corner_vis = Dict{Tuple{Symbol,Symbol}, Int}()  # (:lo/:hi, :lo/:hi) → v_idx
    for (vi, fp, sp, pp) in zip(v_indices, face_pts, span_projs, perp_projs)
        sk = sp < (span_min + span_max) / 2 ? :lo : :hi
        pk = pp < (perp_min + perp_max) / 2 ? :lo : :hi
        corner_vis[(sk, pk)] = vi
    end

    return (;
        intrados, extrados, faces, n_s, n_d,
        cx, cy, z0, ax_dir, perp_dir,
        span_min, span_max, perp_min, perp_max,
        corner_vis, v_indices,
    )
end

# =============================================================================
# Sized mode: draw_vault!
# =============================================================================

"""
    draw_vault!(ax, slab::Slab, struc::BuildingStructure; kwargs...)

Draw a vault slab as a 3D parabolic shell surface (intrados + extrados + caps).

Drop-in replacement for `draw_slab!` when the slab result is a `VaultResult`.
Called automatically by `draw_slabs!`.

# Keyword Arguments
- `color=:salmon`: Surface color
- `alpha=0.6`: Surface transparency
- `n_span=40`: Mesh subdivisions along span
- `n_depth=4`: Mesh subdivisions along depth
- `show_outline=true`: Draw arch edge curves
- `outline_color=:gray30`: Outline color
- `outline_width=1.5`: Outline line width
- `show_thrust=false`: Draw thrust arrows at supports
- `thrust_color=:firebrick`: Thrust arrow color
"""
function draw_vault!(ax, slab::Slab, struc::BuildingStructure;
                     color=:salmon, alpha=0.6,
                     n_span::Int=40, n_depth::Int=4,
                     show_outline::Bool=true,
                     outline_color=:gray30, outline_width=1.5,
                     show_thrust::Bool=false,
                     thrust_color=:firebrick)
    slab.result isa StructuralSizer.VaultResult || return

    md = _vault_mesh_data(slab, struc; n_span, n_depth)

    # ─── Shell surfaces ──────────────────────────────────────────────────
    if !isempty(md.faces)
        GLMakie.mesh!(ax,
            GLMakie.GeometryBasics.Mesh(md.intrados, md.faces),
            color=(color, alpha), transparency=true)
        GLMakie.mesh!(ax,
            GLMakie.GeometryBasics.Mesh(md.extrados, md.faces),
            color=(color, alpha), transparency=true)
    end

    _draw_vault_caps!(ax, md; color, alpha)

    # ─── Outlines ────────────────────────────────────────────────────────
    if show_outline
        _draw_vault_outlines!(ax, md; outline_color, outline_width)
    end

    # ─── Thrust arrows ───────────────────────────────────────────────────
    if show_thrust
        _draw_vault_thrust!(ax, slab, md; thrust_color)
    end
end

# =============================================================================
# Deflected mode: draw_vault_deflected!
# =============================================================================

"""
    draw_vault_deflected!(ax, slab, struc, model, deflection_scale; kwargs...)

Draw a vault surface mapped onto the deflected frame.

The vault has no FEA shell mesh; instead we bilinearly interpolate the
displacements of the four face-corner nodes (from the Asap model) and
add the parabolic vault shape on top.

# Arguments
- `model`: Solved `Asap.Model` containing nodal displacements
- `deflection_scale`: Multiplier for displacements
"""
function draw_vault_deflected!(ax, slab::Slab, struc::BuildingStructure,
                               model, deflection_scale::Float64;
                               color=:salmon, alpha=0.5,
                               n_span::Int=40, n_depth::Int=4,
                               show_outline::Bool=true,
                               outline_color=:gray30, outline_width=1.0)
    slab.result isa StructuralSizer.VaultResult || return

    md = _vault_mesh_data(slab, struc; n_span, n_depth)

    # ─── Gather corner displacements ─────────────────────────────────────
    # Corners are identified by (span_lo/hi, perp_lo/hi).
    # Each corresponds to a skeleton vertex → Asap node.
    function _node_disp(vi::Int)
        vi > length(model.nodes) && return [0.0, 0.0, 0.0]
        return Asap.to_displacement_vec(model.nodes[vi].displacement)[1:3]
    end

    d00 = _node_disp(get(md.corner_vis, (:lo, :lo), 0))
    d10 = _node_disp(get(md.corner_vis, (:hi, :lo), 0))
    d01 = _node_disp(get(md.corner_vis, (:lo, :hi), 0))
    d11 = _node_disp(get(md.corner_vis, (:hi, :hi), 0))

    # ─── Bilinear interpolation of displacement for each mesh vertex ─────
    L_span = md.span_max - md.span_min
    L_perp = md.perp_max - md.perp_min
    L_span = max(L_span, 1e-6)
    L_perp = max(L_perp, 1e-6)

    function _offset_vert(pt::GLMakie.Point3f, row::Int, col::Int)
        u = (col - 1) / (md.n_s - 1)   # 0 → 1 along span
        v = (row - 1) / (md.n_d - 1)   # 0 → 1 along depth
        δ = (1 - u) * (1 - v) .* d00 .+ u * (1 - v) .* d10 .+
            (1 - u) * v .* d01 .+ u * v .* d11
        return GLMakie.Point3f(
            pt[1] + Float32(deflection_scale * δ[1]),
            pt[2] + Float32(deflection_scale * δ[2]),
            pt[3] + Float32(deflection_scale * δ[3]),
        )
    end

    # Offset all vertices
    def_intrados = GLMakie.Point3f[]
    def_extrados = GLMakie.Point3f[]
    for row in 1:md.n_d, col in 1:md.n_s
        idx = (row - 1) * md.n_s + col
        push!(def_intrados, _offset_vert(md.intrados[idx], row, col))
        push!(def_extrados, _offset_vert(md.extrados[idx], row, col))
    end

    # ─── Draw deflected surfaces ─────────────────────────────────────────
    if !isempty(md.faces)
        GLMakie.mesh!(ax,
            GLMakie.GeometryBasics.Mesh(def_intrados, md.faces),
            color=(color, alpha), transparency=true)
        GLMakie.mesh!(ax,
            GLMakie.GeometryBasics.Mesh(def_extrados, md.faces),
            color=(color, alpha), transparency=true)
    end

    # Caps + outlines on deflected geometry
    def_md = (; md..., intrados=def_intrados, extrados=def_extrados)
    _draw_vault_caps!(ax, def_md; color, alpha=alpha * 0.8)

    if show_outline
        _draw_vault_outlines!(ax, def_md; outline_color, outline_width)
    end
end

# =============================================================================
# Shared helpers (caps, outlines, thrust)
# =============================================================================

"""Draw side caps that close the vault shell at span ends and depth edges."""
function _draw_vault_caps!(ax, md; color=:salmon, alpha=0.5)
    TF = GLMakie.GeometryBasics.TriangleFace{Int}

    # Span-end caps (transverse arch cross-sections)
    for col_idx in [1, md.n_s]
        verts = GLMakie.Point3f[]
        for row in 1:md.n_d
            push!(verts, md.intrados[(row - 1) * md.n_s + col_idx])
        end
        for row in md.n_d:-1:1
            push!(verts, md.extrados[(row - 1) * md.n_s + col_idx])
        end
        n = length(verts)
        n >= 3 || continue
        faces = [TF(1, k, k + 1) for k in 2:n-1]
        GLMakie.mesh!(ax, GLMakie.GeometryBasics.Mesh(verts, faces),
            color=(color, alpha), transparency=true)
    end

    # Depth-edge caps (longitudinal arch strips)
    for row_idx in [1, md.n_d]
        verts = GLMakie.Point3f[]
        for col in 1:md.n_s
            push!(verts, md.intrados[(row_idx - 1) * md.n_s + col])
        end
        for col in md.n_s:-1:1
            push!(verts, md.extrados[(row_idx - 1) * md.n_s + col])
        end
        n = length(verts)
        n >= 3 || continue
        faces = [TF(1, k, k + 1) for k in 2:n-1]
        GLMakie.mesh!(ax, GLMakie.GeometryBasics.Mesh(verts, faces),
            color=(color, alpha), transparency=true)
    end
end

"""Draw arch outlines along the vault edges."""
function _draw_vault_outlines!(ax, md; outline_color=:gray30, outline_width=1.5)
    # Arch curves along depth edges (extrados + intrados)
    for row_idx in [1, md.n_d]
        for (verts, lw) in [(md.extrados, outline_width), (md.intrados, outline_width * 0.7)]
            curve = [verts[(row_idx - 1) * md.n_s + col] for col in 1:md.n_s]
            GLMakie.lines!(ax, curve, color=outline_color, linewidth=lw)
        end
    end
    # Corner verticals
    for row_idx in [1, md.n_d], col_idx in [1, md.n_s]
        idx = (row_idx - 1) * md.n_s + col_idx
        GLMakie.lines!(ax, [md.intrados[idx], md.extrados[idx]],
            color=outline_color, linewidth=outline_width * 0.5)
    end
    # Transverse edges at span ends
    for col_idx in [1, md.n_s]
        for verts in [md.intrados, md.extrados]
            edge = [verts[(row - 1) * md.n_s + col_idx] for row in 1:md.n_d]
            GLMakie.lines!(ax, edge, color=outline_color, linewidth=outline_width * 0.5)
        end
    end
end

"""Draw horizontal thrust arrows at vault abutments."""
function _draw_vault_thrust!(ax, slab::Slab, md; thrust_color=:firebrick)
    result = slab.result
    H = ustrip(u"kN/m", StructuralSizer.total_thrust(result))
    arrow_len = H * 0.01  # kN/m → meters (visual scale)

    for col_idx in [1, md.n_s]
        mid_row = div(md.n_d, 2) + 1
        pt = md.intrados[(mid_row - 1) * md.n_s + col_idx]
        sgn = col_idx == 1 ? -1.0 : 1.0
        dx = Float32(sgn * md.ax_dir[1] * arrow_len)
        dy = Float32(sgn * md.ax_dir[2] * arrow_len)
        GLMakie.arrows3d!(ax, [pt], [GLMakie.Vec3f(dx, dy, 0)],
            color=thrust_color, tipradius=0.06, tiplength=0.15,
            shaftradius=0.02)
    end
end

# =============================================================================
# Standalone vault figure (cross-section + 3D)
# =============================================================================

"""
    visualize_vault(design::BuildingDesign; kwargs...)
    visualize_vault(struc::BuildingStructure; kwargs...)

Presentation figure with the 3D vault building (left) and a dimensioned
cross-section of the governing vault panel (right).

# Returns
`GLMakie.Figure`

# Example
```julia
design = design_building(struc, DesignParameters(
    floor = VaultOptions(lambda=8.0),
))
fig = visualize_vault(design)
```
"""
function visualize_vault(design::BuildingDesign; kwargs...)
    return visualize_vault(design.structure; design=design, kwargs...)
end

function visualize_vault(struc::BuildingStructure;
    design::Union{BuildingDesign, Nothing} = nothing,
    color = :salmon,
    alpha::Float64 = 0.6,
    n_span::Int = 40,
    show_thrust::Bool = true,
    show_annotations::Bool = true,
    show_frame::Bool = true,
    theme::Union{Nothing, Symbol} = nothing,
)
    if theme == :light
        GLMakie.set_theme!(StructuralPlots.sp_light)
    elseif theme == :dark
        GLMakie.set_theme!(StructuralPlots.sp_dark)
    end

    skel = struc.skeleton
    model = struc.asap_model

    vault_slabs = [s for s in struc.slabs if s.result isa StructuralSizer.VaultResult]
    isempty(vault_slabs) && error("No vault slabs found in structure")

    fig = GLMakie.Figure(size=(1400, 700))

    # ═══ Left: 3D building with vault surfaces ═══════════════════════════
    ax3d = GLMakie.Axis3(fig[1, 1],
        aspect=:data,
        title="Vault Building — 3D View",
        xlabel="x [m]", ylabel="y [m]", zlabel="z [m]",
    )

    # Frame centerlines
    if show_frame && model.processed
        nan_pt = GLMakie.Point3f(NaN, NaN, NaN)
        pts = GLMakie.Point3f[]
        for el in model.elements
            p1, p2 = get_drawing_pts(el, 0.0)
            push!(pts, GLMakie.Point3f(p1...), GLMakie.Point3f(p2...), nan_pt)
        end
        !isempty(pts) && GLMakie.lines!(ax3d, pts, color=(:gray50, 0.7), linewidth=1.5)
    end

    # Supports
    sup_vis = get(skel.groups_vertices, :support, Int[])
    if !isempty(sup_vis)
        sp = [let c = Meshes.coords(skel.vertices[vi])
            GLMakie.Point3f(ustrip(u"m", c.x), ustrip(u"m", c.y), ustrip(u"m", c.z))
        end for vi in sup_vis]
        GLMakie.scatter!(ax3d, sp, color=:red, marker=:utriangle, markersize=12)
    end

    # Vault surfaces
    for slab in vault_slabs
        draw_vault!(ax3d, slab, struc; color, alpha, n_span, show_thrust)
    end

    # Nodes
    if model.processed
        n_sk = length(skel.vertices)
        npts = [GLMakie.Point3f(ustrip.(u"m", n.position)...) for n in model.nodes[1:min(n_sk, end)]]
        GLMakie.scatter!(ax3d, npts, color=:black, markersize=5)
    end

    # ═══ Right: governing vault cross-section ════════════════════════════
    gov = argmax(s -> s.result.stress_check.ratio, vault_slabs)
    r = gov.result
    span_m = ustrip(u"m", gov.spans.primary)
    rise_m = ustrip(u"m", r.rise)
    t_m    = ustrip(u"m", r.thickness)
    H_tot  = ustrip(u"kN/m", StructuralSizer.total_thrust(r))

    ax2d = GLMakie.Axis(fig[1, 2],
        title="Vault Cross-Section",
        xlabel="Span [m]", ylabel="Height [m]",
        aspect=GLMakie.DataAspect(),
    )

    xs = range(0.0, span_m, length=200)
    zi = [(4.0 * rise_m / span_m^2) * x * (span_m - x) for x in xs]
    ze = [z + t_m for z in zi]

    GLMakie.band!(ax2d, xs, zi, ze, color=(color, 0.4))
    GLMakie.lines!(ax2d, xs, zi, color=:gray30, linewidth=2, label="Intrados")
    GLMakie.lines!(ax2d, xs, ze, color=:gray60, linewidth=1.5, linestyle=:dash, label="Extrados")

    # Abutment lines
    GLMakie.lines!(ax2d, [0.0, 0.0], [-0.3, ze[1] + 0.1], color=:gray40, linewidth=1)
    GLMakie.lines!(ax2d, [span_m, span_m], [-0.3, ze[end] + 0.1], color=:gray40, linewidth=1)

    # Thrust arrows
    if show_thrust
        al = span_m * 0.12
        GLMakie.arrows2d!(ax2d, [0.0], [0.0], [-al], [0.0],
            color=:firebrick, shaftwidth=3, tipwidth=10, tiplength=8)
        GLMakie.arrows2d!(ax2d, [span_m], [0.0], [al], [0.0],
            color=:firebrick, shaftwidth=3, tipwidth=10, tiplength=8)
        GLMakie.text!(ax2d, -al * 0.5, -rise_m * 0.15,
            text="H = $(round(H_tot, digits=1)) kN/m",
            fontsize=11, color=:firebrick, align=(:center, :top))
    end

    # Annotations
    if show_annotations
        yd = -rise_m * 0.25
        GLMakie.lines!(ax2d, [0.0, span_m], [yd, yd], color=:black, linewidth=0.8)
        GLMakie.scatter!(ax2d, [0.0, span_m], [yd, yd], color=:black, markersize=5)
        GLMakie.text!(ax2d, span_m / 2, yd - rise_m * 0.06,
            text="L = $(round(span_m, digits=2)) m  ($(round(ustrip(u"ft", gov.spans.primary), digits=1))')",
            fontsize=11, align=(:center, :top))

        xm = span_m / 2
        GLMakie.lines!(ax2d, [xm, xm], [0.0, rise_m], color=:steelblue, linewidth=0.8, linestyle=:dot)
        GLMakie.text!(ax2d, xm + span_m * 0.03, rise_m / 2,
            text="h = $(round(rise_m * 100, digits=1)) cm",
            fontsize=10, color=:steelblue, align=(:left, :center))

        xq = span_m * 0.25
        zqi = (4.0 * rise_m / span_m^2) * xq * (span_m - xq)
        zqe = zqi + t_m
        GLMakie.lines!(ax2d, [xq, xq], [zqi, zqe], color=:darkorange, linewidth=2)
        GLMakie.text!(ax2d, xq - span_m * 0.02, (zqi + zqe) / 2,
            text="t = $(round(t_m * 1000, digits=0)) mm",
            fontsize=10, color=:darkorange, align=(:right, :center))

        λ = span_m / rise_m
        GLMakie.text!(ax2d, span_m * 0.95, rise_m * 0.95,
            text="λ = $(round(λ, digits=1))",
            fontsize=11, align=(:right, :top))
    end

    GLMakie.axislegend(ax2d, position=:rt, framevisible=false, labelsize=10)

    # ═══ Info panel ══════════════════════════════════════════════════════
    info = """
    ─── Vault Design ───
    Span: $(round(span_m, digits=2)) m    Rise: $(round(rise_m*100, digits=1)) cm    Shell: $(round(t_m*1000, digits=0)) mm    λ: $(round(span_m/rise_m, digits=1))
    Thrust (D): $(round(ustrip(u"kN/m", r.thrust_dead), digits=1)) kN/m    Thrust (L): $(round(ustrip(u"kN/m", r.thrust_live), digits=1)) kN/m    Total: $(round(H_tot, digits=1)) kN/m
    σ_max: $(round(r.σ_max, digits=2)) MPa    σ_allow: $(round(r.stress_check.σ_allow, digits=2)) MPa    ratio: $(round(r.stress_check.ratio, digits=3))
    Adequate: $(StructuralSizer.is_adequate(r) ? "YES" : "NO")    Governs: $(r.governing_case)
    """
    GLMakie.Label(fig[2, 1:2], info, fontsize=11, halign=:left, valign=:top, padding=(10, 10, 5, 5))
    GLMakie.rowsize!(fig.layout, 2, GLMakie.Auto())

    display(fig)
    return fig
end
