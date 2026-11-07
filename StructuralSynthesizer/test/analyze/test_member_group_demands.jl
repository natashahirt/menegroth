# Unit tests for the FEM → ACI 318-19 end-moment sign-convention helper used
# by `member_group_demands` to populate `MemberDemand.M1x/M2x/M1y/M2y` for
# columns from the Asap analysis.
#
# Reference: ACI 318-19 §6.6.4.5.3 (Cm) and §6.2.5.1 (slenderness limit) —
# `M1/M2 > 0` ⇔ double curvature, `M1/M2 < 0` ⇔ single curvature. AISC
# 360-16 Appendix 8 uses the same sign convention.

using Test
using StructuralSynthesizer

@testset "_fem_to_aci_endmoments — ACI 318-19 sign convention" begin
    f = StructuralSynthesizer._fem_to_aci_endmoments

    @testset "Cantilever-like (one end zero)" begin
        # M_start = 0, M_end ≠ 0 → only one moment, ratio is 0.
        M1, M2 = f(0.0, 100.0)
        @test M2 ≈ 100.0
        @test M1 ≈ 0.0

        # Symmetric: M_start ≠ 0, M_end = 0
        M1, M2 = f(100.0, 0.0)
        @test M2 ≈ 100.0
        @test M1 ≈ 0.0
    end

    @testset "Single curvature (FEM signs opposite) → ACI M1/M2 < 0" begin
        # Equal magnitudes, opposite FEM signs (single curvature).
        M1, M2 = f(+100.0, -100.0)
        @test M2 ≈ 100.0
        @test M1 ≈ -100.0
        @test M1 / M2 ≈ -1.0  # ACI 318-19: -1.0 = pure single curvature

        # Unequal magnitudes, opposite signs.
        M1, M2 = f(+50.0, -100.0)
        @test M2 ≈ 100.0
        @test M1 ≈ -50.0
        @test M1 / M2 ≈ -0.5
    end

    @testset "Double curvature (FEM signs same) → ACI M1/M2 > 0" begin
        # Equal magnitudes, same FEM sign (double curvature S-shape).
        M1, M2 = f(+100.0, +100.0)
        @test M2 ≈ 100.0
        @test M1 ≈ +100.0
        @test M1 / M2 ≈ +1.0  # ACI 318-19: +1.0 = pure double curvature

        # Unequal magnitudes, same sign.
        M1, M2 = f(-50.0, -100.0)
        @test M2 ≈ 100.0
        @test M1 ≈ +50.0
        @test M1 / M2 ≈ +0.5
    end

    @testset "|M2| ≥ |M1| ordering enforced" begin
        # Larger magnitude is at start.
        M1, M2 = f(-150.0, +75.0)
        @test M2 ≈ 150.0
        @test abs(M1) ≤ M2

        # Larger at end.
        M1, M2 = f(+75.0, -150.0)
        @test M2 ≈ 150.0
        @test abs(M1) ≤ M2
    end

    @testset "Zero moments" begin
        M1, M2 = f(0.0, 0.0)
        @test M1 == 0.0
        @test M2 == 0.0
    end

    @testset "ACI 318-19 limits sanity checks" begin
        # In single curvature (M1/M2 < 0), the slenderness limit
        # (34 + 12·M1/M2) is *smaller* than 34 — more conservative.
        M1, M2 = f(+100.0, -100.0)
        @test 34 + 12 * M1 / M2 ≈ 22.0  # = 34 - 12·1 = 22

        # In double curvature (M1/M2 > 0), the limit is larger (capped at 40).
        M1, M2 = f(+100.0, +100.0)
        @test 34 + 12 * M1 / M2 ≈ 46.0  # raw value before min(., 40) clamp
    end
end

# Default beam roll Ψ = π/2 puts local y along +global Z, so a downward load
# is Vy and its moment is My. Design shear has to follow that pair. A
# fixed-fixed (or simple) span of length L under uniform w has end shear wL/2.
@testset "gravity shear is the strong-axis shear" begin
    Asap = StructuralSynthesizer.Asap
    sec = Asap.Section(0.01u"m^2", 200e9u"Pa", 77e9u"Pa",
                       1e-4u"m^4", 1e-4u"m^4", 1e-4u"m^4")
    pin = [false, false, false, false, true, true]
    roller = [true, false, false, false, true, true]
    L = 8.0
    w = 1000.0   # N/m = 1000 Pa × 1 m
    n1 = Asap.Node([0.0u"m", 0.0u"m", 0.0u"m"], pin)
    n2 = Asap.Node([L * u"m", 0.0u"m", 0.0u"m"], roller)
    el = Asap.Element(n1, n2, sec)
    @test el.Ψ ≈ π / 2
    load = Asap.TributaryLoad(el, [0.0, 1.0], [1.0u"m", 1.0u"m"], w * u"Pa",
                              (0.0, 0.0, -1.0))
    model = Asap.Model([n1, n2], [el], [load])
    Asap.solve!(model)

    fd = Asap.ElementForceAndDisplacement(el, [load]; resolution = 21)
    peaks = StructuralSynthesizer._strong_weak_peaks(fd.forces.My, fd.forces.Vy,
                                                     fd.forces.Mz, fd.forces.Vz)
    # End shear of a full-span uniform load is wL/2 for both end conditions
    # Asap integrates. The strong-axis peak must be that shear, not Vz.
    @test peaks.Vu ≈ w * L / 2 rtol = 1e-6
    @test peaks.Vu ≈ maximum(abs, fd.forces.Vy)
    @test peaks.Mu > 0
    @test peaks.Vu_weak < 1.0
    @test peaks.Mu_weak < 1.0

    # Along global Y the rotation matrix is a special case. Same pairing.
    # Both ends fixed: releasing θy would free torsion on a Y-aligned member.
    fixed = fill(false, 6)
    n3 = Asap.Node([0.0u"m", 0.0u"m", 0.0u"m"], fixed)
    n4 = Asap.Node([0.0u"m", L * u"m", 0.0u"m"], fixed)
    ely = Asap.Element(n3, n4, sec)
    loady = Asap.TributaryLoad(ely, [0.0, 1.0], [1.0u"m", 1.0u"m"], w * u"Pa",
                               (0.0, 0.0, -1.0))
    modely = Asap.Model([n3, n4], [ely], [loady])
    Asap.solve!(modely)
    fdy = Asap.ElementForceAndDisplacement(ely, [loady]; resolution = 21)
    peaksy = StructuralSynthesizer._strong_weak_peaks(fdy.forces.My, fdy.forces.Vy,
                                                      fdy.forces.Mz, fdy.forces.Vz)
    @test peaksy.Vu ≈ w * L / 2 rtol = 1e-6
    @test peaksy.Vu_weak < 1.0

    # Raw local end-force slots: 2 = Vy, 3 = Vz, 6 = My, 5 = Mz.
    raw = zeros(12)
    raw[2] = 10.0
    raw[3] = 99.0
    raw[6] = 20.0
    raw[5] = 77.0
    raw[8] = -4.0
    ends = StructuralSynthesizer._strong_weak_peaks(raw)
    @test ends.Vu ≈ 10.0
    @test ends.Mu ≈ 20.0
end
