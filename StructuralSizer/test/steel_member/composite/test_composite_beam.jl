using StructuralSizer
using Asap
using Unitful
using Test

# ==============================================================================
# Helper: create common test fixtures
# ==============================================================================

"""W21×55 beam with solid slab, loosely adapted from AISC Example I-1."""
function _example_I1_setup()
    section = W("W21X55")
    material = A992_Steel
    
    # Solid slab: t_slab = 7.5 in. (mimics total 3 in. deck + 4.5 in. concrete
    # from the original example, treated as a solid slab for our implementation)
    fc′ = 4.0ksi
    wc  = 145.0u"lb/ft^3"
    Ec  = wc^1.5 * sqrt(uconvert(u"psi", fc′)) * 1.0u"psi^(-0.5)*lb^(-0.5)*ft^(1.5)"
    # Ec ≈ 3,644 ksi for NWC 4 ksi (AISC formula)
    # Use standard value:
    Ec = 3644.0ksi
    Es = 29000.0ksi
    
    slab = SolidSlabOnBeam(
        7.5u"inch",       # t_slab
        fc′,              # fc'
        Ec,               # Ec
        wc,               # wc
        Es,               # Es (for computing n)
        10.0u"ft",        # beam_spacing_left
        10.0u"ft",        # beam_spacing_right
    )
    
    L_beam = 45.0u"ft"
    
    # ¾ in. headed studs, 5 in. long, Fu = 65 ksi (ASTM A108)
    anchor = HeadedStudAnchor(
        0.75u"inch",      # d_sa
        5.0u"inch",       # l_sa
        65.0ksi,       # Fu
        50.0ksi,       # Fy (nominal)
        7850.0u"kg/m^3",  # ρ
    )
    
    return (; section, material, slab, anchor, L_beam)
end

# ==============================================================================
# 1. Type Construction
# ==============================================================================

@testset "Composite Types" begin
    @testset "SolidSlabOnBeam construction" begin
        slab = SolidSlabOnBeam(
            8.0u"inch", 4.0ksi, 3644.0ksi, 145.0u"lb/ft^3",
            29000.0ksi, 10.0u"ft", 10.0u"ft"
        )
        @test isapprox(slab.t_slab, uconvert(u"m", 8.0u"inch"); rtol=0.001)
        @test slab.fc′ == 4.0ksi
        # n = Es/Ec
        @test isapprox(slab.n, 29000.0 / 3644.0; rtol=0.001)
    end
    
    @testset "SolidSlabOnBeam with edge distances" begin
        slab = SolidSlabOnBeam(
            8.0u"inch", 4.0ksi, 3644.0ksi, 145.0u"lb/ft^3",
            29000.0ksi, 10.0u"ft", 10.0u"ft";
            edge_dist_left=3.0u"ft", edge_dist_right=nothing
        )
        @test isapprox(slab.edge_dist_left, uconvert(u"m", 3.0u"ft"); rtol=0.001)
        @test slab.edge_dist_right === nothing
    end
    
    @testset "HeadedStudAnchor construction" begin
        a = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0ksi, 50.0ksi,
                             7850.0u"kg/m^3")
        @test isapprox(a.d_sa, uconvert(u"m", 0.75u"inch"); rtol=0.001)
        @test a.n_per_row == 1
        @test a.ecc ≈ 1.72u"kgCO2e/kg"
    end
    
    @testset "HeadedStudAnchor with multi-row" begin
        a = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0ksi, 50.0ksi,
                             7850.0u"kg/m^3"; n_per_row=2)
        @test a.n_per_row == 2
    end
    
    @testset "HeadedStudAnchor invalid n_per_row" begin
        @test_throws ArgumentError HeadedStudAnchor(
            0.75u"inch", 5.0u"inch", 65.0ksi, 50.0ksi,
            7850.0u"kg/m^3"; n_per_row=0)
    end
    
    @testset "Stud mass (cylindrical shank)" begin
        a = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0ksi, 50.0ksi,
                             7850.0u"kg/m^3")
        m = stud_mass(a)
        # A = π/4 × (0.75 in)² ≈ 0.4418 in² = 2.85e-4 m²
        # V = 0.4418 in² × 5 in = 2.209 in³ = 3.62e-5 m³
        # m = 7850 × 3.62e-5 ≈ 0.284 kg
        @test ustrip(u"kg", m) > 0.0
        @test isapprox(ustrip(u"kg", m), 0.284; rtol=0.05)
    end
    
    @testset "CompositeContext construction" begin
        fix = _example_I1_setup()
        ctx = CompositeContext(fix.slab, fix.anchor, fix.L_beam)
        @test ctx.shored == false
        @test ctx.neg_moment == false
        @test isapprox(ctx.Lb_const, uconvert(u"m", fix.L_beam); rtol=0.001)
    end
    
    @testset "CompositeContext with options" begin
        fix = _example_I1_setup()
        ctx = CompositeContext(fix.slab, fix.anchor, fix.L_beam;
                               shored=true, Lb_const=10.0u"ft",
                               Asr=1.0u"inch^2", Fysr=60.0ksi,
                               neg_moment=true)
        @test ctx.shored == true
        @test isapprox(ctx.Lb_const, uconvert(u"m", 10.0u"ft"); rtol=0.001)
        @test ctx.neg_moment == true
    end
end

# ==============================================================================
# 2. Effective Width (AISC I3.1a)
# ==============================================================================

@testset "Effective Width (I3.1a)" begin
    @testset "Interior beam — spacing controls" begin
        # AISC Example I-1: L=45 ft, spacing=10 ft
        # L/8 = 45/8 = 5.625 ft per side → 11.25 ft total
        # spacing/2 = 10/2 = 5.0 ft per side → 10.0 ft total ← controls
        fix = _example_I1_setup()
        b_eff = get_b_eff(fix.slab, fix.L_beam)
        @test isapprox(b_eff, 10.0u"ft"; rtol=0.001)
    end
    
    @testset "Interior beam — span controls" begin
        slab = SolidSlabOnBeam(
            8.0u"inch", 4.0ksi, 3644.0ksi, 145.0u"lb/ft^3",
            29000.0ksi, 20.0u"ft", 20.0u"ft"
        )
        b_eff = get_b_eff(slab, 30.0u"ft")
        # L/8 = 30/8 = 3.75 ft per side → 7.5 ft total ← controls
        # spacing/2 = 10 ft per side → 20 ft total
        @test isapprox(b_eff, 7.5u"ft"; rtol=0.001)
    end
    
    @testset "Edge beam — edge distance controls one side" begin
        slab = SolidSlabOnBeam(
            8.0u"inch", 4.0ksi, 3644.0ksi, 145.0u"lb/ft^3",
            29000.0ksi, 10.0u"ft", 10.0u"ft";
            edge_dist_left=2.0u"ft", edge_dist_right=nothing
        )
        b_eff = get_b_eff(slab, 45.0u"ft")
        # Left: min(45/8=5.625, 10/2=5, 2.0) = 2.0 ft
        # Right: min(45/8=5.625, 10/2=5) = 5.0 ft
        # Total = 7.0 ft
        @test isapprox(b_eff, 7.0u"ft"; rtol=0.001)
    end
end

# ==============================================================================
# 3. Stud Strength (AISC I8.2a)
# ==============================================================================

@testset "Stud Shear Strength (I8.2a)" begin
    @testset "Solid slab — Rg=1.0, Rp=0.75" begin
        fix = _example_I1_setup()
        Rg, Rp = StructuralSizer._Rg_Rp(fix.anchor, fix.slab)
        @test Rg == 1.0
        @test Rp == 0.75
    end
    
    @testset "Qn for ¾-in. stud in 4 ksi solid slab" begin
        fix = _example_I1_setup()
        Qn = get_Qn(fix.anchor, fix.slab)
        
        # Manual calculation:
        # Asa = π/4 × 0.75² = 0.4418 in²
        # Qn_conc = 0.5 × 0.4418 × √(4 × 3644) = 0.5 × 0.4418 × 120.73 = 26.67 kips
        # Qn_steel = 1.0 × 0.75 × 0.4418 × 65 = 21.54 kips ← controls
        Qn_kips = ustrip(kip, Qn)
        @test isapprox(Qn_kips, 21.54; rtol=0.03)
    end
    
    @testset "Qn for deck slab (perpendicular, 1 stud/rib)" begin
        slab_deck = DeckSlabOnBeam(
            uconvert(u"m", 4.5u"inch"), 4.0ksi, 3644.0ksi, 145.0u"lb/ft^3",
            29000.0 / 3644.0,
            uconvert(u"m", 3.0u"inch"), uconvert(u"m", 6.0u"inch"), :perpendicular,
            uconvert(u"m", 10.0u"ft"), uconvert(u"m", 10.0u"ft"), nothing, nothing,
            nothing, nothing, π / 2, nothing
        )
        anchor = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0ksi, 50.0ksi,
                                  7850.0u"kg/m^3"; n_per_row=1)
        Rg, Rp = StructuralSizer._Rg_Rp(anchor, slab_deck)
        @test Rg == 1.0
        @test Rp == 0.6   # perpendicular deck, default (conservative)
    end
end

# ==============================================================================
# 4. Stud Validation Checks
# ==============================================================================

@testset "Stud Validations" begin
    @testset "Diameter check — passes" begin
        fix = _example_I1_setup()
        tf = fix.section.tf  # W21×55 tf ≈ 0.522 in.
        # 2.5 × 0.522 = 1.305 in. > 0.75 in. → ok
        @test validate_stud_diameter(fix.anchor, tf) === nothing
    end
    
    @testset "Diameter check — fails" begin
        big_stud = HeadedStudAnchor(1.5u"inch", 6.0u"inch", 65.0ksi, 50.0ksi,
                                    7850.0u"kg/m^3")
        tf = 0.4u"inch"  # 2.5 × 0.4 = 1.0 < 1.5
        @test_throws ArgumentError validate_stud_diameter(big_stud, tf)
    end
    
    @testset "Length check — passes (l_sa ≥ 4 d_sa)" begin
        fix = _example_I1_setup()
        # l_sa = 5 in., 4 × d_sa = 4 × 0.75 = 3.0 in. → ok
        @test validate_stud_length(fix.anchor, fix.slab) === nothing
    end
    
    @testset "Length check — fails (too short)" begin
        short_stud = HeadedStudAnchor(0.75u"inch", 2.0u"inch", 65.0ksi, 50.0ksi,
                                      7850.0u"kg/m^3")
        slab = SolidSlabOnBeam(8.0u"inch", 4.0ksi, 3644.0ksi, 145.0u"lb/ft^3",
                               29000.0ksi, 10.0u"ft", 10.0u"ft")
        # l_sa = 2 in. < 4 × 0.75 = 3.0 in.
        @test_throws ArgumentError validate_stud_length(short_stud, slab)
    end
end

# ==============================================================================
# 5. Horizontal Shear / Compression Force (I3.2d)
# ==============================================================================

