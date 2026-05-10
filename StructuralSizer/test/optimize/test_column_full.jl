# ==============================================================================
# Full Column Sizing Workflow Tests
# ==============================================================================
# End-to-end tests for the unified column sizing API with both
# steel and concrete materials.

using Test
using StructuralSizer
using Unitful
import JuMP
const MOI = JuMP.MOI

@testset "Full Column Sizing Workflow" begin
    
    # Test data: 4-column building with varying demands
    column_heights = [4.0, 4.0, 4.0, 4.0]  # meters
    Pu_kip = [800.0, 1000.0, 1200.0, 600.0]  # factored axial (kip)
    Mux_kipft = [80.0, 100.0, 120.0, 60.0]   # factored moment about x (kip-ft)
    Muy_kipft = [40.0, 50.0, 60.0, 30.0]     # factored moment about y (kip-ft)
    
    # Convert to SI for steel (N, N*m)
    Pu_N = Pu_kip .* 4448.22
    Mux_Nm = Mux_kipft .* 1355.82
    Muy_Nm = Muy_kipft .* 1355.82
    
    # Geometries
    conc_geometries = [ConcreteMemberGeometry(h; Lu=h, k=1.0) for h in column_heights]
    steel_geometries = [SteelMemberGeometry(h; Lb=h, Kx=1.0, Ky=1.0) for h in column_heights]
    
    # =========================================================================
    @testset "Steel Columns - Default Options" begin
        result = size_columns(Pu_N, Mux_Nm, steel_geometries, SteelColumnOptions())
        
        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 4
        @test all(s -> s isa ISymmSection, result.sections)
        @test result.objective_value > 0
        
        # All sections should be W shapes (default)
        for sec in result.sections
            @test startswith(sec.name, "W")
        end
    end
    
    # =========================================================================
    @testset "Steel Columns - HSS" begin
        opts = SteelColumnOptions(section_type = :hss)
        result = size_columns(Pu_N, Mux_Nm, steel_geometries, opts; Muy=Muy_Nm)
        
        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 4
        @test all(s -> s isa HSSRectSection, result.sections)
        
        # All sections should be HSS
        for sec in result.sections
            @test startswith(sec.name, "HSS")
        end
    end
    
    # =========================================================================
    @testset "Steel Columns - Pipe" begin
        opts = SteelColumnOptions(section_type = :pipe)
        result = size_columns(Pu_N, Mux_Nm, steel_geometries, opts)
        
        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 4
    end
    
    # =========================================================================
    @testset "Steel Columns - Combined W + HSS" begin
        opts = SteelColumnOptions(section_type = :w_and_hss)
        result = size_columns(Pu_N, Mux_Nm, steel_geometries, opts; Muy=Muy_Nm)
        
        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 4
        
        # Sections can be either W or HSS
        for sec in result.sections
            is_w = sec isa ISymmSection
            is_hss = sec isa HSSRectSection
            @test is_w || is_hss
        end
    end
    
    # =========================================================================
    @testset "Steel Columns - Max Depth" begin
        opts = SteelColumnOptions(max_depth = 0.35u"m")  # 350mm max
        result = size_columns(Pu_N, Mux_Nm, steel_geometries, opts)
        
        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        
        # All sections should respect depth constraint
        for sec in result.sections
            d_m = ustrip(u"m", section_depth(sec))
            @test d_m <= 0.36  # Allow small tolerance
        end
    end
    
    # =========================================================================
    @testset "Concrete Columns - Default Options" begin
        opts = ConcreteColumnOptions()
        result = size_columns(Pu_kip, Mux_kipft, conc_geometries, opts; Muy=Muy_kipft)
        
        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 4
        @test all(s -> s isa RCColumnSection, result.sections)
        @test result.objective_value > 0
        
        # All sections should have reasonable sizes (12" to 30")
        for sec in result.sections
            b_in = ustrip(u"inch", sec.b)
            h_in = ustrip(u"inch", sec.h)
            @test 12 <= b_in <= 30
            @test 12 <= h_in <= 30
        end
    end
    
    # =========================================================================
    @testset "Concrete Columns - High Strength" begin
        opts = ConcreteColumnOptions(material = NWC_6000)
        result = size_columns(Pu_kip, Mux_kipft, conc_geometries, opts; Muy=Muy_kipft)
        
        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 4
    end
    
    # =========================================================================
    @testset "Concrete Columns - Max Depth" begin
        # Use smaller demands to fit within 600mm limit
        Pu_small = [400.0, 500.0, 600.0, 300.0]
        Mux_small = [40.0, 50.0, 60.0, 30.0]
        Muy_small = [20.0, 25.0, 30.0, 15.0]
        
        opts = ConcreteColumnOptions(max_depth = 0.6u"m")  # 600mm limit (24")
        result = size_columns(Pu_small, Mux_small, conc_geometries, opts; Muy=Muy_small)
        
        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        
        # All sections should respect max_depth constraint
        for sec in result.sections
            h_m = ustrip(u"m", sec.h)
            @test h_m <= 0.61  # 600mm + tolerance
        end
    end
    
    # =========================================================================
    @testset "Concrete Columns - No Slenderness" begin
        opts = ConcreteColumnOptions(include_slenderness = false)
        result = size_columns(Pu_kip, Mux_kipft, conc_geometries, opts)
        
        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 4
    end
    
    # =========================================================================
    @testset "n_max_sections Constraint" begin
        opts = ConcreteColumnOptions(n_max_sections = 2)
        result = size_columns(Pu_kip, Mux_kipft, conc_geometries, opts; Muy=Muy_kipft)
        
        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 4
        
        # Should use at most 2 unique sections
        unique_sections = unique(result.sections)
        @test length(unique_sections) <= 2
    end
    
    # =========================================================================
    @testset "Material Comparison" begin
        opts_w = SteelColumnOptions()
        opts_hss = SteelColumnOptions(section_type = :hss)
        opts_rc = ConcreteColumnOptions()
        
        result_w = size_columns(Pu_N, Mux_Nm, steel_geometries, opts_w; Muy=Muy_Nm)
        result_hss = size_columns(Pu_N, Mux_Nm, steel_geometries, opts_hss; Muy=Muy_Nm)
        result_rc = size_columns(Pu_kip, Mux_kipft, conc_geometries, opts_rc; Muy=Muy_kipft)
        
        # All should succeed
        @test result_w.status == MOI.OPTIMAL || result_w.status == MOI.TIME_LIMIT
        @test result_hss.status == MOI.OPTIMAL || result_hss.status == MOI.TIME_LIMIT
        @test result_rc.status == MOI.OPTIMAL || result_rc.status == MOI.TIME_LIMIT
        
        # Steel should have smaller volume than concrete (for same loads)
        @test result_w.objective_value < result_rc.objective_value
        @test result_hss.objective_value < result_rc.objective_value
        
        # HSS is typically more efficient for biaxial loading
        @test result_hss.objective_value <= result_w.objective_value * 1.1  # within 10%
    end
    
    # =========================================================================
    @testset "Geometry Conversions" begin
        # Steel → concrete preserves per-axis k (Kx → kx, Ky → ky).
        steel_geom = SteelMemberGeometry(5.0; Lb=2.5, Kx=1.0, Ky=0.8)
        conc_geom = to_concrete_geometry(steel_geom)

        @test conc_geom isa ConcreteMemberGeometry
        @test ustrip(u"m", conc_geom.L) ≈ 5.0
        @test ustrip(u"m", conc_geom.Lu) ≈ 2.5
        @test conc_geom.kx == 1.0
        @test conc_geom.ky == 0.8

        # Concrete → steel preserves per-axis k (kx → Kx, ky → Ky).
        conc_geom2 = ConcreteMemberGeometry(4.0; Lu=4.0, kx=1.2, ky=0.9)
        steel_geom2 = to_steel_geometry(conc_geom2)

        @test steel_geom2 isa SteelMemberGeometry
        @test ustrip(u"m", steel_geom2.L) ≈ 4.0
        @test ustrip(u"m", steel_geom2.Lb) ≈ 4.0
        @test steel_geom2.Kx == 1.2
        @test steel_geom2.Ky == 0.9
        
        # Batch conversion
        geoms = [ConcreteMemberGeometry(3.0), ConcreteMemberGeometry(4.0)]
        steel_geoms = convert_geometries(geoms, :steel)
        @test all(g -> g isa SteelMemberGeometry, steel_geoms)
    end
    
    # =========================================================================
    @testset "Demand Conversions" begin
        # RC to Steel
        rc_demands = [
            RCColumnDemand(1; Pu=500.0, Mux=50.0, Muy=25.0),
            RCColumnDemand(2; Pu=600.0, Mux=60.0, Muy=30.0),
        ]
        steel_demands = to_steel_demands(rc_demands)
        
        @test length(steel_demands) == 2
        @test all(d -> d isa MemberDemand, steel_demands)
        @test steel_demands[1].Pu_c == 500.0
        @test steel_demands[1].Mux == 50.0
        
        # Steel to RC
        member_demands = [MemberDemand(1; Pu_c=700.0, Mux=70.0, Muy=35.0)]
        rc_converted = to_rc_demands(member_demands; βdns=0.5)
        
        @test length(rc_converted) == 1
        @test rc_converted[1] isa RCColumnDemand
        @test rc_converted[1].Pu == 700.0
        @test rc_converted[1].βdns == 0.5
    end
    
    # =========================================================================
    @testset "Options Display" begin
        opts_steel = SteelColumnOptions(section_type = :hss, max_depth = 0.4u"m")
        opts_conc = ConcreteColumnOptions(max_depth = 0.5u"m", n_max_sections = 3)
        opts_beam = SteelBeamOptions(deflection_limit = 1/480)
        
        # Check display includes key info
        str_steel = string(opts_steel)
        @test occursin("Steel", str_steel)
        @test occursin("HSS", str_steel)
        @test occursin("0.4", str_steel)
        
        str_conc = string(opts_conc)
        @test occursin("Concrete", str_conc)
        @test occursin("0.5", str_conc)
        @test occursin("3", str_conc)
        
        str_beam = string(opts_beam)
        @test occursin("Member", str_beam) || occursin("Beam", str_beam)
        @test occursin("480", str_beam)
    end
    
    # =========================================================================
    @testset "Default Values" begin
        # Steel defaults
        s = SteelColumnOptions()
        @test s.material === A992_Steel
        @test s.section_type === :w
        @test s.catalog === :preferred
        @test isinf(ustrip(u"m", s.max_depth))
        @test s.n_max_sections == 0
        
        # Concrete defaults
        c = ConcreteColumnOptions()
        @test c.material === NWC_4000
        @test c.rebar_material === Rebar_60
        @test c.catalog === :standard
        @test c.include_slenderness == true
        @test c.include_biaxial == true
        @test c.βdns == 0.6
        
        # Beam defaults
        b = SteelBeamOptions()
        @test b.material === A992_Steel
        @test b.deflection_limit ≈ 1/360
    end
    
    # =========================================================================
    @testset "Circular Concrete Columns - Default" begin
        opts = ConcreteColumnOptions(section_shape = :circular)
        
        # Use smaller demands for circular columns (typically used for lighter loads)
        Pu_circ = [400.0, 500.0, 600.0, 350.0]  # kip
        Mux_circ = [40.0, 50.0, 60.0, 35.0]     # kip-ft
        
        result = size_columns(Pu_circ, Mux_circ, conc_geometries, opts)
        
        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 4
        @test all(s -> s isa RCCircularSection, result.sections)
        @test result.objective_value > 0
        
        # All sections should have reasonable diameters (12" to 30")
        for sec in result.sections
            D_in = ustrip(u"inch", sec.D)
            @test 12 <= D_in <= 36
        end
    end
    
    # =========================================================================
    @testset "Circular Concrete Columns - High Strength" begin
        opts = ConcreteColumnOptions(
            section_shape = :circular,
            material = NWC_6000
        )
        
        Pu_circ = [500.0, 600.0, 700.0, 400.0]
        Mux_circ = [50.0, 60.0, 70.0, 40.0]
        
        result = size_columns(Pu_circ, Mux_circ, conc_geometries, opts)
        
        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 4
        @test all(s -> s isa RCCircularSection, result.sections)
    end
    
    # =========================================================================
    @testset "Circular Concrete Columns - Biaxial" begin
        opts = ConcreteColumnOptions(
            section_shape = :circular,
            include_biaxial = true
        )
        
        Pu_circ = [400.0, 500.0, 600.0, 350.0]
        Mux_circ = [40.0, 50.0, 60.0, 35.0]
        Muy_circ = [30.0, 40.0, 50.0, 25.0]
        
        result = size_columns(Pu_circ, Mux_circ, conc_geometries, opts; Muy=Muy_circ)
        
        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 4
        @test all(s -> s isa RCCircularSection, result.sections)
    end
    
    # =========================================================================
    @testset "Circular Concrete Columns - Max Depth" begin
        opts = ConcreteColumnOptions(
            section_shape = :circular,
            max_depth = 0.5u"m"  # 500mm max (≈20")
        )
        
        # Smaller demands to fit within 20" diameter
        Pu_small = [200.0, 250.0, 300.0, 150.0]
        Mux_small = [20.0, 25.0, 30.0, 15.0]
        
        result = size_columns(Pu_small, Mux_small, conc_geometries, opts)
        
        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        
        # All sections should respect max_depth constraint (diameter ≤ 500mm)
        for sec in result.sections
            D_m = ustrip(u"m", sec.D)
            @test D_m <= 0.51  # 500mm + small tolerance
        end
    end
    
    # =========================================================================
    @testset "Circular vs Rectangular Comparison" begin
        opts_rect = ConcreteColumnOptions(section_shape = :rect)
        opts_circ = ConcreteColumnOptions(section_shape = :circular)
        
        Pu_test = [400.0, 500.0, 600.0, 350.0]
        Mux_test = [40.0, 50.0, 60.0, 35.0]
        
        result_rect = size_columns(Pu_test, Mux_test, conc_geometries, opts_rect)
        result_circ = size_columns(Pu_test, Mux_test, conc_geometries, opts_circ)
        
        # Both should succeed
        @test result_rect.status == MOI.OPTIMAL || result_rect.status == MOI.TIME_LIMIT
        @test result_circ.status == MOI.OPTIMAL || result_circ.status == MOI.TIME_LIMIT
        
        # Check section types
        @test all(s -> s isa RCColumnSection, result_rect.sections)
        @test all(s -> s isa RCCircularSection, result_circ.sections)
        
        # Both should have positive objective values
        @test result_rect.objective_value > 0
        @test result_circ.objective_value > 0
    end
    
    # =========================================================================
    @testset "Catalog Builders" begin
        # Steel catalogs
        w_cat = steel_column_catalog(:w, :preferred)
        @test length(w_cat) > 0
        @test all(s -> s isa ISymmSection, w_cat)
        
        hss_cat = steel_column_catalog(:hss, :all)
        @test length(hss_cat) > 0
        @test all(s -> s isa HSSRectSection, hss_cat)
        
        combined = steel_column_catalog(:w_and_hss, :preferred)
        @test length(combined) == length(preferred_W()) + length(all_HSS())
        
        # RC rectangular catalogs
        rc_rect_std = rc_column_catalog(:rect, :standard)
        @test length(rc_rect_std) > 0
        @test all(s -> s isa RCColumnSection, rc_rect_std)
        
        rc_rect_all = rc_column_catalog(:rect, :all)
        @test length(rc_rect_all) >= length(rc_rect_std)
        
        # RC circular catalogs
        rc_circ_std = rc_column_catalog(:circular, :standard)
        @test length(rc_circ_std) > 0
        @test all(s -> s isa RCCircularSection, rc_circ_std)
        
        rc_circ_all = rc_column_catalog(:circular, :all)
        @test length(rc_circ_all) >= length(rc_circ_std)
        
        # Legacy single-arg version defaults to rectangular
        rc_std = rc_column_catalog(:standard)
        @test length(rc_std) > 0
        @test all(s -> s isa RCColumnSection, rc_std)
    end
    
    # =========================================================================
    @testset "Error Handling" begin
        # Mismatched demand/geometry lengths
        @test_throws ArgumentError size_columns(
            [100.0, 200.0], [10.0], [SteelMemberGeometry(4.0), SteelMemberGeometry(4.0)],
            SteelColumnOptions()
        )
        
        # Invalid steel catalog type
        @test_throws ArgumentError steel_column_catalog(:invalid, :all)
        
        # Invalid RC section_shape
        @test_throws ArgumentError rc_column_catalog(:invalid, :common)
        
        # Invalid catalog for RC (legacy single-arg version)
        @test_throws ArgumentError rc_column_catalog(:invalid)
    end
end
