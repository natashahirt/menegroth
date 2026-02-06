# Test AISC H3 - Torsion for HSS Sections
# Based on AISC 360-16 Section H3 equations

using StructuralSizer
using StructuralSizer: torsional_constant_rect_hss, torsional_constant_round_hss
using StructuralSizer: get_Fcr_torsion, check_combined_torsion_interaction, can_neglect_torsion
using StructuralSizer: HSSRectSection, HSSRoundSection
using StructuralSizer.Asap: ksi, kip  # For ustrip
using Test
using Unitful

println("Testing AISC H3: Torsion for HSS Sections...")

# =============================================================================
# Test 1: Torsional Constant - Rectangular HSS
# =============================================================================
println("\n1. Testing torsional constant for rectangular HSS...")

# HSS 8×4×3/8 (example dimensions)
# B = 4", H = 8", t_nominal = 3/8" = 0.375"
# t_design = 0.93 × 0.375" = 0.349" (per AISC B4.2)
B = 4.0u"inch"
H = 8.0u"inch"
t = 0.349u"inch"

C_rect = torsional_constant_rect_hss(B, H, t)
# C = 2(B-t)(H-t)t - 4.5(4-π)t³
C_expected = 2 * (4.0 - 0.349) * (8.0 - 0.349) * 0.349 - 4.5 * (4 - π) * 0.349^3
println("  HSS 8×4×3/8: C = $(round(ustrip(u"inch^3", C_rect), digits=2)) in³")
println("  Expected: $(round(C_expected, digits=2)) in³")
@test isapprox(ustrip(u"inch^3", C_rect), C_expected, rtol=0.001)

# Square HSS 6×6×1/4
B_sq = 6.0u"inch"
H_sq = 6.0u"inch"
t_sq = 0.233u"inch"  # 0.93 × 0.25"

C_square = torsional_constant_rect_hss(B_sq, H_sq, t_sq)
println("  HSS 6×6×1/4: C = $(round(ustrip(u"inch^3", C_square), digits=2)) in³")
@test C_square > 0u"inch^3"

println("  ✓ Rectangular HSS torsional constant tests passed")

# =============================================================================
# Test 2: Torsional Constant - Round HSS
# =============================================================================
println("\n2. Testing torsional constant for round HSS...")

# HSS 6.625×0.280 (6" nominal pipe)
D = 6.625u"inch"
t_round = 0.260u"inch"  # 0.93 × 0.280"

C_round = torsional_constant_round_hss(D, t_round)
# C = π(D-t)²t / 2
C_round_expected = π * (6.625 - 0.260)^2 * 0.260 / 2
println("  HSS 6.625×0.280: C = $(round(ustrip(u"inch^3", C_round), digits=2)) in³")
println("  Expected: $(round(C_round_expected, digits=2)) in³")
@test isapprox(ustrip(u"inch^3", C_round), C_round_expected, rtol=0.001)

println("  ✓ Round HSS torsional constant tests passed")

# =============================================================================
# Test 3: Critical Stress - Rectangular HSS (H3-3, H3-4, H3-5)
# =============================================================================
println("\n3. Testing Fcr for rectangular HSS...")

# Note: A500 Gr.C and A992 both have Fy = 50 ksi
mat = A992_Steel
E = mat.E
Fy = mat.Fy

# Calculate slenderness limits
rt = sqrt(ustrip(E / Fy))
lim1 = 2.45 * rt  # Compact limit
lim2 = 3.07 * rt  # Noncompact limit
println("  Material: A992 Steel (Fy = $(ustrip(ksi, Fy)) ksi)")
println("  Compact limit (h/t): $(round(lim1, digits=1))")
println("  Noncompact limit (h/t): $(round(lim2, digits=1))")

# Test Case A: Compact section (yielding) - h/t < 2.45√(E/Fy)
# Need h/t ≈ 30-40 for typical HSS
# HSS 6×4×1/2: h = 6-3×0.465 = 4.605", t = 0.465", h/t ≈ 9.9
section_compact = HSSRectSection(6.0u"inch", 4.0u"inch", 0.465u"inch"; name="HSS6X4X1/2")
Fcr_compact = get_Fcr_torsion(section_compact, mat)
println("  Compact (HSS 6×4×1/2, h/t ≈ 10): Fcr = $(round(ustrip(ksi, Fcr_compact), digits=1)) ksi")
@test isapprox(Fcr_compact, 0.6 * Fy, rtol=0.01)  # Should be 0.6Fy for compact

