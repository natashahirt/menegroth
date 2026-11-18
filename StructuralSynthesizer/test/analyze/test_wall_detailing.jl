# Wall bar placement on a building: ratios, an opening, a corner, and the scene record.

using Test
using Unitful
using StructuralSynthesizer

function _shear_record(idx, Vu_N)
    return WallCheckRecord(idx, 0, :X, :D, :strength_1_4D, :only,
                           "in-plane shear", true, 0.2, Float64(Vu_N), 1.0e6,
                           "ACI 318-19 11.5.4.3")
end

@testset "wall detailing on a building" begin
    skel = gen_medium_office(20.0u"ft", 20.0u"ft", 12.0u"ft", 1, 1, 1)
    struc = BuildingStructure(skel)
    empty!(struc.walls)
    push!(struc.walls, Wall([1], 3.658u"m"; thickness = 0.3048u"m",
                            x1 = 0.0, y1 = 0.0, x2 = 6.096, y2 = 0.0,
                            openings = [WallOpening(1.5, 0.0, 0.9, 2.1, :door)]))
    push!(struc.walls, Wall([1], 3.658u"m"; thickness = 0.3048u"m",
                            x1 = 6.096, y1 = 0.0, x2 = 6.096, y2 = 4.0))
    design = BuildingDesign(struc, DesignParameters(name = "wall detail", skip_visualization = true))
    design.walls[1] = [_shear_record(1, 50_000.0)]
    design.walls[2] = [_shear_record(2, 50_000.0)]

    bd = detail_building(design)
    @test isempty(bd.errors)
    @test length(bd.walls) == 2
    pier = bd.walls[1]
    @test !isempty(pier.groups)
    @test length(pier.voids) == 1
    @test any(g -> g.role === :trim, pier.groups)
    @test any(g -> g.role === :dowel, pier.groups)
    leg = bd.walls[2]
    @test any(g -> g.role === :horizontal && occursin("corner lap", g.note), leg.groups)
    # The pier's ratios are the calculated areas. Placed bars have to cover them.
    # ρ · ℓw · h and ρ · height · h, with ℓw = 4 m, height = 3.658 m, h = 0.3048 m.
    Ab(g) = ustrip(u"m^2", StructuralSizer.bar_area(g.bar_size))
    placed(role) = sum(g -> g.count * Ab(g), (g for g in leg.groups if g.role === role); init = 0.0)
    @test placed(:vertical) >= 0.0025 * 4.0 * 0.3048
    @test placed(:horizontal) >= 0.0025 * 3.658 * 0.3048
    smear = (0.0025 + 0.0025) * 4.0 * 3.658 * 0.3048
    # Takeoff volume exceeds the smeared volume: spacing rounds down, and the
    # centerlines include hooks, the corner lap, and the dowels.
    vol = sum(leg.groups) do g
        g.count * ustrip(u"m", g.length) * ustrip(u"m^2", StructuralSizer.bar_area(g.bar_size))
    end
    @test vol > smear

    rec = StructuralSynthesizer._detail_record(pier)
    @test rec["kind"] == "wall"
    @test !isempty(rec["groups"])
    @test length(rec["voids_m"]) == 1
    @test !isempty(rec["section_dots_m"])
    @test haskey(rec["groups"][1], "z_positions_m")
    areas = rec["areas_in2"]
    @test areas["vertical_placed_in2"] >= areas["vertical_ideal_in2"]
    @test areas["horizontal_placed_in2"] >= areas["horizontal_ideal_in2"]
end

function _gap_bar(x0, x1; role=:horizontal)
    return StructuralSizer.BarGroup(;
        mark = "H", role = role, direction = :transverse, bar_size = 4, count = 1,
        length = max(x1 - x0, 0.0) * u"m", path = [(x0, 0.0), (x1, 0.0)])
end

function _gap_detail(bars)
    md = StructuralSizer.MemberDetail(:wall)
    append!(md.groups, bars)
    return md
end

