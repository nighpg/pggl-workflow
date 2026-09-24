#!/usr/bin/env bash
#
# Genotypes the structural variants that are embedded in the pangenome graph,
# from the read support built by vg pack, and writes them as bgzipped,
# tabix-indexed VCFs in reference coordinates.
#
# vg call has one ploidy for the whole run, so the sex chromosomes cannot come
# out right in a single pass: at the default ploidy 2 a male chrX is genotyped
# as a diploid and roughly half its sites are called heterozygous, which on a
# haploid chromosome they cannot be (measured on NA18945: 47.6% of chrX SVs
# het, against a chrX read depth exactly half the autosomal one). So the same
# pack is called twice -- once diploid, once with -d 1 -- and the regions are
# taken from whichever pass has the right ploidy for them:
#
#   <prefix>.sv.vcf.gz               autosomes + PAR          diploid
#   <prefix>.sv.chrX_female.vcf.gz   chrX outside PAR         diploid
#   <prefix>.sv.chrX_male.vcf.gz     chrX outside PAR         haploid
#   <prefix>.sv.chrY.vcf.gz          chrY                     haploid
#
# Both sexes are emitted and neither is chosen here, exactly as the gVCF side
# of the workflow does: the sample's sex is not an input, and guessing it from
# coverage is the caller's business, not this step's.
#
# -d 1 rather than -R <contig>:1 for the haploid pass: -R assigns ploidy per
# contig by regex and so could do both in one pass, but on a graph whose
# reference is stored as PanSN subranges the contig it matches against is the
# fragment name (GRCh38#0#chrX[2781479]), and whether the regex is applied
# before or after that is resolved is not documented. -d 1 makes the whole pass
# haploid, which is wrong for the autosomes -- but nothing is taken from the
# autosomes of that pass, so it does not matter, and it has no such dependency.
#
# Without the three interval BEDs there is nothing to split on, so the run
# falls back to one whole-genome diploid <prefix>.sv.vcf.gz and no sex files.
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
#                      [--pack <file>] [--par-bed <file>] [--chrx-bed <file>]
#                      [--chry-bed <file>]
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
PAR_BED=
CHRX_BED=
CHRY_BED=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ref-paths)
      REF_PATHS=$2
      shift 2
      ;;
    --par-bed)
      PAR_BED=$2
      shift 2
      ;;
    --chrx-bed)
      CHRX_BED=$2
      shift 2
      ;;
    --chry-bed)
      CHRY_BED=$2
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

# The normaliser is shared by both passes. It goes to a file rather than a
# shell variable because it is full of $0 and $1, which a double-quoted
# variable would hand to bash instead of to awk.
cat > normalise.awk <<'NORMALISE_AWK'
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
          # A dictionary also carries the contig lengths, and the ones vg
          # reports are wrong for a reference stored as subranges: it gives the
          # end of the last fragment, so every clipped tail is missing (chr9 is
          # 83 kb short on JaSaPaGe). A VCF whose ##contig lengths disagree with
          # the reference is rejected outright by anything that compares
          # sequence dictionaries, so the dictionary wins.
          for (i = 2; i <= nf; i++) {
            if (substr(fld[i], 1, 3) == "LN:") { dictlen[strip(name)] = substr(fld[i], 4); break }
          }
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
    tail = substr(rest, length(raw_id) + 1)
    if (id in dictlen) sub(/length=[0-9]+/, "length=" dictlen[id], tail)
    contig[id] = "##contig=<ID=" id tail
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
NORMALISE_AWK

# One vg call pass: genotype, normalise the contig names and order, sort, index.
# Usage: call_pass <out.vcf.gz> [extra vg call args...]
call_pass() {
  local out=$1
  shift
  vg call "${CALL_ARGS[@]}" "$@" > raw.vcf
  awk -v p="$REF_PATH_PREFIX" -v refpaths="$REF_PATHS" -f normalise.awk raw.vcf > fixed.vcf
  bcftools sort -O z -o "$out" fixed.vcf
  bcftools index -t "$out"
  rm -f raw.vcf fixed.vcf
  [ -s "$out" ] || { echo "vg-call-sv.sh: no output produced for $out" >&2; exit 1; }
}

MAIN="${PREFIX}.sv.vcf.gz"
count() { bcftools view -H "$1" | wc -l; }

call_pass diploid.vcf.gz

# No intervals to split on: leave the whole genome in one diploid file, which
# is what this step did before the sex chromosomes were separated out.
if [ -z "$PAR_BED" ] || [ -z "$CHRX_BED" ] || [ -z "$CHRY_BED" ]; then
    mv diploid.vcf.gz "$MAIN"
    mv diploid.vcf.gz.tbi "${MAIN}.tbi"
    rm -f normalise.awk
    echo "genotyped $(count "$MAIN") SV sites (>= ${MIN_LENGTH} bp); no interval BEDs given, so chrX and chrY stay at ploidy 2" >&2
    exit 0
fi

call_pass haploid.vcf.gz -d 1

# The sex chromosomes are named by the BEDs rather than hardcoded here, so a
# reference that names them differently still works.
XNAME=$(cut -f1 "$CHRX_BED" | sort -u | head -1)
YNAME=$(cut -f1 "$CHRY_BED" | sort -u | head -1)

# Autosomes are the diploid pass with the sex chromosomes dropped; PAR is added
# back from that same pass, being diploid in both sexes.
bcftools view -O z -o auto.vcf.gz -t "^${XNAME},${YNAME}" diploid.vcf.gz
bcftools index -t auto.vcf.gz
bcftools view -O z -o par.vcf.gz -R "$PAR_BED" diploid.vcf.gz
bcftools index -t par.vcf.gz
bcftools concat -a -O z -o "$MAIN" auto.vcf.gz par.vcf.gz
bcftools index -t "$MAIN"

for spec in "chrX_female:$CHRX_BED:diploid.vcf.gz" \
            "chrX_male:$CHRX_BED:haploid.vcf.gz" \
            "chrY:$CHRY_BED:haploid.vcf.gz"; do
    name=${spec%%:*}; rest=${spec#*:}
    bed=${rest%%:*}; src=${rest#*:}
    bcftools view -O z -o "${PREFIX}.sv.${name}.vcf.gz" -R "$bed" "$src"
    bcftools index -t "${PREFIX}.sv.${name}.vcf.gz"
done

rm -f diploid.vcf.gz diploid.vcf.gz.tbi haploid.vcf.gz haploid.vcf.gz.tbi \
      auto.vcf.gz auto.vcf.gz.tbi par.vcf.gz par.vcf.gz.tbi normalise.awk

echo "genotyped SV sites (>= ${MIN_LENGTH} bp):" \
     "$(count "$MAIN") autosome+PAR," \
     "$(count "${PREFIX}.sv.chrX_female.vcf.gz") chrX diploid," \
     "$(count "${PREFIX}.sv.chrX_male.vcf.gz") chrX haploid," \
     "$(count "${PREFIX}.sv.chrY.vcf.gz") chrY haploid" >&2
