# =============================================================================
# FEA Load Cases — D/L Split Solve & Post-Solve Combination
# =============================================================================
#
# Linear elastic FEA → superposition holds.  Solve once for D, once for L,
# store per-element moments, then combine post-solve for any load combination.
#
# This replaces the legacy single-solve path (qu = max(1.2D+1.6L, 1.4D))
# and enables:
#   - Proper ASCE 7 §2.3.1 load combinations evaluated per-element
#   - FEA-native pattern loading (checkerboard, adjacent spans)
#
# Pattern loading modes:
#   - :efm_amp — EFM amplification factors (fast, approximate)
#   - :fea_resolve — Re-solve FEA for each pattern (accurate, slower)
#
# =============================================================================

"""
ASCE 7 §2.3.1 factored load combinations as `(α_D, α_L)` tuples.

`M = α_D × M_D + α_L × M_L` for each combination.
"""
const _LOAD_COMBOS = (
    (1.2, 1.6),   # 1.2D + 1.6L  (ASCE 7 §2.3.1 combo 2)
    (1.4, 0.0),   # 1.4D         (ASCE 7 §2.3.1 combo 1)
)

# =============================================================================
# Solve for a Single Load Case
# =============================================================================

"""
    _solve_load_case!(cache, q; verbose=false) -> Vector{ElementMoments}

Set the model's area load to `q`, re-solve, and extract per-element moments.
Returns a fresh `Vector{ElementMoments}` (Mxx, Myy, Mxy in N·m/m).

The model's stiffness matrix is unchanged — only the load vector is updated.
"""
function _solve_load_case!(cache::FEAModelCache, q::Pressure; verbose::Bool = false)
    model = cache.model

    # Update area load pressure
    for load in model.loads
        if load isa Asap.AreaLoad
            load.pressure = uconvert(u"Pa", q)
        end
    end

    # Re-assemble load vector and solve (stiffness unchanged)
    Asap.update!(model; values_only=true)
    Asap.solve!(model)

    # Extract per-element moments
    shell_vec = model.shell_elements
    n = length(shell_vec)
    ws = Asap.ShellMomentWorkspace()
    M_buf = zeros(3)
    moments = Vector{ElementMoments}(undef, n)

    @inbounds for k in 1:n
        tri = shell_vec[k]
        if tri isa Asap.ShellTri3
            Asap.bending_moments!(M_buf, tri, model.u, ws)
            moments[k] = ElementMoments(M_buf[1], M_buf[2], M_buf[3])
        else
            moments[k] = ElementMoments(0.0, 0.0, 0.0)
        end
    end

    if verbose
        @debug "LOAD CASE SOLVED" q=q n_elements=n
    end

    return moments
end

# =============================================================================
# D/L Split Solve
# =============================================================================

"""
    _solve_dl_cases!(cache, qD, qL; verbose=false, U_qu=nothing)

Solve the FEA model separately for dead load (`qD`) and live load (`qL`).
Stores results in `cache.element_data_D` and `cache.element_data_L`.

After extracting D/L moments, the model is restored to the governing factored
state `qu = max(1.2D+1.6L, 1.4D)` so that displacement, reaction, and
column-stub force fields are consistent with the factored state.

When `U_qu` is provided (e.g. from the initial build solve), the factored
state is restored via a cheap back-substitution instead of a full re-solve,
saving one `solve!` call on first pass.

After calling this, use `_combine_element_moments!` to write the governing
per-element factored moments into `cache.element_data`.
"""
function _solve_dl_cases!(cache::FEAModelCache, qD::Pressure, qL::Pressure;
                          verbose::Bool = false,
                          U_qu::Union{Nothing, Vector{Float64}} = nothing)
    cache.element_data_D = _solve_load_case!(cache, qD; verbose=verbose)
    # Snapshot dead-load displacement field for pattern loading superposition
    cache.U_D = copy(cache.model.u)
    cache.element_data_L = _solve_load_case!(cache, qL; verbose=verbose)

    # Restore model to factored state for consistent displacements/reactions.
    qu_restore = max(1.2 * qD + 1.6 * qL, 1.4 * qD)
    for load in cache.model.loads
        if load isa Asap.AreaLoad
            load.pressure = uconvert(u"Pa", qu_restore)
        end
    end

    if !isnothing(U_qu)
        # Fast path: restore cached factored displacement without re-solving.
        # The stiffness matrix hasn't changed, so the factored displacement
        # from the initial build is still valid.
        copy!(cache.model.u, U_qu)
        Asap.update!(cache.model; values_only=true)
        Asap.post_process!(cache.model)
    else
        # No cached displacement — full re-solve required.
        Asap.update!(cache.model; values_only=true)
        Asap.solve!(cache.model)
    end

    if verbose
        @debug "D/L SPLIT SOLVE COMPLETE" n_D=length(cache.element_data_D) n_L=length(cache.element_data_L)
    end
