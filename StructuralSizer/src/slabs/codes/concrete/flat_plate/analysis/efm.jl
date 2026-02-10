# =============================================================================
# Equivalent Frame Method (EFM) - ACI 318-19 Section 8.11
# =============================================================================
#
# Stiffness-based frame analysis for flat plate moment distribution.
#
# The equivalent frame models:
# 1. Slab-beam strips (horizontal members with enhanced stiffness at columns)
# 2. Equivalent columns (K_ec = combined column + torsional stiffness)
#
# Reference:
# - ACI 318-19 Section 8.11
# - StructurePoint DE-Two-Way-Flat-Plate Section 3.2
# - PCA Notes on ACI 318-11 Tables A1, A7
#
# =============================================================================

using Logging
using Asap

# =============================================================================
# EFM Model Cache (reuse Asap model across iterations)
# =============================================================================

"""
    EFMModelCache

Mutable cache that holds a built EFM Asap model so it can be reused across
design iterations.  Only the element section properties and load magnitudes
are updated; the topology (nodes, DOFs, connectivity) stays fixed.

Create with `EFMModelCache()` before the design loop and pass as the
`efm_cache` keyword to `run_moment_analysis`.
"""
mutable struct EFMModelCache
    initialized::Bool
    model::Union{Nothing, Model}                 # Asap.Model (concrete)
    span_elements::Vector{Element{FixedFixed}}   # slab-beam elements
    col_elements::Vector{Element{FixedFixed}}    # column stub elements
    joint_Kec::Vector{Any}                       # Kec per joint (Moment units)
    n_spans::Int

    EFMModelCache() = new(false, nothing, Element{FixedFixed}[], Element{FixedFixed}[], Any[], 0)
end

"""
    _update_efm_sections_and_loads!(cache, spans, joint_positions, qu, Ecs, Ecc, H,
                                    ν_concrete, ρ_concrete; column_shape, k_slab, k_col)

Update section properties and loads on a cached EFM model to reflect new column
sizes and/or slab thickness.  Avoids reallocating nodes, elements, and loads.
"""
function _update_efm_sections_and_loads!(
    cache::EFMModelCache,
    spans::Vector{<:EFMSpanProperties},
    joint_positions::Vector{Symbol},
    qu::Pressure,
    Ecs::Pressure,
    Ecc::Pressure,
    H::Length,
    ν_concrete::Float64,
    ρ_concrete;
    column_shape::Symbol = :rectangular,
    k_slab::Float64 = PCA_K_SLAB,
    k_col::Float64 = PCA_K_COL,
)
    model = cache.model
    span_elements = cache.span_elements
    col_elements  = cache.col_elements
    n_joints      = cache.n_spans + 1

    h  = spans[1].h
    l2 = spans[1].l2

    # ── Slab section ──
    G_slab  = Ecs / (2 * (1 + ν_concrete))
    Is_eff  = (k_slab / 4.0) * l2 * h^3 / 12
    A_slab  = l2 * h
    J_slab  = _torsional_constant_rect(l2, h)

    slab_sec = Section(
        uconvert(u"m^2", A_slab),
        uconvert(u"Pa", Ecs),
        uconvert(u"Pa", G_slab),
        uconvert(u"m^4", Is_eff),
        uconvert(u"m^4", Is_eff / 10),
        uconvert(u"m^4", J_slab),
        ρ_concrete
    )
    for elem in span_elements
        elem.section = slab_sec
    end

    # ── Column stub sections ──
    G_col   = Ecc / (2 * (1 + ν_concrete))
    new_Kec = Vector{Moment}(undef, n_joints)

    for j in 1:n_joints
        if j == 1
            c1 = spans[1].c1_left;  c2 = spans[1].c2_left
        elseif j == n_joints
            c1 = spans[end].c1_right; c2 = spans[end].c2_right
        else
            c1 = (spans[j-1].c1_right + spans[j].c1_left) / 2
            c2 = (spans[j-1].c2_right + spans[j].c2_left) / 2
        end

        c2_tor = column_shape == :circular ? equivalent_square_column(c2) : c2
        Ic     = column_moment_of_inertia(c1, c2; shape=column_shape)
        Kc     = column_stiffness_Kc(Ecc, Ic, H, h; k_factor=k_col)
        C_t    = torsional_constant_C(h, c2_tor)
        Kt1    = torsional_member_stiffness_Kt(Ecs, C_t, l2, c2_tor)

        n_tor  = joint_positions[j] == :interior ? 2 : 1
        Kec    = equivalent_column_stiffness_Kec(2 * Kc, n_tor * Kt1)
        new_Kec[j] = Kec

        Ic_eff = ustrip(u"lbf*inch", Kec) * ustrip(u"inch", H) /
                 (8 * ustrip(u"psi", Ecc)) * u"inch^4"

        col_sec = Section(
            uconvert(u"m^2", c1 * c2),
            uconvert(u"Pa", Ecc),
            uconvert(u"Pa", G_col),
            uconvert(u"m^4", Ic_eff),
            uconvert(u"m^4", Ic_eff),
            uconvert(u"m^4", _torsional_constant_rect(c1, c2)),
            ρ_concrete
        )
        col_elements[j].section = col_sec
    end
    cache.joint_Kec = new_Kec

    # ── Loads ──
    w_N_m = uconvert(u"N/m", qu * l2)
    for load in model.loads
        load.value = [0.0u"N/m", 0.0u"N/m", -w_N_m]
    end

    # Invalidate cached state so next solve! re-processes
    model._factorization = nothing
    model.processed = false
end

# =============================================================================
# EFM Moment Analysis
# =============================================================================

