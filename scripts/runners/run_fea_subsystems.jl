#!/usr/bin/env julia
#
# Run the full Foundations + Slabs test sets in StructuralSizer.
#
# This is the regression scope for the mat-foundation in-place section
# update refactor (Asap.update!(model; values_only=true) inside
# `_design_mat_winkler_fea` and `_solve_winkler!`).  Both subsystems use
# the Asap shell mesh / Winkler / shell-bending machinery, so they are
# the primary places to catch unintended fallout.
#
# Usage:
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralSizer \
#       scripts/runners/run_fea_subsystems.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSizer"))

using Test, Unitful
using StructuralSizer
using Asap

const TEST_DIR = joinpath(@__DIR__, "..", "..", "StructuralSizer", "test")

@testset "FEA subsystems regression — mat in-place refactor" begin

    @testset "Foundations" begin
        include(joinpath(TEST_DIR, "foundations", "test_spread_footing.jl"))
        include(joinpath(TEST_DIR, "foundations", "test_spread_aci.jl"))
        include(joinpath(TEST_DIR, "foundations", "test_strip_aci.jl"))
        include(joinpath(TEST_DIR, "foundations", "test_mat_aci.jl"))
        include(joinpath(TEST_DIR, "foundations", "test_rebar_quantity.jl"))
        include(joinpath(TEST_DIR, "foundations", "test_no_tension_springs.jl"))
        include(joinpath(TEST_DIR, "foundations", "test_types_load.jl"))
    end

    @testset "Slabs" begin
        include(joinpath(TEST_DIR, "slabs", "test_strip_geometry.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_spanning_behavior.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_tributary_workflow.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_one_way_slab_reference.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_flat_plate.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_flat_plate_methods.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_size_flat_plate.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_method_comparison.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_frameline_ddm.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_hardy_cross_larger.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_efm_stiffness.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_efm_pipeline.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_raw_asap_frame.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_flat_slab.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_pipeline_provisions.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_aci_audit_tier1.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_shear_transfer.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_shear_studs.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_punching_reinforcement.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_torsion_discount.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_column_growth.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_pattern_loading_sizing.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_stud_catalog.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_waffle_geometry.jl"))
        include(joinpath(TEST_DIR, "slabs", "test_flat_plate_optimizer.jl"))
    end

end
