# =============================================================================
# Member Sizing Orchestrator
# =============================================================================

"""
    size_members!(struc; beam_opts=nothing, column_opts=nothing, ...)

Top-level orchestrator that sizes beams, columns, and struts.

Dispatches automatically to `size_beams!` and `size_columns!` based on
the options types.  Options fall back to `struc.design_parameters` if not
provided explicitly.

Note: `BuildingStructure` has no `design_parameters` field as of this writing
(see `building_types/structure.jl`), so the `struc.design_parameters` fallback is
an inert backstop kept for a future harness-gated addition of the field.

# Example
```julia
size_members!(struc;
    beam_opts   = SteelBeamOptions(deflection_limit = 1/360),
    column_opts = ConcreteColumnOptions(material = NWC_5000),
)
```
"""
function size_members!(
    struc::BuildingStructure;
    beam_opts::Union{StructuralSizer.BeamOptions, Nothing} = nothing,
    column_opts::Union{StructuralSizer.ColumnOptions, Nothing} = nothing,
    beam_method::Symbol = :discrete,
    column_method::Symbol = :discrete,
    resolution::Int = 200,
    reanalyze::Bool = false,   # defer re-analysis to end
    gravity_factor::Quantity = GRAVITY,
)
    # Size beams
    size_beams!(struc, beam_opts;
        method = beam_method,
        resolution, reanalyze = false, gravity_factor)

    # Size columns
    size_columns!(struc, column_opts;
        resolution, reanalyze = false, gravity_factor)

    # Single re-analysis after both member types are sized
    if reanalyze
        Asap.process!(struc.asap_model)
        _solve_struc_model!(struc)
    end

    return struc
end

# =============================================================================
# Multi-Material Column Sizing
# =============================================================================

"""
    size_columns!(struc::BuildingStructure)
    size_columns!(struc::BuildingStructure, opts::SteelColumnOptions)
    size_columns!(struc::BuildingStructure, opts::ConcreteColumnOptions)

Size columns using discrete MIP optimization.

If no options are provided, uses `struc.design_parameters.columns` if set,
otherwise defaults to `SteelColumnOptions()`.

Note: `BuildingStructure` has no `design_parameters` field as of this writing
(see `building_types/structure.jl`), so the `struc.design_parameters` fallback (and
the assignment shown in the example below) is an inert backstop kept for a future
harness-gated addition of the field.

# Example
```julia
# Use design parameters (recommended)
struc.design_parameters = DesignParameters(
    columns = ConcreteColumnOptions(material = NWC_5000),
)
size_columns!(struc)

# Or pass options directly
size_columns!(struc, SteelColumnOptions(section_type = :hss))
size_columns!(struc, ConcreteColumnOptions(max_depth = 0.6))
```
"""
function size_columns!(
    struc::BuildingStructure,
    opts::Union{StructuralSizer.ColumnOptions, Nothing} = nothing;
    resolution::Int = 200,
    reanalyze::Bool = true,
    gravity_factor::Quantity = GRAVITY,
    # ACI 318-11 §10.10.4.1 — cracked-stiffness reduction factor applied to concrete
    # column sections only (threaded from params.column_I_factor by the design workflow).
    # Default 0.70 keeps callers that do not pass it byte-identical.
    I_factor::Real = 0.70,
    tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
)
    # NOTE: as of this writing `BuildingStructure` has NO `design_parameters` field
    # (see building_types/structure.jl), so `hasproperty(...)` is always false and `dp`
    # is `nothing` here; the `dp`-based fallbacks below are an INERT backstop kept for a
    # future harness-gated addition of the field.
    dp = (hasproperty(struc, :design_parameters) && !isnothing(struc.design_parameters)) ?
         struc.design_parameters : nothing

    effective_opts = if !isnothing(opts)
        opts
    elseif !isnothing(dp) && !isnothing(dp.columns)
        dp.columns
    else
        obj = !isnothing(dp) ? resolve_objective(dp.optimize_for) : StructuralSizer.MinWeight()
        StructuralSizer.SteelColumnOptions(objective=obj)
    end

    StructuralSizer.emit!(tc, :sizing, "size_columns!", "", :enter;
                          opts_type=string(typeof(effective_opts)))

    if !isnothing(dp) && dp.collinear_grouping
        group_collinear_members!(struc; member_type=:columns)
    end
    
    result = _size_columns_impl!(struc, effective_opts; resolution, reanalyze, gravity_factor, I_factor)
    StructuralSizer.emit!(tc, :sizing, "size_columns!", "", :exit)
    return result
