# =============================================================================
# Phase 5c — in-building wall-shell assembly vs. isolated FEMLateralEvaluator
# =============================================================================
#
# GOAL
#   Show that the in-building wall-shell mesher `_mesh_wall_shells`
#   (StructuralSynthesizer/src/analyze/asap/utils.jl — now adds NO supports)
#   reproduces the isolated StructuralSizer `FEMLateralEvaluator` on a matched
#   model, under identical geometry, boundary conditions and loads.
#
#   TIER A (reference): the isolated `FEMLateralEvaluator` on 8 `WallPanel`s
#     (4 base ids 1-4, 4 upper ids 5-8). Base per-wall shear is recovered
#     EXACTLY from nodal base reactions; upper-story shear is WITHHELD (NaN),
#     so ids 5-8 are NOT compared.
#
#   TIER B (under test): a `BuildingStructure` with 8 `Wall`s on the same plan
#     lines, meshed by `_mesh_wall_shells`. The isolated evaluator's boundary
#     conditions are replicated IN THIS RUNNER ONLY (no src change):
#       - fixed base: every wall node at z≈0 has all dof set false;
#       - stiff-shell floor diaphragm: at each story-top elevation one centroid
#         master node (all dof free) is fan-triangulated to every wall node at
#         that elevation with stiff ShellTri3 elements — the SAME construction
#         the FEMLateralEvaluator uses (`diaphragm_E`, `diaphragm_t`, ν=0.2);
#       - a nodal load Fx (+x) at each story master.
#
#   WHY A STIFF-SHELL DIAPHRAGM HERE (not production's rigid diaphragm):
#     Tier A (`_build_asap_wall_model`) builds a STIFF-SHELL floor diaphragm,
#     whereas production (`_join_wall_nodes_to_rigid_diaphragm!`) ties only
#     (u_x, u_y, θ_z) via exact RigidLinks and releases (u_z, θ_x, θ_y). On this
#     symmetric 4-wall core the walls are spatially SEPARATE (no shared corner
#     nodes), so the diaphragm is their ONLY coupling and dominates interstory
#     drift: a rigid-link Tier B vs. stiff-shell Tier A differs ~5% in drift
#     (base shear agrees because it is global equilibrium, diaphragm-independent).
#     To ISOLATE the wall mesher `_mesh_wall_shells`, Tier B is given Tier A's
#     EXACT stiff-shell diaphragm so any residual drift gap is attributable to
#     the wall mesh/assembly alone. Whether production should instead adopt the
#     stiff-shell diaphragm (or Tier A the rigid one) is a separate Phase 6
#     decision — NOT resolved here.
#
# This file is SELF-CONTAINED verification; it imports only public entry points
# plus the two internal mesher helpers (`_mesh_wall_shells`,
# `_wall_pier_geometry` is called transitively). It modifies NO src file.
#
# SAFETY: material E, ν, ρ come ONLY from the NWC_4000 preset (f'c = 4000 psi,
# ACI 318-11 §8.5.1 Ec); no modulus/density/BC is invented. The SAME E, ν, t
# are fed to both tiers so the comparison isolates the mesh+assembly, not the
# material.
# =============================================================================

using StructuralSynthesizer
using StructuralSizer
using Asap
using Unitful
using LinearAlgebra

const SS = StructuralSynthesizer

# -----------------------------------------------------------------------------
# Fixed geometry / loads (bare SI, metres & newtons)
# -----------------------------------------------------------------------------
const H   = 3.0          # story height [m]
const T_W = 0.3          # wall thickness [m]
const FX  = 5.0e5        # story lateral load, +x [N] (per story)
const NX  = 2            # mesh columns per wall (matches mesher's hardcoded nx)
const PLAN_HALFWIDTH = (5.0, 5.0)

# Four plan lines shared by both stories: (x1, y1, x2, y2).
#   walls 1,2 run along x (resist Fx in-plane); walls 3,4 run along y.
const PLAN_LINES = (
    (-2.0, -5.0,  2.0, -5.0),   # id 1 / 5
    (-2.0,  5.0,  2.0,  5.0),   # id 2 / 6
    (-5.0, -2.0, -5.0,  2.0),   # id 3 / 7
    ( 5.0, -2.0,  5.0,  2.0),   # id 4 / 8
)

