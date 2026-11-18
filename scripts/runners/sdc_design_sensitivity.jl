#=
One beam-supported shear-wall office, redesigned as the load, the span, the
height, the concrete, and the seismic category change.

Live load goes in through `GravityLoads`, which is what `prepare!` writes onto
the bays. Category B is run at SDS = 0.20 and category D at SDS = 1.0.

    SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer \
        scripts/runners/sdc_design_sensitivity.jl
=#

using Dates
using Printf
using Asap
using Unitful
using Meshes
using StructuralSizer
using StructuralSynthesizer

const OUT = joinpath(@__DIR__, "..", "..", "logs", "sdc_design_sensitivity.txt")

function say(io, msg)
    println(msg)
    println(io, msg)
    flush(io)
end

function _xy(skel, vidx)
    c = Meshes.coords(skel.vertices[vidx])
    return (ustrip(u"m", c.x), ustrip(u"m", c.y))
end

function _horizontal(skel, eidx)
    v1, v2 = skel.edge_indices[eidx]
    c1, c2 = Meshes.coords(skel.vertices[v1]), Meshes.coords(skel.vertices[v2])
    return abs(ustrip(u"m", c1.z) - ustrip(u"m", c2.z)) <= 1e-6
end

function _same_plan(skel, eidx, x1, y1, x2, y2)
    v1, v2 = skel.edge_indices[eidx]
    ax, ay = _xy(skel, v1)
    bx, by = _xy(skel, v2)
    return (hypot(ax - x1, ay - y1) <= 1e-6 && hypot(bx - x2, by - y2) <= 1e-6) ||
           (hypot(ax - x2, ay - y2) <= 1e-6 && hypot(bx - x1, by - y1) <= 1e-6)
end

function _claim_wall!(skel, beams, story, x1, y1, x2, y2)
    edges = [e for e in skel.stories[story].edges
             if e in beams && _horizontal(skel, e) && _same_plan(skel, e, x1, y1, x2, y2)]
    length(edges) == 1 || error("story $story has $(length(edges)) edges on the wall line")
    eidx = only(edges)
    filter!(!=(eidx), skel.groups_edges[:beams])
    delete!(beams, eidx)
    walls = get!(skel.groups_edges, :walls, Int[])
    eidx in walls || push!(walls, eidx)
    return eidx
end

"Grade bays. Story 0 has no beam grid, and a ground-story wall needs a floor face."
function _grade_grid!(skel, bay)
    b = ustrip(u"m", bay)
    function at(i, j)
        x, y = i * b, j * b
        hits = Int[]
        for (k, v) in enumerate(skel.vertices)
            c = Meshes.coords(v)
            hypot(ustrip(u"m", c.x) - x, ustrip(u"m", c.y) - y) <= 1e-6 &&
                abs(ustrip(u"m", c.z)) <= 1e-6 && push!(hits, k)
        end
        length(hits) == 1 || error("grade point ($x, $y) has $(length(hits)) vertices")
        return only(hits)
    end
    for j in 0:2, i in 0:1
        add_element!(skel, at(i, j), at(i + 1, j); group=:beams, level_idx=0)
    end
    for i in 0:2, j in 0:1
        add_element!(skel, at(i, j), at(i, j + 1); group=:beams, level_idx=0)
    end
    for j in 0:1, i in 0:1
        cycle = [at(i, j), at(i + 1, j), at(i + 1, j + 1), at(i, j + 1)]
        StructuralSynthesizer.add_face!(skel, Meshes.Ngon(skel.vertices[cycle]...);
                                        group=:grade, level_idx=0, v_indices=cycle)
    end
    return skel
end

"Two bays each way. One pier on each side, ends not shared."
function _piers(bay)
    b = ustrip(u"m", bay)
    return ((0.0, 0.0, b, 0.0),
            (b, 2b, 2b, 2b),
            (2b, 0.0, 2b, b),
            (0.0, b, 0.0, 2b))
end

