# Run test suites (StructuralSizer, then StructuralSynthesizer).
# Usage: julia --project=StructuralSizer scripts/runners/run_tests.jl [sizer|synthesizer|all]
#        Or from repo root: julia --project=StructuralSizer scripts/runners/run_tests.jl
# Default: all. Run from repo root.

ENV["SS_ENABLE_VISUALIZATION"] = "false"
using Pkg

root = @__DIR__
while !isfile(joinpath(root, "Project.toml")) && dirname(root) != root
    root = dirname(root)
end
root = dirname(root)  # scripts/runners -> scripts -> repo root
cd(root)

target = length(ARGS) >= 1 ? ARGS[1] : "all"
if target in ("sizer", "all")
    println("=== StructuralSizer tests ===")
    Pkg.activate("StructuralSizer")
    Pkg.test()
end
if target in ("synthesizer", "all")
    println("=== StructuralSynthesizer tests ===")
    Pkg.activate("StructuralSynthesizer")
    Pkg.test()
end