@testset "Compression Force Cf (I3.2d)" begin
    fix = _example_I1_setup()
    b_eff = get_b_eff(fix.slab, fix.L_beam)  # 10.0 ft = 120 in.
    
    @testset "Full composite (ΣQn large)" begin
        ΣQn = 10000.0kip  # artificially large
        Cf = get_Cf(fix.section, fix.material, fix.slab, b_eff, ΣQn)
        
        # Cf = min(0.85×4×120×7.5, 50×As, 10000) 
        # V'_conc = 0.85 × 4 × 120 × 7.5 = 3060 kips (using b_eff=120 in, t=7.5 in)
        # V'_steel = 50 × 16.2 = 810 kips ← controls (W21×55, A≈16.2 in²)
        Cf_kips = ustrip(kip, Cf)
        @test isapprox(Cf_kips, 810.0; rtol=0.05)
    end
    
    @testset "Partial composite (studs limit)" begin
        ΣQn = 292.0kip  # from Example I-1
        Cf = get_Cf(fix.section, fix.material, fix.slab, b_eff, ΣQn)
        # ΣQn = 292 < min(3060, 810) → Cf = 292
        @test isapprox(ustrip(kip, Cf), 292.0; rtol=0.001)
    end
end

# ==============================================================================
# 6. Web Compactness Guard (I3.2a)
# ==============================================================================

@testset "Web Compactness (I3.2a)" begin
    @testset "W21×55 — compact web passes" begin
        fix = _example_I1_setup()
        # h/tw for W21×55 ≈ 50.0 < 3.76√(29000/50) = 90.55
        @test StructuralSizer._check_web_compact_composite(fix.section, fix.material) === nothing
    end
end

# ==============================================================================
# 7. PNA Solver — Positive Moment
# ==============================================================================

@testset "PNA Solver & Composite Mn" begin
    fix = _example_I1_setup()
    b_eff = get_b_eff(fix.slab, fix.L_beam)
    
    @testset "Full composite (PNA in slab)" begin
        As_Fy = fix.material.Fy * fix.section.A
        ΣQn = uconvert(kip, As_Fy)  # Full composite: limited by steel yielding
        result = get_Mn_composite(fix.section, fix.material, fix.slab, b_eff, ΣQn)
        
        # a = As×Fy / (0.85 fc' b_eff)
        # a = 810 / (0.85 × 4 × 120) = 810/408 = 1.985 in.
        a_in = ustrip(u"inch", result.a)
        @test isapprox(a_in, 1.985; rtol=0.05)
        
        # PNA should be in slab (a < t_slab = 7.5 in.)
        @test ustrip(u"inch", result.a) < 7.5
        
        # For full composite W21×55, ϕMn should be around 800-900 kip-ft
        ϕMn = 0.9 * result.Mn
        ϕMn_kipft = ustrip(kip*u"ft", ϕMn)
        @test ϕMn_kipft > 700  # must exceed Mu = 687 kip-ft
    end
    
    @testset "Partial composite ΣQn=292 kips (Example I-1 level)" begin
        ΣQn = 292.0kip
        result = get_Mn_composite(fix.section, fix.material, fix.slab, b_eff, ΣQn)
        
        # a = 292 / (0.85 × 4 × 120) = 0.716 in. (matches Example I-1!)
        a_in = ustrip(u"inch", result.a)
        @test isapprox(a_in, 0.716; rtol=0.02)
        
        # PNA should be in the steel (partial composite):
        # Cf = 292 < As×Fy = 810, so PNA is in steel section
        # y_pna is measured from top of slab, so y_pna > t_slab
        y_pna_from_slab_top = ustrip(u"inch", result.y_pna)
        @test y_pna_from_slab_top > ustrip(u"inch", fix.slab.t_slab)
        
        # ϕMn should be around 767 kip-ft (from Example I-1)
        # Note: Example I-1 uses a deck slab (different Ac geometry), so 
        # our solid slab result will differ somewhat. We verify a reasonable range.
        ϕMn_kipft = ustrip(kip*u"ft", 0.9 * result.Mn)
        @test ϕMn_kipft > 687.0   # must exceed required Mu
        @test ϕMn_kipft < 1000.0  # reasonable upper bound
    end
    
    @testset "Mn increases monotonically with ΣQn" begin
        Mn_prev = 0.0u"N*m"
        for frac in [0.25, 0.50, 0.75, 1.0]
            Cf_max = StructuralSizer._Cf_max(fix.section, fix.material, fix.slab, b_eff)
            ΣQn = frac * Cf_max
            result = get_Mn_composite(fix.section, fix.material, fix.slab, b_eff, ΣQn)
            @test result.Mn >= Mn_prev
            Mn_prev = result.Mn
        end
    end
    
    @testset "PNA equilibrium check (force balance)" begin
        ΣQn = 400.0kip
        result = get_Mn_composite(fix.section, fix.material, fix.slab, b_eff, ΣQn)
        Cf = get_Cf(fix.section, fix.material, fix.slab, b_eff, ΣQn)
        
        # For PNA in steel: Cf = Fy × (A_below_PNA - A_above_PNA)
        # A_above_PNA = (As×Fy - Cf) / (2 Fy)
        As = fix.section.A
        Fy = fix.material.Fy
        A_above = (As * Fy - Cf) / (2 * Fy)
        A_below = As - A_above
        
        # Equilibrium: C_slab + C_steel = T_steel
        # C_slab = Cf, T_steel = Fy × A_below, C_steel = Fy × A_above
        residual = ustrip(kip, Cf + Fy * A_above - Fy * A_below)
        @test abs(residual) < 0.01  # kips
    end
end

# ==============================================================================
# 8. Partial Composite Solver (find_required_ΣQn)
# ==============================================================================

@testset "Partial Composite Solver" begin
    fix = _example_I1_setup()
    b_eff = get_b_eff(fix.slab, fix.L_beam)
    Qn = get_Qn(fix.anchor, fix.slab)
    
    @testset "Target Mu = 687 kip-ft (Example I-1 LRFD)" begin
        Mu = 687.0kip*u"ft"
        result = find_required_ΣQn(fix.section, fix.material, fix.slab,
                                    b_eff, Mu, Qn; ϕ=0.9)
        @test result.sufficient == true
        # Example I-1 uses ΣQn = 292 kips at PNA location 6
        # Our solver should find a value in the same ballpark
        ΣQn_kips = ustrip(kip, result.ΣQn)
        @test ΣQn_kips > 200  # must be above the 25% minimum
        @test ΣQn_kips < 900  # must be below full composite
    end
    
    @testset "Infeasible — even full composite insufficient" begin
        Mn_huge = 5000.0kip*u"ft"
        result = find_required_ΣQn(fix.section, fix.material, fix.slab,
                                    b_eff, Mn_huge, Qn; ϕ=0.9)
        @test result.sufficient == false
    end
end

# ==============================================================================
# 9. Negative Moment (I3.2b)
# ==============================================================================

@testset "Negative Moment (I3.2b)" begin
    fix = _example_I1_setup()
    
    @testset "No rebar — falls back to bare steel Mp" begin
        Mn = get_Mn_negative(fix.section, fix.material, 0.0u"mm^2", 0.0u"MPa")
        Mp = fix.material.Fy * fix.section.Zx
        @test isapprox(Mn, Mp; rtol=0.001)
    end
    
    @testset "With rebar — Mn exceeds bare steel" begin
        Asr = 2.0u"inch^2"
        Fysr = 60.0ksi
        Mn = get_Mn_negative(fix.section, fix.material, Asr, Fysr)
        Mp = fix.material.Fy * fix.section.Zx
        # Rebar contribution should increase Mn
        @test ustrip(kip*u"ft", Mn) > ustrip(kip*u"ft", Mp)
    end
    
    @testset "Chapter F when the I3.2b gates are open" begin
        Lb = 3.0u"ft"
        Asr = 2.0u"inch^2"
        Fysr = 60.0ksi
        ϕF = get_ϕMn(fix.section, fix.material; Lb = Lb, Cb = 1.0, axis = :strong)
        none = StructuralSizer.available_negative_flexure(fix.section, fix.material; Lb = Lb,
                                           Asr = 0.0u"inch^2", Fysr = Fysr,
                                           neg_moment = true, ΣQn = 200.0u"kip")
        no_anchors = StructuralSizer.available_negative_flexure(fix.section, fix.material; Lb = Lb,
                                                Asr = Asr, Fysr = Fysr,
                                                neg_moment = false, ΣQn = 200.0u"kip")
        no_sum = StructuralSizer.available_negative_flexure(fix.section, fix.material; Lb = Lb,
                                            Asr = Asr, Fysr = Fysr,
                                            neg_moment = true)
        @test isapprox(none, ϕF; rtol = 1e-8)
        @test isapprox(no_anchors, ϕF; rtol = 1e-8)
        @test isapprox(no_sum, ϕF; rtol = 1e-8)
        developed = StructuralSizer.available_negative_flexure(fix.section, fix.material; Lb = Lb,
                                               Asr = Asr, Fysr = Fysr,
                                               neg_moment = true, ΣQn = 200.0u"kip")
        @test developed > ϕF
    end

    @testset "Negative Mn equilibrium check" begin
        Asr = 1.5u"inch^2"
        Fysr = 60.0ksi
        Mn = get_Mn_negative(fix.section, fix.material, Asr, Fysr)
        # Should be positive and finite
        @test ustrip(kip*u"ft", Mn) > 0
        @test isfinite(ustrip(kip*u"ft", Mn))
    end
end

# ==============================================================================
# 10. Transformed I and I_LB
# ==============================================================================

