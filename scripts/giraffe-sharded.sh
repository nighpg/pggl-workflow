#!/usr/bin/env bash
#
# Parallel vg giraffe for one lane. Shards the FASTQ pair into `chunks`
# read-pair blocks (a block never splits a read pair), maps each block with
# vg-giraffe.sh (vg giraffe -> GAM -> vg surject -> BAM) in parallel, then
# concatenates the per-block BAMs with samtools cat. Each read therefore gets
# the identical alignment to a single-process run; only the record order of
# the lane BAM changes (downstream sort/fixmate/markdup make it deterministic).
# Per-block threads = ceil(threads / chunks), keeping total CPU ~constant
# while dividing vg's peak per-process memory by `chunks`.
#
# With <call_sv> set the lane GAM is kept whether or not <emit_gam> asked for
# it, because the SV track packs it later. Nothing is packed here: `vg pack -i`,
# the obvious way to sum per-block coverage, segfaults in collect_coverage on a
# whole-genome graph (measured on JaSaPaGe, with one thread as well as 32), so
# the packing is done once, at the end, over every lane's GAM concatenated --
# which is the thing summing packs was only ever an optimisation for. GAM is a
# concatenable stream, so `cat` is all a lane needs.
#
# Usage: giraffe-sharded.sh <gbz> <dist> <min> <zipcodes> <ref_paths>
#              <threads> <read_group> <sample> <fq1> <fq2> <lane> <emit_gam>
#              <chunks> [call_sv]
set -euo pipefail

GBZ=$1
DIST=$2
MIN=$3
ZIP=$4
REF_PATHS=$5
THREADS=$6
RG=$7
SM=$8
FQ1=$9
FQ2=${10}
LANE=${11}
EMIT_GAM=${12}
CHUNKS=${13:-1}
CALL_SV=${14:-false}

# Byte-oriented (no multibyte locale) so mawk/wc stay on the fast path.
export LC_ALL=C

RECS=$(( $(wc -l < "$FQ1") / 4 ))
if [ "$RECS" -lt 1 ]; then
    echo "giraffe-sharded.sh: no reads in $FQ1" >&2
    exit 1
fi
if [ "$CHUNKS" -le 0 ]; then CHUNKS=1; fi
if [ "$CHUNKS" -gt "$RECS" ]; then CHUNKS="$RECS"; fi
PER=$(( (RECS + CHUNKS - 1) / CHUNKS ))
CTHREADS=$(( (THREADS + CHUNKS - 1) / CHUNKS ))
[ "$CTHREADS" -lt 1 ] && CTHREADS=1

rm -rf shards
mkdir -p shards

awk -v per="$PER" -v out="shards" '
NR % 4 == 1 { r = ((NR - 1) / 4) + 1; ch = int((r - 1) / per) + 1 }
{ print > (out "/c" ch ".fq1") }
' "$FQ1" &
AWK1=$!
awk -v per="$PER" -v out="shards" '
NR % 4 == 1 { r = ((NR - 1) / 4) + 1; ch = int((r - 1) / per) + 1 }
{ print > (out "/c" ch ".fq2") }
' "$FQ2" &
AWK2=$!
A=0
wait "$AWK1" || A=1
wait "$AWK2" || A=1
if [ "$A" -ne 0 ]; then
    echo "giraffe-sharded.sh: FASTQ sharding failed" >&2
    exit 1
fi

# A block writes its GAM when the caller wants one and when the SV track does.
KEEP_GAM=$EMIT_GAM
[ "$CALL_SV" = "true" ] && KEEP_GAM=true

pids=()
for i in $(seq 1 "$CHUNKS"); do
    (
        bash vg-giraffe.sh "$GBZ" "$DIST" "$MIN" "$ZIP" "$REF_PATHS" \
            "$CTHREADS" "$RG" "$SM" "shards/c${i}.fq1" "shards/c${i}.fq2" \
            "${LANE}.c${i}" "$KEEP_GAM"
    ) &
    pids+=("$!")
done

status=0
for pid in "${pids[@]}"; do
    wait "$pid" || status=1
done
if [ "$status" -ne 0 ]; then
    echo "giraffe-sharded.sh: one or more blocks failed" >&2
    exit 1
fi

bams=()
for i in $(seq 1 "$CHUNKS"); do
    bams+=("${LANE}.c${i}.bam")
done
samtools cat -o "${LANE}.bam" "${bams[@]}"

if [ "$KEEP_GAM" = "true" ]; then
    if [ "$CHUNKS" -eq 1 ]; then
        mv "${LANE}.c1.gam" "${LANE}.gam"
    else
        rm -f "${LANE}.gam"
        for i in $(seq 1 "$CHUNKS"); do
            cat "${LANE}.c${i}.gam" >> "${LANE}.gam"
        done
    fi
    [ -s "${LANE}.gam" ] || { echo "giraffe-sharded.sh: no GAM produced for ${LANE}" >&2; exit 1; }
fi

for i in $(seq 1 "$CHUNKS"); do
    rm -f "${LANE}.c${i}.bam" "${LANE}.c${i}.gam"
done
rm -rf shards

[ -s "${LANE}.bam" ] || { echo "giraffe-sharded.sh: no BAM produced for ${LANE}" >&2; exit 1; }