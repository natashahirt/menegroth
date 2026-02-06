# =============================================================================
# Flat Plate Result Builders
# =============================================================================
#
# Functions to construct result structs from design outputs.
#
# =============================================================================

"""
    build_slab_result(h, sw, moment_results, rebar_design, Δ_total, Δ_limit, punching_results) -> FlatPlatePanelResult

Build FlatPlatePanelResult from design outputs.

# Arguments
- `h`: Final slab thickness
- `sw`: Self-weight pressure
- `moment_results`: MomentAnalysisResult with geometry and M0
- `rebar_design`: Strip reinforcement design (column & middle strips)
- `Δ_total`: Total computed deflection
- `Δ_limit`: Deflection limit
- `punching_results`: Dict of per-column punching check results

# Returns
`FlatPlatePanelResult` with all design data
"""
function build_slab_result(h, sw, moment_results, rebar_design, Δ_total, Δ_limit, punching_results)
    # Aggregate punching results
    punching_check = (
        passes = all(pr.ok for pr in values(punching_results)),
        max_ratio = maximum(pr.ratio for pr in values(punching_results); init=0.0),
        details = punching_results
    )
    
    # Deflection summary - convert to same units before calculating ratio
    Δ_total_in = ustrip(u"inch", Δ_total)
    Δ_limit_in = ustrip(u"inch", Δ_limit)
    deflection_check = (
        passes = Δ_total <= Δ_limit,
        Δ_total = Δ_total,
        Δ_limit = Δ_limit,
        ratio = Δ_total_in / Δ_limit_in
    )
    
    # Use convenience constructor with h-based signature
    return FlatPlatePanelResult(
        moment_results.l1,
        moment_results.l2,
        h,
        moment_results.M0,
        rebar_design.column_strip_width,
        rebar_design.column_strip_reinf,
        rebar_design.middle_strip_width,
        rebar_design.middle_strip_reinf,
        punching_check,
        deflection_check
    )
end

"""
    build_column_results(struc, columns, column_result, Pu, Mu, punching_results) -> Dict

Build column design results dict from design outputs.
"""
function build_column_results(struc, columns, column_result, Pu, Mu, punching_results)
    results = Dict{Int, Any}()
    
    for (i, col) in enumerate(columns)
        col_idx = findfirst(==(col), struc.columns)
        section = column_result.sections[i]
        
        b_in = ustrip(u"inch", section.b)
        h_in = ustrip(u"inch", section.h)
        
        # Handle both unitful and stripped Mu
        Mu_val = Mu[i] isa Unitful.Quantity ? uconvert(u"kN*m", Mu[i]) : uconvert(u"kN*m", Mu[i] * kip*u"ft")
        
        results[col_idx] = (
            section_size = "$(b_in)×$(h_in)",
            b = section.b,
            h = section.h,
            ρg = section.ρg,
            Pu = uconvert(u"kN", Pu[i] * kip),
            Mu = Mu_val,
            punching = punching_results[col_idx]
        )
    end
    
    return results
end

# =============================================================================
# Exports
# =============================================================================

export build_slab_result, build_column_results
