# Snapshots

> ```julia
> snapshot!(struc, :before_sizing)
> # ... perform sizing operations ...
> restore!(struc, :before_sizing)
> has_snapshot(struc, :before_sizing)  # true
> delete_snapshot!(struc, :before_sizing)
> ```

## Overview

The snapshot system provides deep-copy save/restore for `BuildingStructure` state. This enables `design_building` to modify the structure during design and then restore it to its original state, allowing multiple design runs on the same structure without side effects.

## Key Types

```@docs
DesignSnapshot
SlabSnapshot
```

## Functions

```@docs
snapshot!
restore!
has_snapshot
delete_snapshot!
snapshot_keys
```

## Implementation Details

### What Is Captured

A `DesignSnapshot{T,P}` stores the mutable state that changes during design:

| Field | Description |
|:------|:------------|
| `column_c1` | Column dimension c1 for each column |
| `column_c2` | Column dimension c2 for each column |
| `column_sections` | Column section assignments |
| `beam_sections` | Beam section assignments |
| `cell_self_weights` | Cell self-weight values (change as slab thickness changes) |
| `cell_live_loads` | Cell live load values |
| `slab_snapshots` | Vector of `SlabSnapshot` for each slab |

A `SlabSnapshot` stores per-slab state:
- `result` — the `AbstractFloorResult`
- `design_details` — detailed design output
- `volumes` — `MaterialVolumes`
- `drop_panel` — drop panel dimensions

### Snapshot Keys

Snapshots are stored in the structure's `_snapshots` dictionary, keyed by `Symbol`. Common keys:

| Key | Used By | Purpose |
|:----|:--------|:--------|
| `:prepare` | `prepare!` / `design_building` | Restore after design pipeline |

### Deep Copy Semantics

`snapshot!` performs a deep copy of all captured state, ensuring that subsequent mutations do not affect the snapshot. `restore!` writes the snapshot data back into the structure's fields, also via deep copy, so the snapshot remains valid for future restores.

### Usage in design_building

The `design_building` workflow uses snapshots as follows:

1. `prepare!(struc, params)` calls `snapshot!(struc, :prepare)` after initialization and column estimation
2. The pipeline runs, mutating `struc` in place
3. `capture_design(struc, params)` reads the final state into a `BuildingDesign`
4. `restore!(struc, :prepare)` reverts `struc` to its pre-design state

This pattern allows:
```julia
d1 = design_building(struc, params_A)
d2 = design_building(struc, params_B)  # struc is unchanged from before d1
compare_designs(d1, d2)
```

## Limitations & Future Work

- Snapshots do not capture the Asap model or tributary caches; these are rebuilt as needed.
- Snapshot storage is in-memory; serialization to disk for checkpointing is planned.
- The snapshot key space is flat; nested or hierarchical snapshots are not supported.
