#!/usr/bin/env cwl-runner

cwlVersion: v1.1
class: ExpressionTool
id: keep-bam
label: keep-bam
doc: Pass the final duplicate-marked BAM through to the workflow output only when keep is true. The BAM is always produced internally for variant calling; this only controls whether it is materialised in the output directory.

requirements:
  InlineJavascriptRequirement: {}

inputs:
  bam_in:
    type: File
    secondaryFiles:
      - .bai

  keep:
    type: boolean
    doc: When false the BAM is not exposed as a workflow output

outputs:
  bam:
    type: File?
    secondaryFiles:
      - .bai

expression: >-
  $({
    bam: inputs.keep ? inputs.bam_in : null
  })