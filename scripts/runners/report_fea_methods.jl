# =============================================================================
# FEA Method Comparison Report
# =============================================================================
#
# Runs every FEA knob combination on the same building and prints a
# comprehensive comparison matrix so we can spot problems and understand
# how each assumption affects the results.
#
# Building: 54×42 ft, 3×3 bays, H=9 ft, 16" square columns, h=7"
# Loads:    SDL=20 psf, LL=50 psf
# Material: f'c=4000 psi (slab), f'c=6000 psi (col), fy=60 ksi
#
# Usage:
#   julia scripts/runners/report_fea_methods.jl
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

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
# Tee IO — write to both stdout and a file simultaneously
# ─────────────────────────────────────────────────────────────────────────────
const REPORT_PATH = joinpath(@__DIR__, "..", "..", "StructuralSynthesizer", "test", "reports", "fea_method_comparison.txt")
mkpath(dirname(REPORT_PATH))

struct TeeIO <: IO
    ios::Vector{IO}
end
Base.write(t::TeeIO, x::UInt8) = (for io in t.ios; write(io, x); end; 1)
Base.unsafe_write(t::TeeIO, p::Ptr{UInt8}, n::UInt) = (for io in t.ios; unsafe_write(io, p, n); end; n)

const _report_file = open(REPORT_PATH, "w")
const _tee = TeeIO([stdout, _report_file])

# Override println/print to go through the tee
_println(args...) = (println(_tee, args...); flush(_report_file))
_print(args...)   = (print(_tee, args...); flush(_report_file))
_printf(fmt, args...) = (Printf.format(_tee, Printf.Format(fmt), args...); flush(_report_file))

# ─────────────────────────────────────────────────────────────────────────────
# Report formatting helpers
# ─────────────────────────────────────────────────────────────────────────────
const W = 90
hline() = _println("─"^W)
dline() = _println("═"^W)
section(t) = (_println(); dline(); _println("  ", t); dline())
sub(t)     = (_println(); _println("  ", "─"^(W-4)); _println("  ", t); _println("  ", "─"^(W-4)))
note(msg)  = _println("    → ", msg)

# ─────────────────────────────────────────────────────────────────────────────
# Build the test building (same as the EFM integration report)
# ─────────────────────────────────────────────────────────────────────────────
section("FEA METHOD COMPARISON REPORT")
_println("  Building: 54×42 ft, 3×3 bays, H=9 ft, 16\" cols, h=7\"")
_println("  Loads:    SDL=20 psf, LL=50 psf")
_println("  Material: f'c=4000 psi (slab), f'c=6000 psi (col), fy=60 ksi")
_println()

h     = 7.0u"inch"
sdl   = 20.0u"psf"
ll    = 50.0u"psf"
fc    = 4000.0u"psi"
mat   = SR.RC_4000_60

struc = with_logger(NullLogger()) do
    _skel = SS.gen_medium_office(54.0u"ft", 42.0u"ft", 9.0u"ft", 3, 3, 1)
    _struc = SS.BuildingStructure(_skel)
    _opts = SR.FlatPlateOptions(
        material = mat,
        method   = SR.FEA(),
        cover    = 0.75u"inch",
        bar_size = 5,
    )
    SS.initialize!(_struc; floor_type=:flat_plate, floor_opts=_opts)
    for c in _struc.cells
        c.sdl       = uconvert(u"kN/m^2", sdl)
        c.live_load = uconvert(u"kN/m^2", ll)
    end
    for col in _struc.columns
        col.c1 = 16.0u"inch"
        col.c2 = 16.0u"inch"
    end
    SS.to_asap!(_struc)
    _struc
end

slab    = struc.slabs[1]
cell_set = Set(slab.cell_indices)
columns = SR.find_supporting_columns(struc, cell_set)

γ   = mat.concrete.ρ
ν   = mat.concrete.ν
wc  = ustrip(SR.pcf, γ)
Ecs = SR.Ec(fc, wc)

# ─────────────────────────────────────────────────────────────────────────────
# 1. Run the baseline FEA (frame, default knobs) to build the mesh/cache
# ─────────────────────────────────────────────────────────────────────────────
cache = SR.FEAModelCache()
baseline_method = SR.FEA(design_approach=:frame, pattern_loading=false)
baseline_result = with_logger(NullLogger()) do
    SR.run_moment_analysis(
        baseline_method, struc, slab, columns, h, fc, Ecs, γ;
        ν_concrete=ν, verbose=false, cache=cache)
end

# Extract setup info
setup = SR._moment_analysis_setup(struc, slab, columns, h, γ)
span_axis = setup.span_axis

M0_kf  = ustrip(u"kip*ft", baseline_result.M0)
qu_psf = ustrip(u"psf", baseline_result.qu)
qD_psf = ustrip(u"psf", baseline_result.qD)
qL_psf = ustrip(u"psf", baseline_result.qL)
l1_ft  = ustrip(u"ft", baseline_result.l1)
l2_ft  = ustrip(u"ft", baseline_result.l2)
ln_ft  = ustrip(u"ft", baseline_result.ln)

sub("Baseline")
_printf("    l₁ = %.1f ft   l₂ = %.1f ft   lₙ = %.2f ft\n", l1_ft, l2_ft, ln_ft)
_printf("    qD = %.1f psf   qL = %.1f psf   qᵤ = %.1f psf\n", qD_psf, qL_psf, qu_psf)
_printf("    M₀ = %.2f kip·ft\n", M0_kf)
_printf("    Mesh: %d shell elements, %d nodes\n",
        length(cache.model.shell_elements), length(cache.model.nodes))
_printf("    Cells: %s\n", join(slab.cell_indices, ", "))
_println()

# ─────────────────────────────────────────────────────────────────────────────
# 2. Define all FEA method variants to compare
# ─────────────────────────────────────────────────────────────────────────────

# Helper to convert N·m to kip·ft
const _Nm_to_kf = ustrip(u"kip*ft", 1.0u"N*m")

# Define method variants — each is (label, FEA object, description)
method_variants = [
    # ── Frame-level (ACI fractions) ──
    ("frm",     SR.FEA(design_approach=:frame, pattern_loading=false),
     "Frame-level CL + ACI fractions"),

    # ── Strip: element + delta_band + projection ──
    ("δ-proj",  SR.FEA(design_approach=:strip, moment_transform=:projection,
                        field_smoothing=:element, cut_method=:delta_band, pattern_loading=false),
     "Element δ-band, projection"),

    # ── Strip: element + delta_band + Wood-Armer ──
    ("δ-WA",    SR.FEA(design_approach=:strip, moment_transform=:wood_armer,
                        field_smoothing=:element, cut_method=:delta_band, pattern_loading=false),
     "Element δ-band, Wood–Armer"),

    # ── Strip: nodal + delta_band + projection (for field_smoothing isolation) ──
    ("nδ-proj", SR.FEA(design_approach=:strip, moment_transform=:projection,
                        field_smoothing=:nodal, cut_method=:delta_band, pattern_loading=false),
     "Nodal δ-band, projection"),

    # ── Strip: nodal + isoparametric (α=1.0, straight) + projection ──
    ("iso1-pr", SR.FEA(design_approach=:strip, moment_transform=:projection,
                        field_smoothing=:nodal, cut_method=:isoparametric, iso_alpha=1.0,
                        pattern_loading=false),
     "Nodal iso (α=1.0 straight), projection"),

    # ── Strip: nodal + isoparametric (α=0.5, blended) + projection ──
    ("iso5-pr", SR.FEA(design_approach=:strip, moment_transform=:projection,
                        field_smoothing=:nodal, cut_method=:isoparametric, iso_alpha=0.5,
                        pattern_loading=false),
     "Nodal iso (α=0.5 blended), projection"),

    # ── Strip: nodal + isoparametric (α=0.0, contour-following) + projection ──
    ("iso0-pr", SR.FEA(design_approach=:strip, moment_transform=:projection,
                        field_smoothing=:nodal, cut_method=:isoparametric, iso_alpha=0.0,
                        pattern_loading=false),
     "Nodal iso (α=0.0 contour), projection"),

    # ── Strip: nodal + isoparametric (α=1.0) + Wood-Armer ──
    ("iso1-WA", SR.FEA(design_approach=:strip, moment_transform=:wood_armer,
                        field_smoothing=:nodal, cut_method=:isoparametric, iso_alpha=1.0,
                        pattern_loading=false),
     "Nodal iso (α=1.0 straight), Wood–Armer"),

    # ── Area-based: projection ──
    ("area-pr", SR.FEA(design_approach=:area, moment_transform=:projection,
                        pattern_loading=false),
     "Area-based per-element, projection"),

    # ── Area-based: Wood-Armer ──
    ("area-WA", SR.FEA(design_approach=:area, moment_transform=:wood_armer,
                        pattern_loading=false),
     "Area-based per-element, Wood–Armer"),

    # ── Area-based: projection with rebar rotation (for rebar_direction isolation) ──
    ("area-pr-30", SR.FEA(design_approach=:area, moment_transform=:projection,
                           rebar_direction=deg2rad(30.0), pattern_loading=false),
     "Area-based, projection, rebar @ 30°"),
    ("area-pr-45", SR.FEA(design_approach=:area, moment_transform=:projection,
                           rebar_direction=deg2rad(45.0), pattern_loading=false),
     "Area-based, projection, rebar @ 45°"),

    # ── Area-based: Wood-Armer, rotated rebar ──
    ("area-wa-30", SR.FEA(design_approach=:area, moment_transform=:wood_armer,
                          rebar_direction=deg2rad(30.0), pattern_loading=false),
     "Area-based, Wood-Armer, rebar @ 30°"),
    ("area-wa-45", SR.FEA(design_approach=:area, moment_transform=:wood_armer,
                          rebar_direction=deg2rad(45.0), pattern_loading=false),
     "Area-based, Wood-Armer, rebar @ 45°"),

    # ── No-torsion baselines (intentionally unconservative) ──
    ("δ-noMxy", SR.FEA(design_approach=:strip, moment_transform=:no_torsion,
                        field_smoothing=:element, cut_method=:delta_band, pattern_loading=false),
     "Element δ-band, NO TORSION (Mxy dropped)"),
    ("area-noMxy", SR.FEA(design_approach=:area, moment_transform=:no_torsion,
                           pattern_loading=false),
     "Area-based, NO TORSION (Mxy dropped)"),

    # ── Separate-faces nodal smoothing ──
    ("iso5-sep", SR.FEA(design_approach=:strip, moment_transform=:projection,
                         field_smoothing=:nodal, cut_method=:isoparametric, iso_alpha=0.5,
                         sign_treatment=:separate_faces, pattern_loading=false),
     "Nodal iso (α=0.5), separate top/bottom smoothing"),
    ("iso1-sep", SR.FEA(design_approach=:strip, moment_transform=:projection,
                         field_smoothing=:nodal, cut_method=:isoparametric, iso_alpha=1.0,
                         sign_treatment=:separate_faces, pattern_loading=false),
     "Nodal iso (α=1.0), separate top/bottom smoothing"),

    # ── Concrete torsion discount (Wood–Armer only) ──
    ("δ-WA-td",  SR.FEA(design_approach=:strip, moment_transform=:wood_armer,
                         field_smoothing=:element, cut_method=:delta_band,
                         concrete_torsion_discount=true, pattern_loading=false),
     "Element δ-band, Wood–Armer, concrete torsion discount"),
    ("area-WA-td", SR.FEA(design_approach=:area, moment_transform=:wood_armer,
                           concrete_torsion_discount=true, pattern_loading=false),
     "Area-based, Wood–Armer, concrete torsion discount"),
]

