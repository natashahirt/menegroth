# Flat Plate Design

Two-way flat plate slab design per ACI 318-11, with integrated column P-M design and multiple analysis methods.

## Quick Start

```julia
using StructuralSizer

# Design a flat plate slab (uses DDM by default)
result = size_flat_plate!(struc, slab, ConcreteColumnOptions())

# With EFM analysis (more accurate for irregular layouts)
opts = FlatPlateOptions(analysis_method=:efm)
result = size_flat_plate!(struc, slab, ConcreteColumnOptions(); method=EFM(), opts=opts)

# Check results
result.slab_result.thickness
result.slab_result.punching_ok
result.slab_result.deflection_ok
```

## Analysis Methods

| Method | Symbol | Description | When to Use |
| ------ | ------ | ----------- | ----------- |
| `DDM()` | `:ddm` | Direct Design Method | Regular grids, quick estimates |
| `DDM(:simplified)` | `:mddm` | Modified DDM | Simplified coefficients |
| `EFM()` | `:efm` | Equivalent Frame Method | Irregular geometry, final design |

**DDM** uses ACI 318 Table 8.10 coefficients — fast but requires regular geometry (aspect ratio, load limits).

**EFM** builds an Asap frame model and distributes moments by stiffness — handles irregular geometry and provides more accurate results.

## Design Workflow

```
Phase A: Moment Analysis (method-specific)
├── DDM: ACI coefficient tables → static moment → column/middle strip
└── EFM: Asap frame model → moment distribution → column/middle strip

Phase B: Slab Design (shared)
├── Column P-M interaction design (iterates with slab)
├── Punching shear check (Vu + γv×Mub)
├── Two-way deflection (crossing beam method)
├── One-way shear check
├── Reinforcement design (flexure + minimum)
└── Integrity reinforcement (ACI 8.7.4.2)
```

## Configuration via FlatPlateOptions

```julia
FlatPlateOptions(
    # Materials
    material = RC_4000_60,       # Concrete + rebar bundle
    cover = 0.75u"inch",         # Clear cover (ACI Table 20.6.1.3.1)
    bar_size = 5,                # Typical bar (#3-#11)
    
    # Analysis
    analysis_method = :ddm,      # :ddm, :mddm, or :efm
    
    # Edge conditions
    has_edge_beam = false,       # Spandrel beam at exterior?
    
    # Strength reduction (ACI Table 21.2.1)
    φ_flexure = 0.90,            # Tension-controlled
    φ_shear = 0.75,              # Shear and torsion
    λ = 1.0,                     # Lightweight factor
    
    # Deflection
    deflection_limit = :L_360,   # :L_240, :L_360, :L_480
)
```

## Key Functions

| Function | Description | API Level |
| -------- | ----------- | --------- |
| `size_flat_plate!` | Full design pipeline | **Public** |
| `ddm_analysis` | DDM moment analysis | Internal |
| `efm_analysis` | EFM moment analysis | Internal |
| `check_punching_shear` | ACI 22.6 punching check | Internal |
| `check_two_way_deflection` | Crossing beam method | Internal |
| `design_strip_reinforcement` | Flexure + minimum As | Internal |

## Results

```julia
result = size_flat_plate!(struc, slab, col_opts)

# Slab result
result.slab_result.thickness         # Final thickness
result.slab_result.punching_ok       # All columns pass punching?
result.slab_result.deflection_ok     # Deflection within limit?
result.slab_result.one_way_shear_ok  # One-way shear OK?
result.slab_result.reinforcement     # Strip-by-strip As

# Column results (keyed by column index)
result.column_results[col_idx].section   # Designed section
result.column_results[col_idx].Pu        # Factored axial
result.column_results[col_idx].Mu        # Factored moment
```

## Reference

- ACI 318-11 Chapter 13 (Two-Way Slabs)
- ACI 318-11 §13.6 (DDM)
- ACI 318-11 §13.7 (EFM)
- StructurePoint DE-Two-Way-Flat-Plate Example
- PCA Notes on ACI 318 (stiffness factors)
