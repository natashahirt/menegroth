# =============================================================================
# Tests for Punching Shear Reinforcement: Closed Stirrups, Shear Caps,
# Column Capitals — ACI 318-11 §11.11.3, §13.2.6, §13.1.2
#
# Tests cover:
#   - Unit-level design function correctness
#   - ACI code limits (Vn cap, depth limits, spacing)
#   - Edge cases (near-capacity, minimum depth, max projection)
#   - Comparison across reinforcement types for same demand
# =============================================================================

using Test
using Unitful
using Unitful: @u_str
using StructuralSizer

# ─── Shared test parameters ──────────────────────────────────────────────────
const _fc = 4000.0u"psi"
const _fyt = 60000.0u"psi"
const _d = 9.0u"inch"          # Effective depth (typical 11" slab) — ≥ 16·db for #4 bars
const _h = 11.0u"inch"         # Total slab thickness
const _c1 = 20.0u"inch"        # Column dimension 1
const _c2 = 20.0u"inch"        # Column dimension 2
const _λ = 1.0
const _φ = 0.75

# Precompute geometry for an interior square column
const _geom = StructuralSizer.punching_geometry_interior(_c1, _c2, _d)
const _b0 = _geom.b0           # 2(20+9) + 2(20+9) = 116"
const _β = 1.0                 # Square
const _αs = 40                 # Interior

# Demand: moderate punching shear stress (above concrete-only capacity)
const _vu_moderate = 200.0u"psi"  # Above 4λ√f'c × φ = 0.75 × 253 = 190 psi → needs reinf.
const _vu_high = 350.0u"psi"     # High demand

# =============================================================================
# §11.11.3 — Closed Stirrups
# =============================================================================
@testset "Closed Stirrups — ACI §11.11.3" begin

    @testset "Basic design — moderate demand" begin
        # Design stirrups for a moderate punching failure
        stirrups = design_closed_stirrups(
            _vu_moderate, _fc, _β, _αs, _b0, _d, :interior, _fyt, 4;
            λ=_λ, φ=_φ, c1=_c1, c2=_c2)

        @test stirrups.required == true
        @test stirrups.bar_size == 4
        # 20" faces > 2d = 18" → 3 legs per face × 4 faces (§11.11.3.3)
        @test stirrups.n_legs == 12
        @test stirrups.n_lines >= 2  # ACI 421.1R-99 §3.4 Step 4: ≥ 2 lines
        @test stirrups.outer_ok

        # vcs capped at 2λ√f'c = 2×1×√4000 ≈ 126.5 psi (§11.11.3.1)
        vcs_psi = ustrip(u"psi", stirrups.vcs)
        @test vcs_psi ≈ 2.0 * sqrt(4000) atol=1.0

        # Spacing ≤ d/2 (§11.11.3.3)
        @test ustrip(u"inch", stirrups.s) <= ustrip(u"inch", _d) / 2 + 0.01

        # First stirrup ≤ d/2 from column face
        @test ustrip(u"inch", stirrups.s0) <= ustrip(u"inch", _d) / 2 + 0.01

        # vc_max = 6√f'c (§11.11.3.2)
        @test ustrip(u"psi", stirrups.vc_max) ≈ 6.0 * sqrt(4000) atol=1.0

        # Av per line = n_legs × Ab(#4) = 12 × 0.20 = 2.40 in²
        @test ustrip(u"inch^2", stirrups.Av_per_line) ≈ 12 * 0.20 atol=0.01
    end

    @testset "Minimum depth check — d < 6 in." begin
        # §11.11.3: d ≥ 6 in. required for closed stirrups
        d_thin = 5.0u"inch"
        stirrups = design_closed_stirrups(
            _vu_moderate, _fc, _β, _αs, _b0, d_thin, :interior, _fyt, 3;
            λ=_λ, φ=_φ)

        # Should fail: d < 6 in.
        @test stirrups.n_legs == 0
        @test stirrups.outer_ok == false
        @test is_adequate(stirrups) == false
    end

    @testset "Minimum depth check — d < 16·d_b" begin
        # §11.11.3: d ≥ 16·d_b. For #5 bar: db = 0.625", 16·db = 10"
        d_thin = 9.0u"inch"  # < 10"
        stirrups = design_closed_stirrups(
            _vu_moderate, _fc, _β, _αs, _b0, d_thin, :interior, _fyt, 5;
            λ=_λ, φ=_φ)

        # Should fail: d < 16 × 0.625 = 10"
        @test stirrups.n_legs == 0
        @test is_adequate(stirrups) == false
    end

    @testset "Demand exceeds 6√f'c cap" begin
        # §11.11.3.2: Vn ≤ 6√f'c → vu/φ ≤ 6√f'c ≈ 379.5 psi
        # So vu ≤ 0.75 × 379.5 ≈ 284.6 psi for stirrups to work
        vu_over = 300.0u"psi"  # vu/φ = 400 > 379.5 → exceeds cap
        stirrups = design_closed_stirrups(
            vu_over, _fc, _β, _αs, _b0, _d, :interior, _fyt, 4;
            λ=_λ, φ=_φ)

        @test stirrups.n_legs == 0
        @test is_adequate(stirrups) == false
    end

    @testset "Edge column — fewer legs" begin
        geom_edge = StructuralSizer.punching_geometry_edge(_c1, _c2, _d)
        b0_edge = geom_edge.b0
        stirrups = design_closed_stirrups(
            _vu_moderate, _fc, _β, 30, b0_edge, _d, :edge, _fyt, 4;
            λ=_λ, φ=_φ, c1=_c1, c2=_c2)

        @test stirrups.n_legs == 9  # Edge: 3 per face × 3 faces (20" > 2d)
    end

    @testset "Corner column — fewest legs" begin
        geom_corner = StructuralSizer.punching_geometry_corner(_c1, _c2, _d)
        b0_corner = geom_corner.b0
        stirrups = design_closed_stirrups(
            _vu_moderate, _fc, _β, 20, b0_corner, _d, :corner, _fyt, 4;
            λ=_λ, φ=_φ, c1=_c1, c2=_c2)

        @test stirrups.n_legs == 6  # Corner: 3 per face × 2 faces (20" > 2d)
    end

    @testset "check_punching_with_stirrups" begin
        stirrups = design_closed_stirrups(
            _vu_moderate, _fc, _β, _αs, _b0, _d, :interior, _fyt, 4;
            λ=_λ, φ=_φ, c1=_c1, c2=_c2)

        chk = check_punching_with_stirrups(_vu_moderate, stirrups; φ=_φ)
        # Design should produce a valid check result
        @test chk.ratio > 0.0
        @test chk.ratio < Inf
    end