# ─────────────────────────────────────────────────────────────────────────────
# 3. Run all strip-level extractions (reuse the same solved cache)
# ─────────────────────────────────────────────────────────────────────────────
section("PART 1 — STRIP MOMENT EXTRACTION (all methods, same FEA solve)")
note("All methods share the same FEA mesh and solved displacement field.")
note("Differences are ONLY due to post-processing (smoothing, cuts, transform).")
_println()

# Store results: label => (cs=(ext, pos, int), ms=(ext, pos, int)) in kip·ft
strip_results = Dict{String, NamedTuple}()

# Also store the full run_moment_analysis result for frame-level
full_results = Dict{String, Any}()

for (lbl, meth, desc) in method_variants
    da = meth.design_approach

    if da == :frame
        # Frame-level: run full moment analysis (uses ACI fractions internally)
        res = with_logger(NullLogger()) do
            SR.run_moment_analysis(
                meth, struc, slab, columns, h, fc, Ecs, γ;
                ν_concrete=ν, verbose=false, cache=cache)
        end
        full_results[lbl] = res

        # CL moments are the frame-level output; CS/MS via ACI fractions
        cl_ext = ustrip(u"kip*ft", res.M_neg_ext)
        cl_pos = ustrip(u"kip*ft", res.M_pos)
        cl_int = ustrip(u"kip*ft", res.M_neg_int)

        # ACI 318-11 §13.6.4/.6 fractions (no edge beam, αf=0)
        cs_frac = (ext=1.00, pos=0.60, int=0.75)
        ms_frac = (ext=0.00, pos=0.40, int=0.25)

        strip_results[lbl] = (
            cl  = (ext=cl_ext, pos=cl_pos, int=cl_int),
            cs  = (ext=cl_ext*cs_frac.ext, pos=cl_pos*cs_frac.pos, int=cl_int*cs_frac.int),
            ms  = (ext=cl_ext*ms_frac.ext, pos=cl_pos*ms_frac.pos, int=cl_int*ms_frac.int),
            sum = cl_ext/2 + cl_int/2 + cl_pos,
        )

    elseif da == :strip
        # Strip-level: dispatch to the appropriate extraction function
        _rax_s = !isnothing(meth.rebar_direction) ?
            SR._resolve_rebar_axis(meth, span_axis) : nothing
        strips = try
            SR._dispatch_fea_strip_extraction(
                meth, cache, struc, slab, columns, span_axis;
                rebar_axis=_rax_s, verbose=false)
        catch e
            @warn "Strip extraction failed for $lbl" exception=e
            nothing
        end

        if strips !== nothing
            cs = (ext = strips.M_neg_ext_cs * _Nm_to_kf,
                  pos = strips.M_pos_cs * _Nm_to_kf,
                  int = strips.M_neg_int_cs * _Nm_to_kf)
            ms = (ext = strips.M_neg_ext_ms * _Nm_to_kf,
                  pos = strips.M_pos_ms * _Nm_to_kf,
                  int = strips.M_neg_int_ms * _Nm_to_kf)
            cl = (ext = cs.ext + ms.ext,
                  pos = cs.pos + ms.pos,
                  int = cs.int + ms.int)
            strip_results[lbl] = (
                cl  = cl,
                cs  = cs,
                ms  = ms,
                sum = cl.ext/2 + cl.int/2 + cl.pos,
            )
        end

    elseif da == :area
        # Area-based: extract per-element, then bridge to strip format
        area_moms = try
            SR._extract_area_design_moments(cache, meth, span_axis; verbose=false)
        catch e
            @warn "Area extraction failed for $lbl" exception=e
            nothing
        end

        if area_moms !== nothing
            # Resolve rebar axis for directed strip classification
            _rax = !isnothing(meth.rebar_direction) ?
                SR._resolve_rebar_axis(meth, span_axis) : nothing
            strips = try
                SR._area_to_strip_envelope(
                    area_moms, cache, struc, slab, columns, span_axis;
                    rebar_axis=_rax, verbose=false)
            catch e
                @warn "Area→strip bridge failed for $lbl" exception=e
                nothing
            end

            if strips !== nothing
                cs = (ext = strips.M_neg_ext_cs * _Nm_to_kf,
                      pos = strips.M_pos_cs * _Nm_to_kf,
                      int = strips.M_neg_int_cs * _Nm_to_kf)
                ms = (ext = strips.M_neg_ext_ms * _Nm_to_kf,
                      pos = strips.M_pos_ms * _Nm_to_kf,
                      int = strips.M_neg_int_ms * _Nm_to_kf)
                cl = (ext = cs.ext + ms.ext,
                      pos = cs.pos + ms.pos,
                      int = cs.int + ms.int)
                strip_results[lbl] = (
                    cl  = cl,
                    cs  = cs,
                    ms  = ms,
                    sum = cl.ext/2 + cl.int/2 + cl.pos,
                )
            end
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# 4. Print the method knobs table
# ─────────────────────────────────────────────────────────────────────────────
sub("Method Knobs")
_printf("    %-10s %-10s %-12s %-10s %-14s %-5s  %s\n",
        "Label", "Approach", "Transform", "Smoothing", "Cut Method", "α", "Description")
_printf("    %-10s %-10s %-12s %-10s %-14s %-5s  %s\n",
        "─"^10, "─"^10, "─"^12, "─"^10, "─"^14, "─"^5, "─"^30)
for (lbl, meth, desc) in method_variants
    da = string(meth.design_approach)
    mt = string(meth.moment_transform)
    fs = string(meth.field_smoothing)
    cm = string(meth.cut_method)
    α  = meth.cut_method == :isoparametric ? @sprintf("%.1f", meth.iso_alpha) : "–"
    _printf("    %-10s %-10s %-12s %-10s %-14s %-5s  %s\n", lbl, da, mt, fs, cm, α, desc)
end
_println()

# ─────────────────────────────────────────────────────────────────────────────
# 5. Print the comparison matrix — Centerline (CL) moments
# ─────────────────────────────────────────────────────────────────────────────
sub("Centerline (CL) Moments — Full Frame Width (kip·ft)")
note("CL = CS + MS for strip methods.  For frame, CL = run_moment_analysis output.")
note("M₀ = $(round(M0_kf, digits=2)) kip·ft.  Σ/M₀ = (M⁻_ext/2 + M⁻_int/2 + M⁺) / M₀.")
note("iso_alpha has no effect on quad cells: bilinear iso-ξ lines are linear in η,"
     * " so p_iso ≡ p_straight for any quad shape (rectangle, parallelogram, trapezoid).")
_println()

labels_ordered = [lbl for (lbl, _, _) in method_variants if haskey(strip_results, lbl)]
n_meth = length(labels_ordered)

# Header
_printf("    %-14s", "Location")
for lbl in labels_ordered; _printf(" %9s", lbl); end
_println()
_printf("    %-14s", "─"^14)
for _ in 1:n_meth; _printf(" %9s", "─"^9); end
_println()

# CL rows
for (row_label, key) in [("CL Ext neg", :ext), ("CL Positive", :pos), ("CL Int neg", :int)]
    _printf("    %-14s", row_label)
    for lbl in labels_ordered
        r = strip_results[lbl]
        _printf(" %9.1f", r.cl[key])
    end
    _println()
end

# Σ/M₀ row
_printf("    %-14s", "Σ/M₀ (%)")
for lbl in labels_ordered
    r = strip_results[lbl]
    ratio = M0_kf > 0 ? r.sum / M0_kf * 100 : 0.0
    _printf(" %8.1f%%", ratio)
end
_println()
_println()

# ─────────────────────────────────────────────────────────────────────────────
# 6. Print the comparison matrix — Column Strip (CS) moments
# ─────────────────────────────────────────────────────────────────────────────
sub("Column Strip (CS) Moments (kip·ft)")
note("Frame method uses ACI 318-11 §13.6.4/.6 fractions (100%/60%/75% for no-edge-beam).")
note("Strip/area methods extract directly from FEA field.")
_println()

_printf("    %-14s", "Location")
for lbl in labels_ordered; _printf(" %9s", lbl); end
_println()
_printf("    %-14s", "─"^14)
for _ in 1:n_meth; _printf(" %9s", "─"^9); end
_println()

for (row_label, key) in [("CS Ext neg", :ext), ("CS Positive", :pos), ("CS Int neg", :int)]
    _printf("    %-14s", row_label)
    for lbl in labels_ordered
        r = strip_results[lbl]
        _printf(" %9.1f", r.cs[key])
    end
    _println()
end
_println()

# ─────────────────────────────────────────────────────────────────────────────
# 7. Print the comparison matrix — Middle Strip (MS) moments
# ─────────────────────────────────────────────────────────────────────────────
sub("Middle Strip (MS) Moments (kip·ft)")
note("Frame method uses ACI 318-11 §13.6.4/.6 fractions (0%/40%/25% for no-edge-beam).")
_println()

_printf("    %-14s", "Location")
for lbl in labels_ordered; _printf(" %9s", lbl); end
_println()
_printf("    %-14s", "─"^14)
for _ in 1:n_meth; _printf(" %9s", "─"^9); end
_println()

for (row_label, key) in [("MS Ext neg", :ext), ("MS Positive", :pos), ("MS Int neg", :int)]
    _printf("    %-14s", row_label)
    for lbl in labels_ordered
        r = strip_results[lbl]
        _printf(" %9.1f", r.ms[key])
    end
    _println()
end
_println()

# ─────────────────────────────────────────────────────────────────────────────
# 8. Deviation analysis — how far is each method from the frame baseline?
# ─────────────────────────────────────────────────────────────────────────────
sub("Deviation from Frame Baseline (Δ%)")
note("Positive = method gives LARGER moment (more conservative).")
note("Negative = method gives SMALLER moment (less conservative, potential problem).")
_println()

ref = strip_results["frm"]

