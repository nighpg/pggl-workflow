#!/usr/bin/env bash
#
# One DeepVariant call with NVIDIA Parabricks (pbrun deepvariant), taking the same
# arguments as the run_deepvariant steps of the other call parts so the CWL parts
# can swap tools without changing their wiring:
#
#   make_examples_extra_args  run_deepvariant style, comma separated; the two keys
#                             the workflow sets are translated:
#                               --min_mapping_quality=N -> --min-mapping-quality N
#                               --normalize_reads=true  -> --normalize-reads
#                             anything else is rejected rather than silently dropped
#   postprocess_extra_args    --haploid_contigs=chrX    -> --haploid-contigs chrX
#
# pbrun writes <prefix>.g.vcf.gz plus a plain VCF next to it; both are indexed here
# if pbrun left them unindexed. The GPU count is --num-gpus (pbrun's default is 1).
#
# Usage: parabricks-deepvariant.sh <ref.fa> <in.bam> <interval.bed|""> <prefix>
#                                  <num_gpus> <make_examples_extra_args>
#                                  <postprocess_extra_args> [model_type]
set -euo pipefail

REF=$1
BAM=$2
BED=$3
PREFIX=$4
NUM_GPUS=$5
ME_ARGS=$6
PP_ARGS=$7
MODEL=${8:-WGS}

ARGS=( --ref "$REF" --in-bam "$BAM" --out-variants "${PREFIX}.g.vcf.gz" --gvcf
       --num-gpus "$NUM_GPUS" --tmp-dir "$PWD" )
[ -n "$BED" ] && ARGS+=( --interval-file "$BED" )
case "$MODEL" in
    WGS) ;;
    WES) ARGS+=( --use-wes-model ) ;;
    *) echo "parabricks-deepvariant.sh: model_type $MODEL has no Parabricks equivalent here" >&2; exit 2 ;;
esac

IFS=, read -r -a me <<< "$ME_ARGS"
for a in "${me[@]}"; do
    case "$a" in
        "") ;;
        --min_mapping_quality=*) ARGS+=( --min-mapping-quality "${a#*=}" ) ;;
        --normalize_reads=true) ARGS+=( --normalize-reads ) ;;
        --normalize_reads=false) ;;
        *) echo "parabricks-deepvariant.sh: make_examples argument $a is not translated for pbrun" >&2; exit 2 ;;
    esac
done
IFS=, read -r -a pp <<< "$PP_ARGS"
for a in "${pp[@]}"; do
    case "$a" in
        "") ;;
        --haploid_contigs=*) ARGS+=( --haploid-contigs "${a#*=}" ) ;;
        *) echo "parabricks-deepvariant.sh: postprocess argument $a is not translated for pbrun" >&2; exit 2 ;;
    esac
done

# apptainer --nv puts the driver libraries in /.singularity.d/libs and points
# LD_LIBRARY_PATH there, but cwltool runs its tools with a cleaned environment,
# so put the directory back rather than rely on the runner passing it through.
if [ -d /.singularity.d/libs ]; then
    case ":${LD_LIBRARY_PATH:-}:" in
        *:/.singularity.d/libs:*) ;;
        *) export LD_LIBRARY_PATH=/.singularity.d/libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} ;;
    esac
fi

# pbrun only says "Could not find accessible GPUs"; say what this process sees,
# so a missing --nv, a device cgroup or a driver problem can be told apart.
if ! nvidia-smi -L >&2; then
    {
        echo "parabricks-deepvariant.sh: nvidia-smi sees no GPU in this container"
        echo "  CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES-<unset>} NVIDIA_VISIBLE_DEVICES=${NVIDIA_VISIBLE_DEVICES-<unset>}"
        echo "  devices: $(ls /dev/nvidia* 2>/dev/null | tr '\n' ' ')"
        echo "  nvidia-smi: $(command -v nvidia-smi || echo 'not found (was apptainer run with --nv?)')"
    } >&2
    exit 1
fi
echo "pbrun deepvariant ${ARGS[*]}" >&2
pbrun deepvariant "${ARGS[@]}"

for f in "${PREFIX}.g.vcf.gz" "${PREFIX}.vcf.gz"; do
    [ -s "$f" ] || { echo "parabricks-deepvariant.sh: $f was not produced" >&2; exit 1; }
    [ -s "$f.tbi" ] || bcftools index -t -f "$f"
done
