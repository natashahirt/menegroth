# Lateral stage on plan axes other than global X and Y.
#
# A rotated rectangle analyzed on its own axes must give the axis-aligned
# results. Analyzed on global axes, its walls are on neither axis. A
# parallelogram has walls on neither axis whatever axis is chosen, which is a
# Type 5 nonparallel system irregularity. In Category C that requires the
# §12.5.1.2 orthogonal combination. The ELF and wind numbers are fixture
# wiring, the same as the axis-aligned stage tests.

using Test
using LinearAlgebra: dot
using Unitful
using Asap
using StructuralSynthesizer
using StructuralSizer

import Meshes
include(joinpath(@__DIR__, "skew_plan_fixtures.jl"))

function _skew_inputs(; sdc::Symbol=:B, directions=((1.0, 0.0), (0.0, 1.0)),
                      orthogonal::Bool=false)
    return OrdinaryWallInputs(;
        directions=directions,
        qz=[1.0, 1.5, 2.0], qh=2.0, Kd=1.0, G=0.85, GCpi=0.18,
        roof=:Lr, method=:sds, SDS=0.05, S1=0.02, Ie=1.0, T=0.4, β=1.0,
        SD1=0.02, TL=8.0, rho=1.0, sdc=sdc, risk_category=:II,
        drift_system=:other, boundary=:pinned, material=RC_4000_60,
        model_uses_cracked_section_stiffness=true,
        sustained_lateral_loads=false, sustained_lateral_divisor_applied=false,
        type1_horizontal_irregularity=false, type5_horizontal_irregularity=false,
        orthogonal_combination=orthogonal,
        orthogonal_12_5_4_conditions_absent=false,
        ax_applied_to_accidental_torsion=false,
        pdelta_included_in_member_forces=false)
end

function _skew_params(; system=WallsSeismicSystem(:A3), plan_axis=(1.0, 0.0), kwargs...)
    return DesignParameters(
        lateral=LateralDesign(; system, assignment=BuildingUnit(), plan_axis),
        wall_inputs=_skew_inputs(; kwargs...),
        diaphragm_mode=:rigid,
        skip_visualization=true)
end

function _skew_run(map, params; floor_type::Symbol=:one_way)
    struc = _skew_office(map; floor_type, plan_axis=params.lateral.plan_axis)
    to_asap!(struc; params=params, diaphragms=:rigid)
    return struc, design_ordinary_walls!(struc, params)
end

_skew_master(z) = Asap.Node([0.0u"m", 0.0u"m", z * u"m"], :free)

@testset "plan axes" begin
    @test StructuralSynthesizer.unit_plan_axis((3.0, 4.0)) == (0.6, 0.8)
    @test_throws ArgumentError StructuralSynthesizer.unit_plan_axis((0.0, 0.0))
    e1, e2 = StructuralSynthesizer.plan_axes((0.6, 0.8))
    @test e2 == (-0.8, 0.6)
    @test LateralDesign(; system=WallsSeismicSystem(:A3), assignment=BuildingUnit(),
                        plan_axis=(2.0, 0.0)).plan_axis == (1.0, 0.0)

    wall(x2, y2) = Wall([1], 4.0u"m"; thickness=0.3u"m", x1=0.0, y1=0.0, x2=x2, y2=y2,
                        story=0, ρl=0.0025, ρt=0.0025)
    axis = (cos(deg2rad(30)), sin(deg2rad(30)))
    along = wall(6 * axis[1], 6 * axis[2])
    across = wall(-6 * axis[2], 6 * axis[1])
    angled = wall(6.0, 0.0)
    @test StructuralSynthesizer._pier_axis_direction(along, axis) === :X
    @test StructuralSynthesizer._pier_axis_direction(across, axis) === :Y
    @test StructuralSynthesizer._pier_axis_direction(angled, axis) === :skew
    @test StructuralSynthesizer._pier_axis_direction(angled) === :X
    # 30° from the first axis: cos 30° on X and sin 30° on Y.
    @test StructuralSynthesizer._pier_axis_cosine(angled, axis, :X) ≈ cos(deg2rad(30))
    @test StructuralSynthesizer._pier_axis_cosine(angled, axis, :Y) ≈ sin(deg2rad(30))
    @test StructuralSynthesizer._pier_axis_cosine(across, axis, :X) < 1e-12
end

