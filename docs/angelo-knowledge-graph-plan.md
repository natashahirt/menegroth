# Angelo knowledge-graph plan for menegroth

_Status: 2026-07-12. Author: overnight setup session._

This document is the plan for standing up [angelo](https://github.com/natashahirt/angelo)
as menegroth's knowledge-graph layer. It covers what is already in place, the one
real blocker, and the design for the two big pieces still to build: re-extracting
the `corpus/` into a zettelkasten, and cross-linking that canon to the code with
synapse.

The goals (from the project owner) are to use the graph to **(a)** build more of
menegroth off shared knowledge, **(b)** capture the *why/what/how* reasoning in the
code, and **(c)** link code to the design examples and building-code documents that
live as PDFs in `corpus/`.

---

## 1. What angelo gives us, mapped to the three goals

Angelo is a multi-agent MCP toolkit with four cooperating stores:

| Store | What it is | Serves goal |
|---|---|---|
| **Memory — research tree** | Typed hierarchy (Project → Subproject → Phase → Entries; types: plan/decision/checkpoint/experiment/note/annotation/todo) recording *why* the code is the way it is. Markdown+YAML under `.memory/`, committed to git. | (b) |
| **Memory — code graph** | A live structural map of functions/classes/modules, auto-built by parsing the working tree into KGLite and queried with `codebase()`. Rebuilt automatically on every `git HEAD` change. | (b), (a) |
| **Zettelkasten** | A literature-review knowledge graph of `claim`/`quote`/`equation`/`dataset` notes with verbatim grounding, organized into **spines** (arrangements by a chosen dimension). This is the "more sophisticated upgrade of the corpus pipeline." | (c) |
| **Synapse** | A typed cross-store overlay linking memory (practice/code) to the zettelkasten (canon), with a practice-vs-canon matrix. | (c), (a) |

The **coordinator** orchestrates multi-agent runs over these (scope → design a task
DAG → execute in waves), and contributes the `create_extraction_graph`
grounded-extraction capability when the zettelkasten bundle is enabled.

**How this satisfies the goals**

- **(b) Why/what/how in the code** = the memory research tree (this document's
  companion, already initialized under `.memory/`) + the auto-built `codebase()`
  code graph. The tree carries reasoning a symbol graph cannot.
- **(c) Link code ↔ documents/examples** = zettelkasten (the re-extracted corpus)
  + synapse edges from code entries to the grounded claims/quotes they implement.
- **(a) Build more of menegroth** = agents read the tree + `codebase()` + the
  grounded canon before writing code, so new design-code implementations start from
  the cited clause and the existing patterns instead of from scratch.

---

## 2. What is already set up

- **angelo 1.7.8** installed with the `[zettelkasten]` extra into the conda base
  env (`/opt/miniconda3`).
- **`angelo init --cursor --with-zettelkasten`** scaffolded `.cursor/`:
  - `mcp.json` with four servers — `memory`, `coordinator`, `zettelkasten`,
    `memory-artifacts` — using absolute console-script paths (after
    `angelo doctor --fix`) so Cursor's GUI-launch PATH resolves them.
  - Rules: `memory`, `coordinator`, `zettelkasten`, `grounded-extraction`,
    `stream`, `operations`; skills `onboard-project`, `close-branch`.
- **`.memory/` research tree initialized** — project `menegroth`, an architecture
  subproject with a phase per package (Asap, StructuralSizer, StructuralSynthesizer,
  Plots/Visualization/Studies), and this program's setup checkpoint/decision/todos.
- `.gitignore` updated (angelo block): `.angelo/` runtime cache ignored, `.memory/`
  committed.

---

## 3. The one real blocker: kglite native crash

`memory.server` builds a KGLite graph at import; under this machine's conda
**Python 3.13** build that import crashes natively — **SIGFPE** (integer
divide-by-zero) at `memory/server.py:1284` (`kglite.KnowledgeGraph()`),
nondeterministically also SIGSEGV. In isolation `kglite.KnowledgeGraph()` works
(8 CPUs); the crash only appears *after* `memory.server`'s heavy imports (numpy /
pandas / model2vec / tokenizers), pointing at an FP-exception or thread-init
interaction between those extensions and the kglite Rust extension.

