# Wall thickness jump: one analysis predicts the other inches.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

function _jump_pier(; length=5.0, height=3.0, thickness=0.20,
                    x1=0.0, y1=0.0, x2=nothing, y2=0.0, story=0)
    x2 === nothing && (x2 = x1 + length)
    return Wall([1], height * u"m"; thickness=thickness * u"m",
                x1=x1, y1=y1, x2=x2, y2=y2, story=story)
end

function _jump_trial(wall, actions; N_self0=0.0, lw=nothing, hw=nothing,
                     boundary=:restrained)
    lw = lw === nothing ? wall_length(wall) * u"m" : lw
    hw = hw === nothing ? wall.base.L : hw
    return WallThicknessTrial(wall, actions, Float64(N_self0), lw, 0.0u"N*m",
                              RC_4000_60, hw, nothing, boundary, nothing)
end

@testset "Wall self-weight axial splits from tributary" begin
    wall = _jump_pier()
    ρ = RC_4000_60.concrete.ρ
    N0 = pier_self_weight_N(wall, 0.20u"m", 5.0u"m", ρ)
    @test N0 ≈ ustrip(u"kg/m^3", ρ) * 0.20 * 5.0 * 3.0 * 9.80665 rtol=1e-12
    N1 = pier_self_weight_N(wall, 0.40u"m", 5.0u"m", ρ)
    @test N1 ≈ 2 * N0 rtol=1e-12
end

@testset "Factored axial picks up self-weight; V and M stay" begin
    a14 = CombinedWallAction(:strength_1_4D, :only, 1.4e6, 8.0e4, 9.0e4)
    N_self = 1.0e5
    doubled = scale_wall_action(a14, 0.40u"m", 0.20u"m", N_self, 0.0)
    @test doubled.V == a14.V
    @test doubled.M == a14.M
    @test doubled.N ≈ a14.N + 1.4 * N_self rtol=1e-12

    aE = CombinedWallAction(:strength_1_2D_1_0E, :only, 1.2e6, 8.0e4, 9.0e4)
    SDS = 0.5
    scaled = scale_wall_action(aE, 0.40u"m", 0.20u"m", N_self, SDS)
    # D factor 1.2 plus Ev = +0.2 SDS D.
    @test scaled.N ≈ aE.N + (1.2 + 0.2 * SDS) * N_self rtol=1e-12
    @test scaled.V == aE.V
end

@testset "Thickness groups follow the plan and the stack" begin
    function pier(x1, y1, x2, y2; story=1)
        return Wall([1], 3.0u"m"; thickness=0.30u"m",
                    x1=x1, y1=y1, x2=x2, y2=y2, story=story)
    end
    south = pier(0, 0, 8, 0)
    south_on = pier(8, 0, 12, 0)
    south_gap = pier(14, 0, 18, 0)
    south_up = pier(0, 0, 8, 0; story=2)
    north = pier(0, 6, 8, 6)
    east = pier(8, 0, 8, 6)
    south.wall_above = south_up
    walls = [south, south_on, south_gap, south_up, north, east]
    @test wall_thickness_groups(walls) == [1, 1, 1, 1, 1, 1]
    @test wall_thickness_groups(walls; grouping=:pier) == collect(1:6)
    @test wall_thickness_groups(walls; grouping=:story) == [1, 1, 1, 2, 1, 1]
    # The touching south pieces and the story above are one line. The gap is not.
    @test wall_thickness_groups(walls; grouping=:wall_line) == [1, 1, 2, 1, 3, 4]
    @test wall_thickness_groups(walls; grouping=:wall_line_story) == [1, 1, 2, 3, 4, 5]
    # Only the linked south stack shares a group. The touching piece is its own pier.
    @test wall_thickness_groups(walls; grouping=:pier_stack) == [1, 2, 3, 1, 4, 5]
    @test wall_thickness_groups(Wall[]) == Int[]
    @test_throws ArgumentError wall_thickness_groups(walls; grouping=:bay)

    for g in WALL_THICKNESS_GROUPINGS
        params = DesignParameters(wall_thickness_grouping=g)
        @test StructuralSynthesizer._require_wall_thickness_grouping(params) === nothing
    end
    params = DesignParameters(wall_thickness_grouping=:bay)
    @test_throws ArgumentError StructuralSynthesizer._require_wall_thickness_grouping(params)
