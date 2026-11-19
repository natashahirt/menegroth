# Row F frame resizing. A failing frame group walks its catalog to the lightest
# section that passes its row F rows, and concrete discrete sizing keeps any
# section that passes those rows. A floor with no stored rows (an overstressed
# column floored on the wall solution) keeps that section or a heavier one.

using StructuralSynthesizer
using StructuralSizer
using Test
using Unitful

const _FF = StructuralSynthesizer
const _FZ = StructuralSizer

function _floor_frame()
    struc = BuildingStructure(gen_medium_office(6.0u"m", 6.0u"m", 3.0u"m", 1, 1, 1))
    initialize!(struc)
    @assert length(struc.columns) >= 2
    for (i, c) in enumerate(struc.columns)
        c.base.group_id = i <= 2 ? UInt64(1) : UInt64(2)
    end
    return struc
end

@testset "Row F section floors" begin
    struc = _floor_frame()
    opts = ConcreteColumnOptions(material = RC_4000_60.concrete, rebar_material = Rebar_60)
    cat = _FZ.rc_column_catalog(opts.section_shape, opts.catalog)
    obj = s -> _FZ.objective_value(opts.objective, s, opts.material, 1.0u"m")
    light = cat[argmin(obj.(cat))]
    foreach(c -> c.base.section = light, struc.columns)

    member_opts = (columns = opts, beams = nothing)
    frame() = _FF._frame_checkers(RC_4000_60, member_opts)
    resists(i, s, rows) = first(_FF._member_resists(:column, struc.columns[i], s, rows, frame()))

    # kip and kip·ft, as `_member_demand_rows` builds them.
    heavy = [("E", RCColumnDemand(1; Pu = 112.0, Mux = 148.0, Muy = 0.0))]
    small = [("E", RCColumnDemand(2; Pu = 2.0, Mux = 1.0, Muy = 0.0))]
    rows = Dict((:column, i) => (i == 1 ? heavy : small) for i in eachindex(struc.columns))
    @test !resists(1, light, heavy)
    @test resists(2, light, small)

    checks = [_FF.FrameMemberCheck(:column, i, i != 1, i == 1 ? "E does not pass" : "")
              for i in eachindex(struc.columns)]

    # No concrete column options: nothing to walk, so no floor.
    out = _FF._raise_frame_floors!(checks, struc, rows, (columns = nothing, beams = nothing),
                                   frame())
    @test isempty(struc.frame_section_floors)
    @test isempty(struc.frame_floor_demands)
    @test occursin("not resized", out[1].detail)
    @test !out[1].passed

    out = _FF._raise_frame_floors!(checks, struc, rows, member_opts, frame())
    @test collect(keys(struc.frame_section_floors)) == [UInt64(1)]
    floor = struc.frame_section_floors[UInt64(1)]
    # Group 1's stored rows are the union of its two members.
    demands = struc.frame_floor_demands[UInt64(1)]
    @test length(demands) == length(heavy) + length(small)
    @test any(row -> row[2].Mux == 148.0, demands)
    @test any(row -> row[2].Mux == 1.0, demands)
    @test !haskey(struc.frame_floor_demands, UInt64(2))
    @test occursin("floor", out[1].detail)
    @test !out[1].passed
    @test out[2] == checks[2]
    # The floor passes every member of the group and is the lightest that does.
    @test resists(1, floor, heavy) && resists(2, floor, small)
    @test obj(floor) >= obj(light)
    for s in cat
        obj(light) <= obj(s) < obj(floor) * (1 - 1e-9) || continue
        @test !(resists(1, s, heavy) && resists(2, s, small))
    end

    # The sizing mask keeps, for group 1 only, exactly the sections that pass
    # the stored rows of both members. The floor is the lightest of them.
    mask = _FF._frame_floor_mask(struc, :column, [UInt64(1), UInt64(2)], cat, frame())
    @test mask[2] == collect(eachindex(cat))
    @test any(j -> _FF._sections_identical(cat[j], floor), mask[1])
    @test all(j -> obj(cat[j]) >= obj(floor) * (1 - 1e-9), mask[1])
    @test all(j -> (j in mask[1]) == (resists(1, cat[j], heavy) && resists(2, cat[j], small)),
              eachindex(cat))
    @test _FF._frame_floor_mask(struc, :column, [UInt64(3)], cat, frame()) === nothing

    # A floor left heavy by an earlier round does not keep out a lighter
    # section that passes the stored rows.
    heaviest = cat[argmax(obj.(cat))]
    struc.frame_section_floors[UInt64(1)] = heaviest
    relaxed = _FF._frame_floor_mask(struc, :column, [UInt64(1)], cat, frame())
    @test any(j -> _FF._sections_identical(cat[j], floor), relaxed[1])
    @test any(j -> obj(cat[j]) < obj(heaviest), relaxed[1])
    struc.frame_section_floors[UInt64(1)] = floor

    # The sizer honors the mask: a tiny demand picks a lighter section without it.
    geoms = [_FZ.ConcreteMemberGeometry(3.0u"m")]
    tiny = [RCColumnDemand(1; Pu = 2.0, Mux = 1.0, Muy = 0.0)]
    free = _FZ.size_columns(tiny, geoms, opts; catalog = cat)
    held = _FZ.size_columns(tiny, geoms, opts; catalog = cat, feasible = [mask[1]])
    @test obj(only(free.sections)) < obj(floor)
    @test obj(only(held.sections)) >= obj(floor) * (1 - 1e-9)

    # NLP keeps its own section when it passes the stored rows, even below the
    # floor, and falls back to the floor when it fails them or the solve
    # failed. A group with no floor is unchanged.
    struc.frame_section_floors[UInt64(1)] = heaviest
    @test _FF._sections_identical(
        _FF._nlp_section_or_floor(struc, :column, UInt64(1), light, opts), heaviest)
    @test _FF._sections_identical(
        _FF._nlp_section_or_floor(struc, :column, UInt64(1), floor, opts), floor)
    @test _FF._sections_identical(
        _FF._nlp_section_or_floor(struc, :column, UInt64(1), nothing, opts), heaviest)
    @test _FF._nlp_section_or_floor(struc, :column, UInt64(2), light, opts) === light
    struc.frame_section_floors[UInt64(1)] = floor

    # Rows accumulate: a later round with only the small row keeps the heavy
    # row stored, so the floor does not fall.
    later = Dict((:column, i) => small for i in eachindex(struc.columns))
    _FF._raise_frame_floors!(checks, struc, later, member_opts, frame())
    @test any(row -> row[2].Mux == 148.0, struc.frame_floor_demands[UInt64(1)])
    @test obj(struc.frame_section_floors[UInt64(1)]) >= obj(floor) * (1 - 1e-9)

    # A path that cannot keep the floor refuses it instead of dropping it.
    @test_throws ArgumentError _FF._refuse_frame_floors(struc, [UInt64(1)], "test sizing")
    @test _FF._refuse_frame_floors(struc, [UInt64(2)], "test sizing") === nothing

    # Floors are design state: snapshots carry the section and its demand rows.
    _FF.snapshot!(struc, :with_floor)
    empty!(struc.frame_section_floors)
    empty!(struc.frame_floor_demands)
    _FF.restore!(struc, :with_floor)
    @test _FF._sections_identical(struc.frame_section_floors[UInt64(1)], floor)
    restored = struc.frame_floor_demands[UInt64(1)]
    @test length(restored) == length(heavy) + length(small)
    @test any(row -> row[2].Mux == 148.0, restored)
