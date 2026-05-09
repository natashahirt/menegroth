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
| `SLACK_BOT_TOKEN` | Slack Web API (bot user OAuth token, `xoxb-...`) for workflows and doc-audit notifications | — |

### Slack bot

You need the **same token value in two independent stores**: (1) **GitHub** — *Settings → Secrets and variables → Actions* → **Secrets** (not Variables); name `SLACK_BOT_TOKEN`. This is what `.github/workflows/cursor-slack-test.yml` reads. (2) **Cursor** — *Cloud Agents / My Secrets* with the same name for `scripts/prompts/doc-audit.md`. Cursor secrets are **not** visible to GitHub Actions and vice versa.

After you **add or remove bot scopes** in the Slack app settings, you must **reinstall the app** to the workspace (OAuth reinstall) and copy the new **Bot User OAuth Token** into GitHub, Cursor, and `secrets/slack_bot_token`. Old `xoxb-` tokens keep their previous scopes until replaced.

For local use, you can store the same token in `secrets/slack_bot_token` (the whole `secrets/` directory is gitignored). Smoke-test the bot without Actions or Cursor:

```bash
julia --project=StructuralSynthesizer scripts/runners/slack_bot_local_smoke.jl
```

The default smoke test opens a DM and needs the **`im:write`** bot scope. If your app only has **`chat:write`**, set `SLACK_SMOKE_CHANNEL` to a channel ID where the bot is already a member (for example the nightly docs channel) and the script will skip `conversations.open`:

```bash
set SLACK_SMOKE_CHANNEL=C0AL4NPK1SA
julia --project=StructuralSynthesizer scripts/runners/slack_bot_local_smoke.jl
```

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

### Building-code corpus & MCP server

The repo ships a curated building-code corpus under `corpus/` (manifest at
`corpus/manifests/sources.yml`) and a local **MCP server** that exposes the
corpus and (when present) LangExtract structured extractions as queryable
tools. The Cursor rule `.cursor/rules/corpus.mdc` directs the agent to
prefer these MCP tools over raw file search whenever a question is derived
from a published code or guide.

Pipeline overview:

```text
StructuralSizer/**/reference/   →  scripts/corpus/ingest.py
                                →  corpus/sources/ + corpus/text/
                                →  scripts/corpus/extract.py (LangExtract)
                                →  corpus/extractions/ (JSONL, grounded)
                                →  scripts/runners/corpus_promote.jl
                                →  Julia constants / tests / docs
```

#### Tool surface (eight `corpus.*` tools)

| Tool | Purpose |
|---|---|
| `list_sources` | Browse manifest entries (filter by family / role / tier / edition). |
| `get_source_text` | Read a slice of a source's normalized text by character offsets. |
| `search_text` | Regex/substring search across `corpus/text/` (fallback path). |
| `page_window` | Read text spanning a PDF page range. |
| `search_extractions` | Query LangExtract JSONL for grounded structured entries. |
| `get_extraction_by_id` | Fetch a single extraction by stable id. |
| `search_by_attributes` | Typed attribute filter for a class. |
| `get_clause` | Best-effort clause lookup with explicit `confidence` field. |

Pre-extraction state: extraction tools return `status: "no_extractions_available"`
with a hint instead of failing, so the server is useful from day one for
text search.

#### MCP registration

The repo intentionally does **not** ship a `.cursor/mcp.json` — Cursor
treats project-level and user-level entries with the same `name` as
separate registrations (it does *not* dedupe), and the right Python
invocation differs between Mac and Windows (see "Why the asymmetry"
below). Instead we ship `.cursor/mcp.json.example` as a template that
you copy into your **user-level** Cursor config and edit once per
machine.

User-level config locations:

- macOS / Linux : `~/.cursor/mcp.json`
- Windows       : `%USERPROFILE%\.cursor\mcp.json`

If a user-level config already exists with other servers, merge the
`menegroth-corpus` entry into the existing `mcpServers` object rather
than replacing the file.

