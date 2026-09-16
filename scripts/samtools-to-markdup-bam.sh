#!/usr/bin/env bash
#
# Produces a coordinate-sorted, duplicate-marked BAM plus markdup statistics
# from the per-lane sorted BAMs produced by vg giraffe (+ postprocess).
#
# Usage:
#   samtools-to-markdup-bam.sh <prefix> <threads> [--bams <bam...>]
set -euo pipefail

PREFIX=$1
THREADS=$2
shift 2

case "${1:-}" in
  --bams)
    shift
    [ "$#" -gt 0 ] || { echo "ERROR: --bams requires at least one BAM" >&2; exit 2; }
    samtools merge -@ "$THREADS" -o in.bam "$@"
    ;;
  *)
    echo "ERROR: no per-lane BAMs supplied (--bams <bam...>)" >&2
    exit 2
    ;;
esac

samtools index -@ "$THREADS" in.bam
samtools markdup -@ "$THREADS" -T . -f "${PREFIX}.markdup.metrics" in.bam marked.bam
mv marked.bam "${PREFIX}.bam"
samtools index -@ "$THREADS" "${PREFIX}.bam"