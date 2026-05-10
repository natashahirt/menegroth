using StructuralSizer
using Unitful
using Test

# =============================================================================
# Rebar Quantity Audits — Mat (Rigid) and Strip Transverse T&S Steel
# =============================================================================
#
# These tests pin down two corrections to the foundation rebar takeoff:
#
# 1. Mat — Rigid Kramrisch path (`_design_mat_rigid`):
#    The strip-method moment `M_strip = qu·trib_width·Ls²/coeff` had been
#    fed to `_flexural_steel_footing(M_strip, Lm, d, …)`, which interpreted
#    `M_strip` as a full-mat moment. That returned `As ≈ M_strip/(φ·fy·d)` —
#    enough steel for ONE strip — but `_mat_build_result` then distributed
#    that single-strip As across the whole mat. The fix passes the full mat
#    width perpendicular to the strip span (Lm for x-strips, B for y-strips)
#    so the moment scale matches the per-unit-length × full-width convention
#    used by the Shukla and Winkler-FEA paths. Reference: ACI 336.2R-88
#    §6.1.2 Step 3 (corpus: aci-336-combined-footings-mats Chapter 6).
#
# 2. Strip footing — transverse T&S steel:
#    `As_trans` is the concentrated band steel under one column, and the
#    volume previously summed `N` such bands and stopped there. The footing
#    length OUTSIDE the bands still requires minimum shrinkage/temperature
#    steel transverse to the strip axis. The fix adds inter-band T&S steel
#    per ACI 318-11 §7.12.2.1 (corpus: aci-318-11, page 106).
# =============================================================================

println("\n" * "="^90)
println("Foundation Rebar Quantity — Mat (Rigid) & Strip T&S Audits")
println("="^90)

# ─────────────────────────────────────────────────────────────────────────────
# Mat — Rigid path: As scales with full mat width, not one tributary strip
# ─────────────────────────────────────────────────────────────────────────────
#
# Build a 4×4 column grid where flexure governs (h forced large enough that
# punching is trivially OK). Then verify:
#   (a) As_x_bot in the rigid path is on the same scale as a hand calc using
#       the worst per-unit-width moment intensity × full mat width;
#   (b) the rigid path's reported steel volume is comparable to (within a
#       factor of ~2 of) the FEA path, instead of being ~Lm/avg_trib_x times
#       smaller as before;
#   (c) the Shukla envelope is still ≥ rigid (envelope property).

println("\n--- Mat Rigid: rebar quantity scales with full mat width ---")

function build_mat_grid_4x4(spacing_ft, Pu_corner, Pu_edge, Pu_interior,
                            Ps_corner, Ps_edge, Ps_interior)
    demands   = FoundationDemand[]
    positions = NTuple{2, typeof(0.0u"ft")}[]
    n = 4
    for (i, x) in enumerate(range(0.0, step = spacing_ft, length = n)),
        (j, y) in enumerate(range(0.0, step = spacing_ft, length = n))

        idx       = (i - 1) * n + j
        is_corner = (i == 1 || i == n) && (j == 1 || j == n)
        is_edge   = !is_corner && (i == 1 || i == n || j == 1 || j == n)
        Pu = is_corner ? Pu_corner : is_edge ? Pu_edge : Pu_interior
        Ps = is_corner ? Ps_corner : is_edge ? Ps_edge : Ps_interior
        push!(demands,   FoundationDemand(idx; Pu = Pu, Ps = Ps))
        push!(positions, (x * u"ft", y * u"ft"))
    end
    return demands, positions
end

# Moderate office loading (matches Scenario A in test_mat_aci.jl) but with
# h forced to 48 in. so flexure governs in the rigid path.
demands_mat, positions_mat = build_mat_grid_4x4(
    25.0,
    180.0kip, 300.0kip, 500.0kip,
    125.0kip, 210.0kip, 350.0kip,
)
soil_mat = Soil(3.0ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa";
                ks = 25000.0u"kN/m^3")

base_opts = (material         = RC_4000_60,
             bar_size_x       = 8,
             bar_size_y       = 8,
             cover            = 3.0u"inch",
             min_depth        = 48.0u"inch",
             depth_increment  = 1.0u"inch")

