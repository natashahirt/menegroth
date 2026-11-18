
"""
Punching shear check result for a column.
All values stored in coherent SI (kN, kN·m, m, m²).

`Mub` is the slab-column unbalanced moment from the moment analysis (DDM/EFM/FEA),
**not** the column frame bending demand `Mu_x`. Micro-experiments must use this
value for `check_punching_for_column` so results match the full design.
"""
Base.@kwdef mutable struct PunchingDesignResult
    Vu::typeof(1.0u"kN")             # Punching shear force demand
    φVc::typeof(1.0u"kN")            # Capacity (factored)
    ratio::Float64                    # vu_stress / φvc_stress
    ok::Bool                          # ratio ≤ 1.0
    critical_perimeter::typeof(1.0u"m")
    tributary_area::typeof(1.0u"m^2")
    Mub::typeof(1.0u"kN*m") = 0.0u"kN*m"  # Slab-column unbalanced moment (ACI 318-19 §8.4.4.2)
end

"""
Row F frame check for one column or beam (ASCE 7-22 §12.2.5.8).

`ratio` is the governing demand/capacity ratio from the member checker.
`NaN` means the member was recorded as failing without a checked section.
"""
Base.@kwdef struct SeismicFrameCheck
    passed::Bool = true
    governing_check::String = ""
    ratio::Float64 = 0.0
    case_label::String = ""
    detail::String = ""
    clause::String = "ASCE 7-22 12.2.5.8"
end

"""
Design result for a column.
"""
Base.@kwdef mutable struct ColumnDesignResult
    # Sizing
    section_size::String = ""         # e.g., "W14x90", "16x16"
    section_obj::Union{StructuralSizer.AbstractSection, Nothing} = nothing

    # Column geometry (populated from Column.c1, .c2, .shape)
    c1::typeof(1.0u"m") = 0.0u"m"
    c2::typeof(1.0u"m") = 0.0u"m"
    shape::Symbol = :rectangular      # :rectangular or :circular
    
    # Member dimensions for material takeoff
    height::typeof(1.0u"m") = 0.0u"m"        # full column height
    Ag::typeof(1.0u"m^2") = 0.0u"m^2"        # gross section area
    As_total::typeof(1.0u"m^2") = 0.0u"m^2"  # total rebar area
    rho_g::Float64 = 0.0                       # reinforcement ratio
    
    # Demands
    Pu::typeof(1.0u"kN") = 0.0u"kN"
    Mu_x::typeof(1.0u"kN*m") = 0.0u"kN*m"
    Mu_y::typeof(1.0u"kN*m") = 0.0u"kN*m"
    
    # Capacity ratios
    axial_ratio::Float64 = 0.0
    interaction_ratio::Float64 = 0.0
    # The sizer's own governing check, when the column was sized by one.
    # Empty means the ratios above are the screen in `_populate_column_results!`.
    governing_check::String = ""
    governing_ratio::Float64 = 0.0
    governing_clause::String = ""
    ok::Bool = true
    # Sizing outcomes that are not a failed check: a full-load loop that did
    # not settle, or a column left smaller than the one above.
    notes::Vector{String} = String[]
    
    # Punching (if supporting flat slab)
    punching::Union{PunchingDesignResult, Nothing} = nothing

    # One-way shear, ACI 318-19 §10.5.3.1 / §22.5. Steel columns leave the
    # defaults: `shear_ok` stays true and `shear_clause` stays empty, so the
    # scene does not invent a concrete shear check. `Vu_x` is parallel to the
    # section width and `Vu_y` to the depth, in the assignment that governed.
    Vu_x::typeof(1.0u"kN") = 0.0u"kN"
    Vu_y::typeof(1.0u"kN") = 0.0u"kN"
    ϕVn_x::typeof(1.0u"kN") = 0.0u"kN"
    ϕVn_y::typeof(1.0u"kN") = 0.0u"kN"
    shear_ratio::Float64 = 0.0
    shear_ok::Bool = true
    tie_spacing::typeof(1.0u"m") = 0.0u"m"
    tie_bar_size::Int = 0
    shear_clause::String = ""
    # Row F 25% frame check. `nothing` when this column was not in that check.
    seismic_frame::Union{SeismicFrameCheck, Nothing} = nothing
end
