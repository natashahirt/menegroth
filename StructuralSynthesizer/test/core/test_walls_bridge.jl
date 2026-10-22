# =============================================================================
# Wall-bridge geometry derivation tests (src/walls_bridge.jl)
# =============================================================================
#
# SAFETY-CRITICAL: these helpers feed the reduced lateral (wall) evaluator. If
# the plate frame or centre of mass is wrong, interstory corner drift and the
# torsional eccentricity handed to the evaluator are wrong. The tests here are
# known-answer (hand-computed) checks against a small synthetic, OFF-ORIGIN,
# asymmetric-mass skeleton, plus a frame-consistency cross-check against
# `to_wall_line` (the datum the walls themselves resolve against) and a
# degenerate-geometry guard.
#
# Geometry used throughout (two unit-height rectangles sharing edge 2–3):
#   Vertices (x, y, z) — off-origin footprint x∈[2,10], y∈[0,4]:
#     1:(2,0) 2:(6,0) 3:(6,4) 4:(2,4) 5:(10,0) 6:(10,4)
#   Face 1 (cell A): [1,2,3,4] → x∈[2,6], centroid (4,2), area 16 m²
#   Face 2 (cell B): [2,5,6,3] → x∈[6,10], centroid (8,2), area 16 m²
#   ⇒ true bbox: plate_center (6,2), plan_halfwidth (4,2)
# =============================================================================

using StructuralSynthesizer
using StructuralSizer
using Unitful
using Asap  # resolves u"kN", u"m", etc. via the Asap unit module
using Test

# --- shared synthetic-skeleton builder ---------------------------------------
# Returns a populated two-cell BuildingSkeleton + its single Story. Built exactly
# like walls_bridge_selfcheck's fixture so the tests exercise the same datum the
# production code reads (GeometryCache.vertex_coords).
function _wb_build_skeleton()
    skel = BuildingSkeleton{Float64}()
    skel.face_vertex_indices = [[1, 2, 3, 4], [2, 5, 6, 3]]
    vc = [ 2.0  0.0  0.0;
           6.0  0.0  0.0;
           6.0  4.0  0.0;
           2.0  4.0  0.0;
          10.0  0.0  0.0;
          10.0  4.0  0.0]
    skel.geometry = GeometryCache(vc,
                                  Vector{typeof(1.0u"m")}(),
                                  Vector{typeof(1.0u"m^2")}(),
                                  Dict{Int,Int}(), Dict{Int,Int}())
    story = Story{Float64}(0.0)
    story.faces = [1, 2]
    return skel, story
end

# Two cells with ASYMMETRIC dead load carried on sdl (self_weight left at 0):
#   cell A dead 5 kN/m², cell B dead 1 kN/m²; live load (3 kN/m²) must NOT enter W.
function _wb_build_cells()
    spans = StructuralSynthesizer.SpanInfo{Float64}(1.0, 1.0, (1.0, 0.0), 1.0)
    cellA = Cell(1, 16.0u"m^2", spans, 5.0u"kN/m^2", 3.0u"kN/m^2")
    cellB = Cell(2, 16.0u"m^2", spans, 1.0u"kN/m^2", 3.0u"kN/m^2")
    return cellA, cellB
end

# --- single-square [0,10]² fixture for the enclosure self-check tests ---------
# A single axis-aligned unit-mass square floor spanning x∈[0,10], y∈[0,10], so the
# derived plate is the clean, known box: plate_center (5,5), plan_halfwidth (5,5).
# This makes "inside / on-edge / outside" wall centers trivial to reason about
# (e.g. a wall center at x=12 is unambiguously one plan-unit beyond the +x edge).
#   Vertices: 1:(0,0) 2:(10,0) 3:(10,10) 4:(0,10);  Face 1: [1,2,3,4]
function _wb_build_square_skeleton()
    skel = BuildingSkeleton{Float64}()
    skel.face_vertex_indices = [[1, 2, 3, 4]]
    vc = [ 0.0   0.0  0.0;
          10.0   0.0  0.0;
          10.0  10.0  0.0;
           0.0  10.0  0.0]
    skel.geometry = GeometryCache(vc,
                                  Vector{typeof(1.0u"m")}(),
                                  Vector{typeof(1.0u"m^2")}(),
                                  Dict{Int,Int}(), Dict{Int,Int}())
    story = Story{Float64}(0.0)
    story.faces = [1]
    return skel, story
end

