# Spot-check rebar plotting coordinates and catalog placement against ACI 318-19
# §25.2.3 (column bar clear spacing ≥ max(1.5 in, 1.5 d_b)).
ENV["SS_ENABLE_VISUALIZATION"] = "false"
using StructuralSizer, Unitful

circ = RCCircularSection(D = 20u"inch", bar_size = 8, n_bars = 6, cover = 1.5u"inch")
pts = section_rebar_positions(circ)
println("circular 20\" 6#8 radii (in): ", [round(hypot(y, z) / 0.0254, digits = 2) for (y, z) in pts])
println("circular rebar diameter (in): ", round(2 * section_rebar_radius(circ) / 0.0254, digits = 3))

rect = RCColumnSection(b = 16u"inch", h = 16u"inch", bar_size = 8, n_bars = 6)
println("rect 16x16 6#8 (y,z) in: ", [(round(y / 0.0254, digits = 2), round(z / 0.0254, digits = 2))
                                      for (y, z) in section_rebar_positions(rect)])

# Clear-spacing violations in the default square catalog
function min_clear_spacing_in(s)
    db = sqrt(4 * ustrip(u"inch^2", s.bars[1].As) / π)
    xy = [(ustrip(u"inch", b.x), ustrip(u"inch", b.y)) for b in s.bars]
    d = minimum(hypot(p[1] - q[1], p[2] - q[2]) for (i, p) in enumerate(xy) for q in xy[i+1:end])
    return d - db, db
end
bad = String[]
for s in square_rc_columns()
    clear, db = min_clear_spacing_in(s)
    clear < max(1.5, 1.5 * db) && push!(bad, "$(s.name) clear=$(round(clear, digits=2))\"")
end
println("\nsquare catalog: $(length(square_rc_columns())) sections, $(length(bad)) violate §25.2.3")
println(join(first(bad, 12), "\n"))
edge = ustrip(u"inch", minimum(b.x for b in first(square_rc_columns()).bars))
println("\nfirst catalog section $(first(square_rc_columns()).name): edge-to-bar-centre = $(edge)\"")