_printf("    %-14s", "Location")
for lbl in labels_ordered; _printf(" %9s", lbl); end
_println()
_printf("    %-14s", "─"^14)
for _ in 1:n_meth; _printf(" %9s", "─"^9); end
_println()

for (row_label, key, strip_key) in [
    ("CS Ext neg", :ext, :cs), ("CS Positive", :pos, :cs), ("CS Int neg", :int, :cs),
    ("MS Ext neg", :ext, :ms), ("MS Positive", :pos, :ms), ("MS Int neg", :int, :ms),
]
    _printf("    %-14s", row_label)
    for lbl in labels_ordered
        r = strip_results[lbl]
        val = getfield(r, strip_key)[key]
        ref_val = getfield(ref, strip_key)[key]
        if abs(ref_val) > 0.01
            δ = (val - ref_val) / abs(ref_val) * 100
            _printf(" %+8.1f%%", δ)
        else
            _printf(" %9s", "–")
        end
    end
    _println()
end
_println()

# ─────────────────────────────────────────────────────────────────────────────
# 9. Equilibrium check — Σ moments vs M₀
# ─────────────────────────────────────────────────────────────────────────────
sub("Equilibrium Check: Σ(CS+MS) vs M₀")
note("For a properly equilibrated method, Σ/M₀ should be close to 100%.")
note("Two-way action distributes load in both directions, so Σ/M₀ < 100% is expected for FEA.")
_println()

_printf("    %-10s %10s %10s %10s %10s %10s\n",
        "Method", "Σ(kip·ft)", "M₀(kip·ft)", "Σ/M₀ (%)", "CS total", "MS total")
_printf("    %-10s %10s %10s %10s %10s %10s\n",
        "─"^10, "─"^10, "─"^10, "─"^10, "─"^10, "─"^10)

for lbl in labels_ordered
    r = strip_results[lbl]
    cs_total = r.cs.ext/2 + r.cs.int/2 + r.cs.pos
    ms_total = r.ms.ext/2 + r.ms.int/2 + r.ms.pos
    ratio = M0_kf > 0 ? r.sum / M0_kf * 100 : 0.0
    _printf("    %-10s %10.1f %10.1f %9.1f%% %10.1f %10.1f\n",
            lbl, r.sum, M0_kf, ratio, cs_total, ms_total)
end
_println()

# ─────────────────────────────────────────────────────────────────────────────
# 10. CS/MS split ratios
# ─────────────────────────────────────────────────────────────────────────────
sub("CS/MS Split Ratios (CS fraction of CL)")
note("ACI 318-11 §13.6.4/.6 fractions: ext=100%, pos=60%, int=75% (no edge beam).")
note("Values far from ACI fractions may indicate problems in strip classification.")
_println()

_printf("    %-14s", "Location")
for lbl in labels_ordered; _printf(" %9s", lbl); end
_println()
_printf("    %-14s", "─"^14)
for _ in 1:n_meth; _printf(" %9s", "─"^9); end
_println()

for (row_label, key) in [("Ext neg CS%", :ext), ("Positive CS%", :pos), ("Int neg CS%", :int)]
    _printf("    %-14s", row_label)
    for lbl in labels_ordered
        r = strip_results[lbl]
        cl_val = r.cl[key]
        cs_val = r.cs[key]
        if abs(cl_val) > 0.01
            frac = cs_val / cl_val * 100
            _printf(" %8.0f%%", frac)
        else
            _printf(" %9s", "–")
        end
    end
    _println()
end
_println()

# ─────────────────────────────────────────────────────────────────────────────
# 11. Knob Isolation Analysis — one knob at a time
# ─────────────────────────────────────────────────────────────────────────────
section("PART 1B — KNOB ISOLATION ANALYSIS")
note("Each table isolates ONE knob while holding all others constant.")
note("Δ% = difference from the baseline (first column) method.")
_println()

# ── Table A: Moment Transform Effect (projection vs wood_armer) ──
sub("A. Moment Transform: Projection vs Wood–Armer")
note("Held constant: strip, element, δ-band.  Varied: projection → wood_armer")
_println()

_printf("    %-14s %12s %12s %12s\n", "Location", "δ-proj", "δ-WA", "Δ%")
_printf("    %-14s %12s %12s %12s\n", "─"^14, "─"^12, "─"^12, "─"^12)

if haskey(strip_results, "δ-proj") && haskey(strip_results, "δ-WA")
    ref = strip_results["δ-proj"]
    cmp = strip_results["δ-WA"]
    for (row_label, key, strip_key) in [
        ("CS Ext neg", :ext, :cs), ("CS Positive", :pos, :cs), ("CS Int neg", :int, :cs),
        ("MS Ext neg", :ext, :ms), ("MS Positive", :pos, :ms), ("MS Int neg", :int, :ms),
    ]
        ref_val = getfield(ref, strip_key)[key]
        cmp_val = getfield(cmp, strip_key)[key]
        δ = abs(ref_val) > 0.01 ? (cmp_val - ref_val) / abs(ref_val) * 100 : 0.0
        _printf("    %-14s %12.1f %12.1f %+11.1f%%\n", row_label, ref_val, cmp_val, δ)
    end
end
_println()

# ── Table B: Field Smoothing Effect (element vs nodal) ──
sub("B. Field Smoothing: Element vs Nodal")
note("Held constant: strip, projection, δ-band.  Varied: element → nodal")
_println()

_printf("    %-14s %12s %12s %12s\n", "Location", "δ-proj", "nδ-proj", "Δ%")
_printf("    %-14s %12s %12s %12s\n", "─"^14, "─"^12, "─"^12, "─"^12)

if haskey(strip_results, "δ-proj") && haskey(strip_results, "nδ-proj")
    ref = strip_results["δ-proj"]
    cmp = strip_results["nδ-proj"]
    for (row_label, key, strip_key) in [
        ("CS Ext neg", :ext, :cs), ("CS Positive", :pos, :cs), ("CS Int neg", :int, :cs),
        ("MS Ext neg", :ext, :ms), ("MS Positive", :pos, :ms), ("MS Int neg", :int, :ms),
    ]
        ref_val = getfield(ref, strip_key)[key]
        cmp_val = getfield(cmp, strip_key)[key]
        δ = abs(ref_val) > 0.01 ? (cmp_val - ref_val) / abs(ref_val) * 100 : 0.0
        _printf("    %-14s %12.1f %12.1f %+11.1f%%\n", row_label, ref_val, cmp_val, δ)
    end
end
_println()

# ── Table C: Cut Method Effect (δ-band vs isoparametric) ──
sub("C. Cut Method: δ-band vs Isoparametric")
note("Held constant: strip, projection, nodal.  Varied: δ-band → isoparametric (α=1.0)")
_println()

_printf("    %-14s %12s %12s %12s\n", "Location", "nδ-proj", "iso1-pr", "Δ%")
_printf("    %-14s %12s %12s %12s\n", "─"^14, "─"^12, "─"^12, "─"^12)

if haskey(strip_results, "nδ-proj") && haskey(strip_results, "iso1-pr")
    ref = strip_results["nδ-proj"]
    cmp = strip_results["iso1-pr"]
    for (row_label, key, strip_key) in [
        ("CS Ext neg", :ext, :cs), ("CS Positive", :pos, :cs), ("CS Int neg", :int, :cs),
        ("MS Ext neg", :ext, :ms), ("MS Positive", :pos, :ms), ("MS Int neg", :int, :ms),
    ]
        ref_val = getfield(ref, strip_key)[key]
        cmp_val = getfield(cmp, strip_key)[key]
        δ = abs(ref_val) > 0.01 ? (cmp_val - ref_val) / abs(ref_val) * 100 : 0.0
        _printf("    %-14s %12.1f %12.1f %+11.1f%%\n", row_label, ref_val, cmp_val, δ)
    end
end
_println()

# ── Table D: Design Approach Effect (frame vs strip vs area) ──
sub("D. Design Approach: Frame vs Strip vs Area")
note("Held constant: projection.  Varied: frame → strip (element δ) → area")
_println()

_printf("    %-14s %12s %12s %12s %12s\n", "Location", "frm", "δ-proj", "area-pr", "Δ% (strip)")
_printf("    %-14s %12s %12s %12s %12s\n", "─"^14, "─"^12, "─"^12, "─"^12, "─"^12)

if haskey(strip_results, "frm") && haskey(strip_results, "δ-proj") && haskey(strip_results, "area-pr")
    ref = strip_results["frm"]
    cmp = strip_results["δ-proj"]
    area = strip_results["area-pr"]
    for (row_label, key, strip_key) in [
        ("CS Ext neg", :ext, :cs), ("CS Positive", :pos, :cs), ("CS Int neg", :int, :cs),
        ("MS Ext neg", :ext, :ms), ("MS Positive", :pos, :ms), ("MS Int neg", :int, :ms),
    ]
        ref_val = getfield(ref, strip_key)[key]
        cmp_val = getfield(cmp, strip_key)[key]
        area_val = getfield(area, strip_key)[key]
        δ = abs(ref_val) > 0.01 ? (cmp_val - ref_val) / abs(ref_val) * 100 : 0.0
        _printf("    %-14s %12.1f %12.1f %12.1f %+11.1f%%\n", row_label, ref_val, cmp_val, area_val, δ)
    end
end
_println()

# ── Table E: iso_alpha Effect (α = 0.0, 0.5, 1.0) ──
sub("E. iso_alpha: Contour (0.0) vs Blended (0.5) vs Straight (1.0)")
note("Held constant: strip, projection, nodal, isoparametric.  Varied: α = 0.0 → 0.5 → 1.0")
note("iso_alpha has no effect on quad cells (bilinear iso-ξ = linear in η → p_iso ≡ p_straight).")
_println()

_printf("    %-14s %12s %12s %12s %12s\n", "Location", "iso0-pr", "iso5-pr", "iso1-pr", "Max Δ%")
_printf("    %-14s %12s %12s %12s %12s\n", "─"^14, "─"^12, "─"^12, "─"^12, "─"^12)

if haskey(strip_results, "iso0-pr") && haskey(strip_results, "iso5-pr") && haskey(strip_results, "iso1-pr")
    iso0 = strip_results["iso0-pr"]
    iso5 = strip_results["iso5-pr"]
    iso1 = strip_results["iso1-pr"]
    for (row_label, key, strip_key) in [
        ("CS Ext neg", :ext, :cs), ("CS Positive", :pos, :cs), ("CS Int neg", :int, :cs),
        ("MS Ext neg", :ext, :ms), ("MS Positive", :pos, :ms), ("MS Int neg", :int, :ms),
    ]
        v0 = getfield(iso0, strip_key)[key]
        v5 = getfield(iso5, strip_key)[key]
        v1 = getfield(iso1, strip_key)[key]
        max_δ = abs(v0) > 0.01 ? max(abs((v5 - v0) / abs(v0) * 100), abs((v1 - v0) / abs(v0) * 100)) : 0.0
        _printf("    %-14s %12.1f %12.1f %12.1f %11.2f%%\n", row_label, v0, v5, v1, max_δ)
    end