end

@testset "Row F frame members are checked with their own materials" begin
    cols = ConcreteColumnOptions(material = NWC_6000, rebar_material = Rebar_75)
    beams = ConcreteBeamOptions(material = NWC_5000, rebar_material = Rebar_80)
    f = _FF._frame_checkers(RC_4000_60, (columns = cols, beams = beams))
    @test f.column.concrete === NWC_6000
    @test f.column.checker.fy_ksi ≈ 75.0
    @test !f.column.checker.include_slenderness
    @test f.beam.concrete === NWC_5000
    @test f.beam.checker.fy_ksi ≈ 80.0
    @test f.beam.checker.fyt_ksi ≈
          ustrip(u"ksi", _FZ.get_transverse_rebar(beams).Fy)

    # Without concrete member options, the wall material is used.
    w = _FF._frame_checkers(RC_4000_60, (columns = nothing, beams = nothing))
    @test w.column.concrete === RC_4000_60.concrete
    @test w.column.checker.fy_ksi ≈ ustrip(u"ksi", RC_4000_60.rebar.Fy)
    @test w.beam.checker.fyt_ksi ≈ ustrip(u"ksi", RC_4000_60.transverse.Fy)

    # A stronger column concrete raises the P-M capacity the check reads.
    struc = _floor_frame()
    sec = first(_FZ.rc_column_catalog(:rect, :standard))
    weak = _FF._frame_checkers(RC_4000_60,
        (columns = ConcreteColumnOptions(material = NWC_3000, rebar_material = Rebar_60),
         beams = nothing))
    strong = _FF._frame_checkers(RC_4000_60,
        (columns = ConcreteColumnOptions(material = NWC_6000, rebar_material = Rebar_60),
         beams = nothing))
    pass(fr, Pu) = first(_FF._member_resists(:column, struc.columns[1], sec,
        [("E", RCColumnDemand(1; Pu = Pu, Mux = 0.0, Muy = 0.0))], fr))
    # Find an axial load (kip) the 6000 psi section carries and the 3000 psi one does not.
    loads = [25.0k for k in 1:200]
    split = findfirst(P -> pass(strong, P) && !pass(weak, P), loads)
    @test split !== nothing