r_rigid = design_footing(MatFoundation(), demands_mat, positions_mat, soil_mat;
            opts = MatParams(; base_opts..., analysis_method = RigidMat()))
r_shukla = design_footing(MatFoundation(), demands_mat, positions_mat, soil_mat;
            opts = MatParams(; base_opts..., analysis_method = ShuklaAFM()))
r_fea = design_footing(MatFoundation(), demands_mat, positions_mat, soil_mat;
            opts = MatParams(; base_opts..., analysis_method = WinklerFEA()))

# Plan dimensions and effective depth — for the hand check
B_ft  = ustrip(u"ft",   r_rigid.B)
Lm_ft = ustrip(u"ft",   r_rigid.L_ftg)
h_in  = ustrip(u"inch", r_rigid.D)
d_in  = ustrip(u"inch", r_rigid.d)

# Total factored load and factored net pressure
Pu_total_kip = sum(ustrip(kip, d.Pu) for d in demands_mat)
A_mat_ft2    = B_ft * Lm_ft
qu_ksf       = Pu_total_kip / A_mat_ft2  # kip/ft²

# Worst per-unit-width moment intensity from the strip method:
# largest interior coefficient is wL²/10 (negative) with bay 25 ft.
# Per-unit-width units: kip-ft per ft = kip.
bay_ft       = 25.0
mU_per_ft    = qu_ksf * bay_ft^2 / 10.0  # kip per ft of width (= kip-ft/ft)
M_full_x_kipft = mU_per_ft * Lm_ft       # total kip-ft for full Lm width
# Lever-arm-bound: As_lower ≈ M / (φ·fy·d) with φ=0.9, fy=60 ksi, d in inches
As_x_lower_in2 = (M_full_x_kipft * 12.0) / (0.9 * 60.0 * d_in)

As_x_bot_rigid_in2 = ustrip(u"inch^2", r_rigid.As_x_bot)
As_x_bot_fea_in2   = ustrip(u"inch^2", r_fea.As_x_bot)

println("  Mat: B = $(round(B_ft, digits=2)) ft, Lm = $(round(Lm_ft, digits=2)) ft, h = $(round(h_in, digits=1)) in., d = $(round(d_in, digits=1)) in.")
println("  qu  = $(round(qu_ksf, digits=3)) ksf  →  worst m/ft = $(round(mU_per_ft, digits=2)) kip-ft/ft")
println("  Hand-check As_x_bot lower bound (full-mat scale) ≈ $(round(As_x_lower_in2, digits=1)) in²")
println("  Rigid:  As_x_bot = $(round(As_x_bot_rigid_in2, digits=1)) in²")
println("  FEA:    As_x_bot = $(round(As_x_bot_fea_in2,   digits=1)) in²")

@testset "Mat rigid: As_x_bot scales with full mat width" begin
    # (a) Rigid As must be at least the per-ft moment × Lm hand bound, allowing
    #     ~5% slack for rounding & lever-arm differences. Before the fix this
    #     was an avg_trib/Lm fraction of the bound (~1/3 for a 4×4 grid).
    @test As_x_bot_rigid_in2 ≥ 0.95 * As_x_lower_in2

    # (b) Rigid is now within a factor of 2 of FEA — was ~3× smaller before.
    @test As_x_bot_rigid_in2 ≥ 0.5 * As_x_bot_fea_in2

    # Same checks for y-direction (square grid, symmetric loading).
    As_y_bot_rigid_in2 = ustrip(u"inch^2", r_rigid.As_y_bot)
    @test As_y_bot_rigid_in2 ≥ 0.95 * As_x_lower_in2

    # (c) Envelope property: Shukla ≥ Rigid on every face.
    @test ustrip(u"inch^2", r_shukla.As_x_bot) ≥ As_x_bot_rigid_in2 - 0.1
    @test ustrip(u"inch^2", r_shukla.As_x_top) ≥
          ustrip(u"inch^2", r_rigid.As_x_top) - 0.1
end