end

@testset "The jump keeps one shared thickness" begin
    a = _jump_pier(; thickness=0.30)
    b = _jump_pier(; thickness=0.30)
    @test ustrip(u"m", shared_wall_thickness([a, b])) ≈ 0.30
    b.thickness = 0.40u"m"
    @test shared_wall_thickness([a, b]) === nothing
    @test shared_wall_thickness(Wall[]) === nothing
end

@testset "Inch stations start above the analyzed thickness" begin
    ts = wall_thickness_candidates(0.20u"m")
    @test !isempty(ts)
    @test all(t -> ustrip(u"m", t) > 0.20 + 1e-9, ts)
    inch = ustrip(u"m", 1.0u"inch")
    @test ustrip(u"m", ts[1]) ≈ ceil((0.20 + 1e-9) / inch) * inch atol=1e-9
    @test ustrip(u"m", ts[2] - ts[1]) ≈ inch atol=1e-9
end

@testset "A scale below the geometric self-weight is refused" begin
    wall = _jump_pier()
    N_self = pier_self_weight_N(wall, wall.thickness, 5.0u"m", RC_4000_60.concrete.ρ)
    # 1.4D axial smaller than 1.4 × self-weight.
    light = CombinedWallAction(:strength_1_4D, :only, 0.5 * 1.4 * N_self, 1e3, 1e3)
    trial = _jump_trial(wall, [light]; N_self0=N_self, lw=5.0u"m")
    @test wall_thickness_scale_applies(0.20u"m", [trial]) == false
    ok = CombinedWallAction(:strength_1_4D, :only, 1.4 * (N_self + 2e5), 1e3, 1e3)
    @test wall_thickness_scale_applies(0.20u"m", [_jump_trial(wall, [ok]; N_self0=N_self, lw=5.0u"m")])
end

function _jump_result(checks; drift=SeismicStoryDriftCheck[],
                      boundary=Dict{Int, StructuralSynthesizer.SpecialBoundaryDecision}())
    checks isa AbstractDict || (checks = Dict(1 => checks))
    return StructuralSynthesizer.OrdinaryWallResult(
        checks, drift, 0.0, Float64[],
        StructuralSynthesizer.WallGravityShare[],
        StructuralSynthesizer.InteractiveStoryShearCheck[],
        StructuralSynthesizer.FrameMemberCheck[], false, String[], false,
        boundary, Dict{Int, Vector{StructuralSynthesizer.SpecialBoundaryDecision}}(),
        Dict{Int, StructuralSynthesizer.BoundaryEndReinforcement}(),
        StructuralSynthesizer.GravityInducedCheck[])
end

function _jump_record(check, ratio, demand, capacity; passed=false, index=1)
    return WallCheckRecord(index, 0, :X, :D, :strength_1_4D, :only, check,
                           passed, ratio, demand, capacity, "ACI 318-19 11.5.3")
end

@testset "Net axial tension alone does not jump" begin
    tension = _jump_record(
        "bottom bearing wall (§11.5.3): net axial tension — method inapplicable",
        Inf, -6.0e3, 0.0)
    @test !StructuralSynthesizer.wall_result_needs_thickness(_jump_result([tension]))
    shear = _jump_record("in-plane shear", 1.2, 1.2e5, 1.0e5)
    @test StructuralSynthesizer.wall_result_needs_thickness(_jump_result([tension, shear]))
end

