# Finite-width FEA one-way shear cut.
#
# The July shell cut integrated every element in a longitudinal band, so a
# 3-bay mesh was compared with the one-bay frame-strip capacity. These
# oracles check the repaired integrator:
#   * uniform intensity recovers Vu = Q_n * cut length
#   * elements outside the frame width do not contribute
#   * signed intensities cancel before the resultant is taken
#   * splitting the mesh does not change the resultant
# The analytical demand still governs `check_one_way_shear`.

using Test
using Unitful
using Asap
using StructuralSizer

const SS = StructuralSizer

function _shear_elem(cx, cy, area, Qxz)
    SS.FEAElementData(cx, cy, area, 0.0, 0.0, 0.0, Qxz, 0.0, (1.0, 0.0), (0.0, 1.0))
end

"""One row of elements on the cut, filling the band of depth 2δ."""
function _uniform_row(; y_centers, spacing, δ, Q, x)
    area = spacing * (2 * δ)
    [_shear_elem(x, y, area, Q) for y in y_centers]
end

@testset "Finite-width one-way shear cut" begin
    δ = 0.25
    spacing = 0.5
    half_width = 2.5
    Q = 1000.0                 # N/m
    x_cut = 0.35               # c1/2 + d with c1 = 0.4, d = 0.15
    ys = collect(-2.25:spacing:2.25)
    elems = _uniform_row(; y_centers=ys, spacing, δ, Q, x=x_cut)
    cut = SS._integrate_one_way_shear_cut(
        elems, 0.0, 0.0, 0.4, 1.0, 0.0, 0.15, δ, half_width,
    )
    L = length(ys) * spacing
    @test cut.n_elements == length(ys)
    @test cut.Vu_N ≈ Q * L rtol = 1e-9

    # Outside the frame strip. The old cut would have added this bay.
    outside = _shear_elem(x_cut, 4.0, spacing * 2 * δ, Q)
    wide = SS._integrate_one_way_shear_cut(
        vcat(elems, outside), 0.0, 0.0, 0.4, 1.0, 0.0, 0.15, δ, half_width,
    )
    @test wide.Vu_N ≈ cut.Vu_N rtol = 1e-9
    @test wide.n_elements == cut.n_elements

    # Opposing signs cancel. An element-wise absolute value would double Vu.
    signed = vcat(
        _uniform_row(; y_centers=ys[1:5], spacing, δ, Q, x=x_cut),
        _uniform_row(; y_centers=ys[6:10], spacing, δ, Q=-Q, x=x_cut),
    )
    cancelled = SS._integrate_one_way_shear_cut(
        signed, 0.0, 0.0, 0.4, 1.0, 0.0, 0.15, δ, half_width,
    )
    @test cancelled.Vu_N < 1.0

    # Mesh refinement: each element split in two, same total force.
    fine_ys = collect(-2.375:spacing/2:2.375)
    fine = _uniform_row(; y_centers=fine_ys, spacing=spacing/2, δ, Q, x=x_cut)
    fine_cut = SS._integrate_one_way_shear_cut(
        fine, 0.0, 0.0, 0.4, 1.0, 0.0, 0.15, δ, half_width,
    )
    @test fine_cut.Vu_N ≈ cut.Vu_N rtol = 1e-6

    # Analytical frame-strip demand is the same number when Q_n = qu*(ℓn/2−d).
    qu = 200.0psf
    bw = (L) * u"m"
    ln = 20.0u"ft"
    d = 6.0u"inch"
    Vu_code = SS.one_way_shear_demand(qu, bw, ln, d)
    q_line = ustrip(u"N/m", qu * (ln / 2 - d))
    oracle = _uniform_row(; y_centers=ys, spacing, δ, Q=q_line, x=x_cut)
    oracle_cut = SS._integrate_one_way_shear_cut(
        oracle, 0.0, 0.0, 0.4, 1.0, 0.0, 0.15, δ, half_width,
    )
    @test oracle_cut.Vu_N ≈ ustrip(u"N", Vu_code) rtol = 1e-6
end

@testset "Analytical one-way shear governs" begin
    moment_results = (l2 = 20.0u"ft", ln = 18.0u"ft", qu = 200.0psf,
                      M_neg_ext = 40.0kip * u"ft", M_neg_int = 80.0kip * u"ft")
    fea_only = SS.check_one_way_shear(
        moment_results, 6.0u"inch", 4000.0u"psi";
        h = 7.0u"inch", fy = 60.0u"ksi", fea_Vu = 500.0u"kip",
    )
    plain = SS.check_one_way_shear(moment_results, 6.0u"inch", 4000.0u"psi";
                                   h = 7.0u"inch", fy = 60.0u"ksi")
    @test fea_only.source == :analytical
    @test fea_only.Vu ≈ plain.Vu
    @test fea_only.ratio ≈ plain.ratio
    @test fea_only.Vu_fea ≈ 500.0u"kip"
    @test fea_only.ok == plain.ok
end

@testset "Governing-check labels" begin
    @test SS._governing_check_label("", nothing) == "table_minimum"
    @test SS._governing_check_label("", 5.0u"inch") == "search_floor"
    @test SS._governing_check_label("one_way_shear", 2.0u"inch") == "one_way_shear"
end
