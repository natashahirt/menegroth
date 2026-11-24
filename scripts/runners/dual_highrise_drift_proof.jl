#=
Dual-system drift-governor proof on a tall steel moment frame + RC core.

    julia --project=StructuralSynthesizer scripts/runners/dual_highrise_drift_proof.jl [NZ] [out.mgscene]

Builds a `NZ`-story (default 30) perimeter steel moment frame around a stiff
central core (the 4 inner columns, held fixed as the "background"), then drives
the moment-frame members to their ASCE 7-22 §12.12 inter-story drift limit with
`StructuralSizer.resize_for_drift!` — the virtual-work optimality-criteria
resizer wired onto Asap's batched `drift_participation` and the first-order
`linear_response` accelerator, with a strength floor folded in via `floor_I_fn`.

This is a PROOF/visualization runner, not a production design:
  * one combined gravity+lateral case stands in for the full load-combination set;
  * the strength floor is a transparent flexural proxy  I_floor = (d/2)/(φ Fy)·M
    (assumed depth d), not the full AISC App. 8 member check (that lives in the
    member stage); it is displacement-dependent, so it exercises the real
    strength↔drift coupling the accelerator targets.

Writes an `.mgscene` of the converged, solved tower (default
`viewer/public/dual_highrise_drift_proof.mgscene`) for the viewer.
=#

using StructuralSizer
using StructuralSynthesizer            # export_scene / build_scene
using Asap
using Unitful
using Printf

# ----------------------------------------------------------------------------
# Parameters
# ----------------------------------------------------------------------------
const NZ   = isempty(ARGS) ? 30 : parse(Int, ARGS[1])          # stories
const OUT  = length(ARGS) >= 2 ? ARGS[2] :
             joinpath(@__DIR__, "..", "..", "viewer", "public", "dual_highrise_drift_proof.mgscene")

const E   = 200.0e9u"Pa"               # steel modulus
const Gs  = 77.0e9u"Pa"
const ρ   = 7850.0u"kg/m^3"
const Fy  = 345.0e6                     # Pa (A992)
const BAY = 6.0                         # m, plan bay
const HST = 4.0                         # m, story height
const NB  = 3                           # bays per side ⇒ (NB+1)² = 16 columns

# ASCE 7-22 §12.12 / Table 12.12-1 allowable story drift and the SMF Cd (Table
# 12.2-1, D.9): elastic inter-story drift limit δxe ≤ Δa·Ie/Cd, Δa = 0.020·hsx.
const Cd  = 5.5
const Ie  = 1.0
const Δa  = 0.020 * HST
const DRIFT_ALLOW = Δa * Ie / Cd        # elastic story-drift budget [m]

# Section catalog: I [m⁴] in a geometric series; A ∝ √I, J ∝ I (W-shape-ish).
const I_MIN = 2.0e-4
const CATALOG = Float64[I_MIN * 1.15^k for k in 0:40]      # up to ≈ 0.06 m⁴
const I_CORE = 1.5e-2                   # fixed core-column inertia (background)

sec_from_I(I) = Asap.Section((0.6 * sqrt(I))u"m^2", E, Gs,
                             I * u"m^4", I * u"m^4", (0.01 * I)u"m^4", ρ)
cur_I(el)      = ustrip(u"m^4", el.section.Ix)
apply_I!(el, I) = (el.section = sec_from_I(I))

# Flexural strength proxy: required inertia I_floor = (d/2)/(φ Fy)·M for an
# assumed depth d, from the member's peak end moment at displacement `u`.
const D_ASSUMED = 0.5                   # m
const C_STR = (D_ASSUMED / 2) / (0.9 * Fy)

# ----------------------------------------------------------------------------
# Build the tower
# ----------------------------------------------------------------------------
nidx = Dict{NTuple{3,Int},Int}()
nodes = Asap.Node[]
for iz in 0:NZ, iy in 0:NB, ix in 0:NB
    fix = iz == 0 ? :fixed : :free
    push!(nodes, Asap.Node([ix * BAY * u"m", iy * BAY * u"m", iz * HST * u"m"], fix))
    nidx[(ix, iy, iz)] = length(nodes)
end

is_core(ix, iy) = ix in (1, 2) && iy in (1, 2)   # inner 2×2 column lines = core

elements = Asap.Element[]
is_sized = Bool[]                                 # parallel to `elements`
function add_elem!(a, b, I, tag, sized)
    el = Asap.Element(nodes[a], nodes[b], sec_from_I(I), tag)
    push!(elements, el); push!(is_sized, sized)
end

# Columns (core fixed/background; perimeter+interior MF columns sized).
for iz in 0:(NZ - 1), iy in 0:NB, ix in 0:NB
    core = is_core(ix, iy)
    add_elem!(nidx[(ix, iy, iz)], nidx[(ix, iy, iz + 1)],
              core ? I_CORE : I_MIN, :column, !core)
end
# Beams at every floor (all sized MF girders), in X and Y.
for iz in 1:NZ, iy in 0:NB, ix in 0:(NB - 1)
    add_elem!(nidx[(ix, iy, iz)], nidx[(ix + 1, iy, iz)], I_MIN, :beam, true)
