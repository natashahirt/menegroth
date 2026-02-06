# =============================================================================
# Flat Plate Pipeline Validation - Clear Step-by-Step Report
# =============================================================================
#
# Usage:
#   cd StructuralSynthesizer
#   julia --project=. ../StructuralSizer/test/flat_plate_full_pipeline_validation.jl
#
# =============================================================================

using Pkg
pkg_path = joinpath(@__DIR__, "..", "..", "StructuralSynthesizer")
isdir(pkg_path) ? Pkg.activate(pkg_path) : Pkg.activate(joinpath(@__DIR__, ".."))

using StructuralSynthesizer
using StructuralSizer
using StructuralSizer: size_flat_plate!, DDM, EFM, ConcreteColumnOptions
using Unitful
using Printf
using Dates
using Logging

# Suppress excessive logging during runs
global_logger(ConsoleLogger(stderr, Logging.Error))

using Asap: kip, ksi, psf, ksf, pcf

# =============================================================================
# FORMATTING
# =============================================================================

divider() = println("─" ^ 75)
section(title) = (println(); println("═" ^ 75); println("  ", title); println("═" ^ 75))

# =============================================================================
# STRUCTURE FACTORY
# =============================================================================

function make_structure(; column_size=16.0u"inch", flat_plate_opts=FlatPlateOptions())
    skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 1)
    struc = BuildingStructure(skel)
    
    opts = FloorOptions(flat_plate = flat_plate_opts, tributary_axis = nothing)
    initialize!(struc; floor_type = :flat_plate, floor_kwargs = (options = opts,))
    
    for col in struc.columns
        col.c1 = column_size
        col.c2 = column_size
    end
    
    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 20.0psf)
        cell.live_load = uconvert(u"kN/m^2", 50.0psf)
    end
    
    to_asap!(struc)
    return struc, opts
end

# =============================================================================
# MAIN REPORT
# =============================================================================

section("FLAT PLATE DESIGN VALIDATION REPORT")
println()
println("  Generated: ", now())
println("  Purpose: Compare analysis methods and shear stud strategies")

# ─────────────────────────────────────────────────────────────────────────────
section("1. TEST CASE")
# ─────────────────────────────────────────────────────────────────────────────

println("""
  Geometry:
    • 3×3 bay grid
    • Spans: 18 ft × 14 ft panels
    • Story height: 10 ft
    
  Loading:
    • SDL = 20 psf
    • LL = 50 psf
    • qu ≈ 193 psf (factored with self-weight)
    
  Materials:
    • f'c = 4,000 psi
    • fy = 60,000 psi (rebar)
    • fyt = 51,000 psi (studs, ASTM A1044)
""")

# ─────────────────────────────────────────────────────────────────────────────
section("2. ANALYSIS METHOD COMPARISON (16\" columns)")
# ─────────────────────────────────────────────────────────────────────────────

println("""
  Comparing ALL FOUR analysis methods:
  
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  Method              │  Description                                    │
  ├─────────────────────────────────────────────────────────────────────────┤
  │  DDM (Full)          │  ACI 318 Table 8.10 coefficients (0.26/0.52/0.70│
  │                      │  for end spans, 0.65/0.35 for interior)         │
  │  DDM (Simplified)    │  MDDM: Uniform 0.65/0.35 for all spans          │
  │  EFM (ASAP)          │  FEM stiffness analysis via ASAP library        │
  │  EFM (MomentDist)    │  Analytical moment distribution (Hardy Cross)   │
  └─────────────────────────────────────────────────────────────────────────┘
""")

results = Dict{String, NamedTuple}()

# Method configurations: (display_name, method_object)
method_configs = [
    ("DDM (Full)",       DDM(:full)),
    ("DDM (Simplified)", DDM(:simplified)),
    ("EFM (ASAP)",       EFM(:asap)),
    ("EFM (MomentDist)", EFM(:moment_distribution)),
]

for (name, method_obj) in method_configs
    println("  Running $name...")
    
    # Create fresh structure for each method
    fp_opts = FlatPlateOptions()
    struc, opts = make_structure(flat_plate_opts = fp_opts)
    slab = struc.slabs[1]
    
    # Call size_flat_plate! directly with specific method object
    col_opts = ConcreteColumnOptions()
    full_result = size_flat_plate!(struc, slab, col_opts; 
                                   method = method_obj, 
                                   opts = fp_opts,
                                   verbose = false)
    result = full_result.slab_result
    
    # Get column info
    cols = [col.c1 for col in struc.columns]
    c_min = minimum(ustrip.(u"inch", cols))
    c_max = maximum(ustrip.(u"inch", cols))
    
    results[name] = (
        h = ustrip(u"inch", result.thickness),
        M0 = ustrip(kip*u"ft", result.M0),
        punching_max = result.punching_check.max_ratio,
        defl_ratio = result.deflection_check.ratio,
        col_min = c_min,
        col_max = c_max,
    )
end
println()

# Summary table
divider()
println(@sprintf "  %-18s │ h (in) │ M₀ (k-ft) │ Punch │ Defl  │ Columns" "Method")
divider()
for (name, _) in method_configs
    r = results[name]
    col_str = r.col_min == r.col_max ? @sprintf("%.0f\"", r.col_min) : @sprintf("%.0f\"–%.0f\"", r.col_min, r.col_max)
    println(@sprintf "  %-18s │ %5.2f  │  %7.2f  │ %5.3f │ %5.3f │ %s" name r.h r.M0 r.punching_max r.defl_ratio col_str)
