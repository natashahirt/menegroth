# Design Code Reference

> ```julia
> # All code checks dispatch on (section_type, material_type):
> ϕMn = get_ϕMn(section, steel, geom)  # AISC flexure
> ϕVn = get_ϕVn(section, steel, geom)  # AISC shear
> ```

## Overview

This page provides a comprehensive index of every design code provision implemented in the codebase. Each entry lists the code, section number, provision description, implementation status, and source file location.

```@docs
AbstractDesignCode
```

## AISC 360-16 — Specification for Structural Steel Buildings

| Section | Provision | Status | Source File |
|:--------|:----------|:-------|:------------|
| §D2 | Tensile yielding and rupture | ✅ Implemented | `members/codes/aisc/generic/tension.jl` |
| §E3 | Flexural buckling of members without slender elements | ✅ Implemented | `members/codes/aisc/hss_rect/compression.jl`, `hss_round/compression.jl` |
| §E7 | Members with slender elements | ✅ Implemented | `members/codes/aisc/i_symm/compression.jl` |
| §F2 | Doubly symmetric compact I-shapes — yielding and LTB | ✅ Implemented | `members/codes/aisc/i_symm/flexure.jl` |
| §F3 | Doubly symmetric I-shapes with compact webs, noncompact flanges | ✅ Implemented | `members/codes/aisc/i_symm/flexure.jl` |
| §F4 | Other I-shaped members with compact or noncompact webs | ✅ Implemented | `members/codes/aisc/i_symm/flexure.jl` |
| §F5 | Doubly symmetric and singly symmetric I-shapes with slender webs | ✅ Implemented | `members/codes/aisc/i_symm/flexure.jl` |
| §F6 | I-shaped members bent about their minor axis | ✅ Implemented | `members/codes/aisc/i_symm/flexure.jl` |
| §F7 | Square and rectangular HSS | ✅ Implemented | `members/codes/aisc/hss_rect/flexure.jl` |
| §F8 | Round HSS | ✅ Implemented | `members/codes/aisc/hss_round/flexure.jl` |
| §G2 | I-shaped members — shear in web | ✅ Implemented | `members/codes/aisc/i_symm/shear.jl` |
| §G4 | Rectangular HSS — shear | ✅ Implemented | `members/codes/aisc/hss_rect/shear.jl` |
| §G5 | Round HSS — shear | ✅ Implemented | `members/codes/aisc/hss_round/shear.jl` |
| §G6 | Weak axis shear | ✅ Implemented | `members/codes/aisc/i_symm/shear.jl` |
| §H1 | Doubly and singly symmetric members — combined forces | ✅ Implemented | `members/codes/aisc/generic/interaction.jl` |
| §H1.1 | P-M interaction (Eq. H1-1a, H1-1b) | ✅ Implemented | `members/codes/aisc/generic/interaction.jl` |
| §C2 | Required strength — amplified first-order analysis (B1, B2) | ✅ Implemented | `members/codes/aisc/generic/amplification.jl` |
| DG9 | Torsional analysis of structural steel members | ✅ Implemented | `members/codes/aisc/hss_rect/torsion.jl`, `hss_round/torsion.jl` |
| §I3.1a | Composite beam — effective width | ✅ Implemented | `members/codes/aisc/composite/effective_width.jl` |
| §I3.1b | Composite beam — construction strength | ✅ Implemented | `members/codes/aisc/composite/construction.jl` |
| §I3.2a | Composite beam — positive flexural strength (plastic) | ✅ Implemented | `members/codes/aisc/composite/flexure.jl` |
| §I3.2a(b) | Composite beam — elastic stress distribution | ⚠️ Not implemented (raises error) | `members/codes/aisc/composite/flexure.jl` |
| §I3.2b | Composite beam — negative moment capacity | ✅ Implemented | `members/codes/aisc/composite/flexure.jl` |
| §I3.2c | Formed metal deck — Rg/Rp factors | ✅ Implemented | `members/codes/aisc/composite/stud_strength.jl` |
| §I3.2d | Composite beam — compression force Cf | ✅ Implemented | `members/codes/aisc/composite/flexure.jl` |
| §I8.1 | Stud diameter limit (d_sa ≤ 2.5tf) | ✅ Implemented | `members/codes/aisc/composite/stud_strength.jl` |
| §I8.2a | Headed stud anchors — shear connector strength | ✅ Implemented | `members/codes/aisc/composite/stud_strength.jl` |
| §I8.2d | Stud spacing limits | ✅ Implemented | `members/codes/aisc/composite/stud_strength.jl` |
| Commentary I3.2 | Transformed I, lower-bound I_LB (Eq. C-I3-1) | ✅ Implemented | `members/codes/aisc/composite/deflection.jl` |
| DG19 | Fire resistance of structural steel framing | ✅ Implemented | `members/codes/aisc/fire/` |

