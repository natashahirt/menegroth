# =============================================================================
# Pipeline Stage Implementations
# =============================================================================

"""Extract column options from DesignParameters for flat plate/slab sizing.
Returns ConcreteColumnOptions or PixelFrameColumnOptions; `nothing` for steel (not supported).
With `params.columns` unset on a flat plate or flat slab, returns
[`concrete_column_options`](@ref), so the slab loop sizes columns in the
cascade's column materials. Caller must reject PixelFrame for flat plate/slab before use."""
function _get_column_opts(params::DesignParameters)
    opts = params.columns
    (opts isa ConcreteColumnOptions || opts isa StructuralSizer.PixelFrameColumnOptions) && return opts
    if opts === nothing
        floor = something(params.floor, StructuralSizer.FlatPlateOptions())
        StructuralSizer.floor_symbol(floor) in (:flat_plate, :flat_slab) &&
            return concrete_column_options(params)
    end
    return nothing
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
        cover = existing.cover, tie_type = existing.tie_type,
        tie_bar_size = existing.tie_bar_size)
end

"""
Least standard bar layout with 0.01Ag ≤ As ≤ 0.08Ag.

ACI 318-11 §10.9.1 (corpus: aci-318-11, page 148). Used when a column has no
section, or its previous bars fall outside that window on a grown cross-section.
The axial grow check already set Ag from ACI 318-11 Eq. (10-2) at ρg = 0.01,
so this only restores the reinforcement limits. Bar counts are even, matching the column
reinforcement designer, and at least 4 for tied columns or 6 for spiral. Layouts the
section constructor rejects (e.g. ACI 318-19 §25.2.3 clear spacing) are skipped.
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
    tie_bar = existing isa StructuralSizer.RCColumnSection ? existing.tie_bar_size : 4
    min_bars = tie == :spiral ? 6 : 4
    layout = has_sec ? _uniform_bar_layout(existing) : nothing
    sizes = layout === nothing ? (8, 6, 7, 9, 10, 11) : (layout.bar_size, 8, 6, 7, 9, 10, 11)

    build(size, n) = col.shape == :circular ?
        StructuralSizer.RCCircularSection(
            D = col.c1, bar_size = size, n_bars = n, cover = cover, tie_type = tie) :
        StructuralSizer.RCColumnSection(
            b = col.c1, h = col.c2, bar_size = size, n_bars = n, cover = cover,
            tie_type = tie, tie_bar_size = tie_bar)

    candidates = Tuple{typeof(1.0u"inch^2"), Int, Int}[]
    for size in unique(sizes)
        Ab = uconvert(u"inch^2", StructuralSizer.rebar(size).A)
        n = max(min_bars, ceil(Int, ustrip(As_min / Ab)))
        iseven(n) || (n += 1)
        while n <= 40
            As = n * Ab
            As > As_max && break
            As >= As_min && push!(candidates, (As, size, n))
            n += 2
        end
    end
    sort!(candidates; by = first)
    for (_, size, n) in candidates
        sec = try
            build(size, n)
        catch e
            e isa ArgumentError || rethrow()
            continue
        end
        return sec
    end
    error("No longitudinal layout satisfies ACI 318-11 §10.9.1 and ACI 318-19 §25.2.3 for this column size")
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
Concrete is the column's own `concrete` when set, else
[`column_concrete`](@ref); the second moments of area are
multiplied by `params.column_I_factor` (ACI 318-11 §10.10.4.1). The
rectangular torsion constant is the thin-rectangle series
`β·a·b³`, `β = 1/3 − 0.21 (b/a)(1 − (b/a)⁴/12)`.
"""
function _rc_column_frame_section(col, params::DesignParameters)
    conc = something(col.concrete, column_concrete(params))
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
    _install_sized_column_frame!(struc, params) -> Bool

