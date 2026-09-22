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
# and lets bamsormadup mark duplicates across all lanes together.
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
      samtools cat -@ "$THREADS" -o in.namecol.bam "$@"
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
