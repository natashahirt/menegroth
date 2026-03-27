# Solver Trace Audit — Agent Instructions

## Goal

Ensure every structurally significant decision in the design pipeline emits
trace events via the `TraceCollector` system. The trace is what makes the
solver's reasoning legible to the LLM chat agent — if a decision isn't traced,
the LLM can't explain it to the user.

## Nightly trigger context

This audit is launched by the `Trace Coverage Audit` workflow only after the
`Nightly Doc Audit` workflow completes successfully. Prioritize recent source
changes from the nightly window (the workflow appends a "Changed files" section
to this prompt). If there are no relevant source changes, make no code edits.

---

## 1. Understand the Trace System

Before auditing, read these files to understand the contracts:

- `StructuralSizer/src/trace/trace.jl` — `TraceEvent`, `TraceCollector`,
  `emit!`, `@traced` macro, `TRACE_REGISTRY`
- `StructuralSizer/src/optimize/core/interface.jl` — `explain_feasibility`,
  `CheckResult`, `FeasibilityExplanation`

Key rules:
- `emit!(tc, layer, stage, element_id, event_type; kwargs...)` records a
  decision. `tc` is `Union{Nothing, TraceCollector}` — `nothing` is a no-op.
- Layers: `:pipeline`, `:workflow`, `:sizing`, `:optimizer`, `:checker`, `:slab`
- Event types: `:enter`, `:exit`, `:decision`, `:iteration`, `:fallback`, `:failure`
- Functions with docstrings can't use `@traced` directly (Julia doc macro
  conflict). Instead, register manually before the docstring:
  ```julia
  TRACE_REGISTRY[(:func_name, :layer)] =
      TracedFunctionMeta(:func_name, :layer, [:enter, :exit, ...], nothing,
                         @__FILE__, @__LINE__)
  ```
- `emit!` on `nothing` compiles to a no-op, so tracing is zero-cost when
  disabled. Don't guard `emit!` calls with `if tc !== nothing`.

---

## 2. What Counts as a "Structurally Significant Decision"

Trace events should capture **why the solver did what it did**, not log every
computation. Good trace points are:

- **Strategy selection**: which algorithm was chosen and why (`:discrete` vs
  `:nlp`, Gurobi vs HiGHS, DDM vs EFM vs FEA, `:grow_columns` vs
  `:reinforce_first`)
- **Feasibility screening**: how many options survived, which were eliminated
- **Iteration outcomes**: what check failed, what parameter changed, what the
  new value is (h bumped from X to Y, column grew from A to B)
- **Convergence/divergence**: did the loop converge? after how many iterations?
- **Fallback paths**: when the primary approach failed and the solver switched
  strategies
- **Post-solve explanation**: for optimizers, `explain_feasibility` on the
  chosen section gives detailed code-check ratios

**Do NOT trace**: individual matrix operations, intermediate arithmetic,
per-element loop iterations, cache hits, or anything that would generate
thousands of events per design run.

---

## 3. Audit Procedure

### Step 1: Read the static report (if provided)

If a **Static Report** section appears at the end of this prompt, it contains
the output of `scripts/runners/audit_trace_coverage.jl`. This lists functions
in `TRACE_REGISTRY` and flags any that appear to lack `emit!` calls. Start
with these gaps.

### Step 2: Discover decision-making functions

Search the codebase for functions that make structural design decisions. These
are the functions that **should** have trace instrumentation. Use these
heuristics:

**In `StructuralSizer/src/`:**
- Functions named `optimize_*`, `size_*`, `design_*`, `check_*`
- Functions containing iteration loops with convergence checks
- Functions that select between strategies (if/elseif on `:symbol` options)
- Functions that call `is_feasible` or `explain_feasibility`
- Functions that throw `ArgumentError` on infeasibility

**In `StructuralSynthesizer/src/`:**
- `design_workflow.jl` pipeline stages and orchestration
- `analyze/members/utils.jl` sizing dispatch functions
- `analyze/foundations/utils.jl` foundation strategy and grouping
- Any function that receives a `tc` kwarg but doesn't emit events

### Step 3: Check each function for trace coverage

For each decision-making function:

1. Does it accept `tc::Union{Nothing, TraceCollector}` as a kwarg?
2. Does it emit `:enter` with problem dimensions and configuration?
3. Does it emit `:decision` or `:iteration` at key branch points?
4. Does it emit `:failure` or `:fallback` on error/recovery paths?
5. Does it emit `:exit` with the outcome?
6. Is it registered in `TRACE_REGISTRY` (via `@traced` or manual entry)?

### Step 4: Check the threading chain

Trace collectors must be threaded from `design_building` down to the leaf
functions. Check that `tc` is passed through:
- `design_building` → `build_pipeline` closures → stage functions
- `size_slabs!` → `size_slab!` → `_size_slab!` → `size_flat_plate!`
- `_size_beams_columns!` → `size_beams!` / `size_columns!`
- Any new pipeline stage or sizing function added since the last audit

If a function in the call chain lacks `tc`, the trace is silently broken for
everything below it. The fix is to add `tc` as a kwarg with default `nothing`
and pass it through.

### Step 5: Verify explain_feasibility coverage

For every `AbstractCapacityChecker` subtype:
1. Search for `struct *Checker <: AbstractCapacityChecker`
2. Check if `explain_feasibility` is implemented (not just the fallback)
3. If missing, implement it by mirroring the `is_feasible` logic but collecting
   `CheckResult`s for every code check instead of short-circuiting

---

## 4. How to Add Trace Instrumentation

### Adding `tc` to a function

```julia
function my_function(args...;
                     existing_kwargs...,
                     tc::Union{Nothing, TraceCollector} = nothing)
    emit!(tc, :layer, "my_function", element_id, :enter; key=value)
    # ... existing logic ...
    emit!(tc, :layer, "my_function", element_id, :exit; result=value)
end
```

### Registering in TRACE_REGISTRY (for documented functions)

```julia
TRACE_REGISTRY[(:my_function, :layer)] =
    TracedFunctionMeta(:my_function, :layer,
                       [:enter, :exit, :decision], nothing,
                       @__FILE__, @__LINE__)
```

### Event data guidelines

- Keep payloads small and JSON-serializable (strings, numbers, bools, vectors,
  dicts). Avoid Unitful quantities — convert with `string()` or `ustrip()`.
- Use `string(typeof(x))` for type information.
- For ratios and counts, use plain numbers.
- For section/material identifiers, use `string(section)`.

---

## 5. Testing

After adding instrumentation:

1. Run `julia --project=StructuralSizer scripts/runners/run_trace_tests.jl`
   to verify existing trace tests still pass.
2. For new `explain_feasibility` implementations, add tests following the
   pattern in `StructuralSizer/test/trace/test_trace.jl`.
3. Verify the function appears in `TRACE_REGISTRY` by checking the
   "registered_functions returns the registry" test set.

---

## 6. Do NOT Change

- Do not modify the `TraceEvent` or `TraceCollector` structs.
- Do not add tracing to hot inner loops (per-element feasibility checks, matrix
  operations). Trace at the function level, not the iteration level.
- Do not remove existing `emit!` calls unless the function they're in has been
  deleted.
- Do not change function signatures beyond adding the `tc` kwarg.
- Do not break existing tests. If a test fails because of a new kwarg, the
  default (`nothing`) should make it backward-compatible.

---

## 7. When Done

Commit all changes and provide a summary including:
- Number of functions newly instrumented
- Number of `explain_feasibility` implementations added
- Any threading gaps fixed (functions that now pass `tc` through)
- Functions you found that *might* need tracing but you weren't sure about —
  list these so the team can triage