## ACI 318-11 / ACI 318-19 — Building Code Requirements for Structural Concrete

| Section | Provision | Status | Source File |
|:--------|:----------|:-------|:------------|
| §7.12.2.1 | Minimum shrinkage and temperature reinforcement | ✅ Implemented | `slabs/codes/` |
| §8.6.1 | One-way slab minimum thickness | ✅ Implemented | `slabs/codes/` |
| §8.10.4 | T-beam flange width | ✅ Implemented | `analyze/members/utils.jl` |
| §8.12.2 | Effective flange width for T-beams | ✅ Implemented | `analyze/members/utils.jl` |
| §9.3.2 | Strength reduction factors | ✅ Implemented | `codes/aci/` |
| §9.5 | Beam flexure — required strength | ✅ Implemented | `members/codes/aci/beams/flexure.jl` |
| §9.5(a) | Minimum thickness table — beams | ✅ Implemented | `slabs/codes/` |
| §9.5(c) | Minimum thickness table — one-way slabs | ✅ Implemented | `slabs/codes/` |
| §9.5.3.2 | Immediate deflection (Branson Eq. 9-10) | ✅ Implemented | `codes/aci/deflection.jl` |
| §9.5.3.3 | Long-term deflection multiplier | ✅ Implemented | `codes/aci/deflection.jl` |
| §9.8 | Two-way slab minimum thickness | ✅ Implemented | `slabs/codes/` |
| §10.2 | Whitney rectangular stress block | ✅ Implemented | `codes/aci/whitney.jl` |
| §10.3.6.2 | Column axial capacity | ✅ Implemented | `members/codes/aci/columns/axial.jl` |
| §10.10 | Slenderness effects in compression members | ✅ Implemented | `members/codes/aci/columns/slenderness.jl` |
| §10.10.4.1 | Moment of inertia reduction factors | ✅ Implemented | `members/codes/aci/columns/slenderness.jl` |
| §10.10.7 | Sway magnification factor (δs) | ✅ Implemented | `analyze/members/story_properties.jl` |
| §11.2.1.1 | Concrete shear strength Vc | ✅ Implemented | `members/codes/aci/beams/shear.jl` |
| §11.4 | Shear reinforcement (Vs) | ✅ Implemented | `members/codes/aci/beams/shear.jl` |
| §11.11 | Two-way shear (punching) provisions | ✅ Implemented | `slabs/codes/concrete/flat_plate/punching.jl` |
| §11.11.1.2 | Critical section for punching shear | ✅ Implemented | `slabs/codes/concrete/flat_plate/punching.jl` |
| §11.11.3 | Punching shear strength Vc | ✅ Implemented | `slabs/codes/concrete/flat_plate/punching.jl` |
| §11.11.3.2 | Punching shear with moment transfer | ✅ Implemented | `slabs/codes/concrete/flat_plate/punching.jl` |
| §11.11.5 | Shear stud reinforcement | ✅ Implemented | `slabs/codes/concrete/flat_plate/punching.jl` |
| §11.11.5.1 | Stud layout requirements | ✅ Implemented | `slabs/codes/concrete/flat_plate/punching.jl` |
| §11.11.5.2 | Stud capacity | ✅ Implemented | `slabs/codes/concrete/flat_plate/punching.jl` |
| §11.11.5.4 | Maximum spacing of studs | ✅ Implemented | `slabs/codes/concrete/flat_plate/punching.jl` |
| §12.13 | Development of reinforcement | ✅ Implemented | `codes/aci/rebar.jl` |
| §13.1.2 | Two-way slab applicability limits | ✅ Implemented | `slabs/codes/concrete/flat_plate/` |
| §13.2 | Definitions — column strip, middle strip, panel | ✅ Implemented | `slabs/codes/concrete/flat_plate/` |
| §13.3 | Slab reinforcement limits | ✅ Implemented | `slabs/codes/concrete/flat_plate/` |
| §13.5.3 | Moment transfer at columns | ✅ Implemented | `slabs/codes/concrete/flat_plate/` |
| §13.6 | Direct Design Method (DDM) | ✅ Implemented | `slabs/codes/concrete/flat_plate/ddm.jl` |
| §13.6.2.2 | DDM limitations | ✅ Implemented | `slabs/codes/concrete/flat_plate/ddm.jl` |
| §13.6.3 | DDM total static moment Mo | ✅ Implemented | `slabs/codes/concrete/flat_plate/ddm.jl` |
| §13.6.4 | DDM moment distribution to column/middle strips | ✅ Implemented | `slabs/codes/concrete/flat_plate/ddm.jl` |
| §13.7 | Equivalent Frame Method (EFM) | ✅ Implemented | `slabs/codes/concrete/flat_plate/efm.jl` |
| §13.7.3 | EFM slab-beam stiffness | ✅ Implemented | `slabs/codes/concrete/flat_plate/efm.jl` |
| §13.7.4 | EFM column stiffness | ✅ Implemented | `slabs/codes/concrete/flat_plate/efm.jl` |
| §13.7.5 | EFM equivalent column stiffness (torsional members) | ✅ Implemented | `slabs/codes/concrete/flat_plate/efm.jl` |
| §13.7.6 | EFM loading and analysis | ✅ Implemented | `slabs/codes/concrete/flat_plate/efm.jl` |
| §13.7.6.2 | Pattern loading threshold (L/D) | ✅ Implemented | `slabs/codes/concrete/flat_plate/efm.jl` |
| §13.7.7.1 | EFM moment redistribution | ✅ Implemented | `slabs/codes/concrete/flat_plate/efm.jl` |
| §22.4 | Column P-M interaction | ✅ Implemented | `members/codes/aci/columns/interaction.jl` |
| §22.5 | Shear strength | ✅ Implemented | `members/codes/aci/beams/shear.jl` |
| §22.5.6.1 | Vc with axial compression (Nu) | ✅ Implemented | `analyze/members/utils.jl` |
| §22.6 | Punching shear | ✅ Implemented | `slabs/codes/concrete/flat_plate/punching.jl` |
| §22.7 | Torsion | ✅ Implemented | `members/codes/aci/beams/torsion.jl` |
| §24.2 | Deflection control | ✅ Implemented | `codes/aci/deflection.jl` |
| §6.6 | Second-order analysis | ✅ Implemented | `analyze/members/story_properties.jl` |
| §6.6.4.4.4 | Stiffness reduction for stability | ✅ Implemented | `analyze/members/story_properties.jl` |
| §6.6.4.6.2 | Drift limit for moment magnifier | ✅ Implemented | `design_workflow.jl` |
| §8.4.2.3 | Transfer reinforcement | ✅ Implemented | `slabs/codes/concrete/flat_plate/` |
| §8.7.4 | Structural integrity reinforcement | ✅ Implemented | `slabs/codes/concrete/flat_plate/` |
| §8.7.4.2 | Integrity rebar at columns | ✅ Implemented | `slabs/codes/concrete/flat_plate/` |
| Table 7.3.1.1 | Minimum slab thickness | ✅ Implemented | `slabs/codes/` |
| Table 9.5(a) | Minimum beam depth | ✅ Implemented | `slabs/codes/` |