@testset "Table 11.3.1.1 jumps in one step even when the scale is refused" begin
    t0 = 0.1016u"m"
    wall = _jump_pier(; thickness=0.1016)
    N_self = pier_self_weight_N(wall, t0, 5.0u"m", RC_4000_60.concrete.ρ)
    # 1.4D below 1.4 × self-weight: the frozen-demand scale is refused.
    light = CombinedWallAction(:strength_1_4D, :only, 0.5 * 1.4 * N_self, 1e3, 1e3)
    trial = _jump_trial(wall, [light]; N_self0=N_self, lw=5.0u"m")
    @test !wall_thickness_scale_applies(t0, [trial])
    h_min = 0.144
    thin = _jump_record("bottom bearing wall (§11.5.3): thickness below minimum",
                        h_min / 0.1016, h_min, 0.1016)
    t = propose_wall_thickness(t0, [trial], SeismicStoryDriftCheck[];
                               result=_jump_result([thin]))
    inch = ustrip(u"m", 1.0u"inch")
    @test ustrip(u"m", t) ≈ ceil(h_min / inch) * inch atol=1e-9
    # Nothing geometric failing and the scale refused: no jump.
    shear = _jump_record("in-plane shear", 1.2, 1.2e5, 1.0e5)
    t_same = propose_wall_thickness(t0, [trial], SeismicStoryDriftCheck[];
                                    result=_jump_result([shear]))
    @test t_same == t0
end

@testset "Drift at twice the allowable asks for twice the thickness" begin
    wall = _jump_pier()
    modest = CombinedWallAction(:strength_1_4D, :only, 2.0e5, 1.0e4, 1.0e4)
    trial = _jump_trial(wall, [modest]; N_self0=1.0e4, lw=5.0u"m")
    drift = [SeismicStoryDriftCheck(1, :X, :none, 0.020, 0.010, false)]
    t0 = 0.20u"m"
    t = propose_wall_thickness(t0, [trial], drift; SDS=0.0)
    @test ustrip(u"m", t) >= 0.40 - 1e-9
    @test wall_thickness_passes(0.40u"m", t0, [trial], drift)
    @test !wall_thickness_passes(0.30u"m", t0, [trial], drift)
    @test wall.thickness == 0.20u"m"
    @test wall.ρl == 0.0025 && wall.ρt == 0.0025
end

@testset "Shear above the §11.5.4.2 cap jumps in proportion to t" begin
    t0 = 0.20u"m"
    lw = 5.0
    hw = 12.0
    wall = _jump_pier(; length=lw, height=3.0, thickness=0.20)
    above = _jump_pier(; length=lw, height=9.0, thickness=0.20)
    wall.wall_above = above
    # stacked height is used from wall_above; set a 9 m wall above so hw ≈ 12 m.
    fc = ustrip(u"Pa", RC_4000_60.concrete.fc′)
    fyt = ustrip(u"Pa", RC_4000_60.transverse.Fy)
    λ = RC_4000_60.concrete.λ
    cap0 = wall_shear_capacity_si(fc, fyt, lw, 0.20, 0.0, hw; λ=λ)
    Vu = 1.25 * WALL_PHI_SHEAR * cap0.Vn_max
    N_self = pier_self_weight_N(wall, t0, lw * u"m", RC_4000_60.concrete.ρ)
    actions = [CombinedWallAction(:strength_1_4D, :only, 1.4 * (N_self + 2.0e5), Vu, 1.0e4)]
    trial = _jump_trial(wall, actions; N_self0=N_self, lw=lw * u"m", hw=hw * u"m")
    t = propose_wall_thickness(t0, [trial], SeismicStoryDriftCheck[]; SDS=0.0)
    @test ustrip(u"m", t) >= 1.25 * 0.20 - 1e-9
    @test wall_thickness_passes(t, t0, [trial], SeismicStoryDriftCheck[])
    t_short = (1.10 * 0.20) * u"m"
    @test !wall_thickness_passes(t_short, t0, [trial], SeismicStoryDriftCheck[])
    @test wall.thickness == t0
end

