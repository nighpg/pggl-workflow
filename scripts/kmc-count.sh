#!/usr/bin/env bash
#
# Counts the sample's k-mers into a KFF file, the input `vg haplotypes` scores
# candidate haplotypes against.
#
# k must match the .hapl the sampling step uses (vg haplotypes builds its
# minimizer index at k=29 by default); a mismatch is not detected, it just
# scores badly. Read groups are irrelevant here -- every lane is counted as one
# sample -- so the FASTQs are simply listed for KMC's @file form.
#
# KMC cannot read CRAM (it has its own BAM reader, not htslib, and reports
# "wrong EOF marker of BAM file"), which is why this takes FASTQ.
#
# Usage: kmc-count.sh <prefix> <k> <threads> <max_mem_gb> <min_count> <fastq...>
set -euo pipefail

PREFIX=$1
K=$2
THREADS=$3
MAX_MEM=$4
MIN_COUNT=$5
shift 5

[ "$#" -ge 1 ] || { echo "kmc-count.sh: no FASTQ given" >&2; exit 2; }

printf '%s\n' "$@" > kmc_files.txt
# KMC spills a lot; keep it inside the job directory so the runner's tmpdir
# policy applies to it too.
mkdir -p kmc_tmp

kmc -k"$K" -m"$MAX_MEM" -okff -t"$THREADS" -hp -ci"$MIN_COUNT" \
    @kmc_files.txt "$PREFIX" kmc_tmp

rm -rf kmc_tmp
[ -s "${PREFIX}.kff" ] || { echo "kmc-count.sh: no KFF produced" >&2; exit 1; }
echo "counted $# FASTQ files into ${PREFIX}.kff ($(stat -c %s "${PREFIX}.kff") bytes)" >&2
