# Bar placement for a designed flat plate building, and its scene payload.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSynthesizer: _detail_record

function _detailing_building()
    skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 2)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name = "detailing",
        floor = FlatPlateOptions(method = DDM()),
        materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
        max_iterations = 5,
        skip_visualization = true,
        geometry_is_centerline = false,
        foundation_options = FoundationParameters(
            soil = medium_sand,
            options = FoundationOptions(strategy = :all_spread),
        ),
    )
    return design_building(struc, params; restore = false)
end

@testset "building detailing" begin
    design = _detailing_building()
    struc = design.structure
    bd = detail_building(design)

    @test isempty(bd.errors)
    @test !isempty(bd.slabs)
    @test !isempty(bd.columns)
    @test !isempty(bd.footings)

    @testset "slabs" begin
        for (idx, md) in bd.slabs
            @test !isempty(md.groups)
            dirs = Set(g.direction for g in md.groups)
            @test :primary in dirs
            # Every frame line has two integrity bars (§8.7.4.2.2).
            integ = [g for g in md.groups if g.role === :integrity]
            @test !isempty(integ)
            @test all(g -> g.count == 2, integ)
            # Top bars of the strip design, scaled per line, are all placed.
            r = struc.slabs[idx].result
            @test all(g -> g.bar_size in
                      Set(x.bar_size for x in vcat(r.column_strip_reinf, r.middle_strip_reinf,
                                                   r.secondary_column_strip_reinf,
                                                   r.secondary_middle_strip_reinf)),
                      md.groups)
        end
    end

    @testset "columns" begin
        tops = 0
        for (idx, md) in bd.columns
            col = struc.columns[idx]
            long = only(g for g in md.groups if g.role === :longitudinal)
            sec = design.columns[idx].section_obj
            @test long.count == length(sec.bars)
            if isnothing(col.column_above)
                tops += 1
                @test long.shape === :hook_end
            else
                @test long.length > design.columns[idx].height
            end
            @test any(g -> g.role in (:tie, :spiral), md.groups)
        end
        @test tops > 0
    end

    @testset "footings" begin
        for (idx, md) in bd.footings
            @test count(g -> g.role === :bottom, md.groups) >= 2
            @test count(g -> g.role === :dowel, md.groups) == 1
        end
    end

    @testset "mass and scene payload" begin
        @test building_detail_mass(bd) > 0.0u"kg"
        md = first(values(bd.slabs))
        rec = _detail_record(md)
        @test rec["mass_kg"] ≈ ustrip(u"kg", StructuralSizer.detail_mass(md))
        @test length(rec["groups"]) == length(md.groups)
        g = first(rec["groups"])
        @test all(k -> haskey(g, k), ("mark", "role", "bar_size", "diameter_m", "count",
                                      "length_m", "shape", "path_m", "x_positions_m"))
        @test _detail_record(nothing) === nothing
        @test _detail_record("boom")["error"] == "boom"

        build_analysis_model!(design)
        scene = build_scene(design)
        components = scene.meta["components"]
        details = [c["drawing"]["detail"] for c in components
                   if c["kind"] in ("column", "slab", "footing")]
        @test !isempty(details)
        @test all(d -> d !== nothing && !haskey(d, "error"), details)
        @test scene.meta["design_trace"]["summary"]["rebar_detailed_kg"] > 0
    end
end
