# =============================================================================
# Runner: StructuralSizer slab & rebar tests
# =============================================================================
# Runs the StructuralSizer-level slab pipeline, rebar selection, and FEA tests.
#
# Usage (from repo root):
#   julia scripts/runners/run_sizer_slab_tests.jl          # all slab tests
#   julia scripts/runners/run_sizer_slab_tests.jl rebar     # rebar-related only
#   julia scripts/runners/run_sizer_slab_tests.jl fea       # FEA flat plate only
#   julia scripts/runners/run_sizer_slab_tests.jl optimizer  # optimizer only
#   julia scripts/runners/run_sizer_slab_tests.jl pipeline   # pipeline validation
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", ".."))

using Test, Unitful
using StructuralSizer

# ─── Parse CLI filter ────────────────────────────────────────────────────────
filter = length(ARGS) >= 1 ? ARGS[1] : "all"
test_root = joinpath(@__DIR__, "..", "..", "StructuralSizer", "test")

println("═"^60)
println("  StructuralSizer — Slab & Rebar Tests")
println("  Filter: $(filter)")
println("═"^60)

# ─── Test groups ──────────────────────────────────────────────────────────────

function run_rebar()
    @testset "Rebar selection" begin
        include(joinpath(test_root, "test_rebar_volume.jl"))
    end
end

function run_fea()
    @testset "FEA flat plate" begin
        include(joinpath(test_root, "test_fea_flat_plate.jl"))
    end
end

function run_optimizer()
    @testset "Flat plate optimizer" begin
        include(joinpath(test_root, "slabs", "test_flat_plate_optimizer.jl"))
    end
end

function run_pipeline()
    @testset "Pipeline validation" begin
        include(joinpath(test_root, "flat_plate_full_pipeline_validation.jl"))
    end
end

function run_flat_plate()
    @testset "Flat plate unit tests" begin
        include(joinpath(test_root, "slabs", "test_flat_plate.jl"))
    end
end

# ─── Dispatch ─────────────────────────────────────────────────────────────────

@testset "StructuralSizer Slabs" begin
    if filter == "all"
        run_rebar()
        run_flat_plate()
        run_fea()
        run_optimizer()
        run_pipeline()
    elseif filter == "rebar"
        run_rebar()
    elseif filter == "fea"
        run_fea()
    elseif filter == "optimizer"
        run_optimizer()
    elseif filter == "pipeline"
        run_pipeline()
    elseif filter == "flat_plate"
        run_flat_plate()
    else
        error("Unknown filter: $filter. Use: all, rebar, fea, optimizer, pipeline, flat_plate")
    end
end
