# =============================================================================
# Story Properties for Sway Magnification (ACI 318-19 §6.6.4.6)
# =============================================================================
#
# Computes story-level properties needed for sway moment magnification:
# - ΣPu: Sum of factored axial loads on all columns in story
# - ΣPc: Sum of critical buckling loads (placeholder until sections known)
# - Vus: Factored story shear
# - Δo: First-order story drift
# - lc: Story height (center-to-center of joints)
#
# These properties are assigned to each column's `story_properties` field
# after structural analysis when displacements and forces are available.
#
# =============================================================================

"""
    compute_story_properties!(struc; concrete=NWC_4000, verbose=false)

Compute and assign story properties to all columns for sway magnification.

This function should be called after structural analysis (ASAP solve) when
displacements and member forces are available. It populates the `story_properties`
field on each Column for use in ACI 318-19 sway moment magnification.

# Keyword Arguments
- `concrete`: Concrete material for Ec estimation (default: `NWC_4000`)
- `verbose`: Print diagnostic info

# Story-Level Properties (all returned as Unitful quantities)
- `ΣPu`: Sum of factored axial loads on all columns in story (Force)
- `ΣPc`: Sum of critical buckling loads (Force, estimated, refined during sizing)
- `Vus`: Factored story shear (Force)
- `Δo`: First-order story drift (Length)
- `lc`: Story height (Length)

# Notes
- ΣPc uses Ec from the provided concrete material (ACI 19.2.2.1)
- Actual ΣPc will be refined during column sizing when sections are known
- Δo is computed from ASAP analysis node displacements

# Example
```julia
# After creating model and running analysis
struc, model = create_asap_model(struc; analyze=true)

# Compute and assign story properties (uses NWC_4000 by default)
compute_story_properties!(struc; verbose=true)

# Column now has story_properties for sway magnification
col = struc.columns[1]
Q = stability_index(col.story_properties)  # Story stability index
```
"""
function compute_story_properties!(struc; concrete::StructuralSizer.Concrete = NWC_4000, verbose::Bool = false)
    # Group columns by story
    CT = eltype(struc.columns)
    columns_by_story = Dict{Int, Vector{CT}}()
    for col in struc.columns
        story = col.story
        if !haskey(columns_by_story, story)
            columns_by_story[story] = CT[]
        end
        push!(columns_by_story[story], col)
    end
    
    # For each story, compute properties
    for (story, cols) in columns_by_story
        props = _compute_story_props(struc, cols, story; concrete=concrete, verbose=verbose)
        
        # Assign to all columns in this story
        for col in cols
            col.story_properties = props
        end
    end
    
    if verbose
        n_stories = length(columns_by_story)
        @info "Computed story properties for $n_stories stories, $(length(struc.columns)) columns"
    end
    
    return struc
end

"""
    _compute_story_props(struc, cols, story; verbose=false) -> NamedTuple

Compute story properties for a single story level.
Returns all values as proper Unitful quantities.
"""
function _compute_story_props(struc, cols, story::Int; concrete::StructuralSizer.Concrete = NWC_4000, verbose::Bool = false)
    n_cols = length(cols)
    
    # --- Story height (lc) ---
    # Use average column length in the story
    lc = sum(col.base.L for col in cols) / n_cols
    
    # --- Sum of factored axial loads (ΣPu) ---
    # Get from ASAP results if available, otherwise estimate from tributary
    ΣPu = 0.0u"kip"
    for col in cols
        # Try to get from analysis results first
        Pu = _get_column_axial_from_analysis(struc, col)
        if isnothing(Pu)
            # Estimate from tributary area if analysis not available
            Pu = _estimate_column_axial(struc, col)
        end
        ΣPu += Pu
    end
    
    # --- Sum of critical buckling loads (ΣPc) ---
    # Use simplified formula: Pc = π²EI/(kLu)²
    # EI estimated as 0.4EcIg until section is known
    ΣPc = _estimate_Pc_sum(struc, cols; concrete=concrete)
    
    # --- Story shear (Vus) ---
    # Sum of column shears at the story level
    Vus = _estimate_story_shear(struc, cols, story)
    
    # --- First-order drift (Δo) ---
    # From ASAP analysis node displacements
    Δo = _compute_story_drift(struc, cols, story)
    
    if verbose
        @debug "Story $story properties:" ΣPu=ΣPu ΣPc=ΣPc Vus=Vus Δo=Δo lc=lc
    end
    
    # Strip to Float64 in (kip, inch) — matches the Column.story_properties field type
    # and SwayStoryProperties conventions
    return (
        ΣPu = ustrip(u"kip",  ΣPu),
        ΣPc = ustrip(u"kip",  ΣPc),
        Vus = ustrip(u"kip",  Vus),
        Δo  = ustrip(u"inch", Δo),
        lc  = ustrip(u"inch", lc),
    )
