
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
    ok::Bool = true
    
    # Punching (if supporting flat slab)
    punching::Union{PunchingDesignResult, Nothing} = nothing

    # One-way shear stored by `_assign_column_shear!`. `Vu_x` is parallel to
    # the section width and `Vu_y` to the depth, in the assignment that governed.
    Vu_x::typeof(1.0u"kN") = 0.0u"kN"
    Vu_y::typeof(1.0u"kN") = 0.0u"kN"
    ϕVn_x::typeof(1.0u"kN") = 0.0u"kN"
    ϕVn_y::typeof(1.0u"kN") = 0.0u"kN"
    shear_ratio::Float64 = 0.0
    shear_ok::Bool = true
    tie_spacing::typeof(1.0u"m") = 0.0u"m"
    tie_bar_size::Int = 0
    shear_clause::String = ""
end
