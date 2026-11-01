#!/usr/bin/env cwl-runner

# The GPU part of the calling stage: the five NVIDIA Parabricks DeepVariant
# calls (autosome, PAR, chrX female/male, chrY) on the duplicate-marked
# BAM of parts/call-markdup.cwl. Nothing else runs here, so a GPU node is
# held only for the calls themselves.

class: Workflow
id: call-dv-parabricks
label: call-dv-parabricks
cwlVersion: v1.1

requirements:
  InlineJavascriptRequirement: {}
  ScatterFeatureRequirement: {}
  StepInputExpressionRequirement: {}

inputs:
  ref:
    type: File
    doc: Linear reference FASTA used to decode the CRAM and for variant calling; contig sequences must match the graph reference paths (or the CRAM @SQ)
    secondaryFiles:
      - ^.dict
      - .fai

  bam:
    type: File
    doc: Duplicate-marked BAM in reference coordinates (parts/call-markdup.cwl)
    secondaryFiles:
      - .bai

  autosome_interval:
    type: File
    doc: Interval BED file for autosome regions

  PAR_interval:
    type: File
    doc: Interval BED file for PAR regions

  chrX_interval:
    type: File
    doc: Interval BED file for chrX regions (excluding PAR)

  chrY_interval:
    type: File
    doc: Interval BED file for chrY regions

  prefix:
    type: string
    doc: Output file prefix

  threads:
    type: int
    doc: CPU threads for vg giraffe, samtools and the DeepVariant shards. How many GPUs the run uses is not set here -- it is whatever CUDA is allowed to see (apptainer --nv, NVIDIA_VISIBLE_DEVICES, Slurm --gres).
    default: 32

  num_gpus:
    type: int
    doc: GPUs each pbrun deepvariant call uses (--num-gpus). The calls run one after another unless cwltool --parallel has the GPUs to run several; Slurm must grant them (--gres=gpu:N).
    default: 1

steps:
  # One pbrun over the whole autosome: Parabricks splits the genome across the
  # GPUs itself, so pre-split chunks would only repeat its start-up and model
  # load (autosome_chunks / autosome_chunks_count are for the CPU variants).
  deepvariant_autosome:
    run: ../../Tools/parabricks-deepvariant.cwl
    in:
      ref: ref
      reads: bam
      interval: autosome_interval
      num_shards: threads
      num_gpus: num_gpus
      prefix:
        source: prefix
        valueFrom: $(self + ".autosome")
    out:
      - gvcf

  deepvariant_PAR:
    run: ../../Tools/parabricks-deepvariant.cwl
    in:
      ref: ref
      reads: bam
      interval: PAR_interval
      num_shards: threads
      num_gpus: num_gpus
      prefix:
        source: prefix
        valueFrom: $(self + ".PAR")
    out:
      - gvcf

  deepvariant_chrX_female:
    run: ../../Tools/parabricks-deepvariant.cwl
    in:
      ref: ref
      reads: bam
      interval: chrX_interval
      num_shards: threads
      num_gpus: num_gpus
      prefix:
        source: prefix
        valueFrom: $(self + ".chrX_female")
    out:
      - gvcf

  deepvariant_chrX_male:
    run: ../../Tools/parabricks-deepvariant.cwl
    in:
      ref: ref
      reads: bam
      interval: chrX_interval
      num_shards: threads
      num_gpus: num_gpus
      postprocess_extra_args:
        valueFrom: "--haploid_contigs=chrX"
      prefix:
        source: prefix
        valueFrom: $(self + ".chrX_male")
    out:
      - gvcf

  deepvariant_chrY:
    run: ../../Tools/parabricks-deepvariant.cwl
    in:
      ref: ref
      reads: bam
      interval: chrY_interval
      num_shards: threads
      num_gpus: num_gpus
      postprocess_extra_args:
        valueFrom: "--haploid_contigs=chrY"
      prefix:
        source: prefix
        valueFrom: $(self + ".chrY")
    out:
      - gvcf

outputs:
  gvcf_autosome:
    type: File
    doc: Diploid gVCF for autosome regions (reference coordinates)
    outputSource: deepvariant_autosome/gvcf
    secondaryFiles:
      - .tbi

  gvcf_PAR:
    type: File
    doc: Diploid gVCF for PAR regions (reference coordinates)
    outputSource: deepvariant_PAR/gvcf
    secondaryFiles:
      - .tbi

  gvcf_chrX_female:
    type: File
    doc: Diploid gVCF for female chrX
    outputSource: deepvariant_chrX_female/gvcf
    secondaryFiles:
      - .tbi

  gvcf_chrX_male:
    type: File
    doc: Haploid gVCF for male chrX
    outputSource: deepvariant_chrX_male/gvcf
    secondaryFiles:
      - .tbi

  gvcf_chrY:
    type: File
    doc: Haploid gVCF for chrY
    outputSource: deepvariant_chrY/gvcf
    secondaryFiles:
      - .tbi
