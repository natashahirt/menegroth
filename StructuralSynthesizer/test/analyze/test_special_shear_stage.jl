# Special-wall shear on rows A1 and B4: Ve = Ωv ωv Vu ≤ 3Vu (ACI 318-19
# §18.10.3.1, page 323), φ = 0.60 below the shear at Mn (§21.2.4.1, page 398),
# and ρl ≥ ρt when hw/ℓw ≤ 2 (§18.10.4.3, page 324).

using Test
using Unitful
using Meshes
using StructuralSynthesizer

const _SS = StructuralSynthesizer
const _SS_EQ = :strength_1_2D_1_0E

_ss_action(combination, N, M, V) = _SS.CombinedWallAction(combination, :only, N, V, M)

function _ss_terms(; Ωv=1.0, ωv=1.0, φ_fixed=nothing, at_Mn=Inf, hw=4.0, hwcs=4.0, lw=6.0)
    return _SS.SpecialShearTerms(Ωv, ωv, false, φ_fixed, at_Mn, hw, hwcs, lw)
end

function _ss_wall(; thick=0.3, lw=6.0)
    return Wall([1], 4.0u"m"; thickness=thick * u"m", x1=0.0, y1=0.0, x2=lw, y2=0.0, story=0)
end

@testset "Ve is Ωv ωv Vu on earthquake combinations, not above 3 Vu" begin
    terms = _ss_terms(; Ωv=1.5, ωv=1.23)
    @test _SS.special_shear_demand(terms, _ss_action(_SS_EQ, 0.0, 1.0, 100.0)) ≈ 184.5
    @test _SS.special_shear_demand(terms, _ss_action(_SS_EQ, 0.0, 1.0, -100.0)) ≈ 184.5
    # A wind combination keeps Vu.
    @test _SS.special_shear_demand(terms, _ss_action(:strength_1_2D_1_0W, 0.0, 1.0, 100.0)) ≈ 100.0
    capped = _ss_terms(; Ωv=2.5, ωv=1.5)
    @test _SS.special_shear_demand(capped, _ss_action(_SS_EQ, 0.0, 1.0, 100.0)) ≈ 300.0
end

@testset "φ is 0.60 below the shear at Mn and 0.75 at it" begin
    terms = _ss_terms(; at_Mn=1000.0)
    @test _SS.special_shear_phi(terms, 999.0) == 0.60
    @test _SS.special_shear_phi(terms, 1000.0) == 0.75
    @test _SS.special_shear_phi(_ss_terms(; φ_fixed=0.75, at_Mn=1e12), 1.0) == 0.75
    @test _SS.special_shear_phi(_ss_terms(; φ_fixed=0.60, at_Mn=0.0), 1e12) == 0.60
end

@testset "The shear at Mn reads Mn,max and the largest V/M over earthquake combinations" begin
    wall = _ss_wall()
    fc = ustrip(u"Pa", RC_4000_60.concrete.fc′)
    fy = ustrip(u"Pa", RC_4000_60.rebar.Fy)
    Es = ustrip(u"Pa", RC_4000_60.rebar.E)
    Ast = wall.ρl * 6.0 * 0.3
    actions = [_ss_action(_SS_EQ, 1.0e6, 2.0e6, 5.0e5),
               _ss_action(:strength_0_9D_1_0E, 5.0e5, 1.0e6, 4.0e5),
               # Wind is not read, however large its V/M.
               _ss_action(:strength_1_2D_1_0W, 1.0e6, 1.0e3, 9.0e5)]
    Mn = maximum(StructuralSizer.wall_moment_capacity_at_axial_si(
        fc, fy, Es, 6.0, 0.3, Ast, a.N).Mn for a in actions[1:2])
    @test _SS._shear_at_nominal_moment(wall, 6.0, actions, fc, fy, Es) ≈ Mn * 0.4
    # No moment: the comparison cannot pass, so φ stays 0.60.
    @test _SS._shear_at_nominal_moment(
        wall, 6.0, [_ss_action(_SS_EQ, 1.0e6, 0.0, 5.0e5)], fc, fy, Es) == Inf
end

