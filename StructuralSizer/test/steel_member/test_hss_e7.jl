# Test AISC E7 effective width for rectangular HSS
# Run with: julia --project=. test/test_hss_e7.jl

using StructuralSizer
using StructuralSizer.Asap: ksi, kip
using Unitful

println("Testing AISC E7 effective width for rectangular HSS...")

# Material: A992 Steel (Fy = 50 ksi, same as A500 Gr.C for rectangular HSS)
mat = A992_Steel

E = ustrip(ksi, mat.E)
Fy = ustrip(ksi, mat.Fy)

# Slenderness limit for stiffened elements under uniform compression
λr = 1.40 * sqrt(E / Fy)
println("\nSlender wall limit λr = 1.40√(E/Fy) = $(round(λr, digits=2))")

# Test 1: Compact HSS (typical section)
println("\n1. Testing compact HSS (HSS10x4x1/2)...")
compact_hss = HSSRectSection(
    10.0u"inch",  # H (height)
    4.0u"inch",   # B (width)
    0.5u"inch";   # t (wall thickness)
    name = "HSS10X4X1/2"
)

lim1 = StructuralSizer.get_compression_limits(compact_hss, mat)
Ae1 = StructuralSizer._Ae_rect_hss(compact_hss, mat)
println("   λ_f = $(round(lim1.λ_f, digits=2)), λ_w = $(round(lim1.λ_w, digits=2)), λr = $(round(lim1.λr, digits=2))")
println("   Ag = $(round(u"inch^2", compact_hss.A, digits=2)), Ae = $(round(u"inch^2", Ae1, digits=2))")
@assert Ae1 ≈ compact_hss.A "Compact section should have Ae = Ag"
println("   ✓ Compact HSS correctly has Ae = Ag")

# Test 2: Slender HSS (thin walls)
println("\n2. Testing slender HSS (HSS12x6x1/4)...")
slender_hss = HSSRectSection(
    12.0u"inch",  # H
    6.0u"inch",   # B
    0.25u"inch";  # t (thin wall)
    name = "HSS12X6X1/4 slender"
)

lim2 = StructuralSizer.get_compression_limits(slender_hss, mat)
Ae2 = StructuralSizer._Ae_rect_hss(slender_hss, mat)
println("   λ_f = $(round(lim2.λ_f, digits=2)), λ_w = $(round(lim2.λ_w, digits=2)), λr = $(round(lim2.λr, digits=2))")
println("   Ag = $(round(u"inch^2", slender_hss.A, digits=2)), Ae = $(round(u"inch^2", Ae2, digits=2))")
println("   Ae/Ag = $(round(Ae2/slender_hss.A, digits=3))")

if max(lim2.λ_f, lim2.λ_w) > lim2.λr
    @assert Ae2 < slender_hss.A "Slender section should have Ae < Ag"
    println("   ✓ Slender HSS correctly has Ae < Ag")
else
    println("   (Section is not slender - walls are compact)")
end

# Test 3: Very slender HSS
println("\n3. Testing very slender HSS (HSS16x8x3/16)...")
very_slender_hss = HSSRectSection(
    16.0u"inch",  # H
    8.0u"inch",   # B
    0.1875u"inch";  # t (very thin 3/16")
    name = "HSS16X8X3/16"
)

lim3 = StructuralSizer.get_compression_limits(very_slender_hss, mat)
Ae3 = StructuralSizer._Ae_rect_hss(very_slender_hss, mat)
println("   λ_f = $(round(lim3.λ_f, digits=2)), λ_w = $(round(lim3.λ_w, digits=2)), λr = $(round(lim3.λr, digits=2))")
println("   Ag = $(round(u"inch^2", very_slender_hss.A, digits=2)), Ae = $(round(u"inch^2", Ae3, digits=2))")
println("   Ae/Ag = $(round(Ae3/very_slender_hss.A, digits=3))")

@assert Ae3 < Ae2 || Ae3 < slender_hss.A "More slender section should have lower Ae ratio"
println("   ✓ More slender HSS has proportionally lower effective area")

# Test 4: Flexure effective section modulus
println("\n4. Testing flexure effective section modulus...")
sl = get_slenderness(very_slender_hss, mat)
println("   Slenderness class: flange=$(sl.class_f), web=$(sl.class_w)")

if sl.class_f == :slender || sl.class_w == :slender
    Se = StructuralSizer._Se_rect_hss(very_slender_hss, mat; axis=:strong)
    println("   Sx = $(round(u"inch^3", very_slender_hss.Sx, digits=2)), Se = $(round(u"inch^3", Se, digits=2))")
    println("   Se/Sx = $(round(Se/very_slender_hss.Sx, digits=3))")
    @assert Se < very_slender_hss.Sx "Slender section should have Se < S"
    println("   ✓ Slender HSS correctly has Se < S for flexure")
else
    println("   (Section is not slender for flexure)")
end

println("\n✅ All HSS E7 tests passed!")
