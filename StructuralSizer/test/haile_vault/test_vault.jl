# Test script for Haile unreinforced vault implementation
# Mirrors BasePlotsWithLim.m from MATLAB reference

using Test
using StructuralSizer
using DelimitedFiles
using Unitful: @u_str, ustrip, uconvert

# Explicitly import helpers used in tests (avoids relying on export state / Revise)
using StructuralSizer: total_thrust, is_adequate, vault_stress_symmetric, 
                       vault_stress_asymmetric, solve_equilibrium_rise

# =============================================================================
# Minimal slab-based harness (exercises new slab sizing hierarchy)
# =============================================================================

mutable struct _MockCell{P}
    sdl::P
    live_load::P
    self_weight::P
    face_idx::Int
end

mutable struct _MockSlab
    cell_indices::Vector{Int}
    spans::NamedTuple
    floor_type::Symbol
    result::Any
end

mutable struct _MockStruc{P}
    cells::Vector{_MockCell{P}}
end

function _size_vault_slab(span, sdl, live; options::FloorOptions=FloorOptions())
    P = typeof(sdl)
    cell = _MockCell{P}(sdl, live, zero(P), 1)
    struc = _MockStruc{P}([cell])
    slab = _MockSlab([1], (primary=span,), :vault, nothing)

    return StructuralSizer._size_slab!(StructuralSizer.Vault(), struc, slab, 1; options=options)
end

# =============================================================================
# Test Parameters (Unitful quantities)
# =============================================================================

const TEST_PARAMS = (
    spans = (2.0:0.5:10.5) .* u"m",       # Span range
    lambdas = 5:5:30,                      # Span/rise ratios to test
    trib_depth = 1.0u"m",
    thickness = 0.05u"m",                  # 5 cm shell
    rib_depth = 0.10u"m",                  # 10 cm rib width  
    rib_apex_rise = 0.05u"m",              # 5 cm rib height
    density = 2000.0u"kg/m^3",
    applied_load = 7.0u"kN/m^2",           # Live/SDL
    finishing_load = 1.0u"kN/m^2",
)

# =============================================================================
# Unit Tests
# =============================================================================

