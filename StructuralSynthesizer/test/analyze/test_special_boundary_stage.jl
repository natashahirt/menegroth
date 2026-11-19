# §18.10.6.3 on the pier forces unless the pier is the base of a continuous
# line, hwcs/ℓw ≥ 2, and δu is passed. Continuity comes from the stack.

using Test
using Unitful
using Meshes
using StructuralSynthesizer

const _BD = StructuralSynthesizer.special_boundary_decision
const _EQ = :strength_1_2D_1_0E

function _wall(; story=0, height=4.0, thick=0.3, x1=0.0, y1=0.0, x2=6.0, y2=0.0,
               openings=WallOpening[])
    return Wall([1], height * u"m"; thickness=thick * u"m",
                x1=x1, y1=y1, x2=x2, y2=y2, story=story, openings=openings)
end

function _link!(below, above)
    below.wall_above = above
    return below
end

function _eq(N, M=0.0)
    return StructuralSynthesizer.CombinedWallAction(_EQ, :only, Float64(N), 0.0, Float64(M))
end

function _decide(wall, actions; walls=nothing, assembly=nothing, index=1, fc_floor=nothing,
               section_length=nothing, hu_override=nothing, δu=nothing)
    return _BD(wall, walls === nothing ? [wall] : walls, index, assembly, actions, RC_4000_60;
               fc_floor, section_length, hu_override, δu)
end

"Axial force whose uniform stress is `ratio` times f′c, in newtons."
function _axial(ratio, lw=6.0, t=0.3)
    fc = ustrip(u"Pa", RC_4000_60.concrete.fc′)
    return ratio * fc * (lw * t)
end

@testset "Continuity is the stack, and a critical section is not assumed" begin
    ground = _wall()
    @test StructuralSynthesizer.wall_stack_continuous(ground, [ground])
    upper = _wall(; story=1)
    @test !StructuralSynthesizer.wall_stack_continuous(upper, [upper])
    top = _wall(; story=2)
    mid = _link!(_wall(; story=1), top)
    base = _link!(_wall(), mid)
    line = [base, mid, top]
    @test StructuralSynthesizer.wall_stack_continuous(mid, line)
    @test StructuralSynthesizer.wall_stack_continuous(top, line)
    from_mid = _decide(mid, [_eq(_axial(0.10))]; walls=line)
    @test from_mid.continuous
    @test from_mid.hw_m ≈ 12.0
    punched = _link!(_wall(), _wall(; story=1, openings=[WallOpening(1.0, 0.5, 1.0, 1.0, :window)]))
    @test !StructuralSynthesizer.wall_stack_continuous(punched, [punched, punched.wall_above])
    looped = _wall()
    above = _wall(; story=1)
    looped.wall_above = above
    above.wall_above = looped
    @test_throws ArgumentError StructuralSynthesizer.wall_line_members(looped, [looped, above])
    shared = _wall(; story=1)
    @test_throws ArgumentError StructuralSynthesizer.wall_line_members(
        _link!(_wall(), shared), [_link!(_wall(), shared), _link!(_wall(), shared), shared])

    low = _decide(base, [_eq(_axial(0.10))]; walls=line)
    broken = _decide(punched, [_eq(_axial(0.10))];
                    walls=[punched, punched.wall_above])
    @test low.continuous
    @test !low.single_critical_section
    @test low.route === :stress
    @test !broken.continuous
    @test broken.required_by === low.required_by
    @test broken.σ_Pa ≈ low.σ_Pa
    @test_throws ArgumentError _BD(ground, [ground], 1, nothing, [_eq(_axial(0.10))],
                                   RC_4000_60; single_critical_section=true)
end

