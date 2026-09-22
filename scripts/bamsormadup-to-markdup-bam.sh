#!/usr/bin/env bash
#
# Produces a coordinate-sorted, duplicate-marked BAM plus markdup statistics
# from the name-collated per-lane BAMs produced by samtools-prep-lane.sh.
#
# biobambam2's bamsormadup does mate fixing, coordinate sorting and duplicate
# marking in a single streaming pass, replacing the per-lane sort -n / fixmate /
# sort and the final samtools markdup that this step grew out of.
#
# The per-lane BAMs are already name-collated and read names are unique across
# lanes, so concatenating them with samtools cat keeps the stream name-collated
# and lets bamsormadup mark duplicates across all lanes together -- but only if
# the concatenated header declares every lane's read group, which samtools cat
# does not do by itself. See the header merge below.
#
# bamsormadup must be on PATH (biobambam2). It is not part of the samtools
# container; in the SIF it is installed via sif-stage (see sif-build-gpu.def).
#
# Usage:
#   bamsormadup-to-markdup-bam.sh <prefix> <threads> [--level N] [--bams <bam...>]
set -euo pipefail

PREFIX=$1
THREADS=$2
shift 2

LEVEL=6
case "${1:-}" in
  --level)
    LEVEL=$2
    shift 2
    ;;
esac

case "${1:-}" in
  --bams)
    shift
    [ "$#" -gt 0 ] || { echo "ERROR: --bams requires at least one BAM" >&2; exit 2; }
    if [ "$#" -eq 1 ]; then
      IN=$1
    else
      # samtools cat copies the header of its first input and nothing else, so
      # every other lane's @RG line would be dropped while its reads keep their
      # RG tags. That is an invalid BAM, and worse than cosmetic: bamsormadup
      # files reads whose read group is undeclared under "Unknown Library", and
      # it only ever looks for duplicates *within* a library -- so a duplicate
      # pair split between lane 1 and any other lane goes unmarked. Build a
      # header that declares all of them. @RG before @PG keeps the conventional
      # grouping; samtools does not insist, but header readers are happier.
      {
        samtools view -H "$1" | grep -E '^@HD|^@SQ'
        for b in "$@"; do samtools view -H "$b" | grep '^@RG' || true; done | awk '!seen[$0]++'
        samtools view -H "$1" | grep -vE '^@HD|^@SQ|^@RG' || true
      } > merged_header.sam
      echo "merged header declares $(grep -c '^@RG' merged_header.sam) read group(s) from $# lane BAMs" >&2
      samtools cat -@ "$THREADS" -h merged_header.sam -o in.namecol.bam "$@"
      IN=in.namecol.bam
    fi
    ;;
  *)
    echo "ERROR: no per-lane BAMs supplied (--bams <bam...>)" >&2
    exit 2
    ;;
esac

TMPDIR_LOCAL="$(pwd)/bamsormadup_tmp"
mkdir -p "$TMPDIR_LOCAL"

bamsormadup \
  threads="$THREADS" \
  level="$LEVEL" \
  inputformat=bam \
  outputformat=bam \
  SO=coordinate \
  tmpfile="${TMPDIR_LOCAL}/" \
  M="${PREFIX}.markdup.metrics" \
  < "$IN" > marked.bam

mv marked.bam "${PREFIX}.bam"
samtools index -@ "$THREADS" "${PREFIX}.bam"

rm -rf "$TMPDIR_LOCAL"
