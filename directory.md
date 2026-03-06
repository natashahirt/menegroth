# structural_synthesizer — Directory

> Last updated: 2026-03-06

## Repository Layout

```
structural_synthesizer/
├── StructuralBase/          # Shared units, constants, abstract types
├── StructuralSizer/         # Material definitions, section catalogs,
│                            #   design-code checks, floor/foundation sizing
├── StructuralSynthesizer/   # Building geometry, analysis orchestration,
│                            #   visualization, postprocessing (EC)
├── StructuralPlots/         # Makie themes, colors, axis styles
├── scripts/                 # Top-level run scripts
├── CIP_FLAT_PLATE_DESIGN_PLAN.md
├── todo.md
└── directory.md             # ← this file
```

---

## StructuralBase

Shared foundation types and unit system.

| File | Purpose |
|------|---------|
| `src/StructuralBase.jl` | Module root; re-exports Units, Constants, types |
| `src/Units.jl` | Custom Unitful units: `kip`, `ksi`, `psf`, `GRAVITY` |
| `src/Constants.jl` | ECC coefficients, load factors (`DL_FACTOR`, `LL_FACTOR`), standard loads |
| `src/types.jl` | Abstract supertypes: `AbstractMaterial`, `AbstractSection`, `AbstractDesignCode`, `AbstractBuildingSkeleton`, `AbstractBuildingStructure` |

---

## StructuralSizer

Sizing engine: materials → sections → design-code checks → optimization.

### Key Exports

**Types:** `Metal`, `StructuralSteel`, `RebarSteel`, `Concrete`, `ISymmSection`, `HSSSection`, `GlulamSection`, `RCBeamSection`

**Capacity interface:** `AbstractCapacityChecker`, `create_cache`, `is_feasible`, `precompute_capacities!`, `get_objective_coeff`

**Geometry types:** `SteelMemberGeometry`, `TimberMemberGeometry`, `ConcreteMemberGeometry`

**Checkers:** `AISCChecker` (implemented), `NDSChecker` (stub), `ACIChecker` (stub)

**Optimization:** `optimize_discrete` — MIP-based discrete catalog selection

**Floor types:** `OneWay`, `TwoWay`, `FlatPlate`, `Vault`, `CompositeDeck`, `CLT`, `DLT`, `NLT`, `MassTimberJoist`, …

**Floor results:** `CIPSlabResult`, `ProfileResult`, `VaultResult`, `CompositeDeckResult`, `TimberPanelResult`, …

**Foundations:** `SpreadFooting`, `CombinedFooting`, `DrivenPile`, `Soil`, `design_spread_footing`

### Source Tree

```
src/
├── StructuralSizer.jl         # Module + exports
├── types.jl                   # Metal, Concrete
├── materials/                 # Steel & concrete material presets
│   ├── steel.jl
│   └── concrete.jl
├── members/
│   ├── codes/
│   │   ├── aisc/              # AISC 360: flexure, compression, shear, tension, slenderness, interaction, checker
│   │   ├── aci/               # ACI 318 (stub)
│   │   └── nds/               # NDS (stub)
│   ├── optimize/
│   │   ├── interface.jl       # AbstractCapacityChecker, AbstractCapacityCache, AbstractMemberGeometry
│   │   ├── geometry.jl        # SteelMemberGeometry, TimberMemberGeometry, ConcreteMemberGeometry
│   │   ├── demands.jl         # MemberDemand
│   │   ├── objectives.jl      # MinWeight, MinVolume, MinCost, MinCarbon
│   │   └── discrete_mip.jl    # optimize_discrete (JuMP + HiGHS/Gurobi)
│   └── sections/
│       ├── steel/             # ISymmSection (W-shapes), HSSSection (stub), rebar catalog
│       ├── timber/            # GlulamSection (stub)
│       └── concrete/          # RCBeamSection (stub)
├── slabs/
│   ├── types.jl               # Floor system hierarchy + result types + interfaces
│   ├── options.jl             # FloorOptions, CIPOptions, VaultOptions, …
│   ├── codes/                 # size_floor() dispatch per floor type
│   │   ├── concrete/          # CIP ACI, hollow core
│   │   ├── steel/             # Composite deck, joist roof (stubs)
│   │   ├── timber/            # CLT, DLT, NLT, mass timber joist (stubs)
│   │   ├── vault/             # Haile unreinforced vault
│   │   └── custom/            # ShapedSlab (user-defined geometry fn)
│   └── tributary/             # DCEL-based straight skeleton for tributary areas
│       ├── isotropic.jl       # Two-way (isotropic) straight skeleton
│       ├── one_way.jl         # One-way (directed) partitioning
│       └── spans.jl           # SpanInfo, governing_spans
└── foundations/
    ├── types.jl               # Foundation types, Soil, result types
    └── codes/                 # design_spread_footing (IS 456 spread footing)
```