# Volume sanity: rigid steel volume should not be a tiny fraction of FEA
# volume.  A 4×4 grid had `avg_trib_x ≈ Lm/3`, so the pre-fix rigid V_steel
# was roughly 1/3 of the corrected value.  After the fix the rigid path is
# in the same order of magnitude as FEA.
V_rigid = ustrip(u"m^3", r_rigid.steel_volume)
V_fea   = ustrip(u"m^3", r_fea.steel_volume)
println("  V_steel rigid = $(round(V_rigid, digits=3)) m³,  FEA = $(round(V_fea, digits=3)) m³")

@testset "Mat rigid: steel volume scale" begin
    @test V_rigid ≥ 0.5 * V_fea  # was ~0.3·V_fea before the fix
end

# Independent check: when the strip-statics hand-derived As is also above
# minimum steel, increasing Lm increases As_x_bot proportionally.  Verify by
# building two grids that differ only in number of bays in y (so Lm differs)
# and checking the rigid As scales with Lm.
println("\n--- Mat Rigid: As_x_bot scales linearly with mat width Lm ---")

function rigid_As_x(spacing_ft, ny)
    demands   = FoundationDemand[]
    positions = NTuple{2, typeof(0.0u"ft")}[]
    nx = 4
    for (i, x) in enumerate(range(0.0, step = spacing_ft, length = nx)),
        (j, y) in enumerate(range(0.0, step = spacing_ft, length = ny))
        idx = (i - 1) * ny + j
        push!(demands,   FoundationDemand(idx; Pu = 500.0kip, Ps = 350.0kip))
        push!(positions, (x * u"ft", y * u"ft"))
    end
    s = Soil(3.0ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa";
             ks = 25000.0u"kN/m^3")
    return design_footing(MatFoundation(), demands, positions, s;
        opts = MatParams(; material = RC_4000_60,
                           bar_size_x = 8, bar_size_y = 8,
                           cover = 3.0u"inch", min_depth = 48.0u"inch",
                           depth_increment = 1.0u"inch",
                           analysis_method = RigidMat()))
end

# Hold ny constant on the x-strip side: vary ny, span direction unchanged →
# As_x_bot (x-bars resisting moment along x-spans) should scale ~linearly
# with Lm, since per-unit-width moment is unchanged but full-width grows.
r2 = rigid_As_x(25.0, 2)
r4 = rigid_As_x(25.0, 4)
Lm2 = ustrip(u"ft", r2.L_ftg)
Lm4 = ustrip(u"ft", r4.L_ftg)
As2 = ustrip(u"inch^2", r2.As_x_bot)
As4 = ustrip(u"inch^2", r4.As_x_bot)

println("  ny = 2: Lm = $(round(Lm2, digits=2)) ft, As_x_bot = $(round(As2, digits=2)) in²")
println("  ny = 4: Lm = $(round(Lm4, digits=2)) ft, As_x_bot = $(round(As4, digits=2)) in²")
println("  As ratio = $(round(As4/As2, digits=2)),  Lm ratio = $(round(Lm4/Lm2, digits=2))")

@testset "Mat rigid: As scales with Lm" begin
    # Allow generous tolerance — qu shifts a little when overhang adapts to
    # the new column count, plus the round-up to size_increment is discrete.
    # Pre-fix, As barely changed with Lm because it tracked avg_trib_x only.
    @test As4 / As2 ≥ 0.6 * (Lm4 / Lm2)
    @test As4 / As2 ≤ 1.4 * (Lm4 / Lm2)
end

# ─────────────────────────────────────────────────────────────────────────────
# Strip footing — inter-band transverse T&S steel
# ─────────────────────────────────────────────────────────────────────────────
#
# After the fix the strip footing's V_steel includes minimum shrinkage /
# temperature reinforcement (ACI 318-11 §7.12.2.1) along the inter-band
# length, in addition to the concentrated band steel under each column.

println("\n--- Strip Footing: V_steel includes inter-band T&S steel ---")

# Reuse the StructurePoint Wight Ex 15-5 setup from test_strip_aci.jl.
d_ext_strip = FoundationDemand(1; Pu = 480.0kip, Ps = 350.0kip,
                                  c1 = 18.0u"inch", c2 = 18.0u"inch")
