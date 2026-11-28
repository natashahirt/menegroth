# Bar placement preview: design a flat plate building and an RC beam building,
# detail them, print a takeoff summary, and write scenes the viewer can open.
#
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer scripts/runners/detailing_preview.jl

using StructuralSynthesizer
using StructuralSynthesizer: _detail_record
using Unitful
import JSON3

const OUT = joinpath(@__DIR__, "..", "..", "logs")

function _params(name; kwargs...)
    return DesignParameters(; name, max_iterations = 5, skip_visualization = true,
        geometry_is_centerline = false,
        materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
        foundation_options = FoundationParameters(soil = medium_sand,
            options = FoundationOptions(strategy = :all_spread)),
        kwargs...)
end

_kg(x) = round(Int, ustrip(u"kg", x))

"""Rebar mass in a `MaterialVolumes` dict (the summary's volume-based takeoff)."""
_volume_rebar(vols) = sum((v * k.ρ for (k, v) in vols if k isa StructuralSizer.RebarSteel);
                          init = 0.0u"kg")

function _report(name, design)
    bd = detail_building(design)
    struc = design.structure
    summary_kg = Dict(
        "columns"  => sum((_volume_rebar(volumes(c)) for c in struc.columns); init = 0.0u"kg"),
        "beams"    => sum((_volume_rebar(volumes(b)) for b in struc.beams); init = 0.0u"kg"),
        "slabs"    => sum((_volume_rebar(s.volumes) for s in struc.slabs); init = 0.0u"kg"),
        "footings" => sum((_volume_rebar(f.volumes) for f in struc.foundations); init = 0.0u"kg"))
    println("\n== $name ==")
    for (kind, dict) in (("columns", bd.columns), ("beams", bd.beams),
                         ("slabs", bd.slabs), ("footings", bd.footings))
        println(rpad(kind, 10), "summary (volumes) ", lpad(_kg(summary_kg[kind]), 6), " kg")
        isempty(dict) && continue
        mass = sum(ustrip(u"kg", StructuralSizer.detail_mass(md)) for md in values(dict))
        nwarn = sum(length(md.warnings) for md in values(dict))
        println(rpad("", 10), "placed bars       ", lpad(round(Int, mass), 6), " kg  (",
                length(dict), " members, ", nwarn, " warnings)")
        by_role = Dict{Symbol, Float64}()
        for md in values(dict), g in md.groups
            by_role[g.role] = get(by_role, g.role, 0.0) +
                ustrip(u"kg", StructuralSizer.bar_set_mass(StructuralSizer.bar_set(g)))
        end
        for (role, m) in sort!(collect(by_role); by = last, rev = true)
            println(rpad("", 14), rpad(string(role), 16), lpad(round(Int, m), 6), " kg")
        end
        seen = Set{String}()
        for md in values(dict), w in md.warnings
            key = replace(w, r"\d+(\.\d+)?" => "#")
            key in seen && continue
            push!(seen, key)
            println("    ! ", w)
        end
    end
    for (k, e) in bd.errors
        println("    ERROR ", k, ": ", e)
    end
    println("placed bars: ", round(Int, ustrip(u"kg", building_detail_mass(bd))), " kg; ",
            "summary rebar (volumes): ", round(Int, ustrip(u"kg", design.summary.rebar_weight)), " kg")
    return bd
end

function _save(name, design, bd)
    mkpath(OUT)
    build_analysis_model!(design)
    scene = build_scene(design)
    path = joinpath(OUT, "$(name).mgscene")
    write_scene(path, scene)
    sample = Dict{String, Any}()
    for (kind, dict) in (("column", bd.columns), ("beam", bd.beams),
                         ("slab", bd.slabs), ("footing", bd.footings))
        isempty(dict) && continue
        sample[kind] = _detail_record(dict[first(sort!(collect(keys(dict))))])
    end
    open(joinpath(OUT, "$(name)_detail_sample.json"), "w") do io
        JSON3.pretty(io, sample)
    end
    println("wrote ", path)
end

flat = design_building(BuildingStructure(gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 2)),
                       _params("detailing_flat_plate"; floor = FlatPlateOptions(method = DDM()));
                       restore = false)
_save("detailing_flat_plate", flat, _report("flat plate", flat))

beams = try
    design_building(BuildingStructure(gen_medium_office(54.0u"ft", 42.0u"ft", 12.0u"ft", 3, 3, 2)),
                    _params("detailing_beams"; floor = OneWayOptions(),
                            beams = ConcreteBeamOptions(), columns = ConcreteColumnOptions());
                    restore = false)
catch err
    println("\nRC beam building did not design: ", sprint(showerror, err))
    nothing
end
beams === nothing || _save("detailing_beams", beams, _report("RC beams", beams))