end

# =============================================================================
# §13.2.6 — Shear Caps
# =============================================================================
@testset "Shear Caps — ACI §13.2.6" begin

    @testset "Basic design — moderate demand" begin
        cap = design_shear_cap(
            _vu_moderate, _fc, _d, _h, :interior, _c1, _c2;
            λ=_λ, φ=_φ)

        @test cap.required == true
        # Cap should resolve punching for moderate demand
        @test cap.ok == true
        @test cap.ratio <= 1.0

        # h_cap should be positive
        @test ustrip(u"inch", cap.h_cap) > 0.0

        # extent ≥ h_cap (§13.2.6)
        @test cap.extent >= cap.h_cap

        # d_eff = d + h_cap
        @test ustrip(u"inch", cap.d_eff) ≈ ustrip(u"inch", _d + cap.h_cap) atol=0.01

        # b0_cap > original b0 (cap enlarges critical section)
        @test cap.b0_cap > _b0
    end

    @testset "High demand — may reach max projection" begin
        cap = design_shear_cap(
            _vu_high, _fc, _d, _h, :interior, _c1, _c2;
            λ=_λ, φ=_φ, max_projection=_h)

        @test cap.required == true
        # May or may not resolve depending on projection limit
        if !cap.ok
            @test cap.h_cap == _h  # Reached max projection
        end
    end

    @testset "Zero demand — no cap needed" begin
        # If concrete alone is adequate, shear cap still designed but with tiny projection
        vu_low = 50.0u"psi"  # Well below φ × 4√f'c ≈ 190 psi
        cap = design_shear_cap(
            vu_low, _fc, _d, _h, :interior, _c1, _c2;
            λ=_λ, φ=_φ)

        @test cap.required == true
        @test cap.ok == true
        # Smallest possible cap should suffice
        @test ustrip(u"inch", cap.h_cap) <= 0.5
    end

    @testset "Edge column" begin
        cap = design_shear_cap(
            _vu_moderate, _fc, _d, _h, :edge, _c1, _c2;
            λ=_λ, φ=_φ)

        @test cap.required == true
        # Edge column has smaller b0, so may need larger cap
    end

    @testset "Small column — larger cap needed" begin
        c_small = 12.0u"inch"
        cap = design_shear_cap(
            _vu_moderate, _fc, _d, _h, :interior, c_small, c_small;
            λ=_λ, φ=_φ)

        # Smaller column → smaller b0 → higher stress → larger cap needed
        cap_large_col = design_shear_cap(
            _vu_moderate, _fc, _d, _h, :interior, _c1, _c2;
            λ=_λ, φ=_φ)

        @test cap.h_cap >= cap_large_col.h_cap
    end

    @testset "check_punching_with_shear_cap" begin
        cap = design_shear_cap(
            _vu_moderate, _fc, _d, _h, :interior, _c1, _c2;
            λ=_λ, φ=_φ)

        chk = check_punching_with_shear_cap(cap)
        @test chk.ok == cap.ok
        @test chk.ratio == cap.ratio
    end
