# A solved rectangle feeds the solid-head checks.
#
# The corner reaction is Vu. The rib webs are one per module across the head,
# and the thinner direction is the equivalent thickness. One-way shear is the
# frame shear at d from the head face. A failing head on the rectangle grows
# on its rib bays, the same rule as any other outline.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer
using Asap

const SY = StructuralSynthesizer
const SS = StructuralSizer

function _head_kwargs(; nξ = 4, nη = 4, solid_head = 0.25, pressure = 1000.0,
                      bw = 0.15u"m", h_rib = 0.30u"m", d_rib = 0.22u"m",
                      depth = 0.30u"m", d_head = 0.25u"m",
                      column = 0.40u"m", topping = 0.10u"m")
    return (
        Lx = 6.0, Ly = 4.0, nξ = nξ, nη = nη, pressure = pressure,
        solid_head = solid_head, depth = depth, concrete = NWC_4000,
        column_x = column, column_y = column,
        d_head = d_head, bw = bw, d_rib = d_rib, h_rib = h_rib,
        topping = topping,
    )
end

@testset "a solved grillage checks each solid head" begin
    kw = _head_kwargs()
    solved = SY.analyze_rectangle_grillage(kw.Lx, kw.Ly, kw.nξ, kw.nη, kw.pressure;
                                          solid_head = kw.solid_head, depth = kw.depth,
                                          concrete = kw.concrete)
    heads = SY.check_rectangle_grillage_heads(solved;
        Lx = kw.Lx, Ly = kw.Ly, nξ = kw.nξ, nη = kw.nη, solid_head = kw.solid_head,
        column_x = kw.column_x, column_y = kw.column_y,
        d_head = kw.d_head, h_head = kw.depth,
        bw = kw.bw, d_rib = kw.d_rib, h_rib = kw.h_rib,
        concrete = kw.concrete, qu = kw.pressure * u"Pa", topping = kw.topping)
    @test length(heads) == 4
    @test sum(ustrip(u"N", h.Vu) for h in heads) ≈ kw.pressure * kw.Lx * kw.Ly rtol = 1e-4
    section = SS.rib_web_critical_section(1.5u"m", 1.0u"m", kw.d_head; position = :corner)
    for h in heads
        @test h.Vu > 1.0u"N"
        @test h.support_shear ≈ h.Vu rtol = 1e-3
        @test h.Mub ≈ 0.0u"N*m"
        @test occursin("releases the corner rotation", h.moment_note)
        @test h.classification.kind === :drop_panel
        @test h.ribs_ξ == 1 && h.ribs_η == 1
        @test h.web_direction === :ξ
        @test h.section.b0 ≈ section.b0
        @test h.check.rib_web.eccentric_shear == false
        @test h.check.rib_web.joist_increase == false
        @test all(r -> r.joist_increase == false, h.check.ribs)
        @test !isempty(h.ribs_demand)
        for rib in h.ribs_demand
            @test rib.Vu > 1.0u"N"
            @test rib.Vu < rib.at_face
        end
        @test h.check.ok
        @test h.check.governing in (:column, :rib_web, :rib_one_way)
    end
    # The reaction includes the load inside the section, and the check takes it off.
    @test heads[1].check.rib_web.Vu < heads[1].Vu

    @test_throws ArgumentError SY.check_rectangle_grillage_heads(solved;
        Lx = kw.Lx, Ly = kw.Ly, nξ = kw.nξ, nη = kw.nη, solid_head = kw.solid_head,
        column_x = kw.column_x, column_y = kw.column_y,
        d_head = 0.40u"m", h_head = kw.depth,
        bw = kw.bw, d_rib = kw.d_rib, h_rib = kw.h_rib,
        concrete = kw.concrete, qu = kw.pressure * u"Pa")
end

"""Rectangle of `nξ × nη` rib modules with a column at each corner, resolved on bays."""
function _resolve_rectangle(kw)
    Lx, Ly = kw.Lx, kw.Ly
    outline = [(0.0, 0.0), (Lx, 0.0), (Lx, Ly), (0.0, Ly)]
    arr = SS.modular_rib_arrangement(outline; angle = 0.0,
                                     spacing = (Lx / kw.nξ, Ly / kw.nη), origin = (0.0, 0.0))
    res = SY.resolve_arrangement_heads(arr, outline, kw.pressure;
        outline = outline, concrete = kw.concrete, depth = kw.depth, d_head = kw.d_head,
        bw = kw.bw, d_rib = kw.d_rib, h_rib = kw.h_rib, fy = Rebar_60.Fy,
        topping = kw.topping, column_size = kw.column_x)
    return arr, res
end