end

# --- Helper functions ---

"""
    _get_column_axial_from_analysis(struc, col) -> Union{Force, Nothing}

Extract the worst-case factored axial compression from ASAP analysis results.
Returns `nothing` if the model has not been solved.
"""
function _get_column_axial_from_analysis(struc, col)
    # Need a solved ASAP model
    if !hasfield(typeof(struc), :asap_model) || isnothing(struc.asap_model)
        return nothing
    end
    model = struc.asap_model
    hasfield(typeof(model), :processed) && !model.processed && return nothing

    element_loads = Asap.get_elemental_loads(model)

    Pu_max = 0.0  # track worst-case compression (positive = compression)
    for seg_idx in segment_indices(col)
        seg = struc.segments[seg_idx]
        edge_idx = seg.edge_idx
        edge_idx > 0 || continue

        el = model.elements[edge_idx]
        el_loads = get(element_loads, el.elementID, nothing)
        isnothing(el_loads) && continue

        fd = Asap.ElementForceAndDisplacement(el, el_loads; resolution=10)
        # Convention: negative P = compression
        min_P = minimum(fd.forces.P)
        if min_P < 0
            Pu_max = max(Pu_max, abs(min_P))
        end
    end

    Pu_max > 0 ? uconvert(u"kip", Pu_max * u"N") : nothing
end

"""Estimate column axial load from tributary area and loads. Returns Force (kip)."""
function _estimate_column_axial(struc, col)
    # Get tributary area
    trib = column_tributary_by_cell(struc, col)
    
    Pu = 0.0u"kip"
    for (cell_idx, area_m2) in trib
        cell = struc.cells[cell_idx]
        area = area_m2 * u"m^2"
        
        # Governing factored load (ASCE 7 §2.3.1: max of 1.2D+1.6L, 1.4D)
        qD = cell.sdl + cell.self_weight
        qL = cell.live_load
        qu = max(factored_pressure(default_combo, qD, qL),
                 factored_pressure(strength_1_4D, qD, qL))
        
        Pu += uconvert(u"kip", qu * area)
    end
    
    return Pu
end

"""Estimate sum of critical buckling loads for columns in story. Returns Force (kip)."""
function _estimate_Pc_sum(struc, cols; concrete::StructuralSizer.Concrete = NWC_4000)
    # Use simplified EI = 0.4EcIg per ACI 6.6.4.4.4
    # Pc = π²(0.4EcIg)/(kLu)²
    
    Ec_val = StructuralSizer.Ec(concrete)
    ΣPc = 0.0u"kip"
    
    for col in cols
        # Get column dimensions (fall back to defaults if not set)
        c1 = col.c1
        c2 = col.c2
        if isnothing(c1) || isnothing(c2)
            @warn "Column dimensions not yet sized — using 18\" default for stability index" col.base.edge_idx c1 c2 maxlog=1
            c1 = something(c1, 18.0u"inch")
            c2 = something(c2, 18.0u"inch")
        end
        
        # Gross moment of inertia (assuming rectangular)
        Ig = c1 * c2^3 / 12  # About weak axis (conservative)
        
        # Effective stiffness (simplified per ACI 6.6.4.4.4)
        EI_eff = 0.4 * Ec_val * Ig
        
        # Unbraced length
        Lu = col.base.Lb
        k = col.base.Ky  # Use y-axis (weak)
        
        # Critical buckling load
        if ustrip(k * Lu) > 0
            Pc = π^2 * EI_eff / (k * Lu)^2
            ΣPc += uconvert(u"kip", Pc)
        end
    end
    
    return ΣPc
end