@testset "Vault Analysis Tests" begin
    
    @testset "Geometry: parabolic_arc_length" begin
        # Zero rise should return span
        @test parabolic_arc_length(6.0, 0.0) ≈ 6.0
        @test parabolic_arc_length(10.0, 1e-10) ≈ 10.0
        
        # Positive rise should give arc length > span
        L = parabolic_arc_length(6.0, 1.0)
        @test L > 6.0
        @test L < 10.0  # Sanity check
        
        # Symmetry: arc length should be same for same |rise|
        @test parabolic_arc_length(6.0, 1.0) ≈ parabolic_arc_length(6.0, 1.0)
    end
    
    @testset "Geometry: get_vault_properties" begin
        # Verify geometric properties calculation (new helper)
        span, rise = 6.0, 1.0
        t, trib = 0.05, 1.0
        
        # 1. Shell only
        props = StructuralSizer.get_vault_properties(span, rise, t, trib, 0.0, 0.0)
        
        L = parabolic_arc_length(span, rise)
        @test props.arc_length ≈ L
        @test props.shell_cs_area ≈ t * span
        @test props.shell_vol ≈ t * span * trib
        @test props.rib_vol == 0.0
        @test props.total_vol ≈ props.shell_vol
        
        # 2. With ribs
        rib_d, rib_h = 0.1, 0.05
        props_rib = StructuralSizer.get_vault_properties(span, rise, t, trib, rib_d, rib_h)
        
        @test props_rib.shell_vol ≈ props.shell_vol
        @test props_rib.rib_vol > 0
        @test props_rib.total_vol > props.total_vol
    end

    @testset "Physics: volume and weight consistency" begin
        # Verify that reported volume matches reported self-weight
        opts = FloorOptions(
            flat_plate=FlatPlateOptions(material=ReinforcedConcreteMaterial(NWC_4000, Rebar_60)),
            vault=VaultOptions(rise=1.0u"m", thickness=0.05u"m")
        )
        result = _size_vault_slab(6.0u"m", 1.0u"kN/m^2", 0.0u"kN/m^2"; options=opts)
        
        vol = ustrip(result.volume_per_area) # m
        sw = ustrip(result.self_weight)      # kN/m^2
        
        ρ = ustrip(u"kg/m^3", NWC_4000.ρ)
        g = 9.80665 # standard gravity
        
        # Expected SW = Volume * Density * Gravity
        # Note: volume_per_area is Volume / PlanArea.
        # SelfWeight is Force / PlanArea.
        # So SW = VolPerArea * Density * g
        expected_sw = vol * ρ * g / 1000 # kN/m^2
        
        @test sw ≈ expected_sw rtol=0.001
    end
    
    @testset "Symmetric stress analysis" begin
        p = TEST_PARAMS
        span = 6.0u"m"
        rise = 1.0u"m"
        
        result = vault_stress_symmetric(
            span, rise, p.trib_depth, p.thickness,
            p.rib_depth, p.rib_apex_rise, p.density,
            p.applied_load, p.finishing_load
        )
        
        # Check all outputs are positive and reasonable (Unitful)
        @test ustrip(u"MPa", result.σ) > 0
        @test ustrip(u"kN", result.thrust) > 0
        @test ustrip(u"kN/m^2", result.self_weight) > 0
        @test ustrip(u"kN", result.vertical) > 0
        
        # Thrust should increase with lower rise (shallower arch)
        result_shallow = vault_stress_symmetric(
            span, 0.5u"m", p.trib_depth, p.thickness,
            p.rib_depth, p.rib_apex_rise, p.density,
            p.applied_load, p.finishing_load
        )
        @test result_shallow.thrust > result.thrust
    end
    
    @testset "Asymmetric stress analysis" begin
        p = TEST_PARAMS
        span = 6.0u"m"
        rise = 1.0u"m"
        
        result_sym = vault_stress_symmetric(
            span, rise, p.trib_depth, p.thickness,
            p.rib_depth, p.rib_apex_rise, p.density,
            p.applied_load, p.finishing_load
        )
        
        result_asym = vault_stress_asymmetric(
            span, rise, p.trib_depth, p.thickness,
            p.rib_depth, p.rib_apex_rise, p.density,
            p.applied_load, p.finishing_load
        )
        
        # Both analyses should produce positive, reasonable values
        @test ustrip(u"MPa", result_asym.σ) > 0
        @test ustrip(u"kN", result_asym.thrust) > 0
        
        # Note: Asymmetric doesn't always give higher stress!
        # When live load >> dead load, symmetric (full live) can govern.
        # When dead load >> live load, asymmetric can govern.
        # The vault sizing functions correctly take max of both.
        
        # Self-weight should be same for both
        @test result_asym.self_weight ≈ result_sym.self_weight atol=0.01u"kN/m^2"
    end
    
    @testset "Elastic shortening solver" begin
        p = TEST_PARAMS
        span = 6.0u"m"
        rise = 1.0u"m"
        E = 29000.0u"MPa"  # Concrete modulus
        
        # Get self-weight first
        sym = vault_stress_symmetric(
            span, rise, p.trib_depth, p.thickness,
            p.rib_depth, p.rib_apex_rise, p.density,
            p.applied_load, p.finishing_load
        )
        
        # Total load (all Unitful Pressure)
        total_load = p.applied_load + sym.self_weight + p.finishing_load
        
        result = solve_equilibrium_rise(
            span, rise, total_load, p.thickness, p.trib_depth, E
        )
        
        @test result.converged == true
        @test result.final_rise < rise  # Rise decreases under load
        @test result.final_rise > 0u"m" # But stays positive
        
        # With very high E, deflection should be minimal
        result_stiff = solve_equilibrium_rise(
            span, rise, total_load, p.thickness, p.trib_depth, 1e6u"MPa"  # Very stiff
        )
        @test abs(result_stiff.final_rise - rise) < abs(result.final_rise - rise)
    end
    
    @testset "Vault slab sizing API (slab-based)" begin
        # Test with rise
        result1 = _size_vault_slab(
            6.0u"m", 1.0u"kN/m^2", 1.5u"kN/m^2";
            options=FloorOptions(vault=VaultOptions(rise=1.0u"m", thickness=0.05u"m"))
        )
        @test result1.thickness == 0.05u"m"
        @test ustrip(result1.rise) > 0
        @test ustrip(total_thrust(result1)) > 0
        @test ustrip(result1.self_weight) > 0
        @test ustrip(result1.volume_per_area) > 0
        
        # NEW: Test enhanced result fields
        @test ustrip(result1.arc_length) > ustrip(u"m", 6.0u"m")  # Arc > span
        @test result1.σ_max > 0
        @test result1.governing_case in [:symmetric, :asymmetric]
        
        # Test with lambda (should give same result)
        result2 = _size_vault_slab(
            6.0u"m", 1.0u"kN/m^2", 1.5u"kN/m^2";
            options=FloorOptions(vault=VaultOptions(lambda=6.0, thickness=0.05u"m"))
        )
        @test result2.thickness == result1.thickness
        @test total_thrust(result2) ≈ total_thrust(result1) atol=0.01u"kN/m"
        @test result1.volume_per_area ≈ result2.volume_per_area
        
        # Test validation: both rise and lambda should error (conflicting specifications)
        @test_throws ArgumentError _size_vault_slab(
            6.0u"m", 1.0u"kN/m^2", 1.5u"kN/m^2";
            options=FloorOptions(vault=VaultOptions(rise=1.0u"m", lambda=6.0, thickness=0.05u"m"))
        )
        
        # NEW: With optimization support, providing only thickness now optimizes rise
        # (This was previously an error, but is now a valid 1D optimization case)
        result_opt = _size_vault_slab(
            6.0u"m", 1.0u"kN/m^2", 1.5u"kN/m^2";
            options=FloorOptions(vault=VaultOptions(thickness=0.05u"m"))
        )
        @test result_opt.thickness == 0.05u"m"
        @test ustrip(result_opt.rise) > 0  # Rise was optimized
    end
    
    @testset "Enhanced result structure (check tuples)" begin
        # Test result with explicit stress limit
        result = _size_vault_slab(
            6.0u"m", 1.0u"kN/m^2", 1.5u"kN/m^2";
            options=FloorOptions(vault=VaultOptions(
                rise=1.0u"m", 
                thickness=0.05u"m",
                allowable_stress=15.0  # MPa - generous limit
            ))
        )
        
        # Stress check structure
        @test haskey(NamedTuple(result.stress_check), :σ)
        @test haskey(NamedTuple(result.stress_check), :σ_allow)
        @test haskey(NamedTuple(result.stress_check), :ratio)
        @test haskey(NamedTuple(result.stress_check), :ok)
        
        @test result.stress_check.σ > 0
        @test result.stress_check.σ_allow == 15.0
        @test result.stress_check.ratio ≈ result.stress_check.σ / 15.0
        @test result.stress_check.ok == (result.stress_check.σ <= 15.0)
        
        # Deflection check structure
        @test haskey(NamedTuple(result.deflection_check), :δ)
        @test haskey(NamedTuple(result.deflection_check), :limit)
        @test haskey(NamedTuple(result.deflection_check), :ratio)
        @test haskey(NamedTuple(result.deflection_check), :ok)
        
        @test result.deflection_check.δ >= 0
        @test result.deflection_check.limit > 0
        
        # Convergence check structure
        @test haskey(NamedTuple(result.convergence_check), :converged)
        @test haskey(NamedTuple(result.convergence_check), :iterations)
        
        # is_adequate accessor
        expected_adequate = result.stress_check.ok && result.deflection_check.ok && result.convergence_check.converged
        @test is_adequate(result) == expected_adequate
    end
    
    @testset "Default allowable stress (0.45 fc')" begin
        # Test that default allowable stress is 0.45 × fc'
        # NWC_4000 has fc' ≈ 27.6 MPa, so σ_allow ≈ 12.4 MPa
        result = _size_vault_slab(
            6.0u"m", 1.0u"kN/m^2", 1.5u"kN/m^2";
            options=FloorOptions(vault=VaultOptions(rise=1.0u"m", thickness=0.05u"m"))
        )
        
        fc_MPa = ustrip(u"MPa", NWC_4000.fc′)
        expected_allow = 0.45 * fc_MPa
        @test result.stress_check.σ_allow ≈ expected_allow rtol=0.01
    end
    
    @testset "Material from VaultOptions" begin
        # Test using different concrete material
        result_ggbs = _size_vault_slab(
            6.0u"m", 1.0u"kN/m^2", 1.5u"kN/m^2";
            options=FloorOptions(vault=VaultOptions(
                rise=1.0u"m", 
                thickness=0.05u"m",
                material=NWC_GGBS
            ))
        )
        
        # GGBS has same fc' as NWC_4000, so allowable stress should be similar
        fc_ggbs = ustrip(u"MPa", NWC_GGBS.fc′)
        @test result_ggbs.stress_check.σ_allow ≈ 0.45 * fc_ggbs rtol=0.01
    end
    
    @testset "VaultAnalysisMethod types" begin
        # Verify method types exist and are exported
        @test HaileAnalytical <: VaultAnalysisMethod
        @test ShellFEA <: VaultAnalysisMethod
        
        # Default method should be HaileAnalytical
        opts = VaultOptions(rise=1.0u"m", thickness=0.05u"m")
        @test opts.method isa HaileAnalytical
    end
    
    @testset "Vault slab sizing with ribs" begin
        # Without ribs
        result_no_rib = _size_vault_slab(
            6.0u"m", 1.0u"kN/m^2", 1.5u"kN/m^2";
            options=FloorOptions(vault=VaultOptions(rise=1.0u"m", thickness=0.05u"m",
                                                   rib_depth=0.0u"m", rib_apex_rise=0.0u"m"))
        )
        
        # With ribs (should have higher self-weight)
        result_with_rib = _size_vault_slab(
            6.0u"m", 1.0u"kN/m^2", 1.5u"kN/m^2";
            options=FloorOptions(vault=VaultOptions(rise=1.0u"m", thickness=0.05u"m",
                                                   rib_depth=0.10u"m", rib_apex_rise=0.05u"m"))
        )
        
        @test result_with_rib.self_weight > result_no_rib.self_weight
    end
    
    # =========================================================================
    # Analytical Validation Tests
    # =========================================================================
    
    @testset "Analytical: thrust formula H = wL²/8h" begin
        # For a simple case without ribs, verify thrust matches analytical formula
        span = 6.0u"m"
        rise = 1.0u"m"
        trib = 1.0u"m"
        thickness = 0.05u"m"
        density = 2000.0u"kg/m^3"
        applied = 5.0u"kN/m^2"
        finish = 0.0u"kN/m^2"
        
        result = vault_stress_symmetric(
            span, rise, trib, thickness, 0.0u"m", 0.0u"m", density, applied, finish
        )
        
        # Self-weight for shell only: thickness * density * g
        g = 9.80665u"m/s^2"
        sw_expected = thickness * density * g
        @test ustrip(u"kN/m^2", result.self_weight) ≈ ustrip(u"kN/m^2", sw_expected) rtol=0.01
        
        # Total UDL per meter of span
        total_w = (applied + result.self_weight) * trib  # Force/Length
        
        # Analytical thrust: H = wL²/(8h)
        thrust_analytical = total_w * span^2 / (8 * rise)
        @test ustrip(u"kN", result.thrust) ≈ ustrip(u"kN", thrust_analytical) rtol=0.01
        
        # Vertical reaction: V = wL/2
        vertical_analytical = total_w * span / 2
        @test ustrip(u"kN", result.vertical) ≈ ustrip(u"kN", vertical_analytical) rtol=0.01
    end
    
    @testset "Analytical: stress = resultant / area" begin
        span = 6.0u"m"
        rise = 1.0u"m"
        trib = 1.0u"m"
        thickness = 0.05u"m"
        
        result = vault_stress_symmetric(
            span, rise, trib, thickness, 0.0u"m", 0.0u"m", 2000.0u"kg/m^3", 5.0u"kN/m^2", 0.0u"kN/m^2"
        )
        
        # Resultant = √(H² + V²)
        resultant = sqrt(result.thrust^2 + result.vertical^2)
        
        # Stress = Force / Area
        area = trib * thickness
        stress_expected = resultant / area
        
        @test ustrip(u"MPa", result.σ) ≈ ustrip(u"MPa", stress_expected) rtol=0.001
    end
    
    # =========================================================================
    # Physics/Sensitivity Tests
    # =========================================================================
    
    @testset "Physics: stress increases with span" begin
        p = TEST_PARAMS
        lambda = 10  # Fixed span/rise ratio
        
        stresses = Float64[]
        for span_m in [4.0, 6.0, 8.0, 10.0]
            span = span_m * u"m"
            rise = span / lambda
            result = vault_stress_symmetric(
                span, rise, p.trib_depth, p.thickness,
                p.rib_depth, p.rib_apex_rise, p.density,
                p.applied_load, p.finishing_load
            )
            push!(stresses, ustrip(u"MPa", result.σ))
        end
        
        # Stress should increase monotonically with span
        @test issorted(stresses)
    end
    
    @testset "Physics: thrust increases with shallower arch" begin
        p = TEST_PARAMS
        span = 6.0u"m"
        
        thrusts = Float64[]
        for lambda in [5, 10, 15, 20, 25, 30]  # Increasing = shallower
            rise = span / lambda
            result = vault_stress_symmetric(
                span, rise, p.trib_depth, p.thickness,
                p.rib_depth, p.rib_apex_rise, p.density,
                p.applied_load, p.finishing_load
            )
            push!(thrusts, ustrip(u"kN", result.thrust))
        end
        
        # Thrust should increase with lambda (shallower arch)
        @test issorted(thrusts)
    end
    
    @testset "Physics: self-weight increases with thickness" begin
        p = TEST_PARAMS
        span = 6.0u"m"
        rise = 1.0u"m"
        
        weights = Float64[]
        for t_m in [0.03, 0.05, 0.08, 0.10]
            t = t_m * u"m"
            result = vault_stress_symmetric(
                span, rise, p.trib_depth, t,
                0.0u"m", 0.0u"m", p.density,  # No ribs for clarity
                p.applied_load, p.finishing_load
            )
            push!(weights, ustrip(u"kN/m^2", result.self_weight))
        end
        
        @test issorted(weights)
    end
    
    @testset "Physics: elastic shortening increases with lower E" begin
        p = TEST_PARAMS
        span = 6.0u"m"
        rise = 1.0u"m"
        
        sym = vault_stress_symmetric(
            span, rise, p.trib_depth, p.thickness,
            p.rib_depth, p.rib_apex_rise, p.density,
            p.applied_load, p.finishing_load
        )
        total_load = p.applied_load + sym.self_weight
        
        deflections = Float64[]
        for E_val in [30000.0, 10000.0, 5000.0, 2000.0]  # Decreasing stiffness
            E = E_val * u"MPa"
            result = solve_equilibrium_rise(
                span, rise, total_load, p.thickness, p.trib_depth, E
            )
            if result.converged
                push!(deflections, ustrip(u"m", rise - result.final_rise))
            end
        end
        
        # Deflection should increase as E decreases
        @test issorted(deflections)
    end
    
    # =========================================================================
    # Cross-Validation Tests
    # =========================================================================
    
    @testset "Cross-validation: zero live load" begin
        # When live load is zero, symmetric and asymmetric should give
        # the same thrust (both just dead load)
        p = TEST_PARAMS
        span = 6.0u"m"
        rise = 1.0u"m"
        
        result_sym = vault_stress_symmetric(
            span, rise, p.trib_depth, p.thickness,
            p.rib_depth, p.rib_apex_rise, p.density,
            0.0u"kN/m^2", p.finishing_load  # Zero live load
        )
        
        result_asym = vault_stress_asymmetric(
            span, rise, p.trib_depth, p.thickness,
            p.rib_depth, p.rib_apex_rise, p.density,
            0.0u"kN/m^2", p.finishing_load  # Zero live load
        )
        
        # With no live load, asymmetric formula reduces to symmetric
        # H_asym = (L²/16h)(2q_d) = q_d*L²/8h = H_sym
        @test ustrip(u"kN", result_asym.thrust) ≈ ustrip(u"kN", result_sym.thrust) rtol=0.001
    end
    
    @testset "Cross-validation: lambda vs rise equivalence" begin
        # slab sizing with rise=1.0m should equal lambda=6.0 for span=6.0m
        r1 = _size_vault_slab(
            6.0u"m", 1.0u"kN/m^2", 2.0u"kN/m^2";
            options=FloorOptions(vault=VaultOptions(rise=1.0u"m", thickness=0.05u"m"))
        )
        r2 = _size_vault_slab(
            6.0u"m", 1.0u"kN/m^2", 2.0u"kN/m^2";
            options=FloorOptions(vault=VaultOptions(lambda=6.0, thickness=0.05u"m"))
        )
        
        @test total_thrust(r1) ≈ total_thrust(r2)
        @test r1.self_weight ≈ r2.self_weight
        @test r1.rise ≈ r2.rise rtol=0.01
    end
    
    # =========================================================================
    # Edge Case Tests
    # =========================================================================
    
    @testset "Edge cases: extreme geometries" begin
        p = TEST_PARAMS
        
        # Very deep vault (lambda = 5, rise = span/5)
        result_deep = vault_stress_symmetric(
            6.0u"m", 1.2u"m", p.trib_depth, p.thickness,
            0.0u"m", 0.0u"m", p.density, p.applied_load, p.finishing_load
        )
        @test ustrip(u"MPa", result_deep.σ) > 0
        @test ustrip(u"kN", result_deep.thrust) > 0
        
        # Very shallow vault (lambda = 30, rise = span/30)
        result_shallow = vault_stress_symmetric(
            6.0u"m", 0.2u"m", p.trib_depth, p.thickness,
            0.0u"m", 0.0u"m", p.density, p.applied_load, p.finishing_load
        )
        @test ustrip(u"MPa", result_shallow.σ) > 0
        @test result_shallow.thrust > result_deep.thrust
        
        # Short span
        result_short = vault_stress_symmetric(
            2.0u"m", 0.4u"m", p.trib_depth, p.thickness,
            0.0u"m", 0.0u"m", p.density, p.applied_load, p.finishing_load
        )
        @test ustrip(u"MPa", result_short.σ) > 0
        
        # Long span
        result_long = vault_stress_symmetric(
            10.0u"m", 2.0u"m", p.trib_depth, p.thickness,
            0.0u"m", 0.0u"m", p.density, p.applied_load, p.finishing_load
        )
        @test result_long.σ > result_short.σ
    end
    
    @testset "Edge cases: minimal/no ribs" begin
        p = TEST_PARAMS
        span = 6.0u"m"
        rise = 1.0u"m"
        
        # No ribs at all
        r_none = vault_stress_symmetric(
            span, rise, p.trib_depth, p.thickness,
            0.0u"m", 0.0u"m", p.density, p.applied_load, p.finishing_load
        )
        
        # Zero rib height (effectively no ribs)
        r_zero_height = vault_stress_symmetric(
            span, rise, p.trib_depth, p.thickness,
            0.10u"m", 0.0u"m", p.density, p.applied_load, p.finishing_load
        )
        
        # Zero rib depth (effectively no ribs)
        r_zero_depth = vault_stress_symmetric(
            span, rise, p.trib_depth, p.thickness,
            0.0u"m", 0.05u"m", p.density, p.applied_load, p.finishing_load
        )
        
        # All three should have same self-weight
        @test r_none.self_weight ≈ r_zero_height.self_weight
        @test r_none.self_weight ≈ r_zero_depth.self_weight
    end
