"""
    demo_frame_model() -> Asap.Model

A two-story, two-bay steel frame with a uniform gravity line load on each beam
and one brace. Used by `scripts/runners/export_scene.jl` to produce a packet
the viewer can open without a design run.

The section is intentionally flexible so the deflected shape is visible at a
scale near 1.
"""
function demo_frame_model()
    E = 200e9u"Pa"
    G = 77e9u"Pa"
    ρ = 7850.0u"kg/m^3"
    sec = Asap.Section(4.0e-3u"m^2", E, G, 4.0e-5u"m^4", 1.2e-5u"m^4", 8.0e-7u"m^4", ρ)

    bay_x = 6.0u"m"
    bay_y = 6.0u"m"
    story = 3.6u"m"
    nx, ny, nz = 2, 1, 2

    nodes = Asap.Node[]
    index = Dict{NTuple{3, Int}, Int}()
    for iz in 0:nz, iy in 0:ny, ix in 0:nx
        fix = iz == 0 ? :fixed : :free
        node = Asap.Node([ix * bay_x, iy * bay_y, iz * story], fix)
        push!(nodes, node)
        index[(ix, iy, iz)] = length(nodes)
    end

    elements = Asap.Element[]
    for iz in 0:(nz - 1), iy in 0:ny, ix in 0:nx
        push!(elements, Asap.Element(nodes[index[(ix, iy, iz)]], nodes[index[(ix, iy, iz + 1)]], sec, :column))
    end
    for iz in 1:nz, iy in 0:ny, ix in 0:(nx - 1)
        push!(elements, Asap.Element(nodes[index[(ix, iy, iz)]], nodes[index[(ix + 1, iy, iz)]], sec, :beam))
    end
    for iz in 1:nz, ix in 0:nx, iy in 0:(ny - 1)
        push!(elements, Asap.Element(nodes[index[(ix, iy, iz)]], nodes[index[(ix, iy + 1, iz)]], sec, :beam))
    end
    # One brace, ground to the first elevated corner, so the type code is exercised.
    push!(elements, Asap.Element(nodes[index[(0, 0, 0)]], nodes[index[(1, 0, 1)]], sec, :brace))

    w = [0.0u"N/m", 0.0u"N/m", -8.0e3u"N/m"]
    loads = Asap.AbstractLoad[]
    for elem in elements
        elem.id == :beam || continue
        push!(loads, Asap.LineLoad(elem, w))
    end
    return Asap.Model(nodes, elements, loads)
end
