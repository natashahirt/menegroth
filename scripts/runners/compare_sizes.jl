#=
Size every element of a few reference buildings and write the result, so a
sizing change can be compared against the commit before it.

    julia --project=StructuralSynthesizer scripts/runners/compare_sizes.jl LABEL [CASE ...]
    julia --project=StructuralSynthesizer scripts/runners/compare_sizes.jl --diff BASE NEW

LABEL names the output folder `logs/compare_sizes/LABEL/`, one CSV per case
(kind, id, size, ok, ratio) plus `totals.csv` (embodied carbon by element and
concrete, rebar, and steel quantities). CASE limits the run to the named cases;
by default all of them run. `--diff` prints every element whose size or pass
state changed between two labels, and the change in each total.
=#

ENV["SS_ENABLE_VISUALIZATION"] = "false"
ENV["SS_SKIP_SOLVER_WARMUP"] = get(ENV, "SS_SKIP_SOLVER_WARMUP", "true")

using StructuralSynthesizer
using StructuralSizer
using Asap
using Unitful
using Printf

include(joinpath(@__DIR__, "core_office_geometry.jl"))

const OUT_ROOT = joinpath(@__DIR__, "..", "..", "logs", "compare_sizes")

_spread() = FoundationParameters(soil = medium_sand,
                                 options = FoundationOptions(strategy = :all_spread))

"""
Reference buildings, by name. Each returns `(structure, params)`.

- `flat_plate`: 3×3 bays of 24 ft, two stories, DDM flat plate, RC columns.
- `rc_beams`: the same grid with a one-way slab on RC beams.
- `steel_beams`: the same grid with a one-way slab on steel beams.
- `core_office`: 3×3 bays of 8 m, four stories, concrete core walls, FEA strip
  flat plate (slowest case).
- `two_way`: the office grid with a two-way slab on reinforced-concrete beams.
- `core_mat`: the core office on one mat.
"""
const CASES = Dict{String, Function}(
    "flat_plate" => () -> (
        BuildingStructure(gen_medium_office(72.0u"ft", 72.0u"ft", 12.0u"ft", 3, 3, 2)),
        DesignParameters(
            name = "flat_plate",
            floor = FlatPlateOptions(method = DDM()),
            materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
            columns = ConcreteColumnOptions(material = NWC_4000, rebar_material = Rebar_60),
            foundation_options = _spread(),
            skip_visualization = true)),
    "rc_beams" => () -> (
        BuildingStructure(gen_medium_office(72.0u"ft", 72.0u"ft", 12.0u"ft", 3, 3, 2)),
        DesignParameters(
            name = "rc_beams",
            floor = OneWayOptions(),
            materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
            columns = ConcreteColumnOptions(material = NWC_4000, rebar_material = Rebar_60),
            beams = ConcreteBeamOptions(material = NWC_4000, rebar_material = Rebar_60),
            foundation_options = _spread(),
            skip_visualization = true)),
    "steel_beams" => () -> (
        BuildingStructure(gen_medium_office(72.0u"ft", 72.0u"ft", 12.0u"ft", 3, 3, 2)),
        DesignParameters(
            name = "steel_beams",
            floor = OneWayOptions(),
            materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60,
                                        steel = A992_Steel),
            foundation_options = _spread(),
            skip_visualization = true)),
    "core_office" => () -> (
        BuildingStructure(core_office_skeleton()),
        DesignParameters(
            name = "core_office",
            floor = FlatPlateOptions(method = FEA(design_approach = :strip)),
            materials = MaterialOptions(concrete = RC_4000_60.concrete, rebar = Rebar_60),
            columns = ConcreteColumnOptions(material = RC_4000_60.concrete,
                                            rebar_material = Rebar_60),
            wall_thickness = 0.3u"m",
            diaphragm_mode = :rigid,
            foundation_options = _spread(),
            skip_visualization = true)),
    "two_way" => () -> (
        BuildingStructure(gen_medium_office(72.0u"ft", 72.0u"ft", 12.0u"ft", 3, 3, 2)),
        DesignParameters(
            name = "two_way",
            floor = TwoWayOptions(),
            materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
            columns = ConcreteColumnOptions(material = NWC_4000, rebar_material = Rebar_60),
            beams = ConcreteBeamOptions(material = NWC_4000, rebar_material = Rebar_60),
            foundation_options = _spread(),
            skip_visualization = true)),
    "core_mat" => () -> (
        BuildingStructure(core_office_skeleton()),
        DesignParameters(
            name = "core_mat",
            floor = FlatPlateOptions(method = FEA(design_approach = :strip)),
            materials = MaterialOptions(concrete = RC_4000_60.concrete, rebar = Rebar_60),
            columns = ConcreteColumnOptions(material = RC_4000_60.concrete,
                                            rebar_material = Rebar_60),
            wall_thickness = 0.3u"m",
            diaphragm_mode = :rigid,
            foundation_options = FoundationParameters(
                soil = medium_sand,
                options = FoundationOptions(strategy = :mat)),
            skip_visualization = true)),
)

