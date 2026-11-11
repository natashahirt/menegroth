# ==============================================================================
# ASCE 7-22 §12.5 direction of loading, on the solved ELF cases
# ==============================================================================
#
# The ELF analysis solves each plan axis on its own. This file turns those
# solved cases into the seismic load effects QE that design uses: one per
# case for the independent procedure (§12.5.1.1), or the 100% + 30% sums of
# the orthogonal combination procedure (§12.5.1.2(a)). The analysis is
# linear, so a sum of cases is the sum of their loads.
#
# It also finds the Type 5 nonparallel system irregularity from the geometry:
# a wall, or a row F frame beam, that is not parallel to either plan axis.

# ASCE 7-22 §12.5.1.2(a) (corpus: asce-7-22, PDF page 183).
const ORTHOGONAL_SHARE = 0.30

"""
One seismic load effect `QE`: a signed sum of ELF cases of one purpose.

`direction` is the axis that carries 100% (`:x` or `:y`), and `torsion` is
the accidental torsion on that case. `terms` are `(index into
analysis.cases, factor)`.
"""
struct SeismicEffectCase
    label::Symbol
    direction::Symbol
    torsion::Symbol
    terms::Vector{Tuple{Int, Float64}}
end

"""
    seismic_effect_cases(analysis; orthogonal, purpose=:strength) -> Vector{SeismicEffectCase}

`orthogonal = false` is the independent procedure: each ELF case of `purpose`
is one effect, with factor 1.

`orthogonal = true` is the orthogonal combination procedure. For each axis,
each sign of accidental torsion on that axis, and each sign of the two
terms, the effect is `±QE(axis, ±AT) ± 0.3 QE(other axis)`. The 30% term is
the other axis at the center of mass, without accidental torsion. That is 16
effects.

# Citations
ASCE 7-22 §12.5.1.1 and §12.5.1.2(a) (corpus: asce-7-22, PDF page 183):
100% of the forces for one direction combined with 30% of the forces for the
perpendicular direction, such that each axis has the 100% factor in positive
and negative directions. Commentary C12.5.1.2 (PDF page 720) lists the 16
combinations `±QEX±AT ± 0.3QEY` and `±QEY±AT ± 0.3QEX`, with the 30% term at
the center of mass.
"""
function seismic_effect_cases(analysis::ElfStoryAnalysis; orthogonal::Bool,
                              purpose::Symbol=:strength)
    purpose in (:strength, :drift) || throw(ArgumentError(
        "seismic_effect_cases: purpose must be :strength or :drift, got :$purpose."))
    out = SeismicEffectCase[]
    if !orthogonal
        for (j, case) in enumerate(analysis.cases)
            case.purpose === purpose || continue
            push!(out, SeismicEffectCase(Symbol("QE$(j)_$(case.direction)_$(case.torsion)"),
                                         case.direction, case.torsion, [(j, 1.0)]))
        end
        isempty(out) && throw(ArgumentError(
            "seismic_effect_cases: the ELF analysis has no $purpose case."))
        return out
    end
    for d in (:x, :y)
        o = d === :x ? :y : :x
        companion = _elf_case_index(analysis, purpose, o, :none)
        for t in (:plus, :minus)
            main = _elf_case_index(analysis, purpose, d, t)
            for s1 in (1.0, -1.0), s2 in (1.0, -1.0)
                label = Symbol("QE_$(_sign_word(s1))$(d)_$(t)_$(_sign_word(s2))30$(o)")
                push!(out, SeismicEffectCase(label, d, t,
                    [(main, s1), (companion, s2 * ORTHOGONAL_SHARE)]))
            end
        end
    end
    return out
end

_sign_word(s) = s > 0 ? "pos" : "neg"

"""Index of the one ELF case with this purpose, direction, and torsion."""
function _elf_case_index(analysis::ElfStoryAnalysis, purpose::Symbol, direction::Symbol,
                         torsion::Symbol)
    hits = [j for (j, c) in enumerate(analysis.cases)
            if c.purpose === purpose && c.direction === direction && c.torsion === torsion]
    length(hits) == 1 || throw(ArgumentError(
        "seismic effect: expected one $purpose case for $direction $torsion, " *
        "found $(length(hits))."))
    return only(hits)
end

