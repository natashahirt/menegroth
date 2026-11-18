# ==============================================================================
# Strength combinations and story drift on solved lateral cases
# ==============================================================================
#
# The story analyses keep the Chapter 27 wind force and the §12.8 seismic
# force as computed. A strength combination scales that force by its W or E
# factor. Dead, live, and snow stay on the gravity load path.
#
# Seismic design story drift is judged against Table 12.12-1. Wind story
# displacement is reported and is not judged against that table.

"""
One seismic design-story-drift comparison against Table 12.12-1.

`direction` is the plan axis the drift is measured along. `effect` is
`:independent` for one ELF case, or the §12.5.1.2 combination label, whose
100% axis may differ from `direction`.
"""
struct SeismicStoryDriftCheck
    "Story index from the ELF level."
    story::Int
    direction::Symbol
    torsion::Symbol
    "Magnitude of the center-of-mass design story drift [m]."
    drift_m::Float64
    "Allowable story drift Δa, or Δa/ρ when rho was passed [m]."
    allowable_m::Float64
    passes::Bool
    effect::Symbol
end

SeismicStoryDriftCheck(story, direction, torsion, drift_m, allowable_m, passes) =
    SeismicStoryDriftCheck(story, direction, torsion, drift_m, allowable_m, passes, :independent)

"""
    check_seismic_story_drift(analysis; risk_category, system, rho=nothing)

One check per story of each `:drift` ELF case. `:strength` cases are not
drift cases. `risk_category` and `system` are required and are not inferred.
Pass `rho` only for the §12.12.1.1 moment-frame limit.

The drift is the center-of-mass value. The edge drift of §12.8.6.5 for a
Type 1 horizontal irregularity is not substituted, because this function
does not classify irregularity.

# Citation
ASCE 7-22 §12.12.1 (corpus: asce-7-22, PDF page 194) and Table 12.12-1
(PDF page 195), through [`story_drift_is_allowed`](@ref).
"""
function check_seismic_story_drift(analysis::ElfStoryAnalysis;
                                   risk_category::Symbol,
                                   system::Symbol,
                                   rho::Union{Real, Nothing}=nothing)
    checks = SeismicStoryDriftCheck[]
    for case in analysis.cases
        case.purpose === :drift || continue
        for (i, lv) in enumerate(analysis.levels)
            Δ = case.design_drift_m[i]
            Δa = allowable_story_drift(lv.story_height_m, risk_category, system; rho)
            push!(checks, SeismicStoryDriftCheck(
                lv.story, case.direction, case.torsion, abs(Δ), Δa,
                story_drift_is_allowed(Δ, lv.story_height_m, risk_category, system; rho)))
        end
    end
    return checks
end

"""
Interstory displacement of a wind case at the rigid-diaphragm master.

`drift_x_m` and `drift_y_m` are the master's displacement minus the master
below, with the base taken as zero. There is no allowable. Table 12.12-1
is a seismic limit.
"""
struct WindStoryDriftReport
    story::Int
    kind::Symbol
    direction::NTuple{2, Float64}
    direction_2::Union{Nothing, NTuple{2, Float64}}
    sign_1::Int
    sign_2::Int
    drift_x_m::Float64
    drift_y_m::Float64
end

"""
    wind_story_drift_report(analysis) -> Vector{WindStoryDriftReport}

Report the interstory master displacement of every wind case. This does not
compare the displacement to a limit.
"""
function wind_story_drift_report(analysis::WindStoryAnalysis)
    reports = WindStoryDriftReport[]
    n = length(analysis.levels)
    for case in analysis.cases
        length(case.ux_m) == n || throw(ArgumentError(
            "wind_story_drift_report: a case has $(length(case.ux_m)) X displacements and $n levels."))
        length(case.uy_m) == n || throw(ArgumentError(
            "wind_story_drift_report: a case has $(length(case.uy_m)) Y displacements and $n levels."))
        x_below = 0.0
        y_below = 0.0
        for (i, lv) in enumerate(analysis.levels)
            dx = case.ux_m[i] - x_below
            dy = case.uy_m[i] - y_below
            push!(reports, WindStoryDriftReport(
                lv.story, case.kind, case.direction, case.direction_2,
                case.sign_1, case.sign_2, dx, dy))
            x_below = case.ux_m[i]
            y_below = case.uy_m[i]
        end
    end
    return reports
