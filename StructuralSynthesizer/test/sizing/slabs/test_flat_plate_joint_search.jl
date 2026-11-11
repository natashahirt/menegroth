# End-to-end `punching_strategy = :joint_search` on a 3×3 flat plate with
# 30 ft bays and small starting columns, so punching needs a remedy.
# docs/flat-plate-joint-sizing-plan.md

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer
const _SZ = StructuralSizer

function _joint_fixture(opts; c0 = 12.0u"inch")
    skel = gen_medium_office(90.0u"ft", 90.0u"ft", 12.0u"ft", 3, 3, 1)
    struc = BuildingStructure(skel)
    initialize!(struc; floor_type = :flat_plate, floor_opts = opts)
    for col in struc.columns
        col.c1 = c0
        col.c2 = c0
    end
    return struc, first(struc.slabs)
end

function _joint_run(; kw...)
    opts = FlatPlateOptions(; method = DDM(), kw...)
    struc, slab = _joint_fixture(opts)
    tc = _SZ.TraceCollector()
    r = _SZ.size_flat_plate!(struc, slab, ConcreteColumnOptions();
                             method = DDM(), opts = opts, verbose = false, tc = tc)
    details = r.slab_result === nothing ? Dict() : r.slab_result.punching_check.details
    studs = count(d -> get(d, :studs, nothing) !== nothing, values(details))
    scans = [e for e in tc.events if get(e.data, "outcome", "") == "joint_search"]
    sizes = sort(unique(ustrip(u"inch", c.c1) for c in struc.columns))
    return (r = r, details = details, studs = studs, scans = scans, sizes = sizes)
end

@testset "Flat-plate joint search" begin
    grow = _joint_run(punching_strategy = :grow_columns)
    joint = _joint_run(punching_strategy = :joint_search)
    no_studs = _joint_run(punching_strategy = :joint_search, joint_studs = false)
    heavy = _joint_run(punching_strategy = :joint_search, stud_weight = 1e6)

    for (name, run) in (("grow", grow), ("joint", joint), ("no studs", no_studs),
                        ("stud weight 1e6", heavy))
        J = isempty(run.scans) ? NaN : run.scans[end].data["J"]
        @info "joint search fixture: $name" h_in = round(ustrip(u"inch", run.r.h_final), digits = 2) columns_in = string(run.sizes) studs = run.studs scans = length(run.scans) J = J iterations = run.r.iterations
    end

    @testset "every run converges and passes punching" begin
        for run in (grow, joint, no_studs, heavy)
            @test run.r.converged
            @test !isempty(run.details)
            @test all(d -> d.ok && d.ratio <= 1.0 + 1e-9, values(run.details))
        end
    end

    @testset "the search ran and its choice was confirmed" begin
        for run in (joint, no_studs, heavy)
            @test !isempty(run.scans)
            @test all(e -> e.data["n_feasible"] >= 1, run.scans)
        end
        @test isempty(grow.scans)
    end

    @testset "stud switch and weight" begin
        @test no_studs.studs == 0
        @test heavy.studs == 0
        # Both first scans read the same Phase A analysis, and allowing studs
        # only adds options, so its best objective is no higher.
        @test joint.scans[1].data["J"] <= no_studs.scans[1].data["J"] + 1e-9
    end

    @testset "non-stud reinforcement is refused while studs are on" begin
        opts = FlatPlateOptions(method = DDM(), punching_strategy = :joint_search,
                                punching_reinforcement = :closed_stirrups)
        struc, slab = _joint_fixture(opts)
        @test_throws ArgumentError _SZ.size_flat_plate!(
            struc, slab, ConcreteColumnOptions(); method = DDM(), opts = opts)
    end
end