end
_println()

# ── Table F: Rebar Direction Effect (0°, 30°, 45°) ──
sub("F. Rebar Direction & Moment Transform")
note("Compare Projection vs Wood-Armer for rotated rebar (30°, 45°)")
_println()

_printf("    %-14s %10s %10s %10s %10s %10s\n", "Location", "area-pr", "pr-30", "wa-30", "pr-45", "wa-45")
_printf("    %-14s %10s %10s %10s %10s %10s\n", "─"^14, "─"^10, "─"^10, "─"^10, "─"^10, "─"^10)

if haskey(strip_results, "area-pr")
    ref = strip_results["area-pr"]
    p30 = get(strip_results, "area-pr-30", nothing)
    w30 = get(strip_results, "area-wa-30", nothing)
    p45 = get(strip_results, "area-pr-45", nothing)
    w45 = get(strip_results, "area-wa-45", nothing)
    
    for (row_label, key, strip_key) in [
        ("CS Ext neg", :ext, :cs), ("CS Positive", :pos, :cs), ("CS Int neg", :int, :cs),
        ("MS Ext neg", :ext, :ms), ("MS Positive", :pos, :ms), ("MS Int neg", :int, :ms),
    ]
        ref_val = getfield(ref, strip_key)[key]
        vp30 = isnothing(p30) ? 0.0 : getfield(p30, strip_key)[key]
        vw30 = isnothing(w30) ? 0.0 : getfield(w30, strip_key)[key]
        vp45 = isnothing(p45) ? 0.0 : getfield(p45, strip_key)[key]
        vw45 = isnothing(w45) ? 0.0 : getfield(w45, strip_key)[key]
        
        _printf("    %-14s %10.1f %10.1f %10.1f %10.1f %10.1f\n", 
                row_label, ref_val, vp30, vw30, vp45, vw45)
    end
end
_println()

# ─────────────────────────────────────────────────────────────────────────────
# 11b. Per-Element Rebar Field — Area-Based Methods
# ─────────────────────────────────────────────────────────────────────────────
section("PART 1C — PER-ELEMENT REBAR FIELD (Area-Based Methods)")
note("For each area-based method: build the full ElementRebarField and report")
note("per-element reinforcement statistics (As in mm²/m).")
note("This exercises the new per-element rebar sizing pipeline end-to-end.")
_println()

# Compute effective depth and material strengths for rebar sizing
_d_rebar = SR.effective_depth(h)
_fc_rebar = mat.concrete.fc′
_fy_rebar = mat.rebar.Fy

# Collect area-method labels in order
area_labels = [lbl for (lbl, meth, _) in method_variants if meth.design_approach == :area]

# Build element rebar fields for each area method
area_rebar_fields = Dict{String, SR.ElementRebarField}()
for (lbl, meth, desc) in method_variants
    meth.design_approach == :area || continue

    area_moms = try
        SR._extract_area_design_moments(cache, meth, span_axis; verbose=false)
    catch e
        @warn "Area extraction failed for $lbl (rebar field)" exception=e
        nothing
    end
    area_moms === nothing && continue

    field = try
        SR._build_element_rebar_field(
            area_moms, h, _d_rebar, _fc_rebar, _fy_rebar, meth.moment_transform;
            verbose=false)
    catch e
        @warn "Rebar field build failed for $lbl" exception=e
        nothing
    end
    field !== nothing && (area_rebar_fields[lbl] = field)
end

# ── Summary table: per-method rebar field statistics ──
sub("Per-Element Rebar Field Summary (mm²/m)")
note("As_min = ACI §7.12.2.1 minimum steel per unit width.")
note("Max/Mean = envelope/average over all elements in the field.")
note("Inad. = number of elements where Whitney block solution is imaginary.")
_println()

_printf("    %-12s %8s %8s %8s %8s %8s %8s %8s %8s %6s %6s\n",
        "Method", "As_min", "x_bot↑", "x_bot μ", "x_top↑", "x_top μ",
        "y_bot↑", "y_bot μ", "y_top↑", "y_top μ", "Inad.")
_printf("    %-12s %8s %8s %8s %8s %8s %8s %8s %8s %6s %6s\n",
        "─"^12, "─"^8, "─"^8, "─"^8, "─"^8, "─"^8, "─"^8, "─"^8, "─"^8, "─"^6, "─"^6)

for lbl in area_labels
    haskey(area_rebar_fields, lbl) || continue
    field = area_rebar_fields[lbl]
    elems = field.elements
    n = length(elems)

    As_min_mm2 = field.elements[1].As_min * 1e6
    max_xb = maximum(r.As_x_bot for r in elems) * 1e6
    mean_xb = sum(r.As_x_bot for r in elems) / n * 1e6
    max_xt = maximum(r.As_x_top for r in elems) * 1e6
    mean_xt = sum(r.As_x_top for r in elems) / n * 1e6
    max_yb = maximum(r.As_y_bot for r in elems) * 1e6
    mean_yb = sum(r.As_y_bot for r in elems) / n * 1e6
    max_yt = maximum(r.As_y_top for r in elems) * 1e6
    mean_yt = sum(r.As_y_top for r in elems) / n * 1e6
    n_inad = count(!r.section_adequate for r in elems)

    _printf("    %-12s %8.0f %8.0f %8.0f %8.0f %8.0f %8.0f %8.0f %8.0f %6.0f %6d\n",
            lbl, As_min_mm2, max_xb, mean_xb, max_xt, mean_xt,
            max_yb, mean_yb, max_yt, mean_yt, n_inad)
end
_println()

# ── Knob isolation: projection vs Wood-Armer on per-element As ──
sub("Rebar Field — Projection vs Wood–Armer (max As, mm²/m)")
note("Held constant: area, rebar @ 0°.  Varied: projection → wood_armer")
note("Δ% = (WA − proj) / proj × 100.  Positive = WA gives more steel (conservative).")
_println()

if haskey(area_rebar_fields, "area-pr") && haskey(area_rebar_fields, "area-WA")
    pr = area_rebar_fields["area-pr"]
    wa = area_rebar_fields["area-WA"]

    _printf("    %-14s %12s %12s %12s\n", "Face/Dir", "area-pr", "area-WA", "Δ%")
    _printf("    %-14s %12s %12s %12s\n", "─"^14, "─"^12, "─"^12, "─"^12)

    for (face_lbl, accessor) in [
        ("x' bot (max)", r -> r.As_x_bot),
        ("x' top (max)", r -> r.As_x_top),
        ("y' bot (max)", r -> r.As_y_bot),
        ("y' top (max)", r -> r.As_y_top),
        ("x' bot (mean)", r -> r.As_x_bot),
        ("x' top (mean)", r -> r.As_x_top),
        ("y' bot (mean)", r -> r.As_y_bot),
        ("y' top (mean)", r -> r.As_y_top),
    ]
        is_max = contains(face_lbl, "max")
        pr_val = is_max ? maximum(accessor(r) for r in pr.elements) :
                          sum(accessor(r) for r in pr.elements) / length(pr.elements)
        wa_val = is_max ? maximum(accessor(r) for r in wa.elements) :
                          sum(accessor(r) for r in wa.elements) / length(wa.elements)
        pr_mm2 = pr_val * 1e6
        wa_mm2 = wa_val * 1e6
        δ = abs(pr_mm2) > 0.01 ? (wa_mm2 - pr_mm2) / abs(pr_mm2) * 100 : 0.0
        _printf("    %-14s %12.0f %12.0f %+11.1f%%\n", face_lbl, pr_mm2, wa_mm2, δ)
    end
    _println()
else
    _println("    (area-pr or area-WA not available — skipping)")
    _println()
end

# ── Knob isolation: rebar direction effect on per-element As ──
sub("Rebar Field — Rebar Direction Effect (max As, mm²/m)")
note("Compare 0° (aligned with span) vs 30° vs 45° rotation.")
_println()

_rebar_dir_labels = ["area-pr", "area-pr-30", "area-pr-45", "area-WA", "area-wa-30", "area-wa-45"]
_rebar_dir_present = [lbl for lbl in _rebar_dir_labels if haskey(area_rebar_fields, lbl)]

if length(_rebar_dir_present) > 1
    _printf("    %-14s", "Face/Dir")
    for lbl in _rebar_dir_present; _printf(" %11s", lbl); end
    _println()
    _printf("    %-14s", "─"^14)
    for _ in _rebar_dir_present; _printf(" %11s", "─"^11); end
    _println()

    for (face_lbl, accessor) in [
        ("x' bot (max)", r -> r.As_x_bot),
        ("x' top (max)", r -> r.As_x_top),
        ("y' bot (max)", r -> r.As_y_bot),
        ("y' top (max)", r -> r.As_y_top),
    ]
        _printf("    %-14s", face_lbl)
        for lbl in _rebar_dir_present
            field = area_rebar_fields[lbl]
            val = maximum(accessor(r) for r in field.elements) * 1e6
            _printf(" %11.0f", val)
        end
        _println()
    end

    # Also show total steel demand (area-weighted sum)
    _printf("    %-14s", "─"^14)
    for _ in _rebar_dir_present; _printf(" %11s", "─"^11); end
    _println()
    _printf("    %-14s", "ΣAs·A (mm²·m)")
    for lbl in _rebar_dir_present
        field = area_rebar_fields[lbl]
        total = sum((r.As_x_bot + r.As_x_top + r.As_y_bot + r.As_y_top) * r.area
                    for r in field.elements) * 1e6
        _printf(" %11.0f", total)
    end
    _println()
    _println()
else
    _println("    (insufficient area-based methods — skipping)")
    _println()
end

# ── Section adequacy check ──
sub("Rebar Field — Section Adequacy")
note("Any method with inadequate elements means h is too small for that demand.")
_println()

let any_inad = false
    for lbl in area_labels
        haskey(area_rebar_fields, lbl) || continue
        field = area_rebar_fields[lbl]
        if !field.section_adequate
            n_inad = count(!r.section_adequate for r in field.elements)
            _printf("    ⚠ %s: %d / %d elements inadequate\n", lbl, n_inad, length(field.elements))
            any_inad = true
        end
    end
    if !any_inad
        _println("    ✓ All area-based methods: sections adequate at h = $(ustrip(u"inch", h))\"")
    end
end
_println()

# ─────────────────────────────────────────────────────────────────────────────
# 12. Pattern loading comparison (if applicable)
# ─────────────────────────────────────────────────────────────────────────────
section("PART 2 — PATTERN LOADING COMPARISON")
note("Compares EFM amplification vs FEA-native pattern loading.")
note("Both use the same underlying FEA mesh; differences are in pattern evaluation.")
_println()

