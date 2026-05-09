#!/usr/bin/env julia

"""
    corpus_promote.jl

Julia entrypoint for the corpus promotion stage (STUB).

Reads `corpus/manifests/promotions.yml` (when it exists) and applies
*reviewer-accepted* extractions to the Julia source — for example, by
generating constants tables, updating tests, or inserting cited docs
snippets. This is the **safety-critical gate** for the pipeline.

Per the workspace's safety rule (`.cursor/rules/code-accuracy.mdc`), an
extraction may only be promoted when it carries:

  * a grounded source span (LangExtract `char_interval` is non-null),
  * an explicit edition / code-family identifier (e.g. "ACI 318-19"),
  * an explicit clause citation (e.g. "ACI 318-19 §22.4.2.1"),
  * a reviewer decision recorded in `corpus/manifests/promotions.yml`,
  * unit consistency at every interface boundary.

This stub validates the manifest existence and prints the planned
actions; actually applying changes is intentionally a TODO until the
extraction taxonomy stabilizes.

Usage:

    julia scripts/runners/corpus_promote.jl
    julia scripts/runners/corpus_promote.jl --apply
"""

const REPO_ROOT = abspath(joinpath(@__DIR__, "..", ".."))
const PROMOTIONS_PATH = joinpath(REPO_ROOT, "corpus", "manifests", "promotions.yml")

function main()
    apply = "--apply" in ARGS

    if !isfile(PROMOTIONS_PATH)
        println("No promotions manifest yet: $(relpath(PROMOTIONS_PATH, REPO_ROOT))")
        println("Create it after reviewing extractions in corpus/extractions/.")
        return 0
    end

    println("Found promotions manifest: $(relpath(PROMOTIONS_PATH, REPO_ROOT))")
    println(apply ? "[APPLY]  promotion not yet implemented." :
                    "[DRY RUN] promotion not yet implemented.")
    println("TODO: parse accepted entries and update Julia constants / tests / docs ",
            "with clause citations and unit checks.")
    return 0
end

main()