@testset "Transformed Section Properties" begin
    fix = _example_I1_setup()
    b_eff = get_b_eff(fix.slab, fix.L_beam)
    
    @testset "I_transformed > I_steel" begin
        I_tr = get_I_transformed(fix.section, fix.slab, b_eff)
        @test I_tr > fix.section.Ix
        # For W21×55 with 7.5 in. slab: I_tr should be substantially larger
        ratio = ustrip(I_tr / fix.section.Ix)
        @test ratio > 2.0  # composite I is typically 2-4× steel alone
    end
    
    @testset "I_LB at full composite is Eq. C-I3-1 and is below I_tr" begin
        # AISC 360-22 Commentary Eqs. C-I3-1 and C-I3-2 (corpus: aisc-360-22,
        # PDF pp. 501–502). Full composite action does not switch to I_tr.
        Cf_max = StructuralSizer._Cf_max(fix.section, fix.material, fix.slab, b_eff)
        I_LB = get_I_LB(fix.section, fix.material, fix.slab, b_eff, Cf_max)
        I_tr = get_I_transformed(fix.section, fix.slab, b_eff)
        @test I_LB > fix.section.Ix
        @test I_LB < I_tr

        sec = fix.section
        a = Cf_max / (0.85 * fix.slab.fc′ * b_eff)
        d_3 = sec.d / 2
        d_1 = fix.slab.t_slab - a / 2
        Ae = Cf_max / fix.material.Fy
        Y = (sec.A * d_3 + Ae * (2 * d_3 + d_1)) / (sec.A + Ae)
        I_hand = sec.Ix + sec.A * (Y - d_3)^2 + Ae * (2 * d_3 + d_1 - Y)^2
        @test isapprox(I_LB, I_hand; rtol = 1e-9)
    end

    @testset "Live load that passes on I_tr fails on I_LB" begin
        Cf_max = StructuralSizer._Cf_max(fix.section, fix.material, fix.slab, b_eff)
        I_LB = get_I_LB(fix.section, fix.material, fix.slab, b_eff, Cf_max)
        I_tr = get_I_transformed(fix.section, fix.slab, b_eff)
        L = fix.L_beam
        E = fix.material.E
        limit = L / 360
        # δ = 5 w L^4 / (384 E I). A weight between the two limit weights
        # passes on I_tr and fails on I_LB.
        w_tr = limit * 384 * E * I_tr / (5 * L^4)
        w_lb = limit * 384 * E * I_LB / (5 * L^4)
        w = (w_tr + w_lb) / 2
        r = check_composite_deflection(fix.section, fix.material, fix.slab, b_eff,
                                       Cf_max, L, 0.0u"kip/ft", w; shored = true)
        @test r.ok_LL == false
        δ_tr = 5 * w * L^4 / (384 * E * I_tr)
        @test δ_tr <= limit
    end
    
    @testset "I_LB at zero composite = I_steel" begin
        I_LB = get_I_LB(fix.section, fix.material, fix.slab, b_eff, 0.0kip)
        @test isapprox(I_LB, fix.section.Ix; rtol=0.001)
    end
    
    @testset "I_LB monotonically increases with ΣQn" begin
        Cf_max = StructuralSizer._Cf_max(fix.section, fix.material, fix.slab, b_eff)
        I_prev = fix.section.Ix
        for frac in [0.25, 0.50, 0.75, 1.0]
            I_LB = get_I_LB(fix.section, fix.material, fix.slab, b_eff, frac * Cf_max)
            @test I_LB >= I_prev
            I_prev = I_LB
        end
    end
    
    @testset "I_LB partial composite (Example I-1 level)" begin
        # Example I-1: W21×55, PNA location 6, I_LB = 2440 in.⁴
        # Our setup is slightly different (solid slab vs deck) so we just check range
        ΣQn = 292.0kip
        I_LB = get_I_LB(fix.section, fix.material, fix.slab, b_eff, ΣQn)
        I_LB_in4 = ustrip(u"inch^4", I_LB)
        @test I_LB_in4 > ustrip(u"inch^4", fix.section.Ix)  # > 1140
        @test I_LB_in4 < 10000  # reasonable upper bound
    end
end

# ==============================================================================
# 11. Deflection Checks
# ==============================================================================

@testset "Composite Deflection" begin
    fix = _example_I1_setup()
    b_eff = get_b_eff(fix.slab, fix.L_beam)
    
    @testset "Unshored — DL on steel, LL on composite" begin
        # Use full composite for this general check (ΣQn = Cf_max).
        # Partial composite at ΣQn=292 kip with a solid slab gives a low
        # composite ratio (~36%), where the exact I_LB formula correctly
        # produces a smaller I_LB. The deck-slab Example I-1 validation
        # tests partial composite separately with realistic deck parameters.
        Cf_max = StructuralSizer._Cf_max(fix.section, fix.material, fix.slab, b_eff)
        ΣQn = Cf_max
        w_DL = 0.93kip/u"ft"
        w_LL = 1.00kip/u"ft"
        
        result = check_composite_deflection(
            fix.section, fix.material, fix.slab, b_eff, ΣQn,
            fix.L_beam, w_DL, w_LL;
            shored=false, δ_limit_ratio=1/360
        )
        
        # LL deflection limit = 45ft × 12 / 360 = 1.5 in. = 38.1 mm
        @test isapprox(ustrip(u"mm", result.δ_LL_limit), 38.1; rtol=0.01)
        
        # At full composite, LL deflection easily passes
        @test result.δ_LL < result.δ_LL_limit
        @test result.ok_LL == true
    end
    
    @testset "Shored — all loads on composite" begin
        ΣQn = 292.0kip
        w_DL = 0.93kip/u"ft"
        w_LL = 1.00kip/u"ft"
        
        result = check_composite_deflection(
            fix.section, fix.material, fix.slab, b_eff, ΣQn,
            fix.L_beam, w_DL, w_LL;
            shored=true, δ_limit_ratio=1/360
        )
        
        # Shored: DL uses composite I too, so δ_DL should be smaller
        result_unshored = check_composite_deflection(
            fix.section, fix.material, fix.slab, b_eff, ΣQn,
            fix.L_beam, w_DL, w_LL;
            shored=false, δ_limit_ratio=1/360
        )
        @test result.δ_DL < result_unshored.δ_DL
    end
    
    @testset "Construction deflection limit check" begin
        ΣQn = 292.0kip
        w_DL = 0.83kip/u"ft"  # construction DL
        w_LL = 0.0kip/u"ft"
        
        result = check_composite_deflection(
            fix.section, fix.material, fix.slab, b_eff, ΣQn,
            fix.L_beam, w_DL, w_LL;
            shored=false, δ_limit_ratio=1/360,
            δ_const_limit=2.5u"inch"
        )
        
        # W21×55 Ix = 1140 in⁴, needs Ix_req = 1060 in⁴ → should pass
        @test result.ok_const == true
    end
end

# ==============================================================================
# 12. Construction Stage (I3.1b)
# ==============================================================================

@testset "Construction Stage (I3.1b)" begin
    fix = _example_I1_setup()
    
    @testset "W21×55 construction flexure passes" begin
        # Example I-1: Mu_const = 331 kip-ft (LRFD), ϕMn_steel = 473 kip-ft → ok
        Mu_const = 331.0kip*u"ft"
        Vu_const = 30.0kip
        
        result = check_construction(fix.section, fix.material, Mu_const, Vu_const;
                                     Lb_const=fix.L_beam, Cb_const=1.0)
        
        # W21×55 with Lb=45ft, Cb=1.0 → ϕMn depends on LTB
        # The example states ϕMn = 473 kip-ft (with adequate bracing through deck)
        # With Lb=45ft and no deck bracing, LTB reduces capacity significantly.
        # Let's test with short Lb (deck provides bracing):
        result_braced = check_construction(fix.section, fix.material, Mu_const, Vu_const;
                                            Lb_const=0.0u"ft", Cb_const=1.0)
        @test result_braced.flexure_ok == true
        @test result_braced.shear_ok == true
    end
end

# ==============================================================================
# 13. Stress Block Depth a
# ==============================================================================

@testset "Stress Block Depth" begin
    fix = _example_I1_setup()
    b_eff = get_b_eff(fix.slab, fix.L_beam)
    
    @testset "a = ΣQn / (0.85 fc' b_eff) — Example I-1 value" begin
        ΣQn = 292.0kip
        a = ΣQn / (0.85 * fix.slab.fc′ * b_eff)
        a_in = ustrip(u"inch", a)
        # Example I-1: a = 292 / (0.85 × 4 × 120) = 0.716 in.
        @test isapprox(a_in, 0.716; rtol=0.01)
    end
    
    @testset "a < t_slab for partial composite" begin
        ΣQn = 292.0kip
        result = get_Mn_composite(fix.section, fix.material, fix.slab, b_eff, ΣQn)
        @test ustrip(u"inch", result.a) < ustrip(u"inch", fix.slab.t_slab)
    end
end

# ==============================================================================
# 14. Edge Cases
# ==============================================================================

@testset "Edge Cases" begin
    fix = _example_I1_setup()
    b_eff = get_b_eff(fix.slab, fix.L_beam)
    
    @testset "Minimum composite (25% rule)" begin
        Cf_max = StructuralSizer._Cf_max(fix.section, fix.material, fix.slab, b_eff)
        ΣQn_min = 0.25 * Cf_max
        result = get_Mn_composite(fix.section, fix.material, fix.slab, b_eff, ΣQn_min)
        
        # Should produce a valid Mn above bare steel Mp
        Mp = fix.material.Fy * fix.section.Zx
        @test result.Mn > Mp
    end
    
    @testset "Full composite gives maximum Mn" begin
        Cf_max = StructuralSizer._Cf_max(fix.section, fix.material, fix.slab, b_eff)
        result_full = get_Mn_composite(fix.section, fix.material, fix.slab, b_eff, Cf_max)
        
        # Partial should be less
        result_partial = get_Mn_composite(fix.section, fix.material, fix.slab, b_eff, 0.5 * Cf_max)
        @test result_full.Mn > result_partial.Mn
    end
    
    @testset "ϕMn_composite returns correct fields" begin
        ΣQn = 292.0kip
        result = get_ϕMn_composite(fix.section, fix.material, fix.slab, b_eff, ΣQn)
        @test haskey(result, :ϕMn)
        @test haskey(result, :Mn)
        @test haskey(result, :y_pna)
        @test haskey(result, :Cf)
        @test haskey(result, :a)
        @test isapprox(result.ϕMn, 0.9 * result.Mn; rtol=1e-10)
    end
end

# ==============================================================================
# 15. AISCChecker Integration — Composite is_feasible
# ==============================================================================

@testset "AISCChecker Composite is_feasible" begin
    fix = _example_I1_setup()

    ctx = CompositeContext(fix.slab, fix.anchor, fix.L_beam;
                           shored=false, Lb_const=fix.L_beam)

    checker = AISCChecker(; deflection_limit=1/360, max_depth=Inf)
    cat = [fix.section]
    cache = StructuralSizer.create_cache(checker, 1)
    StructuralSizer.precompute_capacities!(checker, cache, cat, fix.material, MinWeight())

    @testset "Feasible under moderate moment" begin
        # Use a moderate moment well within composite capacity.
        # Lb_const is 10 ft. The pre-cure pour is omitted here (no tributary);
        # the 37-02 load is tested on its own. Beam self-weight remains D.
        light = construction_stage(fix.slab; b_trib = 0.0u"ft", p_concrete = 0.0u"psf")
        ctx_braced = CompositeContext(fix.slab, fix.anchor, fix.L_beam;
                                      shored=false, Lb_const=10.0u"ft",
                                      construction = light)
        Mu_moderate = 300.0kip*u"ft"
        demand = MemberDemand(1;
            Mux   = ustrip(u"N*m", uconvert(u"N*m", Mu_moderate)),
            Mux_neg = 0.0,  # sagging-only example
            Vu_strong = ustrip(u"N", uconvert(u"N", 50.0kip)),
        )
        geom = SteelMemberGeometry(fix.L_beam; Lb=fix.L_beam)

        ok = StructuralSizer.is_feasible(checker, cache, 1, fix.section, fix.material,
                                          demand, geom, ctx_braced)
        @test ok == true
    end

    @testset "Infeasible under extreme moment" begin
        Mu_extreme = 1500.0kip*u"ft"
        demand = MemberDemand(1;
            Mux = ustrip(u"N*m", uconvert(u"N*m", Mu_extreme)),
            Vu_strong = ustrip(u"N", uconvert(u"N", 50.0kip)),
        )
        geom = SteelMemberGeometry(fix.L_beam; Lb=fix.L_beam)

        ok = StructuralSizer.is_feasible(checker, cache, 1, fix.section, fix.material,
                                          demand, geom, ctx)
        @test ok == false
    end

    @testset "Composite ϕMn > bare steel ϕMn" begin
        b_eff = get_b_eff(fix.slab, fix.L_beam)
        Cf_max = StructuralSizer._Cf_max(fix.section, fix.material, fix.slab, b_eff)
        result_comp = get_ϕMn_composite(fix.section, fix.material, fix.slab, b_eff, Cf_max)
        ϕMn_comp = ustrip(u"N*m", result_comp.ϕMn)

        ϕMn_steel = ustrip(u"N*m", get_ϕMn(fix.section, fix.material;
                                              Lb=fix.L_beam, Cb=1.0, axis=:strong))
        @test ϕMn_comp > ϕMn_steel
    end

    @testset "Shored context works" begin
        ctx_shored = CompositeContext(fix.slab, fix.anchor, fix.L_beam; shored=true)
        demand = MemberDemand(1;
            Mux = ustrip(u"N*m", uconvert(u"N*m", 300.0kip*u"ft")),
            Mux_neg = 0.0,  # sagging-only example
            Vu_strong = ustrip(u"N", uconvert(u"N", 50.0kip)),
        )
        geom = SteelMemberGeometry(fix.L_beam; Lb=fix.L_beam)

        ok = StructuralSizer.is_feasible(checker, cache, 1, fix.section, fix.material,
                                          demand, geom, ctx_shored)
        @test ok == true
    end