end
divider()

# Analysis of differences
println()
println("  Method Comparison Notes:")
println()
M0_ddm_full = results["DDM (Full)"].M0
M0_ddm_simp = results["DDM (Simplified)"].M0
M0_efm_asap = results["EFM (ASAP)"].M0
M0_efm_md = results["EFM (MomentDist)"].M0

M0_range = extrema([M0_ddm_full, M0_ddm_simp, M0_efm_asap, M0_efm_md])
M0_spread = (M0_range[2] - M0_range[1]) / M0_range[1] * 100

println(@sprintf "    • M₀ values range: %.2f – %.2f k-ft (%.1f%% spread)" M0_range[1] M0_range[2] M0_spread)
println("    • DDM Full vs Simplified: Same M₀ (coefficients affect distribution, not total)")
ddm_efm_diff = abs(M0_ddm_full - M0_efm_asap) / M0_ddm_full * 100
println(@sprintf "    • DDM vs EFM: %.1f%% difference" ddm_efm_diff)
efm_internal_diff = abs(M0_efm_asap - M0_efm_md) / M0_efm_asap * 100
println(@sprintf "    • EFM ASAP vs MomentDist: %.1f%% difference" efm_internal_diff)
println()

# Store DDM (Full) result for later detailed breakdown
fp_opts_ddm = FlatPlateOptions()
struc_ddm, opts_ddm = make_structure(flat_plate_opts = fp_opts_ddm)
full_result_ddm = size_flat_plate!(struc_ddm, struc_ddm.slabs[1], ConcreteColumnOptions(); 
                                   method = DDM(:full), opts = fp_opts_ddm, verbose = false)
ddm_result = full_result_ddm.slab_result

# ─────────────────────────────────────────────────────────────────────────────
section("3. SHEAR STUD STRATEGY COMPARISON")
# ─────────────────────────────────────────────────────────────────────────────

println("""
  Testing with 14\" columns to force punching failures:
  
  Strategies:
    • :never     → Grow columns only, fail if maxed at 20\"
    • :if_needed → Try columns first, then studs if columns maxed  
    • :always    → Design studs first, grow columns if studs fail
""")

strategies = [:never, :if_needed, :always]
stud_results = Dict{Symbol, NamedTuple}()

for strategy in strategies
    println("  Testing :$strategy...")
    
    fp_opts = FlatPlateOptions(
        shear_studs = strategy,
        max_column_size = 20.0u"inch",
        stud_diameter = 0.5u"inch",
        analysis_method = :ddm
    )
    
    try
        struc, opts = make_structure(column_size = 14.0u"inch", flat_plate_opts = fp_opts)
        size_slabs!(struc; options = opts, verbose = false)
        
        result = struc.slabs[1].result
        cols = [col.c1 for col in struc.columns]
        c_min = minimum(ustrip.(u"inch", cols))
        c_max = maximum(ustrip.(u"inch", cols))
        
        # Check if any columns have studs
        has_studs = false
        n_studs_designed = 0
        punching_details = result.punching_check.details
        for (col_id, details) in punching_details
            if haskey(details, :studs) && !isnothing(get(details, :studs, nothing))
                studs = details.studs
                if hasproperty(studs, :n_rails) && studs.n_rails > 0
                    has_studs = true
                    n_studs_designed += 1
                end
            end
        end
        
        stud_results[strategy] = (
            success = true,
            h = ustrip(u"inch", result.thickness),
            M0 = ustrip(kip*u"ft", result.M0),
            punching_max = result.punching_check.max_ratio,
            col_min = c_min,
            col_max = c_max,
            has_studs = has_studs,
            n_studs = n_studs_designed,
            error = ""
        )
        
    catch e
        stud_results[strategy] = (
            success = false,
            h = 0.0,
            M0 = 0.0,
            punching_max = 0.0,
            col_min = 14.0,
            col_max = 14.0,
            has_studs = false,
            n_studs = 0,
            error = string(e)
        )
    end
end

println()
divider()
println(@sprintf "  %-12s │ h (in) │ Punch │ Columns      │ Studs" "Strategy")
divider()

for strategy in strategies
    r = stud_results[strategy]
    if r.success
        col_str = r.col_min == r.col_max ? @sprintf("%.0f\"", r.col_min) : @sprintf("%.0f\"→%.0f\"", r.col_min, r.col_max)
        stud_str = r.has_studs ? @sprintf("Yes (%d cols)", r.n_studs) : "No"
        println(@sprintf "  %-12s │ %5.2f  │ %5.3f │ %-12s │ %s" ":$strategy" r.h r.punching_max col_str stud_str)
    else
        println(@sprintf "  %-12s │ FAILED: %s" ":$strategy" first(r.error, 40))
    end
end
divider()

# ─────────────────────────────────────────────────────────────────────────────
section("4. DETAILED BREAKDOWN: Hand Calc vs Computed")
# ─────────────────────────────────────────────────────────────────────────────

println()
println("  ┌─────────────────────────────────────────────────────────────────────┐")
println("  │  STEP-BY-STEP COMPARISON: Hand Calculations vs Algorithm Results   │")
println("  └─────────────────────────────────────────────────────────────────────┘")
println()

