# =============================================================================
# Test: Comparison of DDM, MDDM, and EFM Flat Plate Sizing Methods
# =============================================================================
#
# This test creates a medium office building and compares the slab thickness
# results from DDM, MDDM, and EFM analysis methods.
#
# =============================================================================

using Test
using Logging
using Unitful
using Unitful: @u_str
using Asap  # For custom units

using StructuralSynthesizer
using StructuralSizer

const SS = StructuralSynthesizer
const SR = StructuralSizer

# =============================================================================
# Test Configuration
# =============================================================================

# Building geometry
const X_DIM = 90.0u"ft"       # Building X dimension
const Y_DIM = 90.0u"ft"       # Building Y dimension  
const FLOOR_HEIGHT = 9.0u"ft" # Story height
const X_BAYS = 3              # Number of bays in X
const Y_BAYS = 3              # Number of bays in Y
const N_STORIES = 1           # Single story for testing

# Expected span
const L1 = X_DIM / X_BAYS     # 18 ft spans
const L2 = Y_DIM / Y_BAYS     # 14 ft spans

# Material
const MATERIAL = SR.NWC_4000

# Loads (per StructurePoint example)
const SDL = 20.0u"psf"
const LL = 50.0u"psf"

@testset "Flat Plate Method Comparison" begin
    
    # =========================================================================
    # Test 1: Create and Initialize Building Structure
    # =========================================================================
    @testset "Building Structure Setup" begin
        # Create building skeleton
        skel = SS.gen_medium_office(X_DIM, Y_DIM, FLOOR_HEIGHT, X_BAYS, Y_BAYS, N_STORIES)
        
        @test length(skel.vertices) > 0
        @test length(skel.edges) > 0
        @test length(skel.faces) > 0
        
        # Expected: 3x3 = 9 floor panels
        floor_faces = get(skel.groups_faces, :slabs, Int[])
        @test length(floor_faces) >= X_BAYS * Y_BAYS  # includes grade + floor levels
        
        @info "Building skeleton created" vertices=length(skel.vertices) edges=length(skel.edges) faces=length(skel.faces)
    end
    
    # =========================================================================
    # Test 2: Initialize with MDDM (default method)
    # =========================================================================
    @testset "MDDM Sizing" begin
        # Create fresh structure for MDDM
        skel = SS.gen_medium_office(X_DIM, Y_DIM, FLOOR_HEIGHT, X_BAYS, Y_BAYS, N_STORIES)
        struc = SS.BuildingStructure(skel)
        
        # Initialize with MDDM (default)
        opts = SR.FlatPlateOptions(method=SR.DDM(:simplified))
        SS.initialize!(struc; 
                       material=MATERIAL, 
                       floor_type=:flat_plate,
                       floor_opts=opts)
        
        @test length(struc.slabs) >= 1  # slabs may be grouped
        
        # Check slab thicknesses
        for slab in struc.slabs
            h = slab.result.thickness
            @test 5.0u"inch" <= h <= 12.0u"inch"
            @info "MDDM slab thickness" h=uconvert(u"inch", h)
        end
        
        # Get representative thickness (should all be similar for uniform grid)
        h_mddm = first(struc.slabs).result.thickness
        
        @info "MDDM sizing complete" n_slabs=length(struc.slabs) h_typical=uconvert(u"inch", h_mddm)
    end
    
    # =========================================================================
    # Test 3: Initialize with DDM
    # =========================================================================
    @testset "DDM Sizing" begin
        # Create fresh structure for DDM
        skel = SS.gen_medium_office(X_DIM, Y_DIM, FLOOR_HEIGHT, X_BAYS, Y_BAYS, N_STORIES)
        struc = SS.BuildingStructure(skel)
        
        # Initialize with DDM
        opts = SR.FlatPlateOptions(method=SR.DDM())
        SS.initialize!(struc; 
                       material=MATERIAL, 
                       floor_type=:flat_plate,
                       floor_opts=opts)
        
        @test length(struc.slabs) >= 1  # slabs may be grouped
        
        # Check slab thicknesses  
        for slab in struc.slabs
            h = slab.result.thickness
            @test 5.0u"inch" <= h <= 12.0u"inch"
            @info "DDM slab thickness" h=uconvert(u"inch", h)
        end
        
        h_ddm = first(struc.slabs).result.thickness
        
        @info "DDM sizing complete" n_slabs=length(struc.slabs) h_typical=uconvert(u"inch", h_ddm)
    end
    
    # =========================================================================
    # Test 4: Initialize with EFM (falls back to DDM for span-based sizing)
    # =========================================================================
    @testset "EFM Sizing (span-based)" begin
        # Create fresh structure for EFM
        skel = SS.gen_medium_office(X_DIM, Y_DIM, FLOOR_HEIGHT, X_BAYS, Y_BAYS, N_STORIES)
        struc = SS.BuildingStructure(skel)
        
        # Initialize with EFM
        opts = SR.FlatPlateOptions(method=SR.EFM())
        SS.initialize!(struc; 
                       material=MATERIAL, 
                       floor_type=:flat_plate,
                       floor_opts=opts)
        
        @test length(struc.slabs) >= 1  # slabs may be grouped
        
        # Check slab thicknesses
        for slab in struc.slabs
            h = slab.result.thickness
            @test 5.0u"inch" <= h <= 12.0u"inch"
            @info "EFM slab thickness" h=uconvert(u"inch", h)
        end
        
        h_efm = first(struc.slabs).result.thickness
        
        @info "EFM sizing complete (span-based fallback)" n_slabs=length(struc.slabs) h_typical=uconvert(u"inch", h_efm)
    end
    
    # =========================================================================
    # Test 5: Compare Results Side-by-Side
    # =========================================================================
    @testset "Method Comparison" begin
        results = Dict{Symbol, Any}()
        
        _method_map = Dict(:mddm => SR.DDM(:simplified), :ddm => SR.DDM(), :efm => SR.EFM())
        for method in [:mddm, :ddm, :efm]
            skel = SS.gen_medium_office(X_DIM, Y_DIM, FLOOR_HEIGHT, X_BAYS, Y_BAYS, N_STORIES)
            struc = SS.BuildingStructure(skel)
            
            opts = SR.FlatPlateOptions(method=_method_map[method])
            SS.initialize!(struc; 
                           material=MATERIAL, 
                           floor_type=:flat_plate,
                           floor_opts=opts)
            
            h = first(struc.slabs).result.thickness
            sw = first(struc.slabs).result.self_weight
            
            results[method] = (
                thickness = uconvert(u"inch", h),
                self_weight = uconvert(u"psf", sw),
                n_slabs = length(struc.slabs)
            )
        end
        
        # Print comparison table
        println("\n" * "="^70)
        println("FLAT PLATE METHOD COMPARISON")
        println("="^70)
        println("Building: $(ustrip(u"ft", X_DIM)) ft × $(ustrip(u"ft", Y_DIM)) ft, $(X_BAYS)×$(Y_BAYS) bays")
        println("Spans: $(ustrip(u"ft", L1)) ft × $(ustrip(u"ft", L2)) ft")
        println("Loads: SDL=$(ustrip(u"psf", SDL)) psf, LL=$(ustrip(u"psf", LL)) psf")
        println("-"^70)
        println("Method     | Thickness (in) | Self-Weight (psf) | Slabs")
        println("-"^70)
        
        for method in [:mddm, :ddm, :efm]
            r = results[method]
            h_val = round(ustrip(r.thickness), digits=2)
            sw_val = round(ustrip(r.self_weight), digits=1)
            println("$(rpad(uppercase(string(method)), 10)) | $(lpad(h_val, 14)) | $(lpad(sw_val, 17)) | $(r.n_slabs)")
        end
        
        println("="^70)
        
        # Verify all methods produce reasonable results
        for (method, r) in results
            @test r.thickness >= 5.0u"inch"  # Minimum practical thickness
            @test r.thickness <= 12.0u"inch" # Maximum for typical flat plate
            @test r.self_weight >= 50.0u"psf"  # Min reasonable self-weight
            @test r.self_weight <= 200.0u"psf" # Max reasonable self-weight
        end
        
        # For span-based sizing, DDM and EFM should give same results
        # (EFM falls back to DDM for simple sizing)
        h_ddm = results[:ddm].thickness
        h_efm = results[:efm].thickness
        @test h_ddm ≈ h_efm rtol=0.01  # Should be identical
        
        # MDDM may differ slightly from DDM due to simplified coefficients
        h_mddm = results[:mddm].thickness
        @test h_mddm ≈ h_ddm rtol=0.15  # Within 15%
    end
    
    # =========================================================================
    # Test 6: Verify Cell Properties
    # =========================================================================
    @testset "Cell Properties" begin
        skel = SS.gen_medium_office(X_DIM, Y_DIM, FLOOR_HEIGHT, X_BAYS, Y_BAYS, N_STORIES)
        struc = SS.BuildingStructure(skel)
        
        opts = SR.FlatPlateOptions(method=SR.DDM())
        SS.initialize!(struc; 
                       material=MATERIAL, 
                       floor_type=:flat_plate,
                       floor_opts=opts)
        
        # Check cell spans
        for cell in struc.cells
            primary = uconvert(u"ft", cell.spans.primary)
            secondary = uconvert(u"ft", cell.spans.secondary)
            
            # Spans should match expected bay dimensions
            @test primary ≈ min(L1, L2) rtol=0.1
            @test secondary ≈ max(L1, L2) rtol=0.1
        end
        
        # Check cell positions (counts both floor and roof levels for 1-story building)
        n_corner = count(c -> c.position == :corner, struc.cells)
        n_edge = count(c -> c.position == :edge, struc.cells)
        n_interior = count(c -> c.position == :interior, struc.cells)
        
        # For 3x3 grid with 2 levels (floor + roof): 4 corners × 2 = 8, 4 edges × 2 = 8, 1 interior × 2 = 2
        @test n_corner == 8  # 4 corners × 2 levels
        @test n_edge == 8    # 4 edges × 2 levels (for 3x3 grid)
        @test n_interior == 2 # 1 interior × 2 levels (for 3x3 grid)
        
        @info "Cell positions" corner=n_corner edge=n_edge interior=n_interior
    end
    
    # =========================================================================
    # Test 7: Verify Span-based M0 Calculation
    # =========================================================================
    @testset "Static Moment M0" begin
        # Use StructuralSizer calculations directly
        c1 = SR.estimate_column_size_from_span(L1)
        ln = SR.clear_span(L1, c1)
        
        # Estimate factored load
        h_est = 7.0u"inch"  # Typical thickness
        sw = SR.slab_self_weight(h_est, MATERIAL.ρ)
        qu = 1.2 * (sw + SDL) + 1.6 * LL
        
        # Calculate M0
        M0 = SR.total_static_moment(qu, L2, ln)
        
        @info "Static moment calculation" ln=uconvert(u"ft", ln) qu=uconvert(u"psf", qu) M0=uconvert(u"kip*ft", M0)
        
        # M0 = qu × l2 × ln² / 8, so it scales roughly with span³
        # Just verify it's positive and reasonable (not zero, not astronomical)
        @test M0 > 0.0u"kip*ft"
        @test M0 < 5000.0u"kip*ft"  # Sanity upper bound for typical flat plates
    end
    
    # =========================================================================
    # Test 8: Summary Statistics
    # =========================================================================
    @testset "Summary Statistics" begin
        println("\n" * "="^70)
        println("SUMMARY STATISTICS")
        println("="^70)
        
        stats = Dict{Symbol, NamedTuple}()
        
        _method_map_stats = Dict(:mddm => SR.DDM(:simplified), :ddm => SR.DDM(), :efm => SR.EFM())
        for method in [:mddm, :ddm, :efm]
            skel = SS.gen_medium_office(X_DIM, Y_DIM, FLOOR_HEIGHT, X_BAYS, Y_BAYS, N_STORIES)
            struc = SS.BuildingStructure(skel)
            
            opts = SR.FlatPlateOptions(method=_method_map_stats[method])
            SS.initialize!(struc; 
                           material=MATERIAL, 
                           floor_type=:flat_plate,
                           floor_opts=opts)
            
            thicknesses = [ustrip(u"inch", s.result.thickness) for s in struc.slabs]
            self_weights = [ustrip(u"psf", s.result.self_weight) for s in struc.slabs]
            
            stats[method] = (
                h_mean = round(sum(thicknesses) / length(thicknesses), digits=2),
                h_min = minimum(thicknesses),
                h_max = maximum(thicknesses),
                sw_mean = round(sum(self_weights) / length(self_weights), digits=1),
                total_slabs = length(struc.slabs)
            )
        end
        
        println("Method     | h_mean | h_min | h_max | sw_mean | Slabs")
        println("-"^70)
        for method in [:mddm, :ddm, :efm]
            s = stats[method]
            println("$(rpad(uppercase(string(method)), 10)) | $(lpad(s.h_mean, 6)) | $(lpad(s.h_min, 5)) | $(lpad(s.h_max, 5)) | $(lpad(s.sw_mean, 7)) | $(s.total_slabs)")
        end
        println("="^70)
        
        @test true  # Summary always passes
    end
end