_in(x) = @sprintf("%.2f", ustrip(u"inch", x))

"""
    element_rows(design) -> Vector{NTuple{5, String}}

One `(kind, id, size, ok, ratio)` row per designed slab, column, beam, wall,
and foundation, sorted by kind then id.
"""
function element_rows(design)
    rows = NTuple{5, String}[]
    for (i, s) in design.slabs
        push!(rows, ("slab", string(i), "h=" * _in(s.thickness),
                     string(s.converged && s.deflection_ok && s.punching_ok),
                     @sprintf("%.3f", max(s.deflection_ratio, s.punching_max_ratio))))
    end
    for (i, c) in design.columns
        push!(rows, ("column", string(i), c.section_size, string(c.ok),
                     @sprintf("%.3f", max(c.axial_ratio, c.interaction_ratio))))
    end
    for (i, b) in design.beams
        push!(rows, ("beam", string(i), b.section_size, string(b.ok),
                     @sprintf("%.3f", max(b.flexure_ratio, b.shear_ratio))))
    end
    for (i, w) in enumerate(design.structure.walls)
        checks = get(design.walls, i, nothing)
        ok = checks === nothing ? "" : string(all(r -> r.passed, checks))
        push!(rows, ("wall", string(i), "t=" * _in(w.thickness), ok, ""))
    end
    for (i, f) in design.foundations
        push!(rows, ("foundation", string(i),
                     join((_in(f.length), _in(f.width), _in(f.depth)), "x"),
                     string(f.ok),
                     @sprintf("%.3f", max(f.bearing_ratio, f.punching_ratio,
                                          f.flexure_ratio))))
    end
    return sort!(rows; by = r -> (r[1], parse(Int, r[2])))
end

"""
    totals(design) -> Vector{Pair{String, Float64}}

Embodied carbon (kgCO2e) by element, and concrete (m³), rebar (kg), and
structural steel (kg) quantities, from the design summary.
"""
function totals(design)
    s = design.summary
    kg(x) = ustrip(Asap.kgCO2e, x)
    return [
        "carbon_total" => kg(s.embodied_carbon),
        "carbon_slabs" => kg(s.embodied_carbon_slabs),
        "carbon_columns" => kg(s.embodied_carbon_columns),
        "carbon_beams" => kg(s.embodied_carbon_beams),
        "carbon_foundations" => kg(s.embodied_carbon_foundations),
        "concrete_m3" => ustrip(u"m^3", s.concrete_volume),
        "rebar_kg" => ustrip(u"kg", s.rebar_weight),
        "steel_kg" => ustrip(u"kg", s.steel_weight),
    ]
end

_write_csv(path, header, rows) = open(path, "w") do io
    println(io, join(header, ","))
    for r in rows
        println(io, join(r, ","))
    end
end

function _read_csv(path)
    lines = readlines(path)
    return [split(l, ","; keepempty = true) for l in lines[2:end]]
end

