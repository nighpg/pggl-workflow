#!/usr/bin/env bash
#
# One lane of vg giraffe: emits GAM to the workdir (lane.gam, kept only when
# emit_gam is set) and a surjected BAM on the reference paths (lane.bam).
#
# When <pack_out> is given, the same GAM stream is additionally fed to
# `vg pack` through a FIFO, so the read support needed for SV genotyping
# (vg call) is built without ever materialising the GAM on disk. Verified to
# produce a pack identical to `vg pack -g <lane.gam>` on the toy data.
#
# The BAM written here is record-identical to `vg giraffe --output-format BAM`
# (verified for vg 1.70): surfaced reads are surjected onto the reference paths
# listed in the --ref-paths file. The @RG/@SM fields are stamped with -R/-N,
# matching the previous direct-BAM behaviour.
#
# Usage: vg-giraffe.sh <gbz> <dist> <min> <zipcodes> <ref_paths> <threads> \
#                      <read_group> <sample> <fq1> <fq2> <lane> <emit_gam> \
#                      [pack_out]
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
PACK_OUT=${13:-}

# vg's own recommendation for SV genotyping support counts.
PACK_MIN_MAPQ=5

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

# Extra consumers of the GAM stream, spliced in with tee. The GAM file is only
# one of them, so emit_gam and pack_out are independent.
TEE_TARGETS=()
[ "$EMIT_GAM" = "true" ] && TEE_TARGETS+=( "${LANE}.gam" )

PACK_PID=
PACK_FIFO=
if [ -n "$PACK_OUT" ]; then
  PACK_FIFO="${LANE}.pack.fifo"
  rm -f "$PACK_FIFO"
  mkfifo "$PACK_FIFO"
  # Reads the FIFO for as long as tee writes to it; must be reaped before the
  # pack file can be considered complete.
  vg pack -x "$GBZ" -g "$PACK_FIFO" -o "$PACK_OUT" \
      -Q "$PACK_MIN_MAPQ" -t "$THREADS" &
  PACK_PID=$!
  TEE_TARGETS+=( "$PACK_FIFO" )
  # Never leave vg pack blocked on a FIFO nobody writes to when giraffe dies.
  trap '[ -n "$PACK_PID" ] && kill "$PACK_PID" 2>/dev/null; rm -f "$PACK_FIFO"' EXIT
fi

if [ "${#TEE_TARGETS[@]}" -gt 0 ]; then
  vg giraffe "${GIRAFFE_ARGS[@]}" 2>"${LANE}.giraffe.log" \
    | tee "${TEE_TARGETS[@]}" \
    | vg surject "${SURJECT_ARGS[@]}" - > "${LANE}.bam"
else
  vg giraffe "${GIRAFFE_ARGS[@]}" 2>"${LANE}.giraffe.log" \
    | vg surject "${SURJECT_ARGS[@]}" - > "${LANE}.bam"
fi

if [ -n "$PACK_OUT" ]; then
  wait "$PACK_PID" || { echo "vg-giraffe.sh: vg pack failed for ${LANE}" >&2; exit 1; }
  PACK_PID=
  rm -f "$PACK_FIFO"
  [ -s "$PACK_OUT" ] || { echo "vg-giraffe.sh: no pack produced for ${LANE}" >&2; exit 1; }
fi

[ -s "${LANE}.bam" ] || { echo "vg-giraffe.sh: no BAM produced for ${LANE}" >&2; exit 1; }