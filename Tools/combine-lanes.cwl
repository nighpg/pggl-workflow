cwlVersion: v1.1
class: ExpressionTool
id: combine-lanes
label: combine-lanes
doc: Concatenate user-provided FASTQ lanes with the CRAM-recovered lane (if any) into one set of arrays for the aligner.

requirements:
  InlineJavascriptRequirement: {}

inputs:
  user_fq1:
    type: File[]?
    doc: FASTQ file 1 per user lane
    default: []

  user_fq2:
    type: File[]?
    doc: FASTQ file 2 per user lane
    default: []

  user_rg:
    type: string[]?
    doc: Read group string per user lane
    default: []

  cram_fq1:
    type: File?
    doc: Recovered read-1 FASTQ (CRAM track)

  cram_fq2:
    type: File?
    doc: Recovered read-2 FASTQ (CRAM track)

  cram_rg:
    type: File?
    doc: File containing the @RG line recovered from the CRAM header

outputs:
  fq1:
    type: File[]
  fq2:
    type: File[]
  rg:
    type: string[]

expression: >-
  $({
    fq1: (inputs.user_fq1 || []).concat(inputs.cram_fq1 ? [inputs.cram_fq1] : []),
    fq2: (inputs.user_fq2 || []).concat(inputs.cram_fq2 ? [inputs.cram_fq2] : []),
    rg: (inputs.user_rg || []).concat(inputs.cram_rg && String(inputs.cram_rg.contents || "").trim() ? [String(inputs.cram_rg.contents).trim()] : [])
  })