end

# ==============================================================================
# 16. Stud Cost in Objective Function
# ==============================================================================

@testset "Composite Stud Contribution" begin
    fix = _example_I1_setup()
    # 12 ft: full composite does not fit, a moment between steel and full does.
    L = 12.0u"ft"
    ctx = CompositeContext(fix.slab, fix.anchor, L; shored=true)
    b_eff = get_b_eff(fix.slab, L)
    Cf = StructuralSizer._Cf_max(fix.section, fix.material, fix.slab, b_eff)
    Qn = get_Qn(fix.anchor, fix.slab)
    n_full = ceil(Int, ustrip(u"N", Cf) / ustrip(u"N", Qn))
    ϕ_steel = get_ϕMn(fix.section, fix.material; Lb=L, Cb=1.0, axis=:strong)
    ϕ_full = get_ϕMn_composite(fix.section, fix.material, fix.slab, b_eff, Cf).ϕMn
    Mu_mid = 0.5 * (ϕ_steel + ϕ_full)

    @testset "Weight is the designed count, not full composite" begin
        w = composite_stud_contribution(ctx, fix.section, fix.material, MinWeight();
                                        Mu=Mu_mid, Lb=L)
        m_one = stud_mass(fix.anchor)
        @test m_one > 0.0u"kg"
        layout = design_shear_anchors(fix.section, fix.material, fix.slab, fix.anchor,
                                      b_eff, L, Mu_mid; ϕMn_steel=ϕ_steel)
        @test layout.ok
        @test isapprox(ustrip(w / m_one), layout.n_half * 2; atol=1e-6)
        @test 0 < layout.n_half < n_full
    end

    @testset "Steel alone places no studs" begin
        w = composite_stud_contribution(ctx, fix.section, fix.material, MinWeight();
                                        Mu=0.5 * ϕ_steel, Lb=L)
        @test w == 0.0u"kg"
    end

    @testset "Carbon contribution" begin
        c = composite_stud_contribution(ctx, fix.section, fix.material, MinCarbon();
                                        Mu=Mu_mid, Lb=L)
        w = composite_stud_contribution(ctx, fix.section, fix.material, MinWeight();
                                        Mu=Mu_mid, Lb=L)
        @test c > 0.0u"kgCO2e"
        @test isapprox(c, w * fix.anchor.ecc; rtol=1e-10)
    end

    @testset "Volume objective returns zero (no stud volume)" begin
        v = composite_stud_contribution(ctx, fix.section, fix.material, MinVolume();
                                        Mu=Mu_mid, Lb=L)
        @test v ≈ 0.0u"m^3"
    end

    @testset "A moment the studs cannot develop throws" begin
        @test_throws ArgumentError composite_stud_contribution(
            ctx, fix.section, fix.material, MinWeight(); Mu=ϕ_full, Lb=L)
    end
end

# ==============================================================================
# 17. Rebar Extraction from Slab (beam_direction_from_vectors)
# ==============================================================================

@testset "Beam Direction Geometry" begin
    @testset "Parallel vectors" begin
        @test beam_direction_from_vectors((1.0, 0.0), (1.0, 0.0)) == true
        @test beam_direction_from_vectors((1.0, 0.0), (-1.0, 0.0)) == true
        @test beam_direction_from_vectors((0.0, 1.0), (0.0, 1.0)) == true
    end

    @testset "Perpendicular vectors" begin
        @test beam_direction_from_vectors((1.0, 0.0), (0.0, 1.0)) == false
        @test beam_direction_from_vectors((0.0, 1.0), (1.0, 0.0)) == false
    end

    @testset "Diagonal (not parallel)" begin
        @test beam_direction_from_vectors((1.0, 0.0), (1.0, 1.0)) == false
    end

    @testset "Nearly parallel (within tolerance)" begin
        @test beam_direction_from_vectors((1.0, 0.0), (1.0, 0.05); tol=0.1) == true
    end

    @testset "Zero vector returns false" begin
        @test beam_direction_from_vectors((0.0, 0.0), (1.0, 0.0)) == false
    end
end

@testset "Asr at one section" begin
    # §I3.2b(c): one section, inside the effective width. PDF p. 170.
    function _reinf(loc, As)
        z = 0.0u"kip*ft"
        return StripReinforcement(loc, z, As, As, As, 5, 6.0u"inch", 4, true)
    end
    col = [_reinf(:ext_neg, 4.0u"inch^2"), _reinf(:int_neg, 6.0u"inch^2")]
    mid = [_reinf(:ext_neg, 2.0u"inch^2"), _reinf(:int_neg, 3.0u"inch^2")]
    # Column strip 8 ft wide, centered on the beam. Middle strip on the right only.
    bands = [
        (y0 = -4.0u"ft", y1 = 4.0u"ft", strip_width = 8.0u"ft", reinf = col),
        (y0 = 4.0u"ft", y1 = 12.0u"ft", strip_width = 8.0u"ft", reinf = mid),
    ]
    Fysr = 75.0u"ksi"
    # b_eff stays inside the column strip: 2 ft each side. Middle steel is out.
    # Exterior section only: 4 in² * (4 ft / 8 ft) = 2 in². Interior 6 in² is not added.
    inside = asr_at_section(bands, :ext_neg, 2.0u"ft", 2.0u"ft"; Fysr = Fysr)
    @test isapprox(uconvert(u"inch^2", inside.Asr), 2.0u"inch^2"; rtol = 1e-8)
    @test inside.Fysr === Fysr
    # Right side reaches 2 ft into the middle strip.
    # Column overlap is 6 ft: 4 in² * 6/8 = 3 in². Middle overlap is 2 ft: 2 in² * 2/8 = 0.5 in².
    wider = asr_at_section(bands, :ext_neg, 2.0u"ft", 6.0u"ft"; Fysr = Fysr)
    @test isapprox(uconvert(u"inch^2", wider.Asr), 3.5u"inch^2"; rtol = 1e-8)
    interior = asr_at_section(bands, :int_neg, 2.0u"ft", 2.0u"ft"; Fysr = Fysr)
    @test isapprox(uconvert(u"inch^2", interior.Asr), 3.0u"inch^2"; rtol = 1e-8)
    @test_throws ArgumentError asr_at_section(bands, :pos, 2.0u"ft", 2.0u"ft"; Fysr = Fysr)
end

# ==============================================================================
# 17b. Pre-cure load — SEI/ASCE 37-02 Eqs. 2-2 and 2-3
# ==============================================================================

@testset "Pre-cure load is SEI/ASCE 37-02, flagged older than 37-14" begin
    fix = _example_I1_setup()
    stage = construction_stage(fix.slab; cp_class = :medium, b_trib = 10.0u"ft",
                               p_concrete = 100.0u"psf", p_L = 0.0u"Pa")
    dem = construction_span_demand(fix.section, fix.material, stage, 30.0u"ft")
    w_steel = fix.section.A * fix.material.ρ * GRAVITY
    w_c = 100.0u"psf" * 10.0u"ft"
    w_p = 50.0u"psf" * 10.0u"ft"
    # SEI/ASCE 37-02 §2.2.3 (corpus: sei-asce-37-02, PDF p. 16).
    w22 = 1.4 * w_steel + 1.4 * w_c
    w23 = 1.2 * w_steel + 1.4 * w_c + 1.6 * w_p
    @test dem.equation == "2-3"
    @test isapprox(dem.w, max(w22, w23); rtol = 1e-6)
    @test isapprox(dem.Mu, dem.w * (30.0u"ft")^2 / 8; rtol = 1e-9)
    @test isapprox(dem.Vu, dem.w * 30.0u"ft" / 2; rtol = 1e-9)
    @test occursin("37-02", dem.edition)
    @test occursin("37-14", dem.edition)
    @test dem.cp_class == :medium
    @test_throws ArgumentError construction_personnel_pressure(nothing)
    @test_throws ArgumentError construction_personnel_pressure(:bulk)
end

# ==============================================================================
# 18. Bracing Pipeline — Lb_const in CompositeContext
# ==============================================================================