@testset "Earthquake stress crosses the cuts, and other loads do not" begin
    wall = _wall()
    # §18.10.6.3: exceeds 0.2f′c, less than 0.15f′c. Equality is the band.
    under = _decide(wall, [_eq(_axial(0.10))])
    @test under.required_by === :may_discontinue
    @test under.required === false
    @test under.c_m === nothing
    @test under.minimum_thickness_m === nothing
    @test under.thickness_shortfall_m === nothing
    band = _decide(wall, [_eq(_axial(0.17))])
    @test band.required_by === :between
    @test band.required === nothing
    @test band.zone_length_m === nothing
    over = _decide(wall, [_eq(_axial(0.30))])
    @test over.required === true
    @test over.required_by === :stress
    @test over.c_m !== nothing
    @test over.zone_length_m !== nothing
    @test over.minimum_thickness_m ≈ 4.0 / 16
    heavier = _decide(wall, [_eq(_axial(0.45))])
    @test heavier.c_m > over.c_m
    @test heavier.zone_length_m > over.zone_length_m
    @test heavier.minimum_thickness_m ≈ over.minimum_thickness_m
    # A dead combination, however large, is not an earthquake combination.
    masked = _decide(wall, [
        StructuralSynthesizer.CombinedWallAction(:strength_1_4D, :only, _axial(2.0), 0.0, 0.0),
        _eq(_axial(0.10))])
    @test masked.required_by === :may_discontinue
    @test masked.σ_Pa ≈ under.σ_Pa
    @test under.floor_meets === nothing
    weak = 0.5 * RC_4000_60.concrete.fc′
    met = 0.7 * RC_4000_60.concrete.fc′
    required = _decide(wall, [_eq(_axial(0.30))]; fc_floor=met)
    short = _decide(wall, [_eq(_axial(0.30))]; fc_floor=weak)
    quiet = _decide(wall, [_eq(_axial(0.30))])
    @test required.floor_meets
    @test required.floor_ratio ≈ 0.7
    @test short.floor_meets === false
    @test short.floor_ratio ≈ 0.5
    @test quiet.floor_meets === nothing
    @test short.σ_Pa ≈ required.σ_Pa
    @test short.c_m ≈ required.c_m
    @test short.thickness_shortfall_m ≈ required.thickness_shortfall_m
    idle = _decide(wall, [_eq(_axial(0.10))]; fc_floor=weak)
    @test idle.floor_meets === nothing
end

@testset "Moment picks the end, story height picks the thickness" begin
    wall = _wall()
    # Positive M compresses the positive end. The axial part stays under the cut.
    right = _decide(wall, [_eq(_axial(0.05), 5.0e6)])
    left = _decide(wall, [_eq(_axial(0.05), -5.0e6)])
    @test right.governing_end === :positive
    @test left.governing_end === :negative
    @test right.σ_Pa ≈ left.σ_Pa
    @test right.required_by === left.required_by
    tall = _wall(; height=8.0)
    short = _decide(wall, [_eq(_axial(0.30))])
    high = _decide(tall, [_eq(_axial(0.30))])
    @test high.hu_m ≈ 8.0
    @test high.minimum_thickness_m ≈ 8.0 / 16
    @test short.minimum_thickness_m ≈ 4.0 / 16
    @test high.zone_length_m ≈ short.zone_length_m rtol=1e-6
    @test high.σ_Pa ≈ short.σ_Pa
    @test short.thickness_shortfall_m ≈ 0.0 atol=1e-9
    @test high.thickness_shortfall_m ≈ 0.5 - 0.3
end

@testset "An opening edge is the segment rectangle" begin
    opened = _wall(; openings=[WallOpening(2.0, 0.5, 1.0, 1.0, :window)])
    P = _axial(0.12)
    full = _decide(opened, [_eq(P)])
    half = _decide(opened, [_eq(P)]; section_length=3.0u"m")
    @test !full.continuous
    @test !half.continuous
    @test half.route === :stress
    @test !half.single_critical_section
    @test full.required_by === :may_discontinue
    @test half.required === true
    @test half.σ_Pa ≈ 2 * full.σ_Pa rtol=1e-6
    @test half.flanged === false
    web = _wall(; thick=0.20)
    flange = _wall(; thick=0.20, x1=6.0, y1=0.0, x2=6.0, y2=3.0)
    gross = _decide(web, [_eq(_axial(0.30, 6.0, 0.20))];
                   walls=[web, flange],
                   assembly=StructuralSynthesizer.WallAssembly(0, [1, 2], true))
    segment = _decide(web, [_eq(_axial(0.30, 6.0, 0.20))];
                     walls=[web, flange],
                     assembly=StructuralSynthesizer.WallAssembly(0, [1, 2], true),
                     section_length=6.0u"m")
    @test gross.flanged
    @test !segment.flanged
    @test segment.σ_Pa > gross.σ_Pa
    low = _decide(web, [_eq(_axial(0.30, 6.0, 0.20))])
    tall = _decide(web, [_eq(_axial(0.30, 6.0, 0.20))]; hu_override=8.0u"m")
    @test low.hu_m ≈ 4.0
    @test tall.hu_m ≈ 8.0
    @test low.thickness_shortfall_m ≈ 0.25 - 0.20
    @test tall.thickness_shortfall_m ≈ 0.50 - 0.20
    @test tall.σ_Pa ≈ low.σ_Pa
    @test tall.c_m ≈ low.c_m
