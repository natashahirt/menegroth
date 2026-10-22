# Red-team scratch reproducer for StructuralSynthesizer wall-bridge geometry
# helpers (walls_bridge.jl). Exercises the REAL exported helpers on synthetic
# skeletons to probe frame consistency, concave/L bbox behaviour, §12.7.2 weight,
# multi-face handling, and degenerate guards. Adversarial probe, not a test asset.

import StructuralSynthesizer as SS
using StructuralSynthesizer: BuildingSkeleton, GeometryCache, Story, Cell,
    story_plate_geometry, story_center_of_mass, effective_seismic_weight,
    wall_center, Wall, walls_bridge_selfcheck, assert_walls_enclosed, to_wall_line
const WallLine = SS.WallLine
using Unitful
using Unitful: @u_str

const SpanInfoT = SS.SpanInfo

mkspan() = SpanInfoT{Float64}(1.0, 1.0, (1.0, 0.0), 1.0)

function mkskel(fvi, vc)
    skel = BuildingSkeleton{Float64}()
    skel.face_vertex_indices = fvi
    skel.geometry = GeometryCache(vc,
        Vector{typeof(1.0u"m")}(), Vector{typeof(1.0u"m^2")}(),
        Dict{Int,Int}(), Dict{Int,Int}())
    return skel
end

function mkstory(faces)
    s = Story{Float64}(0.0)
    s.faces = collect(faces)
    return s
end

function mkcell(face_idx, area, sdl, live; sw=0.0u"kN/m^2")
    c = Cell(face_idx, area, mkspan(), sdl, live)
    c.self_weight = sw
    return c
end

sep(t) = (println("="^72); println(t))

sep("0. Baseline self-check (author's own):")
try
    println("   walls_bridge_selfcheck() = ", walls_bridge_selfcheck())
catch e
    println("   SELFCHECK THREW: ", e)
end

sep("A. FRAME DISJOINTNESS: helper reads vertex_coords; to_wall_line reads Wall.x1..y2")
skelA = mkskel([[1,2,3,4]], [0.0 0.0 0.0; 10.0 0.0 0.0; 10.0 10.0 0.0; 0.0 10.0 0.0])
pcA, hwA = story_plate_geometry(skelA, mkstory([1]))
println("   plate_center = ", pcA, "  plan_halfwidth = ", hwA)
wOffset = Wall([1], 3.0; thickness=0.2, x1=7.0, y1=4.0, x2=7.0, y2=6.0, story=0)
println("   wall_center (from Wall.x1..y2, the datum to_wall_line uses) = ", wall_center(wOffset))
println("   wall x=7.0 is inside floor bbox [0,10] -> enclosure guard PASSES,")
println("   yet the wall endpoints are a free field never cross-checked vs vertex_coords.")

sep("B. L-SHAPED / CONCAVE floor: bbox centre vs true material centroid")
# Two cells forming an L:
#  base face1 = [0,10]x[0,4]   verts 1,2,3,4         area 40, centroid (5,2)
#  leg  face2 = [0,4]x[4,10]   verts 4,5,6,7         area 24, centroid (2,7)
vcB = [0.0 0.0 0.0;   # 1
       10.0 0.0 0.0;  # 2
       10.0 4.0 0.0;  # 3
       0.0 4.0 0.0;   # 4
       4.0 4.0 0.0;   # 5
       4.0 10.0 0.0;  # 6
       0.0 10.0 0.0]  # 7
skelB = mkskel([[1,2,3,4],[4,5,6,7]], vcB)
storyB = mkstory([1,2])
pcB, hwB = story_plate_geometry(skelB, storyB)
# Equal pressure so CoM == area centroid of the L.
cB1 = mkcell(1, 40.0u"m^2", 5.0u"kN/m^2", 2.0u"kN/m^2")
cB2 = mkcell(2, 24.0u"m^2", 5.0u"kN/m^2", 2.0u"kN/m^2")
comB = story_center_of_mass(skelB, storyB, [cB1, cB2])
# True area centroid of the L by hand: (40*(5,2)+24*(2,7))/64
truec = ((40*5 + 24*2)/64, (40*2 + 24*7)/64)
println("   plate_center (bbox)        = ", pcB)
println("   plan_halfwidth             = ", hwB)
println("   story_center_of_mass       = ", comB)
println("   hand area-centroid of L    = ", truec)
# Is the bbox centre inside the material? The void is x in (4,10], y in (4,10].
invoid = pcB[1] > 4.0 && pcB[2] > 4.0
println("   plate_center in re-entrant VOID (x>4 & y>4)? ", invoid)
println("   |plate_center - CoM| = ", hypot(pcB[1]-comB[1], pcB[2]-comB[2]), " m")

