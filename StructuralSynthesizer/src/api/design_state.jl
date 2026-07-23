# =============================================================================
# DesignState — a serializable PROJECTION / ADAPTER over a BuildingDesign
#
# This is the P0 "unified design-state" substrate. It is a PROJECTION, not a
# rewrite: it binds the pieces of a design that today live in four different
# places — current params, per-element sizing results, the feasibility/trace,
# and governing corpus citations — into ONE plain, JSON-serializable object.
#
# The export form is deliberately DOMAIN-AGNOSTIC so an external, domain-agnostic
# linker (the separate "angelo" system) can index it later WITHOUT any
# menegroth- or angelo-specific coupling baked into the format:
#   • every referenceable entity carries a STABLE id, deterministic from its
#     element index / check name / clause (never a random or memory-address id);
#   • code / data / corpus references are EXPLICIT fields (citation ids that
#     resolve to the top-level `citations` registry);
#   • the payload is only Dicts / Vectors / scalars — no menegroth object handles.
#
# It reuses the existing serialize/diagnose/trace layers rather than duplicating
# them: element results come from `serialize.jl`'s `_serialize_*` field
# selection, governing checks + citations come from the `_diagnose_*` per-check
# dicts (grounded via `corpus_grounding.jl`), and the trace projection reuses
# `StructuralSizer.serialize_trace_event` / `filter_trace` / `build_stage_timeline`.
#
# SCOPE — this is an explanation/perception layer only. It never recomputes or
# alters any numeric ratio, demand, capacity, or pass/fail decision.
# =============================================================================

using OrderedCollections: OrderedDict

const DESIGN_STATE_SCHEMA = "design-state/v1"

"""
    _json_scalar(v)

Coerce a struct field value to a JSON-native, round-trip-consistent scalar.
`Symbol` is converted to `String` explicitly: JSON has no symbol type, so a raw
`Symbol` serializes as a string and would come back as a `String` on
`JSON3.read` (type-lossy). Emitting a `String` up front keeps the in-memory and
round-tripped values identical.

Non-finite floats (`NaN`, `Inf`, `-Inf`) are coerced to `nothing`: JSON has no
representation for them, and `JSON3.write` would otherwise emit the bare tokens
`NaN` / `Infinity`, which are invalid JSON and NOT round-trippable (`JSON3.read`
rejects them). Degenerate ratios (e.g. a 0/0 capacity) can surface such values,
so this guard protects the export's round-trip + byte-stability guarantee. Other
values pass through unchanged.
"""
function _json_scalar(v)
    v isa Symbol && return string(v)
    v isa AbstractFloat && !isfinite(v) && return nothing
    return v
end

"""Convert an API result struct (e.g. `APIColumnResult`) to a plain JSON-safe Dict.
`Symbol` fields are stringified via [`_json_scalar`](@ref) for round-trip consistency."""
_api_result_to_dict(r) = Dict{String, Any}(string(f) => _json_scalar(getfield(r, f)) for f in fieldnames(typeof(r)))

"""
    _canonicalize(x)

Recursively rewrite a JSON-safe payload into a form with a DETERMINISTIC byte
serialization: every `AbstractDict` (and `NamedTuple`) becomes an `OrderedDict`
with keys sorted lexicographically (mirroring the `sort(...)` already used for
`layers_present`), vectors and `Tuple`s are recursed element-wise, any stray
`Symbol` is stringified, and any non-finite float is coerced to `nothing`. Plain
`Dict` iteration order is hash-based and NOT stable across Julia versions, which
would break a content-hashing linker keyed on the export byte stream; sorting
the keys makes `JSON3.write` output stable and reproducible.

`NamedTuple` / `Tuple` are recursed (not passed through opaquely) so any nested
`Symbol` or non-finite float they carry is normalized too. `NaN`/`Inf`/`-Inf`
are mapped to `nothing` because they are not valid JSON tokens and are not
round-trippable — the same guard `_json_scalar` applies at the struct-field
boundary, repeated here to cover values that enter the payload by other paths.
"""
function _canonicalize(x)
    if x isa AbstractDict
        od = OrderedDict{String, Any}()
        for k in sort!(collect(keys(x)); by = string)
            od[string(k)] = _canonicalize(x[k])
        end
        return od
    elseif x isa NamedTuple
        # Treat like a dict: deterministic, sorted-key OrderedDict of its fields.
        od = OrderedDict{String, Any}()
        for k in sort!(collect(string.(keys(x))))
            od[k] = _canonicalize(getfield(x, Symbol(k)))
        end
        return od
    elseif x isa Tuple
        return Any[_canonicalize(v) for v in x]
    elseif x isa AbstractVector && !(x isa AbstractString)
        return Any[_canonicalize(v) for v in x]
    elseif x isa Symbol
        return string(x)
    elseif x isa AbstractFloat && !isfinite(x)
        return nothing
    else
        return x
    end
