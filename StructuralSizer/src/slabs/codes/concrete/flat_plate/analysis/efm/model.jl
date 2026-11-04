# =============================================================================
# EFM ASAP Model Building
# =============================================================================

"""
    build_efm_asap_model(spans, joint_positions, qu; kwargs...)

Build an ASAP frame model for EFM analysis using **3 sub-elements per span**
(rigid zone – clear span – rigid zone) and explicit column stubs.

# Slab-Beam Model (ACI 318-11 §13.7.3.3)

Each span is modeled with 3 elements:
1. **Rigid zone (left)**: column center to column face, length = c₁_left/2.
   Moment of inertia amplified per §13.7.3.3:
       I_rigid = I_s / (1 - c₂/l₂)²
2. **Clear span**: face-to-face, length = l_n.
   Gross moment of inertia: I_s = l₂ × h³ / 12.
3. **Rigid zone (right)**: column face to column center, length = c₁_right/2.
   Same amplified I_rigid.

This eliminates the need for the PCA Table A1 stiffness factor `k_slab`
in the ASAP path — the solver computes exact stiffness, carry-over, and
moment distribution from the actual non-prismatic geometry.

# Column Model

Each joint gets up to two column frame elements (same pattern as FEA):
- **Below column** (always present): fixed base at z = −Lc → slab node (z = 0)
- **Above column** (if `col.column_above` exists): slab node → fixed top at z = +Lc_above

Section properties come from `column_asap_section` (single source of truth),
with I_factor = 0.70 per ACI 318-11 §10.10.4.1.  The ASAP solver computes
column stiffness from actual geometry — no Kec → Ic_eff back-solve.

Roof joints get only the below stub; intermediate joints get both.
Unequal columns above/below are handled naturally.

# Arguments
- `columns`: Vector of column objects (one per joint), each with fields
  `c1`, `c2`, `base.L` (column length), and `column_above` (column above
  or `nothing` for roof).  NamedTuples work fine for tests.

# Returns
- `model`: ASAP Model ready to solve
- `span_elements`: Vector of slab-beam elements (3 per span)
- `col_stubs`: Dict{Int, NamedTuple} — joint index → (below=..., above=...)

# Reference
- ACI 318-11 §13.7.3.3 — Slab-beam moment of inertia at column regions
- ACI 318-11 §10.10.4.1 — Column cracking reduction factor
"""
function build_efm_asap_model(
    spans::Vector{<:EFMSpanProperties},
    joint_positions::Vector{Symbol},
    qu::Pressure;
    Ecs::Pressure,
    Ecc::Pressure,
    ν_concrete::Float64,
    ρ_concrete,
    columns,
    verbose::Bool = false,
    col_I_factor::Float64 = 0.70,
    kec_factors::Union{Nothing, Vector{Float64}} = nothing,
)
    n_spans = length(spans)
    n_joints = n_spans + 1

    l2 = spans[1].l2
    h  = spans[1].h

    Ecs_Pa = uconvert(u"Pa", Ecs)
    G_slab = Ecs / (2 * (1 + ν_concrete))
    ρ = ρ_concrete

    # ── Build nodes ──
    nodes = Node[]
    slab_dofs = [true, false, true, false, true, false]  # XZ plane frame

    # Column-center nodes (one per joint)
    slab_node_indices = Int[]
    x_pos = 0.0u"m"
    for j in 1:n_joints
        push!(nodes, Node([x_pos, 0.0u"m", 0.0u"m"], slab_dofs))
        push!(slab_node_indices, length(nodes))
        if j < n_joints
            x_pos += uconvert(u"m", spans[j].l1)
        end
    end

    # Face-of-column nodes (2 per span: left face, right face)
    face_node_indices = Vector{NTuple{2, Int}}(undef, n_spans)
    for i in 1:n_spans
        sp = spans[i]
        x_left_center = nodes[slab_node_indices[i]].position[1]
        x_right_center = nodes[slab_node_indices[i+1]].position[1]

        c1_left_half  = uconvert(u"m", sp.c1_left / 2)
        c1_right_half = uconvert(u"m", sp.c1_right / 2)

        x_left_face  = x_left_center + c1_left_half
        x_right_face = x_right_center - c1_right_half

        push!(nodes, Node([x_left_face, 0.0u"m", 0.0u"m"], slab_dofs))
        idx_lf = length(nodes)
        push!(nodes, Node([x_right_face, 0.0u"m", 0.0u"m"], slab_dofs))
        idx_rf = length(nodes)
        face_node_indices[i] = (idx_lf, idx_rf)
    end

    # ── Build slab-beam elements (3 per span) ──
    elements = Element[]
    span_elements = Element[]

    Is_gross = l2 * h^3 / 12
    A_slab   = l2 * h
    J_slab   = _torsional_constant_rect(l2, h)

    clear_sec = Section(
        uconvert(u"m^2", A_slab),
        Ecs_Pa,
        uconvert(u"Pa", G_slab),
        uconvert(u"m^4", Is_gross),
        uconvert(u"m^4", Is_gross / 10),
        uconvert(u"m^4", J_slab),
        ρ
    )

    for i in 1:n_spans
        sp = spans[i]
        (idx_lf, idx_rf) = face_node_indices[i]

        # Rigid-zone section: ACI 318-11 §13.7.3.3
        c2_left  = sp.c2_left
        c2_right = sp.c2_right
        ratio_left  = ustrip(c2_left) / ustrip(uconvert(unit(c2_left), l2))
        ratio_right = ustrip(c2_right) / ustrip(uconvert(unit(c2_right), l2))
        ratio_left  = min(ratio_left, 0.99)
        ratio_right = min(ratio_right, 0.99)
        Is_rigid_left  = Is_gross / (1 - ratio_left)^2
        Is_rigid_right = Is_gross / (1 - ratio_right)^2

        rigid_sec_left = Section(
            uconvert(u"m^2", A_slab), Ecs_Pa, uconvert(u"Pa", G_slab),
            uconvert(u"m^4", Is_rigid_left),
            uconvert(u"m^4", Is_rigid_left / 10),
            uconvert(u"m^4", J_slab), ρ
        )
        rigid_sec_right = Section(
            uconvert(u"m^2", A_slab), Ecs_Pa, uconvert(u"Pa", G_slab),
            uconvert(u"m^4", Is_rigid_right),
            uconvert(u"m^4", Is_rigid_right / 10),
            uconvert(u"m^4", J_slab), ρ
        )

        e_rigid_L = Element(nodes[slab_node_indices[i]], nodes[idx_lf], rigid_sec_left)
        e_clear   = Element(nodes[idx_lf], nodes[idx_rf], clear_sec)
        e_rigid_R = Element(nodes[idx_rf], nodes[slab_node_indices[i+1]], rigid_sec_right)

        push!(elements, e_rigid_L); push!(span_elements, e_rigid_L)
        push!(elements, e_clear);   push!(span_elements, e_clear)
        push!(elements, e_rigid_R); push!(span_elements, e_rigid_R)
    end

    # ── Build column stub elements (same pattern as FEA) ──
    col_stubs = Dict{Int, NamedTuple}()

    for j in 1:n_joints
        col = columns[j]
        slab_node = nodes[slab_node_indices[j]]
        x_j = slab_node.position[1]

        # Per-joint I factor: base factor × Kec reduction (ACI 318-11 §13.7.4)
        I_j = col_I_factor * (!isnothing(kec_factors) ? kec_factors[j] : 1.0)

        # Below column (always present)
        Lc_below = col.base.L
        base_below = Node([x_j, 0.0u"m", -uconvert(u"m", Lc_below)], :fixed)
        push!(nodes, base_below)

        sec_below = column_asap_section(
            col.c1, col.c2, col_shape(col), Ecc, ν_concrete; I_factor=I_j)
        elem_below = Element(base_below, slab_node, sec_below)
        push!(elements, elem_below)

        # Above column (if column above exists)
        col_above = hasproperty(col, :column_above) ? col.column_above : nothing
        elem_above = nothing
        if !isnothing(col_above)
            Lc_above = col_above.base.L
            base_above = Node([x_j, 0.0u"m", uconvert(u"m", Lc_above)], :fixed)
            push!(nodes, base_above)

            sec_above = column_asap_section(
                col_above.c1, col_above.c2, col_shape(col_above), Ecc, ν_concrete;
                I_factor=I_j)
            elem_above = Element(slab_node, base_above, sec_above)
            push!(elements, elem_above)
        end

        col_stubs[j] = (
            below = (element=elem_below, base_node=base_below, slab_node=slab_node),
            above = isnothing(elem_above) ? nothing :
                    (element=elem_above, base_node=base_above, slab_node=slab_node),
        )

        if verbose
            above_str = isnothing(col_above) ? "roof (no above)" : "above+below"
            kec_str = !isnothing(kec_factors) ? "  Kec/Kc=$(round(kec_factors[j], digits=3))" : ""
            @debug "Joint $j column stubs" c1=col.c1 c2=col.c2 Lc_below=Lc_below type=above_str I_factor=round(I_j, digits=3) kec_str
        end
    end

    # ── Apply loads to ALL slab elements (rigid + clear) ──
    loads = AbstractLoad[]
    w_N_m = uconvert(u"N/m", qu * l2)
    for elem in span_elements
        push!(loads, LineLoad(elem, [0.0u"N/m", 0.0u"N/m", -w_N_m]))
    end

    model = Model(nodes, elements, loads)

    return model, span_elements, col_stubs
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

