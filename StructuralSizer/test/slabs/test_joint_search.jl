# Joint search over slab thickness, column sizes, and studs
# (docs/flat-plate-joint-sizing-plan.md). The scan is driven here with
# closures so its selection rules are tested without an analysis.

using Test
using Unitful
using StructuralSizer
const SS = StructuralSizer

@testset "Joint search" begin

    @testset "material objective matches the grid-search terms" begin
        c, s = NWC_4000, Rebar_60
        ρc, ρs = ustrip(u"kg/m^3", c.ρ), ustrip(u"kg/m^3", s.ρ)
        @test SS.material_objective(MinVolume(), 2.0, 0.1, c, s) ≈ 2.1
        @test SS.material_objective(MinWeight(), 2.0, 0.1, c, s) ≈ 2.0ρc + 0.1ρs
        @test SS.material_objective(MinCarbon(), 2.0, 0.1, c, s) ≈
              2.0ρc * ustrip(u"kgCO2e/kg", c.ecc) + 0.1ρs * ustrip(u"kgCO2e/kg", s.ecc)
        isnan(c.cost) && @test_throws ArgumentError SS.material_objective(MinCost(), 1.0, 0.0, c, s)
    end

    # A slab term that grows with h, and one column whose smallest passing
    # size falls as h grows: J(h) = 10h + c(h), c(h) = max(14, 60 − 16(h − 8)).
    # J falls to 124 at h = 11, where the column reaches 14, then rises.
    hs = collect(8.0:0.5:13.0)
    col_size(h) = max(14.0, 60.0 - 16.0 * (h - 8.0))
    slab(h) = 10.0 * h

    @testset "picks the lowest total on the staircase" begin
        r = SS.joint_thickness_scan(hs; lower_bound = slab, slab_term = slab,
                                    column_terms = h -> [(c = col_size(h), cost = col_size(h))])
        J = [slab(h) + col_size(h) for h in hs]
        @test r.best.h == hs[argmin(J)]
        @test r.best.J ≈ minimum(J)
        @test isempty(r.rejected)
    end

    @testset "stops once the slab alone exceeds the best total" begin
        seen = Float64[]
        r = SS.joint_thickness_scan(hs; lower_bound = slab,
                                    slab_term = h -> (push!(seen, h); slab(h)),
                                    column_terms = h -> [(cost = col_size(h),)])
        # Best J = 124 at 11. The slab alone is 130 at 13, past 124 × 1.01.
        @test maximum(seen) == 12.5
        @test r.best.h == 11.0
    end

    @testset "slab and column failures are rejected, not chosen" begin
        r = SS.joint_thickness_scan(hs; lower_bound = slab,
                                    slab_term = h -> h < 9.0 ? nothing : slab(h),
                                    column_terms = h -> h < 10.0 ? nothing : [(cost = col_size(h),)])
        @test r.best.h >= 10.0
        @test count(x -> x.reason === :slab, r.rejected) == 2
        @test count(x -> x.reason === :columns, r.rejected) == 2
        none = SS.joint_thickness_scan(hs; lower_bound = slab, slab_term = _ -> nothing,
                                       column_terms = _ -> nothing)
        @test none.best === nothing
    end

    @testset "near-ties go to the preferred candidate" begin
        # 100.0 and 100.5 differ by 0.5 %, inside the 1 % tolerance.
        cost = Dict(8.0 => 100.5, 8.5 => 100.0, 9.0 => 120.0)
        terms = h -> [(cost = cost[h],)]
        args = (lower_bound = _ -> 0.0, slab_term = _ -> 0.0, column_terms = terms)
        @test SS.joint_thickness_scan([8.0, 8.5, 9.0]; args...).best.h == 8.5
        prefer8 = SS.joint_thickness_scan([8.0, 8.5, 9.0]; args...,
                                          preference = c -> c.h == 8.0 ? 1 : 0)
        @test prefer8.best.h == 8.0
        strict = SS.joint_thickness_scan([8.0, 8.5, 9.0]; args..., tie_rtol = 0.0,
                                         preference = c -> c.h == 8.0 ? 1 : 0)
        @test strict.best.h == 8.5
    end

    @testset "options" begin
        o = FlatPlateOptions()
        @test o.objective isa MinCarbon
        @test o.joint_studs
        @test o.stud_weight == 1.0
        @test o.punching_strategy === :grow_columns
        j = FlatPlateOptions(punching_strategy = :joint_search, joint_studs = false,
                             stud_weight = 3.0, objective = MinVolume())
        @test j.punching_strategy === :joint_search
        @test !j.joint_studs && j.stud_weight == 3.0 && j.objective isa MinVolume
        @test_throws ArgumentError FlatPlateOptions(stud_weight = -1.0)
        fs = FlatSlabOptions(base = FlatPlateOptions(punching_strategy = :joint_search))
        @test fs.base.punching_strategy === :joint_search
    end

    @testset "stud steel and column terms" begin
        studs = SS.ShearStudDesign(required = true, n_rails = 8, n_studs_per_rail = 6,
                                   Av_per_line = 8 * π / 4 * (0.5u"inch")^2)
        h, cover = 10.0u"inch", 0.75u"inch"
        @test SS._joint_stud_volume(studs, h, cover) ≈
              ustrip(u"m^2", studs.Av_per_line) * 6 * ustrip(u"m", h - 2cover)
        @test SS._joint_stud_volume(nothing, h, cover) == 0.0
    end
end
