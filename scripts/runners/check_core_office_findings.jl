#=
Four checks on the saved core office, in one load of the design file.

    SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
        julia --project=StructuralSynthesizer \
        scripts/runners/check_core_office_findings.jl [design.mgdesign]

1. Column reinforcement against ACI 318-11 §10.9.1 and the §10.8.4 relief.
2. Factored and service vertical reactions, split into column supports and
   wall-base nodes, next to the wall line loads the mat was given.
3. Whether those pieces add up to every fixed vertical reaction.
4. Why the service-model stiffness is not positive definite: degenerate
   shells first, then the soft pivots of the free stiffness.
=#

using LinearAlgebra
using Printf
using SparseArrays
using Unitful
using Asap
using Meshes
using StructuralSynthesizer
using StructuralSizer

const design_path = isempty(ARGS) ?
    joinpath(@__DIR__, "..", "..", "logs", "core_office_v2.mgdesign") :
    ARGS[1]

const DOF_NAME = ("ux", "uy", "uz", "rx", "ry", "rz")

function _kN(x)
    x isa Unitful.Quantity && return ustrip(u"kN", uconvert(u"kN", x))
    return x / 1000
end

"""Gross area (m²) from [`StructuralSizer.tied_column_area_for_axial`](@ref), Eq. (10-2) at ρg = 0.01."""
_ag_required_m2(Pu_N, fc_Pa, fy_Pa) = ustrip(u"m^2",
    StructuralSizer.tied_column_area_for_axial(Pu_N * u"N", fc_Pa * u"Pa"; fy = fy_Pa * u"Pa"))

function _column_steel(design)
    cols = design.columns
    struc = design.structure
    mat = design.params.materials
    println("columns recorded: ", length(cols), "  structure columns: ", length(struc.columns))
    low = 0
    relief_ok = 0
    relief_short = 0
    for (i, cr) in sort!(collect(pairs(cols)); by = first)
        ρ = cr.rho_g
        ρ >= 0.01 && continue
        low += 1
        Ag = ustrip(u"m^2", cr.Ag)
        Pu = ustrip(u"N", cr.Pu)
        col = struc.columns[i]
        conc = something(col.concrete, mat.concrete)
        reb = mat.rebar
        Ag_req = Pu > 0 ? _ag_required_m2(Pu, ustrip(u"Pa", conc.fc′), ustrip(u"Pa", reb.Fy)) : 0.0
        Ag_eff = max(0.5 * Ag, Ag_req)
        Ast = ρ * Ag
        holds = Ast + 1e-12 >= 0.01 * Ag_eff
        holds ? (relief_ok += 1) : (relief_short += 1)
        low <= 8 && @printf("  col %2d  %s  ρg %.4f  Ag %.4f m²  Ag_req %.4f  Ast/Ag_eff %.4f  %s\n",
                            i, cr.section_size, ρ, Ag, Ag_req, Ag == 0 ? NaN : Ast / Ag_eff,
                            holds ? "§10.8.4 could cover it" : "below even half-area")
    end
    println("  below 0.01Ag: ", low, "   §10.8.4 could cover: ", relief_ok,
            "   still short: ", relief_short)
    flush(stdout)
end

function _fixed_z(model)
    nodes = Asap.Node[]
    for n in model.nodes
        length(n.dof) >= 3 && n.dof[3] == false && push!(nodes, n)
    end
    return nodes
end

function _bucket(label, nodes, R_s)
    pu = ps = 0.0
    neg_pu = neg_ps = 0
    ps_quiet = 0
    for n in nodes
        p = ustrip(u"N", n.reaction[3])
        s = R_s[n.globalID[3]]
        pu += p
        ps += s
        p < -1.0 && (neg_pu += 1)
        s < -1.0 && (neg_ps += 1)
        abs(s) < 1.0 && abs(p) > 1000 && (ps_quiet += 1)
    end
    ratio = abs(ps) > 1 ? pu / ps : NaN
    @printf("  %-22s  n %5d  Pu %10.1f kN  Ps %10.1f kN  Pu/Ps %5.2f  neg %d/%d  Ps≈0 %d\n",
            label, length(nodes), pu / 1000, ps / 1000, ratio, neg_pu, neg_ps, ps_quiet)
    return (pu = pu, ps = ps)
end