end

@testset "Row F reports the governing ratio on the member" begin
    struc = _floor_frame()
    opts = ConcreteColumnOptions(material = RC_4000_60.concrete, rebar_material = Rebar_60)
    light = first(_FZ.rc_column_catalog(opts.section_shape, opts.catalog))
    col = struc.columns[1]
    col.base.section = light
    frame = _FF._frame_checkers(RC_4000_60, (columns = opts, beams = nothing))
    heavy = [("1.2D + 1.0E QE", RCColumnDemand(1; Pu = 20.0, Mux = 400.0, Muy = 0.0))]
    small = [("1.2D + 1.0E QE", RCColumnDemand(1; Pu = 2.0, Mux = 1.0, Muy = 0.0))]
    rep = _FF._member_frame_report(:column, col, light, heavy, frame)
    @test !rep.passed
    @test rep.governing_ratio > 1
    @test !isempty(rep.governing_check)
    @test occursin("QE", rep.case_label)
    ok = _FF._member_frame_report(:column, col, light, small, frame)
    @test ok.passed
    @test ok.governing_ratio <= 1

    # The reported pass/fail is the checker's, for a failing row and a passing one.
    k = frame.column
    cache = _FF._cached_column_capacity!(k.cache, k.checker, light, k.concrete)
    geom = _FF._member_frame_geometry(col)
    for rows in (heavy, small)
        d = rows[1][2]
        feasible = _FZ.is_feasible(k.checker, cache, 1, light, k.concrete, d, geom)
        explained = _FZ.explain_feasibility(k.checker, cache, 1, light, k.concrete, d, geom)
        @test explained.passed == feasible
        @test _FF._member_frame_report(:column, col, light, rows, frame).passed == feasible
    end
end

@testset "Row F beam floors use the framing level's options" begin
    struc = _floor_frame()
    @assert length(struc.beams) >= 2
    for (i, b) in enumerate(struc.beams)
        b.base.group_id = i == 1 ? UInt64(1) : UInt64(2)
    end
    cat = collect(_FZ.rc_beam_catalog(:standard))
    obj = s -> _FZ.objective_value(MinVolume(), s, NWC_5000, 1.0u"m")
    order = sortperm(obj.(cat))
    light, heavy = cat[order[1]], cat[order[end]]
    own = ConcreteBeamOptions(material = NWC_5000, rebar_material = Rebar_60,
                              objective = MinVolume(), custom_catalog = [light, heavy])
    building = ConcreteBeamOptions(material = NWC_3000, rebar_material = Rebar_60,
                                   custom_catalog = [light])
    slab = first(struc.slabs)
    Level = eltype(slab.framing_levels)
    push!(slab.framing_levels, Level(
        slab_idx = 1, level = 1, pattern = IsoparametricPattern(2, 2),
        material = NWC_5000, group_id = UInt64(1), beam_options = own))
    by = _FF._beam_opts_by_group(struc, building)
    @test by[UInt64(1)] === own
    @test by[UInt64(2)] === building

    frame = _FF._frame_checkers(RC_4000_60, (columns = nothing, beams = building);
                                beam_opts_by_group = by)
    @test frame.beam_for(struc.beams[1]).concrete === NWC_5000
    @test frame.beam_for(struc.beams[2]).concrete === NWC_3000
    @test frame.beam.concrete === NWC_3000

    beam = struc.beams[1]
    beam.base.section = light
    resists(sec, Mu) = first(_FF._member_resists(
        :beam, beam, sec, [("E", RCBeamDemand(1; Mu = Mu, Vu = 1.0))], frame))
    mus = [20.0, 50.0, 100.0, 200.0, 400.0, 800.0, 1600.0]
    split = findfirst(Mu -> resists(heavy, Mu) && !resists(light, Mu), mus)
    @test split !== nothing
    Mu = mus[split]
    rows = Dict((:beam, i) => [("E", RCBeamDemand(i; Mu = i == 1 ? Mu : 1.0, Vu = 1.0))]
                for i in eachindex(struc.beams))
    checks = [_FF.FrameMemberCheck(:beam, i, i != 1, i == 1 ? "E does not pass" : "")
              for i in eachindex(struc.beams)]
    out = _FF._raise_frame_floors!(checks, struc, rows, (columns = nothing, beams = building),
                                   frame; beam_opts_by_group = by)
    @test _FF._sections_identical(struc.frame_section_floors[UInt64(1)], heavy)
    @test !haskey(struc.frame_section_floors, UInt64(2))
    @test occursin("floor", out[1].detail)
    # A floor the sizing catalog does not contain is refused, not a bare lookup error.
    other = BuildingStructure(gen_medium_office(6.0u"m", 6.0u"m", 3.0u"m", 1, 1, 1))
    other.frame_section_floors[UInt64(9)] = heavy
    err = try
        _FF._frame_floor_mask(other, :beam, [UInt64(9)], [light],
                              _FF._beam_floor_frame(building))
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("cannot keep", sprint(showerror, err))
end