# Run with pattern loading enabled
pattern_methods = [
    ("no-pat",   SR.FEA(design_approach=:frame, pattern_loading=false),
     "No pattern loading"),
    ("efm-amp",  SR.FEA(design_approach=:frame, pattern_loading=true, pattern_mode=:efm_amp),
     "EFM amplification"),
    ("fea-res",  SR.FEA(design_approach=:frame, pattern_loading=true, pattern_mode=:fea_resolve),
     "FEA-native resolve"),
]

pat_results = Dict{String, NamedTuple}()
for (lbl, meth, desc) in pattern_methods
    # Each needs a fresh cache because pattern loading modifies element_data
    pat_cache = SR.FEAModelCache()
    res = try
        with_logger(NullLogger()) do
            SR.run_moment_analysis(
                meth, struc, slab, columns, h, fc, Ecs, γ;
                ν_concrete=ν, verbose=false, cache=pat_cache)
        end
    catch e
        @warn "Pattern loading failed for $lbl" exception=(e, catch_backtrace())
        nothing
    end

    if res !== nothing
        cl_ext = ustrip(u"kip*ft", res.M_neg_ext)
        cl_pos = ustrip(u"kip*ft", res.M_pos)
        cl_int = ustrip(u"kip*ft", res.M_neg_int)
        pat_results[lbl] = (
            ext = cl_ext, pos = cl_pos, int = cl_int,
            sum = cl_ext/2 + cl_int/2 + cl_pos,
            pattern = res.pattern_loading,
        )
    end
end

sub("Pattern Loading — Frame-Level CL Moments (kip·ft)")
pat_labels = [lbl for (lbl, _, _) in pattern_methods if haskey(pat_results, lbl)]
n_pat = length(pat_labels)

_printf("    %-14s", "Location")
for lbl in pat_labels; _printf(" %12s", lbl); end
_println()
_printf("    %-14s", "─"^14)
for _ in 1:n_pat; _printf(" %12s", "─"^12); end
_println()

for (row_label, key) in [("CL Ext neg", :ext), ("CL Positive", :pos), ("CL Int neg", :int)]
    _printf("    %-14s", row_label)
    for lbl in pat_labels
        r = pat_results[lbl]
        _printf(" %12.1f", r[key])
    end
    _println()
end

# Amplification factors
if haskey(pat_results, "no-pat") && length(pat_labels) > 1
    _printf("    %-14s", "")
    for _ in 1:n_pat; _printf(" %12s", "─"^12); end
    _println()

    base = pat_results["no-pat"]
    for (row_label, key) in [("Amp Ext neg", :ext), ("Amp Positive", :pos), ("Amp Int neg", :int)]
        _printf("    %-14s", row_label)
        for lbl in pat_labels
            r = pat_results[lbl]
            if abs(base[key]) > 0.01
                amp = r[key] / base[key]
                _printf(" %11.3fx", amp)
            else
                _printf(" %12s", "–")
            end
        end
        _println()
    end
end

_printf("    %-14s", "Pattern?")
for lbl in pat_labels
    r = pat_results[lbl]
    _printf(" %12s", r.pattern ? "yes" : "no")
end
_println()
_println()

# ─────────────────────────────────────────────────────────────────────────────
# 12b. Patch stiffness factor comparison
# ─────────────────────────────────────────────────────────────────────────────
section("PART 2b — PATCH STIFFNESS FACTOR COMPARISON")
note("Column patches can be stiffened to model rigid column–slab junction zones.")
note("Each variant uses a fresh FEA solve (stiffness factor changes the model).")
note("Factor 1.0 = baseline (no stiffening); >1 = stiffer column zone.")
_println()

patch_methods = [
    ("psf-1.0", SR.FEA(design_approach=:frame, patch_stiffness_factor=1.0, pattern_loading=false),
     "Baseline (no stiffening)"),
    ("psf-2.0", SR.FEA(design_approach=:frame, patch_stiffness_factor=2.0, pattern_loading=false),
     "2× column patch stiffness"),
    ("psf-5.0", SR.FEA(design_approach=:frame, patch_stiffness_factor=5.0, pattern_loading=false),
     "5× column patch stiffness"),
    ("psf-10",  SR.FEA(design_approach=:frame, patch_stiffness_factor=10.0, pattern_loading=false),
     "10× column patch stiffness"),
]

psf_results = Dict{String, NamedTuple}()
for (lbl, meth, desc) in patch_methods
    psf_cache = SR.FEAModelCache()
    res = try
        with_logger(NullLogger()) do
            SR.run_moment_analysis(
                meth, struc, slab, columns, h, fc, Ecs, γ;
                ν_concrete=ν, verbose=false, cache=psf_cache)
        end
    catch e
        @warn "Patch stiffness test failed for $lbl" exception=(e, catch_backtrace())
        nothing
    end

    if res !== nothing
        cl_ext = ustrip(u"kip*ft", res.M_neg_ext)
        cl_pos = ustrip(u"kip*ft", res.M_pos)
        cl_int = ustrip(u"kip*ft", res.M_neg_int)
        fea_Δ = hasproperty(res, :fea_Δ_panel) && !isnothing(res.fea_Δ_panel) ?
                ustrip(u"inch", res.fea_Δ_panel) : NaN
        psf_results[lbl] = (
            ext = cl_ext, pos = cl_pos, int = cl_int,
            sum = cl_ext/2 + cl_int/2 + cl_pos,
            Δ_panel = fea_Δ,
        )
    end
end

sub("Patch Stiffness Factor — Frame-Level CL Moments (kip·ft)")
psf_labels = [lbl for (lbl, _, _) in patch_methods if haskey(psf_results, lbl)]
n_psf = length(psf_labels)

_printf("    %-14s", "Location")
for lbl in psf_labels; _printf(" %12s", lbl); end
_println()
_printf("    %-14s", "─"^14)
for _ in 1:n_psf; _printf(" %12s", "─"^12); end
_println()

for (row_label, key) in [("CL Ext neg", :ext), ("CL Positive", :pos), ("CL Int neg", :int),
                          ("Σ half-frame", :sum)]
    _printf("    %-14s", row_label)
    for lbl in psf_labels
        r = psf_results[lbl]
        _printf(" %12.1f", r[key])
    end
    _println()
end

# Δ_panel row
_printf("    %-14s", "Δ_panel (in)")
for lbl in psf_labels
    r = psf_results[lbl]
    if isnan(r.Δ_panel)
        _printf(" %12s", "–")
    else
        _printf(" %12.4f", r.Δ_panel)
    end
end
_println()

# Relative change from baseline
if haskey(psf_results, "psf-1.0") && n_psf > 1
    _printf("    %-14s", "")
    for _ in 1:n_psf; _printf(" %12s", "─"^12); end
    _println()

    base = psf_results["psf-1.0"]
    for (row_label, key) in [("Δ% Ext neg", :ext), ("Δ% Positive", :pos), ("Δ% Int neg", :int)]
        _printf("    %-14s", row_label)
        for lbl in psf_labels
            r = psf_results[lbl]
            if abs(base[key]) > 0.01
                pct = (r[key] - base[key]) / abs(base[key]) * 100
                _printf(" %+11.1f%%", pct)
            else
                _printf(" %12s", "–")
            end
        end
        _println()
    end
end
_println()

# ─────────────────────────────────────────────────────────────────────────────
# 13. Per-column forces comparison
# ─────────────────────────────────────────────────────────────────────────────
section("PART 3 — PER-COLUMN DEMANDS (from baseline FEA)")
note("Column shears (Vu), unbalanced moments (Mub), and section moments (M⁻).")
_println()

_printf("    %-5s  %-10s  %10s  %10s  %12s\n",
        "Col", "Position", "Vu (kip)", "M⁻ (kip·ft)", "Mub (kip·ft)")
_printf("    %-5s  %-10s  %10s  %10s  %12s\n",
        "─"^5, "─"^10, "─"^10, "─"^10, "─"^12)

for (i, col) in enumerate(columns)
    Vu  = ustrip(u"kip", baseline_result.column_shears[i])
    Mn  = ustrip(u"kip*ft", baseline_result.column_moments[i])
    Mub = ustrip(u"kip*ft", baseline_result.unbalanced_moments[i])
    _printf("    %-5d  %-10s  %10.1f  %10.1f  %12.1f\n",
            i, string(col.position), Vu, Mn, Mub)
end
_println()

# ─────────────────────────────────────────────────────────────────────────────
# 14. Mesh Convergence — Nodal Smoothing Sensitivity
# ─────────────────────────────────────────────────────────────────────────────
section("PART 4 — MESH CONVERGENCE (Nodal Smoothing Sensitivity)")
note("Same building solved at increasing mesh densities.")
note("For each mesh: element-centroid (δ-proj) vs nodal-smoothed (nδ-proj) extraction.")
note("SPR theory predicts the element↔nodal gap shrinks with mesh refinement.")
_println()

# Mesh edge lengths to test: coarse → fine
# Default adaptive is ~min_span/20 ≈ 0.21 m for this building.
_mesh_edges = [0.50u"m", 0.30u"m", 0.20u"m", 0.12u"m", 0.08u"m"]

_mesh_results = NamedTuple[]  # (edge_m, n_elem, n_nodes, elem_cs, elem_ms, nodal_cs, nodal_ms)

for te in _mesh_edges
    te_m = ustrip(u"m", te)
    _mc = SR.FEAModelCache()

    # Build & solve at this mesh density
    _meth_elem = SR.FEA(design_approach=:strip, moment_transform=:projection,
                         field_smoothing=:element, cut_method=:delta_band,
                         target_edge=te, pattern_loading=false)

    _res_elem = try
        with_logger(NullLogger()) do
            SR.run_moment_analysis(
                _meth_elem, struc, slab, columns, h, fc, Ecs, γ;
                ν_concrete=ν, verbose=false, cache=_mc)
        end
    catch e
        @warn "Mesh convergence failed for edge=$(te_m)m" exception=e
        nothing
    end
    _res_elem === nothing && continue

    n_elem  = length(_mc.model.shell_elements)
    n_nodes = length(_mc.model.nodes)

    # Element-centroid strip extraction
    _strips_elem = SR._dispatch_fea_strip_extraction(
        _meth_elem, _mc, struc, slab, columns, span_axis)
    _ecs = (ext = _strips_elem.M_neg_ext_cs * _Nm_to_kf,
            pos = _strips_elem.M_pos_cs * _Nm_to_kf,
            int = _strips_elem.M_neg_int_cs * _Nm_to_kf)
    _ems = (ext = _strips_elem.M_neg_ext_ms * _Nm_to_kf,
            pos = _strips_elem.M_pos_ms * _Nm_to_kf,
            int = _strips_elem.M_neg_int_ms * _Nm_to_kf)

    # Nodal-smoothed strip extraction (same cache/solve, different post-processing)
    _meth_nodal = SR.FEA(design_approach=:strip, moment_transform=:projection,
                          field_smoothing=:nodal, cut_method=:delta_band,
                          target_edge=te, pattern_loading=false)
    _strips_nodal = SR._dispatch_fea_strip_extraction(
        _meth_nodal, _mc, struc, slab, columns, span_axis)
    _ncs = (ext = _strips_nodal.M_neg_ext_cs * _Nm_to_kf,
            pos = _strips_nodal.M_pos_cs * _Nm_to_kf,
            int = _strips_nodal.M_neg_int_cs * _Nm_to_kf)
    _nms = (ext = _strips_nodal.M_neg_ext_ms * _Nm_to_kf,
            pos = _strips_nodal.M_pos_ms * _Nm_to_kf,
            int = _strips_nodal.M_neg_int_ms * _Nm_to_kf)

    push!(_mesh_results, (
        edge_m  = te_m,
        n_elem  = n_elem,
        n_nodes = n_nodes,
        elem_cs = _ecs,
        elem_ms = _ems,
        nodal_cs = _ncs,
        nodal_ms = _nms,
    ))
