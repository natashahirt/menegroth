# Mesh convergence of membrane-only ShellTri3 on an in-plane cantilever.
# Reports tip displacement / Timoshenko beam value for several meshes.
#   julia --project=StructuralSynthesizer scripts/runners/membrane_mesh_convergence.jl
using Asap, Unitful, Printf

function membrane_tip(L, h, nx, ny; t=0.2, E=30e9, P=1.0e6)
    xs = range(0.0, L; length=nx + 1)
    ys = range(0.0, h; length=ny + 1)
    grid = Matrix{Asap.Node}(undef, nx + 1, ny + 1)
    for i in 1:(nx + 1), j in 1:(ny + 1)
        dof = i == 1 ? fill(false, 6) : [true, true, false, false, false, false]
        grid[i, j] = Asap.Node([xs[i] * u"m", ys[j] * u"m", 0.0u"m"], dof)
    end
    shells = Asap.ShellTri3[]
    for i in 1:nx, j in 1:ny
        a, b, c, d = grid[i, j], grid[i + 1, j], grid[i + 1, j + 1], grid[i, j + 1]
        push!(shells, Asap.ShellTri3((a, b, c), t * u"m", E * u"Pa", 0.0; membrane_only=true))
        push!(shells, Asap.ShellTri3((a, c, d), t * u"m", E * u"Pa", 0.0; membrane_only=true))
    end
    loads = Asap.AbstractLoad[]
    for j in 1:(ny + 1)
        w = (j == 1 || j == ny + 1) ? 0.5 / ny : 1.0 / ny
        push!(loads, Asap.NodeForce(grid[end, j], [0.0u"N", -P * w * u"N", 0.0u"N"]))
    end
    model = Asap.ShellModel(vec(grid), shells, loads)
    Asap.solve!(model)
    tip = -sum(ustrip(u"m", grid[end, j].displacement[2]) for j in 1:(ny + 1)) / (ny + 1)
    I = t * h^3 / 12
    beam = P * L^3 / (3 * E * I) + P * L / ((5 / 6) * (E / 2) * t * h)
    return tip / beam
end

for (L, h) in ((4.0, 2.0), (12.0, 6.0), (6.0, 6.0), (24.0, 6.0))
    println("L/h = $(L / h)")
    for ny in (2, 4, 6, 8, 12, 16)
        nx = max(1, round(Int, ny * L / h))
        @printf("  ny = %2d (nx = %3d): tip / Timoshenko = %.3f\n", ny, nx, membrane_tip(L, h, nx, ny))
    end
end
