# Quick diagnostic: compare methods on specific large-span cases
# Run: julia --project=StructuralStudies scripts/runners/run_quick_method_check.jl

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "flat_plate_method_comparison.jl"))

using Printf

# Test cases: large spans where we saw discrepancies
test_cases = [
    (lx=24.0, ly=24.0, ll=250.0),  # 24x24, high live load
    (lx=32.0, ly=32.0, ll=150.0),  # 32x32, medium live load
    (lx=36.0, ly=36.0, ll=250.0),  # 36x36, high live load
]

println("\n" * "="^80)
println("QUICK METHOD COMPARISON — Pattern Loading DISABLED for EFM/FEA")
println("="^80)

for tc in test_cases
    println("\n" * "-"^80)
    println("Span: $(tc.lx) × $(tc.ly) ft  |  Live Load: $(tc.ll) psf")
    println("-"^80)
    
    # Build skeleton
    ht = max(12.0, round(max(tc.lx, tc.ly) / 3.0))
    max_col = clamp(round(max(tc.lx, tc.ly) * 0.9), 36.0, 60.0)
    
    skel = gen_medium_office(
        tc.lx * 3 * u"ft", tc.ly * 3 * u"ft", ht * u"ft",
        3, 3, 1
    )
    
    base_params = _make_params(;
        floor_type = :flat_plate,
        sdl_psf = 20.0,
        max_col_in = max_col,
        min_h = nothing,
    )
    
    struc = BuildingStructure(skel)
    prepare!(struc, base_params)
    
    # Update live load
    for cell in struc.cells
        cell.live_load = tc.ll * psf
    end
    
    # Run each method
    results = Dict{String, NamedTuple}()
    
    for mcfg in ALL_METHODS
        row = _run_method(struc, base_params, mcfg;
                          lx_ft = tc.lx, ly_ft = tc.ly, live_psf = tc.ll,
                          floor_type = :flat_plate)
        if !isnothing(row) && hasproperty(row, :h_in)
            results[mcfg.name] = row
        else
            println("  $(mcfg.name): FAILED")
        end
    end
    
    # Print comparison table
    @printf("\n  %-12s  %8s  %10s  %10s  %10s  %8s\n",
            "Method", "h (in)", "M0 (kip-ft)", "qu (psf)", "punch", "pattern")
    println("  " * "-"^70)
    
    for name in ["ACI Min", "MDDM", "DDM (Full)", "EFM (HC)", "EFM (ASAP)", "FEA"]
        if haskey(results, name)
            r = results[name]
            h = round(r.h_in, digits=1)
            M0 = round(r.M0_kipft, digits=1)
            qu = round(r.qu_psf, digits=1)
            punch = r.punch_ok ? "OK" : "FAIL"
            pat = hasproperty(r, :pattern_loading) ? (r.pattern_loading ? "yes" : "no") : "-"
            @printf("  %-12s  %8.1f  %10.1f  %10.1f  %8s  %8s\n",
                    name, h, M0, qu, punch, pat)
        end
    end
end

println("\n" * "="^80)
println("Done!")
