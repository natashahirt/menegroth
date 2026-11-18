# =============================================================================
# Hardy Cross Moment Distribution Method
# =============================================================================

"""
    solve_moment_distribution(spans, joint_Kec, joint_positions, qu;
                              COF=nothing, max_iterations=20, tolerance=0.01,
                              drop_loads=nothing)

Solve EFM using Hardy Cross moment distribution method.

This is the analytical method used by StructurePoint (see Table 5 in their
DE-Two-Way-Flat-Plate example). Matches StructurePoint exactly.

# EFM-Specific Implementation

Unlike standard moment distribution (where unbalanced = sum of member moments),
this implementation tracks carry-over received at each joint. This is correct 
for the EFM model because:

1. **Kec represents a column that provides a REACTION**, not just stiffness
2. When distributing: members get `DF × unbalanced`, column absorbs `(1-ΣDF) × unbalanced`
3. After distribution, joint is in equilibrium (column reaction balances members)
4. Only NEW unbalanced from carry-over needs redistribution in subsequent iterations

Standard moment distribution (redistributing full member sums) causes exterior 
moments to decay toward zero - incorrect for EFM. Validated against both
StructurePoint Table 5 (exact match) and ASAP column-stub model (within 2%).

# Algorithm
1. Compute Distribution Factors: DF = K_sb / (ΣK_sb + K_ec) at each joint
2. Compute Fixed-End Moments: FEM = m × w × l₁²
3. Initialize: member moments = FEMs, unbalanced = FEM sum at each joint
4. Iterate until converged:
   a. Distribute carry-over/FEM received: ΔM = -DF × unbalanced
   b. Carry over: far_end += COF × ΔM (track as next iteration's unbalanced)

# Arguments
- `spans`: Vector of EFMSpanProperties with Ksb (slab-beam stiffness)
- `joint_Kec`: Vector of equivalent column stiffness at each joint
- `joint_positions`: Vector of :interior/:edge/:corner symbols
- `qu`: Factored uniform load (pressure)

# Keyword Arguments  
- `COF`: Carry-over factor for every span; `nothing` uses each span's own
  (PCA Table A1, or Tables A2–A5 for a flat slab)
- `max_iterations`: Maximum iterations (default 20)
- `tolerance`: Convergence tolerance in kip-ft (default 0.01)
- `drop_loads`: per-span drop line loads `(w, a_left, a_right)` of a flat slab
  (see `_frame_drop_loads`), added to the FEM by the patch coefficients of
  Tables A2–A5 and to the midspan statics

# Returns
Vector of named tuples matching `extract_span_moments` format:
- `span_idx`, `M_neg_left`, `M_pos`, `M_neg_right`

# Reference
- StructurePoint DE-Two-Way-Flat-Plate Table 5 (exact match)
- ACI 318-11 §13.7
"""
function solve_moment_distribution(
    spans::Vector{<:EFMSpanProperties},
    joint_Kec::Vector{<:Moment},
    joint_positions::Vector{Symbol},
    qu::Union{Pressure, Vector{<:Pressure}};
    COF::Union{Nothing, Float64} = nothing,  # nothing → each span's own COF
    max_iterations::Int = 20,
    tolerance::Float64 = 0.01,
    verbose::Bool = false,
    drop_loads = nothing,
)
    n_spans = length(spans)
    n_joints = n_spans + 1
    
    # Per-span factored loads: scalar → uniform, vector → pattern loading
    qu_per_span = qu isa Pressure ? fill(qu, n_spans) : qu
    length(qu_per_span) == n_spans || error("qu_per_span length ($(length(qu_per_span))) ≠ n_spans ($n_spans)")
    
    # =========================================================================
    # Hardy Cross Moment Distribution following StructurePoint Table 5 exactly
    #
    # Member naming convention:
    #   - Member "i-(i+1)" is span i viewed from joint i (left end)
    #   - Member "(i+1)-i" is span i viewed from joint i+1 (right end)
    #
    # For 3 spans (4 joints):
    #   Joint 1: Member 1-2 (left end of span 1)
    #   Joint 2: Members 2-1 (right end of span 1) and 2-3 (left end of span 2)
    #   Joint 3: Members 3-2 (right end of span 2) and 3-4 (left end of span 3)
    #   Joint 4: Member 4-3 (right end of span 3)
    #
    # Key insight from SP Table 5:
    #   - Each iteration: DISTRIBUTE at all joints, THEN apply ALL carry-overs
    #   - At interior joints, if FEMs balance (sum=0), no initial distribution needed
    #   - Sign: positive = counterclockwise acting on member end
    # =========================================================================
    
    # Member indexing: member_idx = 2*span - 1 for left end, 2*span for right end
    # Matches SP column order: 1-2, 2-1, 2-3, 3-2, 3-4, 4-3
    n_members = 2 * n_spans
    
    # Compute Fixed-End Moments
    # For flat plate: FEM = m × w × l₁²  (single uniform load)
    # For flat slab:  FEM = m₁ × w_slab × l₂ × l₁² + m₂ × w_drop × b_drop × l₁² + m₃ × w_drop × b_drop × l₁²
    # (PCA Tables A2–A5; `drop_loads[s].w` is w_drop × b_drop.)
    FEM = Vector{Float64}(undef, n_members)
    w_kipft = Vector{Float64}(undef, n_spans)
    l1_ft_arr = Vector{Float64}(undef, n_spans)
    COF_span = Vector{Float64}(undef, n_spans)

    @inbounds for span in 1:n_spans
        sp = spans[span]
        l1_f = ustrip(u"ft", sp.l1)
        l1_ft_arr[span] = l1_f
        w_kf = ustrip(kip/u"ft", qu_per_span[span] * sp.l2)
        w_kipft[span] = w_kf
        COF_span[span] = something(COF, sp.COF)
        fem_left = fem_right = sp.m_factor * w_kf * l1_f^2
        dl = isnothing(drop_loads) ? nothing : drop_loads[span]
        if !isnothing(dl) && has_drop_panels(sp)
            wd = ustrip(kip/u"ft", dl.w)
            mL = pca_np_fem_coefficients(sp.c1_left, sp.l1, sp.c2_left, sp.l2,
                                         sp.drop.h_drop, sp.h, dl.a_left; a_far = dl.a_right)
            mR = pca_np_fem_coefficients(sp.c1_right, sp.l1, sp.c2_right, sp.l2,
                                         sp.drop.h_drop, sp.h, dl.a_right; a_far = dl.a_left)
            fem_left  += (mL.m_near + mL.m_far) * wd * l1_f^2
            fem_right += (mR.m_near + mR.m_far) * wd * l1_f^2
        end

        left_idx = 2*span - 1
        right_idx = 2*span
        FEM[left_idx] = fem_left
        FEM[right_idx] = -fem_right
    end
    
    # Compute Distribution Factors at each joint
    # DF[member_idx] = K_member / K_total_at_joint
    DF = Vector{Float64}(undef, n_members)
    fill!(DF, 0.0)
    
    # Track which members are at which joint, and reverse mapping for O(1) lookup
    joint_members = [Int[] for _ in 1:n_joints]
    member_to_joint = Vector{Int}(undef, n_members)
    fill!(member_to_joint, 0)
    
    # Pre-allocate fixed buffers (max 2 slab members per joint)
    _mi_buf = Vector{Int}(undef, 2)
    _Km_buf = Vector{Float64}(undef, 2)

    # Pre-strip Kec and Ksb once (avoids ustrip per joint)
    Kec_stripped = Vector{Float64}(undef, n_joints)
    @inbounds for j in 1:n_joints
        Kec_stripped[j] = ustrip(u"lbf*inch", joint_Kec[j])
    end
    Ksb_stripped = Vector{Float64}(undef, n_spans)
    @inbounds for s in 1:n_spans
        Ksb_stripped[s] = ustrip(u"lbf*inch", spans[s].Ksb)
    end

    for joint in 1:n_joints
        Kec_j = @inbounds Kec_stripped[joint]
        n_at = 0
        
        # Right end of span (joint-1)
        if joint > 1
            span = joint - 1
            n_at += 1
            @inbounds _mi_buf[n_at] = 2*span
            @inbounds _Km_buf[n_at] = Ksb_stripped[span]
        end
        
        # Left end of span (joint)
        if joint <= n_spans
            span = joint
            n_at += 1
            @inbounds _mi_buf[n_at] = 2*span - 1
            @inbounds _Km_buf[n_at] = Ksb_stripped[span]
        end
        
        # Total stiffness at joint includes equivalent column stiffness
        K_total = Kec_j
        @inbounds for k in 1:n_at
            K_total += _Km_buf[k]
        end
        
        # Distribution factors and mappings
        @inbounds for k in 1:n_at
            idx = _mi_buf[k]
            DF[idx] = _Km_buf[k] / K_total
            push!(joint_members[joint], idx)
            member_to_joint[idx] = joint
        end
    end
    
    if verbose
        println("\n=== Hardy Cross Setup ===")
        println("DFs: ", round.(DF, digits=3))
        println("FEMs: ", round.(FEM, digits=2))
    end
    
    # Initialize member-end moments
    M = copy(FEM)
    
    # Track carry-over received at each joint (for determining which joints to release)
    # In iteration 1, the "carry-over" is the FEM itself
    co_at_joint = Vector{Float64}(undef, n_joints)
    fill!(co_at_joint, 0.0)
    for j in 1:n_joints
        for idx in joint_members[j]
            co_at_joint[j] += FEM[idx]
        end
    end
    
    # Preallocate scratch vectors (reused every iteration)
    dist_increments = Vector{Float64}(undef, n_members)
    co_increments   = Vector{Float64}(undef, n_members)
    fill!(dist_increments, 0.0)
    fill!(co_increments, 0.0)
    
    # Hardy Cross iteration: alternating Distribute and Carry-Over rows
    for iter in 1:max_iterations
        max_change = 0.0
        
        # =====================================================================
        # DISTRIBUTE ROW
        # =====================================================================
        fill!(dist_increments, 0.0)
        
        for joint in 1:n_joints
            # Only distribute if this joint received carry-over
            if abs(co_at_joint[joint]) < 1e-10
                continue
            end
            
            members = joint_members[joint]
            
            # The unbalanced moment to distribute is the carry-over received
            M_unbalanced = co_at_joint[joint]
            
            # Distribute to each member
            for idx in members
                ΔM = -DF[idx] * M_unbalanced
                dist_increments[idx] = ΔM
                max_change = max(max_change, abs(ΔM))
            end
        end
        
        # Apply all distributions
        M .+= dist_increments
        
        if verbose && iter <= 10
            print("Dist: ")
            println(round.(dist_increments, digits=2))
        end
        
        # =====================================================================
        # CARRY-OVER ROW: Apply carry-overs from the distributions
        # =====================================================================
        # Reset carry-over tracking for next iteration
        fill!(co_at_joint, 0.0)
        fill!(co_increments, 0.0)
        
        for idx in 1:n_members
            if dist_increments[idx] != 0.0
                # Find far end for carry-over
                # Odd idx (left end) → far is idx+1; Even idx (right end) → far is idx-1
                far_idx = isodd(idx) ? idx + 1 : idx - 1
                co_val = COF_span[(idx + 1) ÷ 2] * dist_increments[idx]
                co_increments[far_idx] = co_val
                
                # Track which joint received this CO (O(1) lookup)
                co_at_joint[member_to_joint[far_idx]] += co_val
            end
        end
        
        # Apply all carry-overs
        M .+= co_increments
        
        if verbose && iter <= 10
            print("CO:   ")
            println(round.(co_increments, digits=2))
            println("M =   ", round.(M, digits=2))
        end
        
        # Check convergence
        if max_change < tolerance
            if verbose
                println("Converged at iteration $iter")
            end
            break
        end
    end
    
    if verbose
        println("\nFinal M: ", round.(M, digits=2))
    end
    
    # Extract span moments
    span_moments = NamedTuple{(:span_idx, :M_neg_left, :M_pos, :M_neg_right), Tuple{Int, Moment, Moment, Moment}}[]
    
    for span in 1:n_spans
        left_idx = 2*span - 1
        right_idx = 2*span
        
        M_left = abs(M[left_idx]) * kip*u"ft"
        M_right = abs(M[right_idx]) * kip*u"ft"

        # Midspan moment from statics: M0 − (M_left + M_right)/2, plus the drop
        dl = isnothing(drop_loads) ? nothing : drop_loads[span]
        M_mid = efm_midspan_moment(M_left, M_right, w_kipft[span] * kip/u"ft",
                                   l1_ft_arr[span] * u"ft"; drop = dl)

        push!(span_moments, (
            span_idx = span,
            M_neg_left = M_left,
            M_pos = uconvert(kip*u"ft", M_mid),
            M_neg_right = M_right
        ))
    end
    
    return span_moments