@testset "floor spans and column sections follow the plan axis" begin
    α = deg2rad(30)
    e1 = (cos(α), sin(α))
    e2 = (-sin(α), cos(α))
    skel = _skew_skeleton(_skew_rotation(α); stories=1)
    StructuralSynthesizer.rebuild_geometry_cache!(skel)
    face = first(skel.stories[1].faces)
    # The 6 m × 5 m bay turned 30°: the longest global-Y chord (5.77 m) is
    # shorter than the global-X chord, so global axes pick neither bay side.
    on_global = StructuralSynthesizer.get_cell_spans(skel, face)
    @test on_global.axis == (0.0, 1.0)
    on_plan = StructuralSynthesizer.get_cell_spans(skel, face; plan_axis=e1)
    @test all(isapprox.(on_plan.axis, e2; atol=1e-12))
    @test ustrip(u"m", on_plan.primary) ≈ 5.0
    @test ustrip(u"m", on_plan.secondary) ≈ 6.0

    # Column.θ is the plan angle of c1. The roll replaces Asap's default Ψ:
    # a column drawn upward gets +α, one drawn downward -α, θ = 0 gives 0,
    # and a beam is not a column.
    sec = Asap.Section(1.0u"m^2", 1.0u"Pa", 1.0u"Pa", 2.0u"m^4", 1.0u"m^4", 1.0u"m^4")
    node(x, y, z) = Asap.Node([x * u"m", y * u"m", z * u"m"], :free)
    up = Asap.Element(node(0, 0, 0), node(0, 0, 4), sec)
    down = Asap.Element(node(1, 0, 4), node(1, 0, 0), sec)
    beam = Asap.Element(node(0, 0, 4), node(6, 0, 4), sec)
    Ψ0 = beam.Ψ
    StructuralSynthesizer._apply_column_roll!(up, α)
    StructuralSynthesizer._apply_column_roll!(down, α)
    StructuralSynthesizer._apply_column_roll!(beam, α)
    @test up.Ψ ≈ α
    @test down.Ψ ≈ -α
    @test beam.Ψ == Ψ0
    zero_roll = Asap.Element(node(0, 0, 0), node(0, 0, 4), sec)
    StructuralSynthesizer._apply_column_roll!(zero_roll, 0.0)
    @test zero_roll.Ψ == 0.0
    # Both drawing directions put local y (the axis Ix acts with) along c2.
    for el in (up, down)
        Asap.lcs!(el, el.Ψ)
        @test abs(dot(el.LCS[2], [-sin(α), cos(α), 0.0])) ≈ 1.0
    end

    # The bounding-box corner of a rotated floor is outside the floor.
    polys = [StructuralSynthesizer._face_plan_vertices(skel, f) for f in skel.stories[1].faces]
    minx = minimum(p[1] for poly in polys for p in poly)
    maxy = maximum(p[2] for poly in polys for p in poly)
    outside = StructuralSizer.WallLine(1, minx, maxy, 0.0, 1.0, 1)
    @test_throws ArgumentError StructuralSynthesizer.assert_walls_on_floor!(
        skel, skel.stories[1], [outside])
    on_edge = StructuralSizer.WallLine(2, polys[1][1][1], polys[1][1][2], 0.0, 1.0, 1)
    @test StructuralSynthesizer.assert_walls_on_floor!(
        skel, skel.stories[1], [on_edge]) === nothing
end

@testset "a rolled column sways along c1 on c2·c1³/12" begin
    # RCColumnSection convention: b = c1 (section x), h = c2, Ix = b·h³/12.
    # Cantilever tip deflection is P·L³/(3·E·I) with I about the axis normal
    # to the sway, so sway along c1 uses Iy = c2·c1³/12.
    E, L, P = 25e9, 3.0, 1000.0
    c1, c2 = 0.3, 0.6
    Ix, Iy = c1 * c2^3 / 12, c2 * c1^3 / 12
    function tip(θ, dir)
        base = Asap.Node([0.0, 0.0, 0.0] .* u"m", :fixed)
        top = Asap.Node([0.0, 0.0, L] .* u"m", :free)
        sec = Asap.Section(c1 * c2 * u"m^2", E * u"Pa", (E / 2.4) * u"Pa",
                           Ix * u"m^4", Iy * u"m^4", (Ix + Iy) * u"m^4", 2400.0u"kg/m^3")
        el = Asap.Element(base, top, sec)
        StructuralSynthesizer._apply_column_roll!(el, θ)
        load = Asap.NodeForce(top, [P * dir[1], P * dir[2], 0.0] .* u"N", :p)
        model = Asap.Model([base, top], Asap.Element[el], Asap.AbstractLoad[load])
        Asap.solve!(model)
        d = [ustrip(u"m", x) for x in top.displacement[1:2]]
        return d[1] * dir[1] + d[2] * dir[2]
    end
    δ(I) = P * L^3 / (3 * E * I)
    for θ in (0.0, deg2rad(30))
        along_c1 = (cos(θ), sin(θ))
        along_c2 = (-sin(θ), cos(θ))
        @test tip(θ, along_c1) ≈ δ(Iy) rtol = 1e-9
        @test tip(θ, along_c2) ≈ δ(Ix) rtol = 1e-9
    end
