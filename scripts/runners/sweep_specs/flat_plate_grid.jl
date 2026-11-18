# Example sweep spec for sweep_design_building.jl: flat-plate office grid
# (span × stories × slab analysis method), 8×5 bays, 12 ft stories.

const _METHODS = Dict(
    "ddm" => () -> StructuralSizer.DDM(),
    "efm" => () -> StructuralSizer.EFM(),
    "fea" => () -> StructuralSizer.FEA(),
)

function sweep_cases()
    [(id = "s$(Int(span))_n$(n)_$(m)", span_ft = span, stories = n, method = m)
     for m in ("ddm", "fea"), n in (3, 6), span in (20.0, 24.0, 28.0)]
end

function build_case(c)
    nx, ny = 8, 5
    skel = gen_medium_office(c.span_ft * nx * u"ft", c.span_ft * ny * u"ft", 12.0u"ft", nx, ny, c.stories)
    params = DesignParameters(
        name  = c.id,
        floor = StructuralSizer.FlatPlateOptions(method = _METHODS[c.method]()),
    )
    return BuildingStructure(skel), params
end
