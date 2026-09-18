#!/usr/bin/env bash
#
# Derive DeepVariant autosome chunk BEDs from a single autosome interval BED,
# so no per-chunk BED files have to be prepared or listed in the job.
#
# <count> controls the split:
#   0 or 1 : a single chunk covering the whole interval (the historical
#            no-chunks default)
#   N >= 2 : contiguous contigs are grouped into at most N chunks whose sizes
#            (in bp) are as balanced as possible (a contig is never split);
#            if N >= the number of contigs, one chunk per contig.
# Chunks are emitted in reference-contig order (natural/version sort) with
# zero-padded names so that the File[] glob order and bcftools concat see them
# in genomic order.
#
# If explicit chunk BEDs are passed after <count>, those are used verbatim
# (order preserved) instead of deriving chunks; this keeps existing jobs that
# supply `autosome_chunks` working.
#
# Usage: make-autosome-chunks.sh <autosome.bed> <count|-> [<chunk.bed> ...]
set -euo pipefail

BED=$1
COUNT=${2:--}
shift 2 || true

# Explicit user chunks: copy in order, numbered so glob order == given order.
if [ "$#" -gt 0 ]; then
    i=0
    for f in "$@"; do
        i=$((i + 1))
        cp "$f" "$(printf 'chunk_%04d.bed' "$i")"
    done
    exit 0
fi

[ -s "$BED" ] || { echo "make-autosome-chunks.sh: no such BED: $BED" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Genomic order: natural contig sort, then position.
sort -k1,1V -k2,2n "$BED" > "$tmp/ordered.bed"

mapfile -t CONTIGS < <(cut -f1 "$tmp/ordered.bed" | uniq)
n=${#CONTIGS[@]}
[ "$n" -gt 0 ] || { echo "make-autosome-chunks.sh: empty BED: $BED" >&2; exit 1; }

declare -A BP
while IFS=$'\t' read -r c s e; do
    BP["$c"]=$(( ${BP["$c"]:-0} + (e - s) ))
done < "$tmp/ordered.bed"

declare -A GRP
if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 2 ]; then
    # No/invalid/1-count: one chunk covering the whole interval.
    cp "$tmp/ordered.bed" chunk_0001.bed
    exit 0
fi

if [ "$COUNT" -lt "$n" ]; then
    total=0
    for c in "${CONTIGS[@]}"; do total=$(( total + BP["$c"] )); done
    target=$(( (total + COUNT - 1) / COUNT ))
    g=0
    acc=0
    for c in "${CONTIGS[@]}"; do
        # Start a new group before c if it would overflow the target and we
        # have not used up the group budget yet.
        if [ "$g" -lt "$((COUNT - 1))" ] && [ "$acc" -gt 0 ] \
           && [ "$((acc + BP["$c"]))" -gt "$target" ]; then
            g=$((g + 1))
            acc=0
        fi
        GRP["$c"]=$g
        acc=$(( acc + BP["$c"] ))
    done
else
    # count >= number of contigs: one chunk per contig.
    g=-1
    for c in "${CONTIGS[@]}"; do
        g=$((g + 1))
        GRP["$c"]=$g
    done
fi

for c in "${CONTIGS[@]}"; do
    printf '%s\t%s\n' "$c" "${GRP[$c]}"
done > "$tmp/map.tsv"

awk -F'\t' -v OFS='\t' '
    NR == FNR { grp[$1] = $2; next }
    { print > (sprintf("chunk_%04d.bed", grp[$1] + 1)) }
' "$tmp/map.tsv" "$tmp/ordered.bed"

ls chunk_*.bed >/dev/null 2>&1 || { echo "make-autosome-chunks.sh: no chunks produced" >&2; exit 1; }
