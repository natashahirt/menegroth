#!/usr/bin/env julia
# Quick test of section_polygon_inner for HSS sections.

using Unitful
using StructuralSizer

# HSS rect: 300mm x 300mm, 10mm wall
hss_rect = HSSRectSection(0.3u"m", 0.3u"m", 0.01u"m")
inner_rect = section_polygon_inner(hss_rect)
@assert length(inner_rect) == 4 "HSS rect inner should have 4 vertices"
println("HSS rect inner: ", length(inner_rect), " vertices OK")

# HSS round: 200mm OD, 10mm wall
hss_round = HSSRoundSection(0.2u"m", 0.01u"m")
inner_round = section_polygon_inner(hss_round)
@assert length(inner_round) >= 20 "HSS round inner should have many vertices"
println("HSS round inner: ", length(inner_round), " vertices OK")

# Solid section (W-shape) returns empty
w_sec = ISymmSection(14u"inch", 14u"inch", 0.44u"inch", 0.71u"inch")
@assert isempty(section_polygon_inner(w_sec)) "Solid section should return empty"
println("Solid section returns empty OK")

println("All section_polygon_inner tests passed.")
