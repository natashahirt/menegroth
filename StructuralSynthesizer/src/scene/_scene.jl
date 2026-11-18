# Scene packets: the binary visualization transport.
# Spec: docs/src/reference/scene_format.md

using JSON3
using LinearAlgebra: mul!

include("format.jl")
include("deflection.jl")
include("build.jl")
include("fields.jl")
include("components.jl")
include("mesh.jl")
include("variants.jl")
include("demo.jl")
