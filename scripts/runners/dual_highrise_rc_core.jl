#=
Dual-system high-rise: steel moment frame + RC shear-wall core, rigid diaphragm,
sized for BOTH seismic and wind, with a §12.2.5.1 frame-only capability check.

    julia --project=StructuralSynthesizer scripts/runners/dual_highrise_rc_core.jl [NZ]

Upgrades `dual_highrise_drift_proof.jl` to a genuine dual system:

  * RC core = concrete **shell walls** (ShellTri3, concrete E) forming a box
    around the central bay — not stiff "columns". Rendered in the scene.
  * **In-plane rigid floor diaphragm** at every level: a per-floor master with
    `RigidLink`s that tie ux, uy, θz and release uz, θx, θy (so gravity axial
    shortening stays independent). The governor, participation, and re-solve all
    run on the condensed master/slave GᵀKG system (the reduced solver).
  * Two lateral cases — a code-form ASCE 7-22 §12.8 ELF **seismic** load and an
    illustrative **wind** pressure profile — with their own drift criteria:
    seismic §12.12 story drift (δxe ≤ Δa·Ie/Cd) and wind H/400 roof
    serviceability. The moment frame is sized to the **envelope** of both plus a
    member-strength floor.
  * ASCE 7-22 §12.2.5.1 dual-system check: the bare frame (core shells removed,
    `exclude_shells=true`) must independently resist ≥25% of the base shear.

Writes one `.mgscene` per load case (seismic / wind) of the converged tower, so
the two deflected shapes can be compared.

Illustrative, not a code submission: seismic parameters (SDS, R, …) and the wind
profile are representative inputs, and the strength floor is a flexural proxy
I ≥ (d/2)/(φFy)·M (the full AISC App. 8 member check lives in the member stage).
=#

using StructuralSizer
using StructuralSynthesizer            # export_scene
using Asap
using Unitful
using Printf

# ----------------------------------------------------------------------------
# Parameters
# ----------------------------------------------------------------------------
const NZ  = isempty(ARGS) ? 30 : parse(Int, ARGS[1])
const OUTDIR = joinpath(@__DIR__, "..", "..", "viewer", "public")

const Es  = 200.0e9u"Pa"; const Gs = 77.0e9u"Pa"; const ρs = 7850.0u"kg/m^3"
const Fy  = 345.0e6                      # Pa (A992)
const Ec  = 27.0e9u"Pa"                  # ~ 4700√34 MPa concrete
const νc  = 0.2;  const ρc = 2400.0;  const T_WALL = 0.75   # m wall thickness
const BAY = 6.0;  const HST = 4.0;  const NB = 3            # (NB+1)² = 16 columns
const H_TOT = NZ * HST

# Seismic (ASCE 7-22 §12.8) — representative inputs.
const SDS = 1.0; const SD1 = 0.6; const R = 8.0; const Ie = 1.0; const Cd = 5.5
const W_FLOOR = 3.5e6                     # N seismic weight per floor (~10 kPa·324 m²)
# Story drift limit (§12.12 / Table 12.12-1): elastic δxe ≤ Δa·Ie/Cd, Δa=0.020·hsx.
const DRIFT_SEISMIC = (0.020 * HST) * Ie / Cd
const DRIFT_WIND = H_TOT / 400.0          # roof serviceability (illustrative)

# Steel section catalog: I [m⁴] geometric; A ∝ √I, J ∝ I.
const I_MIN = 2.0e-4
const CATALOG = Float64[I_MIN * 1.15^k for k in 0:40]
sec_from_I(I) = Asap.Section((0.6 * sqrt(I))u"m^2", Es, Gs,
                             I * u"m^4", I * u"m^4", (0.01 * I)u"m^4", ρs)
cur_I(el)      = ustrip(u"m^4", el.section.Ix)
apply_I!(el, I) = (el.section = sec_from_I(I))
const D_ASSUMED = 0.5
const C_STR = (D_ASSUMED / 2) / (0.9 * Fy)   # I_floor = (d/2)/(φFy)·M

