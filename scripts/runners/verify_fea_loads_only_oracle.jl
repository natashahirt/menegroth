# P1-4 oracle — FEA load-case factorization reuse.
#
# The design-graph gates cannot see a change inside `_solve_load_case!`: the
# cold path and the incremental path call the same function. This runner builds
# ONE flat-plate shell model twice from the same inputs and solves the dead
# case, then the live case, two ways:
#
#   values_only — production `Asap.update!(; values_only=true)` (rebuilds K,
#                 nulls the CHOLMOD factor, refactorizes)
#   loads_only  — candidate `Asap.update!(; loads_only=true)` (keeps K and the
#                 factor, rebuilds only P)
#
# Pass requires exact equality of nodal displacements, reactions, and per-element
# shell moments (Mxx, Myy, Mxy) after each case, and again after the factored-state
# restore used by `_solve_dl_cases!`. A tolerance is the wrong bar: the previous
# landing of this swap moved moments enough to change reinforcement.

using Printf
using Unitful
using Unitful: @u_str

using Asap
using StructuralSynthesizer
using StructuralSizer

const SS = StructuralSizer

function shell_moments(model)
    shells = model.shell_elements
    n = length(shells)
    ws = Asap.ShellMomentWorkspace()
    M = zeros(3)
    out = Vector{NTuple{3, Float64}}(undef, n)
    @inbounds for k in 1:n
        tri = shells[k]
        if tri isa Asap.ShellTri3
            Asap.bending_moments!(M, tri, model.u, ws)
            out[k] = (M[1], M[2], M[3])
        else
            out[k] = (0.0, 0.0, 0.0)
        end
    end
    return out
end

function set_area_pressure!(model, q::Unitful.Pressure)
    n = 0
    for load in model.loads
        load isa Asap.AreaLoad || continue
        load.pressure = uconvert(u"Pa", q)
        n += 1
    end
    n > 0 || error("FEA model has no AreaLoad — oracle would not change P")
    return n
end

"""Solve one pressure with either `:values_only` or `:loads_only`."""
function solve_pressure!(model, q::Unitful.Pressure, mode::Symbol)
    set_area_pressure!(model, q)
    if mode === :values_only
        Asap.update!(model; values_only = true)
    elseif mode === :loads_only
        Asap.update!(model; loads_only = true)
    else
        error("unknown mode $mode")
    end
    Asap.solve!(model)
    return nothing
end

function snapshot_state(model)
    return (
        u = copy(model.u),
        reactions = copy(model.reactions),
        moments = shell_moments(model),
    )
end

function max_abs(a::AbstractVector{<:Real}, b::AbstractVector{<:Real})
    length(a) == length(b) || return Inf
    m = 0.0
    @inbounds for i in eachindex(a)
        m = max(m, abs(a[i] - b[i]))
    end
    return m
end

function moment_max_abs(a, b)
    length(a) == length(b) || return Inf
    m = 0.0
    for i in eachindex(a)
        m = max(m, abs(a[i][1] - b[i][1]), abs(a[i][2] - b[i][2]), abs(a[i][3] - b[i][3]))
    end
    return m
end

function same_state(a, b)
    u_ok = a.u == b.u
    r_ok = a.reactions == b.reactions
    m_ok = a.moments == b.moments
    return (u_ok && r_ok && m_ok,
            max_abs(a.u, b.u),
            max_abs(a.reactions, b.reactions),
            moment_max_abs(a.moments, b.moments))
end

function build_model(struc, slab, columns, h, Ecs, ν, qu, Lc; target_edge)
    cache = SS.FEAModelCache()
    SS._build_or_update_fea!(
        cache, struc, slab, columns, h, Ecs, ν, qu, Lc;
        Ecc = Ecs, target_edge = target_edge, col_I_factor = 0.70,
    )
    return cache.model
end