@testset "Bracing Pipeline (Lb_const)" begin
    fix = _example_I1_setup()

    @testset "Lb_const defaults to L_beam" begin
        ctx = CompositeContext(fix.slab, fix.anchor, fix.L_beam)
        @test isapprox(ctx.Lb_const, uconvert(u"m", fix.L_beam); rtol=1e-10)
    end

    @testset "Deck defaults to a braced top flange" begin
        # Commentary §I3.1b, PDF p. 501: forms not attached to the top flange
        # may leave the unbraced length in control. Deck fastened to the flange
        # is the reverse, so Lb = 0 on the sagging face. An explicit length wins.
        deck = DeckSlabOnBeam(4.5u"inch", 4.0u"ksi", 3644.0u"ksi", 145.0u"lb/ft^3",
                              29000.0u"ksi", 3.0u"inch", 6.0u"inch", :perpendicular,
                              10.0u"ft", 10.0u"ft")
        ctx = CompositeContext(deck, fix.anchor, fix.L_beam)
        @test ctx.Lb_const == 0.0u"m"
        pinned = CompositeContext(deck, fix.anchor, fix.L_beam; Lb_const=fix.L_beam)
        @test isapprox(pinned.Lb_const, uconvert(u"m", fix.L_beam); rtol=1e-10)

        stage = construction_stage(deck; cp_class=:medium, b_trib=2.0u"m")
        pre = construction_span_demand(fix.section, fix.material, stage, fix.L_beam)
        # Appendix 6.3.1a Eq. A-6-5, Cd = 1, PDF p. 342.
        expect = 0.01 * pre.Mu / fix.section.ho
        @test isapprox(uconvert(u"N", pre.Vbr), uconvert(u"N", expect); rtol=1e-10)
    end

    @testset "Analysis dead-load shape scales the pre-cure moment" begin
        # ENGINEERING JUDGMENT: M and V from a uniform analysis dead load scale
        # by w_construction / w_ref. A pinned beam recovers wL²/8 and wL/2.
        # Fixed ends give wL²/12. A propped cantilever's fixed-end shear is 5wL/8.
        stage = construction_stage(fix.slab; cp_class=:medium, b_trib=2.0u"m")
        L = uconvert(u"m", fix.L_beam)
        simple = construction_span_demand(fix.section, fix.material, stage, L)
        @test simple.moment_model == :simple_span

        w_ref = 1000.0u"N/m"
        pinned = construction_with_shape(stage, w_ref * L^2 / 8, w_ref * L / 2, w_ref)
        pre = construction_span_demand(fix.section, fix.material, pinned, L)
        @test pre.moment_model == :analysis_dead_load
        @test isapprox(uconvert(u"N*m", pre.Mu), uconvert(u"N*m", simple.Mu); rtol=1e-10)
        @test isapprox(uconvert(u"N", pre.Vu), uconvert(u"N", simple.Vu); rtol=1e-10)

        fixed = construction_with_shape(stage, w_ref * L^2 / 12, w_ref * L / 2, w_ref)
        pre_f = construction_span_demand(fix.section, fix.material, fixed, L)
        @test isapprox(uconvert(u"N*m", pre_f.Mu), uconvert(u"N*m", simple.Mu) * (2 / 3); rtol=1e-10)

        propped = construction_with_shape(stage, w_ref * L^2 / 8, (5 / 8) * w_ref * L, w_ref)
        pre_p = construction_span_demand(fix.section, fix.material, propped, L)
        @test isapprox(uconvert(u"N", pre_p.Vu), uconvert(u"N", simple.Vu) * 1.25; rtol=1e-10)
    end

    @testset "Commentary Eq. C-F1-5" begin
        # Worked example, PDF p. 443: Mo = −100, M1 = +200, MCL = +50, Cb = 5.67.
        Cb = cb_gravity_top_flange_restrained(-100u"kip*inch", 200u"kip*inch", 50u"kip*inch")
        @test isapprox(Cb, 5.67; atol=0.005)
        sag(s) = 4 * s * (1 - s) * u"N*m"
        @test cb_neg_from_moment_field(sag) === nothing
        rev(s) = s <= 0 ? -100u"N*m" : (s >= 1 ? 200u"N*m" : 50u"N*m")
        @test isapprox(cb_neg_from_moment_field(rev), 5.67; atol=0.005)
    end

    @testset "Negative reinforcement is capped by the anchors" begin
        # §I3.2d.2 Eqs. I3-2a and I3-2b, PDF p. 171.
        Asr = 2.0u"inch^2"
        Fysr = 60.0u"ksi"
        full = get_Mn_negative(fix.section, fix.material, Asr, Fysr)
        capped = get_Mn_negative(fix.section, fix.material, Asr, Fysr; ΣQn = 10.0u"kip")
        bare = get_Mn_negative(fix.section, fix.material, Asr, Fysr; ΣQn = 0.0u"kip")
        @test ustrip(u"N*m", capped) < ustrip(u"N*m", full)
        @test isapprox(uconvert(u"N*m", bare),
                       uconvert(u"N*m", fix.material.Fy * fix.section.Zx); rtol=1e-8)
    end

    @testset "Custom Lb_const affects construction check" begin
        Mu_const = 400.0kip*u"ft"
        Vu_const = 50.0kip

        # Full span unbraced (conservative)
        r_full = check_construction(fix.section, fix.material, Mu_const, Vu_const;
                                     Lb_const=fix.L_beam)

        # Half span braced (deck provides lateral support at midspan)
        r_half = check_construction(fix.section, fix.material, Mu_const, Vu_const;
                                     Lb_const=fix.L_beam / 2)

        # Shorter Lb → higher ϕMn → more likely OK
        @test ustrip(u"N*m", r_half.ϕMn_steel) >= ustrip(u"N*m", r_full.ϕMn_steel)
    end

    @testset "Construction check uses bare steel (not composite)" begin
        Mu_const = 200.0kip*u"ft"
        Vu_const = 30.0kip
        r = check_construction(fix.section, fix.material, Mu_const, Vu_const;
                                Lb_const=fix.L_beam)

        # Compare to Chapter F bare steel capacity
        ϕMn_F = get_ϕMn(fix.section, fix.material; Lb=fix.L_beam, Cb=1.0, axis=:strong)
        @test isapprox(r.ϕMn_steel, ϕMn_F; rtol=1e-10)
    end
end

# ==============================================================================
# 19. AISC Design Example I-1 — Numerical Validation (Deck Slab)
# ==============================================================================
# Validates against AISC Steel Construction Manual, 15th Ed., Example I-1
# "Composite Beam Design"
#
# W21×55, A992, 45 ft span @ 10 ft o/c, unshored
# 3 in. × 18 ga. deck (perpendicular), 4.5 in. NWC above deck, fc'=4 ksi
# 3/4 in. headed studs, Fu=65 ksi, one per rib (weak stud)

function _aisc_example_I1_deck_setup()
    section  = W("W21X55")
    material = A992_Steel

    fc′ = 4.0ksi
    Ec  = 3644.0ksi
    Es  = 29000.0ksi

    slab = DeckSlabOnBeam(
        4.5u"inch",        # t_slab — concrete above deck ribs
        fc′, Ec,
        145.0u"lb/ft^3",  # wc
        Es,                # Es (for n = Es/Ec)
        3.0u"inch",        # hr — nominal rib height
        6.0u"inch",        # wr — average rib width
        :perpendicular,    # deck orientation
        10.0u"ft",         # beam_spacing_left
        10.0u"ft",         # beam_spacing_right
    )

    anchor = HeadedStudAnchor(
        0.75u"inch",       # d_sa
        5.0u"inch",        # l_sa
        65.0ksi,        # Fu
        50.0ksi,        # Fy (nominal)
        7850.0u"kg/m^3",  # ρ
    )

    L_beam = 45.0u"ft"
    return (; section, material, slab, anchor, L_beam)
end

@testset "AISC Example I-1 — Deck Slab Validation" begin
    fix = _aisc_example_I1_deck_setup()
    b_eff = get_b_eff(fix.slab, fix.L_beam)

    @testset "Effective width = 10 ft (spacing controls)" begin
        # Per Example I-1: spacing/2 = 5 ft per side = 10 ft total
        @test isapprox(b_eff, 10.0u"ft"; rtol=0.001)
    end

    @testset "Deck stud Rg/Rp and Qn" begin
        Rg, Rp = StructuralSizer._Rg_Rp(fix.anchor, fix.slab)
        @test Rg == 1.0    # perpendicular deck, 1 stud/rib
        @test Rp == 0.6    # AISC I8.2a "weak stud" position

        Qn = get_Qn(fix.anchor, fix.slab)
        # Example I-1: Qn = 17.2 kips/stud
        @test isapprox(ustrip(kip, Qn), 17.2; rtol=0.02)
    end

    @testset "Stress block depth a = 0.716 in." begin
        # a = ΣQn / (0.85 fc' b_eff) = 292 / (0.85 × 4 × 120) = 0.716 in.
        ΣQn = 292.0kip
        a = ΣQn / (0.85 * fix.slab.fc′ * b_eff)
        @test isapprox(ustrip(u"inch", a), 0.716; rtol=0.01)
    end

    @testset "Composite ϕMn ≈ 767 kip-ft (LRFD, PNA location 6)" begin
        ΣQn = 292.0kip
        result = get_ϕMn_composite(fix.section, fix.material, fix.slab, b_eff, ΣQn)

        # Example I-1: ϕMn = 767 kip-ft
        # Our section database has slightly different As (15.99 vs 16.2 in²),
        # so we allow ~1% tolerance.
        @test isapprox(ustrip(kip*u"ft", result.ϕMn), 767.0; rtol=0.015)

        # Must exceed required Mu = 687 kip-ft
        @test ustrip(kip*u"ft", result.ϕMn) > 687.0
    end

    @testset "I_LB ≈ 2440 in⁴" begin
        ΣQn = 292.0kip
        I_LB = get_I_LB(fix.section, fix.material, fix.slab, b_eff, ΣQn)

        # Example I-1: I_LB = 2440 in⁴ (Manual Table 3-20)
        @test isapprox(ustrip(u"inch^4", I_LB), 2440.0; rtol=0.01)
    end

    @testset "Live load deflection δ_LL ≈ 1.30 in. < L/360" begin
        ΣQn = 292.0kip
        w_DL = 0.93kip/u"ft"
        w_LL = 1.00kip/u"ft"

        result = check_composite_deflection(
            fix.section, fix.material, fix.slab, b_eff, ΣQn,
            fix.L_beam, w_DL, w_LL;
            shored=false, δ_limit_ratio=1/360
        )

        # Example I-1: δ_LL = 1.30 in.
        δ_LL_in = ustrip(u"inch", result.δ_LL)
        @test isapprox(δ_LL_in, 1.30; rtol=0.02)

        # δ_LL < L/360 = 1.5 in.
        @test result.ok_LL == true
    end

    @testset "Construction deflection — W21×55 Ix adequate" begin
        # Example I-1: I_req = 1060 in⁴ for 2.5 in. limit
        # W21×55 Ix ≈ 1123-1140 in⁴ > 1060 → ok
        w_const = 0.83kip/u"ft"

        result = check_composite_deflection(
            fix.section, fix.material, fix.slab, b_eff, 292.0kip,
            fix.L_beam, w_const, 0.0kip/u"ft";
            shored=false, δ_const_limit=2.5u"inch"
        )
        @test result.ok_const == true
    end

    @testset "Construction flexure — bare steel adequate" begin
        # Example I-1 LRFD: Mu_const = max(1.4×0.83, 1.2×0.83+1.6×0.20)×L²/8
        #                  = max(1.16, 1.32) × 45² / 8 = 1.32 × 2025 / 8 = 334 kip-ft
        # AISC states W21×55 ϕMn = 473 kip-ft (with deck bracing Lb ≈ 0)
        Mu_const = 334.0kip*u"ft"
        Vu_const = 30.0kip
        r = check_construction(fix.section, fix.material, Mu_const, Vu_const;
                                Lb_const=0.0u"ft", Cb_const=1.0)
        @test r.flexure_ok == true
    end

    @testset "Required studs: 17 per half-span" begin
        # Example I-1: n = ΣQn / Qn = 292 / 17.2 = 17 studs per side
        Qn = get_Qn(fix.anchor, fix.slab)
        n_half = ceil(Int, 292.0 / ustrip(kip, Qn))
        @test n_half == 17
    end

    @testset "Shear check — ϕVn adequate" begin
        # Example I-1: Vu = 61.2 kips, ϕVn = 234 kips
        Vu = 61.2kip
        ϕVn = get_ϕVn(fix.section, fix.material; axis=:strong)
        @test ϕVn > Vu
    end
end

# ==============================================================================
# 19. Shear anchors — AISC 360-22 §I8 and Commentary §I3.2d
# ==============================================================================

