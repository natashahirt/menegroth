# Re-audit 2026-11-18

Refreshes the sizing map (`../README.md`, `../raw/`) after the feature work of
2026-11-11 to 11-17, and produces the first pieces of the design trace map
(`../plan.md` Workstream T) and the fast-tier inventory (Workstream F.1).

Audit the **working tree as it is** (branch `main`, including uncommitted
and untracked files). Read-only: no source edits.

Each area writes two files here:

- `<area>.md` — the report (sections below).
- `<area>.map.yaml` — the map fragment (schema below).

## Report sections

1. **Changes since 2026-11-11.** What moved relative to the matching
   `../raw/*.md` report: loops added, removed or changed; rules that now relax;
   items now fixed. Cite function anchors.
2. **Flow.** How a design passes through this area: entry points, the order
   of steps, which analysis is called and at what fidelity, which checks run
   in what order, which variables are written, where it loops.
3. **Loops.** One row per loop: id, anchor, what iterates, budget, growth rule
   (`grow-only`, `free`, `free+guard`), convergence test, what it writes, and
   whether an earlier size can persist after its reason is gone (ratchet).
4. **Writers.** For each design variable in this area: every function that
   writes it, with the rule (max, replace, floor).
5. **Fast-tier inventory (F.1).** Per element type: where the analysis method
   is chosen and whether it is embedded in the designer; which checks are pure
   functions of (geometry, size, demands); what a fast demand source would
   need; what blocks separating analysis from design.
6. **Size-impact and speed findings**, ranked, with evidence.
7. **Open questions.**

Tag every claim **[read]** (verified by reading the code) or **[inferred]**.
Prefer function anchors (`path/file.jl::function_name`) over line numbers;
add a line number only as a hint.

## Map fragment schema (`<area>.map.yaml`)

```yaml
area: slabs                      # pipeline | slabs | members | walls_lateral_foundations
nodes:
  - id: slab.flat_plate.punching # dotted, stable, lowercase; prefix = area
    level: L2                    # L0 building, L1 stage, L2 element, L3 check
    kind: check                  # input | stage | element | analysis | check |
                                 # owner | loop | policy | sync | output
    parent: slab.flat_plate      # id of the node one level up (omit for L0)
    anchor: StructuralSizer/src/.../punching.jl::check_punching
    summary: Two-way shear at columns, edges, corners and wall ends
    clause: ACI 318-11 §11.11.7.2      # checks only
    reads: [slab.h, column.c1, column.c2, demand.Vu, demand.Mub]
    writes: []
    fidelity: fea_fine           # analysis nodes only: closed_form | ddm | efm |
                                 # fea_coarse | fea_fine | frame | shell_story | other
    loop:                        # loop nodes only
      iterates: slab.h
      budget: max_iterations
      growth: grow-only          # grow-only | free | free+guard
      converges_when: all checks pass
      ratchet: true              # an earlier size can outlive its reason
    trace_labels: [":punching"]  # TraceEvent stage/event labels emitted here, if any
edges:
  - from: slab.flat_plate.analysis
    to: slab.flat_plate.punching
    kind: data                   # data | control | feedback | call
    var: demand.Vu               # data edges: the variable carried
```

Rules: one node per function or decision that matters for sizes or
speed; do not list helpers. Edges that cross areas use the other area's
prefix (`pipeline.`, `slab.`, `member.`, `wall.`, `lateral.`, `fdn.`); the
merge resolves them. Variables use the element prefix (`slab.h`,
`column.c1`, `column.section`, `beam.section`, `wall.t`, `fdn.B`).
