# Run pattern loading tests
using Pkg
Pkg.activate("StructuralSynthesizer")
Pkg.test("StructuralSynthesizer"; test_args=["test_pattern_loading"])
