# Test AISC E7 Qa effective width calculation for slender webs
# Run with: julia --project=. test/test_qa_slender_web.jl

using StructuralSizer
using StructuralSizer.Asap: ksi, kip
using Unitful

println("Testing AISC E7 Qa effective width for slender webs...")

# Material: A992 Steel (Fy = 50 ksi, E = 29000 ksi)
mat = A992_Steel

# Calculate slenderness limit
E = ustrip(ksi, mat.E)
Fy = ustrip(ksi, mat.Fy)
λr_w = 1.49 * sqrt(E / Fy)
println("\nSlender web limit λr = 1.49√(E/Fy) = $(round(λr_w, digits=2))")

# Test 1: Compact web (typical W-shape)
println("\n1. Testing compact web (W14X90)...")
w14x90 = first(filter(s -> occursin("W14X90", something(s.name, "")), all_W()))
factors1 = StructuralSizer.get_compression_factors(w14x90, mat)
println("   λ_w = $(round(w14x90.λ_w, digits=2)), λr_w = $(round(λr_w, digits=2))")
println("   Qs = $(round(factors1.Qs, digits=3)), Qa = $(round(factors1.Qa, digits=3)), Q = $(round(factors1.Q, digits=3))")
@assert factors1.Qa ≈ 1.0 "Compact web should have Qa = 1.0"
println("   ✓ Compact web correctly has Qa = 1.0")

# Test 2: Create a built-up section with slender web
# For slender web: h/tw > λr_w ≈ 35.88
# Create: d=30", bf=10", tw=0.5", tf=1" → h ≈ 28", λ_w = 28/0.5 = 56 > 35.88
println("\n2. Testing slender web (built-up section)...")
slender_section = ISymmSection(
    30.0u"inch",  # d (total depth)
    10.0u"inch",  # bf (flange width)
    0.5u"inch",   # tw (web thickness)
    1.0u"inch";   # tf (flange thickness)
    name = "Built-up 30x10 slender"
)

println("   Section: d=$(slender_section.d), bf=$(slender_section.bf), tw=$(slender_section.tw), tf=$(slender_section.tf)")
println("   h (clear web) = $(slender_section.h)")
println("   λ_w = $(round(slender_section.λ_w, digits=2)), λr_w = $(round(λr_w, digits=2))")

factors2 = StructuralSizer.get_compression_factors(slender_section, mat)
println("   Qs = $(round(factors2.Qs, digits=3)), Qa = $(round(factors2.Qa, digits=3)), Q = $(round(factors2.Q, digits=3))")

@assert slender_section.λ_w > λr_w "Section should have slender web"
@assert factors2.Qa < 1.0 "Slender web should have Qa < 1.0"
println("   ✓ Slender web correctly has Qa = $(round(factors2.Qa, digits=3)) < 1.0")

# Test 3: Very slender web (extreme case)
println("\n3. Testing very slender web (extreme case)...")
very_slender = ISymmSection(
    40.0u"inch",  # d
    8.0u"inch",   # bf  
    0.25u"inch",  # tw (very thin web)
    0.75u"inch";  # tf
    name = "Extreme slender"
)

println("   h (clear web) = $(very_slender.h)")
println("   λ_w = $(round(very_slender.λ_w, digits=2))")

factors3 = StructuralSizer.get_compression_factors(very_slender, mat)
println("   Qs = $(round(factors3.Qs, digits=3)), Qa = $(round(factors3.Qa, digits=3)), Q = $(round(factors3.Q, digits=3))")

@assert factors3.Qa < factors2.Qa "More slender web should have lower Qa"
println("   ✓ More slender web has lower Qa ($(round(factors3.Qa, digits=3)) < $(round(factors2.Qa, digits=3)))")

# Test 4: Verify Q factor values are reasonable
println("\n4. Verifying Q factor ranges...")
# Q should be in range (0, 1] for slender elements
@assert 0 < factors2.Q <= 1 "Q factor should be in (0, 1]"
@assert 0 < factors3.Q <= 1 "Q factor should be in (0, 1]"

# Qa should decrease with increasing slenderness
@assert factors3.Qa < factors2.Qa < 1.0 "Qa should decrease with slenderness"
println("   ✓ Q factors are in valid range and decrease with slenderness")

println("\n✅ All Qa slender web tests passed!")
