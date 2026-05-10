# ==============================================================================
# Integration Tests: Column Sizing API
# ==============================================================================

using Test
using StructuralSizer
using Unitful
import JuMP
const MOI = JuMP.MOI

@testset "Column Sizing API" begin
    
    @testset "Steel Columns - Basic" begin
        # Simple 3-column problem with increasing demands
        Pu = [500e3, 600e3, 700e3]      # N (compression)
        Mux = [50e3, 60e3, 70e3]        # N*m
        geometries = [
            SteelMemberGeometry(4.0),   # 4m tall columns
            SteelMemberGeometry(4.0),
            SteelMemberGeometry(4.0),
        ]
        
        result = size_columns(Pu, Mux, geometries, SteelColumnOptions())
        
        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 3
        @test all(s -> s isa ISymmSection, result.sections)
        @test result.objective_value > 0
    end
    
    @testset "Steel Columns - Custom Options" begin
        Pu = [500e3, 600e3]
        Mux = [50e3, 60e3]
        geometries = [SteelMemberGeometry(4.0), SteelMemberGeometry(4.0)]
        
        opts = SteelColumnOptions(
            section_type = :hss,
            catalog = :all,
            max_depth = 0.5u"m",
        )
        
        result = size_columns(Pu, Mux, geometries, opts)
        
        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test all(s -> s isa HSSRectSection, result.sections)
    end
    
    @testset "Concrete Columns - Basic" begin
        # Simple 2-column problem
        Pu = [800.0, 1000.0]           # kip (compression)
        Mux = [80.0, 100.0]            # kip-ft
        geometries = [
            ConcreteMemberGeometry(3.66),   # ~12 ft
            ConcreteMemberGeometry(3.66),
        ]
        
        opts = ConcreteColumnOptions(include_biaxial = false)
        result = size_columns(Pu, Mux, geometries, opts)
        
        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 2
        @test all(s -> s isa RCColumnSection, result.sections)
        @test result.objective_value > 0
    end
    
    @testset "Concrete Columns - Biaxial Demands" begin
        # Column with biaxial moments
        Pu = [600.0]                   # kip
        Mux = [60.0]                   # kip-ft
        Muy = [40.0]                   # kip-ft (biaxial)
        geometries = [ConcreteMemberGeometry(3.66)]
        
        opts = ConcreteColumnOptions(include_biaxial = true)
        result = size_columns(Pu, Mux, geometries, opts; Muy=Muy)
        
        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 1
        @test result.sections[1] isa RCColumnSection
    end
    
    @testset "Concrete Columns - Custom Options" begin
        Pu = [500.0]
        Mux = [50.0]
        geometries = [ConcreteMemberGeometry(3.0)]
        
        opts = ConcreteColumnOptions(
            material = NWC_5000,
            rebar_material = Rebar_75,
            include_slenderness = false,
            max_depth = 0.6u"m",
        )
        
        result = size_columns(Pu, Mux, geometries, opts)
        
        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
    end
    
    @testset "Geometry Conversion" begin
        # Steel to concrete: Kx → kx, Ky → ky (per-axis preserved)
        steel_geom = SteelMemberGeometry(5.0; Lb=2.5, Kx=1.0, Ky=0.8)
        conc_geom = to_concrete_geometry(steel_geom)

        @test conc_geom isa ConcreteMemberGeometry
        @test conc_geom.L == 5.0u"m"
        @test conc_geom.Lu == 2.5u"m"  # Maps from Lb
        @test conc_geom.kx == 1.0      # Maps from Kx
        @test conc_geom.ky == 0.8      # Maps from Ky

        # Concrete to steel: kx → Kx, ky → Ky.
        conc_geom2 = ConcreteMemberGeometry(4.0; Lu=4.0, kx=1.2, ky=0.9)
        steel_geom2 = to_steel_geometry(conc_geom2)

        @test steel_geom2 isa SteelMemberGeometry
        @test steel_geom2.L == 4.0u"m"
        @test steel_geom2.Lb == 4.0u"m"  # Maps from Lu
        @test steel_geom2.Kx == 1.2      # Maps from kx
        @test steel_geom2.Ky == 0.9      # Maps from ky

        # Single-`k` legacy constructor still sets both kx and ky.
        conc_geom3 = ConcreteMemberGeometry(4.0; Lu=4.0, k=1.2)
        @test conc_geom3.kx == 1.2
        @test conc_geom3.ky == 1.2

        # Batch conversion
        geoms = [ConcreteMemberGeometry(3.0), ConcreteMemberGeometry(4.0)]
        steel_geoms = convert_geometries(geoms, :steel)
        @test all(g -> g isa SteelMemberGeometry, steel_geoms)
    end
    
    @testset "Demand Conversion" begin
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
        @test steel_demands[1].Muy == 25.0
        
        # Steel to RC
        member_demands = [
            MemberDemand(1; Pu_c=700.0, Mux=70.0, Muy=35.0),
        ]
        rc_converted = to_rc_demands(member_demands; βdns=0.5)
        
        @test length(rc_converted) == 1
        @test rc_converted[1] isa RCColumnDemand
        @test rc_converted[1].Pu == 700.0
        @test rc_converted[1].βdns == 0.5
    end
    
    @testset "Length Mismatch Error" begin
        @test_throws ArgumentError size_columns(
            [100.0, 200.0],          # 2 demands
            [10.0],                  # 1 moment - mismatch!
            [SteelMemberGeometry(4.0), SteelMemberGeometry(4.0)],
            SteelColumnOptions()
        )
    end
end

println("Column sizing API tests passed!")
