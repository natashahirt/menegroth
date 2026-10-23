# =============================================================================
# FEA Options Quick-Start Guide
# =============================================================================
#
# Demonstrates how to pick between FEA configurations for flat plate design.
# Each configuration is a different FEA() method passed to FlatPlateOptions.
#
# Usage:
#   julia scripts/run_fea.jl
# =============================================================================


using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "StructuralSynthesizer"))

using Printf
using Unitful
using Unitful: @u_str
using Asap
using Logging

using StructuralSizer
using StructuralSynthesizer

const SR = StructuralSizer
const SS = StructuralSynthesizer

# ─────────────────────────────────────────────────────────────────────────────
# Build a simple test building
# ─────────────────────────────────────────────────────────────────────────────
println("=" ^ 72)
println("  FEA OPTIONS — QUICK-START GUIDE")
println("=" ^ 72)
println()
println("Building: 54×42 ft, 3×3 bays, H=9 ft, 16\" cols, h=7\"")
println("Loads:    SDL=20 psf, LL=50 psf")
println()

h   = 7.0u"inch"
fc  = 4000.0u"psi"
mat = SR.RC_4000_60

struc = with_logger(NullLogger()) do
    skel = SS.gen_medium_office(54.0u"ft", 42.0u"ft", 9.0u"ft", 3, 3, 1)
    s = SS.BuildingStructure(skel)
    opts = SR.FlatPlateOptions(method=SR.FEA(), material=mat,
                               cover=0.75u"inch", bar_size=5)
    SS.initialize!(s; floor_type=:flat_plate, floor_opts=opts)
    for c in s.cells
        c.sdl       = uconvert(u"kN/m^2", 20.0u"psf")
        c.live_load = uconvert(u"kN/m^2", 50.0u"psf")
    end
    for col in s.columns
        col.c1 = 16.0u"inch"
        col.c2 = 16.0u"inch"
    end
    SS.to_asap!(s)
    s
end

slab    = struc.slabs[1]
columns = SR.find_supporting_columns(struc, Set(slab.cell_indices))
γ  = mat.concrete.ρ
ν  = mat.concrete.ν
wc = ustrip(SR.pcf, γ)
Ecs = SR.Ec(fc, wc)

# Span axis (needed for strip / area extraction)
setup     = SR._moment_analysis_setup(struc, slab, columns, h, γ)
span_axis = setup.span_axis
_Nm_to_kf = ustrip(u"kip*ft", 1.0u"N*m")

# ─────────────────────────────────────────────────────────────────────────────
# Define the most useful FEA configurations
# ─────────────────────────────────────────────────────────────────────────────

