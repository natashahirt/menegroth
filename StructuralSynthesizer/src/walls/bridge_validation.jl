
"""
    assert_story_walls_enclosed!(struc) -> Nothing

Run the plate-enclosure check for every skeleton story that has at least
one building [`Wall`](@ref).

`Wall.story` is 0-based (the same key as `edge_story` / `skeleton.stories`).
[`to_wall_line`](@ref) sets `WallLine.story = Wall.story + 1` because
`WallLine.story` is 1-based; this check does not add 1. Stories with no
walls are skipped. For each story that has walls, calls
[`story_plate_geometry`](@ref) with those walls, which runs
[`assert_walls_enclosed`](@ref) on [`wall_center`](@ref). A wall center
outside the story's floor faces throws `ArgumentError`. A `Wall.story`
that is not a skeleton story key also throws.

Called at the end of [`initialize!`](@ref), after [`initialize_members!`](@ref).
"""
function assert_story_walls_enclosed!(struc::BuildingStructure)
    skel = struc.skeleton
    walls_by_story = Dict{Int, Vector{eltype(struc.walls)}}()
    for w in struc.walls
        haskey(skel.stories, w.story) || throw(ArgumentError(
            "assert_story_walls_enclosed!: Wall.story $(w.story) is not a skeleton " *
            "story key. Wall.story is 0-based; WallLine.story is Wall.story + 1 " *
            "via to_wall_line, and that +1 is not applied here."))
        push!(get!(walls_by_story, w.story, eltype(struc.walls)[]), w)
    end
    for (story_idx, story) in skel.stories
        walls = get(walls_by_story, story_idx, nothing)
        (walls === nothing || isempty(walls)) && continue
        story_plate_geometry(skel, story; walls=walls)
    end
    return nothing
end

"""
    walls_bridge_selfcheck() -> Bool

Self-check for the wall-bridge geometry derivations. Builds a small synthetic
two-cell skeleton with an **off-origin** footprint and **asymmetric** cell mass,
then asserts:

1. `story_plate_geometry` reproduces the true bounding box, with
   `plate_center ≠ (0,0)` (eccentric plate).
2. `story_center_of_mass` matches a hand-computed weight-weighted centroid and
   lands **off** `plate_center`.
3. A degenerate (collinear) footprint throws.

Returns `true` on success; throws `AssertionError` (or a geometry error) on any
failure. Not run at load time; call explicitly from tests or the REPL.
"""
function walls_bridge_selfcheck()
    approx(a, b) = isapprox(a, b; atol = 1e-9, rtol = 1e-9)

    # --- synthetic skeleton: two unit-height rectangles sharing edge 2–3 ------
    # Vertices (x, y, z):  off-origin footprint x∈[2,10], y∈[0,4].
    #   1:(2,0) 2:(6,0) 3:(6,4) 4:(2,4) 5:(10,0) 6:(10,4)
    # Face 1 (cell A): [1,2,3,4] → x∈[2,6], centroid (4,2), area 16 m².
    # Face 2 (cell B): [2,5,6,3] → x∈[6,10], centroid (8,2), area 16 m².
    skel = BuildingSkeleton{Float64}()
    skel.face_vertex_indices = [[1, 2, 3, 4], [2, 5, 6, 3]]
    vc = [2.0 0.0 0.0;
          6.0 0.0 0.0;
          6.0 4.0 0.0;
          2.0 4.0 0.0;
          10.0 0.0 0.0;
          10.0 4.0 0.0]
    skel.geometry = GeometryCache(vc,
                                  Vector{typeof(1.0u"m")}(),
                                  Vector{typeof(1.0u"m^2")}(),
                                  Dict{Int,Int}(), Dict{Int,Int}())
    story = Story{Float64}(0.0)
    story.faces = [1, 2]

    # --- (1) plate geometry ---------------------------------------------------
    (pc, hw) = story_plate_geometry(skel, story)
    @assert approx(pc[1], 6.0) && approx(pc[2], 2.0) "plate_center expected (6,2), got $pc"
    @assert approx(hw[1], 4.0) && approx(hw[2], 2.0) "plan_halfwidth expected (4,2), got $hw"
    @assert !(approx(pc[1], 0.0) && approx(pc[2], 0.0)) "plate_center must be off-origin"

    # --- (2) centre of mass (asymmetric) -------------------------------------
    # Dead loads via sdl (self_weight left 0): A = 5 kN/m², B = 1 kN/m².
    #   W_A = 5·16 = 80 kN at (4,2);  W_B = 1·16 = 16 kN at (8,2)
    #   ex = (80·4 + 16·8)/96 = 448/96 = 4.666…,  ey = 2
    spans = SpanInfo{Float64}(1.0, 1.0, (1.0, 0.0), 1.0)
    cellA = Cell(1, 16.0u"m^2", spans, 5.0u"kN/m^2", 3.0u"kN/m^2")
    cellB = Cell(2, 16.0u"m^2", spans, 1.0u"kN/m^2", 3.0u"kN/m^2")
    @assert approx(ustrip(u"kN", effective_seismic_weight(cellA)), 80.0) "W_A expected 80 kN"
    @assert approx(ustrip(u"kN", effective_seismic_weight(cellB)), 16.0) "W_B expected 16 kN"

    (ex, ey) = story_center_of_mass(skel, story, [cellA, cellB])
    @assert approx(ex, 448.0 / 96.0) "CoM ex expected $(448/96), got $ex"
    @assert approx(ey, 2.0) "CoM ey expected 2, got $ey"
    @assert !approx(ex, pc[1]) "CoM must be eccentric to plate_center in x"

    # --- (3) degenerate footprint throws -------------------------------------
    degen = BuildingSkeleton{Float64}()
    degen.face_vertex_indices = [[1, 2, 3]]
    degen.geometry = GeometryCache([0.0 0.0 0.0; 1.0 0.0 0.0; 2.0 0.0 0.0],
                                   Vector{typeof(1.0u"m")}(),
                                   Vector{typeof(1.0u"m^2")}(),
                                   Dict{Int,Int}(), Dict{Int,Int}())
    dstory = Story{Float64}(0.0)
    dstory.faces = [1]
    threw = false
    try
        story_plate_geometry(degen, dstory)
    catch
        threw = true
    end
    @assert threw "degenerate (collinear) footprint must throw"

    return true
end
