# =============================================================================
# Story Properties for Sway Magnification (ACI 318-19 §6.6.4.6)
# =============================================================================
#
# Computes story-level properties needed for sway moment magnification:
# - ΣPu: Sum of factored axial loads on all columns in story
# - ΣPc: Sum of critical buckling loads (placeholder until sections known)
# - Vus: Factored story shear
# - Δo: First-order story drift
# - lc: Story height (center-to-center of joints)
#
# These properties are assigned to each column's `story_properties` field
# after structural analysis when displacements and forces are available.
#
# =============================================================================

"""
    compute_story_properties!(struc; verbose=false)

Compute and assign story properties to all columns for sway magnification.

This function should be called after structural analysis (ASAP solve) when
displacements and member forces are available. It populates the `story_properties`
field on each Column for use in ACI 318-19 sway moment magnification.

# Story-Level Properties (all returned as Unitful quantities)
- `ΣPu`: Sum of factored axial loads on all columns in story (Force)
- `ΣPc`: Sum of critical buckling loads (Force, estimated, refined during sizing)
- `Vus`: Factored story shear (Force)
- `Δo`: First-order story drift (Length)
- `lc`: Story height (Length)

# Notes
- ΣPc is estimated using simplified EI = 0.4EcIg (conservative per ACI 6.6.4.4.4)
- Actual ΣPc will be refined during column sizing when sections are known
- Δo is computed from ASAP analysis node displacements

# Example
```julia
# After creating model and running analysis
struc, model = create_asap_model(struc; analyze=true)

# Compute and assign story properties
compute_story_properties!(struc; verbose=true)

# Column now has story_properties for sway magnification
col = struc.columns[1]
Q = stability_index(col.story_properties)  # Story stability index
```
"""
function compute_story_properties!(struc; verbose::Bool = false)
    # Group columns by story
    columns_by_story = Dict{Int, Vector}()
    for col in struc.columns
        story = col.story
        if !haskey(columns_by_story, story)
            columns_by_story[story] = []
        end
        push!(columns_by_story[story], col)
    end
    
    # For each story, compute properties
    for (story, cols) in columns_by_story
        props = _compute_story_props(struc, cols, story; verbose=verbose)
        
        # Assign to all columns in this story
        for col in cols
            col.story_properties = props
        end
    end
    
    if verbose
        n_stories = length(columns_by_story)
        @info "Computed story properties for $n_stories stories, $(length(struc.columns)) columns"
    end
    
    return struc
end

"""
    _compute_story_props(struc, cols, story; verbose=false) -> NamedTuple

Compute story properties for a single story level.
Returns all values as proper Unitful quantities.
"""
function _compute_story_props(struc, cols, story::Int; verbose::Bool = false)
    n_cols = length(cols)
    
    # --- Story height (lc) ---
    # Use average column length in the story
    lc = sum(col.base.L for col in cols) / n_cols
    
    # --- Sum of factored axial loads (ΣPu) ---
    # Get from ASAP results if available, otherwise estimate from tributary
    ΣPu = 0.0u"kip"
    for col in cols
        # Try to get from analysis results first
        Pu = _get_column_axial_from_analysis(struc, col)
        if isnothing(Pu)
            # Estimate from tributary area if analysis not available
            Pu = _estimate_column_axial(struc, col)
        end
        ΣPu += Pu
    end
    
    # --- Sum of critical buckling loads (ΣPc) ---
    # Use simplified formula: Pc = π²EI/(kLu)²
    # EI estimated as 0.4EcIg until section is known
    ΣPc = _estimate_Pc_sum(struc, cols)
    
    # --- Story shear (Vus) ---
    # Sum of column shears at the story level
    Vus = _estimate_story_shear(struc, cols, story)
    
    # --- First-order drift (Δo) ---
    # From ASAP analysis node displacements
    Δo = _compute_story_drift(struc, cols, story)
    
    if verbose
        @debug "Story $story properties:" ΣPu=ΣPu ΣPc=ΣPc Vus=Vus Δo=Δo lc=lc
    end
    
    return (ΣPu=ΣPu, ΣPc=ΣPc, Vus=Vus, Δo=Δo, lc=lc)
end

# --- Helper functions ---

"""Get column axial load from ASAP analysis results (returns nothing if not available)."""
function _get_column_axial_from_analysis(struc, col)
    # Check if we have ASAP results
    if !hasfield(typeof(struc), :asap_model) || isnothing(struc.asap_model)
        return nothing
    end
    
    # Try to get from segment forces
    # For now, return nothing to use tributary estimation
    # TODO: Implement extraction from ASAP results when model is available
    return nothing
end

"""Estimate column axial load from tributary area and loads. Returns Force (kip)."""
function _estimate_column_axial(struc, col)
    # Get tributary area
    trib = column_tributary_by_cell(struc, col)
    
    Pu = 0.0u"kip"
    for (cell_idx, area_m2) in trib
        cell = struc.cells[cell_idx]
        area = area_m2 * u"m^2"
        
        # Factored load: 1.2D + 1.6L
        qD = cell.sdl + cell.self_weight
        qL = cell.live_load
        qu = 1.2 * qD + 1.6 * qL
        
        Pu += uconvert(u"kip", qu * area)
    end
    
    return Pu
end

"""Estimate sum of critical buckling loads for columns in story. Returns Force (kip)."""
function _estimate_Pc_sum(struc, cols)
    # Use simplified EI = 0.4EcIg
    # Pc = π²(0.4EcIg)/(kLu)²
    # 
    # For now, estimate based on typical 4000 psi concrete and 
    # assumed column dimensions from c1, c2
    
    ΣPc = 0.0u"kip"
    
    for col in cols
        # Get column dimensions (fall back to defaults if not set)
        c1 = isnothing(col.c1) ? 18.0u"inch" : col.c1
        c2 = isnothing(col.c2) ? 18.0u"inch" : col.c2
        
        # Gross moment of inertia (assuming rectangular)
        Ig = c1 * c2^3 / 12  # About weak axis (conservative)
        
        # Concrete modulus (4000 psi typical)
        Ec = 57.0 * sqrt(4000) * u"psi"  # ACI 19.2.2.1
        
        # Effective stiffness (simplified per ACI 6.6.4.4.4)
        EI_eff = 0.4 * Ec * Ig
        
        # Unsupported length
        Lu = col.base.Lu
        k = col.base.Ky  # Use y-axis (weak)
        
        # Critical buckling load
        if ustrip(k * Lu) > 0
            Pc = π^2 * EI_eff / (k * Lu)^2
            ΣPc += uconvert(u"kip", Pc)
        end
    end
    
    return ΣPc
end

"""Estimate story shear (placeholder - uses ΣPu × 0.05 as lateral fraction). Returns Force."""
function _estimate_story_shear(struc, cols, story::Int)
    # Placeholder: assume 5% of total vertical load as lateral
    # This should be replaced with actual lateral analysis results
    ΣPu = sum(_estimate_column_axial(struc, col) for col in cols)
    return 0.05 * ΣPu
end

"""Compute story drift from ASAP analysis (placeholder). Returns Length."""
function _compute_story_drift(struc, cols, story::Int)
    # Placeholder: return 0.5 inch as typical first-order drift
    # This should be extracted from ASAP node displacements
    # TODO: Implement extraction from ASAP results
    return 0.5u"inch"
end

export compute_story_properties!
