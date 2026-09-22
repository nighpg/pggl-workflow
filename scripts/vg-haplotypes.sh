#!/usr/bin/env bash
#
# Builds a sample's personalized pangenome: the subgraph whose haplotypes match
# the sample's k-mers, so the variation the sample does not carry stops
# misleading the mapper (Siren et al., Personalized pangenome references).
#
# --include-reference and --set-reference are not optional here. Sampling keeps
# only the selected haplotypes, and without these the reference paths go with
# the rest -- leaving nothing for `vg surject` to project onto, which is the
# whole basis of this pipeline. With them the reference survives intact, down to
# the subrange fragments of a clipped assembly.
#
# The haplotype information (.hapl) is an input rather than something generated
# here: it costs an r-index plus its own pass over the graph, it is identical
# for every sample, and its format is versioned (vg 1.70 rejects the version 4
# files that ship with some graphs).
#
# Usage: vg-haplotypes.sh <gbz> <hapl> <kff> <ref_sample> <prefix> <threads>
#                         <diploid_sampling>
set -euo pipefail

GBZ=$1
HAPL=$2
KFF=$3
REF_SAMPLE=$4
PREFIX=$5
THREADS=$6
DIPLOID=${7:-true}

OUT="${PREFIX}.personalized.gbz"

ARGS=( -i "$HAPL" -k "$KFF" -g "$OUT" -t "$THREADS" --include-reference )
[ -n "$REF_SAMPLE" ] && ARGS+=( --set-reference "$REF_SAMPLE" )
[ "$DIPLOID" = "true" ] && ARGS+=( --diploid-sampling )

vg haplotypes -v 2 "${ARGS[@]}" "$GBZ"

[ -s "$OUT" ] || { echo "vg-haplotypes.sh: no personalized graph produced" >&2; exit 1; }

# Fail loudly rather than hand the workflow a graph with no surjection target.
if [ -n "$REF_SAMPLE" ]; then
    n=$(vg paths -x "$OUT" -L 2>/dev/null | grep -c "^${REF_SAMPLE}#" || true)
    [ "$n" -gt 0 ] || {
        echo "vg-haplotypes.sh: no ${REF_SAMPLE} paths survived sampling" >&2
        exit 1
    }
    echo "kept ${n} ${REF_SAMPLE} reference paths" >&2
fi
