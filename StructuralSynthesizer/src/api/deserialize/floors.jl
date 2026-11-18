
# ─── Design Parameters ────────────────────────────────────────────────────────

"""
    json_to_params(api_params::APIParams) -> DesignParameters

Convert API parameter block to a `DesignParameters` instance.
"""
function json_to_params(api_params::APIParams, coord_unit_str::String="meters")
    floor_ll_psf = api_params.loads.floor_LL_psf
    roof_ll_psf = something(api_params.loads.roof_LL_psf, floor_ll_psf)
    grade_ll_psf = something(api_params.loads.grade_LL_psf, floor_ll_psf)

    loads = GravityLoads(
        floor_LL  = floor_ll_psf * psf,
        roof_LL   = roof_ll_psf * psf,
        grade_LL  = grade_ll_psf * psf,
        floor_SDL = api_params.loads.floor_SDL_psf * psf,
        roof_SDL  = api_params.loads.roof_SDL_psf * psf,
        wall_SDL  = api_params.loads.wall_SDL_psf * psf,
    )

    conc, reb, stl = _resolve_materials(api_params)
    column_conc = _resolve_concrete_name(api_params.materials.column_concrete)
    # Set column override so resolve_column_concrete(materials) returns column_conc (default 6 ksi)
    column_rc = StructuralSizer.ReinforcedConcreteMaterial(column_conc, reb)
    materials = MaterialOptions(concrete=conc, rebar=reb, steel=stl, column=column_rc)

    floor = _resolve_floor_options(api_params)

    columns = _resolve_column_options(api_params)
    beams = _resolve_beam_options(api_params)
    # Log when beam_type is ignored (slab-only systems do not size beams)
    ft = Symbol(api_params.floor_type)
    if ft in (:flat_plate, :flat_slab) && api_params.beam_type != "steel_w"
        @info "beam_type=\"$(api_params.beam_type)\" is ignored for floor_type=$(ft) (slab-only system)."
    end

    foundation_options = if api_params.size_foundations
        soil = _resolve_soil_name(api_params.foundation_soil)
        fdn_conc = _resolve_concrete_name(api_params.foundation_concrete)
        reb = _resolve_rebar(api_params)
        opts = _resolve_foundation_options(api_params, fdn_conc, reb)
        FoundationParameters(soil = soil, options = opts, concrete = fdn_conc)
    else
        nothing
    end

    display_units_sys = lowercase(api_params.unit_system) == "metric" ? :metric : :imperial
    scoped_overrides = _resolve_scoped_floor_overrides(api_params, coord_unit_str)

    ucs = Symbol(lowercase(strip(api_params.uniform_column_sizing)))

    framing_opts = _resolve_framing_opts(api_params)

    return DesignParameters(
        loads = loads,
        materials = materials,
        floor = floor,
        framing_opts = framing_opts,
        columns = columns,
        beams = beams,
        fire_rating = validate_fire_rating(api_params.fire_rating),
        optimize_for = Symbol(api_params.optimize_for),
        max_iterations = something(api_params.max_iterations, 20),
        foundation_options = foundation_options,
        scoped_floor_overrides = scoped_overrides,
        uniform_column_sizing = ucs,
        geometry_is_centerline = api_params.geometry_is_centerline,
        display_units = DisplayUnits(display_units_sys),
        visualization_target_edge_m = api_params.visualization_target_edge_m,
        skip_visualization = api_params.skip_visualization,
        visualization_detail = api_params.visualization_detail,
    )
end

