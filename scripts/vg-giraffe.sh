#!/usr/bin/env bash
#
# One lane of vg giraffe: emits GAM to the workdir (lane.gam, kept when emit_gam
# is set, and also when the SV track needs it) and a surjected BAM on the
# reference paths (lane.bam).
#
# The BAM written here is record-identical to `vg giraffe --output-format BAM`
# (verified for vg 1.70): surfaced reads are surjected onto the reference paths
# listed in the --ref-paths file. The @RG/@SM fields are stamped with -R/-N,
# matching the previous direct-BAM behaviour.
#
# Usage: vg-giraffe.sh <gbz> <dist> <min> <zipcodes> <ref_paths> <threads> \
#                      <read_group> <sample> <fq1> <fq2> <lane> <emit_gam>
set -euo pipefail

GBZ=$1
DIST=$2
MIN=$3
ZIP=$4
REFPATHS=$5
THREADS=$6
RG=${7:-}
SAMPLE=${8:-}
FQ1=$9
FQ2=${10}
LANE=${11}
EMIT_GAM=${12:-false}

GIRAFFE_ARGS=(
  -Z "$GBZ" -d "$DIST" -m "$MIN" -z "$ZIP"
  --ref-paths "$REFPATHS"
  -t "$THREADS"
  -f "$FQ1" -f "$FQ2"
  --output-format GAM
)
SURJECT_ARGS=(
  -x "$GBZ" -b -i -F "$REFPATHS"
  -t "$THREADS"
)
[ -n "$RG" ] && GIRAFFE_ARGS+=( -R "$RG" ) && SURJECT_ARGS+=( -R "$RG" )
[ -n "$SAMPLE" ] && GIRAFFE_ARGS+=( -N "$SAMPLE" ) && SURJECT_ARGS+=( -N "$SAMPLE" )

# The GAM is spliced out of the stream with tee when it has to survive the pipe,
# either because the caller asked for it or because the SV track will pack it.
if [ "$EMIT_GAM" = "true" ]; then
  vg giraffe "${GIRAFFE_ARGS[@]}" 2>"${LANE}.giraffe.log" \
    | tee "${LANE}.gam" \
    | vg surject "${SURJECT_ARGS[@]}" - > "${LANE}.bam"
  [ -s "${LANE}.gam" ] || { echo "vg-giraffe.sh: no GAM produced for ${LANE}" >&2; exit 1; }
else
  vg giraffe "${GIRAFFE_ARGS[@]}" 2>"${LANE}.giraffe.log" \
    | vg surject "${SURJECT_ARGS[@]}" - > "${LANE}.bam"
fi

[ -s "${LANE}.bam" ] || { echo "vg-giraffe.sh: no BAM produced for ${LANE}" >&2; exit 1; }