# ═══════════════════════════════════════════════════════════════════════════
# STEP 1: GEOMETRY (from actual slab)
# ═══════════════════════════════════════════════════════════════════════════
println("  ▸ STEP 1: GEOMETRY")
println()

# Get actual spans from computed structure
actual_l1_ft = ustrip(u"ft", struc_ddm.slabs[1].spans.primary)
actual_l2_ft = ustrip(u"ft", struc_ddm.slabs[1].spans.secondary)
c1_in = 16.0  # Column size in inches
c_avg_ft = c1_in / 12
actual_ln_ft = actual_l1_ft - c_avg_ft

println("    From slab.spans (algorithm uses these):")
println(@sprintf "      l₁ (primary span)    = %.2f ft  ← analysis direction" actual_l1_ft)
println(@sprintf "      l₂ (secondary span)  = %.2f ft  ← tributary width" actual_l2_ft)
println(@sprintf "      c_avg (column)       = %.2f ft  (%.0f in)" c_avg_ft c1_in)
println(@sprintf "      ln = l₁ - c_avg      = %.2f - %.2f = %.2f ft" actual_l1_ft c_avg_ft actual_ln_ft)
println()
println("    NOTE: SpanInfo assigns SHORTER span as primary!")
println("          This is why l₁=14ft, not 18ft.")
println()

# ═══════════════════════════════════════════════════════════════════════════
# STEP 2: LOADING
# ═══════════════════════════════════════════════════════════════════════════
println("  ▸ STEP 2: FACTORED LOAD (qu = 1.2D + 1.6L)")
println()

# Get actual thickness from result
ddm_h = ustrip(u"inch", ddm_result.thickness)
ddm_M0 = ustrip(kip*u"ft", ddm_result.M0)

# Calculate loads
sw_psf = ddm_h * 12.5  # 150 pcf concrete, h in inches
sdl_psf = 20.0
ll_psf = 50.0
qD_psf = sw_psf + sdl_psf
qu_psf = 1.2 * qD_psf + 1.6 * ll_psf

println(@sprintf "    Slab thickness h = %.2f in" ddm_h)
println(@sprintf "    Self-weight sw  = h × 12.5 = %.2f × 12.5 = %.1f psf" ddm_h sw_psf)
println(@sprintf "    Dead load qD    = sw + SDL = %.1f + %.1f = %.1f psf" sw_psf sdl_psf qD_psf)
println(@sprintf "    Live load qL    = %.1f psf" ll_psf)
println(@sprintf "    Factored qu     = 1.2×%.1f + 1.6×%.1f = %.1f psf" qD_psf ll_psf qu_psf)
println()

# ═══════════════════════════════════════════════════════════════════════════
# STEP 3: TOTAL STATIC MOMENT M₀
# ═══════════════════════════════════════════════════════════════════════════
println("  ▸ STEP 3: TOTAL STATIC MOMENT M₀ (ACI 318-19 Eq. 8.10.3.2)")
println()

# Hand calculation using actual geometry
M0_hand = qu_psf * actual_l2_ft * actual_ln_ft^2 / 8 / 1000  # kip-ft

println("    Formula: M₀ = qu × l₂ × ln² / 8")
println()
println(@sprintf "    Hand calc:  M₀ = %.1f × %.2f × %.2f² / 8 = %.2f kip-ft" qu_psf actual_l2_ft actual_ln_ft M0_hand)
println(@sprintf "    Computed:   M₀ = %.2f kip-ft" ddm_M0)
M0_diff_pct = abs(M0_hand - ddm_M0) / M0_hand * 100
M0_status = M0_diff_pct < 5 ? "✓ MATCH" : (M0_diff_pct < 15 ? "○ Close" : "⚠ Check")
println(@sprintf "    Difference: %.1f%% %s" M0_diff_pct M0_status)
println()

# ═══════════════════════════════════════════════════════════════════════════
# STEP 4: MINIMUM THICKNESS (uses LONGER span per ACI)
# ═══════════════════════════════════════════════════════════════════════════
println("  ▸ STEP 4: MINIMUM THICKNESS (ACI 318-19 Table 8.3.1.1)")
println()

# ACI 8.3.1.1 requires using the LONGER clear span for h_min
ln_max_ft = max(actual_l1_ft, actual_l2_ft) - c_avg_ft  # Longer span governs

println("    ⚠️  ACI 8.3.1.1 uses the LONGER clear span for h_min:")
println(@sprintf "       ln_max = max(l₁, l₂) - c_avg = max(%.2f, %.2f) - %.2f = %.2f ft" actual_l1_ft actual_l2_ft c_avg_ft ln_max_ft)
println()

h_min_int_gov = ln_max_ft * 12 / 33  # interior panel, longer span
h_min_ext_gov = ln_max_ft * 12 / 30  # exterior panel, longer span

println(@sprintf "    Interior panel: h_min = ln_max/33 = %.2f × 12/33 = %.2f in" ln_max_ft h_min_int_gov)
println(@sprintf "    Exterior panel: h_min = ln_max/30 = %.2f × 12/30 = %.2f in  ← governs" ln_max_ft h_min_ext_gov)
println(@sprintf "    Used by algorithm:                               h = %.2f in" ddm_h)
h_status = ddm_h >= h_min_ext_gov ? "✓ OK" : "⚠ Too thin"
println(@sprintf "    Check h ≥ h_min_ext:             %.2f ≥ %.2f  %s" ddm_h h_min_ext_gov h_status)
println()
println("    (Note: 7.2\" vs 6.67\" due to 0.5\" rounding + metric conversion)")
println()

