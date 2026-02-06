# =============================================================================
# Section Drawing for Visualization
# =============================================================================
#
# Drawing functions for section visualization using GLMakie.
# Imports geometry traits and getters from StructuralSizer.
#
# Modes:
#   :ends  - 2D section silhouettes at member endpoints
#   :solid - 3D extruded sections using composed primitives
# =============================================================================

using GeometryBasics: Point3f, Vec3f, Cylinder, Mesh, TriangleFace
using LinearAlgebra: norm, normalize, cross
using Unitful: ustrip, @u_str

# Import visualization interface from StructuralSizer
using StructuralSizer: AbstractSectionGeometry, SolidRect, HollowRect, HollowRound, IShape
using StructuralSizer: section_geometry
using StructuralSizer: section_width, section_depth, section_thickness
using StructuralSizer: section_flange_width, section_flange_thickness, section_web_thickness
using StructuralSizer: has_rebar, section_rebar_positions, section_rebar_radius

# Helper to strip units to meters for visualization
_to_m(x) = Float32(ustrip(u"m", x))

# =============================================================================
# Axis Rotation Helpers
# =============================================================================

"""
    rotation_matrix_to_axis(axis::Vec3f) -> Matrix{Float32}

Compute rotation matrix that transforms local X-axis to align with `axis`.
Local Y and Z become perpendicular to the member axis (for section drawing).
"""
function rotation_matrix_to_axis(axis::Vec3f)
    x_local = normalize(axis)
    
    # Choose an "up" vector that isn't parallel to axis
    up = abs(x_local[3]) < 0.9 ? Vec3f(0, 0, 1) : Vec3f(1, 0, 0)
    
    # Local Y = up × axis (perpendicular to axis, roughly horizontal)
    y_local = normalize(cross(up, x_local))
    
    # Local Z = X × Y (perpendicular to both)
    z_local = normalize(cross(x_local, y_local))
    
    # Rotation matrix: columns are local axes in global coords
    return Float32[
        x_local[1] y_local[1] z_local[1];
        x_local[2] y_local[2] z_local[2];
        x_local[3] y_local[3] z_local[3]
    ]
end

"""Transform a local 2D point (y, z) to 3D global coordinates at position."""
function local_to_global(y::Float64, z::Float64, position::Point3f, R::Matrix{Float32})
    local_pt = Vec3f(0, Float32(y), Float32(z))
    return position + Point3f((R * local_pt)...)
end

# =============================================================================
# 2D Section Polygons (for :ends mode)
# =============================================================================

"""
    section_polygon(sec) -> Vector{NTuple{2, Float64}}

Return the 2D outline polygon of a section in local y-z coordinates.
Origin at section centroid, y = width direction, z = depth direction.

Dispatches on `section_geometry(sec)` trait from StructuralSizer.
"""
section_polygon(sec) = _section_polygon(section_geometry(sec), sec)

# --- Solid Rectangular ---
function _section_polygon(::SolidRect, sec)
    w = section_width(sec)
    d = section_depth(sec)
    return NTuple{2, Float64}[
        (-w/2, -d/2), (w/2, -d/2), (w/2, d/2), (-w/2, d/2)
    ]
end

# --- Hollow Rectangular ---
function _section_polygon(::HollowRect, sec)
    w = section_width(sec)
    d = section_depth(sec)
    return NTuple{2, Float64}[
        (-w/2, -d/2), (w/2, -d/2), (w/2, d/2), (-w/2, d/2)
    ]
end

"""Return inner polygon for hollow sections."""
function section_polygon_inner(sec)
    geom = section_geometry(sec)
    (geom isa HollowRect || geom isa HollowRound) || return nothing
    _section_polygon_inner(geom, sec)
end

function _section_polygon_inner(::HollowRect, sec)
    w = section_width(sec)
    d = section_depth(sec)
    t = section_thickness(sec)
    return NTuple{2, Float64}[
        (-w/2 + t, -d/2 + t), (w/2 - t, -d/2 + t), 
        (w/2 - t, d/2 - t), (-w/2 + t, d/2 - t)
    ]
end

# --- Hollow Round ---
function _section_polygon(::HollowRound, sec; n_segments::Int=24)
    r = section_width(sec) / 2  # OD/2
    θ = range(0, 2π, length=n_segments+1)[1:end-1]
    return NTuple{2, Float64}[(r * cos(t), r * sin(t)) for t in θ]
end

function _section_polygon_inner(::HollowRound, sec; n_segments::Int=24)
    r = (section_width(sec) - 2*section_thickness(sec)) / 2  # ID/2
    θ = range(0, 2π, length=n_segments+1)[1:end-1]
    return NTuple{2, Float64}[(r * cos(t), r * sin(t)) for t in θ]
end

