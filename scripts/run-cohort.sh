#!/usr/bin/env bash
#
# Run scripts/run-cram-personalized.sh on many samples, a few at a time.
#
# The samples are dealt out to K chains (sample i goes to chain i mod K). In a
# chain, a sample's first job (prepare) starts once the previous sample's
# sampling job has ended, so the next sample decodes its CRAM and builds its
# graph while the previous one is mapped and called. At most about two samples of
# a chain are on disk at a time (a 35x sample peaks at ~600 GB). Everything is
# submitted at once and this script returns immediately.
#
# With --on-fail stop, a sample whose sampling job failed also stops the rest of
# its chain (afterok); by default the chain goes on (afterany) and the failed
# sample is run again later with run-cram-personalized.sh --from.
#
# Usage:
#   scripts/run-cohort.sh --list SAMPLES.tsv --workdir-root DIR [-k N] \
#       [--on-fail continue|stop] [--dry-run] -- RUN-CRAM-PERSONALIZED-OPTIONS
#
#   --list FILE          one sample per line, tab-separated: PREFIX, CRAM, CRAM
#                        reference FASTA ('#' starts a comment)
#   --workdir-root DIR   sample PREFIX is run in DIR/PREFIX
#   -k N                 samples in flight at once (chains; default 1)
#   --on-fail MODE       continue (default) or stop
#   --dry-run            print the commands, submit nothing
#   --cancel             cancel every queued or running job of the cohort (the job IDs
#                        are read from the jobs.tsv of each sample; with --dry-run
#                        only lists them). Work that a running job has not finished
#                        is lost: a step that was running starts again from its
#                        beginning when resumed. A sample's finished steps are kept
#   --resume             continue a cohort that stopped, with the same list and the
#                        same options after --: every sample that is not done and
#                        has no job running is resumed where it stopped (see
#                        run-cram-personalized.sh --resume: from the start, the
#                        sampling step, the mapping, or the call, markdup, sv or
#                        DeepVariant job); a sample never submitted is submitted;
#                        one whose jobs are still queued is left alone. The
#                        sampling steps keep to the -k chains. With --dry-run it
#                        only says where each sample would resume. When both markdup (or
#                        DeepVariant) and sv are to be redone, sv waits for the first
#                        to finish, so one --resume is enough
#
# Progress and resources of a cohort already submitted (Slurm's sacct is run once
# for every job of every sample; see scripts/cohort-report.py):
#   scripts/run-cohort.sh --status --workdir-root DIR [--list SAMPLES.tsv]
#   scripts/run-cohort.sh --report cohort.html --workdir-root DIR [--list SAMPLES.tsv]
#   --status             a table: one row per sample with its state (DONE, RUNNING,
#                        PENDING, FAILED, not submitted), the step that is running
#                        or failed with its Slurm job ID, the state of each step,
#                        the wall time and the CPU hours; a failed run-prepare is
#                        non-fatal if call and every other recorded step succeeded
#   --jobs               every job of every sample with its Slurm job ID, state,
#                        partition, node, start, elapsed time, CPUs, CPU hours
#                        and peak memory (an array's tasks are 12345_1, 12345_2, ...)
#   --report FILE        a one-page HTML report: the same table, the resources of
#                        each step (time, CPU efficiency, peak memory, GPU hours),
#                        a timeline of all the jobs and the failed jobs with their
#                        log directories
# Without --list the samples are the sub-directories of DIR that have a jobs.tsv.
#
# Cores and memory of each job for a given node (scripts/suggest-resources.py):
#   scripts/run-cohort.sh --suggest --node-cpus 128 --node-mem 1000 [--gpu-node-gpus 4 --gpus 4]
# prints a table and the options to give after -- below. Each job has a range of
# cores and memory it is worth running in; the node is divided among the jobs of a
# kind and the result kept inside that range. The ranges are provisional.
#
# The options after -- go to every run-cram-personalized.sh call (--data-root,
# --partition, --variant, --gpu-partition, ...); do not give --cram, --cram-ref,
# --prefix, --workdir or --after there. A sample whose DIR/PREFIX already has a
# jobs.tsv is skipped, so a list can be submitted again after fixing a failure.
set -euo pipefail

