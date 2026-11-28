#=
Check that every wall triangle in a scene names a wall record.

    julia --project=StructuralSynthesizer scripts/runners/check_scene_shell_wall.jl [scene.mgscene]

Default scene: viewer/public/core_office.mgscene.
=#

using StructuralSynthesizer

path = isempty(ARGS) ? joinpath(@__DIR__, "..", "..", "viewer", "public", "core_office.mgscene") : ARGS[1]
packet = read_scene(path)
kinds = scene_u8(packet, "shell_kind")
walls = scene_u32(packet, "shell_wall")
length(walls) == length(kinds) || error("shell_wall has $(length(walls)) values for $(length(kinds)) triangles")
records = Set(Int(r["design_index"]) for r in packet.meta["components"] if r["kind"] == "wall")
on_wall = kinds .== 0x01
bad_kind = count(i -> on_wall[i] != (walls[i] > 0), eachindex(kinds))
missing = setdiff(Set(Int(w) for w in walls if w > 0), records)
per_wall = Dict{Int, Int}()
for w in walls
    w > 0 && (per_wall[Int(w)] = get(per_wall, Int(w), 0) + 1)
end
println("wall triangles: ", count(on_wall), "  with an owner: ", count(>(0), walls))
println("kind/owner mismatches: ", bad_kind, "  owners without a record: ", sort!(collect(missing)))
println("walls meshed: ", length(per_wall), " of ", length(records), " records;  triangles per wall ",
        extrema(values(per_wall)))
