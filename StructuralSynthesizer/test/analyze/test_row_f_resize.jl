# One-story row F frame. Strength utilization climbs with SDS. A member that
# fails is given a catalog floor and, once resized onto it, passes. A catalog
# that contains only the failing section leaves the member failing.

using StructuralSynthesizer
using StructuralSizer
using Asap
using Meshes
using Test
using Unitful

const _RF = StructuralSynthesizer
const _RQ = StructuralSizer

const _RF_SEGMENTS = (
    (0.0, 0.0, 6.0, 0.0),
    (6.0, 12.0, 12.0, 12.0),
    (12.0, 0.0, 12.0, 6.0),
    (0.0, 6.0, 0.0, 12.0),
)

_rf_xy(skel, vidx) = begin
    c = Meshes.coords(skel.vertices[vidx])
    (ustrip(u"m", c.x), ustrip(u"m", c.y))
end

_rf_horizontal(skel, eidx) = begin
    v1, v2 = skel.edge_indices[eidx]
    c1 = Meshes.coords(skel.vertices[v1])
    c2 = Meshes.coords(skel.vertices[v2])
    abs(ustrip(u"m", c1.z) - ustrip(u"m", c2.z)) <= 1e-6
end

_rf_same_plan(skel, eidx, x1, y1, x2, y2) = begin
    v1, v2 = skel.edge_indices[eidx]
    ax, ay = _rf_xy(skel, v1)
    bx, by = _rf_xy(skel, v2)
    (hypot(ax - x1, ay - y1) <= 1e-6 && hypot(bx - x2, by - y2) <= 1e-6) ||
        (hypot(ax - x2, ay - y2) <= 1e-6 && hypot(bx - x1, by - y1) <= 1e-6)
end

"""
Story 0 is the support level and has no beam grid. Copy the story-1 beam
plan down to the column bases so a ground wall has an edge to claim.
"""
function _rf_grade_beams!(skel)
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    any(e -> e in beams && _rf_horizontal(skel, e), skel.stories[0].edges) && return skel
    z0 = skel.stories_z[1]
    for e in skel.stories[1].edges
        (e in beams && _rf_horizontal(skel, e)) || continue
        v1, v2 = skel.edge_indices[e]
        x1, y1 = _rf_xy(skel, v1)
        x2, y2 = _rf_xy(skel, v2)
        _RF.add_element!(skel, Meshes.Segment(
            Meshes.Point(x1 * u"m", y1 * u"m", z0),
            Meshes.Point(x2 * u"m", y2 * u"m", z0));
            group=:beams, level_idx=0)
    end
    grade_of = Dict{NTuple{2, Float64}, Int}()
    for (k, v) in enumerate(skel.vertices)
        c = Meshes.coords(v)
        abs(ustrip(u"m", c.z) - ustrip(u"m", z0)) <= 1e-6 || continue
        grade_of[(round(ustrip(u"m", c.x); digits=6), round(ustrip(u"m", c.y); digits=6))] = k
    end
    for face in skel.stories[1].faces
        cycle = Int[]
        for v in skel.face_vertex_indices[face]
            x, y = _rf_xy(skel, v)
            key = (round(x; digits=6), round(y; digits=6))
            haskey(grade_of, key) || error("row F fixture: no grade vertex at $key")
            push!(cycle, grade_of[key])
        end
        _RF.add_face!(skel, Meshes.Ngon(skel.vertices[cycle]...);
                      group=:grade, level_idx=0, v_indices=cycle)
    end
    return skel
end

function _rf_claim_wall!(skel, beams, x1, y1, x2, y2)
    edges = [e for e in skel.stories[0].edges
             if e in beams && _rf_horizontal(skel, e) &&
                _rf_same_plan(skel, e, x1, y1, x2, y2)]
    length(edges) == 1 || error("row F fixture: $(length(edges)) edges on the wall line")
    eidx = only(edges)
    filter!(!=(eidx), skel.groups_edges[:beams])
    delete!(beams, eidx)
    walls = get!(skel.groups_edges, :walls, Int[])
    eidx in walls || push!(walls, eidx)
    return eidx
end

function _rf_office()
    skel = _rf_grade_beams!(gen_medium_office(12.0u"m", 12.0u"m", 3.0u"m", 2, 2, 1))
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    for (x1, y1, x2, y2) in _RF_SEGMENTS
        _rf_claim_wall!(skel, beams, x1, y1, x2, y2)
    end
    struc = BuildingStructure(skel)
    initialize!(struc;
        floor_type=:vault,
        material=NWC_4000,
        floor_opts=VaultOptions(rise=1.0u"m", thickness=0.05u"m"),
        wall_thickness=0.3u"m")
    for wall in struc.walls
        wall.concrete = RC_4000_60.concrete
    end
    return struc
end

