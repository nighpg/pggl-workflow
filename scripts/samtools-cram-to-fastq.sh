#!/usr/bin/env bash
#
# Recovers read-pair FASTQ from aligned reads -- CRAM or BAM -- so they can be
# re-mapped onto the pangenome with vg giraffe.
#
# The input is name-collated with `samtools collate` and the pairs are written
# out with `samtools fastq`. A CRAM is decoded against the linear reference; a
# BAM carries its own sequences, so --reference is not passed for one.
# Single-end / orphan reads are sent to /dev/null.
#
# Read groups are kept, one output lane per @RG, so that each keeps its own
# library for duplicate marking downstream:
#
#   0 or 1 @RG : one lane, streamed straight from collate to fastq, with the
#                header's @RG (or a synthetic <prefix> one when there is none)
#   2+ @RG     : the collated stream is split by RG (samtools split), and each
#                piece is written out as its own lane with its own @RG line.
#                Reads whose RG is missing or undeclared go to an extra
#                <prefix>_unassigned lane rather than being dropped. The split
#                pieces are transient (BAM level 1) and removed as each lane's
#                FASTQ is written, but at their peak they add roughly one
#                lightly compressed copy of the input to the scratch space.
#
# Outputs, in lane order:
#   <prefix>.cram2fq.<NNNN>.R1.fastq / .R2.fastq   one pair per lane
#   <prefix>.cram2fq.rg.txt                        one @RG line per lane
#
# When no alignment is given the tool produces no outputs (nulls downstream).
# The workflow offers `cram` and `bam` as separate inputs, so giving both is a
# mistake rather than something to resolve silently.
#
# Usage:
#   samtools-cram-to-fastq.sh <prefix> <threads> <ref.fa>
#   samtools-cram-to-fastq.sh <prefix> <threads> <in.cram|in.bam> <ref.fa>
set -euo pipefail
# emit_lane is the last command of a pipeline and counts lanes in LANES, so it
# has to run in this shell rather than a subshell.
shopt -s lastpipe

PREFIX=$1
THREADS=$2
shift 2

# Optional inputs simply drop out of the command line, so the argument count
# says which of them was given.
case "$#" in
  1)
    ALN=
    REF=$1
    ;;
  2)
    ALN=$1
    REF=$2
    ;;
  *)
    echo "ERROR: give at most one aligned input (cram or bam), not both" >&2
    exit 2
    ;;
esac

[ -n "$ALN" ] || {
  echo "no aligned input given; skipping read recovery (outputs will be empty)" >&2
  # The rg list is always written, empty here, so the workflow never has to
  # loadContents a null File (cwltool 3.1 crashes on that in postScatterEval).
  : > "${PREFIX}.cram2fq.rg.txt"
  exit 0
}

[ -f "$ALN" ] || { echo "ERROR: aligned input not found: $ALN" >&2; exit 2; }
[ -f "$REF" ] || { echo "ERROR: reference not found: $REF" >&2; exit 2; }

# A CRAM stores its sequences as differences from the reference and has to be
# decoded against it; a BAM does not.
case "$ALN" in
  *.cram) REF_ARGS=( --reference "$REF" ) ;;
  *.bam)  REF_ARGS=() ;;
  *)      echo "ERROR: expected a .cram or .bam input: $ALN" >&2; exit 2 ;;
esac

mapfile -t RGS < <(samtools view -H "$ALN" 2>/dev/null | grep '^@RG' || true)

RG_OUT="${PREFIX}.cram2fq.rg.txt"
: > "$RG_OUT"
LANES=0

# Write one collated BAM/SAM stream (stdin) out as the next lane, with $1 as
# its @RG line. A read group that holds no pairs produces no lane: an empty
# FASTQ would only fail later in vg giraffe.
emit_lane() {
    local rg=$1 n r1 r2
    n=$(printf '%04d' $((LANES + 1)))
    r1="${PREFIX}.cram2fq.${n}.R1.fastq"
    r2="${PREFIX}.cram2fq.${n}.R2.fastq"
    samtools fastq ${REF_ARGS[@]+"${REF_ARGS[@]}"} -@ "$THREADS" \
        -1 "$r1" -2 "$r2" -0 /dev/null -s /dev/null -
    if [ ! -s "$r1" ]; then
        rm -f "$r1" "$r2"
        echo "no read pairs for: $rg" >&2
        return 0
    fi
    LANES=$((LANES + 1))
    printf '%s\n' "$rg" >> "$RG_OUT"
    echo "lane ${n}: $(( $(wc -l < "$r1") / 4 )) read pairs, $rg" >&2
}

if [ "${#RGS[@]}" -le 1 ]; then
    RG=${RGS[0]:-}
    [ -n "$RG" ] || RG=$(printf '@RG\tID:%s\tPL:ILLUMINA\tSM:%s' "$PREFIX" "$PREFIX")
    samtools collate -u -O -@ "$THREADS" ${REF_ARGS[@]+"${REF_ARGS[@]}"} "$ALN" 2>/dev/null |
        emit_lane "$RG"
else
    echo "input declares ${#RGS[@]} read groups; splitting into one lane each" >&2
    rm -rf rgsplit
    mkdir rgsplit
    # %# is the 0-based index of the @RG line in the header, so rg_<i>.bam
    # belongs to RGS[i] whatever characters its ID holds.
    samtools collate -u -O -@ "$THREADS" ${REF_ARGS[@]+"${REF_ARGS[@]}"} "$ALN" 2>/dev/null |
        samtools split -@ "$THREADS" --output-fmt BAM,level=1 --no-PG \
            -f 'rgsplit/rg_%#.%.' -u rgsplit/unassigned.bam -
    for i in "${!RGS[@]}"; do
        f="rgsplit/rg_${i}.bam"
        [ -f "$f" ] || continue
        emit_lane "${RGS[$i]}" < "$f"
        rm -f "$f"
    done
    if [ -f rgsplit/unassigned.bam ] && [ "$(samtools view -c rgsplit/unassigned.bam)" -gt 0 ]; then
        SM=$(printf '%s\n' "${RGS[0]}" | tr '\t' '\n' | sed -n 's/^SM://p' | head -1)
        emit_lane "$(printf '@RG\tID:%s_unassigned\tPL:ILLUMINA\tSM:%s' "$PREFIX" "${SM:-$PREFIX}")" \
            < rgsplit/unassigned.bam
    fi
    rm -rf rgsplit
fi

[ "$LANES" -gt 0 ] || { echo "ERROR: no read pairs recovered from $ALN" >&2; exit 1; }
echo "recovered ${LANES} lane(s)" >&2