d_int_strip = FoundationDemand(2; Pu = 720.0kip, Ps = 525.0kip,
                                  c1 = 18.0u"inch", c2 = 18.0u"inch")
soil_strip  = Soil(4.32ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
positions_strip = [0.0u"ft", 20.0u"ft"]
opts_strip = StripParams(
    material         = RC_3000_60,
    bar_size_long    = 8,
    bar_size_trans   = 5,
    cover            = 3.0u"inch",  # ACI 318-11 §7.7.1 clear cover
    min_depth        = 12.0u"inch",
    depth_increment  = 1.0u"inch",
    width_increment  = 1.0u"inch",
)

result_strip = design_footing(StripFooting(),
    [d_ext_strip, d_int_strip], positions_strip, soil_strip; opts = opts_strip)

# Recompute the band-only volume the way the pre-fix code did, then verify
# the new V_steel exceeds it by the inter-band T&S contribution.
N_strip   = result_strip.n_columns
B_strip   = result_strip.B
L_strip   = result_strip.L_ftg
h_strip   = result_strip.D
d_strip   = result_strip.d
cover_strip = opts_strip.cover

# `_min_steel_footing` lives inside the package; reproduce its formula here
# (ACI 318-11 §7.12.2.1, Grade 60 deformed bars: ρ_min = 0.0018).
fy_psi    = ustrip(u"psi", opts_strip.material.rebar.Fy)
rho_min   = fy_psi ≤ 60_000.0 ? 0.0018 : max(0.0014, 0.0018 * 60_000.0 / fy_psi)

# Band width per the strip-footing routine: c1_max + d (`c1_max` = 18 in. here).
c1_max    = max(d_ext_strip.c1, d_int_strip.c1)
band_w    = c1_max + d_strip
inter_band_length = max(L_strip - N_strip * band_w, 0.0u"inch")

# Bar properties (must match the strip routine: Ab_t for size 5).
Ab_5_in2  = π * (5/8)^2 / 4   # ACI bar #5 ⇒ 5/8" diameter ⇒ 0.3068 in²
n_inter_expected = ceil(Int,
    rho_min * ustrip(u"inch", inter_band_length) * ustrip(u"inch", h_strip) /
    Ab_5_in2)

bar_len_trans_in  = ustrip(u"inch", B_strip - 2 * cover_strip)
V_inter_band_in3  = n_inter_expected * Ab_5_in2 * bar_len_trans_in
V_inter_band_m3   = V_inter_band_in3 * (0.0254)^3

# As_trans from the result (one band's steel, in²) → bars per band → band V_steel.
As_trans_in2     = ustrip(u"inch^2", result_strip.As_trans)
n_tran_per_band  = ceil(Int, As_trans_in2 / Ab_5_in2)
V_band_only_in3  = N_strip * n_tran_per_band * Ab_5_in2 * bar_len_trans_in

# Longitudinal (top + bottom) volume — independent of the fix.
Ab_8_in2 = π * (8/8)^2 / 4       # bar #8 ⇒ 1.0" ⇒ 0.7854 in² (real value 0.79 in²)
Ab_8_in2 = 0.7854
n_top    = ceil(Int, ustrip(u"inch^2", result_strip.As_long_top) / Ab_8_in2)
n_bot    = ceil(Int, ustrip(u"inch^2", result_strip.As_long_bot) / Ab_8_in2)
bar_len_long_in   = ustrip(u"inch", L_strip - 2 * cover_strip)
V_long_in3        = (n_top + n_bot) * Ab_8_in2 * bar_len_long_in

V_pre_fix_in3     = V_long_in3 + V_band_only_in3                  # band-only takeoff
V_post_fix_in3    = V_pre_fix_in3 + V_inter_band_in3              # with inter-band T&S
V_actual_m3       = ustrip(u"m^3", result_strip.steel_volume)
V_actual_in3      = V_actual_m3 / (0.0254)^3

println("  L = $(round(ustrip(u"ft", L_strip), digits=2)) ft, B = $(round(ustrip(u"ft", B_strip), digits=2)) ft, h = $(round(ustrip(u"inch", h_strip), digits=1)) in.")
println("  band_w = $(round(ustrip(u"inch", band_w), digits=1)) in., inter-band length = $(round(ustrip(u"inch", inter_band_length), digits=1)) in.")
println("  Bars: $(n_top + n_bot) #8 longitudinal, $(n_tran_per_band) #5 / band × $(N_strip), $(n_inter_expected) #5 inter-band")
println("  Hand-check V_steel:  band-only = $(round(V_pre_fix_in3, digits=1)) in³,  with T&S = $(round(V_post_fix_in3, digits=1)) in³")
println("  Reported V_steel       = $(round(V_actual_in3, digits=1)) in³  (= $(round(V_actual_m3, digits=4)) m³)")

@testset "Strip footing: inter-band T&S steel is included" begin
    # Inter-band length must be a non-trivial fraction of L for this footing.
    @test ustrip(u"inch", inter_band_length) > 0.0
    @test ustrip(u"inch", inter_band_length) > 0.3 * ustrip(u"inch", L_strip)

    # Reported V_steel should match the post-fix hand calc within ~5 %.
    @test isapprox(V_actual_in3, V_post_fix_in3; rtol = 0.05)

    # The pre-fix takeoff would have been strictly less by the inter-band
    # T&S contribution; that contribution must be measurably positive.
    @test V_inter_band_in3 > 0.0
    @test V_actual_in3 ≥ V_pre_fix_in3 + 0.5 * V_inter_band_in3
end

# ─────────────────────────────────────────────────────────────────────────────
# Mat — Winkler FEA single-column reference
# ─────────────────────────────────────────────────────────────────────────────
#
# Reference: StructurePoint technical note "Finite Element Mesh Sizing
# Influence on Mat Foundation Reinforcement" (corpus:
# `sp-fea-mesh-sizing-mat-reinforcement`, page 4–5).  spMats is run on a
# 48 ft × 48 ft × 24 in. mat with a single 400 kip point load at the
# centre, soil-spring supported.  At the column-line section Y = 24 ft,
# the integrated y-direction required bottom reinforcement across the
# full 48 ft width is reported as **15.5 in²** for a 0.25 ft mesh and
# **22.68 in²** for an 8 ft mesh — a strength-based value with no T&S
# minimum applied (per the segment table on page 5; e.g. the outer 0-8 ft
# strip is 0.65–0.86 in², well below 0.0018·b·h).
#
# Our WinklerFEA path returns `max(As_strength, As_TS_min)` per layer with
# the §7.12.2.1 T&S minimum applied at the full-mat width.  For this load
# case the strength-based As across the full 48 ft width sits *under* the
# T&S floor (the spMats values 15.5–22.68 in² < 0.0018·576·24 = 24.88 in²),
# so the T&S minimum governs and the expected As is ≈ 24.88 in² per layer.
# The test pins to the T&S floor (which is what governs here) and verifies
# that punching is interior (single column at the centre of a 48 ft mat)
# with utilization well below 1.0 — i.e. the depth iteration must NOT
# bump h above the imposed minimum 24 in.  That last assertion guards
# against the prior `is_edge`/`is_corner` misclassification bug that drove
# h to 36 in. for this exact geometry.

println("\n--- Winkler FEA: 48 ft × 48 ft × 24 in. mat, 400 kip center load ---")

dem_center = FoundationDemand(1; Pu = 400.0kip, Ps = 280.0kip,
                                 c1 = 18.0u"inch", c2 = 18.0u"inch",
                                 shape = :rectangular)
positions_center = [(24.0u"ft", 24.0u"ft")]
soil_center      = Soil(2.0ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa";
                        ks = 100_000.0u"kN/m^3")  # ~ medium-dense reference

opts_fea = MatParams(;
    material         = RC_4000_60,
    bar_size_x       = 8,
    bar_size_y       = 8,
    cover            = 3.0u"inch",
    min_depth        = 24.0u"inch",
    depth_increment  = 1.0u"inch",
    edge_overhang    = 24.0u"ft",   # locks plan to the 48 × 48 ft reference
    analysis_method  = WinklerFEA(),
)

r_fea_ref = design_footing(MatFoundation(), [dem_center], positions_center,
                           soil_center; opts = opts_fea)

B_fea_ft   = ustrip(u"ft",   r_fea_ref.B)
Lm_fea_ft  = ustrip(u"ft",   r_fea_ref.L_ftg)
h_fea_in   = ustrip(u"inch", r_fea_ref.D)
Asy_fea_in2 = ustrip(u"inch^2", r_fea_ref.As_y_bot)
Asx_fea_in2 = ustrip(u"inch^2", r_fea_ref.As_x_bot)
util_fea    = r_fea_ref.utilization

# spMats published reference range across the strength-only fine and coarse
# meshes for the same mat: see corpus citation in the block comment above.
sp_min_in2 = 15.5
sp_max_in2 = 22.68

# ACI T&S minimum (Grade 60: 0.0018·b·h) gives the floor our pipeline
# applies on top of the strength-based As — used as a sanity bracket.
fy_psi_test  = ustrip(u"psi", opts_fea.material.rebar.Fy)
ρ_min_test   = fy_psi_test == 60_000.0 ? 0.0018 :
               fy_psi_test <  60_000.0 ? 0.0020 :
               max(0.0014, 0.0018 * 60_000.0 / fy_psi_test)
As_min_TS_in2 = ρ_min_test *
                ustrip(u"inch", r_fea_ref.B) *
                ustrip(u"inch", r_fea_ref.D)

println("  Plan: B = $(round(B_fea_ft, digits=2)) ft, Lm = $(round(Lm_fea_ft, digits=2)) ft, h = $(round(h_fea_in, digits=1)) in.")
println("  As_x_bot = $(round(Asx_fea_in2, digits=2)) in², As_y_bot = $(round(Asy_fea_in2, digits=2)) in², utilization = $(round(util_fea, digits=3))")
println("  spMats reference strength-only range @ Y=24 ft: [$(sp_min_in2), $(sp_max_in2)] in²")
println("  ACI 318-11 §7.12.2.1 T&S floor for full mat width: $(round(As_min_TS_in2, digits=2)) in²")

@testset "Mat WinklerFEA: 48 ft × 48 ft single-column reference" begin
    # Geometry — `edge_overhang = 24 ft` should pin plan dimensions exactly.
    @test isapprox(B_fea_ft,  48.0; atol = 0.5)
    @test isapprox(Lm_fea_ft, 48.0; atol = 0.5)
    # Thickness should remain at the imposed minimum (400 kip / 24 in. is
    # well below the punching capacity of an 18 in. column on a 24 in. mat).
    @test isapprox(h_fea_in, 24.0; atol = 0.5)

    # Square mat under a single concentric load → symmetric reinforcement.
    @test isapprox(Asx_fea_in2, Asy_fea_in2; rtol = 0.05)

    # Single column at the geometric centre of a 48 ft mat — the critical
    # section sits ~22 ft inside the mat edge, well clear of any boundary,
    # so punching must be interior.  Vu ≈ 400 kip with bo = 4·(c+d) = 152
    # in. and d = h - cover - db ≈ 20 in. → ϕVc ≈ 577 kip → util ≈ 0.69.
    @test 0.5 ≤ util_fea ≤ 0.85

    # Strength-based As (from the FEA moments × full mat width) is below
    # the T&S floor for this load, so all four layers should pin to T&S
    # minimum within ±5% (any larger overshoot signals strength governs
    # somewhere — possible if the FEA peak m/m × Lm exceeds T&S).
    @test isapprox(Asy_fea_in2, As_min_TS_in2; rtol = 0.05)
    @test isapprox(Asx_fea_in2, As_min_TS_in2; rtol = 0.05)

    # Cross-check against the spMats strength-only range as a sanity bound:
    # since T&S governs, our result must be ≥ both spMats bounds (they are
    # the strength-only floor; we add the §7.12.2.1 minimum on top).
    @test Asy_fea_in2 ≥ sp_max_in2
    @test Asx_fea_in2 ≥ sp_max_in2
end

println("\n=== All foundation rebar quantity tests passed ===")