end

# ── Print mesh summary ──
sub("Mesh Density Summary")
_printf("    %-8s %8s %8s %10s\n", "Edge (m)", "Elements", "Nodes", "h_char (mm)")
_printf("    %-8s %8s %8s %10s\n", "─"^8, "─"^8, "─"^8, "─"^10)
for r in _mesh_results
    _printf("    %-8.3f %8d %8d %10.0f\n", r.edge_m, r.n_elem, r.n_nodes, r.edge_m * 1000)
end
_println()

# ── Print convergence table: element vs nodal at each mesh ──
sub("Element vs Nodal: CS Moments (kip·ft)")
note("Δ% = (nodal − element) / element × 100.  Should → 0 as mesh refines.")
_println()

# Header
_printf("    %-14s", "Location")
for r in _mesh_results
    _printf("  %6.0fmm(E) %6.0fmm(N) %7s", r.edge_m*1000, r.edge_m*1000, "Δ%")
end
_println()
_printf("    %-14s", "─"^14)
for _ in _mesh_results
    _printf("  %9s %9s %7s", "─"^9, "─"^9, "─"^7)
end
_println()

for (row_label, key) in [("CS Ext neg", :ext), ("CS Positive", :pos), ("CS Int neg", :int)]
    _printf("    %-14s", row_label)
    for r in _mesh_results
        ev = r.elem_cs[key]
        nv = r.nodal_cs[key]
        δ = abs(ev) > 0.01 ? (nv - ev) / abs(ev) * 100 : 0.0
        _printf("  %9.1f %9.1f %+6.1f%%", ev, nv, δ)
    end
    _println()
end
_println()

# ── Print convergence table: element vs nodal at each mesh (MS) ──
sub("Element vs Nodal: MS Moments (kip·ft)")
_println()

_printf("    %-14s", "Location")
for r in _mesh_results
    _printf("  %6.0fmm(E) %6.0fmm(N) %7s", r.edge_m*1000, r.edge_m*1000, "Δ%")
end
_println()
_printf("    %-14s", "─"^14)
for _ in _mesh_results
    _printf("  %9s %9s %7s", "─"^9, "─"^9, "─"^7)
end
_println()

for (row_label, key) in [("MS Ext neg", :ext), ("MS Positive", :pos), ("MS Int neg", :int)]
    _printf("    %-14s", row_label)
    for r in _mesh_results
        ev = r.elem_ms[key]
        nv = r.nodal_ms[key]
        δ = abs(ev) > 0.01 ? (nv - ev) / abs(ev) * 100 : 0.0
        _printf("  %9.1f %9.1f %+6.1f%%", ev, nv, δ)
    end
    _println()
end
_println()

# ── Condensed Δ% convergence summary ──
sub("Convergence Summary: |Δ%| by Mesh Density")
note("Max |Δ%| across all 6 locations (CS + MS) for each mesh density.")
note("CS negative moments: nodal > element (SPR inflates peaks near columns).")
note("MS negative moments: nodal < element (moment migrates from MS → CS).")
note("CS gap converges with refinement; MS gap persists (structural artifact of SPR).")
_println()

_printf("    %-10s %8s %8s %10s %10s\n",
        "Edge (m)", "Elements", "CS max Δ%", "MS max Δ%", "Overall Δ%")
_printf("    %-10s %8s %8s %10s %10s\n",
        "─"^10, "─"^8, "─"^8, "─"^10, "─"^10)

for r in _mesh_results
    cs_deltas = Float64[]
    ms_deltas = Float64[]
    for key in (:ext, :pos, :int)
        ev_cs = r.elem_cs[key]; nv_cs = r.nodal_cs[key]
        abs(ev_cs) > 0.01 && push!(cs_deltas, abs((nv_cs - ev_cs) / ev_cs * 100))
        ev_ms = r.elem_ms[key]; nv_ms = r.nodal_ms[key]
        abs(ev_ms) > 0.01 && push!(ms_deltas, abs((nv_ms - ev_ms) / ev_ms * 100))
    end
    max_cs = isempty(cs_deltas) ? 0.0 : maximum(cs_deltas)
    max_ms = isempty(ms_deltas) ? 0.0 : maximum(ms_deltas)
    max_all = max(max_cs, max_ms)
    _printf("    %-10.3f %8d %7.1f%% %9.1f%% %9.1f%%\n",
            r.edge_m, r.n_elem, max_cs, max_ms, max_all)
end
_println()

# ─────────────────────────────────────────────────────────────────────────────
# 15. PART 5 — Skewed Grid Analysis
# ─────────────────────────────────────────────────────────────────────────────
section("PART 5 — SKEWED GRID (Trapezoid Bays)")
note("Same building with interior columns shifted ±3 ft in x (alternating by column).")
note("Adjacent interior columns shift opposite directions, so every bay has")
note("unequal-length horizontal edges → true trapezoids.  Bilinear iso mapping")
note("is genuinely nonlinear, so iso_alpha differentiates cut paths.")
note("Mxy is significant even on cardinal axes.")
note("Methods that fail show \"--\" in the table.")
_println()

# Build the skewed building
skew_offset = 3.0u"ft"
skew_struc = with_logger(NullLogger()) do
    _skel = SS.gen_medium_office(54.0u"ft", 42.0u"ft", 9.0u"ft", 3, 3, 1;
                                  irregular=:trapezoid, offset=skew_offset)
    _struc = SS.BuildingStructure(_skel)
    _opts = SR.FlatPlateOptions(
        material = mat,
        method   = SR.FEA(),
        cover    = 0.75u"inch",
        bar_size = 5,
    )
    SS.initialize!(_struc; floor_type=:flat_plate, floor_opts=_opts)
    for c in _struc.cells
        c.sdl       = uconvert(u"kN/m^2", sdl)
        c.live_load = uconvert(u"kN/m^2", ll)
    end
    for col in _struc.columns
        col.c1 = 16.0u"inch"
        col.c2 = 16.0u"inch"
    end
    SS.to_asap!(_struc)
    _struc
end

skew_slab    = skew_struc.slabs[1]
skew_cell_set = Set(skew_slab.cell_indices)
skew_columns = SR.find_supporting_columns(skew_struc, skew_cell_set)

# Solve the baseline FEA on the skewed grid
skew_cache = SR.FEAModelCache()
skew_baseline = try
    with_logger(NullLogger()) do
        SR.run_moment_analysis(
            SR.FEA(design_approach=:frame, pattern_loading=false),
            skew_struc, skew_slab, skew_columns, h, fc, Ecs, γ;
            ν_concrete=ν, verbose=false, cache=skew_cache)
    end
catch e
    @warn "Skewed grid baseline FEA failed" exception=(e, catch_backtrace())
    nothing
end