end

# =============================================================================
# §13.1.2 — Column Capitals
# =============================================================================
@testset "Column Capitals — ACI §13.1.2" begin

    @testset "Basic design — moderate demand" begin
        capital = design_column_capital(
            _vu_moderate, _fc, _d, _h, :interior, _c1, _c2;
            λ=_λ, φ=_φ)

        @test capital.required == true
        @test capital.ok == true
        @test capital.ratio <= 1.0

        # h_cap should be positive
        @test ustrip(u"inch", capital.h_cap) > 0.0

        # 45° rule: c_eff = c + 2·h_cap
        @test ustrip(u"inch", capital.c1_eff) ≈ ustrip(u"inch", _c1 + 2 * capital.h_cap) atol=0.01
        @test ustrip(u"inch", capital.c2_eff) ≈ ustrip(u"inch", _c2 + 2 * capital.h_cap) atol=0.01

        # Effective perimeter should be larger than original
        @test capital.b0_eff > _b0
    end

    @testset "High demand — may reach max projection" begin
        capital = design_column_capital(
            _vu_high, _fc, _d, _h, :interior, _c1, _c2;
            λ=_λ, φ=_φ)

        @test capital.required == true
        # Capital only enlarges b0 (doesn't increase d like shear cap)
        # So it may be less effective for high demands
    end

    @testset "Rectangular column — 45° rule" begin
        c1_rect = 24.0u"inch"
        c2_rect = 12.0u"inch"
        capital = design_column_capital(
            _vu_moderate, _fc, _d, _h, :interior, c1_rect, c2_rect;
            λ=_λ, φ=_φ)

        if capital.ok
            # 45° rule applies to both directions
            @test ustrip(u"inch", capital.c1_eff) ≈ ustrip(u"inch", c1_rect + 2 * capital.h_cap) atol=0.01
            @test ustrip(u"inch", capital.c2_eff) ≈ ustrip(u"inch", c2_rect + 2 * capital.h_cap) atol=0.01
        end
    end

    @testset "Capital vs shear cap — different mechanisms" begin
        # For same demand, compare capital vs shear cap
        capital = design_column_capital(
            _vu_moderate, _fc, _d, _h, :interior, _c1, _c2;
            λ=_λ, φ=_φ)

        cap = design_shear_cap(
            _vu_moderate, _fc, _d, _h, :interior, _c1, _c2;
            λ=_λ, φ=_φ)

        # Both should resolve moderate demand
        @test capital.ok == true
        @test cap.ok == true

        # Shear cap increases d, so it may need less projection
        # Capital only enlarges b0, so it may need more projection
        # (This is a design insight, not a strict test)
    end

    @testset "check_punching_with_capital" begin
        capital = design_column_capital(
            _vu_moderate, _fc, _d, _h, :interior, _c1, _c2;
            λ=_λ, φ=_φ)

        chk = check_punching_with_capital(capital)
        @test chk.ok == capital.ok
        @test chk.ratio == capital.ratio
    end

    @testset "Edge column" begin
        capital = design_column_capital(
            _vu_moderate, _fc, _d, _h, :edge, _c1, _c2;
            λ=_λ, φ=_φ)

        @test capital.required == true
    end
end

