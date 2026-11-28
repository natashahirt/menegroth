# Diagnostic: why captured RC beam results carry Vu ≈ 0. Designs the RC beam
# preview building, then inspects the captured Asap model's beam elements.
#
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer scripts/runners/diag_beam_capture_forces.jl

using StructuralSynthesizer
using StructuralSynthesizer: Asap, segment_indices
using Unitful

params = DesignParameters(; name = "diag", max_iterations = 5, skip_visualization = true,
    geometry_is_centerline = false,
    materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
    foundation_options = FoundationParameters(soil = medium_sand,
        options = FoundationOptions(strategy = :all_spread)),
    floor = OneWayOptions(), beams = ConcreteBeamOptions(), columns = ConcreteColumnOptions())
design = design_building(BuildingStructure(gen_medium_office(54.0u"ft", 42.0u"ft", 12.0u"ft", 3, 3, 2)),
                         params; restore = false)

struc = design.structure
model = struc.asap_model
println("\nmodel: ", typeof(model), "  frames = ", length(model.frame_elements),
        "  loads = ", length(model.loads))
println("load types: ", unique(typeof.(model.loads)))
elloads = Asap.get_elemental_loads(model)

function beam_end_forces()
    rows = Tuple{Int, Int, Float64, Float64}[]
    for (bi, beam) in enumerate(struc.beams)
        for si in segment_indices(beam)
            el = model.frame_elements[struc.segments[si].edge_idx]
            f = el.forces
            push!(rows, (bi, length(elloads[el.elementID]),
                         isempty(f) ? NaN : maximum(abs, f),
                         isempty(f) ? NaN : max(abs(f[3]), abs(f[9]), abs(f[2]), abs(f[8]))))
        end
    end
    return rows
end

rows = beam_end_forces()
println("beam segments: ", length(rows), "  with element loads: ", count(r -> r[2] > 0, rows))
println("max |end force| over beams (as captured): ", maximum(r -> r[3], rows))
println("first rows (beam, n_loads, max|f|, max shear-ish): ", rows[1:min(4, end)])
println("captured design.beams[1].Vu = ", design.beams[1].Vu, "  Mu = ", design.beams[1].Mu)

# Internal forces per beam, all four bending/shear components. Asap pairs
# My with Vy (local-y load) and Mz with Vz (local-z load).
println("\nbeam  dir      max|My| kNm  max|Vy| kN  max|Mz| kNm  max|Vz| kN   captured Vu kN")
for (bi, beam) in enumerate(struc.beams)
    My = Vy = Mz = Vz = 0.0
    dir = ""
    for si in segment_indices(beam)
        el = model.frame_elements[struc.segments[si].edge_idx]
        f = Asap.ElementForceAndDisplacement(el, elloads[el.elementID]; resolution = 20).forces
        My = max(My, maximum(abs, f.My)); Vy = max(Vy, maximum(abs, f.Vy))
        Mz = max(Mz, maximum(abs, f.Mz)); Vz = max(Vz, maximum(abs, f.Vz))
        p1, p2 = el.nodeStart.position, el.nodeEnd.position
        dir = abs(p2[1] - p1[1]) > abs(p2[2] - p1[2]) ? "X" : "Y"
    end
    (bi <= 4 || bi in (37, 38, 39, 40) || bi == length(struc.beams)) &&
        println(lpad(bi, 4), "  ", dir, "  ", lpad(round(My / 1e3; digits = 2), 12),
                lpad(round(Vy / 1e3; digits = 2), 12), lpad(round(Mz / 1e3; digits = 3), 12),
                lpad(round(Vz / 1e3; digits = 3), 12), lpad(round(ustrip(u"kN", design.beams[bi].Vu); digits = 3), 14))
end
