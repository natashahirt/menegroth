#=
Solve one structure under each DesignParameters and write them into one scene.

    julia --project=StructuralSynthesizer scripts/runners/design_variants.jl

This file does not design the office. A design script calls

    write_design_variants(path, struc, params)

which solves each parameter set, restoring the structure after every solve, and
refuses to overwrite an existing file. `append_variant!(path, design)` adds one
solved design to a scene of the same geometry.
=#

println("write_design_variants(path, struc, params) writes every solved design into one .mgscene.")
println("append_variant!(path, design) adds one design. The geometry hash must match the file.")