end

"""Lateral story forces after one combination's W or E factor."""
struct FactoredLateralCase
    combination::Symbol
    "`:W` or `:E`."
    load::Symbol
    "Index into the source analysis `cases`."
    case_index::Int
    Fx_kN::Vector{Float64}
    Fy_kN::Vector{Float64}
    Mz_kN_m::Vector{Float64}
end

"""
    factored_wind_cases(analysis, combo) -> Vector{FactoredLateralCase}

Scale every Chapter 27 case by `combo.W`. An empty vector means `combo.W`
is zero. Dead and live factors are not applied to these forces.

# Citation
ASCE 7-22 §2.3.1 combinations 4a and 5a (corpus: asce-7-22, PDF page 68).
The factor is the `W` field of `combo`.
"""
function factored_wind_cases(analysis::WindStoryAnalysis, combo::LoadCombination)
    out = FactoredLateralCase[]
    for (j, case) in enumerate(analysis.cases)
        Fx, Fy, Mz = factored_lateral_components(
            combo, case.Fx_kN, case.Fy_kN, case.Mz_kN_m; load=:W)
        isempty(Fx) && continue
        push!(out, FactoredLateralCase(combo.name, :W, j, Fx, Fy, Mz))
    end
    return out
end

"""
    factored_seismic_cases(analysis, combo) -> Vector{FactoredLateralCase}

Scale each `:strength` ELF case by `combo.E`, the factor on Eh. `:drift`
cases are omitted: their coefficient is for drift, not for the strength
combination. The story force is split into global X and Y along the case's
plan axis. An empty vector means `combo.E` is zero. `Ev` is not part of this
horizontal story force.

# Citation
ASCE 7-22 §2.3.6 and Eqs. 12.4-1 and 12.4-3 (corpus: asce-7-22, PDF pages
69 and 182–183). The horizontal factor is the `E` field of `combo`.
"""
function factored_seismic_cases(analysis::ElfStoryAnalysis, combo::LoadCombination)
    out = FactoredLateralCase[]
    for (j, case) in enumerate(analysis.cases)
        case.purpose === :strength || continue
        d = elf_direction_vector(analysis, case.direction)
        Fx_in = case.Fx_kN .* d[1]
        Fy_in = case.Fx_kN .* d[2]
        Fx, Fy, Mz = factored_lateral_components(combo, Fx_in, Fy_in, case.Mz_kN_m; load=:E)
        isempty(Fx) && continue
        push!(out, FactoredLateralCase(combo.name, :E, j, Fx, Fy, Mz))
    end
    return out
end

"""Largest stability coefficient on the ELF drift cases. ASCE 7-22 §12.8.7."""
function _max_drift_theta(analysis::ElfStoryAnalysis)
    θmax = 0.0
    found = false
    for case in analysis.cases
        case.purpose === :drift || continue
        for θ in case.θ
            θ === nothing && throw(ArgumentError(
                "ordinary wall stage: a drift case has no stability coefficient θ."))
            isfinite(θ) || throw(ArgumentError(
                "ordinary wall stage: a drift case has a non-finite θ ($θ)."))
            θmax = max(θmax, Float64(θ))
            found = true
        end
    end
    found || throw(ArgumentError(
        "ordinary wall stage: the ELF analysis has no drift case, so θ is unknown."))
    return θmax
end

"""
    _scale_seismic_action(action, multiplier) -> WallAction

Scale one seismic pier resultant by the §12.8.7 factor.

The factor is 1 where θ ≤ 0.10 and `1/(1−θ)` where `0.10 < θ ≤ θmax`.
Gravity and wind are not passed here. `Ev` is applied later from dead load,
so this scale does not touch it.

# Citation
ASCE 7-22 §12.8.7 (corpus: asce-7-22, PDF page 188): where θ is greater
than 0.10 but less than or equal to θmax, displacements and member forces
may be multiplied by 1.0/(1−θ).
"""
function _scale_seismic_action(action::WallAction, multiplier::Real)
    m = Float64(multiplier)
    (isfinite(m) && m > 0) || throw(ArgumentError(
        "ordinary wall stage: the P-delta multiplier must be a positive " *
        "finite number; got $multiplier."))
    return WallAction(action.N * m, action.V * m, action.M * m,
                      action.Vo * m, action.Mo * m)