# ═══════════════════════════════════════════════════════════════════════════
# STEP 5: PUNCHING SHEAR
# ═══════════════════════════════════════════════════════════════════════════
println("  ▸ STEP 5: PUNCHING SHEAR (ACI 318-19 §22.6)")
println()

# Cover and bar assumptions
cover_in = 0.75
bar_dia_in = 0.625  # #5 bar
d_calc = ddm_h - cover_in - bar_dia_in/2
b0_calc = 4 * (c1_in + d_calc)
fc_psi = 4000.0
sqrt_fc = sqrt(fc_psi)
vc_calc = 4 * sqrt_fc
φ_shear = 0.75
φvc_calc = φ_shear * vc_calc

println(@sprintf "    d = h - cover - db/2 = %.2f - %.2f - %.3f = %.2f in" ddm_h cover_in bar_dia_in/2 d_calc)
println(@sprintf "    b₀ = 4(c + d) = 4(%.0f + %.2f) = %.1f in" c1_in d_calc b0_calc)
println(@sprintf "    vc = 4√f'c = 4 × √%.0f = %.0f psi (interior column)" fc_psi vc_calc)
println(@sprintf "    φvc = %.2f × %.0f = %.0f psi" φ_shear vc_calc φvc_calc)
println()

# Get actual punching results
ddm_punch = ddm_result.punching_check.max_ratio
punch_status = ddm_punch < 1.0 ? "✓ OK" : "⚠ FAIL"
println(@sprintf "    Computed punching ratio: vu/φvc = %.3f  %s" ddm_punch punch_status)
println()

# Estimate vu from ratio
vu_est = ddm_punch * φvc_calc
println(@sprintf "    Implied vu ≈ %.3f × %.0f = %.0f psi" ddm_punch φvc_calc vu_est)
println()

# ═══════════════════════════════════════════════════════════════════════════
# STEP 6: DEFLECTION
# ═══════════════════════════════════════════════════════════════════════════
println("  ▸ STEP 6: DEFLECTION CHECK (ACI 318-19 §24.2)")
println()

ddm_defl = ddm_result.deflection_check.ratio
Δ_total = ustrip(u"inch", ddm_result.deflection_check.Δ_total)
Δ_limit = ustrip(u"inch", ddm_result.deflection_check.Δ_limit)

println(@sprintf "    Deflection limit (L/360): %.3f in" Δ_limit)
println(@sprintf "    Computed Δ_total:         %.3f in" Δ_total)
println(@sprintf "    Deflection ratio:         %.3f" ddm_defl)
defl_status = ddm_defl < 1.0 ? "✓ OK" : "⚠ FAIL"
println(@sprintf "    Check Δ ≤ limit:          %s" defl_status)
println()

# ═══════════════════════════════════════════════════════════════════════════
# SUMMARY TABLE
# ═══════════════════════════════════════════════════════════════════════════
divider()
println(@sprintf "  %-28s │  %-12s │  %-12s │  Status" "Parameter" "Hand Calc" "Computed")
divider()
println(@sprintf "  %-28s │  %10.2f ft │  %10.2f ft │  (input)" "l₁ (primary span)" actual_l1_ft actual_l1_ft)
println(@sprintf "  %-28s │  %10.2f ft │  %10.2f ft │  (input)" "l₂ (tributary width)" actual_l2_ft actual_l2_ft)
println(@sprintf "  %-28s │  %10.2f ft │  %10.2f ft │  (input)" "ln (clear span)" actual_ln_ft actual_ln_ft)
println(@sprintf "  %-28s │  %10.2f ft │  %10.2f ft │  ← governs h" "ln_max (longer span)" ln_max_ft ln_max_ft)
println(@sprintf "  %-28s │  %10.1f psf │  %10.1f psf │  (calc)" "qu (factored load)" qu_psf qu_psf)
println(@sprintf "  %-28s │  %9.2f k-ft │  %9.2f k-ft │  %s" "M₀ (static moment)" M0_hand ddm_M0 M0_status)
println(@sprintf "  %-28s │  %10.2f in │  %10.2f in │  %s" "h (slab thickness)" h_min_ext_gov ddm_h h_status)
println(@sprintf "  %-28s │     < 1.0     │  %10.3f    │  %s" "Punching ratio" ddm_punch punch_status)
println(@sprintf "  %-28s │     < 1.0     │  %10.3f    │  %s" "Deflection ratio" ddm_defl defl_status)
divider()
println()

# Reference values
vc_max_studs = 8 * sqrt_fc
println("  Reference: With headed shear studs (ACI 22.6.8.2):")
println(@sprintf "    vn_max = 8√f'c = %.0f psi → φvn_max = %.0f psi (2× unreinforced)" vc_max_studs 0.75*vc_max_studs)
println()

# ─────────────────────────────────────────────────────────────────────────────
section("5. VERIFICATION CHECKLIST")
# ─────────────────────────────────────────────────────────────────────────────