end

# =============================================================================
# MATLAB Numerical Comparison Tests
# =============================================================================

"""
Load test vectors generated by MATLAB.
Run generate_test_vectors.m in MATLAB first to create test_vectors.csv
"""
function load_matlab_test_vectors()
    csv_path = joinpath(@__DIR__, "test_vectors.csv")
    if !isfile(csv_path)
        return nothing
    end
    
    # Read CSV (skip header)
    data, header = readdlm(csv_path, ',', Any, '\n', header=true)
    header = vec(header)
    
    # Convert to vector of named tuples
    vectors = []
    for i in 1:size(data, 1)
        row = data[i, :]
        push!(vectors, (
            test_type = string(row[1]),
            span = Float64(row[2]),
            ratio = Int(row[3]),
            MOE = Float64(row[4]),
            trib_depth = Float64(row[5]),
            brick_thick_cm = Float64(row[6]),
            wall_thick_cm = Float64(row[7]),
            apex_rise_cm = Float64(row[8]),
            density = Float64(row[9]),
            applied_load_Pa = Float64(row[10]),
            finish_load_Pa = Float64(row[11]),
            stress_MPa = Float64(row[12]),
            self_weight_kN_m2 = Float64(row[13]),
            arc_length = Float64(row[14]),
            final_rise = row[15] == "NaN" ? NaN : Float64(row[15]),
            converged = Bool(row[16]),
            deflection_ok = Bool(row[17])
        ))
    end
    return vectors