@testset "ρt rises to the lightest grid ratio, and a squat pier carries ρl ≥ ρt" begin
    material = RC_4000_60
    # 4 MN on a 6 m × 0.3 m pier needs ρt near 0.004 at φ = 0.75.
    actions = [_ss_action(_SS_EQ, 1.0e6, 1.0e6, 4.0e6)]
    function raised(terms)
        wall = _ss_wall()
        _SS._raise_for_special_shear!(wall, terms, actions, material)
        return wall
    end
    at75 = raised(_ss_terms(; φ_fixed=0.75))
    @test at75.ρt > 0.0025
    @test _SS._special_shear_covers(_ss_terms(; φ_fixed=0.75), at75, at75.ρt, actions, material)
    lower = filter(r -> r < at75.ρt - 1e-12, _SS.ORDINARY_WALL_RHO_GRID)
    @test !_SS._special_shear_covers(_ss_terms(; φ_fixed=0.75), at75, last(lower), actions, material)
    # hw/ℓw = 4/6 ≤ 2.
    @test at75.ρl >= at75.ρt - 1e-12
    # Below the shear at Mn, φ = 0.60 needs more steel.
    at60 = raised(_ss_terms(; at_Mn=1e12))
    @test at60.ρt > at75.ρt
    # Ve twice Vu needs more again.
    doubled = raised(_ss_terms(; φ_fixed=0.75, Ωv=2.0))
    @test doubled.ρt > at75.ρt
    # A slender pier does not take the §18.10.4.3 floor.
    tall = raised(_ss_terms(; φ_fixed=0.75, hw=16.0, hwcs=16.0))
    @test tall.ρl < tall.ρt
end

@testset "A vertical segment takes the greater hw/ℓw and its own Ve" begin
    wall = _ss_wall(; lw=2.0)
    material = RC_4000_60
    # Segment 2 m × 1 m (ratio 0.5). Entire wall 2 m × 4 m (ratio 2).
    # Stack is short, so Table 18.10.3.1.2 sets Ωv = 1.
    short = _SS.segment_special_shear_terms(
        wall, [_ss_action(_SS_EQ, 1.0e6, 1.0e6, 1.0e5)], material,
        2.0, 1.0, 2.0, 4.0, 2.0, 1)
    @test short.Ωv == 1.0
    @test short.ωv == 1.0
    @test short.hw_m / short.lw_m ≈ 2.0
    @test short.hwcs_m / short.lw_m ≈ 0.5
    fc = ustrip(u"Pa", material.concrete.fc′)
    fyt = ustrip(u"Pa", material.transverse.Fy)
    @test wall_shear_capacity_si(fc, fyt, short.lw_m, 0.3, wall.ρt, short.hw_m;
                                 λ=material.concrete.λ).αc == 2.0
    # A 12 m stack over a 2 m segment is past 1.5, so Ωv is at least 1.5
    # and ωv leaves 1.
    tall = _SS.segment_special_shear_terms(
        wall, [_ss_action(_SS_EQ, 1.0e6, 2.0e6, 5.0e5)], material,
        2.0, 1.0, 6.0, 12.0, 12.0, 3)
    @test tall.Ωv >= 1.5
    @test tall.ωv > 1.0
    @test _SS.special_shear_demand(tall, _ss_action(_SS_EQ, 0.0, 1.0, 100.0)) ≈
        min(tall.Ωv * tall.ωv * 100.0, 300.0)
    @test_throws ArgumentError _SS.segment_special_shear_terms(
        wall, [_ss_action(_SS_EQ, 1.0e6, 2.0e6, 5.0e5)], material,
        2.0, 1.0, 6.0, 12.0, 12.0, 3; flanged=true)
end

"""Three stories, 5×6 m, a stacked wall on each 5 m line: hw/ℓw = 2.4."""
function _ss_slender_office()
    skel = gen_medium_office(5.0u"m", 6.0u"m", 4.0u"m", 1, 2, 3)
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    xy(v) = (c = Meshes.coords(skel.vertices[v]); (ustrip(u"m", c.x), ustrip(u"m", c.y), ustrip(u"m", c.z)))
    function plan(e)
        v1, v2 = skel.edge_indices[e]
        a, b = xy(v1), xy(v2)
        return a, b
    end
    level(e) = (p = plan(e); abs(p[1][3] - p[2][3]) <= 1e-6)
    len(e) = (p = plan(e); hypot(p[2][1] - p[1][1], p[2][2] - p[1][2]))
    for story in 0:2
        edges = [e for e in skel.stories[story].edges if e in beams && level(e)]
        longest = maximum(len, edges)
        for e in edges
            len(e) + 1e-6 < longest && continue
            filter!(!=(e), skel.groups_edges[:beams])
            delete!(beams, e)
            walls = get!(skel.groups_edges, :walls, Int[])
            e in walls || push!(walls, e)
        end
    end
    struc = BuildingStructure(skel)
    initialize!(struc; floor_type=:vault, material=NWC_4000,
                floor_opts=VaultOptions(rise=1.0u"m", thickness=0.05u"m"),
                wall_thickness=0.3u"m")
    for wall in struc.walls
        wall.concrete = RC_4000_60.concrete
    end
    return struc
