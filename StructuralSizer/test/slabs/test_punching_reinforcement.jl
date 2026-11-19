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
const _SS = StructuralSizer
const _col_int = (position = :interior, c1 = _c1, c2 = _c2, shape = :rectangular)
const _col_edge = (position = :edge, c1 = _c1, c2 = _c2, shape = :rectangular)
const _Vu_moderate = uconvert(u"kip", _vu_moderate * _b0 * _d)   # 208.8 kip on the bare section
const _M0 = 0.0u"kip*ft"

@testset "Shear Caps — ACI §13.2.6 / §11.11.1.2" begin

    @testset "Both critical sections are checked; the worse governs" begin
        cap = design_shear_cap(_col_int, _Vu_moderate, _M0, _fc, _d, _h; λ=_λ, φ=_φ)
        @test cap.required && cap.ok
        @test cap.extent == cap.h_cap                     # §13.2.6 minimum extent
        @test cap.d_eff ≈ _d + cap.h_cap
        @test cap.c1_cap ≈ _c1 + 2cap.h_cap
        # (a) column face through the cap, (b) cap edge in slab depth d.
        a = _SS.check_punching_for_column(_col_int, _Vu_moderate, _M0, _d + cap.h_cap,
                                          _h + cap.h_cap, _fc; λ=_λ, φ_shear=_φ)
        proxy = (position = :interior, c1 = cap.c1_cap, c2 = cap.c2_cap, shape = :rectangular)
        b = _SS.check_punching_for_column(proxy, _Vu_moderate, _M0, _d, _h, _fc; λ=_λ, φ_shear=_φ)
        @test cap.ratio ≈ max(a.ratio, b.ratio)
        @test cap.b0_cap ≈ 4 * (_c1 + 2cap.h_cap + _d)   # d/2 outside the cap, slab d
        # One increment less fails one of the two sections.
        if cap.h_cap > 0.25u"inch"
            hc = cap.h_cap - 0.25u"inch"
            a0 = _SS.check_punching_for_column(_col_int, _Vu_moderate, _M0, _d + hc, _h + hc, _fc;
                                               λ=_λ, φ_shear=_φ)
            p0 = (position = :interior, c1 = _c1 + 2hc, c2 = _c2 + 2hc, shape = :rectangular)
            b0 = _SS.check_punching_for_column(p0, _Vu_moderate, _M0, _d, _h, _fc; λ=_λ, φ_shear=_φ)
            @test max(a0.ratio, b0.ratio) > 1.0
        end
    end

    @testset "The cap edge section is in the slab depth, not d + h_cap" begin
        # A demand the column-face section clears easily with a deep cap
        # still needs the cap edge section at slab depth d to pass.
        Vu = 1.6 * _Vu_moderate
        cap = design_shear_cap(_col_int, Vu, _M0, _fc, _d, _h; λ=_λ, φ=_φ)
        proxy = (position = :interior, c1 = cap.c1_cap, c2 = cap.c2_cap, shape = :rectangular)
        b = _SS.check_punching_for_column(proxy, Vu, _M0, _d, _h, _fc; λ=_λ, φ_shear=_φ)
        @test cap.ratio >= b.ratio - 1e-12
        cap.ok || @test cap.h_cap ≈ _h
    end

    @testset "Edge cap stops at the free edge" begin
        Vu = 0.5 * _Vu_moderate
        Mub = 40.0u"kip*ft"
        cap = design_shear_cap(_col_edge, Vu, Mub, _fc, _d, _h; λ=_λ, φ=_φ,
                               punch_kwargs = (free_edge_parallel = :c2,))
        @test cap.required
        @test cap.c1_cap ≈ _c1 + cap.h_cap          # perpendicular to the edge: one side
        @test cap.c2_cap ≈ _c2 + 2cap.h_cap         # along the edge: both sides
    end

    @testset "Skew or re-entrant corners are not modelled" begin
        col = (position = :corner, c1 = _c1, c2 = _c2, shape = :rectangular,
               corner_kind = :reentrant)
        cap = design_shear_cap(col, _Vu_moderate, _M0, _fc, _d, _h)
        @test cap.required && !cap.ok && cap.governing === :unsupported
    end

    @testset "Smaller column needs at least as deep a cap" begin
        small = (position = :interior, c1 = 12.0u"inch", c2 = 12.0u"inch", shape = :rectangular)
        Vu = 0.6 * _Vu_moderate
        @test design_shear_cap(small, Vu, _M0, _fc, _d, _h).h_cap >=
              design_shear_cap(_col_int, Vu, _M0, _fc, _d, _h).h_cap
    end

    @testset "Volume is the footprint less the column" begin
        cap = ShearCapDesign(required = true, h_cap = 3.0u"inch", extent = 3.0u"inch",
                             c1_cap = 26.0u"inch", c2_cap = 26.0u"inch")
        @test shear_cap_concrete_volume(cap, _c1, _c2) ≈ (26^2 - 20^2) * 3.0u"inch^3"
    end

    @testset "check_punching_with_shear_cap" begin
        cap = design_shear_cap(_col_int, _Vu_moderate, _M0, _fc, _d, _h; λ=_λ, φ=_φ)
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
        capital = design_column_capital(_col_int, _Vu_moderate, _M0, _fc, _d, _h; λ=_λ, φ=_φ)
        @test capital.required && capital.ok
        @test capital.h_cap > 0.0u"inch"
        # 45° rule at an interior column: c_eff = c + 2·h_cap
        @test capital.c1_eff ≈ _c1 + 2capital.h_cap
        @test capital.c2_eff ≈ _c2 + 2capital.h_cap
        # Section at d/2 from the effective support, slab depth d.
        @test capital.b0_eff ≈ 4 * (_c1 + 2capital.h_cap + _d)
    end

    @testset "Rectangular column — 45° rule" begin
        col = (position = :interior, c1 = 24.0u"inch", c2 = 12.0u"inch", shape = :rectangular)
        capital = design_column_capital(col, 0.8 * _Vu_moderate, _M0, _fc, _d, _h)
        @test capital.c1_eff ≈ 24.0u"inch" + 2capital.h_cap
        @test capital.c2_eff ≈ 12.0u"inch" + 2capital.h_cap
    end

    @testset "Edge capital flares only into the slab" begin
        capital = design_column_capital(_col_edge, 0.5 * _Vu_moderate, 40.0u"kip*ft",
                                        _fc, _d, _h; punch_kwargs = (free_edge_parallel = :c2,))
        @test capital.required
        @test capital.c1_eff ≈ _c1 + capital.h_cap
        @test capital.c2_eff ≈ _c2 + 2capital.h_cap
    end

    @testset "Volume is the 45° frustum less the column" begin
        # 20×20 column, 4 in flare → 28×28 at the soffit.
        # Prismoid: 4/6 (400 + 48·48 + 784) = 2325.33; less 20·20·4 = 1600.
        capital = ColumnCapitalDesign(required = true, h_cap = 4.0u"inch",
                                      c1_eff = 28.0u"inch", c2_eff = 28.0u"inch")
        @test capital_concrete_volume(capital, _c1, _c2) ≈ (3488 * 4 / 6 - 1600) * u"inch^3"
        round_cap = ColumnCapitalDesign(required = true, h_cap = 4.0u"inch",
                                        c1_eff = 28.0u"inch", c2_eff = 28.0u"inch",
                                        shape = :circular)
        @test capital_concrete_volume(round_cap, 20.0u"inch", 20.0u"inch") ≈
              (π * 4 / 12 * (400 + 560 + 784) - π * 400 / 4 * 4) * u"inch^3"
    end

    @testset "check_punching_with_capital" begin
        capital = design_column_capital(_col_int, _Vu_moderate, _M0, _fc, _d, _h; λ=_λ, φ=_φ)
        chk = check_punching_with_capital(capital)
        @test chk.ok == capital.ok
        @test chk.ratio == capital.ratio
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
        cap = design_shear_cap(_col_int, _Vu_moderate, _M0, _fc, _d, _h; λ=_λ, φ=_φ)

        # Column capital
        capital = design_column_capital(_col_int, _Vu_moderate, _M0, _fc, _d, _h; λ=_λ, φ=_φ)

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
        @test opts.punching_strategy === :joint_search
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