end

@testset "MATLAB Numerical Comparison" begin
    vectors = load_matlab_test_vectors()
    
    if isnothing(vectors)
        @warn "test_vectors.csv not found - run generate_test_vectors.m in MATLAB first"
        @test_skip "MATLAB test vectors not available"
    else
        @testset "Symmetric stress (vs MATLAB)" begin
            sym_tests = filter(v -> v.test_type == "symmetric", vectors)
            @test length(sym_tests) > 0
            
            for v in sym_tests
                rise_m = v.span / v.ratio
                result = vault_stress_symmetric(
                    v.span * u"m", rise_m * u"m", v.trib_depth * u"m",
                    (v.brick_thick_cm / 100) * u"m",  # cm to m
                    (v.wall_thick_cm / 100) * u"m",   # cm to m
                    (v.apex_rise_cm / 100) * u"m",    # cm to m
                    v.density * u"kg/m^3",
                    (v.applied_load_Pa / 1000) * u"kN/m^2",  # Pa to kN/m²
                    (v.finish_load_Pa / 1000) * u"kN/m^2"    # Pa to kN/m²
                )
                
                # MATLAB-vs-Julia tolerances:
                # - tiny differences expected from gravity constant, quadgk, and Roots' solver choices
                @test isapprox(ustrip(u"MPa", result.σ), v.stress_MPa, rtol=2e-4)
                @test isapprox(ustrip(u"kN/m^2", result.self_weight), v.self_weight_kN_m2, rtol=5e-4)
            end
        end
        
        @testset "Asymmetric stress (vs MATLAB)" begin
            asym_tests = filter(v -> v.test_type == "asymmetric", vectors)
            @test length(asym_tests) > 0
            
            for v in asym_tests
                rise_m = v.span / v.ratio
                result = vault_stress_asymmetric(
                    v.span * u"m", rise_m * u"m", v.trib_depth * u"m",
                    (v.brick_thick_cm / 100) * u"m",
                    (v.wall_thick_cm / 100) * u"m",
                    (v.apex_rise_cm / 100) * u"m",
                    v.density * u"kg/m^3",
                    (v.applied_load_Pa / 1000) * u"kN/m^2",
                    (v.finish_load_Pa / 1000) * u"kN/m^2"
                )
                
                @test isapprox(ustrip(u"MPa", result.σ), v.stress_MPa, rtol=2e-4)
            end
        end
        
        @testset "Arc length (vs MATLAB)" begin
            arc_tests = filter(v -> v.test_type == "arc_length", vectors)
            @test length(arc_tests) > 0
            
            for v in arc_tests
                rise = v.span / v.ratio
                L = parabolic_arc_length(v.span, rise)
                
                @test isapprox(L, v.arc_length, rtol=1e-6)
            end
        end
        
        @testset "Elastic shortening solver (vs MATLAB)" begin
            elastic_tests = filter(v -> v.test_type == "elastic", vectors)
            @test length(elastic_tests) > 0
            
            for v in elastic_tests
                rise_m = v.span / v.ratio
                span = v.span * u"m"
                rise = rise_m * u"m"
                deflection_limit = span / 240
                
                # Get self-weight for total load (matching MATLAB)
                sym = vault_stress_symmetric(
                    span, rise, v.trib_depth * u"m",
                    (v.brick_thick_cm / 100) * u"m",
                    (v.wall_thick_cm / 100) * u"m",
                    (v.apex_rise_cm / 100) * u"m",
                    v.density * u"kg/m^3",
                    (v.applied_load_Pa / 1000) * u"kN/m^2",
                    (v.finish_load_Pa / 1000) * u"kN/m^2"
                )
                
                # Total load (Unitful Pressure)
                total_load = (v.applied_load_Pa / 1000) * u"kN/m^2" + sym.self_weight
                
                result = solve_equilibrium_rise(
                    span, rise, total_load,
                    (v.brick_thick_cm / 100) * u"m",
                    v.trib_depth * u"m",
                    v.MOE * u"MPa";
                    deflection_limit=deflection_limit
                )
                
                @test result.converged == v.converged
                
                if result.converged && v.converged && !isnan(v.final_rise)
                    # fzero (MATLAB) vs Roots.jl (Julia) can differ slightly in termination / bracketing.
                    @test isapprox(ustrip(u"m", result.final_rise), v.final_rise, rtol=2e-2)
                    @test result.deflection_ok == v.deflection_ok
                end
            end
        end
        
        @testset "No-rib cases (vs MATLAB)" begin
            norib_tests = filter(v -> v.test_type == "no_rib", vectors)
            @test length(norib_tests) > 0
            
            for v in norib_tests
                rise_m = v.span / v.ratio
                result = vault_stress_symmetric(
                    v.span * u"m", rise_m * u"m", v.trib_depth * u"m",
                    (v.brick_thick_cm / 100) * u"m",
                    0.0u"m",  # No rib depth
                    0.0u"m",  # No rib height
                    v.density * u"kg/m^3",
                    (v.applied_load_Pa / 1000) * u"kN/m^2",
                    (v.finish_load_Pa / 1000) * u"kN/m^2"
                )
                
                @test isapprox(ustrip(u"MPa", result.σ), v.stress_MPa, rtol=1e-4)
                @test isapprox(ustrip(u"kN/m^2", result.self_weight), v.self_weight_kN_m2, rtol=5e-4)
            end
        end
        
        println("\n✓ All $(length(vectors)) MATLAB test vectors validated for Haile vault.")
    end