methods = [
    # ── 1. RECOMMENDED DEFAULT ──
    # Frame-level: FEA mesh → centerline moments → ACI column/middle strip fractions.
    # Closest to traditional DDM/EFM but with 2D FEA accuracy.
    ("1. Frame (default)",
     SR.FEA(),
     """
     FEA() — all defaults.
     Uses :frame design approach with :efm_amp pattern loading.
     Best for: standard rectangular grids, code-compliant designs.
     """),

    # ── 2. FRAME + FEA-NATIVE PATTERN LOADING ──
    # Same as default but pattern loading uses per-cell FEA superposition
    # instead of EFM amplification factors.
    ("2. Frame + FEA patterns",
     SR.FEA(pattern_mode=:fea_resolve),
     """
     FEA(pattern_mode=:fea_resolve)
     Full FEA-native pattern loading (slower, more accurate for irregular layouts).
     Best for: irregular column grids, high L/D ratios.
     """),

    # ── 3. STRIP: ELEMENT δ-BAND ──
    # Integrates moments directly over column-strip / middle-strip widths
    # using δ-band section cuts through element centroids.
    ("3. Strip (δ-band)",
     SR.FEA(design_approach=:strip, moment_transform=:projection,
            field_smoothing=:element, cut_method=:delta_band),
     """
     FEA(design_approach=:strip)
     Direct strip integration — no ACI fraction tables.
     Best for: non-rectangular panels, irregular geometry.
     """),

    # ── 4. STRIP: WOOD–ARMER ──
    # Uses Wood (1968) transformation to produce conservative design moments
    # that account for twisting (Mxy).
    ("4. Strip (Wood–Armer)",
     SR.FEA(design_approach=:strip, moment_transform=:wood_armer),
     """
     FEA(design_approach=:strip, moment_transform=:wood_armer)
     Conservative: adds |Mxy| to both directions.
     Best for: skewed slabs, significant twisting moments.
     """),

    # ── 5. STRIP: NODAL + ISOPARAMETRIC ──
    # Smoothed nodal field + isoparametric section cuts.
    # Most sophisticated strip method — best for irregular geometry.
    ("5. Strip (nodal iso)",
     SR.FEA(design_approach=:strip, moment_transform=:projection,
            field_smoothing=:nodal, cut_method=:isoparametric, iso_alpha=0.5),
     """
     FEA(design_approach=:strip, field_smoothing=:nodal,
         cut_method=:isoparametric, iso_alpha=0.5)
     Smoothed field + blended isoparametric cuts.
     Best for: complex geometry, research/validation.
     """),

    # ── 6. AREA-BASED: WOOD–ARMER ──
    # Per-element design moments — no strip integration at all.
    # For use with per-element rebar optimization maps.
    ("6. Area (Wood–Armer)",
     SR.FEA(design_approach=:area, moment_transform=:wood_armer),
     """
     FEA(design_approach=:area, moment_transform=:wood_armer)
     Per-element design — no strip averaging.
     Best for: rebar optimization, non-standard layouts, research.
     """),

    # ── 7. NO PATTERN LOADING ──
    # Fastest: single FEA solve with factored loads.
    # Valid when L/D < 0.75 (ACI 318-14 §6.4.3.2).
    ("7. Frame (no patterns)",
     SR.FEA(pattern_loading=false),
     """
     FEA(pattern_loading=false)
     Single solve — no pattern loading overhead.
     Valid for: L/D < 0.75 (most office/residential).
     """),

    # ── 8. CUSTOM REBAR DIRECTION ──
    # For slabs where reinforcement doesn't align with span axes.
    ("8. Area (rebar @ 45°)",
     SR.FEA(design_approach=:area, moment_transform=:wood_armer,
            rebar_direction=deg2rad(45.0)),
     """
     FEA(design_approach=:area, moment_transform=:wood_armer,
         rebar_direction=deg2rad(45.0))
     Rotated rebar direction — for skewed slabs or diagonal reinforcement.
     """),

    # ── 9. FINE MESH ──
    # Explicit mesh density control for convergence studies.
    ("9. Fine mesh (3 in)",
     SR.FEA(target_edge=3.0u"inch", pattern_loading=false),
     """
     FEA(target_edge=3.0u"inch", pattern_loading=false)
     Fine mesh for convergence studies. Slower but more accurate.
     """),

    # ── 10. NO-TORSION BASELINE ──
    # Intentionally drops Mxy from the projection — unconservative but
    # educational: quantifies the effect of twisting moments.
    ("10. Strip (no torsion)",
     SR.FEA(design_approach=:strip, moment_transform=:no_torsion,
            field_smoothing=:element, cut_method=:delta_band),
     """
     FEA(design_approach=:strip, moment_transform=:no_torsion)
     Ignores Mxy — intentionally unconservative baseline.
     Compare with method 3 to see the effect of twisting moments.
     """),

    # ── 11. SEPARATE-FACES NODAL SMOOTHING ──
    # Smooths hogging and sagging fields independently to prevent
    # cross-sign cancellation at inflection points.
    ("11. Strip (sep. faces)",
     SR.FEA(design_approach=:strip, moment_transform=:projection,
            field_smoothing=:nodal, cut_method=:isoparametric,
            iso_alpha=0.5, sign_treatment=:separate_faces),
     """
     FEA(design_approach=:strip, field_smoothing=:nodal,
         cut_method=:isoparametric, sign_treatment=:separate_faces)
     Separate top/bottom smoothing — better hogging accuracy near
     inflection points. Compare with method 5.
     """),
]

