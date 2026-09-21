#!/usr/bin/env bash
#
# Genotypes the structural variants that are embedded in the pangenome graph,
# from the read support built by vg pack, and writes them as a bgzipped,
# tabix-indexed VCF in reference coordinates (<prefix>.sv.vcf.gz).
#
# `vg call -z` restricts the genotypes to the haplotypes stored in the GBZ,
# which is both faster and more accurate than calling arbitrary traversals, and
# `-c <min_length>` keeps only snarls with a traversal of at least that length,
# i.e. the SVs. Note that this genotypes variation *present in the graph*: vg
# cannot discover novel SVs (its own docs state that augmentation-based de novo
# calling does not work for SVs), so novel events need a linear caller such as
# Manta or Delly on <prefix>.bam.
#
# The whole graph is deliberately genotyped in one process rather than scattered
# per contig: every vg call job would have to load the whole GBZ and snarls, so
# a per-contig scatter multiplies memory by the contig count on a 54 GB graph
# instead of dividing the work. vg call is threaded internally with -t.
#
# vg writes plain contig names (chr1) in the CHROM column but keeps the full
# PanSN path name (GRCh38#0#chr1) in the ##contig header lines, so the two
# disagree; ref_path_prefix is stripped from both, which also lines the VCF up
# with <prefix>.bam and the interval BEDs. vg also emits the ##contig lines in
# its own internal order, so they are reordered to follow ref_paths, i.e. the
# same order as the BAM @SQ: bcftools sort orders records by the header, and
# tools that compare sequence dictionaries (GATK) reject a mismatched order.
#
# ref_paths is read in either of the two forms vg accepts for --ref-paths / -F:
# one path name per line, or an HTSlib sequence dictionary. The dictionary form
# is what a graph whose reference is stored as PanSN subranges needs, and both
# are mapped onto the parent contig names the VCF uses.
#
# Produces no output when no pack is given, which is how the workflow expresses
# call_sv=false (cwlVersion v1.1 has no conditional steps).
#
# Usage: vg-call-sv.sh <gbz> <prefix> <sample> <threads> <min_length>
#                      <ref_path_prefix> [--ref-paths <file>] [--snarls <file>]
#                      [--pack <file>]
set -euo pipefail

GBZ=$1
PREFIX=$2
SAMPLE=$3
THREADS=$4
MIN_LENGTH=$5
REF_PATH_PREFIX=$6
shift 6

SNARLS=
PACK=
REF_PATHS=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ref-paths)
      REF_PATHS=$2
      shift 2
      ;;
    --snarls)
      SNARLS=$2
      shift 2
      ;;
    --pack)
      PACK=$2
      shift 2
      ;;
    *)
      echo "vg-call-sv.sh: unexpected argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$PACK" ]; then
    echo "vg-call-sv.sh: no pack given; skipping (SV calling disabled)" >&2
    exit 0
fi
[ -s "$PACK" ] || { echo "ERROR: empty pack: $PACK" >&2; exit 2; }

CALL_ARGS=(
  "$GBZ"
  -k "$PACK"
  -z
  -c "$MIN_LENGTH"
  -s "$SAMPLE"
  -t "$THREADS"
)
[ -n "$SNARLS" ] && CALL_ARGS+=( -r "$SNARLS" )

