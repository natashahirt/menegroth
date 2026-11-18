# Check that Asap's fast value-only update path (cached scatter map, in-place
# CHOLMOD refactorization, block shell transform, mat-vec reactions) matches a
# freshly built model.
#
#   julia --project=StructuralSynthesizer scripts/runners/check_asap_fast_update.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using Asap, Unitful, LinearAlgebra, SparseArrays, Printf

function plate(t, E)
    c = (Node([0.0, 0.0, 0.0] .* u"m", :pinned), Node([6.0, 0.0, 0.0] .* u"m", :pinned),
         Node([6.0, 4.0, 0.0] .* u"m", :pinned), Node([0.0, 4.0, 0.0] .* u"m", :pinned))
    sec = ShellSection(t * u"m", E * u"Pa", 0.2)
    shells = Asap.Shell(c, sec; target_edge_length = 0.4u"m")
    load = Asap.AreaLoad(shells, 5000.0u"Pa")
    m = Asap.Model(collect(c), shells, Asap.AbstractLoad[load])
    Asap.process!(m); Asap.solve!(m)
    return m
end

relerr(a, b) = norm(a - b) / max(norm(b), eps())

# Shell: value-only update twice (second uses the stale-factor refactor) vs. fresh builds.
m = plate(0.20, 30e9)
@assert m._scatter !== nothing "scatter map missing after process!"
for (t, E) in ((0.25, 32e9), (0.18, 28e9))
    for e in m.shell_elements; e.thickness = t; e.E = E; end
    Asap.update!(m; values_only = true)
    @assert m._factorization === nothing || m._factorization_stale
    Asap.solve!(m)
    ref = plate(t, E)
    eS = relerr(Matrix(m.S), Matrix(ref.S)); eu = relerr(m.u, ref.u)
    @printf("shell t=%.2f: rel err S = %.2e, u = %.2e, stale cleared = %s\n", t, eS, eu, !m._factorization_stale)
    @assert eS < 1e-12 && eu < 1e-10
end

# Frame: value-only update after a section change vs. fresh build.
function frame(A)
    n = [Node([0.0, 0.0, 0.0] .* u"m", :fixed), Node([0.0, 0.0, 3.0] .* u"m", :free),
         Node([5.0, 0.0, 3.0] .* u"m", :free), Node([5.0, 0.0, 0.0] .* u"m", :fixed)]
    sec(a) = Section(a * u"m^2", 200e9u"Pa", 80e9u"Pa", 1e-4u"m^4", 1e-4u"m^4", 2e-4u"m^4")
    els = [Element(n[1], n[2], sec(A)), Element(n[2], n[3], sec(A)), Element(n[3], n[4], sec(A))]
    loads = Asap.AbstractLoad[NodeForce(n[2], [10e3, 0.0, -5e3] .* u"N")]
    m = Asap.Model(n, els, loads); Asap.process!(m); Asap.solve!(m)
    return m, sec
end
mf, sec = frame(0.01)
for e in mf.elements; e.section = sec(0.02); end
Asap.update!(mf; values_only = true); Asap.solve!(mf)
rf, _ = frame(0.02)
@printf("frame: rel err u = %.2e\n", relerr(mf.u, rf.u))
@assert relerr(mf.u, rf.u) < 1e-10

# Reactions: full mat-vec must equal the old row-slice product exactly.
for mm in (m, mf)
    @assert Asap._fixed_Ku(mm) == mm.S[mm.fixedDOFs, :] * mm.u
end
println("reactions: bit-identical to S[fixed, :] * u")
println("OK")