Put every sized RC column's concrete section on the frame and its
self-weight on the model, then re-solve. Until then a flat-plate frame column
carries the placeholder section `to_asap!` gave it and no self-weight, so
frame `Pu` leaves out the weight of the columns above. The self-weight is at
[`member_self_weight_acceleration`](@ref). Returns `true` when the model was
re-solved.
"""
function _install_sized_column_frame!(struc::BuildingStructure, params::DesignParameters)
    edges = Set{Int}()
    for col in struc.columns
        (isnothing(col.c1) || isnothing(col.c2)) && continue
        _install_column_frame_section!(struc, col, _rc_column_frame_section(col, params))
        for seg_idx in segment_indices(col)
            push!(edges, struc.segments[seg_idx].edge_idx)
        end
    end
    isempty(edges) && return false
    _add_gravity_loads!(struc, edges, member_self_weight_acceleration(params))
    return _resolve_after_column_change!(struc)
end

"""
Re-solve after column sections changed on an unchanged mesh: element
stiffness values only, then solve and refresh the pattern cache. Returns
`true` when the model was processed and solved.
"""
function _resolve_after_column_change!(struc::BuildingStructure)
    struc.asap_model.processed || return false
    Asap.update!(struc.asap_model; values_only=true)
    _solve_struc_model!(struc)
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
    _reconcile_columns!(struc, params) -> (struc=struc, n_reconciled=Int)

Reconcile column sizes after flat-plate slab sizing.

The slab loop designs columns from tributary Pu (single-floor tributary).
For multi-story buildings, Asap model forces may be larger due to load
accumulation from upper floors. The frame first gets each column's concrete
section and self-weight ([`_install_sized_column_frame!`](@ref)). This stage
then grows any column whose
Asap-model axial demand exceeds ACI 318-11 Eq. (10-2) at ρg = 0.01,
using the column concrete and rebar rather than the slab's.

Then [`check_flat_plate_columns!`](@ref) gives every column the lightest
section that passes its full-load strength, its §10.12 joints, and punching.
`floors` is forwarded there: a plan size the slab analysis had to grow a
column back to.

Returns the structure, the number of columns either step grew, whether the
model was re-solved, and the full-load check's summary.
"""
function _reconcile_columns!(
    struc::BuildingStructure,
    params::DesignParameters;
    tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
    floors::Dict{Int, Tuple} = Dict{Int, Tuple}(),
)
    _col_opts = _get_column_opts(params)
    conc = column_concrete(params)
    reb = column_rebar(params)
    grew = 0

    _shape_con = !isnothing(_col_opts) ? _col_opts.shape_constraint : :square
    _max_ar   = !isnothing(_col_opts) ? _col_opts.max_aspect_ratio : 2.0
    _c_inc    = !isnothing(_col_opts) ? _col_opts.size_increment : 0.5u"inch"

    StructuralSizer.emit!(tc, :workflow, "_reconcile_columns!", "", :enter;
                          n_columns=length(struc.columns))

    framed = _install_sized_column_frame!(struc, params)

    for col in struc.columns
        isnothing(col.c1) && continue
        
        Pu_N = _column_asap_Pu(struc, col)
        
        # Check if column needs to grow for axial capacity
        needs_growth = false
        if Pu_N > 0
            # ACI 318-11 Eq. (10-2) at ρg = 0.01. Same expression as the axial check.
            Ag_required = StructuralSizer.tied_column_area_for_axial(
                Pu_N * u"N", conc.fc′; fy = reb.Fy)
            Ag_required_m2 = ustrip(u"m^2", Ag_required)
            c_required = sqrt(Ag_required_m2) * u"m"
            if c_required > col.c1 || c_required > col.c2
                grow_column_for_axial!(col, Ag_required;
                                        shape_constraint=_shape_con, max_ar=_max_ar,
                                        increment=_c_inc)
                grew += 1
                needs_growth = true
            end
        end

        # The slab loop already stored the P-M section. Keep its bars, or
        # redesign only when this column grew, and record concrete and rebar
        # volumes from that section.
        _assign_flat_plate_column_section!(col)
        _set_rc_column_volumes!(
            col,
            something(col.concrete, column_concrete(params)),
            column_rebar(params),
        )
        needs_growth &&
            _install_column_frame_section!(struc, col, _rc_column_frame_section(col, params))
    end

    grew > 0 && @info "Column reconciliation: $grew columns grew from Asap model forces"
    grew > 0 && update_structural_offsets!(struc; input_is_centerline=params.geometry_is_centerline)
    # Self-sync, so the outer pipeline can skip a full sync_asap!.
    synced = (grew > 0 && _resolve_after_column_change!(struc)) || framed

    StructuralSizer.emit!(tc, :workflow, "_reconcile_columns!", "", :decision;
                          outcome = grew > 0 ? "grew_columns" : "no_change",
                          n_reconciled=grew, self_synced=synced)

    full = check_flat_plate_columns!(struc, params; tc, floors)
    synced |= !isempty(full.grown)
    grew += length(full.grown)

    StructuralSizer.emit!(tc, :workflow, "_reconcile_columns!", "", :exit;
                          n_reconciled=grew, self_synced=synced)

    return (struc = struc, n_reconciled = grew, synced = synced, full_load = full)
end





