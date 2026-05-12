# Test AISC 360-16 §E7 effective-area approach for compression members with
# slender FLANGES (built-up plate-girder regime).
#
# AISC 360-16 §E7 replaced the AISC 360-10 Qs/Qa decomposition with a unified
# effective-area approach (Pn = Fcr · Ae). For built-up plate girders or any
# I-shape with slender flanges, the new path correctly reduces the flange
# effective width per Eqs. E7-2/E7-3 with Table E7.1 Case (c) constants
# (c1 = 0.22, c2 = 1.49). The legacy AISC 360-10 §E7-5/E7-6 stress-reduction
# formula is no longer used.
#
# Run with: julia --project=. test/steel_member/test_qa_slender_flange.jl

using StructuralSizer
using StructuralSizer: _compute_Ae_E7, calculate_Fcr, get_Fe_flexural
using StructuralSizer.Asap: ksi, kip
using Unitful

println("Testing AISC 360-16 §E7 effective area for slender flanges...")

mat = A992_Steel
E_ksi  = ustrip(ksi, mat.E)
Fy_ksi = ustrip(ksi, mat.Fy)

# Compression flange limit (Table B4.1a Case 1, unstiffened): λr = 0.56√(E/Fy).
λr_f_compr = 0.56 * sqrt(E_ksi / Fy_ksi)
println("\nFlange compression limit λr = 0.56√(E/Fy) = $(round(λr_f_compr, digits=2))")

# ──────────────────────────────────────────────────────────────────────────
# Test 1: Non-slender flange (rolled W14X90) — Ae must equal Ag exactly.
# ──────────────────────────────────────────────────────────────────────────
println("\n1. Testing non-slender flange (W14X90)...")
w14x90 = first(filter(s -> occursin("W14X90", something(s.name, "")), all_W()))
println("   λ_f = $(round(w14x90.λ_f, digits=2)) (limit $(round(λr_f_compr, digits=2)))")
@assert w14x90.λ_f < λr_f_compr "W14X90 flange must be non-slender"
bd1 = _compute_Ae_E7(w14x90, mat, mat.Fy)
println("   flange_reduction = $(bd1.flange_reduction), web_reduction = $(bd1.web_reduction)")
@assert ustrip(u"inch^2", bd1.flange_reduction) ≈ 0.0  atol=1e-10
@assert ustrip(u"inch^2", bd1.web_reduction)    ≈ 0.0  atol=1e-10
@assert ustrip(u"inch^2", bd1.Ae) ≈ ustrip(u"inch^2", w14x90.A) atol=1e-10
println("   ✓ Non-slender section recovers Ae = Ag")

# ──────────────────────────────────────────────────────────────────────────
# Test 2: Built-up plate girder with SLENDER flange — exercises §E7 Case (c).
# Pick bf/(2 tf) > λr_f_compr (≈ 13.49 at Fy=50). Use bf=20, tf=0.5
# → bf/(2 tf) = 20 → ≈ 1.48 × λr_f_compr (well into slender range).
# Use a stocky web (h/tw < 1.49√(E/Fy)) so only the flange triggers.
# ──────────────────────────────────────────────────────────────────────────
println("\n2. Testing slender flange (built-up plate girder, stocky web)...")
slender_flange = ISymmSection(
    24.0u"inch",   # d   (total depth)
    20.0u"inch",   # bf  (slender flange: bf/(2·tf) = 20 > 13.5)
    1.0u"inch",    # tw  (stocky web: h/tw = 22 < 35.9)
    0.5u"inch";    # tf
    name = "Built-up slender-flange girder",
)
println("   λ_f = $(round(slender_flange.λ_f, digits=2)) > λr_f = $(round(λr_f_compr, digits=2))  → slender flange")
println("   λ_w = $(round(slender_flange.λ_w, digits=2))                              → non-slender web")
@assert slender_flange.λ_f > λr_f_compr "Section must have slender flange"
@assert slender_flange.λ_w < 1.49 * sqrt(E_ksi / Fy_ksi) "Web must be non-slender"

bd2 = _compute_Ae_E7(slender_flange, mat, mat.Fy)
@assert ustrip(u"inch^2", bd2.flange_reduction) > 0.0 "Slender flange must reduce area"
@assert ustrip(u"inch^2", bd2.web_reduction) ≈ 0.0  atol=1e-10
println("   flange_reduction = $(round(ustrip(u"inch^2", bd2.flange_reduction), digits=3)) in²")
println("   Ae/Ag = $(round(bd2.Ae / slender_flange.A, digits=4))")
@assert bd2.Ae < slender_flange.A "Slender flange must reduce Ae below Ag"
@assert bd2.Ae > 0.5 * slender_flange.A "Reduction should be moderate, not catastrophic"
println("   ✓ Slender flange triggers §E7 effective-width reduction")