@testset "Uniform column sizing floors every group in the cohort" begin
    struc = _floor_frame()
    opts = ConcreteColumnOptions(material = RC_4000_60.concrete, rebar_material = Rebar_60)
    cat = _FZ.rc_column_catalog(opts.section_shape, opts.catalog)
    obj = s -> _FZ.objective_value(opts.objective, s, opts.material, 1.0u"m")
    light = cat[argmin(obj.(cat))]
    foreach(c -> c.base.section = light, struc.columns)
    member_opts = (columns = opts, beams = nothing)
    frame = _FF._frame_checkers(RC_4000_60, member_opts)
    heavy = [("E", RCColumnDemand(1; Pu = 112.0, Mux = 148.0, Muy = 0.0))]
    small = [("E", RCColumnDemand(2; Pu = 2.0, Mux = 1.0, Muy = 0.0))]
    rows = Dict((:column, i) => (i == 1 ? heavy : small) for i in eachindex(struc.columns))
    checks = [_FF.FrameMemberCheck(:column, i, i != 1, i == 1 ? "E does not pass" : "")
              for i in eachindex(struc.columns)]
    _FF._raise_frame_floors!(checks, struc, rows, member_opts, frame; uniform_columns = :building)
    @test haskey(struc.frame_section_floors, UInt64(1))
    @test haskey(struc.frame_section_floors, UInt64(2))
    @test _FF._sections_identical(struc.frame_section_floors[UInt64(1)],
                                  struc.frame_section_floors[UInt64(2)])
    floor = struc.frame_section_floors[UInt64(1)]
    @test first(_FF._member_resists(:column, struc.columns[1], floor, heavy, frame))
end