function _rf_install!(struc, colsec, beamsec)
    for col in struc.columns
        _RF.set_section!(col, colsec)
        _RF.set_group_id!(col, UInt64(1))
        for seg in _RF.segment_indices(col)
            e = struc.segments[seg].edge_idx
            struc.asap_model.frame_elements[e].section =
                _RQ.to_asap_section(colsec, NWC_4000; I_factor=0.70)
        end
    end
    for beam in struc.beams
        _RF.set_section!(beam, beamsec)
        _RF.set_group_id!(beam, UInt64(2))
        for seg in _RF.segment_indices(beam)
            e = struc.segments[seg].edge_idx
            struc.asap_model.frame_elements[e].section =
                _RQ.to_asap_section(beamsec, NWC_4000; I_factor=0.35)
        end
    end
    Asap.process!(struc.asap_model)
    return struc
end

function _rf_inputs(sds)
    return OrdinaryWallInputs(;
        directions=((1.0, 0.0), (0.0, 1.0)),
        qz=[1.0],
        qh=2.0,
        Kd=1.0,
        G=0.85,
        GCpi=0.18,
        roof=:Lr,
        method=:sds,
        SDS=sds,
        S1=0.4 * sds,
        Ie=1.0,
        T=0.4,
        β=1.0,
        SD1=0.4 * sds,
        TL=8.0,
        rho=1.0,
        sdc=:B,
        risk_category=:II,
        drift_system=:other,
        boundary=:pinned,
        material=RC_4000_60,
        model_uses_cracked_section_stiffness=true,
        sustained_lateral_loads=false,
        sustained_lateral_divisor_applied=false,
        type1_horizontal_irregularity=false,
        type5_horizontal_irregularity=false,
        orthogonal_combination=false,
        orthogonal_12_5_4_conditions_absent=false,
        ax_applied_to_accidental_torsion=false,
        pdelta_included_in_member_forces=false,
    )
end

function _rf_params(sds; columns=nothing, beams=nothing)
    return DesignParameters(
        lateral=LateralDesign(; system=InteractiveShearWallFrameSystem(),
                               assignment=BuildingUnit()),
        wall_inputs=_rf_inputs(sds),
        columns=something(columns, ConcreteColumnOptions(
            material=NWC_4000, rebar_material=Rebar_60)),
        beams=something(beams, ConcreteBeamOptions(
            material=NWC_4000, rebar_material=Rebar_60)),
        skip_visualization=true,
        jump_wall_thickness=false)
end

_rf_worst(members) = maximum(c.governing_ratio for c in members)

@testset "Row F strength scales with SDS, then a floor resizes the frame" begin
    struc = _rf_office()
    @test length(struc.walls) == 4
    @test length(struc.columns) >= 4
    @test !isempty(struc.beams)
    cat = _RQ.square_rc_columns()
    colsec = cat[argmin(ustrip(u"inch^2", s.Ag) + 1000.0 * s.ρg for s in cat)]
    beamsec = RCBeamSection(b=12.0u"inch", h=24.0u"inch", bar_size=8, n_bars=3)
    params0 = _rf_params(1.0)
    to_asap!(struc; params=params0, diaphragms=:rigid)
    _rf_install!(struc, colsec, beamsec)

    # At low SDS the gravity moment can govern, so the ratio need not move
    # between 0.5 and 1.0. It must not fall, and a higher SDS that fails the
    # frame must sit above this gravity ratio. The design story shear still
    # rises: demand_N is 75% of that shear (ASCE 7-22 §12.2.5.8).
    ratios = Float64[]
    shears = Float64[]
    for sds in (0.5, 1.0)
        empty!(struc.frame_section_floors)
        empty!(struc.frame_floor_demands)
        result = design_ordinary_walls!(struc, _rf_params(sds))
        members = result.frame_members
        @test !isempty(members)
        @test all(c.passed for c in members)
        @test isempty(struc.frame_section_floors)
        @test !isempty(result.interactive_shear)
        r = _rf_worst(members)
        @test 0.0 < r < 1.0
        push!(ratios, r)
        push!(shears, maximum(c.demand_N for c in result.interactive_shear))
    end
    @test ratios[2] >= ratios[1]
    @test shears[2] > shears[1]

    # Keep raising SDS until a frame member fails. θ stays a frame-only check;
    # a throw here means the story is unstable, which this section is not at
    # SDS 1.
    failed = nothing
    fail_sds = nothing
    for sds in (2.0, 3.0, 4.0, 5.0)
        empty!(struc.frame_section_floors)
        empty!(struc.frame_floor_demands)
        result = design_ordinary_walls!(struc, _rf_params(sds))
        members = result.frame_members
        r = _rf_worst(members)
        @test r + 1e-6 >= ratios[end]
        push!(ratios, r)
        any(!c.passed for c in members) || continue
        failed = members
        fail_sds = sds
        break
    end
    @test fail_sds !== nothing
    @test ratios[end] > ratios[1]
    @test any(c -> !c.passed && !isempty(c.governing_check), failed)
    @test !isempty(struc.frame_section_floors)
    for c in failed
        c.passed && continue
        @test occursin("floor", c.detail)
    end

    _RF.snapshot!(struc, :row_f_floor)
    saved = copy(struc.frame_section_floors)
    saved_rows = Dict(gid => copy(rows) for (gid, rows) in struc.frame_floor_demands)
    empty!(struc.frame_section_floors)
    empty!(struc.frame_floor_demands)
    _RF.restore!(struc, :row_f_floor)
    @test keys(struc.frame_section_floors) == keys(saved)
    @test keys(struc.frame_floor_demands) == keys(saved)
    @test keys(struc.frame_floor_demands) == keys(saved_rows)
    @test all(!isempty(rows) for rows in values(struc.frame_floor_demands))
    for k in keys(saved)
        @test _RF._sections_identical(struc.frame_section_floors[k], saved[k])
    end

    # Resize onto the floor, then check the same SDS again.
    params = _rf_params(fail_sds)
    haskey(struc.frame_section_floors, UInt64(1)) &&
        size_columns!(struc, params.columns; reanalyze=false)
    haskey(struc.frame_section_floors, UInt64(2)) &&
        size_beams!(struc, params.beams; reanalyze=false)
    Asap.process!(struc.asap_model)
    again = design_ordinary_walls!(struc, params)
    @test all(c.passed for c in again.frame_members)
    @test _rf_worst(again.frame_members) < 1.0
    if haskey(saved, UInt64(1))
        floor = saved[UInt64(1)]
        obj = s -> _RQ.objective_value(params.columns.objective, s,
                                       params.columns.material, 1.0u"m")
        @test all(obj(c.base.section) >= obj(floor) for c in struc.columns)
    end

    # The same light sections, with a catalog that has nowhere to go, stay failing.
    _rf_install!(struc, colsec, beamsec)
    empty!(struc.frame_section_floors)
    empty!(struc.frame_floor_demands)
    capped = _rf_params(fail_sds;
        columns=ConcreteColumnOptions(material=NWC_4000, rebar_material=Rebar_60,
                                      custom_catalog=[colsec]),
        beams=ConcreteBeamOptions(material=NWC_4000, rebar_material=Rebar_60,
                                  custom_catalog=[beamsec]))
    held = design_ordinary_walls!(struc, capped)
    @test any(!c.passed for c in held.frame_members)
    @test isempty(struc.frame_section_floors)
    @test any(c -> !c.passed && occursin("not resized", c.detail), held.frame_members)
    @test !haskey(struc.stage_diagnostics, :wall_members)
