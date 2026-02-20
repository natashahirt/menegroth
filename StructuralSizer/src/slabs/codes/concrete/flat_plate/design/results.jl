# =============================================================================
# Flat Plate Result Builders
# =============================================================================
#
# Functions to construct result structs from design outputs.
#
# =============================================================================

"""
    build_slab_result(h, sw, moment_results, rebar_design, deflection_result, punching_results;
                       γ_concrete, secondary_rebar_design=nothing) -> FlatPlatePanelResult

Build FlatPlatePanelResult from design outputs.

# Arguments
- `h`: Final slab thickness
- `sw`: Self-weight pressure
- `moment_results`: MomentAnalysisResult with geometry and M0
- `rebar_design`: Strip reinforcement design (column & middle strips) — primary direction
- `deflection_result`: Result from `check_two_way_deflection`
- `punching_results`: Dict of per-column punching check results
- `γ_concrete`: Weight density of concrete (force/volume); defaults to NWC_4000
- `secondary_rebar_design`: Optional secondary direction strip reinforcement

# Returns
`FlatPlatePanelResult` with all design data
"""
function build_slab_result(h, sw, moment_results, rebar_design, deflection_result, punching_results;
                           γ_concrete = NWC_4000.ρ * GRAVITY,
                           secondary_rebar_design = nothing)
    # Aggregate punching results
    punching_check = (
        ok = all(pr.ok for pr in values(punching_results)),
        max_ratio = maximum(pr.ratio for pr in values(punching_results); init=0.0),
        details = punching_results
    )
    
    # Deflection summary — use the pre-computed check from check_two_way_deflection
    Δ_check_in = ustrip(u"inch", deflection_result.Δ_check)
    Δ_limit_in = ustrip(u"inch", deflection_result.Δ_limit)
    deflection_check = (
        ok = deflection_result.ok,
        Δ_check = deflection_result.Δ_check,
        Δ_total = deflection_result.Δ_total,
        Δ_limit = deflection_result.Δ_limit,
        ratio = Δ_check_in / Δ_limit_in
    )
    
    # Secondary reinforcement kwargs
    sec_kwargs = if !isnothing(secondary_rebar_design)
        (
            sec_cs_width = secondary_rebar_design.column_strip_width,
            sec_cs_reinf = secondary_rebar_design.column_strip_reinf,
            sec_ms_width = secondary_rebar_design.middle_strip_width,
            sec_ms_reinf = secondary_rebar_design.middle_strip_reinf,
        )
    else
        NamedTuple()
    end
    
    return FlatPlatePanelResult(
        moment_results.l1,
        moment_results.l2,
        h,
        moment_results.M0,
        moment_results.qu,
        rebar_design.column_strip_width,
        rebar_design.column_strip_reinf,
        rebar_design.middle_strip_width,
        rebar_design.middle_strip_reinf,
        punching_check,
        deflection_check;
        γ_concrete = γ_concrete,
        sec_kwargs...
    )
end

"""
    build_column_results(struc, columns, column_result, Pu, Mu, punching_results) -> Dict

Build column design results dict from design outputs.
"""
function build_column_results(struc, columns, column_result, Pu, Mu, punching_results)
    results = Dict{Int, NamedTuple}()
    
    for (i, col) in enumerate(columns)
        col_idx = findfirst(==(col), struc.columns)
        section = column_result.sections[i]
        bb = bounding_box(section)
        
        w_in = ustrip(u"inch", bb.width)
        d_in = ustrip(u"inch", bb.depth)
        
        Mu_val = uconvert(u"kN*m", Mu[i])
        
        results[col_idx] = (
            section_size = "$(w_in)×$(d_in)",
            b = bb.width,
            h = bb.depth,
            ρg = section.ρg,
            Pu = uconvert(u"kN", Pu[i] * kip),
            Mu = Mu_val,
            punching = punching_results[col_idx]
        )
    end
    
    return results
end

