# Story-shell live-load deflection of one steel or composite span.
# The frame model's own deflection stays on MemberDemand. This record is the
# shell's live-load check, per span, against that span's own length.

"""
    SteelShellSpan(; L, Δ_LL, I_solved, solved)

Live-load deflection of one span of a steel or composite beam in the service
shell. SI: `L` and `Δ_LL` in metres, `I_solved` in m⁴.

`solved` names the section the shell was solved with. `I_solved` is that
section's inertia: `Ix` for bare steel.
"""
struct SteelShellSpan
    L::Float64
    Δ_LL::Float64
    I_solved::Float64
    solved::Union{String, Nothing}
end

function SteelShellSpan(; L, Δ_LL, I_solved, solved = nothing)
    L > 0 || throw(ArgumentError("a shell span needs a positive length"))
    Δ_LL >= 0 || throw(ArgumentError("shell live-load deflection must be non-negative"))
    I_solved > 0 || throw(ArgumentError("the solved inertia must be positive"))
    return SteelShellSpan(Float64(L), Float64(Δ_LL), Float64(I_solved), solved)
end

_shell_section_name(section) = hasproperty(section, :name) ? section.name : nothing

"""
Worst `(Δ / L) / limit` over the spans of demand `i`, with `section` in place
of the solved one. Zero when there is no limit or no span.

Each span's deflection scales by `I_solved / I_candidate`. The solved section
itself is checked at ratio one, whatever `I_candidate` evaluates to. The
caller passes the inertia the shell recorded: `Ix` for bare steel, and the
same service inertia the frame deflection check already uses for composite.

# ENGINEERING JUDGMENT
The ratio holds the span's share of load fixed. A stiffer candidate draws more
load in the shell, so the scaled value flatters it. The story-shell loop
re-solves until sections stop changing, and the final section is then checked
unscaled.
"""
function _steel_shell_ratio(checker, i::Int, section, I_candidate::Real)
    isempty(checker.shell_spans) && return 0.0
    lim = checker.deflection_limit
    (lim === nothing || lim <= 0) && return 0.0
    name = _shell_section_name(section)
    worst = 0.0
    for sp in checker.shell_spans[i]
        same = name !== nothing && sp.solved == name
        k = same ? 1.0 : sp.I_solved / I_candidate
        worst = max(worst, sp.Δ_LL * k / sp.L / lim)
    end
    return worst
end

"""Append the story-shell live-load check when demand `i` has spans."""
function _push_steel_shell_check!(checks, checker, i::Int, section, I_candidate, clause)
    (isempty(checker.shell_spans) || isempty(checker.shell_spans[i])) && return checks
    lim = checker.deflection_limit
    (lim === nothing || lim <= 0) && return checks
    r = _steel_shell_ratio(checker, i, section, I_candidate)
    push!(checks, CheckResult("shell_deflection_ll", r <= 1, r, r * lim, lim, clause))
    return checks
end