@testset "Special shear sizes the jump for Ve at the analyzed φ" begin
    t0 = 0.20u"m"
    lw, hw = 5.0, 12.0
    wall = _jump_pier(; length=lw, height=3.0, thickness=0.20)
    wall.wall_above = _jump_pier(; length=lw, height=9.0, thickness=0.20)
    fc = ustrip(u"Pa", RC_4000_60.concrete.fc′)
    fyt = ustrip(u"Pa", RC_4000_60.transverse.Fy)
    cap0 = wall_shear_capacity_si(fc, fyt, lw, 0.20, 0.0, hw; λ=RC_4000_60.concrete.λ)
    Vu = 1.25 * WALL_PHI_SHEAR * cap0.Vn_max
    N_self = pier_self_weight_N(wall, t0, lw * u"m", RC_4000_60.concrete.ρ)
    actions = [CombinedWallAction(:strength_1_2D_1_0E, :only, 1.4 * (N_self + 2.0e5), Vu, 1.0e4)]
    shear = StructuralSynthesizer.WallThicknessShear(2.0, 1.0, 0.60, hw, hw)
    trial = WallThicknessTrial(wall, actions, N_self, lw * u"m", 0.0u"N*m",
                              RC_4000_60, hw * u"m", nothing, :pinned, shear)
    # Ve = 2 Vu and φ = 0.60, against φ = 0.75 at Vu: 2 × 0.75 / 0.60 = 2.5,
    # and the section is already 1.25 times over the ordinary cap.
    failing = _jump_record(StructuralSynthesizer.SPECIAL_WALL_SHEAR_CHECK, 3.2, 2 * Vu, Vu / 3.2)
    t = propose_wall_thickness(t0, [trial], SeismicStoryDriftCheck[];
                              SDS=0.0, result=_jump_result([failing]))
    @test ustrip(u"m", t) >= 2.5 * 1.25 * 0.20 - 1e-6
    @test wall_thickness_passes(t, t0, [trial], SeismicStoryDriftCheck[])
    @test wall.thickness == t0
end

"""Two walls. `:parallel` splits by line, `:collinear` joins on one line, `:stack` joins up the height."""
function _placed_walls(layout; thickness=0.20)
    if layout === :parallel
        return [
            _jump_pier(; thickness, x1=0.0, y1=0.0, x2=5.0, y2=0.0, story=1),
            _jump_pier(; thickness, x1=0.0, y1=6.0, x2=5.0, y2=6.0, story=1),
        ]
    elseif layout === :collinear
        return [
            _jump_pier(; thickness, x1=0.0, y1=0.0, x2=5.0, y2=0.0, story=1),
            _jump_pier(; thickness, x1=5.0, y1=0.0, x2=10.0, y2=0.0, story=1),
        ]
    elseif layout === :stack
        lower = _jump_pier(; thickness, x1=0.0, y1=0.0, x2=5.0, y2=0.0, story=1)
        upper = _jump_pier(; thickness, x1=0.0, y1=0.0, x2=5.0, y2=0.0, story=2)
        lower.wall_above = upper
        return [lower, upper]
    end
    error("wall layout $layout is not parallel, collinear, or stack")
end

_meters(ts) = [ustrip(u"m", t) for t in ts]

function _scale_refused_trial(wall)
    lw = hypot(wall.x2 - wall.x1, wall.y2 - wall.y1) * u"m"
    N_self = pier_self_weight_N(wall, wall.thickness, lw, RC_4000_60.concrete.ρ)
    action = CombinedWallAction(:strength_1_4D, :only, 0.5 * 1.4 * N_self, 1e3, 1e3)
    return _jump_trial(wall, [action]; N_self0=N_self, lw=lw)
end

function _modest_trial(wall)
    lw = hypot(wall.x2 - wall.x1, wall.y2 - wall.y1) * u"m"
    action = CombinedWallAction(:strength_1_4D, :only, 2.0e5, 1.0e4, 1.0e4)
    return _jump_trial(wall, [action]; N_self0=1.0e4, lw=lw)
