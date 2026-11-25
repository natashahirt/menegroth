#=
Pass-0 handedness localization for star/e0c0 hub girders.

Prior probes narrowed the chirality: the mesh is reflection-symmetric, the
one-way tributary PARTITION is reflection-covariant (Δ=0), and the FEA/demand
path is covariant given mirrored sections. So the carrier is a handedness in the
sizing-side CONVENTIONS, not the analysis. This probe pins which one, on a
UNIFORM-STIFFNESS frame (every floor element set to one shared section — removes
any already-diverged section feedback), by dumping for the four hub girders:

  (A) beam_side_profiles(struc, beam)  -> per-side tributary extent profiles
      (geometry only; tests the LEFT/RIGHT labeling in _edge_perside_canonical).
  (B) beam_signed_moment_field         -> sagging/hogging convention.

Mirror reading across y=10 (NE<->SE, NW<->SW), the shared hub sits on the axis so
s is preserved:
  * signed moments equal per station  => moment convention is covariant.
  * side profiles: a covariant labeling has NE.left == SE.right (values mirror,
    sides swap). If instead NE.left == SE.left (same label, same values) the
    left/right assignment is reflection-FLIPPED -> the handedness carrier.

A short (max_iterations low) design just sets up tributaries + loads; the test
then overwrites stiffness uniformly, so the convergence state does not matter.

    SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
        julia --project=StructuralStudies scripts/runners/sdf_e0c0_pass0_handedness.jl
=#

include(joinpath(@__DIR__, "sdf_rib_design.jl"))

const SSy = StructuralSynthesizer
_r(x) = round(x; digits = 3)
_xyz(p) = (ustrip(u"m", p[1]), ustrip(u"m", p[2]), ustrip(u"m", p[3]))

"""Signed moment field (kN·m, sagging +) sampled at s = 0,0.1,…,1."""
function _moment_samples(struc, beam)
    M_of_s, _ = SSy.beam_signed_moment_field(struc, beam)
    return [round(ustrip(u"kN*m", M_of_s(s)); digits = 1) for s in 0.0:0.1:1.0]
end

"""Flatten a per-side profile (SideExtentProfile / (pos,extent) / nothing) to a
short `(positions, extents_m)` string for printing."""
function _fmt_side(p)
    p === nothing && return "nothing (slab edge)"
    pos = hasproperty(p, :positions) ? p.positions :
          (p isa Tuple ? p[1] : getfield(p, 1))
    ext = hasproperty(p, :extents_m) ? p.extents_m :
          hasproperty(p, :extents) ? p.extents :
          (p isa Tuple ? p[2] : getfield(p, 2))
    return "pos=$(_r.(collect(pos)))  ext_m=$(_r.(collect(ext)))"
end

"""The four hub girders by far-end label -> Beam object."""
function _hub_girders(struc)
    skel = struc.skeleton
    xy(v) = SSy._vertex_xy_m(skel, v)
    hub = (12.0, 10.0)
    far = Dict("NE(18,15)" => (18.0, 15.0), "NW(6,15)" => (6.0, 15.0),
               "SE(18,5)" => (18.0, 5.0), "SW(6,5)" => (6.0, 5.0))
    near(p, q) = hypot(p[1] - q[1], p[2] - q[2]) <= 1e-3
    ends(b) = (vs = SSy._ordered_chain_vertices(skel,
                 [struc.segments[si].edge_idx for si in SSy.segment_indices(b)]);
               (xy(vs[1]), xy(vs[end])))
    out = Pair{String, Any}[]
    for (lab, f) in sort(collect(far))
        for b in struc.beams
            p, q = ends(b)
            ((near(p, hub) && near(q, f)) || (near(q, hub) && near(p, f))) || continue
            push!(out, lab => b); break
        end
    end
    return out
end

function main(plan = "star/e0c0")
    p = rib_parameters(plan, :waffle)
    p.max_iterations = parse(Int, get(ENV, "PASS0_ITERS", "1"))
    struc0 = BuildingStructure(plan_skeleton(load_plan(plan)))
    design = design_building(struc0, p; restore = false)
    struc = design.structure
    model = design.asap_model === nothing ? struc.asap_model : design.asap_model

    girders = _hub_girders(struc)

    # Uniform stiffness: one shared section on every horizontal floor element.
    ref = nothing; floor_idx = Int[]
    for (i, el) in enumerate(model.frame_elements)
        a = _xyz(el.nodeStart.position); b = _xyz(el.nodeEnd.position)
        (abs(a[3] - b[3]) <= 1e-3 && a[3] > 1e-3) || continue
        push!(floor_idx, i)
        ref === nothing && (ref = el.section)
    end
    for i in floor_idx
        model.frame_elements[i].section = ref
    end
    Asap.process!(model); Asap.solve!(model)
    println("\n===== e0c0 PASS-0 HANDEDNESS (uniform stiffness, $(length(floor_idx)) floor els) =====")

    println("\n[A] beam_side_profiles (geometry; LEFT / RIGHT per girder):")
    sides = Dict{String, Any}()
    for (lab, b) in girders
        l, r = SSy.beam_side_profiles(struc, b)
        sides[lab] = (l, r)
        println("  ", lpad(lab, 10))
        println("        LEFT : ", _fmt_side(l))
        println("        RIGHT: ", _fmt_side(r))
    end

    println("\n[B] beam_signed_moment_field M(s) kN·m (sagging +):")
    mom = Dict{String, Any}()
    for (lab, b) in girders
        mom[lab] = _moment_samples(struc, b)
        println("  ", lpad(lab, 10), "  ", mom[lab])
    end

    println("\n[C] mirror comparison across y=10:")
    for (p1, p2) in (("NE(18,15)", "SE(18,5)"), ("NW(6,15)", "SW(6,5)"))
        (haskey(mom, p1) && haskey(mom, p2)) || continue
        dM = maximum(abs.(mom[p1] .- mom[p2]); init = 0.0)
        println("   $p1 vs $p2 :  |ΔM(s)| max = ", _r(dM), " kN·m",
                dM <= 0.5 ? "  (moment covariant)" : "  (moment CHIRAL)")
    end
    println("\n  (inspect [A]: covariant labeling => NE.LEFT matches SE.RIGHT;")
    println("   same-label match (NE.LEFT == SE.LEFT) => reflection-flipped side labeling.)")
    println("===== END =====\n")
    return nothing
end

main(get(ENV, "DIAG_PLAN", "star/e0c0"))
