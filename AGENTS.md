# AGENTS.md

## Cursor Cloud specific instructions

### Project overview

Julia-based structural engineering design automation tool (Julia 1.11.6). Monorepo with four local packages:

| Package | Role |
|---|---|
| `StructuralBase` | Shared types, Unitful custom units (kip, ksi, psf) |
| `StructuralSizer` | Member/slab/foundation sizing per ACI, AISC, NDS codes |
| `StructuralPlots` | GLMakie visualization themes |
| `StructuralSynthesizer` | Top-level orchestrator: geometry, analysis pipeline, visualization |

Two external packages (`external/Asap`, `external/AsapToolkit`) are **gitignored** and must be provided separately. They are structural FEA (finite element analysis) packages. Without the real implementations, stub packages are created during setup to allow `Pkg.instantiate()` to succeed; tests that depend on FEA (`test_aisc_beam_examples.jl`, `test_handcalc_beam.jl`, `test_aisc_column_examples.jl`, `test_tributary_workflow.jl`) will not produce meaningful results with stubs.

### Running tests

Tests that work without the real Asap package (run from repo root):

```bash
julia --project=. -e 'using Test, Unitful, StructuralSizer; using StructuralBase: StructuralUnits; include("StructuralSizer/test/cip/test_cip.jl")'
julia --project=. -e 'using Test, StructuralSizer, DelimitedFiles; using Unitful: @u_str, ustrip; using StructuralSizer: total_thrust; include("StructuralSizer/test/haile_vault/test_vault.jl")'
julia --project=. -e 'using Test, Unitful, StructuralSizer; using StructuralBase: StructuralUnits; include("StructuralSizer/test/foundations/test_spread_footing.jl")'
julia --project=StructuralSizer -e 'using Test, Meshes, Unitful, StructuralSizer; using StructuralBase: StructuralUnits; include("StructuralSizer/test/tributary/test_spans.jl")'
```

Tests requiring Meshes (e.g., `test_spans.jl`) must use `--project=StructuralSizer` since Meshes is not in the root project deps.

StructuralSynthesizer basic tests: `julia --project=StructuralSynthesizer -e 'using Pkg; Pkg.instantiate(); using Test, StructuralSynthesizer, StructuralSizer, Unitful, Meshes; include("StructuralSynthesizer/test/runtests.jl")'`

### Known issues

- **Case sensitivity**: `StructuralSynthesizer/src/core/_core.jl` includes `utils_asap.jl` but the file is `utils_ASAP.jl`. On Linux, a symlink `utils_asap.jl → utils_ASAP.jl` is needed (created during setup).
- **Gurobi**: The codebase imports Gurobi (commercial MIP solver) but gracefully falls back to HiGHS (open-source) when unavailable. No Gurobi license is needed.
- **GLMakie / visualization**: Requires a display server or headless rendering (xvfb). Visualization functions (`visualize()`, plotting) will fail without a display. Non-visualization tests work fine without it.
- **StructuralSynthesizer test error**: The "Slab sizing by slab groups" test in `StructuralSynthesizer/test/runtests.jl` has a pre-existing BoundsError (missing `find_faces!()` call for face_vertex_indices). The other 7 tests pass.

### Package management

- Use `julia --project=. -e 'using Pkg; Pkg.instantiate()'` from the repo root to resolve/install all deps.
- The root project activates all four local packages plus Asap/AsapToolkit.
- Sub-packages have their own `Project.toml`/`Manifest.toml`; use `--project=<SubPackage>` when running their tests directly.