end

"""Driver wall at `over` times the §11.5.4.2 cap. The other wall is at half the cap."""
function _shear_trials(walls; over=1.25, hw=3.0)
    lw = 5.0
    t0 = ustrip(u"m", walls[1].thickness)
    fc = ustrip(u"Pa", RC_4000_60.concrete.fc′)
    fyt = ustrip(u"Pa", RC_4000_60.transverse.Fy)
    λ = RC_4000_60.concrete.λ
    cap = wall_shear_capacity_si(fc, fyt, lw, t0, 0.0, hw; λ=λ)
    ϕmax = WALL_PHI_SHEAR * cap.Vn_max
    trials = WallThicknessTrial[]
    for (i, wall) in enumerate(walls)
        factor = i == 1 ? over : 0.50
        N_self = pier_self_weight_N(wall, wall.thickness, lw * u"m", RC_4000_60.concrete.ρ)
        action = CombinedWallAction(
            :strength_1_4D, :only, 1.4 * (N_self + 2.0e5), factor * ϕmax, 1.0e4)
        push!(trials, _jump_trial(wall, [action]; N_self0=N_self, lw=lw * u"m", hw=hw * u"m"))
    end
    return trials
end

"""
`:all` is one thickness. Every other grouping's thickest wall matches it.
A building-level demand (`shared_demand`) gives that thickness to every wall.
A local demand gives it only to groups that contain `driver`.
"""
function _agrees_with_shared(walls, trials, result; driver::Int, shared_demand::Bool, t_min, t_max)
    before = _meters(w.thickness for w in walls)
    base = _meters(propose_wall_thicknesses(walls, trials, result))
    @test all(t -> isapprox(t, base[1]; atol=1e-9), base)
    @test t_min - 1e-9 <= base[1] < t_max
    for grouping in WALL_THICKNESS_GROUPINGS
        @testset "$grouping" begin
            got = _meters(propose_wall_thicknesses(walls, trials, result; grouping))
            @test maximum(got) ≈ base[1] atol=1e-9
            part = wall_thickness_groups(walls; grouping)
            if shared_demand
                @test all(t -> isapprox(t, base[1]; atol=1e-9), got)
            else
                with = part[driver]
                for i in eachindex(got)
                    expect = part[i] == with ? base[1] : before[i]
                    @test got[i] ≈ expect atol=1e-9
                end
            end
        end
    end
    @test _meters(w.thickness for w in walls) ≈ before atol=1e-12
end

const _LAYOUTS = (:parallel, :collinear, :stack)

@testset "Groupings agree with one shared thickness" begin
    inch = ustrip(u"m", 1.0u"inch")
    geometric = ceil((0.144 - 1e-9) / inch) * inch
    @testset "$layout, minimum thickness" for layout in _LAYOUTS
        walls = _placed_walls(layout; thickness=0.1016)
        trials = [_scale_refused_trial(w) for w in walls]
        thin = _jump_record(
            "bearing wall (§11.5.3): thickness below minimum",
            0.144 / 0.1016, 0.144, 0.1016)
        _agrees_with_shared(walls, trials, _jump_result([thin]);
                            driver=1, shared_demand=false,
                            t_min=geometric, t_max=geometric + 1e-4)
    end

    @testset "$layout, shear over the cap" for layout in _LAYOUTS
        walls = _placed_walls(layout)
        trials = _shear_trials(walls)
        shear = _jump_record("in-plane shear", 1.25, 1.25e5, 1.0e5)
        _agrees_with_shared(walls, trials, _jump_result([shear]);
                            driver=1, shared_demand=false,
                            t_min=1.25 * 0.20, t_max=0.40)
    end

    @testset "$layout, story drift" for layout in _LAYOUTS
        walls = _placed_walls(layout)
        trials = [_modest_trial(w) for w in walls]
        drift = [SeismicStoryDriftCheck(1, :X, :none, 0.020, 0.010, false)]
        _agrees_with_shared(walls, trials, _jump_result(WallCheckRecord[]; drift);
                            driver=1, shared_demand=true, t_min=0.40, t_max=0.60)
    end

    @testset "$layout, interactive story shear" for layout in _LAYOUTS
        walls = _placed_walls(layout)
        trials = [_modest_trial(w) for w in walls]
        story = _jump_record("interactive wall shear", 1.5, 1.5e5, 1.0e5)
        _agrees_with_shared(walls, trials, _jump_result([story]);
                            driver=1, shared_demand=true, t_min=0.30, t_max=0.50)
    end
