using StructuralSynthesizer
using StructuralSizer
using Asap
using Test
using Unitful

# =============================================================================
# Micro-Experiments Tests
#
# These tests verify the experiment dispatch, argument validation, and error
# handling. Since constructing a full BuildingDesign requires geometry + FEM,
# we build minimal mock designs with only the fields each experiment touches.
# =============================================================================

function _mock_design(;
    columns = Dict{Int, StructuralSynthesizer.ColumnDesignResult}(),
    slabs = Dict{Int, StructuralSynthesizer.SlabDesignResult}(),
    params = StructuralSynthesizer.DesignParameters(),
)
    skel = StructuralSynthesizer.BuildingSkeleton{Float64}()
    struc = StructuralSynthesizer.BuildingStructure(skel)
    design = StructuralSynthesizer.BuildingDesign(struc, params)
    for (k, v) in columns
        design.columns[k] = v
    end
    for (k, v) in slabs
        design.slabs[k] = v
    end
    return design
end

function _mock_punching_column(; c1_m=0.4, c2_m=0.4, Vu_kN=200.0, ratio=0.85)
    pdr = StructuralSynthesizer.PunchingDesignResult(
        Vu = Vu_kN * u"kN",
        φVc = (Vu_kN / ratio) * u"kN",
        ratio = ratio,
        ok = ratio ≤ 1.0,
        critical_perimeter = 2.0u"m",
        tributary_area = 4.0u"m^2",
    )
    StructuralSynthesizer.ColumnDesignResult(
        section_size = "16x16",
        c1 = c1_m * u"m",
        c2 = c2_m * u"m",
        shape = :rectangular,
        Pu = 500.0u"kN",
        Mu_x = 50.0u"kN*m",
        Mu_y = 20.0u"kN*m",
        axial_ratio = 0.5,
        interaction_ratio = 0.7,
        ok = true,
        punching = pdr,
    )
end

function _mock_rc_column(; dim_in=16, Pu_kip=300.0, Mu_x_kipft=100.0, ratio=0.8)
    c_m = dim_in * 0.0254
    StructuralSynthesizer.ColumnDesignResult(
        section_size = "$(dim_in)x$(dim_in)",
        c1 = c_m * u"m",
        c2 = c_m * u"m",
        shape = :rectangular,
        Pu = Pu_kip * u"kip",
        Mu_x = Mu_x_kipft * u"kip*ft",
        Mu_y = 10.0u"kip*ft",
        axial_ratio = ratio * 0.7,
        interaction_ratio = ratio,
        ok = ratio ≤ 1.0,
        punching = nothing,
    )
end

function _mock_slab(; thickness_m=0.2, deflection_in=0.4, limit_in=0.5, ok=true)
    StructuralSynthesizer.SlabDesignResult(
        thickness = thickness_m * u"m",
        self_weight = 4.8u"kPa",
        deflection_ok = ok,
        deflection_ratio = deflection_in / limit_in,
        deflection_in = deflection_in,
        deflection_limit_in = limit_in,
    )
end