end

@testset "a tributary_axis override reaches load routing" begin
    # Vault cells would span 5 m along Y. Forcing X recomputes the spans and
    # survives the to_asap! recompute, which passes no axis.
    struc = _skew_office((x, y) -> (x, y); floor_type=:vault, tributary_axis=(1.0, 0.0))
    @test struc._tributary_caches.axis_override == (1.0, 0.0)
    @test all(c -> c.θ == 0.0, struc.columns)
    StructuralSynthesizer.compute_cell_tributaries!(struc)
    @test struc._tributary_caches.axis_override == (1.0, 0.0)
    idx = findfirst(c -> c.floor_type == :vault, struc.cells)
    @test struc.cells[idx].spans.axis == (1.0, 0.0)
    @test struc._tributary_caches.cell_axes[idx] == (1.0, 0.0)
    forced = StructuralSynthesizer.cell_edge_tributaries(struc, idx,
        StructuralSizer.OneWaySpanning(), (1.0, 0.0))
    @test !isnothing(forced)
    @test StructuralSynthesizer.cell_edge_tributaries(struc, idx) === forced
end

@testset "§12.5 procedure selection" begin
    req(sdc; t1=false, t5=false, absent=true) = orthogonal_combination_required(;
        sdc, type1_horizontal_irregularity=t1, type5_horizontal_irregularity=t5,
        orthogonal_12_5_4_conditions_absent=absent)
    @test !req(:B; t1=true, t5=true, absent=false)
    @test !req(:C)
    @test !req(:C; t1=true)
    @test req(:C; t5=true)
    @test !req(:D)
    @test req(:D; t1=true)
    @test req(:D; t5=true)
    @test req(:D; absent=false)
    @test_throws ArgumentError req(:A)
end

@testset "§12.5.1.2 effects and drift" begin
    level = StructuralSynthesizer.ElfLevel(1, 4.0, 4.0, 4.0, 1.0, 1.0, 1.0, _skew_master(4.0),
        (0.0, 0.0), (10.0, 6.0), (0.0, 10.0, 0.0, 6.0), Vector{Vector{NTuple{2, Float64}}}())
    # Own-axis and cross-axis design drift, distinct for every case.
    own = Dict((:x, :none) => 0.010, (:x, :plus) => 0.012, (:x, :minus) => 0.008,
               (:y, :none) => 0.020, (:y, :plus) => 0.023, (:y, :minus) => 0.017)
    cross = Dict((:x, :none) => 0.001, (:x, :plus) => 0.0015, (:x, :minus) => 0.0005,
                 (:y, :none) => 0.004, (:y, :plus) => 0.005, (:y, :minus) => 0.003)
    cases = StructuralSynthesizer.ElfCase[]
    for d in (:x, :y), t in (:none, :plus, :minus)
        z = zeros(1)
        push!(cases, StructuralSynthesizer.ElfCase(d, :drift, t, 0.1, 1.0, 1.0,
            z, z, z, z, z, z, [own[(d, t)]],
            Union{Float64, Nothing}[0.01], Union{Float64, Nothing}[1.0],
            Union{Float64, Nothing}[nothing], [cross[(d, t)]]))
    end
    analysis = StructuralSynthesizer.ElfStoryAnalysis([level], cases)

    independent = seismic_effect_cases(analysis; orthogonal=false, purpose=:drift)
    @test length(independent) == 6
    @test all(e -> length(e.terms) == 1 && only(e.terms)[2] == 1.0, independent)

    effects = seismic_effect_cases(analysis; orthogonal=true, purpose=:drift)
    @test length(effects) == 16
    @test length(unique(e.label for e in effects)) == 16
    @test all(e -> e.torsion in (:plus, :minus), effects)
    for e in effects
        main, comp = e.terms
        @test abs(main[2]) == 1.0
        @test abs(comp[2]) ≈ 0.3
        @test cases[main[1]].direction === e.direction
        @test cases[main[1]].torsion === e.torsion
        @test cases[comp[1]].direction !== e.direction
        @test cases[comp[1]].torsion === :none
    end

    checks, mults = StructuralSynthesizer._story_drift_with_pdelta(analysis;
        risk_category=:II, system=:other, orthogonal=true)
    # Eight effects with a positive 100% term, each read along both axes.
    @test length(checks) == 16 == length(mults)
    @test all(m -> m == 1.0, mults)
    label = :QE_posx_plus_pos30y
    @test any(e -> e.label === label, effects)
    on_x = only(c for c in checks if c.effect === label && c.direction === :x)
    on_y = only(c for c in checks if c.effect === label && c.direction === :y)
    @test on_x.drift_m ≈ own[(:x, :plus)] + 0.3 * cross[(:y, :none)]
    @test on_y.drift_m ≈ cross[(:x, :plus)] + 0.3 * own[(:y, :none)]
    neg = only(c for c in checks if c.effect === :QE_posy_minus_neg30x && c.direction === :y)
    @test neg.drift_m ≈ abs(own[(:y, :minus)] - 0.3 * cross[(:x, :none)])
