# Type Hierarchy

> ```julia
> # Functions dispatch on (section_type, material_type):
> get_ϕMn(section::ISymmSection, steel::StructuralSteel, geom::SteelMemberGeometry)
> get_ϕMn(section::RCBeamSection, conc::Concrete, geom::ConcreteMemberGeometry)
> ```

## Overview

The codebase uses Julia's multiple dispatch to organize structural engineering calculations. Abstract types define interfaces, and concrete types provide implementations. Design code functions like `get_ϕMn`, `get_ϕVn`, and `check_interaction` dispatch on the combination of section type, material type, and member geometry to select the appropriate code provision.

## Materials

```
AbstractMaterial
├── Metal
│   ├── StructuralSteel      # ASTM A992, A500, A36, etc.
│   └── RebarSteel            # ASTM A615 Gr. 60, Gr. 80
├── Concrete                  # Normal-weight concrete (fc′ = 3000–8000 psi)
├── ReinforcedConcreteMaterial # Concrete + rebar composite
├── FiberReinforcedConcrete   # FRC with residual strength (fib MC2010)
└── Timber                    # GLT, LVL, CLT, NLT, DLT
```

### Material Type Subtypes

```
MetalType
├── StructuralSteelType       # Hot-rolled structural steel
└── RebarType                 # Reinforcing steel
```

See [Steel](../sizer/materials/steel.md), [Concrete](../sizer/materials/concrete.md), [FRC](../sizer/materials/frc.md), and [Timber](../sizer/materials/timber.md) for full type documentation.

### Fire Protection

```
FireProtection
├── NoFireProtection
├── SFRM                     # Sprayed fire-resistive material (UL X772)
├── IntumescentCoating        # Intumescent paint (UL N643)
└── CustomCoating             # User-defined fire protection
```

See [Fire Protection](../sizer/materials/fire_protection.md) for full type documentation.

## Sections

```
AbstractSection
├── ISymmSection              # Doubly-symmetric I-shapes (W, S, HP)
├── HSSRectSection            # Rectangular HSS
├── HSSRoundSection           # Round HSS and Pipe
├── Rebar                     # Reinforcing bar (for rebar design)
├── RCBeamSection             # RC rectangular beam
├── RCTBeamSection            # RC T-beam
├── RCColumnSection           # RC rectangular column
├── RCCircularSection         # RC circular column
├── GlulamSection             # Glulam timber beam/column
└── PixelFrameSection         # PixelFrame composite section
```

### Hollow Section Subtypes

```
AbstractHollowSection
├── AbstractRectHollowSection
│   └── HSSRectSection
└── AbstractRoundHollowSection
    └── HSSRoundSection
```

See [Steel Sections](../sizer/members/sections/steel.md), [Concrete Sections](../sizer/members/sections/concrete.md), and [Timber Sections](../sizer/members/sections/timber.md) for full type documentation.

## Demands

```
AbstractDemand
├── MemberDemand              # Generic (Pu, Mu, Vu, Tu) demand
├── RCColumnDemand            # RC column (Pu, Mux, Muy) with slenderness
└── RCBeamDemand              # RC beam (Mu, Vu, Tu) with exposure
```

See [Types & Demands](../sizer/members/types.md) for full type documentation.

## Member Geometry

```
AbstractMemberGeometry
├── SteelMemberGeometry       # L, Lb, Kx, Ky, Cb for steel members
├── ConcreteMemberGeometry    # L, cover, ties/spirals for RC members
└── TimberMemberGeometry      # L, Le, moisture, temperature for timber
```

See [Types & Demands](../sizer/members/types.md) for full type documentation.

## Floor Systems

```
AbstractFloorSystem
├── AbstractConcreteSlab
│   ├── OneWay                # One-way slab spanning to beams
│   ├── TwoWay                # Two-way slab on beams
│   ├── FlatPlate             # Flat plate (beamless two-way)
│   ├── FlatSlab              # Flat slab with drop panels
│   ├── PTBanded              # Post-tensioned banded slab
│   ├── Waffle                # Waffle (ribbed) slab
│   ├── Grade                 # Slab on grade
│   ├── HollowCore            # Precast hollow-core plank
│   ├── Vault                 # Thin-shell vault
│   └── ShapedSlab            # Custom-geometry slab
├── AbstractSteelFloor
│   ├── CompositeDeck         # Composite steel deck + concrete
│   ├── NonCompositeDeck      # Non-composite steel deck
│   └── JoistRoofDeck         # Open-web steel joist roof
└── AbstractTimberFloor
    ├── CLT                   # Cross-laminated timber panel
    ├── DLT                   # Dowel-laminated timber panel
    ├── NLT                   # Nail-laminated timber panel
    └── MassTimberJoist        # Mass timber joist floor
```

See [Slab Types & Options](../sizer/slabs/types.md) for full type documentation.

### Spanning Behavior

```
SpanningBehavior
├── OneWaySpanning
├── TwoWaySpanning
└── BeamlessSpanning
```

### Analysis Methods

```
FlatPlateAnalysisMethod
├── DDM                       # Direct Design Method (ACI 318 §13.6)
├── EFM                       # Equivalent Frame Method (ACI 318 §13.7)
├── FEA                       # Finite Element Analysis
└── RuleOfThumb               # Quick span/thickness estimate
```

