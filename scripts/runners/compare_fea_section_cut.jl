# Compare flat-plate design moments after the column-width, span-side section cut.
#
# Ground truth is the StructurePoint spSlab example (ACI 318-14), one 18×14 ft
# panel, h = 7 in, 16 in columns, qu = 193 psf:
#   M₀ = 93.82 kip·ft
#   end span:  M⁻_ext = 0.26 M₀ = 24.39,  M⁺ = 0.52 M₀ = 48.79,  M⁻_int = 0.70 M₀ = 65.67
# Those coefficients are what DDM applies.  EFM and FEA are not required to
# match them; the table shows how far each method sits from that example and
# from the others on the same 3×3 bay floor.
#
#   julia --project=StructuralSynthesizer -t auto scripts/runners/compare_fea_section_cut.jl

ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] = get(ENV, "SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD", "false")

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using Printf, Logging
using Unitful, Asap, StructuralSizer, StructuralSynthesizer

const SR = StructuralSizer
const SS = StructuralSynthesizer

const SP_M0 = 93.82
const SP = (M_neg_ext = 0.26 * SP_M0, M_pos = 0.52 * SP_M0, M_neg_int = 0.70 * SP_M0)

mat = SR.RC_4000_60
fc = 4000.0u"psi"
γ, ν = mat.concrete.ρ, mat.concrete.ν
Ecs = SR.Ec(fc, ustrip(SR.pcf, γ))
h = 7.0u"inch"

s = with_logger(NullLogger()) do
    struc = SS.BuildingStructure(SS.gen_medium_office(54.0u"ft", 42.0u"ft", 9.0u"ft", 3, 3, 1))
    SS.initialize!(struc; floor_type = :flat_plate,
                   floor_opts = SR.FlatPlateOptions(material = mat, method = SR.FEA(),
                                                    cover = 0.75u"inch", bar_size = 5))
    for c in struc.cells
        c.sdl = uconvert(u"kN/m^2", 20.0u"psf")
        c.live_load = uconvert(u"kN/m^2", 40.0u"psf")
    end
    for col in struc.columns
        col.c1 = 16.0u"inch"; col.c2 = 16.0u"inch"
    end
    SS.to_asap!(struc)
    struc
end
slab = s.slabs[1]
cols = SR.find_supporting_columns(s, Set(slab.cell_indices))
positions = [c.position for c in cols]

println("StructurePoint panel: M₀=$(SP_M0)  M⁻ext=$(round(SP.M_neg_ext; digits=2))  " *
        "M⁺=$(round(SP.M_pos; digits=2))  M⁻int=$(round(SP.M_neg_int; digits=2)) kip·ft")
println("Model: $(length(s.cells)) cells, $(length(cols)) columns, slab spans " *
        "l1=$(slab.spans.primary) l2=$(slab.spans.secondary)")

const CASES = [
    ("DDM", SR.DDM()),
    ("EFM", SR.EFM()),
    ("FEA flex", SR.FEA()),
    ("FEA rigid", SR.FEA(patch_stiffness_factor = 100.0)),
    ("FEA rigid 0.15m", SR.FEA(patch_stiffness_factor = 100.0, target_edge = 0.15u"m")),
]

kft(x) = ustrip(kip * u"ft", x)
kipf(x) = ustrip(kip, x)

const LONG_ROWS = Tuple{String, Any, Float64}[]

vu_of(sec) = hasproperty(sec, :Vu_max) ? kipf(sec.Vu_max) : maximum(kipf, sec.column_shears)

function print_row(name, M0, ext, int, pos, mub, Vu, defl)
    by(p) = (v = [mub[i] for i in eachindex(cols) if positions[i] == p]; isempty(v) ? NaN : maximum(abs, v))
    @printf("%-16s %8.1f %8.1f %8.1f %8.1f | %6.2f %6.2f %6.2f | %8.1f %8.1f %8.1f %8.1f %7.2f\n",
            name, M0, ext, int, pos, ext / M0, int / M0, pos / M0,
            by(:interior), by(:edge), by(:corner), Vu, defl)
end

function header(title)
    println()
    println(title)
    @printf("%-16s %8s %8s %8s %8s | %7s %7s %7s | %8s %8s %8s %8s %7s\n",
            "method", "M0", "M-ext", "M-int", "M+", "ext/M0", "int/M0", "pos/M0",
            "Mub int", "Mub edge", "Mub cor", "Vu max", "defl mm")
end

header("Primary direction (short span, l1 = $(slab.spans.primary))")
for (name, method) in CASES
    local r
    try
        r = with_logger(NullLogger()) do
            SR.run_moment_analysis(method, s, slab, cols, h, fc, Ecs, γ; ν_concrete = ν)
        end
    catch e
        println(name, " FAILED: ", first(split(sprint(showerror, e), '\n')))
        continue
    end
    defl = r.fea_Δ_panel === nothing ? NaN : ustrip(u"mm", r.fea_Δ_panel)
    print_row(name, kft(r.M0), kft(r.M_neg_ext), kft(r.M_neg_int), kft(r.M_pos),
              kft.(r.unbalanced_moments), kipf(r.Vu_max), defl)

    sec = if name in ("DDM", "EFM")
        with_logger(NullLogger()) do
            SR.run_secondary_moment_analysis(method, s, slab, cols, h, fc, Ecs, γ; ν_concrete = ν)
        end
    else
        r.secondary
    end
    # Stash on a global so the long-span table can be printed after every solve.
    push!(LONG_ROWS, (name, sec, defl))
end

header("Secondary direction (long span — StructurePoint's tabulated direction)")
for (name, sec, defl) in LONG_ROWS
    sec === nothing && (println(name, " has no secondary"); continue)
    print_row(name, kft(sec.M0), kft(sec.M_neg_ext), kft(sec.M_neg_int), kft(sec.M_pos),
              kft.(sec.unbalanced_moments), vu_of(sec), defl)
end

println()
println("Coefficients are moment / that method's own M₀ in that direction.")
println("StructurePoint long-span end-span targets: M₀=$(SP_M0), ext $(round(SP.M_neg_ext; digits=2)), pos $(round(SP.M_pos; digits=2)), int $(round(SP.M_neg_int; digits=2)) kip·ft (0.26 / 0.52 / 0.70).")
println("ACI 318-11 §13.6.3.6 exterior unbalanced moment is 0.30 M₀ of the frame strip, not of one column.")
