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

"""One seismic design-story-drift comparison against Table 12.12-1."""
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
end

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

Scale each `:strength` ELF case by `combo.E`. `:drift` cases are omitted:
their coefficient is for drift, not for the strength combination. The story
force is placed on global X or Y according to the case direction. An empty
vector means `combo.E` is zero.

# Citation
ASCE 7-22 §2.3.6 (corpus: asce-7-22, PDF page 69). The horizontal factor is
the `E` field of `combo`. `Ev` and the 0.15 snow companion are not applied
to these story forces.
"""
function factored_seismic_cases(analysis::ElfStoryAnalysis, combo::LoadCombination)
    out = FactoredLateralCase[]
    for (j, case) in enumerate(analysis.cases)
        case.purpose === :strength || continue
        n = length(case.Fx_kN)
        if case.direction === :x
            Fx_in = case.Fx_kN
            Fy_in = zeros(Float64, n)
        elseif case.direction === :y
            Fx_in = zeros(Float64, n)
            Fy_in = case.Fx_kN
        else
            throw(ArgumentError(
                "factored_seismic_cases: direction must be :x or :y; got $(repr(case.direction))."))
        end
        Fx, Fy, Mz = factored_lateral_components(combo, Fx_in, Fy_in, case.Mz_kN_m; load=:E)
        isempty(Fx) && continue
        push!(out, FactoredLateralCase(combo.name, :E, j, Fx, Fy, Mz))
    end
    return out
end