## ACI 216.1-14 — Code Requirements for Determining Fire Resistance

| Section | Provision | Status | Source File |
|:--------|:----------|:-------|:------------|
| — | Minimum slab thickness for fire rating | ✅ Implemented | `slabs/codes/concrete/` |
| — | Minimum beam cover for fire rating | ✅ Implemented | `members/codes/aci/beams/` |
| — | Minimum column dimension for fire rating | ✅ Implemented | `members/codes/aci/columns/` |

## UL — Fire Protection

| Standard | Provision | Status | Source File |
|:---------|:----------|:-------|:------------|
| UL X772 | SFRM thickness for steel members | ✅ Implemented | `materials/fire_protection.jl` |
| UL N643 | Intumescent coating thickness | ✅ Implemented | `materials/fire_protection.jl` |

## fib Model Code 2010 — Fiber Reinforced Concrete

| Section | Provision | Status | Source File |
|:--------|:----------|:-------|:------------|
| §5.6.3 | Residual strength parameters (fR1, fR3 from CMOD) | ✅ Implemented | `members/codes/fib/frc_shear.jl` |
| §5.6.4 (Eq. 5.6-3) | Linear model for ultimate fiber tensile strength | ✅ Implemented | `members/codes/fib/frc_shear.jl` |
| §7.7.3.2.2 (Eqs. 7.7-5, 7.7-6) | FRC shear capacity | ✅ Implemented | `members/codes/fib/frc_shear.jl` |

