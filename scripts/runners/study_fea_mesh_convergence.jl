# Mesh-convergence study for the flat-plate FEA moment analysis.
#
# For each target mesh edge length, runs `run_moment_analysis(FEA(target_edge=…))`
# on one slab and reports the design quantities the sizing loop consumes
# (frame-strip moments, column moments/shears/unbalanced moments, Vu_max, FEA
# panel deflection) as relative differences from the finest mesh, plus element
# count and timings.
#
#   julia --project=StructuralSynthesizer -t auto scripts/runners/study_fea_mesh_convergence.jl [GEOM] [EDGE_M...]
#
# Optional GEOM restricts to one geometry name; EDGE_M overrides the edge list
# (finest first). Writes logs/fea_mesh_convergence[_GEOM].csv.

ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] = get(ENV, "SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD", "false")

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using Printf, Logging
using Unitful
using Asap
using StructuralSizer
using StructuralSynthesizer

const SR = StructuralSizer
const SS = StructuralSynthesizer

# Finest first: it is the reference for the relative differences.
const EDGES_M = length(ARGS) >= 2 ? parse.(Float64, ARGS[2:end]) : [0.20, 0.30, 0.40, 0.50, 0.60, 0.75, 1.00]

const ALL_GEOMETRIES = [
    (name = "office_8x5_20ft", Lx = 159.0u"ft", Ly = 108.0u"ft", nx = 8, ny = 5, col = 18.0u"inch", h = 9.0u"inch"),
    (name = "grid_3x3_30ft",   Lx = 90.0u"ft",  Ly = 90.0u"ft",  nx = 3, ny = 3, col = 22.0u"inch", h = 11.0u"inch"),
]
const GEOMETRIES = isempty(ARGS) ? ALL_GEOMETRIES : filter(g -> g.name == ARGS[1], ALL_GEOMETRIES)

mat = SR.RC_4000_60
fc  = 4000.0u"psi"
γ, ν = mat.concrete.ρ, mat.concrete.ν
Ecs = SR.Ec(fc, ustrip(SR.pcf, γ))

function build_struc(g)
    with_logger(NullLogger()) do
        s = SS.BuildingStructure(SS.gen_medium_office(g.Lx, g.Ly, 12.0u"ft", g.nx, g.ny, 2))
        opts = SR.FlatPlateOptions(material = mat, method = SR.FEA(), cover = 0.75u"inch", bar_size = 5)
        SS.initialize!(s; floor_type = :flat_plate, floor_opts = opts)
        for c in s.cells
            c.sdl = uconvert(u"kN/m^2", 20.0u"psf"); c.live_load = uconvert(u"kN/m^2", 50.0u"psf")
        end
        for col in s.columns
            col.c1 = g.col; col.c2 = g.col
        end
        SS.to_asap!(s)
        s
    end
end

"""Scalar summaries of a `MomentAnalysisResult` that drive sizing (SI-stripped)."""
function summarize(r)
    kNm(x) = ustrip(u"kN*m", x); kN(x) = ustrip(u"kN", x)
    maxabs(v) = isempty(v) ? 0.0 : maximum(abs, v)
    return (
        M_neg_ext = kNm(r.M_neg_ext), M_neg_int = kNm(r.M_neg_int), M_pos = kNm(r.M_pos),
        col_M_max = maxabs(kNm.(r.column_moments)),
        col_V_max = maxabs(kN.(r.column_shears)),
        unbal_max = maxabs(kNm.(r.unbalanced_moments)),
        Vu_max = kN(r.Vu_max),
        defl_mm = r.fea_Δ_panel === nothing ? NaN : ustrip(u"mm", r.fea_Δ_panel),
    ), (col_M = kNm.(r.column_moments), col_V = kN.(r.column_shears), unbal = kNm.(r.unbalanced_moments))
end

relpct(a, b) = 100 * (a - b) / max(abs(b), 1e-9)
maxrel(v, ref) = isempty(v) ? 0.0 : 100 * maximum(abs.(v .- ref)) / max(maximum(abs, ref), 1e-9)

rows = String[]
push!(rows, "geometry,target_edge_m,n_shells,n_dofs,t_build_s,t_iter_s," *
            "M_neg_ext,M_neg_int,M_pos,col_M_max,col_V_max,unbal_max,Vu_max,defl_mm," *
            "dM_neg_ext_pct,dM_neg_int_pct,dM_pos_pct,dcol_M_pct,dcol_V_pct,dunbal_pct,dVu_pct,ddefl_pct,h_mesh_m,band_m,fixed_band_colM,dfixed_band_colM_pct")

