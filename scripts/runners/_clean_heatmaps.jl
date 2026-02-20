using CSV, DataFrames

const SDL_PSF  = 20.0
const WC_PCF   = 148.5   # NWC_4000: 2380 kg/m³ ≈ 148.5 pcf
const DDM_METHODS = ("MDDM", "DDM (Full)")

"""Estimate ACI L/D ratio from geometry and live load."""
function aci_LD_ratio(lx_ft, ly_ft, live_psf)
    h_min_in = max(max(lx_ft, ly_ft) * 12 / 33, 5.0)
    sw_psf   = h_min_in / 12 * WC_PCF
    D        = SDL_PSF + sw_psf
    return live_psf / D
end

"""Mark DDM rows ineligible where L/D > 2.0 (ACI §8.10.2.6)."""
function postprocess_LD!(df::DataFrame)
    df.LD_ratio    = aci_LD_ratio.(df.lx_ft, df.ly_ft, df.live_psf)
    df.ddm_eligible = .!(
        (df.method .∈ Ref(DDM_METHODS)) .& (df.LD_ratio .> 2.0)
    )
    n_flagged = count(.!df.ddm_eligible)
    @info "Flagged $n_flagged / $(nrow(df)) rows as DDM-ineligible (L/D > 2.0)"
    return df
end

# --- Process all heatmap CSVs in results/ ---
results_dir = joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                       "flat_plate_methods", "results")

for f in readdir(results_dir; join=true)
    endswith(f, ".csv") || continue
    occursin("heatmap", f) || continue

    df = CSV.read(f, DataFrame)
    hasproperty(df, :method) || continue

    postprocess_LD!(df)
    CSV.write(f, df)       # overwrite in place
    @info "Updated $(basename(f))"
end