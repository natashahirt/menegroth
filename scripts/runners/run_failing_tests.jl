#!/usr/bin/env julia
# Run only the failing testsets with verbose output to diagnose failures.
# Usage: julia --project=StructuralSizer scripts/runners/run_failing_tests.jl

using Pkg
proj = joinpath(@__DIR__, "..", "..", "StructuralSizer")
Pkg.activate(proj)
Pkg.instantiate()

using Test
using Unitful
using StructuralSizer
using Asap

testdir = joinpath(proj, "test")

println(repeat("=", 70))
println("1. Tributary Load Workflow (4 failures)")
println(repeat("=", 70))
include(joinpath(testdir, "slabs", "test_tributary_workflow.jl"))

println()
println(repeat("=", 70))
println("2. Full Column Sizing Workflow + Material Comparison (4 failures)")
println(repeat("=", 70))
include(joinpath(testdir, "optimize", "test_column_full.jl"))
