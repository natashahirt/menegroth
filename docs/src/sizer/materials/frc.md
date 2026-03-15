# Fiber Reinforced Concrete

> ```julia
> using StructuralSizer
> frc  = FiberReinforcedConcrete(NWC_6000, 30.0, 4.5, 3.8)
> fR1  = frc.fR1       # 4.5 MPa at CMOD = 0.5 mm
> fR3  = frc.fR3       # 3.8 MPa at CMOD = 2.5 mm
> ```

## Overview

`FiberReinforcedConcrete` extends the base `Concrete` type with steel fiber properties for use in PixelFrame and similar rebar-free structural systems. Residual flexural tensile strengths (fR1, fR3) follow the fib Model Code 2010 §5.6.3 notation and are used in the fib MC2010 shear capacity model.

This is a specialized material for research into novel structural systems — most conventional RC design uses `ReinforcedConcreteMaterial` instead.

## Key Types

```@docs
AbstractMaterial
FiberReinforcedConcrete
```

### Fields

| Field | Type | Description |
|:------|:-----|:------------|
| `concrete` | `Concrete` | Base concrete (fc′, E, ρ, εcu, ecc) |
| `fiber_dosage` | `Float64` | Fiber dosage [kg/m³] |
| `fR1` | `Float64` | Residual flexural tensile strength at CMOD = 0.5 mm [MPa] |
| `fR3` | `Float64` | Residual flexural tensile strength at CMOD = 2.5 mm [MPa] |
| `fiber_ecc` | `Float64` | Embodied carbon of fiber [kgCO₂e/kg-fiber] (default 1.4) |

Property delegation (`frc.fc′`, `frc.E`, etc.) forwards to the inner `Concrete` via `Base.getproperty` overload.

## Functions

```@docs
fc′_dosage2fR1
fc′_dosage2fR3
```

## Implementation Details

- **Regression source**: `fc′_dosage2fR1` and `fc′_dosage2fR3` are linear regressions from the Wongsittikan (2024) dataset for Dramix-type hooked-end steel fibers. Valid for dosages 20–40 kg/m³ and fc′ ∈ [28, 100] MPa.
- **Dosage levels**: Coefficients are tabulated for 0, 20, 25, 30, 35, 40 kg/m³. Non-standard dosages are linearly interpolated between bracketing levels. Dosages below 20 kg/m³ are linearly scaled from the 20 kg/m³ regression; dosages above 40 kg/m³ extrapolate from the 40 kg/m³ regression.
- **fib MC2010 reference**: fR1 (CMOD = 0.5 mm) characterizes serviceability crack control; fR3 (CMOD = 2.5 mm) characterizes ultimate limit state behavior. These values feed into the fib MC2010 linear shear model (Eq. 7.7-5) used in the PixelFrame checker.
- **Embodied carbon**: Fiber ECC defaults to 1.4 kgCO₂e/kg (steel fiber + tendon, from the original PixelFrame study). Total FRC embodied carbon is computed as `concrete_ecc × concrete_mass + fiber_ecc × fiber_dosage × volume`.

## Limitations & Future Work

- **Fiber types**: Only hooked-end steel fibers are calibrated. Macro-synthetic fibers, straight steel fibers, and glass fibers would require new regression coefficients.
- **Tensile constitutive model**: The current implementation uses discrete fR1/fR3 values. A full stress-crack-opening curve (fib MC2010 §5.6.4) is not modeled.
- **Project-specific testing**: The regression functions provide reasonable estimates, but project-specific beam tests should be used for final design.
