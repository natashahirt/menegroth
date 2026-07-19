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

## 3. The kglite native crash — RESOLVED via a dedicated Python 3.11 venv

**Original problem.** `memory.server` builds a KGLite graph at import; under this
machine's conda **Python 3.13** build that import crashed natively — **SIGFPE**
(integer divide-by-zero) at `memory/server.py:1284` (`kglite.KnowledgeGraph()`),
nondeterministically also SIGSEGV. In isolation `kglite.KnowledgeGraph()` worked;
the crash only appeared *after* `memory.server`'s heavy imports (numpy / pandas /
model2vec / tokenizers), pointing at an FP-exception or thread-init interaction
between those native extensions and the kglite Rust extension. Because the
in-editor MCP servers used the same interpreter (`/opt/miniconda3/bin/python3.13`),
they hit the same crash.

**Fix applied (2026-07-12) — option 1, the dedicated venv.**

- Created **`~/.venvs/angelo`** on **Python 3.11.1** and installed
  `angelo[zettelkasten]` **1.7.8** into it (from the local clone `/tmp/angelo_src`;
  scientific deps are cp311 wheels, and `cryptography 49` was compiled from source
  via the system Rust 1.84 — no prebuilt cp311 x86_64 wheel exists).
- Repointed all four servers in `.cursor/mcp.json` (memory, coordinator,
  zettelkasten, memory-artifacts) from `/opt/miniconda3/bin` to
  `~/.venvs/angelo/bin`.
- **Verified:** `import memory.server` and `KnowledgeGraph()` no longer SIGFPE
  under 3.11 (the crash was specific to the conda 3.13 native stack). The server
  rebuilds the kglite cache from the 25 committed `.memory/` files cleanly, and an
  MCP `initialize` + `tools/list` handshake returns tools fast — **memory 16,
  coordinator 15, zettelkasten 21**.

**Reproduce the original crash (for reference):**
`MEMORY_SKIP_EMBEDDINGS=1 /opt/miniconda3/bin/python -c 'import memory.server'`

### 3a. Embeddings: `MEMORY_SKIP_EMBEDDINGS=1` (temporary)

The servers **eagerly load** the model2vec embedding model
(`minishlab/potion-retrieval-32M`) at startup. On the current throttled network the
HuggingFace `xet` chunked download stalls, which blocked the servers from finishing
init and advertising tools — the symptom *"server loaded but no tools/prompts/
resources."* Worked around by setting **`MEMORY_SKIP_EMBEDDINGS=1`** in each server's
`env` in `mcp.json`; the servers now boot instantly and search falls back to keyword
matching (fine for the 25-entry tree). A background `snapshot_download` with HF `xet`
disabled is caching the model; **once cached, delete the skip-embeddings lines from
`mcp.json` and reload Cursor** to restore semantic search.

> **Zettelkasten uses a *separate* switch.** `MEMORY_SKIP_EMBEDDINGS=1` only
> governs `memory.embedders`' own eager load. The zettelkasten indexing path
> (`zettelkasten/embeddings.py::_build_embedder`) reads
> **`ZETTEL_SKIP_EMBEDDINGS`** instead, and only short-circuits before the
> model2vec download when *that* var is `1`. Because `create_extraction_graph`
> runs its prep (source-graph + spine builds → note indexing) **in the
> coordinator process**, a missing `ZETTEL_SKIP_EMBEDDINGS` made the coordinator
> block ~7 min on the throttled HF download and exceed the MCP client timeout
> (`Connection closed`), even though `MEMORY_SKIP_EMBEDDINGS` was set. Fix:
> set **`ZETTEL_SKIP_EMBEDDINGS=1`** on the **zettelkasten and coordinator**
> servers too. Grounding (verbatim string-match) and coverage are deterministic
> and unaffected; only semantic `note search` / `suggest` / richer `remine`
> classification want vectors, and those matter at Stage 4 (spines), not during
> extraction. **Backfill path:** once the model is cached, drop both
> `*_SKIP_EMBEDDINGS` lines and reload — indexes rebuild from the on-disk `.md`
> notes on next load, so no re-extraction is needed.

> Note: the GitHub-release mirror for the model fails with `SSL:
> CERTIFICATE_VERIFY_FAILED` (the `/usr/local` Python 3.11 lacks a system cert
> bundle); the HuggingFace fallback works, so this is not blocking.

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

**Facet tags (stamped by the scribe, not schema dimensions).** Beyond the
dimension tags, every note carries cross-cutting facet tags so the corpus can be
re-arranged into other spines later without re-extraction: `family:*`,
`edition:*`, `limit-state:*`, `element:*`, `material:*`, and — see below —
`clause:*`. These are additional tags (they don't violate `strict`, which only
requires *one* valid dimension tag); they are set by scribe instruction, since
the schema YAML can't express per-note tag values.

### 4.2a Join keys: preserve `corpus_id`, address at clause level

Two decisions here are **load-bearing and expensive to redo after extraction**, so
they are locked into the schema description as a contract:

- **Document join key = the graph name.** `create_extraction_graph` takes
  `sources[].name` as the kebab-case **graph id**. Set it to the manifest
  `corpus_id` verbatim (`aci-318-11`, `sp-de-combined-footing-aci318-14` — already
  kebab-case). The zk source graph then *is* `aci-318-11`, so every existing Julia
  citation `corpus: aci-318-11` upgrades from "reference to an old-pipeline file"
  to a live zk edge with **no migration mapping**. Minting fresh ids instead would
  inherit a stale-citation remap problem — so we carry the identifiers across and
  swap the backend underneath them.
- **Clause join key = a per-note alias + tag.** The pipeline already mints
  **sub-document notes** (the scribe writes `claim`+`quote` pairs per dimension —
  ~60 claims/source, not one blob/PDF), so a clause like `aci-318-11 §8.5.1`
  becomes several notes (provision/equation/parameters/applicability). But nothing
  auto-stamps a machine-parseable clause id. So the scribe MUST stamp each such
  note with a `clause:<section>` tag AND an alias `<corpus_id>#<section>` (e.g.
  `aci-318-11#8.5.1`). Note primary ids are server-minted from the title, so the
  clause key rides the **alias** channel (resolvable), not the id. This is what
  lets synapse pin an implementation to the exact provision and makes the
  "suspicious number → exact clause" report loop land — instead of resolving only
  to the whole code.

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

#### 4.3a The manifest taxonomy IS the zk seed structure

`sources.yml`'s `family × role × tier` axes map directly onto zk structure, so the
corpus's organizing metadata survives even as the pipeline underneath it is
replaced — nothing about the arrangement is invented fresh:

- **`family`** (`aci` / `aisc` / `fib` / `foundations` / `walls` / …) → **spines**
  (the `synthesis_label` per family; the primary matrix axis in §4.3).
- **`role`** (`codes` / `code_guides` / `examples` / `research` / `textbooks`) →
  **note-type + authority + an additional spine axis.** `codes` are normative
  `provision`/`equation` claims; `code_guides`/`commentary` are `commentary`;
  `examples` become the **machine-readable case notes** (`finding` + `data`
  grounding) that generate tests (goal c → a); `research`/`textbooks` are
  supporting `concept`/`model` context. Role is a second spine axis we can add: a
  "normative canon vs. worked-practice vs. background" arrangement that reuses the
  same notes.
- **`tier`** (1–4) → **priority / authority weighting on retrieval.** Stamp
  `tier:<n>` as a facet tag so ranked retrieval and synapse can prefer the
  higher-authority source when two sources speak to the same clause (a primary
  standard outranks a secondary guide).

### 4.4 Migration from the current corpus pipeline

- Reuse `corpus/manifests/sources.yml` as the source list for
  `create_extraction_graph`; set each `sources[].name = corpus_id` (§4.2a) and map
  `family → synthesis_label`, `role → note-type/authority`, `tier → tier:<n>` facet
  (§4.3a).
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

**Resolution rides the join keys from §4.2a.** A Julia citation `corpus: aci-318-11`
resolves to the source graph (document level); a citation carrying a clause
(`aci-318-11 §8.5.1`) resolves to the exact note via its `<corpus_id>#<section>`
alias (clause level). So synapse edges reconstruct mechanically from citations
already dotted through the code and tests — no hand-mapping — and an `implements`
edge points at the provision itself, which is what makes the "suspicious number →
exact clause" report loop land.

---

## 6. Runbook

1. ~~Fix kglite~~ **DONE (Section 3):** reload Cursor and confirm `angelo-memory`,
   `angelo-coordinator`, `angelo-zettelkasten` show green with their tools in
   Settings → MCP (they run from `~/.venvs/angelo/bin`).
2. ~~Cache the embedding model, then re-enable embeddings.~~ **DONE:** the model
   (`minishlab/potion-retrieval-32M`) is cached (HF hub cache; mirror URL 404s). The
   `*_SKIP_EMBEDDINGS` flags were removed from all three servers and replaced with
   `HF_HUB_OFFLINE=1` + `ANGELO_EMBED_SOURCE=hf` so model load is deterministic
   cache-only (verified: offline load in ~2.5 s, 512-dim). Reload once to pick this up.
3. Call `sync()` then `health()` — confirm the cache rebuilt from the committed
   `.memory/` tree (25 entries) and `format_version: "1.0"`.
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

- **Interpreter:** ✅ Resolved — a dedicated Python 3.11 venv (`~/.venvs/angelo`)
  now backs the angelo MCP servers (Section 3).
- **Zotero:** the zettelkasten can pull from Zotero (`zotero(action="lookup")`). Is
  there a menegroth Zotero library to wire in, or is `corpus/` the whole universe?
- **Spine granularity:** one spine per code family (recommended) vs per document vs a
  single pooled spine — confirm before a large extraction run mints the spines.
- **Old corpus pipeline:** retire `corpus.*` after migration, or keep both?
