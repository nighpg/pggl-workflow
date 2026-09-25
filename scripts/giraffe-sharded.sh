#!/usr/bin/env bash
#
# Parallel vg giraffe for one lane. Shards the FASTQ pair into `chunks`
# read-pair blocks (a block never splits a read pair), maps each block with
# vg-giraffe.sh (vg giraffe -> GAM -> vg surject -> BAM) in parallel, then
# concatenates the per-block BAMs with samtools cat. Per-block threads =
# ceil(threads / chunks), keeping total CPU ~constant.
#
# Every block uses the lane's one fragment-length estimate (see below), so the
# lane maps as one process does: on an NA18945 lane (7.9M reads) chunks=4 and
# chunks=1 gave identical records. Every block holds the whole index set
# (~77 GB for JaSaPaGe with its vg surject), so memory grows with `chunks`
# rather than being divided by it, and blocks 2..N only start once block 1 has
# loaded and estimated -- more blocks is rarely faster on a small lane.
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

# FASTQs may be gzip-compressed (.fastq.gz). vg giraffe reads those natively,
# but the record count and the sharding below are line-based, so a compressed
# file has to be decompressed on the way in or it is cut as raw bytes.
# Detected by the gzip magic number rather than the file name, since CWL may
# stage the file under any basename.
is_gzip() {
    [ "$(head -c 2 "$1" | od -An -tx1 | tr -d ' \n')" = "1f8b" ]
}
if command -v pigz >/dev/null 2>&1; then GUNZIP=(pigz -dc); else GUNZIP=(gzip -dc); fi
read_fastq() {
    if is_gzip "$1"; then "${GUNZIP[@]}" "$1"; else cat "$1"; fi
}

if [ "$CHUNKS" -le 1 ]; then
    # Single block: map the lane FASTQs in place. No record count is needed to
    # split them, and no sharded copy of the lane is written to disk.
    CHUNKS=1
    has_read=$( { read_fastq "$FQ1" 2>/dev/null || true; } | head -c 1 | wc -c )
    if [ "$has_read" -lt 1 ]; then
        echo "giraffe-sharded.sh: no reads in $FQ1" >&2
        exit 1
    fi
    SHARD1=("$FQ1")
    SHARD2=("$FQ2")
    CTHREADS=$THREADS
else
    RECS=$(( $(read_fastq "$FQ1" | wc -l) / 4 ))
    if [ "$RECS" -lt 1 ]; then
        echo "giraffe-sharded.sh: no reads in $FQ1" >&2
        exit 1
    fi
    if [ "$CHUNKS" -gt "$RECS" ]; then CHUNKS="$RECS"; fi
    PER=$(( (RECS + CHUNKS - 1) / CHUNKS ))
    CTHREADS=$(( (THREADS + CHUNKS - 1) / CHUNKS ))

    rm -rf shards
    mkdir -p shards

    # Shards are written uncompressed; vg giraffe reads either form.
    read_fastq "$FQ1" | awk -v per="$PER" -v out="shards" '
    NR % 4 == 1 { r = ((NR - 1) / 4) + 1; ch = int((r - 1) / per) + 1 }
    { print > (out "/c" ch ".fq1") }
    ' &
    AWK1=$!
    read_fastq "$FQ2" | awk -v per="$PER" -v out="shards" '
    NR % 4 == 1 { r = ((NR - 1) / 4) + 1; ch = int((r - 1) / per) + 1 }
    { print > (out "/c" ch ".fq2") }
    ' &
    AWK2=$!
    A=0
    wait "$AWK1" || A=1
    wait "$AWK2" || A=1
    if [ "$A" -ne 0 ]; then
        echo "giraffe-sharded.sh: FASTQ sharding failed" >&2
        exit 1
    fi

    SHARD1=()
    SHARD2=()
    for i in $(seq 1 "$CHUNKS"); do
        SHARD1+=("shards/c${i}.fq1")
        SHARD2+=("shards/c${i}.fq2")
    done
fi
[ "$CTHREADS" -lt 1 ] && CTHREADS=1

# A block writes its GAM when the caller wants one and when the SV track does.
KEEP_GAM=$EMIT_GAM
[ "$CALL_SV" = "true" ] && KEEP_GAM=true

run_block() {
    local i=$1
    (
        bash vg-giraffe.sh "$GBZ" "$DIST" "$MIN" "$ZIP" "$REF_PATHS" \
            "$CTHREADS" "$RG" "$SM" "${SHARD1[$((i - 1))]}" "${SHARD2[$((i - 1))]}" \
            "${LANE}.c${i}" "$KEEP_GAM"
    ) &
    pids+=("$!")
}

# One fragment-length distribution for the whole lane. giraffe estimates it
# from the first read pairs it maps, so independent blocks would each pair and
# score against their own estimate and the lane would no longer map as one
# process does (measured before this was added: ~0.06% of the variant calls
# moved at chunks=4 on a 3x sample; with it, the records are identical). Block 1 starts on the lane's own first pairs, so its estimate is
# the one a single process makes; the other blocks start once it is known and
# are given it with --fragment-mean/--fragment-stdev. They wait for block 1's
# index load (~1.5 min for JaSaPaGe) instead of loading alongside it.
pids=()
run_block 1
if [ "$CHUNKS" -gt 1 ]; then
    LOG1="${LANE}.c1.giraffe.log"
    # Reads the estimate out of block 1's log; prints nothing (and never fails
    # the script under set -e / pipefail) while the log is missing or has not
    # got there yet.
    frag_estimate() {
        [ -f "$LOG1" ] || return 0
        sed -n 's/.*Using fragment length estimate: \([0-9.eE+-]*\) +\/- \([0-9.eE+-]*\).*/\1 \2/p' "$LOG1" \
            | head -1 || true
    }
    FRAG=
    while kill -0 "${pids[0]}" 2>/dev/null; do
        FRAG=$(frag_estimate)
        [ -n "$FRAG" ] && break
        sleep 2
    done
    [ -n "$FRAG" ] || FRAG=$(frag_estimate)
    if [ -n "$FRAG" ]; then
        read -r FMEAN FSTDEV <<< "$FRAG"
        echo "giraffe-sharded.sh: ${LANE}: fragment length ${FMEAN} +/- ${FSTDEV} from block 1, used for blocks 2-${CHUNKS}" >&2
        export GIRAFFE_EXTRA_ARGS="--fragment-mean $FMEAN --fragment-stdev $FSTDEV"
    else
        echo "giraffe-sharded.sh: ${LANE}: block 1 gave no fragment-length estimate; blocks 2-${CHUNKS} estimate their own" >&2
    fi
    for i in $(seq 2 "$CHUNKS"); do
        run_block "$i"
    done
    unset GIRAFFE_EXTRA_ARGS
fi

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