# --- I-Shape ---
function _section_polygon(::IShape, sec)
    d = section_depth(sec)
    bf = section_flange_width(sec)
    tw = section_web_thickness(sec)
    tf = section_flange_thickness(sec)
    
    # I-shape profile (12 vertices, CCW from bottom-left)
    return NTuple{2, Float64}[
        (-bf/2, -d/2),           # 1: bottom-left flange corner
        (-bf/2, -d/2 + tf),      # 2: bottom flange top-left
        (-tw/2, -d/2 + tf),      # 3: web bottom-left
        (-tw/2, d/2 - tf),       # 4: web top-left
        (-bf/2, d/2 - tf),       # 5: top flange bottom-left
        (-bf/2, d/2),            # 6: top-left corner
        (bf/2, d/2),             # 7: top-right corner
        (bf/2, d/2 - tf),        # 8: top flange bottom-right
        (tw/2, d/2 - tf),        # 9: web top-right
        (tw/2, -d/2 + tf),       # 10: web bottom-right
        (bf/2, -d/2 + tf),       # 11: bottom flange top-right
        (bf/2, -d/2),            # 12: bottom-right corner
    ]
end

# =============================================================================
# 3D Section Primitives (for :solid mode)
# =============================================================================

"""
    section_boxes(sec, p1::Point3f, p2::Point3f) -> Vector{Tuple{Point3f, Vec3f}}

Return (center, dimensions) tuples for boxes that compose the section.
Dispatches on geometry trait.
"""
section_boxes(sec, p1::Point3f, p2::Point3f) = _section_boxes(section_geometry(sec), sec, p1, p2)

# --- Solid Rectangular ---
function _section_boxes(::SolidRect, sec, p1::Point3f, p2::Point3f)
    w = _to_m(section_width(sec))
    h = _to_m(section_depth(sec))
    L = Float32(norm(p2 - p1))
    center = (p1 + p2) / 2
    return [(center, Vec3f(L, w, h))]
end

# --- Hollow Rectangular (approximate as solid for simplicity) ---
function _section_boxes(::HollowRect, sec, p1::Point3f, p2::Point3f)
    w = _to_m(section_width(sec))
    h = _to_m(section_depth(sec))
    L = Float32(norm(p2 - p1))
    center = (p1 + p2) / 2
    return [(center, Vec3f(L, w, h))]
end

# --- Hollow Round (handled separately with Cylinder) ---
function _section_boxes(::HollowRound, sec, p1::Point3f, p2::Point3f)
    return Tuple{Point3f, Vec3f}[]  # draw_section_solid! handles this specially
end

# --- I-Shape (3 boxes: 2 flanges + web) ---
function _section_boxes(::IShape, sec, p1::Point3f, p2::Point3f)
    d = _to_m(section_depth(sec))
    bf = _to_m(section_flange_width(sec))
    tw = _to_m(section_web_thickness(sec))
    tf = _to_m(section_flange_thickness(sec))
    
    L = Float32(norm(p2 - p1))
    center = (p1 + p2) / 2
    axis = normalize(p2 - p1)
    R = rotation_matrix_to_axis(Vec3f(axis...))
    
    # Offsets in local z (depth direction)
    z_top = (d/2 - tf/2)
    z_bot = -(d/2 - tf/2)
    hw = d - 2*tf  # web height
    
    # Transform local offsets to global
    top_offset = Point3f((R * Vec3f(0, 0, z_top))...)
    bot_offset = Point3f((R * Vec3f(0, 0, z_bot))...)
    
    return [
        (center + top_offset, Vec3f(L, bf, tf)),   # top flange
        (center + bot_offset, Vec3f(L, bf, tf)),   # bottom flange
        (center, Vec3f(L, tw, hw)),                 # web
    ]
end

# =============================================================================
# Drawing Functions
# =============================================================================

