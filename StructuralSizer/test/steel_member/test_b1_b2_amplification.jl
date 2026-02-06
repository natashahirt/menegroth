# Test AISC Appendix 8 - B1/B2 Moment Amplification
# Based on AISC Design Examples V15.1

using StructuralSizer
using Test

println("Testing AISC Appendix 8: B1/B2 Moment Amplification...")

# =============================================================================
# Test 1: Cm Factor Calculation (A-8-4)
# =============================================================================
println("\n1. Testing Cm factor calculation...")

# Double curvature (reverse curvature): M1/M2 > 0
# M1 = 50 kip-ft, M2 = 100 kip-ft → M1/M2 = 0.5
Cm_reverse = compute_Cm(50.0, 100.0)
Cm_expected_reverse = 0.6 - 0.4 * 0.5  # = 0.4
println("  Double curvature (M1/M2 = 0.5): Cm = $Cm_reverse (expected ≈ 0.4)")
@test isapprox(Cm_reverse, 0.4, atol=0.01)

# Single curvature: M1/M2 < 0 (M1 is negative)
# M1 = -80 kip-ft, M2 = 100 kip-ft → M1/M2 = -0.8
Cm_single = compute_Cm(-80.0, 100.0)
Cm_expected_single = 0.6 - 0.4 * (-0.8)  # = 0.92
println("  Single curvature (M1/M2 = -0.8): Cm = $Cm_single (expected ≈ 0.92)")
@test isapprox(Cm_single, 0.92, atol=0.01)

# Equal end moments, single curvature: M1 = -M2
Cm_equal_single = compute_Cm(-100.0, 100.0)
Cm_expected_equal = 0.6 - 0.4 * (-1.0)  # = 1.0
println("  Equal moments single curvature (M1/M2 = -1.0): Cm = $Cm_equal_single (expected = 1.0)")
@test isapprox(Cm_equal_single, 1.0, atol=0.01)

# No moment at one end
Cm_zero = compute_Cm(0.0, 100.0)
println("  M1 = 0: Cm = $Cm_zero (expected = 0.6)")
@test isapprox(Cm_zero, 0.6, atol=0.01)

# Transverse loading
Cm_transverse = compute_Cm(50.0, 100.0; transverse_loading=true)
println("  Transverse loading: Cm = $Cm_transverse (expected = 1.0)")
@test Cm_transverse == 1.0

println("  ✓ Cm factor tests passed")

# =============================================================================
# Test 2: Pe1 Calculation (A-8-5)
# =============================================================================
println("\n2. Testing Pe1 calculation...")

# Example: W14x132, Lc = 14 ft = 168 in
# E = 29000 ksi, Ix = 1530 in^4
E = 29000.0  # ksi
Ix = 1530.0  # in^4
Lc1 = 168.0  # in (14 ft)

Pe1 = compute_Pe1(E, Ix, Lc1)
Pe1_expected = π^2 * E * Ix / Lc1^2  # = 15,511 kip
println("  Pe1 = $(round(Pe1, digits=0)) kip (expected ≈ 15,511 kip)")
@test isapprox(Pe1, 15511.0, rtol=0.01)

println("  ✓ Pe1 tests passed")

# =============================================================================
# Test 3: B1 Factor Calculation (A-8-3)
# =============================================================================
println("\n3. Testing B1 factor calculation...")

# Case 1: Low axial load, reverse curvature
Pr1 = 500.0  # kip
Cm1 = 0.4
Pe1_1 = 15511.0  # kip
B1_1 = compute_B1(Pr1, Pe1_1, Cm1; α=1.0)
# B1 = 0.4 / (1 - 500/15511) = 0.4 / 0.968 = 0.413 → max(0.413, 1.0) = 1.0
println("  Low axial, reverse curvature: B1 = $(round(B1_1, digits=3)) (expected = 1.0)")
@test B1_1 == 1.0

# Case 2: Higher axial load, single curvature
Pr2 = 3000.0  # kip
Cm2 = 1.0
B1_2 = compute_B1(Pr2, Pe1_1, Cm2; α=1.0)
# B1 = 1.0 / (1 - 3000/15511) = 1.0 / 0.807 = 1.24
println("  Higher axial, single curvature: B1 = $(round(B1_2, digits=3)) (expected ≈ 1.24)")
@test isapprox(B1_2, 1.24, rtol=0.02)

# Case 3: Tension (no amplification)
Pr3 = -100.0  # kip (tension)
B1_3 = compute_B1(Pr3, Pe1_1, Cm1; α=1.0)
println("  Tension: B1 = $B1_3 (expected = 1.0)")
@test B1_3 == 1.0

# Case 4: Near buckling (should return Inf)
Pr4 = 16000.0  # kip (> Pe1)
B1_4 = compute_B1(Pr4, Pe1_1, 1.0; α=1.0)
println("  Near/at buckling: B1 = $B1_4 (expected = Inf)")
@test B1_4 == Inf

# Case 5: ASD (α = 1.6)
Pr5 = 3000.0 / 1.5  # Equivalent ASD load
B1_5 = compute_B1(Pr5, Pe1_1, Cm2; α=1.6)
# B1 = 1.0 / (1 - 1.6*2000/15511) = 1.0 / (1 - 0.206) = 1.26
println("  ASD (α=1.6): B1 = $(round(B1_5, digits=3))")
@test B1_5 >= 1.0

println("  ✓ B1 factor tests passed")

# =============================================================================
# Test 4: B2 Factor Calculation (A-8-6, A-8-7, A-8-8)
# =============================================================================
println("\n4. Testing B2 factor calculation...")

