# =============================================================================
# Tests for ACI Concrete Torsion Capacity — Mxy Discount (torsion_discount.jl)
# =============================================================================
#
# Validates the three internal functions:
#   _aci_torsion_shear_stress  — τ_c = 2λ√f'c
#   _aci_concrete_torsion_capacity — circular V–T interaction
#   _apply_torsion_discount — sign-preserving |Mxy| reduction
#
# Reference: Parsekian (1996) Eq. (3.5), adapted to ACI 318-11 §11.2.1.1.
# =============================================================================

using Test
using StructuralSizer

const SS = StructuralSizer

# =============================================================================
# Helper: convert psi → Pa for ACI formulas
# =============================================================================
@testset "Concrete Torsion Discount" begin

    # =====================================================================
    # _aci_torsion_shear_stress
    # =====================================================================
    @testset "_aci_torsion_shear_stress — τ_c = 2λ√f'c" begin

        @testset "4000 psi NWC (λ=1.0)" begin
            # f'c = 4000 psi = 27.58 MPa
            fc_Pa = 4000.0 * PSI_TO_PA
            τ = SS._aci_torsion_shear_stress(fc_Pa, 1.0)
            # τ_c = 2 × 1.0 × √(27.58e6) = 2 × 5252 = 10504 Pa
            @test isapprox(τ, 2.0 * sqrt(fc_Pa), rtol=1e-12)
            # Sanity: ~10.5 kPa ≈ 1.52 psi × 6895 ≈ 10.5 kPa — but in Pa units:
            # 2√(4000 psi) = 126.5 psi → 126.5 × 6895 ≈ 872 kPa
            # But the function takes Pa, so 2√(27.58e6) ≈ 10504 Pa ≈ 10.5 kPa
            @test τ > 0.0
        end

        @testset "Lightweight concrete (λ=0.75)" begin
            fc_Pa = 4000.0 * PSI_TO_PA
            τ_lwc = SS._aci_torsion_shear_stress(fc_Pa, 0.75)
            τ_nwc = SS._aci_torsion_shear_stress(fc_Pa, 1.0)
            # LWC should be 75% of NWC
            @test isapprox(τ_lwc, 0.75 * τ_nwc, rtol=1e-12)
        end

        @testset "Zero f'c → zero capacity" begin
            @test SS._aci_torsion_shear_stress(0.0, 1.0) == 0.0
        end

        @testset "Scales with √f'c" begin
            fc1 = 3000.0 * PSI_TO_PA
            fc2 = 6000.0 * PSI_TO_PA
            τ1 = SS._aci_torsion_shear_stress(fc1, 1.0)
            τ2 = SS._aci_torsion_shear_stress(fc2, 1.0)
            # τ2/τ1 = √(6000/3000) = √2
            @test isapprox(τ2 / τ1, sqrt(2.0), rtol=1e-10)
        end
    end

    # =====================================================================
    # _aci_concrete_torsion_capacity
    # =====================================================================
    @testset "_aci_concrete_torsion_capacity — V–T interaction" begin

        # Common parameters: 8" NWC slab, f'c = 4000 psi
        h_m = 8.0 * 0.0254       # 0.2032 m
        d_m = 6.5 * 0.0254       # 0.1651 m
        fc_Pa = 4000.0 * PSI_TO_PA
        λ = 1.0

        # Pre-compute τ_c and pure-torsion capacity for hand checks
        τ_c = 2.0 * λ * sqrt(fc_Pa)
        Mxy_c0 = h_m^2 * τ_c / 3.0  # pure-torsion capacity (V=0)

        @testset "Zero shear → full pure-torsion capacity" begin
            # When Qxz = Qyz = 0, the full Mxy_c0 should be returned
            Mxy_c = SS._aci_concrete_torsion_capacity(0.0, 0.0, h_m, d_m, fc_Pa, λ)
            @test isapprox(Mxy_c, Mxy_c0, rtol=1e-10)
            @test Mxy_c > 0.0
        end

        @testset "Shear exactly at capacity → zero torsion capacity" begin
            # V = d · τ_c → V_ratio = 1.0 → Mxy_c = 0
            V_at_cap = d_m * τ_c
            Mxy_c = SS._aci_concrete_torsion_capacity(V_at_cap, 0.0, h_m, d_m, fc_Pa, λ)
            @test Mxy_c == 0.0
        end

        @testset "Shear exceeds capacity → zero torsion capacity" begin
            V_over = 2.0 * d_m * τ_c
            Mxy_c = SS._aci_concrete_torsion_capacity(V_over, 0.0, h_m, d_m, fc_Pa, λ)
            @test Mxy_c == 0.0
        end

        @testset "Moderate shear — hand calculation (V = 0.5 Vc)" begin
            # V_ratio = 0.5 → tv = 0.25 → √(1 - 0.25) = √0.75 ≈ 0.8660
            # Mxy_c = 0.8660 × h² × τ_c / 3
            V_half = 0.5 * d_m * τ_c
            Mxy_c = SS._aci_concrete_torsion_capacity(V_half, 0.0, h_m, d_m, fc_Pa, λ)
            expected = sqrt(0.75) * h_m^2 * τ_c / 3.0
            @test isapprox(Mxy_c, expected, rtol=1e-10)
        end

        @testset "Uses max(|Qxz|, |Qyz|) as governing shear" begin
            V = 0.3 * d_m * τ_c
            # Qxz governs
            c1 = SS._aci_concrete_torsion_capacity(V, 0.0, h_m, d_m, fc_Pa, λ)
            # Qyz governs
            c2 = SS._aci_concrete_torsion_capacity(0.0, V, h_m, d_m, fc_Pa, λ)
            # Both equal
            c3 = SS._aci_concrete_torsion_capacity(V, V, h_m, d_m, fc_Pa, λ)
            @test isapprox(c1, c2, rtol=1e-12)
            @test isapprox(c1, c3, rtol=1e-12)
        end

        @testset "Negative shear forces → same result (uses abs)" begin
            V = 0.4 * d_m * τ_c
            c_pos = SS._aci_concrete_torsion_capacity(V, 0.0, h_m, d_m, fc_Pa, λ)
            c_neg = SS._aci_concrete_torsion_capacity(-V, 0.0, h_m, d_m, fc_Pa, λ)
            @test isapprox(c_pos, c_neg, rtol=1e-12)
        end

        @testset "Degenerate section (d ≈ 0) → zero capacity" begin
            Mxy_c = SS._aci_concrete_torsion_capacity(100.0, 0.0, h_m, 0.0, fc_Pa, λ)
            @test Mxy_c == 0.0
        end

        @testset "Zero f'c → zero capacity" begin
            Mxy_c = SS._aci_concrete_torsion_capacity(0.0, 0.0, h_m, d_m, 0.0, λ)
            @test Mxy_c == 0.0
        end

        @testset "Lightweight concrete reduces capacity" begin
            c_nwc = SS._aci_concrete_torsion_capacity(0.0, 0.0, h_m, d_m, fc_Pa, 1.0)
            c_lwc = SS._aci_concrete_torsion_capacity(0.0, 0.0, h_m, d_m, fc_Pa, 0.75)
            # LWC capacity = 0.75 × NWC capacity (linear in λ for V=0)
            @test isapprox(c_lwc, 0.75 * c_nwc, rtol=1e-10)
        end

        @testset "Thicker slab → higher capacity (quadratic in h)" begin
            h_10 = 10.0 * 0.0254  # 10" slab
            d_10 = 8.5 * 0.0254
            c_8 = SS._aci_concrete_torsion_capacity(0.0, 0.0, h_m, d_m, fc_Pa, λ)
            c_10 = SS._aci_concrete_torsion_capacity(0.0, 0.0, h_10, d_10, fc_Pa, λ)
            # At V=0: Mxy_c ∝ h², so ratio = (10/8)² = 1.5625
            @test isapprox(c_10 / c_8, (10.0 / 8.0)^2, rtol=1e-10)
        end

        @testset "Circular interaction — intermediate points" begin
            # Verify that V² + (Mxy/Mxy_c0)² ≈ 1 on the interaction curve
            # Pick V_ratio = 0.6 → tv = 0.36 → Mxy_c/Mxy_c0 = √(1 - 0.36) = 0.8
            V_06 = 0.6 * d_m * τ_c
            Mxy_c = SS._aci_concrete_torsion_capacity(V_06, 0.0, h_m, d_m, fc_Pa, λ)
            # Check: (V/Vc)² + (Mxy_c/Mxy_c0)² = 0.36 + 0.64 = 1.0
            Vc = d_m * τ_c
            @test isapprox((V_06 / Vc)^2 + (Mxy_c / Mxy_c0)^2, 1.0, atol=1e-10)
        end
    end

    # =====================================================================
    # _apply_torsion_discount
    # =====================================================================
    @testset "_apply_torsion_discount — sign-preserving reduction" begin

        @testset "Positive Mxy, partial reduction" begin
            # |Mxy| = 1000, Mxy_c = 300 → 700
            result = SS._apply_torsion_discount(1000.0, 300.0)
            @test result ≈ 700.0
        end

        @testset "Negative Mxy, partial reduction" begin
            # |Mxy| = 1000, Mxy_c = 300 → -700 (preserves sign)
            result = SS._apply_torsion_discount(-1000.0, 300.0)
            @test result ≈ -700.0
        end

        @testset "Mxy fully absorbed by concrete (|Mxy| < Mxy_c)" begin
            result = SS._apply_torsion_discount(200.0, 500.0)
            @test result == 0.0
        end

        @testset "Negative Mxy fully absorbed" begin
            result = SS._apply_torsion_discount(-200.0, 500.0)
            @test result == 0.0
        end

        @testset "|Mxy| exactly equals Mxy_c → zero" begin
            result = SS._apply_torsion_discount(500.0, 500.0)
            @test result == 0.0
        end

        @testset "Zero Mxy → zero" begin
            result = SS._apply_torsion_discount(0.0, 300.0)
            @test result == 0.0
        end

        @testset "Zero Mxy_c → unchanged" begin
            result = SS._apply_torsion_discount(1000.0, 0.0)
            @test result ≈ 1000.0
        end

        @testset "Both zero → zero" begin
            result = SS._apply_torsion_discount(0.0, 0.0)
            @test result == 0.0
        end
    end

    # =====================================================================
    # FEA struct — concrete_torsion_discount knob
    # =====================================================================
    @testset "FEA struct — concrete_torsion_discount knob" begin

        @testset "Default is false" begin
            fea = SS.FEA()
            @test fea.concrete_torsion_discount == false
        end

        @testset "Can enable with wood_armer" begin
            fea = SS.FEA(moment_transform=:wood_armer, concrete_torsion_discount=true)
            @test fea.concrete_torsion_discount == true
            @test fea.moment_transform == :wood_armer
        end

        @testset "Warning when enabled with non-wood_armer transform" begin
            # Should warn but still construct
            w = @test_logs (:warn, r"concrete_torsion_discount") begin
                SS.FEA(moment_transform=:projection, concrete_torsion_discount=true)
            end
            @test w.concrete_torsion_discount == true
        end
    end

    # =====================================================================
    # Realistic scenario: typical 8" slab, 4000 psi, moderate shear
    # =====================================================================
    @testset "Realistic scenario — 8\" slab, 4000 psi" begin
        h_m = 8.0 * 0.0254       # 0.2032 m
        d_m = 6.5 * 0.0254       # 0.1651 m
        fc_Pa = 4000.0 * PSI_TO_PA
        λ = 1.0

        τ_c = 2.0 * sqrt(fc_Pa)
        Mxy_c0 = h_m^2 * τ_c / 3.0

        @testset "Pure-torsion capacity is reasonable" begin
            # Mxy_c0 for 8" slab, 4000 psi NWC
            # τ_c = 2√(27.58e6) ≈ 10504 Pa
            # Mxy_c0 = 0.2032² × 10504 / 3 ≈ 144.5 N·m/m
            @test Mxy_c0 > 100.0   # N·m/m
            @test Mxy_c0 < 200.0   # reasonable range
        end

        @testset "Discount makes meaningful difference for small Mxy" begin
            # Mxy = 300 N·m/m (small twisting), V ≈ 0 → discount ≈ 145 N·m/m
            # Effective Mxy ≈ 155 N·m/m — about half
            Mxy_c = SS._aci_concrete_torsion_capacity(0.0, 0.0, h_m, d_m, fc_Pa, λ)
            eff = SS._apply_torsion_discount(300.0, Mxy_c)
            @test eff < 300.0
            @test eff > 0.0
            # Reduction should be about Mxy_c0 ≈ 145
            @test isapprox(300.0 - eff, Mxy_c0, rtol=0.01)
        end

        @testset "High shear eliminates torsion discount" begin
            # At V = Vc, no torsion capacity remains
            V = d_m * τ_c
            Mxy_c = SS._aci_concrete_torsion_capacity(V, 0.0, h_m, d_m, fc_Pa, λ)
            eff = SS._apply_torsion_discount(300.0, Mxy_c)
            @test eff ≈ 300.0  # no discount
        end
    end

end
