# Which beams bear on no slab after prepare! with a composite deck floor?
ENV["SS_ENABLE_VISUALIZATION"] = "false"
using StructuralSynthesizer, StructuralSizer, Unitful, Asap
const SS = StructuralSizer
const SY = StructuralSynthesizer

nwc145 = SS.Concrete(SS.NWC_4000.E, SS.NWC_4000.fc′,
                     uconvert(u"kg/m^3", 145.0u"lb/ft^3"), 0.2, SS.NWC_4000.ecc)
skel = gen_medium_office(40.0u"ft", 30.0u"ft", 12.0u"ft", 4, 3, 1)
struc = BuildingStructure(skel)
params = DesignParameters(
    floor = CompositeDeckOptions(deck_profile = "2VLI", fill_material = nwc145),
    materials = MaterialOptions(concrete = nwc145, steel = SS.A992_Steel),
    beams = SteelBeamOptions(composite = true),
    columns = SteelColumnOptions(),
)
prepare!(struc, params)
println("slabs: ", length(struc.slabs), "  beams: ", length(struc.beams))
println("slab spans: ", unique(s.spans.primary for s in struc.slabs))
none = [b for b in struc.beams if isempty(SY._slabs_on_beam(struc, b))]
println("beams with no slab: ", length(none))
vc = struc.skeleton.geometry.vertex_coords
for b in none[1:min(end, 6)]
    e = struc.segments[first(SY.segment_indices(b))].edge_idx
    a, c = struc.skeleton.edge_indices[e]
    println("  role ", b.role, " level ", b.level, " z ", vc[a, 3], " ", vc[c, 3],
            " groups ", [g for (g, es) in struc.skeleton.groups_edges if e in es])
end