end

@testset "rotated rectangle on its own axes matches the axis-aligned run" begin
    α = deg2rad(30)
    e1 = (cos(α), sin(α))
    e2 = (-sin(α), cos(α))
    # Vault floors. Spans are detected on the plan axes and column sections
    # turn with them, so the rotated model is the same structure.
    s0, r0 = _skew_run((x, y) -> (x, y), _skew_params(); floor_type=:vault)
    rot, r1 = _skew_run(_skew_rotation(α),
                        _skew_params(; plan_axis=e1, directions=(e1, e2));
                        floor_type=:vault)
    # Column.θ follows the plan axis and is what the analysis roll uses.
    @test all(c -> c.θ == 0.0, s0.columns)
    @test all(c -> isapprox(c.θ, α; atol=1e-12), rot.columns)
    eidx = rot.segments[first(rot.columns[1].base.segment_indices)].edge_idx
    el = rot.asap_model.frame_elements[eidx]
    za = ustrip(u"m", el.nodeStart.position[3])
    zb = ustrip(u"m", el.nodeEnd.position[3])
    @test el.Ψ ≈ sign(zb - za) * α

    @test !r1.type5_horizontal_irregularity
    @test isempty(r1.nonparallel_elements)
    @test !r1.orthogonal_combination
    @test length(r0.drift) == length(r1.drift)
    for (a, b) in zip(r0.drift, r1.drift)
        @test (a.story, a.direction, a.torsion) == (b.story, b.direction, b.torsion)
        @test isapprox(a.drift_m, b.drift_m; rtol=1e-6)
    end
    @test sort(collect(keys(r0.checks))) == sort(collect(keys(r1.checks)))
    for idx in keys(r0.checks)
        a, b = r0.checks[idx], r1.checks[idx]
        @test length(a) == length(b)
        @test [r.direction for r in a] == [r.direction for r in b]
        @test all(r -> r.direction in (:X, :Y), b)
        # The wind case symbol carries the global wind direction, which rotates
        # with the building. The check and the demand are what must agree.
        @test [r.check for r in a] == [r.check for r in b]
        # Some demands are near zero (in-plane shear of a wall loaded across its
        # thickness), so the tolerance is on this wall's largest demand per check.
        for check in unique(r.check for r in a)
            pairs = [(x.demand, y.demand) for (x, y) in zip(a, b) if x.check == check]
            scale = maximum(max(abs(x), abs(y)) for (x, y) in pairs)
            @test all(abs(x - y) <= 1e-6 * max(scale, 1.0) for (x, y) in pairs)
        end
    end

    # The same rotated building on global axes: every wall is on neither axis.
    r2 = design_ordinary_walls!(rot, _skew_params())
    @test r2.type5_horizontal_irregularity
    @test length(r2.nonparallel_elements) == length(rot.walls)
    # Category B permits the independent procedure even with Type 5.
    @test !r2.orthogonal_combination
    @test all(r -> r.direction === :skew, Iterators.flatten(values(r2.checks)))
