#!/usr/bin/env bash
#
# Split an autosome BED into one BED file per contig (chromosome-level
# DeepVariant chunks). Contig order is preserved from the input (order of
# first appearance), which is the order bcftools concat needs later.
#
# Usage: split-autosome-bed.sh <input.bed> <outdir>
#
# Writes <outdir>/<contig>.bed for each contig and prints the list of produced
# BED files (one per line, in genomic order) to stdout; use that list as the
# workflow `autosome_chunks` input, e.g. with cwltool --autosome-chunks:
#   --autosome-chunks $(< <outdir>/.chunk_order)
set -euo pipefail

BED=$1
OUTDIR=${2:-.}

if [ ! -s "$BED" ]; then
    echo "split-autosome-bed.sh: no such BED: $BED" >&2
    exit 1
fi

mkdir -p "$OUTDIR"
rm -f "$OUTDIR/.chunk_order"

awk -v out="$OUTDIR" '
{
    if (!seen[$1]++) {
        cnt++;
        order[cnt] = $1;
    }
    print > (out "/" $1 ".bed");
}
END {
    for (i = 1; i <= cnt; i++) {
        print order[i] ".bed" > (out "/.chunk_order");
    }
}' "$BED"

printf 'split-autosome-bed.sh: %d chunks -> %s\n' "$(wc -l < "$OUTDIR/.chunk_order")" "$OUTDIR" >&2
cat "$OUTDIR/.chunk_order"