"""
Park the column stack at each pier end.

The eight ends are distinct. Every story of each stack leaves `:columns`
for `:absent`. The center column is not on a pier and stays.
"""
function _park_pier_columns!(skel, bay, n)
    ends = NTuple{2, Float64}[]
    for (x1, y1, x2, y2) in _piers(bay)
        push!(ends, (x1, y1), (x2, y2))
    end
    park = Int[]
    keep = Int[]
    for eidx in get(skel.groups_edges, :columns, Int[])
        v1, v2 = skel.edge_indices[eidx]
        c1 = Meshes.coords(skel.vertices[v1])
        c2 = Meshes.coords(skel.vertices[v2])
        x1, y1 = ustrip(u"m", c1.x), ustrip(u"m", c1.y)
        x2, y2 = ustrip(u"m", c2.x), ustrip(u"m", c2.y)
        on_end = hypot(x1 - x2, y1 - y2) <= 1e-6 &&
            any(p -> hypot(x1 - p[1], y1 - p[2]) <= 1e-3, ends)
        on_end ? push!(park, eidx) : push!(keep, eidx)
    end
    length(park) == 8 * n ||
        error("piers: parking $(length(park)) end columns, expected $(8 * n)")
    skel.groups_edges[:columns] = keep
    absent = get!(skel.groups_edges, :absent, Int[])
    for eidx in park
        eidx in absent || push!(absent, eidx)
    end
    return skel
end

function office(; n::Int, bay=9.0u"m", story=4.0u"m", fc=4000.0u"psi")
    side = 2 * bay
    skel = gen_medium_office(side, side, story, 2, 2, n)
    _grade_grid!(skel, bay)
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    for (x1, y1, x2, y2) in _piers(bay)
        for story_i in 0:(n - 1)
            _claim_wall!(skel, beams, story_i, x1, y1, x2, y2)
        end
    end
    # A column whose plan point is a pier end is inside the wall. The wall is
    # the support there. The edges stay in :absent so they can be restored.
    _park_pier_columns!(skel, bay, n)
    conc = fc == 3000.0u"psi" ? NWC_3000 : NWC_4000
    struc = BuildingStructure(skel)
    for wall in struc.walls
        wall.concrete = conc
    end
    return struc, conc
end

function wall_inputs(; n, sdc, sds, sd1, s1, material)
    return OrdinaryWallInputs(;
        directions=((1.0, 0.0), (0.0, 1.0)),
        qz=fill(1.0, n), qh=2.0, Kd=1.0, G=0.85, GCpi=0.18, roof=:Lr,
        method=:sds, SDS=sds, S1=s1, Ie=1.0, T=0.4, β=1.0, SD1=sd1, TL=8.0,
        rho=1.0, sdc=sdc, risk_category=:II, drift_system=:other, boundary=:pinned,
        material=material, model_uses_cracked_section_stiffness=true,
        sustained_lateral_loads=false, sustained_lateral_divisor_applied=false,
        type1_horizontal_irregularity=false, type5_horizontal_irregularity=false,
        orthogonal_combination=false, orthogonal_12_5_4_conditions_absent=false,
        ax_applied_to_accidental_torsion=false, pdelta_included_in_member_forces=false)
end

function design_params(name, conc, n, sdc, row, sds, sd1, s1, live)
    mat = ReinforcedConcreteMaterial(conc, Rebar_60)
    return DesignParameters(;
        name=name,
        loads=GravityLoads(floor_LL=live),
        floor=OneWayOptions(material=mat),
        materials=MaterialOptions(concrete=conc, rebar=Rebar_60),
        beams=ConcreteBeamOptions(material=conc, rebar_material=Rebar_60),
        columns=ConcreteColumnOptions(material=conc, rebar_material=Rebar_60),
        wall_thickness=0.25u"m",
        diaphragm_mode=:rigid,
        max_iterations=8,
        skip_visualization=true,
        jump_wall_thickness=true,
        lateral=LateralDesign(; system=WallsSeismicSystem(row), assignment=BuildingUnit()),
        wall_inputs=wall_inputs(; n=n, sdc=sdc, sds=sds, sd1=sd1, s1=s1, material=mat))
end

inch(x) = ustrip(u"inch", x)
kip(x) = ustrip(u"kip", x)
_maxof(xs, f, default) = isempty(xs) ? default : maximum(f, xs)