# =============================================================================
# Wall reactions at any plan angle (§11.11.1.2)
# =============================================================================
@testset "Wall reaction punching — plan rotation" begin
    SS = StructuralSizer
    d, fc, qu = 7.0u"inch", 4000.0u"psi", 250.0u"psf"
    t = 10.0u"inch"
    trib = Dict(1 => 30.0)
    wall(p, q) = (x1 = p[1], y1 = p[2], x2 = q[1], y2 = q[2], thickness = t,
                  tributary_cell_areas = trib)
    rot(p, θ) = (cos(θ) * p[1] - sin(θ) * p[2], sin(θ) * p[1] + cos(θ) * p[2])
    checks(walls, inside) = SS._push_cluster_checks!(NamedTuple[], walls, d, fc, qu, inside;
                                                    λ = 1.0, ϕ = 0.75)
    θ = deg2rad(30)

    # A free-standing wall with slab on both faces: same check when turned.
    everywhere = pt -> true
    a = only(checks([wall((0.0, 0.0), (3.0, 0.0))], everywhere))
    b = only(checks([wall(rot((0.0, 0.0), θ), rot((3.0, 0.0), θ))], everywhere))
    @test a.kind === b.kind === :wall_interior
    @test a.utilization ≈ b.utilization rtol = 1e-9
    @test a.b0 ≈ b.b0 rtol = 1e-9

    # An L corner with slab in the first quadrant only, turned by 30°.
    quad = pt -> pt[1] > 0 && pt[2] > 0
    quad_r = pt -> quad(rot(pt, -θ))
    L = [wall((0.0, 0.0), (4.0, 0.0)), wall((0.0, 0.0), (0.0, 3.0))]
    Lr = [wall(rot((0.0, 0.0), θ), rot((4.0, 0.0), θ)),
          wall(rot((0.0, 0.0), θ), rot((0.0, 3.0), θ))]
    ca, cb = checks(L, quad), checks(Lr, quad_r)
    @test [c.kind for c in ca] == [c.kind for c in cb] == [:reentrant_corner]
    @test ca[1].utilization ≈ cb[1].utilization rtol = 1e-9

    # Walls meeting at 60°: only the slab-side face lines count.
    V = [wall((0.0, 0.0), (4.0, 0.0)), wall((0.0, 0.0), rot((3.0, 0.0), deg2rad(60)))]
    j = only(checks(V, everywhere))
    @test j.kind === :wall_junction
    @test j.b0 ≈ 2 * (4.0 + 3.0) * u"m"
    Vu = qu * 60.0u"m^2"
    @test j.vu ≈ uconvert(u"psi", Vu / (j.b0 * d)) rtol = 1e-9