# ----------------------------------------------------------------------------
# Geometry
# ----------------------------------------------------------------------------
nidx = Dict{NTuple{3,Int},Int}()
nodes = Asap.Node[]
for iz in 0:NZ, iy in 0:NB, ix in 0:NB
    fix = iz == 0 ? :fixed : :free
    push!(nodes, Asap.Node([ix * BAY * u"m", iy * BAY * u"m", iz * HST * u"m"], fix))
    nidx[(ix, iy, iz)] = length(nodes)
end
node(ix, iy, iz) = nodes[nidx[(ix, iy, iz)]]
is_core_node(ix, iy) = ix in (1, 2) && iy in (1, 2)   # inner 2×2 = core boundary

# Steel frame: columns + beams. Core-boundary columns are background (fixed);
# all other columns and every beam are the sized moment frame.
elements = Asap.Element[]
is_sized = Bool[]
function add_elem!(a, b, I, tag, sized)
    push!(elements, Asap.Element(nodes[a], nodes[b], sec_from_I(I), tag))
    push!(is_sized, sized)
end
# Moment frame starts at the catalog floor; the (thick) RC core alone keeps the
# first solve's drift within budget (otherwise the participation governor reports
# background_infeasible before it can size anything). This is a core-dominated
# dual system: the core controls drift, so the governor sizes the frame by its
# STRENGTH floor (the coupled strength↔drift governor's other half), and
# §12.2.5.1 then confirms the frame can independently carry 25% of the base shear.
const I0 = I_MIN
for iz in 0:(NZ - 1), iy in 0:NB, ix in 0:NB
    core = is_core_node(ix, iy)
    add_elem!(nidx[(ix, iy, iz)], nidx[(ix, iy, iz + 1)], core ? 4.0e-3 : I0, :column, !core)
end
for iz in 1:NZ, iy in 0:NB, ix in 0:(NB - 1)
    add_elem!(nidx[(ix, iy, iz)], nidx[(ix + 1, iy, iz)], I0, :beam, true)
end
for iz in 1:NZ, ix in 0:NB, iy in 0:(NB - 1)
    add_elem!(nidx[(ix, iy, iz)], nidx[(ix, iy + 1, iz)], I0, :beam, true)
end

# RC core = 4 shear-wall planes around the central bay, each story meshed as 2
# concrete :wall triangles between adjacent core-boundary column lines.
shells = Asap.ShellElement[]
function add_wall!(gi1, gj1, gi2, gj2)
    for iz in 0:(NZ - 1)
        A = node(gi1, gj1, iz); B = node(gi2, gj2, iz)
        C = node(gi2, gj2, iz + 1); D = node(gi1, gj1, iz + 1)
        push!(shells, Asap.ShellTri3((A, B, C), T_WALL * u"m", Ec, νc; id = :wall, ρ = ρc))
        push!(shells, Asap.ShellTri3((A, C, D), T_WALL * u"m", Ec, νc; id = :wall, ρ = ρc))
    end
end
add_wall!(1, 1, 2, 1)   # south
add_wall!(1, 2, 2, 2)   # north
add_wall!(1, 1, 1, 2)   # west
add_wall!(2, 1, 2, 2)   # east

# ----------------------------------------------------------------------------
# Loads: gravity (always) + a swappable lateral case. model.loads is mutated.
# ----------------------------------------------------------------------------
gravity = Asap.AbstractLoad[]
for el in elements
    el.id == :beam && push!(gravity, Asap.LineLoad(el, [0.0u"N/m", 0.0u"N/m", -10.0e3u"N/m"]))
end

# Spread a story's X-force equally over its (NB+1)² column nodes so the resultant
# passes through the plan center (= the center of rigidity of this symmetric
# tower). Applying it at one node would move the shear's line of action off-center
# and spin the rigid diaphragm (torsion = F·e). Real accidental torsion
# (ASCE 7 §12.8.4.2, 5% eccentricity) would be added deliberately, not by accident.
const NCOL = (NB + 1)^2
function story_force(iz, Fx)
    [Asap.NodeForce(node(ix, iy, iz), [(Fx / NCOL) * u"N", 0.0u"N", 0.0u"N"])
     for iy in 0:NB, ix in 0:NB] |> vec
end