end

function _ss_params(row)
    inputs = OrdinaryWallInputs(;
        directions=((1.0, 0.0), (0.0, 1.0)),
        qz=[1.0, 1.5, 2.0], qh=2.0, Kd=1.0, G=0.85, GCpi=0.18,
        roof=:Lr, method=:sds, SDS=0.20, S1=0.02, Ie=1.0, T=0.4, β=1.0,
        SD1=0.08, TL=8.0, rho=1.0, sdc=:B, risk_category=:II,
        drift_system=:other, boundary=:pinned, material=RC_4000_60,
        model_uses_cracked_section_stiffness=true,
        sustained_lateral_loads=false, sustained_lateral_divisor_applied=false,
        type1_horizontal_irregularity=false, type5_horizontal_irregularity=false,
        orthogonal_combination=false, orthogonal_12_5_4_conditions_absent=false,
        ax_applied_to_accidental_torsion=false, pdelta_included_in_member_forces=false)
    return DesignParameters(
        lateral=LateralDesign(; system=WallsSeismicSystem(row), assignment=BuildingUnit()),
        wall_inputs=inputs, skip_visualization=true, jump_wall_thickness=false)
end

_ss_factor(clause, name) = parse(Float64, match(Regex("$name = ([0-9.]+)"), clause).captures[1])

@testset "A slender special line is designed for Ve, with Ωv from its base" begin
    function run(row)
        struc = _ss_slender_office()
        params = _ss_params(row)
        to_asap!(struc; params=params, diaphragms=:rigid)
        result = design_ordinary_walls!(struc, params)
        return struc, result
    end
    ordinary, a3 = run(:A3)
    special, a1 = run(:A1)
    # Three 5 m lines (y = 0, 3, 6 m), three stories each.
    @test length(special.walls) == 9
    @test !any(r -> r.check == _SS.SPECIAL_WALL_SHEAR_CHECK, reduce(vcat, values(a3.checks)))
    # hwcs = 12 m = 472.4 in., so ns = 0.007 hwcs = 3.307 > 3 stories.
    ωv = 0.9 + 0.007 * ustrip(u"inch", 12.0u"m") / 10
    for (i, wall) in enumerate(special.walls)
        records = a1.checks[i]
        shear = [r for r in records if r.check == _SS.SPECIAL_WALL_SHEAR_CHECK]
        @test !isempty(shear)
        @test all(r -> r.passed, shear)
        clause = first(shear).clause
        @test _ss_factor(clause, "ωv") ≈ round(ωv; digits = 3)
        @test _ss_factor(clause, "Ωv") >= 1.5
        # Every pier of the line takes the base Ωv.
        line = _SS.wall_line_members(wall, special.walls)
        base = findfirst(w -> w === line[1], special.walls)
        base_clause = first(r for r in a1.checks[base] if r.check == _SS.SPECIAL_WALL_SHEAR_CHECK).clause
        @test _ss_factor(clause, "Ωv") == _ss_factor(base_clause, "Ωv")
        # The base is on §18.10.6.2, so §21.2.4.1 does not apply there.
        wall.story == 0 && @test occursin("φ = 0.75", clause)
        # Ve against the same combination's Vu from the ordinary record.
        Ω = _ss_factor(clause, "Ωv")
        for r in shear
            r.combination in _SS._BOUNDARY_EARTHQUAKE || continue
            vu = only(o.demand for o in records
                      if o.check == "in-plane shear" && o.case === r.case &&
                         o.combination === r.combination && o.alternative === r.alternative)
            @test r.demand ≈ min(Ω * ωv * vu, 3 * vu) rtol = 2e-3
            @test r.demand > vu
        end
    end
    # §18.10.2.4 at the base: hw/ℓw = 2.4, continuous, one critical section.
    bases = [i for (i, w) in enumerate(special.walls) if w.story == 0]
    @test length(bases) == 3
    for i in bases
        bars = a1.end_bars[i]
        @test bars.from_ratio
        @test bars.bar in 5:11
        @test bars.extension_m >= 5.0 - 1e-6
        @test bars.layers >= 2
        flexure = [r for r in a1.checks[i] if r.check == "in-plane axial-flexure (P-M)"]
        @test all(r -> r.passed, flexure)
    end
end
