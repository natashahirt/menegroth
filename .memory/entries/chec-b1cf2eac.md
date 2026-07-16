---
id: chec-b1cf2eac
type: checkpoint
project: menegroth
parent_id: todo-w0000008
title: Session checkpoint — McCormac Ex. 18.1 ingested as §11.5.3 oracle; todo-w0000008
  closed
node_label: McCormac §11.5.3 oracle done
tags: walls,bearing,11.5.3,mccormac,oracle,zettelkasten,checkpoint
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/walls/bearing.jl@18e0db6, StructuralSizer/test/walls/test_walls.jl@18e0db6,
  StructuralSynthesizer/test/report_generators/test_walls_report.jl@18e0db6, .zettelkasten/mccormac-de-bearing-wall-empirical-aci318-11/_meta.yaml@18e0db6
session_id: sess-62ec7e29
created_at: '2026-07-16T10:01:22.752042+00:00'
updated_at: '2026-07-16T10:01:22.752042+00:00'
---
**Done this session (committed de99e0fa; registrations persisted by ZK/memory hooks in bac648cd/18e0db6a).**

User supplied McCormac & Brown, *Design of Reinforced Concrete* 9e. Ingested the PDF → `corpus/text/textbooks/concrete/mccormac-9e.txt` (742 pp., pdftotext -layout; PDF+text gitignored per corpus policy) and registered `textbook-mccormac-reinforced-concrete-9e` in `corpus/manifests/sources.yml`.

Authored a 14-note grounded ZK extraction `.zettelkasten/mccormac-de-bearing-wall-empirical-aci318-11/` (scope/provision/equation/parameters/applicability/example concepts + verbatim quote nodes), registered in `_projects/menegroth.yaml`. Edition slug is **-11** (McCormac 9e uses ACI 318-11 Ch.14 numbering; §14.5.2 Eq. 14-1 is formula-identical to §11.5.3.1).

**Oracle = McCormac Example 18.1** (§18.3): k=0.8, f'c=3000 psi, lc=16 ft, Ag=8×42=336 in² ⇒ **φPnw = 230.6 k** > Pu=64.8 k; h_min=7.68 in, effective length=42 in. Reproduced to <0.1 kip by a new `test_walls.jl` testset through the real `check_wall_bearing_empirical` path (`:restrained` k-table + default φ); report §3B.1 leads with it and pins capacity via that path. Walls suite **161/161**.

**Scope honesty (critic review):** Ex. 18.1 is an *author*-independent hand calc of the *same* closed form — validates the implementation (0.55, φ, k-table, slenderness), NOT the equation choice (grounded in ACI 318-11 §14.5.2 corpus text; FEA cross-checks the physical ingredients). Downgraded prior "fully validated / fully-independent" language in note-w0000016 / todo-w0000008; de-staled bearing.jl docstrings; hardened report demand path.

**Status:** `todo-w0000008` (out-of-plane / slender walls: §11.8 + §11.5.3) fully closed — implemented, oracle-validated, integrated, reported, committed, registered. Next backlog element per plan-w0000001 spine: `todo-w0000009` (walls with openings). User chose to wrap up here.