# -----------------------------------------------------------------------------
# Material — NWC_4000 (closest preset to E ≈ 25e9 Pa). Both tiers use these.
# -----------------------------------------------------------------------------
const CONC = NWC_4000
const E_PA = ustrip(u"Pa", CONC.E)   # ACI 318-11 §8.5.1 Ec, bare SI
const NU   = CONC.ν

# Stiff-shell diaphragm properties — IDENTICAL to FEMLateralEvaluator defaults
# (StructuralSizer/src/walls/fem_evaluator.jl: diaphragm_E, diaphragm_t, and the
# hardcoded ν=0.2 in its ShellTri3 constructor). Tier A uses these exact values,
# so Tier B must too for the diaphragm to be byte-for-byte matched.
const DIA_E = 1.0e12   # in-plane penalty modulus of the stiff diaphragm [Pa]
const DIA_T = 0.05     # diaphragm shell thickness [m]
const DIA_NU = 0.2     # diaphragm shell Poisson ratio (hardcoded in Tier A)

# =============================================================================
# TIER A — isolated FEMLateralEvaluator
# =============================================================================
function run_tier_a()
    ev = FEMLateralEvaluator(story_heights = [H, H], mesh_div = NX,
                             plan_halfwidth = PLAN_HALFWIDTH)

    panels = WallPanel[]
    # base story (ids 1-4, z 0→H, story 1)
    for (i, (x1, y1, x2, y2)) in enumerate(PLAN_LINES)
        push!(panels, WallPanel(i, x1, y1, x2, y2, 0.0, H, T_W, E_PA, NU, 1))
    end
    # upper story (ids 5-8, z H→2H, story 2)
    for (i, (x1, y1, x2, y2)) in enumerate(PLAN_LINES)
        push!(panels, WallPanel(i + 4, x1, y1, x2, y2, H, 2H, T_W, E_PA, NU, 2))
    end

    loads = [StoryLoad(1, FX, 0.0, 0.0, 0.0), StoryLoad(2, FX, 0.0, 0.0, 0.0)]
    res = evaluate_lateral(ev, panels, loads)

    drift = [res.drift[1], res.drift[2]]
    base_shear = [res.wall_forces[i] for i in 1:4]
    withheld = sort(collect(res.wall_forces_withheld))
    return (drift = drift, base_shear = base_shear, withheld = withheld)
end

# =============================================================================
# TIER B — in-building `_mesh_wall_shells`, BCs replicated in the runner
# =============================================================================

"""Integer mm key for matching coincident nodes by position."""
nkey(x, y, z) = (round(Int, x * 1000), round(Int, y * 1000), round(Int, z * 1000))

"""Build a minimal BuildingStructure: 8 walls (4 story-0, 4 story-1) + stories."""
function build_structure()
    LT = typeof(1.0u"m")                       # skeleton length type
    skel = BuildingSkeleton{LT}()
    # Stories at z = 0, H, 2H (0-based keys). _wall_pier_geometry reads
    # stories[wall.story].elevation for the pier bottom; z_top = bottom + base.L.
    skel.stories[0] = Story{LT}(0.0u"m")
    skel.stories[1] = Story{LT}(H * u"m")
    skel.stories[2] = Story{LT}(2H * u"m")

    struc = BuildingStructure(skel)
    for (story0, _) in ((0, nothing), (1, nothing))                     # stories 0,1
        for (x1, y1, x2, y2) in PLAN_LINES
            w = Wall([1], H * u"m"; thickness = T_W * u"m",
                     x1 = x1, y1 = y1, x2 = x2, y2 = y2,
                     story = story0, concrete = CONC)
            push!(struc.walls, w)
        end
    end
    return struc
end

