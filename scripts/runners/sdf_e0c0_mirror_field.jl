#=
Mirror-field covariance test for the e0c0 hub-girder chirality.

Decides whether the converged chiral section field is a BISTABLE pair (two
equally valid mirror solutions; the solver merely locked onto one handedness via
a discrete tie-break) or the product of a reflection-ODD bug in the FEA / demand
path.

Procedure, in one process:
  1. Converge the e0c0 waffle design -> chiral field F (NE=SW=A, NW=SE=B).
  2. Record each hub girder's signed-moment field M(s) under F.
  3. Build the x=12 reflection map (x -> 24-x) over the floor frame elements and
     install the MIRROR field M(F): every floor element takes its mirror
     partner's section. Re-solve the Asap model.
  4. Record each hub girder's M(s) under M(F).

VERDICT:
  * If demands SWAP under the mirror — M(s) of NE under M(F) == M(s) of NW under
    F (up to s-reversal), and likewise SE<->SW — then the FEA/demand path is
    reflection-COVARIANT and M(F) carries the mirrored demands, so M(F) is also a
    fixed point => BISTABLE. The fix is a reflection-invariant tie-break / seed.
  * If the demands do NOT swap, a reflection-odd input remains in the FEA or
    demand extraction => genuine bug to fix there.

    SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
        julia --project=StructuralStudies scripts/runners/sdf_e0c0_mirror_field.jl
=#

include(joinpath(@__DIR__, "sdf_rib_design.jl"))

const SSm = StructuralSynthesizer
const AXIS = 24.0  # x -> AXIS - x reflects across x = 12
_r(x) = round(x; digits = 1)
_xyz(p) = (ustrip(u"m", p[1]), ustrip(u"m", p[2]), ustrip(u"m", p[3]))

_moment_samples(struc, beam) = begin
    M_of_s, _ = SSm.beam_signed_moment_field(struc, beam)
    [round(ustrip(u"kN*m", M_of_s(s)); digits = 1) for s in 0.0:0.1:1.0]
end

"""Hub girders as label => beam, keyed by far corner (hub = (12,10))."""
function hub_girders(struc)
    skel = struc.skeleton
    xy(v) = SSm._vertex_xy_m(skel, v)
    hub = (12.0, 10.0)
    far = ("NE" => (18.0, 15.0), "NW" => (6.0, 15.0),
           "SE" => (18.0, 5.0), "SW" => (6.0, 5.0))
    near(p, q) = hypot(p[1] - q[1], p[2] - q[2]) <= 1e-3
    ends(b) = (vs = SSm._ordered_chain_vertices(skel,
                 [struc.segments[si].edge_idx for si in SSm.segment_indices(b)]);
               (xy(vs[1]), xy(vs[end])))
    out = Pair{String, Any}[]
    for (lab, f) in far
        for b in struc.beams
            p, q = ends(b)
            ((near(p, hub) && near(q, f)) || (near(q, hub) && near(p, f))) || continue
            push!(out, lab => b); break
        end
    end
    return out
end

_secname(b) = try; string(section(b).name); catch; "(n/a)"; end

"""Floor (horizontal, elevated) frame-element indices of the Asap model."""
function floor_elements(m)
    idx = Int[]
    for (i, el) in enumerate(m.frame_elements)
        a = _xyz(el.nodeStart.position); b = _xyz(el.nodeEnd.position)
        (abs(a[3] - b[3]) <= 1e-3 && a[3] > 1e-3) || continue
        push!(idx, i)
    end
    return idx
end

"""element index => its x=12 mirror partner index, matched on reflected endpoints."""
function mirror_map(m, idx)
    key(a, b) = begin
        ka = (round(a[1]; digits = 3), round(a[2]; digits = 3), round(a[3]; digits = 3))
        kb = (round(b[1]; digits = 3), round(b[2]; digits = 3), round(b[3]; digits = 3))
        ka <= kb ? (ka, kb) : (kb, ka)
    end
    bykey = Dict{Any, Int}()
    for i in idx
        a = _xyz(m.frame_elements[i].nodeStart.position)
        b = _xyz(m.frame_elements[i].nodeEnd.position)
        bykey[key(a, b)] = i
    end
    refl(p) = (AXIS - p[1], p[2], p[3])
    partner = Dict{Int, Int}()
    for i in idx
        a = _xyz(m.frame_elements[i].nodeStart.position)
        b = _xyz(m.frame_elements[i].nodeEnd.position)
        j = get(bykey, key(refl(a), refl(b)), 0)
        j != 0 && (partner[i] = j)
    end
    return partner
end

"""Closeness of two moment-sample vectors, allowing s-reversal."""
_swap_diff(u, v) = min(maximum(abs.(u .- v); init = 0.0),
                       maximum(abs.(u .- reverse(v)); init = 0.0))

function main(plan = "star/e0c0")
    println("\n===== e0c0 MIRROR-FIELD COVARIANCE =====")
    p = rib_parameters(plan, :waffle)
    p.max_iterations = 12
    struc = BuildingStructure(plan_skeleton(load_plan(plan)))
    design_building(struc, p; restore = false)
    m = struc.asap_model

    gc = hub_girders(struc)
    println("\n[CONVERGED] hub girders under field F:")
    before = Dict{String, Vector{Float64}}()
    for (lab, b) in gc
        before[lab] = _moment_samples(struc, b)
        println("   ", lpad(lab, 3), "  ", _secname(b), "   M(s)=", before[lab])
    end

    idx = floor_elements(m)
    partner = mirror_map(m, idx)
    unmatched = count(i -> !haskey(partner, i), idx)
    println("\n[MIRROR] floor elements=", length(idx),
            "  matched=", length(partner), "  unmatched=", unmatched)

    # Install the mirror field M(F): each element takes its partner's section.
    orig = Dict(i => m.frame_elements[i].section for i in idx)
    for i in idx
        j = get(partner, i, 0)
        j != 0 && (m.frame_elements[i].section = orig[j])
    end
    Asap.process!(m); Asap.solve!(m)

    println("\n[MIRRORED] hub girders under field M(F):")
    after = Dict{String, Vector{Float64}}()
    for (lab, b) in gc
        after[lab] = _moment_samples(struc, b)
        println("   ", lpad(lab, 3), "  M(s)=", after[lab])
    end

    # Covariance check: under x-mirror, NE<->NW and SE<->SW. The mirrored field
    # should hand each girder its partner's original demand (up to s-reversal).
    println("\n[COVARIANCE] after[X] vs before[mirror(X)] (max |Δ| kN·m, s-reversal allowed):")
    worst = 0.0
    for (a, b) in (("NE", "NW"), ("NW", "NE"), ("SE", "SW"), ("SW", "SE"))
        (haskey(after, a) && haskey(before, b)) || continue
        d = _swap_diff(after[a], before[b])
        worst = max(worst, d)
        println("   ", a, " vs F[", b, "]  Δ=", _r(d))
    end
    println("\n  VERDICT: ", worst <= 1.0 ?
            "demands SWAP under mirror (Δ=$(_r(worst))) => FEA/demand reflection-COVARIANT; " *
            "the chiral field is one of a BISTABLE mirror pair. Fix = symmetric tie-break/seed." :
            "demands do NOT swap (Δ=$(_r(worst))) => reflection-ODD input in FEA/demand path (bug there).")
    println("===== END =====\n")
    return nothing
end

main(get(ENV, "DIAG_PLAN", "star/e0c0"))
