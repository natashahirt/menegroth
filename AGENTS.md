# AGENTS.md

## Cursor Cloud specific instructions

### Overview

**menegroth** is a Julia codebase for automated structural engineering design. The dependency chain is `Asap` (FEM + units) → `StructuralSizer` (sizing library) → `StructuralSynthesizer` (building workflow + REST API).

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

### Nightly Doc Audit (Cursor Cloud Agent)

The **Nightly Doc Audit** workflow (`.github/workflows/doc-audit.yml`) launches a Cursor Cloud Agent to align `docs/src/` with the Julia source. It runs on schedule, on push to `main` (doc/source paths), or via **Actions → Run workflow**.

**Required:** Repo secret `CURSOR_API_KEY` (from [Cursor Dashboard → Integrations](https://cursor.com/dashboard)).

**"Repository not accessible to the parent installation"**

This error means the Cursor API key’s **GitHub App installation** does not have access to this repo. Fix it by:

1. **Install the Cursor GitHub App** for the account that owns the repo: [github.com/apps/cursor](https://github.com/apps/cursor). During install, choose the correct account (user or org) and **select this repository** (or “All repositories”).
2. **Use an API key from the same Cursor team** that performed that installation. Keys are per team; the key in `CURSOR_API_KEY` must belong to the team whose GitHub App has access to `natashahirt/menegroth`.
3. **Org repos:** If the repo is under an organization, install the app on the **organization** and grant access to this repo (or all repos). User-level install only covers your personal repos.

After fixing, re-run the workflow. The Launch step now fails explicitly (exit 1) when the API returns an error, so the run is red and the error is visible in the log.

### Weekly Trace Coverage Audit (Cursor Cloud Agent)

The **Trace Coverage Audit** workflow (`.github/workflows/trace-audit.yml`) launches a Cursor Cloud Agent to ensure every structurally significant decision in the design pipeline emits trace events. It runs weekly on Monday, on push to `main` (source paths), or via **Actions → Run workflow**.

The audit has two layers:
1. **Static script** (`scripts/runners/audit_trace_coverage.jl`): Checks `TRACE_REGISTRY` entries for `emit!` calls, discovers unregistered decision functions, detects `tc` threading gaps, and verifies `explain_feasibility` coverage across all checker types. Run locally with: `julia --project=StructuralSizer scripts/runners/audit_trace_coverage.jl`
2. **Agent prompt** (`scripts/prompts/trace-audit.md`): Heuristic-based instructions that guide the Cursor Cloud Agent through a semantic audit — discovering decision points, verifying trace contracts, and checking the `tc` threading chain from `design_building` to leaf functions.

**Required:** Same `CURSOR_API_KEY` as the doc audit.