end
for iz in 1:NZ, ix in 0:NB, iy in 0:(NB - 1)
    add_elem!(nidx[(ix, iy, iz)], nidx[(ix, iy + 1, iz)], I_MIN, :beam, true)
end

# ----------------------------------------------------------------------------
# Loads: gravity line load on every beam + a triangular (∝ height) lateral
# story force in +X, split over the 16 nodes of each floor.
# ----------------------------------------------------------------------------
loads = Asap.AbstractLoad[]
for el in elements
    el.id == :beam && push!(loads, Asap.LineLoad(el, [0.0u"N/m", 0.0u"N/m", -10.0e3u"N/m"]))
end
const Q_LAT = 6.0e3                                # lateral scale [N per story index]
const NPF = (NB + 1)^2                             # nodes per floor
for iz in 1:NZ
    fx = (Q_LAT * iz) / NPF
    for iy in 0:NB, ix in 0:NB
        push!(loads, Asap.NodeForce(nodes[nidx[(ix, iy, iz)]], [fx * u"N", 0.0u"N", 0.0u"N"]))
    end
end

model = Asap.Model(nodes, elements, loads)
Asap.solve!(model)

sized = findall(is_sized)
nsz = length(sized)
@printf("Tower: %d stories, %d nodes, %d elements (%d sized MF, %d background core)\n",
        NZ, length(nodes), length(elements), nsz, length(elements) - nsz)

# ----------------------------------------------------------------------------
# Drift constraints: elastic inter-story drift in X at the corner column line.
# ----------------------------------------------------------------------------
col_dof(iz) = nodes[nidx[(0, 0, iz)]].globalID[1]
cons = DriftConstraint[]
for iz in 1:NZ
    push!(cons, interstory_drift_constraint(col_dof(iz), col_dof(iz - 1), DRIFT_ALLOW))
end
story_drift() = [model.u[col_dof(iz)] - model.u[col_dof(iz - 1)] for iz in 1:NZ]

d0 = story_drift()
@printf("Initial corner-line story drift: max %.4f m (limit %.4f m) → max ratio %.2f\n",
        maximum(d0), DRIFT_ALLOW, maximum(d0) / DRIFT_ALLOW)

# Displacement-dependent strength floor over the sized members.
felems = Asap._frame_elements(model)
function strength_floor(mdl, u)
    out = Vector{Float64}(undef, nsz)
    fe = Asap._frame_elements(mdl)
    @inbounds for (i, e) in enumerate(sized)
        el = fe[e]; g = el.globalID
        Fe = el.K * view(u, g)
        M = max(maximum(abs, view(Fe, 4:6)), maximum(abs, view(Fe, 10:12)))
        out[i] = max(I_MIN, C_STR * M)
    end
    return out
end

weight = [ustrip(u"m", felems[e].length) for e in sized]    # marginal weight ∝ length

steel_volume() = sum(ustrip(u"m^2", felems[e].section.A) * ustrip(u"m", felems[e].length) for e in sized)
vol0 = steel_volume()

# ----------------------------------------------------------------------------
# Drive to the drift limit with the coupled strength floor + accelerator.
# ----------------------------------------------------------------------------
t = @elapsed res = resize_for_drift!(model, cons;
                                     sized_elements = sized,
                                     weight = weight,
                                     floor_I = fill(I_MIN, nsz),
                                     floor_I_fn = strength_floor,
                                     accelerate = get(ENV, "ACCEL", "true") == "true",
                                     catalog = CATALOG,
                                     current_I = cur_I, apply_I! = apply_I!,
                                     max_outer = 30, tol = 2.0e-2)

d1 = story_drift()
floor_final = strength_floor(model, model.u)
strength_ok = all(res.sizes[i] ≥ floor_final[i] * (1 - 1e-6) for i in 1:nsz)
vol1 = steel_volume()

println("\n── Drift governor result ───────────────────────────────")
@printf("status            : %s  (converged=%s)\n", res.status, res.converged)
@printf("outer iterations  : %d   (%.1f s)\n", res.outer_iterations, t)
@printf("max drift ratio   : %.3f  (was %.2f)\n", maximum(d1) / DRIFT_ALLOW, maximum(d0) / DRIFT_ALLOW)
@printf("all stories ≤ lim : %s\n", all(d1 .≤ DRIFT_ALLOW * (1 + 2e-2)))
@printf("strength floor met: %s\n", strength_ok)
@printf("MF steel volume   : %.2f → %.2f m³  (×%.2f)\n", vol0, vol1, vol1 / vol0)
@printf("MF inertia range  : %.2e … %.2e m⁴\n", minimum(res.sizes), maximum(res.sizes))

# ----------------------------------------------------------------------------
# Scene
# ----------------------------------------------------------------------------
mkpath(dirname(OUT))
packet = export_scene(OUT, model)
println("\nwrote ", abspath(OUT))
@printf("  nodes %d  elements %d  max disp %.3f m  scale %s\n",
        packet.meta["counts"]["nodes"], packet.meta["counts"]["elements"],
        packet.meta["max_displacement"], string(packet.meta["suggested_scale"]))
