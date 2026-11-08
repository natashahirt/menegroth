# =============================================================================
# Slab bars from a story shell
# =============================================================================
#
# The story shell is one elastic analysis of the floor (ACI 318-11 §13.5.1,
# corpus: aci-318-11, page 248; §8.3.1, page 112). Each triangle's moment
# tensor goes through the same area-design transform as the flat-plate shell.
# That transform is selected by the FEA method (`panel_shell()` by default).
# The bar depth is selected by the panel's spanning behavior.
#
# The beams read the same load cases. Their shell demand only ever raises the
# tributary demand: the gross shell can carry load the cracked slab would
# shed onto the beam.

"""
    StoryPanelDesign(q_dead, q_live, h, span_axis, floor)

One panel's inputs for story-shell reinforcement.

`q_dead` and `q_live` are service pressures. `floor` is a floor system
(`OneWay()`, `TwoWay()`, …) and selects the effective depth. `span_axis`
is the primary reinforcement direction.
"""
struct StoryPanelDesign{D, L}
    q_dead::D
    q_live::L
    h::typeof(1.0u"m")
    span_axis::NTuple{2, Float64}
    floor::AbstractConcreteSlab

    function StoryPanelDesign(q_dead, q_live, h::Length, span_axis::NTuple{2, Float64},
                              floor::AbstractConcreteSlab)
        h = uconvert(u"m", h)
        h > zero(h) || throw(ArgumentError("a story panel needs a positive thickness"))
        new{typeof(q_dead), typeof(q_live)}(q_dead, q_live, h, span_axis, floor)
    end
end

"""One bar layer for a one-way panel. Two orthogonal layers otherwise."""
_story_bar_depth(::OneWaySpanning, h::Length; cover, bar_diameter) =
    effective_depth(h; cover = cover, bar_diameter = bar_diameter, two_way = false)

_story_bar_depth(::SpanningBehavior, h::Length; cover, bar_diameter) =
    effective_depth(h; cover = cover, bar_diameter = bar_diameter, two_way = true)

"""Moments `[Mxx, Myy, Mxy]` of every shell, in the element frame (N·m/m)."""
function _story_moment_field(model)
    n = length(model.shell_elements)
    out = Vector{NTuple{3, Float64}}(undef, n)
    ws = Asap.ShellMomentWorkspace()
    buf = zeros(3)
    u = model.u
    @inbounds for k in 1:n
        Asap.bending_moments!(buf, model.shell_elements[k], u, ws)
        out[k] = (buf[1], buf[2], buf[3])
    end
    return out
end

"""
    StoryLoadCases

Unit solves of a story shell and the factored combinations that scale them.

Two kinds of base case are solved: the beam weight alone (`GravityLoad` on
every frame), and 1 Pa on one panel with nothing else. A combination is
`weight × (weight case) + Σ panel[i] × (unit case i)`, with `weight = αD`
and `panel[i]` in Pa. `u_*` are global displacement vectors. `M_*` are each
triangle's `[Mxx, Myy, Mxy]` in its element frame, hogging positive (Asap).

The combinations are ASCE 7 §2.3.1 `1.2D + 1.6L` and `1.4D`, with the live
load placed by [`generate_load_patterns`](@ref) when the FEA method asks for
patterns (ACI 318-11 §13.7.6, corpus: aci-318-11, page 261).
"""
struct StoryLoadCases
    u_weight::Vector{Float64}
    u_unit::Vector{Vector{Float64}}
    M_weight::Vector{NTuple{3, Float64}}
    M_unit::Vector{Vector{NTuple{3, Float64}}}
    combinations::Vector{@NamedTuple{weight::Float64, panel::Vector{Float64}}}
end

"""
    story_load_cases(model, panel_index, panels, method=panel_shell()) -> StoryLoadCases

Solve the base cases of a processed story shell. One solve per panel, plus
the beam weight. The model is left on the loads it had when this was called.
"""
function story_load_cases(
    model,
    panel_index,
    panels::AbstractVector{<:StoryPanelDesign},
    method::FEA = panel_shell(),
)
    if method.pattern_loading && method.pattern_mode != :fea_resolve
        throw(ArgumentError(
            "story shell pattern loading re-solves the shell; got $(method.pattern_mode)"))
    end
    model.processed || throw(ArgumentError("story load cases need a processed model"))
    npan = length(panels)
    shells = model.shell_elements
    length(panel_index) == length(shells) || throw(ArgumentError(
        "panel_index must name every shell element"))
    groups = [Asap.ShellElement[] for _ in 1:npan]
    @inbounds for (k, el) in enumerate(shells)
        i = panel_index[k]
        1 <= i <= npan || throw(ArgumentError("panel_index $i is outside 1:$npan"))
        push!(groups[i], el)
    end

    saved = model.loads
    function solve_on(loads)
        model.loads = loads
        Asap.update!(model; loads_only = true)
        Asap.solve!(model)
        return copy(model.u), _story_moment_field(model)
    end
    u_unit = Vector{Vector{Float64}}(undef, npan)
    M_unit = Vector{Vector{NTuple{3, Float64}}}(undef, npan)
    for i in 1:npan
        loads = Asap.AbstractLoad[]
        isempty(groups[i]) || push!(loads, Asap.AreaLoad(groups[i], 1.0u"Pa"))
        u_unit[i], M_unit[i] = solve_on(loads)
    end
    u_weight, M_weight = solve_on(
        Asap.AbstractLoad[ld for ld in saved if ld isa Asap.GravityLoad])
    model.loads = saved
    Asap.update!(model; loads_only = true)
    Asap.solve!(model)

    qD = [ustrip(u"Pa", panel.q_dead) for panel in panels]
    qL = [ustrip(u"Pa", panel.q_live) for panel in panels]
    patterns = method.pattern_loading ?
        generate_load_patterns(npan) : [fill(:dead_plus_live, npan)]
    combinations = @NamedTuple{weight::Float64, panel::Vector{Float64}}[]
    for pat in patterns, (αD, αL) in _LOAD_COMBOS
        q = [αD * qD[i] + (pat[i] === :dead_plus_live ? αL * qL[i] : 0.0) for i in 1:npan]
        push!(combinations, (weight = αD, panel = q))
    end
    return StoryLoadCases(u_weight, u_unit, M_weight, M_unit, combinations)