@testset "column punching chooses the side; failing ribs grow the head otherwise" begin
    east = (ok = false, ratio = 4.0, outward = (1.0, 0.0))
    north = (ok = false, ratio = 3.95, outward = (0.0, 1.0))
    passing = (ok = true, ratio = 0.5, outward = (0.0, -1.0))
    # Column punching fails and names no face: a ring, whatever the ribs say.
    ring = (direction = (1.0, 0.0), ribs = [east],
            column = (ok = false, ratio = 1.2, direction = nothing))
    @test SY._head_grows(ring)
    @test SY._head_growth_direction(ring) === nothing
    faced = (direction = (1.0, 0.0), ribs = [east],
             column = (ok = false, ratio = 1.2, direction = (0.0, 1.0)))
    @test SY._head_growth_direction(faced) == (0.0, 1.0)
    # When the column face is the slab edge, the ribs' side, then a ring.
    @test SY._head_growth_directions(faced) == [(0.0, 1.0), (1.0, 0.0), nothing]
    @test SY._head_growth_directions(ring) == [nothing, (1.0, 0.0)]
    # Column punching passes and a rib fails one-way shear: the head grows
    # toward that rib. The step is judged on the larger ratio.
    rib = (direction = nothing, ribs = [east, passing],
           column = (ok = true, ratio = 0.6, direction = nothing))
    @test SY._head_grows(rib)
    @test SY._head_growth_direction(rib) == (1.0, 0.0)
    @test SY._head_growth_ratio(rib) ≈ 4.0
    # Two failing ribs leaving in different directions name no side.
    split = (direction = nothing, ribs = [east, north],
             column = (ok = true, ratio = 0.6, direction = nothing))
    @test SY._head_growth_direction(split) === nothing
    # Only stem compression fails: the head does not grow.
    hog = (direction = (1.0, 0.0), ribs = [passing],
           column = (ok = true, ratio = 0.6, direction = nothing))
    @test !SY._head_grows(hog)
    @test SY._head_growth_ratio(hog) ≈ 0.6
end

@testset "a rectangle's corner heads grow on the bays" begin
    # A light panel passes on the seed bays, so the frame is solved once.
    light = _head_kwargs(; pressure = 1000.0)
    arr, held = _resolve_rectangle(light)
    @test held.ok && held.stop === :passed
    @test held.steps == 0
    @test all(h -> length(h.bays) == 1, held.heads)
    @test sum(held.solved.reactions) ≈ light.pressure * light.Lx * light.Ly rtol = 1e-3

    # Narrow ribs under a heavy pressure fail. Each head is a bay set that
    # contains its seed, no bay is in two heads, and a failing head is
    # reported as failing.
    heavy = _head_kwargs(; pressure = 20_000.0, bw = 0.05u"m", h_rib = 0.20u"m",
                         d_rib = 0.16u"m", d_head = 0.20u"m", column = 0.50u"m")
    arr, stuck = _resolve_rectangle(heavy)
    println("heavy: stop=", stuck.stop, " steps=", stuck.steps,
            " bays=", [length(h.bays) for h in stuck.heads],
            " gov=", [c.governing for c in stuck.checks],
            " dir=", [c.direction for c in stuck.checks],
            " ratio=", [round(c.ratio; digits = 2) for c in stuck.checks])
    @test !stuck.ok && stuck.stop === :stopped
    @test isempty(intersect(stuck.heads[1].bays, stuck.heads[3].bays))
    @test any(c -> !c.ok, stuck.checks)

    # Column punching is under 1. Ribs leaving two heads are over 1 in
    # one-way shear on concrete alone. The head grows toward them until the
    # section at d from its face passes.
    wide = _head_kwargs(; nξ = 8, nη = 8, pressure = 4_500.0,
                        bw = 0.10u"m", h_rib = 0.25u"m", d_rib = 0.20u"m",
                        d_head = 0.25u"m", column = 0.50u"m")
    arr, grew = _resolve_rectangle(wide)
    println("wide: stop=", grew.stop, " steps=", grew.steps,
            " bays=", [length(h.bays) for h in grew.heads],
            " gov=", [c.governing for c in grew.checks],
            " dir=", [c.direction for c in grew.checks],
            " ratio=", [round(c.ratio; digits = 2) for c in grew.checks])
    @test grew.ok && grew.stop === :passed
    @test grew.steps > 0
    @test any(h -> length(h.bays) > 1, grew.heads)
    @test all(c -> c.column.ok && all(r -> r.ok, c.ribs), grew.checks)
end