end

# =============================================================================
# Post-Solve Combination
# =============================================================================

"""
    _combine_element_moments!(cache; verbose=false)

Apply ASCE 7 §2.3.1 load combinations to the D/L element moments and write
the governing (envelope) factored moments into `cache.element_data.Mxx/Myy/Mxy`.

For each element, the governing combination is the one that produces the
largest absolute Mxx (the primary bending moment).  The full moment triplet
(Mxx, Myy, Mxy) from that combination is used — we do NOT mix combinations
across moment components, as they must remain consistent for tensor operations
(Wood–Armer, projection).
"""
function _combine_element_moments!(cache::FEAModelCache; verbose::Bool = false)
    n = length(cache.element_data)
    @assert length(cache.element_data_D) == n "D moments length mismatch"
    @assert length(cache.element_data_L) == n "L moments length mismatch"

    @inbounds for k in 1:n
        ed = cache.element_data[k]
        md = cache.element_data_D[k]
        ml = cache.element_data_L[k]

        # Evaluate all combos, pick the one with max |Mxx|
        best_abs = -1.0
        best_Mxx = 0.0
        best_Myy = 0.0
        best_Mxy = 0.0

        for (αD, αL) in _LOAD_COMBOS
            Mxx_c = αD * md.Mxx + αL * ml.Mxx
            a = abs(Mxx_c)
            if a > best_abs
                best_abs = a
                best_Mxx = Mxx_c
                best_Myy = αD * md.Myy + αL * ml.Myy
                best_Mxy = αD * md.Mxy + αL * ml.Mxy
            end
        end

        ed.Mxx = best_Mxx
        ed.Myy = best_Myy
        ed.Mxy = best_Mxy
    end

    if verbose
        @debug "LOAD COMBINATION APPLIED" n_elements=n n_combos=length(_LOAD_COMBOS)
    end
end

# =============================================================================
# FEA-Native Pattern Loading  (:fea_resolve)
# =============================================================================
#
# Strategy: per-cell superposition.
#
# Since the system is linear elastic, the moment response to live load on a
# subset of cells equals the sum of responses to live load on each cell
# individually.  We decompose:
#
#   M_L(pattern) = Σ  M_L_cell[ci]     for ci in loaded cells
#
# where M_L_cell[ci] is the per-element moment vector from live load applied
# ONLY to the shell elements belonging to cell `ci`.
#
# This requires n_cells solves (typically 1–9), each reusing the cached LU
# factorization, which is much cheaper than n_patterns full solves.
#
# For each pattern, the factored moment is:
#   M(pattern) = α_D × M_D + α_L × Σ(M_L_cell[ci] for loaded ci)
#
# The envelope across all patterns is written into cache.element_data.
# =============================================================================

