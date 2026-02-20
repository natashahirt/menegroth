# Diagnostic: Compare moment coefficients (M/M0 percentages) across methods
# This isolates the moment analysis from the iterative design loop to see
# the actual coefficients each method produces for the same geometry.
#
# Run: julia --project=StructuralStudies scripts/runners/run_moment_coefficient_comparison.jl

using StructuralSizer
using StructuralSynthesizer
using Unitful
using Printf

const SR = StructuralSizer

# Test case: 24x24 ft panel with 250 psf live load (where we saw big discrepancy)
const LX = 24.0
const LY = 24.0
const LL = 250.0
const SDL = 20.0
const STORY_HT = 12.0  # ft

println("\n" * "="^80)
println("MOMENT COEFFICIENT COMPARISON — Same Geometry, Same Thickness")
println("="^80)
println("Panel: $(LX) × $(LY) ft  |  Live Load: $(LL) psf  |  Story: $(STORY_HT) ft")
println("="^80)

# Build skeleton (3×3 bay grid)
skel = gen_medium_office(
    LX * 3 * u"ft", LY * 3 * u"ft", STORY_HT * u"ft",
    3, 3, 1
)

# Set up structure with a FIXED slab thickness (to isolate moment analysis)
# Use the DDM-converged thickness (18.5") so all methods see the same loads
const H_FIXED = 18.5u"inch"

struc = BuildingStructure(skel)

# Initialize with flat plate
opts = FlatPlateOptions(
    material = RC_4000_60,
    method = DDM(),  # Method doesn't matter for initialization
    cover = 0.75u"inch",
    bar_size = 5,
)
initialize!(struc; floor_type=:flat_plate, floor_opts=opts)

# Update live load
for cell in struc.cells
    cell.live_load = LL * psf
    cell.sdl = SDL * psf
end

# Get an interior slab and its columns
slab = struc.slabs[1]
columns = SR.get_supporting_columns(struc, slab)

# Material properties
fc = 4000.0u"psi"
Ecs = SR.Ec(fc)
γ_concrete = 2400.0u"kg/m^3"

println("\nRunning moment analysis with FIXED h = $(H_FIXED)...")
println("-"^80)

# Run each method's moment analysis directly (bypassing design iteration)
# Skip FEA for now since it's slow and we want to compare DDM vs EFM
methods_to_run = [
    ("DDM (Full)", SR.DDM(:full)),
    ("MDDM", SR.DDM(:simplified)),
    ("EFM (HC)", SR.EFM(:moment_distribution; pattern_loading=false)),
    ("EFM (ASAP)", SR.EFM(:asap; pattern_loading=false)),
]

results = Dict{String, Any}()

for (name, method) in methods_to_run
    print("  $name: ")
    try
        t0 = time()
        result = SR.run_moment_analysis(
            method, struc, slab, columns, H_FIXED, fc, Ecs, γ_concrete;
            verbose=false
        )
        elapsed = time() - t0
        results[name] = result
        println("$(round(elapsed, digits=2))s")
    catch e
        println("FAILED - $(typeof(e))")
        results[name] = e
    end
end

# Print comparison table
println("\n" * "="^80)
println("MOMENT ANALYSIS RESULTS (h = $(H_FIXED) for all methods)")
println("="^80)

# Header
@printf("\n  %-12s  %10s  %10s  %10s  %10s  %10s  %8s\n",
        "Method", "M0", "M⁻_ext", "M⁺", "M⁻_int", "qu", "∑/M0")
println("  " * "-"^76)

for name in ["DDM (Full)", "MDDM", "EFM (HC)", "EFM (ASAP)"]
    r = get(results, name, nothing)
    if isnothing(r) || r isa Exception
        @printf("  %-12s  %s\n", name, r isa Exception ? "FAILED" : "skipped")
        continue
    end
    
    M0 = ustrip(u"kip*ft", r.M0)
    Mne = ustrip(u"kip*ft", r.M_neg_ext)
    Mp = ustrip(u"kip*ft", r.M_pos)
    Mni = ustrip(u"kip*ft", r.M_neg_int)
    qu = ustrip(psf, r.qu)
    
    # Equilibrium check: (M_neg_ext + M_neg_int)/2 + M_pos should ≈ M0
    sum_check = (Mne + Mni) / 2 + Mp
    sum_ratio = M0 > 0 ? sum_check / M0 : 0.0
    
    @printf("  %-12s  %10.1f  %10.1f  %10.1f  %10.1f  %10.1f  %8.1f%%\n",
            name, M0, Mne, Mp, Mni, qu, sum_ratio * 100)