function measure(design)
    cols = collect(values(design.columns))
    beams = [b for b in values(design.beams)
             if b.section_obj !== nothing && hasproperty(b.section_obj, :h)]
    slabs = collect(values(design.slabs))
    best = isempty(cols) ? nothing : argmax(c -> ustrip(u"m^2", c.Ag), cols)
    col = best === nothing ? "none" :
          @sprintf("%.0f×%.0f", inch(best.section_obj.b), inch(best.section_obj.h))
    rho = best === nothing ? 0.0 : best.rho_g
    beam_h = _maxof(beams, b -> inch(b.section_obj.h), 0.0)
    beam_v = _maxof(beams, b -> kip(b.Vu), 0.0)
    slab_t = _maxof(slabs, s -> inch(s.thickness), 0.0)
    punch = _maxof(slabs, s -> s.punching_max_ratio, 0.0)
    for c in cols
        c.punching === nothing && continue
        punch = max(punch, c.punching.ratio)
    end
    records = collect(Iterators.flatten(values(design.walls)))
    shears = [r.demand for r in records if r.check == "story_shear"]
    vbase = isempty(shears) ? 0.0 : maximum(shears) / 4448.2216152605
    rhos = [w.ρl for w in design.structure.walls]
    wall_rho = isempty(rhos) ? 0.0 : maximum(rhos)
    wall_t = _maxof(design.structure.walls, w -> inch(w.thickness), 0.0)
    drifts = [d.drift_m / d.allowable_m for d in design.seismic_story_drift
              if d.allowable_m > 0]
    drift = isempty(drifts) ? 0.0 : maximum(drifts)
    lives = [ustrip(u"psf", c.live_load) for c in design.structure.cells
             if c.floor_type !== :grade]
    ll = isempty(lives) ? 0.0 : maximum(lives)
    wall_result = design.structure.ordinary_wall_result
    induced = wall_result === nothing ? GravityInducedCheck[] : wall_result.induced
    n_within = count(c -> c.calculated && !c.exceeds, induced)
    n_over = count(c -> c.calculated && c.exceeds, induced)
    n_miss = count(c -> !c.calculated, induced)
    notes = String[]
    detail_err = ""
    try
        built = detail_building(design)
        for md in Iterators.flatten((values(built.columns), values(built.beams), values(built.walls)))
            append!(notes, md.notes)
            append!(notes, md.warnings)
            for g in md.groups
                push!(notes, g.note)
            end
        end
        if !isempty(built.errors)
            shown = join((string(k, ": ", first(split(v, '\n')))
                          for (k, v) in built.errors), " | ")
            detail_err = " detail-errors $(length(built.errors)) [$shown]"
        end
    catch err
        detail_err = " detail FAILED: " * sprint(showerror, err)
    end
    return (
        ll = ll, col = col, rho = rho, beam_h = beam_h, beam_v = beam_v,
        slab = slab_t, punch = punch, vbase = vbase, drift = drift,
        wall_t = wall_t, wall_rho = wall_rho,
        n76 = count(s -> occursin("18.7.6", s), notes),
        n65 = count(s -> occursin("18.6.5", s), notes),
        n32 = count(s -> occursin("18.14.3.2", s), notes),
        n33 = count(s -> occursin("18.14.3.3", s), notes),
        nhoop = count(s -> occursin("boundary hoops", s), notes),
        n_within = n_within, n_over = n_over, n_miss = n_miss,
        crit = design.summary.critical_element,
        ratio = design.summary.critical_ratio,
        ok = design.summary.all_checks_pass,
        rebar = ustrip(u"kg", design.summary.rebar_weight),
        err = detail_err,
    )
end

function line_of(m)
    return @sprintf("LL %.0f  col %s ρ %.4f  beam h %.1f Vu %.0f kip  slab %.1f in punch %.2f  V %.0f kip  drift %.2f  wall t %.1f ρl %.4f  §18.7.6×%d §18.6.5×%d hoops×%d  δDE within %d over %d unchecked %d  %s %.2f  %s%s",
                    m.ll, m.col, m.rho, m.beam_h, m.beam_v, m.slab, m.punch,
                    m.vbase, m.drift, m.wall_t, m.wall_rho, m.n76, m.n65, m.nhoop,
                    m.n_within, m.n_over, m.n_miss,
                    m.crit, m.ratio, m.ok ? "ok" : "NOT OK", m.err)
end

"True when `b` is larger than `a` on at least one of the named fields."
grew(a, b, fields) = any(f -> getfield(b, f) > getfield(a, f) + 1e-6, fields)

function main()
out_path = isempty(get(ENV, "SDC_CASE", "")) ? OUT :
           joinpath(@__DIR__, "..", "..", "logs", "sdc_design_sensitivity_one.txt")