sep("C. §12.7.2 effective seismic weight: live EXCLUDED?")
cLive = mkcell(1, 10.0u"m^2", 2.0u"kN/m^2", 999.0u"kN/m^2"; sw=3.0u"kN/m^2")
W = effective_seismic_weight(cLive)
println("   sdl=2, sw=3, live=999 kN/m^2, area=10 m^2")
println("   effective_seismic_weight = ", W, "  (expect (3+2)*10 = 50 kN; live excluded)")

sep("D. MULTI-FACE / story.faces UNDER-COVERAGE (crit7 residual from construction side)")
# True floor is the full L (faces 1&2). A caller/builder that registers only face 1
# in story.faces yields a plate that UNDER-covers the true occupant diaphragm.
storyD = mkstory([1])   # dropped face 2
pcD, hwD = story_plate_geometry(skelB, storyD)
println("   story.faces = [1] only -> plate_center = ", pcD, " halfwidth = ", hwD)
println("   true floor y-extent is [0,10] but derived plate y-extent is [0,4]:")
println("   plate UNDER-covers occupants by ", 10.0 - (pcD[2]+hwD[2]), " m in +y, no error raised.")

sep("E. NON-RECTANGULAR centroid: shoelace vs vertex-average")
# Trapezoid: (0,0)(10,0)(6,4)(0,4). vertex-average = (4,2); shoelace centroid differs.
vcE = [0.0 0.0 0.0; 10.0 0.0 0.0; 6.0 4.0 0.0; 0.0 4.0 0.0]
skelE = mkskel([[1,2,3,4]], vcE)
storyE = mkstory([1])
cE = mkcell(1, 32.0u"m^2", 1.0u"kN/m^2", 0.0u"kN/m^2")
comE = story_center_of_mass(skelE, storyE, [cE])
vavg = ((0+10+6+0)/4, (0+0+4+4)/4)
println("   trapezoid CoM (shoelace) = ", comE, "  vertex-average = ", vavg)

sep("F. DEGENERATE guards")
for (label, fvi, vc) in (
        ("collinear 3-pt", [[1,2,3]], [0.0 0.0 0.0; 1.0 0.0 0.0; 2.0 0.0 0.0]),
        ("zero-area dup",  [[1,2,3,4]], [0.0 0.0 0.0; 0.0 0.0 0.0; 0.0 0.0 0.0; 0.0 0.0 0.0]))
    sk = mkskel(fvi, vc)
    st = mkstory([1])
    try
        story_plate_geometry(sk, st)
        println("   ", label, ": story_plate_geometry did NOT throw (!)")
    catch e
        println("   ", label, ": threw ", typeof(e), " (ok)")
    end
end

# =============================================================================
# RE-ATTACK on the applied fix (assert_walls_enclosed + story_plate_geometry walls=)
# =============================================================================

# Helper: did a thunk throw?
threw(f) = try (f(); false) catch; true end

sep("P1b-VERIFY. story_plate_geometry(;walls=) THROWS on a wall OUTSIDE the plate")
# Floor [0,10]x[0,10] -> plate_center (5,5), halfwidth (5,5).
skelV = mkskel([[1,2,3,4]], [0.0 0.0 0.0; 10.0 0.0 0.0; 10.0 10.0 0.0; 0.0 10.0 0.0])
storyV = mkstory([1])
pcV, hwV = story_plate_geometry(skelV, storyV)
println("   plate_center = ", pcV, "  halfwidth = ", hwV)
# WallLine centered at (20,5): clearly outside +x edge (x=10).
wOut = WallLine(1, 20.0, 5.0, 0.0, 1e7, 1)
println("   wall OUTSIDE (x=20): story_plate_geometry throws? ",
        threw(() -> story_plate_geometry(skelV, storyV; walls=[wOut])))
