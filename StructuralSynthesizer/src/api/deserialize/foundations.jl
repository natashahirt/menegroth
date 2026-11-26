# Foundation options (optional API overrides → StructuralSizer types)
# =============================================================================

"""Merge optional API spread params into StructuralSizer.SpreadParams. Lengths in API are inches."""
function _api_to_spread_params(api_sp::APISpreadParams, rc::StructuralSizer.ReinforcedConcreteMaterial)
    def = StructuralSizer.SpreadParams(material = rc)
    inch = u"inch"
    StructuralSizer.SpreadParams(
        material = rc,
        cover = api_sp.cover_in !== nothing ? api_sp.cover_in * inch : def.cover,
        min_depth = api_sp.min_depth_in !== nothing ? api_sp.min_depth_in * inch : def.min_depth,
        bar_size = something(api_sp.bar_size, def.bar_size),
        depth_increment = api_sp.depth_increment_in !== nothing ? api_sp.depth_increment_in * inch : def.depth_increment,
        size_increment = api_sp.size_increment_in !== nothing ? api_sp.size_increment_in * inch : def.size_increment,
        pier_shape = def.pier_shape,
        pier_c1 = def.pier_c1,
        pier_c2 = def.pier_c2,
        footing_shape = def.footing_shape,
        ϕ_flexure = def.ϕ_flexure,
        ϕ_shear = def.ϕ_shear,
        ϕ_bearing = def.ϕ_bearing,
        λ = def.λ,
        fc_col = def.fc_col,
        check_bearing = def.check_bearing,
        check_dowels = def.check_dowels,
        check_development = def.check_development,
        objective = def.objective,
    )
end

"""Merge optional API strip params into StructuralSizer.StripParams. Lengths in API are inches."""
function _api_to_strip_params(api_st::APIStripParams, rc::StructuralSizer.ReinforcedConcreteMaterial)
    def = StructuralSizer.StripParams(material = rc)
    inch = u"inch"
    StructuralSizer.StripParams(
        material = rc,
        cover = api_st.cover_in !== nothing ? api_st.cover_in * inch : def.cover,
        min_depth = api_st.min_depth_in !== nothing ? api_st.min_depth_in * inch : def.min_depth,
        bar_size_long = something(api_st.bar_size_long, def.bar_size_long),
        bar_size_trans = something(api_st.bar_size_trans, def.bar_size_trans),
        depth_increment = def.depth_increment,
        width_increment = api_st.width_increment_in !== nothing ? api_st.width_increment_in * inch : def.width_increment,
        max_depth_ratio = something(api_st.max_depth_ratio, def.max_depth_ratio),
        analysis_method = api_st.analysis_method !== nothing ?
            _resolve_strip_analysis_method(api_st.analysis_method) : def.analysis_method,
        ϕ_flexure = def.ϕ_flexure,
        ϕ_shear = def.ϕ_shear,
        ϕ_bearing = def.ϕ_bearing,
        λ = def.λ,
        fc_col = def.fc_col,
        check_development = def.check_development,
        check_bearing = def.check_bearing,
        check_dowels = def.check_dowels,
        merge_gap_factor = something(api_st.merge_gap_factor, def.merge_gap_factor),
        eccentricity_limit = something(api_st.eccentricity_limit, def.eccentricity_limit),
        objective = def.objective,
    )
end

"""Resolve strip/wall analysis_method string to AbstractMatMethod (Shukla is mat-only)."""
function _resolve_strip_analysis_method(s::String)
    am = lowercase(strip(s))
    am == "rigid"   && return StructuralSizer.RigidMat()
    am == "winkler" && return StructuralSizer.WinklerFEA()
    @warn "Unsupported strip/wall analysis_method \"$s\" (use rigid or winkler) — defaulting to rigid"
    return StructuralSizer.RigidMat()
end

"""Resolve mat analysis_method string to AbstractMatMethod."""
function _resolve_mat_analysis_method(s::String)
    am = lowercase(strip(s))
    am == "rigid"   && return StructuralSizer.RigidMat()
    am == "shukla"  && return StructuralSizer.ShuklaAFM()
    am == "winkler" && return StructuralSizer.WinklerFEA()
    @warn "Unknown mat analysis_method \"$s\" — defaulting to rigid"
    return StructuralSizer.RigidMat()
end

"""Merge optional API mat params into StructuralSizer.MatParams. Lengths in API are inches."""
function _api_to_mat_params(api_mat::APIMatParams, rc::StructuralSizer.ReinforcedConcreteMaterial)
    def = StructuralSizer.MatParams(material = rc)
    inch = u"inch"
    method = api_mat.analysis_method !== nothing ?
        _resolve_mat_analysis_method(api_mat.analysis_method) : def.analysis_method
    edge_oh = api_mat.edge_overhang_in !== nothing ? api_mat.edge_overhang_in * inch : def.edge_overhang
    StructuralSizer.MatParams(
        material = rc,
        cover = api_mat.cover_in !== nothing ? api_mat.cover_in * inch : def.cover,
        min_depth = api_mat.min_depth_in !== nothing ? api_mat.min_depth_in * inch : def.min_depth,
        bar_size_x = something(api_mat.bar_size_x, def.bar_size_x),
        bar_size_y = something(api_mat.bar_size_y, def.bar_size_y),
        depth_increment = api_mat.depth_increment_in !== nothing ? api_mat.depth_increment_in * inch : def.depth_increment,
        edge_overhang = edge_oh,
        analysis_method = method,
        ϕ_flexure = def.ϕ_flexure,
        ϕ_shear = def.ϕ_shear,
        λ = def.λ,
        objective = def.objective,
    )
end

"""Build FoundationOptions from API params. Uses foundation_concrete + materials.rebar for RC material."""
function _resolve_foundation_options(api_params::APIParams, fdn_conc::StructuralSizer.Concrete, reb::StructuralSizer.RebarSteel)
    rc = StructuralSizer.ReinforcedConcreteMaterial(fdn_conc, reb)
    def_opts = StructuralSizer.FoundationOptions()
    strategy = def_opts.strategy
    mat_coverage_threshold = def_opts.mat_coverage_threshold
    spread_params = def_opts.spread_params
    strip_params = def_opts.strip_params
    mat_params = def_opts.mat_params

    if api_params.foundation_options !== nothing
        fo = api_params.foundation_options
        raw = strip(fo.strategy)
        strategy = isempty(raw) ? def_opts.strategy : Symbol(lowercase(raw))
        # Explicit mat override — must not fall through to coverage-based logic
        strategy === :mat && @info "Foundation strategy: mat (explicit override)"
        mat_coverage_threshold = fo.mat_coverage_threshold
        if fo.spread_params !== nothing
            spread_params = _api_to_spread_params(fo.spread_params, rc)
        end
        if fo.strip_params !== nothing
            strip_params = _api_to_strip_params(fo.strip_params, rc)
        end
        if fo.mat_params !== nothing
            mat_params = _api_to_mat_params(fo.mat_params, rc)
        end
    else
        # Apply top-level foundation_concrete + rebar to default option blocks
        spread_params = StructuralSizer.SpreadParams(material = rc)
        strip_params = StructuralSizer.StripParams(material = rc)
        mat_params = StructuralSizer.MatParams(material = rc)
    end

    return StructuralSizer.FoundationOptions(
        spread_params = spread_params,
        strip_params = strip_params,
        mat_params = mat_params,
        strategy = strategy,
        mat_coverage_threshold = mat_coverage_threshold,
    )
end
