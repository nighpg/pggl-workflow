#!/usr/bin/env cwl-runner

# Stage 2 of the germline workflows: map ONE lane onto the pangenome and prepare
# it for duplicate marking.
#
#   vg giraffe -> vg surject (giraffe-sharded, align_chunks blocks in parallel)
#   -> strip the PanSN prefix from @SQ + apply the full @RG (samtools-prep-lane)
#
# The germline workflows scatter this over their lanes; scripts/submit-slurm.sh
# runs it as one Slurm array task per lane, so the lanes are mapped on as many
# nodes as are free.

class: Workflow
id: lane-align
label: lane-align
cwlVersion: v1.1

requirements:
  InlineJavascriptRequirement: {}

inputs:
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
    doc: Ordered reference paths of the graph (one per line, or an HTSlib .dict); drives giraffe @SQ and surjection

  ref_path_prefix:
    type: string
    doc: Reference path prefix (PanSN <sample>#<haplotype>#) to strip from @SQ contig names; empty means no strip
    default: "GRCh38#0#"

  fq1:
    type: File
    doc: FASTQ file 1 of the lane

  fq2:
    type: File
    doc: FASTQ file 2 of the lane

  rg:
    type: string
    doc: Full @RG string of the lane

  lane:
    type: string
    doc: Lane ID; names the per-lane files and must be unique within the sample

  threads:
    type: int
    doc: Number of threads for vg giraffe and samtools
    default: 32

  align_chunks:
    type: int
    doc: Number of parallel vg giraffe processes for the lane (see the germline workflows)
    default: 1

  emit_gam:
    type: boolean
    doc: Keep the lane GAM as an output
    default: false

  call_sv:
    type: boolean
    doc: Keep the lane GAM for the sample-wide vg pack of the SV track
    default: false

steps:
  giraffe:
    run: ../../Tools/giraffe-sharded.cwl
    in:
      gbz: gbz
      dist: dist
      min: min
      zipcodes: zipcodes
      ref_paths: ref_paths
      threads: threads
      read_group: rg
      fq1: fq1
      fq2: fq2
      lane: lane
      emit_gam: emit_gam
      chunks: align_chunks
      call_sv: call_sv
    out:
      - bam
      - gam
      - pack_gam

  # Lane prep for bamsormadup ("B"): strip the graph reference prefix and apply
  # the full @RG, keeping the input name-collated order (no sort -n / fixmate /
  # sort). bamsormadup then does fixmate + coordinate sort + markdup in one pass.
  prep_lane:
    run: ../../Tools/samtools-prep-lane.cwl
    in:
      bam: giraffe/bam
      rg: rg
      ref_path_prefix: ref_path_prefix
      lane: lane
      threads: threads
    out:
      - namecol_bam

outputs:
  namecol_bam:
    type: File
    doc: Name-collated lane BAM on reference contig names with the full @RG; input to duplicate marking
    outputSource: prep_lane/namecol_bam

  gam:
    type: File?
    doc: Lane GAM (only when emit_gam is set)
    outputSource: giraffe/gam

  pack_gam:
    type: File?
    doc: Lane GAM for the SV track's vg pack (only when call_sv is set)
    outputSource: giraffe/pack_gam