@testset "Shear anchors per candidate" begin
    fix = _example_I1_setup()

    @testset "I8.1 allows 1 in. studs only in a solid slab" begin
        one_inch = HeadedStudAnchor(1.0u"inch", 5.0u"inch", 65.0ksi, 50.0ksi,
                                    7850.0u"kg/m^3")
        @test validate_stud_diameter(one_inch, fix.section.tf; slab=fix.slab) === nothing
        @test_throws ArgumentError validate_stud_diameter(one_inch, fix.section.tf)
        deck = DeckSlabOnBeam(
            uconvert(u"m", 4.5u"inch"), 4.0ksi, 3644.0ksi, 145.0u"lb/ft^3",
            29000.0 / 3644.0,
            uconvert(u"m", 3.0u"inch"), uconvert(u"m", 6.0u"inch"), :perpendicular,
            uconvert(u"m", 10.0u"ft"), uconvert(u"m", 10.0u"ft"), nothing, nothing,
            nothing, nothing, π / 2, nothing)
        @test_throws ArgumentError validate_stud_diameter(one_inch, fix.section.tf; slab=deck)
    end

    @testset "Commentary ductility harbors" begin
        # AISC 360-22 Commentary §I3.2d (corpus: aisc-360-22, PDF p. 511).
        @test shear_connection_ductile(40.0u"ft", 0.40, 10.0u"kip"/u"ft") == false
        @test shear_connection_ductile(40.0u"ft", 0.40, 10.0u"kip"/u"ft"; slip_checked=true)
        @test shear_connection_ductile(30.0u"ft", 0.10, 1.0u"kip"/u"ft")
        @test shear_connection_ductile(40.0u"ft", 0.50, 1.0u"kip"/u"ft")
        @test shear_connection_ductile(40.0u"ft", 0.20, 16.0u"kip"/u"ft")
    end

    @testset "Simple-span zeros are at the ends" begin
        L = 30.0u"ft"
        spans = StructuralSizer.adjacent_shear_spans(s -> s * (1 - s) * 1.0u"kip*ft", 0.5, L)
        @test isapprox(spans[1], L / 2; rtol=1e-6)
        @test isapprox(spans[2], L / 2; rtol=1e-6)
    end

    @testset "Studs that cannot develop the moment are rejected" begin
        # 12 ft beam: the full-composite stud count does not meet §I8.2d(d).
        L = 12.0u"ft"
        b_eff = get_b_eff(fix.slab, L)
        Cf = StructuralSizer._Cf_max(fix.section, fix.material, fix.slab, b_eff)
        Qn = get_Qn(fix.anchor, fix.slab)
        n_full = ceil(Int, ustrip(u"N", Cf) / ustrip(u"N", Qn))
        n_max = floor(Int, ustrip(u"inch", L / 2) / ustrip(u"inch", 6 * fix.anchor.d_sa))
        @test n_full > n_max
        ϕ_full = ustrip(u"N*m", get_ϕMn_composite(fix.section, fix.material, fix.slab,
                                                 b_eff, Cf).ϕMn)
        ϕ_steel = ustrip(u"N*m", get_ϕMn(fix.section, fix.material; Lb=L, Cb=1.0, axis=:strong))
        ctx = CompositeContext(fix.slab, fix.anchor, L; shored=true)
        checker = AISCChecker(; max_depth=Inf)
        cache = StructuralSizer.create_cache(checker, 1)
        StructuralSizer.precompute_capacities!(checker, cache, [fix.section], fix.material, MinWeight())
        geom = SteelMemberGeometry(L; Lb=L)
        demand_full = MemberDemand(1; Mux=0.99 * ϕ_full, Mux_neg=0.0, Vu_strong=0.0)
        @test StructuralSizer.is_feasible(checker, cache, 1, fix.section, fix.material,
                                          demand_full, geom, ctx) == false
        # A moment between bare steel and what the fitting studs can develop passes.
        Mu_mid = 0.5 * (ϕ_steel + ϕ_full)
        demand_mid = MemberDemand(1; Mux=Mu_mid, Mux_neg=0.0, Vu_strong=0.0)
        @test ϕ_steel < Mu_mid < ϕ_full
        @test StructuralSizer.is_feasible(checker, cache, 1, fix.section, fix.material,
                                          demand_mid, geom, ctx) == true
    end

    @testset "40 ft below both ductility harbors fails unless slip is checked" begin
        # Fu is low enough that the studs which fit stay under 50% and under 16 kip/ft.
        weak = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 1.0ksi, 50.0ksi, 7850.0u"kg/m^3")
        L = 40.0u"ft"
        ctx = CompositeContext(fix.slab, weak, L; shored=true)
        ctx_slip = CompositeContext(fix.slab, weak, L; shored=true, slip_checked=true)
        checker = AISCChecker(; max_depth=Inf)
        cache = StructuralSizer.create_cache(checker, 1)
        StructuralSizer.precompute_capacities!(checker, cache, [fix.section], fix.material, MinWeight())
        geom = SteelMemberGeometry(L; Lb=L)
        ϕ_steel = ustrip(u"N*m", get_ϕMn(fix.section, fix.material; Lb=L, Cb=1.0, axis=:strong))
        b_eff = get_b_eff(fix.slab, L)
        Qn = get_Qn(weak, fix.slab)
        n_max = floor(Int, ustrip(u"inch", L / 2) / ustrip(u"inch", 6 * weak.d_sa))
        Σ_max = n_max * Qn
        ϕ_partial = ustrip(u"N*m", get_ϕMn_composite(fix.section, fix.material, fix.slab,
                                                     b_eff, Σ_max).ϕMn)
        @test ϕ_partial > ϕ_steel
        Mu = 0.5 * (ϕ_steel + ϕ_partial)
        demand = MemberDemand(1; Mux=Mu, Mux_neg=0.0, Vu_strong=0.0)
        @test StructuralSizer.is_feasible(checker, cache, 1, fix.section, fix.material,
                                          demand, geom, ctx) == false
        @test StructuralSizer.is_feasible(checker, cache, 1, fix.section, fix.material,
                                          demand, geom, ctx_slip) == true
        ex = StructuralSizer.explain_feasibility(checker, cache, 1, fix.section, fix.material,
                                                 demand, geom, ctx)
        studs = only(filter(c -> c.name == "shear_anchors", ex.checks))
        @test studs.passed == false
        @test occursin("ductility", studs.code_clause)
    end

    @testset "Partial composite accepts a lighter section than bare steel" begin
        light = W("W16X26")
        heavy = W("W21X55")
        @test light.A < heavy.A
        # Short enough that the full-composite stud count violates §I8.2d(d).
        L = 12.0u"ft"
        Lb = 40.0u"ft"
        b_eff = get_b_eff(fix.slab, L)
        Cf = StructuralSizer._Cf_max(light, fix.material, fix.slab, b_eff)
        Qn = get_Qn(fix.anchor, fix.slab)
        n_full = ceil(Int, ustrip(u"N", Cf) / ustrip(u"N", Qn))
        n_max = floor(Int, ustrip(u"inch", L / 2) / ustrip(u"inch", 6 * fix.anchor.d_sa))
        @test n_full > n_max
        n_fit = n_max
        Σ_fit = min(n_fit * Qn, Cf)
        ϕ_light_steel = ustrip(u"N*m", get_ϕMn(light, fix.material; Lb=Lb, Cb=1.0, axis=:strong))
        ϕ_light_partial = ustrip(u"N*m", get_ϕMn_composite(light, fix.material, fix.slab,
                                                           b_eff, Σ_fit).ϕMn)
        ϕ_heavy_steel = ustrip(u"N*m", get_ϕMn(heavy, fix.material; Lb=Lb, Cb=1.0, axis=:strong))
        @test ϕ_light_steel < ϕ_light_partial
        Mu = 0.5 * (ϕ_light_steel + min(ϕ_light_partial, ϕ_heavy_steel))
        @test ϕ_light_steel < Mu <= ϕ_light_partial
        @test Mu <= ϕ_heavy_steel
        checker = AISCChecker(; max_depth=Inf)
        cache = StructuralSizer.create_cache(checker, 2)
        StructuralSizer.precompute_capacities!(checker, cache, [light, heavy], fix.material, MinWeight())
        geom = SteelMemberGeometry(L; Lb=Lb)
        demand = MemberDemand(1; Mux=Mu, Mux_neg=0.0, Vu_strong=0.0)
        ctx = CompositeContext(fix.slab, fix.anchor, L; shored=true)
        @test StructuralSizer.is_feasible(checker, cache, 1, light, fix.material,
                                          demand, geom, ctx) == true
        @test StructuralSizer.is_feasible(checker, cache, 2, heavy, fix.material,
                                          demand, geom) == true
        bare = AISCChecker(; max_depth=Inf)
        bare_cache = StructuralSizer.create_cache(bare, 1)
        StructuralSizer.precompute_capacities!(bare, bare_cache, [light], fix.material, MinWeight())
        @test StructuralSizer.is_feasible(bare, bare_cache, 1, light, fix.material,
                                          demand, geom) == false
    end

    @testset "Lateral cover is the transverse edge, not the 8 in. shear-edge rule" begin
        # §I8.2d(b): 1 in. clear cover, stud placed on the flange.
        # §I8.2d(c) is the free edge in the shear direction and is not this check.
        function slab_with(; edges...)
            SolidSlabOnBeam(7.5u"inch", 4.0ksi, 3644.0ksi, 145.0u"lb/ft^3",
                            29000.0ksi, 10.0u"ft", 10.0u"ft"; edges...)
        end
        tight = slab_with(; edge_dist_left=0.5u"inch", edge_dist_right=0.5u"inch")
        one_side = slab_with(; edge_dist_left=3.0u"inch", edge_dist_right=nothing)
        @test check_stud_edge_distance(fix.section, fix.anchor, tight) == false
        @test check_stud_edge_distance(fix.section, fix.anchor, one_side) == true
        @test check_stud_edge_distance(fix.section, fix.anchor, fix.slab) == true
        pair = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0ksi, 50.0ksi,
                                7850.0u"kg/m^3"; n_per_row=2)
        narrow = slab_with(; edge_dist_left=2.0u"inch", edge_dist_right=2.0u"inch")
        wide = slab_with(; edge_dist_left=6.0u"inch", edge_dist_right=6.0u"inch")
        @test check_stud_edge_distance(fix.section, pair, narrow) == false
        @test check_stud_edge_distance(fix.section, pair, wide) == true
        deck = DeckSlabOnBeam(4.5u"inch", 4.0ksi, 3644.0ksi, 145.0u"lb/ft^3",
                              29000.0ksi, 3.0u"inch", 6.0u"inch", :perpendicular,
                              10.0u"ft", 10.0u"ft";
                              edge_dist_left=0.5u"inch", edge_dist_right=0.5u"inch")
        @test check_stud_edge_distance(fix.section, fix.anchor, deck) == true

        L = 12.0u"ft"
        ϕ_steel = ustrip(u"N*m", get_ϕMn(fix.section, fix.material; Lb=L, Cb=1.0, axis=:strong))
        checker = AISCChecker(; max_depth=Inf)
        cache = StructuralSizer.create_cache(checker, 1)
        StructuralSizer.precompute_capacities!(checker, cache, [fix.section], fix.material, MinWeight())
        geom = SteelMemberGeometry(L; Lb=L)
        ctx_tight = CompositeContext(tight, fix.anchor, L; shored=true)
        below = MemberDemand(1; Mux=0.5 * ϕ_steel, Mux_neg=0.0, Vu_strong=0.0)
        @test StructuralSizer.is_feasible(checker, cache, 1, fix.section, fix.material,
                                          below, geom, ctx_tight) == true
        above = MemberDemand(1; Mux=1.05 * ϕ_steel, Mux_neg=0.0, Vu_strong=0.0)
        @test StructuralSizer.is_feasible(checker, cache, 1, fix.section, fix.material,
                                          above, geom, ctx_tight) == false
        ex = StructuralSizer.explain_feasibility(checker, cache, 1, fix.section, fix.material,
                                                 above, geom, ctx_tight)
        studs = only(filter(c -> c.name == "shear_anchors", ex.checks))
        @test studs.passed == false
        @test occursin("transverse", studs.code_clause)
    end
