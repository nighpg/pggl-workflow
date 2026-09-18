#!/usr/bin/env bash
#
# Prepares one lane of vg giraffe BAM output for biobambam2 bamsormadup, which
# performs mate fixing, coordinate sorting and duplicate marking in one pass:
#
#   1. strip the graph reference prefix (PanSN <sample>#<haplotype>#) from @SQ
#   2. apply the full @RG string with samtools addreplacerg (overwrite_all)
#
# The output keeps the input read order (name-collated), which is exactly what
# bamsormadup expects for SO=coordinate; no name-sort / fixmate / sort is done
# here anymore. BAM compression is forced to level=6 because addreplacerg
# otherwise writes uncompressed BAM in this build.
#
# Usage: samtools-prep-lane.sh <in.bam> <lane> <threads> <rg> <ref_path_prefix>
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

samtools addreplacerg -@ "$THREADS" -w -m overwrite_all -r "$RG" \
  -O BAM,level=6 rehead.bam > "${LANE}.namecol.bam"

rm -f rehead.bam
