#!/usr/bin/env bash
#
# Builds the sample-wide `vg pack` coverage index -- the read support that
# `vg call` genotypes against -- from every lane's graph-space GAM.
#
# The lanes are concatenated rather than packed separately and summed. Summing
# is what `vg pack -i` is for, and it is what this step used to do, but that
# path segfaults in vg::Packer::collect_coverage on a whole-genome graph:
# reproduced on JaSaPaGe with two packs, with -Q and without, and at one thread
# as well as 32, so it is neither a race nor a quality-vector mismatch. Packing
# the concatenated GAM in one pass is the definition the sum was approximating
# anyway, and GAM is a concatenable stream, so `cat` is a faithful join.
#
# The concatenated copy is the price: it is as large as all the lane GAMs put
# together, roughly 156 GB for a 30x sample over 12 lanes, and it is removed as
# soon as the pack exists. A single lane is packed in place, with no copy.
#
# Produces no output when no GAMs are given, which is how the workflow
# expresses call_sv=false (cwlVersion v1.1 has no conditional steps).
#
# Usage: vg-pack.sh <gbz> <prefix> <threads> [--gams <gam...>]
set -euo pipefail

GBZ=$1
PREFIX=$2
THREADS=$3
shift 3

# vg's own recommendation for SV genotyping support counts: ignore reads below
# this MAPQ, and positions below this base quality.
PACK_MIN_MAPQ=5

case "${1:-}" in
  --gams)
    shift
    ;;
  *)
    echo "vg-pack.sh: no per-lane GAMs given; skipping (SV calling disabled)" >&2
    exit 0
    ;;
esac

if [ "$#" -lt 1 ]; then
    echo "vg-pack.sh: no per-lane GAMs given; skipping (SV calling disabled)" >&2
    exit 0
fi

OUT="${PREFIX}.pack"
JOINED=

if [ "$#" -eq 1 ]; then
    IN=$1
else
    JOINED="${PREFIX}.all.gam"
    # Tens of GB per lane, so never leave it behind on a failed run.
    trap 'rm -f "$JOINED"' EXIT
    cat "$@" > "$JOINED"
    IN=$JOINED
fi

vg pack -x "$GBZ" -g "$IN" -o "$OUT" -Q "$PACK_MIN_MAPQ" -t "$THREADS"

if [ -n "$JOINED" ]; then
    rm -f "$JOINED"
    JOINED=
fi

[ -s "$OUT" ] || { echo "vg-pack.sh: no pack produced" >&2; exit 1; }