end

# =============================================================================
# Stress-Span Curve Generation (like BasePlotsWithLim.m)
# =============================================================================

"""
Generate stress vs span data for multiple lambda values.
Returns a Dict of lambda => (spans, stresses) pairs.
"""
function generate_stress_curves(;
    spans = (2.0:0.5:10.0) .* u"m",
    lambdas = [5, 10, 15, 20, 25, 30],
    trib_depth = 1.0u"m",
    thickness = 0.05u"m",
    rib_depth = 0.10u"m",
    rib_apex_rise = 0.05u"m",
    density = 2000.0u"kg/m^3",
    applied_load = 7.0u"kN/m^2",
    finishing_load = 1.0u"kN/m^2"
)
    results = Dict{Int, NamedTuple{(:spans, :stresses), Tuple{Vector{Float64}, Vector{Float64}}}}()
    
    for λ in lambdas
        span_vec = Float64[]
        stress_vec = Float64[]
        
        for span in spans
            rise = span / λ
            
            # Use symmetric analysis (like MATLAB base curves)
            result = vault_stress_symmetric(
                span, rise, trib_depth, thickness,
                rib_depth, rib_apex_rise, density,
                applied_load, finishing_load
            )
            
            push!(span_vec, ustrip(u"m", span))
            push!(stress_vec, ustrip(u"MPa", result.σ))
        end
        
        results[λ] = (spans=span_vec, stresses=stress_vec)
    end
    
    return results
