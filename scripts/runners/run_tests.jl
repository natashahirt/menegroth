# Run test suites (StructuralSizer, then StructuralSynthesizer).
# Usage: from repo root:
#   julia --project=StructuralSizer scripts/runners/run_tests.jl [sizer|synthesizer|all]
# Default: all.

ENV["SS_ENABLE_VISUALIZATION"] = "false"
using Pkg

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
