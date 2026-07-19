# Phase 2 integration smoke: to_asap! must preserve all-:fixedfixed behavior
# when segment release symbols are :default (the placeholder default).
# Run: SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer scripts/runners/run_phase2_toasap_smoke.jl
using Unitful, Asap
using StructuralSynthesizer, StructuralSizer
const SS = StructuralSynthesizer

skel = gen_medium_office(60.0u"ft", 60.0u"ft", 12.0u"ft", 2, 2, 1)
struc = BuildingStructure(skel)
opts = FlatPlateOptions(material=RC_4000_60, method=DDM(), cover=0.75u"inch", bar_size=5)
initialize!(struc; floor_type=:flat_plate, floor_opts=opts)
for cell in struc.cells
    cell.sdl = uconvert(u"kN/m^2", 20.0u"psf")
    cell.live_load = uconvert(u"kN/m^2", 50.0u"psf")
end
for col in struc.columns
    col.c1 = 16.0u"inch"; col.c2 = 16.0u"inch"
end

to_asap!(struc; params=DesignParameters())

releases = [SS._get_release_symbol(el) for el in struc.asap_model.elements if el isa Asap.Element]
println("n_frame_elements = ", length(releases))
uniq = unique(releases)
println("unique releases   = ", uniq)
@assert !isempty(releases) "no frame elements built"
@assert uniq == [:fixedfixed] "expected all :fixedfixed, got $uniq"
println("PASS: to_asap! preserved all-:fixedfixed under :default releases")
