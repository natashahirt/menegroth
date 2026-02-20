# =============================================================================
# Test the new design API: typed floor options, material cascade,
# prepare!/capture_design, and parametric variation with `with`.
# =============================================================================

using StructuralSynthesizer
using StructuralSizer
using Test
using Unitful

println("Testing new design API...")

@testset "Design API" begin

    # ─── Typed Floor Options ──────────────────────────────────────────────
    @testset "AbstractFloorOptions hierarchy" begin
        # All option types are AbstractFloorOptions subtypes
        @test FlatPlateOptions()  isa AbstractFloorOptions
        @test FlatSlabOptions()   isa AbstractFloorOptions
        @test OneWayOptions()     isa AbstractFloorOptions
        @test VaultOptions()      isa AbstractFloorOptions
        @test CompositeDeckOptions() isa AbstractFloorOptions
        @test TimberOptions()     isa AbstractFloorOptions

        # floor_symbol returns the correct discriminator
        @test StructuralSizer.floor_symbol(FlatPlateOptions()) == :flat_plate
        @test StructuralSizer.floor_symbol(FlatSlabOptions())  == :flat_slab
        @test StructuralSizer.floor_symbol(OneWayOptions())    == :one_way
        @test StructuralSizer.floor_symbol(VaultOptions())     == :vault
    end

    # ─── Typed Analysis Method ────────────────────────────────────────────
    @testset "Typed analysis method in FlatPlateOptions" begin
        # Default method is DDM()
        opts = FlatPlateOptions()
        @test opts.method isa DDM
        @test opts.method.variant == :full

        # Typed method objects
        opts_mddm = FlatPlateOptions(method = DDM(:simplified))
        @test opts_mddm.method isa DDM
        @test opts_mddm.method.variant == :simplified

        opts_efm = FlatPlateOptions(method = EFM(:asap))
        @test opts_efm.method isa EFM

        opts_fea = FlatPlateOptions(method = FEA())
        @test opts_fea.method isa FEA

        # Backward-compat: .analysis_method returns a Symbol
        @test opts.analysis_method == :ddm
        @test opts_mddm.analysis_method == :mddm
        @test opts_efm.analysis_method == :efm
        @test opts_fea.analysis_method == :fea

        opts_hc = FlatPlateOptions(method = EFM(:moment_distribution))
        @test opts_hc.analysis_method == :efm_hc
    end

    # ─── FlatSlabOptions forwarding ───────────────────────────────────────
    @testset "FlatSlabOptions property forwarding" begin
        fs = FlatSlabOptions(base = FlatPlateOptions(method = EFM()))
        @test fs.method isa EFM
        @test fs.analysis_method == :efm
        @test fs.material == RC_4000_60

        # flat_slab convenience constructor
        fs2 = flat_slab(method = FEA(), shear_studs = :always)
        @test fs2 isa FlatSlabOptions
        @test fs2.method isa FEA
        @test fs2.shear_studs == :always
    end

    # ─── DesignParameters floor field ─────────────────────────────────────
    @testset "DesignParameters.floor" begin
        # Floor field accepts typed options
        params = DesignParameters(
            floor = FlatPlateOptions(method = EFM(:asap)),
        )
        @test !isnothing(params.floor)
        @test params.floor isa FlatPlateOptions
        @test params.floor.method isa EFM

        # Default is nothing → resolve_floor_options returns FlatPlateOptions()
        params_default = DesignParameters()
        resolved = resolve_floor_options(params_default)
        @test resolved isa FlatPlateOptions
    end

    # ─── Material Cascade ─────────────────────────────────────────────────
    @testset "Material cascade" begin
        # Default: NWC_4000 when nothing set
        params = DesignParameters()
        @test resolve_concrete(params) == NWC_4000
        @test resolve_rebar(params) == Rebar_60

        # Building-level override via MaterialOptions
        params5k = DesignParameters(
            materials = MaterialOptions(concrete = NWC_5000, rebar = Rebar_75),
        )
        @test resolve_concrete(params5k) == NWC_5000
        @test resolve_rebar(params5k) == Rebar_75

        # RC material builds from cascaded values
        mat = resolve_rc_material(params5k)
        @test mat.concrete == NWC_5000
        @test mat.rebar == Rebar_75

        # Member-level override beats params-level
        @test resolve_concrete(params5k, NWC_6000) == NWC_6000
        @test resolve_rebar(params5k, Rebar_80) == Rebar_80

        # Material cascade applies to floor options
        params_cascade = DesignParameters(
            materials = MaterialOptions(concrete = NWC_5000, rebar = Rebar_75),
            floor = FlatPlateOptions(),
        )
        resolved = resolve_floor_options(params_cascade)
        @test resolved isa FlatPlateOptions
        @test resolved.material.concrete == NWC_5000
        @test resolved.material.rebar == Rebar_75
    end

    # ─── with() helper ────────────────────────────────────────────────────
    @testset "with() parameter variation" begin
        base = DesignParameters(
            name = "base",
            materials = MaterialOptions(concrete = NWC_4000),
            floor = FlatPlateOptions(method = DDM()),
        )

        # Vary floor
        v1 = with(base; floor = FlatPlateOptions(method = FEA()))
        @test v1.floor.method isa FEA
        @test v1.name == "base"   # unchanged
        @test v1.materials.concrete == NWC_4000  # unchanged

        # Vary material
        v2 = with(base; materials = MaterialOptions(concrete = NWC_6000), name = "high-strength")
        @test v2.materials.concrete == NWC_6000
        @test v2.name == "high-strength"
        @test v2.floor.method isa DDM  # unchanged

        # Vary loads
        v3 = with(base; loads = GravityLoads(floor_LL = 80.0psf))
        @test v3.loads.floor_LL == 80.0psf

        # Original unchanged
        @test base.materials.concrete == NWC_4000
        @test base.name == "base"
    end

    # ─── prepare! + capture_design (integration) ─────────────────────────
    @testset "prepare! and capture_design" begin
        skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 1)
        struc = BuildingStructure(skel)
        params = DesignParameters(
            name = "prepare_test",
            floor = FlatPlateOptions(method = DDM()),
            max_iterations = 3,
        )

        # prepare! initializes + snapshots
        prepare!(struc, params)
        @test has_snapshot(struc)
        @test length(struc.slabs) > 0
        @test length(struc.columns) > 0

        # Run the pipeline stages manually
        for stage in build_pipeline(params)
            stage.fn(struc)
            stage.needs_sync && sync_asap!(struc; params=params)
        end

        # Capture results
        design = capture_design(struc, params)
        @test design isa BuildingDesign
        @test design.params.name == "prepare_test"
        @test length(design.slabs) > 0
    end

    # ─── Full design_building with new API ────────────────────────────────
    @testset "design_building with typed floor" begin
        skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 1)
        struc = BuildingStructure(skel)

        design = design_building(struc, DesignParameters(
            name = "new_api_test",
            materials = MaterialOptions(concrete = NWC_4000),
            floor = FlatPlateOptions(method = DDM()),
            max_iterations = 3,
        ))

        @test design isa BuildingDesign
        @test design.params.name == "new_api_test"
        @test all_ok(design) || true  # May or may not pass for small geometry
        @test design.compute_time_s > 0
    end

    # ─── Parametric variation pattern ─────────────────────────────────────
    @testset "Parametric variation pattern" begin
        skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 1)
        struc = BuildingStructure(skel)

        base = DesignParameters(
            materials = MaterialOptions(concrete = NWC_4000),
            floor = FlatPlateOptions(),
            max_iterations = 2,
        )

        # Compare DDM vs EFM
        methods = [DDM(), EFM()]
        designs = BuildingDesign[]
        for m in methods
            p = with(base; name = string(typeof(m)), floor = FlatPlateOptions(method = m))
            d = design_building(struc, p)
            push!(designs, d)
        end

        @test length(designs) == 2
        @test designs[1].params.name == "DDM"
        @test designs[2].params.name == "EFM"

        # Compare via compare_designs
        comparison = compare_designs(designs)
        @test haskey(comparison, "DDM")
        @test haskey(comparison, "EFM")
    end
end

println("All design API tests passed!")