"""
    _solve_per_cell_live!(cache, slab, qL; verbose=false)

Decompose the live load into per-cell contributions by solving the model
with live load applied only to the elements of each cell in turn.

Stores results in `cache.cell_live_moments[cell_idx]`.

Uses the cached LU factorization — only the load vector changes between
solves, so each solve is just a forward/backward substitution (O(n) with
the factored matrix).
"""
function _solve_per_cell_live!(cache::FEAModelCache, slab, qL::Pressure;
                               verbose::Bool = false)
    model = cache.model
    n = length(model.shell_elements)
    p_L = ustrip(u"Pa", qL)

    # Ensure factorization is cached (stiffness unchanged)
    fact = Asap._get_factorization(model)
    idx = model.freeDOFs

    ws = Asap.ShellMomentWorkspace()
    M_buf = zeros(3)

    empty!(cache.cell_live_moments)
    empty!(cache.cell_live_displacements)

    # Pre-allocate work vectors outside the cell loop
    P_cell = zeros(model.nDOFs)
    U      = zeros(model.nDOFs)

    for ci in slab.cell_indices
        tri_indices = get(cache.cell_tri_indices, ci, Int[])
        isempty(tri_indices) && continue

        # Build load vector with live load ONLY on this cell's elements
        fill!(P_cell, 0.0)
        for k in tri_indices
            shell = model.shell_elements[k]
            shell isa Asap.ShellTri3 || continue
            fpn = p_L * shell.area / length(shell.nodes)
            for node in shell.nodes
                gid = node.globalID
                P_cell[gid[3]] -= fpn   # -Z direction (downward)
            end
        end

        # Solve with cached factorization (fast back-substitution)
        fill!(U, 0.0)
        U[idx] = fact \ P_cell[idx]

        # Extract per-element moments from the displacement field
        moments = Vector{ElementMoments}(undef, n)
        @inbounds for k in 1:n
            tri = model.shell_elements[k]
            if tri isa Asap.ShellTri3
                Asap.bending_moments!(M_buf, tri, U, ws)
                moments[k] = ElementMoments(M_buf[1], M_buf[2], M_buf[3])
            else
                moments[k] = ElementMoments(0.0, 0.0, 0.0)
            end
        end

        cache.cell_live_moments[ci] = moments
        cache.cell_live_displacements[ci] = copy(U)

        if verbose
            n_tri = length(tri_indices)
            max_Mxx = maximum(abs(moments[k].Mxx) for k in tri_indices; init=0.0)
            @debug "  Per-cell L solve: cell $ci ($n_tri elements) max|Mxx|=$(round(max_Mxx, digits=1)) N·m/m"
        end
    end

    if verbose
        @debug "PER-CELL LIVE DECOMPOSITION" n_cells=length(cache.cell_live_moments)
    end
end

