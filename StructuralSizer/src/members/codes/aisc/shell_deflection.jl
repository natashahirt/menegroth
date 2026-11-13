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