function run_tier_b()
    struc  = build_structure()
    params = DesignParameters()

    # ----- mesh the walls (the function under test) -----
    shells, wall_nodes = SS._mesh_wall_shells(struc, params, Asap.Node[], Asap.ShellTri3[])

    # Position → node lookup for base-reaction recovery.
    node_at = Dict{NTuple{3,Int},Asap.Node}()
    for nd in wall_nodes
        p = nd.position
        node_at[nkey(ustrip(u"m", p[1]), ustrip(u"m", p[2]), ustrip(u"m", p[3]))] = nd
    end

    # ----- fixed base: every wall node at z≈0 → all dof false (runner-only pin,
    #       replicating Tier A's fixed cantilever base; NOT a src change) -----
    for nd in wall_nodes
        if isapprox(ustrip(u"m", nd.position[3]), 0.0; atol = 1e-6)
            nd.dof .= false
        end
    end

    # ----- stiff-shell floor diaphragm at z = H and z = 2H -----
    # This is the SAME construction Tier A's `_build_asap_wall_model` uses so the
    # comparison isolates the wall mesh (`_mesh_wall_shells`), not the diaphragm
    # model. For each floor: one master node at the plan centroid (mean of the
    # floor's wall nodes, = (0,0) here), all 6 dof FREE — exactly as Tier A's
    # `get_node!` creates it (:free) — stiffened by a fan triangulation of stiff
    # ShellTri3 elements (DIA_E, DIA_T, ν=DIA_NU) from the master to the floor's
    # wall nodes, sorted by plan angle. The shells (membrane + bending) give the
    # master all its stiffness; no dof is fixed, so there is no zero-stiffness
    # mode once the diaphragm is assembled. Collinear (near-degenerate) triangles
    # are skipped, mirroring the evaluator's |ax·by − ay·bx| < 1e-6 guard.
    dia_shells = Asap.ShellTri3[]
    loads      = Asap.NodeForce[]
    masters    = Asap.Node[]
    for zf in (H, 2H)
        fnodes = [nd for nd in wall_nodes
                  if isapprox(ustrip(u"m", nd.position[3]), zf; atol = 1e-6)]
        isempty(fnodes) && continue
        cx = sum(ustrip(u"m", nd.position[1]) for nd in fnodes) / length(fnodes)
        cy = sum(ustrip(u"m", nd.position[2]) for nd in fnodes) / length(fnodes)
        master = Asap.Node([cx, cy, zf] .* u"m", :free, :diaphragm_master)
        push!(masters, master)
        # fan triangles centroid→consecutive wall nodes sorted by plan angle
        others = [nd for nd in fnodes if nd !== master]
        if length(others) >= 2
            sort!(others; by = nd -> atan(ustrip(u"m", nd.position[2]) - cy,
                                          ustrip(u"m", nd.position[1]) - cx))
            for i in eachindex(others)
                a = others[i]; b = others[mod1(i + 1, length(others))]
                ax = ustrip(u"m", a.position[1]) - cx; ay = ustrip(u"m", a.position[2]) - cy
                bx = ustrip(u"m", b.position[1]) - cx; by = ustrip(u"m", b.position[2]) - cy
                abs(ax * by - ay * bx) < 1e-6 && continue   # skip collinear
                push!(dia_shells, Asap.ShellTri3((master, a, b),
                                                 DIA_T * u"m", DIA_E * u"Pa", DIA_NU;
                                                 id = :diaphragm))
            end
        end
        push!(loads, Asap.NodeForce(master, [FX, 0.0, 0.0] .* u"N"))
    end

    # ----- assemble & solve -----
    all_nodes  = vcat(wall_nodes, masters)
    all_shells = vcat(shells, dia_shells)
    model = Asap.Model(all_nodes, all_shells, Vector{Asap.AbstractLoad}(loads))
    Asap.process!(model)
    Asap.solve!(model)

    # ----- drift from master in-plane displacements -----
    mu = zeros(2, 2)   # [story, (ux, uy)]
    for (s, master) in enumerate(masters)
        gid = master.globalID
        mu[s, 1] = model.u[gid[1]]
        mu[s, 2] = model.u[gid[2]]
    end
    drift = zeros(2)
    drift[1] = hypot(mu[1, 1], mu[1, 2]) / H
    drift[2] = hypot(mu[2, 1] - mu[1, 1], mu[2, 2] - mu[1, 2]) / H

    # ----- base-story per-wall shear (ids 1-4): sum base-node horizontal
    #       reactions, projected on the wall axis — same recovery as
    #       fem_evaluator.jl ~295-307 -----
    base_shear = zeros(4)
    for (i, (x1, y1, x2, y2)) in enumerate(PLAN_LINES)
        lw = hypot(x2 - x1, y2 - y1)
        ux = (x2 - x1) / lw; uy = (y2 - y1) / lw
        Rx = 0.0; Ry = 0.0
        for c in 0:NX
            s = c / NX
            bx = x1 + (x2 - x1) * s
            by = y1 + (y2 - y1) * s
            nd = get(node_at, nkey(bx, by, 0.0), nothing)
            nd === nothing && continue
            Rx += ustrip(u"N", nd.reaction[1])
            Ry += ustrip(u"N", nd.reaction[2])
        end
        base_shear[i] = abs(Rx * ux + Ry * uy)
    end

    return (drift = drift, base_shear = base_shear)
