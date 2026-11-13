# RC column groups are sized on each member's concurrent pattern cases. The
# group envelope (largest P with largest M, from different members or cases)
# is not a load state and is used only when a group has no case rows.

using StructuralSynthesizer
using StructuralSizer
using Asap
using Test
using Unitful

const _CS = StructuralSynthesizer
const _CZ = StructuralSizer

_cs_N(kip) = ustrip(u"N", kip * Asap.kip)
_cs_Nm(kipft) = ustrip(u"N*m", kipft * Asap.kip * u"ft")

"""Group envelope and two case rows: high axial with a small moment, low axial with a large one."""
function _cs_group(P_hi, M_lo, P_lo, M_hi)
    env = _CZ.MemberDemand(1; Pu_c = _cs_N(P_hi), Mux = _cs_Nm(M_hi),
                           M1x = 0.0, M2x = _cs_Nm(M_hi))
    rows = [_CS.ColumnCaseRow(_cs_N(P_hi), _cs_Nm(M_lo), 0.0, 0.0, _cs_Nm(M_lo), 0.0, 0.0),
            _CS.ColumnCaseRow(_cs_N(P_lo), _cs_Nm(M_hi), 0.0, 0.0, _cs_Nm(M_hi), 0.0, 0.0)]
    return env, rows
end

@testset "RC column sets are the concurrent case rows" begin
    opts = ConcreteColumnOptions(material = NWC_4000, rebar_material = Rebar_60)
    env, rows = _cs_group(600.0, 20.0, 60.0, 200.0)

    set = only(_CS._rc_column_demand_sets([env], [rows], opts))
    @test length(set.cases) == 2
    @test [c.Pu for c in set.cases] ≈ [600.0, 60.0]
    @test [c.Mux for c in set.cases] ≈ [20.0, 200.0]
    @test [c.M2x for c in set.cases] ≈ [20.0, 200.0]
    @test all(c -> c.βdns == opts.βdns, set.cases)

    # A group with no case rows falls back on the envelope.
    fallback = only(_CS._rc_column_demand_sets([env], [_CS.ColumnCaseRow[]], opts))
    @test length(fallback.cases) == 1
    @test only(fallback.cases).Pu ≈ 600.0
    @test only(fallback.cases).Mux ≈ 200.0

    # Without the envelope row the sizer can pick a lighter section that
    # still passes every real case; it never picks a heavier one.
    geoms = [_CZ.ConcreteMemberGeometry(3.0u"m")]
    obj = s -> _CZ.objective_value(opts.objective, s, opts.material, 1.0u"m")
    lighter = false
    for (P_hi, M_lo, P_lo, M_hi) in ((600.0, 20.0, 60.0, 200.0), (900.0, 30.0, 80.0, 300.0),
                                     (1400.0, 40.0, 120.0, 500.0))
        env, rows = _cs_group(P_hi, M_lo, P_lo, M_hi)
        cases = only(_CS._rc_column_demand_sets([env], [rows], opts))
        with_env = _CZ.RCColumnDemandSet(1, vcat(
            only(_CS._rc_column_demand_sets([env], [_CS.ColumnCaseRow[]], opts)).cases,
            cases.cases))
        s_new = only(_CZ.size_columns([cases], geoms, opts).sections)
        s_old = only(_CZ.size_columns([with_env], geoms, opts).sections)
        @test obj(s_new) <= obj(s_old) * (1 + 1e-9)
        obj(s_new) < obj(s_old) * (1 - 1e-9) && (lighter = true)
    end
    @test lighter
end
