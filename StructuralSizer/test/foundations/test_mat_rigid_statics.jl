# Bowles 5th ed. §9-2: a rigid strip is a combined footing. Soil pressure
# is uniform and upward; column loads are downward point loads. The moment
# between the columns is negative (top steel). The moment in the column
# region is positive (bottom steel).
# corpus: textbook-bowles-foundation-analysis-design-5e, PDF pages 502–504.

using StructuralSizer
using Test
using Unitful

const SS = StructuralSizer

@testset "rigid strip moments from the shear diagram" begin
    # L = 20 ft, width = 10 ft, columns 100 kip at 2 ft and 18 ft.
    # qu = 200 kip / 200 ft² = 1 ksf, so w = 10 kip/ft.
    # M(10) = 10*(10)^2/2 − 100*(10−2) = −300 kip·ft.
    # M(2)  = 10*(2)^2/2 = 20 kip·ft.
    L = 20.0u"ft"
    width = 10.0u"ft"
    qu = 1.0ksf
    stations = [2.0u"ft", 18.0u"ft"]
    loads = [100.0kip, 100.0kip]
    mom = SS._rigid_mat_strip_moments(qu, L, width, stations, loads)
    @test ustrip(kip * u"ft", mom.M_neg) ≈ 300.0 rtol = 0.02
    @test ustrip(kip * u"ft", mom.M_pos) ≈ 20.0 rtol = 0.05
    @test mom.M_neg > mom.M_pos

    diag = SS._strip_VM_diagram(L, width, qu, stations, loads)
    @test abs(diag.M_kipft[end]) < 1.0
    @test abs(diag.V_kip[end]) < 1.0
end
