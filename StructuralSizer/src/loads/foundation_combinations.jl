# =============================================================================
# One footing's (P, Mx, My) for one ASCE 7-22 combination
# =============================================================================
# P is compression-positive, in newtons. Moments are in newton-metres.
# A combination scales one dead, one live, one roof companion, and either one
# wind case or one seismic case. Wind and earthquake are not added together.

"""
Vertical force, the two plan moments, and the two horizontal base shears at
one support, for one case.

`Hx`/`Hy` are the horizontal reactions used by the global-stability (sliding /
overturning / uplift) checks. Only lateral cases (wind, seismic `Eh`) carry a
nonzero horizontal shear; gravity cases (dead, live, roof companion) leave it
at zero. Existing call sites that pass only `(P, Mx, My)` keep a zero shear.
"""
struct FootingAction
    label::Symbol
    "Compression-positive vertical force [N]."
    P::Float64
    "Moment about the global x-axis [N·m]."
    Mx::Float64
    "Moment about the global y-axis [N·m]."
    My::Float64
    "Horizontal base shear along x [N]."
    Hx::Float64
    "Horizontal base shear along y [N]."
    Hy::Float64
    function FootingAction(label, P, Mx, My, Hx, Hy)
        new(Symbol(label), Float64(P), Float64(Mx), Float64(My),
            Float64(Hx), Float64(Hy))
    end
end

"""Gravity case (no horizontal shear): `Hx = Hy = 0`."""
FootingAction(label, P, Mx, My) = FootingAction(label, P, Mx, My, 0.0, 0.0)

FootingAction(label) = FootingAction(label, 0.0, 0.0, 0.0, 0.0, 0.0)

"""
    combine_foundation_action(combo, roof, D, L, companion; wind, qe, rho, SDS,
                              alternative=:only) -> FootingAction

Scale one support's basic actions by one [`LoadCombination`](@ref).

`wind` is one wind case. `qe` is one seismic case before `ρ`. `Eh = ρ QE`
multiplies every component of that case. `Ev = 0.2 SDS D` is added to the
vertical force only.

`Lr`, `S`, and `R` are not added together. Only `roof` is passed.
Combination 3's two readings are `alternative = :L` and `:W`.

# Citations
ASCE 7-22 §2.3.1 and §2.4.1 (corpus: asce-7-22, PDF pages 68–69),
§2.3.6 and §2.4.5 (PDF pages 69–70).
Eq. 12.4-3, `Eh = ρ QE`, and Eq. 12.4-4a, `Ev = 0.2 SDS D`
(PDF page 183), through [`vertical_seismic_load_effect`](@ref).

# ENGINEERING JUDGMENT
`D` in Eq. 12.4-4a is the dead-load effect. Ev is applied to the vertical
dead effect only. Dead moments keep the D factor and are not also scaled
by `0.2 SDS`. The same reading is used for wall pier axial force.
"""
function combine_foundation_action(combo::LoadCombination, roof::Symbol,
                                   D::FootingAction, L::FootingAction,
                                   companion::FootingAction;
                                   wind::Union{Nothing, FootingAction}=nothing,
                                   qe::Union{Nothing, FootingAction}=nothing,
                                   rho::Union{Nothing, Real}=nothing,
                                   SDS::Union{Nothing, Real}=nothing,
                                   alternative::Symbol=:only)
    roof in (:Lr, :S, :R) || throw(ArgumentError(
        "foundation combination: the roof companion must be :Lr, :S, or :R, " *
        "got :$roof."))
    alternative in (:only, :L, :W) || throw(ArgumentError(
        "foundation combination: alternative must be :only, :L, or :W, " *
        "got $(repr(alternative))."))
    if alternative !== :only && combo.name !== :strength_1_2D_1_6Lr
        throw(ArgumentError(
            "foundation combination: :L and :W are the two readings of " *
            "combination 3. $(combo.name) is not that combination."))
    end
    use_wind = alternative === :L ? false : combo.W != 0.0
    use_live = alternative === :W ? false : true
    use_eh = combo.E != 0.0
    use_ev = combo.Ev != 0.0
    if use_wind && wind === nothing
        throw(ArgumentError(
            "foundation combination: $(combo.name) has a wind factor and no " *
            "wind case was passed."))
    end
    if (use_eh || use_ev) && qe === nothing
        throw(ArgumentError(
            "foundation combination: $(combo.name) includes earthquake and no " *
            "seismic case was passed."))
    end
    ρ = use_eh ? _foundation_rho(rho) : 1.0
    ev_P = 0.0
    if use_ev
        SDS === nothing && throw(ArgumentError(
            "foundation combination: $(combo.name) includes Ev and SDS was " *
            "not passed. Ev = 0.2 SDS D is not assumed."))
        # ASCE 7-22 Eq. 12.4-4a (corpus: asce-7-22, PDF page 183).
        ev_P = vertical_seismic_load_effect(SDS, D.P)
    end
    live = use_live ? L : FootingAction(:live)
    wind_a = use_wind ? wind : FootingAction(:wind)
    eh = use_eh ? FootingAction(:eh, ρ * qe.P, ρ * qe.Mx, ρ * qe.My,
                                ρ * qe.Hx, ρ * qe.Hy) :
         FootingAction(:eh)
    P = _foundation_component(combo, roof, D.P, live.P, companion.P,
                              wind_a.P, eh.P, ev_P)
    Mx = _foundation_component(combo, roof, D.Mx, live.Mx, companion.Mx,
                               wind_a.Mx, eh.Mx, 0.0)
    My = _foundation_component(combo, roof, D.My, live.My, companion.My,
                               wind_a.My, eh.My, 0.0)
    # Horizontal base shear travels with the same combination factors as the
    # moments. Ev is a vertical seismic effect only (ASCE 7-22 Eq. 12.4-4a,
    # corpus: asce-7-22, PDF page 183), so it adds no horizontal term.
    Hx = _foundation_component(combo, roof, D.Hx, live.Hx, companion.Hx,
                               wind_a.Hx, eh.Hx, 0.0)
    Hy = _foundation_component(combo, roof, D.Hy, live.Hy, companion.Hy,
                               wind_a.Hy, eh.Hy, 0.0)
    return FootingAction(combo.name, P, Mx, My, Hx, Hy)
