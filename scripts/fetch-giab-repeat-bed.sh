#!/usr/bin/env bash
#
# Downloads the GIAB GRCh38 tandem-repeat and homopolymer BED (stratifications v3.6)
# that the graph presets use as sv_exclude_bed (30 MB, not tracked by git). Run once
# on a host with network access; copy the file to an offline host.
#
# Usage: scripts/fetch-giab-repeat-bed.sh [--out DIR]
#   --out DIR   directory to put the BED in (default: this checkout's interval_files/,
#               where apply-graph.py finds it; a DIR elsewhere is found only when it
#               is $PGGL_DATA/interval_files)
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT_DIR=$HERE/interval_files
while [ $# -gt 0 ]; do
    case "$1" in
        --out) [ $# -ge 2 ] || { echo "--out needs a directory" >&2; exit 1; }; OUT_DIR=$2; shift 2 ;;
        -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option $1 (see --help)" >&2; exit 1 ;;
    esac
done
NAME=GRCh38_AllTandemRepeatsandHomopolymers_slop5.bed.gz
URL=https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/release/genome-stratifications/v3.6/GRCh38@all/LowComplexity/$NAME
OUT=$OUT_DIR/$NAME
[ -s "$OUT" ] && { echo "$OUT already present"; exit 0; }
mkdir -p "$OUT_DIR" 2>/dev/null && [ -w "$OUT_DIR" ] \
    || { echo "cannot write to $OUT_DIR; pass --out DIR (a writable directory)" >&2; exit 1; }
curl -fsSL -o "$OUT.part" "$URL"
gzip -t "$OUT.part"
mv "$OUT.part" "$OUT"
echo "wrote $OUT ($(gzip -dc "$OUT" | wc -l) regions)"