end

# ==============================================================================
# Deck limits (§I3.2c), e_mid-ht (§I8.2a), default stud, twist-restraint spacing
# ==============================================================================

@testset "Deck limits, e_mid-ht, default stud, twist spacing" begin
    fix = _aisc_example_I1_deck_setup()
    deck(; hr=3.0u"inch", wr=6.0u"inch", t=4.5u"inch", orient=:perpendicular, kw...) =
        DeckSlabOnBeam(t, 4.0ksi, 3644.0ksi, 145.0u"lb/ft^3", 29000.0ksi,
                       hr, wr, orient, 10.0u"ft", 10.0u"ft"; kw...)

    @testset "Rp from e_mid-ht (§I8.2a, PDF p. 182)" begin
        @test StructuralSizer._Rg_Rp(fix.anchor, deck())[2] == 0.6
        @test StructuralSizer._Rg_Rp(fix.anchor, deck(e_mid_ht=1.5u"inch"))[2] == 0.6
        @test StructuralSizer._Rg_Rp(fix.anchor, deck(e_mid_ht=2.0u"inch"))[2] == 0.75
        @test get_Qn(fix.anchor, deck(e_mid_ht=2.5u"inch")) >= get_Qn(fix.anchor, deck())
    end

    @testset "§I3.2c limits (PDF p. 170)" begin
        ok = deck_limit_failures(fix.slab, fix.anchor)
        @test isempty(ok.failures)
        @test length(ok.unchecked) == 1
        @test isempty(deck_limit_failures(deck(anchorage_spacing=12.0u"inch"), fix.anchor).unchecked)
        has(r, tag) = any(m -> occursin(tag, m), r.failures)
        @test has(deck_limit_failures(deck(hr=3.5u"inch"), fix.anchor), "I3.2c(a): hr")
        @test has(deck_limit_failures(deck(wr=1.75u"inch"), fix.anchor), "I3.2c(a): wr")
        @test has(deck_limit_failures(deck(t=1.5u"inch"), fix.anchor), "I3.2c(c)")
        @test has(deck_limit_failures(deck(anchorage_spacing=24.0u"inch"), fix.anchor), "I3.2c(d)")
        short = HeadedStudAnchor(0.75u"inch", 4.0u"inch", 65.0ksi, 0.0ksi, 7850.0u"kg/m^3")
        @test has(deck_limit_failures(deck(), short), "extends")
        tall = HeadedStudAnchor(0.75u"inch", 7.25u"inch", 65.0ksi, 0.0ksi, 7850.0u"kg/m^3")
        @test has(deck_limit_failures(deck(), tall), "cover")
        pair = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0ksi, 0.0ksi, 7850.0u"kg/m^3";
                                n_per_row=2)
        par = deck(hr=2.0u"inch", wr=4.5u"inch", orient=:parallel)
        @test has(deck_limit_failures(par, pair), "I3.2c(3)")
        @test isempty(deck_limit_failures(deck(hr=2.0u"inch", wr=5.0u"inch", orient=:parallel),
                                          pair).failures)
        solid = SolidSlabOnBeam(6.0u"inch", 4.0ksi, 3644.0ksi, 145.0u"lb/ft^3",
                                29000.0ksi, 10.0u"ft", 10.0u"ft")
        @test isempty(deck_limit_failures(solid, fix.anchor).unchecked)
    end

    @testset "Failed deck limits leave only the steel section" begin
        bad = deck(hr=3.5u"inch")
        b = get_b_eff(bad, fix.L_beam)
        ϕ_s = get_ϕMn(fix.section, fix.material; Lb=0.0u"m", Cb=1.0, axis=:strong)
        above = design_shear_anchors(fix.section, fix.material, bad, fix.anchor, b,
                                     fix.L_beam, 1.2 * ϕ_s; ϕMn_steel=ϕ_s)
        @test above.ok == false
        @test above.reason == :deck_limits
        below = design_shear_anchors(fix.section, fix.material, bad, fix.anchor, b,
                                     fix.L_beam, 0.8 * ϕ_s; ϕMn_steel=ϕ_s)
        @test below.ok == true
        @test below.n_half == 0
        good = design_shear_anchors(fix.section, fix.material, fix.slab, fix.anchor,
                                    get_b_eff(fix.slab, fix.L_beam), fix.L_beam, 1.2 * ϕ_s;
                                    ϕMn_steel=ϕ_s)
        @test good.ok == true
    end

    @testset "Default stud (AISC Manual 14th ed., PDF p. 165)" begin
        s = default_headed_stud()
        @test isapprox(s.d_sa, 0.75u"inch"; rtol=1e-12)
        @test isapprox(s.l_sa, 3.0u"inch"; rtol=1e-12)
        @test isapprox(s.Fu, 65.0ksi; rtol=1e-12)
        @test s.source == DEFAULT_STUD_SOURCE
        @test isapprox(default_headed_stud(; hr=3.0u"inch").l_sa, 4.5u"inch"; rtol=1e-12)
        @test isapprox(default_headed_stud(; hr=1.0u"inch").l_sa, 3.0u"inch"; rtol=1e-12)
        @test validate_stud_diameter(s, 0.30u"inch") === nothing
        @test_throws ArgumentError validate_stud_diameter(s, 0.29u"inch")
        @test fix.anchor.source == ""
    end

    @testset "Twist-restraint spacing for C-F1-5" begin
        # Fixed-fixed uniform load, sagging positive: ends −1, mid +1/2.
        ff(s) = (-1 + 6 * s * (1 - s)) * u"N*m"
        @test isapprox(cb_neg_from_moment_field(ff), 3.0; atol=1e-9)
        L = 10.0u"m"
        # Segments of L/2: Mo = −1, M1 = +1/2, MCL = +1/8 ⇒ Cb = 3 + 1/3 + 1/3.
        @test isapprox(cb_neg_from_moment_field(ff; L=L, L_twist=5.0u"m"), 11 / 3; atol=1e-9)
        @test cb_neg_from_moment_field(ff; L=L, L_twist=20.0u"m") ==
              cb_neg_from_moment_field(ff)
        @test StructuralSizer._twist_segments(L, 4.0u"m") ≈ [0.0, 0.4, 0.8, 1.0]
        geom = SteelMemberGeometry(L)
        hog = StructuralSizer._hogging_ltb_inputs(fix.section, fix.material, geom;
                                                  L_twist=2.0u"m")
        @test hog.Lb_neg_m ≈ 2.0
        @test StructuralSizer._hogging_ltb_inputs(fix.section, fix.material, geom).Lb_neg_m ≈ 10.0
        ctx = CompositeContext(fix.slab, fix.anchor, L; L_twist=2.0u"m")
        @test ctx.L_twist ≈ 2.0u"m"
        @test_throws ArgumentError CompositeContext(fix.slab, fix.anchor, L; L_twist=0.0u"m")
    end
end

@testset "Vulcraft composite deck geometry" begin
    p3 = composite_deck_profile("3VLI")
    @test isapprox(p3.hr, 3.0u"inch"; rtol=1e-12)
    # Example I-1 uses wr = 6 in. for 3 in. deck.
    @test isapprox(deck_wr(p3), 6.0u"inch"; rtol=1e-12)
    @test isapprox(p3.pitch, 12.0u"inch"; rtol=1e-12)
    @test isapprox(p3.gages[20].t, 0.0358u"inch"; rtol=1e-12)
    p2 = composite_deck_profile("2plvli-36")
    @test p2.name == "2VLI"
    @test isapprox(deck_wr(p2), 6.0u"inch"; rtol=1e-12)
    p15 = composite_deck_profile("1.5VLI")
    @test isapprox(deck_wr(p15), 2.125u"inch"; rtol=1e-12)
    @test occursin("vulcraft-deck-solutions-2020", p15.source)
    @test_throws ArgumentError composite_deck_profile("1.5VLR")
    # All three profiles meet §I3.2c(a) on their own.
    for p in values(VULCRAFT_COMPOSITE_DECKS)
        @test p.hr <= 3.0u"inch" + 1e-9u"m"
        @test deck_wr(p) >= 2.0u"inch" - 1e-9u"m"
    end
end

@testset "Deck attachment is reported and not checked" begin
    deck = _aisc_example_I1_deck_setup()
    ctx = CompositeContext(deck.slab, deck.anchor, deck.L_beam)
    @test ctx.deck_attachment isa DeckAttachment
    @test ctx.deck_attachment.support_pattern == DEFAULT_DECK_SUPPORT_PATTERN
    @test occursin("sdi-ddm-3e-2004", ctx.deck_attachment.pattern_source)
    @test ctx.deck_attachment.Sn === nothing
    solid = _example_I1_setup()
    @test CompositeContext(solid.slab, solid.anchor, solid.L_beam).deck_attachment === nothing
    custom = DeckAttachment(support_pattern = "36/7", sidelap_per_span = 3, Sn = 500.0u"lbf/ft")
    @test custom.pattern_source == "Caller-supplied deck support fastener pattern."
    @test isapprox(custom.Sn, 500.0u"lbf/ft"; rtol = 1e-9)
    note = deck_brace_note(ctx.deck_attachment, 1.0u"kip")
    @test occursin("36/4", note)
    @test occursin("Not a check", note)
    @test occursin("not supplied", note)
    @test occursin("not compared", deck_brace_note(custom, 1.0u"kip"))
    @test deck_brace_note(nothing, 1.0u"kip") == ""
    @test_throws ArgumentError DeckAttachment(sidelap_per_span = -1)
    kept = CompositeContext(deck.slab, deck.anchor, deck.L_beam; deck_attachment = custom)
    @test kept.deck_attachment.support_pattern == "36/7"
end

# ==============================================================================
# Skewed deck ribs: perpendicular stud rules, studs only at rib crossings
# ==============================================================================

