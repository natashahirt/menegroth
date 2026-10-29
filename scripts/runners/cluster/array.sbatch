#!/bin/bash
# One array element = one task from experiments.jl. Submitted by submit.sh,
# which passes REPO, EXPERIMENT, RUN_DIR and TASK_OFFSET.
#SBATCH --job-name=menegroth
#SBATCH --cpus-per-task=1
#SBATCH --requeue
#SBATCH --output=logs/slurm/%x_%A_%a.out
set -uo pipefail
source "${REPO:?}/scripts/runners/cluster/env.sh"
cd "$REPO"

IDX=$(( SLURM_ARRAY_TASK_ID + ${TASK_OFFSET:-0} ))
ID=$(awk -F'\t' -v i="$IDX" '$1 == i { print $2 }' "$RUN_DIR/manifest_${EXPERIMENT}.tsv")
if [[ -n "$ID" && -f "$RUN_DIR/$EXPERIMENT/$ID.done" ]]; then
    echo "skip $ID: done"   # checked here so finished tasks cost no Julia start-up
    exit 0
fi
if [[ -n "$ID" && -f "$RUN_DIR/$EXPERIMENT/$ID.error" && "${INCLUDE_ERRORED:-0}" != 1 ]]; then
    echo "skip $ID: raised an exception earlier (see $ID.error); INCLUDE_ERRORED=1 to retry"
    exit 0
fi

# --compiled-modules=existing: use the caches from setup_engaging.sh and never
# compile in parallel across tasks. Stale caches load slowly, not wrongly.
julia --project=StructuralStudies --startup-file=no --compiled-modules=existing \
    scripts/runners/cluster/run_task.jl "$EXPERIMENT" "$IDX" "$RUN_DIR"
