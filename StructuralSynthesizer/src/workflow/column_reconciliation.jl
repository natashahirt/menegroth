# =============================================================================
# Pipeline Stage Implementations
# =============================================================================

"""Extract column options from DesignParameters for flat plate/slab sizing.
Returns ConcreteColumnOptions or PixelFrameColumnOptions; `nothing` for steel (not supported).
Caller must reject PixelFrame for flat plate/slab before use."""
function _get_column_opts(params::DesignParameters)
    opts = params.columns
    (opts isa ConcreteColumnOptions || opts isa StructuralSizer.PixelFrameColumnOptions) ? opts : nothing
end

# Half a sizing increment. Used only to recognize an unchanged cross-section.
_column_size_match(a, b) = abs(uconvert(u"inch", a) - uconvert(u"inch", b)) <= 0.05u"inch"

function _section_matches_column_size(sec, col)
    if sec isa StructuralSizer.RCColumnSection
        return (_column_size_match(sec.b, col.c1) && _column_size_match(sec.h, col.c2)) ||
               (_column_size_match(sec.b, col.c2) && _column_size_match(sec.h, col.c1))
    elseif sec isa StructuralSizer.RCCircularSection
        return _column_size_match(sec.D, col.c1) && _column_size_match(sec.D, col.c2)
    end
    return false
end

"""Bar size and count when every longitudinal bar has the same area, else `nothing`."""
function _uniform_bar_layout(sec)
    bars = sec.bars
    isempty(bars) && return nothing
    As0 = uconvert(u"inch^2", bars[1].As)
    all(b -> uconvert(u"inch^2", b.As) ≈ As0, bars) || return nothing
    for size in (3, 4, 5, 6, 7, 8, 9, 10, 11, 14, 18)
        bar = StructuralSizer.rebar(size)
        if uconvert(u"inch^2", bar.A) ≈ As0
            return (bar_size = size, n_bars = length(bars))
        end
    end
    return nothing
end

"""Place `existing`'s bar size and count on `col`'s current dimensions."""
function _same_bars_on_new_size(existing, col)
    layout = _uniform_bar_layout(existing)
    layout === nothing && return nothing
    if existing isa StructuralSizer.RCCircularSection
        return StructuralSizer.RCCircularSection(
            D = col.c1, bar_size = layout.bar_size, n_bars = layout.n_bars,
            cover = existing.cover, tie_type = existing.tie_type)
    end
    return StructuralSizer.RCColumnSection(
        b = col.c1, h = col.c2, bar_size = layout.bar_size, n_bars = layout.n_bars,
        cover = existing.cover, tie_type = existing.tie_type)
end

"""
Least standard bar layout with 0.01Ag ≤ As ≤ 0.08Ag.

ACI 318-11 §10.9.1 (corpus: aci-318-11, page 148). Used when a column has no
section, or its previous bars fall outside that window on a grown cross-section.
The axial grow check already set Ag from ACI 318-11 Eq. (10-2) at ρg = 0.01,
so this only restores the reinforcement limits. Bar counts are even, matching the column
reinforcement designer, and at least 4 for tied columns or 6 for spiral.
"""
function _minimum_longitudinal_section(col, existing)
    Ag = col.shape == :circular ?
        (π / 4) * uconvert(u"inch", col.c1)^2 :
        uconvert(u"inch", col.c1) * uconvert(u"inch", col.c2)
    As_min = 0.01 * Ag
    As_max = 0.08 * Ag
    has_sec = existing isa StructuralSizer.RCColumnSection || existing isa StructuralSizer.RCCircularSection
    tie = has_sec ? existing.tie_type : (col.shape == :circular ? :spiral : :tied)
    cover = has_sec ? existing.cover : 1.5u"inch"
    min_bars = tie == :spiral ? 6 : 4
    layout = has_sec ? _uniform_bar_layout(existing) : nothing
    sizes = layout === nothing ? (8, 6, 7, 9, 10, 11) : (layout.bar_size, 8, 6, 7, 9, 10, 11)

    best = nothing
    best_As = As_max + 1.0u"inch^2"
    for size in unique(sizes)
        Ab = uconvert(u"inch^2", StructuralSizer.rebar(size).A)
        n = max(min_bars, ceil(Int, ustrip(As_min / Ab)))
        iseven(n) || (n += 1)
        while n <= 40
            As = n * Ab
            As > As_max && break
            if As >= As_min && As < best_As
                best = (bar_size = size, n_bars = n, cover = cover, tie_type = tie)
                best_As = As
            end
            n += 2
        end
    end
    best === nothing && error("No longitudinal layout satisfies ACI 318-11 §10.9.1 for this column size")
    if col.shape == :circular
        return StructuralSizer.RCCircularSection(
            D = col.c1, bar_size = best.bar_size, n_bars = best.n_bars,
            cover = best.cover, tie_type = best.tie_type)
    end
    return StructuralSizer.RCColumnSection(
        b = col.c1, h = col.c2, bar_size = best.bar_size, n_bars = best.n_bars,
        cover = best.cover, tie_type = best.tie_type)