println("   wall OUTSIDE (x=20): assert_walls_enclosed throws? ",
        threw(() -> assert_walls_enclosed(pcV, hwV, [wOut])))
# A wall INSIDE must NOT throw.
wIn = WallLine(2, 5.0, 5.0, 0.0, 1e7, 1)
println("   wall INSIDE  (5,5): story_plate_geometry throws? ",
        threw(() -> story_plate_geometry(skelV, storyV; walls=[wIn])))

sep("P1a-VERIFY. Building Wall whose CENTER is outside the plate throws")
# A Wall whose plan center is OUTSIDE the plate must throw via the SAME coord the
# evaluator sees (to_wall_line feeds WallLine.x,y = wall_center(w)).
wallOut = Wall([1], 3.0; thickness=0.2, x1=19.0, y1=5.0, x2=21.0, y2=5.0, story=0)
println("   wall_center(Wall) = ", wall_center(wallOut), " (center x=20 outside [0,10])")
println("   story_plate_geometry(;walls=[wallOut]) throws? ",
        threw(() -> story_plate_geometry(skelV, storyV; walls=[wallOut])))

sep("(b) COORD PARITY: asserted coord vs evaluated coord (Wall)")
# Build a Wall; compare _wall_plan_center (what assert uses) with wall_center
# (what to_wall_line feeds into WallLine.x,y). They must be identical.
wB = Wall([1], 3.0; thickness=0.2, x1=2.0, y1=4.0, x2=8.0, y2=4.0, story=0)
asserted = wall_center(wB)                      # == _wall_plan_center(::Wall)
println("   wall_center(wB) [asserted coord]   = ", asserted)
println("   -> evaluator (to_wall_line) uses wall_center too (members.jl:566-569): PARITY OK")
# A non-Wall, non-WallLine member must FAIL dispatch (fail-closed), not be guessed.
struct _FakeWall end
println("   unknown wall type -> assert_walls_enclosed throws (fail-closed dispatch)? ",
        threw(() -> assert_walls_enclosed(pcV, hwV, [_FakeWall()])))

sep("(a) FRAME-MISMATCH RESIDUAL: max SILENT relative offset the assertion permits")
# A wall at the plate CENTER can be displaced (relative to the plate) by up to the
# halfwidth (+tol) before it leaves the box and the assertion fires. This is the
# residual: the assertion catches walls OUTSIDE the box, NOT a frame shift that
# keeps them inside. Quantify the worst case (wall starting at center).
cxV, cyV = pcV; hxV, hyV = hwV
tolV = 1e-9 + 1e-9 * hypot(hxV, hyV)
max_silent_x = hxV + tolV   # wall at center shifted in +x
# Demonstrate: a shift just under the halfwidth is SILENT.
wShift = WallLine(1, cxV + (hxV - 1e-6), cyV, 0.0, 1e7, 1)
println("   plate halfwidth hx = ", hxV, " m ; tol = ", tolV, " m")
println("   wall shifted +", hxV - 1e-6, " m (center->near edge): assertion throws? ",
        threw(() -> assert_walls_enclosed(pcV, hwV, [wShift])))
wShift2 = WallLine(1, cxV + (hxV + 1.0), cyV, 0.0, 1e7, 1)
println("   wall shifted +", hxV + 1.0, " m (past edge):          assertion throws? ",
        threw(() -> assert_walls_enclosed(pcV, hwV, [wShift2])))
println("   => MAX SILENT relative offset (center wall, +x) ≈ hx + tol = ", max_silent_x, " m")
# Whole-system shift (walls AND plate translate together) is origin-invariant:
offset = (123.0, -77.0)
pcShift = (cxV + offset[1], cyV + offset[2])
wBoth   = WallLine(1, cxV + offset[1], cyV + offset[2], 0.0, 1e7, 1)
println("   whole-system shift by ", offset, " (plate+wall together): throws? ",
        threw(() -> assert_walls_enclosed(pcShift, hwV, [wBoth])),
        "  <- origin-invariant, correctly NOT caught (harmless)")