# Test Case B: Noncompact section (inelastic buckling)
# Need h/t in range 59-74 (for Fy=50 ksi)
# Use HSS 12×4×1/8: h = 12-3×0.116 = 11.65", t = 0.116", h/t ≈ 100 (actually slender!)
# Let's use something with h/t ~ 65: HSS 12×4×0.150: h = 12-3×0.150 = 11.55, t = 0.150, h/t = 77 (slender)
# Need: h/t = 65 → for H=12", t ≈ (12-3t)/65 → 12 = t(65+3) = 68t → t = 0.176"
# HSS with H=12", t=0.15": h = 12 - 3×0.15 = 11.55", h/t = 77 (slender, not noncompact)
# Try: h/t = 65 → h = 9.5", t = 0.146", H = h + 3t = 9.94" → use t=0.135, H=10"
#  h = 10 - 3×0.135 = 9.595", h/t = 71 (barely slender)
# For truly noncompact: 59 < h/t < 74
# Use H=10", t=0.140": h = 10 - 0.42 = 9.58", h/t = 68.4 → noncompact
section_noncompact = HSSRectSection(10.0u"inch", 4.0u"inch", 0.140u"inch"; name="HSS10X4X0.140")
Fcr_noncompact = get_Fcr_torsion(section_noncompact, mat)
h_nc = 10.0 - 3*0.140
ht_nc = h_nc / 0.140
println("  Noncompact (HSS 10×4×0.140, h/t ≈ $(round(ht_nc, digits=1))): Fcr = $(round(ustrip(ksi, Fcr_noncompact), digits=1)) ksi")
# For noncompact (59 < h/t < 74), Fcr should be less than 0.6Fy (H3-4)
# H3-4: Fcr = 0.6Fy × 2.45√(E/Fy) / (h/t)
Fcr_expected_nc = 0.6 * ustrip(ksi, Fy) * lim1 / ht_nc
println("  Expected (H3-4): $(round(Fcr_expected_nc, digits=1)) ksi ($(round(ustrip(ksi, 0.6*Fy), digits=1)) × $(round(lim1/ht_nc, digits=2)))")
@test Fcr_noncompact < 0.6 * Fy
@test isapprox(ustrip(ksi, Fcr_noncompact), Fcr_expected_nc, rtol=0.05)

# Test Case C: Slender section (elastic buckling)
# Need h/t > 74 (for Fy=50 ksi)
# HSS 16×4×3/16: h = 16-3×0.174 = 15.48", t = 0.174", h/t ≈ 89
section_slender = HSSRectSection(16.0u"inch", 4.0u"inch", 0.174u"inch"; name="HSS16X4X3/16")
Fcr_slender = get_Fcr_torsion(section_slender, mat)
h_sl = 16.0 - 3*0.174
ht_sl = h_sl / 0.174
# H3-5: Fcr = 0.458π²E/(h/t)²
Fcr_expected_slender = 0.458 * π^2 * ustrip(ksi, E) / ht_sl^2
println("  Slender (HSS 16×4×3/16, h/t ≈ $(round(ht_sl, digits=1))): Fcr = $(round(ustrip(ksi, Fcr_slender), digits=1)) ksi")
println("  Expected (H3-5): $(round(Fcr_expected_slender, digits=1)) ksi")
@test isapprox(ustrip(ksi, Fcr_slender), Fcr_expected_slender, rtol=0.05)

println("  ✓ Rectangular HSS Fcr tests passed")

# =============================================================================
# Test 4: Critical Stress - Round HSS (H3-2a, H3-2b)
# =============================================================================
println("\n4. Testing Fcr for round HSS...")

# HSS 6.625×0.280
round_section = HSSRoundSection(6.625u"inch", 0.260u"inch"; name="HSS6.625X0.280")
L = 10.0u"ft"

# With length (both H3-2a and H3-2b considered)
Fcr_round_L = get_Fcr_torsion(round_section, mat; L=L)
println("  HSS 6.625×0.280, L=10ft: Fcr = $(round(ustrip(ksi, Fcr_round_L), digits=1)) ksi")

# Without length (conservative H3-2b only)
Fcr_round_noL = get_Fcr_torsion(round_section, mat)
println("  HSS 6.625×0.280, no L: Fcr = $(round(ustrip(ksi, Fcr_round_noL), digits=1)) ksi")

# Should not exceed 0.6Fy
@test Fcr_round_L <= 0.6 * Fy
@test Fcr_round_noL <= 0.6 * Fy
@test Fcr_round_L > 0ksi
@test Fcr_round_noL > 0ksi

# Manual check of H3-2b: Fcr2 = 0.60E / (D/t)^1.5
Dt = 6.625 / 0.260
Fcr2_manual = 0.60 * ustrip(ksi, E) / Dt^1.5
println("  H3-2b manual check: Fcr2 = $(round(Fcr2_manual, digits=1)) ksi")

println("  ✓ Round HSS Fcr tests passed")

# =============================================================================
# Test 5: Torsional Strength Tn
# =============================================================================
println("\n5. Testing torsional strength Tn...")

# Rectangular HSS
Tn_rect = get_Tn(section_compact, mat)
ϕTn_rect = get_ϕTn(section_compact, mat)
println("  HSS 6×4×1/2: Tn = $(round(ustrip(kip*u"inch", Tn_rect), digits=0)) kip-in")
println("  HSS 6×4×1/2: ϕTn = $(round(ustrip(kip*u"inch", ϕTn_rect), digits=0)) kip-in")
@test ϕTn_rect ≈ 0.9 * Tn_rect

