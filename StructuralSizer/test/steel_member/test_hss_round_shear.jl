# Test AISC G5 shear for round HSS with Lv parameter
# Run with: julia --project=. test/test_hss_round_shear.jl

using StructuralSizer
using StructuralSizer.Asap: ksi, kip
using Unitful

println("Testing AISC G5 shear for round HSS...")

# Material: A500 Grade B (Fy = 42 ksi for round HSS)
# Using A992 for now since A500 isn't defined
mat = A992_Steel

# Create a round HSS section
# HSS6.625x0.280 (6-5/8" OD x 0.280" wall)
hss_round = HSSRoundSection(
    6.625u"inch",  # OD
    0.280u"inch";  # t
    name = "HSS6.625X0.280"
)

println("\nSection: $(hss_round.name)")
println("  OD = $(hss_round.OD), t = $(hss_round.t)")
println("  A = $(round(u"inch^2", hss_round.A, digits=3))")
println("  D/t = $(round(ustrip(hss_round.OD/hss_round.t), digits=1))")

# Test 1: Without Lv (conservative, Fcr = 0.6Fy)
println("\n1. Testing shear without Lv (conservative)...")
Vn_conservative = get_Vn(hss_round, mat)
println("   Vn (conservative) = $(round(kip, Vn_conservative, digits=2))")

# Test 2: With Lv (may allow higher capacity if buckling controls)
L = 10.0u"ft"  # Member length
Lv = L / 2     # Shear from max (support) to zero (midspan)
println("\n2. Testing shear with Lv = $Lv...")
Vn_with_Lv = get_Vn(hss_round, mat; Lv=Lv)
println("   Vn (with Lv) = $(round(kip, Vn_with_Lv, digits=2))")

# Verify conservative is ≤ buckling-controlled (or equal when yielding controls)
@assert Vn_conservative <= Vn_with_Lv || Vn_conservative ≈ Vn_with_Lv "Conservative Vn should not exceed buckling Vn"
println("   ✓ Conservative Vn ≤ Vn with Lv (yielding controls for this stocky section)")

# Test 3: Short Lv (stocky member, yielding definitely controls)
Lv_short = 2.0u"ft"
println("\n3. Testing with short Lv = $Lv_short...")
Vn_short = get_Vn(hss_round, mat; Lv=Lv_short)
println("   Vn (short Lv) = $(round(kip, Vn_short, digits=2))")
@assert Vn_short ≈ Vn_conservative "Short member should be controlled by yielding"
println("   ✓ Short member controlled by yielding")

# Test 4: Very long Lv (buckling may govern)
Lv_long = 30.0u"ft"
println("\n4. Testing with long Lv = $Lv_long...")
Vn_long = get_Vn(hss_round, mat; Lv=Lv_long)
println("   Vn (long Lv) = $(round(kip, Vn_long, digits=2))")
println("   Vn_long/Vn_conservative = $(round(ustrip(Vn_long/Vn_conservative), digits=3))")

# Test 5: LRFD design strength
println("\n5. Testing design shear strength ϕVn...")
ϕVn = get_ϕVn(hss_round, mat; Lv=Lv)
println("   ϕVn = $(round(kip, ϕVn, digits=2)) (ϕ=0.9)")
@assert ϕVn ≈ 0.9 * Vn_with_Lv "ϕVn should equal 0.9 × Vn"
println("   ✓ ϕ = 0.9 correctly applied")

println("\n✅ All round HSS shear tests passed!")