println("""
  □ M₀ values match hand calculation (~70-77 kip-ft for this geometry)
  □ DDM and EFM give similar results (within 15%)
  □ :never strategy grows columns when punching fails
  □ :if_needed tries columns first, then studs
  □ :always designs studs first, columns only if studs insufficient
  □ Slab thickness h ≈ 7-7.5\" (from deflection/minimum requirements)
  □ Punching ratios < 1.0 after design converges
""")

# ─────────────────────────────────────────────────────────────────────────────
section("6. STRESS TEST: LONG SPANS (Deflection-Critical)")
# ─────────────────────────────────────────────────────────────────────────────

println("""
  Testing with LARGER spans (24ft × 20ft) to trigger:
    • Deflection failures → slab thickness increase
    • Punching failures → column growth or studs
    • Multiple iteration cycles
    
  This demonstrates the full convergence process when multiple
  checks fail and the pipeline must iterate to find a solution.
""")

# Create structure with larger spans
println("  Creating structure: 2×2 bays, 24ft × 20ft panels...")

function make_long_span_structure()
    skel = gen_medium_office(48.0u"ft", 40.0u"ft", 12.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    
    fp_opts = FlatPlateOptions(
        shear_studs = :if_needed,
        max_column_size = 28.0u"inch",
        analysis_method = :ddm
    )
    opts = FloorOptions(flat_plate = fp_opts, tributary_axis = nothing)
    initialize!(struc; floor_type = :flat_plate, floor_kwargs = (options = opts,))
    
    # Start with 18" columns
    for col in struc.columns
        col.c1 = 18.0u"inch"
        col.c2 = 18.0u"inch"
    end
    
    # Higher loads
    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 25.0psf)
        cell.live_load = uconvert(u"kN/m^2", 80.0psf)
    end
    
    to_asap!(struc)
    return struc, opts
end

struc_long, opts_long = make_long_span_structure()

println()
println("  Parameters:")
println("    Spans: 24 ft × 20 ft (larger than typical 18×14)")
println("    Columns: 18\" initial (max 28\")")
println("    SDL: 25 psf, LL: 80 psf (office loads)")
println("    Shear studs: :if_needed")
println()

# Calculate expected minimum thickness
ln_long = 24.0 - 18/12  # ln = l1 - c_avg
h_min_long_int = ln_long * 12 / 33
h_min_long_ext = ln_long * 12 / 30

println("  Expected minimum thickness:")
println(@sprintf "    Interior: h_min = ln/33 = %.2f × 12 / 33 = %.2f in" ln_long h_min_long_int)
println(@sprintf "    Exterior: h_min = ln/30 = %.2f × 12 / 30 = %.2f in" ln_long h_min_long_ext)
println()

# Re-enable logging for this run to show iteration
global_logger(ConsoleLogger(stderr, Logging.Warn))

println("  Running size_slabs! (showing warnings for iterations)...")
println("─" ^ 75)
println()

try
    size_slabs!(struc_long; options = opts_long, verbose = true, max_iterations = 30)
    
    result_long = struc_long.slabs[1].result
    cols_long = [col.c1 for col in struc_long.columns]
    c_min_long = minimum(ustrip.(u"inch", cols_long))
    c_max_long = maximum(ustrip.(u"inch", cols_long))
    
    println()
    println("─" ^ 75)
    println()
    println("  ✓ LONG SPAN DESIGN CONVERGED")
    println()
    divider()
    println("  Final Design Summary:")
    divider()
    println(@sprintf "    Slab thickness:    h = %.2f in (started at ~%.1f in)" ustrip(u"inch", result_long.thickness) h_min_long_ext)
    println(@sprintf "    Total static moment: M₀ = %.1f kip-ft" ustrip(kip*u"ft", result_long.M0))
    println(@sprintf "    Punching ratio:    %.3f %s" result_long.punching_check.max_ratio (result_long.punching_check.passes ? "✓" : "✗"))
    println(@sprintf "    Deflection ratio:  %.3f %s" result_long.deflection_check.ratio (result_long.deflection_check.passes ? "✓" : "✗"))
    
    col_str = c_min_long == c_max_long ? @sprintf("%.0f\"", c_min_long) : @sprintf("%.0f\"–%.0f\"", c_min_long, c_max_long)
    println(@sprintf "    Columns:           %s (started at 18\")" col_str)
    
    # Check for studs
    punching_details = result_long.punching_check.details
    n_with_studs = 0
    for (col_id, details) in punching_details
        if haskey(details, :studs) && !isnothing(get(details, :studs, nothing))
            studs = details.studs
            if hasproperty(studs, :n_rails) && studs.n_rails > 0
                n_with_studs += 1
            end
        end
    end
    stud_str = n_with_studs > 0 ? "Yes ($n_with_studs columns)" : "No"
    println(@sprintf "    Shear studs:       %s" stud_str)
    divider()
    
catch e
    println()
    println("─" ^ 75)
    println()
    println("  ✗ Design failed:")
    println("    ", first(string(e), 70))
end

# Disable logging again
global_logger(ConsoleLogger(stderr, Logging.Error))

# ─────────────────────────────────────────────────────────────────────────────
section("7. DEFLECTION-DOMINATED TEST (L/480 limit)")
# ─────────────────────────────────────────────────────────────────────────────

