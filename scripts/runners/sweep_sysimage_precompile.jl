# Precompile trace for build_sweep_sysimage.jl: one small building per slab
# method through the same per-case function the sweep workers call.

using Logging, LinearAlgebra
using Unitful, Asap, StructuralSizer, StructuralSynthesizer

const _TRACE_METHODS = Dict(
    "ddm" => () -> StructuralSizer.DDM(),
    "efm" => () -> StructuralSizer.EFM(),
    "fea" => () -> StructuralSizer.FEA(),
)

function build_case(c)
    skel = gen_medium_office(c.span_ft * 3 * u"ft", c.span_ft * 3 * u"ft", 12.0u"ft", 3, 3, c.stories)
    params = DesignParameters(name = c.id, max_iterations = 2,
                              floor = StructuralSizer.FlatPlateOptions(method = _TRACE_METHODS[c.method]()))
    return BuildingStructure(skel), params
end

include(joinpath(@__DIR__, "sweep_case_runner.jl"))

for m in ("ddm", "efm", "fea")
    row = run_sweep_case((id = "trace_$m", span_ft = 18.0, stories = 2, method = m))
    @info "sysimage trace" method=m status=row.status seconds=round(row.seconds; digits = 1) error=row.error
end
