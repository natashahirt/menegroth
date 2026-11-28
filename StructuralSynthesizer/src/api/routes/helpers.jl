# ─── Global state ─────────────────────────────────────────────────────────────

const DESIGN_CACHE = DesignCache()
const SERVER_STATUS = ServerStatus()
const DESIGN_LOG_LINES = String[]
const DESIGN_LOG_LOCK = ReentrantLock()
const DESIGN_LOG_BASE_INDEX = Ref(0)
const DESIGN_LOG_MAX_LINES = 2000

"""Best-effort integer coercion for route/query values."""
function _route_coerce_int(x)::Union{Int, Nothing}
    isnothing(x) && return nothing
    x isa Integer && return Int(x)
    if x isa Real
        return isinteger(x) ? Int(x) : nothing
    elseif x isa AbstractString
        s = strip(x)
        isempty(s) && return nothing
        i = tryparse(Int, s)
        !isnothing(i) && return i
        f = tryparse(Float64, s)
        (!isnothing(f) && isfinite(f) && isinteger(f)) && return Int(f)
    end
    return nothing
end

"""Best-effort float coercion for route/body values."""
function _route_coerce_float(x)::Union{Float64, Nothing}
    isnothing(x) && return nothing
    x isa Real && return Float64(x)
    if x isa AbstractString
        s = strip(x)
        isempty(s) && return nothing
        return tryparse(Float64, replace(s, "," => ""))
    end
    return nothing
end

function _reset_design_logs!()
    lock(DESIGN_LOG_LOCK) do
        empty!(DESIGN_LOG_LINES)
        DESIGN_LOG_BASE_INDEX[] = 0
    end
    return nothing
end

function _append_design_log!(line::AbstractString)
    clean = isempty(line) ? "" : strip(String(line))
    lock(DESIGN_LOG_LOCK) do
        push!(DESIGN_LOG_LINES, clean)
        while length(DESIGN_LOG_LINES) > DESIGN_LOG_MAX_LINES
            popfirst!(DESIGN_LOG_LINES)
            DESIGN_LOG_BASE_INDEX[] += 1
        end
    end
    return nothing
end

function _read_design_logs_since(since::Int)
    lock(DESIGN_LOG_LOCK) do
        base = DESIGN_LOG_BASE_INDEX[]
        total = base + length(DESIGN_LOG_LINES)
        clamped = max(0, min(since, total))
        start_abs = max(clamped, base)
        start_local = start_abs - base + 1
        lines = start_local <= length(DESIGN_LOG_LINES) ?
            DESIGN_LOG_LINES[start_local:end] :
            String[]
        return (base=base, next_since=total, lines=copy(lines))
    end
end

function _query_int(req::HTTP.Request, key::String, default::Int=0)
    target = String(req.target)
    qidx = findfirst('?', target)
    qidx === nothing && return default
    query = target[qidx + 1:end]
    for pair in split(query, '&')
        kv = split(pair, '='; limit=2)
        length(kv) == 2 || continue
        kv[1] == key || continue
        v = _route_coerce_int(kv[2])
        return isnothing(v) ? default : v
    end
    return default
end

"""Return query param value for key, or nothing if absent/invalid."""
function _query_string(req::HTTP.Request, key::String)::Union{String, Nothing}
    target = String(req.target)
    qidx = findfirst('?', target)
    qidx === nothing && return nothing
    query = target[qidx + 1:end]
    for pair in split(query, '&')
        kv = split(pair, '='; limit=2)
        length(kv) == 2 || continue
        strip(lowercase(kv[1])) == key || continue
        return strip(kv[2])
    end
    return nothing
end

# ─── JSON helpers ─────────────────────────────────────────────────────────────

"""Build a JSON HTTP response with the given status code."""
function _json_resp(status_code::Int, obj)
    body = JSON3.write(obj)
    return HTTP.Response(status_code, ["Content-Type" => "application/json"], body)
end

"""HTTP 200 JSON response."""
_json_ok(obj) = _json_resp(200, obj)
"""HTTP 400 JSON response."""
_json_bad(obj) = _json_resp(400, obj)
"""HTTP 500 JSON response."""
_json_err(obj) = _json_resp(500, obj)

"""Parse a JSON request body into `APIInput`, returning `(input, nothing)` on
success or `(nothing, HTTP.Response)` with a 400 error on parse failure."""
function _parse_json_body(req::HTTP.Request)
    try
        input = JSON3.read(String(req.body), APIInput)
        return (input, nothing)
    catch e
        resp = _json_bad(Dict(
            "status" => "error",
            "error" => "ParseError",
            "message" => "Invalid JSON: $(sprint(showerror, e))",
        ))
        return (nothing, resp)
    end
end

"""Build a standard 400 validation-error response from a `ValidationResult`."""
function _validation_error_response(vr::ValidationResult)
    structured = [
        Dict(
            "field" => e.field,
            "value" => e.value,
            "constraint" => e.constraint,
            "allowed" => e.allowed,
            "message" => e.message,
        )
        for e in vr.errors
    ]
    return _json_bad(Dict(
        "status" => "error",
        "error" => "ValidationError",
        "message" => "Validation failed: $(length(vr.errors)) error(s)",
        "errors" => structured,
    ))
end