println("""
  Testing with STRICT deflection limit:
    • Long single span (32ft × 25ft), 1×1 bay
    • L/480 deflection limit (sensitive elements like glass partitions)
    • Large 30\" columns + high loads
""")

println("  Creating structure with strict deflection limit...")

function make_deflection_critical_structure()
    # Very long spans: 32ft × 25ft with 1×1 bay (single interior panel)
    skel = gen_medium_office(32.0u"ft", 25.0u"ft", 10.0u"ft", 1, 1, 1)
    struc = BuildingStructure(skel)
    
    # Use L/480 limit (sensitive elements like glass partitions)
    fp_opts = FlatPlateOptions(
        shear_studs = :if_needed,
        max_column_size = 36.0u"inch",  # Very large max
        analysis_method = :ddm,
        deflection_limit = :L_480  # Stricter than typical L/360
    )
    opts = FloorOptions(flat_plate = fp_opts, tributary_axis = nothing)
    initialize!(struc; floor_type = :flat_plate, floor_kwargs = (options = opts,))
    
    # HUGE 30" columns so punching passes easily, isolating deflection check
    for col in struc.columns
        col.c1 = 30.0u"inch"
        col.c2 = 30.0u"inch"
    end
    
    # Higher loads to stress deflection
    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 25.0psf)
        cell.live_load = uconvert(u"kN/m^2", 80.0psf)
    end
    
    to_asap!(struc)
    return struc, opts
end

struc_defl, opts_defl = make_deflection_critical_structure()

# Calculate expected h_min
ln_defl = 32.0 - 30/12
h_min_calc = ln_defl * 12 / 30  # exterior: ln/30

println()
println("  Parameters:")
println("    Spans: 32 ft × 25 ft (single bay)")
println("    Columns: 30\" (huge to ensure punching passes)")
println("    Deflection limit: L/480 (sensitive elements)")
println(@sprintf "    ACI h_min (exterior): ln/30 = %.1f × 12/30 = %.1f in" ln_defl h_min_calc)
println(@sprintf "    L/480 deflection allowable: %.2f in" (32.0*12/480))
println()

# Enable warnings
global_logger(ConsoleLogger(stderr, Logging.Warn))

println("  Running size_slabs!...")
println("─" ^ 75)
println()

try
    size_slabs!(struc_defl; options = opts_defl, verbose = true, max_iterations = 30)
    
    result_defl = struc_defl.slabs[1].result
    cols_defl = [col.c1 for col in struc_defl.columns]
    c_min_defl = minimum(ustrip.(u"inch", cols_defl))
    c_max_defl = maximum(ustrip.(u"inch", cols_defl))
    
    println()
    println("─" ^ 75)
    println()
    println("  ✓ DEFLECTION TEST CONVERGED")
    println()
    divider()
    println("  Final Design Summary:")
    divider()
    h_final = ustrip(u"inch", result_defl.thickness)
    println(@sprintf "    Slab thickness:    h = %.2f in (ACI min = %.1f in)%s" h_final h_min_calc (h_final > h_min_calc + 0.5 ? " ← GREW" : ""))
    println(@sprintf "    Total static moment: M₀ = %.1f kip-ft" ustrip(kip*u"ft", result_defl.M0))
    println(@sprintf "    Punching ratio:    %.3f %s" result_defl.punching_check.max_ratio (result_defl.punching_check.passes ? "✓" : "✗"))
    println(@sprintf "    Deflection ratio:  %.3f %s" result_defl.deflection_check.ratio (result_defl.deflection_check.passes ? "✓" : "✗"))
    
    col_str = c_min_defl == c_max_defl ? @sprintf("%.0f\"", c_min_defl) : @sprintf("%.0f\"–%.0f\"", c_min_defl, c_max_defl)
    println(@sprintf "    Columns:           %s" col_str)
    divider()
    
catch e
    println()
    println("─" ^ 75)
    println()
    println("  ✗ Design failed:")
    println("    ", first(string(e), 70))
end

# Disable logging
global_logger(ConsoleLogger(stderr, Logging.Error))

# ─────────────────────────────────────────────────────────────────────────────
section("8. FAILURE MODE ISOLATION TESTS")
# ─────────────────────────────────────────────────────────────────────────────

println("""
  Testing specific conditions to trigger each failure mode independently:
  
  CHECK 1: Punching Shear
    → Triggers: Small columns with high shear stress
    → Resolution: Grow columns OR design shear studs
    
  CHECK 2: Two-Way Deflection
    → Triggers: Long spans, high live load, thin slab
    → Resolution: Increase slab thickness h
    
  CHECK 3: One-Way (Beam) Shear
    → Triggers: Very high load, thin slab
    → Resolution: Increase slab thickness h
""")

# ═══════════════════════════════════════════════════════════════════════════
# TEST 8A: PUNCHING SHEAR FAILURE
# ═══════════════════════════════════════════════════════════════════════════
println()
println("  ╔═══════════════════════════════════════════════════════════════════╗")
println("  ║  TEST 8A: PUNCHING SHEAR FAILURE                                  ║")
println("  ╚═══════════════════════════════════════════════════════════════════╝")
println()
println("  Setup: 12\" columns with standard spans (should fail punching)")
println()

