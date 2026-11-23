# ==============================================================================
# Shared story stability record — bridges ACI 318-11 §10.10 and AISC 360-16 App.8
# ==============================================================================
#
# ACI's sway procedure (δs = 1/(1 − Q)) and AISC's story P-Δ procedure
# (B2 = 1/(1 − α·ΣPu/Pe,story)) consume the *same* first-order story data: the
# total factored vertical load, the story shear that produced a drift, that
# drift, and the story height. `StoryStability` holds that shared data once so a
# single solved-model extraction feeds both material codes; thin adapters map it
# onto the existing `SwayStoryProperties` (ACI) and `B2StoryProperties` (AISC).

"""
    StoryStability

Material-agnostic first-order story data for approximate second-order design.
A single record, populated once from the solved frame/shell model, drives both
the ACI 318-11 §10.10.5/§10.10.7 sway index `Q` and the AISC 360-16 Appendix 8
story amplifier `B2`.

# Fields
- `ΣPu`: total factored vertical (gravity) load on the story [force]
- `V`:  first-order story shear that produced the drift `Δ` (ACI `Vus` / AISC `H`) [force]
- `Δ`:  first-order inter-story drift under `V` (ACI `Δo` / AISC `ΔH`) [length]
- `L`:  story height, joint-to-joint (ACI `lc` / AISC `L`) [length]
- `Pmf`: vertical load carried by moment-frame columns in the story, for the
         AISC `RM` factor (Eq. A-8-8); `0` for a fully braced/shear-wall story [force]
- `ΣPc`: Σ of column critical buckling loads for the ACI §10.10.7.3(b) `ΣPu/ΣPc`
         fallback; `0` when only the `Q`-method is used [force]

# Units
`ΣPu`, `V`, `Pmf`, `ΣPc` must share one force unit and `Δ`, `L` one length unit;
both `Q = ΣPu·Δ/(V·L)` and `B2` are dimensionless, so any consistent system works
(production RC uses kip/in). Values are stored as `Float64`.
"""
struct StoryStability
    ΣPu::Float64
    V::Float64
    Δ::Float64
    L::Float64
    Pmf::Float64
    ΣPc::Float64
end

"""
    StoryStability(; ΣPu, V, Δ, L, Pmf=0.0, ΣPc=0.0)

Keyword constructor. `Pmf` defaults to `0` (braced/shear-wall story, `RM = 1`)
and `ΣPc` to `0` (ACI `Q`-method only, no `ΣPu/ΣPc` fallback).
"""
function StoryStability(; ΣPu, V, Δ, L, Pmf = 0.0, ΣPc = 0.0)
    return StoryStability(Float64(ΣPu), Float64(V), Float64(Δ),
                          Float64(L), Float64(Pmf), Float64(ΣPc))
end

# --- ACI 318-11 §10.10.5.2 adapter -------------------------------------------

"""
    SwayStoryProperties(s::StoryStability) -> SwayStoryProperties

Project the shared record onto ACI's sway-story record. `ΣPc` carries through
for the §10.10.7.3(b) `ΣPu/ΣPc` fallback.
"""
SwayStoryProperties(s::StoryStability) =
    SwayStoryProperties(s.ΣPu, s.ΣPc, s.V, s.Δ, s.L)

"""
    stability_index(s::StoryStability) -> Float64

ACI 318-11 §10.10.5.2 story stability index `Q = ΣPu·Δ/(V·L)`. A story is sway
when `Q > 0.05`.
"""
stability_index(s::StoryStability) = stability_index(SwayStoryProperties(s))

"""
    is_sway_frame(s::StoryStability) -> Bool

`true` when `Q > 0.05` (ACI 318-11 §10.10.5.2).
"""
is_sway_frame(s::StoryStability) = stability_index(s) > 0.05

# --- AISC 360-16 Appendix 8 adapter ------------------------------------------

"""
    B2StoryProperties(s::StoryStability; α=1.0) -> B2StoryProperties

Project the shared record onto AISC's story record and compute `RM`, `Pe,story`,
and `B2`. `α = 1.0` for LRFD, `1.6` for ASD.
"""
B2StoryProperties(s::StoryStability; α::Float64 = 1.0) =
    B2StoryProperties(s.ΣPu, s.V, s.L, s.Δ; Pmf = s.Pmf, α = α)

"""
    story_B2(s::StoryStability; α=1.0) -> Float64

AISC 360-16 Eq. A-8-6 story amplifier `B2 = 1/(1 − α·ΣPu/Pe,story) ≥ 1`.
"""
story_B2(s::StoryStability; α::Float64 = 1.0) = B2StoryProperties(s; α = α).B2
