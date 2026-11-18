# A finalized design round-trips through the archive, and the scene rebuilt from
# the loaded design matches the scene built from the live design.
#
# The building is one story, three bays each way, direct design. It is not the
# office. The office runner writes the same file on its next design run.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

const _SS = StructuralSynthesizer

"""One-story 3×3 flat plate. Three continuous spans, so direct design applies."""
function _archive_building()
    skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 1)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name = "design-archive",
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
    return struc, params
end

function _section_area(el)
    return ustrip(u"m^2", el.section.A)
end

@testset "design archive" begin
    @testset "header rejects a file that is not this format" begin
        dir = mktempdir()
        bad = joinpath(dir, "bad.mgdesign")
        open(bad, "w") do io
            write(io, htol(UInt32(0)))
            write(io, htol(UInt16(_SS.DESIGN_ARCHIVE_VERSION)))
        end
        err = try
            load_design(bad)
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("magic", sprint(showerror, err))

        stale = joinpath(dir, "stale.mgdesign")
        open(stale, "w") do io
            write(io, htol(UInt32(_SS.DESIGN_ARCHIVE_MAGIC)))
            write(io, htol(UInt16(99)))
        end
        err = try
            load_design(stale)
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("format 99", sprint(showerror, err))

        err = try
            _SS._assert_archive_versions("0.0.0", _SS._archive_package_versions())
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("Julia", sprint(showerror, err))

        wrong = _SS._archive_package_versions()
        wrong["Asap"] = "0.0.0"
        err = try
            _SS._assert_archive_versions(string(VERSION), wrong)
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("Asap", sprint(showerror, err))
    end

    @testset "round trip rebuilds the scene" begin
        struc, params = _archive_building()
        tc = StructuralSizer.TraceCollector()
        design = design_building(struc, params; tc = tc, restore = false)
        @test !isempty(design.columns)
        @test !isempty(design.slabs)
        @test !isempty(design.foundations)
        @test !isempty(design.solver_trace)
        @test all(v -> v == (0.0, 0.0), values(design.structural_offsets))
        @test any(v -> hypot(v...) > 0, values(_SS.slab_vertex_overhang(design.structure)))

        build_analysis_model!(design)
        original_scene = build_scene(design)
        original_nodes = design.asap_model.nodes
        areas = [_section_area(el) for el in design.structure.asap_model.frame_elements]
        rolls = [el.Ψ for el in design.structure.asap_model.frame_elements]
        section_size = first(design.columns)[2].section_size
        slab_thickness = first(design.slabs)[2].thickness
        footing_length = first(design.foundations)[2].length

        path = joinpath(mktempdir(), "plate.mgdesign")
        save_design(path, design)
        @test design.asap_model !== nothing
        @test length(design.asap_model.nodes) == length(original_nodes)
        @test isfile(path)

        loaded = load_design(path)
        @test loaded.asap_model === nothing
        @test loaded.structural_offsets == design.structural_offsets
        @test loaded.context_hash == design.context_hash
        @test loaded.diagnostics == design.diagnostics
        @test loaded.converged == design.converged
        @test loaded.scope_notes == design.scope_notes
        # A gravity-only design says so without failing.
        @test (design.params.lateral === nothing) ==
              any(n -> occursin("Gravity-only", n), design.scope_notes)
        @test length(loaded.solver_trace) == length(design.solver_trace)
        @test [(e.stage, e.element_id, e.event_type) for e in loaded.solver_trace] ==
              [(e.stage, e.element_id, e.event_type) for e in design.solver_trace]
        @test first(loaded.columns)[2].section_size == section_size
        @test first(loaded.slabs)[2].thickness == slab_thickness
        @test first(loaded.foundations)[2].length == footing_length
        @test loaded.walls == design.walls

        loaded_frames = loaded.structure.asap_model.frame_elements
        @test length(loaded_frames) == length(areas)
        for (el, area, roll) in zip(loaded_frames, areas, rolls)
            @test isapprox(_section_area(el), area; rtol = 1e-12, atol = 1e-18)
            @test el.Ψ == roll
        end

        build_analysis_model!(loaded)
        loaded_scene = build_scene(loaded)
        @test loaded_scene.meta["counts"]["nodes"] == original_scene.meta["counts"]["nodes"]
        @test loaded_scene.meta["counts"]["elements"] == original_scene.meta["counts"]["elements"]
        @test isapprox(
            loaded_scene.meta["max_displacement"],
            original_scene.meta["max_displacement"];
            rtol = 1e-6, atol = 1e-9)
    end
end
