#!/usr/bin/env cwl-runner

# Duplicate marking over all lanes: the BAM the DeepVariant calls read. One of
# the three parts of the calling stage (with parts/call-sv.cwl and a
# parts/call-dv-*.cwl); scripts/submit-slurm.sh --variant parabricks runs each as
# its own Slurm job, so DeepVariant starts on the GPU node as soon as this BAM
# exists, without waiting for the graph SVs.
class: Workflow
id: call-markdup
label: call-markdup
cwlVersion: v1.1

requirements:
  InlineJavascriptRequirement: {}
  ScatterFeatureRequirement: {}
  StepInputExpressionRequirement: {}

inputs:
  prefix:
    type: string
    doc: Output file prefix

  threads:
    type: int
    doc: CPU threads for vg giraffe, samtools and the DeepVariant shards. How many GPUs the run uses is not set here -- it is whatever CUDA is allowed to see (apptainer --nv, NVIDIA_VISIBLE_DEVICES, Slurm --gres).
    default: 32

  namecol_bams:
    type: File[]
    doc: Name-collated lane BAMs from parts/lane-align.cwl, in lane order; duplicate-marked together

  gams:
    type:
      - "null"
      - type: array
        items: ["null", File]
    doc: Lane GAMs to pass through as the gam output (emit_gam); nulls are dropped
    default: []

steps:
  pick_gam:
    run: ../../Tools/pick-gam.cwl
    in:
      gam_in: gams
    out:
      - gam

  to_markdup_bam:
    run: ../../Tools/bamsormadup-to-markdup-bam.cwl
    in:
      namecol_bams:
        source: namecol_bams
        valueFrom: '$(self != null && self.length > 0 ? self : null)'
      prefix: prefix
      threads: threads
    out:
      - bam
      - markdup_metrics

outputs:
  bam:
    type: File
    doc: BAM duplicate-marked, in reference coordinates; always written, since the DeepVariant calls read it
    outputSource: to_markdup_bam/bam
    secondaryFiles:
      - .bai

  gam:
    type: File[]?
    doc: Per-lane graph-space alignment in GAM format (kept when emit_gam is true)
    outputSource: pick_gam/gam

  markdup_metrics:
    type: File
    doc: MarkDuplicates statistics (replaces the BQSR table of the linear WGSpipeline)
    outputSource: to_markdup_bam/markdup_metrics
