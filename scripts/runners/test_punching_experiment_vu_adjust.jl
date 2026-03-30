#!/usr/bin/env julia
#
# Verify that increasing column size (29" → 32") with Vu adjustment for
# critical-area change produces a sensible (improved) punching ratio,
# fixing the prior bug where frozen Vu caused paradoxical worsening.

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSizer"))

using StructuralSizer
using Unitful
using Unitful: @u_str
using Asap  # registers psf, pcf, etc.
using Test

@testset "Punching experiment Vu adjustment — edge column 29→32 in" begin
    fc = 4000.0u"psi"
    cover = 0.75u"inch"
    bar_d = 0.5u"inch"
    h = 10.0u"inch"
    d = h - cover - bar_d

    # Typical edge column scenario
    orig_c1 = 29.0u"inch"
    orig_c2 = 29.0u"inch"
    position = :edge

    # Tributary area from a typical 25 ft × 25 ft bay (edge takes half)
    At = 25.0u"ft" * 12.5u"ft"

    # Critical area for original column (edge: (c1 + d/2)(c2 + d))
    Ac_orig = (orig_c1 + d / 2) * (orig_c2 + d)

    # Assumed factored load intensity
    qu = 300.0u"psf"
    Vu_orig = qu * (At - Ac_orig)

    # Unbalanced moment (moderate)
    Mub = 50.0u"kip*ft"

    col_orig = (c1 = orig_c1, c2 = orig_c2, position = position, shape = :rectangular)
    result_orig = check_punching_for_column(col_orig, Vu_orig, Mub, d, h, fc; col_idx = 1)

    # ── New column: 32" × 32" ──
    new_c1 = 32.0u"inch"
    new_c2 = 32.0u"inch"
    Ac_new = (new_c1 + d / 2) * (new_c2 + d)

    # Vu adjusted for larger critical area (correct approach)
    Vu_adjusted = qu * (At - Ac_new)
    @test ustrip(u"kip", Vu_adjusted) < ustrip(u"kip", Vu_orig)  # demand must decrease

    col_new = (c1 = new_c1, c2 = new_c2, position = position, shape = :rectangular)
    result_adjusted = check_punching_for_column(col_new, Vu_adjusted, Mub, d, h, fc; col_idx = 1)

    # Vu frozen (old broken approach) — may give paradoxical result
    result_frozen = check_punching_for_column(col_new, Vu_orig, Mub, d, h, fc; col_idx = 1)

    println("Original  (29\"): ratio = $(round(result_orig.ratio; digits=3)), " *
            "vu = $(round(ustrip(u"psi", result_orig.vu); digits=1)) psi, " *
            "φvc = $(round(ustrip(u"psi", result_orig.φvc); digits=1)) psi")
    println("Adjusted  (32\"): ratio = $(round(result_adjusted.ratio; digits=3)), " *
            "vu = $(round(ustrip(u"psi", result_adjusted.vu); digits=1)) psi, " *
            "φvc = $(round(ustrip(u"psi", result_adjusted.φvc); digits=1)) psi, " *
            "Vu = $(round(ustrip(u"kip", Vu_adjusted); digits=2)) kip")
    println("Frozen Vu (32\"): ratio = $(round(result_frozen.ratio; digits=3)), " *
            "vu = $(round(ustrip(u"psi", result_frozen.vu); digits=1)) psi  [OLD BUG PATH]")
    println()
    println("Vu orig  = $(round(ustrip(u"kip", Vu_orig); digits=2)) kip")
    println("Vu adj   = $(round(ustrip(u"kip", Vu_adjusted); digits=2)) kip")
    println("ΔVu      = $(round(ustrip(u"kip", Vu_orig - Vu_adjusted); digits=2)) kip reduction")

    @test result_adjusted.ratio < result_orig.ratio  # larger column must help with adjusted Vu
    @test result_adjusted.ratio < result_frozen.ratio  # adjusted path must be better than frozen

    println("\n✓ Larger column improves ratio when Vu is properly adjusted.")
end

@testset "Punching experiment Vu adjustment — interior column" begin
    fc = 4000.0u"psi"
    h = 10.0u"inch"
    d = h - 0.75u"inch" - 0.5u"inch"
    At = 25.0u"ft" * 25.0u"ft"
    qu = 300.0u"psf"

    orig_c1 = 20.0u"inch"
    orig_c2 = 20.0u"inch"
    Ac_orig = (orig_c1 + d) * (orig_c2 + d)
    Vu_orig = qu * (At - Ac_orig)
    Mub = 30.0u"kip*ft"

    col_orig = (c1 = orig_c1, c2 = orig_c2, position = :interior, shape = :rectangular)
    r_orig = check_punching_for_column(col_orig, Vu_orig, Mub, d, h, fc; col_idx = 1)

    new_c1 = 24.0u"inch"
    new_c2 = 24.0u"inch"
    Ac_new = (new_c1 + d) * (new_c2 + d)
    Vu_adj = qu * (At - Ac_new)

    col_new = (c1 = new_c1, c2 = new_c2, position = :interior, shape = :rectangular)
    r_adj = check_punching_for_column(col_new, Vu_adj, Mub, d, h, fc; col_idx = 1)

    println("\nInterior 20\"→24\": ratio $(round(r_orig.ratio; digits=3)) → $(round(r_adj.ratio; digits=3))")
    @test r_adj.ratio < r_orig.ratio

    println("✓ Interior column: larger size improves ratio with adjusted Vu.")
end

@testset "Punching experiment Vu adjustment — corner column" begin
    fc = 4000.0u"psi"
    h = 10.0u"inch"
    d = h - 0.75u"inch" - 0.5u"inch"
    At = 12.5u"ft" * 12.5u"ft"
    qu = 300.0u"psf"

    orig_c1 = 20.0u"inch"
    orig_c2 = 20.0u"inch"
    # Corner: (c1 + d/2)(c2 + d/2)
    Ac_orig = (orig_c1 + d / 2) * (orig_c2 + d / 2)
    Vu_orig = qu * (At - Ac_orig)
    Mub = 40.0u"kip*ft"

    col_orig = (c1 = orig_c1, c2 = orig_c2, position = :corner, shape = :rectangular)
    r_orig = check_punching_for_column(col_orig, Vu_orig, Mub, d, h, fc; col_idx = 1)

    new_c1 = 24.0u"inch"
    new_c2 = 24.0u"inch"
    Ac_new = (new_c1 + d / 2) * (new_c2 + d / 2)
    Vu_adj = qu * (At - Ac_new)

    col_new = (c1 = new_c1, c2 = new_c2, position = :corner, shape = :rectangular)
    r_adj = check_punching_for_column(col_new, Vu_adj, Mub, d, h, fc; col_idx = 1)

    println("\nCorner 20\"→24\": ratio $(round(r_orig.ratio; digits=3)) → $(round(r_adj.ratio; digits=3))")
    @test r_adj.ratio < r_orig.ratio

    println("✓ Corner column: larger size improves ratio with adjusted Vu.")
end
