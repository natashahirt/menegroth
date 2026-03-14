using Pkg

Pkg.activate("StructuralSynthesizer")

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
include(joinpath(repo_root, "StructuralSynthesizer", "test", "core", "test_api_units_faces.jl"))
