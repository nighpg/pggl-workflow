#!/usr/bin/env cwl-runner

# The GPU half of the calling stage: the five NVIDIA Parabricks DeepVariant
# calls (autosome chunks, PAR, chrX female/male, chrY) on the duplicate-marked
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

  autosome_chunks:
    type:
      - type: array
        items: File
      - "null"
    doc: Optional explicit list of BED files partitioning the autosome. Leave unset to derive the chunks automatically (see autosome_chunks_count); when set, these are used verbatim, in this order.
    default: []

  autosome_chunks_count:
    type: int?
    doc: Convenience knob for automatic autosome chunking. Omit or 0 = a single chunk over the whole autosome (the previous default); N>=2 groups contiguous contigs into ~N bp-balanced chunks (a contig is never split); if N >= the number of contigs, one chunk per contig. Ignored when autosome_chunks is set. DeepVariant still shards each chunk internally via base_shards. Non-HS37 DNA sites that fall in no chunk are dropped.
    default: 0

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
  make_autosome_chunks:
    run: ../../Tools/make-autosome-chunks.cwl
    in:
      bed: autosome_interval
      count: autosome_chunks_count
      user_chunks: autosome_chunks
    out:
      - chunks

  autosome_regions:
    run: ../../Tools/autosome-regions.cwl
    in:
      autosome_chunks: make_autosome_chunks/chunks
      autosome_interval: autosome_interval
      base_shards: threads
      prefix: prefix
    out:
      - chunks
      - prefixes
      - shards

  deepvariant_autosome:
    run: ../../Tools/parabricks-deepvariant.cwl
    in:
      ref: ref
      reads: bam
      interval: autosome_regions/chunks
      num_shards: autosome_regions/shards
      num_gpus: num_gpus
      prefix: autosome_regions/prefixes
    scatter: [interval, num_shards, prefix]
    scatterMethod: dotproduct
    out:
      - gvcf

  concat_autosome:
    run: ../../Tools/concat-gvcfs.cwl
    in:
      prefix: prefix
      gvcf: deepvariant_autosome/gvcf
    out:
      - out_gvcf

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
    outputSource: concat_autosome/out_gvcf
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
