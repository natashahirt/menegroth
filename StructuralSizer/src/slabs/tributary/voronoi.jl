# Voronoi Vertex Tributary Computation
#
# Computes tributary areas for vertices (column locations) using Voronoi tessellation.
# Uses DelaunayTriangulation.jl for Voronoi, Meshes.jl for boundary clipping.
# Handles both convex and concave polygons correctly.

import DelaunayTriangulation as DT
import Meshes
using Unitful: ustrip, @u_str

"""
    VertexTributary

Tributary area result for a single vertex (column location).

# Fields
- `vertex_idx::Int`: Index of the vertex in the source geometry
- `polygon::Vector{NTuple{2, Float64}}`: Tributary polygon vertices (CCW, meters)
- `area::Float64`: Tributary area in m²
- `position::Symbol`: `:interior`, `:edge`, or `:corner`
"""
struct VertexTributary
    vertex_idx::Int
    polygon::Vector{NTuple{2, Float64}}
    area::Float64
    position::Symbol
end

"""
    compute_voronoi_tributaries(vertices; floor_boundary=nothing) -> Vector{VertexTributary}

Compute Voronoi vertex tributary areas for a set of column positions.

Uses DelaunayTriangulation.jl for Voronoi computation, then clips each cell
to the actual floor boundary using Meshes.jl. Handles both convex and concave
boundaries correctly.

# Arguments
- `vertices`: Column positions as Vector of NTuple{2, Float64}
- `floor_boundary`: Floor polygon vertices (Vector of tuples). Required for
  proper clipping. If not provided, clips to convex hull only.

# Returns
Vector of `VertexTributary` in the same order as input vertices.
"""
function compute_voronoi_tributaries(
    vertices::Vector{NTuple{2, Float64}};
    floor_boundary = nothing
)
    isempty(vertices) && return VertexTributary[]
    n = length(vertices)
    
    # Single point case
    if n == 1
        return [_single_vertex_tributary(vertices[1], floor_boundary)]
    end
    
    # Determine boundary
    boundary_pts = if !isnothing(floor_boundary)
        _extract_boundary_points(floor_boundary)
    else
        vertices  # Use vertices as boundary (convex hull)
    end
    
    # Create boundary polygon for clipping
    boundary_poly = _create_meshes_polygon(boundary_pts)
    
    # Add tiny perturbation to avoid degenerate cases
    perturbed = _perturb_points(vertices)
    
    # Compute Delaunay triangulation and Voronoi
    tri = DT.triangulate(perturbed)
    vorn = DT.voronoi(tri; clip=true)  # Clip to convex hull first
    
    # Process each Voronoi cell, clipping to actual boundary
    tributaries = VertexTributary[]
    for i in 1:n
        # Get Voronoi cell polygon
        voronoi_poly = _get_voronoi_polygon(vorn, i)
        
        if isnothing(voronoi_poly) || isnothing(boundary_poly)
            # Fallback: equal division
            area = _voronoi_polygon_area(boundary_pts) / n
            push!(tributaries, VertexTributary(i, NTuple{2,Float64}[], area, :corner))
            continue
        end
        
        # Clip Voronoi cell to actual boundary (handles concave!)
        clipped = _clip_to_boundary(voronoi_poly, boundary_poly)
        
        if isnothing(clipped)
            # Intersection failed, use small fallback
            push!(tributaries, VertexTributary(i, NTuple{2,Float64}[], 0.0, :corner))
            continue
        end
        
        # Extract clipped polygon vertices and area
        poly_verts = _extract_polygon_vertices(clipped)
        area = _meshes_area(clipped)
        position = _classify_position(poly_verts)
        
        push!(tributaries, VertexTributary(i, poly_verts, area, position))
    end
    
    return tributaries
end

"""Get Voronoi cell as Meshes polygon."""
function _get_voronoi_polygon(vorn, vertex_idx::Int)
    verts = NTuple{2, Float64}[]
    
    try
        cell_indices = DT.get_polygon(vorn, vertex_idx)
        for v_idx in cell_indices
            if v_idx > 0
                pt = DT.get_polygon_point(vorn, v_idx)
                push!(verts, (Float64(pt[1]), Float64(pt[2])))
            end
        end
    catch
        return nothing
    end
    
    length(verts) < 3 && return nothing
    return _create_meshes_polygon(verts)
