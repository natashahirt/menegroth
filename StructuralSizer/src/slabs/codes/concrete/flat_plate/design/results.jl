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
- `wall_face_parts`, `wall_face_parts_secondary`: dead and live moment at
  each wall face, with that wall's plan line; empty when dead and live
  were not separated

# Returns
`FlatPlatePanelResult` with all design data
"""
function _stored_wall_moment(moment_results)
    hasproperty(moment_results, :M_wall_ext) || return 0.0u"kN*m"
    return max(abs(moment_results.M_wall_ext), abs(moment_results.M_wall_int))
end

function build_slab_result(h, sw, moment_results, rebar_design, deflection_result, punching_results;
                           γ_concrete = NWC_4000.ρ * GRAVITY,
                           secondary_rebar_design = nothing,
                           secondary_results = nothing,
                           wall_face_parts = SlabWallFaceMoment[],
                           wall_face_parts_secondary = SlabWallFaceMoment[])
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
        M_wall = _stored_wall_moment(moment_results),
        M_wall_secondary = secondary_results === nothing ? 0.0u"kN*m" :
                           _stored_wall_moment(secondary_results),
        wall_face_parts = wall_face_parts,
        wall_face_parts_secondary = wall_face_parts_secondary,
        sec_kwargs...
    )
end

"""
    build_column_results(struc, columns, column_result, Pu, Mu, punching_results;
                         Mu_secondary=nothing, stubs=nothing, stubs_secondary=nothing) -> Dict

Build column design results dict from design outputs.

`Mu` and `Mu_secondary` are the joint unbalanced moments in the slab's
primary and perpendicular directions, before the ACI 318-11 §13.6.9.2 split
between the columns above and below. `Mu_secondary` is zero when that
direction was not analyzed.

`stubs` and `stubs_secondary` are the [`stub_moments`](@ref) of a shell
analysis in each direction. Each result then carries `Mu_below`,
`Mu_above`, `Mu_secondary_below`, and `Mu_secondary_above`, the moment in
the column below and above the slab. A direction without stub moments (DDM,
EFM, or a perpendicular direction the shell did not report) leaves its pair
`nothing`, and its joint moment is split by stiffness instead.
"""
function build_column_results(struc, columns, column_result, Pu, Mu, punching_results;
                              Mu_secondary = nothing, stubs = nothing,
                              stubs_secondary = nothing)
    results = Dict{Int, NamedTuple}()
    if !_rc_nlp_result_installable(column_result)
        @warn "Column NLP result is not a completed design; omitting column results" status=column_result.status
        return results
    end

    for (i, col) in enumerate(columns)
        col_idx = findfirst(==(col), struc.columns)
        section = column_result.sections[i]
        bb = bounding_box(section)
        
        w_in = ustrip(u"inch", bb.width)
        d_in = ustrip(u"inch", bb.depth)
        
        Mu_val = uconvert(u"kN*m", Mu[i])
        Mu_sec = isnothing(Mu_secondary) ? 0.0u"kN*m" : uconvert(u"kN*m", Mu_secondary[i])
        stub(s, side) = s === nothing ? nothing : uconvert(u"kN*m", getproperty(s, side)[i])

        results[col_idx] = (
            section_size = "$(w_in)×$(d_in)",
            b = bb.width,
            h = bb.depth,
            # Plan size the slab was designed at (punching, ln), which the
            # P-M section above can be smaller than.
            c1 = col.c1,
            c2 = col.c2,
            ρg = section.ρg,
            Pu = uconvert(u"kN", Pu[i] * kip),
            Mu = Mu_val,
            Mu_secondary = Mu_sec,
            Mu_below = stub(stubs, :below),
            Mu_above = stub(stubs, :above),
            Mu_secondary_below = stub(stubs_secondary, :below),
            Mu_secondary_above = stub(stubs_secondary, :above),
            punching = punching_results[col_idx]
        )
    end
    
    return results
end

