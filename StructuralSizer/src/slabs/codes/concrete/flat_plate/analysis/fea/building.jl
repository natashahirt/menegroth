# =============================================================================
# FEA from the building model — FEA(source = :building)
# =============================================================================
#
# The slab is not meshed here. The building package meshes every flat-plate
# floor into its building model, solves it, and fills an `FEAModelCache` for
# one slab from that solve. Everything after the cache is the FEA path.
# =============================================================================

"""
    building_fea_analysis!(struc, slab, columns, h, setup; Ecs, ν, use_pattern,
                           drop_panel, verbose) -> (; cache, forces, Δ_panel)

Read `slab` at thickness `h` and slab modulus `Ecs` from the building model of
`struc`. Defined by the package that owns the building model; this package only
declares it.

- `cache`: an initialized [`FEAModelCache`](@ref) for the slab's triangles, with
  unfactored dead and live moments (`element_data_D`, `element_data_L`) and,
  when `use_pattern`, the live moments of each cell loaded alone
  (`cell_live_moments`).
- `forces`: the fields of [`_extract_fea_column_forces`](@ref), one entry per
  column of `columns`, enveloped over the same load combinations and patterns.
- `Δ_panel`: factored panel deflection at gross section, the quantity
  [`check_two_way_deflection`](@ref) reads from `fea_Δ_panel`.

`setup` is [`_moment_analysis_setup`](@ref) at `h`; its `qD` and `qL` load the
slab's own cells.
"""
function building_fea_analysis! end

"""
    building_fea_available(struc, slab) -> Bool

True when `struc` has a building model whose shells carry `slab`. Without
one, `FEA(source = :building)` analyses the slab on its own model.
"""
building_fea_available(struc, slab) = false

"""`method` with `source` replaced. Every other setting is kept."""
function with_fea_source(method::FEA, source::Symbol)
    method.source === source && return method
    return FEA(; target_edge = method.target_edge,
               pattern_loading = method.pattern_loading,
               pattern_mode = method.pattern_mode,
               design_approach = method.design_approach,
               moment_transform = method.moment_transform,
               field_smoothing = method.field_smoothing,
               cut_method = method.cut_method,
               iso_alpha = method.iso_alpha,
               rebar_direction = method.rebar_direction,
               sign_treatment = method.sign_treatment,
               concrete_torsion_discount = method.concrete_torsion_discount,
               patch_stiffness_factor = method.patch_stiffness_factor,
               averaging_width_factor = method.averaging_width_factor,
               deflection_Ie_method = method.deflection_Ie_method,
               source)
end

"""
    _building_moment_analysis(method, struc, slab, columns, h, Ecs, γ_concrete, setup;
                              ν_concrete, drop_panel, verbose) -> MomentAnalysisResult

`FEA(source = :building)`. Patterns are the building's re-solves with each cell
of the slab loaded alone (ACI 318-11 §13.7.6, corpus: aci-318-11, page 261), so
`pattern_mode` is not read.
"""
function _building_moment_analysis(method::FEA, struc, slab, columns, h::Length,
                                   Ecs::Pressure, γ_concrete, setup;
                                   ν_concrete::Float64 = 0.20,
                                   drop_panel = nothing, verbose::Bool = false)
    applicable(building_fea_analysis!, struc, slab, columns, h, setup) || throw(ArgumentError(
        "FEA(source = :building) needs a building model, and $(typeof(struc)) has none. " *
        "Use FEA(source = :slab)."))
    use_pattern = method.pattern_loading && requires_pattern_loading(setup.qD, setup.qL) &&
                  length(columns) >= 3
    built = building_fea_analysis!(struc, slab, columns, h, setup;
                                   Ecs, ν = ν_concrete, use_pattern, drop_panel, verbose)
    cache = built.cache
    cache.averaging_width_factor = method.averaging_width_factor
    _combine_element_moments!(cache; verbose)
    use_pattern && _fea_pattern_envelope!(cache, slab; verbose)

    incl_torsion = method.moment_transform != :no_torsion
    envelope = _extract_cell_moments(cache, struc, slab, columns, setup.span_axis;
                                     include_torsion = incl_torsion, verbose)
    column_moments = [uconvert(kip * u"ft", m * u"N*m") for m in envelope.col_Mneg]
    neg_env = _envelope_from_columns(column_moments, columns)
    return _fea_moment_result(
        method, struc, slab, columns, h, γ_concrete, setup, cache, built.forces;
        column_moments,
        M_neg_ext = neg_env.M_neg_ext,
        M_neg_int = neg_env.M_neg_int,
        M_pos = uconvert(kip * u"ft", envelope.M_pos),
        fea_Δ_panel = built.Δ_panel,
        pattern_loading = use_pattern,
        sec_pattern = nothing,
        include_torsion = incl_torsion,
        n_cells = envelope.n_cells,
        verbose)
end
