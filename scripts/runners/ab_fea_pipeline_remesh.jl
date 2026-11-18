# Do the FEA full-pipeline tests in test_fea_flat_plate.jl converge with and
# without the remesh on column growth?
#
#   julia --project=StructuralSynthesizer -t auto scripts/runners/ab_fea_pipeline_remesh.jl
#
# Runs the 3x3 medium-office pipeline fixture (16 in square and 18 in circular
# columns) with the remesh off at 10 passes, and on at 10 and 20 passes. Prints
# the slab result type and the column sizes each FEA call saw.

ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using Printf, Logging
using Unitful
using Asap
using StructuralSizer
using StructuralSynthesizer

const REMESH = get(ENV, "AB_REMESH", "on") == "on"
println("remesh on column growth: ", REMESH ? "on" : "off")
REMESH || @eval StructuralSizer _reset_fea_cache!(cache::FEAModelCache) = cache

function run_case(shape::Symbol, max_iter::Int)
    struc = BuildingStructure(gen_medium_office(54.0u"ft", 42.0u"ft", 9.0u"ft", 3, 3, 1))
    opts = FlatPlateOptions(material = RC_4000_60, method = FEA(), cover = 0.75u"inch",
                            bar_size = 5, shear_studs = :always, min_h = 5.0u"inch")
    initialize!(struc; floor_type = :flat_plate, floor_opts = opts)
    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 20.0 * Asap.psf)
        cell.live_load = uconvert(u"kN/m^2", 40.0 * Asap.psf)
    end
    D = shape === :circular ? 18.0u"inch" : 16.0u"inch"
    for col in struc.columns
        col.c1 = D
        col.c2 = D
        col.shape = shape
    end
    to_asap!(struc)
    tc = StructuralSizer.TraceCollector()
    t = @elapsed StructuralSizer.size_slabs!(struc; options = opts, max_iterations = max_iter, tc = tc)
    r = struc.slabs[1].result
    @printf("\n%s columns, max_iterations %d: %s, %.1f s, %d trace events\n",
            shape, max_iter, nameof(typeof(r)), t, length(tc.events))
    r isa StructuralSizer.FlatPlatePanelResult &&
        @printf("  h = %.2f in\n", ustrip(u"inch", r.h))
    for ev in tc.events
        ev.stage == "size_flat_plate!" || continue
        get(ev.data, "phase", "") == "B" || continue
        if haskey(ev.data, "failing_ratios")
            ratios = sort(collect(ev.data["failing_ratios"]); by = x -> -x[2])
            println("  punching pass: ", length(ratios), " failing, worst ",
                    join(("$(c)=$(v)" for (c, v) in first(ratios, 6)), ", "))
        elseif haskey(ev.data, "punching_ratios")
            println("  punching ok, max ratio ", maximum(ev.data["punching_ratios"]))
        end
    end
end

run_case(:rectangular, 10)
