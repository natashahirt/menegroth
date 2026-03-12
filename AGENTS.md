# AGENTS.md

## Cursor Cloud specific instructions

### Overview

Structural Synthesizer (repo: **menegroth**) is a Julia codebase for automated structural engineering design. The dependency chain is `Asap` (FEM + units) → `StructuralSizer` (sizing library) → `StructuralSynthesizer` (building workflow + REST API).

### Julia version

The project targets **Julia 1.12.4** (see `Dockerfile`). The update script installs it to `/opt/julia-1.12.4/`.

### Critical setup: backslash paths

The `Project.toml` files use Windows-style backslash paths (`..\\external\\Asap`). On Linux these **must** be converted to forward slashes before `Pkg.instantiate()`. The update script handles this automatically via `sed`. If you see `PackageSpec` or path resolution errors, check that backslashes have been replaced.

### Critical setup: git submodule

`external/Asap` is a git submodule. Run `git submodule update --init --recursive` before any Julia operations. The update script handles this.

### Environment variables

| Variable | Purpose | Default |
|---|---|---|
| `SS_ENABLE_VISUALIZATION` | Disable GLMakie loading (set `false` for headless) | `false` |
| `SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD` | Skip heavy precompile (set `false` for faster startup) | `false` |
| `GRB_LICENSE_FILE` | Gurobi license file path | `/opt/gurobi/gurobi.lic` |

### Gurobi license

If the secrets `GRB_WLSACCESSID`, `GRB_WLSSECRET`, and `GRB_LICENSEID` are set, the update script writes `/opt/gurobi/gurobi.lic` automatically. Without Gurobi, HiGHS is used as a fallback — all MIP tests that require Gurobi will error but the rest of the suite passes.

### Running tests

```bash
# StructuralSizer (comprehensive — ~6 min)
SS_ENABLE_VISUALIZATION=false julia --project=StructuralSizer -e 'using Pkg; Pkg.test()'

# StructuralSynthesizer (integration — ~20 min)
SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer -e 'using Pkg; Pkg.test()'
```

### Running the API

```bash
SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer scripts/api/sizer_bootstrap.jl
```

Bootstrap mode: `/health` and `/status` respond immediately; `/design`, `/validate`, `/schema` become available after background loading (~60s). See `docs/src/getting_started.md` for full API docs.

### Known test issues on Linux / headless

- **`test_voronoi_vis.jl`** (1 error) — requires GLMakie display server; expected to fail in headless environments. All other tests pass cleanly.
- **Gurobi-dependent tests** error without a license (~39 in StructuralSizer). Ensure `GRB_LICENSE_FILE` is set. Without Gurobi, HiGHS is the fallback in production code.

### Runner scripts

Per workspace rules, runner scripts belong in `scripts/runners/`. Do not place ad-hoc run scripts in the project root. Prefer Julia runner scripts over shell one-liners.
