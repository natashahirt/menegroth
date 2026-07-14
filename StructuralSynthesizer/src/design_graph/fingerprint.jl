# =============================================================================
# DesignGraph — Fingerprinting (Run 2)
# =============================================================================
#
# Two content-addressed hashes per node, both SHA-256 (generalizing the existing
# `compute_geometry_hash` in api/cache.jl — same `SHA256_CTX` + `update!` + byte
# serialization discipline, just applied to node inputs/outputs instead of raw
# geometry):
#
#   input_hash(node, upstream_output_hashes, params; base_hash)
#       = H(code_version tag, node identity/NodeKey, upstream OUTPUT hashes,
#           the node's declared param slice, base_hash)
#     — changes iff anything the node depends on changes → drives recompute.
#
#   output_hash(node, struc)
#       = H(the struc fields the node WRITES)  (via `struc_writes(node)`)
#     — used for EARLY CUTOFF: if a recomputed node's output hash equals the
#       memoized one, its downstream inputs are unchanged, so downstream stays
#       clean.
#
# SAFETY: `output_hash` must be COMPLETE over the node's declared writes — a
# missed field would let early cutoff skip a genuinely-dirty downstream node
# (stale reuse). The per-field extractors below mirror exactly the design-mutable
# state (columns, beams, cells, slabs, asap model, supports, foundations), i.e.
# the same fields the snapshot mechanism (core/snapshot.jl) captures.
# =============================================================================

using SHA

# -----------------------------------------------------------------------------
# Low-level content serializer — deterministic bytes into a SHA256 context.
# -----------------------------------------------------------------------------
# Handles only the PLAIN value types produced by the field extractors below
# (numbers, bools, strings/symbols, Unitful quantities, arrays, tuples, pairs,
# nothing). A type tag precedes every value so structurally different data can
# never alias. Anything unexpected falls back to a `repr` string, which is
# deterministic and content-based for the value structs used here.

_hash_tag!(ctx::SHA.SHA256_CTX, tag::Char) = SHA.update!(ctx, UInt8[UInt8(tag)])

function _content_hash!(ctx::SHA.SHA256_CTX, ::Nothing)
    _hash_tag!(ctx, 'N')
    return ctx
end

function _content_hash!(ctx::SHA.SHA256_CTX, x::Bool)
    _hash_tag!(ctx, 'B')
    SHA.update!(ctx, UInt8[x ? 0x01 : 0x00])
    return ctx
end

function _content_hash!(ctx::SHA.SHA256_CTX, x::Integer)
    _hash_tag!(ctx, 'I')
    # Widen to Int128 so any 64-bit integer (signed OR unsigned, e.g. a UInt64
    # objectid/hash surfaced by a field extractor) serializes without an
    # InexactError from a lossy Int64 conversion.
    SHA.update!(ctx, reinterpret(UInt8, [Int128(x)]))
    return ctx
end

function _content_hash!(ctx::SHA.SHA256_CTX, x::AbstractFloat)
    _hash_tag!(ctx, 'F')
    SHA.update!(ctx, reinterpret(UInt8, [Float64(x)]))
    return ctx
end

function _content_hash!(ctx::SHA.SHA256_CTX, x::Union{Symbol, AbstractString})
    _hash_tag!(ctx, x isa Symbol ? 'Y' : 'S')
    SHA.update!(ctx, Vector{UInt8}(String(x)))
    _hash_tag!(ctx, '|')   # length-delimit strings so "ab"+"c" ≠ "a"+"bc"
    return ctx
end

function _content_hash!(ctx::SHA.SHA256_CTX, x::Unitful.Quantity)
    _hash_tag!(ctx, 'Q')
    SHA.update!(ctx, reinterpret(UInt8, [Float64(Unitful.ustrip(x))]))
    _content_hash!(ctx, string(Unitful.unit(x)))
    return ctx
end

function _content_hash!(ctx::SHA.SHA256_CTX, x::Pair)
    _hash_tag!(ctx, 'P')
    _content_hash!(ctx, x.first)
    _content_hash!(ctx, x.second)
    return ctx
end

function _content_hash!(ctx::SHA.SHA256_CTX, x::Union{Tuple, AbstractArray})
    _hash_tag!(ctx, x isa Tuple ? 'T' : 'A')
    SHA.update!(ctx, reinterpret(UInt8, [Int64(length(x))]))
    for el in x
        _content_hash!(ctx, el)
    end
    return ctx
end

# Fallback: deterministic `repr` for value-like structs (sections, sizer
# results, material/floor option structs, etc.). NOT used for `BuildingStructure`
# members (which can hold back-references, e.g. `Column.column_above`) — those go
# through the explicit field extractors below.
function _content_hash!(ctx::SHA.SHA256_CTX, x)
    _hash_tag!(ctx, 'R')
    SHA.update!(ctx, Vector{UInt8}(repr(x)))
    _hash_tag!(ctx, '|')
    return ctx
end

"""
    content_hash(x) -> String

SHA-256 hex digest of a value's canonical byte serialization. Deterministic
within a process for the plain value types produced by the fingerprint
extractors (and for `repr`-able value structs via the fallback).
"""
function content_hash(x)
    ctx = SHA.SHA256_CTX()
    _content_hash!(ctx, x)
    return bytes2hex(SHA.digest!(ctx))
end

