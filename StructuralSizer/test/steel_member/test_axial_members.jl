# ==============================================================================
# Axial-Member Sizer Tests (size_axial_members)
# ==============================================================================
# Pure axial steel members (braces / truss chords / struts / ties).
#   - Compression → AISC 360-16 Chapter E (buckling).
#   - Tension     → AISC 360-16 Chapter D §D2.
# The sizer is a thin adapter over the steel `size_columns` path; these tests
# exercise the engineering contract (brace_type → demand mapping, :nlp+tension
# guard, unit acceptance), not the capacity math (covered elsewhere).

using Test
using StructuralSizer
using Unitful
using StructuralSizer: kip
import JuMP
const MOI = JuMP.MOI

_optimal(status) = status == MOI.OPTIMAL || status == MOI.TIME_LIMIT
_area_in2(section) = ustrip(u"inch^2", section_area(section))

@testset "Axial Member Sizing" begin

    # A long brace so Chapter E buckling clearly penalizes the compression case
    # relative to the same force carried in pure tension (no buckling).
    L = 6.0u"m"
    P = 200.0 * kip
    opts = SteelColumnOptions(section_type = :hss, catalog = :all)

    # --- Case 1 & 2: same magnitude + length, compression vs tension ----------
    @testset "Compression (Ch. E) is heavier than tension (Ch. D)" begin
        geom = [SteelMemberGeometry(L)]

        comp = size_axial_members([P], [0.0 * kip], geom, opts;
                                  brace_type = :compression_only)
        tens = size_axial_members([0.0 * kip], [P], geom, opts;
                                  brace_type = :tension_only)

        @test _optimal(comp.status)
        @test _optimal(tens.status)
        @test comp.sections[1] isa HSSRectSection
        @test tens.sections[1] isa HSSRectSection

        # Chapter E buckling over a 6 m length forces a larger section than
        # Chapter D tension yielding/rupture of the same demand.
        @test _area_in2(comp.sections[1]) > _area_in2(tens.sections[1])
    end

    # --- Case 3: :both takes the governing (compression) limit state ----------
    @testset ":both satisfies the governing limit state" begin
        geom = [SteelMemberGeometry(L)]

        comp = size_axial_members([P], [0.0 * kip], geom, opts;
                                  brace_type = :compression_only)
        both = size_axial_members([P], [P], geom, opts; brace_type = :both)

        @test _optimal(both.status)
        # With equal magnitudes, compression governs, so :both must be at least
        # as heavy as the compression-only design (never lighter).
        @test _area_in2(both.sections[1]) >= _area_in2(comp.sections[1]) - 1e-9
    end

    # --- Case 4: :nlp + tension must fail loudly ------------------------------
    @testset ":nlp with tension throws" begin
        geom = [SteelMemberGeometry(L)]
        nlp_opts = SteelColumnOptions(section_type = :w, sizing_strategy = :nlp)

        # :tension_only carries tension → no Chapter D on the NLP path.
        @test_throws ArgumentError size_axial_members(
            [0.0 * kip], [P], geom, nlp_opts; brace_type = :tension_only)
        # :both also carries tension.
        @test_throws ArgumentError size_axial_members(
            [P], [P], geom, nlp_opts; brace_type = :both)

        # A compression-only member has no tension → :nlp is allowed.
        comp_nlp = size_axial_members([P], [0.0 * kip], geom, nlp_opts;
                                      brace_type = :compression_only)
        @test comp_nlp.status === :nlp_complete
    end

    # --- Case 5: unit acceptance (kip vs kN) ----------------------------------
    @testset "Consistent results in kip and kN" begin
        geom = [SteelMemberGeometry(L)]
        P_kip = 200.0 * kip
        P_kN  = uconvert(u"kN", P_kip)   # same physical force, SI unit

        r_kip = size_axial_members([P_kip], [0.0 * kip], geom, opts;
                                   brace_type = :compression_only)
        r_kN  = size_axial_members([P_kN], [0.0u"kN"], geom, opts;
                                   brace_type = :compression_only)

        @test r_kip.section_indices == r_kN.section_indices
        @test _area_in2(r_kip.sections[1]) ≈ _area_in2(r_kN.sections[1])
    end

    # --- brace_type validation -------------------------------------------------
    @testset "brace_type validation" begin
        geom = [SteelMemberGeometry(L), SteelMemberGeometry(L)]
        Pc = [P, P]
        Pt = [0.0 * kip, 0.0 * kip]

        # Per-member vector of the wrong length is rejected.
        @test_throws ArgumentError size_axial_members(
            Pc, Pt, geom, opts; brace_type = [:both])
        # Unknown symbol is rejected.
        @test_throws ArgumentError size_axial_members(
            Pc, Pt, geom, opts; brace_type = :tension)
        # Mismatched demand lengths are rejected.
        @test_throws ArgumentError size_axial_members(
            [P], Pt, geom, opts; brace_type = :both)
    end
end