end

# =============================================================================
# Compare (tolerances FIXED here, before any result is seen)
# =============================================================================
const DRIFT_RTOL        = 0.02      # interstory drift, both stories
const DRIFT_ABSFLOOR    = 1e-9      # both ~0 ⇒ compare absolutely
const SHEAR_RTOL        = 0.05      # base per-wall shear, ids 1-4
# Denominator floor for shear: a wall whose in-plane shear is < this (both
# tiers) carries ~zero in-plane demand (the Y-walls under pure Fx), so a
# relative diff is meaningless — treat as agreement. Fixed now, not retuned.
const SHEAR_NEG_FLOOR   = 1.0e-3 * (2 * FX)   # = 1000 N

"""Relative difference wrt reference `a`, with a both-~0 absolute fallback."""
function rel_or_abs(a, b; absfloor, negfloor = 0.0)
    if max(abs(a), abs(b)) <= max(absfloor, negfloor)
        return 0.0                      # both negligible ⇒ agree
    end
    return abs(a - b) / max(abs(a), abs(b))
end

function main()
    println("Running TIER A (isolated FEMLateralEvaluator) ...")
    A = run_tier_a()
    println("Running TIER B (in-building _mesh_wall_shells assembly) ...")
    B = run_tier_b()

    drift_rel = [rel_or_abs(A.drift[s], B.drift[s]; absfloor = DRIFT_ABSFLOOR)
                 for s in 1:2]
    shear_rel = [rel_or_abs(A.base_shear[i], B.base_shear[i];
                            absfloor = 0.0, negfloor = SHEAR_NEG_FLOOR)
                 for i in 1:4]

    drift_ok = all(r -> r <= DRIFT_RTOL, drift_rel)
    shear_ok = all(r -> r <= SHEAR_RTOL, shear_rel)
    agree = drift_ok && shear_ok

    fmt(v) = "[" * join((string(round(x; sigdigits = 6)) for x in v), ", ") * "]"

    println()
    println("DONE: Phase 5c verification of in-building _mesh_wall_shells vs isolated FEMLateralEvaluator")
    println("FILES: scripts/runners/verify_wall_shell_assembly_phase5c.jl")
    println("TIER_A: drift=", fmt(A.drift),
            ", base wall_forces ids1-4=", fmt(A.base_shear),
            ", withheld ids=", fmt(A.withheld))
    println("TIER_B: drift=", fmt(B.drift),
            ", base shears ids1-4=", fmt(B.base_shear))
    println("DELTAS: drift rel=", fmt(drift_rel),
            ", base shear rel=", fmt(shear_rel))
    println("RESULT: ", agree ? "AGREE" : "DISAGREE")
    println("NOTES: material = NWC_4000 (E=", round(E_PA; sigdigits = 6),
            " Pa, ν=", NU, "), fed identically to both tiers. Diaphragm now ",
            "MATCHED: Tier B uses the SAME stiff-shell floor diaphragm as Tier A ",
            "(centroid master, all dof free, fan-triangulated stiff ShellTri3 at ",
            "DIA_E=", round(DIA_E; sigdigits = 3), " Pa, t=", DIA_T, " m, ν=", DIA_NU,
            "), replacing the previous exact-RigidLink tie — so this test isolates ",
            "the wall mesher `_mesh_wall_shells`. Master is the plan centroid ",
            "(0,0) at each floor (mean of floor wall nodes), matching Tier A; no ",
            "artificial torsion. Production uses a true rigid diaphragm ",
            "(`_join_wall_nodes_to_rigid_diaphragm!`, tie u_x,u_y,θ_z only, release ",
            "u_z,θ_x,θ_y), which differs ~5% in drift from the stiff shell — a ",
            "separate Phase 6 decision, NOT resolved here. Upper-story shears ",
            "(ids 5-8) withheld/NaN in Tier A, NOT compared. Y-wall (ids 3,4) ",
            "in-plane shear ~0 under pure Fx (negligible-floor ",
            round(SHEAR_NEG_FLOOR; sigdigits = 3), " N applied to its relative diff).")
    return agree
end

main()