end

# =============================================================================
# Outer section demand: both moments, mapped like the column-face check
# =============================================================================
@testset "Outer section demand mapping" begin
    SS = StructuralSizer
    c = 20.0u"inch"
    dem = (Vu = 100.0u"kip", Mub = 60.0u"kip*ft", Muy = 25.0u"kip*ft")

    # Free edge along y, span along x: Mub is about the edge-parallel axis.
    edge = (position = :edge, c1 = c, c2 = c, shape = :rectangular,
            boundary_edge_dirs = [(0.0, 1.0)], θ = 0.0)
    o = SS._outer_section_demand(edge, dem; span_axis = (1.0, 0.0))
    @test o.M_about_y == dem.Mub && o.M_about_x == dem.Muy
    # Span along the edge: the secondary moment is the edge-parallel one.
    o = SS._outer_section_demand(edge, dem; span_axis = (0.0, 1.0))
    @test o.M_about_y == dem.Muy && o.M_about_x == dem.Mub
    # No edge direction: both axes carry the larger moment.
    bare = (position = :edge, c1 = c, c2 = c, shape = :rectangular)
    o = SS._outer_section_demand(bare, dem)
    @test o.M_about_y == dem.Mub && o.M_about_x == dem.Mub

    # Interior: the span moment follows the span axis onto c1 or c2.
    int = (position = :interior, c1 = c, c2 = c, shape = :rectangular)
    o = SS._outer_section_demand(int, dem; span_axis = (1.0, 0.0))
    @test o.M_about_y == dem.Mub && o.M_about_x == dem.Muy
    o = SS._outer_section_demand(int, dem; span_axis = (0.0, 1.0))
    @test o.M_about_y == dem.Muy && o.M_about_x == dem.Mub
