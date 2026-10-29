#!/bin/bash
# Runs after an experiment's arrays end (submit.sh queues it with
# --dependency=afterany). Merges results, then, if tasks are unfinished
# (time limit, preemption, node failure), submits a new array for just those
# plus another follow-up. Unfinished tasks resume at their next unfinished
# method. Stops when nothing is unfinished or after MAX_ROUNDS submissions.
# Tasks that raised an exception (status "error") are listed, not retried.
#
# Expects REPO, EXPERIMENT, RUN_TAG and ROUND in the environment.
set -uo pipefail
source "${REPO:?}/scripts/runners/cluster/env.sh"
cd "$REPO"
RUN_DIR="$RESULTS_ROOT/$RUN_TAG"

julia --project=StructuralStudies --startup-file=no --compiled-modules=existing \
    scripts/runners/cluster/merge_results.jl "$RUN_DIR" "$EXPERIMENT"

MISSING_FILE="$RUN_DIR/${EXPERIMENT}_missing.tsv"
n_unfinished=$(awk -F'\t' '$3 == "unfinished"' "$MISSING_FILE" | wc -l)
n_error=$(awk -F'\t' '$3 == "error"' "$MISSING_FILE" | wc -l)
echo "$EXPERIMENT round $ROUND: $n_unfinished unfinished, $n_error with errors"

if (( n_unfinished == 0 )); then
    echo "$EXPERIMENT: nothing left to resubmit"
    exit 0
fi
if (( ROUND >= MAX_ROUNDS )); then
    echo "$EXPERIMENT: $n_unfinished tasks still unfinished after $ROUND rounds; stopping." \
         "Resubmit by hand: ONLY_MISSING=1 bash scripts/runners/cluster/submit.sh $EXPERIMENT $RUN_TAG"
    exit 0
fi

ROUND=$(( ROUND + 1 )) ONLY_MISSING=1 bash scripts/runners/cluster/submit.sh "$EXPERIMENT" "$RUN_TAG"