end

@testset "A flange changes the fiber stress and not the route" begin
    web = _wall()
    flange = _wall(; thick=0.20, x1=6.0, y1=0.0, x2=6.0, y2=3.0)
    walls = [web, flange]
    assembly = StructuralSynthesizer.WallAssembly(0, [1, 2], true)
    # Height above the section is 4 m, so the overhang cap is 1 m.
    # The flange concrete past the web face is longer than that.
    bare = _decide(web, [_eq(_axial(0.30))])
    flanged = _decide(web, [_eq(_axial(0.30))]; walls=walls, assembly=assembly)
    @test flanged.flanged
    @test flanged.route === :stress
    @test flanged.σ_Pa < bare.σ_Pa
    @test flanged.required_by === bare.required_by
    @test flanged.thickness_shortfall_m ≈ 0.0 atol=1e-9
    thin = _wall(; thick=0.20)
    thin_flange = _wall(; thick=0.20, x1=6.0, y1=0.0, x2=6.0, y2=3.0)
    rectangle = _decide(thin, [_eq(_axial(0.30, 6.0, 0.20))])
    covered = _decide(thin, [_eq(_axial(0.30, 6.0, 0.20))];
                     walls=[thin, thin_flange],
                     assembly=StructuralSynthesizer.WallAssembly(0, [1, 2], true))
    @test rectangle.thickness_shortfall_m ≈ 0.25 - 0.20
    @test covered.flanged
    @test covered.thickness_shortfall_m ≈ 0.0 atol=1e-9
    @test covered.σ_Pa < rectangle.σ_Pa
    long = _wall(; thick=0.20, x1=6.0, y1=0.0, x2=6.0, y2=20.0)
    capped = _decide(web, [_eq(_axial(0.30))];
                    walls=[web, long],
                    assembly=StructuralSynthesizer.WallAssembly(0, [1, 2], true))
    @test capped.σ_Pa ≈ flanged.σ_Pa rtol=1e-8
    # Height above the section is 4 m, so §18.10.5.2 stops the flange 1 m
    # past the web face. The return's bars run from the joint out to that
    # end: half the 0.30 m web plus the 1 m overhang.
    flange.ρl = 0.01
    counted = StructuralSynthesizer._boundary_flange(web, [web, flange], 1, assembly, 4.0u"m")
    @test counted.positive.As_m2 ≈ 0.01 * 0.20 * (0.15 + 1.0)
    @test counted.negative === nothing
    short = _wall(; thick=0.20, x1=6.0, y1=0.0, x2=6.0, y2=0.50)
    short.ρl = 0.01
    stub = StructuralSynthesizer._boundary_flange(
        web, [web, short], 1, StructuralSynthesizer.WallAssembly(0, [1, 2], true), 4.0u"m")
    @test stub.positive.As_m2 ≈ 0.01 * 0.20 * 0.50
    # A return at each end is one section. The same axial sits on more area.
    other = _wall(; thick=0.20, x1=0.0, y1=0.0, x2=0.0, y2=3.0)
    other.ρl = 0.01
    one = _decide(web, [_eq(_axial(0.10))];
        walls=[web, flange],
        assembly=StructuralSynthesizer.WallAssembly(0, [1, 2], true))
    two = _decide(web, [_eq(_axial(0.10))];
        walls=[web, flange, other],
        assembly=StructuralSynthesizer.WallAssembly(0, [1, 2, 3], true))
    @test two.flanged
    @test two.σ_Pa < one.σ_Pa