end

"""
    _assign_flat_plate_column_section!(col) -> section

Keep the longitudinal bars already stored on `col` when that section still
matches `c1` × `c2`. Flat-plate sizing writes the P-M section onto the column;
replacing it with four #8 bars made the recorded rebar mass independent of
the design.

When the cross-section has grown, keep those bars if they still satisfy
ACI 318-11 §10.9.1 (0.01Ag ≤ As ≤ 0.08Ag; corpus: aci-318-11, page 148).
Otherwise install the least standard layout inside that window.
"""
function _assign_flat_plate_column_section!(col)
    existing = section(col)
    if _section_matches_column_size(existing, col)
        return existing
    end
    chosen = if existing isa StructuralSizer.RCColumnSection || existing isa StructuralSizer.RCCircularSection
        preserved = try
            _same_bars_on_new_size(existing, col)
        catch
            nothing
        end
        if preserved !== nothing && 0.01 <= preserved.ρg <= 0.08
            preserved
        else
            _minimum_longitudinal_section(col, existing)
        end
    else
        _minimum_longitudinal_section(col, existing)
    end
    set_section!(col, chosen)
    return chosen
end

"""
    _rc_column_frame_section(col, params) -> Asap.Section

Frame section for an RC column at its current `c1` × `c2` (or diameter).
The second moments of area are multiplied by `params.column_I_factor`
(ACI 318-11 §10.10.4.1). The rectangular torsion constant is
`β·a·b³`, `β = 1/3 − 0.21 (b/a)(1 − (b/a)⁴/12)`.
"""
function _rc_column_frame_section(col, params::DesignParameters)
    conc = something(col.concrete, resolve_column_concrete(params.materials))
    E_Pa = ustrip(u"Pa", conc.E)
    G_Pa = E_Pa / (2.0 * (1.0 + conc.ν))
    ρ_kg = ustrip(u"kg/m^3", conc.ρ)
    k = params.column_I_factor
    b_m = ustrip(u"m", col.c1)
    h_m = ustrip(u"m", col.c2)
    if col.shape == :circular
        A = π * b_m^2 / 4
        I = π * b_m^4 / 64
        J = π * b_m^4 / 32
        return Asap.Section(A * u"m^2", E_Pa * u"Pa", G_Pa * u"Pa",
                            k * I * u"m^4", k * I * u"m^4", k * J * u"m^4",
                            ρ_kg * u"kg/m^3")
    end
    a_dim, b_dim = max(b_m, h_m), min(b_m, h_m)
    β = 1/3 - 0.21 * (b_dim / a_dim) * (1 - (b_dim / a_dim)^4 / 12)
    return Asap.Section(b_m * h_m * u"m^2", E_Pa * u"Pa", G_Pa * u"Pa",
                        k * b_m * h_m^3 / 12 * u"m^4", k * h_m * b_m^3 / 12 * u"m^4",
                        k * β * a_dim * b_dim^3 * u"m^4", ρ_kg * u"kg/m^3")
end

"""Put `asap_sec` on every frame element of `col`."""
function _install_column_frame_section!(struc::BuildingStructure, col, asap_sec)
    for seg_idx in segment_indices(col)
        edge_idx = struc.segments[seg_idx].edge_idx
        (edge_idx < 1 || edge_idx > length(struc.asap_model.frame_elements)) && continue
        struc.asap_model.frame_elements[edge_idx].section = asap_sec
    end
    return col
