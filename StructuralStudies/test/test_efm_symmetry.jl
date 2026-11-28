# Column demands on a symmetric 3×3 bay of 20 ft squares.
# Guards the EFM frame-line split: a whole floor once solved as one 15-span
# beam, which gave corner columns unbalanced moments that differed by 2×.
# Each column class must carry one value per direction, and the two
# directions must mirror each other.

using Test

include(joinpath(@__DIR__, "..", "src", "flat_plate_methods",
                 "flat_plate_method_comparison.jl"))

const SYM_RTOL = 0.02

base  = _make_params(; concrete_label = "NWC_4000", max_col_in = _resolve_max_col(20.0))
struc = BuildingStructure(_build_skeleton(20.0, 20.0, _adaptive_story_ht(20.0), 3))
prepare!(struc, base)
_set_live_load!(struc, 150.0)

slab = struc.slabs[1]
cols = SR.find_supporting_columns(struc, Set(slab.cell_indices))
h    = 9.0u"inch"
fc   = SR.NWC_4000.fc′
γ    = SR.NWC_4000.ρ
Ecs  = SR.Ec(fc, ustrip(SR.pcf, γ))

"""Column centre (x, y) in ft, rounded to the grid."""
function _col_xy(c)
    v  = struc.skeleton.vertices[c.vertex_idx]
    cc = getfield(parentmodule(typeof(v)), :coords)(v)
    return round.(ustrip.(u"ft", (cc.x, cc.y)))
end

"""Unbalanced moments (k·ft) by class: corners, edges at x = 0/60, edges at y = 0/60, interior."""
function _mub_classes(res)
    out = Dict(k => Float64[] for k in (:corner, :edge_x, :edge_y, :interior))
    for (i, c) in enumerate(cols)
        x, y = _col_xy(c)
        on_x = x in (0.0, 60.0)
        on_y = y in (0.0, 60.0)
        k = on_x && on_y ? :corner : on_x ? :edge_x : on_y ? :edge_y : :interior
        push!(out[k], ustrip(SR.kip * u"ft", res.unbalanced_moments[i]))
    end
    return out
end

_uniform(v) = !isempty(v) && (maximum(v) - minimum(v)) <= SYM_RTOL * maximum(abs.(v))

@testset "Symmetric bay: column demands" begin
    @test length(cols) == 16

    for (name, m) in [("EFM Hardy Cross", SR.EFM(solver = :hardy_cross, pattern_loading = true)),
                      ("EFM ASAP",        SR.EFM(solver = :asap, pattern_loading = true)),
                      ("DDM",             SR.DDM(:full))]
        @testset "$name" begin
            px = _mub_classes(SR.run_moment_analysis(m, struc, slab, cols, h, fc, Ecs, γ))
            py = _mub_classes(SR.run_secondary_moment_analysis(m, struc, slab, cols, h, fc, Ecs, γ))

            for k in keys(px)
                @test length(px[k]) == 4
                @test _uniform(px[k])
                @test _uniform(py[k])
            end
            # The two directions mirror each other
            @test isapprox(px[:corner][1],   py[:corner][1];   rtol = SYM_RTOL)
            @test isapprox(px[:interior][1], py[:interior][1]; rtol = SYM_RTOL)
            @test isapprox(px[:edge_x][1],   py[:edge_y][1];   rtol = SYM_RTOL)
            @test isapprox(px[:edge_y][1],   py[:edge_x][1];   rtol = SYM_RTOL)
            # Perimeter columns carry real transfer moment, not a fake-beam remnant
            @test minimum(px[:corner]) > 0.3 * maximum(px[:edge_x])
        end
    end
end