```
VaultAnalysisMethod
├── HaileAnalytical           # Analytical thin-shell theory
└── ShellFEA                  # Shell finite element analysis
```

### Floor Results

```
AbstractFloorResult
├── CIPSlabResult             # Cast-in-place slab result
├── ProfileResult             # Profile deck result
├── CompositeDeckResult       # Composite deck result
├── JoistDeckResult           # Joist deck result
├── TimberPanelResult         # Timber panel result
├── TimberJoistResult         # Timber joist result
├── VaultResult               # Vault analysis result
├── ShapedSlabResult          # Custom slab result
└── FlatPlatePanelResult      # Flat plate panel result
```

## Foundations

```
AbstractFoundation
├── AbstractShallowFoundation
│   ├── SpreadFooting         # Isolated spread footing
│   ├── CombinedFooting       # Combined footing for 2+ columns
│   ├── StripFooting          # Continuous strip footing
│   └── MatFoundation         # Mat (raft) foundation
└── AbstractDeepFoundation
    ├── DrivenPile            # Driven steel/concrete pile
    ├── DrilledShaft          # Cast-in-drilled-hole shaft
    └── Micropile             # Small-diameter grouted pile
```

### Foundation Results

```
AbstractFoundationResult
├── SpreadFootingResult
├── CombinedFootingResult
├── StripFootingResult
├── MatFootingResult
└── PileCapResult
```

See [Foundation Types](../sizer/foundations/types.md) for full type documentation.

## Optimization

### Objectives

```
AbstractObjective
├── MinWeight                 # Minimize total structural weight
├── MinVolume                 # Minimize total material volume
├── MinCost                   # Minimize estimated cost
└── MinCarbon                 # Minimize embodied carbon (kgCO₂e)
```

See [Objectives](../sizer/optimize/objectives.md) for full type documentation.

### Capacity Checkers

```
AbstractCapacityChecker
├── AISCChecker               # AISC 360-16 steel checks
├── ACIBeamChecker            # ACI 318 RC beam checks
├── ACIColumnChecker          # ACI 318 RC column checks
├── PixelFrameChecker         # PixelFrame composite checks
└── NDSChecker                # NDS timber checks (stub)
```

See individual design code pages for full checker documentation: [AISC](../sizer/members/codes/aisc/hss_rect.md), [ACI Beams](../sizer/members/codes/aci/beams.md), [ACI Columns](../sizer/members/codes/aci/columns.md).

### Composite Beam Types (AISC Chapter I)

```
AbstractSlabOnBeam
├── SolidSlabOnBeam           # Solid reinforced-concrete slab on steel beam
└── DeckSlabOnBeam            # Metal-deck composite slab on steel beam

AbstractSteelAnchor
└── HeadedStudAnchor          # Steel headed stud anchor (I8)

CompositeContext              # Bundles slab + anchor + span for checker pipeline
```

See [AISC W Shapes — Chapter I](../sizer/members/codes/aisc/i_symm.md#chapter-i-composite-members-beams) for full documentation.

### Capacity Caches

```
AbstractCapacityCache
├── AISCCapacityCache
├── ACIBeamCapacityCache
├── ACIColumnCapacityCache
└── PixelFrameCapacityCache
```

### NLP Problems

```
AbstractNLPProblem
├── RCColumnNLPProblem
├── RCCircularNLPProblem
├── RCBeamNLPProblem
├── RCTBeamNLPProblem
├── HSSColumnNLPProblem
├── WColumnNLPProblem
├── SteelWBeamNLPProblem
├── SteelHSSBeamNLPProblem
├── VaultNLPProblem
└── FlatPlateNLPProblem
```

## Synthesizer Types

```
AbstractStructuralSynthesizer
├── AbstractBuildingSkeleton
│   └── BuildingSkeleton      # Geometry container
└── AbstractBuildingStructure
    └── BuildingStructure     # Skeleton + structural data
```

See [Skeleton](../synthesizer/building_types/skeleton.md) and [Structure](../synthesizer/building_types/structure.md) for full type documentation.

## Dispatch Model

The key design pattern is multiple dispatch on `(section_type, material_type)` pairs. This allows the same function name family to be used across different code provisions:

```julia
# AISC steel flexure
get_ϕMn(w_section, A992_Steel; Lb=20.0u"ft", Cb=1.0, axis=:strong)

# AISC steel axial
get_ϕPn(hss_section, A992_Steel, 20.0u"ft"; axis=:strong)

# ACI concrete beam design helpers
design_beam_flexure(Mu, bw, d, fc, fy)
design_tbeam_flexure(Mu, bw, bf, hf, d, fc, fy)
```

The optimization framework uses this dispatch to provide a unified interface:

1. `AbstractCapacityChecker` wraps the dispatch logic
2. The optimizer calls checker APIs such as `is_feasible`, `get_objective_coeff`, and cache helpers (`create_cache`, `precompute_capacities!`) for each candidate section
3. The checker dispatches to the appropriate code provision based on the section and material types
4. Results are compared via the `AbstractObjective` to select the optimal section

This pattern extends naturally to new materials and codes: adding Eurocode 2 support requires defining new concrete section types and implementing `get_ϕMn` / `get_ϕVn` dispatches for those types.