# Seismic ELF vertical distribution (§12.8.3): Fx = Cvx·V, Cvx = wx·hx^k/Σ.
function seismic_case()
    Ta = 0.028 * (H_TOT / 0.3048)^0.8               # §12.8.2.1 steel MF (hn in ft)
    k  = Ta ≤ 0.5 ? 1.0 : (Ta ≥ 2.5 ? 2.0 : 1.0 + (Ta - 0.5) / 2.0)   # §12.8.3
    Cs = max(min(SDS / (R / Ie), SD1 / (Ta * (R / Ie))), 0.044 * SDS * Ie)  # §12.8.1.1
    V  = Cs * (NZ * W_FLOOR)                         # §12.8.1 base shear
    denom = sum((iz * HST)^k for iz in 1:NZ)
    loads = Asap.AbstractLoad[]
    for iz in 1:NZ
        append!(loads, story_force(iz, V * (iz * HST)^k / denom))
    end
    return loads, V, Cs, k, Ta
end

# Illustrative wind: fuller profile (∝ (z/H)^0.4), ~0.6× the seismic base shear.
function wind_case(Vtarget)
    denom = sum((iz / NZ)^0.4 for iz in 1:NZ)
    loads = Asap.AbstractLoad[]
    for iz in 1:NZ
        append!(loads, story_force(iz, Vtarget * (iz / NZ)^0.4 / denom))
    end
    return loads
end

model = Asap.Model(nodes, elements, shells, Asap.AbstractLoad[])
set_case!(lateral) = (empty!(model.loads); append!(model.loads, gravity); append!(model.loads, lateral); model)

# In-plane rigid diaphragm: tie ux,uy,θz to a per-floor master (corner (0,0));
# release uz,θx,θy so columns shorten independently under gravity.
const DIAPHRAGM_RELEASE = (false, false, true, true, true, false)
links = Asap.RigidLink[]
for iz in 1:NZ
    master = node(0, 0, iz)
    for iy in 0:NB, ix in 0:NB
        (ix == 0 && iy == 0) && continue
        push!(links, Asap.RigidLink(master, node(ix, iy, iz); release = DIAPHRAGM_RELEASE))
    end
end

sized = findall(is_sized)
nsz = length(sized)
@printf("Tower: %d stories | %d nodes | %d frame elems (%d sized MF) | %d wall shells | %d diaphragm links\n",
        NZ, length(nodes), length(elements), nsz, length(shells), length(links))

# ----------------------------------------------------------------------------
# Drift constraints + strength floor
# ----------------------------------------------------------------------------
mdof(iz) = node(0, 0, iz).globalID[1]                # master X DOF per floor
story_constraints(limit) = [interstory_drift_constraint(mdof(iz), mdof(iz - 1), limit) for iz in 1:NZ]
roof_constraint(limit)   = [total_drift_constraint(mdof(NZ), limit)]
story_drift() = [model.u[mdof(iz)] - model.u[mdof(iz - 1)] for iz in 1:NZ]
roof_drift()  = model.u[mdof(NZ)]

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
# Geometric member length from node coordinates — `el.length` is only populated
# by `process!`, so reading it before the first solve gives 0 (a zero weight
# later trips the optimality resizer's `w > 0` guard).
function elen(el)
    a = el.nodeStart.position; b = el.nodeEnd.position
    return sqrt(sum(abs2, ustrip.(u"m", b .- a)))
end
weight = [elen(felems[e]) for e in sized]
steel_vol() = sum(ustrip(u"m^2", felems[e].section.A) * elen(felems[e]) for e in sized)

run_governor(cons, floor_vec) = resize_for_drift!(model, cons;
    sized_elements = sized, weight = weight, floor_I = floor_vec,
    floor_I_fn = strength_floor, accelerate = true, catalog = CATALOG,
    current_I = cur_I, apply_I! = apply_I!, links = links,
    max_outer = 40, tol = 2.0e-2)

# ----------------------------------------------------------------------------
# Stage 1: seismic
# ----------------------------------------------------------------------------
seis, Vseis, Cs, kelf, Ta = seismic_case()
set_case!(seis); Asap.solve!(model, links)
@printf("\nSeismic ELF: Ta=%.2fs  k=%.2f  Cs=%.3f  V=%.0f kN\n", Ta, kelf, Cs, Vseis / 1e3)
d0 = story_drift()
@printf("  initial max story-drift ratio %.2f (limit %.4f m)\n", maximum(d0) / DRIFT_SEISMIC, DRIFT_SEISMIC)
res_s = run_governor(story_constraints(DRIFT_SEISMIC), fill(I_MIN, nsz))
sizes_seismic = copy(res_s.sizes)
@printf("  → status=%s iters=%d  max ratio %.3f  steel %.1f m³\n",
        res_s.status, res_s.outer_iterations, maximum(story_drift()) / DRIFT_SEISMIC, steel_vol())

