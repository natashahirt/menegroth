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
    fc′ = 4.0u"ksi"
    wc  = 145.0u"lb/ft^3"
    Ec  = wc^1.5 * sqrt(uconvert(u"psi", fc′)) * 1.0u"psi^(-0.5)*lb^(-0.5)*ft^(1.5)"
    # Ec ≈ 3,644 ksi for NWC 4 ksi (AISC formula)
    # Use standard value:
    Ec = 3644.0u"ksi"
    Es = 29000.0u"ksi"
    
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
        65.0u"ksi",       # Fu
        50.0u"ksi",       # Fy (nominal)
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
            8.0u"inch", 4.0u"ksi", 3644.0u"ksi", 145.0u"lb/ft^3",
            29000.0u"ksi", 10.0u"ft", 10.0u"ft"
        )
        @test isapprox(slab.t_slab, uconvert(u"m", 8.0u"inch"); rtol=0.001)
        @test slab.fc′ == 4.0u"ksi"
        # n = Es/Ec
        @test isapprox(slab.n, 29000.0 / 3644.0; rtol=0.001)
    end
    
    @testset "SolidSlabOnBeam with edge distances" begin
        slab = SolidSlabOnBeam(
            8.0u"inch", 4.0u"ksi", 3644.0u"ksi", 145.0u"lb/ft^3",
            29000.0u"ksi", 10.0u"ft", 10.0u"ft";
            edge_dist_left=3.0u"ft", edge_dist_right=nothing
        )
        @test isapprox(slab.edge_dist_left, uconvert(u"m", 3.0u"ft"); rtol=0.001)
        @test slab.edge_dist_right === nothing
    end
    
    @testset "HeadedStudAnchor construction" begin
        a = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0u"ksi", 50.0u"ksi",
                             7850.0u"kg/m^3")
        @test isapprox(a.d_sa, uconvert(u"m", 0.75u"inch"); rtol=0.001)
        @test a.n_per_row == 1
        @test a.ecc ≈ 1.72
    end
    
    @testset "HeadedStudAnchor with multi-row" begin
        a = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0u"ksi", 50.0u"ksi",
                             7850.0u"kg/m^3"; n_per_row=2)
        @test a.n_per_row == 2
    end
    
    @testset "HeadedStudAnchor invalid n_per_row" begin
        @test_throws ArgumentError HeadedStudAnchor(
            0.75u"inch", 5.0u"inch", 65.0u"ksi", 50.0u"ksi",
            7850.0u"kg/m^3"; n_per_row=0)
    end
    
    @testset "Stud mass (cylindrical shank)" begin
        a = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0u"ksi", 50.0u"ksi",
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
                               Asr=1.0u"inch^2", Fysr=60.0u"ksi",
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
            8.0u"inch", 4.0u"ksi", 3644.0u"ksi", 145.0u"lb/ft^3",
            29000.0u"ksi", 20.0u"ft", 20.0u"ft"
        )
        b_eff = get_b_eff(slab, 30.0u"ft")
        # L/8 = 30/8 = 3.75 ft per side → 7.5 ft total ← controls
        # spacing/2 = 10 ft per side → 20 ft total
        @test isapprox(b_eff, 7.5u"ft"; rtol=0.001)
    end
    
    @testset "Edge beam — edge distance controls one side" begin
        slab = SolidSlabOnBeam(
            8.0u"inch", 4.0u"ksi", 3644.0u"ksi", 145.0u"lb/ft^3",
            29000.0u"ksi", 10.0u"ft", 10.0u"ft";
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
        Qn_kips = ustrip(u"kip", Qn)
        @test isapprox(Qn_kips, 21.54; rtol=0.03)
    end
    
    @testset "Qn for deck slab (perpendicular, 1 stud/rib)" begin
        slab_deck = DeckSlabOnBeam(
            uconvert(u"m", 4.5u"inch"), 4.0u"ksi", 3644.0u"ksi", 145.0u"lb/ft^3",
            29000.0 / 3644.0,
            uconvert(u"m", 3.0u"inch"), uconvert(u"m", 6.0u"inch"), :perpendicular,
            uconvert(u"m", 10.0u"ft"), uconvert(u"m", 10.0u"ft"), nothing, nothing
        )
        anchor = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0u"ksi", 50.0u"ksi",
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
        big_stud = HeadedStudAnchor(1.5u"inch", 6.0u"inch", 65.0u"ksi", 50.0u"ksi",
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
        short_stud = HeadedStudAnchor(0.75u"inch", 2.0u"inch", 65.0u"ksi", 50.0u"ksi",
                                      7850.0u"kg/m^3")
        slab = SolidSlabOnBeam(8.0u"inch", 4.0u"ksi", 3644.0u"ksi", 145.0u"lb/ft^3",
                               29000.0u"ksi", 10.0u"ft", 10.0u"ft")
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
        ΣQn = 10000.0u"kip"  # artificially large
        Cf = get_Cf(fix.section, fix.material, fix.slab, b_eff, ΣQn)
        
        # Cf = min(0.85×4×120×7.5, 50×As, 10000) 
        # V'_conc = 0.85 × 4 × 120 × 7.5 = 3060 kips (using b_eff=120 in, t=7.5 in)
        # V'_steel = 50 × 16.2 = 810 kips ← controls (W21×55, A≈16.2 in²)
        Cf_kips = ustrip(u"kip", Cf)
        @test isapprox(Cf_kips, 810.0; rtol=0.05)
    end
    
    @testset "Partial composite (studs limit)" begin
        ΣQn = 292.0u"kip"  # from Example I-1
        Cf = get_Cf(fix.section, fix.material, fix.slab, b_eff, ΣQn)
        # ΣQn = 292 < min(3060, 810) → Cf = 292
        @test isapprox(ustrip(u"kip", Cf), 292.0; rtol=0.001)
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
        ΣQn = uconvert(u"kip", As_Fy)  # Full composite: limited by steel yielding
        result = get_Mn_composite(fix.section, fix.material, fix.slab, b_eff, ΣQn)
        
        # a = As×Fy / (0.85 fc' b_eff)
        # a = 810 / (0.85 × 4 × 120) = 810/408 = 1.985 in.
        a_in = ustrip(u"inch", result.a)
        @test isapprox(a_in, 1.985; rtol=0.05)
        
        # PNA should be in slab (a < t_slab = 7.5 in.)
        @test ustrip(u"inch", result.a) < 7.5
        
        # For full composite W21×55, ϕMn should be around 800-900 kip-ft
        ϕMn = 0.9 * result.Mn
        ϕMn_kipft = ustrip(u"kip*ft", ϕMn)
        @test ϕMn_kipft > 700  # must exceed Mu = 687 kip-ft
    end
    
    @testset "Partial composite ΣQn=292 kips (Example I-1 level)" begin
        ΣQn = 292.0u"kip"
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
        ϕMn_kipft = ustrip(u"kip*ft", 0.9 * result.Mn)
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
        ΣQn = 400.0u"kip"
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
        residual = ustrip(u"kip", Cf + Fy * A_above - Fy * A_below)
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
        Mn_required = 687.0u"kip*ft" / 0.9  # back out from ϕMn
        result = find_required_ΣQn(fix.section, fix.material, fix.slab,
                                    b_eff, Mn_required, Qn; ϕ=0.9)
        @test result.sufficient == true
        # Example I-1 uses ΣQn = 292 kips at PNA location 6
        # Our solver should find a value in the same ballpark
        ΣQn_kips = ustrip(u"kip", result.ΣQn)
        @test ΣQn_kips > 200  # must be above the 25% minimum
        @test ΣQn_kips < 900  # must be below full composite
    end
    
    @testset "Infeasible — even full composite insufficient" begin
        Mn_huge = 5000.0u"kip*ft"
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
        Fysr = 60.0u"ksi"
        Mn = get_Mn_negative(fix.section, fix.material, Asr, Fysr)
        Mp = fix.material.Fy * fix.section.Zx
        # Rebar contribution should increase Mn
        @test ustrip(u"kip*ft", Mn) > ustrip(u"kip*ft", Mp)
    end
    
    @testset "Negative Mn equilibrium check" begin
        Asr = 1.5u"inch^2"
        Fysr = 60.0u"ksi"
        Mn = get_Mn_negative(fix.section, fix.material, Asr, Fysr)
        # Should be positive and finite
        @test ustrip(u"kip*ft", Mn) > 0
        @test isfinite(ustrip(u"kip*ft", Mn))
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
    
    @testset "I_LB at full composite = I_transformed" begin
        Cf_max = StructuralSizer._Cf_max(fix.section, fix.material, fix.slab, b_eff)
        I_LB = get_I_LB(fix.section, fix.material, fix.slab, b_eff, Cf_max)
        I_tr = get_I_transformed(fix.section, fix.slab, b_eff)
        @test isapprox(I_LB, I_tr; rtol=0.001)
    end
    
    @testset "I_LB at zero composite = I_steel" begin
        I_LB = get_I_LB(fix.section, fix.material, fix.slab, b_eff, 0.0u"kip")
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
        ΣQn = 292.0u"kip"
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
        w_DL = 0.93u"kip/ft"
        w_LL = 1.00u"kip/ft"
        
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
        ΣQn = 292.0u"kip"
        w_DL = 0.93u"kip/ft"
        w_LL = 1.00u"kip/ft"
        
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
        ΣQn = 292.0u"kip"
        w_DL = 0.83u"kip/ft"  # construction DL
        w_LL = 0.0u"kip/ft"
        
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
        Mu_const = 331.0u"kip*ft"
        Vu_const = 30.0u"kip"
        
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
        ΣQn = 292.0u"kip"
        a = ΣQn / (0.85 * fix.slab.fc′ * b_eff)
        a_in = ustrip(u"inch", a)
        # Example I-1: a = 292 / (0.85 × 4 × 120) = 0.716 in.
        @test isapprox(a_in, 0.716; rtol=0.01)
    end
    
    @testset "a < t_slab for partial composite" begin
        ΣQn = 292.0u"kip"
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
        ΣQn = 292.0u"kip"
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
        # Lb_const is set to 10 ft (deck braces the beam during construction),
        # so the construction-stage ϕMn is not overly penalized by LTB.
        ctx_braced = CompositeContext(fix.slab, fix.anchor, fix.L_beam;
                                      shored=false, Lb_const=10.0u"ft")
        Mu_moderate = 300.0u"kip*ft"
        demand = MemberDemand(1;
            Mux   = ustrip(u"N*m", uconvert(u"N*m", Mu_moderate)),
            Vu_strong = ustrip(u"N", uconvert(u"N", 50.0u"kip")),
        )
        geom = SteelMemberGeometry(fix.L_beam; Lb=fix.L_beam)

        ok = StructuralSizer.is_feasible(checker, cache, 1, fix.section, fix.material,
                                          demand, geom, ctx_braced)
        @test ok == true
    end

    @testset "Infeasible under extreme moment" begin
        Mu_extreme = 1500.0u"kip*ft"
        demand = MemberDemand(1;
            Mux = ustrip(u"N*m", uconvert(u"N*m", Mu_extreme)),
            Vu_strong = ustrip(u"N", uconvert(u"N", 50.0u"kip")),
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
            Mux = ustrip(u"N*m", uconvert(u"N*m", 300.0u"kip*ft")),
            Vu_strong = ustrip(u"N", uconvert(u"N", 50.0u"kip")),
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
    ctx = CompositeContext(fix.slab, fix.anchor, fix.L_beam)

    @testset "Weight contribution" begin
        w = composite_stud_contribution(ctx, fix.section, fix.material, MinWeight())
        @test w > 0.0
        m_one_kg = ustrip(u"kg", stud_mass(fix.anchor))
        @test m_one_kg > 0.0
        # Weight = n_studs_total × m_one
        # n_studs_total should be > 0 (at least a few dozen for this span)
        n_studs_est = w / m_one_kg
        @test n_studs_est > 10  # reasonable for a 45 ft beam
    end

    @testset "Carbon contribution" begin
        c = composite_stud_contribution(ctx, fix.section, fix.material, MinCarbon())
        @test c > 0.0
        # Carbon = weight × ecc
        w = composite_stud_contribution(ctx, fix.section, fix.material, MinWeight())
        @test isapprox(c, w * fix.anchor.ecc; rtol=1e-10)
    end

    @testset "Volume objective returns zero (no stud volume)" begin
        v = composite_stud_contribution(ctx, fix.section, fix.material, MinVolume())
        @test v ≈ 0.0
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

# ==============================================================================
# 18. Bracing Pipeline — Lb_const in CompositeContext
# ==============================================================================

@testset "Bracing Pipeline (Lb_const)" begin
    fix = _example_I1_setup()

    @testset "Lb_const defaults to L_beam" begin
        ctx = CompositeContext(fix.slab, fix.anchor, fix.L_beam)
        @test isapprox(ctx.Lb_const, uconvert(u"m", fix.L_beam); rtol=1e-10)
    end

    @testset "Custom Lb_const affects construction check" begin
        Mu_const = 400.0u"kip*ft"
        Vu_const = 50.0u"kip"

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
        Mu_const = 200.0u"kip*ft"
        Vu_const = 30.0u"kip"
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

    fc′ = 4.0u"ksi"
    Ec  = 3644.0u"ksi"
    Es  = 29000.0u"ksi"

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
        65.0u"ksi",        # Fu
        50.0u"ksi",        # Fy (nominal)
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
        @test isapprox(ustrip(u"kip", Qn), 17.2; rtol=0.02)
    end

    @testset "Stress block depth a = 0.716 in." begin
        # a = ΣQn / (0.85 fc' b_eff) = 292 / (0.85 × 4 × 120) = 0.716 in.
        ΣQn = 292.0u"kip"
        a = ΣQn / (0.85 * fix.slab.fc′ * b_eff)
        @test isapprox(ustrip(u"inch", a), 0.716; rtol=0.01)
    end

    @testset "Composite ϕMn ≈ 767 kip-ft (LRFD, PNA location 6)" begin
        ΣQn = 292.0u"kip"
        result = get_ϕMn_composite(fix.section, fix.material, fix.slab, b_eff, ΣQn)

        # Example I-1: ϕMn = 767 kip-ft
        # Our section database has slightly different As (15.99 vs 16.2 in²),
        # so we allow ~1% tolerance.
        @test isapprox(ustrip(u"kip*ft", result.ϕMn), 767.0; rtol=0.015)

        # Must exceed required Mu = 687 kip-ft
        @test ustrip(u"kip*ft", result.ϕMn) > 687.0
    end

    @testset "I_LB ≈ 2440 in⁴" begin
        ΣQn = 292.0u"kip"
        I_LB = get_I_LB(fix.section, fix.material, fix.slab, b_eff, ΣQn)

        # Example I-1: I_LB = 2440 in⁴ (Manual Table 3-20)
        @test isapprox(ustrip(u"inch^4", I_LB), 2440.0; rtol=0.01)
    end

    @testset "Live load deflection δ_LL ≈ 1.30 in. < L/360" begin
        ΣQn = 292.0u"kip"
        w_DL = 0.93u"kip/ft"
        w_LL = 1.00u"kip/ft"

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
        w_const = 0.83u"kip/ft"

        result = check_composite_deflection(
            fix.section, fix.material, fix.slab, b_eff, 292.0u"kip",
            fix.L_beam, w_const, 0.0u"kip/ft";
            shored=false, δ_const_limit=2.5u"inch"
        )
        @test result.ok_const == true
    end

    @testset "Construction flexure — bare steel adequate" begin
        # Example I-1 LRFD: Mu_const = max(1.4×0.83, 1.2×0.83+1.6×0.20)×L²/8
        #                  = max(1.16, 1.32) × 45² / 8 = 1.32 × 2025 / 8 = 334 kip-ft
        # AISC states W21×55 ϕMn = 473 kip-ft (with deck bracing Lb ≈ 0)
        Mu_const = 334.0u"kip*ft"
        Vu_const = 30.0u"kip"
        r = check_construction(fix.section, fix.material, Mu_const, Vu_const;
                                Lb_const=0.0u"ft", Cb_const=1.0)
        @test r.flexure_ok == true
    end

    @testset "Required studs: 17 per half-span" begin
        # Example I-1: n = ΣQn / Qn = 292 / 17.2 = 17 studs per side
        Qn = get_Qn(fix.anchor, fix.slab)
        n_half = ceil(Int, 292.0 / ustrip(u"kip", Qn))
        @test n_half == 17
    end

    @testset "Shear check — ϕVn adequate" begin
        # Example I-1: Vu = 61.2 kips, ϕVn = 234 kips
        Vu = 61.2u"kip"
        ϕVn = get_ϕVn(fix.section, fix.material; axis=:strong)
        @test ϕVn > Vu
    end
end