end

# Steel implementation
function _size_columns_impl!(
    struc::BuildingStructure,
    opts::StructuralSizer.SteelColumnOptions;
    resolution::Int,
    reanalyze::Bool,
    gravity_factor::Quantity,
    # Accepted for the uniform `size_columns!` dispatch but inert here: the cracked-stiffness
    # I_factor (ACI 318-11 §10.10.4.1) applies to concrete sections only, and this is the
    # steel path (_apply_column_results! is called with material_type=:steel, which never
    # passes I_factor to to_asap_section).
    I_factor::Real = 0.70,
)
    skel = struc.skeleton
    member_edge_group = :columns
    edge_ids_in_group = Set(get(skel.groups_edges, member_edge_group, Int[]))
    
    # Add gravity loads
    _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)
    
    # Get group demands
    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        member_group_demands(struc; member_edge_group=member_edge_group, resolution=resolution)
    
    # Build geometries
    geometries = [StructuralSizer.SteelMemberGeometry(L; Lb=Lb, Cb=Cb, Kx=Kx, Ky=Ky)
                  for (L, Lb, Cb, Kx, Ky) in zip(L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs)]
    
    # Extract demands (N, N*m for steel).
    # AISC 360-16 §H1.1 compression (corpus: aisc-360-16, page 133) uses Pu_c.
    # §H1.2 tension (page 134) uses Pu_t. Mux_neg on column groups equals Mux.
    Pu = [d.Pu_c for d in demands]
    Pu_t = [d.Pu_t for d in demands]
    Mux = [d.Mux for d in demands]
    Muy = [d.Muy for d in demands]

    result = StructuralSizer.size_columns(Pu, Mux, geometries, opts; Muy=Muy, Pu_t=Pu_t)
    
    # Apply results
    _apply_column_results!(struc, result, group_ids, opts.material, :steel, edge_ids_in_group)
    
    if reanalyze
        Asap.process!(struc.asap_model)
        _solve_struc_model!(struc)
    end
    
    @info "Sized $(length(group_ids)) column groups" material="steel" section_type=opts.section_type
    return struc
end

"""
One `RCColumnDemandSet` per column group.

The envelope row and every pattern case are both included, each also with the
two section axes swapped. Below the balance point a case with the same moment
and less compression can govern, and the model does not record which global
direction bends the section about its strong axis.
"""
function _rc_column_demand_sets(opts, demands, case_rows)
    kipft = Asap.kip * u"ft"
    to_kipft(M) = ustrip(uconvert(kipft, M * u"N*m"))
    rc_row(i, d, Pu, Mux, Muy, M1x, M2x, M1y, M2y) = StructuralSizer.RCColumnDemand(i;
        Pu  = ustrip(uconvert(Asap.kip, Pu * u"N")),
        Mux = to_kipft(Mux), Muy = to_kipft(Muy),
        M1x = to_kipft(M1x), M2x = to_kipft(M2x),
        M1y = to_kipft(M1y), M2y = to_kipft(M2y),
        βdns = opts.βdns,
        transverse_load = d.transverse_load,
    )
    both(i, d, Pu, Mux, Muy, M1x, M2x, M1y, M2y) =
        (rc_row(i, d, Pu, Mux, Muy, M1x, M2x, M1y, M2y),
         rc_row(i, d, Pu, Muy, Mux, M1y, M2y, M1x, M2x))
    return map(enumerate(demands)) do (i, d)
        cases = collect(both(i, d, d.Pu_c, d.Mux, d.Muy, d.M1x, d.M2x, d.M1y, d.M2y))
        for r in case_rows[i]
            append!(cases, both(i, d, r.Pu_c, r.Mux, r.Muy, r.M1x, r.M2x, r.M1y, r.M2y))
        end
        StructuralSizer.RCColumnDemandSet(i, cases)
    end
