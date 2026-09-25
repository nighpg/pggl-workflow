#!/usr/bin/env cwl-runner

class: CommandLineTool
id: samtools-cram-to-fastq
label: samtools-cram-to-fastq
cwlVersion: v1.1
doc: |
  Recover read-pair FASTQ from aligned reads -- CRAM or BAM -- for re-mapping
  onto a pangenome. A CRAM is decoded against the linear reference; a BAM
  carries its own sequences and needs none.

  cram and bam are separate inputs rather than one, so a job file cannot pass a
  CRAM where a BAM is meant without saying so. Giving both is an error: the
  optional ones drop out of the command line, and the script reads the argument
  count.

  Every read group of the input becomes its own lane (fq1/fq2/rg are parallel
  arrays), so per-library duplicate marking survives the round trip.

requirements:
  # Reserve the cores this step actually uses, so `cwltool --parallel` only
  # starts it when they are free instead of oversubscribing the node.
  ResourceRequirement:
    coresMin: $(inputs.threads)
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

  bam:
    type: File?
    doc: Coordinate-sorted aligned BAM; produces reads when provided (null otherwise). Mutually exclusive with cram.
    secondaryFiles:
      - { pattern: ".bai", required: false }
    inputBinding:
      position: 3

  cram:
    type: File?
    doc: Coordinate-sorted aligned CRAM in reference coordinates; produces reads when provided (null otherwise). Mutually exclusive with bam.
    secondaryFiles:
      - { pattern: ".crai", required: false }
    inputBinding:
      position: 3

  ref:
    type: File
    doc: Linear reference FASTA matching the input @SQ. Used to decode a CRAM; still required with a BAM because the rest of the workflow needs it anyway.
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
    type: File[]
    doc: Recovered read-1 FASTQ, one per read group of the input, in @RG header order (empty when neither cram nor bam is provided)
    outputBinding:
      glob: $(inputs.prefix).cram2fq.*.R1.fastq

  fq2:
    type: File[]
    doc: Recovered read-2 FASTQ, parallel to fq1
    outputBinding:
      glob: $(inputs.prefix).cram2fq.*.R2.fastq

  rg:
    type: File
    doc: The @RG line of each recovered lane, one per line, parallel to fq1 (an empty file when neither cram nor bam is provided)
    outputBinding:
      glob: $(inputs.prefix).cram2fq.rg.txt
