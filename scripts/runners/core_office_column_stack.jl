#=
Column sizes per story in a saved core-office scene, and the scene fields
stored for each column.

    SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer \
        scripts/runners/core_office_column_stack.jl [logs/core_office_v6.mgscene]
=#

using StructuralSynthesizer

path = get(ARGS, 1, joinpath(@__DIR__, "..", "..", "logs", "core_office_v6.mgscene"))
packet = StructuralSynthesizer.read_scene(path)

buf(name) = only(b for b in packet.buffers if b.name == name).data
stories = reinterpret(UInt16, buf("element_story"))
axial = reinterpret(Float32, buf("element_axial"))
nodes = reinterpret(UInt32, buf("element_nodes"))
xyz = reinterpret(Float32, buf("node_position"))
sections = packet.meta["element_section"]

println("element  story  (x, y) bottom m   section            axial kN")
order = sortperm(collect(eachindex(stories)); by = i -> (stories[i], i))
for i in order
    a = nodes[2i - 1] + 1
    x, y = xyz[3a - 2], xyz[3a - 1]
    println(lpad(i, 7), "  ", lpad(Int(stories[i]), 5), "  (", lpad(round(x; digits = 1), 5), ", ",
            lpad(round(y; digits = 1), 5), ")   ", rpad(string(sections[i]), 18), " ",
            round(axial[i] / 1000; digits = 1))
end

trace = packet.meta["design_trace"]
println("\ndesign_trace: ", typeof(trace))
println("  summary: ", trace["summary"])
kinds = Dict{String, Int}()
for e in trace["events"]
    k = string(get(e, "stage", "?"), " / ", get(e, "event_type", get(e, "kind", "?")))
    kinds[k] = get(kinds, k, 0) + 1
end
println("  event kinds:")
for (k, n) in sort!(collect(kinds))
    println("    ", rpad(k, 50), n)
end
println("  column events:")
for e in trace["events"]
    s = string(e)
    occursin(r"(?i)column", s) || continue
    println("    ", first(s, 700))
end