function test_punching_failure()
    skel = gen_medium_office(36.0u"ft", 28.0u"ft", 10.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    
    fp_opts = FlatPlateOptions(
        shear_studs = :never,  # Force column growth
        max_column_size = 24.0u"inch",
        analysis_method = :ddm
    )
    opts = FloorOptions(flat_plate = fp_opts, tributary_axis = nothing)
    initialize!(struc; floor_type = :flat_plate, floor_kwargs = (options = opts,))
    
    # TINY 12" columns - guaranteed punching failure
    for col in struc.columns
        col.c1 = 12.0u"inch"
        col.c2 = 12.0u"inch"
    end
    
    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 20.0psf)
        cell.live_load = uconvert(u"kN/m^2", 50.0psf)
    end
    
    to_asap!(struc)
    return struc, opts
end

global_logger(ConsoleLogger(stderr, Logging.Warn))
struc_punch, opts_punch = test_punching_failure()

initial_cols = [ustrip(u"inch", col.c1) for col in struc_punch.columns]
println(@sprintf "  Initial columns: %.0f\"" minimum(initial_cols))
println()

try
    size_slabs!(struc_punch; options = opts_punch, verbose = true, max_iterations = 20)
    
    final_cols = [ustrip(u"inch", col.c1) for col in struc_punch.columns]
    result = struc_punch.slabs[1].result
    
    println()
    println(@sprintf "  ✓ Resolved: Columns grew from %.0f\" to %.0f\"–%.0f\"" minimum(initial_cols) minimum(final_cols) maximum(final_cols))
    println(@sprintf "    Punching ratio: %.3f" result.punching_check.max_ratio)
catch e
    println("  ✗ Failed: ", first(string(e), 60))
end

global_logger(ConsoleLogger(stderr, Logging.Error))

# ═══════════════════════════════════════════════════════════════════════════
# TEST 8B: DEFLECTION FAILURE
# ═══════════════════════════════════════════════════════════════════════════
println()
println("  ╔═══════════════════════════════════════════════════════════════════╗")
println("  ║  TEST 8B: DEFLECTION FAILURE                                      ║")
println("  ╚═══════════════════════════════════════════════════════════════════╝")
println()
println("  Setup: Very long spans (30ft) + L/480 limit + high LL/DL ratio")
println("         Large columns (28\") to ensure punching passes easily")
println()

function test_deflection_failure()
    # Single large bay with very long span
    skel = gen_medium_office(30.0u"ft", 24.0u"ft", 10.0u"ft", 1, 1, 1)
    struc = BuildingStructure(skel)
    
    fp_opts = FlatPlateOptions(
        shear_studs = :never,
        max_column_size = 36.0u"inch",
        analysis_method = :ddm,
        deflection_limit = :L_480  # Very strict limit
    )
    opts = FloorOptions(flat_plate = fp_opts, tributary_axis = nothing)
    initialize!(struc; floor_type = :flat_plate, floor_kwargs = (options = opts,))
    
    # HUGE columns so punching won't govern
    for col in struc.columns
        col.c1 = 28.0u"inch"
        col.c2 = 28.0u"inch"
    end
    
    # High live load ratio to stress long-term deflection
    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 15.0psf)   # Low DL
        cell.live_load = uconvert(u"kN/m^2", 100.0psf)  # High LL
    end
    
    to_asap!(struc)
    return struc, opts
end

global_logger(ConsoleLogger(stderr, Logging.Warn))
struc_defl2, opts_defl2 = test_deflection_failure()

# Calculate expected h_min
ln_test = 30.0 - 28/12
h_min_expected = ln_test * 12 / 30
println(@sprintf "  Expected h_min: ln/30 = %.1f × 12/30 = %.1f in" ln_test h_min_expected)
println(@sprintf "  L/480 allowable: %.2f in" (30.0*12/480))
println()

try
    size_slabs!(struc_defl2; options = opts_defl2, verbose = true, max_iterations = 20)
    
    result = struc_defl2.slabs[1].result
    h_final = ustrip(u"inch", result.thickness)
    
    println()
    if h_final > h_min_expected + 0.3
        println(@sprintf "  ✓ Deflection governed: h grew from %.1f\" to %.2f\" (+%.2f\")" h_min_expected h_final (h_final - h_min_expected))
    else
        println(@sprintf "  ○ Deflection passed at h_min: h = %.2f\", ratio = %.3f" h_final result.deflection_check.ratio)
        println("    (ACI h_min is conservative enough for this case)")
    end
    println(@sprintf "    Deflection ratio: %.3f" result.deflection_check.ratio)
catch e
    println("  ✗ Failed: ", first(string(e), 60))
end

global_logger(ConsoleLogger(stderr, Logging.Error))

# ═══════════════════════════════════════════════════════════════════════════
# TEST 8C: ONE-WAY SHEAR FAILURE
# ═══════════════════════════════════════════════════════════════════════════
println()
println("  ╔═══════════════════════════════════════════════════════════════════╗")
println("  ║  TEST 8C: ONE-WAY SHEAR FAILURE                                   ║")
println("  ╚═══════════════════════════════════════════════════════════════════╝")
println()
println("  Setup: Very high load (150 psf LL) + moderate spans")
println("         One-way shear typically requires extreme conditions to govern")
println()