end

"""
Story 0 is the support level and has no beam grid. Copy the story-1 beam
plan down to the column bases so a ground wall has an edge to claim.
"""
function _boundary_grade_beams!(skel)
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    level(e) = begin
        v1, v2 = skel.edge_indices[e]
        c1 = Meshes.coords(skel.vertices[v1])
        c2 = Meshes.coords(skel.vertices[v2])
        abs(ustrip(u"m", c1.z) - ustrip(u"m", c2.z)) <= 1e-6
    end
    any(e -> e in beams && level(e), skel.stories[0].edges) && return skel
    z0 = skel.stories_z[1]
    for e in skel.stories[1].edges
        (e in beams && level(e)) || continue
        v1, v2 = skel.edge_indices[e]
        c1 = Meshes.coords(skel.vertices[v1])
        c2 = Meshes.coords(skel.vertices[v2])
        StructuralSynthesizer.add_element!(skel, Meshes.Segment(
            Meshes.Point(c1.x, c1.y, z0), Meshes.Point(c2.x, c2.y, z0));
            group=:beams, level_idx=0)
    end
    # find_faces! has already run, so the grade faces are added here.
    at = Dict{NTuple{2, Float64}, Int}()
    for (k, v) in enumerate(skel.vertices)
        c = Meshes.coords(v)
        abs(ustrip(u"m", c.z) - ustrip(u"m", z0)) <= 1e-6 || continue
        at[(round(ustrip(u"m", c.x); digits=6), round(ustrip(u"m", c.y); digits=6))] = k
    end
    for face in skel.stories[1].faces
        cycle = Int[]
        for v in skel.face_vertex_indices[face]
            c = Meshes.coords(skel.vertices[v])
            key = (round(ustrip(u"m", c.x); digits=6), round(ustrip(u"m", c.y); digits=6))
            haskey(at, key) || error("boundary fixture: no grade vertex at $key")
            push!(cycle, at[key])
        end
        StructuralSynthesizer.add_face!(skel, Meshes.Ngon(skel.vertices[cycle]...);
                                        group=:grade, level_idx=0, v_indices=cycle)
    end
    return skel
end

function _boundary_office()
    skel = gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 2, 1)
    _boundary_grade_beams!(skel)
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    ground = [e for e in skel.stories[0].edges if e in beams]
    longest = maximum(begin
        v1, v2 = skel.edge_indices[e]
        c1 = Meshes.coords(skel.vertices[v1])
        c2 = Meshes.coords(skel.vertices[v2])
        hypot(ustrip(u"m", c2.x - c1.x), ustrip(u"m", c2.y - c1.y))
    end for e in ground)
    for e0 in ground
        v1, v2 = skel.edge_indices[e0]
        c1 = Meshes.coords(skel.vertices[v1])
        c2 = Meshes.coords(skel.vertices[v2])
        hypot(ustrip(u"m", c2.x - c1.x), ustrip(u"m", c2.y - c1.y)) + 1e-6 < longest && continue
        filter!(!=(e0), skel.groups_edges[:beams])
        delete!(beams, e0)
        walls = get!(skel.groups_edges, :walls, Int[])
        e0 in walls || push!(walls, e0)
    end
    struc = BuildingStructure(skel)
    initialize!(struc; floor_type=:vault, material=NWC_4000,
                floor_opts=VaultOptions(rise=1.0u"m", thickness=0.05u"m"),
                wall_thickness=0.3u"m")
    for wall in struc.walls
        wall.concrete = RC_4000_60.concrete
    end
    return struc
end

