# =============================================================================
# Ludicrous building → local Sizer API → OpenAI chat → print assistant reply
#
# Geometry: 159×108 ft footprint, 3 stories, 1 bay in X (full 159 ft span),
# 3 bays in Y (~36 ft each) — intentionally extreme flat-plate bay sizes.
#
# Usage:
#   1) Put your API key in `secrets/openai_api_key` (or set CHAT_LLM_API_KEY).
#   2) Run this script (it can spawn the bootstrap server automatically):
#        julia --project=StructuralSynthesizer scripts/runners/run_ludicrous_openai_chat.jl
#
# Env:
#   APP_URL / first CLI arg     — API base (default http://127.0.0.1:18888)
#   LUDICROUS_START_SERVER      — "1" spawn sizer_bootstrap.jl, "0" use existing server
#   LUDICROUS_CHAT_PORT         — port when spawning (default 18888)
#   CHAT_LLM_*                  — inherited by child server (same as sizer_bootstrap)
# =============================================================================

using Pkg
const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
Pkg.activate(joinpath(REPO_ROOT, "StructuralSynthesizer"))

using HTTP
using JSON3
using Unitful
using StructuralSynthesizer
import Meshes

const START_SERVER = get(ENV, "LUDICROUS_START_SERVER", "1") == "1"
const SPAWN_PORT = parse(Int, get(ENV, "LUDICROUS_CHAT_PORT", "18888"))
const BASE = length(ARGS) >= 1 ? rstrip(ARGS[1], '/') :
    get(ENV, "APP_URL", "http://127.0.0.1:$(START_SERVER ? SPAWN_PORT : 8080)")

"""Convert a `gen_medium_office` skeleton to POST /design JSON (feet, 1-based indices)."""
function skeleton_to_design_payload(skel::BuildingSkeleton)::Dict{String, Any}
    verts = Vector{Vector{Float64}}()
    sizehint!(verts, length(skel.vertices))
    for p in skel.vertices
        c = Meshes.coords(p)
        x = ustrip(u"ft", uconvert(u"ft", c.x))
        y = ustrip(u"ft", uconvert(u"ft", c.y))
        z = ustrip(u"ft", uconvert(u"ft", c.z))
        push!(verts, [round(x; digits=4), round(y; digits=4), round(z; digits=4)])
    end
    beam_pairs = Vector{Vector{Int}}()
    for ei in get(skel.groups_edges, :beams, Int[])
        a, b = skel.edge_indices[ei]
        push!(beam_pairs, [a, b])
    end
    col_pairs = Vector{Vector{Int}}()
    for ei in get(skel.groups_edges, :columns, Int[])
        a, b = skel.edge_indices[ei]
        push!(col_pairs, [a, b])
    end
    supp = sort!(collect(get(skel.groups_vertices, :support, Int[])))
    sz_ft = Float64[ustrip(u"ft", uconvert(u"ft", z)) for z in skel.stories_z]
    params = Dict{String, Any}(
        "unit_system" => "imperial",
        "loads" => Dict(
            "floor_LL_psf" => 80,
            "roof_LL_psf" => 20,
            "grade_LL_psf" => 100,
            "floor_SDL_psf" => 15,
            "roof_SDL_psf" => 15,
            "wall_SDL_psf" => 10,
        ),
        "floor_type" => "flat_plate",
        "floor_options" => Dict(
            "method" => "DDM",
            "deflection_limit" => "L_360",
            "punching_strategy" => "grow_columns",
        ),
        "materials" => Dict(
            "concrete" => "NWC_4000",
            "column_concrete" => "NWC_6000",
            "rebar" => "Rebar_60",
            "steel" => "A992",
        ),
        "column_type" => "rc_rect",
        "beam_type" => "steel_w",
        "fire_rating" => 0,
        "optimize_for" => "weight",
        "max_iterations" => 4,
        "size_foundations" => false,
        "skip_visualization" => true,
        "visualization_detail" => "minimal",
    )
    return Dict{String, Any}(
        "units" => "feet",
        "vertices" => verts,
        "edges" => Dict(
            "beams" => beam_pairs,
            "columns" => col_pairs,
            "braces" => Vector{Vector{Int}}(),
        ),
        "supports" => supp,
        "stories_z" => sz_ft,
        "faces" => Dict{String, Any}(),
        "params" => params,
    )
end

function geometry_only(d::Dict{String, Any})::Dict{String, Any}
    Dict{String, Any}(
        "units" => d["units"],
        "vertices" => d["vertices"],
        "edges" => d["edges"],
        "supports" => d["supports"],
        "stories_z" => d["stories_z"],
        "faces" => d["faces"],
    )
end

function wait_bootstrap_ready(base::String; max_s::Int = 300)::Bool
    for _ in 1:max_s
        try
            r = HTTP.get("$(base)/status"; readtimeout = 5)
            r.status == 200 || (sleep(1); continue)
            o = JSON3.read(String(r.body))
            st = string(get(o, :state, get(o, "state", "")))
            ready = Bool(get(o, :ready, get(o, "ready", false)))
            if ready && st != "warming" && st != "error"
                return true
            end
        catch
        end
        sleep(1)
    end
    return false
