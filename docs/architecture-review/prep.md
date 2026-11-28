# Architecture & performance review — prep packet

Starting point for the "big review". Two coupled workstreams:

1. **Package-boundary contracts & lifecycle ownership** (architecture)
2. **Codebase/sizing-loop efficiency** (performance)

They are coupled: most speed wins (fixed slab mesh, low-rank updates,
content-addressed caches, rigid-link solve cache) must land inside the
right package seam — analysis machinery in **Asap**, sizing in
**StructuralSizer**, orchestration in **StructuralSynthesizer** — so the
boundary work and the speed work gate each other.

Dependency direction (invariant): `Asap → StructuralSizer → StructuralSynthesizer → leaf consumers`.

---

## 1. Architecture: package-boundary contracts

**Doctrine.** `.cursor/rules/architecture-contracts.mdc` and
`docs/src/reference/architecture_contracts.md`. Memory: the code-steward
mandate `note-61fb1dd6` — one direction of dependence, one owner per concept,
small public surface, every new system plugs into a named seam; cycles and
parallel pipelines are P0.

**Migration plan.** `plan-0deab668` — seven waves:

1. Typed statuses, outcomes, diagnostics, installability.
2. Prove the pattern on floor sizing: immutable `FloorDesignRequest`/`Result`
   contracts; loud unsupported dispatch.
3. StructuralSynthesizer installs slab/support changes transactionally.
4. Asap: explicit source-realization maps, owned invalidation operations,
   typed static results.
5. Unitful request/result contracts on wall checks; keep the reduced kernel.
6. Atomically remove compatibility aliases, broad reexports, private
   cross-package calls, silent defaults, reflection-based fallbacks.
7. Split wall/floor orchestration/analysis/design god files — only after
   boundaries stabilize.

**Status to confirm at review start:** `plan-0deab668` has `open_threads: 0`
and no child entries tracking per-wave progress — so either the waves have not
started or progress was logged elsewhere. First review action: establish which
waves (if any) have landed, against the current tree.

**God-file candidates (largest src files, 2026-11-19):**

| Lines | File |
|---|---|
| 2192 | `SY/analyze/members/members/size_beams.jl` |
| 1846 | `SY/api/chat/geometry_context.jl` |
| 1842 | `SY/analyze/asap/asap/load_routing.jl` |
| 1430 | `SS/walls/special_boundary.jl` |
| 1408 | `SS/slabs/codes/concrete/flat_plate/analysis/ddm/eq137_support_sides.jl` |
| 1395 | `SS/slabs/codes/concrete/flat_plate/design/checks/punching.jl` |
| 1389 | `SY/analyze/lateral/ordinary_wall_stage.jl` |
| 1341 | `SY/analyze/members/members/demands.jl` |
| 1233 | `SY/scene/build.jl` |
| 1217 | `SY/analyze/slabs/slabs/story_shell.jl` |

(Wave 7 targets these; do them last, after contracts.)

---

## 2. Performance: sizing-loop efficiency

**Primary source:** `docs/sizing-map/audit-2026-11-18/speed.md` — a read-only
audit with measured costs, cost drivers, and **17 ranked opportunities**.
Companion maps: `audit-2026-11-18/{members,slabs,pipeline,walls_lateral_foundations}.md`.
`docs/sizing-map/README.md` is the stage/loop map; `phase1-benchmarks.md` has
the instrumentation.

**Approved directions** (`deci-623746f4`, user 2026-11-18 = `plan.md`
Phase 7.7–7.13):

- 7.7 Merge the Ipopt constraint cache from `row-f-nlp` (~150×: 1249 → 8 s).
- 7.8 Fixed slab mesh with node rings at candidate column sizes; chosen ring
  made rigid; no remesh (supersedes the conforming-remesh approach).
- 7.9 Woodbury / low-rank factorization updates; symbolic-factorization reuse.
- 7.10 Slab superelements condensed once per geometry; condensed stiffness
  scaled by `(h/h0)^3` per uniform-thickness region; regions (field, drops,
  solid heads, smeared ribs) each with their own scale; interpolate at 2–3
  thicknesses where shear/membrane-bending coupling breaks scalar scaling;
  measure error.
- 7.11 Coarse-to-fine FEA.
- 7.12 Content-addressed caching: canonical fingerprints over normalized
  geometry/supports/loads/materials/code options; levels = meshes /
  superelements / unit-case results / P-M diagrams / element designs per exact
  demand set; persistent on disk with a source-code hash in **every** key;
  report hit rates. Caching shares computation; grouping forces sizes — group
  only where a policy asks.
- 7.13 Parallelism opt-in; results identical for any thread/worker count;
  production at scale on a cluster, not this machine.

**Headline measured costs** (from speed.md §1): core-office flat-plate FEA run
~780–950 s, ~90 % in Asap slab analysis; one slab **remesh 27–36 s vs
value-only update 4–6 s** (4.5–9×); remeshing on column growth **doubled** a
building run (536 vs 297 s); DDM path is 5–100× faster than FEA on the same
building. Ipopt column NLP with many rows was 1249 s (8 s with the cache that
is only on `row-f-nlp`).

**Top-ranked opportunities** (speed.md §3): #1 fixed slab mesh with column
patch (~1.8–2× whole FEA run), #2 low-rank/Woodbury column updates (5–20× per
Phase B analysis), #3 predict-then-confirm punching (3–10× fewer analyses),
#4 content-addressed FEA cache, #11 land the Ipopt constraint cache (~150× on
NLP). Nine open measurements are listed in speed.md §4 (the core-office
`pipeline` 699 s is still unattributed by stage — measurement #1).

---

## 3. Cross-cutting dependencies & current state

- **row-f-nlp merge is parked, not landed** (`note-0ae4bb04`): branch
  `merge/row-f-nlp` @ `b7e2af13`, verified. Landing is blocked on the live
  ribbed-floor session's 54 uncommitted files in the main checkout (22
  overlap). The Ipopt constraint cache (speed item 7.7 / #11) rides this
  merge, so performance Phase 7.7 depends on landing it.
- **Pre-existing flat-plate-on-building-model failures** (fail on integration
  `abe95f9e` too, from commit `764c0ae1`): pattern-loading tests, design-graph
  exact-first/incremental equivalence, visualization unverified-column. Not
  merge regressions; should be triaged separately.
- **Cladding slab-edge load path** (`deci-3d324e9c`): designed, not
  implemented — flat-plate cladding still rides the zero-stiffness perimeter
  frame element.
- **Live rib/joist workstream** is active in the main checkout; coordinate
  before any boundary refactor that touches `demands.jl`, `size_columns.jl`,
  `member_iteration.jl`, `check_settle.jl`, the T-beam checker, or
  `subdivision.jl`.

---

## 4. Suggested review sequence

1. Confirm boundary-wave status against the tree (which of `plan-0deab668`'s
   seven waves have landed).
2. Land `row-f-nlp` once the rib session commits; unblocks speed item 7.7.
3. Run speed.md §4 measurement #1 (stage-split the core-office pipeline) so
   the performance work is aimed at real numbers.
4. Sequence the speed items against the boundary waves so each lands in the
   correct seam (fixed mesh / Woodbury / superelements → Asap; caching keys →
   shared; member-stage cache hoist → StructuralSynthesizer).
