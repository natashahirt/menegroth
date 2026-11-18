# Regression tests for flat-plate safety defects found in audit:
#   1. λ missing from the modulus of rupture (ACI 318-11 Eq. 9-10, aci-318-11 p.132)
#   2. invented midspan ρ′ in the long-term multiplier (§9.5.2.5, p.132)
#   3. unknown deflection limits silently fell back to a default (Table 9.5(b), p.133)
#   4. slab loads read from the first cell only
#   5. column stiffness transposed in the §13.6.9.2 above/below split (p.258)
#   6. fallback column shear was half the interior tributary
#   7. crossing-beam strip ratio used Ie_frame, cancelling cracking (PCA Eq. 11)
# Expected values are hand calculations written out in the comments.

using Test
using Unitful
using Asap
using StructuralSizer

const SS = StructuralSizer

@testset "Flat-plate safety regressions" begin

    @testset "modulus of rupture carries λ (Eq. 9-10)" begin
        # 7.5·√4000 = 7.5 × 63.245553 = 474.3417 psi; ×0.75 = 355.7562 psi.
        fc = 4000u"psi"
        @test ustrip(u"psi", SS.fr(fc)) ≈ 474.3417 rtol = 1e-6
        @test ustrip(u"psi", SS.fr(fc; λ = 0.75)) ≈ 355.7562 rtol = 1e-6
        @test SS.fr(fc; λ = 0.75) ≈ 0.75 * SS.fr(fc)
        # A material carries its own λ: all-lightweight LWC_4000_AL has λ = 0.75.
        @test SS.fr(SS.LWC_4000_AL) ≈ 0.75 * SS.fr(fc)
        @test_throws ArgumentError SS.fr(fc; λ = 0.0)
        @test_throws ArgumentError SS.fr(fc; λ = 1.2)
    end

    @testset "Ie for lightweight concrete (Eq. 9-8, 9-9)" begin
        # b = 12 in, h = 8 in: Ig = 12·8³/12 = 512 in⁴, yt = 4 in.
        # λ = 0.75: Mcr = 355.7562 × 512 / 4 = 45 536.8 lb·in = 3.794733 kip·ft.
        # Ma = 6 kip·ft: Mcr/Ma = 0.6324555 = √0.4, cubed = 0.2529822.
        # Icr = 100 in⁴: Ie = 0.2529822·512 + 0.7470178·100 = 204.2287 in⁴.
        Ig = 512.0u"inch^4"
        Icr = 100.0u"inch^4"
        h = 8.0u"inch"
        Mcr = SS.cracking_moment(SS.fr(4000u"psi"; λ = 0.75), Ig, h)
        @test ustrip(kip * u"ft", Mcr) ≈ 3.794733 rtol = 1e-5
        Ie = SS.effective_moment_of_inertia(Mcr, 6.0kip * u"ft", Ig, Icr)
        @test ustrip(u"inch^4", Ie) ≈ 204.2287 rtol = 1e-5
        # Normal weight at the same Ma is stiffer (Mcr/Ma = 0.84327, Ie = 347.06 in⁴).
        Ie_nw = SS.effective_moment_of_inertia(
            SS.cracking_moment(SS.fr(4000u"psi"), Ig, h), 6.0kip * u"ft", Ig, Icr)
        @test ustrip(u"inch^4", Ie_nw) ≈ 347.06 rtol = 1e-4
    end

    # Interior 20 ft × 20 ft panel, 8 in plate, crossing-beam path (no FEA field).
    defl_inputs = (
        mr = (M_pos = 50.0kip * u"ft", M_neg_ext = 80.0kip * u"ft",
              M_neg_int = 80.0kip * u"ft",
              qu = 260.0psf, qD = 150.0psf, qL = 50.0psf),
        h = 8.0u"inch", d = 6.75u"inch", fc = 4000u"psi", fy = 60u"ksi",
        Es = 29000u"ksi", Ecs = SS.Ec(4000u"psi", 150.0),
        spans = (primary = 20.0u"ft", secondary = 20.0u"ft"),
        γ = 150.0pcf, columns = [(position = :interior,)],
    )
    two_way(; kw...) = SS.check_two_way_deflection(
        defl_inputs.mr, defl_inputs.h, defl_inputs.d, defl_inputs.fc, defl_inputs.fy,
        defl_inputs.Es, defl_inputs.Ecs, defl_inputs.spans, defl_inputs.γ,
        defl_inputs.columns; kw...)

    @testset "two-way deflection threads λ into Mcr and Ie" begin
        nw = two_way(λ = 1.0)
        lw = two_way(λ = 0.75)
        # Mcr = fr·Ig/yt is linear in fr, so the ratio is exactly λ.
        @test lw.Mcr ≈ 0.75 * nw.Mcr
        # Normal weight stays uncracked: Ig_frame = 240·8³/12 = 10 240 in⁴, and
        # Ma,sup(D+L) = 80·200/260 = 61.5 kip·ft < (2/3)·Mcr = 67.5 kip·ft.
        # Ec = 33·150^1.5·√4000 = 3 834 254 psi; w = 200 psf × 20 ft = 333.33 lb/in.
        # Δframe = w·l⁴/(384·Ec·I) = 333.33 × 240⁴ / (384 × 3 834 254 × 10 240) = 0.073354 in.
        # Ig_cs = Ig_ms = 120·8³/12 = 5120 in⁴, ratio Ig_frame/Ig_strip = 2 (PCA Eq. 11).
        # Δc = 0.675 × 0.073354 × 2 × 1.10 = 0.108931; Δm = 0.325 × 0.073354 × 2 × 1.10 = 0.052448.
        # Panel = 0.161379 in.
        @test ustrip(u"inch^4", nw.Ie_DL) ≈ 10240 rtol = 1e-9
        @test ustrip(u"inch", nw.Δ_panel_DL) ≈ 0.161379 rtol = 1e-4
        # Lightweight cracks at the support ((2/3)·0.75·Mcr = 50.6 kip·ft < 61.5), so
        # Ie_DL < Ig and the crossing-beam deflection grows as Ig / Ie_DL. Before the
        # PCA Eq. 11 fix, Ie cancelled and both panels were 0.161379 in.
        @test lw.Ie_DL < nw.Ie_DL
        @test lw.Δ_panel_DL / nw.Δ_panel_DL ≈ nw.Ie_DL / lw.Ie_DL rtol = 1e-9
        # λ must be given explicitly.
        @test_throws UndefKeywordError two_way()
    end

    @testset "long-term multiplier with ρ′ = 0 at midspan (§9.5.2.5)" begin
        # ξ = 2.0 for 5 years or more; ρ′ = 0 → λΔ = 2.0 / (1 + 0) = 2.0.
        @test SS.FLAT_PLATE_MIDSPAN_RHO_PRIME == 0.0
        @test SS.long_term_deflection_factor(2.0, SS.FLAT_PLATE_MIDSPAN_RHO_PRIME) == 2.0
        @test two_way(λ = 1.0).λ_Δ == 2.0
        @test !isdefined(SS, :rho_prime_estimate)
    end

    @testset "unknown deflection limits throw" begin
        @test_throws ArgumentError SS.deflection_limit(20.0u"ft", :L_100)
        @test_throws ArgumentError two_way(λ = 1.0, limit_type = :L_999)
        @test_throws ArgumentError SS.FlatPlateOptions(deflection_limit = :L_100)
        # The accepted values still map to Table 9.5(b): ℓ/360, ℓ/240, ℓ/480.
        @test two_way(λ = 1.0, limit_type = :L_360).Δ_limit ≈ 20.0u"ft" / 360
        @test two_way(λ = 1.0, limit_type = :L_240).Δ_limit ≈ 20.0u"ft" / 240
        @test two_way(λ = 1.0, limit_type = :L_480).Δ_limit ≈ 20.0u"ft" / 480
        @test SS.FlatPlateOptions(deflection_limit = :L_480).deflection_limit == :L_480
    end

    @testset "slab loads use the governing cell" begin
        # Cell 1: SDL 20 psf, L 50 psf. Cell 2: SDL 15 psf, L 100 psf.
        # Governing: SDL 20, L 100. 8 in at 150 pcf = 100 psf self-weight.
        # qD = 120 psf; qu = max(1.2·120 + 1.6·100, 1.4·120) = max(304, 168) = 304 psf.
        struc = (cells = [(sdl = 20.0psf, live_load = 50.0psf),
                          (sdl = 15.0psf, live_load = 100.0psf)],)
        slab = (cell_indices = [1, 2],
                spans = (primary = 20.0u"ft", secondary = 20.0u"ft", axis = (1.0, 0.0)))
        sw, qD, qL, qu = SS._flat_plate_uniform_pressures(struc, slab, 8.0u"inch", 150.0pcf)
        @test ustrip(psf, sw) ≈ 100.0 rtol = 1e-6
        @test ustrip(psf, qD) ≈ 120.0 rtol = 1e-6
        @test ustrip(psf, qL) ≈ 100.0 rtol = 1e-6
        @test ustrip(psf, qu) ≈ 304.0 rtol = 1e-6
        # Order of cells does not matter.
        rev = (cells = reverse(struc.cells),)
        @test SS._flat_plate_uniform_pressures(rev, slab, 8.0u"inch", 150.0pcf)[3] ≈ qL
        # Eq. (13-7) recovers the trial self-weight from qD with the same SDL.
        @test ustrip(psf, SS._eq137_sw_trial(struc, slab, qD)) ≈ 100.0 rtol = 1e-6

        # Primary setup: 16 in square columns, ln = 20 − 16/12 = 18.6667 ft.
        # M0 = qu·l2·ln²/8 = 304 × 20 × 18.6667² / 8 = 264 817.8 lb·ft.
        cols = [(c1 = 16.0u"inch", c2 = 16.0u"inch", position = :interior)]
        setup = SS._moment_analysis_setup(struc, slab, cols, 8.0u"inch", 150.0pcf)
        @test ustrip(psf, setup.qL) ≈ 100.0 rtol = 1e-6
        @test ustrip(u"ft", setup.ln) ≈ 18.6667 rtol = 1e-4
        @test ustrip(kip * u"ft", setup.M0) ≈ 264.818 rtol = 1e-4
        sec = SS._secondary_moment_analysis_setup(struc, slab, cols, 8.0u"inch", 150.0pcf)
        @test ustrip(psf, sec.qu) ≈ 304.0 rtol = 1e-6
    end

    @testset "column stiffness split per bending direction (§13.6.9.2)" begin
        # Below 16 × 24 in (c1 = 16 along X), above 16 × 16 in, equal heights.
        # Span along c1 (X): I_below = 24·16³/12 = 8192, I_above = 16·16³/12 = 5461.33
        #   → 8192 / 13653.33 = 0.600.
        # Span along c2 (Y): I_below = 16·24³/12 = 18432 → 18432 / 23893.33 = 0.771429.
        L = 12.0u"ft"
        above = (c1 = 16.0u"inch", c2 = 16.0u"inch", base = (L = L,), concrete = nothing)
        below = (c1 = 16.0u"inch", c2 = 24.0u"inch", base = (L = L,), concrete = nothing,
                 column_above = above)
        opts = (material = SS.NWC_4000,)
        fx = SS.column_moment_distribution_factors(nothing, [below], opts; span_axis = (1.0, 0.0))
        @test fx.primary[1] ≈ 0.600 rtol = 1e-9
        @test fx.secondary[1] ≈ 0.771429 rtol = 1e-6
        fy = SS.column_moment_distribution_factors(nothing, [below], opts; span_axis = (0.0, 1.0))
        @test fy.primary[1] ≈ 0.771429 rtol = 1e-6
        @test fy.secondary[1] ≈ 0.600 rtol = 1e-9
        # The same column turned 90°: c1 now lies along Y.
        rot = merge(below, (θ = π / 2, column_above = merge(above, (θ = π / 2,))))
        fr90 = SS.column_moment_distribution_factors(nothing, [rot], opts; span_axis = (1.0, 0.0))
        @test fr90.primary[1] ≈ 0.771429 rtol = 1e-6
        # No column above: the column below takes the whole moment in both directions.
        top = merge(below, (column_above = nothing,))
        ft = SS.column_moment_distribution_factors(nothing, [top], opts; span_axis = (1.0, 0.0))
        @test ft.primary[1] == 1.0 && ft.secondary[1] == 1.0
        # The span axis is required.
        @test_throws UndefKeywordError SS.column_moment_distribution_factors(nothing, [below], opts)
    end

    @testset "fallback column shear uses the full interior tributary" begin
        # qu = 200 psf, l2 = 20 ft, ln = 18 ft. Interior: 20 × 18 = 360 ft² → 72 kip.
        # Edge: half → 36 kip. Convex corner: quarter → 18 kip. Re-entrant: 3/4 → 54 kip.
        qu, l2, ln = 200.0psf, 20.0u"ft", 18.0u"ft"
        V(col) = ustrip(kip, SS._compute_column_shear(nothing, col, qu, l2, ln))
        @test V((position = :interior,)) ≈ 72.0 rtol = 1e-9
        @test V((position = :edge,)) ≈ 36.0 rtol = 1e-9
        @test V((position = :corner, corner_kind = :convex)) ≈ 18.0 rtol = 1e-9
        @test V((position = :corner, corner_kind = :reentrant)) ≈ 54.0 rtol = 1e-9
        # A Voronoi area, when present, still governs: 30 m² × 200 psf.
        col = (position = :interior, tributary_cell_areas = Dict(1 => 30.0))
        @test SS._compute_column_shear(nothing, col, qu, l2, ln) ≈ uconvert(kip, qu * 30.0u"m^2")
    end
end