end

# Concrete implementation
function _size_columns_impl!(
    struc::BuildingStructure,
    opts::StructuralSizer.ConcreteColumnOptions;
    resolution::Int,
    reanalyze::Bool,
    gravity_factor::Quantity,
    # ACI 318-11 §10.10.4.1 — cracked-stiffness reduction for concrete column sections,
    # threaded from params.column_I_factor (default 0.70).
    I_factor::Real = 0.70,
)
    skel = struc.skeleton
    member_edge_group = :columns
    edge_ids_in_group = Set(get(skel.groups_edges, member_edge_group, Int[]))

    _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)

    case_rows = Vector{ColumnCaseRow}[]
    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        member_group_demands(struc; member_edge_group=member_edge_group, resolution=resolution,
                             case_rows=case_rows)

    # Concrete columns now carry per-axis effective length factors so the ACI
    # 318 slenderness check evaluates the strong (kx, h, b·h³/12) and weak
    # (ky, b, h·b³/12) axes independently. Previously both axes collapsed
    # onto Ky, which silently lost the strong-axis bracing information.
    geometries = [StructuralSizer.ConcreteMemberGeometry(L; Lu=Lb, kx=Kx, ky=Ky)
                  for (L, Lb, Kx, Ky) in zip(L_totals, Lb_govs, Kx_govs, Ky_govs)]

    # Build RC demands directly from the analysis output. `member_group_demands`
    # already populated `M1x/M2x/M1y/M2y` from FEA at the column ends in
    # ACI 318-19 sign convention. We just need to re-unit SI → ACI (kip,
    # kip·ft) before constructing `RCColumnDemand`s; the demand-driven
    # `size_columns` overload preserves the signed end moments end-to-end so
    # the slenderness path can compute `Cm = 0.6 − 0.4·(M1/M2)` instead of
    # the conservative `M1 = 0` stand-in.
    #
    # Each group is checked against the envelope and against every pattern
    # case on its own, including the NLP path. Below the balance point, less
    # compression means less moment capacity, so the envelope (max P with
    # max M) can pass a section that fails a case with the same moment and
    # lower axial load.
    rc_demands = _rc_column_demand_sets(opts, demands, case_rows)

    has_floor = any(gid -> haskey(struc.frame_section_floors, gid), group_ids)
    if has_floor
        # NLP has no catalog, so it cannot keep a section floor.
        (opts.sizing_strategy !== :nlp && opts.materials === nothing &&
         opts.n_max_sections == 0) ||
            _refuse_frame_floors(struc, group_ids, "this concrete column sizing")
    end
    # A section floor indexes one catalog, so growth happens here and the
    # explicit catalog turns off the growth inside `size_columns`. With no
    # floor, `size_columns` grows a soft named catalog itself.
    tier = (has_floor && opts.catalog_constraint === :soft &&
            opts.custom_catalog === nothing) ? opts.catalog : nothing
    cat = has_floor ?
        (isnothing(opts.custom_catalog) ?
            StructuralSizer.rc_column_catalog(opts.section_shape, opts.catalog) :
            opts.custom_catalog) : nothing
    obj = s -> StructuralSizer.objective_value(opts.objective, s, opts.material, 1.0u"m")
    result = nothing
    while true
        floor_kw = has_floor ?
            (; catalog = cat,
              feasible = _frame_floor_mask(struc, group_ids, cat, obj)) : (;)
        try
            result = StructuralSizer.size_columns(rc_demands, geometries, opts; floor_kw...)
            break
        catch e
            grown = tier isa Symbol ?
                StructuralSizer.grow_rc_column_catalog(cat, opts.section_shape, tier) :
                nothing
            (grown !== nothing && e isa ArgumentError &&
                startswith(e.msg, "No feasible sections for group")) || rethrow()
            cat, nxt = grown
            depth_in = round(Int, maximum(s -> s isa StructuralSizer.RCCircularSection ?
                ustrip(u"inch", s.D) : ustrip(u"inch", max(s.b, s.h)), cat))
            @warn "RC column sizing: no section in the :$tier catalog passes the section floor; " *
                  "retrying with :$nxt added (sizes to $(depth_in) in)." reason = e.msg
            tier = nxt
        end
    end

    _apply_column_results!(struc, result, group_ids, opts.material, :concrete, edge_ids_in_group;
                           I_factor=I_factor, rebar=opts.rebar_material)

    if reanalyze
        Asap.process!(struc.asap_model)
        _solve_struc_model!(struc)
    end

    @info "Sized $(length(group_ids)) column groups" material=StructuralSizer.material_name(opts.material)
    return struc
