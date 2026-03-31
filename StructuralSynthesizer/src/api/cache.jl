# =============================================================================
# API Cache — Geometry hashing + skeleton/structure cache
# =============================================================================

using SHA

"""
    DesignCache

Caches the last `BuildingSkeleton` and `BuildingStructure` keyed by a hash
of the geometry fields. When only design parameters change, the server skips
skeleton/structure rebuild and re-runs `design_building` on the cached structure.
"""
mutable struct DesignCache
    geometry_hash::String
    skeleton::Union{BuildingSkeleton, Nothing}
    structure::Union{BuildingStructure, Nothing}
    last_result::Union{APIOutput, APIError, Nothing}
    last_design::Union{BuildingDesign, Nothing}
    last_diagnose::Union{Dict{String, Any}, Nothing}
    diagnose_design_id::UInt64
    """Canonical wire-format API params snapshot (SSoT). Set on each successful POST /design or chat `run_design`; overwritten in full — no separate 'original' copy."""
    last_api_params_json::Dict{String, Any}
    lock::ReentrantLock
end

"""Create an empty `DesignCache` with no stored geometry or results."""
DesignCache() = DesignCache("", nothing, nothing, nothing, nothing, nothing, UInt64(0), Dict{String, Any}(), ReentrantLock())

"""Thread-safe read from the design cache."""
function with_cache_read(f, cache::DesignCache)
    lock(cache.lock) do
        f(cache)
    end
end

"""Thread-safe write to the design cache."""
function with_cache_write!(f, cache::DesignCache)
    lock(cache.lock) do
        f(cache)
    end
end

"""
    get_cached_diagnose(cache::DesignCache, design::BuildingDesign; kwargs...) -> Dict

Return the cached diagnose result if the design hasn't changed, otherwise
recompute and cache it.
"""
function get_cached_diagnose(cache::DesignCache, design::BuildingDesign; kwargs...)
    design_id = objectid(design)
    lock(cache.lock) do
        if !isnothing(cache.last_diagnose) && cache.diagnose_design_id == design_id
            return cache.last_diagnose
        end
        result = design_to_diagnose(design; kwargs...)
        cache.last_diagnose = result
        cache.diagnose_design_id = design_id
        return result
    end
end

"""Invalidate the cached diagnose result (call when design changes)."""
function invalidate_diagnose_cache!(cache::DesignCache)
    lock(cache.lock) do
        cache.last_diagnose = nothing
        cache.diagnose_design_id = UInt64(0)
    end
end

"""
    compute_geometry_hash(input::APIInput) -> String

Compute a deterministic SHA-256 hash of the geometry portion of the input
(units, vertices, edges, supports, stories_z, faces). Params are excluded
so that parameter-only changes produce the same hash.
"""
function compute_geometry_hash(input::APIInput)
    ctx = SHA.SHA256_CTX()

    # Units
    SHA.update!(ctx, Vector{UInt8}(input.units))

    # Vertices
    for v in input.vertices
        for c in v
            SHA.update!(ctx, reinterpret(UInt8, [c]))
        end
    end

    # Edges — beams then columns
    for edge in input.edges.beams
        SHA.update!(ctx, reinterpret(UInt8, Int64.(edge)))
    end
    for edge in input.edges.columns
        SHA.update!(ctx, reinterpret(UInt8, Int64.(edge)))
    end
    for edge in input.edges.braces
        SHA.update!(ctx, reinterpret(UInt8, Int64.(edge)))
    end

    # Supports
    SHA.update!(ctx, reinterpret(UInt8, Int64.(input.supports)))

    # Stories Z
    SHA.update!(ctx, reinterpret(UInt8, Float64.(input.stories_z)))

    # Faces (sorted by category for determinism)
    for cat in sort(collect(keys(input.faces)))
        SHA.update!(ctx, Vector{UInt8}(cat))
        for poly in input.faces[cat]
            for coord in poly
                SHA.update!(ctx, reinterpret(UInt8, Float64.(coord)))
            end
        end
    end

    return bytes2hex(SHA.digest!(ctx))
end

"""
    is_geometry_cached(cache::DesignCache, hash::String) -> Bool

Check whether the cache holds a skeleton/structure for the given geometry hash.
"""
function is_geometry_cached(cache::DesignCache, hash::String)
    lock(cache.lock) do
        !isempty(hash) && cache.geometry_hash == hash &&
        !isnothing(cache.skeleton) && !isnothing(cache.structure)
    end
end

# ─── Design history ring buffer ───────────────────────────────────────────────

"""
Snapshot of a completed design for session history.
Enables compare_designs and get_design_history tools.
"""
Base.@kwdef struct DesignHistoryEntry
    timestamp::DateTime        = now()
    geometry_hash::String      = ""
    params_patch::Dict{String, Any} = Dict{String, Any}()
    """Full resolved parameter snapshot for accurate cross-run comparison."""
    cumulative_params::Dict{String, Any} = Dict{String, Any}()
    all_pass::Bool             = false
    critical_ratio::Float64    = 0.0
    critical_element::String   = ""
    embodied_carbon::Float64   = 0.0
    n_columns::Int             = 0
    n_beams::Int               = 0
    n_slabs::Int               = 0
    n_failing::Int             = 0
    source::String             = "design"
end

const DESIGN_HISTORY      = DesignHistoryEntry[]
const DESIGN_HISTORY_LOCK = ReentrantLock()
const DESIGN_HISTORY_MAX  = 10

