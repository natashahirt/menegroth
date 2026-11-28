# Trial: one story of concrete ribs through design_building.
#
# A 2×2 bay office, one-way slab, ribs at 30 in centers sized as T-beams
# (`include_flange`). After the design, each rib is checked against ACI 318-11
# §8.13. The topping between the ribs is not designed here.

using StructuralSynthesizer
using StructuralSizer
using Unitful
using Printf

const SS = StructuralSynthesizer
const SR = StructuralSizer

skel = gen_medium_office(40.0u"ft", 30.0u"ft", 12.0u"ft", 2, 2, 1)
struc = BuildingStructure(skel)

rib_opts = SR.ConcreteBeamOptions(
    material = SR.NWC_4000,
    include_flange = true,
)
girder_opts = SR.ConcreteBeamOptions(
    material = SR.NWC_4000,
    include_flange = true,
)

params = DesignParameters(
    floor = SR.OneWayOptions(),
    beams = girder_opts,
    columns = SR.ConcreteColumnOptions(material = SR.NWC_4000),
    skip_visualization = true,
    framing_opts = (;
        materials = (; beam = SR.NWC_4000),
        spacing = 30.0u"inch",
        beam_options = rib_opts,
    ),
)

println("design_building: 40 ft × 30 ft, 2×2 bays, one story, 30 in rib spacing")
design = design_building(struc, params)
final = design.structure

joists = filter(b -> b isa SS.Beam && SS.is_joist(b), final.beams)
girders = filter(b -> b isa SS.Beam && SS.level_of(b) == 0, final.beams)
println("joists: ", length(joists), "   girders: ", length(girders))
println("diagnostics: ", length(design.diagnostics))
for d in design.diagnostics
    println("  ", d)
end

function _report_rib(beam, center)
    sec = beam.base.section
    sec === nothing && return "unsized"
    sec isa SR.RCTBeamSection || return "$(something(sec.name, "?")) ($(nameof(typeof(sec))))"
    joist = SR.JoistConstruction(sec, center, :one_way)
    chk = SR.check_joist_construction(joist)
    bw = ustrip(u"inch", sec.bw)
    h = ustrip(u"inch", sec.h)
    hf = ustrip(u"inch", sec.hf)
    stem = ustrip(u"inch", joist.rib_depth)
    clear = ustrip(u"inch", joist.clear_spacing)
    return @sprintf("%s  bw=%.1f in  h=%.1f in  hf=%.1f in  stem=%.1f in  clear=%.1f in  ok=%s  Vc+10%%=%s",
                    something(sec.name, "?"), bw, h, hf, stem, clear, chk.ok, chk.vc_increase_permitted)
end

println("rib check (first of each distinct section):")
seen = Set{String}()
for beam in joists
    line = _report_rib(beam, 30.0u"inch")
    line in seen && continue
    push!(seen, line)
    println("  ", line)
end
isempty(joists) && println("  no joists were materialized")

# Per framing level: interior and edge groups and their flanges. After column
# sizing, `member_groups` holds columns, so the joists are found by group id.
for slab in final.slabs, fl in slab.framing_levels
    fl.group_id === nothing && continue
    for (label, gid) in (("interior", fl.group_id), ("edge", fl.edge_group_id))
        gid === nothing && continue
        members = [b for b in final.beams if group_id(b) == gid]
        isempty(members) && continue
        sec = section(first(members))
        bf = sec isa SR.RCTBeamSection ? @sprintf("%.1f", ustrip(u"inch", sec.bf)) : "-"
        @printf("  slab %d  %-8s  %2d joists  %s  bf=%s in\n", fl.slab_idx, label,
                length(members), sec === nothing ? "unsized" : sec.name, bf)
    end
end

println("girder flanges:")
for g in girders
    sec = g.base.section
    sec isa SR.RCTBeamSection || continue
    line = @sprintf("  %s  bf=%.1f in  hf=%.1f in", sec.name, ustrip(u"inch", sec.bf),
                    ustrip(u"inch", sec.hf))
    line in seen && continue
    push!(seen, line)
    println(line)
end