end

# PixelFrame column implementation
function _size_columns_impl!(
    struc::BuildingStructure,
    opts::StructuralSizer.PixelFrameColumnOptions;
    resolution::Int,
    reanalyze::Bool,
    gravity_factor::Quantity,
    # Accepted for the uniform `size_columns!` dispatch but inert here: this PixelFrame path
    # builds its own ASAP sections (ACI 318-11 §10.10.4.1 cracked-stiffness factor is applied
    # internally by its own to_asap_section call), so the column I_factor is unused.
    I_factor::Real = 0.70,
)
    skel = struc.skeleton
    member_edge_group = :columns
    edge_ids_in_group = Set(get(skel.groups_edges, member_edge_group, Int[]))

    # Add gravity loads
    _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)

    # Get group demands
    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        member_group_demands(struc; member_edge_group=member_edge_group, resolution=resolution)

    isempty(group_ids) && return struc

    member_array = struc.columns

    # Build demand vectors with Unitful SI units
    Pu  = [d.Pu_c * u"N"    for d in demands]
    Mux = [d.Mux * u"N*m"   for d in demands]
    Muy = [d.Muy * u"N*m"   for d in demands]

    # PixelFrame columns are graded by pixel material, but slenderness still
    # uses ACI 318 mechanics. Carry per-axis kx/ky so weak-axis Muy magnification
    # uses (ky, b, h·b³/12) instead of the strong-axis dimensions.
    geometries = [StructuralSizer.ConcreteMemberGeometry(L; Lu=Lb, kx=Kx, ky=Ky)
                  for (L, Lb, Kx, Ky) in zip(L_totals, Lb_govs, Kx_govs, Ky_govs)]

    # Call PixelFrame column sizing (validates pixel divisibility, runs MIP)
    result = StructuralSizer.size_columns(Pu, Mux, geometries, opts; Muy=Muy)

    # Build per-pixel material pool from catalog
    cat = if !isnothing(opts.custom_catalog)
        opts.custom_catalog
    else
        StructuralSizer.generate_pixelframe_catalog(;
            StructuralSizer._pf_catalog_kwargs(opts)...)
    end
    material_pool = unique(s.material for s in cat)

    # Build checker for per-pixel assignment
    checker = StructuralSizer.PixelFrameChecker(;
        StructuralSizer._pf_checker_kwargs(opts)...)

    # Strip pixel length to mm at the boundary
    px_mm = StructuralSizer._pf_pixel_mm(opts)

    # Apply results to member groups + ASAP elements + individual members
    for (g_idx, gid) in enumerate(group_ids)
        chosen = result.sections[g_idx]
        n_px = result.n_pixels[g_idx]

        mg = struc.member_groups[gid]
        mg.section = chosen

        # Build ASAP section for FEA stiffness update
        asap_sec = StructuralSizer.to_asap_section(chosen)

        # Build uniform pixel demands (same demand for all pixels in this group)
        pixel_demands = [demands[g_idx] for _ in 1:n_px]

        # Build PixelFrameDesign with per-pixel material assignment
        design = StructuralSizer.build_pixel_design(
            chosen,
            L_totals[g_idx] * u"m",
            px_mm,
            pixel_demands,
            material_pool,
            checker,
        )

        for m_idx in mg.member_indices
            m = member_array[m_idx]

            L_raw = sum(struc.segments[i].L for i in segment_indices(m))
            L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
            set_section!(m, chosen)
            set_pixel_design!(m, design)

            # Compute volumes from per-pixel material assignment
            pv = StructuralSizer.pixel_volumes(design)
            vols = MaterialVolumes()
            for (mat, vol) in pv
                vols[mat] = vol
            end
            set_volumes!(m, vols)

            # Update ASAP elements
            for seg_idx in segment_indices(m)
                edge_idx = struc.segments[seg_idx].edge_idx
                edge_idx in edge_ids_in_group || continue
            struc.asap_model.frame_elements[edge_idx].section = asap_sec
            end
        end
    end

    if reanalyze
        Asap.process!(struc.asap_model)
        _solve_struc_model!(struc)
    end

    n_total = length(group_ids)
    λs = join(string.(opts.λ_values), ",")
    @info "Sized $n_total PixelFrame column groups via MIP" layups=λs pixel_mm=StructuralSizer._pf_pixel_mm(opts)

    return struc