die() { echo "run-cohort.sh: $*" >&2; exit 1; }
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

[ "${1:-}" != --suggest ] || { shift; exec python3 "$(dirname "${BASH_SOURCE[0]}")/suggest-resources.py" "$@"; }

LIST= ROOT= K=1 ON_FAIL=continue DRY_RUN=0 STATUS=0 JOBS=0 RESUME=0 CANCEL=0 REPORT=
while [ $# -gt 0 ]; do
    case "$1" in
        --list) LIST=$2; shift 2 ;;
        --workdir-root) ROOT=$2; shift 2 ;;
        -k) K=$2; shift 2 ;;
        --on-fail) ON_FAIL=$2; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --status) STATUS=1; shift ;;
        --jobs) JOBS=1; shift ;;
        --resume) RESUME=1; shift ;;
        --cancel) CANCEL=1; shift ;;
        --report) REPORT=$2; shift 2 ;;
        --) shift; break ;;
        -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option $1 (the run-cram-personalized.sh options go after --)" ;;
    esac
done
if [ "$CANCEL" = 1 ]; then
    # every queued or running job of the cohort, from the jobs.tsv files (squeue lists only those)
    [ -n "$ROOT" ] && [ -d "$ROOT" ] || die "--cancel needs --workdir-root"
    names=()
    if [ -n "$LIST" ]; then
        [ -s "$LIST" ] || die "$LIST not found"
        while IFS=$'\t' read -r n _; do case "${n:-}" in ''|'#'*) ;; *) names+=("$n") ;; esac; done < "$LIST"
    else
        for d in "$ROOT"/*/; do [ -e "$d/jobs.tsv" ] && names+=("$(basename "$d")"); done
    fi
    ids=$(for n in ${names[@]+"${names[@]}"}; do cut -f2 "$ROOT/$n/jobs.tsv" "$ROOT/$n/run/jobs.tsv" 2>/dev/null || true; done \
        | { grep -E '^[0-9]+$' || true; } | sort -un | paste -sd, -)
    [ -n "$ids" ] || { echo "no job IDs under $ROOT"; exit 0; }
    command -v squeue >/dev/null || die "squeue not found"
    active=$(squeue -h -j "$ids" -o "%i|%T|%j" 2>/dev/null || true)
    [ -n "$active" ] || { echo "no queued or running jobs of this cohort"; exit 0; }
    echo "$active" | awk -F'|' '{ printf "%-16s %-12s %s\n", $1, $2, $3 }'
    jobs=$(echo "$active" | cut -d'|' -f1 | sed 's/_.*//' | sort -un | paste -sd' ' -)
    if [ "$DRY_RUN" = 1 ]; then
        echo "would cancel: $jobs"
    else
        # shellcheck disable=SC2086
        scancel $jobs
        echo "cancelled: $jobs"
        echo "jobs that were running end shortly (COMPLETING); wait until squeue no longer lists them, then --resume"
    fi
    exit 0
fi
if [ "$STATUS" = 1 ] || [ "$JOBS" = 1 ] || [ -n "$REPORT" ]; then
    [ -n "$ROOT" ] || die "--status, --jobs and --report need --workdir-root"
    [ -z "$LIST" ] || [ -s "$LIST" ] || die "$LIST not found"
    args=(--workdir-root "$ROOT")
    [ -z "$LIST" ] || args+=(--list "$LIST")
    [ "$STATUS" = 0 ] || args+=(--status)
    [ "$JOBS" = 0 ] || args+=(--jobs)
    [ -z "$REPORT" ] || args+=(--html "$REPORT")
    exec python3 "$REPO/scripts/cohort-report.py" "${args[@]}"
fi
[ -s "${LIST:-}" ] && [ -n "$ROOT" ] || die "--list and --workdir-root are required"
case "$K" in ''|*[!0-9]*|0) die "-k takes a positive integer" ;; esac
case "$ON_FAIL" in continue) DEP=afterany ;; stop) DEP=afterok ;; *) die "--on-fail takes continue or stop" ;; esac
for a in "$@"; do
    case "$a" in
        --cram|--cram-ref|--prefix|--workdir|--after|--from|--status|--resume)
            die "$a is set per sample by this script" ;;
    esac