end

@testset "Drift multiplies each group from the thickness it has" begin
    walls = _placed_walls(:parallel)
    walls[2].thickness = 0.30u"m"
    trials = [_modest_trial(w) for w in walls]
    drift = [SeismicStoryDriftCheck(1, :X, :none, 0.020, 0.010, false)]
    result = _jump_result(WallCheckRecord[]; drift)
    inch = ustrip(u"m", 1.0u"inch")
    next_inch(t0) = ceil((2 * t0 - 1e-9) / inch) * inch
    for grouping in WALL_THICKNESS_GROUPINGS
        @testset "$grouping" begin
            ids = wall_thickness_groups(walls; grouping)
            merged = ids[1] == ids[2]
            if merged && grouping !== :all
                @test_throws ArgumentError propose_wall_thicknesses(
                    walls, trials, result; grouping)
            elseif grouping === :all
                ts = _meters(propose_wall_thicknesses(walls, trials, result; grouping))
                @test ts ≈ [0.20, 0.30] atol=1e-9
            else
                ts = _meters(propose_wall_thicknesses(walls, trials, result; grouping))
                @test ts[1] ≈ next_inch(0.20) atol=1e-6
                @test ts[2] ≈ next_inch(0.30) atol=1e-6
                @test ts[1] / 0.20 >= 2 - 1e-6
                @test ts[2] / 0.30 >= 2 - 1e-6
            end
        end
    end
    @test ustrip(u"m", walls[1].thickness) ≈ 0.20 atol=1e-12
    @test ustrip(u"m", walls[2].thickness) ≈ 0.30 atol=1e-12
end

@testset "A passing mixed group keeps the thicknesses it has" begin
    walls = _placed_walls(:parallel)
    walls[2].thickness = 0.30u"m"
    trials = [_modest_trial(w) for w in walls]
    ok = _jump_record("in-plane shear", 0.4, 4.0e4, 1.0e5; passed=true)
    result = _jump_result([ok])
    for grouping in WALL_THICKNESS_GROUPINGS
        ts = _meters(propose_wall_thicknesses(walls, trials, result; grouping))
        @test ts ≈ [0.20, 0.30] atol=1e-12
    end
end

@testset "A passing analysis proposes the thickness it has" begin
    walls = _placed_walls(:parallel)
    saved = _meters(w.thickness for w in walls)
    trials = [_modest_trial(w) for w in walls]
    ok = _jump_record("in-plane shear", 0.4, 4.0e4, 1.0e5; passed=true)
    result = _jump_result([ok])
    for grouping in WALL_THICKNESS_GROUPINGS
        @test _meters(propose_wall_thicknesses(walls, trials, result; grouping)) ≈ saved atol=1e-12
    end
end

