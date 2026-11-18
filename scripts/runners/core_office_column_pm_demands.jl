#=
Column P-M demands on one open floor of the core office, at the starting slab
thickness, as `_size_flat_plate!` forms them on its first iteration.

    SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
        julia --project=StructuralSynthesizer scripts/runners/core_office_column_pm_demands.jl

Prints Pu, Mu (primary and secondary), the §13.6.9.2 distribution factor, and
whether the column catalog holds a section for that column alone.
Does not design the building.
=#

using StructuralSynthesizer
using StructuralSizer
using Unitful
using Printf

include(joinpath(@__DIR__, "core_office_geometry.jl"))

const Z_FLOOR = parse(Float64, get(ENV, "CORE_FLOOR_Z", "3.6"))

struc = BuildingStructure(core_office_skeleton())
initialize!(struc; floor_type = :flat_plate, wall_thickness = 0.3u"m")

idx = findfirst(struc.slabs) do s
    z = StructuralSizer._slab_elevation_m(struc, s)
    z !== nothing && abs(z - Z_FLOOR) < 0.1
end
idx === nothing && error("no slab at z = $Z_FLOOR m")
slab = struc.slabs[idx]

opts = FlatPlateOptions(material = RC_4000_60, method = FEA(design_approach = :strip))
column_opts = ConcreteColumnOptions(material = RC_4000_60.concrete, rebar_material = Rebar_60)
material = opts.material
fc = material.concrete.fc′
γ = material.concrete.ρ
Ecs = Ec(fc, ustrip(pcf, γ))

columns = find_supporting_columns(struc, Set(slab.cell_indices))
ln_max = max(slab.spans.primary, slab.spans.secondary)
c_init = min(estimate_column_size_from_span(ln_max), opts.max_column_size)
for col in columns
    if isnothing(col.c1) || col.c1 <= 0u"inch"
        col.c1 = c_init
        col.c2 = c_init
    end
end
has_edge = StructuralSizer.slab_discontinuous_edge(struc, slab, columns)
h = min_thickness(FlatPlate(), ln_max; discontinuous_edge = has_edge)
sw = StructuralSizer.slab_self_weight(h, γ)

println("Floor z = $Z_FLOOR m, slab $idx, ", length(columns), " columns, h = ",
        round(u"m", h; digits = 3), ", c_init = ", round(u"inch", c_init; digits = 1))
flush(stdout)

Pu = StructuralSizer.compute_column_axial_loads(struc, columns, Set(slab.cell_indices), sw)
dist = StructuralSizer.column_moment_distribution_factors(
    struc, columns, column_opts; span_axis = StructuralSizer._get_span_axis(slab))

cache = FEAModelCache()
t = @elapsed r = StructuralSizer.run_moment_analysis(
    opts.method, struc, slab, columns, h, fc, Ecs, γ;
    ν_concrete = material.concrete.ν, verbose = false,
    col_I_factor = opts.col_I_factor, cache = cache,
)
println("FEA moment analysis: ", round(t; digits = 1), " s")
model = cache.model
println("  nodes ", length(model.nodes), "  shells ", length(model.shell_elements),
        "  frames ", length(model.frame_elements),
        "  NaN in u: ", count(isnan, model.u), " / ", length(model.u),
        "  NaN in reactions: ", count(isnan, model.reactions),
        "  NaN column shears: ", count(v -> isnan(ustrip(v)), r.column_shears),
        "  M0 = ", round(kip * u"ft", r.M0; digits = 1))
flush(stdout)
sec = r.secondary