end

"""
    solve_efm_frame!(model)

Solve the EFM ASAP frame model.

Uses `process!` to set up the model (compute stiffness matrices, apply constraints)
followed by `solve!` to perform the linear static analysis.
"""
function solve_efm_frame!(model; full_process::Bool=true, loads_only::Bool=false, postprocess::Symbol=:elements)
    if full_process
        process!(model)
    elseif loads_only
        # Only load magnitudes changed — preserve factorization
        Asap.update!(model; loads_only=true)
    else
        Asap.update!(model)
    end
    solve!(model; postprocess=postprocess)
end

"""
    extract_span_moments(model, span_elements, spans; qu=nothing, drop_loads=nothing)

Extract moments at key locations from solved ASAP model.

End moments are taken from the **outer ends** of each span's first and last
sub-elements (the rigid zones, at column centerlines). The midspan moment is
computed from statics ([`efm_midspan_moment`](@ref)):
    M_pos = M0 - (M_neg_left + M_neg_right) / 2   (plus the drop, if any)

# Arguments
- `model`: Solved ASAP model
- `span_elements`: slab-beam elements in build order (3 per span for a flat
  plate: [rigid_L₁, clear₁, rigid_R₁, …]; a flat slab adds drop segments),
  or one element per span (legacy)
- `spans`: Vector of EFMSpanProperties
- `qu`: Optional factored pressure, or one per span under a load pattern
  (for midspan moment calculation from statics)
- `drop_loads`: the drop line loads the model was built with

# Returns
Vector of named tuples with:
- `M_neg_left`: Negative moment at left column centerline
- `M_pos`: Positive moment at midspan
- `M_neg_right`: Negative moment at right column centerline

# Notes
- elem.forces[6]  = Mz at node 1 (start node, in N·m for SI model)
- elem.forces[12] = Mz at node 2 (end node, in N·m for SI model)
"""
function extract_span_moments(model, span_elements, spans;
                              qu::Union{Nothing, Pressure, AbstractVector{<:Pressure}}=nothing,
                              drop_loads = nothing)
    n_spans = length(spans)
    ranges = length(span_elements) == n_spans ? [i:i for i in 1:n_spans] :
        _efm_span_ranges(spans, drop_loads)
    last(ranges[end]) == length(span_elements) || error(
        "EFM span elements ($(length(span_elements))) do not match the span layout")

    span_moments = NamedTuple{(:span_idx, :M_neg_left, :M_pos, :M_neg_right), Tuple{Int, Moment, Moment, Moment}}[]

    for i in 1:n_spans
        sp = spans[i]
        # Column centerlines: node 1 of the span's first element, node 2 of its last
        M_neg_left  = to_kipft(abs(span_elements[first(ranges[i])].forces[6]) * u"N*m") * kip*u"ft"
        M_neg_right = to_kipft(abs(span_elements[last(ranges[i])].forces[12]) * u"N*m") * kip*u"ft"

        q_span = isnothing(qu) ? 0.0psf : (qu isa AbstractVector ? qu[i] : qu)
        M_pos = efm_midspan_moment(M_neg_left, M_neg_right, q_span * sp.l2, sp.l1;
                                   drop = _span_drop(drop_loads, i))

        push!(span_moments, (
            span_idx = i,
            M_neg_left  = M_neg_left,
            M_pos       = uconvert(kip*u"ft", M_pos),
            M_neg_right = M_neg_right
        ))
    end

    return span_moments