@testset "Mixed thicknesses stay put for :all and split where the grouping does" begin
    walls = _placed_walls(:parallel; thickness=0.1016)
    walls[2].thickness = 0.30u"m"
    trials = [_scale_refused_trial(w) for w in walls]
    thin = _jump_record(
        "bearing wall (§11.5.3): thickness below minimum",
        0.144 / 0.1016, 0.144, 0.1016)
    result = _jump_result([thin])
    inch = ustrip(u"m", 1.0u"inch")
    jumped = ceil((0.144 - 1e-9) / inch) * inch
    for grouping in WALL_THICKNESS_GROUPINGS
        @testset "$grouping" begin
            ids = wall_thickness_groups(walls; grouping)
            if ids[1] == ids[2]
                if grouping === :all
                    ts = _meters(propose_wall_thicknesses(walls, trials, result; grouping))
                    @test ts ≈ [0.1016, 0.30] atol=1e-9
                else
                    @test_throws ArgumentError propose_wall_thicknesses(
                        walls, trials, result; grouping)
                end
            else
                ts = _meters(propose_wall_thicknesses(walls, trials, result; grouping))
                @test ts[1] ≈ jumped atol=1e-9
                @test ts[2] ≈ 0.30 atol=1e-9
            end
        end
    end
end

function _shortfall_decision(gap)
    return StructuralSynthesizer.SpecialBoundaryDecision(
        true, false, :stress, true, :stress, :positive,
        0.0, 0.2, 0.2, 0.25, gap, 4.0, 4.0, false, nothing, nothing, nothing)
end

@testset "A boundary shortfall thickens that pier only" begin
    south = _jump_pier(; thickness=0.20, x2=5.0)
    north = _jump_pier(; thickness=0.20, y1=6.0, y2=6.0, x2=5.0)
    walls = [south, north]
    inch = ustrip(u"m", 1.0u"inch")
    function propose(boundary; grouping=:all, constraint=:soft)
        result = _jump_result(Dict{Int, Vector{WallCheckRecord}}(); boundary=boundary)
        return propose_wall_thicknesses(walls, WallThicknessTrial[], result;
                                        grouping, constraint)
    end
    quiet = propose(Dict(1 => _shortfall_decision(nothing)))
    @test ustrip.(u"m", quiet) ≈ [0.20, 0.20] atol=1e-9
    met = propose(Dict(1 => _shortfall_decision(0.0)))
    @test ustrip.(u"m", met) ≈ [0.20, 0.20] atol=1e-9
    # hu/16 is 0.05 m above this web. The next inch is this pier's alone.
    one = propose(Dict(1 => _shortfall_decision(0.05)))
    expect = ceil((0.25 - 1e-9) / inch) * inch
    @test ustrip(u"m", one[1]) ≈ expect atol=1e-9
    @test ustrip(u"m", one[2]) ≈ 0.20 atol=1e-9
    # A taller story's shortfall moves the same pier and leaves the other.
    taller = propose(Dict(1 => _shortfall_decision(0.30)))
    expect_tall = ceil((0.50 - 1e-9) / inch) * inch
    @test ustrip(u"m", taller[1]) ≈ expect_tall atol=1e-9
    @test ustrip(u"m", taller[2]) ≈ 0.20 atol=1e-9
    @test ustrip(u"m", taller[1]) > ustrip(u"m", one[1])
    # :all does not hand this pier's floor to its neighbor.
    spread = propose(Dict(2 => _shortfall_decision(0.05)); grouping=:pier)
    @test ustrip(u"m", spread[1]) ≈ 0.20 atol=1e-9
    @test ustrip(u"m", spread[2]) ≈ expect atol=1e-9
    # 40 in is past the 36 in catalog. Soft raises the limit; hard errors.
    gap40 = ustrip(u"m", 40.0u"inch") - 0.20
    grown = @test_logs (:warn, r"raising the limit to 48 in") match_mode=:any begin
        propose(Dict(1 => _shortfall_decision(gap40)))
    end
    @test ustrip(u"m", grown[1]) ≈ ustrip(u"m", 40.0u"inch") atol=1e-9
    @test ustrip(u"m", grown[2]) ≈ 0.20 atol=1e-9
    @test_throws ArgumentError propose(Dict(1 => _shortfall_decision(gap40));
                                       constraint=:hard)
    # Past the 72 in top, soft errors too.
    @test_throws ArgumentError propose(Dict(1 => _shortfall_decision(2.0)))
end
