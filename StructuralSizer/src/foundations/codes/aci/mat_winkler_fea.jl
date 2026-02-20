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

# ─────────────────────────────────────────────────────────────────────────────
# Column load application
# ─────────────────────────────────────────────────────────────────────────────

"""
    _find_nearest_node(nodes, x_m, y_m) → (node, dist)

Find the node closest to (x_m, y_m) in meters.
"""
function _find_nearest_node(nodes::Vector{Node}, x_m::Float64, y_m::Float64)
    best = nodes[1]
    best_d2 = Inf
    for node in nodes
        nx = ustrip(u"m", node.position[1])
        ny = ustrip(u"m", node.position[2])
        d2 = (nx - x_m)^2 + (ny - y_m)^2
        if d2 < best_d2
            best_d2 = d2
            best = node
        end
    end
    return best, sqrt(best_d2)
end

"""
    _mat_apply_column_loads(nodes, positions_loc_m, demands) → Vector{NodeForce}

Apply each column's Pu as a downward NodeForce at the nearest mesh node.
With ShellPatch, there is always a node at (or very near) the column center.
"""
function _mat_apply_column_loads(
    nodes::Vector{Node},
    positions_loc_m::Vector{NTuple{2, Float64}},
    demands::Vector{<:FoundationDemand}
)
    loads = NodeForce[]
    for (k, dem) in enumerate(demands)
        cx, cy = positions_loc_m[k]
        Pu_N = ustrip(u"N", uconvert(u"N", dem.Pu))
        node, _ = _find_nearest_node(nodes, cx, cy)
        push!(loads, NodeForce(node, [0.0, 0.0, -Pu_N] .* u"N"))
    end
    return loads
end

# ─────────────────────────────────────────────────────────────────────────────
# Column-strip moment integration (analogous to slab FEA _integrate_at)
# ─────────────────────────────────────────────────────────────────────────────

"""
    _strip_moment(cx, cy, area, M, n, span_pos, span_half, trans_pos, trans_half)

Area-weighted average moment per unit length within a rectangular strip.

Selects elements whose centroid is within `span_half` of `span_pos` along the
span direction AND within `trans_half` of `trans_pos` in the transverse direction.

Returns `Σ(M_i × A_i) / Σ(A_i)` (N·m/m), i.e. the average moment *intensity*
within the strip.  Multiply by full mat width for total As.

This is the mat-foundation analog of the slab FEA's `_integrate_at()`, which
integrates within cell-scoped triangles at column faces and midspan sections.
"""
function _strip_moment(
    cx_arr::Vector{Float64}, cy_arr::Vector{Float64},
    area_arr::Vector{Float64}, M_arr::Vector{Float64}, n::Int,
    span_pos::Float64, span_half::Float64,
    trans_pos::Float64, trans_half::Float64,
)
    Mn_A   = 0.0   # N·m·m accumulator (moment × area)
    strip_A = 0.0   # m²   accumulator (total area in strip)
    @inbounds for k in 1:n
        abs(cx_arr[k] - span_pos)  > span_half  && continue
        abs(cy_arr[k] - trans_pos) > trans_half  && continue
        Mn_A    += M_arr[k] * area_arr[k]
        strip_A += area_arr[k]
    end
    return strip_A > 1e-10 ? Mn_A / strip_A : 0.0
end

# ─────────────────────────────────────────────────────────────────────────────
# Main Winkler FEA design driver
# ─────────────────────────────────────────────────────────────────────────────

