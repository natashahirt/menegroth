# =============================================================================
# Test runner — run from repo root:
#   julia scripts/runners/run_tests.jl                 # all tests
#   julia scripts/runners/run_tests.jl design_api      # just the new API tests
#   julia scripts/runners/run_tests.jl core             # core test group
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", ".."))

using Test, Unitful
using StructuralSynthesizer
using Asap

# ─── Parse CLI filter ────────────────────────────────────────────────────────
test_filter = length(ARGS) >= 1 ? ARGS[1] : "all"
test_root = normpath(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer", "test"))

println("═"^60)
println("  StructuralSynthesizer Test Runner")
println("  Filter: $(test_filter)")
println("═"^60)

# ─── Test groups ──────────────────────────────────────────────────────────────

function run_core()
    @testset "Core" begin
        include(joinpath(test_root, "core", "test_core_structs.jl"))
        include(joinpath(test_root, "core", "test_design_architecture.jl"))
        include(joinpath(test_root, "core", "test_member_hierarchy.jl"))
        include(joinpath(test_root, "core", "test_design_api.jl"))
    end
end

function run_design_api()
    @testset "Design API" begin
        include(joinpath(test_root, "core", "test_design_api.jl"))
    end
end

function run_geometry()
    @testset "Geometry" begin
        include(joinpath(test_root, "geometry", "test_slab_geometry.jl"))
        include(joinpath(test_root, "geometry", "test_slab_coloring.jl"))
    end
end

function run_slabs()
    @testset "Slab Sizing" begin
        include(joinpath(test_root, "sizing", "slabs", "test_flat_plate_efm_integration.jl"))
        include(joinpath(test_root, "sizing", "slabs", "test_flat_plate_methods_comparison.jl"))
        include(joinpath(test_root, "sizing", "slabs", "test_vault_pipeline.jl"))
    end
end

function run_members()
    @testset "Member Sizing" begin
        include(joinpath(test_root, "sizing", "members", "test_beam_sizing_report.jl"))
        include(joinpath(test_root, "sizing", "members", "test_column_sizing_report.jl"))
        include(joinpath(test_root, "sizing", "members", "test_aisc_column_examples.jl"))
    end
end

function run_integration()
    @testset "Integration" begin
        include(joinpath(test_root, "integration", "test_structuralsizer_workflow_integration.jl"))
    end
end

# ─── Dispatch ─────────────────────────────────────────────────────────────────

@testset "StructuralSynthesizer" begin
    if test_filter == "all"
        run_core()
        run_geometry()
        run_slabs()
        run_members()
        run_integration()
    elseif test_filter == "design_api"
        run_design_api()
    elseif test_filter == "core"
        run_core()
    elseif test_filter == "geometry"
        run_geometry()
    elseif test_filter == "slabs"
        run_slabs()
    elseif test_filter == "members"
        run_members()
    elseif test_filter == "integration"
        run_integration()
    else
        error("Unknown filter: $test_filter. Use: all, design_api, core, geometry, slabs, members, integration")
    end
end