@testset "Micro-Experiments" begin
    @testset "list_experiments" begin
        result = StructuralSynthesizer.list_experiments()
        @test haskey(result, "experiments")
        @test length(result["experiments"]) == 4
        names = [e["name"] for e in result["experiments"]]
        @test "punching" in names
        @test "pm_column" in names
        @test "deflection" in names
        @test "catalog_screen" in names
    end

    @testset "evaluate_experiment dispatch" begin
        design = _mock_design()

        # Unknown type
        r = StructuralSynthesizer.evaluate_experiment(design, "bogus", Dict{String, Any}())
        @test r["error"] == "unknown_experiment"

        # Missing required args
        r = StructuralSynthesizer.evaluate_experiment(design, "punching", Dict{String, Any}())
        @test r["error"] == "missing_col_idx"

        r = StructuralSynthesizer.evaluate_experiment(design, "deflection", Dict{String, Any}())
        @test r["error"] == "missing_slab_idx"
    end

    @testset "evaluate_experiment string numeric args" begin
        col = _mock_punching_column(c1_m=0.4, c2_m=0.4, Vu_kN=200.0, ratio=0.85)
        slab = _mock_slab(deflection_in=0.4, limit_in=0.5, ok=true)
        design = _mock_design(columns = Dict(1 => col), slabs = Dict(1 => slab))

        r_pm = StructuralSynthesizer.evaluate_experiment(
            design,
            "pm_column",
            Dict{String, Any}("col_idx" => "1", "section_size" => "18"),
        )
        @test r_pm["experiment"] == "pm_column"
        @test r_pm["modified"]["section"] == "18x18"

        r_catalog = StructuralSynthesizer.evaluate_experiment(
            design,
            "catalog_screen",
            Dict{String, Any}("col_idx" => "1", "candidates" => ["12", "16", "20"]),
        )
        @test r_catalog["experiment"] == "catalog_screen"
        @test length(r_catalog["candidates"]) == 3

        r_bad = StructuralSynthesizer.evaluate_experiment(
            design,
            "catalog_screen",
            Dict{String, Any}("col_idx" => 1, "candidates" => ["12", "bad"]),
        )
        @test r_bad["error"] == "invalid_candidates"
    end

    @testset "experiment_punching" begin
        col = _mock_punching_column(c1_m=0.4, c2_m=0.4, Vu_kN=200.0, ratio=0.85)
        slab = _mock_slab(thickness_m=0.2)
        design = _mock_design(
            columns = Dict(1 => col),
            slabs = Dict(1 => slab),
        )

        # Column not found
        r = StructuralSynthesizer.experiment_punching(design, 99)
        @test r["error"] == "column_not_found"

        # No punching data
        col_no_punch = _mock_rc_column()
        design2 = _mock_design(columns = Dict(1 => col_no_punch))
        r = StructuralSynthesizer.experiment_punching(design2, 1)
        @test r["error"] == "no_punching_data"

        # Valid experiment: grow column → should reduce ratio
        r = StructuralSynthesizer.experiment_punching(design, 1; c1_in=24.0, c2_in=24.0)
        @test r["experiment"] == "punching"
        @test haskey(r, "original")
        @test haskey(r, "modified")
        @test haskey(r, "delta_ratio")
        @test r["modified"]["c1_in"] == 24.0
        @test r["modified"]["c2_in"] == 24.0
        @test haskey(r["modified"], "ratio")
        @test haskey(r["modified"], "ok")
    end

    @testset "experiment_pm_column" begin
        col = _mock_rc_column(dim_in=16, Pu_kip=300.0, Mu_x_kipft=100.0, ratio=0.8)
        design = _mock_design(columns = Dict(1 => col))

        # Missing section_size
        r = StructuralSynthesizer.experiment_pm_column(design, 1)
        @test r["error"] == "section_size_required"

        # Valid: try bigger column
        r = StructuralSynthesizer.experiment_pm_column(design, 1; section_size=24.0)
        @test r["experiment"] == "pm_column"
        @test r["column_type"] == "RC"
        @test haskey(r, "modified")
        @test r["modified"]["section"] == "24x24"
        @test haskey(r["modified"], "interaction_ratio")
        @test haskey(r["modified"], "ok")
        @test haskey(r, "delta_ratio")

        # Valid: try smaller column (may fail)
        r_small = StructuralSynthesizer.experiment_pm_column(design, 1; section_size=10.0)
        @test r_small["experiment"] == "pm_column"
        # Smaller column should have higher ratio
        @test r_small["modified"]["interaction_ratio"] > r["modified"]["interaction_ratio"]
    end

    @testset "experiment_deflection" begin
        slab = _mock_slab(deflection_in=0.4, limit_in=0.5, ok=true)
        design = _mock_design(slabs = Dict(1 => slab))

        # Slab not found
        r = StructuralSynthesizer.experiment_deflection(design, 99)
        @test r["error"] == "slab_not_found"

        # Valid: same limit
        r = StructuralSynthesizer.experiment_deflection(design, 1; deflection_limit="L_360")
        @test r["experiment"] == "deflection"
        @test haskey(r, "original")
        @test haskey(r, "modified")

        # More restrictive limit → higher ratio
        r_strict = StructuralSynthesizer.experiment_deflection(design, 1; deflection_limit="L_480")
        @test r_strict["modified"]["ratio"] > r["modified"]["ratio"]

        # Less restrictive limit → lower ratio
        r_lax = StructuralSynthesizer.experiment_deflection(design, 1; deflection_limit="L_240")
        @test r_lax["modified"]["ratio"] < r["modified"]["ratio"]

        # Invalid limit
        r_bad = StructuralSynthesizer.experiment_deflection(design, 1; deflection_limit="L_100")
        @test r_bad["error"] == "invalid_limit"
    end

    @testset "experiment_catalog_screen" begin
        col = _mock_rc_column(dim_in=16, Pu_kip=300.0, Mu_x_kipft=100.0, ratio=0.8)
        design = _mock_design(columns = Dict(1 => col))

        # Empty candidates
        r = StructuralSynthesizer.experiment_catalog_screen(design, 1; candidates=Float64[])
        @test r["error"] == "no_candidates"

        # Valid: screen several sizes
        r = StructuralSynthesizer.experiment_catalog_screen(design, 1;
            candidates=[12.0, 16.0, 20.0, 24.0, 28.0])
        @test r["experiment"] == "catalog_screen"
        @test length(r["candidates"]) == 5

        # Candidates should be sorted by interaction_ratio (ascending)
        ratios = [get(c, "interaction_ratio", Inf) for c in r["candidates"]]
        @test issorted(ratios)

        # Larger sections should have lower ratios
        @test r["candidates"][end]["section"] in ["12x12"]  # worst = smallest
    end

    @testset "batch_evaluate" begin
        col = _mock_punching_column()
        slab = _mock_slab()
        design = _mock_design(columns = Dict(1 => col), slabs = Dict(1 => slab))

        experiments = [
            Dict{String, Any}("type" => "punching", "args" => Dict{String, Any}("col_idx" => 1, "c1_in" => 20.0, "c2_in" => 20.0)),
            Dict{String, Any}("type" => "deflection", "args" => Dict{String, Any}("slab_idx" => 1, "deflection_limit" => "L_480")),
        ]
        r = StructuralSynthesizer.batch_evaluate(design, experiments)
        @test r["n_experiments"] == 2
        @test length(r["results"]) == 2
        @test r["results"][1]["experiment_index"] == 1
        @test r["results"][2]["experiment_index"] == 2
    end
end
