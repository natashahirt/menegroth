#!/usr/bin/env julia
# Run RC column NLP and adapter tests.
using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSizer"))
Pkg.test(; test_args=["test_column_nlp_adapter", "test_column_nlp"])