function _boundary_params(row)
    inputs = OrdinaryWallInputs(;
        directions=((1.0, 0.0), (0.0, 1.0)),
        qz=[1.5], qh=2.0, Kd=1.0, G=0.85, GCpi=0.18,
        roof=:Lr, method=:sds, SDS=0.20, S1=0.02, Ie=1.0, T=0.4, β=1.0,
        SD1=0.08, TL=8.0, rho=1.0, sdc=:B, risk_category=:II,
        drift_system=:other, boundary=:pinned, material=RC_4000_60,
        model_uses_cracked_section_stiffness=true,
        sustained_lateral_loads=false, sustained_lateral_divisor_applied=false,
        type1_horizontal_irregularity=false, type5_horizontal_irregularity=false,
        orthogonal_combination=false, orthogonal_12_5_4_conditions_absent=false,
        ax_applied_to_accidental_torsion=false, pdelta_included_in_member_forces=false)
    return DesignParameters(
        lateral=LateralDesign(; system=WallsSeismicSystem(row), assignment=BuildingUnit()),
        wall_inputs=inputs, skip_visualization=true, jump_wall_thickness=false)
end

@testset "A special row records the decision and leaves the wall alone" begin
    function run(row)
        struc = _boundary_office()
        thick = [w.thickness for w in struc.walls]
        params = _boundary_params(row)
        to_asap!(struc; params=params, diaphragms=:rigid)
        result = design_ordinary_walls!(struc, params)
        return struc, thick, result
    end
    ordinary, thick_a3, a3 = run(:A3)
    special, thick_a1, a1 = run(:A1)
    @test isempty(a3.boundary)
    @test isempty(a3.opening_edges)
    @test isempty(a1.opening_edges)
    @test thick_a3 == [w.thickness for w in ordinary.walls]
    @test issetequal(keys(a1.boundary), eachindex(special.walls))
    @test thick_a1 == [w.thickness for w in special.walls]
    @test thick_a1 == thick_a3
    for decision in values(a1.boundary)
        @test decision.continuous
        @test !decision.single_critical_section
        @test decision.route === :stress
        @test !decision.flanged
        @test decision.floor_meets === nothing
    end
    for records in values(a1.checks)
        @test !any(r -> occursin("18.10.6", r.check) || occursin("18.10.6", r.clause), records)
    end
    for decision in values(a1.boundary)
        @test decision.δu_m === nothing
    end
end

# §18.10.7 (corpus: aci-318-19, PDF pages 332–334). A horizontal segment of a
# pierced special pier is designed as a coupling beam. ℓn/h ≥ 4 is §18.6.
# A beam between the limits uses §18.6.3 through §18.6.5. An ordinary pier
# keeps the ordinary beam check.
@testset "A pierced special pier designs its coupling beams" begin
    function run(row, z0, height)
        struc = _boundary_office()
        lengths = [hypot(w.x2 - w.x1, w.y2 - w.y1) for w in struc.walls]
        wall = struc.walls[argmax(lengths)]
        L = maximum(lengths)
        @test L >= 6.0
        width = 3.0
        wall.openings = [WallOpening(0.5 * (L - width), z0, width, height, :window)]
        params = _boundary_params(row)
        to_asap!(struc; params=params, diaphragms=:rigid)
        return design_ordinary_walls!(struc, params)
    end
    beams_of(result) = [r for records in values(result.checks) for r in records
                        if startswith(r.check, "coupling-beam")]
    # 0.4 m bands under and over a 3 m opening: ℓn/h = 7.5, a §18.6 beam.
    @test isempty(beams_of(run(:A3, 0.4, 3.2)))
    long = beams_of(run(:A1, 0.4, 3.2))
    @test any(r -> r.check == "coupling-beam flexure" && occursin("18.6", r.clause), long)
    @test any(r -> r.check == "coupling-beam dimensions" && occursin("7.5", r.clause), long)
    @test !any(r -> r.check == "coupling-beam diagonal", long)
    # 1.2 m bands: ℓn/h = 2.5, §18.6.3 through §18.6.5, without the width limit.
    deep = beams_of(run(:A1, 1.2, 1.6))
    @test any(r -> r.check == "coupling-beam flexure" && occursin("18.6.3", r.clause), deep)
    @test !any(r -> r.check == "coupling-beam dimensions", deep)
end