## NDS 2018 — National Design Specification for Wood

| Section | Provision | Status | Source File |
|:--------|:----------|:-------|:------------|
| General | Timber member design (GLT, LVL) | 🔧 Stub | `members/codes/nds/` |
| Table 4A, 4B | Reference design values | 🔧 Stub | `members/codes/nds/` |

## ACI 336.2R-88 — Mat Foundations

| Section | Provision | Status | Source File |
|:--------|:----------|:-------|:------------|
| §3.3.2 (Eq. 3-8) | Bearing pressure distribution | ✅ Implemented | `foundations/codes/aci/mat_footing.jl` |
| §4.2 | Allowable bearing pressure | ✅ Implemented | `foundations/codes/aci/mat_footing.jl` |
| §6.1.2 | Flexural design of mat | ✅ Implemented | `foundations/codes/aci/mat_footing.jl` |
| §6.4 | Punching shear for mat | ✅ Implemented | `foundations/codes/aci/mat_footing.jl` |
| §6.7 | One-way shear for mat | ✅ Implemented | `foundations/codes/aci/mat_footing.jl` |
| §6.9 | Minimum thickness | ✅ Implemented | `foundations/codes/aci/mat_footing.jl` |

## ASCE 7 — Minimum Design Loads

| Section | Provision | Status | Source File |
|:--------|:----------|:-------|:------------|
| §2.3.1 | LRFD load combinations | ✅ Implemented | `loads/combinations.jl` |

## Planned (Not Yet Implemented)

| Code | Description | Status |
|:-----|:------------|:-------|
| Eurocode 2 (EN 1992) | Design of concrete structures | 📋 Planned |
| Eurocode 3 (EN 1993) | Design of steel structures | 📋 Planned |
| AS 3600 | Australian concrete code | 📋 Planned |
| CSA A23.3 | Canadian concrete code | 📋 Planned |

## Implementation Notes

All source file paths are relative to `StructuralSizer/src/`. Code clause numbers are cited in source comments adjacent to the implementing equation or logic. The capacity functions dispatch on `(section_type, material_type)` pairs, enabling consistent interfaces across different code provisions.
