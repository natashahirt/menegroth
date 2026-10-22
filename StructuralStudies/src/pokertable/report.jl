# Text report for a solved poker-table model.

using Asap
using Unitful
using Printf
using LinearAlgebra: norm

function max_uz_inch(model)
    uz = [model.u[n.globalID[3]] for n in model.nodes]  # meters, +up
    i = argmin(uz)  # most downward
    return uconvert(u"inch", uz[i] * u"m"), model.nodes[i]
end

function foot_reactions(result)
    feet = filter(n -> n.id in (:foot, :endfoot), result.model.nodes)
    rows = NamedTuple[]
    for n in unique(feet)
        Rx = ustrip(u"lbf", n.reaction[1])
        Ry = ustrip(u"lbf", n.reaction[2])
        Rz = ustrip(u"lbf", n.reaction[3])
        Rh = hypot(Rx, Ry)
        μ = Rz > 1e-6 ? Rh / Rz : Inf
        x, y = _xy_inch(n)
        push!(rows, (; id = n.id, x, y, Rx, Ry, Rz, μ, uplift = Rz < -1e-3))
    end
    return rows
end

function axial_by_group(frames)
    groups = Dict{Symbol, Vector{Float64}}()
    for el in frames
        P = el.forces[1]  # N, local axial
        push!(get!(groups, el.id, Float64[]), ustrip(u"lbf", P * u"N"))
    end
    return groups
end

function print_report(result)
    g = result.g
    println("=" ^ 64)
    println("Poker table seed solve  ·  state=$(result.state)  ·  case=$(result.case)")
    println("leaf_support=$(g.leaf_support)  core=$(g.core_length)×$(g.width) in  apex=±$(g.support_x)")
    println("=" ^ 64)
    println()
    println("Mesh: $(result.model.nShellElements) shells, $(result.model.nFrameElements) frame members, $(result.model.nNodes) nodes")
    println("Hinge links: $(length(result.top.links))")
    al_lb = round(ustrip(u"lb", aluminum_mass_lb(result.frames)); digits = 2)
    wood_lb = round(ustrip(u"lb", wood_mass_lb(g; deploy = result.state === :poker)); digits = 2)
    t_in = round(ustrip(u"inch", WOOD_T); digits = 2)
    println("Wood t=$t_in in  plan mass=$wood_lb lb")
    println("Aluminum mass (deployed members in this state): $al_lb lb")
    println()

    uz, node = max_uz_inch(result.model)
    x, y = _xy_inch(node)
    @printf "Max downward uz = %.3f in at (%.1f, %.1f) id=%s\n" ustrip(u"inch", uz) x y node.id

    if result.state === :poker
        for (label, S) in zip(("-x apex", "+x apex"), result.base.S)
            uzi = uconvert(u"inch", result.model.u[S.globalID[3]] * u"m")
            @printf "  %s uz = %.3f in\n" label ustrip(u"inch", uzi)
        end
    end
    println()

    println("Foot reactions (lbf). Uplift = Rz < 0.  μ_req = |Rh|/Rz")
    any_uplift = false
    μ_max = 0.0
    for r in foot_reactions(result)
        any_uplift |= r.uplift
        isfinite(r.μ) && (μ_max = max(μ_max, r.μ))
        @printf "  %-8s (%6.1f, %6.1f)  Rz=%7.1f  Rh=%6.1f  μ=%.3f%s\n" r.id r.x r.y r.Rz hypot(r.Rx, r.Ry) r.μ (r.uplift ? "  UPLIFT" : "")
    end
    println(any_uplift ? "  FAIL: uplift at a rubber foot" : "  no-uplift: pass")
    @printf "  max μ_required = %.3f\n" μ_max
    rz_sum = sum(r.Rz for r in foot_reactions(result))
    @printf "  ΣRz = %.1f lbf (vertical equilibrium check)\n" rz_sum
    println()

    println("Peak |axial| by member group (lbf)")
    for (id, vals) in sort(collect(axial_by_group(result.frames)); by = first)
        @printf "  %-8s  n=%2d  max|P|=%7.1f\n" id length(vals) maximum(abs, vals)
    end
    println()
    println("Materials are ENGINEERING JUDGMENT (no NDS/APA/ADM in corpus).")
    println("Live 250 lbf / 50 lbf-per-player are furniture judgment, not ASCE 7 occupancy.")
end
