#!/usr/bin/env bash
#
# Post-processes one lane of vg giraffe BAM output so that it is a proper
# coordinate-sorted BAM on GRCh38 contig names with a complete @RG header:
#
#   1. strip the graph reference prefix (PanSN <sample>#<haplotype>#) from @SQ
#   2. apply the full @RG string with samtools addreplacerg
#   3. name-sort -> fixmate (-m) -> coordinate-sort (markdup-ready)
#
# Usage: samtools-postprocess-lane.sh <in.bam> <lane> <threads> <rg> <ref_path_prefix>
set -euo pipefail

IN_BAM=$1
LANE=$2
THREADS=$3
RG_RAW=$4
REF_PATH_PREFIX=$5

# Interpret literal \t as a real tab; real tabs pass through unchanged.
RG=$(printf '%b' "$RG_RAW")

if [ -n "$REF_PATH_PREFIX" ]; then
  SEDCMD="sed -E 's/^(@SQ\\tSN:)${REF_PATH_PREFIX}/\\1/'"
  samtools reheader -c "$SEDCMD" "$IN_BAM" > rehead.bam
else
  cp "$IN_BAM" rehead.bam
fi

samtools addreplacerg -w -m overwrite_all -r "$RG" rehead.bam > addrg.bam
samtools sort -n -@ "$THREADS" addrg.bam -o name_sorted.bam
samtools fixmate -m name_sorted.bam fixmate.bam
samtools sort -@ "$THREADS" fixmate.bam -o "${LANE}.sorted.bam"