"""
    _estimate_story_shear(struc, cols, story) -> Force

Compute factored story shear from ASAP column element forces.

Sums the horizontal shear resultant (√(Vy² + Vz²)) at the bottom end of
each column in the story.  Falls back to 5% of ΣPu if the model has not
been solved.
"""
function _estimate_story_shear(struc, cols, story::Int)
    model = _get_solved_model(struc)
    if isnothing(model)
        ΣPu = sum(_estimate_column_axial(struc, col) for col in cols)
        return 0.05 * ΣPu
    end

    Vus = 0.0  # Newtons

    for col in cols
        for seg_idx in segment_indices(col)
            seg = struc.segments[seg_idx]
            eidx = seg.edge_idx
            (eidx < 1 || eidx > length(model.elements)) && continue

            el = model.elements[eidx]
            isempty(el.forces) && continue
            n_dof = length(el.forces)

            # Local element forces: [Fx1, Fy1, Fz1, Mx1, My1, Mz1,
            #                         Fx2, Fy2, Fz2, Mx2, My2, Mz2]
            # Take bottom end (start) shears — Vy and Vz
            Vy = abs(el.forces[2])
            Vz = n_dof >= 3 ? abs(el.forces[3]) : 0.0
            Vus += sqrt(Vy^2 + Vz^2)
        end
    end

    if Vus ≈ 0
        # No shear detected — fall back to 5% gravity estimate
        ΣPu = sum(_estimate_column_axial(struc, col) for col in cols)
        return 0.05 * ΣPu
    end

    return uconvert(u"kip", Vus * u"N")
end

"""
    _compute_story_drift(struc, cols, story) -> Length

Compute first-order inter-story drift from ASAP node displacements.

For each column, finds top/bottom nodes via the skeleton edge mapping,
reads the solved horizontal displacement, and takes the maximum absolute
inter-story drift across all columns in the story (governing direction).

Falls back to 0.5 in. if the model has not been solved.
"""
function _compute_story_drift(struc, cols, story::Int)
    model = _get_solved_model(struc)
    isnothing(model) && return 0.5u"inch"

    skel = struc.skeleton
    vc   = skel.geometry.vertex_coords   # n_verts × 3 matrix (m)

    max_drift = 0.0  # metres

    for col in cols
        for seg_idx in segment_indices(col)
            seg = struc.segments[seg_idx]
            eidx = seg.edge_idx
            (eidx < 1 || eidx > length(model.elements)) && continue

            v1, v2 = skel.edge_indices[eidx]
            z1, z2 = vc[v1, 3], vc[v2, 3]
            top_idx    = z1 > z2 ? v1 : v2
            bottom_idx = z1 > z2 ? v2 : v1

            # Access solved displacements (Unitful: metres / radians)
            top_node    = model.nodes[top_idx]
            bottom_node = model.nodes[bottom_idx]

            # Horizontal displacement components (indices 1=x, 2=y)
            dx_top = ustrip(u"m", top_node.displacement[1])
            dy_top = ustrip(u"m", top_node.displacement[2])
            dx_bot = ustrip(u"m", bottom_node.displacement[1])
            dy_bot = ustrip(u"m", bottom_node.displacement[2])

            drift_x = abs(dx_top - dx_bot)
            drift_y = abs(dy_top - dy_bot)
            max_drift = max(max_drift, drift_x, drift_y)
        end
    end

    # Guard: if no drift was extracted (all zero or no elements), use fallback
    if max_drift ≈ 0
        return 0.001u"inch"   # near-zero but avoids divide-by-zero downstream
    end
    return uconvert(u"inch", max_drift * u"m")
end

"""Return the solved ASAP model, or `nothing` if unavailable."""
function _get_solved_model(struc)
    !hasfield(typeof(struc), :asap_model) && return nothing
    model = struc.asap_model
    isnothing(model) && return nothing
    hasfield(typeof(model), :processed) && !model.processed && return nothing
    return model
end

# =============================================================================
# P-Δ Iterative Second-Order Analysis (ACI 318-19 §6.7 / §10.10.4)
# =============================================================================
#
# Performs elastic second-order analysis by iteratively applying equivalent
# lateral forces that represent the P-Δ effect:
#
#   F_PΔ = ΣPu × Δ / lc   at each story level
#
# The iteration continues until lateral drifts converge (< tolerance) or the
# ACI 318-19 §6.6.4.6.2 limit is exceeded (secondary moments > 1.4 × primary).
#
# Reference:
#   ACI 318-11 §10.10.4, ACI 318-19 §6.7 — Elastic second-order analysis
#   ACI 318-11 §10.10.2.1 — Total moment ≤ 1.4 × first-order moment
# =============================================================================