---

## StructuralSynthesizer

Building-level orchestration: geometry generation → analysis → sizing → postprocessing.

### Key Exports

**Types:** `BuildingSkeleton`, `BuildingStructure`, `Story`, `Cell`, `Slab`, `Segment`, `Beam`, `Column`, `Strut`, `MemberGroup`, `Support`, `Foundation`, `FoundationGroup`

**Workflow:** `gen_medium_office` → `initialize!` → `to_asap!` → `size_members_discrete!` → `size_foundations!` → `compute_building_ec`

**Visualization:** `visualize`, `visualize_cell_tributaries`, `vis_embodied_carbon_summary`

### Source Tree

```
src/
├── StructuralSynthesizer.jl   # Module + exports
├── types.jl                   # Core data types (SiteConditions, Cell, Slab, Beam, Column, Strut, …)
├── core/
│   ├── lookup_utils.jl        # SkeletonLookup for O(1) vertex/edge/face queries
│   ├── utils_building_skeleton.jl  # add_vertex!, add_element!, find_faces!, rebuild_stories!
│   ├── utils_ASAP.jl          # to_asap!, slab load transfer, update_slab_loads!
│   └── initialize.jl          # initialize! (cells → slabs → segments → members)
├── generate/
│   └── doe/medium_office.jl   # gen_medium_office (DOE archetype geometry)
├── analyze/
│   ├── slabs/                 # initialize_cells!, initialize_slabs!, build_slab_groups!, compute_cell_tributaries!
│   ├── members/               # initialize_segments!, initialize_members!, build_member_groups!, size_members_discrete!
│   └── foundations/           # initialize_supports!, size_foundations!, group_foundations_by_reaction!
├── visualization/
│   ├── vis_building_skeleton.jl
│   ├── vis_building_structure.jl
│   ├── vis_tributaries.jl
│   └── vis_data.jl            # vis_embodied_carbon_summary
└── postprocess/
    └── ec.jl                  # element_ec, compute_building_ec, ec_summary
```

---

## StructuralPlots

Makie themes and visualization utilities for structural engineering plots.

| File | Purpose |
|------|---------|
| `src/colors.jl` | Named colors (`sp_powderblue`, …), `harmonic` palette, gradients |
| `src/themes.jl` | `sp_light`, `sp_dark` |
| `src/themes_mono.jl` | `sp_light_mono`, `sp_dark_mono` |
| `src/functions.jl` | `discretize`, `labelize!`, `labelscale!`, `gridtoggle!` |
| `src/axis_styles.jl` | `graystyle!`, `structurestyle!`, `asapstyle!`, `blueprintstyle!` |
| `src/figure_sizes.jl` | `fullwidth`, `halfwidth`, `customwidth` (journal-ready sizes) |

---

## Design Workflow

```
gen_medium_office()        # → BuildingSkeleton
  └─ initialize!(struc)    # cells, slabs (size_floor), segments, members
      └─ to_asap!(struc)   # build FE model, apply slab loads
          └─ size_members_discrete!(struc)  # MIP-based W-shape selection
              └─ initialize_foundations! / size_foundations!
                  └─ compute_building_ec(struc)  # embodied carbon summary
```

---

## Stub Modules (not yet implemented)

| Stub | Location | Notes |
|------|----------|-------|
| ACI beam/column checker | `members/codes/aci/` | TODO: strength calculations |
| NDS timber checker | `members/codes/nds/` | TODO: adjustment factors |
| HSS sections | `members/sections/steel/hss_section.jl` | TODO: geometry + catalog |
| Glulam sections | `members/sections/timber/glulam_section.jl` | TODO: catalog loading |
| RC beam sections | `members/sections/concrete/rc_beam_section.jl` | TODO: rebar optimization |
| Hollow core catalog | `slabs/codes/concrete/hollow_core.jl` | TODO: load span tables |
| CLT / DLT / NLT | `slabs/codes/timber/` | TODO: manufacturer data |
| Composite deck | `slabs/codes/steel/composite_deck.jl` | TODO: Vulcraft/ASC tables |
| Steel joist roof | `slabs/codes/steel/joist_roof.jl` | TODO: SJI joist tables |
| Combined footing design | `analyze/foundations/` | TODO: multi-column footing |
