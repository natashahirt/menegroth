# Documentation Nightly Update — Agent Instructions

## Goal

Audit all Markdown files under `docs/src/` against the Julia source code in
`StructuralSizer/src/` and `StructuralSynthesizer/src/`. Fix every discrepancy.
The docs should be accurate enough that a user can copy-paste a Quick Start
example and have it run without modification.

## Scope (when "Changed files" is provided)

If a **Changed files** list appears at the end of this prompt, **prioritize**
those paths and any doc pages or source files that reference them. For those,
apply the full audit (API accuracy, structural consistency, stale limitations,
etc.). For all other files, do a lighter pass: only fix obvious errors or skip
unless you find clear discrepancies. This keeps the audit focused on what
actually changed.

---

## 1. API Accuracy (highest priority)

Every function call, type name, keyword argument, and default value in the docs
must match the actual source.

### Verifying function and type names
- For every function or type referenced in a code example, confirm it appears in
  the `export` lines of `StructuralSizer.jl` or `StructuralSynthesizer.jl`.
- If a name is not exported, search the source for it — it may have been renamed
  or made internal. Update the docs to the current name.

### Verifying keyword arguments, types, and defaults
- For every options/parameters table in the docs, locate the corresponding
  `Base.@kwdef struct` in source. Compare field-by-field:
  - **Name**: Does the field exist? Has it been renamed or removed?
  - **Type**: Does the documented type match the declared type exactly?
    Watch for `Symbol` vs enum, `Symbol` vs struct instance, `Bool` vs `Symbol`,
    `Float64` vs `Symbol`, concrete type vs `Union{..., Nothing}`.
  - **Default**: Does the documented default match the `@kwdef` default exactly?
    Watch for numeric values, tuple bounds, and `nothing` vs a concrete default.
- For every function call in a code example, check that each keyword argument
  exists in the function signature and that the value passed is a valid instance
  of the declared parameter type. Common traps:
  - Passing a `Symbol` where the function expects a struct instance (or vice versa)
  - Passing a parent type where a specific subtype is required
  - Passing a constructor call `Foo()` where a `const` value `Foo` is expected
    (or vice versa)

### Verifying return types
- Where docs describe what a function returns (e.g. "returns a `NamedTuple` with
  fields..."), trace the `return` statements in the source to confirm the field
  names and types.

---

## 2. Structural Consistency

All pages of the same kind should follow the same heading structure:

- **Standard sections** (in order): Quick Start blockquote → Overview →
  Key Types → Functions → Implementation Details → Options & Configuration →
  Limitations & Future Work → References
- Not every page needs every section, but the ones present should be in this
  order.
- Use **"Limitations & Future Work"** (not "Limitations & Assumptions")
  everywhere.
- Use **"References"** (plural) everywhere.

---

## 3. Stale Limitations

Read every item in every "Limitations & Future Work" section and verify it
against source code. Search for the feature described — if a function, test, or
dispatch method now exists for it, the limitation is stale and should be updated
or removed.

---

## 4. `@docs` Block Coverage

Every major exported type should have a `@docs` block on its canonical
documentation page so Documenter.jl pulls in the docstring. To audit:
1. Collect all exported types from both `StructuralSizer.jl` and
   `StructuralSynthesizer.jl` (lines starting with `export`).
2. Search `docs/src/` for ` ```@docs` blocks and extract every symbol inside.
3. Any exported type with no `@docs` block should be added to its canonical page.

---

## 5. Cross-References and Navigation

- Verify `docs/make.jl` pages list matches files on disk (no orphans, no broken
  nav entries).
- Verify all `](relative_path.md)` links resolve to existing files.
- External links to Asap.jl must point to `natashahirt/Asap.jl` (local fork).

---

## 6. Math Formatting

Equations for structural engineering formulas should use fenced LaTeX blocks:

    ```math
    a = \frac{A_s f_y}{0.85 f'_c b}
    ```

NOT inline code like `a = As × fy / (0.85 × fc′ × b)`. Check all design code
pages for inline equations that should be math blocks.

---

## 7. API-Specific Checks (HTTP API docs under `docs/src/api/`)

- `schema.md`: Verify every field table against the corresponding `@kwdef struct`
  in `StructuralSynthesizer/src/api/schema.jl`.
- `validation.md`: Verify the validation checks table against
  `StructuralSynthesizer/src/api/validation.jl`.
- `serialization.md`: Verify the JSON-to-Julia mapping table against
  `StructuralSynthesizer/src/api/deserialize.jl`.
- `overview.md`: Verify example JSON responses against route handlers in
  `StructuralSynthesizer/src/api/routes.jl`.

---

## 8. Do NOT Change

- Do not modify source code (`.jl` files), only documentation (`.md` files and
  docstrings in `.jl` files).
- Do not add new documentation pages — only update existing ones.
- Do not change `docs/make.jl` page ordering unless a file was renamed.
- Do not invent example code; every example must be verifiable against the
  exports.

---

## 9. When Done

Once all changes are committed, send a summary to the Slack channel
`@menegroth-nightly-documentation` including:
- Number of files changed
- Brief description of each fix (grouped by category: API accuracy, stale
  limitations, math formatting, etc.)
- **Recommendations for API cleanup** — a short, actionable list of improvements
  you noticed but did not implement (docs-only). Examples: naming inconsistencies,
  missing or redundant exports, schema/validation clarity, deprecated patterns,
  or doc/source mismatches that would require code changes. Keep each item
  one line so the team can triage.
- Any loose ends or ambiguities you encountered but could not resolve — flag
  these clearly so they can be addressed manually.

Thank you!