# ─────────────────────────────────────────────────────────────────────────────
# Run each configuration and compare results
# ─────────────────────────────────────────────────────────────────────────────

# ── Helper: extract CS/MS moments for any design approach ──────────────
function _extract_cs_ms(method, cache, result, struc, slab, columns, span_axis)
    da = method.design_approach
    kf(m) = round(ustrip(u"kip*ft", m), digits=1)

    if da == :frame
        # ACI 318-11 §13.6.4/.6 fractions (no edge beam, αf = 0)
        cl_ext = kf(result.M_neg_ext)
        cl_int = kf(result.M_neg_int)
        cl_pos = kf(result.M_pos)
        cs = (ext = round(cl_ext * 1.00, digits=1),
              pos = round(cl_pos * 0.60, digits=1),
              int = round(cl_int * 0.75, digits=1))
        ms = (ext = round(cl_ext * 0.00, digits=1),
              pos = round(cl_pos * 0.40, digits=1),
              int = round(cl_int * 0.25, digits=1))
        return (cs=cs, ms=ms)

    elseif da == :strip
        rax = !isnothing(method.rebar_direction) ?
            SR._resolve_rebar_axis(method, span_axis) : nothing
        strips = SR._dispatch_fea_strip_extraction(
            method, cache, struc, slab, columns, span_axis;
            rebar_axis=rax, verbose=false)
        cs = (ext = round(strips.M_neg_ext_cs * _Nm_to_kf, digits=1),
              pos = round(strips.M_pos_cs     * _Nm_to_kf, digits=1),
              int = round(strips.M_neg_int_cs * _Nm_to_kf, digits=1))
        ms = (ext = round(strips.M_neg_ext_ms * _Nm_to_kf, digits=1),
              pos = round(strips.M_pos_ms     * _Nm_to_kf, digits=1),
              int = round(strips.M_neg_int_ms * _Nm_to_kf, digits=1))
        return (cs=cs, ms=ms)

    else  # :area
        area_moms = SR._extract_area_design_moments(cache, method, span_axis; verbose=false)
        rax = !isnothing(method.rebar_direction) ?
            SR._resolve_rebar_axis(method, span_axis) : nothing
        strips = SR._area_to_strip_envelope(
            area_moms, cache, struc, slab, columns, span_axis;
            rebar_axis=rax, verbose=false)
        cs = (ext = round(strips.M_neg_ext_cs * _Nm_to_kf, digits=1),
              pos = round(strips.M_pos_cs     * _Nm_to_kf, digits=1),
              int = round(strips.M_neg_int_cs * _Nm_to_kf, digits=1))
        ms = (ext = round(strips.M_neg_ext_ms * _Nm_to_kf, digits=1),
              pos = round(strips.M_pos_ms     * _Nm_to_kf, digits=1),
              int = round(strips.M_neg_int_ms * _Nm_to_kf, digits=1))
        return (cs=cs, ms=ms)
    end
end

# ── Centerline moments ─────────────────────────────────────────────────
println("  CENTERLINE (CL) MOMENTS — full frame width")
println("-" ^ 72)
@printf("  %-24s  %8s  %8s  %8s  %8s\n",
        "Configuration", "M⁻_ext", "M⁻_int", "M⁺", "M₀")
@printf("  %-24s  %8s  %8s  %8s  %8s\n",
        "", "kip·ft", "kip·ft", "kip·ft", "kip·ft")
println("-" ^ 72)

# Collect results for the CS/MS table
all_results = []

for (label, method, desc) in methods
    cache = SR.FEAModelCache()
    result = with_logger(NullLogger()) do
        SR.run_moment_analysis(
            method, struc, slab, columns, h, fc, Ecs, γ;
            ν_concrete=ν, verbose=false, cache=cache)
    end

    kf(m) = round(ustrip(u"kip*ft", m), digits=1)
    @printf("  %-24s  %8.1f  %8.1f  %8.1f  %8.1f\n",
            label, kf(result.M_neg_ext), kf(result.M_neg_int),
            kf(result.M_pos), kf(result.M0))

    # Extract CS/MS (catch errors so one bad method doesn't kill the table)
    csms = try
        _extract_cs_ms(method, cache, result, struc, slab, columns, span_axis)
    catch e
        @warn "CS/MS extraction failed for $label" exception=e
        nothing
    end
    push!(all_results, (label=label, result=result, csms=csms))
