# Ordinary-wall checks in the engineering report and the design JSON.
#
# A gravity-only design omits the section. When checks exist, the report
# prints the governing check and every other failure. Demand stays in the
# checker's units, converted for display. The JSON keeps every record.

@testset "Ordinary wall report and JSON" begin
    struc = BuildingStructure(gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 1, 1))
    params = DesignParameters(name="gravity", skip_visualization=true)
    design = BuildingDesign(struc, params)

    buf = IOBuffer()
    engineering_report(design; io=buf)
    quiet = String(take!(buf))
    @test !occursin("ORDINARY WALLS", quiet)
    @test !occursin("SEISMIC STORY DRIFT", quiet)

    shear = WallCheckRecord(
        1, 0, :X, :D, :strength, :only,
        "in-plane shear", true, 0.40, 1_000.0, 2_500.0,
        "ACI 318-19 11.5.4.3")
    flexure = WallCheckRecord(
        1, 0, :X, :W, :strength, :only,
        "in-plane axial-flexure (P-M)", false, 1.20, 5_000.0, 4_000.0,
        "ACI 318-19 22.2 / Table 21.2.2")
    reinf = WallCheckRecord(
        1, 0, :X, :D, :strength, :only,
        "min longitudinal reinf ρl", false, 1.05, 0.0025, 0.0020,
        "ACI 318-19 11.6.2(a)")
    design.walls[1] = [shear, flexure, reinf]
    design.seismic_story_drift = Any[
        SeismicStoryDriftCheck(1, :X, :none, 0.010, 0.020, true),
    ]

    engineering_report(design; io=buf, report_units=:metric)
    text = String(take!(buf))
    @test occursin("ORDINARY WALLS", text)
    @test occursin("in-plane axial-flexure (P-M)", text)
    @test occursin("min longitudinal reinf ρl", text)
    @test !occursin("in-plane shear", text)
    @test occursin("5.0 kN·m", text)
    @test occursin("4.0 kN·m", text)
    @test occursin("0.0025 ρ", text)
    @test occursin("SEISMIC STORY DRIFT", text)
    @test occursin("0.0100", text)
    @test occursin("0.0200", text)

    payload = design_to_json(design)
    @test length(payload.walls) == 3
    @test payload.walls[1].check == "in-plane shear"
    @test payload.walls[1].passed
    @test payload.walls[2].passed == false
    @test payload.walls[2].clause == "ACI 318-19 22.2 / Table 21.2.2"
    @test length(payload.seismic_story_drift) == 1
    @test payload.seismic_story_drift[1].drift_m ≈ 0.010
    @test payload.seismic_story_drift[1].passes
end