end

"""
Re-solve after column sections changed on an unchanged mesh. Returns `true`
when the model was processed and solved.
"""
function _resolve_after_column_change!(struc::BuildingStructure)
    struc.asap_model.processed || return false
    Asap.update!(struc.asap_model; values_only=true)
    Asap.solve!(struc.asap_model)
    _refresh_pattern_solve_cache!(struc)
    return true
end

StructuralSizer.TRACE_REGISTRY[(:_reconcile_columns!, :workflow)] =
    StructuralSizer.TracedFunctionMeta(
        :_reconcile_columns!,
        :workflow,
        [:enter, :exit, :decision],
        nothing,
        @__FILE__,
        @__LINE__,
    )

"""
Tied-column design axial strength by ACI 318-11 Eq. (10-2), in newtons.

φPn,max = 0.80 φ [0.85 f′c (Ag − Ast) + fy Ast], with φ = 0.65 for a
compression-controlled tied member (§9.3.2.2(b); corpus aci-318-11, p. 127)
and Ast = 0.01 Ag (§10.9.1; p. 148). Eq. (10-2) is §10.3.6.2, p. 143.
`Ag_m2` is gross area in m²; stresses are in Pa.
"""
function _tied_pn_max(Ag_m2, fc_Pa, fy_Pa; ρg::Float64 = 0.01, φ::Float64 = 0.65)
    Ast = ρg * Ag_m2
    return 0.80 * φ * (0.85 * fc_Pa * (Ag_m2 - Ast) + fy_Pa * Ast)
end

"""Gross area (m²) at which [`_tied_pn_max`](@ref) equals `Pu_N`."""
function _tied_ag_for_pu(Pu_N, fc_Pa, fy_Pa; ρg::Float64 = 0.01, φ::Float64 = 0.65)
    denom = 0.80 * φ * (0.85 * fc_Pa * (1.0 - ρg) + fy_Pa * ρg)
    return Pu_N / denom
end