"""Write the design as a viewer scene next to the CSV and under viewer/public."""
function _write_case_scene(design, dir, name)
    try
        packet = build_scene(design)
        path = joinpath(dir, name * ".mgscene")
        write_scene(path, packet)
        pub = joinpath(@__DIR__, "..", "..", "viewer", "public")
        mkpath(pub)
        write_scene(joinpath(pub, name * ".mgscene"), packet)
        names = sort!(filter(f -> endswith(f, ".mgscene"), readdir(pub)))
        open(joinpath(pub, "scenes.json"), "w") do io
            print(io, "[")
            for (i, scene_name) in enumerate(names)
                i > 1 && print(io, ",")
                print(io, "\"", scene_name, "\"")
            end
            println(io, "]")
        end
        @printf("   scene %s (%.0f KiB)\n", abspath(path), filesize(path) / 1024)
    catch err
        println("   SCENE FAILED: ", sprint(showerror, err))
        for fr in stacktrace(catch_backtrace())[1:min(8, end)]
            println("      ", fr)
        end
    end
end

function run_cases(label, names)
    dir = mkpath(joinpath(OUT_ROOT, label))
    total_rows = NTuple{3, String}[]
    for name in names
        haskey(CASES, name) || error("unknown case $name; known: $(join(sort!(collect(keys(CASES))), ", "))")
        println("── ", name)
        flush(stdout)
        struc, params = CASES[name]()
        t = @elapsed design = try
            design_building(struc, params; restore = false)
        catch err
            println("   FAILED: ", sprint(showerror, err))
            bt = stacktrace(catch_backtrace())
            for fr in bt[1:min(12, end)]
                println("      ", fr)
            end
            push!(total_rows, (name, "error", "1"))
            continue
        end
        rows = element_rows(design)
        _write_csv(joinpath(dir, name * ".csv"), ("kind", "id", "size", "ok", "ratio"), rows)
        for (k, v) in totals(design)
            push!(total_rows, (name, k, @sprintf("%.3f", v)))
        end
        nfail = count(r -> r[4] == "false", rows)
        @printf("   %d elements, %d failing, %.1f s\n", length(rows), nfail, t)
        _write_case_scene(design, dir, name)
    end
    _write_csv(joinpath(dir, "totals.csv"), ("case", "quantity", "value"), total_rows)
    println("wrote ", abspath(dir))
end

function diff_labels(base, new)
    bdir, ndir = joinpath(OUT_ROOT, base), joinpath(OUT_ROOT, new)
    for file in sort!(filter(f -> endswith(f, ".csv") && f != "totals.csv", readdir(ndir)))
        isfile(joinpath(bdir, file)) || continue
        old = Dict((r[1], r[2]) => r for r in _read_csv(joinpath(bdir, file)))
        changed = 0
        println("── ", replace(file, ".csv" => ""))
        for r in _read_csv(joinpath(ndir, file))
            o = get(old, (r[1], r[2]), nothing)
            o === nothing && (println("   new  ", join(r, " ")); changed += 1; continue)
            (o[3] == r[3] && o[4] == r[4]) && continue
            @printf("   %-10s %-4s %s (ok=%s) -> %s (ok=%s)\n", r[1], r[2], o[3], o[4], r[3], r[4])
            changed += 1
        end
        changed == 0 && println("   no size or pass changes")
    end
    old = Dict((r[1], r[2]) => r[3] for r in _read_csv(joinpath(bdir, "totals.csv")))
    println("── totals (base -> new)")
    for r in _read_csv(joinpath(ndir, "totals.csv"))
        o = get(old, (r[1], r[2]), "")
        o == r[3] && continue
        a, b = tryparse(Float64, o), tryparse(Float64, r[3])
        pct = (a === nothing || b === nothing || a == 0) ? "" :
              @sprintf("  (%+.1f%%)", 100 * (b - a) / a)
        @printf("   %-12s %-20s %s -> %s%s\n", r[1], r[2], o, r[3], pct)
    end
end

if length(ARGS) == 3 && ARGS[1] == "--diff"
    diff_labels(ARGS[2], ARGS[3])
elseif !isempty(ARGS)
    run_cases(ARGS[1], length(ARGS) > 1 ? ARGS[2:end] : sort!(collect(keys(CASES))))
else
    println("usage: compare_sizes.jl LABEL [CASE ...] | --diff BASE NEW")
end
