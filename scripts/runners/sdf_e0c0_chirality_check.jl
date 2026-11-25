#=
Chirality verification for star/e0c0 (waffle framing).

Runs the full e0c0 waffle design in-place (`restore=false`, so the mutated
`struc` is left available to inspect) and prints the final installed section of
each of the four hub girders, labelled by their far corner. On a non-chiral
plan the reflection-covariant settle (see `check_settle.jl`) should give:

    NE == NW == SE == SW     (both mirror axes respected)

Pre-fix the signature was NE == SW != NW == SE (C2 only; reflection broken).

    SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
        julia --project=StructuralStudies scripts/runners/sdf_e0c0_chirality_check.jl
=#

include(joinpath(@__DIR__, "sdf_rib_design.jl"))

const SSc = StructuralSynthesizer

"""Final section of each hub girder (hub -> far corner), labelled by corner."""
function hub_girder_sections(struc)
    skel = struc.skeleton
    hub = (12.0, 10.0)
    far = ("NE" => (18.0, 15.0), "NW" => (6.0, 15.0),
           "SE" => (18.0, 5.0), "SW" => (6.0, 5.0))
    near(p, q) = hypot(p[1] - q[1], p[2] - q[2]) <= 1e-3
    out = Tuple{String, String}[]
    for (lab, f) in far
        for b in struc.beams
            edges = [struc.segments[si].edge_idx for si in SSc.segment_indices(b)]
            isempty(edges) && continue
            vs = SSc._ordered_chain_vertices(skel, edges)
            (isempty(vs) || length(vs) < 2) && continue
            p0 = SSc._vertex_xy_m(skel, vs[1]); p1 = SSc._vertex_xy_m(skel, vs[end])
            if (near(p0, hub) && near(p1, f)) || (near(p1, hub) && near(p0, f))
                sec = SSc._story_beam_section(struc, b)
                nm = sec === nothing ? "(none)" :
                     (hasproperty(sec, :name) ? string(sec.name) : string(sec))
                push!(out, (lab, nm))
                break
            end
        end
    end
    return out
end

function main(plan = "star/e0c0")
    println("\n===== e0c0 CHIRALITY CHECK =====")
    p = rib_parameters(plan, :waffle)
    p.max_iterations = 12
    struc = BuildingStructure(plan_skeleton(load_plan(plan)))
    design_building(struc, p; restore = false)
    secs = hub_girder_sections(struc)
    println("\nHub girder final sections:")
    for (lab, nm) in secs
        println("  $lab  $nm")
    end
    d = Dict(secs)
    if haskey(d, "NE") && haskey(d, "NW") && haskey(d, "SE") && haskey(d, "SW")
        mirror_x = d["NE"] == d["NW"] && d["SE"] == d["SW"]
        mirror_y = d["NE"] == d["SE"] && d["NW"] == d["SW"]
        println("\n  mirror across x=12 (NE==NW, SE==SW): ", mirror_x)
        println("  mirror across y=10 (NE==SE, NW==SW): ", mirror_y)
        println("  fully non-chiral (all four equal):   ",
                mirror_x && mirror_y && d["NE"] == d["SE"])
    end
    println("===== END =====\n")
    return nothing
end

main(get(ENV, "DIAG_PLAN", "star/e0c0"))
