#=
Pipeline Benchmark — End-to-End Timing
=======================================

Exercises the full StructuralSynthesizer → StructuralSizer → Asap pipeline:
  1. Package loading
  2. Building skeleton + BuildingStructure construction
  3. ASAP model creation + solve
  4. Flat-plate slab sizing (DDM)
  5. Flat-plate slab sizing (EFM)
  6. Steel member sizing

Usage:
    julia --project=. benchmarks/bench_pipeline.jl
    julia --project=. -t4 benchmarks/bench_pipeline.jl   # with 4 threads
=#

using Printf

# ─── 1. Package Loading ─────────────────────────────────────────────────────
print("1) Loading packages … ")
t_load = @elapsed begin
    using StructuralSynthesizer
    using StructuralSizer
    using Asap
    using Unitful
end
@printf("%.2f s\n", t_load)

println("   Threads: ", Threads.nthreads())

# ─── Helper ──────────────────────────────────────────────────────────────────
macro bench(label, expr)
    quote
        print("   ", $(esc(label)), " … ")
        local t = @elapsed $(esc(expr))
        @printf("%.4f s\n", t)
        t
    end
end

# =============================================================================
# 2. Building + ASAP construction
# =============================================================================
println("\n2) Building construction")

skel = nothing
struc = nothing

t_skel = @bench "gen_medium_office" begin
    skel = gen_medium_office(54.0u"ft", 42.0u"ft", 9.0u"ft", 3, 3, 1)
end

t_struc = @bench "BuildingStructure" begin
    struc = BuildingStructure(skel)
end

# =============================================================================
# 3. DDM Flat-Plate Sizing
# =============================================================================
println("\n3) DDM flat-plate sizing")

opts_ddm = FlatPlateOptions(
    material = RC_4000_60,
    method = DDM(),
    cover = 0.75u"inch",
    bar_size = 5,
)

initialize!(struc; floor_type = :flat_plate, floor_opts = opts_ddm)

for cell in struc.cells
    cell.sdl       = uconvert(u"kN/m^2", 20.0u"psf")
    cell.live_load = uconvert(u"kN/m^2", 40.0u"psf")
end
for col in struc.columns
    col.c1 = 16.0u"inch"
    col.c2 = 16.0u"inch"
end

t_asap_ddm = @bench "to_asap!" to_asap!(struc)
t_ddm = @bench "size_slabs! (DDM)" size_slabs!(struc; options = opts_ddm, verbose = false, max_iterations = 20)

# =============================================================================
# 4. EFM Flat-Plate Sizing (fresh structure)
# =============================================================================
println("\n4) EFM flat-plate sizing")

skel_efm = gen_medium_office(54.0u"ft", 42.0u"ft", 9.0u"ft", 3, 3, 1)
struc_efm = BuildingStructure(skel_efm)

opts_efm = FlatPlateOptions(
    material = RC_4000_60,
    method = EFM(),
    cover = 0.75u"inch",
    bar_size = 5,
)

initialize!(struc_efm; floor_type = :flat_plate, floor_opts = opts_efm)

for cell in struc_efm.cells
    cell.sdl       = uconvert(u"kN/m^2", 20.0u"psf")
    cell.live_load = uconvert(u"kN/m^2", 40.0u"psf")
end
for col in struc_efm.columns
    col.c1 = 16.0u"inch"
    col.c2 = 16.0u"inch"
end

t_asap_efm = @bench "to_asap!" to_asap!(struc_efm)
t_efm = @bench "size_slabs! (EFM)" size_slabs!(struc_efm; options = opts_efm, verbose = false, max_iterations = 20)

# =============================================================================
# 5. Steel Beam Sizing
# =============================================================================
println("\n5) Steel beam sizing")

L_m = ustrip(u"m", 20.0u"ft")
skel_st = BuildingSkeleton{Float64}()
id1 = add_vertex!(skel_st, [0.0, 0.0, 0.0])
id2 = add_vertex!(skel_st, [L_m, 0.0, 0.0])
e1  = add_element!(skel_st, id1, id2)
skel_st.groups_edges[:beams]   = [e1]
skel_st.groups_vertices[:support] = [id1, id2]

struc_st = BuildingStructure(skel_st)
initialize_segments!(struc_st)
for seg in struc_st.segments; seg.Lb = zero(seg.L) end
initialize_members!(struc_st)
to_asap!(struc_st)

model_st = struc_st.asap_model
model_st.nodes[id1].dof = [false, false, false, false, false, false]
model_st.nodes[id2].dof = [true,  true,  false, true,  true,  true]

w_si = uconvert(u"N/m", 2.8u"kip/ft")
push!(model_st.loads, Asap.LineLoad(model_st.elements[e1], [0.0u"N/m", 0.0u"N/m", -w_si]))

Asap.process!(model_st)
Asap.solve!(model_st)

t_steel = @bench "size_steel_members!" begin
    size_steel_members!(
        struc_st;
        member_edge_group = :beams,
        material = A992_Steel,
        optimizer = :auto,
        resolution = 200,
    )
end

# =============================================================================
# 6. ASAP Solve micro-benchmark (repeated solves)
# =============================================================================
println("\n6) ASAP micro-benchmark (100 repeated solves)")

n1 = Node([0.0, 0.0, 0.0]u"m", :fixed)
n2 = Node([5.0, 0.0, 0.0]u"m", :free)
sec = Section(0.01u"m^2", 200e9u"Pa", 80e9u"Pa", 8.33e-5u"m^4", 8.33e-5u"m^4", 1.0e-4u"m^4", 7850.0u"kg/m^3")
el  = Element(n1, n2, sec)
ld  = NodeForce(n2, [0.0, 0.0, -10_000.0]u"N")
micro_model = FrameModel([n1, n2], [el], [ld])

Asap.process!(micro_model)
Asap.solve!(micro_model)

t_solve100 = @bench "100× solve!" begin
    for _ in 1:100
        Asap.solve!(micro_model; reprocess = true)
    end
end

# =============================================================================
# Summary
# =============================================================================
println("\n", "="^60)
println("  BENCHMARK SUMMARY")
println("="^60)
@printf("  Package loading       : %8.2f s\n", t_load)
@printf("  Skeleton + Structure  : %8.4f s\n", t_skel + t_struc)
@printf("  ASAP init + solve DDM : %8.4f s\n", t_asap_ddm)
@printf("  DDM slab sizing       : %8.4f s\n", t_ddm)
@printf("  ASAP init + solve EFM : %8.4f s\n", t_asap_efm)
@printf("  EFM slab sizing       : %8.4f s\n", t_efm)
@printf("  Steel beam sizing     : %8.4f s\n", t_steel)
@printf("  100× ASAP resolve     : %8.4f s  (%.1f μs/solve)\n", t_solve100, t_solve100 / 100 * 1e6)
@printf("  ────────────────────────────────\n")
@printf("  Total (excl. loading) : %8.4f s\n",
    t_skel + t_struc + t_asap_ddm + t_ddm + t_asap_efm + t_efm + t_steel + t_solve100)
println("="^60)