"""
    p_delta_iterate!(struc; max_iter=10, tol=0.01, verbose=false) -> NamedTuple

Perform iterative P-Δ elastic second-order analysis on the ASAP model.

After the first-order solve (which must already be done), this function:
1. Extracts story drifts and column axial forces from the solved model
2. Computes equivalent lateral P-Δ forces at each story level
3. Adds them as `NodeForce` loads on story-level column top nodes
4. Re-solves the model
5. Checks convergence (max drift change < `tol`)
6. Checks the ACI §6.6.4.6.2 limit (drift ratio ≤ 1.4×)

# Keyword Arguments
- `max_iter::Int=10`: Maximum P-Δ iterations
- `tol::Float64=0.01`: Convergence tolerance (relative drift change)
- `verbose::Bool=false`: Print iteration diagnostics
- `concrete`: Concrete material for Ec estimation (default: `NWC_4000`)

# Returns
Named tuple:
- `converged::Bool`: Whether iterations converged within tolerance
- `iterations::Int`: Number of iterations performed
- `max_drift_ratio::Float64`: Final max(second-order / first-order) drift ratio
- `stories_needing_attention::Vector{Int}`: Stories where drift ratio > 1.4

# Notes
- The model's loads are modified in-place (P-Δ NodeForces are appended).
  Call this once after the first-order solve; do not call repeatedly unless
  you first remove the added P-Δ loads.
- The original first-order loads remain unchanged — only additive P-Δ
  forces are appended.
"""
function p_delta_iterate!(struc;
    max_iter::Int = 10,
    tol::Float64 = 0.01,
    verbose::Bool = false,
    concrete::StructuralSizer.Concrete = NWC_4000,
)
    model = _get_solved_model(struc)
    if isnothing(model)
        @warn "P-Δ iteration requires a solved ASAP model"
        return (converged=false, iterations=0, max_drift_ratio=NaN,
                stories_needing_attention=Int[])
    end

    skel = struc.skeleton
    vc   = skel.geometry.vertex_coords

    # ── Group columns by story ──
    CT = eltype(struc.columns)
    columns_by_story = Dict{Int, Vector{CT}}()
    for col in struc.columns
        s = col.story
        if !haskey(columns_by_story, s)
            columns_by_story[s] = CT[]
        end
        push!(columns_by_story[s], col)
    end

    # ── Record first-order drifts (baseline) ──
    first_order_drifts = Dict{Int, Float64}()   # story → max drift (m)
    for (s, cols) in columns_by_story
        Δ = _compute_story_drift(struc, cols, s)
        first_order_drifts[s] = ustrip(u"m", Δ)
    end

    # Track P-Δ loads we add so they can be identified later
    pdelta_load_ids = Symbol[]
    n_original_loads = length(model.loads)

    prev_drifts = copy(first_order_drifts)
    converged = false
    n_iter = 0
    max_drift_ratio = 1.0
    attention = Int[]

    for iter in 1:max_iter
        n_iter = iter

        # ── Compute and apply P-Δ equivalent lateral forces ──
        # Remove any P-Δ loads from the previous iteration
        if length(model.loads) > n_original_loads
            resize!(model.loads, n_original_loads)
        end

        for (s, cols) in columns_by_story
            # Story-level ΣPu (from current solved state)
            ΣPu_N = 0.0
            for col in cols
                for seg_idx in segment_indices(col)
                    seg = struc.segments[seg_idx]
                    eidx = seg.edge_idx
                    (eidx < 1 || eidx > length(model.elements)) && continue
                    el = model.elements[eidx]
                    isempty(el.forces) && continue
                    # Axial: el.forces[1] (start), el.forces[7] (end); negative = compression
                    P_start = el.forces[1]
                    P_end   = length(el.forces) >= 7 ? el.forces[7] : P_start
                    ΣPu_N += max(abs(P_start), abs(P_end))
                end
            end

            # Story height
            lc_m = sum(ustrip(u"m", col.base.L) for col in cols) / length(cols)
            lc_m = max(lc_m, 0.1)  # guard

            # Current drift for this story
            Δ_m = _story_drift_m(struc, model, skel, vc, cols)

            # Equivalent lateral force: F = ΣPu × Δ / lc  (Newtons)
            F_pd = ΣPu_N * Δ_m / lc_m

            if F_pd ≈ 0
                continue
            end

            # Distribute the force to column top nodes.
            # Apply in the governing drift direction (x or y).
            dir = _governing_drift_direction(struc, model, skel, vc, cols)
            F_per_col = F_pd / length(cols)

            for col in cols
                top_node = _column_top_node(struc, model, skel, vc, col)
                isnothing(top_node) && continue

                force_vec = dir == :x ?
                    [F_per_col, 0.0, 0.0] .* u"N" :
                    [0.0, F_per_col, 0.0] .* u"N"

                push!(model.loads, Asap.NodeForce(top_node, force_vec, :p_delta))
            end
        end

        # ── Re-solve ──
        Asap.update!(model)
        Asap.solve!(model)

        # ── Check convergence ──
        curr_drifts = Dict{Int, Float64}()
        max_change = 0.0
        max_drift_ratio = 1.0

        for (s, cols) in columns_by_story
            Δ_new = _story_drift_m(struc, model, skel, vc, cols)
            curr_drifts[s] = Δ_new

            Δ_prev = get(prev_drifts, s, Δ_new)
            if Δ_prev > 0
                change = abs(Δ_new - Δ_prev) / Δ_prev
                max_change = max(max_change, change)
            end

            Δ_first = get(first_order_drifts, s, Δ_new)
            if Δ_first > 0
                ratio = Δ_new / Δ_first
                max_drift_ratio = max(max_drift_ratio, ratio)
            end
        end

        if verbose
            @info "P-Δ iteration $iter" max_change=round(max_change, digits=4) max_drift_ratio=round(max_drift_ratio, digits=3)
        end

        # ACI 318-19 §6.6.4.6.2: total moment ≤ 1.4 × first-order
        # Using drift as a proxy (moments scale with drift in elastic analysis)
        if max_drift_ratio > 1.4
            attention = [s for (s, _) in columns_by_story
                         if get(curr_drifts, s, 0.0) / max(get(first_order_drifts, s, 1e-10), 1e-10) > 1.4]
            if verbose
                @warn "P-Δ drift ratio $(round(max_drift_ratio, digits=2)) > 1.4 (ACI §6.6.4.6.2 limit)" stories=attention
            end
        end

        prev_drifts = curr_drifts

        if max_change < tol
            converged = true
            break
        end
    end

    # Update story properties with converged values
    compute_story_properties!(struc; concrete=concrete, verbose=false)

    if verbose
        status = converged ? "converged" : "did NOT converge"
        @info "P-Δ analysis $status in $n_iter iterations" max_drift_ratio=round(max_drift_ratio, digits=3)
    end

    return (converged=converged, iterations=n_iter,
            max_drift_ratio=max_drift_ratio,
            stories_needing_attention=attention)
