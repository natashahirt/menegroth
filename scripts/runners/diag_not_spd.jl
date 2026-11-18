# Which degrees of freedom make the stiffness matrix not positive definite?
#
#   julia --project=StructuralSynthesizer scripts/runners/diag_not_spd.jl
#
# Same floor as diag_story_shell_sections.jl (54 ft × 42 ft, 3×3 bays, steel
# joists at 24 in, concrete girders). Every time Cholesky fails, the free-DOF
# stiffness is decomposed densely and its near-zero or negative modes are
# mapped back to nodes, DOF directions, and the elements on those nodes.
# Stops after the first few distinct failing models.

ENV["SS_ENABLE_VISUALIZATION"] = "false"
ENV["SS_SKIP_SOLVER_WARMUP"] = "true"

using LinearAlgebra
using Serialization
using SparseArrays
using Unitful
using Asap
using StructuralSynthesizer
using StructuralSizer

const SS = StructuralSynthesizer
const MAX_MODELS = 1
const SEEN = Set{UInt}()
const DOF_NAME = ("ux", "uy", "uz", "rx", "ry", "rz")

struct StopDiagnosis <: Exception end

"""Elements on each node, as `(kind, id, release)` strings."""
function _node_elements(model)
    out = IdDict{Any, Vector{String}}()
    frames = hasproperty(model, :frame_elements) ? model.frame_elements : model.elements
    for el in frames
        hasproperty(el, :nodeStart) || continue
        rel = string(typeof(el).parameters[1])
        tag = "frame $(el.id) #$(el.elementID) $rel"
        push!(get!(() -> String[], out, el.nodeStart), tag)
        push!(get!(() -> String[], out, el.nodeEnd), tag)
    end
    if hasproperty(model, :shell_elements)
        for sh in model.shell_elements, n in sh.nodes
            push!(get!(() -> String[], out, n), "shell $(sh.id)")
        end
    end
    return out
end

"""Free-DOF index → (node, direction 1–6)."""
function _dof_owner(model)
    owner = Dict{Int, Tuple{Any, Int}}()
    for node in model.nodes, (k, g) in enumerate(node.globalID)
        owner[g] = (node, k)
    end
    return owner
end

_xyz(node) = [round(x isa Unitful.Quantity ? ustrip(u"m", x) : Float64(x); digits = 3)
              for x in node.position]

"""
Negative and tiny pivots of a sparse LDLᵀ, each mapped to the DOF it
eliminates. A pivot is tiny when it is below 1e-10 of the DOF's own diagonal.
"""
function _pivot_report(model, K)
    F = ldlt(Symmetric(K); check = false)
    issuccess(F) || (println("LDLᵀ also failed"); return)
    d = Vector(diag(sparse(F.LD)))
    p = F.p
    kd = diag(K)
    owner = _dof_owner(model)
    gdof = model.freeDOFs
    elems = _node_elements(model)
    bad = Int[]
    for i in eachindex(d)
        j = p[i]
        (d[i] < 0 || abs(d[i]) <= 1e-10 * abs(kd[j])) && push!(bad, i)
    end
    println("pivots: negative=$(count(<(0), d))  tiny=$(length(bad) - count(<(0), d))")
    summary = Dict{String, Int}()
    for (m, i) in enumerate(bad)
        j = p[i]
        node, k = owner[gdof[j]]
        on = get(elems, node, String[])
        kinds = sort(unique(replace.(on, r" #\d+" => "")))
        key = "$(DOF_NAME[k]) at node $(node.id) with " * join(kinds, ", ")
        summary[key] = get(summary, key, 0) + 1
        m <= 12 && println("  pivot $(round(d[i]; sigdigits = 3)) (diag $(round(kd[j]; sigdigits = 3)))  " *
                           "$(DOF_NAME[k]) at node $(node.nodeID) $(node.id) $(_xyz(node))  " *
                           "elements: $(join(on, "; "))")
    end
    println("  pivot pattern counts:")
    for (k, c) in sort(collect(summary); by = last, rev = true)[1:min(end, 12)]
        println("    $c × $k")
    end
end

"""Save `K` and the DOF map so the pivots can be re-read without a design run."""
function _dump(model, K)
    path = joinpath(@__DIR__, "..", "..", "logs", "not_spd_model.jls")
    elems = _node_elements(model)
    nodes = [(id = n.nodeID, tag = n.id, xyz = _xyz(n), gid = copy(n.globalID),
              elements = get(elems, n, String[])) for n in model.nodes]
    serialize(path, (K = K, free = copy(model.freeDOFs), nodes = nodes))
    println("saved $(abspath(path))")
end