end

"""Add self-weight `GravityLoad`s to ASAP elements in the given edge group."""
function _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)
    existing_gravity_ids = Set{UInt}()
    for load in struc.asap_model.loads
        if isa(load, Asap.GravityLoad)
            push!(existing_gravity_ids, objectid(load.element))
        end
    end
    
    for edge_idx in edge_ids_in_group
        el = struc.asap_model.frame_elements[edge_idx]
        objectid(el) in existing_gravity_ids && continue
        push!(struc.asap_model.loads, Asap.GravityLoad(el, gravity_factor))
    end
end

# Helper: apply optimization results
"""
    _apply_column_results!(struc, result, group_ids, material, material_type, edge_ids_in_group; I_factor)

Apply sized sections to column member groups, members, and ASAP elements.

When the result comes from multi-material optimization (`hasproperty(result, :materials_chosen)`),
each group uses its own material from `result.materials_chosen[g_idx]`. Otherwise, the single
`material` argument is used for all groups.
"""
function _apply_column_results!(struc, result, group_ids, material, material_type, edge_ids_in_group;
                                 I_factor::Real = 0.70, rebar=nothing)
    # NLP success is :nlp_complete only, and only when every column passed
    # the as-built check. Any other Symbol status is not a completed design.
    # Discrete MIP results use a MathOptInterface status and still apply.
    if !StructuralSizer._rc_nlp_result_installable(result)
        @warn "Column sizing result is not a completed design; leaving the building unchanged" status=result.status
        return
    end
    member_array = struc.columns
    has_multi_mat = hasproperty(result, :materials_chosen)
    
    for (g_idx, gid) in enumerate(group_ids)
        chosen = result.sections[g_idx]
        group_mat = has_multi_mat ? result.materials_chosen[g_idx] : material
        
        mg = struc.member_groups[gid]
        mg.section = chosen
        
        # I_factor applies to concrete sections only (ACI 318-11 §10.10.4.1); the Metal
        # to_asap_section overloads take no such kwarg, so branch PER GROUP on the chosen
        # material. In a multi-material result `group_mat` can vary per group, so a
        # function-level `material_type` test would misroute a steel group under a
        # concrete result (MethodError) or skip the factor on a concrete group under a
        # steel result — mirror `_apply_beam_results!` and decide per group instead.
        asap_sec = if group_mat isa StructuralSizer.Concrete
            StructuralSizer.to_asap_section(chosen, group_mat; I_factor=I_factor)
        else
            StructuralSizer.to_asap_section(chosen, group_mat)
        end
        
        for m_idx in mg.member_indices
            m = member_array[m_idx]
            
            # Compute total length
            L_raw = sum(struc.segments[i].L for i in segment_indices(m))
            L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
            
            set_section!(m, chosen)
            _record_member_check!(m, chosen, result, g_idx)
            set_volumes!(m, member_material_volumes(chosen, L_total, group_mat; rebar=rebar))
            # Plan size follows the installed RC section; harmonization,
            # offsets and reports read c1/c2.
            if chosen isa StructuralSizer.RCColumnSection ||
               chosen isa StructuralSizer.RCCircularSection
                bb = StructuralSizer.bounding_box(chosen)
                m.c1 = bb.width
                m.c2 = bb.depth
            end
            
            # Update ASAP elements
            for seg_idx in segment_indices(m)
                edge_idx = struc.segments[seg_idx].edge_idx
                edge_idx in edge_ids_in_group || continue
                struc.asap_model.frame_elements[edge_idx].section = asap_sec
            end
        end
    end
