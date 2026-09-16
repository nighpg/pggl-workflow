#!/usr/bin/env cwl-runner

class: CommandLineTool
id: samtools-postprocess-lane
label: samtools-postprocess-lane
cwlVersion: v1.1

requirements:
  InlineJavascriptRequirement: {}
  InitialWorkDirRequirement:
    listing:
      - class: File
        location: ../scripts/samtools-postprocess-lane.sh
        basename: samtools-postprocess-lane.sh

hints:
  DockerRequirement:
    dockerPull: quay.io/biocontainers/samtools:1.21--h96c455f_1

baseCommand: [bash, samtools-postprocess-lane.sh]

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
  sorted_bam:
    type: File
    doc: Coordinate-sorted, mate-fixed, re-paired BAM with the full @RG header on GRCh38 contig names
    outputBinding:
      glob: $(inputs.lane).sorted.bam