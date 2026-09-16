#!/usr/bin/env cwl-runner

class: CommandLineTool
id: vg-giraffe
label: vg-giraffe
cwlVersion: v1.1

$namespaces:
  cwltool: http://commonwl.org/cwltool#

requirements:
  InlineJavascriptRequirement: {}

hints:
  DockerRequirement:
    dockerPull: quay.io/vgteam/vg:v1.70.0

baseCommand: [vg, giraffe]

inputs:
  gbz:
    type: File
    doc: GBZ pangenome graph
    inputBinding:
      prefix: -Z
      position: 1

  dist:
    type: File
    doc: giraffe distance index (.dist)
    inputBinding:
      prefix: -d
      position: 2

  min:
    type: File
    doc: giraffe minimizer index (.min)
    inputBinding:
      prefix: -m
      position: 3

  zipcodes:
    type: File
    doc: giraffe zipcode index (.zipcodes)
    inputBinding:
      prefix: -z
      position: 4

  ref_paths:
    type: File
    doc: Ordered list of reference paths in the graph, one per line, to surject reads to and to use for the @SQ header
    inputBinding:
      prefix: --ref-paths
      position: 5

  threads:
    type: int
    doc: Number of mapping threads
    inputBinding:
      prefix: -t
      position: 6

  read_group:
    type: string?
    doc: Read group string. Only the ID is set here; the full @RG string is applied afterwards with samtools addreplacerg
    inputBinding:
      prefix: -R
      position: 7

  sample:
    type: string?
    doc: Sample name (sets SM)
    inputBinding:
      prefix: -N
      position: 8

  fq1:
    type: File
    doc: FASTQ file 1
    inputBinding:
      prefix: -f
      position: 9

  fq2:
    type: File
    doc: FASTQ file 2
    inputBinding:
      prefix: -f
      position: 10

  lane:
    type: string
    doc: Lane / read-group ID used to name the output BAM; must be unique per lane

arguments:
  - position: 11
    valueFrom: --output-format
  - position: 12
    valueFrom: BAM

stdout: $(inputs.lane).bam

outputs:
  bam:
    type: File
    doc: Aligned BAM in reference path coordinates
    outputBinding:
      glob: $(inputs.lane).bam