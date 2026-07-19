# Tests for the (role, material, lateral_role) connection-default dispatch
# (StructuralSizer/src/members/defaults.jl + per-material specializations).
#
# Asserts every declared combination returns the plan-specified value, that
# undeclared combinations error with a helpful message, and that the steel-joist
# seat eccentricity is computed correctly (and unit-agnostically).

using Test
using Unitful
using StructuralSizer
using Asap  # units

@testset "Member connection defaults" begin
    steel = A992_Steel                     # StructuralSteel (Metal{StructuralSteelType})
    conc  = NWC_4000                        # Concrete
    # Minimal Timber instance (values irrelevant — only the type drives dispatch).
    tmb = Timber(:douglas_fir, :no1,
                 12.4e3u"MPa", 6.6e3u"MPa", 6.9u"MPa", 4.6u"MPa",
                 1.2u"MPa", 11.7u"MPa", 4.3u"MPa", 470.0u"kg/m^3", 0.31)

    @testset "Steel" begin
        # OWSJ: simple (pinned) seat connections — AISC 360-16 §B3.4a / §J1.2.
        @test default_release(:joist, steel, :gravity) === (:pinned, :pinned)
        @test default_release(:joist, steel) === (:pinned, :pinned)  # lateral_role default
        # Asap `:joist` (OWSJ-style: pinned bending, retained GJ) selected.
        @test default_torsion_released(:joist, steel) === true

        # Girder / beam: FR (moment) connections idealized as fixed — Cmt. §B3.4.
        @test default_release(:girder, steel, :gravity) === (:fixed, :fixed)
        @test default_release(:girder, steel, :moment_frame) === (:fixed, :fixed)
        @test default_release(:beam, steel, :gravity) === (:fixed, :fixed)
        @test default_torsion_released(:girder, steel) === false
        @test default_torsion_released(:beam, steel) === false
    end

    @testset "Concrete (monolithic)" begin
        # Cast-in-place RC is continuous with supports — ACI 318-11 §8.9.3.
        @test default_release(:joist, conc, :gravity) === (:fixed, :fixed)
        @test default_release(:girder, conc, :gravity) === (:fixed, :fixed)
        @test default_release(:beam, conc, :gravity) === (:fixed, :fixed)
        @test default_torsion_released(:joist, conc) === false
        @test default_torsion_released(:girder, conc) === false
        @test default_torsion_released(:beam, conc) === false
    end

    @testset "Timber" begin
        # Simple bearing / hanger connections (engineering judgment; NDS practice).
        @test default_release(:joist, tmb, :gravity) === (:pinned, :pinned)
        @test default_release(:girder, tmb, :gravity) === (:fixed, :fixed)
        @test default_release(:beam, tmb, :gravity) === (:fixed, :fixed)
        @test default_torsion_released(:joist, tmb) === false   # => :freefree
        @test default_torsion_released(:girder, tmb) === false
        @test default_torsion_released(:beam, tmb) === false
    end

    @testset "Seat eccentricity" begin
        # Steel joist on top of girder: transverse-y offset = (host + member)/2.
        # host_depth = 0.5 m, member_depth = 0.3 m -> (0, 0, 0.4, 0).
        e_unitful = default_seat_eccentricity(:joist, steel, 0.5u"m", 0.3u"m")
        @test e_unitful isa NTuple{4, Float64}
        @test e_unitful[1] == 0.0
        @test e_unitful[2] == 0.0
        @test e_unitful[3] ≈ 0.4
        @test e_unitful[4] == 0.0

        # Plain-number inputs (already metres) give the same result.
        e_plain = default_seat_eccentricity(:joist, steel, 0.5, 0.3)
        @test e_plain[3] ≈ 0.4

        # Non-joist / other materials have zero eccentricity.
        @test default_seat_eccentricity(:girder, steel, 0.5u"m", 0.3u"m") === (0.0, 0.0, 0.0, 0.0)
        @test default_seat_eccentricity(:beam, steel, 0.5u"m", 0.3u"m") === (0.0, 0.0, 0.0, 0.0)
        @test default_seat_eccentricity(:joist, conc, 0.5u"m", 0.3u"m") === (0.0, 0.0, 0.0, 0.0)
        @test default_seat_eccentricity(:joist, tmb, 0.5u"m", 0.3u"m") === (0.0, 0.0, 0.0, 0.0)
        @test default_seat_eccentricity(:beam, tmb, 0.5u"m", 0.3u"m") === (0.0, 0.0, 0.0, 0.0)
    end

    @testset "Undeclared combinations error" begin
        # Unknown role for a declared material.
        @test_throws ErrorException default_release(:strut, steel, :gravity)
        @test_throws ErrorException default_torsion_released(:strut, steel)
        @test_throws ErrorException default_seat_eccentricity(:strut, steel, 0.5, 0.3)
        # Declared role, undeclared lateral_role (steel beam has :gravity only).
        @test_throws ErrorException default_release(:beam, steel, :moment_frame)
        # Material with no declared methods (rebar steel is not StructuralSteel).
        @test_throws ErrorException default_release(:joist, Rebar_60, :gravity)

        # Error message names the offending combination.
        err = try
            default_release(:strut, steel, :gravity)
            nothing
        catch e
            sprint(showerror, e)
        end
        @test err !== nothing
        @test occursin("role = :strut", err)
        @test occursin("lateral_role = :gravity", err)
    end
end