done

# read and check the whole list first, so a typo does not leave half the cohort submitted
prefixes=() crams=() refs=()
while IFS=$'\t' read -r prefix cram ref rest || [ -n "${prefix:-}" ]; do
    case "${prefix:-}" in ''|'#'*) continue ;; esac
    [ -n "${cram:-}" ] && [ -n "${ref:-}" ] || die "$LIST: '$prefix' needs PREFIX, CRAM and reference separated by tabs"
    for p in "${prefixes[@]+"${prefixes[@]}"}"; do [ "$p" != "$prefix" ] || die "$LIST: $prefix is listed twice"; done
    prefixes+=("$prefix"); crams+=("$cram"); refs+=("$ref")
done < "$LIST"
[ "${#prefixes[@]}" -gt 0 ] || die "$LIST has no samples"

# chain_last[c]: the sampling job the next sample of chain c waits for
declare -a chain_last
n=0 nfail=0
for i in "${!prefixes[@]}"; do
    prefix=${prefixes[$i]}; c=$((i % K)); W=$ROOT/$prefix
    if [ "$RESUME" = 0 ] && [ -e "$W/jobs.tsv" ]; then
        echo "skip $prefix: $W/jobs.tsv exists (already submitted; --resume continues the ones that stopped)"
        # a running sample still holds its place in the chain
        id=$(awk -F'\t' '$1 == "sample" { id = $2 } END { print id }' "$W/jobs.tsv")
        [ -z "$id" ] || chain_last[$c]=$id
        continue
    fi
    cmd=("$REPO/scripts/run-cram-personalized.sh" --cram "${crams[$i]}" --cram-ref "${refs[$i]}"
         --prefix "$prefix" --workdir "$W" "$@")
    [ -z "${chain_last[$c]:-}" ] || cmd+=(--after "$DEP:${chain_last[$c]}")
    if [ "$RESUME" = 1 ]; then
        # each sample says where it stands and resubmits what stopped; one that cannot be resumed does not stop the rest
        cmd+=(--resume); [ "$DRY_RUN" = 0 ] || cmd+=(--dry-run)
        if [ ! -s "$W/jobs.tsv" ]; then
            [ "$DRY_RUN" = 1 ] && echo "$prefix: never submitted: would be submitted as a new sample" \
                || echo "$prefix: never submitted: submitting it as a new sample"
        fi
        "${cmd[@]}" || { echo "$prefix: not resumed (see above)"; nfail=$((nfail + 1)); continue; }
        after=$(awk -F'\t' '$1 == "sample" { id = $2 } END { print id }' "$W/jobs.tsv" 2>/dev/null || true)
        # a new sampling job holds its place in the chain; a sample that is running or done keeps the one it had
        [ "$DRY_RUN" = 1 ] || [ -z "$after" ] || chain_last[$c]=$after
        continue
    fi
    if [ "$DRY_RUN" = 1 ]; then
        echo "chain $((c + 1)): ${cmd[*]}"
        chain_last[$c]=DRYRUN
        continue
    fi
    echo "chain $((c + 1)): $prefix${chain_last[$c]:+ (after sample job ${chain_last[$c]})}"
    "${cmd[@]}" || die "$prefix: run-cram-personalized.sh failed; nothing after it in the list was submitted"
    chain_last[$c]=$(awk -F'\t' '$1 == "sample" { id = $2 } END { print id }' "$W/jobs.tsv")
    [ -n "${chain_last[$c]}" ] || die "$prefix: no sample job in $W/jobs.tsv"
    n=$((n + 1))
done
if [ "$RESUME" = 1 ]; then
    [ "$DRY_RUN" = 1 ] || echo "resumed; $nfail sample(s) could not be resumed; status: scripts/run-cohort.sh --status --workdir-root $ROOT"
else
    [ "$DRY_RUN" = 1 ] || echo "submitted $n sample(s) in $K chain(s); status: scripts/run-cram-personalized.sh --status --workdir $ROOT/<prefix>"
fi
