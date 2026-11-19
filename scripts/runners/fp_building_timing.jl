# Warm timing of prepare! and to_asap! on a flat-plate building, with and
# without building-model flat-plate shells.
#   SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true julia --project=StructuralSynthesizer scripts/runners/fp_building_timing.jl
using StructuralSynthesizer, StructuralSizer, Unitful, Printf

const SS = StructuralSynthesizer

function building(mode)
    skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 2)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        floor = FlatPlateOptions(),
        materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
        skip_visualization = true,
        flat_plate_analysis = mode,
    )
    return struc, params
end

for mode in (:building, :options, :building)
    struc, params = building(mode)
    tp = @elapsed SS.prepare!(struc, params)
    ta = @elapsed SS.to_asap!(struc; params)
    ts = @elapsed SS.update_analysis!(struc, :geometry; params)
    @printf("%-9s prepare! %.1f s   to_asap! %.1f s   :geometry update %.1f s   shells %d\n",
            mode, tp, ta, ts, length(struc.asap_model.shell_elements))
end
