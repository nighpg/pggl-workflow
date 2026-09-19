#!/usr/bin/env bash
#
# Sums the per-lane `vg pack` coverage indexes into one sample-wide pack, the
# read support that `vg call` genotypes against.
#
# `vg pack -i` sums coverage packs, and summing per-lane packs is exact: the
# result is identical to packing a single GAM holding every lane's alignments
# (verified on the toy data). A single pack is passed through unchanged rather
# than re-summed, which avoids a needless full read/write pass.
#
# Produces no output when no packs are given, which is how the workflow
# expresses call_sv=false (cwlVersion v1.1 has no conditional steps).
#
# Usage: vg-pack.sh <gbz> <prefix> <threads> [--packs <pack...>]
set -euo pipefail

GBZ=$1
PREFIX=$2
THREADS=$3
shift 3

case "${1:-}" in
  --packs)
    shift
    ;;
  *)
    echo "vg-pack.sh: no per-lane packs given; skipping (SV calling disabled)" >&2
    exit 0
    ;;
esac

if [ "$#" -lt 1 ]; then
    echo "vg-pack.sh: no per-lane packs given; skipping (SV calling disabled)" >&2
    exit 0
fi

OUT="${PREFIX}.pack"

if [ "$#" -eq 1 ]; then
    cp "$1" "$OUT"
else
    args=()
    for p in "$@"; do
        args+=( -i "$p" )
    done
    vg pack -x "$GBZ" "${args[@]}" -o "$OUT" -t "$THREADS"
fi

[ -s "$OUT" ] || { echo "vg-pack.sh: no pack produced" >&2; exit 1; }