if skew_baseline !== nothing
    skew_setup = SR._moment_analysis_setup(skew_struc, skew_slab, skew_columns, h, γ)
    skew_span_axis = skew_setup.span_axis
    skew_M0_kf = ustrip(u"kip*ft", skew_baseline.M0)

    sub("Skewed Grid Baseline")
    _printf("    Offset: ±%.1f ft (trapezoid — alternating columns)\n", ustrip(u"ft", skew_offset))
    _printf("    Mesh: %d shell elements, %d nodes\n",
            length(skew_cache.model.shell_elements), length(skew_cache.model.nodes))
    _printf("    M₀ = %.2f kip·ft (DDM reference, may not apply to skewed grid)\n", skew_M0_kf)
    _printf("    Span axis = (%.3f, %.3f)\n", skew_span_axis[1], skew_span_axis[2])
    _printf("    Cells: %s\n", join(skew_slab.cell_indices, ", "))
    _println()

    # ── Method variants for skewed grid ──
    # Use a focused subset that exercises the knobs we want to differentiate
    skew_variants = [
        ("frm",     SR.FEA(design_approach=:frame, pattern_loading=false),
         "Frame-level CL + ACI fractions"),
        ("δ-proj",  SR.FEA(design_approach=:strip, moment_transform=:projection,
                            field_smoothing=:element, cut_method=:delta_band, pattern_loading=false),
         "Element δ-band, projection"),
        ("δ-WA",    SR.FEA(design_approach=:strip, moment_transform=:wood_armer,
                            field_smoothing=:element, cut_method=:delta_band, pattern_loading=false),
         "Element δ-band, Wood–Armer"),
        ("nδ-proj", SR.FEA(design_approach=:strip, moment_transform=:projection,
                            field_smoothing=:nodal, cut_method=:delta_band, pattern_loading=false),
         "Nodal δ-band, projection"),
        ("iso1-pr", SR.FEA(design_approach=:strip, moment_transform=:projection,
                            field_smoothing=:nodal, cut_method=:isoparametric, iso_alpha=1.0,
                            pattern_loading=false),
         "Nodal iso (α=1.0 straight), projection"),
        ("iso5-pr", SR.FEA(design_approach=:strip, moment_transform=:projection,
                            field_smoothing=:nodal, cut_method=:isoparametric, iso_alpha=0.5,
                            pattern_loading=false),
         "Nodal iso (α=0.5 blended), projection"),
        ("iso0-pr", SR.FEA(design_approach=:strip, moment_transform=:projection,
                            field_smoothing=:nodal, cut_method=:isoparametric, iso_alpha=0.0,
                            pattern_loading=false),
         "Nodal iso (α=0.0 contour), projection"),
        ("δ-noMxy", SR.FEA(design_approach=:strip, moment_transform=:no_torsion,
                            field_smoothing=:element, cut_method=:delta_band, pattern_loading=false),
         "Element δ-band, no torsion"),
        ("area-pr", SR.FEA(design_approach=:area, moment_transform=:projection,
                            pattern_loading=false),
         "Area-based, projection"),
        ("area-WA", SR.FEA(design_approach=:area, moment_transform=:wood_armer,
                            pattern_loading=false),
         "Area-based, Wood–Armer"),
        ("area-noMxy", SR.FEA(design_approach=:area, moment_transform=:no_torsion,
                               pattern_loading=false),
         "Area-based, no torsion"),
        ("iso5-sep", SR.FEA(design_approach=:strip, moment_transform=:projection,
                             field_smoothing=:nodal, cut_method=:isoparametric, iso_alpha=0.5,
                             sign_treatment=:separate_faces, pattern_loading=false),
         "Nodal iso (α=0.5), separate faces"),
        ("iso1-sep", SR.FEA(design_approach=:strip, moment_transform=:projection,
                             field_smoothing=:nodal, cut_method=:isoparametric, iso_alpha=1.0,
                             sign_treatment=:separate_faces, pattern_loading=false),
         "Nodal iso (α=1.0), separate faces"),
    ]

    # ── Run all methods on the skewed grid ──
    skew_strip_results = Dict{String, NamedTuple}()
    skew_failures = Dict{String, String}()  # label => error message

    for (lbl, meth, desc) in skew_variants
        da = meth.design_approach

        if da == :frame
            res = try
                with_logger(NullLogger()) do
                    SR.run_moment_analysis(
                        meth, skew_struc, skew_slab, skew_columns, h, fc, Ecs, γ;
                        ν_concrete=ν, verbose=false, cache=skew_cache)
                end
            catch e
                skew_failures[lbl] = sprint(showerror, e)
                nothing
            end

            if res !== nothing
                cl_ext = ustrip(u"kip*ft", res.M_neg_ext)
                cl_pos = ustrip(u"kip*ft", res.M_pos)
                cl_int = ustrip(u"kip*ft", res.M_neg_int)
                cs_frac = (ext=1.00, pos=0.60, int=0.75)
                ms_frac = (ext=0.00, pos=0.40, int=0.25)
                skew_strip_results[lbl] = (
                    cl  = (ext=cl_ext, pos=cl_pos, int=cl_int),
                    cs  = (ext=cl_ext*cs_frac.ext, pos=cl_pos*cs_frac.pos, int=cl_int*cs_frac.int),
                    ms  = (ext=cl_ext*ms_frac.ext, pos=cl_pos*ms_frac.pos, int=cl_int*ms_frac.int),
                    sum = cl_ext/2 + cl_int/2 + cl_pos,
                )
            end

        elseif da == :strip
            _rax_s = !isnothing(meth.rebar_direction) ?
                SR._resolve_rebar_axis(meth, skew_span_axis) : nothing
            strips = try
                SR._dispatch_fea_strip_extraction(
                    meth, skew_cache, skew_struc, skew_slab, skew_columns, skew_span_axis;
                    rebar_axis=_rax_s, verbose=false)
            catch e
                skew_failures[lbl] = sprint(showerror, e)
                nothing
            end

            if strips !== nothing
                cs = (ext = strips.M_neg_ext_cs * _Nm_to_kf,
                      pos = strips.M_pos_cs * _Nm_to_kf,
                      int = strips.M_neg_int_cs * _Nm_to_kf)
                ms = (ext = strips.M_neg_ext_ms * _Nm_to_kf,
                      pos = strips.M_pos_ms * _Nm_to_kf,
                      int = strips.M_neg_int_ms * _Nm_to_kf)
                cl = (ext = cs.ext + ms.ext,
                      pos = cs.pos + ms.pos,
                      int = cs.int + ms.int)
                skew_strip_results[lbl] = (
                    cl  = cl, cs  = cs, ms  = ms,
                    sum = cl.ext/2 + cl.int/2 + cl.pos,
                )
            end

        elseif da == :area
            area_moms = try
                SR._extract_area_design_moments(skew_cache, meth, skew_span_axis; verbose=false)
            catch e
                skew_failures[lbl] = sprint(showerror, e)
                nothing
            end

            if area_moms !== nothing
                _rax = !isnothing(meth.rebar_direction) ?
                    SR._resolve_rebar_axis(meth, skew_span_axis) : nothing
                strips = try
                    SR._area_to_strip_envelope(
                        area_moms, skew_cache, skew_struc, skew_slab, skew_columns, skew_span_axis;
                        rebar_axis=_rax, verbose=false)
                catch e
                    skew_failures[lbl] = sprint(showerror, e)
                    nothing
                end

                if strips !== nothing
                    cs = (ext = strips.M_neg_ext_cs * _Nm_to_kf,
                          pos = strips.M_pos_cs * _Nm_to_kf,
                          int = strips.M_neg_int_cs * _Nm_to_kf)
                    ms = (ext = strips.M_neg_ext_ms * _Nm_to_kf,
                          pos = strips.M_pos_ms * _Nm_to_kf,
                          int = strips.M_neg_int_ms * _Nm_to_kf)
                    cl = (ext = cs.ext + ms.ext,
                          pos = cs.pos + ms.pos,
                          int = cs.int + ms.int)
                    skew_strip_results[lbl] = (
                        cl  = cl, cs  = cs, ms  = ms,
                        sum = cl.ext/2 + cl.int/2 + cl.pos,
                    )
                end
            end
        end
    end

    # ── Print method status (pass/fail) ──
    sub("Skewed Grid — Method Status")
    _printf("    %-10s %-6s  %s\n", "Label", "Status", "Description / Error")
    _printf("    %-10s %-6s  %s\n", "─"^10, "─"^6, "─"^40)
    for (lbl, meth, desc) in skew_variants
        if haskey(skew_strip_results, lbl)
            _printf("    %-10s %-6s  %s\n", lbl, "✓", desc)
        else
            err_msg = get(skew_failures, lbl, "unknown")
            # Truncate long error messages
            short_err = length(err_msg) > 60 ? err_msg[1:57] * "..." : err_msg
            _printf("    %-10s %-6s  %s\n", lbl, "✗", short_err)
        end
    end
    _println()

    # ── Skewed grid CL moments ──
    skew_labels = [lbl for (lbl, _, _) in skew_variants]
    n_skew = length(skew_labels)

    sub("Skewed Grid — CL Moments (kip·ft)")
    note("\"--\" = method failed on this geometry.")
    _println()

    _printf("    %-14s", "Location")
    for lbl in skew_labels; _printf(" %9s", lbl); end
    _println()
    _printf("    %-14s", "─"^14)
    for _ in 1:n_skew; _printf(" %9s", "─"^9); end
    _println()

    for (row_label, key) in [("CL Ext neg", :ext), ("CL Positive", :pos), ("CL Int neg", :int)]
        _printf("    %-14s", row_label)
        for lbl in skew_labels
            if haskey(skew_strip_results, lbl)
                _printf(" %9.1f", skew_strip_results[lbl].cl[key])
            else
                _printf(" %9s", "--")
            end
        end
        _println()
    end

    _printf("    %-14s", "Σ/M₀ (%)")
    for lbl in skew_labels
        if haskey(skew_strip_results, lbl)
            ratio = skew_M0_kf > 0 ? skew_strip_results[lbl].sum / skew_M0_kf * 100 : 0.0
            _printf(" %8.1f%%", ratio)
        else
            _printf(" %9s", "--")
        end
    end
    _println()
    _println()

    # ── Skewed grid CS moments ──
    sub("Skewed Grid — CS Moments (kip·ft)")
    _println()

    _printf("    %-14s", "Location")
    for lbl in skew_labels; _printf(" %9s", lbl); end
    _println()
    _printf("    %-14s", "─"^14)
    for _ in 1:n_skew; _printf(" %9s", "─"^9); end
    _println()

    for (row_label, key) in [("CS Ext neg", :ext), ("CS Positive", :pos), ("CS Int neg", :int)]
        _printf("    %-14s", row_label)
        for lbl in skew_labels
            if haskey(skew_strip_results, lbl)
                _printf(" %9.1f", skew_strip_results[lbl].cs[key])
            else
                _printf(" %9s", "--")
            end
        end
        _println()
    end
    _println()

    # ── Skewed grid MS moments ──
    sub("Skewed Grid — MS Moments (kip·ft)")
    _println()

    _printf("    %-14s", "Location")
    for lbl in skew_labels; _printf(" %9s", lbl); end
    _println()
    _printf("    %-14s", "─"^14)
    for _ in 1:n_skew; _printf(" %9s", "─"^9); end
    _println()

    for (row_label, key) in [("MS Ext neg", :ext), ("MS Positive", :pos), ("MS Int neg", :int)]
        _printf("    %-14s", row_label)
        for lbl in skew_labels
            if haskey(skew_strip_results, lbl)
                _printf(" %9.1f", skew_strip_results[lbl].ms[key])
            else
                _printf(" %9s", "--")
            end
        end
        _println()
    end
    _println()

    # ── Knob isolation: no_torsion vs projection on skewed grid ──
    sub("Skewed Grid — No-Torsion vs Projection (Mxy Effect)")
    note("On skewed grids, Mxy contributes even on cardinal rebar axes.")
    note("Δ% = (projection − no_torsion) / no_torsion × 100 = contribution of Mxy.")
    _println()

    _printf("    %-14s %12s %12s %12s %12s %12s %12s\n",
            "Location", "δ-noMxy", "δ-proj", "Δ%", "a-noMxy", "area-pr", "Δ%")
    _printf("    %-14s %12s %12s %12s %12s %12s %12s\n",
            "─"^14, "─"^12, "─"^12, "─"^12, "─"^12, "─"^12, "─"^12)

    for (row_label, key, strip_key) in [
        ("CS Ext neg", :ext, :cs), ("CS Positive", :pos, :cs), ("CS Int neg", :int, :cs),
        ("MS Ext neg", :ext, :ms), ("MS Positive", :pos, :ms), ("MS Int neg", :int, :ms),
    ]
        _printf("    %-14s", row_label)

        # Strip: δ-noMxy vs δ-proj
        for (ref_lbl, cmp_lbl) in [("δ-noMxy", "δ-proj"), ("area-noMxy", "area-pr")]
            has_ref = haskey(skew_strip_results, ref_lbl)
            has_cmp = haskey(skew_strip_results, cmp_lbl)
            if has_ref && has_cmp
                ref_val = getfield(skew_strip_results[ref_lbl], strip_key)[key]
                cmp_val = getfield(skew_strip_results[cmp_lbl], strip_key)[key]
                δ = abs(ref_val) > 0.01 ? (cmp_val - ref_val) / abs(ref_val) * 100 : 0.0
                _printf(" %12.1f %12.1f %+11.1f%%", ref_val, cmp_val, δ)
            else
                _printf(" %12s %12s %12s", has_ref ? "--" : "--", has_cmp ? "--" : "--", "--")
            end
        end
        _println()
    end
    _println()

    # ── Knob isolation: iso_alpha on skewed grid ──
    sub("Skewed Grid — iso_alpha Effect")
    note("For 4-vertex (quad) cells, bilinear iso-ξ lines are LINEAR in η,")
    note("so iso_alpha blending between p_iso and p_straight is a no-op.")
    note("iso_alpha only differentiates for N-gon (N≠4) Wachspress panels.")
    _println()

    _printf("    %-14s %12s %12s %12s %12s\n", "Location", "iso0-pr", "iso5-pr", "iso1-pr", "Max Δ%")
    _printf("    %-14s %12s %12s %12s %12s\n", "─"^14, "─"^12, "─"^12, "─"^12, "─"^12)

    has_iso = haskey(skew_strip_results, "iso0-pr") &&
              haskey(skew_strip_results, "iso5-pr") &&
              haskey(skew_strip_results, "iso1-pr")

    if has_iso
        sk_iso0 = skew_strip_results["iso0-pr"]
        sk_iso5 = skew_strip_results["iso5-pr"]
        sk_iso1 = skew_strip_results["iso1-pr"]
        for (row_label, key, strip_key) in [
            ("CS Ext neg", :ext, :cs), ("CS Positive", :pos, :cs), ("CS Int neg", :int, :cs),
            ("MS Ext neg", :ext, :ms), ("MS Positive", :pos, :ms), ("MS Int neg", :int, :ms),
        ]
            v0 = getfield(sk_iso0, strip_key)[key]
            v5 = getfield(sk_iso5, strip_key)[key]
            v1 = getfield(sk_iso1, strip_key)[key]
            max_δ = abs(v0) > 0.01 ? max(abs((v5 - v0) / abs(v0) * 100), abs((v1 - v0) / abs(v0) * 100)) : 0.0
            _printf("    %-14s %12.1f %12.1f %12.1f %11.2f%%\n", row_label, v0, v5, v1, max_δ)
        end
    else
        # Show which ones failed
        for iso_lbl in ["iso0-pr", "iso5-pr", "iso1-pr"]
            if !haskey(skew_strip_results, iso_lbl)
                _printf("    %s: FAILED\n", iso_lbl)
            end
        end
    end
    _println()

    # ── Knob isolation: separate_faces on skewed grid ──
    sub("Skewed Grid — Separate Faces vs Signed Smoothing")
    note("On skewed grids, inflection points may fall within column strips.")
    _println()

    _printf("    %-14s %12s %12s %12s\n", "Location", "iso5-pr", "iso5-sep", "Δ%")
    _printf("    %-14s %12s %12s %12s\n", "─"^14, "─"^12, "─"^12, "─"^12)

    has_sep = haskey(skew_strip_results, "iso5-pr") && haskey(skew_strip_results, "iso5-sep")
    if has_sep
        sk_signed = skew_strip_results["iso5-pr"]
        sk_sep    = skew_strip_results["iso5-sep"]
        for (row_label, key, strip_key) in [
            ("CS Ext neg", :ext, :cs), ("CS Positive", :pos, :cs), ("CS Int neg", :int, :cs),
            ("MS Ext neg", :ext, :ms), ("MS Positive", :pos, :ms), ("MS Int neg", :int, :ms),
        ]
            ref_val = getfield(sk_signed, strip_key)[key]
            cmp_val = getfield(sk_sep, strip_key)[key]
            δ = abs(ref_val) > 0.01 ? (cmp_val - ref_val) / abs(ref_val) * 100 : 0.0
            _printf("    %-14s %12.1f %12.1f %+11.1f%%\n", row_label, ref_val, cmp_val, δ)
        end
    else
        for sep_lbl in ["iso5-pr", "iso5-sep"]
            if !haskey(skew_strip_results, sep_lbl)
                _printf("    %s: FAILED\n", sep_lbl)
            end
        end
    end
    _println()

    # ── Skewed grid: per-element rebar field for area methods ──
    sub("Skewed Grid — Per-Element Rebar Field (mm²/m)")
    note("Same rebar sizing on the skewed grid — exercises rebar axes on non-rectangular bays.")
    _println()

    skew_area_labels = [lbl for (lbl, meth, _) in skew_variants if meth.design_approach == :area]
    skew_rebar_fields = Dict{String, SR.ElementRebarField}()

    for (lbl, meth, desc) in skew_variants
        meth.design_approach == :area || continue
        area_moms = try
            SR._extract_area_design_moments(skew_cache, meth, skew_span_axis; verbose=false)
        catch e
            nothing
        end
        area_moms === nothing && continue
        field = try
            SR._build_element_rebar_field(
                area_moms, h, _d_rebar, _fc_rebar, _fy_rebar, meth.moment_transform;
                verbose=false)
        catch e
            nothing
        end
        field !== nothing && (skew_rebar_fields[lbl] = field)
    end

    _printf("    %-12s %8s %8s %8s %8s %8s %8s %8s %8s %6s %6s\n",
            "Method", "As_min", "x_bot↑", "x_bot μ", "x_top↑", "x_top μ",
            "y_bot↑", "y_bot μ", "y_top↑", "y_top μ", "Inad.")
    _printf("    %-12s %8s %8s %8s %8s %8s %8s %8s %8s %6s %6s\n",
            "─"^12, "─"^8, "─"^8, "─"^8, "─"^8, "─"^8, "─"^8, "─"^8, "─"^8, "─"^6, "─"^6)

    for lbl in skew_area_labels
        haskey(skew_rebar_fields, lbl) || continue
        field = skew_rebar_fields[lbl]
        elems = field.elements
        n = length(elems)

        As_min_mm2 = elems[1].As_min * 1e6
        max_xb = maximum(r.As_x_bot for r in elems) * 1e6
        mean_xb = sum(r.As_x_bot for r in elems) / n * 1e6
        max_xt = maximum(r.As_x_top for r in elems) * 1e6
        mean_xt = sum(r.As_x_top for r in elems) / n * 1e6
        max_yb = maximum(r.As_y_bot for r in elems) * 1e6
        mean_yb = sum(r.As_y_bot for r in elems) / n * 1e6
        max_yt = maximum(r.As_y_top for r in elems) * 1e6
        mean_yt = sum(r.As_y_top for r in elems) / n * 1e6
        n_inad = count(!r.section_adequate for r in elems)

        _printf("    %-12s %8.0f %8.0f %8.0f %8.0f %8.0f %8.0f %8.0f %8.0f %6.0f %6d\n",
                lbl, As_min_mm2, max_xb, mean_xb, max_xt, mean_xt,
                max_yb, mean_yb, max_yt, mean_yt, n_inad)
    end

    if isempty(skew_rebar_fields)
        _println("    (no area-based methods succeeded on skewed grid)")
    end
    _println()

