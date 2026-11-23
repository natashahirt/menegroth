#=
Does the SOLVED e0c0 model's analysis frame break reflection symmetry, and where?

Narrowing so far (find-1d5f57f8 + probes): the e0c0 mesh is reflection-symmetric,
and the one-way tributary partition, span-axis choice, and signed-moment sign are
all reflection-covariant. The flange GEOMETRY was already shown symmetric. Yet the
design breaks both mirrors while keeping the 180deg rotation — so the carrier is an
orientation pseudoscalar (rotation-even, reflection-odd), and the only remaining
place it can live is the DISCRETE grillage that generates demands (e0c0 waffle
falls back to one-way joists) OR an emergent solve/tie-break divergence.

This run discriminates the two:
  * Reflect every horizontal analysis frame element across y=10. If the element
    set does NOT map to itself, the GRILLAGE is the chiral carrier (geometric,
    present from iteration 1).
  * If the frame IS reflection-symmetric but the four hub girders (B11/B27/B44/B55)
    still get mirror-broken sections, the break is EMERGENT in the solve/sizing.

    SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
        julia --project=StructuralStudies scripts/runners/sdf_e0c0_grillage_symmetry.jl
=#

include(joinpath(@__DIR__, "sdf_rib_design.jl"))

const SSy = StructuralSynthesizer

_r(x) = round(x; digits = 3)

# (x,y,z) meters of an Asap node position.
_xyz(p) = (ustrip(u"m", p[1]), ustrip(u"m", p[2]), ustrip(u"m", p[3]))

function main(plan = "star/e0c0")
    struc0 = BuildingStructure(plan_skeleton(load_plan(plan)))
    design = design_building(struc0, rib_parameters(plan, :waffle))
    struc = design.structure
    model = design.asap_model === nothing ? struc.asap_model : design.asap_model

    # Reflection axis from the plan bounds.
    skel = struc.skeleton
    ys = [SSy._vertex_xy_m(skel, v)[2] for v in 1:length(skel.vertices)]
    axisy = (minimum(ys) + maximum(ys)) / 2
    println("\n===== e0c0 SOLVED-FRAME REFLECTION SYMMETRY (axis y=", _r(axisy), ") =====")

    # --- 1. Horizontal (floor) frame elements: reflect endpoints, check set maps to itself.
    key(a, b) = begin  # order-independent, rounded endpoint-pair key
        ka = (round(a[1]; digits=3), round(a[2]; digits=3), round(a[3]; digits=3))
        kb = (round(b[1]; digits=3), round(b[2]; digits=3), round(b[3]; digits=3))
        ka <= kb ? (ka, kb) : (kb, ka)
    end
    refl(p) = (p[1], 2axisy - p[2], p[3])

    horiz = Tuple{Any,Any}[]
    for el in model.frame_elements
        a = _xyz(el.nodeStart.position); b = _xyz(el.nodeEnd.position)
        abs(a[3] - b[3]) <= 1e-3 || continue          # horizontal only
        abs(a[3]) <= 1e-3 && continue                  # skip grade/ground level if any
        push!(horiz, (a, b))
    end
    present = Set(key(a, b) for (a, b) in horiz)
    missing_mirror = Tuple[]
    for (a, b) in horiz
        key(refl(a), refl(b)) in present || push!(missing_mirror, (a, b))
    end
    println("horizontal floor frame elements: ", length(horiz))
    println("elements whose mirror image is ABSENT: ", length(missing_mirror))
    for (a, b) in sort(missing_mirror)[1:min(end, 16)]
        println("   (", _r(a[1]), ",", _r(a[2]), ")->(", _r(b[1]), ",", _r(b[2]), ")  z=", _r(a[3]))
    end

    # --- 2. The four hub girders from (12,10): sections + whether mirrors match.
    hub = (12.0, 10.0)
    targets = Dict("NE(18,15)" => (18.0, 15.0), "NW(6,15)" => (6.0, 15.0),
                   "SE(18,5)"  => (18.0, 5.0),  "SW(6,5)"  => (6.0, 5.0))
    xy(v) = SSy._vertex_xy_m(skel, v)
    near(p, q) = hypot(p[1]-q[1], p[2]-q[2]) <= 1e-3
    beam_ends(b) = begin
        vs = SSy._ordered_chain_vertices(skel, [struc.segments[si].edge_idx for si in SSy.segment_indices(b)])
        (xy(vs[1]), xy(vs[end]))
    end
    println("\nhub girders (section name):")
    for (lab, far) in sort(collect(targets))
        for (bi, b) in enumerate(struc.beams)
            p, q = beam_ends(b)
            ((near(p, hub) && near(q, far)) || (near(q, hub) && near(p, far))) || continue
            sec = try; string(section(b).name); catch; "(n/a)"; end
            println("   ", lpad(lab, 10), "  Beam ", bi, "  ", sec)
            break
        end
    end

    println("\nVERDICT: ",
            isempty(missing_mirror) ?
            "solved frame IS reflection-symmetric => break is EMERGENT in the solve/sizing (tie-break / discrete path), not the grillage geometry." :
            "solved frame is NOT reflection-symmetric => the GRILLAGE geometry is the chiral carrier (present from iteration 1).")
    println("===== END =====\n")
    return nothing
end

main(get(ENV, "DIAG_PLAN", "star/e0c0"))