end

"""Human-readable label for a material object (its `name` field, else its type name)."""
_material_label(x) = x === nothing ? nothing :
    (hasproperty(x, :name) ? string(getproperty(x, :name)) : string(nameof(typeof(x))))

"""Snapshot the material cascade (component-level choices) as JSON-safe labels."""
function _materials_snapshot(m::MaterialOptions)
    return Dict{String, Any}(
        "concrete" => _material_label(m.concrete),
        "rebar"    => _material_label(m.rebar),
        "steel"    => _material_label(m.steel),
        "timber"   => _material_label(m.timber),
    )
end

"""
    _params_snapshot(params, du) -> Dict{String, Any}

Curated, JSON-safe snapshot of the design levers on `DesignParameters`. Captures
the scalar/symbol design knobs (not the full internal option objects), so the
state stays self-describing and stable across serialization.
"""
function _params_snapshot(params::DesignParameters, du::DisplayUnits)
    return Dict{String, Any}(
        "name"                   => params.name,
        "description"            => params.description,
        "unit_system"            => _is_imperial(du) ? "imperial" : "metric",
        "floor_options_type"     => params.floor === nothing ? nothing : string(nameof(typeof(params.floor))),
        "deflection_limit"       => string(params.deflection_limit),
        "optimize_for"           => string(params.optimize_for),
        "fire_rating"            => params.fire_rating,
        "max_iterations"         => params.max_iterations,
        "uniform_column_sizing"  => string(params.uniform_column_sizing),
        "geometry_is_centerline" => params.geometry_is_centerline,
        "pattern_loading"        => string(params.pattern_loading),
        "materials"              => _materials_snapshot(params.materials),
    )
end

"""
    _collect_state_elements!(elements, citations, etype, results, diags)

Pair compact sizing `results` (from `_serialize_*`, each carrying an integer
`id`) with the `_diagnose_*` per-element dicts (governing check + grounded
per-check citations) into stable-id element entries. Registers every referenced
citation into the shared `citations` registry (deduped by citation id).
"""
function _collect_state_elements!(
    elements::Vector{Dict{String, Any}},
    citations::Dict{String, Any},
    etype::String,
    results,
    diags,
)
    diag_by_id = Dict{Int, Any}()
    for d in diags
        d isa AbstractDict && haskey(d, "id") && (diag_by_id[Int(d["id"])] = d)
    end

    for r in results
        idx = Int(r.id)
        d = get(diag_by_id, idx, nothing)
        governing = d === nothing ? nothing : get(d, "governing_check", nothing)

        citation_ids = String[]
        governing_citation_id = nothing
        if d !== nothing
            for chk in get(d, "checks", Any[])
                chk isa AbstractDict || continue
                cit = get(chk, "citation", nothing)
                cit isa AbstractDict || continue
                cid = get(cit, "id", nothing)
                cid === nothing && continue
                cid = string(cid)
                citations[cid] = cit
                push!(citation_ids, cid)
                if governing !== nothing && string(get(chk, "name", "")) == string(governing)
                    governing_citation_id = cid
                end
            end
        end

        push!(elements, Dict{String, Any}(
            "id"                    => "$(etype)/$(idx)",   # stable, deterministic id
            "type"                  => etype,
            "index"                 => idx,
            "ok"                    => r.ok,
            "result"                => _api_result_to_dict(r),
            "governing_check"       => governing,
            "governing_citation_id" => governing_citation_id,
            "citation_ids"          => unique(citation_ids),
        ))
    end
    return elements
end

