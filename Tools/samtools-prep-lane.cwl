#!/usr/bin/env cwl-runner

class: CommandLineTool
id: samtools-prep-lane
label: samtools-prep-lane
cwlVersion: v1.1

requirements:
  InlineJavascriptRequirement: {}
  InitialWorkDirRequirement:
    listing:
      - class: File
        location: ../scripts/samtools-prep-lane.sh
        basename: samtools-prep-lane.sh

hints:
  DockerRequirement:
    dockerPull: quay.io/biocontainers/samtools:1.21--h96c455f_1

baseCommand: [bash, samtools-prep-lane.sh]

inputs:
  bam:
    type: File
    doc: Per-lane BAM from vg giraffe (contig names may carry a graph reference prefix)
    inputBinding:
      position: 1

  lane:
    type: string
    doc: Lane / read-group ID used to name the output BAM
    inputBinding:
      position: 2

  threads:
    type: int
    doc: Number of threads
    default: 1
    inputBinding:
      position: 3

  rg:
    type: string
    doc: Full read group string (@RG\\tID:...); literal \\t or real tabs are accepted
    inputBinding:
      position: 4

  ref_path_prefix:
    type: string
    doc: Reference path prefix to strip from @SQ contig names (e.g. GRCh38#0#); may be empty
    default: ""
    inputBinding:
      position: 5

outputs:
  namecol_bam:
    type: File
    doc: Name-collated (input read order) BAM with the full @RG header on GRCh38 contig names, BAM level 6; input to bamsormadup-to-markdup-bam
    outputBinding:
      glob: $(inputs.lane).namecol.bam