"""
    draw_section_ends!(ax, sec, p1::Point3f, p2::Point3f; kwargs...)

Draw 2D section silhouettes at both ends of a member.
"""
function draw_section_ends!(ax, sec, p1::Point3f, p2::Point3f;
                            color = :steelblue,
                            alpha = 0.7,
                            linecolor = :black,
                            linewidth = 1.0,
                            scale = 1.0)
    axis = Vec3f(normalize(p2 - p1)...)
    R = rotation_matrix_to_axis(axis)
    
    poly = section_polygon(sec)
    isempty(poly) && return
    
    # Draw at both ends
    for position in [p1, p2]
        # Transform polygon to 3D
        pts_3d = [local_to_global(pt[1] * scale, pt[2] * scale, position, R) for pt in poly]
        
        # Close the polygon
        push!(pts_3d, pts_3d[1])
        
        # Draw filled polygon
        if length(pts_3d) >= 4
            n = length(pts_3d) - 1
            faces = [TriangleFace(1, k, k+1) for k in 2:n-1]
            mesh = Mesh(pts_3d[1:n], faces)
            GLMakie.mesh!(ax, mesh, color = (color, alpha), transparency = true)
        end
        
        # Draw outline
        GLMakie.lines!(ax, pts_3d, color = linecolor, linewidth = linewidth)
        
        # Draw inner polygon for hollow sections
        inner = section_polygon_inner(sec)
        if !isnothing(inner) && !isempty(inner)
            inner_3d = [local_to_global(pt[1] * scale, pt[2] * scale, position, R) for pt in inner]
            push!(inner_3d, inner_3d[1])
            GLMakie.lines!(ax, inner_3d, color = linecolor, linewidth = linewidth)
        end
    end
    
    # Draw rebar for RC sections
    if has_rebar(sec)
        rebar_pts = section_rebar_positions(sec)
        rebar_r = section_rebar_radius(sec) * scale
        
        for position in [p1, p2]
            for (y, z) in rebar_pts
                center = local_to_global(y * scale, z * scale, position, R)
                GLMakie.scatter!(ax, [center], color = :black, markersize = rebar_r * 500)
            end
        end
    end
end

"""
    draw_section_solid!(ax, sec, p1::Point3f, p2::Point3f; kwargs...)

Draw 3D extruded section as composed box primitives (or cylinder for round).
"""
function draw_section_solid!(ax, sec, p1::Point3f, p2::Point3f;
                             color = :steelblue,
                             alpha = 0.8)
    geom = section_geometry(sec)
    
    # Special handling for round sections
    if geom isa HollowRound
        _draw_cylinder!(ax, sec, p1, p2; color=color, alpha=alpha)
        return
    end
    
    axis = Vec3f(normalize(p2 - p1)...)
    R = rotation_matrix_to_axis(axis)
    
    boxes = section_boxes(sec, p1, p2)
    
    for (center, dims) in boxes
        L, w, h = dims
        
        # 8 corners of box in local coords (axis = X direction)
        local_corners = [
            Vec3f(-L/2, -w/2, -h/2), Vec3f(L/2, -w/2, -h/2),
            Vec3f(L/2, w/2, -h/2), Vec3f(-L/2, w/2, -h/2),
            Vec3f(-L/2, -w/2, h/2), Vec3f(L/2, -w/2, h/2),
            Vec3f(L/2, w/2, h/2), Vec3f(-L/2, w/2, h/2),
        ]
        
        # Transform to global
        global_corners = [Point3f(center + (R * corner)...) for corner in local_corners]
        
        # Box faces (12 triangles)
        faces = [
            TriangleFace(1, 2, 3), TriangleFace(1, 3, 4),  # bottom
            TriangleFace(5, 7, 6), TriangleFace(5, 8, 7),  # top
            TriangleFace(1, 5, 6), TriangleFace(1, 6, 2),  # front
            TriangleFace(4, 3, 7), TriangleFace(4, 7, 8),  # back
            TriangleFace(1, 4, 8), TriangleFace(1, 8, 5),  # left
            TriangleFace(2, 6, 7), TriangleFace(2, 7, 3),  # right
        ]
        
        mesh = Mesh(global_corners, faces)
        GLMakie.mesh!(ax, mesh, color = (color, alpha), transparency = true)
    end
end

"""Draw round section as cylinder."""
function _draw_cylinder!(ax, sec, p1::Point3f, p2::Point3f; color, alpha)
    r = _to_m(section_width(sec)) / 2  # OD/2
    cyl = Cylinder(p1, p2, r)
    GLMakie.mesh!(ax, cyl, color = (color, alpha), transparency = true)
end

# =============================================================================
# Section Colors (trait-based)
# =============================================================================

"""Default colors for geometry types."""
const GEOMETRY_COLORS = Dict{Type{<:AbstractSectionGeometry}, Symbol}(
    SolidRect => :gray60,
    HollowRect => :slategray,
    HollowRound => :cadetblue,
    IShape => :steelblue,
)

"""Get color for a section based on its geometry trait."""
function section_color(sec)
    geom = section_geometry(sec)
    return get(GEOMETRY_COLORS, typeof(geom), :gray70)
end

"""Get color based on material (more specific than geometry)."""
function section_color_by_material(sec)
    if sec isa StructuralSizer.RCColumnSection || sec isa StructuralSizer.RCBeamSection
        return :gray55
    elseif sec isa StructuralSizer.GlulamSection
        return :burlywood
    elseif sec isa StructuralSizer.ISymmSection
        return :steelblue
    elseif sec isa StructuralSizer.HSSRectSection
        return :slategray
    elseif sec isa StructuralSizer.HSSRoundSection
        return :cadetblue
    else
        return section_color(sec)
    end
end