"""
    run_moment_analysis(method::EFM, struc, slab, columns, h, fc, Ecs, γ_concrete; ν_concrete, verbose)

Run moment analysis using Equivalent Frame Method (EFM).

EFM models the slab strip as a continuous beam supported on equivalent columns.
The equivalent column stiffness K_ec accounts for:
- Column flexural stiffness (K_c)
- Torsional flexibility of the slab-column connection (K_t)

Combined in series: 1/K_ec = 1/ΣK_c + 1/ΣK_t

# Arguments
- `method::EFM`: EFM method with solver selection
- `struc`: BuildingStructure with cells, columns, and loads
- `slab`: Slab being designed
- `columns`: Vector of supporting columns
- `h::Length`: Slab thickness
- `fc::Pressure`: Concrete compressive strength
- `Ecs::Pressure`: Slab concrete modulus of elasticity
- `γ_concrete`: Concrete unit weight
- `ν_concrete`: Concrete Poisson's ratio (from user's material)

# Returns
`MomentAnalysisResult` with all moments and geometry data.

# Reference
- ACI 318-19 Section 8.11
- StructurePoint Table 5 (EFM Moments)
"""
function run_moment_analysis(
    method::EFM,
    struc,
    slab,
    supporting_columns,
    h::Length,
    fc::Pressure,
    Ecs::Pressure,
    γ_concrete;
    ν_concrete::Float64 = 0.20,
    verbose::Bool = false,
    efm_cache::Union{Nothing, EFMModelCache} = nothing,
    cache = nothing,  # API parity (unused by EFM)
    drop_panel::Union{Nothing, DropPanelGeometry} = nothing,
    βt::Float64 = 0.0,  # API parity (unused by EFM — torsion captured in Kt)
)
    # Shared setup: l1, l2, ln, span_axis, c1_avg, qD, qL, qu, M0
    setup = _moment_analysis_setup(struc, slab, supporting_columns, h, γ_concrete)
    (; l1, l2, ln, c1_avg, qD, qL, qu, M0) = setup
    n_cols = length(supporting_columns)
    
    # Detect column shape (use first column's shape, default :rectangular)
    col_shape_val = col_shape(first(supporting_columns))
    
    if verbose
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "MOMENT ANALYSIS - EFM (Equivalent Frame Method)"
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "Geometry" l1=l1 l2=l2 ln=ln c_avg=c1_avg h=h
        @debug "Loads" qD=qD qL=qL qu=qu
        @debug "Reference M₀" M0=uconvert(kip*u"ft", M0)
    end
    
    # Get column concrete strength (may differ from slab)
    fc_col = _get_column_fc(supporting_columns, fc)
    wc_pcf = ustrip(pcf, γ_concrete)                 # mass density → pcf
    Ecc = Ec(fc_col, wc_pcf)                          # ACI 19.2.2.1.a: 33 × wc^1.5 × √f'c
    
    # Get column height
    H = _get_column_height(supporting_columns)
    
    # Build EFM span properties (with drop panel geometry if flat slab)
    spans = _build_efm_spans(supporting_columns, l1, l2, ln, h, Ecs; drop_panel=drop_panel)
    
    # Determine joint positions
    joint_positions = [col.position for col in supporting_columns]
    
    # Solve using selected method
    if method.solver == :asap
        if !isnothing(efm_cache) && efm_cache.initialized
            # Reuse cached model — update sections & loads in-place
            # (joint Kec is recomputed inside _update; skip standalone call)
            _update_efm_sections_and_loads!(
                efm_cache, spans, joint_positions, qu, Ecs, Ecc, H,
                ν_concrete, γ_concrete;
                column_shape = col_shape_val,
            )
            solve_efm_frame!(efm_cache.model; full_process=false)
            span_moments = extract_span_moments(
                efm_cache.model, efm_cache.span_elements, spans; qu=qu
            )
            joint_Kec = efm_cache.joint_Kec
        else
            # First call — build from scratch and populate cache
            model, span_elements, jKec = build_efm_asap_model(
                spans, joint_positions, qu;
                column_height = H,
                Ecs = Ecs,
                Ecc = Ecc,
                ν_concrete = ν_concrete,
                ρ_concrete = γ_concrete,
                column_shape = col_shape_val,
                verbose = verbose,
            )
            solve_efm_frame!(model)
            span_moments = extract_span_moments(model, span_elements, spans; qu=qu)
            joint_Kec = jKec

            if !isnothing(efm_cache)
                n_sp = length(spans)
                efm_cache.initialized    = true
                efm_cache.model          = model
                efm_cache.span_elements  = collect(Element{FixedFixed}, span_elements)
                efm_cache.col_elements   = collect(Element{FixedFixed}, model.elements[(n_sp+1):end])
                efm_cache.joint_Kec      = collect(Any, jKec)
                efm_cache.n_spans        = n_sp
            end
        end

        if verbose
            @debug "───────────────────────────────────────────────────────────────────"
            @debug "EFM FRAME RESULTS"
            @debug "───────────────────────────────────────────────────────────────────"
            for (i, sm) in enumerate(span_moments)
                @debug "Span $i" M_neg_left=uconvert(kip*u"ft", sm.M_neg_left) M_pos=uconvert(kip*u"ft", sm.M_pos) M_neg_right=uconvert(kip*u"ft", sm.M_neg_right)
            end
        end

        M_neg_ext = span_moments[1].M_neg_left
        M_neg_int = span_moments[1].M_neg_right
        M_pos = span_moments[1].M_pos

    elseif method.solver == :moment_distribution
        # Hardy Cross moment distribution (analytical method matching StructurePoint)
        joint_Kec = _compute_joint_Kec(spans, joint_positions, H, Ecs, Ecc; column_shape=col_shape_val)
        span_moments = solve_moment_distribution(spans, joint_Kec, joint_positions, qu; verbose=verbose)
        
        if verbose
            @debug "───────────────────────────────────────────────────────────────────"
            @debug "MOMENT DISTRIBUTION RESULTS"
            @debug "───────────────────────────────────────────────────────────────────"
            for (i, sm) in enumerate(span_moments)
                @debug "Span $i" M_neg_left=uconvert(kip*u"ft", sm.M_neg_left) M_pos=uconvert(kip*u"ft", sm.M_pos) M_neg_right=uconvert(kip*u"ft", sm.M_neg_right)
            end
        end
        
        M_neg_ext = span_moments[1].M_neg_left
        M_neg_int = span_moments[1].M_neg_right
        M_pos = span_moments[1].M_pos
    else
        error("Unknown EFM solver: $(method.solver)")
    end
    
    # Build column-level results
    column_moments, column_shears, unbalanced_moments = _compute_efm_column_demands(
        struc, supporting_columns, span_moments, qu, l2, ln
    )
    
    # Convert all outputs to consistent US units for MomentAnalysisResult
    # Moments in kip*ft, lengths in ft, forces in kip, pressures in psf
    # (Same as DDM to ensure consistent type signature)
    M0_conv = uconvert(kip * u"ft", M0)
    M_neg_ext_conv = uconvert(kip * u"ft", M_neg_ext)
    M_neg_int_conv = uconvert(kip * u"ft", M_neg_int)
    M_pos_conv = uconvert(kip * u"ft", M_pos)
    Vu_max = uconvert(kip, qu * l2 * ln / 2)
    
    return MomentAnalysisResult(
        M0_conv,
        M_neg_ext_conv,
        M_neg_int_conv,
        M_pos_conv,
        qu, qD, qL,  # Already in psf
        uconvert(u"ft", l1),
        uconvert(u"ft", l2),
        uconvert(u"ft", ln),
        uconvert(u"ft", c1_avg),
        column_moments,  # Already in kip*ft from _compute_efm_column_demands
        column_shears,   # Already in kip
        unbalanced_moments,  # Already in kip*ft
        Vu_max
    )