end

"""
    distribute_moments_to_strips(span_moments, joint_positions)

Distribute frame-level moments to column and middle strips per ACI 318-11 §13.6.4/.6.

This is the transverse distribution step - identical for DDM and EFM.

# ACI 318-11 §13.6.4/.6 Distribution Factors (flat plate, αf = 0)
- Interior negative: 75% to column strip, 25% to middle strip
- Exterior negative: 100% to column strip (no edge beam)
- Positive: 60% to column strip, 40% to middle strip
"""
function distribute_moments_to_strips(span_moments, joint_positions)
    strip_moments = []
    
    for sm in span_moments
        # Left support distribution
        if joint_positions[sm.span_idx] in [:corner, :edge]
            # Exterior: 100% to column strip (ACI 318-11 §13.6.4.2, no edge beam)
            M_neg_left_cs = sm.M_neg_left
            M_neg_left_ms = 0.0kip*u"ft"
        else
            # Interior: 75% / 25% (ACI 318-11 §13.6.4.1)
            M_neg_left_cs = ACI_COL_STRIP_INT_NEG * sm.M_neg_left
            M_neg_left_ms = (1 - ACI_COL_STRIP_INT_NEG) * sm.M_neg_left
        end
        
        # Right support distribution — check if right column is exterior
        right_joint_idx = sm.span_idx + 1
        if right_joint_idx <= length(joint_positions) &&
           joint_positions[right_joint_idx] in [:corner, :edge]
            # Exterior: 100% to column strip
            M_neg_right_cs = sm.M_neg_right
            M_neg_right_ms = 0.0kip*u"ft"
        else
            # Interior: 75% / 25%
            M_neg_right_cs = ACI_COL_STRIP_INT_NEG * sm.M_neg_right
            M_neg_right_ms = (1 - ACI_COL_STRIP_INT_NEG) * sm.M_neg_right
        end
        
        # Positive distribution: 60% / 40%
        col_strip_pos = 0.60
        M_pos_cs = col_strip_pos * sm.M_pos
        M_pos_ms = (1 - col_strip_pos) * sm.M_pos
        
        push!(strip_moments, (
            span_idx = sm.span_idx,
            M_neg_left_cs = M_neg_left_cs,
            M_neg_left_ms = M_neg_left_ms,
            M_pos_cs = M_pos_cs,
            M_pos_ms = M_pos_ms,
            M_neg_right_cs = M_neg_right_cs,
            M_neg_right_ms = M_neg_right_ms
        ))
    end
    
    return strip_moments
end