# The floor is a function of the demand and of the uniformity mode. A harder
# moment does not produce a lighter floor. Below the balance point a lower
# axial load can be the one that needs the floor (ACI 318-19 §22.4). Story
# cohorts do not borrow a floor from another story.
@testset "Row F floors follow the demand and the uniformity mode" begin
    struc = _floor_frame()
    for (i, c) in enumerate(struc.columns)
        c.base.group_id = UInt64(i)
        c.story = i == 1 ? 0 : 1
    end
    opts = ConcreteColumnOptions(material = RC_4000_60.concrete, rebar_material = Rebar_60)
    cat = _FZ.rc_column_catalog(opts.section_shape, opts.catalog)
    obj = s -> _FZ.objective_value(opts.objective, s, opts.material, 1.0u"m")
    light = cat[argmin(obj.(cat))]
    heaviest = cat[argmax(obj.(cat))]
    foreach(c -> c.base.section = light, struc.columns)
    member_opts = (columns = opts, beams = nothing)
    frame = _FF._frame_checkers(RC_4000_60, member_opts)
    resists(sec, Pu, Mu; Muy = 0.0) = first(_FF._member_resists(
        :column, struc.columns[1], sec,
        [("E", RCColumnDemand(1; Pu = Pu, Mux = Mu, Muy = Muy))], frame))

    function raise_column(Pu, Mu; Muy = 0.0, uniform = :off, installed = light)
        empty!(struc.frame_section_floors)
        empty!(struc.frame_floor_demands)
        struc.columns[1].base.section = installed
        demand = [("E", RCColumnDemand(1; Pu = Pu, Mux = Mu, Muy = Muy))]
        tiny = [("E", RCColumnDemand(2; Pu = 2.0, Mux = 1.0, Muy = 0.0))]
        rows = Dict((:column, i) => (i == 1 ? demand : tiny) for i in eachindex(struc.columns))
        passed = resists(installed, Pu, Mu; Muy = Muy)
        checks = [_FF.FrameMemberCheck(:column, i, i == 1 ? passed : true,
                                       i == 1 && !passed ? "E does not pass" : "")
                  for i in eachindex(struc.columns)]
        out = _FF._raise_frame_floors!(checks, struc, rows, member_opts, frame;
                                       uniform_columns = uniform)
        return out
    end

    # A moment the installed section carries does not move the floor.
    out = raise_column(20.0, 5.0)
    @test resists(light, 20.0, 5.0)
    @test isempty(struc.frame_section_floors)
    @test out[1].passed

    # Past the whole catalog: still failing, and nothing is written.
    out = raise_column(20.0, 20000.0)
    @test !resists(heaviest, 20.0, 20000.0)
    @test isempty(struc.frame_section_floors)
    @test occursin("not resized", out[1].detail)
    @test !out[1].passed

    # Stepping the moment up never steps the floor down.
    moments = [40.0, 80.0, 150.0, 300.0, 600.0]
    last_obj = nothing
    saw_floor = false
    for Mu in moments
        resists(light, 50.0, Mu) && continue
        resists(heaviest, 50.0, Mu) || continue
        raise_column(50.0, Mu)
        @test haskey(struc.frame_section_floors, UInt64(1))
        fl = struc.frame_section_floors[UInt64(1)]
        @test resists(fl, 50.0, Mu)
        last_obj === nothing || @test obj(fl) >= last_obj
        last_obj = obj(fl)
        saw_floor = true
    end
    @test saw_floor

    # Below balance, the low-axial case can be the one that fails. The light
    # section is not always the one that shows it; search the catalog.
    split = nothing
    for (k, sec) in enumerate(cat)
        k % 12 == 1 || continue
        for Pu_hi in (200.0, 600.0), Mu in (40.0, 100.0, 180.0), Pu_lo in (0.0, 20.0)
            resists(sec, Pu_hi, Mu) || continue
            resists(sec, Pu_lo, Mu) && continue
            resists(heaviest, Pu_lo, Mu) || continue
            split = (sec, Pu_hi, Pu_lo, Mu)
            break
        end
        split === nothing || break
    end
    @test split !== nothing
    if split !== nothing
    sec, Pu_hi, Pu_lo, Mu = split
    out_hi = raise_column(Pu_hi, Mu; installed = sec)
    @test out_hi[1].passed
    @test !haskey(struc.frame_section_floors, UInt64(1))
    out_lo = raise_column(Pu_lo, Mu; installed = sec)
    @test !out_lo[1].passed
    @test haskey(struc.frame_section_floors, UInt64(1))
    lo_floor = struc.frame_section_floors[UInt64(1)]
    @test resists(lo_floor, Pu_lo, Mu)
    # The floor is the lightest passing section, which can sit below the
    # installed one.
    @test !any(s -> obj(s) < obj(lo_floor) * (1 - 1e-9) && resists(s, Pu_lo, Mu), cat)

    # The orthogonal moment is not easier than the uniaxial case.
    if !resists(sec, Pu_lo, Mu; Muy = Mu) && resists(heaviest, Pu_lo, Mu; Muy = Mu)
        uni = struc.frame_section_floors[UInt64(1)]
        raise_column(Pu_lo, Mu; Muy = Mu, installed = sec)
        biax = struc.frame_section_floors[UInt64(1)]
        @test obj(biax) >= obj(uni)
        @test resists(biax, Pu_lo, Mu; Muy = Mu)
    end

    # :per_story floors the failing story's group. :building floors every group.
    for c in struc.columns
        c.base.section = light
    end
    for (i, c) in enumerate(struc.columns)
        c.base.group_id = i == 1 ? UInt64(1) : UInt64(2)
        c.story = i == 1 ? 0 : 1
    end
    raise_column(Pu_lo, Mu; uniform = :per_story, installed = sec)
    @test haskey(struc.frame_section_floors, UInt64(1))
    @test !haskey(struc.frame_section_floors, UInt64(2))
    story_floor = struc.frame_section_floors[UInt64(1)]
    raise_column(Pu_lo, Mu; uniform = :building, installed = sec)
    @test haskey(struc.frame_section_floors, UInt64(1))
    @test haskey(struc.frame_section_floors, UInt64(2))
    @test _FF._sections_identical(struc.frame_section_floors[UInt64(1)], story_floor)
    @test _FF._sections_identical(struc.frame_section_floors[UInt64(2)], story_floor)
    end