# `vg call` genotypes *every* reference assembly in the graph by default (the
# default for -p is "all"), so on a graph that carries more than one -- e.g.
# JaSaPaGe, whose GBWT reference_samples tag is "CHM13v2 GRCh38" -- the VCF
# comes out with the contigs of both assemblies mixed together and no longer
# matches the BAM and the gVCFs. ref_path_prefix is the PanSN
# <sample>#<haplotype># of the assembly this run surjects onto, so its sample
# field selects the matching one. An empty prefix means plain contig names,
# i.e. a single-reference graph, where the default is already right.
REF_SAMPLE=${REF_PATH_PREFIX%%#*}
[ -n "$REF_SAMPLE" ] && CALL_ARGS+=( -S "$REF_SAMPLE" )

vg call "${CALL_ARGS[@]}" > raw.vcf

# Strip the PanSN prefix from the ##contig headers and, defensively, from the
# CHROM column too (a no-op when vg already wrote plain names there), then
# re-emit the ##contig block in ref_paths order.
awk -v p="$REF_PATH_PREFIX" -v refpaths="$REF_PATHS" '
  function strip(s) {
    return (n > 0 && substr(s, 1, n) == p) ? substr(s, n + 1) : s
  }
  # vg is expected to report subrange paths against their parent contig, as
  # `vg surject` does. Should a name reach the VCF with the subrange marker
  # still on it, its POS is relative to the fragment rather than to the contig,
  # so the file would silently disagree with the BAM: fail instead of guessing.
  function check_subrange(id) {
    if (id ~ /\[[0-9]+\]$/) {
      print "vg-call-sv.sh: vg call emitted the subpath contig \"" id \
            "\"; its positions are fragment-relative and cannot be" \
            " reconciled with the BAM." > "/dev/stderr"
      exit 3
    }
  }
  BEGIN {
    FS = OFS = "\t"
    n = length(p)
    norder = 0
    if (refpaths != "") {
      while ((getline line < refpaths) > 0) {
        sub(/\r$/, "", line)
        if (line == "") continue
        # Both forms vg itself accepts for --ref-paths / -F are read here: one
        # path name per line, or an HTSlib sequence dictionary. The dictionary
        # is the only way to surject onto a reference whose paths are stored as
        # PanSN subranges (chr1[585988]), because vg then takes the contig
        # names and lengths from the header instead of from the split paths.
        if (substr(line, 1, 1) == "@") {
          if (substr(line, 1, 3) != "@SQ") continue
          name = ""
          nf = split(line, fld, "\t")
          for (i = 2; i <= nf; i++) {
            if (substr(fld[i], 1, 3) == "SN:") { name = substr(fld[i], 4); break }
          }
          if (name == "") continue
        } else {
          name = line
        }
        id = strip(name)
        # A subrange path belongs to its parent contig, which is the name the
        # VCF carries, so several entries can collapse onto one contig.
        sub(/\[[0-9]+\]$/, "", id)
        if (id in ordered) continue
        ordered[id] = 1
        order[++norder] = id
      }
      close(refpaths)
    }
  }
  /^##contig=<ID=/ {
    # ##contig=<ID= is 13 characters; the id runs up to the next , or >
    rest = substr($0, 14)
    raw_id = rest
    sub(/[,>].*$/, "", raw_id)
    id = strip(raw_id)
    check_subrange(id)
    contig[id] = "##contig=<ID=" id substr(rest, length(raw_id) + 1)
    if (!(id in seen)) { seen[id] = 1; extra[++nextra] = id }
    next
  }
  /^#CHROM/ {
    # Emit the contigs in ref_paths order, then any the graph had on top.
    for (i = 1; i <= norder; i++) {
      if (order[i] in contig) { print contig[order[i]]; emitted[order[i]] = 1 }
    }
    for (i = 1; i <= nextra; i++) {
      if (!(extra[i] in emitted)) print contig[extra[i]]
    }
    print
    next
  }
  /^#/ { print; next }
  { $1 = strip($1); check_subrange($1); print }
' raw.vcf > fixed.vcf

OUT="${PREFIX}.sv.vcf.gz"
bcftools sort -O z -o "$OUT" fixed.vcf
bcftools index -t "$OUT"

rm -f raw.vcf fixed.vcf

[ -s "$OUT" ] || { echo "vg-call-sv.sh: no output produced" >&2; exit 1; }
echo "genotyped $(bcftools view -H "$OUT" | wc -l) SV sites (>= ${MIN_LENGTH} bp)" >&2