Because the in-editor MCP servers use the **same interpreter**
(`/opt/miniconda3/bin/python3.13`), they will hit the same crash. **This must be
fixed before the MCP servers, coordinator, or `create_extraction_graph` can run
in-editor.** The memory tree above was authored by writing `.memory/` files
directly through the crash-free `memory.storage` layer (angelo rebuilds its cache
from those files, so the result is identical).

**Reproduce:** `MEMORY_SKIP_EMBEDDINGS=1 python -c 'import memory.server'`

**Fix options (in rough order of preference):**

1. **Dedicated Python 3.11 venv for angelo.** Create `~/.venvs/angelo` on 3.11,
   `pip install "angelo[zettelkasten]"`, and repoint `.cursor/mcp.json` commands to
   that venv's `angelo-*` console scripts (or run `angelo init --local-paths` from
   it). 3.11 is angelo's most-tested line and most likely to dodge the 3.13/native
   ABI interaction.
2. **Rebuild/reinstall kglite** against 3.13 (`pip install --force-reinstall --no-binary kglite` if a source build is available), in case the `cp310-abi3` wheel is the culprit.
3. **Isolate and neutralize the offending import** — bisect which of numpy /
   tokenizers / model2vec flips FP-exception trapping, and set the corresponding
   thread/FP env (`RAYON_NUM_THREADS`, `TOKENIZERS_PARALLELISM=false`, etc.) in the
   server launch env.

A secondary, non-blocking degradation: the **embedding model** (model2vec
`minishlab/potion-retrieval-32M`, ~120 MB) is fetched from a GitHub-release mirror
(HF fallback), and both endpoints return 0 bytes on the current (throttled) network.
Until it caches, set `MEMORY_SKIP_EMBEDDINGS=1` and memory/zk search degrade to
keyword matching; embeddings backfill automatically once the model is present.

---

## 4. Zettelkasten: re-extracting the corpus (goal c, source side)

The existing `corpus/` pipeline (LangExtract → JSONL, surfaced by the `corpus.*`
MCP server) becomes the input to a richer, grounded zettelkasten. The corpus is
already curated in `corpus/manifests/sources.yml` and organized by **semantic role**
(codes, code_guides, examples, research, textbooks) and **code family** (aci, aisc,
csa, fib, foundations, slabs).

### 4.1 Pipeline

Use the coordinator's `create_extraction_graph` (the grounded-extraction pipeline):

```
prep (ingest + content-hash + seed hub note)
  → extractor  (read-only planner; claim + verbatim quote candidates, parallel per source)
  → scribe     (implementer; writes claim/quote/equation notes, serialized)
  → auditor    (checker, different model; verifies grounding + schema coverage)
  → synthesizer(once; cross-source + cross-spine links, _cross hubs)
  → memory     (records the run)
```

Grounding modalities to use for building codes:
- **quote** — verbatim clause text, checked against the source's cached fulltext.
- **equation** — transcribed LaTeX for design equations, with an optional cropped
  page snapshot (PDF text mangles math; snapshots are the visual ground-truth).
- **data** — for worked examples with numbers, a re-computable statistic over a
  `dataset` note (verified by recompute).

Large textbooks/codes auto-slice on chapter bookmarks (the pipeline handles the
~200k-char / ~60-page threshold), so full documents are extracted, not just the
first window.

### 4.2 Schema (the extraction rubric)

Define a **building-code schema** whose dimension tags are the questions we want
answerable across every source. Proposed dimensions:

- `scope` — what member/element/limit-state the clause governs (e.g. flexure, shear,
  punching shear, slenderness, development length, deflection, fire).
- `provision` — the normative rule / capacity equation / limit.
- `parameters` — symbols, units, and their definitions.
- `applicability` — material, geometry, and code-edition bounds.
- `example` — worked-example inputs/outputs (grounds `data` claims).
- `commentary` — rationale / intent (the "why" behind a provision).