##### Quick setup — Windows

1. Install Python ≥ 3.10 from [python.org](https://www.python.org/downloads/)
   (check **"Add Python to PATH"** during install) **or** from the
   Microsoft Store (auto-adds `python` and `python3` aliases).
2. Install the runtime deps:

   ```powershell
   python -m pip install mcp pyyaml
   ```

3. Find the absolute path of that interpreter — `where python` from a
   shell — then write `%USERPROFILE%\.cursor\mcp.json`. Use absolute
   paths for **both** the interpreter and the script (`cwd` is silently
   ignored in user-level configs — see the cheat sheet below):

   ```json
   {
     "mcpServers": {
       "menegroth-corpus": {
         "command": "C:\\Users\\<you>\\AppData\\Local\\Programs\\Python\\Python313\\python.exe",
         "args": [
           "C:\\absolute\\path\\to\\menegroth\\scripts\\corpus\\mcp_server.py"
         ]
       }
     }
   }
   ```

   You can use bare `"command": "python"` on Windows since GUI launches
   inherit the user `PATH`, but absolute paths are more robust against
   future Python re-installs that shuffle which interpreter `python`
   resolves to.
4. Restart Cursor (or "Reload MCP Servers"). The server should appear
   connected in Settings → MCP.

##### Quick setup — macOS

1. Install Python ≥ 3.10 via Homebrew (or the python.org installer):

   ```bash
   brew install python@3.13
   ```

   The prefix is `/usr/local/bin/` on Intel and `/opt/homebrew/bin/`
   on Apple Silicon.
2. Install the runtime deps into that exact interpreter (Homebrew
   Python is PEP 668 "externally managed" — `--break-system-packages`
   is the intended escape hatch for non-formula installs):

   ```bash
   /usr/local/bin/python3.13 -m pip install --break-system-packages mcp pyyaml
   ```

3. Write `~/.cursor/mcp.json` using absolute paths for **both** the
   interpreter and the script (`cwd` is silently ignored in user-level
   configs — see the cheat sheet below):

   ```json
   {
     "mcpServers": {
       "menegroth-corpus": {
         "command": "/usr/local/bin/python3.13",
         "args": [
           "/absolute/path/to/menegroth/scripts/corpus/mcp_server.py"
         ]
       }
     }
   }
   ```

4. Restart Cursor (or "Reload MCP Servers").

##### Why the asymmetry

Cursor inherits its child-process `PATH` from however the OS launched it:

- **Windows**: GUI launches inherit the user `PATH` from the registry,
  which Python installers populate. So bare `python` works.
- **macOS**: GUI launches (Spotlight, Dock, Finder) inherit launchd's
  default `PATH` — `/usr/bin:/bin:/usr/sbin:/sbin` only. **Neither**
  `/usr/local/bin/` (Intel Homebrew) nor `/opt/homebrew/bin/` (Apple
  Silicon Homebrew) is included. Bare `python` / `python3` therefore
  resolves to Apple's system interpreter (`/usr/bin/python3` =
  Python 3.9), which is too old for the `mcp` SDK
  (`requires_python: >=3.10`). The only reliable fix is an absolute
  path in user-level `~/.cursor/mcp.json`.

##### Failure-mode cheat sheet

