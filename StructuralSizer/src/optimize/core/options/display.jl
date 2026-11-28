# ==============================================================================
# Display
# ==============================================================================

"""Compact display for `SteelColumnOptions`."""
function Base.show(io::IO, opts::SteelColumnOptions)
    mat_str = material_name(opts.material)
    sec_type = uppercase(string(opts.section_type))
    strat_str = opts.sizing_strategy == :nlp ? " NLP" : ""
    print(io, "SteelColumnOptions(", mat_str, " ", sec_type, strat_str)
    isfinite(opts.max_depth) && print(io, ", max_depth=", opts.max_depth)
    opts.n_max_sections > 0 && print(io, ", n_max=", opts.n_max_sections)
    print(io, ")")
end

"""Compact display for `SteelBeamOptions`."""
function Base.show(io::IO, opts::SteelBeamOptions)
    mat_str = material_name(opts.material)
    sec_type = uppercase(string(opts.section_type))
    strat_str = opts.sizing_strategy == :nlp ? " NLP" : ""
    print(io, "SteelBeamOptions(", mat_str, " ", sec_type, strat_str)
    isfinite(opts.max_depth) && print(io, ", max_depth=", opts.max_depth)
    dl = _deflection_limit(opts)
    !isnothing(dl) && print(io, ", L/", Int(round(1/dl)))
    tdl = _total_deflection_limit(opts)
    !isnothing(tdl) && print(io, ", L_total/", Int(round(1/tdl)))
    opts.composite && print(io, ", composite")
    opts.n_max_sections > 0 && print(io, ", n_max=", opts.n_max_sections)
    print(io, ")")
end

"""Compact display for `ConcreteColumnOptions`."""
function Base.show(io::IO, opts::ConcreteColumnOptions)
    mat_str = material_name(opts.material)
    shape_str = opts.section_shape == :circular ? "CIRCULAR" : "RECT"
    strat_str = opts.sizing_strategy == :nlp ? " NLP" : ""
    print(io, "ConcreteColumnOptions(", mat_str, " ", shape_str, strat_str)
    isfinite(opts.max_depth) && print(io, ", max_depth=", opts.max_depth)
    opts.n_max_sections > 0 && print(io, ", n_max=", opts.n_max_sections)
    !opts.include_slenderness && print(io, ", no_slenderness")
    !opts.include_biaxial && print(io, ", no_biaxial")
    print(io, ")")
end

"""Compact display for `ConcreteBeamOptions`."""
function Base.show(io::IO, opts::ConcreteBeamOptions)
    mat_str = material_name(opts.material)
    strat_str = opts.sizing_strategy == :nlp ? " NLP" : ""
    print(io, "ConcreteBeamOptions(", mat_str, strat_str)
    isfinite(opts.max_depth) && print(io, ", max_depth=", opts.max_depth)
    isfinite(opts.max_width) && print(io, ", max_width=", opts.max_width)
    if !isnothing(opts.deflection_limit)
        print(io, ", L/", Int(round(1/opts.deflection_limit)))
    end
    opts.include_flange && print(io, ", T-beam")
    opts.n_max_sections > 0 && print(io, ", n_max=", opts.n_max_sections)
    print(io, ")")
end

"""Compact display for `PixelFrameBeamOptions`."""
function Base.show(io::IO, opts::PixelFrameBeamOptions)
    n_fc = length(opts.fc_values)
    λs = join(string.(opts.λ_values), ",")
    px_mm = _to_mm(opts.pixel_length)
    print(io, "PixelFrameBeamOptions(λ=[", λs, "], fc=", n_fc, " grades")
    print(io, ", px=", Int(px_mm), "mm")
    !isnothing(opts.deflection_limit) && print(io, ", L/", Int(round(1/opts.deflection_limit)))
    d_mm = _to_mm(opts.min_depth); w_mm = _to_mm(opts.min_width)
    (d_mm > 0 || w_mm > 0) && print(io, ", min_bbox=", d_mm, "×", w_mm, "mm")
    opts.n_max_sections > 0 && print(io, ", n_max=", opts.n_max_sections)
    print(io, ")")
end

"""Compact display for `PixelFrameColumnOptions`."""
function Base.show(io::IO, opts::PixelFrameColumnOptions)
    n_fc = length(opts.fc_values)
    λs = join(string.(opts.λ_values), ",")
    px_mm = _to_mm(opts.pixel_length)
    print(io, "PixelFrameColumnOptions(λ=[", λs, "], fc=", n_fc, " grades")
    print(io, ", px=", Int(px_mm), "mm")
    d_mm = _to_mm(opts.min_depth); w_mm = _to_mm(opts.min_width)
    (d_mm > 0 || w_mm > 0) && print(io, ", min_bbox=", d_mm, "×", w_mm, "mm")
    opts.n_max_sections > 0 && print(io, ", n_max=", opts.n_max_sections)
    print(io, ")")
end

"""Compact display for `NLPColumnOptions`."""
function Base.show(io::IO, opts::NLPColumnOptions)
    mat_str = material_name(opts.material)
    min_in = round(Int, ustrip(u"inch", opts.min_dim))
    max_in = round(Int, ustrip(u"inch", opts.max_dim))
    print(io, "NLPColumnOptions(", mat_str)
    print(io, ", dims=", min_in, "\"-", max_in, "\"")
    opts.aspect_limit < 3.0 && print(io, ", aspect≤", opts.aspect_limit)
    opts.prefer_square > 0 && print(io, ", prefer_square")
    !opts.include_slenderness && print(io, ", no_slenderness")
    print(io, ", solver=:", opts.solver, ")")
end

"""Compact display for `NLPHSSOptions`."""
function Base.show(io::IO, opts::NLPHSSOptions)
    mat_str = material_name(opts.material)
    min_in = round(ustrip(u"inch", opts.min_outer), digits=1)
    max_in = round(ustrip(u"inch", opts.max_outer), digits=1)
    print(io, "NLPHSSOptions(", mat_str)
    print(io, ", outer=", min_in, "\"-", max_in, "\"")
    opts.aspect_limit < 3.0 && print(io, ", aspect≤", opts.aspect_limit)
    opts.prefer_square > 0 && print(io, ", prefer_square")
    opts.use_ad && print(io, ", AD")
    print(io, ", solver=:", opts.solver, ")")
end

"""Compact display for `NLPBeamOptions`."""
function Base.show(io::IO, opts::NLPBeamOptions)
    mat_str = material_name(opts.material)
    bmin = round(Int, ustrip(u"inch", opts.min_width))
    bmax = round(Int, ustrip(u"inch", opts.max_width))
    hmin = round(Int, ustrip(u"inch", opts.min_depth))
    hmax = round(Int, ustrip(u"inch", opts.max_depth))
    print(io, "NLPBeamOptions(", mat_str,
          ", b=", bmin, "\"-", bmax, "\"",
          ", h=", hmin, "\"-", hmax, "\"",
          ", solver=:", opts.solver, ")")
end

"""Compact display for `NLPWOptions`."""
function Base.show(io::IO, opts::NLPWOptions)
    mat_str = material_name(opts.material)
    d_min = round(Int, ustrip(u"inch", opts.min_depth))
    d_max = round(Int, ustrip(u"inch", opts.max_depth))
    print(io, "NLPWOptions(", mat_str)
    print(io, ", d=", d_min, "\"-", d_max, "\"")
    !opts.require_compact && print(io, ", allow_noncompact")
    print(io, ", solver=:", opts.solver, ")")
end