else
    _println("  ⚠ Skewed grid baseline FEA failed — skipping Part 5.")
    _println()
end

# ─────────────────────────────────────────────────────────────────────────────
# 16. Summary flags
# ─────────────────────────────────────────────────────────────────────────────
section("SUMMARY — POTENTIAL ISSUES")
note("Σ/M₀ > 100% is expected for FEA on multi-bay buildings (two-way action).")
note("Values up to ~150% are normal; > 150% or < 50% warrant investigation.")
note("qL/qD = $(round(qL_psf/qD_psf, digits=2)) — pattern loading " *
     (qL_psf/qD_psf > 0.75 ? "required" : "NOT required") * " (threshold: 0.75).")
_println()

let issues_found = false
    for lbl in labels_ordered
        r = strip_results[lbl]
        ratio = M0_kf > 0 ? r.sum / M0_kf * 100 : 0.0

        # Flag if Σ/M₀ is too low (< 50%) or too high (> 150%)
        if ratio < 50.0
            _println("  ⚠ $lbl: Σ/M₀ = $(round(ratio, digits=1))% — suspiciously low (< 50%)")
            issues_found = true
        elseif ratio > 150.0
            _println("  ⚠ $lbl: Σ/M₀ = $(round(ratio, digits=1))% — suspiciously high (> 150%)")
            issues_found = true
        end

        # Flag if any moment is negative (wrong sign)
        for (loc, key) in [("CS ext neg", :ext), ("CS positive", :pos), ("CS int neg", :int)]
            val = r.cs[key]
            if val < -0.1
                _println("  ⚠ $lbl: $loc = $(round(val, digits=1)) kip·ft — negative (wrong sign?)")
                issues_found = true
            end
        end

        # Flag if CS fraction is far from ACI expectations
        for (loc, key, aci_frac) in [("ext neg", :ext, 1.0), ("positive", :pos, 0.6), ("int neg", :int, 0.75)]
            cl_val = r.cl[key]
            cs_val = r.cs[key]
            if abs(cl_val) > 0.5
                actual_frac = cs_val / cl_val
                if actual_frac < 0.3 || actual_frac > 1.2
                    _printf("  ⚠ %s: CS fraction for %s = %.0f%% (ACI expects ~%.0f%%)\n",
                            lbl, loc, actual_frac*100, aci_frac*100)
                    issues_found = true
                end
            end
        end
    end

    # Check pattern loading amplification
    if haskey(pat_results, "efm-amp") && haskey(pat_results, "no-pat")
        base = pat_results["no-pat"]
        amp = pat_results["efm-amp"]
        for (loc, key) in [("ext neg", :ext), ("positive", :pos), ("int neg", :int)]
            if abs(base[key]) > 0.01
                factor = amp[key] / base[key]
                if factor > 2.0
                    _printf("  ⚠ EFM amplification for %s = %.2fx (> 2.0, unusually large)\n", loc, factor)
                    issues_found = true
                end
            end
        end
    end

    # Check per-element rebar field issues
    for lbl in area_labels
        haskey(area_rebar_fields, lbl) || continue
        field = area_rebar_fields[lbl]
        if !field.section_adequate
            n_inad = count(!r.section_adequate for r in field.elements)
            _printf("  ⚠ %s: %d elements have inadequate section (rebar field)\n", lbl, n_inad)
            issues_found = true
        end
        # Flag if max As is very large (> 5× minimum → heavy reinforcement)
        max_As = maximum(max(r.As_x_bot, r.As_x_top, r.As_y_bot, r.As_y_top)
                         for r in field.elements)
        if max_As > 5.0 * field.elements[1].As_min
            ratio = max_As / field.elements[1].As_min
            _printf("  ⚠ %s: max As = %.1f× As_min (heavy reinforcement at peak)\n", lbl, ratio)
            issues_found = true
        end
    end

    if !issues_found
        _println("  ✓ No obvious issues detected.")
    end
end

_println()
dline()
_println("  Report complete.")
dline()

# Close the report file and notify
close(_report_file)
println("\n✓ Report saved to: $REPORT_PATH")