"""Resolve face-scoped floor overrides from API params (coordinates converted to meters)."""
function _resolve_scoped_floor_overrides(api_params::APIParams, coord_unit_str::String)
    isempty(api_params.scoped_overrides) && return ScopedFloorOverride[]

    coord_unit = parse_unit(coord_unit_str)
    _to_m(x) = ustrip(uconvert(u"m", x * coord_unit))
    out = ScopedFloorOverride[]

    for ov in api_params.scoped_overrides
        ft = Symbol(ov.floor_type)
        method = ov.floor_options.method
        defl = ov.floor_options.deflection_limit
        punch = ov.floor_options.punching_strategy
        target_edge_m = ov.floor_options.target_edge_m
        concrete = isnothing(ov.floor_options.concrete) ? nothing : _resolve_concrete_name(ov.floor_options.concrete)
        λ = ov.floor_options.vault_lambda

        faces_m = Vector{NTuple{3, Float64}}[]
        for poly in ov.faces
            pts = NTuple{3, Float64}[]
            for c in poly
                length(c) < 3 && continue
                push!(pts, (_to_m(c[1]), _to_m(c[2]), _to_m(c[3])))
            end
            length(pts) >= 3 && push!(faces_m, pts)
        end

        push!(out, ScopedFloorOverride(
            floor_type = ft,
            method = method,
            deflection_limit = defl,
            punching_strategy = punch,
            target_edge_m = target_edge_m,
            concrete = concrete,
            vault_lambda = λ,
            faces = faces_m,
        ))
    end

    return out
end
"""Resolve floor options from API params."""
function _resolve_floor_options(api_params::APIParams)
    ft = Symbol(api_params.floor_type)
    method = _resolve_analysis_method(api_params.floor_options)
    defl   = _resolve_deflection_limit(api_params.floor_options.deflection_limit)
    punch  = _resolve_punching_strategy(api_params.floor_options.punching_strategy)

    if ft == :flat_plate
        return StructuralSizer.FlatPlateOptions(
            method=method, deflection_limit=defl, punching_strategy=punch)
    elseif ft == :flat_slab
        return StructuralSizer.FlatSlabOptions(
            base=StructuralSizer.FlatPlateOptions(
                method=method, deflection_limit=defl, punching_strategy=punch))
    elseif ft == :one_way
        return StructuralSizer.OneWayOptions()
    elseif ft == :vault
        λ = something(api_params.floor_options.vault_lambda, DEFAULT_VAULT_LAMBDA)
        return StructuralSizer.VaultOptions(lambda=λ)
    else
        return StructuralSizer.FlatPlateOptions(
            method=method, deflection_limit=defl, punching_strategy=punch)
    end
end

const _ANALYSIS_METHOD_MAP = Dict{String, Function}(
    "DDM"             => () -> StructuralSizer.DDM(),
    "DDM_SIMPLIFIED"  => () -> StructuralSizer.DDM(:simplified),
    "EFM"             => () -> StructuralSizer.EFM(),
    "EFM_HARDY_CROSS" => () -> StructuralSizer.EFM(solver=:hardy_cross),
)

"""Resolve analysis method from floor options. FEA uses target_edge_m when provided (FEA default: adaptive)."""
function _resolve_analysis_method(floor_opts::APIFloorOptions)
    s = uppercase(strip(floor_opts.method))
    if s == "FEA"
        te = isnothing(floor_opts.target_edge_m) ? nothing : floor_opts.target_edge_m * u"m"
        return StructuralSizer.FEA(target_edge=te)
    end
    haskey(_ANALYSIS_METHOD_MAP, s) && return _ANALYSIS_METHOD_MAP[s]()
    @warn "Unknown analysis_method '$(floor_opts.method)' — defaulting to DDM"
    return StructuralSizer.DDM()
end

const _DEFLECTION_LIMIT_MAP = Dict{String, Symbol}(
    "L_240" => :L_240, "L_360" => :L_360, "L_480" => :L_480,
)

"""Resolve deflection limit string to Symbol."""
function _resolve_deflection_limit(s::String)
    key = uppercase(strip(s))
    haskey(_DEFLECTION_LIMIT_MAP, key) && return _DEFLECTION_LIMIT_MAP[key]
    @warn "Unknown deflection_limit '$s' — defaulting to L_360"
    return :L_360
end

const _PUNCHING_STRATEGY_MAP = Dict{String, Symbol}(
    "grow_columns" => :grow_columns,
    "reinforce_last" => :reinforce_last,
    "reinforce_first" => :reinforce_first,
)

"""Resolve punching strategy string to Symbol."""
function _resolve_punching_strategy(s::String)
    key = lowercase(strip(s))
    haskey(_PUNCHING_STRATEGY_MAP, key) && return _PUNCHING_STRATEGY_MAP[key]
    @warn "Unknown punching_strategy '$s' — defaulting to grow_columns"
    return :grow_columns
end