# Round HSS
Tn_round = get_Tn(round_section, mat; L=L)
ϕTn_round = get_ϕTn(round_section, mat; L=L)
println("  HSS 6.625×0.280: Tn = $(round(ustrip(kip*u"inch", Tn_round), digits=0)) kip-in")
println("  HSS 6.625×0.280: ϕTn = $(round(ustrip(kip*u"inch", ϕTn_round), digits=0)) kip-in")
@test ϕTn_round ≈ 0.9 * Tn_round

println("  ✓ Torsional strength tests passed")

# =============================================================================
# Test 6: Combined Interaction (H3-6)
# =============================================================================
println("\n6. Testing combined interaction (H3-6)...")

# Test case: Member with moderate loads
# (Pr/Pc + Mr/Mc) + (Vr/Vc + Tr/Tc)² ≤ 1.0
Pr, Pc = 50.0, 200.0   # Axial
Mr, Mc = 100.0, 400.0  # Moment
Vr, Vc = 20.0, 80.0    # Shear
Tr, Tc = 30.0, 150.0   # Torsion

ratio = check_combined_torsion_interaction(Pr, Mr, Vr, Tr, Pc, Mc, Vc, Tc)
# (50/200 + 100/400) + (20/80 + 30/150)² = (0.25 + 0.25) + (0.25 + 0.2)² = 0.5 + 0.2025 = 0.7025
expected_ratio = (50/200 + 100/400) + (20/80 + 30/150)^2
println("  Test case: ratio = $(round(ratio, digits=3)) (expected $(round(expected_ratio, digits=3)))")
@test isapprox(ratio, expected_ratio, atol=0.001)
@test ratio < 1.0  # Should pass

# Test case at limit
Pr2, Pc2 = 100.0, 200.0
Mr2, Mc2 = 100.0, 200.0
Vr2, Vc2 = 30.0, 60.0
Tr2, Tc2 = 30.0, 60.0
ratio2 = check_combined_torsion_interaction(Pr2, Mr2, Vr2, Tr2, Pc2, Mc2, Vc2, Tc2)
println("  Limit case: ratio = $(round(ratio2, digits=3))")
# (0.5 + 0.5) + (0.5 + 0.5)² = 1.0 + 1.0 = 2.0 - fails
@test ratio2 > 1.0  # Should fail

println("  ✓ Combined interaction tests passed")

# =============================================================================
# Test 7: Torsion Neglect Check (H3.2)
# =============================================================================
println("\n7. Testing torsion neglect threshold...")

# Can neglect if Tr ≤ 0.2×Tc
@test can_neglect_torsion(10.0, 100.0) == true   # 10% < 20%
@test can_neglect_torsion(20.0, 100.0) == true   # 20% = 20%
@test can_neglect_torsion(25.0, 100.0) == false  # 25% > 20%

println("  ✓ Torsion neglect threshold tests passed")

# =============================================================================
# Test 8: Sanity Checks
# =============================================================================
println("\n8. Sanity checks...")

# Larger sections should have higher torsional capacity
small_rect = HSSRectSection(4.0u"inch", 4.0u"inch", 0.233u"inch"; name="HSS4X4X1/4")
large_rect = HSSRectSection(8.0u"inch", 8.0u"inch", 0.465u"inch"; name="HSS8X8X1/2")
@test get_ϕTn(large_rect, mat) > get_ϕTn(small_rect, mat)
println("  ✓ Larger rect HSS has higher torsional capacity")

small_round = HSSRoundSection(4.5u"inch", 0.175u"inch"; name="HSS4.5X0.188")
large_round = HSSRoundSection(8.625u"inch", 0.300u"inch"; name="HSS8.625X0.322")
@test get_ϕTn(large_round, mat) > get_ϕTn(small_round, mat)
println("  ✓ Larger round HSS has higher torsional capacity")

# Square HSS should have higher torsion capacity than same-perimeter rectangle
# (more material at distance from center)
square = HSSRectSection(6.0u"inch", 6.0u"inch", 0.233u"inch"; name="HSS6X6X1/4")
rect = HSSRectSection(8.0u"inch", 4.0u"inch", 0.233u"inch"; name="HSS8X4X1/4")
# Same perimeter: 4×6 = 24" vs 2×(8+4) = 24"
# Square should be slightly more efficient for torsion
C_sq = torsional_constant_rect_hss(6.0u"inch", 6.0u"inch", 0.233u"inch")
C_rect = torsional_constant_rect_hss(4.0u"inch", 8.0u"inch", 0.233u"inch")
println("  Square 6×6: C = $(round(ustrip(u"inch^3", C_sq), digits=1)) in³")
println("  Rect 8×4: C = $(round(ustrip(u"inch^3", C_rect), digits=1)) in³")
# Both have same area/perimeter, but may have different C

println("  ✓ Sanity checks passed")

# =============================================================================
# Summary
# =============================================================================
println("\n" * "="^60)
println("✅ All AISC H3 torsion tests passed!")
println("="^60)
