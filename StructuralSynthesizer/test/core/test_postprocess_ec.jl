# Tests: postprocess/ec.jl serialization (to_dict) and value invariants.
#
# Validates that the to_dict helpers strip Unitful quantities into a
# JSON-friendly Dict and preserve totals, percentages, and floor-area unit
# conventions. Doesn't drive compute_building_ec end-to-end — that path is
# exercised by the integration suite — instead it pins the serialization
# contract using a hand-built BuildingECResult so the test is fast and
# deterministic.

using Test
using Unitful
using Asap  # ensures u"kgCO2e", u"kip", etc resolve via Asap unit module
using StructuralSynthesizer

@testset "Postprocess — EC to_dict serialization" begin
    elem_slab = ElementECResult(:slab, 1, 100.0u"kgCO2e", 5.0u"m^3", 12000.0u"kg")
    elem_mem  = ElementECResult(:column, 2, 50.0u"kgCO2e", 0.5u"m^3", 1200.0u"kg")
    elem_fdn  = ElementECResult(:foundation, 1, 25.0u"kgCO2e", 3.0u"m^3", 7200.0u"kg")

    bldg = BuildingECResult(
        [elem_slab], [elem_mem], [elem_fdn],
        100.0u"kgCO2e",          # slab_ec
        50.0u"kgCO2e",           # member_ec
        25.0u"kgCO2e",           # foundation_ec
        10.0u"kgCO2e",           # fireproofing_ec
        185.0u"kgCO2e",          # total_ec  (= sum of the above)
        500.0u"m^2",             # floor_area
        0.37u"kgCO2e/m^2",       # ec_per_floor_area (185 / 500)
    )

    @testset "ElementECResult.to_dict — SI units, stripped" begin
        d = to_dict(elem_slab)
        @test d isa Dict{String, Any}
        @test d["element_type"] == "slab"
        @test d["element_id"] == 1
        @test d["kgco2e"] ≈ 100.0
        @test d["volume_m3"] ≈ 5.0
        @test d["mass_kg"] ≈ 12000.0
        # No Unitful quantities in serialized form.
        for v in values(d)
            @test !(v isa Unitful.Quantity)
        end
    end

    @testset "BuildingECResult.to_dict — totals and unit-tagged area (imperial)" begin
        d = to_dict(bldg)  # default du = imperial → ft²
        @test d["slab_kgco2e"] ≈ 100.0
        @test d["member_kgco2e"] ≈ 50.0
        @test d["foundation_kgco2e"] ≈ 25.0
        @test d["fireproofing_kgco2e"] ≈ 10.0
        @test d["total_kgco2e"] ≈ 185.0
        @test d["intensity_kgco2e_per_m2"] ≈ 0.37

        # Imperial floor-area conversion: 500 m² ≈ 5381.95 ft².
        @test d["floor_area"] ≈ ustrip(u"ft^2", 500.0u"m^2") rtol=1e-9
        @test occursin("ft", d["floor_area_unit"])
        @test occursin("ft", d["intensity_kgco2e_per_display_area_unit"])
        # Intensity in display units must be consistent with floor_area:
        @test d["intensity_kgco2e_per_display_area"] ≈ 185.0 / d["floor_area"] rtol=1e-9

        # Per-element vectors round-trip via to_dict(::ElementECResult).
        @test length(d["slabs"]) == 1
        @test length(d["members"]) == 1
        @test length(d["foundations"]) == 1
        @test d["slabs"][1]["kgco2e"] ≈ 100.0
    end

    @testset "BuildingECResult.to_dict — metric display units" begin
        d = to_dict(bldg; du = StructuralSynthesizer.metric)
        @test d["floor_area"] ≈ 500.0 rtol=1e-9
        @test occursin("m", d["floor_area_unit"])
        @test d["intensity_kgco2e_per_display_area"] ≈ 0.37 rtol=1e-9
    end

    @testset "BuildingECResult.to_dict — zero floor area is safe" begin
        empty = BuildingECResult(
            ElementECResult[], ElementECResult[], ElementECResult[],
            0.0u"kgCO2e", 0.0u"kgCO2e", 0.0u"kgCO2e", 0.0u"kgCO2e", 0.0u"kgCO2e",
            0.0u"m^2", 0.0u"kgCO2e/m^2",
        )
        d = to_dict(empty)
        @test d["total_kgco2e"] == 0.0
        @test d["floor_area"] == 0.0
        @test d["intensity_kgco2e_per_display_area"] == 0.0
    end
end