end

function wait_design_idle(base::String; max_s::Int = 900)::Bool
    for _ in 1:max_s
        try
            r = HTTP.get("$(base)/status"; readtimeout = 10)
            r.status == 200 || (sleep(1); continue)
            o = JSON3.read(String(r.body))
            st = string(get(o, :state, get(o, "state", "")))
            st == "idle" && return true
        catch
        end
        sleep(1)
    end
    return false
end

"""Extract assistant-visible text from an SSE body (token deltas + final token)."""
function collect_sse_assistant_text(body::String)::String
    parts = String[]
    for line in split(body, '\n')
        startswith(line, "data: ") || continue
        payload = strip(line[7:end])
        payload == "[DONE]" && continue
        try
            obj = JSON3.read(payload)
            tok = get(obj, :token, get(obj, "token", nothing))
            if tok !== nothing
                push!(parts, string(tok))
            end
        catch
        end
    end
    join(parts, "")
end

function main()
    skel = gen_medium_office(159.0u"ft", 108.0u"ft", 12.0u"ft", 1, 3, 3)
    payload = skeleton_to_design_payload(skel)
    geo = geometry_only(payload)

    server_proc = nothing
    if START_SERVER
        proj = joinpath(REPO_ROOT, "StructuralSynthesizer")
        boot = joinpath(REPO_ROOT, "scripts", "api", "sizer_bootstrap.jl")
        cmd = addenv(
            `$(Base.julia_cmd()) --project=$(proj) $(boot)`,
            "PORT" => string(SPAWN_PORT),
            "SIZER_PORT" => string(SPAWN_PORT),
            "SIZER_HOST" => "127.0.0.1",
            "SS_ENABLE_VISUALIZATION" => "false",
            "SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD" => "false",
        )
        println(stderr, "[ludicrous_chat] spawning bootstrap on port $(SPAWN_PORT) ...")
        server_proc = run(pipeline(cmd, stdout = devnull, stderr = devnull), wait = false)
    end

    try
        println(stderr, "[ludicrous_chat] waiting for API at $(BASE) ...")
        wait_bootstrap_ready(BASE) || error("API did not become ready at $(BASE)")

        hdr = ["Content-Type" => "application/json"]
        println(stderr, "[ludicrous_chat] POST /design (large spans — may take several minutes) ...")
        design_body = JSON3.write(payload)
        dr = HTTP.post("$(BASE)/design", hdr, design_body; readtimeout = 900, status_exception = false)
        dr.status in (200, 202) || error("POST /design failed: status=$(dr.status) body=$(String(dr.body)[1:min(end,500)])")

        wait_design_idle(BASE) || error("Design did not finish (timeout)")

        rr = HTTP.get("$(BASE)/result"; readtimeout = 120, status_exception = false)
        design_ok = rr.status == 200
        design_status = "no_result"
        if design_ok
            res = JSON3.read(String(rr.body))
            design_status = String(get(res, :status, get(res, "status", "")))
            design_ok = design_status == "ok"
        else
            design_status = "http_$(rr.status)"
        end
        println(stderr, "[ludicrous_chat] GET /result status=$(design_status) → chat mode=$(design_ok ? "results" : "design")")

        mode = design_ok ? "results" : "design"
        user_msg = """
        This building is intentionally absurd: about 159 ft by 108 ft in plan, 3 stories, \
        with only ONE bay in the 159-ft direction (so ~159 ft slab span between column lines in that direction) \
        and three bays in the other (~36 ft each). It's a thought experiment, not a serious proposal.

        In plain language: what goes wrong structurally with a two-way flat plate at this scale? \
        Use the structural tools (e.g. situation card, diagnose summary) if there is a completed design in cache; \
        otherwise reason qualitatively from the geometry. Keep the tone a little amused but technically grounded.
        """

        chat_payload = Dict{String, Any}(
            "mode" => mode,
            "session_id" => "ludicrous_openai_demo",
            "messages" => [Dict("role" => "user", "content" => strip(user_msg))],
        )
        if mode == "design"
            chat_payload["building_geometry"] = geo
            chat_payload["geometry_summary"] =
                "159x108 ft, 3 stories, 1 bay x 3 bays — ~159 ft single span in X."
        end

        println(stderr, "[ludicrous_chat] POST /chat (OpenAI) mode=$(mode) ...")
        cr = HTTP.post(
            "$(BASE)/chat",
            hdr,
            JSON3.write(chat_payload);
            readtimeout = 600,
            status_exception = false,
        )
        cr.status == 200 || error("POST /chat failed: status=$(cr.status) body=$(String(cr.body)[1:min(end,800)])")

        text = collect_sse_assistant_text(String(cr.body))
        println()
        println("========== ASSISTANT REPLY ==========")
        println(isempty(text) ? "(empty — check SSE parsing or LLM error events)" : text)
        println("=====================================")
    finally
        if server_proc !== nothing
            try
                kill(server_proc)
            catch
            end
        end
    end
end

main()
