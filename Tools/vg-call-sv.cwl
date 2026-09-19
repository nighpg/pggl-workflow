#!/usr/bin/env cwl-runner

class: CommandLineTool
id: vg-call-sv
label: vg-call (genotype graph SVs)
cwlVersion: v1.1

requirements:
  InlineJavascriptRequirement: {}
  InitialWorkDirRequirement:
    listing:
      - class: File
        location: ../scripts/vg-call-sv.sh
        basename: vg-call-sv.sh

hints:
  DockerRequirement:
    dockerPull: quay.io/vgteam/vg:v1.70.0
    dockerFile: |
      # Runs under cwltool --no-container in this project, where vg and
      # bcftools must both be on PATH (vg call writes the VCF, bcftools sorts
      # and indexes it). This hint only records the upstream tool image.

baseCommand: [bash, vg-call-sv.sh]

inputs:
  gbz:
    type: File
    doc: GBZ pangenome graph; its embedded haplotypes define the SV alleles that can be genotyped

  pack:
    type: File?
    doc: Sample-wide read support from vg-pack; null when call_sv is false, in which case no output is produced

  ref_paths:
    type: File?
    doc: Ordered reference path names, one per line (the same file the aligner uses). The VCF ##contig block is emitted in this order so it matches the BAM @SQ order.

  snarls:
    type: File?
    doc: Precomputed snarls (vg snarls) for this graph. Optional but strongly recommended for whole-genome graphs, where recomputing them on every run is expensive.

  prefix:
    type: string
    doc: Output file prefix; produces <prefix>.sv.vcf.gz (+ .tbi)

  sample:
    type: string
    doc: Sample name written into the VCF; taken from the SM field of the read groups so it matches the gVCFs
    default: SAMPLE

  threads:
    type: int
    doc: Number of threads for vg call
    default: 1

  min_length:
    type: int
    doc: Genotype only snarls with a traversal of at least this length, i.e. keep SVs only (vg call -c)
    default: 50

  ref_path_prefix:
    type: string
    doc: Reference path prefix (PanSN <sample>#<haplotype>#) to strip from the VCF contig names, e.g. GRCh38#0#; empty means no strip
    default: ""

arguments:
  - position: 1
    valueFrom: $(inputs.gbz.path)
  - position: 2
    valueFrom: $(inputs.prefix)
  - position: 3
    valueFrom: $(inputs.sample)
  - position: 4
    valueFrom: $(inputs.threads)
  - position: 5
    valueFrom: $(inputs.min_length)
  - position: 6
    valueFrom: $(inputs.ref_path_prefix)
  - position: 7
    valueFrom: '$(inputs.ref_paths != null ? ["--ref-paths", inputs.ref_paths.path] : [])'
  - position: 8
    valueFrom: '$(inputs.snarls != null ? ["--snarls", inputs.snarls.path] : [])'
  - position: 9
    valueFrom: '$(inputs.pack != null ? ["--pack", inputs.pack.path] : [])'

outputs:
  sv_vcf:
    type: File?
    doc: Genotyped structural variants in reference coordinates (null when SV calling is disabled)
    outputBinding:
      glob: $(inputs.prefix).sv.vcf.gz
    secondaryFiles:
      - pattern: ".tbi"