end

# Coefficient comparison
println("\n" * "="^80)
println("MOMENT COEFFICIENTS (% of M0)")
println("="^80)

@printf("\n  %-12s  %10s  %10s  %10s  %10s\n",
        "Method", "M⁻_ext/M0", "M⁺/M0", "M⁻_int/M0", "Total")
println("  " * "-"^56)

# DDM reference coefficients
@printf("  %-12s  %10s  %10s  %10s  %10s\n",
        "ACI DDM", "26%", "52%", "70%", "148%")
println("  " * "-"^56)

for name in ["DDM (Full)", "MDDM", "EFM (HC)", "EFM (ASAP)"]
    r = get(results, name, nothing)
    if isnothing(r) || r isa Exception
        continue
    end
    
    M0 = ustrip(u"kip*ft", r.M0)
    Mne = ustrip(u"kip*ft", r.M_neg_ext)
    Mp = ustrip(u"kip*ft", r.M_pos)
    Mni = ustrip(u"kip*ft", r.M_neg_int)
    
    c_ext = M0 > 0 ? 100 * Mne / M0 : 0.0
    c_pos = M0 > 0 ? 100 * Mp / M0 : 0.0
    c_int = M0 > 0 ? 100 * Mni / M0 : 0.0
    c_total = c_ext + c_pos + c_int
    
    @printf("  %-12s  %9.1f%%  %9.1f%%  %9.1f%%  %9.1f%%\n",
            name, c_ext, c_pos, c_int, c_total)
end

# Compare with DDM as baseline
println("\n" * "="^80)
println("DIFFERENCE FROM DDM (FULL)")
println("="^80)

ddm_r = get(results, "DDM (Full)", nothing)
if !isnothing(ddm_r) && !(ddm_r isa Exception)
    ddm_M0 = ustrip(u"kip*ft", ddm_r.M0)
    ddm_Mne = ustrip(u"kip*ft", ddm_r.M_neg_ext)
    ddm_Mp = ustrip(u"kip*ft", ddm_r.M_pos)
    ddm_Mni = ustrip(u"kip*ft", ddm_r.M_neg_int)
    
    @printf("\n  %-12s  %10s  %10s  %10s  %10s\n",
            "Method", "ΔM⁻_ext", "ΔM⁺", "ΔM⁻_int", "ΔM0")
    println("  " * "-"^56)
    
    for name in ["EFM (HC)", "EFM (ASAP)"]
        r = get(results, name, nothing)
        if isnothing(r) || r isa Exception
            continue
        end
        
        M0 = ustrip(u"kip*ft", r.M0)
        Mne = ustrip(u"kip*ft", r.M_neg_ext)
        Mp = ustrip(u"kip*ft", r.M_pos)
        Mni = ustrip(u"kip*ft", r.M_neg_int)
        
        d_M0 = ddm_M0 > 0 ? 100 * (M0 - ddm_M0) / ddm_M0 : 0.0
        d_Mne = ddm_Mne > 0 ? 100 * (Mne - ddm_Mne) / ddm_Mne : 0.0
        d_Mp = ddm_Mp > 0 ? 100 * (Mp - ddm_Mp) / ddm_Mp : 0.0
        d_Mni = ddm_Mni > 0 ? 100 * (Mni - ddm_Mni) / ddm_Mni : 0.0
        
        @printf("  %-12s  %+9.1f%%  %+9.1f%%  %+9.1f%%  %+9.1f%%\n",
                name, d_Mne, d_Mp, d_Mni, d_M0)
    end
end

println("\n" * "="^80)
println("Done!")
