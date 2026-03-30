using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using StructuralSynthesizer

# Verify the new experiment functions are callable
methods_to_check = [
    :experiment_punching,
    :experiment_beam,
    :experiment_punching_reinforcement,
    :_resolve_punching_inputs,
    :evaluate_experiment,
    :list_experiments,
    :batch_evaluate,
]

for m in methods_to_check
    fn = getfield(StructuralSynthesizer, m)
    println("  $m  →  $(length(methods(fn))) method(s)")
end

# Verify list_experiments includes new types
exps = StructuralSynthesizer.list_experiments()
names = [e["name"] for e in exps["experiments"]]
println("\nExperiment types: $names")

expected = ["punching", "pm_column", "beam", "punching_reinforcement", "deflection", "catalog_screen"]
for e in expected
    @assert e in names "Missing experiment type: $e"
end
println("All $(length(expected)) experiment types present.")

# Verify tool registry includes new types
contract = StructuralSynthesizer.api_llm_contract()
exp_names = [e["name"] for e in contract["experiment_types"]]
println("\nContract experiment types: $exp_names")
for e in expected
    @assert e in exp_names "Missing from contract: $e"
end
println("Contract OK.")

println("\n=== All load checks passed ===")
