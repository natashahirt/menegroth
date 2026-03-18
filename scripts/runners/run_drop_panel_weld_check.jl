using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))
using HTTP
using JSON3

const BASE = length(ARGS) >= 1 ? rstrip(ARGS[1], '/') : "http://127.0.0.1:8080"
const MAX_WAIT_S = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 600

function wait_for_idle!(base::AbstractString, max_wait_s::Int)
    for i in 1:max_wait_s
        resp = HTTP.get("$(base)/status"; readtimeout=10)
        if resp.status == 200
            status_obj = JSON3.read(String(resp.body))
            state = haskey(status_obj, :state) ? String(status_obj.state) : "unknown"
            if state == "idle"
                return
            end
        end
        sleep(1.0)
    end
    error("API did not reach idle within $(max_wait_s)s")
end

wait_for_idle!(BASE, MAX_WAIT_S)
resp = HTTP.get("$(BASE)/result"; readtimeout=30)
@assert resp.status == 200 "GET /result failed with status $(resp.status)"

obj = JSON3.read(String(resp.body))
@assert haskey(obj, :visualization) "Result missing visualization block"
viz = obj.visualization
@assert haskey(viz, :deflected_slab_meshes) "Visualization missing deflected_slab_meshes"

meshes = viz.deflected_slab_meshes

slab_ids = Int[]
for m in meshes
    @assert haskey(m, :slab_id) "A deflected slab mesh token is missing slab_id"
    push!(slab_ids, Int(m.slab_id))
end

counts = Dict{Int, Int}()
for sid in slab_ids
    counts[sid] = get(counts, sid, 0) + 1
end

dupes = sort([sid for (sid, c) in counts if c > 1])
@assert isempty(dupes) "Expected one deflected_slab_meshes token per slab_id; duplicates found for slab_id(s): $(dupes)"

function _face_components(faces::Vector{Vector{Int}}, nverts::Int)
    v_to_faces = [Int[] for _ in 1:max(nverts, 1)]
    for (fi, f) in enumerate(faces)
        for vi in f
            if 1 <= vi <= nverts
                push!(v_to_faces[vi], fi)
            end
        end
    end

    adj = [Int[] for _ in 1:length(faces)]
    for flist in v_to_faces
        if length(flist) <= 1
            continue
        end
        for i in 1:length(flist)
            fi = flist[i]
            for j in (i + 1):length(flist)
                fj = flist[j]
                push!(adj[fi], fj)
                push!(adj[fj], fi)
            end
        end
    end
    for i in 1:length(adj)
        adj[i] = unique(adj[i])
    end

    comp_id = fill(0, length(faces))
    cid = 0
    for i in 1:length(faces)
        comp_id[i] != 0 && continue
        cid += 1
        queue = [i]
        comp_id[i] = cid
        qh = 1
        while qh <= length(queue)
            fcur = queue[qh]
            qh += 1
            for fn in adj[fcur]
                if comp_id[fn] == 0
                    comp_id[fn] = cid
                    push!(queue, fn)
                end
            end
        end
    end
    return comp_id
end

for m in meshes
    sid = Int(m.slab_id)
    verts = haskey(m, :vertices) ? m.vertices : Vector{Any}()
    faces_raw = haskey(m, :faces) ? m.faces : Vector{Any}()
    faces = Vector{Vector{Int}}()
    for f in faces_raw
        if length(f) >= 3
            push!(faces, [Int(f[1]), Int(f[2]), Int(f[3])])
        end
    end
    isempty(faces) && continue

    dp_face_set = Set{Int}()
    if haskey(m, :drop_panel_meshes)
        for dpm in m.drop_panel_meshes
            if haskey(dpm, :face_indices)
                for fi in dpm.face_indices
                    fidx = Int(fi)
                    if 1 <= fidx <= length(faces)
                        push!(dp_face_set, fidx)
                    end
                end
            end
        end
    end

    isempty(dp_face_set) && continue
    if length(dp_face_set) == length(faces)
        # Entire slab token marked as drop panel faces; skip connectivity assertion.
        continue
    end

    comp = _face_components(faces, length(verts))
    comps_with_non_dp = Set(comp[i] for i in 1:length(faces) if !(i in dp_face_set))
    comps_with_dp = Set(comp[i] for i in dp_face_set)
    shared = intersect(comps_with_non_dp, comps_with_dp)

    @assert !isempty(shared) "Slab $sid has drop-panel faces disconnected from main slab faces (separate mesh island)"
end

println("Drop panel weld check passed:")
println("  deflected_slab_meshes tokens = $(length(meshes))")
println("  unique slab_ids = $(length(keys(counts)))")
println("  no duplicate slab_id tokens and no disconnected drop-panel face islands detected")
