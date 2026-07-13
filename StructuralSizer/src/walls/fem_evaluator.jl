# ==============================================================================
# Lateral System — FEM Evaluator (Asap vertical wall shells + diaphragms)
# ==============================================================================
# Plan S3. The high-fidelity tier of the `AbstractLateralEvaluator` interface,
# used ONLY to validate the near-optimal layouts the reduced evaluator selects
# (never in the optimizer inner loop). Skew walls and torsion fall out of the FE
# assembly automatically — no projection math.
#
# Implementation status (see memory todo `todo-w0000004`): Asap has validated
# `ShellTri3` membrane+bending elements and a `Diaphragm` helper, BUT menegroth's
# `to_asap!` currently BUILDS diaphragm shells and then DROPS them from
# `Asap.Model` (frame-only), and there is no vertical-wall meshing path. This
# evaluator therefore assembles its own mixed model. The Asap constructor
# signatures below are written against Asap's documented API and are marked
# VERIFY: they must be validated (and a single-story frame+wall+diaphragm
# benchmark added) before this tier is trusted, and its wall-shear split
# cross-checked against `ReducedDiaphragmEvaluator` (the S2 known-answer oracle).

using LinearAlgebra

"""
    FEMLateralEvaluator

High-fidelity Asap-shell lateral evaluator (plan S3). Same interface as
[`ReducedDiaphragmEvaluator`](@ref); intended for validating survivors.

# Fields
- `story_heights::Vector{Float64}`: story heights [m]
- `story_elevations::Vector{Float64}`: cumulative elevations of each floor [m]
- `mesh_div::Int`: shell subdivisions per wall panel edge (mesh density)
- `diaphragm_stiffness::Float64`: penalty in-plane modulus for the rigid
  diaphragm shells [Pa] (Asap models rigidity via a very stiff, massless shell)
"""
Base.@kwdef struct FEMLateralEvaluator <: AbstractLateralEvaluator
    story_heights::Vector{Float64}
    story_elevations::Vector{Float64} = Float64[]
    mesh_div::Int = 2
    diaphragm_stiffness::Float64 = 1.0e12
end

"""
    WallPanel

Geometry of one wall panel for FE meshing (bare SI): a vertical rectangle from
`(x1,y1)` to `(x2,y2)` in plan, spanning `[z_bot, z_top]`, thickness `t`, with
concrete elastic properties `E`, `ν`.
"""
struct WallPanel
    id::Int
    x1::Float64; y1::Float64
    x2::Float64; y2::Float64
    z_bot::Float64; z_top::Float64
    t::Float64
    E::Float64
    ν::Float64
    story::Int
end

"""
    evaluate_lateral(ev::FEMLateralEvaluator, panels, loads) -> LateralResult

Assemble a mixed Asap model (vertical wall shells + per-floor rigid diaphragm
shells), apply the story lateral loads as diaphragm node forces, solve, and
recover per-wall in-plane shear from `Asap.ShellInternalForces` (the `Nxy`
membrane resultant integrated over the panel). See file header for status.

NOTE: `panels::Vector{WallPanel}` (not `WallLine`) because FE needs full panel
geometry; `walls_to_panels` builds them from the reduced-model `WallLine`s.
"""
function evaluate_lateral(ev::FEMLateralEvaluator,
                          panels::Vector{WallPanel},
                          loads::Vector{StoryLoad})
    model, node_index, panel_nodes = _build_asap_wall_model(ev, panels, loads)

    # Solve the assembled mixed model. VERIFY: Asap.solve! signature/mutation.
    Asap.solve!(model)

    nstory = length(ev.story_heights)
    story_disp = zeros(nstory, 3)
    drift = zeros(nstory)
    torsion = ones(nstory)
    wall_forces = Dict{Int,Float64}()

    # Per-wall in-plane shear = ∫ Nxy along the panel (membrane shear flow).
    # VERIFY: Asap.ShellInternalForces field names (Nxy) and API.
    for p in panels
        V = 0.0
        for el in get(panel_nodes, p.id, ())
            sif = Asap.ShellInternalForces(el, model.u)
            edge_len = _panel_edge_length(p) / max(ev.mesh_div, 1)
            V += abs(sif.Nxy) * edge_len   # N/m × m → N
        end
        wall_forces[p.id] = V
    end

    # Story displacements from a representative diaphragm node per floor.
    # VERIFY: node DOF indexing in Asap's global displacement vector `model.u`.
    for s in 1:nstory
        # Placeholder recovery: the reduced evaluator is the validated oracle for
        # drift; FEM drift recovery is wired once the Asap node/DOF map is
        # confirmed against a benchmark (todo-w0000004).
        story_disp[s, :] .= 0.0
        drift[s] = 0.0
        torsion[s] = 1.0
    end

    return LateralResult(story_disp, drift, wall_forces, torsion)
end

"""
    walls_to_panels(walls, story_elevations, thickness_of) -> Vector{WallPanel}

Bridge the reduced-model `WallLine`s to FE `WallPanel`s. `thickness_of(id)`
returns the wall thickness [m]; `story_elevations` gives floor levels [m].
Wall length/orientation are recovered from the `WallLine` position + `θ` and the
supplied `lengths` map.
"""
function walls_to_panels(walls::Vector{WallLine},
                         story_elevations::Vector{Float64},
                         thickness_of::Function,
                         length_of::Function,
                         E::Float64, ν::Float64)
    panels = WallPanel[]
    for w in walls
        lw = length_of(w.id)
        half = lw / 2
        dx = cos(w.θ) * half; dy = sin(w.θ) * half
        z_bot = story_elevations[w.story]
        z_top = story_elevations[w.story + 1]
        push!(panels, WallPanel(w.id, w.x - dx, w.y - dy, w.x + dx, w.y + dy,
                                z_bot, z_top, thickness_of(w.id), E, ν, w.story))
    end
    return panels
end

# ------------------------------------------------------------------------------
# Asap model assembly (integration points flagged VERIFY — see file header)
# ------------------------------------------------------------------------------

_panel_edge_length(p::WallPanel) = sqrt((p.x2 - p.x1)^2 + (p.y2 - p.y1)^2)

"""
    _build_asap_wall_model(ev, panels, loads) -> (model, node_index, panel_nodes)

Build the mixed frame/shell Asap model: vertical wall shells + per-floor rigid
diaphragm shells + lateral node forces. This is the concrete wiring that
`to_asap!` is missing (it drops shells). VERIFY every Asap.* call against the
Asap API and cover with a benchmark before use (todo-w0000004).
"""
function _build_asap_wall_model(ev::FEMLateralEvaluator,
                                panels::Vector{WallPanel},
                                loads::Vector{StoryLoad})
    # Placeholder assembler: this documents the required construction and returns
    # a structure the recovery code expects. The actual Asap element/model
    # constructors are intentionally NOT invoked here until their signatures are
    # verified against a benchmark, so loading/tests of the reduced tier are not
    # coupled to the (currently unvalidated) Asap wall-mesh path.
    error("FEMLateralEvaluator: Asap vertical-wall-shell assembly is not yet " *
          "wired (todo-w0000004). Use ReducedDiaphragmEvaluator for the S4 " *
          "inner loop; enable this tier after the Asap mesh benchmark lands.")
end
