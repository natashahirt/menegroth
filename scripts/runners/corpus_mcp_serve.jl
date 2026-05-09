#!/usr/bin/env julia

"""
    corpus_mcp_serve.jl

Julia entrypoint for the corpus MCP server.

Cursor will normally launch the server itself based on the user-level MCP
config (see `AGENTS.md` and `corpus/README.md`). This runner exists for
local diagnostic use:

    # Self-test (loads manifest, exits non-zero if no sources):
    julia scripts/runners/corpus_mcp_serve.jl --self-test

    # Run the server over stdio (for piping into a custom MCP client):
    julia scripts/runners/corpus_mcp_serve.jl

All flags are forwarded directly to `scripts/corpus/mcp_server.py`.
"""

const REPO_ROOT = abspath(joinpath(@__DIR__, "..", ".."))
const PY_SCRIPT = joinpath(REPO_ROOT, "scripts", "corpus", "mcp_server.py")

function main()
    isfile(PY_SCRIPT) || error("MCP server script not found: $PY_SCRIPT")
    cmd = Cmd(`python3 $PY_SCRIPT $(ARGS)`; dir = REPO_ROOT)
    run(cmd)
end

main()