# A building `Wall` whose plan center is exactly `(cx, cy)`: a short vertical pier
# centered there (x1=x2=cx, y1=cy-1, y2=cy+1 ⇒ wall_center == (cx, cy)). Used to
# exercise the `Wall` input type of the enclosure check alongside `WallLine`.
function _wb_wall_at(cx::Float64, cy::Float64)
    return Wall([1], 3.0u"m"; thickness = 0.2u"m",
                x1 = cx, y1 = cy - 1.0, x2 = cx, y2 = cy + 1.0,
                story = 0, concrete = NWC_4000)
end

@testset "Walls Bridge Geometry" begin

    # ── (1) BBOX: true, off-origin plate; cross-check against _chat_geo_envelope
    # Why interesting: an eccentric plate is the case where a (0,0)-anchored or
    # half-footprint bug is silently wrong on a centred one. We assert the center
    # is the REAL center (not the origin) and that 2·halfwidth reproduces the
    # independent chat-geometry footprint on identical vertices.
    @testset "BBOX reproduces true off-origin bbox" begin
        skel, story = _wb_build_skeleton()
        (plate_center, plan_halfwidth) = story_plate_geometry(skel, story)

        # Known answer from the hand-computed bbox.
        @test isapprox(plate_center[1], 6.0; atol = 1e-9)
        @test isapprox(plate_center[2], 2.0; atol = 1e-9)
        @test isapprox(plan_halfwidth[1], 4.0; atol = 1e-9)
        @test isapprox(plan_halfwidth[2], 2.0; atol = 1e-9)

        # Eccentric plate: center must NOT collapse to the origin.
        @test !(isapprox(plate_center[1], 0.0; atol = 1e-9) &&
                isapprox(plate_center[2], 0.0; atol = 1e-9))

        # Cross-check against the independent chat-geometry envelope on the SAME
        # vertices: 2·plan_halfwidth == (footprint_x, footprint_y).
        verts = [[2.0, 0.0, 0.0], [6.0, 0.0, 0.0], [6.0, 4.0, 0.0],
                 [2.0, 4.0, 0.0], [10.0, 0.0, 0.0], [10.0, 4.0, 0.0]]
        env = StructuralSynthesizer._chat_geo_envelope(verts, "m")
        @test env !== nothing
        @test isapprox(2 * plan_halfwidth[1], env["footprint_x"]; atol = 1e-6)
        @test isapprox(2 * plan_halfwidth[2], env["footprint_y"]; atol = 1e-6)
    end

    # ── (2) CoM: mass-weighted centroid for asymmetric cell masses, OFF center
    # Why interesting: equal-area cells with unequal mass must pull the centre of
    # mass toward the heavy cell — a pure area (unweighted) centroid would land on
    # plate_center (6,2); the correct mass-weighted result must not.
    #   W_A = 5·16 = 80 kN at (4,2);  W_B = 1·16 = 16 kN at (8,2)
    #   ex = (80·4 + 16·8)/96 = 448/96 = 4.666…,  ey = 2
    @testset "CoM is mass-weighted and eccentric" begin
        skel, story = _wb_build_skeleton()
        cellA, cellB = _wb_build_cells()

        # Seismic weight excludes live load (ASCE 7-22 §12.7.2): dead only.
        @test isapprox(ustrip(u"kN", effective_seismic_weight(cellA)), 80.0; atol = 1e-9)
        @test isapprox(ustrip(u"kN", effective_seismic_weight(cellB)), 16.0; atol = 1e-9)

        (ex, ey) = story_center_of_mass(skel, story, [cellA, cellB])
        @test isapprox(ex, 448.0 / 96.0; atol = 1e-9)
        @test isapprox(ey, 2.0; atol = 1e-9)

        # Must land OFF the geometric plate center (6,2) — pulled toward cell A.
        (plate_center, _) = story_plate_geometry(skel, story)
        @test !isapprox(ex, plate_center[1]; atol = 1e-6)
        @test ex < plate_center[1]   # heavier cell A is at x=4 < 6
    end

    # ── (3) FRAME CONSISTENCY: plate geometry agrees with to_wall_line's frame
    # Why interesting: the whole point of walls_bridge is that its plate frame is
    # the SAME datum the walls resolve against. A wall placed exactly on the plate
    # edge must have its WallLine plan coordinate one half-width from plate_center.
    @testset "Plate frame matches to_wall_line frame" begin
        skel, story = _wb_build_skeleton()
        (plate_center, plan_halfwidth) = story_plate_geometry(skel, story)

        # Wall along the RIGHT plate edge x=10, from (10,0) to (10,4):
        # wall_center = (10, 2) → WallLine.x = 10, WallLine.y = 2.
        w = Wall([1], 3.0u"m"; thickness = 0.2u"m",
                 x1 = 10.0, y1 = 0.0, x2 = 10.0, y2 = 4.0,
                 story = 0, concrete = NWC_4000)
        wl = to_wall_line(w, 1, NWC_4000)

        # Same frame ⇒ a wall on the +x plate edge sits one x-half-width out.
        @test isapprox(abs(wl.x - plate_center[1]), plan_halfwidth[1]; atol = 1e-9)
        # And it lies on the center line in y (0 half-widths out).
        @test isapprox(abs(wl.y - plate_center[2]), 0.0; atol = 1e-9)
        # Sanity: WallLine coord equals the raw wall_center in the same frame.
        @test isapprox(wl.x, wall_center(w)[1]; atol = 1e-9)
        @test isapprox(wl.y, wall_center(w)[2]; atol = 1e-9)
    end

    # ── (4) DEGENERATE: a collinear / zero-area floor must FAIL CLOSED (throw)
    # Why interesting: returning a zero-size plate silently would make drift
    # checks divide by zero or pass vacuously. The helper must throw instead.
    @testset "Degenerate footprint throws" begin
        degen = BuildingSkeleton{Float64}()
        degen.face_vertex_indices = [[1, 2, 3]]
        degen.geometry = GeometryCache([0.0 0.0 0.0; 1.0 0.0 0.0; 2.0 0.0 0.0],
                                       Vector{typeof(1.0u"m")}(),
                                       Vector{typeof(1.0u"m^2")}(),
                                       Dict{Int,Int}(), Dict{Int,Int}())
        dstory = Story{Float64}(0.0)
        dstory.faces = [1]
        # Collinear points along x ⇒ zero y-span ⇒ degenerate footprint.
        @test_throws ArgumentError story_plate_geometry(degen, dstory)
    end

    # ── (5) Built-in self-check returns true (the source's own invariant guard).
    @testset "walls_bridge_selfcheck()" begin
        @test walls_bridge_selfcheck() == true
    end

    # =========================================================================
    # ENCLOSURE SELF-CHECK (walls=...) — the SAFE path that feeds the reduced
    # lateral evaluator. story_plate_geometry(skeleton, story; walls=...) VERIFIES
    # (does not assume) that every wall plan center lies inside — or exactly on —
    # the derived plate, failing CLOSED (ArgumentError) otherwise. Fixture:
    # single-square floor [0,10]² ⇒ plate_center (5,5), plan_halfwidth (5,5).
    # =========================================================================

    # ── (6) ENCLOSURE PASS: all wall centers inside the derived plate ⇒ no throw,
    # and the plate returned is unchanged by the (satisfied) check. Interesting
    # because the SAFE path must be transparent when the contract holds. Exercises
    # BOTH wall input types (WallLine and building Wall).
    @testset "Enclosure PASS: walls inside derived plate" begin
        skel, story = _wb_build_square_skeleton()
        base = story_plate_geometry(skel, story)         # no-walls reference plate
        @test base == ((5.0, 5.0), (5.0, 5.0))           # sanity on the fixture

        # WallLines strictly inside [0,10]²: center, near a corner, near an edge.
        wls = StructuralSizer.WallLine[
            StructuralSizer.WallLine(1, 5.0, 5.0, 0.0,    1.0e9, 1),
            StructuralSizer.WallLine(2, 2.0, 8.0, pi / 2, 1.0e9, 1),
            StructuralSizer.WallLine(3, 9.0, 1.0, 0.0,    1.0e9, 1),
        ]
        # The SAFE path returns the SAME plate and does NOT throw.
        @test story_plate_geometry(skel, story; walls = wls) == base
        # Direct assertion is a no-op (returns nothing) when all walls are inside.
        @test assert_walls_enclosed(base[1], base[2], wls) === nothing

        # Same contract honored for a building Wall whose center (4,5) is inside.
        wall_in = _wb_wall_at(4.0, 5.0)
        @test wall_center(wall_in) == (4.0, 5.0)
        @test story_plate_geometry(skel, story; walls = [wall_in]) == base
    end

    # ── (7) ENCLOSURE FAIL-CLOSED: a wall center OUTSIDE the plate must THROW.
    # The core safety property: a frame mismatch / incomplete story.faces (a wall
    # at x=12, one plan-unit beyond the +x edge at x=10) is caught, never silently
    # mis-located. Verified for BOTH input types (WallLine and building Wall), via
    # both story_plate_geometry(; walls=...) and assert_walls_enclosed directly.
    @testset "Enclosure FAIL-CLOSED: wall outside plate throws" begin
        skel, story = _wb_build_square_skeleton()
        pc, hw = (5.0, 5.0), (5.0, 5.0)

        # (a) WallLine center (12,5): x=12 > 10+tol ⇒ outside the +x edge.
        bad_wl = StructuralSizer.WallLine(1, 12.0, 5.0, 0.0, 1.0e9, 1)
        @test bad_wl.x == 12.0
        @test_throws ArgumentError story_plate_geometry(skel, story; walls = [bad_wl])
        @test_throws ArgumentError assert_walls_enclosed(pc, hw, [bad_wl])

        # (b) Building Wall center (12,5): x1=x2=12 ⇒ wall_center x = 12 ⇒ outside.
        bad_wall = _wb_wall_at(12.0, 5.0)
        @test wall_center(bad_wall)[1] == 12.0
        @test_throws ArgumentError story_plate_geometry(skel, story; walls = [bad_wall])
        @test_throws ArgumentError assert_walls_enclosed(pc, hw, [bad_wall])

        # A single bad wall mixed with good ones still fails closed.
        good = StructuralSizer.WallLine(2, 5.0, 5.0, 0.0, 1.0e9, 1)
        @test_throws ArgumentError story_plate_geometry(skel, story; walls = [good, bad_wl])
    end

    # ── (8) BOUNDARY: a wall center EXACTLY on the plate edge is ACCEPTED (no
    # throw). The tolerance tol = 1e-9 + 1e-9·hypot(hx,hy) makes on-boundary pass
    # despite float assembly noise; a genuine over-hang (test 7) still fails. Edge
    # case split: +x edge (x=10) and the corner (10,10), WallLine and Wall.
    @testset "Boundary: wall center on plate edge accepted" begin
        skel, story = _wb_build_square_skeleton()
        base = ((5.0, 5.0), (5.0, 5.0))

        # WallLine exactly on the +x edge: |w.x - cx| == hx == 5 ⇒ on boundary.
        edge_wl = StructuralSizer.WallLine(1, 10.0, 5.0, 0.0, 1.0e9, 1)
        @test story_plate_geometry(skel, story; walls = [edge_wl]) == base
        @test assert_walls_enclosed(base[1], base[2], [edge_wl]) === nothing

        # Building Wall exactly on the (10,10) corner: on both the +x and +y edges.
        corner_wall = _wb_wall_at(10.0, 10.0)
        @test wall_center(corner_wall) == (10.0, 10.0)
        @test story_plate_geometry(skel, story; walls = [corner_wall]) == base
        @test assert_walls_enclosed(base[1], base[2], [corner_wall]) === nothing
    end

    # ── (9) EMPTY walls: nothing to enclose ⇒ vacuously enclosed (no throw), for
    # an empty vector of either wall type and for assert_walls_enclosed directly.
    @testset "Empty walls vector is vacuously enclosed" begin
        skel, story = _wb_build_square_skeleton()
        base = ((5.0, 5.0), (5.0, 5.0))
        @test story_plate_geometry(skel, story; walls = StructuralSizer.WallLine[]) == base
        @test story_plate_geometry(skel, story; walls = Wall[]) == base
        @test assert_walls_enclosed(base[1], base[2], StructuralSizer.WallLine[]) === nothing
    end

    # ── (10) DUPLICATE face_idx: Cell.face_idx is contractually unique per cell
    # (initialize_cells! dedups faces). A duplicate signals a CORRUPTED cell vector
    # that would silently drop floor mass from the mass-weighted centroid, so
    # story_center_of_mass must FAIL CLOSED (throw) rather than let a later cell
    # overwrite an earlier one.
    @testset "Duplicate Cell.face_idx throws (corrupted cell vector)" begin
        skel, story = _wb_build_skeleton()
        cellA, _ = _wb_build_cells()
        # A second cell re-using face_idx == 1 (same face as cellA).
        spans = StructuralSynthesizer.SpanInfo{Float64}(1.0, 1.0, (1.0, 0.0), 1.0)
        cell_dup = Cell(1, 16.0u"m^2", spans, 1.0u"kN/m^2", 3.0u"kN/m^2")
        @test cellA.face_idx == cell_dup.face_idx == 1
        @test_throws ArgumentError story_center_of_mass(skel, story, [cellA, cell_dup])
    end

    # ── (11) BACK-COMPAT: the default (walls=nothing) path is byte-identical to
    # the pre-enclosure behavior. The check-free plate must equal the walls=nothing
    # plate for both fixtures — so adding the self-check did not perturb the plate.
    @testset "Back-compat: walls=nothing matches check-free plate" begin
        skel, story = _wb_build_skeleton()
        @test story_plate_geometry(skel, story; walls = nothing) ==
              story_plate_geometry(skel, story)

        sskel, sstory = _wb_build_square_skeleton()
        @test story_plate_geometry(sskel, sstory; walls = nothing) ==
              story_plate_geometry(sskel, sstory)
    end

end
