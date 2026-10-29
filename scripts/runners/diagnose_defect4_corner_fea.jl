# =============================================================================
# DIAGNOSTIC (read-only): Defect-4 corner punching — FEA-fallback hypothesis
# =============================================================================
#
# Reproduces EXACTLY the first + second blocks of the failing testset
#   "Corner punching — pipeline / RuleOfThumb pass Muy"
#   (StructuralSizer/test/slabs/test_corner_punching.jl, lines ~468-552)
# and reports empirical facts needed to resolve the fork:
#
#   (A) FEA corner SECONDARY transfer moment ~0  -> genuine FEA safety bug
#       (FEA column-force / secondary-moment extraction understates corner
#        biaxial punching), OR
#   (B) FEA corner SECONDARY non-zero but != DDM coefficient (0.3*M0) ->
#       method-inherent oracle/geometry mismatch (a single all-4-corners
#       panel can never satisfy ACI 318-11 §13.6.1.1, so DDM is not
#       applicable and production correctly falls back to FEA; the oracle
#       forces DDM and therefore cannot agree within rtol 0.08).
#
# It does NOT modify any source/test file.  Per the runner-scripts rule it
# lives under scripts/runners/.
#
# Run from repo root (honouring the one-Julia-process constraint):
#   SS_ENABLE_VISUALIZATION=false SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD=false \
#     julia --project=StructuralSizer scripts/runners/diagnose_defect4_corner_fea.jl
# =============================================================================

using Test
using Unitful
using Unitful: @u_str
using Asap
using StructuralSizer
using StructuralSynthesizer

const SS = StructuralSizer

psi(x)   = ustrip(u"psi", x)
kft(x)   = ustrip(kip * u"ft", x)
r3(x)    = round(x; digits = 3)

"""Build the exact 20×30 single-panel test building with 16" square columns."""
function build_case()
    skel = gen_medium_office(20.0u"ft", 30.0u"ft", 10.0u"ft", 1, 1, 1)
    struc = BuildingStructure(skel)
    opts = FlatPlateOptions(min_h = 7.0u"inch")
    initialize!(struc; floor_type = :flat_plate, floor_opts = opts)
    for col in struc.columns
        col.c1 = 16.0u"inch"
        col.c2 = 16.0u"inch"
    end
    slab = first(struc.slabs)
    return (; struc, slab, opts)
end

"""Print the resolved method record for a `size_flat_plate!` result."""
function report_method(label, res)
    println("── $label method record ───────────────────────────────")
    println("  method_requested        = ", res.method_requested)
    println("  method_used             = ", res.method_used)
    println("  method_fallback_reasons = ", res.method_fallback_reasons)
    fell_back = !isempty(res.method_fallback_reasons) ||
                string(res.method_used) != string(res.method_requested)
    println("  >>> DDM-not-applicable → FEA fallback fired? ", fell_back ? "YES" : "no")
    return fell_back
end

