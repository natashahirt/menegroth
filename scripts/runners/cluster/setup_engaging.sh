#!/bin/bash
# One-time setup on ORCD Engaging, and again after every `git pull` that
# changes package code (stale compile caches make jobs slow, not wrong).
#
# Precompiling takes 15–30 min, so run it inside an interactive job rather
# than on the login node:
#
#   salloc -p mit_normal -c 4 --mem=16G -t 2:00:00
#   bash scripts/runners/cluster/setup_engaging.sh
#
# Steps: juliaup + Julia $JULIA_VERSION, git submodule, forward-slash paths,
# instantiate + precompile StructuralStudies, then load the study code once.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO"

if ! command -v juliaup >/dev/null 2>&1; then
    curl -fsSL https://install.julialang.org | sh -s -- --yes --add-to-path=no
fi
juliaup add "$JULIA_VERSION"
juliaup default "$JULIA_VERSION"
julia --version

git submodule update --init --recursive

# Project and manifest files may carry Windows-style path separators
# (docs/agent-setup.md). Only `path = ...` lines are rewritten.
for f in Project.toml Manifest.toml \
         StructuralSizer/{Project,Manifest}.toml \
         StructuralSynthesizer/{Project,Manifest}.toml \
         StructuralStudies/{Project,Manifest}.toml \
         StructuralPlots/{Project,Manifest}.toml; do
    [[ -f "$f" ]] && sed -i '/path *= */s#\\\\#/#g' "$f"
done

mkdir -p "$JULIA_DEPOT_PATH" "$RESULTS_ROOT" logs/slurm
JULIA_PKG_PRECOMPILE_AUTO=1 julia --project=StructuralStudies \
    -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

# Load the study code once so the caches the array jobs use exist.
julia --project=StructuralStudies -e '
    include("StructuralStudies/src/flat_plate_methods/building_scale_analysis.jl")
    println("study code loaded; Gurobi license: ", get(ENV, "GRB_LICENSE_FILE", "none (HiGHS fallback)"))'

echo "Setup done. Depot: $JULIA_DEPOT_PATH  Results: $RESULTS_ROOT"
