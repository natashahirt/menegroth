# Section-independent check of the steel_deck deflection failure on
# topology/r2c1: are the governing members CANTILEVERS (slab/framing
# overhanging past the end column)? The deflection spans depend only on the
# frame lines and their supports, not on the sections, so this runs fast
# (prepare! + to_asap!, no sizing).
#
# For every constant-level frame line it reports the deflection spans
# (`_deflection_spans`): :chord between supports, :tip0/:tip1 for a cantilever.
# A :tip span is an overhang; its length is the cantilever reach, and the
# deflection limit uses l = 2*reach, so even stiff sections fail a long one.
#
#     SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#         julia --project=StructuralStudies \
#         scripts/runners/diag_overhang_geometry.jl [plan] [system]

include(joinpath(@__DIR__, "sdf_nova_topology_systems.jl"))

using Printf

function main()
    plan = length(ARGS) >= 1 ? ARGS[1] : "topology/r2c1"
    system = length(ARGS) >= 2 ? Symbol(ARGS[2]) : :steel_deck
    @printf("=== %s  %s  (frame-line overhang geometry) ===\n", plan, system)
    params = nova_system_parameters(plan, system)

    struc = BuildingStructure(plan_skeleton(load_plan(plan)))
    prepare!(struc, params)
    to_asap!(struc; params = params, diaphragms = :none)
    SS.assign_framing_levels!(struc)

    lines = SS._constant_level_lines(struc, SS._frame_lines(struc))
    skel = struc.skeleton
    fixed = SS.beam_support_lookup(struc).fixed
    at = Dict{Int, Vector{Int}}()
    level_of = Vector{Int}(undef, length(lines))
    for (i, ln) in enumerate(lines)
        level_of[i] = struc.beams[ln.beams[1]].level
        for v in ln.verts
            push!(get!(at, v, Int[]), i)
        end
    end

    n_tip = 0; n_chord = 0
    chords = Tuple{Int, Float64, Int, Int}[]  # (line, length m, nsupports, nbeams)
    for (li, ln) in enumerate(lines)
        cum, xy = SS._line_stations(skel, ln.verts)
        total = cum[end]
        total > 1e-8 || continue
        sup = SS._line_support_stations(ln, li, lines, at, fixed, cum, level_of)
        spans = SS._deflection_spans(sup, total)
        for (s0, s1, kind) in spans
            if kind === :chord
                n_chord += 1
                push!(chords, (li, s1 - s0, length(sup), length(ln.beams)))
            else
                n_tip += 1
            end
        end
        @printf("line %-3d  total %5.2f m  supports %d  spans: %s\n", li, total, length(sup),
                join([@sprintf("%.2f%s", s1 - s0, kind === :chord ? "" : "[" * String(kind) * "]")
                      for (s0, s1, kind) in spans], ", "))
    end

    @printf("\nframe lines: %d   chord spans: %d   tip spans: %d\n",
            length(lines), n_chord, n_tip)
    sort!(chords; by = c -> -c[2])
    @printf("\nlongest CHORD spans (limit uses l = span; δ/l must be < 1/360):\n")
    @printf("  %-5s %-10s %-10s %-8s\n", "line", "span(m)", "nsupports", "nbeams")
    for c in chords[1:min(15, length(chords))]
        @printf("  %-5d %-10.3f %-10d %-8d\n", c[1], c[2], c[3], c[4])
    end
    lens = [c[2] for c in chords]
    @printf("\nchord span length: min %.2f  median %.2f  max %.2f m  (n=%d)\n",
            minimum(lens), lens[cld(length(lens), 2)], maximum(lens), length(lens))
end

main()