end

"""Create Meshes.PolyArea from vertices."""
function _create_meshes_polygon(verts::Vector{NTuple{2, Float64}})
    length(verts) < 3 && return nothing
    try
        points = [Meshes.Point(v[1], v[2]) for v in verts]
        return Meshes.PolyArea(points)
    catch
        return nothing
    end
end

"""Clip polygon to boundary using Meshes.jl intersection."""
function _clip_to_boundary(poly::Meshes.Geometry, boundary::Meshes.Geometry)
    try
        return poly ∩ boundary
    catch
        return nothing
    end
end

"""Extract vertices from Meshes geometry as tuples."""
function _extract_polygon_vertices(geom)
    verts = NTuple{2, Float64}[]
    isnothing(geom) && return verts
    
    # Handle different geometry types from intersection
    if geom isa Meshes.Multi
        # Multi-polygon: take the first/largest part
        for part in geom
            part_verts = _extract_polygon_vertices(part)
            if length(part_verts) > length(verts)
                verts = part_verts
            end
        end
        return verts
    end
    
    # Extract vertices from single polygon
    try
        for v in Meshes.vertices(geom)
            c = Meshes.coords(v)
            # Handle both unitful and unitless coordinates
            x = _to_float_meters(c.x)
            y = _to_float_meters(c.y)
            push!(verts, (x, y))
        end
    catch
        # Empty on error
    end
    return verts
end

"""Get area from Meshes geometry."""
function _meshes_area(geom)
    isnothing(geom) && return 0.0
    
    try
        # Handle Multi geometries
        if geom isa Meshes.Multi
            return sum(_meshes_area(part) for part in geom)
        end
        
        m = Meshes.measure(geom)
        return m isa Unitful.Quantity ? Float64(ustrip(u"m^2", m)) : Float64(m)
    catch
        return 0.0
    end
end

"""Classify vertex position based on polygon geometry."""
function _classify_position(poly_verts::Vector{NTuple{2, Float64}})
    n_sides = length(poly_verts)
    if n_sides <= 4
        return :corner
    elseif n_sides <= 5
        return :edge
    else
        return :interior
    end
end

"""Add tiny deterministic perturbation to avoid Voronoi degeneracies."""
function _perturb_points(vertices::Vector{NTuple{2, Float64}})
    ε = 1e-4  # 0.1 mm in meters
    return [(
        v[1] + ε * sin(i * 1.1),
        v[2] + ε * cos(i * 1.3)
    ) for (i, v) in enumerate(vertices)]
end

"""Handle single vertex case."""
function _single_vertex_tributary(vertex::NTuple{2, Float64}, floor_boundary)
    if isnothing(floor_boundary)
        return VertexTributary(1, [vertex], 0.0, :interior)
    else
        boundary_pts = _extract_boundary_points(floor_boundary)
        area = _voronoi_polygon_area(boundary_pts)
        return VertexTributary(1, boundary_pts, area, :interior)
    end
end

"""Extract boundary points as Vector of tuples."""
function _extract_boundary_points(boundary)
    if boundary isa Vector{NTuple{2, Float64}}
        return boundary
    elseif boundary isa Vector{<:Tuple}
        return [(Float64(p[1]), Float64(p[2])) for p in boundary]
    else
        # Assume Meshes.Geometry
        pts = NTuple{2, Float64}[]
        for v in Meshes.vertices(boundary)
            c = Meshes.coords(v)
            x = _to_float_meters(c.x)
            y = _to_float_meters(c.y)
            push!(pts, (x, y))
        end
        return pts
    end
end

"""Compute polygon area using shoelace formula."""
function _voronoi_polygon_area(verts::Vector{NTuple{2, Float64}})
    n = length(verts)
    n < 3 && return 0.0
    
    area = 0.0
    for i in 1:n
        j = mod1(i + 1, n)
        area += verts[i][1] * verts[j][2]
        area -= verts[j][1] * verts[i][2]
    end
    return abs(area) / 2.0
end

"""Convert coordinate to Float64 meters."""
function _to_float_meters(x)
    if x isa Unitful.Quantity
        return Float64(ustrip(u"m", x))
    else
        return Float64(x)
    end
end