open(out_path, "w") do io
    say(io, "sensitivity $(Dates.now())")
    tall = BuildingStructure(gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 1, 20))
    err = try
        design_ordinary_walls!(tall, design_params("tall", NWC_4000, 20, :D, :A1,
                                                   1.0, 0.60, 0.40, 80.0u"psf"))
        nothing
    catch e
        e
    end
    msg = err === nothing ? "NO THROW" : sprint(showerror, err)
    say(io, "height 20 stories in D: $(err isa ArgumentError && occursin("160", msg) ? "STOPPED at 160 ft" : "UNEXPECTED: " * msg)")

    # Category B at SDS 0.20. Category D at SDS 1.0. Live load is the parameter.
    mild = (sdc=:B, row=:A3, sds=0.20, sd1=0.08, s1=0.05)
    hard = (sdc=:D, row=:A1, sds=1.00, sd1=0.60, s1=0.40)
    cases = [
        (id="base", n=5, bay=9.0u"m", story=4.0u"m", live=80.0u"psf", fc=4000.0u"psi", mild...),
        (id="live 160", n=5, bay=9.0u"m", story=4.0u"m", live=160.0u"psf", fc=4000.0u"psi", mild...),
        (id="bay 12 m", n=5, bay=12.0u"m", story=4.0u"m", live=80.0u"psf", fc=4000.0u"psi", mild...),
        (id="6 stories", n=6, bay=9.0u"m", story=4.0u"m", live=80.0u"psf", fc=4000.0u"psi", mild...),
        (id="story 6 m", n=5, bay=9.0u"m", story=6.0u"m", live=80.0u"psf", fc=4000.0u"psi", mild...),
        (id="f′c 3000", n=5, bay=9.0u"m", story=4.0u"m", live=80.0u"psf", fc=3000.0u"psi", mild...),
        (id="D / A1", n=5, bay=9.0u"m", story=4.0u"m", live=80.0u"psf", fc=4000.0u"psi", hard...),
        (id="B / A1", n=5, bay=9.0u"m", story=4.0u"m", live=80.0u"psf", fc=4000.0u"psi",
         sdc=:B, row=:A1, sds=0.20, sd1=0.08, s1=0.05),
    ]
    only = get(ENV, "SDC_CASE", "")
    results = Dict{String, Any}()
    for case in cases
        !isempty(only) && case.id != only && continue
        t0 = time()
        got = try
            n_env = get(ENV, "SDC_STORIES", "")
            n = isempty(n_env) ? case.n : parse(Int, n_env)
            struc, conc = office(; n=n, bay=case.bay, story=case.story, fc=case.fc)
            design = design_building(struc, design_params(case.id, conc, n, case.sdc,
                                                          case.row, case.sds, case.sd1, case.s1,
                                                          case.live))
            scene_path = get(ENV, "SDC_SCENE", "")
            if !isempty(scene_path)
                mkpath(dirname(scene_path))
                export_scene(scene_path, design)
                @info "wrote scene" path = abspath(scene_path)
            end
            measure(design)
        catch e
            io = IOBuffer()
            showerror(io, e, catch_backtrace())
            ErrorException(String(take!(io)))
        end
        results[case.id] = got
        text = got isa Exception ? "FAILED: " * sprint(showerror, got) : line_of(got)
        say(io, @sprintf("%-12s %6.0fs  %s", case.id, time() - t0, text))
    end

    isempty(only) || return
    say(io, "---- what changed ----")
    function verdict(a, b, label, ok)
        say(io, (ok ? "moves    " : "NO MOVE  ") * label)
    end
    base, heavy = results["base"], results["live 160"]
    wide, tall6 = results["bay 12 m"], results["6 stories"]
    high, weak = results["story 6 m"], results["f′c 3000"]
    dee, bee = results["D / A1"], results["B / A1"]
    if any(x -> x isa Exception, (base, heavy, wide, tall6, high, weak, dee, bee))
        say(io, "a case failed, so the comparisons stop")
    else
        verdict("base", "live 160", "doubled live load",
                heavy.ll > 100 && grew(base, heavy, (:beam_h, :beam_v, :slab, :rebar, :punch)))
        verdict("base", "bay 12 m", "a longer bay",
                grew(base, wide, (:beam_h, :slab, :rebar)))
        verdict("base", "6 stories", "a sixth story",
                grew(base, tall6, (:vbase, :rebar, :drift)))
        verdict("base", "story 6 m", "a taller story",
                grew(base, high, (:drift, :rebar, :vbase)))
        verdict("base", "f′c 3000", "weaker concrete",
                grew(base, weak, (:beam_h, :slab, :rebar, :punch)) || weak.col != base.col)
        verdict("base", "D / A1", "category D at SDS 1.0 against B at SDS 0.20",
                grew(base, dee, (:vbase, :drift, :wall_rho, :wall_t)) && dee.n76 > 0 && base.n76 == 0)
        verdict("D / A1", "B / A1", "the same special row in B does not take the D–F bars",
                dee.n76 > 0 && bee.n76 == 0 && dee.n65 >= bee.n65)
    end
end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
