# =============================================================================
# EFM ASAP Model Building
# =============================================================================

"""
    _efm_span_segments(sp, drop) -> Vector{NamedTuple}

Sub-elements of one slab-beam span, left to right. Each has a `role`, its
end stations `x0`, `x1` from the left centerline (m), and `w_extra`, the
drop line load on it (N/m).

Flat plate: rigid zone, clear span, rigid zone. Flat slab
(`drop = (w, a_left, a_right)`): a `:drop` segment runs from each column
face to the drop edge. A drop that ends inside the column has no segment;
its load is spread over the rigid zone.
"""
function _efm_span_segments(sp, drop)
    m = u"m"
    l1 = uconvert(m, sp.l1)
    fL = uconvert(m, sp.c1_left / 2)
    fR = l1 - uconvert(m, sp.c1_right / 2)
    aL = drop === nothing ? 0.0m : uconvert(m, drop.a_left)
    aR = drop === nothing ? 0.0m : uconvert(m, drop.a_right)
    wd = drop === nothing ? 0.0u"N/m" : uconvert(u"N/m", drop.w)
    spread(a, f) = a <= zero(a) ? zero(wd) : a >= f ? wd : wd * (a / f)
    tol = 1e-6m
    segs = NamedTuple[(role = :rigid_left, x0 = 0.0m, x1 = fL, w_extra = spread(aL, fL),
                       drop_face = aL > fL + tol)]
    eL = max(aL, fL)
    eR = min(l1 - aR, fR)
    aL > fL + tol && push!(segs, (role = :drop, x0 = fL, x1 = eL, w_extra = wd, drop_face = true))
    eR > eL + tol && push!(segs, (role = :clear, x0 = eL, x1 = eR, w_extra = 0.0u"N/m",
                                  drop_face = false))
    l1 - aR < fR - tol && push!(segs, (role = :drop, x0 = max(eR, eL), x1 = fR, w_extra = wd,
                                       drop_face = true))
    push!(segs, (role = :rigid_right, x0 = fR, x1 = l1, w_extra = spread(aR, l1 - fR),
                 drop_face = l1 - aR < fR - tol))
    return segs
end

"""
    _efm_segment_section(seg, sp, Ecs, ν_concrete, ρ) -> Section

ACI 318-11 §13.7.3.2: gross section outside the joint, `Is` or, over a
drop, the composite `Is_drop`. §13.7.3.3: from the centerline to the
column face, the section at the face divided by (1 − c2/l2)².
"""
function _efm_segment_section(seg, sp, Ecs, ν_concrete, ρ)
    l2, h = sp.l2, sp.h
    I_face = seg.drop_face ? sp.Is_drop : l2 * h^3 / 12
    I = if seg.role === :rigid_left
        I_face / (1 - min(ustrip(Unitful.NoUnits, sp.c2_left / l2), 0.99))^2
    elseif seg.role === :rigid_right
        I_face / (1 - min(ustrip(Unitful.NoUnits, sp.c2_right / l2), 0.99))^2
    else
        I_face
    end
    G = Ecs / (2 * (1 + ν_concrete))
    return Section(
        uconvert(u"m^2", l2 * h), uconvert(u"Pa", Ecs), uconvert(u"Pa", G),
        uconvert(u"m^4", I), uconvert(u"m^4", I / 10),
        uconvert(u"m^4", _torsional_constant_rect(l2, h)), ρ,
    )
end

