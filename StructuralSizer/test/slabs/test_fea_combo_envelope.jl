# =============================================================================
# FEA design envelope — per-face moments over ASCE 7 combinations
# =============================================================================
#
# `_combine_element_moments!` still writes the max-|Mxx| representative
# tensor (visualization / fallback).  Design extractors must envelope the
# *transformed* face moments over every ASCE 7-16 §2.3.1 combo
# (corpus: asce-7-16, page 62: 1.4D and 1.2D+1.6L, gravity-only) so an
# element whose Myy (or opposite face) governs under a different combo
# is not underdesigned.
#
# Single-combo identity: when D/L split data are absent, extractors see
# exactly `ed.Mxx/Myy/Mxy`.
# =============================================================================

using Test
using StructuralSizer

const SS = StructuralSizer

function _synthetic_element(; Mxx=0.0, Myy=0.0, Mxy=0.0)
    return SS.FEAElementData(
        0.0, 0.0, 1.0,
        Mxx, Myy, Mxy,
        0.0, 0.0,
        (1.0, 0.0),
        (0.0, 1.0),
    )
end

@testset "FEA combo envelope (Myy governs a different combo)" begin
    cache = SS.FEAModelCache()
    push!(cache.element_data, _synthetic_element())
    # Asap hogging-positive.  Dead is y-dominant; live is x-dominant.
    #   1.2D+1.6L: Mxx = 172, Myy = 136   ← max |Mxx|
    #   1.4D:      Mxx =  14, Myy = 140   ← max |Myy|
    push!(cache.element_data_D, SS.ElementMoments(10.0, 100.0, 0.0))
    push!(cache.element_data_L, SS.ElementMoments(100.0, 10.0, 0.0))

    SS._combine_element_moments!(cache)
    ed = cache.element_data[1]

    @testset "representative tensor is still max |Mxx|" begin
        @test ed.Mxx ≈ 1.2 * 10.0 + 1.6 * 100.0
        @test ed.Myy ≈ 1.2 * 100.0 + 1.6 * 10.0
        @test ed.Mxy ≈ 0.0
    end

    @testset "combo tensors expose the Myy-governing combo" begin
        @test SS._n_design_combos(cache) == 2
        t1 = SS._combo_tensor(cache, 1, 1)
        t2 = SS._combo_tensor(cache, 1, 2)
        @test t1[1] ≈ 172.0
        @test t1[2] ≈ 136.0
        @test t2[1] ≈ 14.0
        @test t2[2] ≈ 140.0
        @test t2[2] > t1[2]   # Myy is larger under 1.4D
    end

    @testset "δ-band envelope takes Myy from the other combo" begin
        # `_integrate_at` returns Σ(Mn · A) / δ.  One element, A = 1, δ = 2
        # → I = Mn / 2.
        δ = 2.0
        faces_x = SS._integrate_design_faces(cache, [1], (0.0, 0.0), (1.0, 0.0), δ)
        faces_y = SS._integrate_design_faces(cache, [1], (0.0, 0.0), (0.0, 1.0), δ)
        @test faces_x.hogging ≈ 172.0 / δ
        @test faces_y.hogging ≈ 140.0 / δ   # 1.4D, not the |Mxx| combo's 136
        @test faces_y.hogging > (1.2 * 100.0 + 1.6 * 10.0) / δ
        @test faces_x.sagging ≈ 0.0
        @test faces_y.sagging ≈ 0.0
    end

    @testset "Wood–Armer / area envelope both faces both directions" begin
        method = SS.FEA(moment_transform = :wood_armer, pattern_loading = false)
        moms = SS._extract_area_design_moments(cache, method, (1.0, 0.0))
        r = moms[1]
        # Asap hogging → negate → WA top (≤ 0).  Envelope:
        #   Mx_top from 1.2D+1.6L = −172
        #   My_top from 1.4D      = −140
        @test r.Mx_top ≈ -172.0
        @test r.My_top ≈ -140.0
        @test r.Mx_bot ≈ 0.0
        @test r.My_bot ≈ 0.0
        # The |Mxx|-picked tensor would have given My_top = −136.
        @test r.My_top < -(1.2 * 100.0 + 1.6 * 10.0)
    end

    @testset "sagging Myy governs under 1.4D" begin
        # Opposite-face envelope: dead is sagging in y (Asap-negative);
        # live is hogging in x.  1.2D+1.6L still wins |Mxx|; 1.4D wins
        # sagging |Myy|.
        cache_s = SS.FEAModelCache()
        push!(cache_s.element_data, _synthetic_element())
        push!(cache_s.element_data_D, SS.ElementMoments(10.0, -100.0, 0.0))
        push!(cache_s.element_data_L, SS.ElementMoments(100.0, 10.0, 0.0))
        SS._combine_element_moments!(cache_s)
        @test cache_s.element_data[1].Mxx ≈ 172.0
        @test cache_s.element_data[1].Myy ≈ 1.2 * (-100.0) + 1.6 * 10.0  # −104

        δ = 2.0
        faces_y = SS._integrate_design_faces(cache_s, [1], (0.0, 0.0), (0.0, 1.0), δ)
        @test faces_y.hogging ≈ 0.0
        @test faces_y.sagging ≈ 140.0 / δ   # 1.4D Myy = −140, not −104
        @test faces_y.sagging > abs(1.2 * (-100.0) + 1.6 * 10.0) / δ

        method = SS.FEA(moment_transform = :wood_armer, pattern_loading = false)
        rs = SS._extract_area_design_moments(cache_s, method, (1.0, 0.0))[1]
        # Negated Asap: 1.2D+1.6L → (−172, +104); 1.4D → (−14, +140).
        @test rs.Mx_top ≈ -172.0
        @test rs.My_bot ≈ 140.0
        @test rs.My_bot > -(1.2 * (-100.0) + 1.6 * 10.0)
    end

    @testset "single-combo identity" begin
        cache1 = SS.FEAModelCache()
        push!(cache1.element_data, _synthetic_element(Mxx=50.0, Myy=-30.0, Mxy=4.0))
        @test SS._n_design_combos(cache1) == 1
        @test SS._combo_tensor(cache1, 1, 1) == (50.0, -30.0, 4.0)
        faces = SS._integrate_design_faces(cache1, [1], (0.0, 0.0), (1.0, 0.0), 2.0)
        @test faces.hogging ≈ 50.0 / 2.0
        @test faces.sagging ≈ 0.0

        method = SS.FEA(moment_transform = :wood_armer, pattern_loading = false)
        r1 = SS._extract_area_design_moments(cache1, method, (1.0, 0.0))[1]
        wa = SS.wood_armer(-50.0, 30.0, -4.0)  # negated Asap tensor
        @test r1.Mx_bot ≈ wa.Mx_bot
        @test r1.My_bot ≈ wa.My_bot
        @test r1.Mx_top ≈ wa.Mx_top
        @test r1.My_top ≈ wa.My_top
    end
end
