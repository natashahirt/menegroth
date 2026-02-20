# =============================================================================
# Quick smoke test: all four flat plate/slab × ACI/nomin variations
# =============================================================================
# Runs a 3×3 bay 24 ft grid at 50 psf LL with EFM for all four combos:
#   1. flat_plate + ACI min
#   2. flat_plate + nomin
#   3. flat_slab  + ACI min
#   4. flat_slab  + nomin
#
# Usage:  julia scripts/runners/run_quick_plate_test.jl
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", ".."))

using Unitful
using StructuralSizer
using StructuralSynthesizer

const SR = StructuralSizer

println("="^70)
println("  Four-Variant Flat Plate / Slab Smoke Test")
println("="^70)

# ─── Build skeleton once ─────────────────────────────────────────────────────
span   = 24.0
n_bays = 3
ht     = 13.0
total  = span * n_bays * u"ft"
skel   = gen_medium_office(total, total, ht * u"ft", n_bays, n_bays, 1)
struc  = BuildingStructure(skel)

ll_psf  = 50.0
sdl_psf = 20.0

variants = [
    ("flat_plate", "ACI",   :flat_plate, nothing),
    ("flat_plate", "nomin", :flat_plate, 1.0u"inch"),
    ("flat_slab",  "ACI",   :flat_slab,  nothing),
    ("flat_slab",  "nomin", :flat_slab,  1.0u"inch"),
]

for (label, mh_label, ft, min_h) in variants
    println("\n─── $label ($mh_label) ───")

    fp = SR.FlatPlateOptions(
        method          = SR.EFM(:asap),
        material        = SR.RC_4000_60,
        shear_studs     = :if_needed,
        max_column_size = 36.0u"inch",
        min_h           = min_h,
    )
    floor = ft === :flat_slab ? SR.FlatSlabOptions(base = fp) : fp

    params = DesignParameters(
        name       = "$(label)_$(mh_label)",
        loads      = GravityLoads(floor_LL = ll_psf * psf, roof_LL = ll_psf * psf,
                                   floor_SDL = sdl_psf * psf, roof_SDL = sdl_psf * psf),
        materials  = MaterialOptions(concrete = SR.NWC_4000, rebar = SR.Rebar_60),
        columns    = SR.ConcreteColumnOptions(grade = SR.NWC_6000, catalog = :high_capacity),
        floor      = floor,
        max_iterations = 100,
    )

    t0 = time()
    ok = true
    design = nothing
    try
        design = design_building(struc, params)
    catch e
        ok = false
        println("  ✗ Pipeline threw: ", sprint(showerror, e))
    end
    elapsed = round(time() - t0; digits=2)

    if ok && !isnothing(design)
        for (idx, sr) in design.slabs
            if sr.converged
                h_in = round(ustrip(u"inch", sr.thickness); digits=1)
                pat  = sr.pattern_loading ? "YES" : "no"
                println("  slab $idx ✓  h=$(h_in)in  iters=$(sr.iterations)  pattern=$pat  ($(elapsed)s)")
            else
                println("  slab $idx ✗  $(sr.failure_reason)  failing=$(sr.failing_check)  iters=$(sr.iterations)  ($(elapsed)s)")
            end
        end
    end
end

println("\n" * "="^70)
println("  Done.")
println("="^70)