end

# =============================================================================
# Initial Column Size Estimation
# =============================================================================

"""
    estimate_column_sizes!(struc; fc=4000u"psi", qu_default=200psf, method=:tributary,
                           input_is_centerline=false, start=:span, max_size=nothing)

Estimate initial column sizes and store in Column.c1, Column.c2.

This provides preliminary column dimensions needed for slab clear span calculation
(ln = l - c) before full column design. The estimate is intentionally conservative.

After sizing, calls `update_structural_offsets!` to record boundary normals.
Column centers stay on the skeleton vertices.

# Arguments
- `struc`: BuildingStructure with columns and tributary areas computed
- `fc`: Concrete compressive strength (default 4000 psi)
- `qu_default`: Default factored floor load if not available from cells (default 200 psf)
- `method`: :tributary (from Voronoi area) or :span (from span rule of thumb)
- `input_is_centerline`: forwarded to `update_structural_offsets!`. Column centers stay on the vertices either way.
- `start`: `:span` sizes for axial load and at least span/15 (StructurePoint).
  `:axial` sizes for axial load only, with a 14" minimum. Column sizing only
  grows, so the start is the smallest column the design can return; `:axial`
  leaves punching growth to the slab loop.
- `max_size`: the floor's column cap. The estimate never starts above it,
  so the cap is not silently raised to the estimate.

# Requires
- Columns initialized with `initialize_members!()`
- Tributary areas computed with `compute_column_tributaries!()`

# Effects
- Sets `col.c1` and `col.c2` for each column
- Uses square columns (c1 = c2) for interior
- May use rectangular (c2 = 1.5 × c1) for edge columns

# Example
```julia
initialize!(struc; floor_type=:flat_plate, ...)
compute_column_tributaries!(struc)  # Usually called by initialize!
estimate_column_sizes!(struc; fc=5000u"psi")

# Now columns have c1, c2 set
for col in struc.columns
    println("Column at story \$(col.story): \$(col.c1) × \$(col.c2)")
end
```
"""
function estimate_column_sizes!(struc::BuildingStructure;
                                 fc::Unitful.Pressure = 4000u"psi",
                                 qu_default::Unitful.Pressure = 200psf,
                                 method::Symbol = :tributary,
                                 input_is_centerline::Bool = false,
                                 start::Symbol = :span,
                                 max_size::Union{Nothing, Unitful.Length} = nothing)
    start in (:span, :axial) ||
        throw(ArgumentError("start must be :span or :axial, got $(start)"))
    c_axial_min = 14.0u"inch"
    skel = struc.skeleton
    n_total_stories = length(skel.stories_z) - 1  # stories_z includes ground (0)
    
    if n_total_stories < 1
        @warn "No stories found in skeleton, cannot estimate column sizes"
        return struc
    end
    
    estimated_count = 0
    
    # Get average span for punching-based column sizing (flat plate design)
    avg_span = _estimate_avg_span(skel)
    
    for col in struc.columns
        # Number of stories above this column
        n_above = n_total_stories - col.story
        n_above = max(n_above, 1)  # At least 1 (supports at least 1 floor)
        
        if method == :tributary
            # Get tributary area (already Unitful from cache)
            At = column_tributary_area(struc, col)
            
            if isnothing(At) || ustrip(u"m^2", At) <= 0
                # Fall back to span-based estimate, or the minimum for :axial
                c = start === :axial ? c_axial_min :
                    StructuralSizer.estimate_column_size_from_span(avg_span)
                col.c1 = c
                col.c2 = c
            else
                # Get average load from adjacent cells
                qu = _get_column_load_intensity(struc, col, qu_default)
                
                # Estimate column size considering both axial load AND punching shear
                # Pass span for punching-based minimum (c ≥ span/15 per StructurePoint)
                c = start === :axial ?
                    StructuralSizer.estimate_column_size(At, qu, n_above, fc;
                                                         min_size=c_axial_min) :
                    StructuralSizer.estimate_column_size(At, qu, n_above, fc; span=avg_span)
                
                # Rectangular for edge/corner columns (optional)
                if col.position == :interior
                    col.c1 = c
                    col.c2 = c
                else
                    # Edge/corner: use rectangular (c2 = c, c1 = c/1.2)
                    # This gives better punching shear capacity at edges
                    col.c1 = c
                    col.c2 = c
                end
            end
        else  # method == :span
            c = StructuralSizer.estimate_column_size_from_span(avg_span)
            col.c1 = c
            col.c2 = c
        end

        if !isnothing(max_size)
            col.c1 = min(col.c1, max_size)
            col.c2 = min(col.c2, max_size)
        end

        estimated_count += 1
    end
    
    @info "Estimated initial column sizes" method=method columns=estimated_count fc=fc

    # Compute structural offsets now that column dimensions are available.
    update_structural_offsets!(struc; input_is_centerline=input_is_centerline)

    return struc