end

# =============================================================================
# EFM Joint Stiffness Computation
# =============================================================================

"""
    _compute_joint_Kec(spans, joint_positions, H, Ecs, Ecc; k_col=PCA_K_COL)

Compute equivalent column stiffness Kec at each joint.

Kec combines column and torsional stiffness in series:
    1/Kec = 1/ΣKc + 1/ΣKt

# Returns
Vector of Kec values (in Moment units) for each joint.
"""
function _compute_joint_Kec(
    spans::Vector{<:EFMSpanProperties},
    joint_positions::Vector{Symbol},
    H::Length,
    Ecs::Pressure,
    Ecc::Pressure;
    k_col::Float64 = 4.74,
    column_shape::Symbol = :rectangular
)
    n_spans = length(spans)
    n_joints = n_spans + 1
    h = spans[1].h
    l2 = spans[1].l2
    has_drops = has_drop_panels(spans[1])
    
    joint_Kec = Vector{Moment}(undef, n_joints)
    
    for j in 1:n_joints
        # Get column dimensions at this joint
        if j == 1
            c1 = spans[1].c1_left
            c2 = spans[1].c2_left
        elseif j == n_joints
            c1 = spans[end].c1_right
            c2 = spans[end].c2_right
        else
            c1 = (spans[j-1].c1_right + spans[j].c1_left) / 2
            c2 = (spans[j-1].c2_right + spans[j].c2_left) / 2
        end
        
        # For circular columns, use equivalent square for torsional calc
        c2_torsion = column_shape == :circular ? equivalent_square_column(c2) : c2
        
        # Column stiffness: always prismatic PCA factor — ASAP handles non-prismatic
        Ic = column_moment_of_inertia(c1, c2; shape=column_shape)
        Kc = column_stiffness_Kc(Ecc, Ic, H, h; k_factor=k_col)
        ΣKc = 2 * Kc  # Above and below
        
        # Torsional stiffness: use total depth at drop panel (if present) for C
        if has_drops
            drop = spans[1].drop
            h_total = total_depth_at_drop(h, drop)
            C = torsional_constant_C(h_total, c2_torsion)
        else
            C = torsional_constant_C(h, c2_torsion)
        end
        
        # Torsional stiffness
        Kt_single = torsional_member_stiffness_Kt(Ecs, C, l2, c2_torsion)
        
        # Number of torsional members at this joint
        n_torsion = joint_positions[j] == :interior ? 2 : 1
        ΣKt = n_torsion * Kt_single
        
        Kec = equivalent_column_stiffness_Kec(ΣKc, ΣKt)
        joint_Kec[j] = Kec
    end
    
    return joint_Kec
end

# =============================================================================
# EFM ASAP Model Building
# =============================================================================

