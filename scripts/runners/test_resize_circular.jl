#!/usr/bin/env julia
# Quick test for resize_column_with_reinforcement with RCCircularSection

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSizer"))

using StructuralSizer
using Unitful

# Create a circular column section
sec = RCCircularSection(D=18u"inch", bar_size=8, n_bars=8, cover=1.5u"inch", tie_type=:spiral)

# Test resize to larger diameter (simulating punching shear growth)
# Use ReinforcedConcreteMaterial (slab pipeline passes this)
mat = ReinforcedConcreteMaterial(NWC_4000, Rebar_60)
new_sec = resize_column_with_reinforcement(
    sec, 22u"inch", 22u"inch", 300.0, 150.0, mat
)

@assert new_sec isa RCCircularSection
@assert new_sec.D >= 22u"inch"
println("✓ resize_column_with_reinforcement(RCCircularSection) works")
