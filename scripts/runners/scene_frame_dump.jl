# Dump the frame of one scene variant: nodes, elements, and section names.
#
#     SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#         julia --project=StructuralSynthesizer scripts/runners/scene_frame_dump.jl <scene> [variant] [out.tsv]

using StructuralSynthesizer
const SY = StructuralSynthesizer

function main(args)
    path = args[1]
    index = SY.read_variant_index(path)
    id = length(args) >= 2 ? args[2] : String(index["variants"][1]["id"])
    out = length(args) >= 3 ? args[3] : "logs/scene_frame_dump.tsv"
    packet = SY.materialize_variant(path, id)
    pos = SY.scene_f32(packet, "node_position")
    pairs = SY.scene_u32(packet, "element_nodes")
    names = get(packet.meta, "element_section", String[])
    o = packet.origin
    mkpath(dirname(out))
    open(out, "w") do io
        println(io, "e\tx1\ty1\tz1\tx2\ty2\tz2\tsection")
        for e in 1:(length(pairs) ÷ 2)
            a, b = Int(pairs[2e - 1]) + 1, Int(pairs[2e]) + 1
            p(i, k) = round(pos[3(i - 1) + k] + o[k]; digits = 3)
            name = e <= length(names) ? String(names[e]) : ""
            println(io, e - 1, '\t', p(a, 1), '\t', p(a, 2), '\t', p(a, 3), '\t',
                    p(b, 1), '\t', p(b, 2), '\t', p(b, 3), '\t', name)
        end
    end
    println("wrote ", out, "  elements=", length(pairs) ÷ 2)
end

main(ARGS)