end

"""
First-order seismic pier action with the §12.8.7 factor on each term.

A one-direction effect is multiplied by that direction's `1/(1−θ)`. An
orthogonal effect scales each term by its own direction before the sum.
Gravity and `Ev` are not in this action.

# Citation
ASCE 7-22 §12.8.7 (corpus: asce-7-22, PDF page 188).
"""
function _pdelta_scaled_qe(struc, elf, pier, effect::SeismicEffectCase)
    wall = struc.walls[pier.wall_index]
    level = _elf_level_index(struc, elf, wall)
    length(elf.displacements) == length(elf.cases) || throw(ArgumentError(
        "ordinary wall stage: P-delta scaling needs one stored displacement " *
        "per ELF case."))
    N = V = M = Vo = Mo = 0.0
    for (j, f) in effect.terms
        c = elf.cases[j]
        m = f * _drift_multiplier(elf, c.direction, c.torsion, level)
        loads = _elf_loads(struc, elf.levels, c.Fx_kN, c.Mz_kN_m,
                           elf_direction_vector(elf, c.direction))
        a = pier_wall_action(wall, pier, elf.displacements[j];
                             loads, fixed_end_from_loads=true)
        N += m * a.N
        V += m * a.V
        M += m * a.M
        Vo += m * a.Vo
        Mo += m * a.Mo
    end
    return WallAction(N, V, M, Vo, Mo)
end

"""
Multiplier stored on the drift case of the same direction and torsion.

A strength case leaves `multiplier` empty. In this linear model Δ scales
with V, so θ of the strength case equals θ of the matching drift case.
"""
function _drift_multiplier(elf::ElfStoryAnalysis, direction::Symbol, torsion::Symbol,
                           level_index::Int)
    hits = ElfCase[]
    for case in elf.cases
        case.purpose === :drift || continue
        case.direction === direction && case.torsion === torsion || continue
        push!(hits, case)
    end
    length(hits) == 1 || throw(ArgumentError(
        "ordinary wall stage: expected one drift case for $direction $torsion, " *
        "found $(length(hits))."))
    1 <= level_index <= length(only(hits).multiplier) || throw(ArgumentError(
        "ordinary wall stage: level $level_index is outside the drift case."))
    m = only(hits).multiplier[level_index]
    m === nothing && throw(ArgumentError(
        "ordinary wall stage: the $direction $torsion drift case has no " *
        "P-delta multiplier at level $level_index."))
    return Float64(m)
end

"""
ELF level whose story height is this pier.

`Wall.story` is the skeleton story at the bottom of the pier. The matching
level is the lowest ELF level above that elevation. Its θ is the stability
coefficient of the story between the two.
"""
function _elf_level_index(struc::BuildingStructure, elf::ElfStoryAnalysis, wall)
    haskey(struc.skeleton.stories, wall.story) || throw(ArgumentError(
        "ordinary wall stage: wall story $(wall.story) is not on the skeleton."))
    z_bot = ustrip(u"m", struc.skeleton.stories[wall.story].elevation)
    best = 0
    best_z = Inf
    for (i, lv) in enumerate(elf.levels)
        lv.elevation_m > z_bot + 1e-6 || continue
        if lv.elevation_m < best_z
            best = i
            best_z = lv.elevation_m
        end
    end
    best == 0 && throw(ArgumentError(
        "ordinary wall stage: wall story $(wall.story) at z = $(z_bot) m " *
        "has no ELF level above it."))
    return best
end

