include("utils.jl")
include("i_symm/_i_symm.jl")
include("hss_rect/_hss_rect.jl")
include("hss_round/_hss_round.jl")
include("generic/_generic.jl")

# Chapter I — Composite Members
include("composite/_composite.jl")

# Capacity Checker (implements AbstractCapacityChecker interface)
include("shell_deflection.jl")
include("checker.jl")