# Example story data:
# Pstory = 2000 kip (total vertical load)
# H = 50 kip (story shear)
# L = 144 in (12 ft story height)
# ΔH = 0.36 in (first-order drift)
# Moment frame (Pmf = 2000 kip)

Pstory = 2000.0  # kip
H = 50.0         # kip
L = 144.0        # in
ΔH = 0.36        # in
Pmf = 2000.0     # kip (all columns in moment frame)

# RM calculation
RM = compute_RM(Pmf, Pstory)
RM_expected = 1.0 - 0.15 * (2000/2000)  # = 0.85
println("  RM (moment frame): $RM (expected = 0.85)")
@test isapprox(RM, 0.85, atol=0.01)

# RM for braced frame (Pmf = 0)
RM_braced = compute_RM(0.0, Pstory)
println("  RM (braced frame): $RM_braced (expected = 1.0)")
@test RM_braced == 1.0

# Pe_story calculation
Pe_story = compute_Pe_story(H, L, ΔH, RM)
Pe_story_expected = 0.85 * 50 * 144 / 0.36  # = 17,000 kip
println("  Pe_story = $(round(Pe_story, digits=0)) kip (expected = 17,000 kip)")
@test isapprox(Pe_story, 17000.0, rtol=0.01)

# B2 calculation
B2 = compute_B2(Pstory, Pe_story; α=1.0)
B2_expected = 1.0 / (1 - 2000/17000)  # = 1.0 / 0.882 = 1.13
println("  B2 = $(round(B2, digits=3)) (expected ≈ 1.13)")
@test isapprox(B2, 1.13, rtol=0.02)

# Convenience function
B2_conv = compute_B2(Pstory, H, L, ΔH; Pmf=Pmf, α=1.0)
println("  B2 (convenience): $(round(B2_conv, digits=3))")
@test isapprox(B2_conv, B2, atol=0.001)

# Zero drift (braced frame → B2 = 1.0)
B2_zero = compute_B2(Pstory, Inf; α=1.0)
println("  B2 (no drift): $B2_zero (expected = 1.0)")
@test B2_zero == 1.0

println("  ✓ B2 factor tests passed")

# =============================================================================
# Test 5: Second-Order Moment and Axial Amplification (A-8-1, A-8-2)
# =============================================================================
println("\n5. Testing moment and axial amplification...")

# Given forces
Mnt = 200.0  # kip-ft (no-translation moment)
Mlt = 100.0  # kip-ft (lateral translation moment)
Pnt = 500.0  # kip (no-translation axial)
Plt = 50.0   # kip (lateral translation axial)

B1_test = 1.05
B2_test = 1.15

# Second-order moment: Mr = B1·Mnt + B2·Mlt
Mr = amplify_moments(Mnt, Mlt, B1_test, B2_test)
Mr_expected = 1.05 * 200 + 1.15 * 100  # = 210 + 115 = 325 kip-ft
println("  Mr = $Mr kip-ft (expected = 325 kip-ft)")
@test isapprox(Mr, 325.0, atol=0.1)

# Second-order axial: Pr = Pnt + B2·Plt
Pr = amplify_axial(Pnt, Plt, B2_test)
Pr_expected = 500 + 1.15 * 50  # = 500 + 57.5 = 557.5 kip
println("  Pr = $Pr kip (expected = 557.5 kip)")
@test isapprox(Pr, 557.5, atol=0.1)

# Braced frame (Mlt = 0, B2 = 1.0)
Mr_braced = amplify_moments(Mnt, 0.0, B1_test, 1.0)
println("  Mr (braced): $Mr_braced kip-ft (expected = $(1.05 * 200) kip-ft)")
@test isapprox(Mr_braced, 1.05 * 200, atol=0.01)

println("  ✓ Amplification tests passed")

# =============================================================================
# Test 6: Complete B1 calculation from basic parameters
# =============================================================================
println("\n6. Testing complete B1 calculation...")

# W14x132 column, 14 ft unbraced, reverse curvature
E_test = 29000.0  # ksi
I_test = 1530.0   # in^4
L_test = 168.0    # in
M1_test = 50.0    # kip-ft
M2_test = 100.0   # kip-ft
Pr_test = 500.0   # kip

B1_complete = compute_B1(Pr_test, E_test, I_test, L_test, M1_test, M2_test; 
                         K=1.0, α=1.0, transverse_loading=false)
println("  B1 (complete): $(round(B1_complete, digits=3))")
@test B1_complete >= 1.0

println("  ✓ Complete B1 calculation test passed")

# =============================================================================
# Test 7: Integration with geometry flag
# =============================================================================
println("\n7. Testing integration with SteelMemberGeometry...")

# Create geometry for braced and unbraced cases
geo_braced = SteelMemberGeometry(14.0; Lb=14.0, Cb=1.0, Kx=1.0, Ky=1.0, braced=true)
geo_unbraced = SteelMemberGeometry(14.0; Lb=14.0, Cb=1.0, Kx=1.0, Ky=1.0, braced=false)

println("  Braced geometry: braced = $(geo_braced.braced)")
@test geo_braced.braced == true

println("  Unbraced geometry: braced = $(geo_unbraced.braced)")
@test geo_unbraced.braced == false

# For braced frames: only B1 applies (Mlt = 0)
# For unbraced frames: both B1 and B2 apply

println("  ✓ Geometry integration test passed")

# =============================================================================
# Summary
# =============================================================================
println("\n" * "="^60)
println("✅ All AISC B1/B2 moment amplification tests passed!")
println("="^60)