# =============================================================================
# Comparative Tests — All Reinforcement Types for Same Demand
# =============================================================================
@testset "Comparative — All Reinforcement Types" begin

    @testset "All types resolve moderate demand" begin
        # Headed studs (generic)
        studs = design_shear_studs(
            _vu_moderate, _fc, _β, _αs, _b0, _d, :interior,
            51000.0u"psi", 0.5u"inch"; λ=_λ, φ=_φ,
            c1=_c1, c2=_c2)

        # Closed stirrups
        stirrups = design_closed_stirrups(
            _vu_moderate, _fc, _β, _αs, _b0, _d, :interior, _fyt, 4;
            λ=_λ, φ=_φ, c1=_c1, c2=_c2)

        # Shear cap
        cap = design_shear_cap(
            _vu_moderate, _fc, _d, _h, :interior, _c1, _c2;
            λ=_λ, φ=_φ)

        # Column capital
        capital = design_column_capital(
            _vu_moderate, _fc, _d, _h, :interior, _c1, _c2;
            λ=_λ, φ=_φ)

        # All design functions should produce valid results for moderate demand
        @test studs.required == true
        @test studs.n_rails > 0        # Studs designed successfully
        @test stirrups.required == true
        @test stirrups.n_legs > 0      # Stirrups designed successfully
        @test cap.ok == true           # Shear cap resolves punching
        @test capital.ok == true       # Column capital resolves punching
    end

    @testset "Studs vs stirrups — capacity limits" begin
        # Studs: Vn ≤ 8√f'c (§11.11.5)  → vu/φ ≤ 506 psi
        # Stirrups: Vn ≤ 6√f'c (§11.11.3) → vu/φ ≤ 380 psi
        # So stirrups have a lower capacity ceiling

        # Demand between the two limits: vu = 250 psi → vu/φ = 333
        vu_between = 250.0u"psi"

        studs = design_shear_studs(
            vu_between, _fc, _β, _αs, _b0, _d, :interior,
            51000.0u"psi", 0.5u"inch"; λ=_λ, φ=_φ,
            c1=_c1, c2=_c2)
        stud_chk = check_punching_with_studs(vu_between, studs; φ=_φ)

        # Studs should design successfully (inner section below 8√f'c cap)
        @test studs.required == true
        @test studs.n_rails > 0

        # Stirrups should also be designable at this level
        stirrups = design_closed_stirrups(
            vu_between, _fc, _β, _αs, _b0, _d, :interior, _fyt, 4;
            λ=_λ, φ=_φ, c1=_c1, c2=_c2)
        @test stirrups.required == true
        @test stirrups.n_legs > 0
    end
end

# =============================================================================
# FlatPlateOptions — New Reinforcement Symbols
# =============================================================================
@testset "FlatPlateOptions — New Reinforcement Types" begin

    @testset "Closed stirrups option" begin
        opts = FlatPlateOptions(
            punching_strategy = :reinforce_last,
            punching_reinforcement = :closed_stirrups,
            stirrup_bar_size = 4)
        @test opts.punching_reinforcement === :closed_stirrups
        @test opts.stirrup_bar_size == 4
    end

    @testset "Shear caps option" begin
        opts = FlatPlateOptions(
            punching_strategy = :reinforce_first,
            punching_reinforcement = :shear_caps)
        @test opts.punching_reinforcement === :shear_caps
    end

    @testset "Column capitals option" begin
        opts = FlatPlateOptions(
            punching_strategy = :reinforce_first,
            punching_reinforcement = :column_capitals)
        @test opts.punching_reinforcement === :column_capitals
    end

    @testset "Default still works" begin
        opts = FlatPlateOptions()
        @test opts.punching_strategy === :grow_columns
        @test opts.punching_reinforcement === :headed_studs_generic
        @test opts.stirrup_bar_size == 4
    end

    @testset "Backward compat — shear_studs kwarg" begin
        opts = FlatPlateOptions(shear_studs = :if_needed)
        @test opts.punching_strategy === :reinforce_last
    end
end

# =============================================================================
# is_adequate dispatch
# =============================================================================
@testset "is_adequate — all types" begin
    @test is_adequate(ClosedStirrupDesign()) == true   # required=false → adequate
    @test is_adequate(ShearCapDesign()) == true         # required=false → adequate
    @test is_adequate(ColumnCapitalDesign()) == true    # required=false → adequate

    # Required but not designed → inadequate
    @test is_adequate(ClosedStirrupDesign(required=true, n_legs=0, outer_ok=false)) == false
    @test is_adequate(ShearCapDesign(required=true, ok=false)) == false
    @test is_adequate(ColumnCapitalDesign(required=true, ok=false)) == false
end