"""
Per-corner oracle table for one design run.

`res`        : the `size_flat_plate!` result (production detail source)
`struc`,`slab`: the (already-designed) structure/slab
`opts`       : FlatPlateOptions used
Returns a vector of per-corner NamedTuples with the key numbers.
"""
function report_corners(label, res, struc, slab, opts)
    println("── $label per-corner oracle ───────────────────────────")
    h = res.h_final
    d = effective_depth(h; cover = opts.cover, bar_diameter = bar_diameter(opts.bar_size))
    mat = opts.material
    fc  = mat.concrete.fc′
    ρc  = mat.concrete.ρ
    Ecs = Ec(fc, ustrip(pcf, ρc))

    cols = SS.find_supporting_columns(struc, Set(slab.cell_indices))

    # DDM oracle (what the test forces), regardless of what production used.
    primary   = SS.run_moment_analysis(DDM(), struc, slab, cols, h, fc, Ecs, ρc)
    secondary = SS.run_secondary_moment_analysis(DDM(), struc, slab, cols, h, fc, Ecs, ρc)

    # FEA analysis (what production actually uses after the §13.6.1.1 fallback).
    # The FEA secondary is produced *inside* run_moment_analysis and stashed in
    # `.secondary`; run_secondary_moment_analysis(::FEA) only re-extracts it.
    fea_primary = SS.run_moment_analysis(FEA(), struc, slab, cols, h, fc, Ecs, ρc)
    fea_secondary = fea_primary.secondary

    details = res.slab_result.punching_check.details

    # One-time structural dump of the stored detail so we can see exactly which
    # fields are persisted (the stored PunchingCheckResult carries `Mub` — the
    # primary transfer moment — and `vu`, but NOT a separate secondary moment).
    printed_dump = false

    out = NamedTuple[]
    for (i, col) in enumerate(cols)
        col.position == :corner || continue
        gidx = findfirst(==(col), struc.columns)
        pr = details[gidx]

        if !printed_dump
            println("  stored detail propertynames = ", propertynames(pr))
            printed_dump = true
        end

        r_old = SS.check_punching_for_column(
            col, primary.column_shears[i], primary.unbalanced_moments[i], d, h, fc)
        r_new = SS.check_punching_for_column(
            col, primary.column_shears[i], primary.unbalanced_moments[i], d, h, fc;
            Muy = secondary.unbalanced_moments[i])

        ddm_Mux = primary.unbalanced_moments[i]
        ddm_Muy = secondary.unbalanced_moments[i]
        fea_Mux = fea_primary.unbalanced_moments[i]
        fea_Muy = isnothing(fea_secondary) ? nothing : fea_secondary.unbalanced_moments[i]

        println("  corner gidx=$gidx  (cols index i=$i)")
        println("    production  pr.vu         = ", r3(psi(pr.vu)), " psi   ",
                "(stored pr.Mub = ", r3(kft(pr.Mub)), " kip*ft)")
        println("    DDM r_old.vu (Mux only)   = ", r3(psi(r_old.vu)), " psi   ",
                "(DDM Mux = ", r3(kft(ddm_Mux)), " kip*ft)")
        println("    DDM r_new.vu (Mux+Muy)    = ", r3(psi(r_new.vu)), " psi   ",
                "(DDM Muy = ", r3(kft(ddm_Muy)), " kip*ft)")
        println("    FEA  Mux (primary)        = ", r3(kft(fea_Mux)), " kip*ft")
        println("    FEA  Muy (secondary)      = ",
                isnothing(fea_Muy) ? "nothing" : string(r3(kft(fea_Muy)), " kip*ft"),
                "   <<< FORK-RESOLVING NUMBER")
        println("    rtol(pr.vu, r_new.vu)     = ",
                r3(abs(psi(pr.vu) - psi(r_new.vu)) / psi(r_new.vu)))

        push!(out, (; gidx, i,
                    pr_vu = psi(pr.vu), pr_Mub = kft(pr.Mub),
                    r_old_vu = psi(r_old.vu), r_new_vu = psi(r_new.vu),
                    ddm_Mux = kft(ddm_Mux), ddm_Muy = kft(ddm_Muy),
                    fea_Mux = kft(fea_Mux),
                    fea_Muy = isnothing(fea_Muy) ? nothing : kft(fea_Muy)))
    end
    println("  n_corners = ", length(out))
    return out
end

function main()
    println("=========================================================")
    println(" DEFECT-4 CORNER PUNCHING — FEA-FALLBACK DIAGNOSTIC")
    println("=========================================================")

    # ── Run 1: RuleOfThumb() ──────────────────────────────────────────
    c1 = build_case()
    col_opts = ConcreteColumnOptions()
    rot = SS.size_flat_plate!(c1.struc, c1.slab, col_opts;
                              method = RuleOfThumb(), opts = c1.opts, verbose = false)
    println()
    rot_fallback = report_method("RuleOfThumb()", rot)
    rot_corners  = report_corners("RuleOfThumb()", rot, c1.struc, c1.slab, c1.opts)

    # ── Run 2: DDM() (fresh building) ─────────────────────────────────
    c2 = build_case()
    pipe = SS.size_flat_plate!(c2.struc, c2.slab, ConcreteColumnOptions();
                               method = DDM(), opts = c2.opts, verbose = false)
    println()
    ddm_fallback = report_method("DDM()", pipe)
    ddm_corners  = report_corners("DDM()", pipe, c2.struc, c2.slab, c2.opts)

    # ── Verdict ───────────────────────────────────────────────────────
    println()
    println("=========================================================")
    println(" VERDICT INPUTS")
    println("=========================================================")
    println("  RuleOfThumb fell back to FEA? ", rot_fallback)
    println("  DDM        fell back to FEA? ", ddm_fallback)

    # Pick the DDM-run corners (production == FEA fallback there if ddm_fallback)
    allc = vcat(rot_corners, ddm_corners)
    fea_muys = [c.fea_Muy for c in allc if c.fea_Muy !== nothing]
    if !isempty(fea_muys)
        maxabs = maximum(abs, fea_muys)
        println("  max |FEA corner secondary Muy| = ", r3(maxabs), " kip*ft")
        ddm_muys = [c.ddm_Muy for c in allc]
        println("  representative DDM corner Muy coeff = ",
                r3(isempty(ddm_muys) ? NaN : maximum(abs, ddm_muys)), " kip*ft")
        if maxabs < 0.5
            println("  >>> FEA corner secondary is ~0  ->  FORK (A) FEA-bug candidate")
        else
            println("  >>> FEA corner secondary is NON-ZERO but differs from DDM coeff",
                    "  ->  FORK (B) oracle/geometry mismatch candidate")
        end
    end
    println("=========================================================")
end

main()