"""
    _story_drift_with_pdelta(analysis; risk_category, system, orthogonal=false)
        -> (checks, multipliers)

[`check_seismic_story_drift`](@ref), with each design story drift multiplied
by that story's §12.8.7 factor. `rho` is not passed: Δa/ρ is the
moment-frame limit.

With `orthogonal = true` the drifts are those of the §12.5.1.2(a) effects:
`QE(axis, ±AT) ± 0.3 QE(other axis)` on the drift cases. Each effect is read
along both plan axes, and each reading is one check. The overall sign is not
repeated, because the limit is on the magnitude.

# Engineering judgment
A combined drift along one axis is multiplied by the largest §12.8.7 factor
of that axis's drift cases at that story. §12.8.7 defines θ for one story and
one direction of force, not for a sum of two directions.

# Citation
ASCE 7-22 §12.8.7 (corpus: asce-7-22, PDF page 188) and §12.12.1
(PDF page 194), Table 12.12-1 (PDF page 195). §12.5.1.2 (PDF page 183):
drift requirements shall be satisfied for all combinations. Commentary
C12.5.1.2 (PDF page 720): use the combinations to determine the maximum story
drift in each orthogonal axis.
"""
function _story_drift_with_pdelta(analysis::ElfStoryAnalysis;
                                  risk_category::Symbol,
                                  system::Symbol,
                                  orthogonal::Bool=false)
    orthogonal && return _orthogonal_story_drift(analysis; risk_category, system)
    checks = SeismicStoryDriftCheck[]
    multipliers = Float64[]
    for case in analysis.cases
        case.purpose === :drift || continue
        for (i, lv) in enumerate(analysis.levels)
            m = case.multiplier[i]
            m === nothing && throw(ArgumentError(
                "ordinary wall stage: a drift case has no P-delta multiplier."))
            # ASCE 7-22 §12.8.7 (corpus: asce-7-22, PDF page 188):
            # displacements may be multiplied by 1.0/(1−θ). The factor is
            # already 1 where θ ≤ 0.10.
            Δ = case.design_drift_m[i] * Float64(m)
            Δa = allowable_story_drift(lv.story_height_m, risk_category, system)
            push!(multipliers, Float64(m))
            push!(checks, SeismicStoryDriftCheck(
                lv.story, case.direction, case.torsion, abs(Δ), Δa,
                story_drift_is_allowed(Δ, lv.story_height_m, risk_category, system)))
        end
    end
    isempty(checks) && throw(ArgumentError(
        "ordinary wall stage: the ELF analysis has no drift case to amplify."))
    return checks, multipliers
end

"""Largest §12.8.7 factor of the drift cases along `direction` at level `i`."""
function _axis_drift_multiplier(analysis::ElfStoryAnalysis, direction::Symbol, i::Int)
    m = 0.0
    for case in analysis.cases
        case.purpose === :drift && case.direction === direction || continue
        mi = case.multiplier[i]
        mi === nothing && throw(ArgumentError(
            "ordinary wall stage: a drift case has no P-delta multiplier."))
        m = max(m, Float64(mi))
    end
    m > 0 || throw(ArgumentError(
        "ordinary wall stage: no drift case along $direction at level $i."))
    return m
end

function _orthogonal_story_drift(analysis::ElfStoryAnalysis; risk_category::Symbol,
                                 system::Symbol)
    checks = SeismicStoryDriftCheck[]
    multipliers = Float64[]
    for effect in seismic_effect_cases(analysis; orthogonal=true, purpose=:drift)
        # ±QE is the same magnitude. Keep the positive 100% term.
        first(effect.terms)[2] > 0 || continue
        for (i, lv) in enumerate(analysis.levels)
            along = Dict(:x => 0.0, :y => 0.0)
            for (j, f) in effect.terms
                c = analysis.cases[j]
                other = c.direction === :x ? :y : :x
                along[c.direction] += f * c.design_drift_m[i]
                along[other] += f * c.design_cross_drift_m[i]
            end
            Δa = allowable_story_drift(lv.story_height_m, risk_category, system)
            for axis in (:x, :y)
                m = _axis_drift_multiplier(analysis, axis, i)
                # ASCE 7-22 §12.8.7 (corpus: asce-7-22, PDF page 188).
                Δ = along[axis] * m
                push!(multipliers, m)
                push!(checks, SeismicStoryDriftCheck(
                    lv.story, axis, effect.torsion, abs(Δ), Δa,
                    story_drift_is_allowed(Δ, lv.story_height_m, risk_category, system),
                    effect.label))
            end
        end
    end
    isempty(checks) && throw(ArgumentError(
        "ordinary wall stage: the ELF analysis has no drift case to combine."))
    return checks, multipliers
end