function _reactions(struc)
    model = struc.asap_model
    println("solve the stored gravity model")
    flush(stdout)
    t = @elapsed StructuralSynthesizer.Asap.solve!(model)
    println("  solve ", round(t; digits = 1), " s   nodes ", length(model.nodes),
            "  shells ", length(model.shell_elements), "  frames ", length(model.frame_elements))
    kinds = Dict{Symbol, Int}()
    for ld in model.loads
        k = nameof(typeof(ld))
        kinds[k] = get(kinds, k, 0) + 1
    end
    println("  stored loads: ", kinds)
    for ld in model.loads
        ld isa Asap.AreaLoad || continue
        println("  AreaLoad ", ld.id, " on ", length(ld.shells), " shells")
    end
    R_s = StructuralSynthesizer._service_reactions(struc)
    fixed = _fixed_z(model)
    support_ids = Set(objectid(model.nodes[s.node_idx]) for s in struc.supports)
    grade = minimum(ustrip(u"m", model.nodes[s.node_idx].position[3]) for s in struc.supports)
    wall_ids = Set{UInt64}()
    for sh in model.shell_elements
        sh.id === :wall || continue
        for n in sh.nodes
            abs(ustrip(u"m", n.position[3]) - grade) < 0.05 && push!(wall_ids, objectid(n))
        end
    end
    both = Asap.Node[]
    cols = Asap.Node[]
    walls = Asap.Node[]
    other = Asap.Node[]
    for n in fixed
        id = objectid(n)
        in_c = id in support_ids
        in_w = id in wall_ids
        if in_c && in_w
            push!(both, n)
        elseif in_c
            push!(cols, n)
        elseif in_w
            push!(walls, n)
        else
            push!(other, n)
        end
    end
    println("fixed vertical supports, grade z = ", round(grade; digits = 3), " m")
    c = _bucket("column supports", cols, R_s)
    b = _bucket("column on a wall", both, R_s)
    w = _bucket("wall base only", walls, R_s)
    o = _bucket("other fixed", other, R_s)
    total_pu = c.pu + b.pu + w.pu + o.pu
    total_ps = c.ps + b.ps + w.ps + o.ps
    @printf("  %-22s  n %5d  Pu %10.1f kN  Ps %10.1f kN  Pu/Ps %5.2f\n",
            "all fixed", length(fixed), total_pu / 1000, total_ps / 1000,
            abs(total_ps) > 1 ? total_pu / total_ps : NaN)

    groups = StructuralSynthesizer.collect_grade_wall_groups(struc)
    line_pu = line_ps = 0.0
    for g in groups
        line_pu += sum(ustrip(u"N", smp.Pu) for leg in g.legs for smp in leg.samples)
        line_ps += sum(ustrip(u"N", smp.Ps) for leg in g.legs for smp in leg.samples)
    end
    @printf("  wall line loads given to the mat:  Pu %10.1f kN  Ps %10.1f kN\n",
            line_pu / 1000, line_ps / 1000)
    @printf("  line loads minus wall-base reactions:  Pu %8.1f kN  Ps %8.1f kN\n",
            (line_pu - b.pu - w.pu) / 1000, (line_ps - b.ps - w.ps) / 1000)
    demands = StructuralSynthesizer.support_demands(struc)
    dem_pu = sum(ustrip(u"N", d.Pu) for d in demands)
    dem_ps = sum(ustrip(u"N", d.Ps) for d in demands)
    @printf("  column support demands:             Pu %10.1f kN  Ps %10.1f kN\n",
            dem_pu / 1000, dem_ps / 1000)
    @printf("  supports + wall-only, vs all fixed: Pu residual %8.1f kN  Ps residual %8.1f kN\n",
            (dem_pu + w.pu - total_pu) / 1000, (dem_ps + w.ps - total_ps) / 1000)
    flush(stdout)
end

_xyz(n) = [round(ustrip(u"m", x); digits = 3) for x in n.position]

function _degenerate_shells(model)
    println("shells with area < 1e-4 m² or a corner under 1°")
    shown = 0
    smallest = Inf
    for sh in model.shell_elements
        p = [_xyz(n) for n in sh.nodes]
        a, b = p[2] .- p[1], p[3] .- p[1]
        area = sqrt(sum(abs2, (
            a[2] * b[3] - a[3] * b[2],
            a[3] * b[1] - a[1] * b[3],
            a[1] * b[2] - a[2] * b[1]))) / 2
        smallest = min(smallest, area)
        ang = minimum(1:3) do k
            u = p[mod1(k + 1, 3)] .- p[k]
            v = p[mod1(k + 2, 3)] .- p[k]
            acosd(clamp(sum(u .* v) / (sqrt(sum(abs2, u)) * sqrt(sum(abs2, v)) + 1e-300), -1, 1))
        end
        (area < 1e-4 || ang < 1.0) || continue
        shown += 1
        shown <= 15 && @printf("  %s  area %.3e m²  min angle %.3g°  at %s\n",
                               sh.id, area, ang, string(p))
    end
    println("  degenerate: ", shown, " of ", length(model.shell_elements),
            "   smallest area ", smallest)
    flush(stdout)
end

function _pivots(model)
    idx = model.freeDOFs
    K = model.S[idx, idx]
    println("free DOFs ", length(idx), "  factorizing")
    flush(stdout)
    F = ldlt(Symmetric(K); check = false)
    issuccess(F) || (println("LDLᵀ failed"); return)
    d = Vector(diag(sparse(F.LD)))
    p = F.p
    kd = diag(K)
    println("pivots: negative ", count(<(0), d), "  of ", length(d))
    owner = Dict{Int, Tuple{Any, Int}}()
    for node in model.nodes, (k, g) in enumerate(node.globalID)
        owner[g] = (node, k)
    end
    shown = 0
    summary = Dict{String, Int}()
    for i in eachindex(d)
        j = p[i]
        soft = d[i] < 0 || abs(d[i]) <= 1e-8 * max(abs(kd[j]), 1.0)
        soft || continue
        node, k = owner[idx[j]]
        on = String[]
        key = DOF_NAME[k] * " " * string(node.id)
        summary[key] = get(summary, key, 0) + 1
        shown += 1
        shown <= 12 && @printf("  pivot %.3e  diag %.3e  %s  node %s %s\n",
                               d[i], kd[j], DOF_NAME[k], node.id, string(_xyz(node)))
    end
    println("  soft pivots: ", shown)
    for (k, c) in sort!(collect(summary); by = last, rev = true)[1:min(end, 8)]
        println("    ", c, " × ", k)
    end
    flush(stdout)
end

println("load ", design_path)
flush(stdout)
design = load_design(design_path)
println()
println("1. column steel")
_column_steel(design)
println()
println("2. reactions")
_reactions(design.structure)
println()
println("3. service model stiffness")
flush(stdout)
t = @elapsed build_analysis_model!(design)
println("  built in ", round(t; digits = 1), " s")
model = design.asap_model
_degenerate_shells(model)
_pivots(model)