end

# ── P-Δ helper: compute story drift in metres (raw Float64) ──
function _story_drift_m(struc, model, skel, vc, cols)
    max_d = 0.0
    for col in cols
        for seg_idx in segment_indices(col)
            seg = struc.segments[seg_idx]
            eidx = seg.edge_idx
            (eidx < 1 || eidx > length(model.elements)) && continue

            v1, v2 = skel.edge_indices[eidx]
            z1, z2 = vc[v1, 3], vc[v2, 3]
            top_idx    = z1 > z2 ? v1 : v2
            bottom_idx = z1 > z2 ? v2 : v1

            top_n    = model.nodes[top_idx]
            bottom_n = model.nodes[bottom_idx]

            dx = abs(ustrip(u"m", top_n.displacement[1]) - ustrip(u"m", bottom_n.displacement[1]))
            dy = abs(ustrip(u"m", top_n.displacement[2]) - ustrip(u"m", bottom_n.displacement[2]))
            max_d = max(max_d, dx, dy)
        end
    end
    return max_d
end

# ── P-Δ helper: determine governing drift direction ──
function _governing_drift_direction(struc, model, skel, vc, cols)
    sum_dx = 0.0
    sum_dy = 0.0
    for col in cols
        for seg_idx in segment_indices(col)
            seg = struc.segments[seg_idx]
            eidx = seg.edge_idx
            (eidx < 1 || eidx > length(model.elements)) && continue

            v1, v2 = skel.edge_indices[eidx]
            z1, z2 = vc[v1, 3], vc[v2, 3]
            top_idx    = z1 > z2 ? v1 : v2
            bottom_idx = z1 > z2 ? v2 : v1

            top_n    = model.nodes[top_idx]
            bottom_n = model.nodes[bottom_idx]

            sum_dx += abs(ustrip(u"m", top_n.displacement[1]) - ustrip(u"m", bottom_n.displacement[1]))
            sum_dy += abs(ustrip(u"m", top_n.displacement[2]) - ustrip(u"m", bottom_n.displacement[2]))
        end
    end
    return sum_dx >= sum_dy ? :x : :y
end

# ── P-Δ helper: get column top node from ASAP model ──
function _column_top_node(struc, model, skel, vc, col)
    for seg_idx in segment_indices(col)
        seg = struc.segments[seg_idx]
        eidx = seg.edge_idx
        (eidx < 1 || eidx > length(model.elements)) && continue

        v1, v2 = skel.edge_indices[eidx]
        z1, z2 = vc[v1, 3], vc[v2, 3]
        top_idx = z1 > z2 ? v1 : v2
        return model.nodes[top_idx]
    end
    return nothing
end
