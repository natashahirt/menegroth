# =============================================================================
# API Status — Server state tracking and single-slot request queue
# =============================================================================

"""Server states."""
@enum ServerState begin
    SERVER_IDLE
    SERVER_RUNNING
    SERVER_QUEUED
end

"""
    ServerStatus

Thread-safe server status with a single-slot request queue.

- `state`: current server state (idle / running / queued)
- `queued_input`: the most recent queued request (latest wins)
- `lock`: protects all mutable fields
"""
mutable struct ServerStatus
    state::ServerState
    queued_input::Union{APIInput, Nothing}
    lock::ReentrantLock
end

"""Create an idle `ServerStatus` with no queued input."""
ServerStatus() = ServerStatus(SERVER_IDLE, nothing, ReentrantLock())

"""Get the current server state as a string."""
function status_string(ss::ServerStatus)
    lock(ss.lock) do
        ss.state == SERVER_IDLE    && return "idle"
        ss.state == SERVER_RUNNING && return "running"
        ss.state == SERVER_QUEUED  && return "queued"
        return "unknown"
    end
end

"""
    try_start!(ss::ServerStatus) -> Bool

Attempt to transition from IDLE → RUNNING. Returns `true` if successful.
"""
function try_start!(ss::ServerStatus)
    lock(ss.lock) do
        if ss.state == SERVER_IDLE
            ss.state = SERVER_RUNNING
            return true
        end
        return false
    end
end

"""
    enqueue!(ss::ServerStatus, input::APIInput) -> Bool

Queue a request while the server is running. Returns `true` if the request
was queued (server was RUNNING), `false` if the server was idle (caller
should run immediately instead).
"""
function enqueue!(ss::ServerStatus, input::APIInput)
    lock(ss.lock) do
        if ss.state == SERVER_RUNNING || ss.state == SERVER_QUEUED
            ss.queued_input = input
            ss.state = SERVER_QUEUED
            return true
        end
        return false
    end
end

"""
    finish!(ss::ServerStatus) -> Union{APIInput, Nothing}

Transition from RUNNING/QUEUED → IDLE. If a queued request exists, returns
it and transitions to RUNNING (caller should process the queued request).
Otherwise transitions to IDLE and returns `nothing`.
"""
function finish!(ss::ServerStatus)
    lock(ss.lock) do
        queued = ss.queued_input
        ss.queued_input = nothing
        if !isnothing(queued)
            ss.state = SERVER_RUNNING
            return queued
        else
            ss.state = SERVER_IDLE
            return nothing
        end
    end
end
