function _size_slab_groups(groups, slab_specs, struc, material, floor_opts::StructuralSizer.AbstractFloorOptions; col_I_factor::Real = 0.70)  # ACI 318-11 §10.10.4.1
    gids = collect(keys(groups))
    n = length(gids)
    
    results_vec  = Vector{AbstractFloorResult}(undef, n)
    sw_vec       = Vector{typeof(0.0u"kPa")}(undef, n)
    spans_vec    = Vector{SpanInfo}(undef, n)
    mats_vec     = Vector{Concrete}(undef, n)
    
    @inbounds Threads.@threads for k in 1:n
        gid = gids[k]
        spec_idxs = groups[gid]
        specs = slab_specs[spec_idxs]
        result, sw_service, spans_gov, mat_eff = _process_single_slab_group(gid, specs, struc, material, floor_opts; col_I_factor=col_I_factor)
        
        results_vec[k] = result
        sw_vec[k]      = sw_service
        spans_vec[k]   = spans_gov
        mats_vec[k]    = mat_eff
    end
    
    group_results = Dict{UInt64, AbstractFloorResult}(gids[k] => results_vec[k] for k in 1:n)
    group_sw      = Dict{UInt64, typeof(0.0u"kPa")}(gids[k] => sw_vec[k] for k in 1:n)
    group_spans   = Dict{UInt64, SpanInfo}(gids[k] => spans_vec[k] for k in 1:n)
    group_mats    = Dict{UInt64, Concrete}(gids[k] => mats_vec[k] for k in 1:n)

    return group_results, group_sw, group_spans, group_mats
end

"""Size a single slab group: resolve governing demands, call the backend, return `(result, self_weight, spans)`."""
function _process_single_slab_group(gid, specs, struc, material, floor_opts::StructuralSizer.AbstractFloorOptions; col_I_factor::Real = 0.70)  # ACI 318-11 §10.10.4.1
    ft_syms = unique(getfield.(specs, :floor_type))
    length(ft_syms) == 1 || throw(ArgumentError("Slab group $gid has mixed floor types: $(ft_syms)."))

    ft_sym = only(ft_syms)
    ft = StructuralSizer.floor_type(ft_sym)

    if ft isa Vault
        for s in specs
            length(s.cell_indices) == 1 || throw(ArgumentError("Vault slabs must be a single rectangular face; got a slab with $(length(s.cell_indices)) cells in group $gid."))
            cell = struc.cells[only(s.cell_indices)]
            _assert_rectangular_slab_face(struc, cell.face_idx)
        end
    end

    all_spans = [s.spans_gov for s in specs]
    spans_gov = StructuralSizer.governing_spans(all_spans)
    
    sdl_gov = maximum(getfield.(specs, :sdl_gov))
    live_gov = maximum(getfield.(specs, :live_gov))

    span_for_sizing = _sizing_span(ft, spans_gov)

    scoped_opts = unique([s.floor_opts_override for s in specs if hasproperty(s, :floor_opts_override) && !isnothing(s.floor_opts_override)])
    length(scoped_opts) <= 1 || throw(ArgumentError("Slab group $gid has conflicting floor options overrides."))
    effective_floor_opts = isempty(scoped_opts) ? floor_opts : only(scoped_opts)

    scoped_mats = unique([s.material_override for s in specs if hasproperty(s, :material_override) && !isnothing(s.material_override)])
    length(scoped_mats) <= 1 || throw(ArgumentError("Slab group $gid has conflicting material overrides."))
    effective_material = isempty(scoped_mats) ? material : only(scoped_mats)

    effective_floor_opts = _with_concrete_material(effective_floor_opts, effective_material)
    # ACI 318-11 §10.10.4.1 — scoped-override cells inherit the global column cracking factor
    effective_floor_opts = _apply_col_I_factor(effective_floor_opts, col_I_factor)

    extra_kwargs = if ft isa Vault && !(effective_floor_opts isa StructuralSizer.VaultOptions)
        (lambda=10.0,)
    elseif ft isa TwoWay
        # The short reinforcement-axis chord sets β (ACI 318-11 §9.5.3.3).
        (l2 = min(spans_gov.primary, spans_gov.secondary),)
    else
        NamedTuple()
    end
    result = StructuralSizer._size_span_floor(ft, span_for_sizing, sdl_gov, live_gov;
                                               material=effective_material, options=effective_floor_opts, extra_kwargs...)
    sw_service = StructuralSizer.self_weight(result)

    return result, sw_service, spans_gov, effective_material
end

"""Replace concrete grade in floor options while preserving rebar/detail settings."""
function _with_concrete_material(opts::StructuralSizer.FlatPlateOptions, concrete::Concrete)
    rc = ReinforcedConcreteMaterial(concrete, opts.material.rebar, opts.material.transverse)
    return StructuralSizer.FlatPlateOptions(
        material=rc,
        cover=opts.cover,
        bar_size=opts.bar_size,
        has_edge_beam=opts.has_edge_beam,
        edge_beam_βt=opts.edge_beam_βt,
        method=opts.method,
        grouping=opts.grouping,
        φ_flexure=opts.φ_flexure,
        φ_shear=opts.φ_shear,
        λ=opts.λ,
        deflection_limit=opts.deflection_limit,
        punching_strategy=opts.punching_strategy,
        punching_reinforcement=opts.punching_reinforcement,
        max_column_size=opts.max_column_size,
        stud_material=opts.stud_material,
        stud_diameter=opts.stud_diameter,
        stirrup_bar_size=opts.stirrup_bar_size,
        min_h=opts.min_h,
        objective=opts.objective,
        col_I_factor=opts.col_I_factor,
        on_inapplicable=opts.on_inapplicable,
        column_span_minimum=opts.column_span_minimum,
        punching_thickening=opts.punching_thickening)
end

function _with_concrete_material(opts::StructuralSizer.FlatSlabOptions, concrete::Concrete)
    return StructuralSizer.FlatSlabOptions(
        h_drop=opts.h_drop,
        a_drop_ratio=opts.a_drop_ratio,
        base=_with_concrete_material(opts.base, concrete))
end

function _with_concrete_material(opts::StructuralSizer.OneWayOptions, concrete::Concrete)
    rc = ReinforcedConcreteMaterial(concrete, opts.material.rebar, opts.material.transverse)
    return StructuralSizer.OneWayOptions(
        material=rc,
        cover=opts.cover,
        bar_size=opts.bar_size,
        support=opts.support)
end

function _with_concrete_material(opts::StructuralSizer.VaultOptions, concrete::Concrete)
    return StructuralSizer.VaultOptions(
        lambda_bounds=opts.lambda_bounds,
        rise_bounds=opts.rise_bounds,
        thickness_bounds=opts.thickness_bounds,
        rise=opts.rise,
        lambda=opts.lambda,
        thickness=opts.thickness,
        trib_depth=opts.trib_depth,
        rib_depth=opts.rib_depth,
        rib_apex_rise=opts.rib_apex_rise,
        finishing_load=opts.finishing_load,
        allowable_stress=opts.allowable_stress,
        deflection_limit=opts.deflection_limit,
        check_asymmetric=opts.check_asymmetric,
        objective=opts.objective,
        solver=opts.solver,
        n_grid=opts.n_grid,
        n_refine=opts.n_refine,
        method=opts.method,
        material=concrete)
end

_with_concrete_material(opts::StructuralSizer.AbstractFloorOptions, ::Concrete) = opts
