# Composite deck floor + composite steel beams through design_building.
ENV["SS_ENABLE_VISUALIZATION"] = "false"
using StructuralSynthesizer, StructuralSizer, Unitful, Asap
const SS = StructuralSizer

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
design = design_building(struc, params)
s = design.structure
for slab in s.slabs[1:min(end, 3)]
    r = slab.result
    println(typeof(r).name.name, " ", r.deck_profile, " g", r.deck_gauge,
            " total ", round(u"inch", r.total_depth; digits=2),
            " span ", round(u"ft", r.checks.span; digits=2),
            " sw ", round(u"psf", r.self_weight; digits=1),
            " vols ", slab.volumes)
end
for (gid, g) in s.member_groups
    g.section === nothing && continue
    println("group ", gid, " ", g.section.name)
end