"""
    _trace_projection(design, tier) -> Dict{String, Any}

Tiered, JSON-safe projection of the solver decision trace. Reuses the shared
`StructuralSizer` trace primitives and, by design, does NOT dump the full raw
trace by default (the default `tier` filters to failure/fallback events plus the
pipeline/workflow timeline).
"""
function _trace_projection(design::BuildingDesign, tier::Symbol)
    events = design.solver_trace
    if isempty(events)
        return Dict{String, Any}(
            "tier"           => string(tier),
            "total_events"   => 0,
            "shown_events"   => 0,
            "layers_present" => String[],
            "stage_timeline" => Any[],
            "events"         => Any[],
        )
    end

    tier in StructuralSizer.TRACE_TIERS || (tier = :failures)
    filtered = StructuralSizer.filter_trace(events; tier = tier)

    return Dict{String, Any}(
        "tier"           => string(tier),
        "total_events"   => length(events),
        "shown_events"   => length(filtered),
        "layers_present" => sort(unique(string(ev.layer) for ev in events)),
        "stage_timeline" => StructuralSizer.build_stage_timeline(events),
        "events"         => StructuralSizer.serialize_trace_event.(filtered),
    )
end

"""
    design_to_design_state(design::BuildingDesign; report_units=nothing, trace_tier=:failures)
        -> Dict{String, Any}

Project a `BuildingDesign` into a unified, serializable DesignState (see file
header). The returned Dict binds four views of the design behind stable ids:

- `"params"`    — curated snapshot of the design levers ([`_params_snapshot`](@ref)).
- `"summary"`   — building-level totals (reuses `_serialize_summary`).
- `"elements"`  — per-element sizing results (reuses the `_serialize_*` field
  selection) each tagged with a stable `"id"`, its `"governing_check"`, and
  explicit `"citation_ids"` into the corpus.
- `"citations"` — deduped registry of grounded corpus references
  (`source_id` / `clause` / `page`), keyed by stable citation id.
- `"trace"`     — tiered projection of the solver decision trace.

All numeric values are in the display unit system given by `report_units`
(`:imperial` / `:metric`) or `design.params.display_units` when not specified.
The result is round-trippable through JSON3 (`JSON3.write` → `JSON3.read`).

# Keyword arguments
- `report_units`: override the display unit system (`:imperial` / `:metric`).
- `trace_tier`: trace disclosure tier (`:summary`, `:failures`, `:decisions`,
  `:full`); defaults to `:failures` to avoid dumping the full raw trace.
"""
function design_to_design_state(
    design::BuildingDesign;
    report_units = nothing,
    trace_tier::Symbol = :failures,
)::AbstractDict{String, Any}
    params = design.params
    du = report_units === nothing ? params.display_units : DisplayUnits(report_units)
    struc = design.structure

    # (b) compact per-element sizing results — reuse serialize.jl field selection.
    col_results  = _serialize_columns(design, du)
    beam_results = _serialize_beams(design, du)
    slab_results = _serialize_slabs(design, du)
    fdn_results  = _serialize_foundations(design, du)

    # (d) governing check + grounded corpus citations — reuse the /diagnose
    #     per-check dicts, which now carry a "citation" via corpus_grounding.jl.
    col_diag  = _diagnose_columns(design, struc, du)
    beam_diag = _diagnose_beams(design, struc, du)
    slab_diag = _diagnose_slabs(design, struc, du)
    fdn_diag  = _diagnose_foundations(design, du)

    citations = Dict{String, Any}()
    elements = Dict{String, Any}[]
    _collect_state_elements!(elements, citations, "column",     col_results,  col_diag)
    _collect_state_elements!(elements, citations, "beam",       beam_results, beam_diag)
    _collect_state_elements!(elements, citations, "slab",       slab_results, slab_diag)
    _collect_state_elements!(elements, citations, "foundation", fdn_results,  fdn_diag)

    # Canonicalize the whole payload (sorted keys, stringified symbols) so the
    # exported byte stream is deterministic and stable across Julia versions —
    # a hard requirement for the external content-hashing linker (P2).
    return _canonicalize(Dict{String, Any}(
        "schema"       => DESIGN_STATE_SCHEMA,
        "generated_at" => string(design.created),
        "status"       => "ok",
        "units" => Dict{String, Any}(
            "unit_system"    => _is_imperial(du) ? "imperial" : "metric",
            "length_unit"    => _length_unit_string(du),
            "thickness_unit" => _thickness_unit_string(du),
            "force_unit"     => _force_unit_str(du),
            "moment_unit"    => _moment_unit_str(du),
        ),
        "params"    => _params_snapshot(params, du),
        "summary"   => _api_result_to_dict(_serialize_summary(design, du)),
        "elements"  => elements,
        "citations" => citations,
        "trace"     => _trace_projection(design, trace_tier),
    ))
end