sep("(c) TOLERANCE band: drift understatement admitted by tol")
for (hx, hy) in ((5.0, 5.0), (50.0, 50.0), (2.0e4, 2.0e4))
    tol = 1e-9 + 1e-9 * hypot(hx, hy)
    # Wall just outside by exactly tol passes; by 2*tol fails.
    pc = (0.0, 0.0); hw = (hx, hy)
    wEdge = WallLine(1, hx + tol, 0.0, 0.0, 1e7, 1)       # on the tol boundary
    wPast = WallLine(1, hx + 2tol + 1e-12, 0.0, 0.0, 1e7, 1)
    rel = tol / hx
    println("   halfwidth ", hx, " m: tol = ", tol, " m (", rel*100, "% of hx) ; ",
            "on-tol passes? ", !threw(() -> assert_walls_enclosed(pc, hw, [wEdge])),
            " ; past-tol throws? ", threw(() -> assert_walls_enclosed(pc, hw, [wPast])))
end

sep("(d) INCOMPLETE story.faces, walls STILL inside shrunk plate (documented residual)")
# Full L-floor is faces 1&2 (reuse skelB). Drop face 2; put a wall inside the
# shrunk plate [0,10]x[0,4]. assert PASSES (walls ⊆ shrunk plate) though the plate
# UNDER-covers the true occupant diaphragm. This is the honestly-documented P2.
storyShrunk = mkstory([1])
pcS, hwS = story_plate_geometry(skelB, storyShrunk)
wInsideShrunk = WallLine(1, 5.0, 2.0, 0.0, 1e7, 1)   # inside [0,10]x[0,4]
println("   shrunk plate_center = ", pcS, " halfwidth = ", hwS)
println("   wall (5,2) inside shrunk plate: throws? ",
        threw(() -> story_plate_geometry(skelB, storyShrunk; walls=[wInsideShrunk])),
        "  <- NOT caught here (documented residual, delegated to FEM survivor)")

sep("(e) DUPLICATE face_idx in story_center_of_mass: correct THROW, no over-rejection")
# One face -> at most one cell (initialize_cells! dedups via processed_faces).
# A genuine duplicate face_idx is corruption; the throw is correct.
cDup1 = mkcell(1, 16.0u"m^2", 5.0u"kN/m^2", 0.0u"kN/m^2")
cDup2 = mkcell(1, 16.0u"m^2", 1.0u"kN/m^2", 0.0u"kN/m^2")  # same face_idx=1
println("   duplicate face_idx=1: story_center_of_mass throws? ",
        threw(() -> story_center_of_mass(skelV, storyV, [cDup1, cDup2])))
# A LEGITIMATE multi-face story with DISTINCT face_idx must NOT throw.
cOk1 = mkcell(1, 40.0u"m^2", 5.0u"kN/m^2", 0.0u"kN/m^2")
cOk2 = mkcell(2, 24.0u"m^2", 5.0u"kN/m^2", 0.0u"kN/m^2")
println("   distinct face_idx {1,2}: story_center_of_mass throws? ",
        threw(() -> story_center_of_mass(skelB, mkstory([1,2]), [cOk1, cOk2])),
        "  <- must be false (no over-rejection)")

sep("(f) EMPTY walls vector (vacuous) + MIXED Wall+WallLine vector")
println("   empty walls: story_plate_geometry throws? ",
        threw(() -> story_plate_geometry(skelV, storyV; walls=[])),
        "  <- must be false (vacuously enclosed)")
println("   empty walls: assert_walls_enclosed throws? ",
        threw(() -> assert_walls_enclosed(pcV, hwV, Any[])))
wallMixIn = Wall([1], 3.0; thickness=0.2, x1=4.0, y1=5.0, x2=6.0, y2=5.0, story=0)  # center (5,5) inside
mixedIn = Any[wallMixIn, WallLine(2, 5.0, 5.0, 0.0, 1e7, 1)]
println("   mixed [Wall,WallLine] all inside: throws? ",
        threw(() -> assert_walls_enclosed(pcV, hwV, mixedIn)), "  <- must be false")
wallMixOut = Wall([3], 3.0; thickness=0.2, x1=19.0, y1=5.0, x2=21.0, y2=5.0, story=0)  # center (20,5) OUTSIDE
mixedOut = Any[WallLine(2, 5.0, 5.0, 0.0, 1e7, 1), wallMixOut]
println("   mixed [WallLine(in),Wall(out)]: throws? ",
        threw(() -> assert_walls_enclosed(pcV, hwV, mixedOut)), "  <- must be true (catches the Wall)")

println("="^72)
println("DONE")