"""Story loads of one effect. Each term's ELF loads, scaled by its factor."""
function seismic_effect_loads(analysis::ElfStoryAnalysis, effect::SeismicEffectCase)
    loads = Asap.AbstractLoad[]
    for (j, f) in effect.terms
        c = analysis.cases[j]
        full = _elf_loads(analysis.levels, c.Fx_kN, c.Mz_kN_m,
                          elf_direction_vector(analysis, c.direction))
        append!(loads, scale_story_loads(full, f))
    end
    isempty(loads) && throw(ArgumentError(
        "seismic effect $(effect.label) has no story load."))
    return loads
end

"""
    seismic_effect_loads(struc, analysis, effect)

Rigid-diaphragm story loads of one effect.

The ordinary-wall stage passes the building. The forces and moments are the
master loads from [`seismic_effect_loads(analysis, effect)`](@ref). No rigid
links throws: this is not the flexible or semirigid distribution.
"""
function seismic_effect_loads(struc::BuildingStructure, analysis::ElfStoryAnalysis,
                              effect::SeismicEffectCase)
    isempty(struc.asap_rigid_links) && throw(ArgumentError(
        "seismic effect loads: this placement puts the force and the moment on the " *
        "rigid-diaphragm master. asap_rigid_links is empty."))
    return seismic_effect_loads(analysis, effect)
end

"""
    orthogonal_combination_required(; sdc, type1_horizontal_irregularity,
        type5_horizontal_irregularity, orthogonal_12_5_4_conditions_absent) -> Bool

True when §12.5 does not permit the independent procedure.

Category B never requires it. Category C requires it with a Type 5
irregularity. Categories D through F require it with a Type 1 or Type 5
irregularity, and unless 12.5.4(a)–(g) are stated absent.

# Citation
ASCE 7-22 §12.5.2, §12.5.3, §12.5.4 (corpus: asce-7-22, PDF pages 183–184).
"""
function orthogonal_combination_required(; sdc::Symbol,
                                         type1_horizontal_irregularity::Bool,
                                         type5_horizontal_irregularity::Bool,
                                         orthogonal_12_5_4_conditions_absent::Bool)
    sdc === :B && return false
    sdc === :C && return type5_horizontal_irregularity
    sdc in (:D, :E, :F) || throw(ArgumentError(
        "Seismic Design Category $(sdc) is not B, C, D, E, or F."))
    return type1_horizontal_irregularity || type5_horizontal_irregularity ||
           !orthogonal_12_5_4_conditions_absent
end

"""
    nonparallel_system_elements(struc, plan_axis; frames) -> Vector{String}

Vertical lateral force-resisting elements that are not parallel to either
plan axis. Empty means no Type 5 irregularity was found.

Every wall pier is checked. With `frames = true` (row F, where the moment
frames are part of the system), each horizontal frame element of every beam
is checked as well, since a beam's plan line is its frame's plane.

# Citation
ASCE 7-22 Table 12.3-1 Type 5 (corpus: asce-7-22, PDF page 180):
nonparallel system irregularity exists where vertical lateral
force-resisting elements are not parallel to the major orthogonal axes of
the seismic force-resisting system.
"""
function nonparallel_system_elements(struc::BuildingStructure, plan_axis::NTuple{2, Float64};
                                     frames::Bool)
    found = String[]
    for (i, wall) in enumerate(struc.walls)
        _pier_axis_direction(wall, plan_axis) === :skew || continue
        tx, ty, _, _ = _pier_plan_axes(wall)
        push!(found, "wall $i (tangent $(round(tx; digits=4)), $(round(ty; digits=4)))")
    end
    frames || return found
    for (i, beam) in enumerate(struc.beams)
        for el in _member_frame_elements(struc, beam)
            a = el.nodeStart.position
            b = el.nodeEnd.position
            dx = ustrip(u"m", b[1] - a[1])
            dy = ustrip(u"m", b[2] - a[2])
            hypot(dx, dy) > 1e-9 || continue
            _plan_vector_direction((dx, dy), plan_axis) === :skew || continue
            push!(found, "beam $i")
            break
        end
    end
    return found
end

"""
`:X` or `:Y` when plan vector `v` is parallel to the first or second plan
axis, else `:skew`.
"""
function _plan_vector_direction(v::Tuple{Real, Real}, plan_axis::NTuple{2, Float64})
    t = unit_plan_axis(v)
    e1, e2 = plan_axes(plan_axis)
    abs(t[1] * e1[1] + t[2] * e1[2]) >= 1 - 1e-8 && return :X
    abs(t[1] * e2[1] + t[2] * e2[2]) >= 1 - 1e-8 && return :Y
    return :skew
end
