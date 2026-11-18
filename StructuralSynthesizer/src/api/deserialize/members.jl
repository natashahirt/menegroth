
"""Resolve sizing strategy string to Symbol."""
function _resolve_sizing_strategy(s::String)
    key = lowercase(strip(s))
    key == "nlp" && return :nlp
    key == "discrete" && return :discrete
    key == "mip" && return :discrete  # legacy GH wire value; same as discrete (catalog MIP)
    throw(ArgumentError(
        "Unknown sizing_strategy '$s'; expected \"discrete\", \"nlp\", or legacy \"mip\""))
end

"""Build fc_values [MPa] from PixelFrame options. 1 ksi ≈ 6.895 MPa."""
function _resolve_pixelframe_fc_values(api_params::APIParams)
    ksi_to_MPa = Asap.KSI_TO_PA / 1e6
    opts = api_params.pixelframe_options
    preset = opts !== nothing ? lowercase(strip(opts.fc_preset)) : "standard"

    if preset == "custom" && opts !== nothing &&
       opts.fc_min_ksi !== nothing && opts.fc_max_ksi !== nothing && opts.fc_resolution_ksi !== nothing
        min_ksi = opts.fc_min_ksi
        max_ksi = opts.fc_max_ksi
        res_ksi = max(opts.fc_resolution_ksi, 0.5)
        vals_ksi = collect(min_ksi:res_ksi:max_ksi)
        return Float64.(vals_ksi .* ksi_to_MPa)
    end

    # Presets: fc values in MPa (catalog uses MPa)
    if preset == "low"
        return [21.0, 28.0, 35.0]  # ≈ 3–5 ksi
    elseif preset == "high"
        return [42.0, 50.0, 57.0, 69.0]  # ≈ 6–10 ksi
    elseif preset == "extended"
        return collect(Float64, 28:7:97)  # 4–14 ksi, step 1 ksi
    else
        # standard: 4–8 ksi
        return [28.0, 35.0, 42.0, 50.0, 57.0]
    end
end

"""Resolve column type string to ColumnOptions. Uses column_concrete (default 6 ksi)."""
function _resolve_column_options(api_params::APIParams)
    ct = lowercase(strip(api_params.column_type))
    _, rebar, steel = _resolve_materials(api_params)
    column_conc = _resolve_concrete_name(api_params.materials.column_concrete)
    strat = _resolve_sizing_strategy(api_params.column_sizing_strategy)

    # column_catalog is optional; resolve a safe default by column_type.
    # This prevents defaults from failing validation (e.g. rc_rect + "preferred").
    function _effective_column_catalog_str()
        if api_params.column_catalog !== nothing
            return lowercase(strip(api_params.column_catalog))
        end
        if ct == "rc_rect" || ct == "rc_circular"
            return "standard"
        elseif startswith(ct, "steel_")
            return "preferred"
        else
            return "standard"
        end
    end

    if ct == "pixelframe"
        strat === :discrete || throw(ArgumentError(
            "PixelFrame column sizing requires column_sizing_strategy=\"discrete\""))
        fc_vals = _resolve_pixelframe_fc_values(api_params)
        return StructuralSizer.PixelFrameColumnOptions(
            fc_values = fc_vals .* u"MPa",
        )
    elseif startswith(ct, "rc_")
        shape = ct == "rc_circular" ? :circular : :rect
        catalog_sym = Symbol(_effective_column_catalog_str())
        return StructuralSizer.ConcreteColumnOptions(
            material = column_conc,
            rebar_material = rebar,
            section_shape = shape,
            catalog = catalog_sym,
            sizing_strategy = strat,
            time_limit_sec = something(api_params.mip_time_limit_sec, 30.0),
        )
    elseif startswith(ct, "steel_")
        section_type = if ct == "steel_w"
            :w
        elseif ct == "steel_hss"
            :hss
        elseif ct == "steel_pipe"
            :pipe
        else
            :w  # default
        end
        catalog_sym = Symbol(_effective_column_catalog_str())
        strat === :nlp && !(section_type in (:w, :hss)) && throw(ArgumentError(
            "Steel column NLP sizing supports only steel_w and steel_hss"))
        return StructuralSizer.SteelColumnOptions(
            material = steel,
            section_type = section_type,
            catalog = catalog_sym,
            sizing_strategy = strat,
            time_limit_sec = something(api_params.mip_time_limit_sec, 30.0),
        )
    else
        # Default to RC rectangular
        return StructuralSizer.ConcreteColumnOptions(
            material = column_conc,
            rebar_material = rebar,
            section_shape = :rect
        )
    end
