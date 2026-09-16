#!/usr/bin/env cwl-runner

class: CommandLineTool
id: samtools-cram-to-fastq
label: samtools-cram-to-fastq
cwlVersion: v1.1
doc: Recover read-pair FASTQ from an aligned CRAM (decoded with the linear reference) for re-mapping onto a pangenome.

requirements:
  InlineJavascriptRequirement: {}
  InitialWorkDirRequirement:
    listing:
      - class: File
        location: ../scripts/samtools-cram-to-fastq.sh
        basename: samtools-cram-to-fastq.sh

hints:
  DockerRequirement:
    dockerPull: quay.io/biocontainers/samtools:1.21--h96c455f_1

baseCommand: [bash, samtools-cram-to-fastq.sh]

inputs:
  prefix:
    type: string
    doc: Output file prefix (also used for a synthetic read group when the CRAM header has none)

  threads:
    type: int
    doc: Number of threads
    default: 1

  cram:
    type: File?
    doc: Coordinate-sorted aligned CRAM in reference coordinates; produces reads when provided (null otherwise)
    secondaryFiles:
      - { pattern: ".crai", required: false }
    inputBinding:
      position: 3

  ref:
    type: File
    doc: Linear reference FASTA matching the CRAM @SQ (used to decode); sequences must match the graph reference paths
    secondaryFiles:
      - .fai
    inputBinding:
      position: 4

arguments:
  - position: 1
    valueFrom: $(inputs.prefix)
  - position: 2
    valueFrom: $(inputs.threads)

outputs:
  fq1:
    type: File?
    doc: Recovered read-1 FASTQ (null when cram is not provided)
    outputBinding:
      glob: $(inputs.prefix).cram2fq.R1.fastq

  fq2:
    type: File?
    doc: Recovered read-2 FASTQ (null when cram is not provided)
    outputBinding:
      glob: $(inputs.prefix).cram2fq.R2.fastq

  rg:
    type: File?
    doc: Read group @RG line carried over from the CRAM header (null when cram is not provided)
    outputBinding:
      glob: $(inputs.prefix).cram2fq.rg.txt