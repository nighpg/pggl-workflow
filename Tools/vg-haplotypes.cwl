#!/usr/bin/env cwl-runner

class: CommandLineTool
id: vg-haplotypes
label: vg haplotypes (sample a personalized pangenome)
cwlVersion: v1.1

doc: |
  Cuts the pangenome down to the haplotypes matching the sample's k-mers, so
  variation the sample does not carry stops misleading the mapper.

  The reference is kept (--include-reference / --set-reference): sampling
  otherwise drops it along with the other haplotypes, leaving `vg surject` with
  nothing to project onto. The step fails if no reference path survives rather
  than passing on a graph the rest of the pipeline cannot use.

requirements:
  InlineJavascriptRequirement: {}
  InitialWorkDirRequirement:
    listing:
      - class: File
        location: ../scripts/vg-haplotypes.sh
        basename: vg-haplotypes.sh

hints:
  DockerRequirement:
    dockerPull: quay.io/vgteam/vg:v1.70.0

baseCommand: [bash, vg-haplotypes.sh]

inputs:
  gbz:
    type: File
    doc: The full pangenome graph to sample from
    inputBinding:
      position: 1

  hapl:
    type: File
    doc: |
      Haplotype information for this graph (vg haplotypes -H), built once per
      graph from its distance index and r-index. It is an input because it is
      the same for every sample and costs a pass over the whole graph. Its
      format is versioned: vg 1.70 rejects the version 4 files shipped with some
      graphs ("Expected version 5 to 5, got version 4"), so rebuild rather than
      reuse a downloaded one.
    inputBinding:
      position: 2

  kff:
    type: File
    doc: The sample's k-mer counts, from the kmc step
    inputBinding:
      position: 3

  ref_sample:
    type: string
    doc: PanSN sample name of the reference to keep in the sampled graph (GRCh38, CHM13v2). Empty keeps the graph's own reference designation.
    default: "GRCh38"
    inputBinding:
      position: 4

  prefix:
    type: string
    doc: Output file prefix; produces <prefix>.personalized.gbz
    inputBinding:
      position: 5

  threads:
    type: int
    default: 16
    inputBinding:
      position: 6

  diploid_sampling:
    type: boolean
    doc: Pick the best pair of candidate haplotypes instead of the greedy set (vg's recommendation). It needs enough coverage to tell heterozygous from homozygous k-mers -- the vg wiki asks for 20x.
    default: true

arguments:
  - position: 7
    valueFrom: '$(inputs.diploid_sampling ? "true" : "false")'

outputs:
  personalized_gbz:
    type: File
    doc: The sample's personalized pangenome
    outputBinding:
      glob: $(inputs.prefix).personalized.gbz
