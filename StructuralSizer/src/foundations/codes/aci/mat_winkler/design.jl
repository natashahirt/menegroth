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
    opts::MatParams = MatParams(),
    walls::Vector{<:WallLineDemand} = WallLineDemand[],
)
    # The rigid mat applies a wall line. This plate does not: a non-empty
    # `walls` would drop that load, so it stops here instead.
    isempty(walls) || error(
        "Winkler mat design does not apply wall line loads. Keep the rigid method, or place the line on the plate.")
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
    ν_c   = Float64(opts.material.concrete.ν)  # Poisson's ratio from material

    # Concrete modulus — ACI 318-11 §8.5.1 (corpus: aci-318-11, page 115)
    Ec_c = Ec(fc)

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
    ks_Pa_m = ustrip(u"N/m^3", soil.ks)

    # ── Step 3: Build mesh + model + springs ONCE (outside thickness loop) ──
    # Mesh topology, node positions, tributary spring stiffnesses, and
    # column loads are all independent of thickness.  Only the per-element
    # `K` matrices change with `h` (via the in-place section update below),
    # so we build the mesh/model exactly once and reuse them for every
    # thickness trial.  Saves an O(N_iter) Delaunay triangulation +
    # full-model assembly that previously dominated runtime.
    h = opts.min_depth
    h_incr = opts.depth_increment

    # Effective depth per ACI 318-11 §2.2 (corpus: aci-318-11, page 37):
    # d = h − cover − db/2, measured from extreme compression fiber to the
    # centroid of the longitudinal tension reinforcement.  We use the
    # larger of the two layer diameters (worst case for d_eff in punching).
    db_eff = max(db_x, db_y) / 2

    # Punching estimate is only a start. Every thinner grid point is still
    # checked, so a high seed cannot skip a passing thickness. The plate
    # is built once, at the thickness the loop will try first.
    h_seed = _mat_punching_h_seed(demands, fc, λ_c, ϕv, cover, db_eff)
    k_h = _mat_depth_index(h, h_incr, h_seed)
    if k_h > 0
        qu_seed = sum(dem.Pu for dem in demands) / (B * Lm)
        for k in 0:k_h
            h_k = _mat_grid_h(opts.min_depth, h_incr, k)
            d_k = h_k - cover - db_eff
            d_k < 6.0u"inch" && continue
            util_k = _mat_punching_util(demands, plan, qu_seed, d_k, fc, λ_c, ϕv)
            if util_k <= 1.0
                k_h = k
                break
            end
        end
    end
    h = _mat_grid_h(opts.min_depth, h_incr, k_h)
    n_thick = 60 - k_h

    Ec_Pa = ustrip(u"Pa", Ec_c)
    h_init_m = ustrip(u"m", h)

    # Shell section seeded at the initial thickness; per-element thickness
    # is mutated in place each iteration of the thickness loop (see below).
    section_init = ShellSection(h_init_m * u"m", Ec_Pa * u"Pa", ν_c)

    # ShellPatch at each column (per-column dimensions, same section as slab).
    # Patch sections share the same initial thickness as the main mat —
    # they are mutated together with the main shell elements.
    patches = ShellPatch[]
    for (j, (cx, cy)) in enumerate(positions_loc_m)
        push!(patches, ShellPatch(cx, cy, col_c1_m[j], col_c2_m[j],
                                  section_init; id=:col_patch))
    end

    # Build Delaunay mesh with Ruppert refinement at column patches
    shells = Shell(corner_nodes, section_init;
                   id=:mat_fea,
                   interior_nodes=interior_nodes,
                   interior_patches=patches,
                   edge_support_type=edge_dofs,
                   interior_support_type=:free,
                   target_edge_length=target_edge,
                   refinement_edge_length=refine_edge)

    nodes = get_nodes(shells)

    # Apply column loads (ShellPatch guarantees a node at each column).
    # NodeForce magnitudes are independent of thickness, so this is built once.
    loads = _mat_apply_column_loads(nodes, positions_loc_m, demands)

    # Generate Winkler springs (one per node, tributary-area based).
    # `elem.area` is computed from node positions (independent of thickness),
    # so the spring stiffnesses are constant across the thickness sweep.
    springs = _mat_winkler_springs(
        nodes, shells, B_m, Lm_m, ks_Pa_m, method.double_edge_springs)

    # Build model and process once.  Subsequent thickness changes are
    # propagated by mutating elem.thickness on each ShellTri3 and calling
    # Asap.update!(model; values_only=true) inside _solve_winkler!.
    model = Model(nodes, shells, loads)
    process!(model)

    # Storage for results from the final (converged) thickness iteration —
    # only the last iteration's moments and active mask flow downstream.
    local gov_Mx_total_pos, gov_Mx_total_neg, gov_My_total_pos, gov_My_total_neg
    local active_springs_mask

    for iter in 1:n_thick
        d_eff = h - cover - db_eff
        d_eff < 6.0u"inch" && (h += h_incr; continue)

        h_m = ustrip(u"m", h)

        # In-place section update: mutate thickness on every shell element
        # (main mat + column patches share the same section schedule).
        # E and ν are invariant across thickness iterations.
        for elem in shells
            elem.thickness = h_m
        end

        # Solve plate-on-Winkler model (compression-only by default; iterates
        # the active set until uplifted springs are deactivated and any
        # re-engaged springs are reactivated).  Throws on non-convergence —
        # there is no silent fallback to a partially-converged solution.
        # Reuses `model` with refreshed K from the new thickness.
        active_springs_mask = _solve_winkler!(
            model, springs, loads;
            no_tension = method.no_tension_springs,
            max_iters  = method.max_no_tension_iters,
            tol        = method.no_tension_tol,
        )

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
        # Extract moments and rotate from element-local to global coordinates.
        # Each ShellTri3 has its own LCS; moments must be rotated before integration.
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
            
            # Rotate element-local moments to global frame:
            # M_global = R · M_local · Rᵀ  where R = [ex ey] (columns = local axes)
            ex1, ex2 = elem.LCS[1][1], elem.LCS[1][2]
            ey1, ey2 = elem.LCS[2][1], elem.LCS[2][2]
            Mxx_l = M_buf[1]  # local Mxx
            Myy_l = M_buf[2]  # local Myy
            Mxy_l = M_buf[3]  # local Mxy
            
            # Global frame moments
            elem_Mxx[k] = Mxx_l * ex1^2 + Myy_l * ey1^2 + 2 * Mxy_l * ex1 * ey1
            elem_Myy[k] = Mxx_l * ex2^2 + Myy_l * ey2^2 + 2 * Mxy_l * ex2 * ey2
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

        # ── Punching shear check (reuse shared util with corner detection) ──
        qu_punch = sum(d.Pu for d in demands) / (B * Lm)
        util_p = _mat_punching_util(demands, plan, qu_punch, d_eff, fc, λ_c, ϕv)
        punch_ok = util_p ≤ 1.0

        # Same (Mu, b) pairs Step 4 reinforces; moments change with h.
        flex_ok = _footing_flexure_ok(((gov_Mx_total_pos * u"N*m", Lm),
                                       (gov_Mx_total_neg * u"N*m", Lm),
                                       (gov_My_total_pos * u"N*m", B),
                                       (gov_My_total_neg * u"N*m", B)),
                                      d_eff, fc, fy, ϕf)

        punch_ok && flex_ok && break
        h += h_incr
        iter == n_thick && @warn "WinklerFEA mat thickness did not converge at h=$h"
    end

    d_eff = h - cover - db_eff  # ACI 318-11 §2.2 — centroid of tension reinforcement

    # ── Step 3b: Vertical equilibrium & uplift diagnostics ──
    # Sums the signed reaction Σ kz·(−w) over the active springs (only
    # springs in compression contribute under the no-tension model; under
    # the legacy two-way model both signs contribute and partially cancel).
    # The two-way path keeps a separate uplift accumulator so a stiff
    # point-loaded mat doesn't false-alarm equilibrium when corners heave.
    F_applied = sum(abs(ustrip(u"N", l.value[3])) for l in loads)
    F_reaction_compr  = 0.0  # springs in compression (w < 0): push up
    F_reaction_uplift = 0.0  # springs in tension    (w > 0): pull down (2-way only)
    n_lifted_off = 0          # nodes that lifted off (no-tension only)
    for (i, s) in enumerate(springs)
        kz = s.stiffness[3]                          # N/m
        w  = ustrip(u"m", s.node.displacement[3])    # m (signed)
        if method.no_tension_springs
            if active_springs_mask[i]
                F_reaction_compr += kz * (-w)        # active ⇒ w ≤ 0
            else
                n_lifted_off += 1                    # deactivated by iteration
            end
        else
            if w < 0
                F_reaction_compr  += kz * (-w)
            else
                F_reaction_uplift += kz *   w
            end
        end
    end
    F_reaction_net = F_reaction_compr - F_reaction_uplift
    eq_imbalance = F_applied > 0 ? abs(F_applied - F_reaction_net) / F_applied : 0.0
    eq_imbalance > 0.02 && @warn(
        "WinklerFEA vertical equilibrium imbalance: " *
        "applied=$(round(F_applied/1e3, digits=1)) kN, " *
        "reaction_net=$(round(F_reaction_net/1e3, digits=1)) kN, " *
        "error=$(round(100*eq_imbalance, digits=2))%")

    # Diagnostic: how much of the mat lost soil contact?  Under the no-
    # tension model this is a *node count* (force is zero by construction);
    # under the two-way model it's a force fraction (legacy diagnostic).
    if method.no_tension_springs
        n_total = length(springs)
        lift_frac_nodes = n_total > 0 ? n_lifted_off / n_total : 0.0
        lift_frac_nodes > 0.20 && @info(
            "WinklerFEA: $(n_lifted_off) / $n_total spring nodes " *
            "($(round(100*lift_frac_nodes, digits=1))%) lifted off the " *
            "soil (no-tension model).  Significant edge / corner uplift " *
            "is expected on stiff, concentrically loaded mats.")
    else
        uplift_frac = F_applied > 0 ? F_reaction_uplift / F_applied : 0.0
        uplift_frac > 0.05 && @warn(
            "WinklerFEA (2-way mode): $(round(100*uplift_frac, digits=1))% " *
            "of applied load is balanced by tension in soil springs " *
            "(corner heave).  Switch to compression-only springs " *
            "(`WinklerFEA(no_tension_springs=true)`) if uplift is unphysical.")
    end

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
                             utilization;
                             analysis = :winkler)
end