end

"""Get average span from skeleton for span-based column estimate."""
function _estimate_avg_span(skel::BuildingSkeleton)
    isempty(skel.edges) && return 20u"ft"
    
    vc = skel.geometry.vertex_coords
    total_len = 0.0u"m"
    n = 0
    
    for (e_idx, (v1, v2)) in enumerate(skel.edge_indices)
        abs(vc[v1, 3] - vc[v2, 3]) < 0.1 || continue  # horizontal only
        total_len += edge_length(skel, e_idx)
        n += 1
    end
    
    return n > 0 ? total_len / n : 20u"ft"
end

"""
    _get_column_load_intensity(struc, col, qu_default; combo=default_combo) -> PressureQuantity

Get area-weighted factored load intensity for a column from adjacent cells.

Uses `total_factored_pressure(cell, combo)` which includes SDL, live load,
AND slab self-weight, factored per the given load combination.

Note: Cell self-weight is populated during slab sizing via `initialize_slabs!`.
If called before slab sizing, self-weight will be zero.
"""
function _get_column_load_intensity(struc::BuildingStructure, col, qu_default;
                                    combo::LoadCombination = default_combo)
    by_cell = column_tributary_by_cell(struc, col)
    
    if isnothing(by_cell) || isempty(by_cell)
        return qu_default
    end
    
    total_load = 0.0u"kN"
    total_area = 0.0u"m^2"
    
    for (cell_idx, area) in by_cell
        if cell_idx <= length(struc.cells)
            cell = struc.cells[cell_idx]
            qu = total_factored_pressure(cell, combo)
            total_load += qu * area
            total_area += area
        end
    end
    
    return total_area > 0u"m^2" ? total_load / total_area : qu_default
end
