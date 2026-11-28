#!/bin/bash
# Submit one experiment as Slurm array(s), then a follow-up job that runs
# when they all end: it merges results and, if tasks are unfinished (12 h
# limit, preemption, node failure), resubmits just those and chains another
# follow-up, up to MAX_ROUNDS rounds (followup.sh).
#
#   bash scripts/runners/cluster/submit.sh EXPERIMENT [RUN_TAG]
#   bash scripts/runners/cluster/submit.sh --list            # task counts
#
# RUN_TAG names the results folder ($RESULTS_ROOT/$RUN_TAG); default: today.
# Submitting again with the same tag reruns only tasks without a .done file;
# ONLY_MISSING=1 submits just the indices in <experiment>_missing.tsv
# (written by the merge), and INCLUDE_ERRORED=1 adds tasks that raised
# exceptions. Partition, time, memory and concurrency come from env.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO"

if [[ "${1:-}" == "--list" ]]; then
    julia --startup-file=no scripts/runners/cluster/make_manifest.jl --list
    exit 0
fi
EXPERIMENT="${1:?usage: submit.sh EXPERIMENT [RUN_TAG]}"
RUN_TAG="${2:-$(date +%Y%m%d)}"
RUN_DIR="$RESULTS_ROOT/$RUN_TAG"
ROUND="${ROUND:-1}"
mkdir -p "$RUN_DIR" logs/slurm

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "warning: uncommitted changes; results record git_dirty=true" >&2
fi

N=$(julia --startup-file=no scripts/runners/cluster/make_manifest.jl "$EXPERIMENT" "$RUN_DIR" | tail -1)

submit_array() {   # $1 = --array spec, $2 = TASK_OFFSET
    sbatch --parsable \
        --partition="$PARTITION" --time="$TIME_LIMIT" --mem="$MEM" \
        --array="$1" \
        --job-name="mg_${EXPERIMENT}" \
        --export=ALL,REPO="$REPO",EXPERIMENT="$EXPERIMENT",RUN_DIR="$RUN_DIR",TASK_OFFSET="$2",ROUND="$ROUND",INCLUDE_ERRORED="${INCLUDE_ERRORED:-0}" \
        scripts/runners/cluster/array.sbatch
}

JOBS=()
LIST=""
if [[ "${ONLY_MISSING:-0}" == 1 && -f "$RUN_DIR/${EXPERIMENT}_missing.tsv" ]]; then
    want='$3 == "unfinished"'
    [[ "${INCLUDE_ERRORED:-0}" == 1 ]] && want='1'
    LIST=$(awk -F'\t' "$want { print \$1 }" "$RUN_DIR/${EXPERIMENT}_missing.tsv" | paste -sd, -)
    if [[ -z "$LIST" ]]; then
        echo "$EXPERIMENT: nothing to resubmit"
        exit 0
    fi
    MAX_IDX=$(tr ',' '\n' <<< "$LIST" | sort -n | tail -1)
    if (( MAX_IDX >= MAX_ARRAY )); then
        LIST=""   # indices beyond MaxArraySize: resubmit everything; done tasks exit at once
    fi
fi

if [[ -n "$LIST" ]]; then
    jid=$(submit_array "${LIST}%${MAX_CONCURRENT}" 0)
    echo "$EXPERIMENT round $ROUND: array $jid for tasks $LIST → $RUN_DIR"
    JOBS+=("$jid")
else
    echo "$EXPERIMENT round $ROUND: $N tasks → $RUN_DIR"
    for (( off = 0; off < N; off += MAX_ARRAY )); do
        n=$(( N - off < MAX_ARRAY ? N - off : MAX_ARRAY ))
        jid=$(submit_array "1-${n}%${MAX_CONCURRENT}" "$off")
        echo "  array $jid: tasks $(( off + 1 ))–$(( off + n ))"
        JOBS+=("$jid")
    done
fi

DEPS=$(IFS=:; echo "${JOBS[*]}")
fid=$(sbatch --parsable --partition="$PARTITION" --time=1:00:00 --mem=16G \
    --dependency="afterany:$DEPS" --job-name="mg_followup_${EXPERIMENT}" \
    --output="logs/slurm/%x_%j.out" \
    --export=ALL,REPO="$REPO",EXPERIMENT="$EXPERIMENT",RUN_TAG="$RUN_TAG",ROUND="$ROUND" \
    scripts/runners/cluster/followup.sh)
echo "  follow-up $fid (merge, then resubmit unfinished; round $ROUND of $MAX_ROUNDS) after: $DEPS"
