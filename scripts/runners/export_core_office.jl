#=
Four-story flat-plate office with a central wall core and isolated spread
footings, analysis model only (members are not sized).

    julia --project=StructuralSynthesizer scripts/runners/export_core_office.jl [out.mgscene]

For the fully designed building use design_core_office.jl and
export_designed_core_office.jl. Writes viewer/public/core_office.mgscene when
no path is given.

Foundations are sized with FoundationOptions(strategy=:all_spread) on medium
sand from the reactions of the unsized frame; column bases use the support
defaults.
=#

using StructuralSynthesizer
using Asap
using Unitful

include(joinpath(@__DIR__, "core_office_geometry.jl"))

function core_office()
    struc = BuildingStructure(core_office_skeleton())
    initialize!(struc;
        floor_type = :flat_plate,
        floor_opts = FlatPlateOptions(),
        material = NWC_4000,
        wall_thickness = 0.30u"m")
    params = DesignParameters(materials = MaterialOptions(concrete = NWC_4000))
    to_asap!(struc; params = params, diaphragms = :rigid)
    solve!(struc.asap_model)
    initialize_supports!(struc)
    size_foundations!(struc;
        soil = medium_sand,
        opts = FoundationOptions(strategy = :all_spread),
        verbose = true)
    # Grade walls carry their own supports. A column off the wall stays a
    # spread footing. Every support is on one footing or the other.
    covered = Set{Int}()
    for fnd in struc.foundations
        union!(covered, fnd.support_indices)
    end
    covered == Set(eachindex(struc.supports)) || error(
        "core: $(length(covered)) of $(length(struc.supports)) supports are on a footing")
    return struc
end

const out = isempty(ARGS) ?
    joinpath(@__DIR__, "..", "..", "viewer", "public", "core_office.mgscene") :
    ARGS[1]

println("Building the four-story core office…")
struc = core_office()
mkpath(dirname(out))
packet = export_scene(out, struc)
println("wrote ", abspath(out))
println("  nodes: ", packet.meta["counts"]["nodes"],
        "  frame elements: ", packet.meta["counts"]["elements"],
        "  shell triangles: ", get(packet.meta["counts"], "shell_triangles", 0),
        "  footings: ", length(struc.foundations))
println("  max displacement: ", packet.meta["max_displacement"], " m")
println("  suggested scale: ", packet.meta["suggested_scale"])
