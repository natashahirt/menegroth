# design_building designs one-way slabs on beams with the story shell: the
# beams size against it, the columns size after, and each slab carries the
# bars of its own panels from a shell solve with the final sections.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

const SY = StructuralSynthesizer

@testset "design_building: one-way slabs on the story shell" begin
    skel = gen_medium_office(6.0u"m", 6.0u"m", 3.0u"m", 2, 1, 2)
    struc = BuildingStructure(skel)
    design = design_building(struc, DesignParameters(
        name = "story_shell_pipeline",
        materials = MaterialOptions(concrete = NWC_4000),
        floor = OneWayOptions(),
        max_iterations = 3,
    ))

    # design_building leaves the caller's structure untouched. The sized
    # building is the one on the design.
    designed = design.structure
    levels = SY._story_shell_design_levels(designed)
    @test !isempty(levels)

    panels = 0
    for (i, sr) in design.slabs
        slab = designed.slabs[i]
        all(ci -> designed.cells[ci].floor_type in (:one_way, :unknown), slab.cell_indices) ||
            continue
        @test sr.analysis_status == "analyzed"
        @test length(sr.shell_reinforcement) == length(slab.cell_indices)
        @test all(f -> f.section_adequate, sr.shell_reinforcement)
        @test all(f -> any(e -> e.As_x_bot > 0 || e.As_y_bot > 0, f.elements),
                  sr.shell_reinforcement)
        @test sr.converged
        panels += length(sr.shell_reinforcement)
    end
    @test panels > 0
end