@testset "A short coupling beam is designed with diagonal bars" begin
    wall = _wall(; thick=0.3048)
    ties = RebarSteel(29000.0u"ksi", 11200.0u"ksi", 60.0u"ksi", 90.0u"ksi",
                      490.0u"lb/ft^3", 0.30, 1.72u"kgCO2e/kg")
    material = ReinforcedConcreteMaterial(NWC_4000, Rebar_60, ties)
    ℓn, h = 1.2192, 0.9144
    seg = (s0=0.0, s1=ℓn, z0=0.0, z1=h)
    Acw = wall.thickness * h * u"m"
    cap = coupling_beam_diagonal_strength(1.0u"inch^2", 60.0u"ksi", 0.4u"rad",
                                          material.concrete.fc′, Acw).cap
    Vu = ustrip(u"N", 0.5 * COUPLING_BEAM_DIAGONAL_PHI * cap)
    action = CombinedWallAction(:strength_1_2D_1_0E, :only, 0.0, Vu, 0.0)
    records = StructuralSynthesizer.check_coupling_beam(
        wall, 1, :X, seg, [action], [action], material)
    @test length(records) == 1
    @test records[1].check == "coupling-beam diagonal"
    @test records[1].passed
    @test occursin("18.10.7.4", records[1].clause)
    @test occursin("0.85", records[1].clause)
end

function _elf_case(direction, purpose, torsion, design)
    z = zeros(length(design))
    blank = Union{Float64, Nothing}[nothing for _ in design]
    return StructuralSynthesizer.ElfCase(
        direction, purpose, torsion, 0.1, 100.0, 1.0,
        z, z, z, z, Float64.(design), z, z, blank, blank, blank)
end

@testset "δu is the largest drift-purpose displacement along the pier" begin
    none = _elf_case(:x, :drift, :none, [0.10, 0.20])
    plus = _elf_case(:x, :drift, :plus, [0.25, 0.15])
    minus = _elf_case(:x, :drift, :minus, [0.20, 0.40])
    strength = _elf_case(:x, :strength, :none, [5.0, 5.0])
    cross = _elf_case(:y, :drift, :plus, [9.0, 9.0])
    cases = [none, plus, minus, strength, cross]
    lower = StructuralSynthesizer.elf_design_displacement(cases, :x, 1)
    @test lower.δu_m ≈ 0.25
    @test lower.torsion === :plus
    # The upper floor is a different case. The strength case and the Y case do not move it.
    upper = StructuralSynthesizer.elf_design_displacement(cases, :x, 2)
    @test upper.δu_m ≈ 0.40
    @test upper.torsion === :minus
    grown = StructuralSynthesizer.elf_design_displacement(
        [none, plus, minus, _elf_case(:x, :strength, :plus, [8.0, 8.0]), cross], :x, 1)
    @test grown.δu_m ≈ lower.δu_m
    @test grown.torsion === lower.torsion
    # An equal torsion case does not replace the earlier one.
    tied = StructuralSynthesizer.elf_design_displacement(
        [none, _elf_case(:x, :drift, :plus, [0.10, 0.20])], :x, 1)
    @test tied.δu_m ≈ 0.10
    @test tied.torsion === :none
    # The sign is the sense of motion. δu is the length.
    flipped = StructuralSynthesizer.elf_design_displacement(
        [_elf_case(:x, :drift, :minus, [-0.30, -0.30]), none], :x, 1)
    @test flipped.δu_m ≈ 0.30
    @test flipped.torsion === :minus
    y = StructuralSynthesizer.elf_design_displacement(cases, :y, 1)
    @test y.δu_m ≈ 9.0
    @test y.torsion === :plus
    @test StructuralSynthesizer.elf_level_for_height([4.0, 8.0], 8.0) == 2
    @test StructuralSynthesizer.elf_level_for_height([4.0, 8.0], 4.0009) == 1
    @test_throws ArgumentError StructuralSynthesizer.elf_level_for_height([4.0, 8.0], 4.0011)
    @test_throws ArgumentError StructuralSynthesizer.elf_design_displacement(
        [_elf_case(:y, :drift, :none, [1.0])], :x, 1)
end