"""
    build_efm_asap_model(spans, joint_positions, qu; drop_loads=nothing, kwargs...)

Build an ASAP frame model for EFM analysis with sub-elements per span
([`_efm_span_segments`](@ref)) and explicit column stubs.

# Slab-Beam Model (ACI 318-11 §13.7.3.3)

A flat plate span is modeled with 3 elements:
1. **Rigid zone (left)**: column center to column face, length = c₁_left/2.
   Moment of inertia amplified per §13.7.3.3:
       I_rigid = I_s / (1 - c₂/l₂)²
2. **Clear span**: face-to-face, length = l_n.
   Gross moment of inertia: I_s = l₂ × h³ / 12.
3. **Rigid zone (right)**: column face to column center, length = c₁_right/2.
   Same amplified I_rigid.

A flat slab span (`drop_loads[s] = (w, a_left, a_right)`) adds a drop
segment from each face to the drop edge with the composite `Is_drop`
(§13.7.3.2), and its rigid zones amplify `Is_drop`. The drop line load
`w` acts from each column centre to the drop edge on top of `qu × l₂`.

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
- `span_elements`: Vector of slab-beam elements, span by span, left to right
  (3 per span for a flat plate)
- `col_stubs`: Dict{Int, NamedTuple} — joint index → (below=..., above=...)

`model.loads[k]` is the line load on `span_elements[k]`.
[`_efm_span_ranges`](@ref) recovers each span's elements.

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
    drop_loads = nothing,
)
    n_spans = length(spans)
    n_joints = n_spans + 1
    ρ = ρ_concrete
    slab_dofs = [true, false, true, false, true, false]  # XZ plane frame

    # ── Column-center nodes (one per joint) ──
    nodes = Node[]
    slab_node_indices = Int[]
    x_pos = 0.0u"m"
    for j in 1:n_joints
        push!(nodes, Node([x_pos, 0.0u"m", 0.0u"m"], slab_dofs))
        push!(slab_node_indices, length(nodes))
        j < n_joints && (x_pos += uconvert(u"m", spans[j].l1))
    end

    # ── Slab-beam sub-elements and their line loads ──
    elements = Element[]
    span_elements = Element[]
    loads = AbstractLoad[]
    for i in 1:n_spans
        sp = spans[i]
        dl = _span_drop(drop_loads, i)
        w_slab = uconvert(u"N/m", qu * sp.l2)
        x_center = nodes[slab_node_indices[i]].position[1]
        segs = _efm_span_segments(sp, dl)
        n_left = nodes[slab_node_indices[i]]
        for (k, seg) in enumerate(segs)
            n_right = if k == length(segs)
                nodes[slab_node_indices[i + 1]]
            else
                push!(nodes, Node([x_center + seg.x1, 0.0u"m", 0.0u"m"], slab_dofs))
                nodes[end]
            end
            e = Element(n_left, n_right, _efm_segment_section(seg, sp, Ecs, ν_concrete, ρ))
            push!(elements, e)
            push!(span_elements, e)
            push!(loads, LineLoad(e, [0.0u"N/m", 0.0u"N/m", -(w_slab + seg.w_extra)]))
            n_left = n_right
        end
    end

    # ── Build column stub elements (same pattern as FEA) ──
    col_stubs = Dict{Int, NamedTuple}()

    for j in 1:n_joints
        col = columns[j]
        slab_node = nodes[slab_node_indices[j]]
        if _support_is_wall_fixed(col)
            # R13.1 / R13.6.3.3: little rotation at a wall cast with the slab.
            # The XZ frame's in-plane rotation is ry (dof 5). A new vector,
            # because the slab nodes share one dof array.
            slab_node.dof = [true, false, false, false, false, false]
            continue
        end
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

            sec_a = _sized_column_section(col_above)
            c1_a, c2_a = sec_a === nothing ? (col.c1, col.c2) : sec_a
            sec_above = column_asap_section(
                c1_a, c2_a, col_shape(col_above), Ecc, ν_concrete;
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

    model = Model(nodes, elements, loads)

    return model, span_elements, col_stubs
end

"""Drop line load of span `s`, or `nothing` for a flat plate."""
_span_drop(drop_loads, s::Int) = drop_loads === nothing ? nothing : drop_loads[s]

"""
    _efm_span_ranges(spans, drop_loads) -> Vector{UnitRange{Int}}

Indices into `span_elements` (and `model.loads`) of each span's
sub-elements, in the order [`build_efm_asap_model`](@ref) creates them.
"""
function _efm_span_ranges(spans, drop_loads)
    ranges = Vector{UnitRange{Int}}(undef, length(spans))
    k = 0
    for i in eachindex(spans)
        n = length(_efm_span_segments(spans[i], _span_drop(drop_loads, i)))
        ranges[i] = (k + 1):(k + n)
        k += n
    end
    return ranges
end

"""
    _set_efm_slab_loads!(model, spans, qu, drop_loads)

Rewrite the line load on every slab-beam sub-element: `qu × l₂` (one
pressure, or one per span under a load pattern) plus the drop line load.
The drop is dead load and is not patterned.
"""
function _set_efm_slab_loads!(model, spans, qu, drop_loads)
    k = 0
    for i in eachindex(spans)
        q = qu isa AbstractVector ? qu[i] : qu
        w_slab = uconvert(u"N/m", q * spans[i].l2)
        for seg in _efm_span_segments(spans[i], _span_drop(drop_loads, i))
            k += 1
            model.loads[k].value = [0.0u"N/m", 0.0u"N/m", -(w_slab + seg.w_extra)]
        end
    end
    return model
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