# -----------------------------------------------------------------------------
# Per-field struc fingerprints — the design-mutable state, by field name.
# -----------------------------------------------------------------------------
# Each returns a plain, deterministically-hashable summary of one
# BuildingStructure field. These mirror the fields the pipeline mutates (and the
# snapshot mechanism captures), so `output_hash` over a node's `struc_writes`
# fully reflects everything downstream can observe.

_section_fp(m) = repr(section(m))

function _field_fingerprint(struc, field::Symbol)
    if field === :columns
        return Any[(col.c1, col.c2, col.shape, _section_fp(col), repr(volumes(col)))
                   for col in struc.columns]
    elseif field === :beams
        return Any[(_section_fp(b), repr(volumes(b))) for b in struc.beams]
    elseif field === :cells
        return Any[(c.sdl, c.self_weight, c.live_load) for c in struc.cells]
    elseif field === :slabs
        return Any[(repr(slab.result),
                    repr(hasproperty(slab, :design_details) ? slab.design_details : nothing),
                    repr(slab.volumes),
                    repr(slab.drop_panel)) for slab in struc.slabs]
    elseif field === :supports
        # forces carry units (kN / kN·m); keep them as Quantities and let the
        # recursive content hasher serialize each element (no Float64 coercion,
        # which would throw on dimensionful values).
        return Any[collect(s.forces) for s in struc.supports]
    elseif field === :foundations
        return Any[(repr(f.result), f.group_id, collect(Int, f.support_indices))
                   for f in struc.foundations]
    elseif field === :asap_model
        return _asap_fingerprint(struc.asap_model)
    else
        # Unknown field: fall back to a repr of the whole field. Safe (complete)
        # but coarse; declared writes should use the named fields above.
        return repr(getproperty(struc, field))
    end
end

# Asap model fingerprint: everything downstream nodes read off the solved model
# — per-element internal forces + section, and the global displacement/reaction
# vectors. Element sections determine the assembled stiffness, so identical
# sections + forces ⇒ identical downstream analysis. Deliberately excludes the
# recomputable factorization cache and topology (fixed after `prepare!`).
function _asap_fingerprint(model)
    (isnothing(model) || isempty(model.elements)) && return Any[]
    # Keep raw element/global vectors (may be plain Float64 or dimensionful) and
    # let the recursive content hasher serialize each element; forcing Float64
    # would throw on unit-ful entries.
    els = Any[(collect(el.forces), repr(el.section)) for el in model.elements]
    return Any[els, collect(model.u), collect(model.reactions)]
end

# -----------------------------------------------------------------------------
# Param-slice hashing — generalizes compute_geometry_hash to DesignParameters.
# -----------------------------------------------------------------------------

"""
    hash_param_slice(params::DesignParameters, slice) -> String

SHA-256 digest of the named `DesignParameters` fields in `slice`. Field order is
normalized (sorted) so the hash is independent of declaration order, and each
field's name is mixed in alongside its value so two different fields sharing a
value cannot alias. Content-based (equal parameter values ⇒ equal hash) for the
value-struct field types on `DesignParameters`.
"""
function hash_param_slice(params::DesignParameters, slice)
    ctx = SHA.SHA256_CTX()
    for f in sort(collect(Symbol, slice))
        _content_hash!(ctx, f)
        _content_hash!(ctx, getfield(params, f))
    end
    return bytes2hex(SHA.digest!(ctx))
end

# -----------------------------------------------------------------------------
# Node input / output hashes.
# -----------------------------------------------------------------------------

"""
    output_hash(node::DesignNode, struc::BuildingStructure) -> String

SHA-256 digest of the `BuildingStructure` fields `node` writes (see
[`struc_writes`](@ref)), taken in a normalized field order. Two structures with
equal output hashes for a node have byte-identical state in that node's written
fields — the basis for early cutoff.
"""
function output_hash(node::DesignNode, struc::BuildingStructure)
    ctx = SHA.SHA256_CTX()
    for f in sort(struc_writes(node))
        _content_hash!(ctx, f)
        _content_hash!(ctx, _field_fingerprint(struc, f))
    end
    return bytes2hex(SHA.digest!(ctx))
end

"""
    input_hash(node, upstream_output_hashes, params; base_hash="") -> String

SHA-256 digest of everything `node`'s output depends on:

- `code_version(node)` — bump to force invalidation on a code change,
- `node_key(node)` — the node's content-stable identity,
- `upstream_output_hashes` — the OUTPUT hashes of `node`'s dependencies (in the
  order supplied by the caller; the scheduler passes them in dependency order),
- the node's declared param slice ([`hash_param_slice`](@ref)),
- `base_hash` — a per-engine baseline tag (prepared geometry/loads) so results
  keyed in a shared memo never alias across different prepared structures.

Equal input hashes ⇒ the node's recompute would be identical ⇒ its memoized
result may be reused.
"""
function input_hash(node::DesignNode, upstream_output_hashes, params::DesignParameters;
                    base_hash::AbstractString = "")
    ctx = SHA.SHA256_CTX()
    _content_hash!(ctx, code_version(node))
    _content_hash!(ctx, node_key(node))
    _content_hash!(ctx, base_hash)
    for h in upstream_output_hashes
        _content_hash!(ctx, h)
    end
    _content_hash!(ctx, hash_param_slice(params, param_slice(node)))
    return bytes2hex(SHA.digest!(ctx))
end
