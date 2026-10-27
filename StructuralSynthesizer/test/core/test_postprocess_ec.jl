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
    z = 0.0u"kgCO2e"
    elem_slab = ElementECResult(:slab, 1, 100.0u"kgCO2e", 80.0u"kgCO2e", 20.0u"kgCO2e", z, 5.0u"m^3", 12000.0u"kg")
    elem_mem  = ElementECResult(:column, 2, 50.0u"kgCO2e", 40.0u"kgCO2e", 10.0u"kgCO2e", z, 0.5u"m^3", 1200.0u"kg")
    elem_fdn  = ElementECResult(:foundation, 1, 25.0u"kgCO2e", 20.0u"kgCO2e", 5.0u"kgCO2e", z, 3.0u"m^3", 7200.0u"kg")

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
        @test d["concrete_kgco2e"] ≈ 80.0
        @test d["rebar_kgco2e"] ≈ 20.0
        @test d["structural_steel_kgco2e"] ≈ 0.0
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

@testset "Postprocess — concrete and steel carbon are separable" begin
    conc = StructuralSizer.NWC_4000
    reb  = StructuralSizer.Rebar_60
    stl  = StructuralSizer.A992_Steel
    vols = MaterialVolumes(
        conc => 2.0u"m^3",
        reb  => 0.02u"m^3",
        stl  => 0.05u"m^3",
    )
    parts = material_ec(vols)
    toff = material_takeoff(vols)
    @test toff.concrete_volume ≈ 2.0u"m^3"
    @test toff.rebar_mass ≈ uconvert(u"kg", 0.02u"m^3" * reb.ρ)
    @test toff.structural_steel_mass ≈ uconvert(u"kg", 0.05u"m^3" * stl.ρ)
    @test toff.concrete_ec ≈ parts.concrete
    @test toff.rebar_ec ≈ parts.rebar
    @test toff.structural_steel_ec ≈ parts.structural_steel
    @test parts.concrete ≈ element_ec(MaterialVolumes(conc => 2.0u"m^3"))
    @test parts.rebar ≈ element_ec(MaterialVolumes(reb => 0.02u"m^3"))
    @test parts.structural_steel ≈ element_ec(MaterialVolumes(stl => 0.05u"m^3"))
    @test parts.concrete + parts.rebar + parts.structural_steel + parts.timber + parts.other ≈ element_ec(vols)
    @test parts.concrete > 0.0u"kgCO2e"
    @test parts.rebar > 0.0u"kgCO2e"
    @test parts.structural_steel > 0.0u"kgCO2e"

    # A column with no volumes contributes nothing. After the RC volume write,
    # concrete and rebar are both present and the column shows up in building EC.
    # `BuildingStructure` does not create columns until `initialize!`, so this
    # uses the member constructor directly.
    col = Column(1, 3.0u"m"; c1 = 0.4u"m", c2 = 0.4u"m")
    set_section!(col, StructuralSizer.RCColumnSection(b = col.c1, h = col.c2, bar_size = 8, n_bars = 4))
    skel = gen_medium_office(10.0u"m", 10.0u"m", 3.0u"m", 1, 1, 1)
    struc = BuildingStructure(skel)
    push!(struc.columns, col)
    empty_ec = compute_building_ec(struc)
    @test sum(r.ec for r in empty_ec.members if r.element_type == :column; init = 0.0u"kgCO2e") == 0.0u"kgCO2e"

    StructuralSynthesizer._set_rc_column_volumes!(col, StructuralSizer.NWC_6000, StructuralSizer.Rebar_60)
    col_parts = material_ec(volumes(col))
    @test col_parts.concrete > 0.0u"kgCO2e"
    @test col_parts.rebar > 0.0u"kgCO2e"
    @test col_parts.structural_steel == 0.0u"kgCO2e"
    @test col_parts.concrete + col_parts.rebar ≈ element_ec(volumes(col))

    filled = compute_building_ec(struc)
    col_rows = [r for r in filled.members if r.element_type == :column]
    @test length(col_rows) == 1
    @test col_rows[1].ec ≈ element_ec(volumes(col))
    @test col_rows[1].concrete_ec ≈ col_parts.concrete
    @test col_rows[1].rebar_ec ≈ col_parts.rebar
    @test col_rows[1].structural_steel_ec == 0.0u"kgCO2e"

    beam = StructuralSizer.RCBeamSection(b = 0.3u"m", h = 0.6u"m", bar_size = 8, n_bars = 3)
    beam_vols = StructuralSynthesizer.member_material_volumes(beam, 6.0u"m", StructuralSizer.NWC_4000; rebar = StructuralSizer.Rebar_60)
    beam_parts = material_ec(beam_vols)
    @test beam_parts.concrete > 0.0u"kgCO2e"
    @test beam_parts.rebar > 0.0u"kgCO2e"
    @test beam_parts.structural_steel == 0.0u"kgCO2e"
    @test beam_parts.concrete + beam_parts.rebar ≈ element_ec(beam_vols)

    steel_vols = StructuralSynthesizer.member_material_volumes(beam, 6.0u"m", StructuralSizer.A992_Steel)
    @test material_ec(steel_vols).structural_steel ≈ element_ec(steel_vols)
    @test material_ec(steel_vols).concrete == 0.0u"kgCO2e"
    @test material_ec(steel_vols).rebar == 0.0u"kgCO2e"
    tot = material_ec_total(struc)
    @test tot.concrete + tot.rebar + tot.structural_steel + tot.timber + tot.other ≈
          filled.total_ec - filled.fireproofing_ec
    by_el = takeoff_by_element(struc)
    @test by_el.columns.concrete_volume > 0.0u"m^3"
    @test by_el.columns.rebar_mass > 0.0u"kg"
    @test by_el.columns.structural_steel_mass == 0.0u"kg"
    @test by_el.columns.concrete_ec + by_el.columns.rebar_ec ≈ col_rows[1].ec
    @test by_el.slabs.concrete_volume == 0.0u"m^3"

    # Reconciliation used to replace the P-M section with four #8 bars.
    # An unchanged cross-section keeps its bars. A modest growth keeps them
    # while ACI 318-11 §10.9.1 still holds. A growth that drops those bars
    # below 0.01Ag is redesigned, so the stored area increases.
    kept_col = Column(1, 3.0u"m"; c1 = 0.4u"m", c2 = 0.4u"m")
    designed = StructuralSizer.RCColumnSection(b = kept_col.c1, h = kept_col.c2, bar_size = 8, n_bars = 8)
    set_section!(kept_col, designed)
    kept = StructuralSynthesizer._assign_flat_plate_column_section!(kept_col)
    @test length(kept.bars) == 8
    @test kept.As_total ≈ designed.As_total

    kept_col.c1 = 0.5u"m"
    kept_col.c2 = 0.5u"m"
    still = StructuralSynthesizer._assign_flat_plate_column_section!(kept_col)
    @test length(still.bars) == 8
    @test still.As_total ≈ designed.As_total
    @test 0.01 <= still.ρg <= 0.08

    kept_col.c1 = 0.8u"m"
    kept_col.c2 = 0.8u"m"
    grown = StructuralSynthesizer._assign_flat_plate_column_section!(kept_col)
    @test 0.01 <= grown.ρg <= 0.08
    @test grown.As_total > designed.As_total
end