# ──────────────────────────────────────────────────────────────────────────
# Test 3: Verify §E7 long-column relief — for the same slender section,
# Ae(Fcr) should be larger when Fcr < Fy than when Fcr = Fy (more effective
# width is recovered as the column gets longer and global buckling governs).
# ──────────────────────────────────────────────────────────────────────────
println("\n3. Testing §E7 long-column effective-width relief...")
# Compute Fcr at a long unbraced length (weak-axis flexural buckling).
KL_long = 30.0u"ft"
Fe_long = get_Fe_flexural(slender_flange, mat, KL_long; axis=:weak)
Fcr_long = calculate_Fcr(Fe_long, mat.Fy)
println("   At KL = $(KL_long): Fe = $(round(ustrip(ksi, Fe_long), digits=2)) ksi, " *
        "Fcr = $(round(ustrip(ksi, Fcr_long), digits=2)) ksi (Fy = $(Fy_ksi) ksi)")
@assert Fcr_long < mat.Fy "Long column must have Fcr < Fy"

bd_long = _compute_Ae_E7(slender_flange, mat, Fcr_long)
println("   Ae/Ag at Fcr=Fy:    $(round(bd2.Ae    / slender_flange.A, digits=4))")
println("   Ae/Ag at Fcr<Fy:    $(round(bd_long.Ae / slender_flange.A, digits=4))")
@assert bd_long.Ae >= bd2.Ae - 1e-10u"inch^2" "Long column should recover Ae per §E7-2"
println("   ✓ Long-column Ae ≥ Fcr=Fy bound (correct §E7-2 behavior)")

# ──────────────────────────────────────────────────────────────────────────
# Test 4: Pn smoke test — get_Pn must run end-to-end on the slender-flange
# section and return a positive force.
# ──────────────────────────────────────────────────────────────────────────
println("\n4. End-to-end Pn for slender-flange built-up section...")
Pn = get_Pn(slender_flange, mat, KL_long; axis=:weak)
println("   Pn = $(round(ustrip(kip, Pn), digits=1)) kip at KL = $(KL_long)")
@assert ustrip(kip, Pn) > 0.0 "Pn must be positive"
println("   ✓ get_Pn works on slender-flange section under §E7")

# ──────────────────────────────────────────────────────────────────────────
# Test 5: Combined slender flange + slender web (full plate-girder case) —
# both reductions must apply, and Q = Ae/Ag = Qs + Qa − 1 (NOT Qs · Qa).
# ──────────────────────────────────────────────────────────────────────────
println("\n5. Combined slender flange + slender web...")
both_slender = ISymmSection(
    36.0u"inch",   # d
    20.0u"inch",   # bf  (slender flange)
    0.375u"inch",  # tw  (slender web: h/tw = 35/0.375 = 93)
    0.5u"inch";    # tf
    name = "Plate girder — slender flange + slender web",
)
@assert both_slender.λ_f > λr_f_compr "Flange must be slender"
@assert both_slender.λ_w > 1.49 * sqrt(E_ksi / Fy_ksi) "Web must be slender"
println("   λ_f = $(round(both_slender.λ_f, digits=2)), λ_w = $(round(both_slender.λ_w, digits=2))")

bd5 = _compute_Ae_E7(both_slender, mat, mat.Fy)
@assert ustrip(u"inch^2", bd5.flange_reduction) > 0.0 "Slender flange reduction expected"
@assert ustrip(u"inch^2", bd5.web_reduction)    > 0.0 "Slender web reduction expected"
println("   flange_reduction = $(round(ustrip(u"inch^2", bd5.flange_reduction), digits=3)) in²")
println("   web_reduction    = $(round(ustrip(u"inch^2", bd5.web_reduction),    digits=3)) in²")
println("   Ae/Ag = $(round(bd5.Ae / both_slender.A, digits=4))")

# Cross-check the legacy (Qs, Qa, Q) interface:
factors5 = StructuralSizer.get_compression_factors(both_slender, mat)
println("   Legacy summary: Qs = $(round(factors5.Qs, digits=4)), " *
        "Qa = $(round(factors5.Qa, digits=4)), Q = $(round(factors5.Q, digits=4))")
@assert factors5.Q ≈ factors5.Qs + factors5.Qa - 1 atol=1e-6 "Under §E7: Q = Qs + Qa − 1"
@assert factors5.Q ≈ bd5.Ae / both_slender.A atol=1e-6 "Q must equal Ae/Ag"
@assert factors5.Q < min(factors5.Qs, factors5.Qa) "Both reductions must compound into Q"
println("   ✓ Combined slender path is consistent (Q = Qs + Qa − 1 = Ae/Ag)")

println("\n✅ All §E7 slender-flange / plate-girder tests passed!")
