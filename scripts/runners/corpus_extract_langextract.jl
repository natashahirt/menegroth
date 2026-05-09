#!/usr/bin/env julia

"""
    corpus_extract_langextract.jl

Julia entrypoint for the corpus extraction stage.

Delegates to `scripts/corpus/extract.py`, which (eventually) runs
`langextract` tasks against `corpus/text/...` and writes
`corpus/extractions/<task>/<mirrored path>.jsonl` plus
`corpus/review/<task>/<mirrored path>.html` visualizations.

Until task configs exist under `scripts/corpus/tasks/*.yml` and the
`langextract` package is wired into `extract.py`, this runner only
performs a dry-run plumbing check.

Usage:

    # Dry run (no LLM calls):
    julia scripts/runners/corpus_extract_langextract.jl

    # Apply (requires LANGEXTRACT_API_KEY when extraction is wired up):
    julia scripts/runners/corpus_extract_langextract.jl --apply

    # Subset by role / task:
    julia scripts/runners/corpus_extract_langextract.jl --role codes --task strength_reduction_factors
"""

const REPO_ROOT = abspath(joinpath(@__DIR__, "..", ".."))
const PY_SCRIPT = joinpath(REPO_ROOT, "scripts", "corpus", "extract.py")

function main()
    isfile(PY_SCRIPT) || error("Python extract script not found: $PY_SCRIPT")
    cmd = Cmd(`python3 $PY_SCRIPT $(ARGS)`; dir = REPO_ROOT)
    run(cmd)
end

main()
