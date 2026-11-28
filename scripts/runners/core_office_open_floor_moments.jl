#=
One open floor of the core office: equivalent frame next to the shell.

    SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
        julia --project=StructuralSynthesizer scripts/runners/core_office_open_floor_moments.jl

Floor at 3.6 m. Direct design is expected to fail ACI 318-11 §13.6.1.1.
Does not design the building and does not write a scene.
=#

using StructuralSynthesizer
using StructuralSizer
using Unitful
using Printf

include(joinpath(@__DIR__, "core_office_geometry.jl"))

const Z_OPEN = 3.6

struc = BuildingStructure(core_office_skeleton())
initialize!(struc; floor_type = :flat_plate, wall_thickness = 0.3u"m")

function _slab_at(struc, z0)
    i = findfirst(struc.slabs) do s
        z = StructuralSizer._slab_elevation_m(struc, s)
        z !== nothing && abs(z - z0) < 0.1
    end
    i === nothing && error("no slab at z = $z0 m")
    return i, struc.slabs[i]
end

idx, slab = _slab_at(struc, Z_OPEN)
columns = find_supporting_columns(struc, Set(slab.cell_indices))
isempty(columns) && error("open floor has no columns")

ln_max = max(slab.spans.primary, slab.spans.secondary)
c_min = estimate_column_size_from_span(ln_max)
for col in columns
    if isnothing(col.c1) || col.c1 <= 0u"inch"
        col.c1 = c_min
        col.c2 = c_min
    end
end

println("Open floor z = $Z_OPEN m, slab $idx")
println("  spans ", round(u"ft", slab.spans.primary; digits = 1), " × ",
        round(u"ft", slab.spans.secondary; digits = 1))
println("  columns ", length(columns),
        "  wall lines ", length(StructuralSizer.supporting_wall_segments(struc, slab)))

permitted = Dict{String, Bool}()
for (name, result) in (
        ("DDM", StructuralSizer.check_ddm_applicability(struc, slab, columns; throw_on_failure = false)),
        ("EFM", StructuralSizer.check_efm_applicability(struc, slab, columns; throw_on_failure = false)),
    )
    permitted[name] = result.ok
    println(name, result.ok ? " applicable" : " refused")
    for v in result.violations
        println("  ", v)
    end
end

has_edge = any(col.position != :interior for col in columns)
h = min_thickness(FlatPlate(), ln_max; discontinuous_edge = has_edge)
println("  h = ", round(u"inch", h; digits = 2), " (Table 9.5(c))")

opts = FlatPlateOptions(material = RC_4000_60)
fc = opts.material.concrete.fc′
γ = opts.material.concrete.ρ
Ecs = Ec(fc, ustrip(pcf, γ))
ν = opts.material.concrete.ν

wanted = Set(split(get(ENV, "OPEN_FLOOR_METHODS", "DDM,EFM,FEA"), ","))
methods = (
    ("DDM", DDM()),
    ("EFM", EFM()),
    ("FEA", FEA()),
)

println()
@printf("  %-8s  %10s  %10s  %10s  %10s  %10s\n",
        "Method", "M₀", "M⁻_col_ext", "M⁻_col_int", "M⁺", "M⁻_wall")
println("  ", "─"^66)

fea_cache = FEAModelCache()
for (name, method) in methods
    name in wanted || continue
    t = @elapsed r = try
        StructuralSizer.run_moment_analysis(
            method, struc, slab, columns, h, fc, Ecs, γ;
            ν_concrete = ν, verbose = false, col_I_factor = opts.col_I_factor,
            cache = name == "FEA" ? fea_cache : nothing,
        )
    catch e
        e
    end
    if r isa Exception
        println("  ", name, "  failed in ", round(t; digits = 1), " s")
        println("    ", sprint(showerror, r))
    else
        M0 = ustrip(kip * u"ft", r.M0)
        Mne = ustrip(kip * u"ft", r.M_neg_ext)
        Mni = ustrip(kip * u"ft", r.M_neg_int)
        Mp = ustrip(kip * u"ft", r.M_pos)
        Mw = ustrip(kip * u"ft", r.M_wall_ext + r.M_wall_int)
        note = get(permitted, name, true) ? "" : "  refused by applicability"
        @printf("  %-8s  %10.1f  %10.1f  %10.1f  %10.1f  %10.1f   (%.1f s)%s\n",
                name, M0, Mne, Mni, Mp, Mw, t, note)
    end
    flush(stdout)
end
println("  Units: kip·ft.  Column and wall negatives are separate supports.")

if "FEA" in wanted && fea_cache.initialized
    ax = StructuralSizer._get_span_axis(slab)
    faces = StructuralSizer._fea_wall_face_moments(fea_cache, struc, slab, ax)
    println()
    println("  Shell hogging at the wall face, perpendicular to the span")
    if isempty(faces)
        println("    none")
    else
        for w in faces
            @printf("    (%.1f, %.1f) m   L = %.1f m   M⁻ = %8.1f kip·ft\n",
                    w.x, w.y, w.L, ustrip(kip * u"ft", w.M))
        end
    end
end