end

"""Triangle `k`'s moment tensor under combination `c`, element frame, hogging positive."""
function _combined_moment(cases::StoryLoadCases, c, k::Int)
    Mxx, Myy, Mxy = c.weight .* cases.M_weight[k]
    @inbounds for (i, q) in enumerate(c.panel)
        m = cases.M_unit[i][k]
        Mxx += q * m[1]
        Myy += q * m[2]
        Mxy += q * m[3]
    end
    return (Mxx, Myy, Mxy)
end

"""
    story_panel_reinforcement(model, panel_index, panels, method=panel_shell();
        cases, fc, fy, cover, bar_diameter) -> Vector{ElementRebarField}

Size the bars in each panel of a processed story-shell model.

`panels` is one [`StoryPanelDesign`](@ref) per panel, in `panel_index` order.
`method` is the area-design FEA. `cases` are the factored load cases from
[`story_load_cases`](@ref). Pass them in when the beams use the same solves.

[`OneWayMomentCoefficients`](@ref) is not a shell tensor, so that method
throws. Beam sections are not changed.
"""
function story_panel_reinforcement(
    model,
    panel_index,
    panels::AbstractVector{<:StoryPanelDesign},
    method::FEA = panel_shell();
    cases::StoryLoadCases = story_load_cases(model, panel_index, panels, method),
    fc::Pressure,
    fy::Pressure = Rebar_60.Fy,
    cover::Length = 0.75u"inch",
    bar_diameter::Length = 0.5u"inch",
)
    method.design_approach == :area || throw(ArgumentError(
        "story shell bars use area design; got $(method.design_approach)"))
    npan = length(panels)
    shells = model.shell_elements
    n = length(shells)
    length(panel_index) == n || throw(ArgumentError(
        "panel_index must name every shell element"))

    ex = Vector{NTuple{2, Float64}}(undef, n)
    ey = Vector{NTuple{2, Float64}}(undef, n)
    cx = Vector{Float64}(undef, n)
    cy = Vector{Float64}(undef, n)
    area = Vector{Float64}(undef, n)
    @inbounds for k in 1:n
        el = shells[k]
        ex[k] = (el.LCS[1][1], el.LCS[1][2])
        ey[k] = (el.LCS[2][1], el.LCS[2][2])
        cx[k], cy[k] = _triangle_centroid(el)
        area[k] = el.area
    end

    faces = Vector{NTuple{4, Float64}}(undef, n)
    @inbounds for k in 1:n
        combos = [_combined_moment(cases, c, k) for c in cases.combinations]
        faces[k] = _envelope_design_faces(
            method, panels[panel_index[k]].span_axis, ex[k], ey[k], combos)
    end

    fields = Vector{ElementRebarField}(undef, npan)
    for i in 1:npan
        moments = AreaDesignMoment[]
        for k in 1:n
            panel_index[k] == i || continue
            Mx_bot, My_bot, Mx_top, My_top = faces[k]
            push!(moments, AreaDesignMoment(
                k, cx[k], cy[k], area[k], Mx_bot, My_bot, Mx_top, My_top))
        end
        panel = panels[i]
        d = _story_bar_depth(spanning_behavior(panel.floor), panel.h;
                             cover = cover, bar_diameter = bar_diameter)
        d > zero(d) || throw(ArgumentError(
            "panel $i has no effective depth at thickness $(panel.h)"))
        fields[i] = _build_element_rebar_field(
            moments, panel.h, d, fc, fy, method.moment_transform)
    end
    return fields
end

function story_panel_reinforcement(
    ::Any,
    ::Any,
    ::AbstractVector{<:StoryPanelDesign},
    ::OneWayMomentCoefficients;
    kwargs...,
)
    throw(ArgumentError(
        "ACI 318-11 §8.3.3 coefficients are span moments, not a shell moment tensor"))
end