end

println("-" ^ 72)
println()

# ── Column-strip moments ───────────────────────────────────────────────
println("  COLUMN STRIP (CS) MOMENTS")
println("-" ^ 72)
@printf("  %-24s  %8s  %8s  %8s\n",
        "Configuration", "M⁻_ext", "M⁻_int", "M⁺")
@printf("  %-24s  %8s  %8s  %8s\n",
        "", "kip·ft", "kip·ft", "kip·ft")
println("-" ^ 72)

for r in all_results
    if r.csms === nothing
        @printf("  %-24s  %8s  %8s  %8s\n", r.label, "—", "—", "—")
    else
        @printf("  %-24s  %8.1f  %8.1f  %8.1f\n",
                r.label, r.csms.cs.ext, r.csms.cs.int, r.csms.cs.pos)
    end
end

println("-" ^ 72)
println()

# ── Middle-strip moments ──────────────────────────────────────────────
println("  MIDDLE STRIP (MS) MOMENTS")
println("-" ^ 72)
@printf("  %-24s  %8s  %8s  %8s\n",
        "Configuration", "M⁻_ext", "M⁻_int", "M⁺")
@printf("  %-24s  %8s  %8s  %8s\n",
        "", "kip·ft", "kip·ft", "kip·ft")
println("-" ^ 72)

for r in all_results
    if r.csms === nothing
        @printf("  %-24s  %8s  %8s  %8s\n", r.label, "—", "—", "—")
    else
        @printf("  %-24s  %8.1f  %8.1f  %8.1f\n",
                r.label, r.csms.ms.ext, r.csms.ms.int, r.csms.ms.pos)
    end
end

println("-" ^ 72)
println()

# ─────────────────────────────────────────────────────────────────────────────
# Print the decision guide
# ─────────────────────────────────────────────────────────────────────────────

println("=" ^ 72)
println("  DECISION GUIDE")
println("=" ^ 72)
println("""
  ┌─────────────────────────────────────────────────────────────────────┐
  │  Standard rectangular grid?                                        │
  │    YES → FEA()                              (option 1, default)    │
  │    YES + high L/D → FEA(pattern_mode=:fea_resolve)   (option 2)   │
  │                                                                     │
  │  Irregular geometry / non-rectangular panels?                       │
  │    → FEA(design_approach=:strip)            (option 3)             │
  │    → FEA(..., moment_transform=:wood_armer) (option 4, if skewed)  │
  │                                                                     │
  │  Research / validation / convergence study?                         │
  │    → FEA(design_approach=:strip, field_smoothing=:nodal,           │
  │          cut_method=:isoparametric, iso_alpha=0.5)  (option 5)     │
  │                                                                     │
  │  Per-element rebar optimization?                                    │
  │    → FEA(design_approach=:area, moment_transform=:wood_armer)      │
  │                                              (option 6)             │
  │                                                                     │
  │  Fastest (L/D < 0.75)?                                             │
  │    → FEA(pattern_loading=false)             (option 7)             │
  └─────────────────────────────────────────────────────────────────────┘

  Knob Reference:
    design_approach   :frame (default) | :strip | :area
    moment_transform  :projection (default) | :wood_armer
    field_smoothing   :element (default) | :nodal
    cut_method        :delta_band (default) | :isoparametric
    iso_alpha         0.0–1.0 (default: 1.0, only for isoparametric)
    pattern_loading   true (default) | false
    pattern_mode      :efm_amp (default) | :fea_resolve
    rebar_direction   nothing (default, = span axis) | Float64 radians
    target_edge       nothing (default, adaptive) | Length
""")