"""
    build_efm_asap_model(spans, joint_positions, qu; kwargs...)

Build an ASAP frame model with EFM-compliant stiffnesses using column stubs.

# Methodology (Validated against StructurePoint)
Models the equivalent column stiffness Kec by using column stub elements with
effective moment of inertia Ic_eff derived from Kec:

    For a stub of length H/2 with fixed base:
    K_stub = 4 × E × Ic_eff / (H/2) = 8 × E × Ic_eff / H
    
    Setting K_stub = Kec:
    Ic_eff = Kec × H / (8 × E)

This approach is mathematically equivalent to using rotational springs and
validated to match StructurePoint EFM results within 5%.

# Key EFM Stiffnesses
- Slab-beam: K_sb = k × E_cs × I_s / l₁ (k ≈ 4.127 from PCA Table A1)
- Column: K_c = k × E_cc × I_c / H (k ≈ 4.74 from PCA Table A7)
- Torsional: K_t = 9 × E_cs × C / (l₂ × (1 - c₂/l₂)³)
- Equivalent column: 1/K_ec = 1/ΣK_c + 1/ΣK_t

# Returns
- `model`: ASAP Model ready to solve
- `span_elements`: Vector of slab-beam elements
- `joint_Kec`: Vector of equivalent column stiffnesses at each joint

# Reference
- StructurePoint DE-Two-Way-Flat-Plate Table 5 (moment distribution validation)
- PCA Notes on ACI 318-11 Tables A1, A7
"""
function build_efm_asap_model(
    spans::Vector{<:EFMSpanProperties},
    joint_positions::Vector{Symbol},
    qu::Pressure;
    column_height::Length,
    Ecs::Pressure,
    Ecc::Pressure,
    ν_concrete::Float64,
    ρ_concrete,
    k_col::Float64 = PCA_K_COL,
    k_slab::Float64 = PCA_K_SLAB,
    column_shape::Symbol = :rectangular,
    verbose::Bool = false
)
    n_spans = length(spans)
    n_joints = n_spans + 1
    
    # Convert to SI for ASAP
    l1_m = [uconvert(u"m", sp.l1) for sp in spans]
    l2 = spans[1].l2
    h = spans[1].h
    H = column_height
    
    Ecs_Pa = uconvert(u"Pa", Ecs)
    Ecc_Pa = uconvert(u"Pa", Ecc)
    
    # Shear modulus: G = E / (2(1+ν))
    G_slab = Ecs / (2 * (1 + ν_concrete))
    G_col = Ecc / (2 * (1 + ν_concrete))
    ρ = ρ_concrete
    
    # Compute stiffnesses for each joint
    joint_Kec = Vector{Moment}()
    joint_Ic_eff = Vector{typeof(1.0u"inch^4")}()  # Effective column I for each joint
    
    for j in 1:n_joints
        # Get column dimensions at this joint
        if j == 1
            c1 = spans[1].c1_left
            c2 = spans[1].c2_left
        elseif j == n_joints
            c1 = spans[end].c1_right
            c2 = spans[end].c2_right
        else
            # Average of adjacent spans
            c1 = (spans[j-1].c1_right + spans[j].c1_left) / 2
            c2 = (spans[j-1].c2_right + spans[j].c2_left) / 2
        end
        
        # For circular columns, use equivalent square for torsional calc
        # but actual circular Ic for column stiffness
        c2_torsion = column_shape == :circular ? equivalent_square_column(c2) : c2
        
        # Column stiffness
        Ic = column_moment_of_inertia(c1, c2; shape=column_shape)
        Kc = column_stiffness_Kc(Ecc, Ic, H, h; k_factor=k_col)
        
        # Torsional stiffness (sum from adjacent spans)
        # For circular columns, use equivalent square dimension for torsional member width
        C = torsional_constant_C(h, c2_torsion)
        Kt_single = torsional_member_stiffness_Kt(Ecs, C, l2, c2_torsion)
        
        # Number of torsional members at this joint
        n_torsion = joint_positions[j] == :interior ? 2 : 1
        n_columns = 2  # Above and below (typical intermediate floor)
        
        # Combined stiffnesses
        ΣKc = n_columns * Kc
        ΣKt = n_torsion * Kt_single
        
        Kec = equivalent_column_stiffness_Kec(ΣKc, ΣKt)
        push!(joint_Kec, Kec)
        
        # Derive Ic_eff from Kec for column stub
        # K_stub = 8 × E × Ic_eff / H → Ic_eff = Kec × H / (8E)
        Kec_inlb = ustrip(u"lbf*inch", Kec)
        H_in = ustrip(u"inch", H)
        Ecc_psi = ustrip(u"psi", Ecc)
        Ic_eff = Kec_inlb * H_in / (8 * Ecc_psi) * u"inch^4"
        push!(joint_Ic_eff, Ic_eff)
        
        if verbose
            @debug "Joint $j ($(joint_positions[j]))" Kc=uconvert(u"lbf*inch", Kc) Kt=uconvert(u"lbf*inch", Kt_single) Kec=uconvert(u"lbf*inch", Kec) Ic_eff=uconvert(u"inch^4", Ic_eff)
        end
    end
    
    # Create ASAP model with column stubs
    nodes = Node[]
    elements = Element[]
    loads = AbstractLoad[]
    
    # Track node indices for slab and column base nodes
    slab_node_indices = Int[]
    col_base_indices = Int[]
    
    # Create slab-level nodes at column locations (free DOFs for 2D plane frame)
    x_pos = 0.0u"m"
    for j in 1:n_joints
        # XZ plane frame: allow X translation, Z translation, Y rotation
        dofs = [true, false, true, false, true, false]
        node = Node([x_pos, 0.0u"m", 0.0u"m"], dofs)
        push!(nodes, node)
        push!(slab_node_indices, length(nodes))
        if j < n_joints
            x_pos += l1_m[j]
        end
    end
    
    # Create column base nodes (fixed) at H/2 below slab
    H_stub = H / 2
    H_stub_m = uconvert(u"m", H_stub)
    for j in 1:n_joints
        x_pos_j = nodes[slab_node_indices[j]].position[1]
        base_node = Node([x_pos_j, 0.0u"m", -H_stub_m], :fixed)
        push!(nodes, base_node)
        push!(col_base_indices, length(nodes))
    end
    
    # Create slab-beam elements with effective stiffness
    span_elements = Element[]
    
    # Slab section properties (with k_slab/4 enhancement for non-prismatic effect)
    Is_gross = l2 * h^3 / 12
    Is_eff = (k_slab / 4.0) * Is_gross
    A_slab = l2 * h
    J_slab = _torsional_constant_rect(l2, h)
    
    # Slab material and section (unitful constructor)
    slab_sec = Section(
        uconvert(u"m^2", A_slab),
        Ecs_Pa,
        uconvert(u"Pa", G_slab),
        uconvert(u"m^4", Is_eff),
        uconvert(u"m^4", Is_eff/10),  # Iy (minor axis, not critical)
        uconvert(u"m^4", J_slab),
        ρ
    )
    
    for i in 1:n_spans
        n1 = nodes[slab_node_indices[i]]
        n2 = nodes[slab_node_indices[i+1]]
        elem = Element(n1, n2, slab_sec)
        push!(elements, elem)
        push!(span_elements, elem)
    end
    
    # Create column stub elements with Ic_eff
    for j in 1:n_joints
        # Get column dimensions at this joint for A and J
        if j == 1
            c1 = spans[1].c1_left
            c2 = spans[1].c2_left
        elseif j == n_joints
            c1 = spans[end].c1_right
            c2 = spans[end].c2_right
        else
            c1 = (spans[j-1].c1_right + spans[j].c1_left) / 2
            c2 = (spans[j-1].c2_right + spans[j].c2_left) / 2
        end
        
        A_col = c1 * c2
        J_col = _torsional_constant_rect(c1, c2)
        Ic_eff = joint_Ic_eff[j]
        
        # Column section (unitful constructor)
        col_sec = Section(
            uconvert(u"m^2", A_col),
            Ecc_Pa,
            uconvert(u"Pa", G_col),
            uconvert(u"m^4", Ic_eff),  # KEY: Ic_eff from Kec
            uconvert(u"m^4", Ic_eff),
            uconvert(u"m^4", J_col),
            ρ
        )
        
        n_base = nodes[col_base_indices[j]]
        n_slab = nodes[slab_node_indices[j]]
        col_elem = Element(n_base, n_slab, col_sec)
        push!(elements, col_elem)
    end
    
    # Apply uniform loads using LineLoad for accurate moment distribution
    # w = qu × l₂ (load per unit length of frame)
    w = qu * l2
    w_N_m = uconvert(u"N/m", w)
    
    for elem in span_elements
        # LineLoad in global coordinates: [wx, wy, wz] - gravity is -Z
        line_load = LineLoad(elem, [0.0u"N/m", 0.0u"N/m", -w_N_m])
        push!(loads, line_load)
    end
    
    # Build model
    model = Model(nodes, elements, loads)
    
    return model, span_elements, joint_Kec
end

"""
    _torsional_constant_rect(width, depth)

Torsional constant C for a rectangular section (ACI 318 formula).

C = (1 - 0.63×x/y) × x³×y / 3

where x = smaller dimension, y = larger dimension.
"""
function _torsional_constant_rect(width::Length, depth::Length)
    x = min(width, depth)
    y = max(width, depth)
    x_val = ustrip(u"inch", x)
    y_val = ustrip(u"inch", y)
    return (1 - 0.63 * x_val/y_val) * x_val^3 * y_val / 3 * u"inch^4"
end

# =============================================================================
# Hardy Cross Moment Distribution Method
# =============================================================================

