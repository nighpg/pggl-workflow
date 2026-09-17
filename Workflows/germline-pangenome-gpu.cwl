#!/usr/bin/env cwl-runner
# GPU variant: identical to germline-pangenome-cpu.cwl except the five
# DeepVariant steps run on the GPU (google/deepvariant:1.10.0-gpu, --use_gpu).
# vg giraffe + samtools stay on CPU. Requires a CUDA driver (e.g. V100S) on the
# host and the container started with GPU passthrough:
#   singularity exec --nv deepvariant-opencode-cpu-vg-gpu.sif \
#     /opt/pangenome/run-pangenome.sh Workflows/germline-pangenome-gpu.cwl ...

class: Workflow
id: germline-pangenome-gpu
label: germline-pangenome-gpu
cwlVersion: v1.1

requirements:
  InlineJavascriptRequirement: {}
  ScatterFeatureRequirement: {}
  StepInputExpressionRequirement: {}

inputs:
  fq1:
    type: File[]?
    doc: FASTQ file 1. This option can be used multiple times. Omit when cram is provided.
    default: []

  fq2:
    type: File[]?
    doc: FASTQ file 2. This option can be used multiple times. Omit when cram is provided.
    default: []

  rg:
    type: string[]?
    doc: Read group string. This option can be used multiple times. Omit when cram is provided.
    default: []

  cram:
    type: File?
    doc: Coordinate-sorted aligned CRAM in reference coordinates with @SQ matching ref; reads are recovered to FASTQ (decoded with ref) and re-mapped onto the pangenome with vg giraffe, exactly like a FASTQ lane (its @RG is carried over)
    secondaryFiles:
      - { pattern: ".crai", required: false }

  gbz:
    type: File
    doc: GBZ pangenome graph

  dist:
    type: File
    doc: giraffe distance index (.dist)

  min:
    type: File
    doc: giraffe minimizer index (.min)

  zipcodes:
    type: File
    doc: giraffe zipcode index (.zipcodes)

  ref_paths:
    type: File
    doc: Ordered list of reference paths in the graph, one per line; drives giraffe @SQ and surjection

  ref:
    type: File
    doc: Linear reference FASTA used to decode the CRAM and for variant calling; contig sequences must match the graph reference paths (or the CRAM @SQ)
    secondaryFiles:
      - ^.dict
      - .fai

  ref_path_prefix:
    type: string
    doc: Reference path prefix (PanSN <sample>#<haplotype>#) to strip from @SQ contig names; empty means no strip
    default: "GRCh38#0#"

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
    doc: Number of threads for vg giraffe, samtools and DeepVariant shards
    default: 32

steps:
  lane_from_rg:
    run: ../Tools/lane-from-rg.cwl
    in:
      rg: combine_lanes/rg
    out:
      - lane_names

  cram_to_fastq:
    run: ../Tools/samtools-cram-to-fastq.cwl
    in:
      prefix: prefix
      threads: threads
      cram: cram
      ref: ref
    out:
      - fq1
      - fq2
      - rg

  combine_lanes:
    run: ../Tools/combine-lanes.cwl
    in:
      user_fq1: fq1
      user_fq2: fq2
      user_rg: rg
      cram_fq1: cram_to_fastq/fq1
      cram_fq2: cram_to_fastq/fq2
      cram_rg:
        source: cram_to_fastq/rg
        loadContents: true
    out:
      - fq1
      - fq2
      - rg

  giraffe:
    run: ../Tools/vg-giraffe.cwl
    in:
      gbz: gbz
      dist: dist
      min: min
      zipcodes: zipcodes
      ref_paths: ref_paths
      threads: threads
      read_group: combine_lanes/rg
      fq1: combine_lanes/fq1
      fq2: combine_lanes/fq2
      lane: lane_from_rg/lane_names
    scatter: [fq1, fq2, read_group, lane]
    scatterMethod: dotproduct
    out:
      - bam

  postprocess_lane:
    run: ../Tools/samtools-postprocess-lane.cwl
    in:
      bam: giraffe/bam
      rg: combine_lanes/rg
      ref_path_prefix: ref_path_prefix
      lane: lane_from_rg/lane_names
      threads: threads
    scatter: [bam, rg, lane]
    scatterMethod: dotproduct
    out:
      - sorted_bam

  to_markdup_bam:
    run: ../Tools/samtools-to-markdup-bam.cwl
    in:
      sorted_bams:
        source: postprocess_lane/sorted_bam
        valueFrom: '$(self != null && self.length > 0 ? self : null)'
      prefix: prefix
      threads: threads
    out:
      - bam
      - markdup_metrics

  deepvariant_autosome:
    run: ../Tools/deepvariant-gpu.cwl
    in:
      ref: ref
      reads: to_markdup_bam/bam
      interval: autosome_interval
      num_shards: threads
      prefix:
        source: prefix
        valueFrom: $(self + ".autosome")
    out:
      - gvcf

  deepvariant_PAR:
    run: ../Tools/deepvariant-gpu.cwl
    in:
      ref: ref
      reads: to_markdup_bam/bam
      interval: PAR_interval
      num_shards: threads
      prefix:
        source: prefix
        valueFrom: $(self + ".PAR")
    out:
      - gvcf

  deepvariant_chrX_female:
    run: ../Tools/deepvariant-gpu.cwl
    in:
      ref: ref
      reads: to_markdup_bam/bam
      interval: chrX_interval
      num_shards: threads
      prefix:
        source: prefix
        valueFrom: $(self + ".chrX_female")
    out:
      - gvcf

  deepvariant_chrX_male:
    run: ../Tools/deepvariant-gpu.cwl
    in:
      ref: ref
      reads: to_markdup_bam/bam
      interval: chrX_interval
      num_shards: threads
      postprocess_extra_args:
        valueFrom: "--haploid_contigs=chrX"
      prefix:
        source: prefix
        valueFrom: $(self + ".chrX_male")
    out:
      - gvcf

  deepvariant_chrY:
    run: ../Tools/deepvariant-gpu.cwl
    in:
      ref: ref
      reads: to_markdup_bam/bam
      interval: chrY_interval
      num_shards: threads
      postprocess_extra_args:
        valueFrom: "--haploid_contigs=chrY"
      prefix:
        source: prefix
        valueFrom: $(self + ".chrY")
    out:
      - gvcf

outputs:
  bam:
    type: File
    doc: BAM duplicate-marked, in reference coordinates
    outputSource: to_markdup_bam/bam
    secondaryFiles:
      - .bai

  markdup_metrics:
    type: File
    doc: MarkDuplicates statistics (replaces the BQSR table of the linear WGSpipeline)
    outputSource: to_markdup_bam/markdup_metrics

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