end

# =============================================================================
# Flat slab: reinforcement for the section that governs (§11.11.1.2)
# =============================================================================
@testset "Drop-panel punching remedies" begin
    SS = StructuralSizer
    col = (position = :interior, c1 = 20.0u"inch", c2 = 20.0u"inch", shape = :rectangular)
    h, d = 10.0u"inch", 8.5u"inch"
    panel = DropPanelGeometry(4.25u"inch", 5.0u"ft", 5.0u"ft")
    drop = SS._drop_depths(panel, h, 0.75u"inch", 0.5u"inch")
    @test drop.h_total ≈ 14.25u"inch"
    @test drop.d_total ≈ SS.effective_depth(drop.h_total; cover = 0.75u"inch",
                                            bar_diameter = 0.5u"inch")
    @test SS._drop_depths(nothing, h, 0.75u"inch", 0.5u"inch") === nothing

    qu = 300.0u"psf"
    mr = (qu = qu,)
    Mub = 0.0u"kip*ft"
    punch(Vu) = SS.check_punching(col, Vu, Mub, h, d, drop.h_total, drop.d_total,
                                  _fc, panel; qu = qu)
    studs = FlatPlateOptions(punching_reinforcement = :headed_studs_generic)
    demand(Vu) = (Vu = Vu, Mub = Mub, Muy = nothing)

    # Column face fails inside the drop; the drop edge passes.
    Vu = 380.0u"kip"
    r = punch(Vu)
    @test !r.ok && r.governing_section === :column && r.drop_section.ok
    reach = 5.0u"ft" - 10.0u"inch" - drop.d_total / 2
    out = SS._try_drop_reinforcement(:headed_studs_generic, r, _fc, col, studs, mr,
                                     demand(Vu), drop)
    s = out.studs
    @test s !== nothing
    @test s.s0 + (s.n_studs_per_rail - 1) * s.s <= reach + 1e-9u"inch"
    # Designed at the drop depth: the first line sits at d_total/2.
    @test s.s0 ≈ drop.d_total / 2

    # Caps and capitals assume slab depth around the column.
    for kind in (:shear_caps, :column_capitals)
        @test !SS._try_drop_reinforcement(kind, r, _fc, col, studs, mr, demand(Vu), drop).ok
    end

    # Drop edge fails: no column-side remedy, the slab thickens.
    Vu_big = 1200.0u"kip"
    rb = punch(Vu_big)
    @test !rb.drop_section.ok
    @test !SS._try_drop_reinforcement(:headed_studs_generic, rb, _fc, col, studs, mr,
                                      demand(Vu_big), drop).ok
    cols = [(position = :interior, c1 = 20.0u"inch", c2 = 20.0u"inch", shape = :rectangular)]
    mres = (column_shears = [Vu_big], unbalanced_moments = [Mub], column_moments = [Mub],
            qu = qu)
    grew, h_new = SS._resolve_punching_failures!(
        Any[rb], cols, [1], studs, ConcreteColumnOptions(), mres, nothing,
        h, d, _fc, 0.5u"inch"; drop = drop)
    @test grew && h_new == 10.5u"inch"
end