end

@testset "An unsolved frame does not floor its columns" begin
    struc = _floor_frame()
    concrete = DesignParameters(columns = ConcreteColumnOptions(
        material = RC_4000_60.concrete, rebar_material = Rebar_60))
    @test !_FF._floor_overstressed_frame_columns!(struc, concrete)
    @test isempty(struc.frame_section_floors)
    steel = DesignParameters(columns = SteelColumnOptions())
    @test !_FF._floor_overstressed_frame_columns!(struc, steel)
end

@testset "A floor with no stored rows keeps the floor or heavier" begin
    struc = _floor_frame()
    opts = ConcreteColumnOptions(material = RC_4000_60.concrete, rebar_material = Rebar_60)
    cat = _FZ.rc_column_catalog(opts.section_shape, opts.catalog)
    obj = s -> _FZ.objective_value(opts.objective, s, opts.material, 1.0u"m")
    frame = (column = _FF._column_checker_bundle(nothing, opts),)
    order = sortperm(obj.(cat))
    mid = cat[order[cld(length(order), 2)]]
    struc.frame_section_floors[UInt64(1)] = mid
    @test isempty(struc.frame_floor_demands)

    mask = _FF._frame_floor_mask(struc, :column, [UInt64(1), UInt64(2)], cat, frame;
                                 objective_of = obj)
    @test mask[2] == collect(eachindex(cat))
    @test any(j -> _FF._sections_identical(cat[j], mid), mask[1])
    @test all(j -> _FF._sections_identical(cat[j], mid) || obj(cat[j]) > obj(mid), mask[1])
    @test mask[1] == _FF._frame_floor_mask(struc, [UInt64(1)], cat, obj)[1]

    err = try
        _FF._frame_floor_mask(struc, :column, [UInt64(1)], cat, frame)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("cannot keep", sprint(showerror, err))
end

@testset "Frame station loads stay on their element" begin
    a = (elementID = 1,)
    b = (elementID = 2,)
    loads = [(element = a, tag = :on_a), (element = b, tag = :on_b), (shells = Int[],)]
    on = _FF._loads_on_element(loads, a)
    @test length(on) == 1
    @test on[1].tag === :on_a
end

@testset "Beam NLP shear rows pair Vu with its own axial" begin
    # Asap P is tension-positive; the row's Nu is compression-positive.
    vu, nu = _FF._concurrent_strong_shear([-5.0, -50.0, 20.0], [10.0, -3.0, -40.0])
    @test vu == 40.0
    @test nu == -20.0
    @test _FF._concurrent_strong_shear(Float64[], Float64[]) == (0.0, 0.0)

    S = _FF.BeamShearCase
    rows = [S(100.0, 10.0, 0.0),   # covered by the next row: same Vu, less compression there
            S(100.0, 0.0, 0.0),
            S(80.0, -5.0, 0.0),    # less shear but more tension (lower Vc): kept
            S(120.0, 50.0, 0.0),   # most shear, with compression: kept
            S(100.0, 0.0, 0.0),    # duplicate: one copy kept
            S(60.0, -30.0, 0.0),   # covered by the next row: same tension, less shear
            S(70.0, -30.0, 0.0),   # most tension: kept
            S(90.0, 0.0, 5.0)]     # torsion row is never pruned against Tu = 0
    kept = _FF._prune_covered_shear(rows)
    @test kept == [S(100.0, 0.0, 0.0), S(80.0, -5.0, 0.0), S(120.0, 50.0, 0.0),
                   S(70.0, -30.0, 0.0), S(90.0, 0.0, 5.0)]
end
