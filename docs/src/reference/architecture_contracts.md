# Architecture and Contract Guidelines

These guidelines keep the structural engineering kernels extensible without
allowing orchestration, state, or solver-specific behavior to leak across the
codebase. Correct engineering behavior takes priority over compactness.

## Dependency and ownership direction

Keep dependencies flowing in one direction:

```text
Asap → StructuralSizer → StructuralSynthesizer → API / visualization / studies
```

- **Asap** owns finite-element state, assembly, solving, and analysis results.
  Node identity, element connectivity, meshing, and degenerate elements are
  part of that. Welding coincident nodes or dropping a zero-area shell is
  implemented in Asap and called from above. Slab-edge geometry, such as which
  column face sets a band width, stays in the package that owns the slab.
- **StructuralSizer** owns materials, sections, code checks, sizing problems,
  optimization adapters, slab design, and foundation design.
- **StructuralSynthesizer** owns building objects, load paths, lifecycle
  orchestration, design sessions, and finalized building results.
- Transport, visualization, and study code consume the core packages; core
  packages must not depend on them.
- Place a type where its behavior is owned. Do not put an abstract building type
  in a lower package solely to avoid a dependency decision.

Reexports are conveniences, not ownership. New public APIs should import their
owning package explicitly, and reexports should be narrowed over time.

## One owner per lifecycle phase

A design run should have this relationship:

```text
DesignParameters
    → ResolvedDesignContext
    → DesignSession
    → IncrementalEngine / mutable BuildingStructure workspace
    → finalized BuildingDesign
```

- Resolve defaults, effective options, and content hashes once at the run
  boundary.
- Treat the resolved context as immutable. Later mutation of caller-owned
  parameters must not change an active run.
- Give one session ownership of mutable execution state and caches.
- Do not maintain independent top-level workflows with different semantics.
- Finalize results before publishing them. A published design must not change
  when a workspace is restored, reused, or incrementally redesigned.
- Make non-convergence, partial failure, and diagnostics explicit result state;
  exhausting an iteration limit is not successful convergence.

## Normalize public contracts

Public APIs must normalize backend-specific behavior at their boundary.

### Strategies and capabilities

- Declare the accepted strategy, solver, objective, and method values.
- Validate enum-like `Symbol` values before performing work.
- Never let an unknown value silently select the default branch.
- Never advertise a capability that only exists in a standalone or experimental
  function.
- Return or throw an explicit unsupported-capability outcome. Do not use
  `nothing` as an undocumented success-shaped result.

```julia
strategy in (:discrete_mip, :nlp) ||
    throw(ArgumentError("unsupported sizing strategy: $strategy"))
```

### Optimization objectives

- Record both the requested objective and the objective actually evaluated.
- Reject unsupported objective/problem pairs instead of substituting area,
  weight, cost, or carbon.
- Keep objective evaluation in one authoritative implementation per problem.
- Preserve code-specific feasibility checks behind checker/problem interfaces;
  normalization must not duplicate engineering equations.

### Results and statuses

Separate these questions:

1. Why did the backend stop?
2. Is the result feasible?
3. Is the result installable?

A public optimization result should expose:

- normalized outcome (`:optimal`, `:feasible`, `:infeasible`, or `:failed`);
- normalized termination reason such as convergence, time limit, iteration
  limit, or backend error;
- requested/evaluated objective and value;
- selected sections or `nothing`;
- per-member outcomes and diagnostics;
- backend identity for debugging.

Backend statuses such as MOI codes or Ipopt return symbols belong in adapters.
An aggregate result cannot report success when a required child failed. Use one
installability predicate rather than open-coded status checks at call sites.

### Errors, units, and optional values

- Use exceptions for invalid requests and violated preconditions.
- Use typed results for expected engineering outcomes such as infeasibility or
  non-convergence.
- Use `nothing` only for a documented optional value, never to mean unsupported,
  failed, skipped, and not-yet-run simultaneously.
- Accept unitful values at public engineering boundaries. Strip or convert units
  once at solver/catalog boundaries and document the internal unit.
- Do not mix force, moment, length, stress, or mass/carbon units in untyped
  numeric payloads.

## Mutation, caches, and publication

- Mutate through operations that own invalidation of every derived value.
- Document whether a mutation changes values, loads, stiffness, geometry, DOF
  topology, or graph topology.
- A cache key must include every input that can change its output. Content hashes
  are authoritative; revision counters may be fast prefilters only.
- Do not expose mutable cached objects unless the caller also owns invalidation.
- Publish API result, design, parameters, geometry, diagnostics, version, and
  history as one logical operation after finalization.
- A failed run must not partially replace a previously published design.

## Julia types and dispatch

Use an abstract type when at least one of these is true:

- multiple meaningful concrete implementations exist;
- shared behavior is selected through dispatch;
- external packages are intentionally expected to add implementations.

Otherwise prefer a concrete type with a trait, enum-like tag, or composed policy.
Do not create placeholder subtypes that imply unsupported capability.

- Put shared interface methods beside the abstract interface.
- Put code- or material-specific methods beside the concrete implementation.
- Prefer composition for objectives, solvers, analysis methods, and policies.
- Avoid `Any` and duck-typed cross-package objects at public boundaries; define a
  narrow context or protocol owned by the receiving package.
- Nested modules are ownership boundaries, not a remedy for large files.

## Duplication and organization

Consolidate repeated **control flow and policy**, including validation, result
adaptation, cache invalidation, state publication, and identical geometry
predicates.

Do not consolidate formulas merely because they look similar when they represent
different:

- code provisions or editions;
- section families or material systems;
- axes, signs, faces, or load combinations;
- boundary conditions or analysis methods.

When uncertain, preserve the separate engineering implementations and share only
their non-numerical orchestration.

Large active wall and floor files may remain intact while those systems are
changing. Extract stable interfaces and helpers first; perform physical splits
after behavior is characterized.

## Required tests

Every public contract change needs tests at the narrowest authoritative layer:

- invalid and unsupported values fail loudly;
- every advertised strategy/objective pair is exercised;
- aggregate and child failure semantics agree;
- regression tests reproduce each fixed defect;
- code-derived calculations use known-answer or published-example oracles;
- fresh and incremental designs are equivalent;
- published results survive parameter mutation, workspace restoration, and later
  redesigns unchanged;
- failed, non-converged, and partial runs cannot enter result caches;
- unit-equivalent inputs produce unit-equivalent outputs.

Keep targeted contract tests fast. Run affected package suites after targeted
tests pass, and run cross-package integration tests in the package that owns the
integration.

## Review checklist

Before merging a new public path, verify:

1. Which package and object own the behavior and mutable state?
2. Are all accepted values validated before execution?
3. Are requested and evaluated strategies/objectives identical?
4. Can backend-specific statuses escape?
5. Can a child failure become aggregate success?
6. What invalidates every cache touched by this path?
7. Is the result finalized before publication?
8. Are units converted exactly once at a documented boundary?
9. Is apparent duplication a control-flow duplicate or a legitimate engineering
   distinction?
10. Which focused regression and integration tests prove the contract?
