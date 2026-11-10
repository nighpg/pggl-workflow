#!/usr/bin/env cwl-runner

class: CommandLineTool
id: concat-gvcfs
label: bcftools concat (per-chunk autosome gVCFs or VCFs)
cwlVersion: v1.1

$namespaces:
  cwltool: http://commonwl.org/cwltool#

requirements:
  InlineJavascriptRequirement: {}
  InitialWorkDirRequirement:
    listing:
      - class: File
        location: ../scripts/concat-gvcfs.sh
        basename: concat-gvcfs.sh

hints:
  DockerRequirement:
    dockerPull: quay.io/biocontainers/bcftools:1.19--h8b25389_0

baseCommand: [bash, concat-gvcfs.sh]

inputs:
  prefix:
    type: string
    doc: Output prefix; produces <prefix>.autosome.g.vcf.gz (+ .tbi)
    inputBinding:
      position: 1

  suffix:
    type: string
    doc: Extension of the inputs and the output, g.vcf.gz (gVCFs) or vcf.gz (the plain VCFs)
    default: g.vcf.gz
    inputBinding:
      position: 2
      prefix: --suffix

  gvcf:
    type:
      type: array
      items: File
    doc: Per-chunk autosome gVCFs (or VCFs) to concatenate, in genomic order
    inputBinding:
      position: 3

outputs:
  out_gvcf:
    type: File
    doc: Concatenated, tabix-indexed autosome gVCF (or VCF)
    outputBinding:
      glob: $(inputs.prefix).autosome.$(inputs.suffix)
    secondaryFiles:
      - pattern: ".tbi"

  tbi:
    type: File?
    doc: Tabix index of the concatenated autosome gVCF
    outputBinding:
      glob: $(inputs.prefix).autosome.$(inputs.suffix).tbi