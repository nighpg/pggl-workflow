#!/usr/bin/env bash
#
# Keeps the graph SV calls this pipeline genotypes reliably: simple deletions and
# insertions outside repeats. vg call genotypes only alleles already in the graph,
# so every record is a known (panel) allele; what the filter removes are the calls
# short reads cannot settle.
#
#   1. multi-allelic records split (bcftools norm -m -any); only records whose
#      allele the sample carries are kept (GT="alt")
#   2. FILTER PASS (or .) and QUAL >= min_qual
#   3. |ALT - REF| >= min_length
#   4. simple DEL/INS: the shorter of REF and ALT is at most max_short_allele bp
#      (drops inversions and complex substitutions, whose two alleles are both long)
#   5. no overlap of the record's REF span with exclude_bed (bcftools -T ^bed
#      --targets-overlap 1), e.g. GIAB GRCh38_AllTandemRepeatsandHomopolymers_slop5:
#      VNTR and STR lengths cannot be told apart from short-read k-mers, and on
#      HG002 these regions held 84% of the SVs every short-read method missed
#
# On HG002 (GIAB v5.0q, truvari refine) outside tandem repeats and homopolymers
# the unfiltered calls already reach precision 0.975-0.986, recall 0.895-0.906;
# steps 2 and 4 remove the few low-precision classes (QUAL < 30: 0.29-0.88,
# complex: 0.77-0.92). The region holds about 16% of a genome's SVs, so the output
# is precise but deliberately partial.
#
# Usage: filter-sv-nonrep.sh <in.vcf.gz> <out.vcf.gz> <exclude.bed[.gz]> <min_qual>
#                            <max_short_allele> <min_length>
set -euo pipefail

IN=$1
OUT=$2
BED=$3
MIN_QUAL=$4
MAX_SHORT=$5
MIN_LEN=$6

EXPR="GT=\"alt\" && QUAL>=${MIN_QUAL} && abs(strlen(ALT)-strlen(REF))>=${MIN_LEN}"
EXPR+=" && (strlen(REF)<=${MAX_SHORT} || strlen(ALT)<=${MAX_SHORT})"

bcftools norm -m -any "$IN" \
  | bcftools view -f PASS,. -i "$EXPR" \
  | bcftools view -T ^"$BED" --targets-overlap 1 \
  | bcftools annotate --header-line "##pggl_sv_filter=simple DEL/INS (shorter allele <= ${MAX_SHORT} bp, |ALT-REF| >= ${MIN_LEN}), QUAL >= ${MIN_QUAL}, PASS, carried by the sample, no overlap with $(basename "$BED")" \
      -O z -o "$OUT"
bcftools index -t -f "$OUT"
echo "filter-sv-nonrep.sh: $(basename "$IN"): $(bcftools view -H "$IN" | wc -l) records in, $(bcftools view -H "$OUT" | wc -l) kept" >&2