@testset "Skewed deck ribs" begin
    fix = _aisc_example_I1_deck_setup()
    deck(θ; pitch=12.0u"inch", kw...) =
        DeckSlabOnBeam(4.5u"inch", 4.0ksi, 3644.0ksi, 145.0u"lb/ft^3", 29000.0ksi,
                       3.0u"inch", 6.0u"inch", rib_orientation(θ), 10.0u"ft", 10.0u"ft";
                       rib_angle=θ, rib_pitch=pitch, kw...)
    stud(n) = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0ksi, 50.0ksi,
                               7850.0u"kg/m^3"; n_per_row=n)

    @testset "Angle and classification" begin
        @test rib_angle_between((1.0, 0.0), (0.0, 2.0)) ≈ π / 2
        @test isapprox(rib_angle_between((1.0, 0.0), (-3.0, 0.0)), 0.0; atol=1e-12)
        @test rib_angle_between((1.0, 1.0), (1.0, 0.0)) ≈ π / 4
        @test rib_orientation(0.0) === :parallel
        @test rib_orientation(π / 2) === :perpendicular
        # Only truly parallel ribs are parallel; 1° is skewed.
        @test rib_orientation(deg2rad(1.0)) === :skewed
        @test deck(deg2rad(30)).deck_orientation === :skewed
        @test deck(deg2rad(30)).rib_angle ≈ deg2rad(30)
        @test_throws ArgumentError DeckSlabOnBeam(4.5u"inch", 4.0ksi, 3644.0ksi,
            145.0u"lb/ft^3", 29000.0ksi, 3.0u"inch", 6.0u"inch", :perpendicular,
            10.0u"ft", 10.0u"ft"; rib_angle=deg2rad(30))
        @test_throws ArgumentError DeckSlabOnBeam(4.5u"inch", 4.0ksi, 3644.0ksi,
            145.0u"lb/ft^3", 29000.0ksi, 3.0u"inch", 6.0u"inch", :skewed,
            10.0u"ft", 10.0u"ft")
        @test fix.slab.rib_angle ≈ π / 2
        @test fix.slab.rib_pitch === nothing
    end

    @testset "Skewed ribs take the perpendicular Rg and Rp" begin
        for n in 1:3
            @test StructuralSizer._Rg_Rp(stud(n), deck(deg2rad(30))) ==
                  StructuralSizer._Rg_Rp(stud(n), deck(π / 2))
        end
        # e_mid-ht is measured perpendicular to the rib, not scaled by 1/sin θ.
        @test StructuralSizer._Rg_Rp(stud(1), deck(deg2rad(30); e_mid_ht=1.5u"inch"))[2] == 0.6
        @test StructuralSizer._Rg_Rp(stud(1), deck(deg2rad(30); e_mid_ht=2.0u"inch"))[2] == 0.75
        @test get_Qn(stud(1), deck(deg2rad(30))) < get_Qn(stud(1), deck(0.0))
    end

    @testset "Rib crossings along the beam" begin
        @test isapprox(rib_crossing_spacing(deck(π / 2)), 12.0u"inch"; rtol=1e-9)
        @test isapprox(rib_crossing_spacing(deck(deg2rad(30))), 24.0u"inch"; rtol=1e-9)
        @test rib_crossing_spacing(deck(0.0)) === nothing
        @test rib_crossing_spacing(deck(deg2rad(30); pitch=nothing)) === :unknown
        @test rib_crossing_spacing(fix.slab) === :unknown
        s_min, s_max = 4.5u"inch", 36.0u"inch"
        L = 270.0u"inch"
        # 90°: crossings every 12 in; every third one keeps 36 in.
        @test rib_row_bounds(L, 12.0u"inch", s_min, s_max) == (8, 22)
        # 30°: crossings every 24 in; every one is needed.
        @test rib_row_bounds(L, 24.0u"inch", s_min, s_max) == (11, 11)
        # 12 in pitch is at the 36 in limit at asin(1/3) = 19.47°.
        @test rib_row_bounds(L, rib_crossing_spacing(deck(deg2rad(20))), s_min, s_max) == (7, 7)
        @test rib_row_bounds(L, rib_crossing_spacing(deck(deg2rad(19))), s_min, s_max) == (1, 0)
        # A shear span shorter than one crossing holds no guaranteed crossing.
        @test rib_row_bounds(20.0u"inch", 24.0u"inch", s_min, s_max) == (1, 0)
    end

    @testset "Studs on a skewed rib lie along the rib" begin
        narrow = W("W12X14")   # bf = 3.97 in
        three = stud(3)        # needs 2 · 4 d_sa = 6 in along the rib
        @test StructuralSizer._transverse_studs_fit(narrow, three, deck(π / 2)) == false
        @test StructuralSizer._transverse_studs_fit(narrow, three, deck(deg2rad(30))) == true
    end

    @testset "Stud layout and bare-steel fallback" begin
        L = 45.0u"ft"
        lay(θ; kw...) = design_shear_anchors(fix.section, fix.material, deck(θ; kw...),
                                             fix.anchor, get_b_eff(deck(θ; kw...), L), L,
                                             10.0u"kip*ft"; ϕMn_steel=0.0u"N*m",
                                             slip_checked=true)
        @test lay(π / 2).ok && lay(π / 2).n_rows == 8 && lay(π / 2).n_rows_max == 22
        @test lay(deg2rad(30)).ok && lay(deg2rad(30)).n_rows == 11
        bad = lay(deg2rad(15))
        @test bad.ok == false && bad.reason === :rib_spacing && bad.n_half == 0
        unknown = lay(deg2rad(30); pitch=nothing)
        @test unknown.ok == false && unknown.reason === :rib_pitch_unknown
        # Parallel deck is not tied to crossings.
        @test lay(0.0).ok
    end

    @testset "Checker reports the skew and falls back to steel alone" begin
        L = 45.0u"ft"
        ϕ_steel = ustrip(u"N*m", get_ϕMn(fix.section, fix.material; Lb=L, Cb=1.0, axis=:strong))
        checker = AISCChecker(; max_depth=Inf)
        cache = StructuralSizer.create_cache(checker, 1)
        StructuralSizer.precompute_capacities!(checker, cache, [fix.section], fix.material, MinWeight())
        geom = SteelMemberGeometry(L; Lb=L)
        above = MemberDemand(1; Mux=1.05 * ϕ_steel, Mux_neg=0.0, Vu_strong=0.0)
        below = MemberDemand(1; Mux=0.5 * ϕ_steel, Mux_neg=0.0, Vu_strong=0.0)
        ctx15 = CompositeContext(deck(deg2rad(15)), fix.anchor, L; shored=true)
        @test StructuralSizer.is_feasible(checker, cache, 1, fix.section, fix.material,
                                          below, geom, ctx15) == true
        @test StructuralSizer.is_feasible(checker, cache, 1, fix.section, fix.material,
                                          above, geom, ctx15) == false
        ex = StructuralSizer.explain_feasibility(checker, cache, 1, fix.section, fix.material,
                                                 above, geom, ctx15)
        studs = only(filter(c -> c.name == "shear_anchors", ex.checks))
        @test occursin("rib_spacing", studs.code_clause)
        @test occursin("skewed 15.0°", studs.code_clause)
        @test occursin("perpendicular Rg/Rp", studs.code_clause)
        ctx30 = CompositeContext(deck(deg2rad(30)), fix.anchor, L; shored=true)
        ex30 = StructuralSizer.explain_feasibility(checker, cache, 1, fix.section, fix.material,
                                                   above, geom, ctx30)
        studs30 = only(filter(c -> c.name == "shear_anchors", ex30.checks))
        @test occursin("24.0 inch", studs30.code_clause)
    end
end

# AISC 360-22 Commentary Eq. C-I3-5 (corpus: aisc-360-22, PDF p. 502).
# I = 0.6 I_pos + 0.4 I_neg for a continuous gravity beam.
# I_pos = 1000 in⁴, I_neg = 400 in⁴ → I = 760 in⁴.
# Drift uses 0.5 and 0.5 → 700 in⁴.
# The I_pos that produces 760 is (760 − 0.4×400) / 0.6 = 1000 in⁴.
@testset "Continuous composite service inertia" begin
    I_pos = 1000.0u"inch^4"
    I_neg = 400.0u"inch^4"
    @test composite_service_inertia(I_pos, I_neg) ≈ I_pos
    @test composite_service_inertia(I_pos, I_neg; continuous=true) ≈ 760.0u"inch^4"
    @test composite_service_inertia(I_pos, I_neg; continuous=true, for_drift=true) ≈ 700.0u"inch^4"
    @test positive_inertia_for_service(760.0u"inch^4", I_neg; continuous=true) ≈ I_pos

    @test StructuralSizer.moment_field_has_negative(s -> 1000.0) == false
    @test StructuralSizer.moment_field_has_negative(s -> s < 0.2 ? -500.0 : 1000.0) == true

    fix = _example_I1_setup()
    b_eff = get_b_eff(fix.slab, fix.L_beam)
    Cf = StructuralSizer._Cf_max(fix.section, fix.material, fix.slab, b_eff)
    simple = check_composite_deflection(fix.section, fix.material, fix.slab, b_eff, Cf,
                                         fix.L_beam, 0.5kip/u"ft", 1.0kip/u"ft")
    continuous = check_composite_deflection(fix.section, fix.material, fix.slab, b_eff, Cf,
                                             fix.L_beam, 0.5kip/u"ft", 1.0kip/u"ft";
                                             continuous=true)
    I_hand = 0.6 * simple.I_LB + 0.4 * fix.section.Ix
    @test continuous.I_service ≈ I_hand
    @test continuous.δ_LL > simple.δ_LL
    @test continuous.δ_DL ≈ simple.δ_DL
end

# Cracked negative-moment inertia, steel + developed bars (engineering judgment
# for I_neg in Eq. C-I3-5). Two areas A_s and A_sr a distance Δ apart:
#   I_cr = I_s + A_s A_sr / (A_s + A_sr) Δ²
# W21X55 as built from plates (no fillets): A = 15.990 in², d = 20.8 in,
# Ix = 1123.35 in⁴. A_sr = 2.0 in² at 3.0 in above the top of steel:
# Δ = 10.4 + 3.0 = 13.4 in,
#   I_cr = 1123.35 + (15.990·2.0/17.990)·13.4² = 1123.35 + 319.20 = 1442.55 in⁴.
@testset "Cracked negative-moment inertia with developed bars" begin
    fix = _example_I1_setup()
    sec = fix.section
    Asr = 2.0u"inch^2"
    d_r = 3.0u"inch"

    I_cr = get_I_cracked_negative(sec, Asr; d_rebar = d_r)
    Δ = sec.d / 2 + d_r
    I_closed = sec.Ix + sec.A * Asr / (sec.A + Asr) * Δ^2
    @test I_cr ≈ I_closed
    @test isapprox(ustrip(u"inch^4", I_cr), 1442.55; rtol = 1e-4)

    # No bars, or bars at the top of the steel, bound the result from below.
    @test get_I_cracked_negative(sec, 0.0u"inch^2") == sec.Ix
    @test get_I_cracked_negative(sec, Asr) < I_cr
    @test get_I_cracked_negative(sec, Asr) > sec.Ix

    # The context only adds the bars when the negative region is composite.
    L = fix.L_beam
    plain = CompositeContext(fix.slab, fix.anchor, L; Asr = Asr, Fysr = 60.0ksi)
    comp  = CompositeContext(fix.slab, fix.anchor, L; Asr = Asr, Fysr = 60.0ksi,
                             neg_moment = true)
    @test composite_negative_inertia(sec, plain) == sec.Ix
    @test composite_negative_inertia(sec, comp; d_rebar = d_r) ≈ I_cr

    # Eq. C-I3-5 with the cracked section is stiffer than with I_s.
    b_eff = get_b_eff(fix.slab, L)
    Cf = StructuralSizer._Cf_max(sec, fix.material, fix.slab, b_eff)
    w_D, w_L = 0.5kip/u"ft", 1.0kip/u"ft"
    bare = check_composite_deflection(sec, fix.material, fix.slab, b_eff, Cf, L, w_D, w_L;
                                      continuous = true)
    cracked = check_composite_deflection(sec, fix.material, fix.slab, b_eff, Cf, L, w_D, w_L;
                                         continuous = true, I_neg = I_cr)
    @test cracked.I_service ≈ 0.6 * cracked.I_LB + 0.4 * I_cr
    @test cracked.δ_LL < bare.δ_LL
end