# ----------------------------------------------------------------------------
# Stage 2: wind (floored by the seismic design → envelope)
# ----------------------------------------------------------------------------
wind = wind_case(0.6 * Vseis)
set_case!(wind); Asap.solve!(model, links)
@printf("\nWind: V=%.0f kN  initial roof drift %.3f m (H/400 = %.3f m, ratio %.2f)\n",
        0.6 * Vseis / 1e3, roof_drift(), DRIFT_WIND, roof_drift() / DRIFT_WIND)
res_w = run_governor(roof_constraint(DRIFT_WIND), sizes_seismic)   # never below seismic design
@printf("  → status=%s iters=%d  roof drift %.3f m (ratio %.3f)  steel %.1f m³\n",
        res_w.status, res_w.outer_iterations, roof_drift(), roof_drift() / DRIFT_WIND, steel_vol())
sizes_env = copy(res_w.sizes)

# ----------------------------------------------------------------------------
# Verify both cases on the envelope design
# ----------------------------------------------------------------------------
set_case!(seis); Asap.solve!(model, links); d_s = story_drift()
twist = maximum(abs(model.u[node(0, 0, iz).globalID[6]]) for iz in 1:NZ)  # master θz
set_case!(wind); Asap.solve!(model, links); r_w = roof_drift()
floor_final = strength_floor(model, model.u)
@printf("\nEnvelope design check:\n")
@printf("  diaphragm twist (max |θz|)  : %.2e rad  (≈0 ⇒ no torsion, symmetric)\n", twist)
@printf("  seismic story drift ≤ limit : %s (max ratio %.3f)\n",
        all(d_s .≤ DRIFT_SEISMIC * 1.02), maximum(d_s) / DRIFT_SEISMIC)
@printf("  wind roof drift ≤ H/400     : %s (ratio %.3f)\n", r_w ≤ DRIFT_WIND * 1.02, r_w / DRIFT_WIND)
@printf("  strength floor met          : %s\n",
        all(sizes_env[i] ≥ floor_final[i] * (1 - 1e-6) for i in 1:nsz))

# ----------------------------------------------------------------------------
# §12.2.5.1: bare moment frame (core shells removed) resists ≥25% of base shear
# ----------------------------------------------------------------------------
quarter = seismic_case()[1]                         # 25% applied below
set_case!([Asap.NodeForce(l.node, 0.25 .* l.value) for l in quarter])
u_full = Asap.solve(model, [model.loads], links)[1]
u_frame = Asap.solve(model, [model.loads], links; exclude_shells = true)[1]
drift_full  = maximum(u_full[mdof(iz)] - u_full[mdof(iz - 1)] for iz in 1:NZ)
drift_frame = maximum(u_frame[mdof(iz)] - u_frame[mdof(iz - 1)] for iz in 1:NZ)
@printf("\n§12.2.5.1 frame-only @25%% base shear: full max drift %.4f m, bare-frame %.4f m (finite ⇒ frame is a stable LFRS)\n",
        drift_full, drift_frame)

# ----------------------------------------------------------------------------
# Scenes — one per load case, drawn from the with-links (rigid-diaphragm) solve.
# ----------------------------------------------------------------------------
mkpath(OUTDIR)
for (name, lateral) in (("seismic", seis), ("wind", wind))
    set_case!(lateral); Asap.solve!(model, links)   # fills node.displacement
    out = joinpath(OUTDIR, "dual_rc_core_$(name).mgscene")
    packet = export_scene(out, model; resolve = false, include_shells = true)
    @printf("wrote %s  (nodes %d, elems %d, shell tris %d, max disp %.3f m)\n",
            out, packet.meta["counts"]["nodes"], packet.meta["counts"]["elements"],
            packet.meta["counts"]["shell_triangles"], packet.meta["max_displacement"])
end