"""
    _design_mat_winkler_fea(demands, positions, soil, method; opts) → MatFootingResult

Design a mat foundation using FEA plate on Winkler springs.

Mesh generated via Asap's polygon-based Delaunay triangulation with
ShellPatch at each column (Ruppert refinement for graded element quality).
Same meshing approach as the slab FEA.

Iterates on thickness h to satisfy punching shear at every column.
Flexural reinforcement from governing shell bending moments.

Requires `soil.ks` to be provided.

# References
- ACI 336.2R-88 §6.4, §6.7, §6.9.
"""
function _design_mat_winkler_fea(
    demands::Vector{<:FoundationDemand},
    positions::Vector{<:NTuple{2, <:Length}},
    soil::Soil,
    method::WinklerFEA;
    opts::MatFootingOptions = MatFootingOptions()
)
    N_col = length(demands)
    soil.ks !== nothing || error("WinklerFEA requires soil.ks to be provided")

    # Material / options
    fc    = opts.material.concrete.fc′
    fy    = opts.material.rebar.Fy
    λ_c   = something(opts.λ, opts.material.concrete.λ)
    cover = opts.cover
    db_x  = bar_diameter(opts.bar_size_x)
    db_y  = bar_diameter(opts.bar_size_y)
    ϕf    = opts.ϕ_flexure
    ϕv    = opts.ϕ_shear
    ν_c   = 0.2  # concrete Poisson's ratio

    # Concrete modulus — ACI 318 §19.2.2.1
    Ec = 57000.0u"psi" * sqrt(ustrip(u"psi", fc))

    # ── Step 1: Plan Sizing (first-principles overhang) ──
    plan = _mat_plan_sizing(positions, opts; demands = demands, soil = soil)
    B, Lm = plan.B, plan.Lm
    B_m  = ustrip(u"m", B)
    Lm_m = ustrip(u"m", Lm)

    Ps_total = sum(d.Ps for d in demands)
    util_bearing = to_kip(Ps_total) / to_kip(soil.qa * B * Lm)
    util_bearing > 1.0 && @warn "Mat bearing exceeds allowable: util=$(round(util_bearing, digits=3))"

    # Per-column dimensions (in metres) for ShellPatch sizing & mesh refinement
    col_c1_m = [ustrip(u"m", demands[j].c1) for j in 1:N_col]
    col_c2_m = [ustrip(u"m", demands[j].c2) for j in 1:N_col]
    c_max_m  = maximum(max(col_c1_m[j], col_c2_m[j]) for j in 1:N_col)

    # ── Step 2: Mesh parameters ──
    # Adaptive target edge: ~20 elements per shortest bay, clamped [0.15, 0.75] m
    # (same heuristic as the slab FEA).
    bay_xs = sort(unique(ustrip.(u"m", [p[1] for p in positions])))
    bay_ys = sort(unique(ustrip.(u"m", [p[2] for p in positions])))
    min_bay_m = Inf
    for i in 2:length(bay_xs); min_bay_m = min(min_bay_m, bay_xs[i] - bay_xs[i-1]); end
    for i in 2:length(bay_ys); min_bay_m = min(min_bay_m, bay_ys[i] - bay_ys[i-1]); end
    if isinf(min_bay_m); min_bay_m = min(B_m, Lm_m); end

    te_m = if method.target_edge === nothing
        clamp(min_bay_m / 20.0, 0.15, 0.75)
    else
        ustrip(u"m", method.target_edge)
    end
    target_edge = te_m * u"m"

    # Refinement edge: half the largest column dimension, clamped to [0.04, te_m/2] m
    # (same as slab FEA — ensures ≥2 elements across each column face).
    refine_edge = clamp(c_max_m / 2.0, 0.04, te_m / 2.0) * u"m"

    # Column positions in local mesh coordinates (meters)
    positions_loc_m = [
        (ustrip(u"m", plan.xs_loc[j]), ustrip(u"m", plan.ys_loc[j]))
        for j in 1:N_col
    ]

    # ── Step 2b: Build geometry once (outside thickness loop) ──
    # Corner nodes of mat rectangle (CCW)
    corner_nodes = (
        Node([0.0u"m", 0.0u"m",  0.0u"m"], :free),
        Node([B_m*u"m", 0.0u"m",  0.0u"m"], :free),
        Node([B_m*u"m", Lm_m*u"m", 0.0u"m"], :free),
        Node([0.0u"m", Lm_m*u"m", 0.0u"m"], :free),
    )

    # Interior nodes at column positions (ensures mesh nodes exist at columns)
    interior_nodes = Node[]
    for (cx, cy) in positions_loc_m
        push!(interior_nodes, Node([cx * u"m", cy * u"m", 0.0u"m"], :free))
    end

    # Pin in-plane DOFs on boundary (same as slab FEA)
    edge_dofs = [false, false, true, true, true, true]

    # Soil spring stiffness in SI
    ks_Pa_m = ustrip(u"N/m^3", uconvert(u"N/m^3", soil.ks))

    # ── Step 3: Iterate on thickness ──
    h = opts.min_depth
    h_incr = opts.depth_increment

    Ec_Pa = ustrip(u"Pa", uconvert(u"Pa", Ec))
    local gov_Mx_total_pos, gov_Mx_total_neg, gov_My_total_pos, gov_My_total_neg
    local loads, springs  # saved for equilibrium check

    for iter in 1:60
        d_eff = h - cover - max(db_x, db_y)
        d_eff < 6.0u"inch" && (h += h_incr; continue)

        h_m = ustrip(u"m", h)

        # Shell section (updated each iteration for new thickness)
        section = ShellSection(h_m * u"m", Ec_Pa * u"Pa", ν_c)

        # ShellPatch at each column (per-column dimensions, same section as slab)
        patches = ShellPatch[]
        for (j, (cx, cy)) in enumerate(positions_loc_m)
            push!(patches, ShellPatch(cx, cy, col_c1_m[j], col_c2_m[j],
                                      section; id=:col_patch))
        end

        # Build Delaunay mesh with Ruppert refinement at column patches
        shells = Shell(corner_nodes, section;
                       id=:mat_fea,
                       interior_nodes=interior_nodes,
                       interior_patches=patches,
                       edge_support_type=edge_dofs,
                       interior_support_type=:free,
                       target_edge_length=target_edge,
                       refinement_edge_length=refine_edge)

        nodes = get_nodes(shells)

        # Apply column loads (ShellPatch guarantees a node at each column)
        loads = _mat_apply_column_loads(nodes, positions_loc_m, demands)

        # Build model — springs added after process!
        model = Model(nodes, shells, loads)
        process!(model)

        # Add Winkler springs (tributary-area based)
        springs = _mat_winkler_springs(
            nodes, shells, B_m, Lm_m, ks_Pa_m, method.double_edge_springs)
        add_springs!(model, springs)

        # Solve
        solve!(model)

        # ── Extract governing moments (column-strip integration) ──
        # Mirrors the slab FEA's _integrate_at() / _extract_cell_strip_moments()
        # pattern: integrate Mxx × A within a column-strip-width band in the
        # transverse direction, evaluated at column faces and midspan positions.
        #
        # For Mxx (bending in the xz-plane):
        #   - δ-band along x (span direction): max(c_max, min_span/20, 0.25m)
        #   - Column strip in y (transverse): half the min y-span
        #   - Evaluate at each column x-line and at each midspan x-line
        #   - Average moment per unit length = Σ(Mxx×A) / (δ × strip_width)
        #   - Design moment = avg_m/m × full mat width (conservative: assumes
        #     column-strip intensity across the full width)
        #
        # This captures the localized moment concentration near columns that
        # the full-width integration loses, while avoiding single-element peaks.

        # ── Precompute per-element data (same pattern as slab FEA cache) ──
        n_elems = length(shells)
        elem_cx   = Vector{Float64}(undef, n_elems)
        elem_cy   = Vector{Float64}(undef, n_elems)
        elem_area = Vector{Float64}(undef, n_elems)
        elem_Mxx  = Vector{Float64}(undef, n_elems)
        elem_Myy  = Vector{Float64}(undef, n_elems)
        ws = Asap.ShellMomentWorkspace()
        M_buf = zeros(3)
        for (k, elem) in enumerate(shells)
            c  = shell_centroid(elem)
            bending_moments!(M_buf, elem, model.u, ws)
            elem_cx[k]   = c.x
            elem_cy[k]   = c.y
            elem_area[k] = elem.area
            elem_Mxx[k]  = M_buf[1]
            elem_Myy[k]  = M_buf[2]
        end

        # ── Column and midspan lines ──
        col_xs = sort(unique(round.(ustrip.(u"m", plan.xs_loc); digits=4)))
        col_ys = sort(unique(round.(ustrip.(u"m", plan.ys_loc); digits=4)))
        mid_xs = [(col_xs[i] + col_xs[i+1]) / 2 for i in 1:length(col_xs)-1]
        mid_ys = [(col_ys[i] + col_ys[i+1]) / 2 for i in 1:length(col_ys)-1]

        # Span lengths (m)
        span_xs = [col_xs[i+1] - col_xs[i] for i in 1:length(col_xs)-1]
        span_ys = [col_ys[i+1] - col_ys[i] for i in 1:length(col_ys)-1]
        min_span_x = isempty(span_xs) ? B_m : minimum(span_xs)
        min_span_y = isempty(span_ys) ? Lm_m : minimum(span_ys)

        # Strip parameters (same δ formula as slab FEA: max(c_max, L/20, 0.25m))
        δ_x = max(c_max_m, min_span_x / 20, 0.25)   # band width along x
        δ_y = max(c_max_m, min_span_y / 20, 0.25)   # band width along y

        # Column strip width in the transverse direction (DDM: half the span)
        cs_width_y = isempty(span_ys) ? Lm_m / 2 : minimum(span_ys) / 2
        cs_width_x = isempty(span_xs) ? B_m / 2  : minimum(span_xs) / 2

        # ── Mxx: sweep column faces and midspan along x, within y-column-strip ──
        gov_mx_pos = 0.0   # max positive Mxx per unit length (top tension)
        gov_mx_neg = 0.0   # max |negative| Mxx per unit length (bottom tension)

        eval_xs = vcat(col_xs, mid_xs)
        cs_half_y = cs_width_y / 2

        for x_eval in eval_xs
            # Evaluate at each column y-line (column strip centered on that y)
            for y_line in col_ys
                m = _strip_moment(elem_cx, elem_cy, elem_area, elem_Mxx, n_elems,
                                  x_eval, δ_x / 2, y_line, cs_half_y)
                gov_mx_pos = max(gov_mx_pos,  m)
                gov_mx_neg = max(gov_mx_neg, -m)
            end
        end

        # ── Myy: sweep column faces and midspan along y, within x-column-strip ──
        gov_my_pos = 0.0
        gov_my_neg = 0.0

        eval_ys = vcat(col_ys, mid_ys)
        cs_half_x = cs_width_x / 2

        for y_eval in eval_ys
            for x_line in col_xs
                m = _strip_moment(elem_cy, elem_cx, elem_area, elem_Myy, n_elems,
                                  y_eval, δ_y / 2, x_line, cs_half_x)
                gov_my_pos = max(gov_my_pos,  m)
                gov_my_neg = max(gov_my_neg, -m)
            end
        end

        # Convert governing per-unit-length moments to total (× full mat width).
        # Conservative: assumes column-strip intensity across the full width.
        gov_Mx_total_pos = gov_mx_pos * Lm_m   # N·m
        gov_Mx_total_neg = gov_mx_neg * Lm_m
        gov_My_total_pos = gov_my_pos * B_m
        gov_My_total_neg = gov_my_neg * B_m

        # ── Punching shear check (per-column dimensions) ──
        qu_punch = sum(d.Pu for d in demands) / (B * Lm)
        punch_ok = true
        for j in 1:N_col
            c1j, c2j = demands[j].c1, demands[j].c2
            is_edge = (
                plan.xs_loc[j] < plan.overhang + 0.5u"ft" ||
                plan.xs_loc[j] > (B - plan.overhang - 0.5u"ft") ||
                plan.ys_loc[j] < plan.overhang + 0.5u"ft" ||
                plan.ys_loc[j] > (Lm - plan.overhang - 0.5u"ft")
            )
            pos_sym = is_edge ? :edge : :interior
            Ac = if demands[j].shape == :circular
                π * (c1j + d_eff)^2 / 4
            else
                is_edge ? (c1j + d_eff / 2) * (c2j + d_eff) :
                          (c1j + d_eff) * (c2j + d_eff)
            end
            Vu_p = max(uconvert(u"lbf", demands[j].Pu - qu_punch * Ac), 0.0u"lbf")

            pch = punching_check(Vu_p, demands[j].Mux, demands[j].Muy,
                                  d_eff, fc, c1j, c2j;
                                  position = pos_sym, shape = demands[j].shape,
                                  λ = λ_c, ϕ = ϕv)
            if !pch.ok
                punch_ok = false
                break
            end
        end

        punch_ok && break
        h += h_incr
        iter == 60 && @warn "WinklerFEA mat thickness did not converge at h=$h"
    end

    d_eff = h - cover - max(db_x, db_y)

    # ── Step 3b: Vertical equilibrium check ──
    # ΣF_applied (downward) should equal ΣF_spring (upward).
    # Springs: F_up = kz × |w|.  Applied: Fz < 0 (downward).
    F_applied = sum(abs(ustrip(u"N", l.value[3])) for l in loads)
    F_reaction = sum(
        let kz = s.stiffness[3]             # N/m
            w  = ustrip(u"m", s.node.displacement[3])  # m (negative = down)
            kz * abs(w)
        end for s in springs)
    eq_imbalance = F_applied > 0 ? abs(F_applied - F_reaction) / F_applied : 0.0
    eq_imbalance > 0.05 && @warn(
        "WinklerFEA vertical equilibrium imbalance: " *
        "applied=$(round(F_applied/1e3, digits=1)) kN, " *
        "reaction=$(round(F_reaction/1e3, digits=1)) kN, " *
        "error=$(round(100*eq_imbalance, digits=2))%")

    # ── Step 4: Flexural reinforcement from FEA moments ──
    # Column-strip integration gives the governing average moment per unit
    # length within the column strip, then scales to full mat width.
    # This is analogous to the slab FEA's _integrate_at() with cell-scoped
    # triangles and DDM column-strip definitions.
    #
    # Asap sign convention:
    #   positive Mxx → TOP tension (hogging)  → As_top
    #   negative Mxx → BOTTOM tension (sagging) → As_bot
    #
    # gov_Mx_total_pos = column-strip avg Mxx/m × full y-width (N·m)
    # gov_Mx_total_neg = column-strip avg |neg Mxx|/m × full y-width (N·m)
    Mx_pos_total = gov_Mx_total_pos * u"N*m"   # top tension
    Mx_neg_total = gov_Mx_total_neg * u"N*m"   # bottom tension
    My_pos_total = gov_My_total_pos * u"N*m"   # top tension
    My_neg_total = gov_My_total_neg * u"N*m"   # bottom tension

    # positive → As_top (top tension → top steel)
    As_x_top = max(_flexural_steel_footing(uconvert(u"lbf*ft", Mx_pos_total), Lm, d_eff, fc, fy, ϕf),
                   _min_steel_footing(Lm, h, fy))
    # |negative| → As_bot (bottom tension → bottom steel)
    As_x_bot = max(_flexural_steel_footing(uconvert(u"lbf*ft", Mx_neg_total), Lm, d_eff, fc, fy, ϕf),
                   _min_steel_footing(Lm, h, fy))
    # positive → As_top (top tension → top steel)
    As_y_top = max(_flexural_steel_footing(uconvert(u"lbf*ft", My_pos_total), B, d_eff, fc, fy, ϕf),
                   _min_steel_footing(B, h, fy))
    # |negative| → As_bot (bottom tension → bottom steel)
    As_y_bot = max(_flexural_steel_footing(uconvert(u"lbf*ft", My_neg_total), B, d_eff, fc, fy, ϕf),
                   _min_steel_footing(B, h, fy))

    # ── Utilization ──
    qu_final = sum(d.Pu for d in demands) / (B * Lm)
    util_punch = _mat_punching_util(demands, plan, qu_final, d_eff, fc, λ_c, ϕv)
    utilization = max(util_bearing, util_punch)

    return _mat_build_result(plan, demands, opts, h, d_eff,
                             As_x_bot, As_x_top, As_y_bot, As_y_top,
                             utilization)
end