| Symptom in Cursor's MCP panel | Likely cause | Fix |
|---|---|---|
| Two `menegroth-corpus` entries appear | Both a project `.cursor/mcp.json` and `~/.cursor/mcp.json` exist; Cursor lists them separately, it does not merge by name | Delete (or rename to `.example`) the project-level `.cursor/mcp.json` so only the user-level entry remains |
| New manifest entry doesn't show up in `list_sources` after `ingest --apply` | The MCP server caches the manifest at startup (`CorpusIndex._sources` is set on first call and never refreshed); manifest edits and new ingests are invisible until restart | "Reload MCP Servers" in Cursor (or restart Cursor) after every `corpus/manifests/sources.yml` change |
| `can't open file '/Users/<you>/scripts/corpus/mcp_server.py'` (or similar `$HOME`-rooted path) | Cursor silently ignores the `cwd` field in user-level `~/.cursor/mcp.json` and launches from the user home directory | Put the **absolute** path to `mcp_server.py` in `args` instead of relying on `cwd`; remove the `cwd` field |
| `spawn python ENOENT` (Windows) | Python not on the user `PATH` (or only `py` is installed) | Reinstall Python with "Add to PATH" checked, install via Microsoft Store, or set `"command": "py"` with `"args": ["-3", "scripts/corpus/mcp_server.py"]` |
| `spawn <path>/python3.13 ENOENT` (macOS) | Homebrew Python uninstalled or a different minor is installed | `brew install python@3.13`, or change `command` in `~/.cursor/mcp.json` to whatever `ls /usr/local/bin/python3.*` (Intel) or `ls /opt/homebrew/bin/python3.*` (Apple Silicon) shows |
| `TypeError: dataclass() got an unexpected keyword argument 'slots'` | Pre-fix bug; should not recur | Pull latest `scripts/corpus/mcp_schemas.py` |
| `ERROR: the 'mcp' Python SDK is required` | `mcp` not installed in the interpreter Cursor is using | `pip install mcp` against that exact interpreter (use its absolute path, not bare `python`) |
| `Error executing tool list_sources: No module named 'yaml'` | `pyyaml` not installed in the interpreter Cursor is using | `pip install pyyaml` against that exact interpreter |
| `Connection failed: MCP error -32000: Connection closed` with no other context | Server crashed during init; the real traceback is *above* this line in Cursor's MCP log panel | Read upward in the panel for the underlying Python exception |

##### Verifying which interpreter Cursor is actually using

When in doubt, temporarily add at the top of `build_server` in
`scripts/corpus/mcp_server.py`:

```python
import sys
sys.stderr.write(f"[corpus-mcp] running on {sys.executable} ({sys.version})\n")
```

Restart the MCP server; the line appears in Cursor's MCP log panel
(tagged `[error]` because it's on stderr — that's normal for FastMCP and
not a real error). Remove the diagnostic when done.

#### Local diagnostics (no Cursor needed)

```bash
# Sanity check that the manifest loads and sources resolve:
julia scripts/runners/corpus_mcp_serve.jl --self-test

# Run unit tests for the tool functions:
python3 scripts/corpus/tests/test_mcp_tools.py

# End-to-end stdio handshake against the live MCP server:
python3 scripts/runners/corpus_mcp_smoke.py
```

#### Citation contract

Every Julia change derived from a corpus result must cite, in a comment, the
`source_id`, the clause / equation reference, and (when available) the PDF
page from the tool result's `page_range`. See `.cursor/rules/corpus.mdc` for
the full rule.

### Weekly Trace Coverage Audit (Cursor Cloud Agent)

The **Trace Coverage Audit** workflow (`.github/workflows/trace-audit.yml`) launches a Cursor Cloud Agent to ensure every structurally significant decision in the design pipeline emits trace events. It runs weekly on Monday, on push to `main` (source paths), or via **Actions → Run workflow**.

The audit has two layers:
1. **Static script** (`scripts/runners/audit_trace_coverage.jl`): Checks `TRACE_REGISTRY` entries for `emit!` calls, discovers unregistered decision functions, detects `tc` threading gaps, and verifies `explain_feasibility` coverage across all checker types. Run locally with: `julia --project=StructuralSizer scripts/runners/audit_trace_coverage.jl`
2. **Agent prompt** (`scripts/prompts/trace-audit.md`): Heuristic-based instructions that guide the Cursor Cloud Agent through a semantic audit — discovering decision points, verifying trace contracts, and checking the `tc` threading chain from `design_building` to leaf functions.

**Required:** Same `CURSOR_API_KEY` as the doc audit.
