# Smoke run: flat plate analysed on the building model (FEA(source = :building)).
#   SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true julia --project=StructuralSynthesizer scripts/runners/fp_building_smoke.jl
using StructuralSynthesizer, StructuralSizer, Asap, Unitful

const SS = StructuralSynthesizer

skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 2)
struc = BuildingStructure(skel)
params = DesignParameters(
    floor = FlatPlateOptions(),
    materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
    max_iterations = 5,
    skip_visualization = true,
)

t0 = time()
design = design_building(struc, params; restore = false)
println("design_building: ", round(time() - t0; digits = 1), " s")

m = struc.asap_model
println("shells: ", length(m.shell_elements), "  frames: ", length(m.frame_elements),
        "  nodes: ", length(m.nodes))
println("area loads: ", count(l -> l isa Asap.AreaLoad, m.loads),
        "  tributary loads: ", count(l -> l isa Asap.TributaryLoad, m.loads))

for (i, slab) in enumerate(struc.slabs)
    r = slab.result
    d = slab.design_details
    src = d isa NamedTuple && hasproperty(d, :analysis_source) ? d.analysis_source : :unknown
    println("slab $i: h = ", hasproperty(r, :thickness) ? r.thickness : "?", "  source = ", src)
    if d isa NamedTuple && hasproperty(d, :punching_check) && d.punching_check !== nothing
        pc = d.punching_check
        hasproperty(pc, :max_ratio) && println("   punching max ratio = ", round(pc.max_ratio; digits = 3))
    end
end
