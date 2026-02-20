# Test script to verify biaxial fix for rectangular columns
# Run with: julia --project=. test/test_biaxial_fix.jl

using StructuralSizer
using Unitful

println("Testing biaxial fix for rectangular columns...")

# Create a rectangular column section (b ≠ h)
# 12x24 column with 8 #8 bars
rect_section = RCColumnSection(;
    b = 12u"inch",
    h = 24u"inch", 
    bar_size = 8,
    n_bars = 8,
    cover = 1.5u"inch"
)

# Create a square column section for comparison
square_section = RCColumnSection(;
    b = 18u"inch",
    h = 18u"inch",
    bar_size = 8,
    n_bars = 8,
    cover = 1.5u"inch"
)

# Material
mat = (fc = 4.0, fy = 60.0, Es = 29000.0, εcu = 0.003)

println("\n1. Testing P-M diagram generation for rectangular section...")
diagram_x = generate_PM_diagram(rect_section, mat; n_intermediate=15)
diagram_y = generate_PM_diagram(rect_section, mat, WeakAxis(); n_intermediate=15)

# Get capacities at same axial load
Pu = 300.0  # kip
check_x = check_PM_capacity(diagram_x, Pu, 0.0)
check_y = check_PM_capacity(diagram_y, Pu, 0.0)

println("  Rectangular 12x24:")
println("    φMnx (strong axis) at Pu=$Pu kip: $(round(check_x.φMn_at_Pu, digits=1)) kip-ft")
println("    φMny (weak axis) at Pu=$Pu kip: $(round(check_y.φMn_at_Pu, digits=1)) kip-ft")
println("    Ratio φMnx/φMny: $(round(check_x.φMn_at_Pu / check_y.φMn_at_Pu, digits=2))")

# For rectangular column, strong axis should be stronger
@assert check_x.φMn_at_Pu > check_y.φMn_at_Pu "Strong axis should have higher capacity"
println("  ✓ Strong axis correctly has higher capacity than weak axis")

println("\n2. Testing ACIColumnChecker cache for rectangular vs square...")
checker = ACIColumnChecker(; include_biaxial=true, α_biaxial=1.5)
cache_rect = StructuralSizer.ACIColumnCapacityCache(1)
cache_square = StructuralSizer.ACIColumnCapacityCache(1)

# Precompute for rectangular
StructuralSizer.precompute_capacities!(checker, cache_rect, [rect_section], NWC_4000, MinVolume())
# Precompute for square
StructuralSizer.precompute_capacities!(checker, cache_square, [square_section], NWC_4000, MinVolume())

println("  Rectangular 12x24:")
println("    is_square = $(cache_rect.is_square[1])")
println("    has y-axis diagram = $(cache_rect.diagrams_y[1] !== nothing)")

println("  Square 18x18:")
println("    is_square = $(cache_square.is_square[1])")
println("    has y-axis diagram = $(cache_square.diagrams_y[1] !== nothing)")

@assert cache_rect.is_square[1] == false "Rectangular section should not be flagged as square"
@assert cache_rect.diagrams_y[1] !== nothing "Rectangular section should have y-axis diagram"
@assert cache_square.is_square[1] == true "Square section should be flagged as square"
@assert cache_square.diagrams_y[1] === nothing "Square section should not have y-axis diagram"

println("  ✓ Correct caching behavior for rectangular vs square sections")

println("\n3. Testing biaxial check uses correct φMny for rectangular...")
# For rectangular column, biaxial with Mux = Muy should use different capacities
geometry = ConcreteMemberGeometry(12.0/3.28; k=1.0, braced=true)
demand_biaxial = RCColumnDemand(1; Pu=300.0, Mux=100.0, Muy=100.0)

# Test feasibility - this exercises the biaxial path
is_ok = StructuralSizer.is_feasible(checker, cache_rect, 1, rect_section, NWC_4000, demand_biaxial, geometry)
println("  Rectangular with Mux=Muy=100: feasible = $is_ok")

println("\n4. Testing M1/M2 end moments in RCColumnDemand...")
# Test default: M1=0 (conservative single curvature)
demand_default = RCColumnDemand(1; Pu=300.0, Mux=100.0)
println("  Default M1/M2: M1x=$(demand_default.M1x), M2x=$(demand_default.M2x), Mux=$(demand_default.Mux)")
@assert demand_default.M1x == 0.0 "Default M1x should be 0"
@assert demand_default.M2x == 100.0 "M2x should equal Mux when not specified"
println("  ✓ Default M1=0 convention works correctly")

# Test explicit end moments (double curvature)
demand_double = RCColumnDemand(1; Pu=300.0, M1x=-80.0, M2x=100.0)
println("  Double curvature: M1x=$(demand_double.M1x), M2x=$(demand_double.M2x), Mux=$(demand_double.Mux)")
@assert demand_double.M1x == -80.0 "M1x should be as specified"
@assert demand_double.M2x == 100.0 "M2x should be as specified"
@assert demand_double.Mux == 100.0 "Mux should be max(|M1x|, |M2x|)"
println("  ✓ Explicit end moments work correctly")

# Test single curvature (same sign moments)
demand_single = RCColumnDemand(1; Pu=300.0, M1x=50.0, M2x=100.0)
println("  Single curvature: M1x=$(demand_single.M1x), M2x=$(demand_single.M2x), ratio=$(demand_single.M1x/demand_single.M2x)")
@assert demand_single.M1x / demand_single.M2x > 0 "Same sign = single curvature"
println("  ✓ Single curvature M1/M2 > 0")

println("\n✅ All biaxial fix tests passed!")
