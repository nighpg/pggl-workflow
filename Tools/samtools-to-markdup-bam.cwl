#!/usr/bin/env cwl-runner

class: CommandLineTool
id: samtools-to-markdup-bam
label: samtools-to-markdup-bam
cwlVersion: v1.1

requirements:
  InlineJavascriptRequirement: {}
  InitialWorkDirRequirement:
    listing:
      - class: File
        location: ../scripts/samtools-to-markdup-bam.sh
        basename: samtools-to-markdup-bam.sh

hints:
  DockerRequirement:
    dockerPull: quay.io/biocontainers/samtools:1.21--h96c455f_1

baseCommand: [bash, samtools-to-markdup-bam.sh]

inputs:
  sorted_bams:
    type: File[]?
    doc: Coordinate-sorted per-lane BAMs on reference contig names (from vg giraffe + postprocess)

  prefix:
    type: string
    doc: Output file prefix

  threads:
    type: int
    doc: Number of threads
    default: 1

arguments:
  - position: 1
    valueFrom: $(inputs.prefix)
  - position: 2
    valueFrom: $(inputs.threads)
  - position: 3
    valueFrom: '$(inputs.sorted_bams != null && inputs.sorted_bams.length > 0 ? ["--bams"].concat(inputs.sorted_bams.map(function(f){ return f.path })) : [])'

outputs:
  bam:
    type: File
    doc: Duplicate-marked BAM on reference coordinates
    outputBinding:
      glob: $(inputs.prefix).bam
    secondaryFiles:
      - .bai

  markdup_metrics:
    type: File
    doc: MarkDuplicates statistics (replaces the BQSR table of the linear WGSpipeline)
    outputBinding:
      glob: $(inputs.prefix).markdup.metrics