# Compile on a coarse mesh before timing.
let g = ALL_GEOMETRIES[2], s = build_struc(g)
    slab = s.slabs[1]; cols = SR.find_supporting_columns(s, Set(slab.cell_indices))
    with_logger(NullLogger()) do
        c = SR.FEAModelCache()
        SR.run_moment_analysis(SR.FEA(target_edge = 1.0u"m"), s, slab, cols, g.h, fc, Ecs, γ; ν_concrete = ν, cache = c)
        SR.run_moment_analysis(SR.FEA(target_edge = 1.0u"m"), s, slab, cols, g.h + 0.5u"inch", fc, Ecs, γ; ν_concrete = ν, cache = c)
    end
end

for g in GEOMETRIES
    s = build_struc(g)
    slab = s.slabs[1]
    cols = SR.find_supporting_columns(s, Set(slab.cell_indices))
    println("\n== $(g.name): $(length(cols)) columns, h = $(g.h), columns $(g.col) ==")
    @printf("  %6s %8s %8s %8s %7s | %8s %8s %8s %8s %8s %8s %8s %8s\n", "edge", "shells", "build", "iter",
            "", "Mneg,ext", "Mneg,int", "Mpos", "colM", "colV", "Munbal", "Vu", "defl")
    ref = nothing
    for te in EDGES_M
        meth = SR.FEA(target_edge = te * u"m")
        cache = SR.FEAModelCache()
        GC.gc()
        local r
        t_build = @elapsed r = with_logger(NullLogger()) do
            SR.run_moment_analysis(meth, s, slab, cols, g.h, fc, Ecs, γ; ν_concrete = ν, cache = cache)
        end
        # Same solution, column M⁻ re-extracted with the section-cut band pinned
        # to the column width (mesh_edge_length = 0 selects that fallback),
        # separating mesh effects on the FE field from band-width effects.
        h_mesh = cache.mesh_edge_length
        δ_used = SR._section_cut_bandwidth(cache, cols)
        cache.mesh_edge_length = 0.0
        fb = SR._extract_cell_moments(cache, s, slab, cols, SR._get_span_axis(slab))
        cache.mesh_edge_length = h_mesh
        fb_M = fb.col_Mneg ./ 1e3
        t_iter = @elapsed with_logger(NullLogger()) do
            SR.run_moment_analysis(meth, s, slab, cols, g.h + 0.5u"inch", fc, Ecs, γ; ν_concrete = ν, cache = cache)
        end
        m = cache.model
        sm, vecs = summarize(r)
        ref === nothing && (ref = (sm, vecs, fb_M))
        rs, rv, rfb = ref
        d = (relpct(sm.M_neg_ext, rs.M_neg_ext), relpct(sm.M_neg_int, rs.M_neg_int), relpct(sm.M_pos, rs.M_pos),
             maxrel(vecs.col_M, rv.col_M), maxrel(vecs.col_V, rv.col_V), maxrel(vecs.unbal, rv.unbal),
             relpct(sm.Vu_max, rs.Vu_max), relpct(sm.defl_mm, rs.defl_mm))
        d_fb = relpct(maximum(fb_M), maximum(rfb))
        @printf("  %5.2fm %8d %7.1fs %7.2fs   Δ%%: | %+8.2f %+8.2f %+8.2f %8.2f %8.2f %8.2f %+8.2f %+8.2f | h=%.3f δ=%.3f fixed-band colM %+7.2f\n",
                te, length(m.shell_elements), t_build, t_iter, d..., h_mesh, δ_used, d_fb)
        push!(rows, join(Any[g.name, te, length(m.shell_elements), length(m.freeDOFs),
                             round(t_build; digits = 2), round(t_iter; digits = 3),
                             values(sm)..., (round.(d; digits = 3))...,
                             round(h_mesh; digits = 4), round(δ_used; digits = 4), maximum(fb_M), round(d_fb; digits = 3)], ","))
    end
end

out = joinpath(@__DIR__, "..", "..", "logs", isempty(ARGS) ? "fea_mesh_convergence.csv" : "fea_mesh_convergence_$(ARGS[1]).csv")
mkpath(dirname(out))
write(out, join(rows, "\n") * "\n")
println("\nwrote ", normpath(out))
println("Δ% columns: signed % difference from the $(EDGES_M[1]) m mesh (column-vector quantities: max abs difference / max abs reference).")
