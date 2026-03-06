# AGENTS.md

## Cursor Cloud specific instructions

### Project overview

Julia 1.11.6 structural engineering design automation tool. Monorepo layout:

| Package | Role |
|---|---|
| `StructuralBase` | Shared types, Unitful custom units |
| `StructuralSizer` | Member/slab/foundation/vault sizing per ACI, AISC, NDS codes |
| `StructuralPlots` | GLMakie visualization themes |
| `StructuralSynthesizer` | Top-level orchestrator: geometry, FEA, analysis pipeline, visualization |
| `external/Asap` | FEA solver (cloned from `natashahirt/Asap.jl` on GitHub, gitignored) |

### Setup

The `external/Asap` package is gitignored. Clone it during setup:
```bash
gh repo clone natashahirt/Asap.jl external/Asap
```

Windows backslash paths in `Project.toml` files (`external\\Asap`) must be converted to forward slashes for Linux.

### Running tests

From the repo root with `--project=.`:
```bash
julia --project=. StructuralSizer/test/runtests.jl
```

The test suite runs ~3100 tests. Known issues:
- **Gurobi license**: ~39 tests error because they require a Gurobi WLS license (commercial optimizer). HiGHS (open-source) handles everything else. Set `GRB_WLSACCESSID`, `GRB_WLSSECRET`, `GRB_LICENSEID` secrets to enable Gurobi.
- **Method redefinition**: `StructuralSynthesizer` has a pre-existing `_convex_hull_2d` duplicate definition that prevents precompilation but loads fine at runtime.
- **`const` redefinition**: Some concrete beam tests hit `invalid redefinition of constant` on Julia 1.11.

### Package management

- `julia --project=. -e 'using Pkg; Pkg.instantiate()'` resolves all deps.
- If `LinearAlgebra` compat in `StructuralSizer/Project.toml` is set to `1.12.0`, relax it to `1.11.0` for Julia 1.11.

### GLMakie / visualization

Requires a display server or headless rendering (xvfb). Non-visualization code works fine without it.
