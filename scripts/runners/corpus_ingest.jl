#!/usr/bin/env julia

"""
    corpus_ingest.jl

Julia entrypoint for the corpus ingestion stage.

Delegates to `scripts/corpus/ingest.py`, which reads
`corpus/manifests/sources.yml` and copies / normalizes source documents
into `corpus/sources/` (PDF) and `corpus/text/` (sibling `.txt`).

Usage:

    # Dry run (no file changes):
    julia scripts/runners/corpus_ingest.jl

    # Apply (actually copy + regenerate stale .txt via convert_pdfs_to_text.py):
    julia scripts/runners/corpus_ingest.jl --apply

    # Subset by manifest id(s):
    julia scripts/runners/corpus_ingest.jl --apply --ids aci-318-11 aisc-360-16

Forward any extra arguments straight through to the Python CLI.
"""

const REPO_ROOT = abspath(joinpath(@__DIR__, "..", ".."))
const PY_SCRIPT = joinpath(REPO_ROOT, "scripts", "corpus", "ingest.py")

function main()
    isfile(PY_SCRIPT) || error("Python ingest script not found: $PY_SCRIPT")
    cmd = Cmd(`python3 $PY_SCRIPT $(ARGS)`; dir = REPO_ROOT)
    run(cmd)
end

main()
