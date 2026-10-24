# ==============================================================================
# Per-station T-beam flange width — ACI 318-11 §8.12.2 / §8.12.3
# ==============================================================================
#
# The per-side tributary extent is sampled at a station and capped the same way
# `effective_flange_width` caps a constant spacing. A constant profile must match
# that scalar result. A varying profile uses the width at the sagging station
# that maximizes M⁺/bf, not the widest point on the span.
#
# Reference: ACI 318-11 §8.12.2, §8.12.3 (corpus: aci-318-11, PDF p. 119).

using Test
using Unitful
using StructuralSizer

@testset "Per-station T-beam flange (ACI 8.12)" begin

    bw = 12.0u"inch"
    hf = 5.0u"inch"
    ln = 240.0u"inch"
    # sw = 48 in ⇒ each side d = sw/2 = 24 in = 0.6096 m
    d = 0.6096
    left = SideExtentProfile(d)
    right = SideExtentProfile(d)

    @testset "constant interior profile matches effective_flange_width" begin
        bf_scalar = effective_flange_width(bw=bw, hf=hf, sw=48.0u"inch", ln=ln,
                                           position=:interior)
        bf_s = flange_width_at_station(bw, hf, ln, 0.5; left=left, right=right)
        @test bf_s == bf_scalar
        # Parabolic sagging demand. Constant bf ⇒ governing station is midspan,
        # and the returned width is the scalar width.
        M(s) = (4 * s * (1 - s)) * u"N*m"
        bf_g = governing_flange_width(bw, hf, ln, M; left=left, right=right)
        @test bf_g == bf_scalar
    end

    @testset "constant edge profile matches the one-sided caps" begin
        bf_scalar = effective_flange_width(bw=bw, hf=hf, sw=48.0u"inch", ln=ln,
                                           position=:edge)
        bf_s = flange_width_at_station(bw, hf, ln, 0.3; left=left, right=nothing)
        @test isapprox(ustrip(u"inch", bf_s), ustrip(u"inch", bf_scalar); atol=1e-6)
    end

    @testset "varying profile is taken where M⁺/bf peaks, not at the widest point" begin
        # Caps do not bind: 8·hf and ln/8 are far above d. The neck is at s = 0.7.
        hf_loose = 2.0u"m"
        ln_loose = 100.0u"m"
        bw_m = 0.3u"m"
        neck = SideExtentProfile([0.0, 0.7, 1.0], [1.0, 0.15, 1.0])
        # Demand concentrated at the neck.
        M(s) = exp(-((s - 0.7) / 0.05)^2) * u"N*m"
        bf_g = governing_flange_width(bw_m, hf_loose, ln_loose, M;
                                      left=neck, right=neck)
        bf_neck = flange_width_at_station(bw_m, hf_loose, ln_loose, 0.7;
                                          left=neck, right=neck)
        bf_wide = flange_width_at_station(bw_m, hf_loose, ln_loose, 0.0;
                                          left=neck, right=neck)
        @test isapprox(ustrip(u"m", bf_g), ustrip(u"m", bf_neck); atol=2e-2)
        @test ustrip(u"m", bf_g) < ustrip(u"m", bf_wide) - 0.5
    end

    @testset "no sagging demand returns the midspan width" begin
        M(s) = -1.0u"N*m"
        bf_g = governing_flange_width(bw, hf, ln, M; left=left, right=right)
        bf_mid = flange_width_at_station(bw, hf, ln, 0.5; left=left, right=right)
        @test bf_g == bf_mid
    end
end
