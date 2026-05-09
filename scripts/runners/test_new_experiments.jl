#!/usr/bin/env julia
#
# Verify the new experiment capabilities:
#  1. fc_in on punching (stronger concrete should improve ratio)
#  2. Beam experiment (steel beam W-shape via AISC checker)
#  3. Punching reinforcement (studs/stirrups should reduce ratio)

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSizer"))

using StructuralSizer
using Unitful
using Unitful: @u_str
using Asap
using Test

# ─────────────────────────────────────────────────────────────────────────────
# 1. fc_in: stronger concrete improves punching ratio
# ─────────────────────────────────────────────────────────────────────────────

@testset "Punching: fc_in — 4000 psi → 5000 psi" begin
    h = 10.0u"inch"
    d = h - 0.75u"inch" - 0.5u"inch"
    orig_c1 = 20.0u"inch"
    orig_c2 = 20.0u"inch"
    At = 25.0u"ft" * 25.0u"ft"
    qu = 300.0u"psf"
    Ac = (orig_c1 + d) * (orig_c2 + d)
    Vu = qu * (At - Ac)
    Mub = 30.0u"kip*ft"
    col = (c1 = orig_c1, c2 = orig_c2, position = :interior, shape = :rectangular)

    fc_4000 = 4000.0u"psi"
    fc_5000 = 5000.0u"psi"

    r4 = check_punching_for_column(col, Vu, Mub, d, h, fc_4000; col_idx = 1)
    r5 = check_punching_for_column(col, Vu, Mub, d, h, fc_5000; col_idx = 1)

    println("Interior 20\" @ 4000 psi: ratio = $(round(r4.ratio; digits=3))")
    println("Interior 20\" @ 5000 psi: ratio = $(round(r5.ratio; digits=3))")

    @test r5.ratio < r4.ratio
    println("✓ Higher f'c improves punching ratio.\n")
end

# ─────────────────────────────────────────────────────────────────────────────
# 2. Beam experiment: W-shape via AISC checker
# ─────────────────────────────────────────────────────────────────────────────

@testset "Beam experiment: W14X22 vs W16X40" begin
    mat = A992_Steel
    L = 20.0u"ft"
    Lb = 5.0u"ft"        # braced at quarter points
    Mu = 60.0u"kip*ft"
    Vu = 15.0u"kip"

    geom = SteelMemberGeometry(L; Lb=Lb, Cb=1.0, Kx=1.0, Ky=1.0)
    dem = MemberDemand(1; Mux=to_newton_meters(Mu), Vu_strong=to_newtons(Vu))

    sec_small = W("W14X22")
    checker = AISCChecker()
    cat_s = [sec_small]
    cache_s = create_cache(checker, 1)
    precompute_capacities!(checker, cache_s, cat_s, mat, MinWeight())
    expl_s = explain_feasibility(checker, cache_s, 1, sec_small, mat, dem, geom)

    sec_large = W("W16X40")
    cat_l = [sec_large]
    cache_l = create_cache(checker, 1)
    precompute_capacities!(checker, cache_l, cat_l, mat, MinWeight())
    expl_l = explain_feasibility(checker, cache_l, 1, sec_large, mat, dem, geom)

    println("W14X22: ratio = $(round(expl_s.governing_ratio; digits=3)), " *
            "governing = $(expl_s.governing_check), passed = $(expl_s.passed)")
    println("W16X40: ratio = $(round(expl_l.governing_ratio; digits=3)), " *
            "governing = $(expl_l.governing_check), passed = $(expl_l.passed)")

    @test expl_l.governing_ratio < expl_s.governing_ratio
    @test expl_l.passed
    println("✓ Heavier beam section improves ratio.\n")
end

# ─────────────────────────────────────────────────────────────────────────────
# 3. Punching reinforcement: studs reduce ratio on a failing column
# ─────────────────────────────────────────────────────────────────────────────