@testset "The horizontal bars' worse end is the §18.10.6.4(k) gap" begin
    L = 6.0u"m"
    inch = ustrip(u"m", 1.0u"inch")
    close = _gap_detail([_gap_bar(inch, 6.0 - inch)])
    @test StructuralSizer.wall_horizontal_end_gap(close, L) ≈ inch * u"m" atol=1e-9u"m"
    # The far end governs. Moving the near end does not.
    far = _gap_detail([_gap_bar(inch, 6.0 - 7inch)])
    @test ustrip(u"inch", StructuralSizer.wall_horizontal_end_gap(far, L)) ≈ 7 atol=1e-6
    nearer = _gap_detail([_gap_bar(0.0, 6.0 - 7inch)])
    @test StructuralSizer.wall_horizontal_end_gap(nearer, L) ≈
        StructuralSizer.wall_horizontal_end_gap(far, L)
    brought = _gap_detail([_gap_bar(inch, 6.0 - 2inch)])
    @test ustrip(u"inch", StructuralSizer.wall_horizontal_end_gap(brought, L)) ≈ 2 atol=1e-6
    # A lap past the concrete end has no gap there. Equality at 6 in. is within the limit.
    lapped = _gap_detail([_gap_bar(-0.3, 6.0 - 6inch)])
    @test ustrip(u"inch", StructuralSizer.wall_horizontal_end_gap(lapped, L)) ≈ 6 atol=1e-6
    # Meter subtraction sits a fraction of a nanometer past 6 in. Equality still reaches.
    @test StructuralSizer.web_end_within_six_inches(
        StructuralSizer.wall_horizontal_end_gap(lapped, L))
    vertical = _gap_detail([_gap_bar(0.0, 6.0; role=:vertical)])
    @test StructuralSizer.wall_horizontal_end_gap(vertical, L) === nothing
end

function _termination_decision(required; continuous=true, zone_length=nothing, flanged=false)
    return StructuralSynthesizer.SpecialBoundaryDecision(
        continuous, false, :stress, required, :stress, :positive,
        0.0, nothing, zone_length, nothing, nothing, 4.0, 4.0, flanged, nothing, nothing, nothing)
end

function _termination_result(; boundary=Dict{Int, StructuralSynthesizer.SpecialBoundaryDecision}(),
                             edges=Dict{Int, Vector{StructuralSynthesizer.SpecialBoundaryDecision}}())
    return StructuralSynthesizer.OrdinaryWallResult(
        Dict{Int, Vector{WallCheckRecord}}(), SeismicStoryDriftCheck[], 0.0, Float64[],
        StructuralSynthesizer.WallGravityShare[],
        StructuralSynthesizer.InteractiveStoryShearCheck[],
        StructuralSynthesizer.FrameMemberCheck[],
        false, String[], false, boundary, edges,
        Dict{Int, StructuralSynthesizer.BoundaryEndReinforcement}(),
        StructuralSynthesizer.GravityInducedCheck[])
end

@testset "A required element records the end gap and not a hook" begin
    skel = gen_medium_office(20.0u"ft", 20.0u"ft", 12.0u"ft", 1, 1, 1)
    struc = BuildingStructure(skel)
    empty!(struc.walls)
    push!(struc.walls, Wall([1], 3.658u"m"; thickness = 0.3048u"m",
                            x1 = 0.0, y1 = 0.0, x2 = 6.096, y2 = 0.0))
    design = BuildingDesign(struc, DesignParameters(name = "end gap", skip_visualization = true))
    design.walls[1] = [_shear_record(1, 50_000.0)]
    function detail(result)
        struc.ordinary_wall_result = result
        return StructuralSynthesizer._detail_wall(design, nothing, 1)
    end
    plain = detail(nothing)
    @test !any(s -> occursin("18.10.6.4(k)", s), plain.notes)
    @test !any(s -> occursin("18.10.6.4(k)", s), plain.warnings)
    idle = detail(_termination_result(; boundary=Dict(1 => _termination_decision(false))))
    @test !any(s -> occursin("18.10.6.4(k)", s), idle.notes)
    required = detail(_termination_result(; boundary=Dict(1 => _termination_decision(true))))
    @test any(s -> occursin("18.10.6.4(k)", s) && occursin("within", s) &&
                   occursin("hook is not chosen", s), required.notes)
    @test !any(s -> occursin("18.10.6.4(k)", s), required.warnings)
    edge = detail(_termination_result(;
        edges=Dict(1 => [_termination_decision(true)])))
    @test any(s -> occursin("within", s), edge.notes)
end

