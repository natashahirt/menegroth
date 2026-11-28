# Micro-benchmark of the Asap work inside one flat-plate FEA slab analysis:
# mesh build (first call) and the per-iteration update + re-solve (later calls).
# `--profile` writes a call-tree profile of three warm update iterations.
#
#   julia --project=StructuralSynthesizer -t auto scripts/runners/bench_asap_fea_slab.jl [--profile]

ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using Printf, Profile, Logging, LinearAlgebra, SparseArrays
using Unitful
using Asap
using StructuralSizer
using StructuralSynthesizer

const SR = StructuralSizer
const SS = StructuralSynthesizer
const DO_PROFILE = "--profile" in ARGS

mat = SR.RC_4000_60
fc  = 4000.0u"psi"
struc = with_logger(NullLogger()) do
    s = SS.BuildingStructure(SS.gen_medium_office(159.0u"ft", 108.0u"ft", 14.0u"ft", 8, 5, 2))
    opts = SR.FlatPlateOptions(material = mat, method = SR.FEA(), cover = 0.75u"inch", bar_size = 5)
    SS.initialize!(s; floor_type = :flat_plate, floor_opts = opts)
    for c in s.cells
        c.sdl = uconvert(u"kN/m^2", 20.0u"psf"); c.live_load = uconvert(u"kN/m^2", 50.0u"psf")
    end
    for col in s.columns
        col.c1 = 18.0u"inch"; col.c2 = 18.0u"inch"
    end
    SS.to_asap!(s)
    s
end

slab    = struc.slabs[1]
columns = SR.find_supporting_columns(struc, Set(slab.cell_indices))
γ, ν    = mat.concrete.ρ, mat.concrete.ν
Ecs     = SR.Ec(fc, ustrip(SR.pcf, γ))
meth    = SR.FEA(design_approach = :frame, pattern_loading = false)

analyze(cache, h) = with_logger(NullLogger()) do
    SR.run_moment_analysis(meth, struc, slab, columns, h, fc, Ecs, γ;
                           ν_concrete = ν, verbose = false, cache = cache)
end

function one_round(; quiet = false)
    cache = SR.FEAModelCache()
    t_build = @elapsed analyze(cache, 8.0u"inch")
    hs = (8.5, 9.0, 9.5, 10.0, 10.5)
    t_upd = @elapsed for h in hs
        analyze(cache, h * u"inch")
    end
    if !quiet
        m = cache.model
        @printf("  mesh: %d nodes, %d shells, %d frame, %d free DOFs, nnz(S)=%d\n",
                length(m.nodes), length(m.shell_elements), length(m.frame_elements),
                length(m.freeDOFs), nnz(m.S))
        @printf("  build + first solve:  %8.3f s\n", t_build)
        @printf("  update + re-solve:    %8.3f s per iteration\n", t_upd / length(hs))
    end
    return cache
end

println("threads = ", Threads.nthreads())
one_round(quiet = true)   # compile
GC.gc()
println("warm:")
cache = one_round()

# Isolated Asap kernels on the warm model.
m = cache.model
t_K   = @elapsed for e in m.shell_elements; Asap.global_K!(e); end
t_S   = @elapsed Asap._update_S_values!(m)
t_P   = @elapsed Asap.populate_loads!(m)
t_fac = @elapsed (m._factorization = nothing; Asap._get_factorization(m))
t_sol = @elapsed Asap.solve!(m)
@printf("  kernels: global_K! (all shells, serial) %.3f s | _update_S_values! %.3f s | populate_loads! %.3f s | factorize %.3f s | solve!+post %.3f s\n",
        t_K, t_S, t_P, t_fac, t_sol)

# Old indexed S re-assembly vs. cached scatter map, same model.
nz_new = copy(m.S.nzval)
sm = m._scatter
m._scatter = nothing
t_S_old = @elapsed Asap._update_S_values!(m)
same = m.S.nzval == nz_new
m._scatter = sm
@printf("  _update_S_values!: indexed %.3f s -> scatter map %.4f s (%.0fx), bit-identical = %s\n",
        t_S_old, t_S, t_S_old / t_S, same)

if DO_PROFILE
    Profile.clear(); Profile.init(n = 10^8, delay = 0.002)
    @profile for h in (11.0, 11.5, 12.0)
        analyze(cache, h * u"inch")
    end
    open(joinpath(@__DIR__, "..", "..", "logs", "bench_asap_fea_slab_profile.txt"), "w") do io
        Profile.print(IOContext(io, :displaysize => (2000, 300)); format = :tree, maxdepth = 40,
                      mincount = 25, noisefloor = 2.0)
    end
    println("profile written to logs/bench_asap_fea_slab_profile.txt")
end