@testset "Punching reinforcement: studs on failing interior column" begin
    fc = 4000.0u"psi"
    h = 10.0u"inch"
    d = h - 0.75u"inch" - 0.5u"inch"
    orig_c1 = 16.0u"inch"
    orig_c2 = 16.0u"inch"
    At = 25.0u"ft" * 25.0u"ft"
    qu = 300.0u"psf"
    Ac = (orig_c1 + d) * (orig_c2 + d)
    Vu = qu * (At - Ac)
    Mub = 30.0u"kip*ft"
    position = :interior

    col = (c1 = orig_c1, c2 = orig_c2, position = position, shape = :rectangular)
    check = check_punching_for_column(col, Vu, Mub, d, h, fc; col_idx = 1)
    vu = check.vu

    println("Unreinforced: ratio = $(round(check.ratio; digits=3)), ok = $(check.ok)")

    β = max(ustrip(u"inch", orig_c1), ustrip(u"inch", orig_c2)) /
        max(min(ustrip(u"inch", orig_c1), ustrip(u"inch", orig_c2)), 1.0)
    αs = punching_αs(position)
    b0 = check.b0

    stud_design = design_shear_studs(
        vu, fc, β, αs, b0, d, position, 51_000.0u"psi", 0.5u"inch";
        c1 = orig_c1, c2 = orig_c2,
    )

    stud_check = check_punching_with_studs(vu, stud_design)

    println("With studs:   ratio = $(round(stud_check.ratio; digits=3)), ok = $(stud_check.ok)")
    println("  n_rails = $(stud_design.n_rails), n_per_rail = $(stud_design.n_studs_per_rail)")
    println("  s0 = $(round(ustrip(u"inch", stud_design.s0); digits=2))\", " *
            "s = $(round(ustrip(u"inch", stud_design.s); digits=2))\"")

    if check.ratio > 1.0
        @test stud_check.ratio < check.ratio
        println("✓ Studs improve ratio on failing column.\n")
    else
        println("Column already passing — studs test is informational only.\n")
    end
end

@testset "Punching reinforcement: stirrups on interior column" begin
    fc = 4000.0u"psi"
    h = 10.0u"inch"
    d = h - 0.75u"inch" - 0.5u"inch"
    orig_c1 = 16.0u"inch"
    orig_c2 = 16.0u"inch"
    At = 25.0u"ft" * 25.0u"ft"
    qu = 320.0u"psf"
    Ac = (orig_c1 + d) * (orig_c2 + d)
    Vu = qu * (At - Ac)
    Mub = 30.0u"kip*ft"
    position = :interior

    col = (c1 = orig_c1, c2 = orig_c2, position = position, shape = :rectangular)
    check = check_punching_for_column(col, Vu, Mub, d, h, fc; col_idx = 1)
    vu = check.vu

    β = max(ustrip(u"inch", orig_c1), ustrip(u"inch", orig_c2)) /
        max(min(ustrip(u"inch", orig_c1), ustrip(u"inch", orig_c2)), 1.0)
    αs = punching_αs(position)
    b0 = check.b0

    stirrup_design = design_closed_stirrups(
        vu, fc, β, αs, b0, d, position, 60_000.0u"psi", 4;
        c1 = orig_c1, c2 = orig_c2,
    )

    stirrup_check = check_punching_with_stirrups(vu, stirrup_design)

    println("Unreinforced: ratio = $(round(check.ratio; digits=3))")
    println("With stirrups: ratio = $(round(stirrup_check.ratio; digits=3)), ok = $(stirrup_check.ok)")
    println("  bar = #$(stirrup_design.bar_size), n_legs = $(stirrup_design.n_legs), " *
            "n_lines = $(stirrup_design.n_lines)")

    if stirrup_design.required
        @test stirrup_check.ratio < check.ratio
        println("✓ Stirrups improve ratio.\n")
    else
        println("Stirrups not required for this scenario.\n")
    end
end