Set `grounded: true` (every load-bearing claim needs a quote/equation/data
citation). Add a `synthesis` block so each spine is pre-scaffolded.

### 4.3 Spines (how the corpus is arranged)

Choose `synthesis_label` to control spine granularity. Recommended: **one spine per
code family** (`aci-318`, `aisc-360`, `fib-mc2010`, `foundations`, `slabs`), grouping
all sources for a family (the standard, its guide, its worked examples) under one
label. Because every family's spine shares the schema's dimension column-keys, the
spines **auto-unite into a matrix** — one row per family, one column per dimension —
which is exactly the "how do these codes treat punching shear?" comparison surface.

Keep worked **examples** as their own sources under the same family label so that a
design example's numbers attach to the same dimensions as the clause it demonstrates
— this is what makes goal (c) (code ↔ examples) fall out of the arrangement.

### 4.4 Migration from the current corpus pipeline

- Reuse `corpus/manifests/sources.yml` as the source list for
  `create_extraction_graph` (role/family/edition/tier map cleanly to schema tags and
  `synthesis_label`).
- Reuse `corpus/text/` normalized text and `corpus/sources/` PDFs for ingestion
  (page markers already exist for equation snapshots).
- The old `corpus.*` MCP tools (`search_extractions`, `get_clause`, …) can stay live
  during the transition; the zettelkasten supersedes them once spines are
  materialized.

---

## 5. Synapse: linking code to canon (goal c, link side; enables a)

Once both stores exist, run `synapse(action="build")` to mint typed cross-store
edges, then curate the high-value ones:

- **implements** — a code entry / `codebase()` node (e.g. the AISC 360 flexure
  checker, `StructuralSizer/src/members/codes/aisc/checker.jl`) ↔ the zettelkasten
  `claim`/`equation` for the clause it implements.
- **exemplifies** — a design-example note ↔ the code path that reproduces it (a
  regression anchor: the worked example's numbers become a test oracle).
- **contradicts / diverges** — where the implementation deliberately departs from or
  simplifies a clause (surfaced in the practice-vs-canon matrix).

This is what closes the loop for goal (a): an agent extending menegroth can ask
"what does the canon say about X, and where do we already implement it?" and get both
the grounded clause and the code, cross-linked.

---

## 6. Runbook (once the kglite blocker is fixed)

1. Fix kglite (Section 3) and restart Cursor; confirm `angelo-memory`,
   `angelo-coordinator`, `angelo-zettelkasten` show green in Settings → MCP.
2. Cache the embedding model on a good network (or `angelo doctor` /
   `prefetch_model`), then drop `MEMORY_SKIP_EMBEDDINGS`.
3. Call `sync()` then `health()` — confirm the cache rebuilt from the committed
   `.memory/` tree (10 entries) and `format_version: "1.0"`.
4. Deepen the code memory tree: per-package `decision`/`note` entries under the
   phase nodes (from the codebase exploration), each pinned with `files=`.
5. Author the building-code **schema**, then run `create_extraction_graph` over
   `corpus/manifests/sources.yml`, one `synthesis_label` per code family.
6. Materialize each spine's apex/dimension prose; verify with
   `spine(action="verify")`.
7. Run `synapse(action="build")`, curate `implements`/`exemplifies` edges, and open
   the matrix.

---

## 7. Open questions for the owner

- **Interpreter:** OK to stand up a dedicated Python 3.11 venv for the angelo MCP
  servers (Section 3, option 1)? It is the lowest-risk fix.
- **Zotero:** the zettelkasten can pull from Zotero (`zotero(action="lookup")`). Is
  there a menegroth Zotero library to wire in, or is `corpus/` the whole universe?
- **Spine granularity:** one spine per code family (recommended) vs per document vs a
  single pooled spine — confirm before a large extraction run mints the spines.
- **Old corpus pipeline:** retire `corpus.*` after migration, or keep both?
