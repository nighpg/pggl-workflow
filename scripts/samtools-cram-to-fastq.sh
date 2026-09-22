#!/usr/bin/env bash
#
# Recovers read-pair FASTQ from aligned reads -- CRAM or BAM -- so they can be
# re-mapped onto the pangenome with vg giraffe.
#
# The input is name-collated with `samtools collate` and the pairs are written
# out with `samtools fastq`. A CRAM is decoded against the linear reference; a
# BAM carries its own sequences, so --reference is not passed for one. The first
# @RG header line is carried over (fallback: a synthetic <prefix> read group);
# single-end / orphan reads are sent to /dev/null.
#
# When no alignment is given the tool produces no outputs (nulls downstream).
# The workflow offers `cram` and `bam` as separate inputs, so giving both is a
# mistake rather than something to resolve silently.
#
# Usage:
#   samtools-cram-to-fastq.sh <prefix> <threads> <ref.fa>
#   samtools-cram-to-fastq.sh <prefix> <threads> <in.cram|in.bam> <ref.fa>
set -euo pipefail

PREFIX=$1
THREADS=$2
shift 2

# Optional inputs simply drop out of the command line, so the argument count
# says which of them was given.
case "$#" in
  1)
    ALN=
    REF=$1
    ;;
  2)
    ALN=$1
    REF=$2
    ;;
  *)
    echo "ERROR: give at most one aligned input (cram or bam), not both" >&2
    exit 2
    ;;
esac

[ -n "$ALN" ] || {
  echo "no aligned input given; skipping read recovery (outputs will be empty)" >&2
  exit 0
}

[ -f "$ALN" ] || { echo "ERROR: aligned input not found: $ALN" >&2; exit 2; }
[ -f "$REF" ] || { echo "ERROR: reference not found: $REF" >&2; exit 2; }

# A CRAM stores its sequences as differences from the reference and has to be
# decoded against it; a BAM does not.
case "$ALN" in
  *.cram) REF_ARGS=( --reference "$REF" ) ;;
  *.bam)  REF_ARGS=() ;;
  *)      echo "ERROR: expected a .cram or .bam input: $ALN" >&2; exit 2 ;;
esac

# first @RG line of the header, or a synthetic one
RG=$(samtools view -H "$ALN" 2>/dev/null | awk '/^@RG/{print; exit}')
[ -n "$RG" ] || RG=$(printf '@RG\tID:%s\tPL:ILLUMINA\tSM:%s' "$PREFIX" "$PREFIX")

# decode + pair recovery; orphans/singletons are not represented in FASTQ
samtools collate -u -O -@ "$THREADS" ${REF_ARGS[@]+"${REF_ARGS[@]}"} "$ALN" 2>/dev/null |
  samtools fastq ${REF_ARGS[@]+"${REF_ARGS[@]}"} -@ "$THREADS" \
    -1 "${PREFIX}.cram2fq.R1.fastq" \
    -2 "${PREFIX}.cram2fq.R2.fastq" \
    -0 /dev/null -s /dev/null

printf '%s\n' "$RG" > "${PREFIX}.cram2fq.rg.txt"

echo "recovered $(grep -c '^@' "${PREFIX}.cram2fq.R1.fastq") read pairs" >&2
echo "read group: $RG" >&2