end

@testset "parallelogram in Category C uses the orthogonal combination" begin
    struc, r = _skew_run(_skew_shear(deg2rad(20)), _skew_params(; sdc=:C))
    @test r.type5_horizontal_irregularity
    # The two inclined wall lines, on each of three stories.
    @test length(r.nonparallel_elements) == 6
    @test r.orthogonal_combination
    for (idx, records) in r.checks
        wall = struc.walls[idx]
        dir = StructuralSynthesizer._pier_axis_direction(wall)
        @test dir in (:X, :skew)
        @test all(rec -> rec.direction === dir, records)
        qe = unique(rec.case for rec in records if startswith(string(rec.case), "QE"))
        @test length(qe) == 16
        @test all(c -> occursin("30", string(c)), qe)
    end
    @test all(d -> d.effect !== :independent, r.drift)
    @test length(r.drift) == 8 * 3 * 2
    @test Set(d.direction for d in r.drift) == Set([:x, :y])

    # The caller may not turn the combination off where §12.5.3 requires it,
    # and Category B leaves it to the caller.
    _, rb = _skew_run(_skew_shear(deg2rad(20)), _skew_params(; sdc=:B))
    @test rb.type5_horizontal_irregularity
    @test !rb.orthogonal_combination
    @test all(d -> d.effect === :independent, rb.drift)
end

@testset "a parallelogram spans along the axis it is given" begin
    α = deg2rad(20)
    # The sheared edge of a 5 m bay, and the direction perpendicular to it.
    along = (sin(α), cos(α))
    perp = (-along[2], along[1])
    function spans_along(axis)
        struc = _skew_office(_skew_shear(α); floor_type=:one_way, tributary_axis=axis)
        cell = first(c for c in struc.cells if c.floor_type == :one_way)
        return cell.spans
    end
    # The edge itself is the longest chord parallel to it: 5 / cos α.
    s_along = spans_along(along)
    @test all(isapprox.(s_along.axis, along; atol=1e-12))
    @test ustrip(u"m", s_along.primary) ≈ 5 / cos(α)
    # Perpendicular to those edges the bay is 6 cos α deep.
    s_perp = spans_along(perp)
    @test all(isapprox.(s_perp.axis, perp; atol=1e-12))
    @test ustrip(u"m", s_perp.primary) ≈ 6 * cos(α)
    # Global X crosses the bay in the original 6 m.
    s_x = spans_along((1.0, 0.0))
    @test s_x.axis == (1.0, 0.0)
    @test ustrip(u"m", s_x.primary) ≈ 6.0

    # A region axis replaces the building axis on the one bay it covers.
    t = tan(α)
    bay = [(0.0, 0.0, 4.0), (6.0, 0.0, 4.0), (6 + 5t, 5.0, 4.0), (5t, 5.0, 4.0)]
    ov = StructuralSynthesizer.ScopedFloorOverride(floor_type=:one_way, span_axis=(0.0, 1.0), faces=[bay])
    struc = _skew_office(_skew_shear(α); floor_type=:one_way, tributary_axis=(1.0, 0.0),
                         scoped_floor_overrides=[ov])
    axes = struc._tributary_caches.cell_axes
    on_y = [i for (i, ax) in axes if ax == (0.0, 1.0)]
    @test length(on_y) == 1
    @test all(ax -> ax == (1.0, 0.0), (ax for (i, ax) in axes if i != only(on_y)))
    @test StructuralSynthesizer.cell_edge_tributaries(struc, only(on_y)) ===
          StructuralSynthesizer.cell_edge_tributaries(struc, only(on_y),
              StructuralSizer.OneWaySpanning(), (0.0, 1.0))
end

@testset "split systems refuse an element on neither axis" begin
    struc = _skew_office(_skew_shear(deg2rad(20)); floor_type=:one_way)
    params = DesignParameters(
        lateral=LateralDesign(; system_x=WallsSeismicSystem(:B6),
                              system_y=InteractiveShearWallFrameSystem(),
                              assignment=BuildingUnit()),
        wall_inputs=_skew_inputs(),
        diaphragm_mode=:rigid,
        skip_visualization=true)
    to_asap!(struc; params=params, diaphragms=:rigid)
    err = try
        design_ordinary_walls!(struc, params)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    msg = sprint(showerror, err)
    @test occursin("neither plan axis", msg)
    @test occursin("12.2.2", msg)
end
