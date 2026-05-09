# `corpus/` — Building-code corpus + extraction artifacts

This directory houses the project's building-code corpus and the artifacts
produced by the corpus pipeline (see plan: *LangExtract corpus pipeline*).

The corpus is organized along two orthogonal axes:

- **Semantic role** (folder, top-level under `sources/`): describes *what kind*
  of document it is, and is stable over time.
  - `codes/`        — authoritative standards (e.g., ACI 318, AISC 360, fib MC).
  - `code_guides/`  — official commentaries / committee reports / design guides
    (e.g., ACI 336, ACI 421-3R, AISC DG9, ACI 216R-89).
  - `examples/`     — worked design examples (spBeam / spSlab, biaxial /
    slenderness, punching catalogs, AISC exam, etc.).
  - `research/`     — theses, dissertations, papers.
  - `textbooks/`    — handbooks / textbooks.
- **Code family** (second level inside each role): mirrors the downstream
  Julia tree (`aci/`, `aisc/`, `csa/`, `fib/`, `foundations/`, `slabs/`, ...).

Pipeline stage is its own top-level axis (`sources/`, `text/`, `extractions/`,
`review/`), and **mirrors the same internal structure** so any artifact's
source is always at the same relative path under another stage:

```
corpus/
├── sources/         # raw PDFs (semantic + family layout)
├── text/            # normalized .txt outputs (mirrors sources/)
├── extractions/     # LangExtract .jsonl outputs (mirrors sources/)
├── review/          # LangExtract HTML visualizations (mirrors sources/)
└── manifests/       # committed YAML/JSON allowlist + curation/promotion status
```

Tier (initial-copy priority) is a **manifest field**, not a folder, so
prioritization can change without moving files.

## What is committed vs. ignored

By default, only `manifests/` (and an optional `samples/` for small committed
regression fixtures) are tracked in git. `sources/`, `text/`, `extractions/`,
and `review/` are ignored — see `.gitignore`.

## How files get here

`scripts/corpus/ingest.py` reads `corpus/manifests/sources.yml` and copies
each entry's origin file from the upstream `StructuralSizer/**/reference/`
tree into `corpus/sources/<role>/<family>/...`, mirroring the sibling `.txt`
into `corpus/text/`. PDF→text conversion reuses
`scripts/util/convert_pdfs_to_text.py` for any missing `.txt` files.

`scripts/corpus/extract.py` runs LangExtract tasks against `corpus/text/...`
and writes `corpus/extractions/...` JSONL plus `corpus/review/...` HTML
visualizations.

Promotion of accepted extractions into Julia (constants, tests, docs) is
performed by `scripts/runners/corpus_promote.jl`, which requires (per
workspace safety rule) a grounded source span, edition metadata, and a
reviewer decision before any change reaches engineering code.

## Querying the corpus (MCP server)

`scripts/corpus/mcp_server.py` is a stdio MCP server that exposes the
corpus and (when present) LangExtract structured extractions to the Cursor
agent as eight `corpus.*` tools (`list_sources`, `get_source_text`,
`search_text`, `page_window`, `search_extractions`, `get_extraction_by_id`,
`search_by_attributes`, `get_clause`). The Cursor rule
`.cursor/rules/corpus.mdc` directs the agent to prefer these tools over
raw file search whenever a question is derived from a published code or
guide.

The repo ships `.cursor/mcp.json.example` as a template. Per-developer
setup is a one-time copy into your **user-level** Cursor config (paths
must be **absolute** — Cursor silently ignores `cwd` for user-level MCP
entries) plus the official MCP Python SDK and PyYAML:

```bash
pip install mcp pyyaml
cp .cursor/mcp.json.example ~/.cursor/mcp.json
# then edit ~/.cursor/mcp.json to set absolute paths to your Python and
# to scripts/corpus/mcp_server.py — see AGENTS.md for OS-specific guidance
```

Restart Cursor after editing to pick up the server. The MCP server
caches the manifest at startup, so reload the server after editing
`corpus/manifests/sources.yml`.

Local diagnostics, no Cursor needed:

```bash
julia scripts/runners/corpus_mcp_serve.jl --self-test     # sanity check
python3 scripts/corpus/tests/test_mcp_tools.py            # tool unit tests
```

See `AGENTS.md` for the full tool surface, citation contract, and pipeline
overview.