_xyz(n) = ustrip.(u"m", n.position)
if any(isnan, model.u)
    areas = map(model.shell_elements) do sh
        p = map(_xyz, sh.nodes)
        a = p[2] .- p[1]; b = p[3] .- p[1]
        0.5 * sqrt(sum(abs2, (a[2]*b[3]-a[3]*b[2], a[3]*b[1]-a[1]*b[3], a[1]*b[2]-a[2]*b[1])))
    end
    order = sortperm(areas)
    println("  smallest shell areas (m²):")
    for k in order[1:5]
        c = sum(map(_xyz, model.shell_elements[k].nodes)) ./ 3
        @printf("    %.3e at (%.3f, %.3f, %.3f)\n", areas[k], c...)
    end
    used = Set{UInt64}()
    for sh in model.shell_elements, n in sh.nodes; push!(used, objectid(n)); end
    for el in model.frame_elements; push!(used, objectid(el.nodeStart), objectid(el.nodeEnd)); end
    orphans = [n for n in model.nodes if objectid(n) ∉ used]
    println("  nodes in no element: ", length(orphans))
    for n in orphans[1:min(end, 5)]
        println("    ", round.(_xyz(n); digits = 3), "  dof ", n.dof)
    end
    println("  frame stubs:")
    for el in model.frame_elements
        a = _xyz(el.nodeStart); b = _xyz(el.nodeEnd)
        @printf("    (%.2f, %.2f, %.2f) → (%.2f, %.2f, %.2f)  L = %.3f m  free dof %s / %s\n",
                a..., b..., sqrt(sum(abs2, b .- a)), string(el.nodeStart.dof), string(el.nodeEnd.dof))
    end
end
flush(stdout)

if get(ENV, "CORE_DROP_CORNERS", "0") == "1"
    core = ((8.0, 8.0), (16.0, 8.0), (8.0, 16.0), (16.0, 16.0))
    keep = filter(columns) do col
        c = Meshes.coords(struc.skeleton.vertices[col.vertex_idx])
        p = (ustrip(u"m", c.x), ustrip(u"m", c.y))
        !any(q -> hypot(p[1] - q[1], p[2] - q[2]) < 1e-3, core)
    end
    cache2 = FEAModelCache()
    r2 = StructuralSizer.run_moment_analysis(
        opts.method, struc, slab, keep, h, fc, Ecs, γ;
        ν_concrete = material.concrete.ν, verbose = false,
        col_I_factor = opts.col_I_factor, cache = cache2,
    )
    println("Without the 4 core-corner columns (", length(keep), " columns): NaN in u ",
            count(isnan, cache2.model.u), " / ", length(cache2.model.u))
    flush(stdout)
end

geometries = [ConcreteMemberGeometry(col.base.L; Lu = col.base.L, kx = 1.0, ky = 1.0, braced = true)
              for col in columns]

println()
@printf("  %3s  %-9s  %13s  %8s  %6s  %10s  %10s  %s\n",
        "i", "position", "(x, y) m", "Pu kip", "DF", "Mu kip·ft", "Muy kip·ft", "catalog")
for (i, col) in enumerate(columns)
    v = struc.skeleton.vertices[col.vertex_idx]
    c = Meshes.coords(v)
    x = ustrip(u"m", c.x); y = ustrip(u"m", c.y)
    # Same moment the slab loop designs for: the below-stub moment when the
    # shell stored one, otherwise the joint moment times the stiffness share.
    Mu = StructuralSizer.column_design_moment(r, i, dist.primary[i])
    Muy = isnothing(sec) ? 0.0 : StructuralSizer.column_design_moment(sec, i, dist.secondary[i])
    verdict = try
        res = size_columns([Pu[i]], [Mu], [geometries[i]], column_opts; Muy = [Muy])
        s = res.sections[1]
        isnothing(s) ? "rejected" : "ok " * sprint(show, s; context = :compact => true)[1:min(end, 40)]
    catch e
        e isa ArgumentError || rethrow()
        "INFEASIBLE"
    end
    @printf("  %3d  %-9s  (%5.1f, %5.1f)  %8.1f  %6.3f  %10.1f  %10.1f  %s\n",
            i, col.position, x, y, Pu[i], dist.primary[i], Mu, Muy, verdict)
end
