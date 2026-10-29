# The four 20 ft flat-plate buildings from the carbon takeoff comparison:
# 8×5 bays, 12 ft stories, DDM and FEA, 3 and 6 stories.
# Column cap is span/15 (16 in on a 20 ft bay), the main-run cap in
# StructuralStudies (`span15_max_col`). The library default is 30 in.

const _METHODS = Dict(
    "ddm" => () -> StructuralSizer.DDM(),
    "fea" => () -> StructuralSizer.FEA(),
)

function sweep_cases()
    [(id = "s20_n$(n)_$(m)", span_ft = 20.0, stories = n, method = m)
     for m in ("ddm", "fea"), n in (3, 6)]
end

function build_case(c)
    nx, ny = 8, 5
    skel = gen_medium_office(c.span_ft * nx * u"ft", c.span_ft * ny * u"ft", 12.0u"ft", nx, ny, c.stories)
    # span/15 in inches: 0.8 × span_ft, clamped to 16–36 in.
    max_col = clamp(round(c.span_ft * 0.8), 16.0, 36.0) * u"inch"
    params = DesignParameters(
        name  = c.id,
        floor = StructuralSizer.FlatPlateOptions(
            method = _METHODS[c.method](),
            max_column_size = max_col,
        ),
    )
    return BuildingStructure(skel), params
end