@testset "a solid-area cap stops a head that still fails" begin
    heavy = _head_kwargs(; pressure = 20_000.0, bw = 0.05u"m", h_rib = 0.20u"m",
                         d_rib = 0.16u"m", d_head = 0.20u"m", column = 0.50u"m")
    Lx, Ly = heavy.Lx, heavy.Ly
    outline = [(0.0, 0.0), (Lx, 0.0), (Lx, Ly), (0.0, Ly)]
    arr = SS.modular_rib_arrangement(outline; angle = 0.0,
                                     spacing = (Lx / heavy.nξ, Ly / heavy.nη),
                                     origin = (0.0, 0.0))
    capped = SY.resolve_arrangement_heads(arr, outline, heavy.pressure;
        outline = outline, concrete = heavy.concrete, depth = heavy.depth,
        d_head = heavy.d_head, bw = heavy.bw, d_rib = heavy.d_rib, h_rib = heavy.h_rib,
        fy = Rebar_60.Fy, topping = heavy.topping, column_size = heavy.column_x,
        max_solid_fraction = 0.05)
    @test !capped.ok && capped.stop === :solid_cap
    @test capped.steps == 0
end

@testset "a tight void joins a head only along a shared edge" begin
    Lx, Ly = 6.0, 4.0
    outline = [(0.0, 0.0), (Lx, 0.0), (Lx, Ly), (0.0, Ly)]
    arr = SS.modular_rib_arrangement(outline; angle = 0.0,
                                     spacing = (Lx / 4, Ly / 4),
                                     origin = (0.0, 0.0))
    corner = argmin(eachindex(arr.bays)) do bi
        pts = [arr.nodes[k] for k in arr.bays[bi].loop]
        sum(p[1] + p[2] for p in pts)
    end
    head = SS.ColumnSolidHead((0.0, 0.0), [corner])
    # Every bay is narrower than the void minimum. The cap keeps the seed.
    held = SY._close_tight_voids(arr, [head], fill(1.0, length(arr.edges)), 10.0, 0.05)
    @test held[1].bays == [corner]
    # With room to grow, tight bays fill in from the seed and stay one piece.
    closed = SY._close_tight_voids(arr, [head], fill(1.0, length(arr.edges)), 10.0, 1.0)
    @test corner in closed[1].bays
    @test length(closed[1].bays) > 1
    @test length(SS._head_sides(arr, closed[1])) > 0
end

function _head_panel_stub(; Lx = 8.0, Ly = 6.0, n = 8, s = 0.25,
                          eξ = (1.0, 0.0), eη = (0.0, 1.0))
    return (eξ = eξ, eη = eη, Lx = Lx, Ly = Ly, nξ = n, nη = n, s = s,
            bw = 0.15u"m", h = 0.30u"m")
end

@testset "the head around a column is every adjacent panel's corner" begin
    p = _head_panel_stub()
    # Four panels meet at the column: each takes one quadrant.
    four = [(p, 1, 1), (p, 0, 1), (p, 1, 0), (p, 0, 0)]
    g = SY._joint_head_geometry(four)
    @test g.position == :interior
    @test g.head_x ≈ 2 * 0.25 * 8.0u"m"
    @test g.head_y ≈ 2 * 0.25 * 6.0u"m"
    @test g.free_edge === nothing
    # Webs are one per module on each side; the thinner smear governs.
    k = SS.ribs_across_solid_head(8, 0.25)
    area = 2k * 0.15u"m" * 0.30u"m"
    @test g.web_area ≈ area
    @test g.web_area / g.head_width ≈ min(area / g.head_x, area / g.head_y)

    # Two panels on one side of the column: the free edge runs along x.
    two = [(p, 0, 0), (p, 1, 0)]
    e = SY._joint_head_geometry(two)
    @test e.position == :edge
    @test all(isapprox.(abs.(e.free_edge), (1.0, 0.0); atol = 1e-12))
    @test e.head_x ≈ 0.25 * 6.0u"m"
    @test e.head_y ≈ 2 * 0.25 * 8.0u"m"

    c = SY._joint_head_geometry([(p, 0, 0)])
    @test c.position == :corner
    @test c.head_x ≈ 2.0u"m" && c.head_y ≈ 1.5u"m"

    # Two panels on a diagonal, three around a re-entrant corner, and panels
    # that disagree on a shared side are refused.
    @test_throws ArgumentError SY._joint_head_geometry([(p, 0, 0), (p, 1, 1)])
    @test_throws ArgumentError SY._joint_head_geometry([(p, 0, 0), (p, 1, 0), (p, 0, 1)])
    long = _head_panel_stub(Ly = 9.0)
    @test_throws ArgumentError SY._joint_head_geometry([(p, 0, 0), (long, 1, 0)])
    skew = _head_panel_stub(eξ = (cos(0.3), sin(0.3)), eη = (-sin(0.3), cos(0.3)))
    @test_throws ArgumentError SY._joint_head_geometry([(p, 0, 0), (skew, 1, 0)])
end