end

@testset "Row F rows constrain NLP member sizing" begin
    struc = _rf_office()
    cat = _RQ.square_rc_columns()
    colsec = cat[argmin(ustrip(u"inch^2", s.Ag) + 1000.0 * s.ρg for s in cat)]
    beamsec = RCBeamSection(b=12.0u"inch", h=24.0u"inch", bar_size=8, n_bars=3)
    nlp_params(sds) = _rf_params(sds;
        columns=ConcreteColumnOptions(material=NWC_4000, rebar_material=Rebar_60,
                                      sizing_strategy=:nlp),
        beams=ConcreteBeamOptions(material=NWC_4000, rebar_material=Rebar_60,
                                  sizing_strategy=:nlp))
    to_asap!(struc; params=nlp_params(1.0), diaphragms=:rigid)
    _rf_install!(struc, colsec, beamsec)

    failed = nothing
    fail_sds = nothing
    for sds in (2.0, 3.0, 4.0, 5.0)
        empty!(struc.frame_floor_demands)
        result = design_ordinary_walls!(struc, nlp_params(sds))
        any(!c.passed for c in result.frame_members) || continue
        failed = result.frame_members
        fail_sds = sds
        break
    end
    @test fail_sds !== nothing

    # NLP has no catalog: no section floor, only the rows, kept as constraints.
    @test isempty(struc.frame_section_floors)
    @test !isempty(struc.frame_floor_demands)
    @test all(!isempty(rows) for rows in values(struc.frame_floor_demands))
    for c in failed
        c.passed && continue
        @test occursin("NLP member sizing", c.detail)
    end
    column_rows = [d for rows in values(struc.frame_floor_demands)
                   for (_, d) in rows if d isa RCColumnDemand]
    @test all(d -> !d.magnify, column_rows)

    # A second check adds rows and keeps the earlier ones.
    before = Dict(gid => copy(rows) for (gid, rows) in struc.frame_floor_demands)
    design_ordinary_walls!(struc, nlp_params(fail_sds))
    for (gid, rows) in before
        @test all(row -> row in struc.frame_floor_demands[gid], rows)
    end

    # The NLP resize must pass every stored row (it throws otherwise) and
    # lowers the worst row F ratio.
    worst_before = _rf_worst(failed)
    params = nlp_params(fail_sds)
    haskey(struc.frame_floor_demands, UInt64(1)) &&
        size_columns!(struc, params.columns; reanalyze=false)
    haskey(struc.frame_floor_demands, UInt64(2)) &&
        size_beams!(struc, params.beams; reanalyze=false)
    Asap.process!(struc.asap_model)
    again = design_ordinary_walls!(struc, params)
    @test _rf_worst(again.frame_members) < worst_before
end