function main()
    println("="^70)
    println("P1-4 oracle — values_only vs loads_only on one FEA flat-plate slab")
    println("="^70)

    # One bay, coarse mesh: the question is bit-identity of the two update
    # modes, not mesh convergence. 20 ft × 16 ft, 10 ft story, 8 in slab.
    skel = gen_medium_office(20.0u"ft", 16.0u"ft", 10.0u"ft", 1, 1, 1)
    struc = BuildingStructure(skel)
    opts = FlatPlateOptions(
        material = RC_4000_60,
        method = SS.FEA(),
        cover = 0.75u"inch",
        bar_size = 5,
    )
    initialize!(struc; floor_type = :flat_plate, floor_opts = opts)
    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 20.0u"psf")
        cell.live_load = uconvert(u"kN/m^2", 40.0u"psf")
    end
    for col in struc.columns
        col.c1 = 16.0u"inch"
        col.c2 = 16.0u"inch"
    end
    to_asap!(struc)

    slab = struc.slabs[1]
    columns = SS.find_supporting_columns(struc, Set(slab.cell_indices))
    fc = 4000.0u"psi"
    γ = RC_4000_60.concrete.ρ
    ν = RC_4000_60.concrete.ν
    Ecs = SS.Ec(fc, ustrip(SS.pcf, γ))
    h = 8.0u"inch"
    target_edge = 1.5u"m"
    setup = SS._moment_analysis_setup(struc, slab, columns, h, γ)
    Lc = SS._get_column_height(columns)

    println("  building  1×1 bay, h = 8 in, target_edge = 1.5 m")
    @printf("  qD = %.3f psf   qL = %.3f psf   qu = %.3f psf\n",
            ustrip(u"psf", setup.qD), ustrip(u"psf", setup.qL), ustrip(u"psf", setup.qu))

    model_v = build_model(struc, slab, columns, h, Ecs, ν, setup.qu, Lc; target_edge)
    model_l = build_model(struc, slab, columns, h, Ecs, ν, setup.qu, Lc; target_edge)
    println("  shells = $(length(model_v.shell_elements))   ndof = $(length(model_v.u))")

    nfail = 0
    function check(label, a, b)
        ok, du, dr, dm = same_state(a, b)
        mark = ok ? "✓" : "✗"
        @printf("  %s  %-22s   |Δu|max = %.3e   |ΔR|max = %.3e   |ΔM|max = %.3e N·m/m\n",
                mark, label, du, dr, dm)
        ok || (nfail += 1)
        return ok
    end

    # The two fresh builds must already agree, or a later mismatch is the mesh.
    check("initial qu solve", snapshot_state(model_v), snapshot_state(model_l))

    U_qu = copy(model_v.u)

    solve_pressure!(model_v, setup.qD, :values_only)
    solve_pressure!(model_l, setup.qD, :loads_only)
    check("dead qD", snapshot_state(model_v), snapshot_state(model_l))

    solve_pressure!(model_v, setup.qL, :values_only)
    solve_pressure!(model_l, setup.qL, :loads_only)
    check("live qL after qD", snapshot_state(model_v), snapshot_state(model_l))

    # `_solve_dl_cases!` restore: put the factored displacement back, refresh
    # P at qu, post-process. No third solve. Moments come from the restored u.
    qu = setup.qu
    for (model, mode) in ((model_v, :values_only), (model_l, :loads_only))
        set_area_pressure!(model, qu)
        copy!(model.u, U_qu)
        if mode === :values_only
            Asap.update!(model; values_only = true)
        else
            Asap.update!(model; loads_only = true)
        end
        Asap.post_process!(model)
    end
    check("restore qu (no resolve)", snapshot_state(model_v), snapshot_state(model_l))

    println("="^70)
    if nfail == 0
        println("✓ ORACLE PASS — loads_only matches values_only exactly")
    else
        println("✗ ORACLE FAIL — $nfail comparison(s) not exact. P1-4 stays deferred.")
    end
    return nfail == 0
end

ok = main()
exit(ok ? 0 : 1)
