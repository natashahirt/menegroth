# =============================================================================
# Winkler FEA Mat Foundation Design
# =============================================================================
#
# 2D shell plate on Winkler (uncoupled) soil springs, solved with Asap.
#
# Procedure (ACI 336.2R-88 §6.4 / §6.7):
#   1. Delaunay triangulation with ShellPatch mesh conformity at each column
#      (same as slab FEA) and Ruppert refinement for graded element quality.
#   2. Assign soil springs at every node: K = tributary_area × ks.
#      Tributary area = sum(A_tri/3) over attached triangles.
#      Edge springs doubled per ACI 336.2R §6.9.
#   3. Apply column loads as NodeForces at nearest mesh node (columns
#      coincide with ShellPatch centers, so there is always a node there).
#   4. Solve shell + spring model → displacements, bending moments.
#   5. Iterate on thickness h for punching shear.
#   6. Column-strip integration for governing moments (analogous to slab FEA's
#      _integrate_at / _extract_cell_strip_moments).  Average moment per unit
#      length within each column strip, then scale to full mat width for As.
#
# Fully Unitful throughout.
# References:
#   - ACI 336.2R-88 §6.4 (FEM), §6.7 (Winkler springs), §6.9 (edge springs)
#   - ACI 336.2R-88 Fig 6.8 (spring computation)
# =============================================================================

using Asap: Node, ShellTri3, ShellSection, ShellPatch, Shell, Spring, NodeForce,
            Model, process!, solve!, add_springs!, get_nodes,
            bending_moments, bending_moments!, ShellMomentWorkspace, shell_centroid
# `Asap.update!` is invoked qualified (StructuralSizer already exports its
# own `update!`, so we avoid importing the symbol unqualified to keep the
# two semantically-distinct functions clearly separated).

# ─────────────────────────────────────────────────────────────────────────────
# Winkler spring generation — ACI 336.2R §6.7, Fig 6.8
# ─────────────────────────────────────────────────────────────────────────────

"""
    _mat_winkler_springs(nodes, shells, B_m, Lm_m, ks_Pa_m, double_edge)

Create Winkler soil springs at each node.  Spring constant =
tributary_area × ks.  Tributary area per node = Σ(A_tri/3) over
all triangles touching that node (Voronoi dual approximation).

Edge/corner status determined from node position; edge springs
doubled per ACI 336.2R §6.9 when `double_edge = true`.
"""
function _mat_winkler_springs(
    nodes::Vector{Node},
    shells::Vector{<:ShellTri3},
    B_m::Float64, Lm_m::Float64,
    ks_Pa_m::Float64,
    double_edge::Bool
)
    # Build tributary area per node: sum of A_tri/3 for each connected element
    trib = Dict{UInt64, Float64}()
    for elem in shells
        A3 = elem.area / 3.0  # m²
        for nd in elem.nodes
            key = objectid(nd)
            trib[key] = get(trib, key, 0.0) + A3
        end
    end

    edge_tol = min(B_m, Lm_m) * 1e-4
    springs = Spring[]

    for node in nodes
        A_trib = get(trib, objectid(node), 0.0)
        A_trib < 1e-12 && continue  # orphan node

        K_vert = A_trib * ks_Pa_m  # N/m

        # ACI 336.2R §6.9: double edge springs for coupling approximation
        if double_edge
            x = ustrip(u"m", node.position[1])
            y = ustrip(u"m", node.position[2])
            on_edge = (x < edge_tol || x > B_m - edge_tol ||
                       y < edge_tol || y > Lm_m - edge_tol)
            if on_edge
                K_vert *= 2.0
            end
        end

        push!(springs, Spring(node; kz = K_vert * u"N/m"))
    end

    return springs
end

