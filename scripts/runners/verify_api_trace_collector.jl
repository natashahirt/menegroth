# Quick sanity check: design_building(...; tc=TraceCollector()) fills solver_trace.
# Run: julia --project=StructuralSynthesizer scripts/runners/verify_api_trace_collector.jl
using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))
using StructuralSynthesizer
using StructuralSizer
using Unitful

skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 1)
struc = BuildingStructure(skel)
tc = TraceCollector()
design = design_building(
    struc,
    DesignParameters(
        name = "trace_api_smoke",
        materials = MaterialOptions(concrete = NWC_4000),
        floor = FlatPlateOptions(method = DDM()),
        max_iterations = 2,
    );
    tc=tc,
)
n = length(design.solver_trace)
println("solver_trace events: ", n)
@assert n > 0 "expected non-empty solver_trace when tc is passed"
println("ok")