@testset "The base of a continuous line records §18.10.6.4(j)" begin
    skel = gen_medium_office(20.0u"ft", 20.0u"ft", 12.0u"ft", 1, 1, 1)
    struc = BuildingStructure(skel)
    empty!(struc.walls)
    push!(struc.walls, Wall([1], 3.658u"m"; thickness = 0.3048u"m",
                            x1 = 0.0, y1 = 0.0, x2 = 6.096, y2 = 0.0))
    design = BuildingDesign(struc, DesignParameters(name = "support extension",
                                                   skip_visualization = true))
    design.walls[1] = [_shear_record(1, 50_000.0)]
    wall = struc.walls[1]
    function detail(result)
        struc.ordinary_wall_result = result
        return StructuralSynthesizer._detail_wall(design, nothing, 1)
    end
    function extension_note(md)
        notes = [s for s in md.notes if occursin("18.10.6.4(j)", s)]
        return isempty(notes) ? nothing : only(notes)
    end
    required = detail(_termination_result(; boundary=Dict(1 => _termination_decision(true))))
    note = extension_note(required)
    @test note !== nothing
    @test occursin("1.25", note)
    @test occursin("18.10.2.3(b)", note)
    @test occursin("not placed", note)
    @test occursin("12 in. extension is not applied", note)
    conc = StructuralSynthesizer.resolve_column_concrete(design.params.materials)
    rebar = StructuralSynthesizer.resolve_column_rebar(design.params.materials)
    sizes = [g.bar_size for g in required.groups if g.role === :vertical]
    @test !isempty(sizes)
    best = sizes[argmax([ustrip(u"m", StructuralSizer.bar_diameter(s)) for s in sizes])]
    yielded = StructuralSizer.boundary_bar_development(
        best, conc.fc′, rebar.Fy, conc.λ; coating = rebar.coating, yielding_likely = true)
    plain = StructuralSizer.boundary_bar_development(
        best, conc.fc′, rebar.Fy, conc.λ; coating = rebar.coating, yielding_likely = false)
    @test occursin(string(round(ustrip(u"inch", yielded); digits = 2)), note)
    @test !occursin("develop in $(round(ustrip(u"inch", plain); digits = 2)) in.", note)
    # §18.10.2.3(a)'s 12 ft is not added to the placed bars. A roof bar stops at the story.
    Hm = ustrip(u"m", wall.base.L)
    for g in required.groups
        g.role === :vertical || continue
        @test maximum(p[2] for p in g.path) ≈ Hm atol=1e-6
    end
    # The story above this base is not the critical section.
    wall.story = 1
    above = detail(_termination_result(; boundary=Dict(1 => _termination_decision(true))))
    @test extension_note(above) === nothing
    # A line that is not continuous has no single critical section.
    wall.story = 0
    broken = detail(_termination_result(;
        boundary=Dict(1 => _termination_decision(true; continuous=false))))
    @test extension_note(broken) === nothing
    idle = detail(_termination_result(; boundary=Dict(1 => _termination_decision(false))))
    @test extension_note(idle) === nothing
end

@testset "A known boundary length records the hoop arrangement" begin
    skel = gen_medium_office(20.0u"ft", 20.0u"ft", 12.0u"ft", 1, 1, 1)
    struc = BuildingStructure(skel)
    empty!(struc.walls)
    # 12 in. thick. Twice that is 24 in.
    push!(struc.walls, Wall([1], 3.658u"m"; thickness = 0.3048u"m",
                            x1 = 0.0, y1 = 0.0, x2 = 6.096, y2 = 0.0))
    design = BuildingDesign(struc, DesignParameters(name = "boundary hoops",
                                                   skip_visualization = true))
    design.walls[1] = [_shear_record(1, 50_000.0)]
    function notes_for(result)
        struc.ordinary_wall_result = result
        md = StructuralSynthesizer._detail_wall(design, nothing, 1)
        return [s for s in md.notes if occursin("18.10.6.4(f)", s)]
    end
    function note_for(zone; flanged=false)
        notes = notes_for(_termination_result(;
            boundary=Dict(1 => _termination_decision(true; zone_length=zone, flanged))))
        return isempty(notes) ? nothing : only(notes)
    end
    # Edges around openings get the same note, one per required edge.
    edges = notes_for(_termination_result(; edges=Dict(1 => [
        _termination_decision(true; zone_length=0.50),
        _termination_decision(false; zone_length=0.50),
        _termination_decision(true; zone_length=0.70)])))
    @test length(edges) == 2
    @test count(s -> occursin("one hoop", s), edges) == 1
    @test count(s -> occursin("overlapping hoops", s), edges) == 1
    # A flanged element says its flange is not arranged. A web-only one does not.
    @test occursin("flange in the element is not arranged", note_for(0.50; flanged=true))
    @test !occursin("flange", note_for(0.50))
    @test note_for(nothing) === nothing
    # 0.50 m is under twice the 12 in. thickness. 0.70 m is over it.
    one = note_for(0.50)
    @test one !== nothing
    @test occursin("one hoop", one)
    @test occursin("8.0 in", one)
    @test occursin("not placed", one)
    @test occursin("25.7.2.3", one)
    longer = note_for(0.70)
    @test occursin("overlapping hoops", longer)
    @test occursin("8.0 in", longer)
end