"""Frame pieces whose global stiffness has an entry above 1e15, with their inputs."""
function _huge_frames(model)
    frames = hasproperty(model, :frame_elements) ? model.frame_elements : model.elements
    println("frame pieces with max|K| > 1e15:")
    shown = 0
    for el in frames
        hasproperty(el, :K) || continue
        m = maximum(abs, el.K)
        m > 1e15 || continue
        shown += 1
        shown > 20 && continue
        s = el.section
        println("  $(el.id) #$(el.elementID) $(typeof(el).parameters[1])  max|K|=$(round(m; sigdigits = 3))" *
                "  L=$(el.length)  A=$(s.A)  E=$(s.E)  G=$(s.G)  Ix=$(s.Ix)  Iy=$(s.Iy)  J=$(s.J)" *
                "  Ay=$(s.Ay)  Az=$(s.Az)  ecc=$(el.eccentricity)")
    end
    println("  total: $shown")
end

"""Shell triangles with near-zero area or a near-zero corner angle."""
function _degenerate_shells(model)
    hasproperty(model, :shell_elements) || return
    println("shell triangles with area < 1e-4 m² or min angle < 1°:")
    shown = 0
    areas = Float64[]
    for sh in model.shell_elements
        p = [_xyz(n) for n in sh.nodes]
        a, b = p[2] .- p[1], p[3] .- p[1]
        area = norm(cross(a, b)) / 2
        push!(areas, area)
        ang = minimum(1:3) do k
            u = p[mod1(k + 1, 3)] .- p[k]
            v = p[mod1(k + 2, 3)] .- p[k]
            acosd(clamp(dot(u, v) / (norm(u) * norm(v) + 1e-300), -1, 1))
        end
        (area < 1e-4 || ang < 1.0) || continue
        shown += 1
        shown <= 20 && println("  $(sh.id)  area=$(round(area; sigdigits = 3))  min angle=$(round(ang; sigdigits = 3))°" *
                               "  nodes $(join([n.nodeID for n in sh.nodes], ", ")) at $(p)")
    end
    println("  total: $shown of $(length(areas)); smallest area $(minimum(areas))")
end

function diagnose(model, K)
    n = size(K, 1)
    println("\n=== not SPD: $(typeof(model).name.name)  nodes=$(length(model.nodes))  free DOFs=$n")
    _degenerate_shells(model)
    _huge_frames(model)
    _dump(model, K)
    n > 7000 && return _pivot_report(model, K)
    vals, vecs = eigen(Symmetric(Matrix(K)))
    scale = maximum(abs, vals)
    soft = findall(v -> v <= 1e-10 * scale, vals)
    println("eigenvalues: min=$(vals[1])  max=$(vals[end])  near-zero or negative: $(length(soft))")
    gdof = model.freeDOFs
    owner = _dof_owner(model)
    elems = _node_elements(model)
    summary = Dict{String, Int}()
    for (m, j) in enumerate(soft)
        v = vecs[:, j]
        top = sortperm(abs.(v); rev = true)[1:min(4, n)]
        for (r, i) in enumerate(top)
            abs(v[i]) < 0.2 * abs(v[top[1]]) && break
            node, k = owner[gdof[i]]
            p = [round(x isa Unitful.Quantity ? ustrip(u"m", x) : Float64(x); digits = 3)
                 for x in node.position]
            on = get(elems, node, String[])
            key = "$(DOF_NAME[k]) at node $(node.id) with " * join(sort(unique(replace.(on, r"#\d+ " => ""))), ", ")
            summary[key] = get(summary, key, 0) + 1
            m <= 8 && r == 1 &&
                println("  mode $m λ=$(round(vals[j]; sigdigits = 3))  $(DOF_NAME[k]) at node $(node.nodeID) $(node.id) $p  elements: $(join(on, "; "))")
        end
    end
    println("  mode pattern counts (dominant DOF, node kind, elements on it):")
    for (k, c) in sort(collect(summary); by = last, rev = true)[1:min(end, 12)]
        println("    $c × $k")
    end
end

@eval Asap function _get_factorization(model::AbstractModel)
    old = model._factorization
    if old !== nothing && !model._factorization_stale
        return old
    end
    idx = model.freeDOFs
    K = Symmetric(model.S[idx, idx])
    fact = cholesky(K; check = false)
    if !issuccess(fact)
        key = hash((length(model.nodes), length(idx)))
        if !(key in Main.SEEN)
            push!(Main.SEEN, key)
            Main.diagnose(model, model.S[idx, idx])
            length(Main.SEEN) >= Main.MAX_MODELS && throw(Main.StopDiagnosis())
        end
        fact = ldlt(K; check = false)
        issuccess(fact) || (fact = lu(model.S[idx, idx]))
    end
    model._factorization = fact
    model._factorization_stale = false
    model._factor_key = UInt(0)
    return fact
end

skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 1)
struc = BuildingStructure(skel)
api = SS.APIParams(
    floor_type = "one_way",
    skip_visualization = true,
    framing_levels = [
        SS.APIFramingLevel(material = "steel", spacing_in = 24.0),
        SS.APIFramingLevel(material = "concrete", role = "beam"),
    ],
)
params = json_to_params(api)
try
    design_building(struc, params)
    println("\ndesign finished; failing models seen: $(length(SEEN))")
catch err
    err isa StopDiagnosis || rethrow()
    println("\nstopped after $(length(SEEN)) failing models")
end