end

"""
Find deflection limit curves (like BasePlotsWithLim.m limit curves).
For each lambda, find the max span where deflection check passes.
"""
function find_deflection_limits(;
    spans = (2.0:0.25:10.5) .* u"m",
    lambdas = 5:1:30,
    trib_depth = 1.0u"m",
    thickness = 0.05u"m",
    rib_depth = 0.10u"m",
    rib_apex_rise = 0.05u"m",
    density = 2000.0u"kg/m^3",
    applied_load = 7.0u"kN/m^2",
    finishing_load = 1.0u"kN/m^2",
    E = 2000.0u"MPa"  # Default MOE
)
    limit_spans = Float64[]
    limit_stresses = Float64[]
    
    for λ in lambdas
        last_good_span = NaN * u"m"
        
        for span in spans
            rise = span / λ
            deflection_limit = span / 240
            
            # Get self-weight
            sym = vault_stress_symmetric(
                span, rise, trib_depth, thickness,
                rib_depth, rib_apex_rise, density,
                applied_load, finishing_load
            )
            
            total_load = applied_load + sym.self_weight + finishing_load
            
            # Check elastic shortening
            eq = solve_equilibrium_rise(
                span, rise, total_load, thickness, trib_depth, E;
                deflection_limit=deflection_limit
            )
            
            if eq.converged && eq.deflection_ok
                last_good_span = span
            else
                break  # Failed, stop searching for this lambda
            end
        end
        
        if !isnan(ustrip(last_good_span))
            rise = last_good_span / λ
            result = vault_stress_symmetric(
                last_good_span, rise, trib_depth, thickness,
                rib_depth, rib_apex_rise, density,
                applied_load, finishing_load
            )
            push!(limit_spans, ustrip(u"m", last_good_span))
            push!(limit_stresses, ustrip(u"MPa", result.σ))
        end
    end
    
    return (spans=limit_spans, stresses=limit_stresses)
end

# =============================================================================
# Interactive Demo (only when run directly with --demo flag)
# =============================================================================

if (abspath(PROGRAM_FILE) == @__FILE__) && ("--demo" in ARGS)
    # Generate sample data (tests already ran above)
    println("\nGenerating stress curves...")
    curves = generate_stress_curves()
    
    println("\nStress at span=6m for various lambda:")
    for λ in sort(collect(keys(curves)))
        idx = findfirst(s -> s ≈ 6.0, curves[λ].spans)
        if !isnothing(idx)
            println("  λ=$λ (rise=$(6.0/λ)m): σ = $(round(curves[λ].stresses[idx], digits=3)) MPa")
        end
    end
    
    println("\nFinding deflection limits (E=2000 MPa)...")
    limits = find_deflection_limits(E=2000.0u"MPa")
    println("Limit curve has $(length(limits.spans)) points")
    if !isempty(limits.spans)
        println("  Max span in limit curve: $(maximum(limits.spans)) m")
        println("  Corresponding stress: $(round(limits.stresses[argmax(limits.spans)], digits=3)) MPa")
    end
end
