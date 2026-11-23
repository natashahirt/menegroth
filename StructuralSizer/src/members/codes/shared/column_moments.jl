# ==============================================================================
# Shared moment-carrying-column trait — material-dispatched second-order design
# ==============================================================================
#
# `design_column_moments` turns a column's lateral-translation-split demand
# (`demand.lt`, a `LateralTranslation`, or `nothing`) plus the shared
# `StoryStability` record into the design forces each material code's interaction
# check wants. It dispatches on the demand type, which is the material:
#
#   RCColumnDemand (ACI 318-11 §10.10.7) — returns the sway-magnified *end*
#       moments `M = Mns + δs·Ms` (Eq. 10-18, §10.10.7.1). `δs` is a story
#       property, so it is axis-independent; the checker then runs its usual
#       braced (k = 1) along-length magnification and P-M interaction on these
#       magnified end moments, exactly as §10.10.7 prescribes.
#
#   MemberDemand (AISC 360-16 Appendix 8) — returns fully amplified
#       `Mr = B1·Mnt + B2·Mlt` (Eq. A-8-1) and `Pr = Pnt + B2·Plt` (Eq. A-8-2).
#       AISC folds the along-length P-δ into `B1`, so these are ready for the
#       beam-column interaction check directly.
#
# No-op contract: when `demand.lt === nothing` (pure gravity column), or when no
# `story` is supplied, or when the story is non-sway, every amplifier collapses
# to 1.0 and the returned design moments equal the unmodified no-translation
# moments. This keeps gravity-only columns byte-identical to the legacy path.

"""
    design_column_moments(demand, story, ...) -> NamedTuple

Material-dispatched second-order column design moments. See the file header for
the per-material contract. Dispatches on `demand` (`RCColumnDemand` → ACI,
`MemberDemand` → AISC).
"""
function design_column_moments end

# --- ACI 318-11 §10.10.7 sway amplifier (δs) ---------------------------------

"""
    _sway_delta_s(story::StoryStability) -> (δs, method, Q)

Sway magnifier `δs` per ACI 318-11 §10.10.7.3, mirroring
`magnify_moment_sway_complete`: use the `Q`-method `δs = 1/(1 − Q)` when it is
≤ 1.5, otherwise fall back to the `ΣPu/ΣPc` method (§10.10.7.3(b)); flag
`:needs_P_delta` when both exceed 1.5 (§10.10.4 second-order analysis required).
"""
function _sway_delta_s(story::StoryStability)
    Q = stability_index(story)
    δs_Q = magnification_factor_sway_Q(Q)
    if δs_Q <= 1.5
        return δs_Q, :Q, Q
    end
    δs_Pc = magnification_factor_sway(story.ΣPu, story.ΣPc)
    method = (δs_Pc > 1.5 && isfinite(δs_Pc)) ? :needs_P_delta : :ΣPc
    return δs_Pc, method, Q
end

"""
    design_column_moments(demand::RCColumnDemand,
                          story::Union{Nothing, StoryStability}=nothing) -> NamedTuple

Sway-magnified column end moments per ACI 318-11 §10.10.7.1, Eq. 10-18:
`M = Mns + δs·Ms`, applied to both ends of both axes with the single
story-level `δs`. The no-translation end moments come from the demand
(`M1x/M2x`, `M1y/M2y`); the sway end moments come from `demand.lt`.

Returns `(; M1x, M2x, M1y, M2y, δs, Q, method, sway_applied)`. When there is no
lateral-translation split, no story, or the story is non-sway, `δs = 1` and the
end moments are returned unchanged (`sway_applied = false`).
"""
function design_column_moments(demand::RCColumnDemand,
                               story::Union{Nothing, StoryStability} = nothing)
    lt = demand.lt
    # No sway component, no story, or a non-sway story → unmodified end moments.
    if lt === nothing || story === nothing || !is_sway_frame(story)
        return (; M1x = demand.M1x, M2x = demand.M2x,
                  M1y = demand.M1y, M2y = demand.M2y,
                  δs = 1.0, Q = story === nothing ? NaN : stability_index(story),
                  method = :none, sway_applied = false)
    end

    δs, method, Q = _sway_delta_s(story)

    # ACI 318-11 §10.10.7.1, Eq. 10-18: M = Mns + δs·Ms, at each end / each axis.
    M1x = demand.M1x + δs * lt.M1ltx
    M2x = demand.M2x + δs * lt.M2ltx
    M1y = demand.M1y + δs * lt.M1lty
    M2y = demand.M2y + δs * lt.M2lty

    return (; M1x, M2x, M1y, M2y, δs, Q, method, sway_applied = δs > 1.0)
end

# --- AISC 360-16 Appendix 8 amplifier (B1·Mnt + B2·Mlt) ----------------------

