# A rectangular slab on columns, with a right-click switch between rib grids.
#
# One 24 ft square office, two bays each way, one story. Every design shares
# the concrete beams and columns. One-way and two-way differ only in the
# floor, so a right-click on the slab switches them. The beam grid and the
# grillage bay counts differ only in the framing, so a right-click on a beam
# switches the rib configuration.
#
#     julia --project=StructuralSynthesizer scripts/runners/rib_bay_scene.jl [out.mgscene]

using Asap
using Unitful
using StructuralSynthesizer
using StructuralSizer

const OUT = isempty(ARGS) ?
    joinpath(@__DIR__, "..", "..", "viewer", "public", "rib_bay.mgscene") :
    ARGS[1]

function _params(floor, framing)
    return DesignParameters(
        name = "rib bay",
        description = "rectangular slab on columns",
        floor = floor,
        beams = ConcreteBeamOptions(material = NWC_4000, include_flange = true),
        columns = ConcreteColumnOptions(material = NWC_4000),
        loads = GravityLoads(floor_LL = 50.0u"psf", floor_SDL = 15.0u"psf",
                             roof_LL = 50.0u"psf", roof_SDL = 15.0u"psf"),
        materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
        framing_opts = framing,
        max_iterations = 3,
        skip_visualization = true,
    )
end

function _grillage(nξ, nη; solid_head = 0.0)
    # One rib module is 1/n of the panel. Opposite corner heads meet at 1/2,
    # so a 2-bay grid cannot hold a solid head.
    return (;
        materials = (; concrete = NWC_4000),
        n_xi = nξ,
        n_eta = nη,
        analysis = :grillage,
        solid_head = solid_head,
        beam_options = ConcreteBeamOptions(material = NWC_4000, include_flange = true),
    )
end

struc = BuildingStructure(gen_medium_office(24.0u"ft", 24.0u"ft", 12.0u"ft", 2, 2, 1))
params = DesignParameters[
    _params(OneWayOptions(), NamedTuple()),
    _params(OneWayOptions(), _grillage(2, 2)),
    _params(OneWayOptions(), _grillage(4, 4; solid_head = 0.25)),
    _params(TwoWayOptions(), NamedTuple()),
    _params(TwoWayOptions(), _grillage(2, 2)),
    _params(TwoWayOptions(), _grillage(4, 4; solid_head = 0.25)),
]

println("Writing $(length(params)) designs to $OUT")
ids = write_design_variants(OUT, struc, params)
println("variants: ", join(ids, ", "))
