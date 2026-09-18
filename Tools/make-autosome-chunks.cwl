#!/usr/bin/env cwl-runner

class: CommandLineTool
id: make-autosome-chunks
label: Derive DeepVariant autosome chunks from one interval BED
cwlVersion: v1.1

requirements:
  InlineJavascriptRequirement: {}
  InitialWorkDirRequirement:
    listing:
      - class: File
        location: ../scripts/make-autosome-chunks.sh
        basename: make-autosome-chunks.sh

hints:
  DockerRequirement:
    dockerPull: quay.io/biocontainers/bedtools:2.31.1--hf5e1c6e_2
    dockerFile: |
      # Only coreutils/awk are needed here; this hint records provenance for
      # cwltool --no-container runs. Chunks are derived automatically so the
      # user never has to pre-split the autosome BED or list chunk files.

baseCommand: [bash, make-autosome-chunks.sh]

inputs:
  bed:
    type: File
    doc: Autosome interval BED (one or more contigs) to partition into DeepVariant chunks
    inputBinding:
      position: 1

  count:
    type: int?
    doc: Number of chunks. Omit or 0 = a single chunk over the whole interval (same as providing no chunks before). N>=2 groups contiguous contigs into ~N bp-balanced chunks; if N >= the number of contigs, one chunk per contig. Ignored when explicit chunks are supplied.
    default: 0

  user_chunks:
    type:
      - type: array
        items: File
      - "null"
    doc: Optional explicit chunk BED files; when given they are used verbatim (in this order) and no automatic splitting happens.
    inputBinding:
      position: 3

arguments:
  - position: 2
    valueFrom: '$(inputs.count != null && inputs.count > 1 ? String(inputs.count) : "-")'

outputs:
  chunks:
    type: File[]
    doc: Autosome chunk BEDs in genomic order, one per DeepVariant job
    outputBinding:
      glob: chunk_*.bed
