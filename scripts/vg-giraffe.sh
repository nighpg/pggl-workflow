#!/usr/bin/env bash
#
# One lane of vg giraffe: emits GAM to the workdir (lane.gam, kept only when
# emit_gam is set) and a surjected BAM on the reference paths (lane.bam).
#
# When <pack_out> is given, the GAM is also kept on disk for the length of this
# step and `vg pack` is run over it afterwards, building the read support that
# SV genotyping (vg call) needs.
#
# That GAM file is not an accident of convenience: vg pack cannot read a FIFO.
# It opens its -g argument once at startup, closes it again immediately, and
# only reopens it after loading the GBZ -- on a whole-genome graph that is ten
# minutes later. Streaming into a FIFO therefore breaks as soon as the graph is
# big enough: the transient open releases the writer, the writer's first write
# finds no reader left and dies of SIGPIPE, and giraffe follows it down the
# pipe, while vg pack settles into an open() that never returns. Measured on
# JaSaPaGe: giraffe and tee died 2 minutes in, vg pack was still waiting 13
# minutes later with a zero-byte pack. A toy graph loads instantly, which is
# why the FIFO looked fine in the fixtures, and why the disk detour is not
# optional here.
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
# one of them, so emit_gam and pack_out are independent -- but when both are
# set they want the same bytes, so one copy serves both and only the copy this
# step created for itself is removed again.
TEE_TARGETS=()
[ "$EMIT_GAM" = "true" ] && TEE_TARGETS+=( "${LANE}.gam" )

PACK_GAM=
if [ -n "$PACK_OUT" ]; then
  if [ "$EMIT_GAM" = "true" ]; then
    PACK_GAM="${LANE}.gam"
  else
    PACK_GAM="${LANE}.pack.gam"
    TEE_TARGETS+=( "$PACK_GAM" )
    # A lane's GAM is tens of GB and is of no use once the pack exists, so it
    # goes even when the step fails half-way.
    trap 'rm -f "$PACK_GAM"' EXIT
  fi
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
  [ -s "$PACK_GAM" ] || { echo "vg-giraffe.sh: no GAM to pack for ${LANE}" >&2; exit 1; }
  vg pack -x "$GBZ" -g "$PACK_GAM" -o "$PACK_OUT" \
      -Q "$PACK_MIN_MAPQ" -t "$THREADS"
  [ -s "$PACK_OUT" ] || { echo "vg-giraffe.sh: no pack produced for ${LANE}" >&2; exit 1; }
  [ "$EMIT_GAM" = "true" ] || rm -f "$PACK_GAM"
fi

[ -s "${LANE}.bam" ] || { echo "vg-giraffe.sh: no BAM produced for ${LANE}" >&2; exit 1; }