end

"""
    foundation_combination_actions(combos, D, L, companion, winds, qes;
                                   roof, rho, SDS) -> Vector{FootingAction}

Every combination in `combos`, once for each wind case it includes and once
for each seismic case it includes.

A wind factor with no wind case is skipped, and so is an earthquake factor
with no seismic case. Gravity combinations are always emitted. Wind and
earthquake are not placed in the same action.

The 25% reduction of foundation overturning (§12.13.4) is not applied. It
is a permission. Ev is not taken as zero at the soil interface
(§12.4.2.2 exception 2(b)); that is also a permission.

# Citations
ASCE 7-22 §2.3.1, §2.3.6, §2.4.1, §2.4.5 (corpus: asce-7-22, PDF pages
68–70). §12.13.4 and §12.13.6 (PDF pages 195–196).
"""
function foundation_combination_actions(combos, D::FootingAction, L::FootingAction,
                                        companion::FootingAction, winds, qes;
                                        roof::Symbol, rho::Real, SDS::Real)
    out = FootingAction[]
    for combo in combos
        _append_foundation_combo!(out, combo, D, L, companion, winds, qes;
                                  roof, rho, SDS)
    end
    return out
end

function _append_foundation_combo!(out, combo, D, L, companion, winds, qes;
                                   roof, rho, SDS)
    if combo.W != 0.0 && (combo.E != 0.0 || combo.Ev != 0.0)
        throw(ArgumentError(
            "foundation combination: $(combo.name) has both a wind factor and " *
            "an earthquake factor. ASCE 7-22 §2.3.1 and §2.4.1 do not apply " *
            "wind and earthquake together (corpus: asce-7-22, PDF pages 68–69)."))
    end
    if combo.name === :strength_1_2D_1_6Lr
        push!(out, combine_foundation_action(combo, roof, D, L, companion;
                                              rho, SDS, alternative=:L))
        for w in winds
            push!(out, combine_foundation_action(combo, roof, D, L, companion;
                                                  wind=w, rho, SDS, alternative=:W))
        end
        return out
    end
    if combo.W != 0.0
        for w in winds
            push!(out, combine_foundation_action(combo, roof, D, L, companion;
                                                  wind=w, rho, SDS))
        end
        return out
    end
    if combo.E != 0.0 || combo.Ev != 0.0
        for q in qes
            push!(out, combine_foundation_action(combo, roof, D, L, companion;
                                                  qe=q, rho, SDS))
        end
        return out
    end
    push!(out, combine_foundation_action(combo, roof, D, L, companion; rho, SDS))
    return out
end

"""One roof companion. The other two roof keywords stay at zero."""
function _foundation_component(combo, roof::Symbol, D, L, companion, W, E, Ev)
    if roof === :Lr
        return factored_pressure(combo; D, L, Lr=companion, W, E, Ev)
    elseif roof === :S
        return factored_pressure(combo; D, L, S=companion, W, E, Ev)
    else
        return factored_pressure(combo; D, L, R=companion, W, E, Ev)
    end
end

function _foundation_rho(rho)
    rho === nothing && throw(ArgumentError(
        "ρ is required. ASCE 7-22 Eq. 12.4-3 (corpus: asce-7-22, PDF page 183) " *
        "is Eh = ρ QE. No redundancy factor is assumed."))
    ρ = Float64(rho)
    (isfinite(ρ) && ρ > 0) || throw(ArgumentError(
        "ρ must be a finite number > 0; got $rho."))
    return ρ
end