"""
    _reconcile_columns!(struc, params) -> (struc=struc, n_reconciled=Int)

Reconcile column sizes after flat-plate slab sizing.

The slab loop designs columns from tributary Pu (single-floor tributary).
For multi-story buildings, Asap model forces may be larger due to load
accumulation from upper floors. This stage grows any column whose
Asap-model axial demand exceeds ACI 318-11 Eq. (10-2) at ρg = 0.01,
using the column concrete and rebar rather than the slab's.

Returns the mutated structure and the number of columns that grew.
"""
function _reconcile_columns!(
    struc::BuildingStructure,
    params::DesignParameters;
    tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
)
    _col_opts = _get_column_opts(params)
    conc = resolve_column_concrete(params.materials)
    reb = resolve_column_rebar(params.materials)
    fc_Pa = ustrip(u"Pa", conc.fc′)
    fy_Pa = ustrip(u"Pa", reb.Fy)
    E_Pa = ustrip(u"Pa", conc.E)
    ν_c = conc.ν
    G_Pa = E_Pa / (2.0 * (1.0 + ν_c))
    ρ_kg = ustrip(u"kg/m^3", conc.ρ)
    I_factor = params.column_I_factor  # ACI 318-11 §10.10.4.1
    grew = 0

    _shape_con = !isnothing(_col_opts) ? _col_opts.shape_constraint : :square
    _max_ar   = !isnothing(_col_opts) ? _col_opts.max_aspect_ratio : 2.0
    _c_inc    = !isnothing(_col_opts) ? _col_opts.size_increment : 0.5u"inch"

    StructuralSizer.emit!(tc, :workflow, "_reconcile_columns!", "", :enter;
                          n_columns=length(struc.columns))

    for col in struc.columns
        isnothing(col.c1) && continue
        
        Pu_N = _column_asap_Pu(struc, col)
        
        # Check if column needs to grow for axial capacity
        needs_growth = false
        if Pu_N > 0
            # ACI 318-11 Eq. (10-2) at ρg = 0.01. Same expression as the axial check.
            Ag_required_m2 = _tied_ag_for_pu(Pu_N, fc_Pa, fy_Pa)
            Ag_required = Ag_required_m2 * u"m^2"
            c_required = sqrt(Ag_required_m2) * u"m"
            if c_required > col.c1 || c_required > col.c2
                grow_column_for_axial!(col, Ag_required;
                                        shape_constraint=_shape_con, max_ar=_max_ar,
                                        increment=_c_inc)
                grew += 1
                needs_growth = true
            end
        end

        b_m = ustrip(u"m", col.c1)
        h_m = ustrip(u"m", col.c2)
        col_shape = hasproperty(col, :shape) ? col.shape : :rectangular

        # The slab loop already stored the P-M section. Keep its bars, or
        # redesign only when this column grew, and record concrete and rebar
        # volumes from that section.
        _assign_flat_plate_column_section!(col)
        _set_rc_column_volumes!(
            col,
            something(col.concrete, resolve_column_concrete(params.materials)),
            resolve_column_rebar(params.materials),
        )

        # Update Asap model elements if column grew
        if needs_growth
            if col_shape == :circular
                D_m = b_m  # c1 = c2 = D for circular
                A = π * D_m^2 / 4
                I = π * D_m^4 / 64  # Same for both axes
                J = π * D_m^4 / 32  # Torsional constant, solid circular
                asap_sec = Asap.Section(
                    A * u"m^2", E_Pa * u"Pa", G_Pa * u"Pa",
                    I_factor * I * u"m^4", I_factor * I * u"m^4",
                    I_factor * J * u"m^4",
                    ρ_kg * u"kg/m^3",
                )
            else
                A   = b_m * h_m
                Ig_x = b_m * h_m^3 / 12
                Ig_y = h_m * b_m^3 / 12
                a_dim = max(b_m, h_m); b_dim = min(b_m, h_m)
                β = 1/3 - 0.21 * (b_dim / a_dim) * (1 - (b_dim / a_dim)^4 / 12)
                asap_sec = Asap.Section(
                    A * u"m^2", E_Pa * u"Pa", G_Pa * u"Pa",
                    I_factor * Ig_x * u"m^4", I_factor * Ig_y * u"m^4",
                    I_factor * β * a_dim * b_dim^3 * u"m^4",
                    ρ_kg * u"kg/m^3",
                )
            end

            for seg_idx in segment_indices(col)
                edge_idx = struc.segments[seg_idx].edge_idx
                (edge_idx < 1 || edge_idx > length(struc.asap_model.frame_elements)) && continue
                struc.asap_model.frame_elements[edge_idx].section = asap_sec
            end
        end
    end
    
    grew > 0 && @info "Column reconciliation: $grew columns grew from Asap model forces"

    # Recompute structural offsets after column dimensions changed
    grew > 0 && update_structural_offsets!(struc; input_is_centerline=params.geometry_is_centerline)

    # Self-sync: if any columns grew, do a lightweight K+S update and re-solve
    # so the outer pipeline can skip the redundant full sync_asap!
    synced = false
    if grew > 0 && struc.asap_model.processed
        Asap.update!(struc.asap_model; values_only=true)
        Asap.solve!(struc.asap_model)
        _refresh_pattern_solve_cache!(struc)
        synced = true
    end

    # ACI 318-11 §13.6.9.2 end moments, after the axial grow. Every flat-plate
    # design takes this check; there is no flag to leave the moments off.
    full = check_flat_plate_columns!(struc, params; tc)
    synced |= !isempty(full.grown)
    grew += length(full.grown)

    if grew > 0
        StructuralSizer.emit!(tc, :workflow, "_reconcile_columns!", "", :decision;
                              outcome="grew_columns", n_reconciled=grew, self_synced=synced)
    else
        StructuralSizer.emit!(tc, :workflow, "_reconcile_columns!", "", :decision;
                              outcome="no_change", n_reconciled=0, self_synced=false)
    end
    StructuralSizer.emit!(tc, :workflow, "_reconcile_columns!", "", :exit;
                          n_reconciled=grew, self_synced=synced)

    return (struc = struc, n_reconciled = grew, synced = synced, full_load = full)
end

