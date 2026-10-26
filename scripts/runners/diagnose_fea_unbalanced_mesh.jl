# Diagnostic: does the column-stub unbalanced moment converge with mesh size,
# and does stiffening the column-footprint shell patch change that?
#
# Column stubs attach to a single slab node; with patch_stiffness_factor = 1
# the footprint is ordinary slab, so the stub moment enters the plate as a
# point moment. This sweeps (patch factor × target edge) on the 3×3, 30 ft
# grid and prints max |Mub|, max column M⁻ (band pinned to column width) and
# the panel deflection.
#
#   julia --project=StructuralSynthesizer -t auto scripts/runners/diagnose_fea_unbalanced_mesh.jl

ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] = get(ENV, "SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD", "false")

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using Printf, Logging
using Unitful, Asap, StructuralSizer, StructuralSynthesizer

const SR = StructuralSizer
const SS = StructuralSynthesizer

const EDGES_M = [0.08, 0.10, 0.15, 0.20, 0.30, 0.50]
const PATCH_FACTORS = [1.0, 10.0, 100.0, 1000.0]

mat = SR.RC_4000_60
fc  = 4000.0u"psi"
γ, ν = mat.concrete.ρ, mat.concrete.ν
Ecs = SR.Ec(fc, ustrip(SR.pcf, γ))
h = 11.0u"inch"

s = with_logger(NullLogger()) do
    s = SS.BuildingStructure(SS.gen_medium_office(90.0u"ft", 90.0u"ft", 12.0u"ft", 3, 3, 2))
    SS.initialize!(s; floor_type = :flat_plate,
                   floor_opts = SR.FlatPlateOptions(material = mat, method = SR.FEA(), cover = 0.75u"inch", bar_size = 5))
    for c in s.cells
        c.sdl = uconvert(u"kN/m^2", 20.0u"psf"); c.live_load = uconvert(u"kN/m^2", 50.0u"psf")
    end
    for col in s.columns
        col.c1 = 22.0u"inch"; col.c2 = 22.0u"inch"
    end
    SS.to_asap!(s)
    s
end
slab = s.slabs[1]
cols = SR.find_supporting_columns(s, Set(slab.cell_indices))
positions = [c.position for c in cols]

function run_case(te, pf)
    cache = SR.FEAModelCache()
    r = with_logger(NullLogger()) do
        SR.run_moment_analysis(SR.FEA(target_edge = te * u"m", patch_stiffness_factor = pf),
                               s, slab, cols, h, fc, Ecs, γ; ν_concrete = ν, cache = cache)
    end
    h0 = cache.mesh_edge_length
    cache.mesh_edge_length = 0.0
    fb = SR._extract_cell_moments(cache, s, slab, cols, SR._get_span_axis(slab))
    cache.mesh_edge_length = h0
    mub = ustrip.(u"kN*m", r.unbalanced_moments)
    by_pos(p) = (v = [mub[i] for i in eachindex(cols) if positions[i] == p]; isempty(v) ? NaN : maximum(abs, v))
    return (mub_int = by_pos(:interior), mub_edge = by_pos(:edge), mub_corner = by_pos(:corner),
            colM = maximum(fb.col_Mneg) / 1e3, defl = ustrip(u"mm", r.fea_Δ_panel),
            n = length(cache.model.shell_elements))
end

run_case(1.0, 1.0)  # compile

rows = ["patch_factor,target_edge_m,n_shells,mub_interior_kNm,mub_edge_kNm,mub_corner_kNm,colM_fixed_band_kNm,defl_mm"]
for pf in PATCH_FACTORS
    println("\n== patch_stiffness_factor = $pf ==")
    @printf("  %6s %7s | %10s %10s %10s | %12s %8s\n", "edge", "shells", "Mub int", "Mub edge", "Mub corner", "colM (c band)", "defl mm")
    for te in EDGES_M
        GC.gc()
        r = run_case(te, pf)
        @printf("  %5.2fm %7d | %10.1f %10.1f %10.1f | %12.1f %8.2f\n",
                te, r.n, r.mub_int, r.mub_edge, r.mub_corner, r.colM, r.defl)
        push!(rows, join((pf, te, r.n, r.mub_int, r.mub_edge, r.mub_corner, r.colM, r.defl), ","))
    end
end

out = joinpath(@__DIR__, "..", "..", "logs", "fea_unbalanced_mesh.csv")
write(out, join(rows, "\n") * "\n")
println("\nwrote ", normpath(out))
