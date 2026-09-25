#!/usr/bin/env cwl-runner

class: CommandLineTool
id: bamsormadup-to-markdup-bam
label: bamsormadup-to-markdup-bam
cwlVersion: v1.1

requirements:
  # Reserve the cores this step actually uses, so `cwltool --parallel` only
  # starts it when they are free instead of oversubscribing the node.
  ResourceRequirement:
    coresMin: $(inputs.threads)
  InlineJavascriptRequirement: {}
  InitialWorkDirRequirement:
    listing:
      - class: File
        location: ../scripts/bamsormadup-to-markdup-bam.sh
        basename: bamsormadup-to-markdup-bam.sh

hints:
  DockerRequirement:
    dockerPull: quay.io/biocontainers/biobambam2:latest
    dockerFile: |
      # Runs under cwltool --no-container in this project, where bamsormadup
      # (biobambam2) and samtools must both be on PATH. This hint only records
      # the upstream tool image and is used solely for provenance.
      # bamsormadup does fixmate + coordinate sort + markdup in one pass and
      # also marks optical duplicates (optminpixeldif).

baseCommand: [bash, bamsormadup-to-markdup-bam.sh]

inputs:
  namecol_bams:
    type: File[]?
    doc: Name-collated per-lane BAMs (from samtools-prep-lane) on reference contig names; concatenated with samtools cat

  prefix:
    type: string
    doc: Output file prefix

  threads:
    type: int
    doc: Number of threads for bamsormadup and samtools
    default: 1

  level:
    type: int
    doc: BAM compression level for the output
    default: 6

arguments:
  - position: 1
    valueFrom: $(inputs.prefix)
  - position: 2
    valueFrom: $(inputs.threads)
  - position: 3
    valueFrom: $(["--level", String(inputs.level)])
  - position: 4
    valueFrom: '$(inputs.namecol_bams != null && inputs.namecol_bams.length > 0 ? ["--bams"].concat(inputs.namecol_bams.map(function(f){ return f.path })) : [])'

outputs:
  bam:
    type: File
    doc: Duplicate-marked, coordinate-sorted BAM on reference coordinates
    outputBinding:
      glob: $(inputs.prefix).bam
    secondaryFiles:
      - .bai

  markdup_metrics:
    type: File
    doc: bamsormadup duplicate-marking statistics (replaces the BQSR table of the linear WGSpipeline)
    outputBinding:
      glob: $(inputs.prefix).markdup.metrics