"""
    design_column_moments(demand::MemberDemand,
                          story::Union{Nothing, StoryStability},
                          Pe1x, Pe1y; α=1.0) -> NamedTuple

Amplified beam-column design forces per AISC 360-16 Appendix 8:
`Mr = B1·Mnt + B2·Mlt` (Eq. A-8-1) and `Pr = Pnt + B2·Plt` (Eq. A-8-2).

- `Pe1x`, `Pe1y`: elastic critical buckling strengths assuming no lateral
  translation (Eq. A-8-5, `π²EI/Lc1²`) for the strong/weak axes; the caller
  computes these from the section (`compute_Pe1`).
- `story`: shared story record → `B2` (Eq. A-8-6); `nothing` or a non-sway story
  gives `B2 = 1`.
- `α`: 1.0 for LRFD, 1.6 for ASD.

`Cm` (Eq. A-8-4) is taken from the no-translation end moments (`M1x/M2x`,
`M1y/M2y`), per §App.8.2.1. `Mnt` is the demand envelope (`Mux`, `Muy`); `Mlt`
is the lateral-translation envelope from `demand.lt` (`0` when absent).

Returns `(; Mrx, Mry, Pr, B1x, B1y, B2, sway_applied)`. With no `lt`, no story,
or a non-sway story, `B2 = 1` and `Mlt = Plt = 0`, so `Pr = Pnt` and
`Mr = B1·Mnt` — i.e. the ordinary non-sway beam-column result.
"""
function design_column_moments(demand::MemberDemand,
                               story::Union{Nothing, StoryStability},
                               Pe1x, Pe1y; α::Float64 = 1.0)
    lt = demand.lt
    Plt = lt === nothing ? zero(demand.Pu_c) : lt.Plt
    Mltx_env = lt === nothing ? zero(demand.Mux) : Mltx(lt)
    Mlty_env = lt === nothing ? zero(demand.Muy) : Mlty(lt)
    return _aisc_amplified_forces(demand.Pu_c, demand.Mux, demand.Muy,
                                  demand.M1x, demand.M2x, demand.M1y, demand.M2y,
                                  demand.transverse_load, Plt, Mltx_env, Mlty_env,
                                  story, Pe1x, Pe1y; α = α)
end

"""
    _aisc_amplified_forces(Pnt, Mux_env, Muy_env, M1x, M2x, M1y, M2y,
                           transverse_load, Plt, Mltx_env, Mlty_env,
                           story, Pe1x, Pe1y; α=1.0) -> NamedTuple

Scalar core of the AISC 360-16 Appendix 8 beam-column amplification, shared by
the [`design_column_moments`](@ref) `MemberDemand` trait and the steel feasibility
checker so there is one implementation of `Mr = B1·Mnt + B2·Mlt` (Eq. A-8-1) and
`Pr = Pnt + B2·Plt` (Eq. A-8-2). Operating on bare scalars keeps the per-section
feasibility loop allocation-free and unit-agnostic (the caller supplies a single
consistent unit system; the checker passes SI N / N·m).

- `Pnt`, `Mux_env`, `Muy_env`: no-translation axial and moment envelopes (`Mnt`).
- `M1x/M2x`, `M1y/M2y`, `transverse_load`: feed `Cm` (Eq. A-8-4).
- `Plt`, `Mltx_env`, `Mlty_env`: lateral-translation axial and moment envelopes.
- `story`: shared story record → `B2` (Eq. A-8-6); `nothing`/non-sway → `B2 = 1`.
- `Pe1x`, `Pe1y`: no-translation elastic buckling strengths (Eq. A-8-5).

Returns `(; Mrx, Mry, Pr, B1x, B1y, B2, sway_applied)`. With no sway
(`Plt = Mlt = 0`, `B2 = 1`) this reduces to `Pr = Pnt`, `Mr = B1·Mnt`.
"""
function _aisc_amplified_forces(Pnt, Mux_env, Muy_env, M1x, M2x, M1y, M2y,
                                transverse_load::Bool, Plt, Mltx_env, Mlty_env,
                                story::Union{Nothing, StoryStability},
                                Pe1x, Pe1y; α::Float64 = 1.0)
    # B2 (Eq. A-8-6): story P-Δ amplifier; 1.0 if no sway story.
    B2 = (story === nothing || !is_sway_frame(story)) ? 1.0 : story_B2(story; α = α)

    # B1 (Eq. A-8-3) per axis; Cm from the no-translation end moments.
    # AISC 360-16 Commentary to §App.8.2.1: Pr in Eq. A-8-3 may be taken as the
    # first-order total Pnt + Plt (not the B2-amplified Pr), which is standard.
    Pr_for_B1 = Pnt + Plt
    Cmx = compute_Cm(M1x, M2x; transverse_loading = transverse_load)
    Cmy = compute_Cm(M1y, M2y; transverse_loading = transverse_load)
    B1x = compute_B1(Pr_for_B1, Pe1x, Cmx; α = α)
    B1y = compute_B1(Pr_for_B1, Pe1y, Cmy; α = α)

    Pr = amplify_axial(Pnt, Plt, B2)          # Eq. A-8-2: Pr = Pnt + B2·Plt

    # Eq. A-8-1: Mr = B1·Mnt + B2·Mlt.
    Mrx = amplify_moments(Mux_env, Mltx_env, B1x, B2)
    Mry = amplify_moments(Muy_env, Mlty_env, B1y, B2)

    sway_applied = B2 > 1.0 || Plt != 0 || Mltx_env != 0 || Mlty_env != 0
    return (; Mrx, Mry, Pr, B1x, B1y, B2, sway_applied)
end
