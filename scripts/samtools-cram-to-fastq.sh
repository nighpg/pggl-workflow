#!/usr/bin/env bash
#
# Recovers read-pair FASTQ from an aligned CRAM using the linear reference,
# so the reads can be re-mapped onto the pangenome with vg giraffe.
#
# The CRAM is decoded/name-collated with `samtools collate` and the pairs are
# written out with `samtools fastq -T <ref>`. The first @RG header line is
# carried over (fallback: a synthetic <prefix> read group); single-end / orphan
# reads are sent to /dev/null.
#
# When no CRAM is given the tool produces no outputs (nulls downstream).
#
# Usage:
#   samtools-cram-to-fastq.sh <prefix> <threads> <ref.fa>
#   samtools-cram-to-fastq.sh <prefix> <threads> <in.cram> <ref.fa>
set -euo pipefail

PREFIX=$1
THREADS=$2
shift 2

case "${1:-}" in
  *.cram)
    CRAM=$1
    REF=$2
    ;;
  *)
    CRAM=
    REF=${1:-}
    ;;
esac

[ -n "$CRAM" ] || {
  echo "no <cram> given; skipping read recovery (outputs will be empty)" >&2
  exit 0
}

[ -f "$CRAM" ] || { echo "ERROR: CRAM not found: $CRAM" >&2; exit 2; }
[ -f "$REF" ] || { echo "ERROR: reference not found: $REF" >&2; exit 2; }

# first @RG line of the CRAM header, or a synthetic one
RG=$(samtools view -H "$CRAM" 2>/dev/null | awk '/^@RG/{print; exit}')
[ -n "$RG" ] || RG=$(printf '@RG\tID:%s\tPL:ILLUMINA\tSM:%s' "$PREFIX" "$PREFIX")

# decode + pair recovery; orphans/singletons are not represented in FASTQ
samtools collate -u -O -@ "$THREADS" "$CRAM" 2>/dev/null |
  samtools fastq --reference "$REF" -@ "$THREADS" \
    -1 "${PREFIX}.cram2fq.R1.fastq" \
    -2 "${PREFIX}.cram2fq.R2.fastq" \
    -0 /dev/null -s /dev/null

printf '%s\n' "$RG" > "${PREFIX}.cram2fq.rg.txt"

echo "recovered $(grep -c '^@' "${PREFIX}.cram2fq.R1.fastq") read pairs" >&2
echo "read group: $RG" >&2