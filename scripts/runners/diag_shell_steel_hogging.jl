# Where does the hogging on single-bay steel beams in the 2×2 story shell come from?
#
#   julia --project=StructuralSynthesizer scripts/runners/diag_shell_steel_hogging.jl
#
# Same building as story_shell_multibay.jl, with the sections that run chose
# set directly (no sizing loop) and no composite profile (bare steel).

ENV["SS_ENABLE_VISUALIZATION"] = "false"
ENV["SS_SKIP_SOLVER_WARMUP"] = "true"

using Printf
using Asap
using Unitful
using StructuralSynthesizer
using StructuralSizer
const SY = StructuralSynthesizer

skel = gen_medium_office(40.0u"ft", 40.0u"ft", 12.0u"ft", 2, 2, 1)
struc = BuildingStructure(skel)
initialize!(struc; floor_type = :one_way, floor_opts = OneWayOptions(),
            loads = GravityLoads(floor_LL = 50.0u"psf", floor_SDL = 15.0u"psf",
                                 roof_LL = 30.0u"psf", roof_SDL = 15.0u"psf"))
for col in struc.columns
    set_section!(col, W("W14X90"))
end
to_asap!(struc; params = DesignParameters(beams = SteelBeamOptions()), diaphragms = :none)

level = only(SY._story_shell_levels(struc))
z_roof = ustrip(u"m", skel.stories_z[level + 1])
roof = [i for (i, b) in enumerate(struc.beams)
        if all(v -> abs(SY.vertex_coords(skel, v).z - z_roof) < 1e-6,
               SY._story_vertex_chain(struc, b))]
println("roof beams: ", roof)

println("slab span axes: ", unique([c.spans.axis for c in struc.cells if c.floor_type !== :grade]))
for i in roof
    b = struc.beams[i]
    chain = SY._story_vertex_chain(struc, b)
    a, z = SY.vertex_coords(skel, first(chain)), SY.vertex_coords(skel, last(chain))
    dir = abs(z.x - a.x) > abs(z.y - a.y) ? "x" : "y"
    set_section!(b, i in 19:24 ? W("W27X84") : W("W16X26"))
    rel = SY._story_beam_release(struc, b, chain, A992_Steel)
    @printf("beam %2d  dir=%s  (%.2f,%.2f)->(%.2f,%.2f)  role=%s  lateral=%s  nseg=%d  release=%s\n",
            i, dir, a.x, a.y, z.x, z.y, b.role, b.lateral_role,
            length(SY.segment_indices(b)), rel)
end

edge = isempty(ARGS) ? 1.0 : parse(Float64, ARGS[1])
println("target_edge = $edge m")
res = analyze_story_shell(struc, level; target_edge = edge * u"m", service = false,
                          steel = A992_Steel)
println("status=", res.analysis_status, "  reasons=", res.reasons)
println("springs=", length(res.model.springs))

for i in (13, 15, 19, 21)
    id = Symbol("beam_", i)
    pieces = [el for el in res.built.frames if el.id === id]
    types = [string(typeof(el).parameters[1]) for el in pieces]
    println("\nbeam $i  pieces=$(length(pieces))  releases=$(types)")
    d = res.beam_demands[i]
    @printf("  envelope Mu+=%.1f kN·m  Mu-=%.1f kN·m\n", d.Mu_pos / 1e3, d.Mu_neg / 1e3)
    println("  eccentricity = ", first(pieces).eccentricity)
    # Full factored load on every panel (the solved model), per piece:
    # P (kN, +tension), sign-corrected sagging My at start/end (kN·m, about slab mid-plane).
    loads = Asap.get_elemental_loads(
        Asap.AbstractLoad[ld for ld in res.model.loads if ld isa Asap.GravityLoad],
        length(res.model.frame_elements))
    for (k, el) in enumerate(pieces)
        f = SY._element_forces_from_u(el, res.model.u, loads[el.elementID]; resolution = 5)
        sgn = el.LCS[2][3] > 0 ? 1.0 : -1.0
        x0 = SY._plan_xy(el.nodeStart)
        @printf("  piece %d  start=(%.2f,%.2f)  P=%8.1f  M_start=%7.1f  M_mid=%7.1f  M_end=%7.1f  Vy=%6.1f\n",
                k, x0..., f.P[1] / 1e3, sgn * f.My[1] / 1e3, sgn * f.My[3] / 1e3,
                sgn * f.My[end] / 1e3, f.Vy[1] / 1e3)
    end
end
