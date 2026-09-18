#!/usr/bin/env bash
#
# Concatenate the per-chunk autosome gVCFs in the order given and index the
# result with a tabix (.tbi) index, matching the single DeepVariant autosome
# gVCF contract (prefix.autosome.g.vcf.gz + .tbi).
#
# The input gVCFs must be passed in genomic order (see split-autosome-bed.sh,
# which preserves contig order of the input) so that bcftools concat can join
# them without a -R re-sort.
#
# Usage: concat-gvcfs.sh <prefix> <gvcf1> [<gvcf2> ...]
set -euo pipefail

PREFIX=$1
shift
OUT="${PREFIX}.autosome.g.vcf.gz"

if [ "$#" -lt 1 ]; then
    echo "concat-gvcfs.sh: no input gVCFs" >&2
    exit 1
fi

bcftools concat -a -O z -o "$OUT" --no-version "$@"
bcftools index -t "$OUT"

[ -s "$OUT" ] || { echo "concat-gvcfs.sh: no output produced" >&2; exit 1; }