"""
    _fea_pattern_envelope!(cache, slab, qD, qL; verbose=false)

Evaluate all ACI 318-11 §13.7.6 load patterns using per-cell superposition
and write the governing per-element factored moments into `cache.element_data`.

For each pattern and each ASCE 7 §2.3.1 load combination, the per-element
moment is:

    M[k] = α_D × M_D[k] + α_L × Σ(M_L_cell[ci][k])  for loaded ci

The element-wise envelope (max |Mxx|) across all patterns × combos governs.

Requires `_solve_dl_cases!` and `_solve_per_cell_live!` to have been called.
"""
function _fea_pattern_envelope!(cache::FEAModelCache, slab;
                                verbose::Bool = false)
    n = length(cache.element_data)
    cell_indices = collect(slab.cell_indices)
    n_cells = length(cell_indices)

    @assert !isempty(cache.element_data_D) "D moments not computed"
    @assert !isempty(cache.cell_live_moments) "Per-cell L moments not computed"

    # Generate patterns using the existing pattern loading infrastructure.
    # Each slab cell maps to one "span" in the pattern generator.
    patterns = generate_load_patterns(n_cells)

    if verbose
        @debug "FEA PATTERN ENVELOPE" n_cells=n_cells n_patterns=length(patterns)
    end

    # Seed envelope with the full-load combination already in element_data.
    # Pattern loading can only increase demands — the full-load result is
    # a valid lower bound for the envelope.  Starting from zeros would lose
    # the full-load result for elements where no pattern exceeds it.
    best_abs = Vector{Float64}(undef, n)
    best_Mxx = Vector{Float64}(undef, n)
    best_Myy = Vector{Float64}(undef, n)
    best_Mxy = Vector{Float64}(undef, n)
    @inbounds for k in 1:n
        ed = cache.element_data[k]
        best_abs[k] = abs(ed.Mxx)
        best_Mxx[k] = ed.Mxx
        best_Myy[k] = ed.Myy
        best_Mxy[k] = ed.Mxy
    end

    for pat in patterns
        for (αD, αL) in _LOAD_COMBOS
            # For each element, compute M = αD × M_D + αL × Σ(M_L_cell for loaded cells)
            @inbounds for k in 1:n
                md = cache.element_data_D[k]
                Mxx_k = αD * md.Mxx
                Myy_k = αD * md.Myy
                Mxy_k = αD * md.Mxy

                # Add live load contributions from loaded cells
                for (j, load_type) in enumerate(pat)
                    load_type === :dead_plus_live || continue
                    ci = cell_indices[j]
                    cell_moms = get(cache.cell_live_moments, ci, nothing)
                    cell_moms === nothing && continue
                    ml = cell_moms[k]
                    Mxx_k += αL * ml.Mxx
                    Myy_k += αL * ml.Myy
                    Mxy_k += αL * ml.Mxy
                end

                a = abs(Mxx_k)
                if a > best_abs[k]
                    best_abs[k] = a
                    best_Mxx[k] = Mxx_k
                    best_Myy[k] = Myy_k
                    best_Mxy[k] = Mxy_k
                end
            end
        end
    end

    # Write envelope into cache.element_data
    @inbounds for k in 1:n
        ed = cache.element_data[k]
        ed.Mxx = best_Mxx[k]
        ed.Myy = best_Myy[k]
        ed.Mxy = best_Mxy[k]
    end

    if verbose
        max_Mxx = maximum(abs(best_Mxx[k]) for k in 1:n; init=0.0)
        @debug "FEA PATTERN ENVELOPE APPLIED" max_abs_Mxx=round(max_Mxx, digits=1)
    end
end

"""
    _pattern_envelope_displacement(cache, slab) -> Vector{Float64}

Assemble the governing factored displacement field across all ACI 318-11 §13.7.6
load patterns.  For each DOF, the displacement with the largest absolute z-DOF
contribution (max downward displacement at slab nodes) governs.

Uses stored `cache.U_D` (dead-load displacements) and `cache.cell_live_displacements`
(per-cell live-load displacements) from the D/L split solve.

Returns a full DOF displacement vector (Float64, SI units from Asap).
"""
function _pattern_envelope_displacement(cache::FEAModelCache, slab)
    model = cache.model
    nDOFs = model.nDOFs
    cell_indices = collect(slab.cell_indices)
    n_cells = length(cell_indices)

    @assert !isempty(cache.U_D) "Dead-load displacements not stored"
    @assert !isempty(cache.cell_live_displacements) "Per-cell live displacements not stored"

    patterns = generate_load_patterns(n_cells)

    # Slab-level z-DOF indices for max-displacement tracking
    slab_z_gids = Int[n.globalID[3] for n in model.nodes
                      if ustrip(u"m", n.position[3]) > -0.01]

    # Start with the full-load (1.2D+1.6L) displacement as baseline
    best_U = copy(cache.model.u)  # model left in factored state
    best_max_disp = minimum(best_U[gid] for gid in slab_z_gids; init=0.0)

    U_work = zeros(nDOFs)

    for pat in patterns
        for (αD, αL) in _LOAD_COMBOS
            # U(pattern) = αD × U_D + αL × Σ(U_cell[ci] for loaded ci)
            @. U_work = αD * cache.U_D
            for (j, load_type) in enumerate(pat)
                load_type === :dead_plus_live || continue
                ci = cell_indices[j]
                U_cell = get(cache.cell_live_displacements, ci, nothing)
                U_cell === nothing && continue
                @. U_work += αL * U_cell
            end

            # Check if this pattern produces larger max downward displacement
            min_z = minimum(U_work[gid] for gid in slab_z_gids; init=0.0)
            if min_z < best_max_disp
                best_max_disp = min_z
                copy!(best_U, U_work)
            end
        end
    end

    return best_U
end