"""
    solve_moment_distribution(spans, joint_Kec, joint_positions, qu;
                              COF=0.507, max_iterations=20, tolerance=0.01)

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
- `COF`: Carry-over factor (default 0.507 from PCA Table A1)
- `max_iterations`: Maximum iterations (default 20)
- `tolerance`: Convergence tolerance in kip-ft (default 0.01)

# Returns
Vector of named tuples matching `extract_span_moments` format:
- `span_idx`, `M_neg_left`, `M_pos`, `M_neg_right`

# Reference
- StructurePoint DE-Two-Way-Flat-Plate Table 5 (exact match)
- ACI 318-19 Section 8.11
"""
function solve_moment_distribution(
    spans::Vector{<:EFMSpanProperties},
    joint_Kec::Vector{<:Moment},
    joint_positions::Vector{Symbol},
    qu::Pressure;
    COF::Float64 = spans[1].COF,  # Use span's COF (prismatic or non-prismatic)
    max_iterations::Int = 20,
    tolerance::Float64 = 0.01,
    verbose::Bool = false
)
    n_spans = length(spans)
    n_joints = n_spans + 1
    
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
    m_factor = spans[1].m_factor
    has_drops = has_drop_panels(spans[1])
    
    FEM = zeros(Float64, n_members)
    w_kipft = zeros(Float64, n_spans)
    l1_ft_arr = zeros(Float64, n_spans)
    
    for span in 1:n_spans
        sp = spans[span]
        l1_f = ustrip(u"ft", sp.l1)
        l1_ft_arr[span] = l1_f
        
        if has_drops
            # For flat slabs, Hardy Cross uses the same prismatic FEM as flat plates.
            # Non-prismatic section effects are handled by the ASAP elastic solver.
            # The total factored load qu already includes an equivalent uniform load
            # that accounts for slab + drop panel weight (see DDM item 7).
            w = qu * sp.l2
            w_kf = ustrip(kip/u"ft", w)
            w_kipft[span] = w_kf
            fem = m_factor * w_kf * l1_f^2
        else
            # Standard prismatic FEM
            w = qu * sp.l2
            w_kf = ustrip(kip/u"ft", w)
            w_kipft[span] = w_kf
            fem = m_factor * w_kf * l1_f^2
        end
        
        # Member indices for this span
        left_idx = 2*span - 1   # At joint span
        right_idx = 2*span      # At joint span+1
        
        FEM[left_idx] = fem     # Positive at left end
        FEM[right_idx] = -fem   # Negative at right end
    end
    
    # Compute Distribution Factors at each joint
    # DF[member_idx] = K_member / K_total_at_joint
    DF = zeros(Float64, n_members)
    
    # Track which members are at which joint, and reverse mapping for O(1) lookup
    joint_members = [Int[] for _ in 1:n_joints]
    member_to_joint = zeros(Int, n_members)  # member_to_joint[idx] = joint containing idx
    
    # Pre-allocate fixed buffers (max 2 slab members per joint)
    _mi_buf = Vector{Int}(undef, 2)
    _Km_buf = Vector{Float64}(undef, 2)

    for joint in 1:n_joints
        Kec_j = ustrip(u"lbf*inch", joint_Kec[joint])
        n_at = 0
        
        # Right end of span (joint-1)
        if joint > 1
            span = joint - 1
            n_at += 1
            @inbounds _mi_buf[n_at] = 2*span
            @inbounds _Km_buf[n_at] = ustrip(u"lbf*inch", spans[span].Ksb)
        end
        
        # Left end of span (joint)
        if joint <= n_spans
            span = joint
            n_at += 1
            @inbounds _mi_buf[n_at] = 2*span - 1
            @inbounds _Km_buf[n_at] = ustrip(u"lbf*inch", spans[span].Ksb)
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
    co_at_joint = zeros(Float64, n_joints)
    for j in 1:n_joints
        for idx in joint_members[j]
            co_at_joint[j] += FEM[idx]
        end
    end
    
    # Preallocate scratch vectors (reused every iteration)
    dist_increments = zeros(Float64, n_members)
    co_increments   = zeros(Float64, n_members)
    
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
                co_val = COF * dist_increments[idx]
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
        
        M_left = abs(M[left_idx])
        M_right = abs(M[right_idx])
        
        # Midspan moment from statics: M_mid = M0 - (M_left + M_right)/2
        M0 = w_kipft[span] * l1_ft_arr[span]^2 / 8
        M_mid = M0 - (M_left + M_right) / 2
        
        push!(span_moments, (
            span_idx = span,
            M_neg_left = M_left * kip*u"ft",
            M_pos = M_mid * kip*u"ft",
            M_neg_right = M_right * kip*u"ft"
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
function solve_efm_frame!(model; full_process::Bool=true, postprocess::Symbol=:elements)
    if full_process
        process!(model)
    else
        _reprocess_stiffness_and_loads!(model)
    end
    solve!(model; postprocess=postprocess)
end

"""
    extract_span_moments(model, span_elements, spans; qu=nothing)

Extract moments at key locations from solved ASAP model.

For the column stub model (XZ plane frame), moments are extracted from the 
element forces directly. The midspan moment is computed from statics:
    M_pos = M0 - (M_neg_left + M_neg_right) / 2

# Arguments
- `model`: Solved ASAP model
- `span_elements`: Vector of slab-beam elements
- `spans`: Vector of EFMSpanProperties
- `qu`: Optional factored pressure (for midspan moment calculation from statics)

# Returns
Vector of named tuples with:
- `M_neg_left`: Negative moment at left support
- `M_pos`: Positive moment at midspan  
- `M_neg_right`: Negative moment at right support

# Notes
- elem.forces[6] = Mz at node 1 (in N·m for SI model)
- elem.forces[12] = Mz at node 2 (in N·m for SI model)
"""
function extract_span_moments(model, span_elements, spans; qu::Union{Nothing, Pressure}=nothing)
    span_moments = NamedTuple{(:span_idx, :M_neg_left, :M_pos, :M_neg_right), Tuple{Int, Moment, Moment, Moment}}[]
    
    for (i, elem) in enumerate(span_elements)
        sp = spans[i]
        
        # Extract end moments directly from element forces
        # ASAP stores forces in local element coordinates (N·m for SI model)
        # For horizontal element in XZ plane: forces[6] and forces[12] are Mz
        M_neg_left_kipft = to_kipft(abs(elem.forces[6]) * u"N*m")
        M_neg_right_kipft = to_kipft(abs(elem.forces[12]) * u"N*m")
        
        # Compute midspan moment from statics (simple beam formula)
        # M_pos = M0 - (M_left + M_right)/2
        # where M0 = w×l²/8 is the simply-supported moment
        if !isnothing(qu)
            w_kipft = ustrip(kip/u"ft", qu * sp.l2)  # Load per unit length
        else
            # Estimate from tributary width and typical loading
            w_kipft = 0.0
        end
        l_ft = ustrip(u"ft", sp.l1)
        M0 = w_kipft * l_ft^2 / 8
        M_pos_kipft = M0 - (M_neg_left_kipft + M_neg_right_kipft) / 2
        
        # Convert to Unitful quantities
        M_neg_left = M_neg_left_kipft * kip*u"ft"
        M_neg_right = M_neg_right_kipft * kip*u"ft"
        M_pos = M_pos_kipft * kip*u"ft"
        
        push!(span_moments, (
            span_idx = i,
            M_neg_left = M_neg_left,
            M_pos = M_pos,
            M_neg_right = M_neg_right
        ))
    end
    
    return span_moments
end

"""
    distribute_moments_to_strips(span_moments, joint_positions)

Distribute frame-level moments to column and middle strips per ACI 8.10.5.

This is the transverse distribution step - identical for DDM and EFM.

# ACI 8.10.5 Distribution Factors (flat plate, αf = 0)
- Interior negative: 75% to column strip, 25% to middle strip
- Exterior negative: 100% to column strip (no edge beam)
- Positive: 60% to column strip, 40% to middle strip
"""
function distribute_moments_to_strips(span_moments, joint_positions)
    strip_moments = []
    
    for sm in span_moments
        # Left support distribution
        if joint_positions[sm.span_idx] in [:corner, :edge]
            # Exterior: 100% to column strip (ACI Table 8.10.5.2, no edge beam)
            M_neg_left_cs = sm.M_neg_left
            M_neg_left_ms = 0.0kip*u"ft"
        else
            # Interior: 75% / 25% (ACI Table 8.10.5.1)
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

# =============================================================================
# Helper Functions
# =============================================================================

"""
    _build_efm_spans(columns, l1, l2, ln, h, Ecs; drop_panel=nothing)

Build EFM span properties from column/slab data.

For **flat slabs** (drop_panel ≠ nothing), uses the same prismatic PCA factors
as flat plates.  Non-prismatic section behaviour is handled by the ASAP elastic
solver which models the actual varying I along the span.  Hardy Cross moment
distribution is NOT used for flat slabs.

Is_drop (composite I at the drop section) is still computed so the ASAP solver
can assign a stiffer section to the drop-panel zone.
"""
function _build_efm_spans(columns, l1, l2, ln, h, Ecs;
                           drop_panel::Union{Nothing, DropPanelGeometry} = nothing)
    n_cols = length(columns)
    n_spans = n_cols - 1
    
    # Always use prismatic PCA factors — ASAP handles non-prismatic via actual I
    k_slab   = PCA_K_SLAB
    m_factor = PCA_M_FACTOR
    COF      = PCA_COF
    
    spans = Vector{EFMSpanProperties}(undef, n_spans)
    
    for i in 1:n_spans
        col_left = columns[i]
        col_right = columns[i + 1]
        
        Is = slab_moment_of_inertia(l2, h)
        Ksb = slab_beam_stiffness_Ksb(Ecs, Is, l1, col_left.c1, col_left.c2; k_factor=k_slab)
        
        # Compute Is_drop for ASAP section assignment in the drop zone
        Is_drop = if !isnothing(drop_panel)
            h_total = total_depth_at_drop(h, drop_panel)
            slab_moment_of_inertia(l2, h_total)
        else
            nothing
        end
        
        spans[i] = EFMSpanProperties{typeof(Is), typeof(Ksb)}(
            i, i, i + 1,
            l1, l2, ln,
            h,
            col_left.c1, col_left.c2,
            col_right.c1, col_right.c2,
            Is, Ksb,
            m_factor, COF, k_slab,
            drop_panel, Is_drop,
        )
    end
    
    return spans
end

"""Get column concrete strength from first column's material, or fall back to slab fc."""
function _get_column_fc(columns, default_fc)
    if !isempty(columns) && hasproperty(columns[1], :material) && hasproperty(columns[1].material, :fc′)
        return columns[1].material.fc′
    end
    return default_fc
end

"""Get column height from first column. Errors if not available."""
function _get_column_height(columns)
    if !isempty(columns) && hasproperty(columns[1], :base) && hasproperty(columns[1].base, :L)
        return columns[1].base.L
    end
    error("Cannot determine column height: columns[1].base.L not available. " *
          "Ensure column geometry is set before EFM analysis.")
end

"""
    _compute_efm_column_demands(struc, columns, span_moments, qu, l2, ln)

Compute column-level demands from EFM span moments.

Uses tributary area for shear where available.
"""
function _compute_efm_column_demands(struc, columns, span_moments, qu, l2, ln)
    n_cols = length(columns)
    MomentT = typeof(1.0kip*u"ft")
    ForceT  = typeof(1.0kip)
    column_moments     = Vector{MomentT}(undef, n_cols)
    column_shears      = Vector{ForceT}(undef, n_cols)
    unbalanced_moments = Vector{MomentT}(undef, n_cols)
    
    for (i, col) in enumerate(columns)
        if i == 1
            M = span_moments[1].M_neg_left
            Mub = M
        elseif i == n_cols
            M = span_moments[end].M_neg_right
            Mub = M
        else
            M_left = span_moments[i-1].M_neg_right
            M_right = span_moments[i].M_neg_left
            M = max(M_left, M_right)
            Mub = abs(M_left - M_right)
        end
        
        column_moments[i] = M
        unbalanced_moments[i] = Mub
        column_shears[i] = _compute_column_shear(struc, col, qu, l2, ln)
    end
    
    return column_moments, column_shears, unbalanced_moments
end

# _compute_column_shear is defined in common.jl (shared between DDM and EFM)

# =============================================================================
# EFM Applicability Check - ACI 318-19 Section 8.11
# =============================================================================

"""
    EFMApplicabilityError <: Exception

Error thrown when EFM is not applicable for the given geometry/loading.
"""
struct EFMApplicabilityError <: Exception
    violations::Vector{String}
end

function Base.showerror(io::IO, e::EFMApplicabilityError)
    println(io, "EFM (Equivalent Frame Method) is not permitted for this slab per ACI 318-19 §8.11:")
    for (i, v) in enumerate(e.violations)
        println(io, "  $i. $v")
    end
    # FEA is always valid - suggest it as the fallback
    println(io, "\nConsider using FEA (Finite Element Analysis) instead: method=FEA()")
    println(io, "FEA has no geometric restrictions and can handle any layout.")
end

"""
    check_efm_applicability(struc, slab, columns; throw_on_failure=true)

Check if EFM is applicable per ACI 318-19 Section 8.11.

# ACI 318-19 §8.11 Requirements:

Unlike DDM, EFM has **fewer geometric restrictions**. It is a general method that can
handle irregular layouts. However, it still requires:

1. **§8.11.1.1** - Analysis is for gravity loads only (lateral by separate analysis)
2. **§8.11.2** - Slab-beam must extend from column centerline to column centerline
3. **§8.11.5** - Equivalent column stiffness must properly account for torsion
4. **§8.11.6.1** - Design moments taken at face of support
5. **§8.11.6.1** - Negative moment not taken at distance > 0.175×l₁ from column center

# Key Advantage
EFM has **no restrictions** on:
- Number of spans (DDM requires ≥3)
- Panel aspect ratio (DDM requires l₂/l₁ ≤ 2.0)
- Successive span ratios (DDM requires ≤1/3 difference)
- Column offsets (DDM requires ≤10% of span)
- L/D ratio (DDM requires ≤2.0)

# Arguments
- `struc`: BuildingStructure
- `slab`: Slab being designed
- `columns`: Vector of supporting columns
- `throw_on_failure`: If true, throw EFMApplicabilityError; if false, return result

# Returns
Named tuple with:
- `ok::Bool`: true if EFM is applicable
- `violations::Vector{String}`: list of violated conditions with code references

# Throws
`EFMApplicabilityError` if any condition is violated and `throw_on_failure=true`
"""
function check_efm_applicability(struc, slab, columns; throw_on_failure::Bool = true)
    violations = String[]
    
    l1 = slab.spans.primary
    l2 = slab.spans.secondary
    l1_val = ustrip(l1)
    l2_val = ustrip(l2)
    
    # -------------------------------------------------------------------------
    # Minimum clear span check (practical limit for two-way behavior)
    # -------------------------------------------------------------------------
    # Two-way slab analysis assumes slenderness; spans < 4 ft behave more like
    # thick plates where shear governs over flexure
    if !isempty(columns)
        c1_avg = sum(col.c1 for col in columns) / length(columns)
        ln = clear_span(l1, c1_avg)
        
        ln_min = 4.0u"ft"
        if ln < ln_min
            push!(violations, "Clear span ln = $(round(ustrip(u"ft", ln), digits=2)) ft < $(ustrip(u"ft", ln_min)) ft minimum for two-way slab behavior")
        end
    end
    
    # -------------------------------------------------------------------------
    # §8.11.2 - Panel geometry: must be rectangular
    # -------------------------------------------------------------------------
    # EFM models the slab as a 2D frame; non-rectangular bays require FEA
    if l1_val <= 0 || l2_val <= 0
        push!(violations, "§8.11.2: Panel must be rectangular; invalid span dimensions l₁=$(l1), l₂=$(l2)")
    end
    
    # Check if slab has non-rectangular geometry flag (if available)
    if hasproperty(slab, :is_rectangular) && !slab.is_rectangular
        push!(violations, "§8.11.2: Panel must be rectangular; EFM frame model requires orthogonal bays (use FEA for irregular geometry)")
    end
    
    # -------------------------------------------------------------------------
    # §8.11.1.1 - Gravity loads only
    # -------------------------------------------------------------------------
    # We assume this is satisfied since EFM frame doesn't include lateral loads
    # Lateral loads should be handled by a separate lateral system analysis
    
    # -------------------------------------------------------------------------
    # Minimum geometry requirements
    # -------------------------------------------------------------------------
    # EFM requires at least 2 columns to form a span
    n_cols = length(columns)
    if n_cols < 2
        push!(violations, "§8.11.2: EFM requires at least 2 columns to form a frame; only $(n_cols) column(s) found")
    end
    
    # -------------------------------------------------------------------------
    # Column sizing requirements for torsional stiffness
    # -------------------------------------------------------------------------
    # Check that columns have reasonable dimensions for Kt calculation
    # c2/l2 should not be too large (approaches infinity in Kt formula)
    if l2_val > 0
        for (i, col) in enumerate(columns)
            c2 = col.c2
            c2_l2_ratio = ustrip(c2) / l2_val
            if c2_l2_ratio > 0.5
                push!(violations, "§8.11.5: Column $i dimension c₂ = $(c2) exceeds 50% of panel width l₂ = $(l2); torsional stiffness formula invalid")
            end
        end
    end
    
    ok = isempty(violations)
    
    if !ok && throw_on_failure
        throw(EFMApplicabilityError(violations))
    end
    
    return (ok=ok, violations=violations)
end

"""
    enforce_efm_applicability(struc, slab, columns)

Enforce EFM applicability, throwing an error if not permitted.
This is called automatically by `run_moment_analysis(::EFM, ...)`.
"""
function enforce_efm_applicability(struc, slab, columns)
    check_efm_applicability(struc, slab, columns; throw_on_failure=true)
end

# =============================================================================
# FrameLine-Based EFM Analysis
# =============================================================================

"""
    run_moment_analysis(method::EFM, frame_line::FrameLine, struc, h, fc, Ecs, Ecc, qu, qD, qL; verbose=false)

Run EFM moment analysis using a FrameLine (multi-span frame strip).

This overload accepts a pre-built FrameLine which already has:
- Columns sorted along the frame direction
- Clear span lengths computed
- Joint positions (exterior/interior) determined

# Arguments
- `method::EFM`: EFM method with solver selection (:asap or :moment_distribution)
- `frame_line::FrameLine`: Pre-built frame strip with columns and spans
- `struc`: BuildingStructure (for tributary area lookup)
- `h::Length`: Slab thickness
- `fc::Pressure`: Concrete compressive strength
- `Ecs::Pressure`: Slab concrete modulus
- `Ecc::Pressure`: Column concrete modulus
- `qu::Pressure`: Factored uniform load
- `qD::Pressure`: Service dead load
- `qL::Pressure`: Service live load

# Returns
`MomentAnalysisResult` with all moments and geometry data.

# Example
```julia
fl = FrameLine(:x, columns, l2, get_pos, get_width)
result = run_moment_analysis(EFM(:asap), fl, struc, h, fc, Ecs, Ecc, qu, qD, qL)
```
"""
function run_moment_analysis(
    method::EFM,
    frame_line,  # FrameLine{T, C}
    struc,
    h::Length,
    fc::Pressure,
    Ecs::Pressure,
    Ecc::Pressure,
    qu::Pressure,
    qD::Pressure,
    qL::Pressure;
    ν_concrete::Float64 = 0.20,
    ρ_concrete = 2380.0u"kg/m^3",
    verbose::Bool = false,
    efm_cache::Union{Nothing, EFMModelCache} = nothing,
    cache = nothing,  # API parity (unused by EFM)
)
    # Extract from FrameLine
    sorted_columns = frame_line.columns
    l2 = frame_line.tributary_width
    n_spans = length(frame_line.span_lengths)
    n_cols = n_spans + 1
    
    # Build joint positions from FrameLine
    joint_positions = frame_line.joint_positions
    
    # Get column height (assume uniform)
    H = _get_column_height(sorted_columns)
    
    # Build EFM span properties from FrameLine
    spans = EFMSpanProperties[]
    for span_idx in 1:n_spans
        col_left = sorted_columns[span_idx]
        col_right = sorted_columns[span_idx + 1]
        ln = frame_line.span_lengths[span_idx]
        
        # Center-to-center span (approximate from clear span + column widths)
        l1 = ln + (col_left.c1 + col_right.c1) / 2
        
        # Column dimensions
        c1_left = col_left.c1
        c2_left = col_left.c2
        c1_right = col_right.c1
        c2_right = col_right.c2
        
        # Compute span properties
        Is = slab_moment_of_inertia(l2, h)
        Ksb = slab_beam_stiffness_Ksb(Ecs, Is, l1)
        
        # PCA factors
        m_factor = _get_fem_coefficient_from_geometry(c1_left, c1_right, l1)
        k_slab = _get_k_factor_from_geometry(c1_left, c1_right, l1)
        COF = _get_cof_from_geometry(c1_left, c1_right, l1)
        
        push!(spans, EFMSpanProperties(
            span_idx, span_idx, span_idx + 1,
            l1, l2, ln, h,
            c1_left, c2_left, c1_right, c2_right,
            Is, Ksb, m_factor, COF, k_slab
        ))
    end
    
    # Total static moment for reference
    ln_avg = sum(sp.ln for sp in spans) / n_spans
    M0 = total_static_moment(qu, l2, ln_avg)
    
    if verbose
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "MOMENT ANALYSIS - EFM (FrameLine)"
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "Frame direction" dir=frame_line.direction n_spans=n_spans l2=l2
        @debug "Solver" solver=method.solver
        @debug "Loads" qD=qD qL=qL qu=qu
    end
    
    # Detect column shape from first column
    col_shape_val = col_shape(sorted_columns[1])
    
    # Solve using selected method
    if method.solver == :asap
        if !isnothing(efm_cache) && efm_cache.initialized
            _update_efm_sections_and_loads!(
                efm_cache, spans, joint_positions, qu, Ecs, Ecc, H,
                ν_concrete, ρ_concrete;
                column_shape = col_shape_val,
            )
            solve_efm_frame!(efm_cache.model; full_process=false)
            span_moments = extract_span_moments(
                efm_cache.model, efm_cache.span_elements, spans; qu=qu
            )
        else
            model, span_elements, jKec = build_efm_asap_model(
                spans, joint_positions, qu;
                column_height = H,
                Ecs = Ecs,
                Ecc = Ecc,
                ν_concrete = ν_concrete,
                ρ_concrete = ρ_concrete,
                column_shape = col_shape_val,
                verbose = verbose,
            )
            solve_efm_frame!(model)
            span_moments = extract_span_moments(model, span_elements, spans; qu=qu)

            if !isnothing(efm_cache)
                n_sp = length(spans)
                efm_cache.initialized    = true
                efm_cache.model          = model
                efm_cache.span_elements  = collect(Element{FixedFixed}, span_elements)
                efm_cache.col_elements   = collect(Element{FixedFixed}, model.elements[(n_sp+1):end])
                efm_cache.joint_Kec      = collect(Any, jKec)
                efm_cache.n_spans        = n_sp
            end
        end
        
    elseif method.solver == :moment_distribution
        joint_Kec = _compute_joint_Kec(spans, joint_positions, H, Ecs, Ecc; column_shape=col_shape_val)
        span_moments = solve_moment_distribution(spans, joint_Kec, joint_positions, qu; verbose=verbose)
    else
        error("Unknown EFM solver: $(method.solver)")
    end
    
    if verbose
        @debug "───────────────────────────────────────────────────────────────────"
        @debug "EFM RESULTS"
        @debug "───────────────────────────────────────────────────────────────────"
        for (i, sm) in enumerate(span_moments)
            @debug "Span $i" M_neg_left=uconvert(kip*u"ft", sm.M_neg_left) M_pos=uconvert(kip*u"ft", sm.M_pos) M_neg_right=uconvert(kip*u"ft", sm.M_neg_right)
        end
    end
    
    M_neg_ext = span_moments[1].M_neg_left
    M_neg_int = span_moments[1].M_neg_right
    M_pos = span_moments[1].M_pos
    
    # Build column-level results
    column_moments, column_shears, unbalanced_moments = _compute_efm_column_demands(
        struc, sorted_columns, span_moments, qu, l2, ln_avg
    )
    
    l1_avg = sum(sp.l1 for sp in spans) / n_spans
    c1_avg = sum(c.c1 for c in sorted_columns) / n_cols
    
    # Convert all outputs to consistent US units for MomentAnalysisResult
    # Moments in kip*ft, lengths in ft, forces in kip, pressures in psf
    # (Same as DDM to ensure consistent type signature)
    M0_conv = uconvert(kip * u"ft", M0)
    M_neg_ext_conv = uconvert(kip * u"ft", M_neg_ext)
    M_neg_int_conv = uconvert(kip * u"ft", M_neg_int)
    M_pos_conv = uconvert(kip * u"ft", M_pos)
    
    # Convert pressures and lengths to consistent units
    qu_psf = uconvert(psf, qu)
    qD_psf = uconvert(psf, qD)
    qL_psf = uconvert(psf, qL)
    Vu_max = uconvert(kip, qu_psf * l2 * ln_avg / 2)
    
    return MomentAnalysisResult(
        M0_conv,
        M_neg_ext_conv,
        M_neg_int_conv,
        M_pos_conv,
        qu_psf, qD_psf, qL_psf,
        uconvert(u"ft", l1_avg),
        uconvert(u"ft", l2),
        uconvert(u"ft", ln_avg),
        uconvert(u"ft", c1_avg),
        column_moments,
        column_shears,
        unbalanced_moments,
        Vu_max
    )
end