@testset "The displacement route opens at the base of a slender continuous line" begin
    # hwcs/ℓw = 12/4 = 3. hu/16 is already past 12 in., so the floor is not the story.
    tall = _wall(; height=12.0, x2=4.0)
    # 0.06 f′c keeps c under ℓw/(600·0.005·1.5). 0.15 f′c is already past it,
    # so the floor would require the element before δu moved.
    quiet = _decide(tall, [_eq(_axial(0.06, 4.0, 0.3))]; δu=0.0u"m")
    held = _decide(tall, [_eq(_axial(0.06, 4.0, 0.3))]; δu=0.005 * 12.0u"m")
    @test quiet.route === :displacement
    @test quiet.single_critical_section
    @test quiet.δu_m ≈ 0.0
    @test held.δu_m ≈ 0.06
    @test quiet.required_by === held.required_by
    @test quiet.c_m ≈ held.c_m
    pushed = _decide(tall, [_eq(_axial(0.06, 4.0, 0.3))]; δu=1.0u"m")
    @test pushed.c_m ≈ quiet.c_m
    @test pushed.δu_m ≈ 1.0
    # The 0.005 floor does not require an element at this axial. A larger
    # displacement does, and c does not move.
    @test quiet.required === false
    @test pushed.required === true
    @test pushed.required_by === :displacement
    heavier = _decide(tall, [_eq(_axial(0.50, 4.0, 0.3))]; δu=0.0u"m")
    @test heavier.δu_m ≈ quiet.δu_m
    @test heavier.c_m > quiet.c_m
    # The larger axial moves c across Eq. (18.10.6.2a). δu stays on the floor.
    @test heavier.required === true
    # Above the base the critical section is not this pier, even when that
    # pier alone is slender.
    cap = _wall(; story=1, height=10.0, x2=4.0)
    base_pier = _link!(_wall(; height=2.0, x2=4.0), cap)
    line = [base_pier, cap]
    above = _decide(cap, [_eq(_axial(0.50, 4.0, 0.3))]; walls=line, δu=1.0u"m")
    @test above.continuous
    @test above.hw_m ≈ 12.0
    @test above.route === :stress
    @test above.δu_m === nothing
    base = _decide(base_pier, [_eq(_axial(0.50, 4.0, 0.3))]; walls=line, δu=1.0u"m")
    @test base.route === :displacement
    @test base.hw_m ≈ 12.0
    # Not slender: δu is ignored.
    stocky = _decide(_wall(), [_eq(_axial(0.30))]; δu=1.0u"m")
    @test stocky.route === :stress
    @test stocky.δu_m === nothing
    # An opening breaks the line.
    punched = _link!(_wall(; height=8.0, x2=4.0),
        _wall(; story=1, height=4.0, x2=4.0, openings=[WallOpening(1.0, 0.5, 1.0, 1.0, :window)]))
    broken = _decide(punched, [_eq(_axial(0.50, 4.0, 0.3))];
                    walls=[punched, punched.wall_above], δu=1.0u"m")
    @test broken.route === :stress
    # A segment beside an opening is not the gross pier.
    segment = _decide(tall, [_eq(_axial(0.50, 4.0, 0.3))];
                     δu=1.0u"m", section_length=4.0u"m")
    @test segment.route === :stress
end

@testset "The 12 in. floor opens only with the displacement gates" begin
    # Base pier 2 m: hu/16 = 0.125 m, under 12 in. The line is 10 m on a 4 m wall.
    top = _wall(; story=2, height=4.0, x2=4.0)
    mid = _link!(_wall(; story=1, height=4.0, x2=4.0), top)
    base = _link!(_wall(; height=2.0, thick=0.20, x2=4.0), mid)
    line = [base, mid, top]
    function zoned(ratio)
        return _decide(base, [_eq(_axial(ratio, 4.0, 0.20))]; walls=line, δu=1.0u"m")
    end
    shallow = zoned(0.05)
    deep = zoned(0.55)
    @test shallow.route === :displacement
    @test shallow.required === true
    @test shallow.c_m / 4 < 3 / 8
    @test shallow.minimum_thickness_m ≈ 2.0 / 16
    @test deep.c_m > shallow.c_m
    @test deep.δu_m ≈ shallow.δu_m
    @test deep.c_m / 4 >= 3 / 8
    @test deep.minimum_thickness_m ≈ ustrip(u"m", 12.0u"inch")
    @test deep.thickness_shortfall_m ≈ deep.minimum_thickness_m - 0.20
end