"""
    record_design_history!(entry::DesignHistoryEntry)

Append a design snapshot to session history, evicting the oldest when full.
"""
function record_design_history!(entry::DesignHistoryEntry)
    lock(DESIGN_HISTORY_LOCK) do
        push!(DESIGN_HISTORY, entry)
        while length(DESIGN_HISTORY) > DESIGN_HISTORY_MAX
            popfirst!(DESIGN_HISTORY)
        end
    end
end

"""
    get_design_history_entries() -> Vector{DesignHistoryEntry}

Return a copy of the current design history.
"""
function get_design_history_entries()
    lock(DESIGN_HISTORY_LOCK) do
        copy(DESIGN_HISTORY)
    end
end

"""
    clear_design_history!()

Remove all entries from the design-history ring buffer. Call when the server
loads a new geometry hash so `compare_designs` / `get_design_history` are not
mixed across different models.
"""
function clear_design_history!()
    lock(DESIGN_HISTORY_LOCK) do
        empty!(DESIGN_HISTORY)
    end
    return nothing
end

"""
    design_history_to_json(entries::Vector{DesignHistoryEntry}) -> Vector{Dict{String, Any}}

Serialize design history entries for JSON output.
"""
function design_history_to_json(entries::Vector{DesignHistoryEntry})
    return [Dict{String, Any}(
        "index"             => i,
        "timestamp"         => Dates.format(e.timestamp, "yyyy-mm-dd HH:MM:SS"),
        "geometry_hash"     => e.geometry_hash,
        "params_patch"      => e.params_patch,
        "cumulative_params" => e.cumulative_params,
        "all_pass"          => e.all_pass,
        "critical_ratio"    => round(e.critical_ratio; digits=3),
        "critical_element"  => e.critical_element,
        "embodied_carbon"   => round(e.embodied_carbon; digits=0),
        "n_columns"         => e.n_columns,
        "n_beams"           => e.n_beams,
        "n_slabs"           => e.n_slabs,
        "n_failing"         => e.n_failing,
        "source"            => e.source,
    ) for (i, e) in enumerate(entries)]
end

# ─── Session Insights ─────────────────────────────────────────────────────────

"""
Structured learning from a design iteration. The LLM records these after
observing design outcomes so it can avoid re-exploring dead ends and build
on what worked. Cross-referenced with design history indices.
"""
Base.@kwdef struct SessionInsight
    timestamp::DateTime             = now()
    category::Symbol                = :observation  # :observation, :discovery, :dead_end, :sensitivity, :geometry_note
    summary::String                 = ""            # One-line human-readable summary
    detail::String                  = ""            # Longer explanation (optional)
    related_checks::Vector{String}  = String[]      # Governing check families involved
    related_params::Vector{String}  = String[]      # Parameters that were changed/relevant
    design_index::Int               = 0             # Which design history entry this relates to (0 = general)
    confidence::Float64             = 0.5           # 0-1 how confident the LLM is in this insight
end

const SESSION_INSIGHTS      = SessionInsight[]
const SESSION_INSIGHTS_LOCK = ReentrantLock()
const SESSION_INSIGHTS_MAX  = 50

"""
    record_session_insight!(insight::SessionInsight)

Append a session insight. Evicts oldest when at capacity.
"""
function record_session_insight!(insight::SessionInsight)
    lock(SESSION_INSIGHTS_LOCK) do
        push!(SESSION_INSIGHTS, insight)
        while length(SESSION_INSIGHTS) > SESSION_INSIGHTS_MAX
            popfirst!(SESSION_INSIGHTS)
        end
    end
end

"""
    get_session_insights(; category, check, param, min_confidence) -> Vector{SessionInsight}

Retrieve session insights with optional filtering.
"""
function get_session_insights(;
    category::Union{Symbol, Nothing} = nothing,
    check::Union{String, Nothing} = nothing,
    param::Union{String, Nothing} = nothing,
    min_confidence::Float64 = 0.0,
)::Vector{SessionInsight}
    lock(SESSION_INSIGHTS_LOCK) do
        filter(SESSION_INSIGHTS) do s
            !isnothing(category) && s.category != category && return false
            !isnothing(check) && !(check in s.related_checks) && return false
            !isnothing(param) && !(param in s.related_params) && return false
            s.confidence < min_confidence && return false
            return true
        end
    end
end

"""
    clear_session_insights!()

Clear all session insights (e.g. when geometry changes).
"""
function clear_session_insights!()
    lock(SESSION_INSIGHTS_LOCK) do
        empty!(SESSION_INSIGHTS)
    end
end

"""
    session_insights_to_json(insights::Vector{SessionInsight}) -> Vector{Dict{String, Any}}

Serialize session insights for JSON output.
"""
function session_insights_to_json(insights::Vector{SessionInsight})
    return [Dict{String, Any}(
        "index"           => i,
        "timestamp"       => Dates.format(s.timestamp, "yyyy-mm-dd HH:MM:SS"),
        "category"        => string(s.category),
        "summary"         => s.summary,
        "detail"          => s.detail,
        "related_checks"  => s.related_checks,
        "related_params"  => s.related_params,
        "design_index"    => s.design_index,
        "confidence"      => round(s.confidence; digits=2),
    ) for (i, s) in enumerate(insights)]
end