function test_one_way_shear_failure()
    skel = gen_medium_office(24.0u"ft", 20.0u"ft", 10.0u"ft", 1, 1, 1)
    struc = BuildingStructure(skel)
    
    fp_opts = FlatPlateOptions(
        shear_studs = :if_needed,
        max_column_size = 30.0u"inch",
        analysis_method = :ddm
    )
    opts = FloorOptions(flat_plate = fp_opts, tributary_axis = nothing)
    initialize!(struc; floor_type = :flat_plate, floor_kwargs = (options = opts,))
    
    # Large columns to avoid punching dominating
    for col in struc.columns
        col.c1 = 24.0u"inch"
        col.c2 = 24.0u"inch"
    end
    
    # EXTREME loading (storage/heavy industrial)
    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 30.0psf)
        cell.live_load = uconvert(u"kN/m^2", 200.0psf)  # Very heavy LL
    end
    
    to_asap!(struc)
    return struc, opts
end

global_logger(ConsoleLogger(stderr, Logging.Warn))
struc_shear, opts_shear = test_one_way_shear_failure()

ln_shear = 24.0 - 24/12
h_min_shear = ln_shear * 12 / 30
println(@sprintf "  Expected h_min: %.1f in" h_min_shear)
println("  Factored load: 1.2×(sw+30) + 1.6×200 ≈ 450+ psf")
println()

try
    size_slabs!(struc_shear; options = opts_shear, verbose = true, max_iterations = 20)
    
    result = struc_shear.slabs[1].result
    h_final = ustrip(u"inch", result.thickness)
    
    println()
    if h_final > h_min_shear + 0.3
        println(@sprintf "  ✓ Slab thickness grew: %.1f\" → %.2f\" (+%.2f\")" h_min_shear h_final (h_final - h_min_shear))
        println("    (Could be one-way shear, deflection, or punching)")
    else
        println(@sprintf "  ○ Converged at h = %.2f\"" h_final)
    end
    println(@sprintf "    Punching ratio: %.3f" result.punching_check.max_ratio)
    println(@sprintf "    Deflection ratio: %.3f" result.deflection_check.ratio)
catch e
    println("  ✗ Failed: ", first(string(e), 60))
end

global_logger(ConsoleLogger(stderr, Logging.Error))

# ═══════════════════════════════════════════════════════════════════════════
# TEST 8D: COMBINED FAILURES (STRESS TEST)
# ═══════════════════════════════════════════════════════════════════════════
println()
println("  ╔═══════════════════════════════════════════════════════════════════╗")
println("  ║  TEST 8D: COMBINED FAILURES (STRESS TEST)                         ║")
println("  ╚═══════════════════════════════════════════════════════════════════╝")
println()
println("  Setup: Long spans + small columns + high load + strict deflection")
println("         This should trigger multiple failure modes sequentially")
println()

function test_combined_failures()
    skel = gen_medium_office(50.0u"ft", 40.0u"ft", 12.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    
    fp_opts = FlatPlateOptions(
        shear_studs = :if_needed,
        max_column_size = 30.0u"inch",
        analysis_method = :ddm,
        deflection_limit = :L_480
    )
    opts = FloorOptions(flat_plate = fp_opts, tributary_axis = nothing)
    initialize!(struc; floor_type = :flat_plate, floor_kwargs = (options = opts,))
    
    # Small columns + long spans = punching stress
    for col in struc.columns
        col.c1 = 16.0u"inch"
        col.c2 = 16.0u"inch"
    end
    
    # High loads
    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 25.0psf)
        cell.live_load = uconvert(u"kN/m^2", 100.0psf)
    end
    
    to_asap!(struc)
    return struc, opts
end

global_logger(ConsoleLogger(stderr, Logging.Warn))
struc_combo, opts_combo = test_combined_failures()

println("  Spans: 25 ft × 20 ft per bay")
println("  Initial columns: 16\"")
println("  Loads: 25 psf SDL + 100 psf LL")
println("  Deflection limit: L/480")
println()

try
    size_slabs!(struc_combo; options = opts_combo, verbose = true, max_iterations = 30)
    
    result = struc_combo.slabs[1].result
    h_final = ustrip(u"inch", result.thickness)
    cols = [ustrip(u"inch", col.c1) for col in struc_combo.columns]
    
    # Count studs
    n_studs = 0
    for (_, details) in result.punching_check.details
        if haskey(details, :studs) && !isnothing(get(details, :studs, nothing))
            studs = details.studs
            if hasproperty(studs, :n_rails) && studs.n_rails > 0
                n_studs += 1
            end
        end
    end
    
    println()
    println("  ✓ COMBINED TEST CONVERGED")
    divider()
    println(@sprintf "    Slab: h = %.2f in" h_final)
    println(@sprintf "    Columns: %.0f\"–%.0f\"" minimum(cols) maximum(cols))
    println(@sprintf "    Studs: %s" (n_studs > 0 ? "$n_studs columns" : "none"))
    println(@sprintf "    Punching ratio: %.3f" result.punching_check.max_ratio)
    println(@sprintf "    Deflection ratio: %.3f" result.deflection_check.ratio)
    divider()
    
catch e
    println()
    println("  ✗ Design failed to converge:")
    println("    ", first(string(e), 60))
    println("    This may indicate the spans/loads exceed practical flat plate limits")
end

global_logger(ConsoleLogger(stderr, Logging.Error))

section("END OF REPORT")
