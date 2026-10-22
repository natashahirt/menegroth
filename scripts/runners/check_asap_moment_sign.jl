# Empirical Asap My sign convention for horizontal beams under gravity.
# Used by StructuralSynthesizer member_group_demands signed-moment envelopes.
#
# Builds simply-supported and fixed-fixed beams under downward global-Z load,
# with elements in +x, -x, +y, -y, using Asap's default roll Ψ = π/2
# (the Synthesizer `to_asap!` path does not override Ψ).

using Asap
using Unitful

function _section()
    E = 200e9u"Pa"
    G = E / (2 * (1 + 0.3))
    return Section(0.01u"m^2", E, G, 1e-4u"m^4", 5e-5u"m^4", 1e-5u"m^4", 7850u"kg/m^3")
end

function _run_beam(p1, p2, release; w = -10.0u"kN/m")
    # Single element. Nodes are :fixed so torsion / weak-axis mechanisms
    # cannot singularize K. End-moment release (`:freefree`) is what makes
    # the simply-supported case; `:fixedfixed` keeps support moments.
    sec = _section()
    n_start = Node(p1, :fixed)
    n_end   = Node(p2, :fixed)
    nodes = [n_start, n_end]
    el = Element(n_start, n_end, sec; release=release)
    elements = [el]
    loads = [LineLoad(el, [0.0u"N/m", 0.0u"N/m", w])]
    model = Model(nodes, elements, loads)
    process!(model)
    solve!(model)

    println("  Ψ default = $(elements[1].Ψ) rad ($(elements[1].Ψ / π) π)")
    println("  LCS x=$(round.(elements[1].LCS[1]; digits=3)) y=$(round.(elements[1].LCS[2]; digits=3)) z=$(round.(elements[1].LCS[3]; digits=3))")

    el_loads = Asap.get_elemental_loads(model)[el.elementID]
    fd = ElementForceAndDisplacement(el, el_loads; resolution=21)
    n = length(fd.forces.My)
    mid = cld(n, 2)
    My_mid = fd.forces.My[mid]
    Mz_mid = fd.forces.Mz[mid]
    My_s   = fd.forces.My[1]
    Mz_s   = fd.forces.Mz[1]
    My_e   = fd.forces.My[end]
    Mz_e   = fd.forces.Mz[end]
    println("  midspan  My=$(round(My_mid; sigdigits=4))  Mz=$(round(Mz_mid; sigdigits=4))")
    println("  start    My=$(round(My_s; sigdigits=4))  Mz=$(round(Mz_s; sigdigits=4))")
    println("  end      My=$(round(My_e; sigdigits=4))  Mz=$(round(Mz_e; sigdigits=4))")
    println("  midspan My sign = $(sign(My_mid))  start My sign = $(sign(My_s))")
    return (; My_mid, Mz_mid, My_s, Mz_s, My_e, Mz_e, LCS=elements[1].LCS)
end

L = 8.0u"m"
cases = (
    ("+x", [0.0u"m", 0.0u"m", 0.0u"m"], [L, 0.0u"m", 0.0u"m"]),
    ("-x", [L, 0.0u"m", 0.0u"m"], [0.0u"m", 0.0u"m", 0.0u"m"]),
    ("+y", [0.0u"m", 0.0u"m", 0.0u"m"], [0.0u"m", L, 0.0u"m"]),
    ("-y", [0.0u"m", L, 0.0u"m"], [0.0u"m", 0.0u"m", 0.0u"m"]),
)

println("=== SIMPLY SUPPORTED (pinned-pinned), downward LineLoad [0,0,-w] ===")
ss = Dict{String,Any}()
for (name, p1, p2) in cases
    println("\n[$name SS]")
    ss[name] = _run_beam(p1, p2, :freefree)
end

println("\n=== FIXED-FIXED, downward LineLoad [0,0,-w] ===")
ff = Dict{String,Any}()
for (name, p1, p2) in cases
    println("\n[$name FF]")
    ff[name] = _run_beam(p1, p2, :fixedfixed)
end

println("\n=== SUMMARY ===")
println("SS midspan My signs: ", Dict(k => sign(v.My_mid) for (k, v) in ss))
println("FF support My signs: ", Dict(k => sign(v.My_s) for (k, v) in ff))
println("""
Verified convention (default Ψ = π/2):
  Sagging (bottom tension, underside = −global Z) = sign(My) × sign(local_y · ê_Z).
  +x/+y/−y: local y = +Z → +My is sagging, −My is hogging.
  −x:       local y = −Z → −My is sagging, +My is hogging.
  Raw My sign is NOT orientation-independent; classify from local y · ê_Z.
""")
