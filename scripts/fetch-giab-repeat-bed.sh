#!/usr/bin/env bash
#
# Downloads the GIAB GRCh38 tandem-repeat and homopolymer BED (stratifications v3.6)
# that the graph presets use as sv_exclude_bed, into interval_files/ (not tracked:
# 30 MB). Run once per checkout on a host with network access; copy the file along
# with the checkout to an offline host.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NAME=GRCh38_AllTandemRepeatsandHomopolymers_slop5.bed.gz
URL=https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/release/genome-stratifications/v3.6/GRCh38@all/LowComplexity/$NAME
OUT=$HERE/interval_files/$NAME
[ -s "$OUT" ] && { echo "$OUT already present"; exit 0; }
curl -fsSL -o "$OUT.part" "$URL"
gzip -t "$OUT.part"
mv "$OUT.part" "$OUT"
echo "wrote $OUT ($(gzip -dc "$OUT" | wc -l) regions)"
