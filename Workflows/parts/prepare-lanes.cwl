#!/usr/bin/env cwl-runner

# Stage 1 of the germline workflows: turn the reads, however they were given,
# into one list of lanes -- FASTQ pair + @RG string + lane ID each -- plus the
# sample name. The FASTQ lanes pass through; a CRAM/BAM is decoded into one lane
# per read group.
#
# Used as a subworkflow by Workflows/germline-pangenome-*.cwl, and run on its
# own by scripts/submit-slurm.sh, which then maps every lane as its own Slurm
# job (parts/lane-align.cwl).

class: Workflow
id: prepare-lanes
label: prepare-lanes
cwlVersion: v1.1

requirements:
  InlineJavascriptRequirement: {}
  StepInputExpressionRequirement: {}

inputs:
  fq1:
    type: File[]?
    doc: FASTQ file 1, one per lane
    default: []

  fq2:
    type: File[]?
    doc: FASTQ file 2, one per lane
    default: []

  rg:
    type: string[]?
    doc: Full @RG string, one per lane
    default: []

  cram:
    type: File?
    doc: Aligned CRAM to recover lanes from (one per @RG). Mutually exclusive with bam.
    secondaryFiles:
      - { pattern: ".crai", required: false }

  bam:
    type: File?
    doc: Aligned BAM to recover lanes from (one per @RG). Mutually exclusive with cram.
    secondaryFiles:
      - { pattern: ".bai", required: false }

  ref:
    type: File
    doc: Linear reference FASTA; decodes a CRAM
    secondaryFiles:
      - ^.dict
      - .fai

  prefix:
    type: string
    doc: Output file prefix

  threads:
    type: int
    doc: Number of threads for the CRAM/BAM decoding
    default: 32

steps:
  cram_to_fastq:
    run: ../../Tools/samtools-cram-to-fastq.cwl
    in:
      prefix: prefix
      threads: threads
      cram: cram
      bam: bam
      ref: ref
    out:
      - fq1
      - fq2
      - rg

  combine_lanes:
    run: ../../Tools/combine-lanes.cwl
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

  lane_from_rg:
    run: ../../Tools/lane-from-rg.cwl
    in:
      rg: combine_lanes/rg
    out:
      - lane_names
      - sample_name

outputs:
  fq1:
    type: File[]
    doc: FASTQ file 1 of every lane, in lane order
    outputSource: combine_lanes/fq1

  fq2:
    type: File[]
    doc: FASTQ file 2 of every lane, parallel to fq1
    outputSource: combine_lanes/fq2

  rg:
    type: string[]
    doc: Full @RG string of every lane, parallel to fq1
    outputSource: combine_lanes/rg

  lane:
    type: string[]
    doc: Lane ID (the @RG ID) of every lane, parallel to fq1; names the per-lane files
    outputSource: lane_from_rg/lane_names

  sample_name:
    type: string
    doc: Sample name (SM of the first read group that has one); names the sample in the SV VCF
    outputSource: lane_from_rg/sample_name