end

# =============================================================================

"""Composite fields for a steel beam option. Empty when composite is off."""
function _composite_beam_fields(api_params::APIParams)
    api_params.composite || return (;)
    inch(x) = x === nothing ? nothing : x * u"inch"
    ksi(x) = x === nothing ? nothing : x * u"ksi"
    return (;
        composite = true,
        composite_slab_type = Symbol(strip(api_params.composite_slab_type)),
        composite_t_slab = inch(api_params.composite_t_slab_in),
        composite_anchor_d = inch(api_params.composite_anchor_d_in),
        composite_anchor_length = inch(api_params.composite_anchor_length_in),
        composite_anchor_Fu = ksi(api_params.composite_anchor_Fu_ksi),
        composite_shored = api_params.composite_shored,
        composite_cp_class = Symbol(strip(api_params.composite_cp_class)),
        composite_deck_hr = inch(api_params.composite_deck_hr_in),
        composite_deck_wr = inch(api_params.composite_deck_wr_in),
        composite_deck_orientation = Symbol(strip(api_params.composite_deck_orientation)),
    )
end

"""Resolve beam type string to BeamOptions."""
function _resolve_beam_options(api_params::APIParams)
    bt = lowercase(strip(api_params.beam_type))
    concrete, rebar, steel = _resolve_materials(api_params)

    catalog = Symbol(api_params.beam_catalog)

    # Build custom catalog from bounds when beam_catalog is "custom".
    custom_cat = nothing
    if catalog === :custom && api_params.beam_catalog_bounds !== nothing
        b = api_params.beam_catalog_bounds
        custom_cat = StructuralSizer.rc_beam_catalog_from_bounds(;
            min_width_in = b.min_width_in,
            max_width_in = b.max_width_in,
            min_depth_in = b.min_depth_in,
            max_depth_in = b.max_depth_in,
            resolution_in = b.resolution_in,
        )
    end

    tlim = something(api_params.mip_time_limit_sec, 30.0)
    strat = _resolve_sizing_strategy(api_params.beam_sizing_strategy)
    if startswith(bt, "steel_")
        section_type = if bt == "steel_w"
            :w
        elseif bt == "steel_hss"
            :hss
        else
            :w  # default
        end
        strat === :nlp && api_params.composite && throw(ArgumentError(
            "Composite steel beam sizing requires beam_sizing_strategy=\"discrete\""))
        return StructuralSizer.SteelBeamOptions(;
            material = steel,
            section_type = section_type,
            sizing_strategy = strat,
            time_limit_sec = tlim,
            _composite_beam_fields(api_params)...,
        )
    elseif bt == "rc_rect"
        strat === :discrete || throw(ArgumentError(
            "RC beam sizing requires beam_sizing_strategy=\"discrete\""))
        return StructuralSizer.ConcreteBeamOptions(
            material = concrete,
            rebar_material = rebar,
            include_flange = false,
            catalog = catalog === :custom ? :standard : catalog,
            custom_catalog = custom_cat,
            sizing_strategy = strat,
            time_limit_sec = tlim,
        )
    elseif bt == "rc_tbeam"
        strat === :discrete || throw(ArgumentError(
            "RC T-beam sizing requires beam_sizing_strategy=\"discrete\""))
        return StructuralSizer.ConcreteBeamOptions(
            material = concrete,
            rebar_material = rebar,
            include_flange = true,
            catalog = catalog === :custom ? :standard : catalog,
            custom_catalog = custom_cat,
            sizing_strategy = strat,
            time_limit_sec = tlim,
        )
    elseif bt == "pixelframe"
        strat === :discrete || throw(ArgumentError(
            "PixelFrame beam sizing requires beam_sizing_strategy=\"discrete\""))
        fc_vals = _resolve_pixelframe_fc_values(api_params)
        return StructuralSizer.PixelFrameBeamOptions(
            fc_values = fc_vals .* u"MPa",
        )
    else
        # Default to steel W-shape
        return StructuralSizer.SteelBeamOptions(;
            material = steel,
            section_type = :w,
            _composite_beam_fields(api_params)...,
        )
    end
end
